//! Dispatches a parsed `Command` to its implementation.
//!
//! Phase 3 wired install/remove/list/info against the local database;
//! Phase 4 adds the repository layer, so `update` and `search` are real and
//! `install` accepts a package *name* (resolved via repositories) as well
//! as a local `.zpkg` path. `upgrade`/`clean`/`doctor` remain stubs.

const std = @import("std");
const args = @import("args.zig");
const config_mod = @import("../core/config.zig");
const errors = @import("../core/errors.zig");
const log = @import("../core/log.zig");
const install_mod = @import("../core/install.zig");
const repository = @import("../repository/repository.zig");
const repos_config = @import("../repository/repos_config.zig");
const plan_mod = @import("../core/plan.zig");
const resolver = @import("../resolver/resolver.zig");
const cache_mod = @import("../core/cache.zig");
const transaction_mod = @import("../core/transaction.zig");
<<<<<<< HEAD
const doctor_mod = @import("../core/doctor.zig");
=======
>>>>>>> ea9b338f92142d8d550400180e6c2b8d63a0e406
const package_mod = @import("../package/package.zig");
const index_mod = @import("../repository/index.zig");
const checksum_mod = @import("../package/checksum.zig");
const db_mod = @import("../database/db.zig");

/// Builds a repository Manager from the configured repositories file.
/// Returns null when no repositories are configured.
fn openManager(
    allocator: std.mem.Allocator,
    config: config_mod.Config,
    loaded_out: *?repos_config.Loaded,
) !?repository.Manager {
    const loaded = (try repos_config.load(allocator, config)) orelse return null;
    loaded_out.* = loaded;
    return repository.Manager.init(allocator, config, loaded.value);
}

pub fn dispatch(allocator: std.mem.Allocator, config: config_mod.Config, cmd: args.Command) !void {
    // Self-heals a transaction left mid-commit by a previous, interrupted
    // run before this one does anything else -- cheap when there's
    // nothing pending, and means recovery never needs a separate command.
    try transaction_mod.recover(allocator, config);

    const stdout = std.io.getStdOut().writer();

    switch (cmd) {
        // A argument containing a path separator or ending in .zpkg is a
        // local file; anything else is a package name to resolve against
        // the configured repositories.
        .install => |target| {
            if (std.mem.endsWith(u8, target, ".zpkg") or std.mem.indexOfScalar(u8, target, '/') != null) {
                try install_mod.install(allocator, config, target);
            } else {
                try installByName(allocator, config, target);
            }
        },

        .remove => |name| try install_mod.remove(allocator, config, name),

        .list => {
            const names = try install_mod.list(allocator, config);
            defer {
                for (names) |n| allocator.free(n);
                allocator.free(names);
            }
            if (names.len == 0) {
                log.info("no packages installed", .{});
            } else {
                for (names) |n| stdout.print("{s}\n", .{n}) catch {};
            }
        },

        // Prefer the installed package's own record; fall back to
        // repository metadata so `info` works for not-yet-installed
        // packages too.
        .info => |name| {
            if (install_mod.info(allocator, config, name)) |parsed| {
                defer parsed.deinit();
                const pkg = parsed.value;
                stdout.print("name:         {s}\n", .{pkg.name}) catch {};
                stdout.print("version:      {s}\n", .{pkg.version}) catch {};
                stdout.print("architecture: {s}\n", .{pkg.architecture}) catch {};
                stdout.print("state:        installed\n", .{}) catch {};
                stdout.print("files:        {d}\n", .{pkg.files.len}) catch {};
                stdout.print("dependencies: {d}\n", .{pkg.dependencies.len}) catch {};
                return;
            } else |e| {
                if (e != error.NotInstalled) return e;
            }

            var loaded: ?repos_config.Loaded = null;
            defer if (loaded) |l| l.deinit();
            const mgr = (try openManager(allocator, config, &loaded)) orelse return error.NotInstalled;

            const found = (try mgr.find(name)) orelse return error.NotInstalled;
            defer mgr.freeFound(found);
            stdout.print("name:         {s}\n", .{found.entry.name}) catch {};
            stdout.print("version:      {s}\n", .{found.entry.version}) catch {};
            stdout.print("architecture: {s}\n", .{found.entry.architecture}) catch {};
            stdout.print("state:        available ({s})\n", .{found.repo_name}) catch {};
            if (found.entry.description.len > 0) {
                stdout.print("description:  {s}\n", .{found.entry.description}) catch {};
            }
        },

        .update => {
            var loaded: ?repos_config.Loaded = null;
            defer if (loaded) |l| l.deinit();
            const mgr = (try openManager(allocator, config, &loaded)) orelse return error.NoRepositories;
            try mgr.update();
        },

        .search => |query| {
            var loaded: ?repos_config.Loaded = null;
            defer if (loaded) |l| l.deinit();
            const mgr = (try openManager(allocator, config, &loaded)) orelse return error.NoRepositories;

            const results = try mgr.search(query);
            defer {
                for (results) |f| mgr.freeFound(f);
                allocator.free(results);
            }
            if (results.len == 0) {
                log.info("no packages matching '{s}'", .{query});
                return;
            }
            for (results) |f| {
                stdout.print("{s} {s} [{s}]", .{ f.entry.name, f.entry.version, f.repo_name }) catch {};
                if (f.entry.description.len > 0) {
                    stdout.print(" - {s}", .{f.entry.description}) catch {};
                }
                stdout.print("\n", .{}) catch {};
            }
        },

        .upgrade => try upgradeAll(allocator, config),
        .clean => {
            const stats = try cache_mod.clean(allocator, config, .{});
            var buf: [32]u8 = undefined;
            log.info("removed {d} cached file(s), freed {s}", .{
                stats.files,
                cache_mod.formatBytes(&buf, stats.bytes),
            });
        },
        .doctor => {
<<<<<<< HEAD
            const report = doctor_mod.run(allocator, config);
            log.info("{d} check(s), {d} problem(s)", .{ report.checks, report.problems });
            if (report.problems > 0) return error.DoctorFoundProblems;
=======
            log.err("'doctor' is not implemented yet (planned for Phase 10)", .{});
            return error.NotImplemented;
>>>>>>> ea9b338f92142d8d550400180e6c2b8d63a0e406
        },
    }
}

/// Resolves `name` and its dependencies against the configured
/// repositories, then downloads and installs the whole plan in dependency
/// order. Packages already installed and satisfying their constraint are
/// skipped by the resolver.
fn installByName(allocator: std.mem.Allocator, config: config_mod.Config, name: []const u8) !void {
    try installNames(allocator, config, &.{name}, &.{});
}

/// `replace` is the set of currently-installed packages this call will
/// remove and reinstall a new version of (used by `upgradeAll`). They're
/// excluded from "already installed" while resolving -- otherwise the
/// resolver would see the old version still satisfying `*` and skip
/// planning a new one at all -- and passed to `plan.execute` as removes,
/// so the whole replace-and-install happens as one transaction.
fn installNames(
    allocator: std.mem.Allocator,
    config: config_mod.Config,
    names: []const []const u8,
    replace: []const []const u8,
) !void {
    var loaded: ?repos_config.Loaded = null;
    defer if (loaded) |l| l.deinit();
    const mgr = (try openManager(allocator, config, &loaded)) orelse return error.NoRepositories;

    var ctx = try plan_mod.buildContext(allocator, config, mgr);
    defer ctx.deinit();

    var filtered_installed = std.ArrayList(resolver.Candidate).init(allocator);
    defer filtered_installed.deinit();
    for (ctx.installed) |inst| {
        var excluded = false;
        for (replace) |n| {
            if (std.mem.eql(u8, n, inst.name)) {
                excluded = true;
                break;
            }
        }
        if (!excluded) try filtered_installed.append(inst);
    }
    var resolve_ctx = ctx;
    resolve_ctx.installed = filtered_installed.items;

    var diags = resolver.Diagnostics{};
    var resolved = resolver.resolve(allocator, resolve_ctx.provider(), names, &diags) catch |e| {
        reportResolveFailure(e, diags);
        return e;
    };
    defer resolved.deinit();

    if (resolved.order.len == 0 and replace.len == 0) {
        log.info("nothing to do", .{});
        return;
    }

    try plan_mod.execute(allocator, config, mgr, ctx, resolved, replace);
}

/// Turns a resolver error plus its diagnostics into one actionable line.
fn reportResolveFailure(e: anyerror, diags: resolver.Diagnostics) void {
    switch (e) {
        error.PackageNotFound => log.err("package '{s}' not found in any repository", .{diags.package}),
        error.CircularDependency => log.err("circular dependency involving '{s}'", .{diags.package}),
        error.VersionConflict => log.err(
            "cannot satisfy '{s} {s}': only {s} is available",
            .{ diags.package, diags.constraint, diags.available },
        ),
        error.InvalidConstraint => log.err(
            "invalid version constraint '{s}' on '{s}'",
            .{ diags.constraint, diags.package },
        ),
        else => log.err("resolution failed: {s}", .{@errorName(e)}),
    }
}

/// Upgrades every installed package that a repository offers a strictly
/// newer version of. Re-resolves so an upgrade's new dependencies come
/// along too, and applies remove-old + install-new as one Phase 8
/// transaction via `installNames`'s `replace` parameter -- an interrupted
/// upgrade recovers to either the old or the new version, never neither.
fn upgradeAll(allocator: std.mem.Allocator, config: config_mod.Config) !void {
    var loaded: ?repos_config.Loaded = null;
    defer if (loaded) |l| l.deinit();
    const mgr = (try openManager(allocator, config, &loaded)) orelse return error.NoRepositories;

    // A second buildContext happens inside installNames; both only read
    // already-cached local files (no network), so the duplication trades
    // a little redundant disk I/O for keeping installNames' single
    // resolve-then-execute shape for both install and upgrade.
    var ctx = try plan_mod.buildContext(allocator, config, mgr);
    defer ctx.deinit();

    const names = try plan_mod.outdated(allocator, ctx);
    defer allocator.free(names);

    if (names.len == 0) {
        log.info("everything is up to date", .{});
        return;
    }

    try installNames(allocator, config, names, names);
}

<<<<<<< HEAD
test "doctor reports its check count through dispatch on a clean temp environment" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const tmp_path = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(tmp_path);

    var paths: [3][]u8 = undefined;
    const cfg = try tmpConfig(allocator, tmp_path, &paths);
    defer for (paths) |p| allocator.free(p);

    try dispatch(allocator, cfg, .doctor);
=======
test "stub commands still report NotImplemented" {
    const cfg = config_mod.default();
    const commands = [_]args.Command{.doctor};
    for (commands) |cmd| {
        try std.testing.expectError(error.NotImplemented, dispatch(std.testing.allocator, cfg, cmd));
    }
>>>>>>> ea9b338f92142d8d550400180e6c2b8d63a0e406
}

fn tmpConfig(allocator: std.mem.Allocator, tmp_path: []const u8, out: *[3][]u8) !config_mod.Config {
    out[0] = try std.fmt.allocPrint(allocator, "{s}/db", .{tmp_path});
    out[1] = try std.fmt.allocPrint(allocator, "{s}/cache", .{tmp_path});
    out[2] = try std.fmt.allocPrint(allocator, "{s}/repositories.json", .{tmp_path});
    var cfg = config_mod.default();
    cfg.database_path = out[0];
    cfg.cache_dir = out[1];
    cfg.repositories_path = out[2];
    cfg.install_root = tmp_path;
    return cfg;
}

test "update and search report NoRepositories when none are configured" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const tmp_path = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(tmp_path);

    var paths: [3][]u8 = undefined;
    const cfg = try tmpConfig(allocator, tmp_path, &paths);
    defer for (paths) |p| allocator.free(p);

    try std.testing.expectError(error.NoRepositories, dispatch(allocator, cfg, .update));
    try std.testing.expectError(error.NoRepositories, dispatch(allocator, cfg, .{ .search = "x" }));
    try std.testing.expectError(error.NoRepositories, dispatch(allocator, cfg, .upgrade));
}

test "list on an empty database succeeds with no output" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const tmp_path = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(tmp_path);

    var paths: [3][]u8 = undefined;
    const cfg = try tmpConfig(allocator, tmp_path, &paths);
    defer for (paths) |p| allocator.free(p);

    try dispatch(allocator, cfg, .list);
}

test "info and remove on an unknown package report NotInstalled" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const tmp_path = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(tmp_path);

    var paths: [3][]u8 = undefined;
    const cfg = try tmpConfig(allocator, tmp_path, &paths);
    defer for (paths) |p| allocator.free(p);

    try std.testing.expectError(error.NotInstalled, dispatch(allocator, cfg, .{ .info = "nope" }));
    try std.testing.expectError(error.NotInstalled, dispatch(allocator, cfg, .{ .remove = "nope" }));
}

test "install by name without repositories reports NoRepositories" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const tmp_path = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(tmp_path);

    var paths: [3][]u8 = undefined;
    const cfg = try tmpConfig(allocator, tmp_path, &paths);
    defer for (paths) |p| allocator.free(p);

    // No '/' and no .zpkg suffix -> treated as a repository package name.
    try std.testing.expectError(error.NoRepositories, dispatch(allocator, cfg, .{ .install = "hello" }));
}

test "clean runs against an empty cache without error" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const tmp_path = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(tmp_path);

    var paths: [3][]u8 = undefined;
    const cfg = try tmpConfig(allocator, tmp_path, &paths);
    defer for (paths) |p| allocator.free(p);

    try dispatch(allocator, cfg, .clean);
}

test "upgrade replaces the old version with the new one in a single transaction" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const tmp_path = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(tmp_path);

    var paths: [3][]u8 = undefined;
    const cfg = try tmpConfig(allocator, tmp_path, &paths);
    defer for (paths) |p| allocator.free(p);

    // Install v1 locally first (path contains '/', so dispatch treats it
    // as a local .zpkg rather than a repository lookup).
    const v1_bytes = try package_mod.create(
        allocator,
        .{ .name = "hello", .version = "1.0.0", .architecture = "x86_64" },
        &.{.{ .path = "bin/hello", .content = "v1" }},
    );
    defer allocator.free(v1_bytes);
    const v1_path = try std.fmt.allocPrint(allocator, "{s}/hello-v1.zpkg", .{tmp_path});
    defer allocator.free(v1_path);
    try std.fs.cwd().writeFile(.{ .sub_path = v1_path, .data = v1_bytes });
    try dispatch(allocator, cfg, .{ .install = v1_path });

    // Configure a repository and pre-populate its cache with v2, so
    // upgrade needs no network.
    try std.fs.cwd().writeFile(.{
        .sub_path = paths[2],
        .data =
        \\[{"name":"main","url":"https://repo.example.com"}]
        ,
    });

    const v2_bytes = try package_mod.create(
        allocator,
        .{ .name = "hello", .version = "2.0.0", .architecture = "x86_64" },
        &.{.{ .path = "bin/hello", .content = "v2" }},
    );
    defer allocator.free(v2_bytes);
    const v2_checksum = try checksum_mod.sha256Hex(allocator, v2_bytes);
    defer allocator.free(v2_checksum);

    const repos = [_]repository.Repository{.{ .name = "main", .url = "https://repo.example.com" }};
    const mgr = repository.Manager.init(allocator, cfg, &repos);
    const index_path = try mgr.cachedIndexPath(repos[0]);
    defer allocator.free(index_path);
    if (std.fs.path.dirname(index_path)) |dir| try std.fs.cwd().makePath(dir);
    const index_json = try index_mod.toJson(allocator, .{ .packages = &.{
        .{ .name = "hello", .version = "2.0.0", .architecture = "x86_64", .path = "hello-2.0.0.zpkg", .checksum = v2_checksum },
    } });
    defer allocator.free(index_json);
    try std.fs.cwd().writeFile(.{ .sub_path = index_path, .data = index_json });

    const entry = index_mod.IndexEntry{ .name = "hello", .version = "2.0.0", .architecture = "x86_64", .path = "hello-2.0.0.zpkg", .checksum = v2_checksum };
    const cached_pkg_path = try mgr.cachedPackagePath(entry);
    defer allocator.free(cached_pkg_path);
    if (std.fs.path.dirname(cached_pkg_path)) |dir| try std.fs.cwd().makePath(dir);
    try std.fs.cwd().writeFile(.{ .sub_path = cached_pkg_path, .data = v2_bytes });

    try dispatch(allocator, cfg, .upgrade);

    // tmpConfig sets install_root = tmp_path directly (not a subpath).
    const installed_file = try std.fmt.allocPrint(allocator, "{s}/bin/hello", .{tmp_path});
    defer allocator.free(installed_file);
    const content = try std.fs.cwd().readFileAlloc(allocator, installed_file, 1024);
    defer allocator.free(content);
    try std.testing.expectEqualStrings("v2", content);

    const db = db_mod.Database.init(paths[0]);
    const parsed = (try db.get(allocator, "hello")).?;
    defer parsed.deinit();
    try std.testing.expectEqualStrings("2.0.0", parsed.value.version);
}
