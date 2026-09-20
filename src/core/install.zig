//! Local package management: install a `.zpkg` file, remove an installed
//! package, list what's installed, show details. Everything here is local
//! — no repository lookups, no network (that's Phase 4; signature
//! verification for repository-sourced packages happens even earlier, in
//! `repository.Manager.find`/`verifySignature`, before a path ever reaches
//! this file).
//!
//! `install` follows the spec's install flow: download (Phase 4, already
//! done by the time a path lands here) → verify (checksum, via
//! `Transaction.addInstallStreamed`, plus signature upstream) → prepare →
//! transaction → commit, the last three handled by `core/transaction.zig`
//! (Phase 8). Verification and file-writing are streamed (Phase 9): peak
//! RAM is one 64 KiB chunk regardless of package size, not the whole
//! `.zpkg`.

const std = @import("std");
const errors = @import("errors.zig");
const config_mod = @import("config.zig");
const log = @import("log.zig");
const db_mod = @import("../database/db.zig");
const transaction_mod = @import("transaction.zig");
const package_mod = @import("../package/package.zig");

/// Cap for `plan.execute`'s per-dependency reads (still whole-buffer, one
/// package at a time -- see the README's Phase 9 notes on why that's
/// lower priority than this file's single-package `install` path, which
/// no longer needs this constant itself now that it streams).
pub const max_zpkg_bytes: usize = 512 * 1024 * 1024;

/// Installs the `.zpkg` at `zpkg_path` as a single transaction (Phase 8):
/// staged, journaled, then committed. Fails with `error.AlreadyInstalled`
/// if a package with the same name is already tracked in the database —
/// upgrades go through `plan.execute`'s combined remove+install
/// transaction instead.
pub fn install(allocator: std.mem.Allocator, config: config_mod.Config, zpkg_path: []const u8) !void {
    try transaction_mod.recover(allocator, config);

    var txn = transaction_mod.Transaction.init(allocator, config);
    defer txn.deinit();

    const m = try txn.addInstallStreamed(zpkg_path);

    const db = db_mod.Database.init(config.database_path);
    if (try db.isInstalled(allocator, m.name)) {
        txn.discardLastInstall();
        return error.AlreadyInstalled;
    }

    try txn.prepare();
    try txn.commit();

    log.info("installed {s} {s}", .{ m.name, m.version });
}

/// Removes an installed package by name, as a single transaction.
pub fn remove(allocator: std.mem.Allocator, config: config_mod.Config, name: []const u8) !void {
    try transaction_mod.recover(allocator, config);

    var txn = transaction_mod.Transaction.init(allocator, config);
    defer txn.deinit();
    try txn.addRemove(name); // error.NotInstalled if not tracked
    try txn.prepare();
    try txn.commit();

    log.info("removed {s}", .{name});
}

/// Names of all installed packages. Caller owns the result (see
/// `Database.list`).
pub fn list(allocator: std.mem.Allocator, config: config_mod.Config) ![][]const u8 {
    const db = db_mod.Database.init(config.database_path);
    return db.list(allocator);
}

/// Caller must call `.deinit()` on the result.
pub fn info(allocator: std.mem.Allocator, config: config_mod.Config, name: []const u8) !std.json.Parsed(db_mod.InstalledPackage) {
    const db = db_mod.Database.init(config.database_path);
    return (try db.get(allocator, name)) orelse error.NotInstalled;
}

test "install then info then remove, using a temp root and temp db" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const tmp_path = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(tmp_path);

    const install_root = try std.fmt.allocPrint(allocator, "{s}/root", .{tmp_path});
    defer allocator.free(install_root);
    const database_path = try std.fmt.allocPrint(allocator, "{s}/db", .{tmp_path});
    defer allocator.free(database_path);
    const cache_dir = try std.fmt.allocPrint(allocator, "{s}/cache", .{tmp_path});
    defer allocator.free(cache_dir);

    var config = config_mod.default();
    config.install_root = install_root;
    config.database_path = database_path;
    config.cache_dir = cache_dir;

    // Build a .zpkg on disk to install.
    const files = [_]package_mod.FileData{
        .{ .path = "bin/hello", .content = "#!/bin/sh\necho hi\n" },
    };
    const m = package_mod.Manifest{ .name = "hello", .version = "1.0.0", .architecture = "x86_64" };
    const zpkg_bytes = try package_mod.create(allocator, m, &files);
    defer allocator.free(zpkg_bytes);

    const zpkg_path = try std.fmt.allocPrint(allocator, "{s}/hello.zpkg", .{tmp_path});
    defer allocator.free(zpkg_path);
    try std.fs.cwd().writeFile(.{ .sub_path = zpkg_path, .data = zpkg_bytes });

    try install(allocator, config, zpkg_path);
    try std.testing.expectError(error.AlreadyInstalled, install(allocator, config, zpkg_path));

    const installed_file = try std.fmt.allocPrint(allocator, "{s}/bin/hello", .{install_root});
    defer allocator.free(installed_file);
    const written = try std.fs.cwd().readFileAlloc(allocator, installed_file, 1024);
    defer allocator.free(written);
    try std.testing.expectEqualStrings("#!/bin/sh\necho hi\n", written);

    const names = try list(allocator, config);
    defer {
        for (names) |n| allocator.free(n);
        allocator.free(names);
    }
    try std.testing.expectEqual(@as(usize, 1), names.len);
    try std.testing.expectEqualStrings("hello", names[0]);

    const parsed = try info(allocator, config, "hello");
    defer parsed.deinit();
    try std.testing.expectEqualStrings("1.0.0", parsed.value.version);

    try remove(allocator, config, "hello");
    try std.testing.expectError(error.NotInstalled, remove(allocator, config, "hello"));
    try std.testing.expectError(error.FileNotFound, std.fs.cwd().access(installed_file, .{}));
}
