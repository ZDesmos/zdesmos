//! `zdms doctor`: diagnoses common problems without fixing them (that's
//! what install/remove/upgrade are for). Checks:
//!   - config validity
//!   - cache/database/install-root directories are accessible
//!   - every installed package's files are actually present on disk
//!   - the repositories file parses, and each enabled repo has a cached
//!     index (or explains why not)
//!   - leftover staging data from a process killed before it ever wrote
//!     a journal (recover() can't know about those -- there's no journal
//!     to resume)

const std = @import("std");
const config_mod = @import("config.zig");
const log = @import("log.zig");
const db_mod = @import("../database/db.zig");
const repos_config = @import("../repository/repos_config.zig");
const repository = @import("../repository/repository.zig");

pub const Report = struct {
    checks: usize = 0,
    problems: usize = 0,
};

fn checkConfig(config: config_mod.Config, report: *Report) void {
    report.checks += 1;
    config.validate() catch |e| {
        report.problems += 1;
        log.err("configuration is invalid: {s}", .{@errorName(e)});
        return;
    };
    log.info("configuration is valid", .{});
}

fn checkDirectories(config: config_mod.Config, report: *Report) void {
    const dirs = [_]struct { label: []const u8, path: []const u8 }{
        .{ .label = "cache_dir", .path = config.cache_dir },
        .{ .label = "database_path", .path = config.database_path },
    };
    for (dirs) |d| {
        report.checks += 1;
        std.fs.cwd().access(d.path, .{}) catch |e| switch (e) {
            // Not created yet is normal on a system that hasn't installed
            // anything -- Database.put/Transaction create these lazily on
            // first use. Not a problem to report, just informational.
            error.FileNotFound => {
                log.info("{s} ({s}) does not exist yet -- created on first use", .{ d.label, d.path });
                continue;
            },
            else => {
                report.problems += 1;
                log.err("{s} ({s}) is not accessible: {s}", .{ d.label, d.path, @errorName(e) });
                continue;
            },
        };
        log.info("{s} ({s}) exists", .{ d.label, d.path });
    }

    report.checks += 1;
    std.fs.cwd().access(config.install_root, .{}) catch |e| {
        report.problems += 1;
        log.err("install_root ({s}) is not accessible: {s}", .{ config.install_root, @errorName(e) });
        return;
    };
    log.info("install_root ({s}) is accessible", .{config.install_root});
}

/// Checks that every file a package's database entry claims to own is
/// actually present under install_root. Existence only, not checksum --
/// a full re-verify of every installed file could be slow on a large
/// system, and existence already catches the common case (something else
/// deleted a file zdms thinks it owns).
fn checkInstalledFiles(allocator: std.mem.Allocator, config: config_mod.Config, report: *Report) void {
    const db = db_mod.Database.init(config.database_path);
    const names = db.list(allocator) catch |e| {
        report.checks += 1;
        report.problems += 1;
        log.err("could not list installed packages: {s}", .{@errorName(e)});
        return;
    };
    defer {
        for (names) |n| allocator.free(n);
        allocator.free(names);
    }

    for (names) |name| {
        report.checks += 1;
        const parsed = (db.get(allocator, name) catch |e| {
            report.problems += 1;
            log.err("{s}: database entry is unreadable: {s}", .{ name, @errorName(e) });
            continue;
        }) orelse continue;
        defer parsed.deinit();

        var missing: usize = 0;
        for (parsed.value.files) |f| {
            const path = std.fs.path.join(allocator, &.{ config.install_root, f.path }) catch continue;
            defer allocator.free(path);
            std.fs.cwd().access(path, .{}) catch {
                missing += 1;
            };
        }

        if (missing > 0) {
            report.problems += 1;
            log.warn("{s}: {d} of {d} file(s) missing on disk", .{ name, missing, parsed.value.files.len });
        } else {
            log.info("{s}: all {d} file(s) present", .{ name, parsed.value.files.len });
        }
    }
}

fn checkRepositories(allocator: std.mem.Allocator, config: config_mod.Config, report: *Report) void {
    report.checks += 1;
    const loaded = (repos_config.load(allocator, config) catch |e| {
        report.problems += 1;
        log.err("repositories file ({s}) is invalid: {s}", .{ config.repositories_path, @errorName(e) });
        return;
    }) orelse {
        log.info("no repositories configured", .{});
        return;
    };
    defer loaded.deinit();

    log.info("repositories file is valid ({d} repositor{s})", .{
        loaded.value.len,
        @as([]const u8, if (loaded.value.len == 1) "y" else "ies"),
    });

    const mgr = repository.Manager.init(allocator, config, loaded.value);
    for (loaded.value) |repo| {
        report.checks += 1;
        if (!repo.enabled) {
            log.info("'{s}' is disabled, skipping", .{repo.name});
            continue;
        }
        var parsed = mgr.loadIndex(repo) catch |e| {
            report.problems += 1;
            switch (e) {
                error.IndexNotFetched => log.warn("'{s}' has no cached index yet -- run 'zdms update'", .{repo.name}),
                else => log.warn("'{s}' index could not be loaded: {s}", .{ repo.name, @errorName(e) }),
            }
            continue;
        };
        defer parsed.deinit();
        log.info("'{s}': {d} package(s) in cached index", .{ repo.name, parsed.value.packages.len });
    }
}

/// A process killed after `addInstallStreamed` stages files but before
/// `prepare()` ever writes a journal leaves staging data `recover()` has
/// no way to know about (there's no journal pointing at it). This is the
/// one class of leftover the transaction system genuinely can't clean up
/// on its own -- doctor is where it gets surfaced.
fn checkStaging(allocator: std.mem.Allocator, config: config_mod.Config, report: *Report) void {
    report.checks += 1;
    const staging_path = std.fmt.allocPrint(allocator, "{s}/staging", .{
        std.mem.trimRight(u8, config.cache_dir, "/"),
    }) catch return;
    defer allocator.free(staging_path);

    var dir = std.fs.cwd().openDir(staging_path, .{ .iterate = true }) catch |e| switch (e) {
        error.FileNotFound => {
            log.info("no leftover staging data", .{});
            return;
        },
        else => {
            report.problems += 1;
            log.warn("could not inspect staging directory: {s}", .{@errorName(e)});
            return;
        },
    };
    defer dir.close();

    var count: usize = 0;
    var it = dir.iterate();
    while (it.next() catch null) |_| count += 1;

    if (count > 0) {
        report.problems += 1;
        log.warn(
            "staging directory ({s}) has {d} leftover entr{s} -- likely from a killed process; safe to delete manually",
            .{ staging_path, count, @as([]const u8, if (count == 1) "y" else "ies") },
        );
    } else {
        log.info("no leftover staging data", .{});
    }
}

pub fn run(allocator: std.mem.Allocator, config: config_mod.Config) Report {
    var report = Report{};
    checkConfig(config, &report);
    checkDirectories(config, &report);
    checkInstalledFiles(allocator, config, &report);
    checkRepositories(allocator, config, &report);
    checkStaging(allocator, config, &report);
    return report;
}

test "run on a clean temp environment reports no problems" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const tmp_path = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(tmp_path);

    const db_path = try std.fmt.allocPrint(allocator, "{s}/db", .{tmp_path});
    defer allocator.free(db_path);
    const cache_dir = try std.fmt.allocPrint(allocator, "{s}/cache", .{tmp_path});
    defer allocator.free(cache_dir);
    const repos_path = try std.fmt.allocPrint(allocator, "{s}/repositories.json", .{tmp_path});
    defer allocator.free(repos_path);

    var cfg = config_mod.default();
    cfg.database_path = db_path;
    cfg.cache_dir = cache_dir;
    cfg.install_root = tmp_path;
    cfg.repositories_path = repos_path; // doesn't exist -- "no repositories configured"

    const report = run(allocator, cfg);
    try std.testing.expectEqual(@as(usize, 0), report.problems);
    try std.testing.expect(report.checks > 0);
}

test "run reports a missing installed file as a problem" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const tmp_path = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(tmp_path);

    const db_path = try std.fmt.allocPrint(allocator, "{s}/db", .{tmp_path});
    defer allocator.free(db_path);
    const cache_dir = try std.fmt.allocPrint(allocator, "{s}/cache", .{tmp_path});
    defer allocator.free(cache_dir);
    const repos_path = try std.fmt.allocPrint(allocator, "{s}/repositories.json", .{tmp_path});
    defer allocator.free(repos_path);

    var cfg = config_mod.default();
    cfg.database_path = db_path;
    cfg.cache_dir = cache_dir;
    cfg.install_root = tmp_path;
    cfg.repositories_path = repos_path;

    // Record a package in the database without ever writing its file.
    const db = db_mod.Database.init(db_path);
    try db.put(allocator, .{
        .name = "hello",
        .version = "1.0.0",
        .architecture = "x86_64",
        .files = &.{.{ .path = "bin/hello", .size = 5, .sha256 = "x" }},
    });

    const report = run(allocator, cfg);
    try std.testing.expect(report.problems > 0);
}

test "run reports leftover staging data" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const tmp_path = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(tmp_path);

    const db_path = try std.fmt.allocPrint(allocator, "{s}/db", .{tmp_path});
    defer allocator.free(db_path);
    const cache_dir = try std.fmt.allocPrint(allocator, "{s}/cache", .{tmp_path});
    defer allocator.free(cache_dir);
    const repos_path = try std.fmt.allocPrint(allocator, "{s}/repositories.json", .{tmp_path});
    defer allocator.free(repos_path);

    var cfg = config_mod.default();
    cfg.database_path = db_path;
    cfg.cache_dir = cache_dir;
    cfg.install_root = tmp_path;
    cfg.repositories_path = repos_path;

    const staging_file = try std.fmt.allocPrint(allocator, "{s}/staging/0/0", .{cache_dir});
    defer allocator.free(staging_file);
    try std.fs.cwd().makePath(std.fs.path.dirname(staging_file).?);
    try std.fs.cwd().writeFile(.{ .sub_path = staging_file, .data = "orphaned" });

    const report = run(allocator, cfg);
    try std.testing.expect(report.problems > 0);
}
