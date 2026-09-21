//! Cache inspection and cleanup -- backs `zdms clean`.
//!
//! Layout under `config.cache_dir`:
//!   indexes/   repository metadata, refreshed by `zdms update`
//!   packages/  downloaded .zpkg files
//!
//! `clean` removes cached *packages* by default and leaves indexes alone:
//! deleting indexes would force a full `update` before the next install,
//! which is the opposite of what someone reclaiming disk space wants.

const std = @import("std");
const config_mod = @import("config.zig");
const log = @import("log.zig");

pub const Stats = struct {
    files: usize = 0,
    bytes: u64 = 0,
};

pub const Options = struct {
    /// Also clear cached repository indexes.
    include_indexes: bool = false,
    /// Report what would be removed without removing anything.
    dry_run: bool = false,
};

fn subdir(allocator: std.mem.Allocator, config: config_mod.Config, name: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "{s}/{s}", .{
        std.mem.trimRight(u8, config.cache_dir, "/"),
        name,
    });
}

/// Removes every regular file directly inside `dir_path`, accumulating
/// into `stats`. A missing directory is not an error -- nothing cached is
/// the same as nothing to clean.
fn clearDir(dir_path: []const u8, stats: *Stats, dry_run: bool) !void {
    var dir = std.fs.cwd().openDir(dir_path, .{ .iterate = true }) catch |e| switch (e) {
        error.FileNotFound => return,
        else => return e,
    };
    defer dir.close();

    var it = dir.iterate();
    while (try it.next()) |entry| {
        if (entry.kind != .file) continue;

        const stat = dir.statFile(entry.name) catch continue;
        stats.files += 1;
        stats.bytes += stat.size;

        if (dry_run) continue;
        dir.deleteFile(entry.name) catch |e| {
            log.warn("could not remove {s}: {s}", .{ entry.name, @errorName(e) });
            stats.files -= 1;
            stats.bytes -= stat.size;
        };
    }
}

/// Size of the cache without removing anything.
pub fn usage(allocator: std.mem.Allocator, config: config_mod.Config) !Stats {
    var stats = Stats{};
    for ([_][]const u8{ "packages", "indexes" }) |name| {
        const path = try subdir(allocator, config, name);
        defer allocator.free(path);
        try clearDir(path, &stats, true);
    }
    return stats;
}

pub fn clean(allocator: std.mem.Allocator, config: config_mod.Config, options: Options) !Stats {
    var stats = Stats{};

    const packages = try subdir(allocator, config, "packages");
    defer allocator.free(packages);
    try clearDir(packages, &stats, options.dry_run);

    if (options.include_indexes) {
        const indexes = try subdir(allocator, config, "indexes");
        defer allocator.free(indexes);
        try clearDir(indexes, &stats, options.dry_run);
    }

    return stats;
}

/// Human-readable byte count. Writes into `buf` and returns the slice.
pub fn formatBytes(buf: []u8, bytes: u64) []const u8 {
    const units = [_][]const u8{ "B", "KiB", "MiB", "GiB", "TiB" };
    var value: f64 = @floatFromInt(bytes);
    var unit: usize = 0;
    while (value >= 1024.0 and unit + 1 < units.len) : (unit += 1) value /= 1024.0;

    if (unit == 0) {
        return std.fmt.bufPrint(buf, "{d} {s}", .{ bytes, units[0] }) catch buf[0..0];
    }
    return std.fmt.bufPrint(buf, "{d:.1} {s}", .{ value, units[unit] }) catch buf[0..0];
}

fn writeCacheFile(allocator: std.mem.Allocator, cache_dir: []const u8, sub: []const u8, name: []const u8, data: []const u8) !void {
    const dir = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ cache_dir, sub });
    defer allocator.free(dir);
    try std.fs.cwd().makePath(dir);
    const path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ dir, name });
    defer allocator.free(path);
    try std.fs.cwd().writeFile(.{ .sub_path = path, .data = data });
}

test "clean removes cached packages but keeps indexes by default" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const tmp_path = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(tmp_path);

    var cfg = config_mod.default();
    cfg.cache_dir = tmp_path;

    try writeCacheFile(allocator, tmp_path, "packages", "a.zpkg", "aaaa");
    try writeCacheFile(allocator, tmp_path, "packages", "b.zpkg", "bbbbbb");
    try writeCacheFile(allocator, tmp_path, "indexes", "main.json", "{}");

    const stats = try clean(allocator, cfg, .{});
    try std.testing.expectEqual(@as(usize, 2), stats.files);
    try std.testing.expectEqual(@as(u64, 10), stats.bytes);

    // Index must survive, so the next install does not need a full update.
    const index_path = try std.fmt.allocPrint(allocator, "{s}/indexes/main.json", .{tmp_path});
    defer allocator.free(index_path);
    try std.fs.cwd().access(index_path, .{});

    const pkg_path = try std.fmt.allocPrint(allocator, "{s}/packages/a.zpkg", .{tmp_path});
    defer allocator.free(pkg_path);
    try std.testing.expectError(error.FileNotFound, std.fs.cwd().access(pkg_path, .{}));
}

test "clean with include_indexes also clears index metadata" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const tmp_path = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(tmp_path);

    var cfg = config_mod.default();
    cfg.cache_dir = tmp_path;

    try writeCacheFile(allocator, tmp_path, "packages", "a.zpkg", "aaaa");
    try writeCacheFile(allocator, tmp_path, "indexes", "main.json", "{}");

    const stats = try clean(allocator, cfg, .{ .include_indexes = true });
    try std.testing.expectEqual(@as(usize, 2), stats.files);

    const index_path = try std.fmt.allocPrint(allocator, "{s}/indexes/main.json", .{tmp_path});
    defer allocator.free(index_path);
    try std.testing.expectError(error.FileNotFound, std.fs.cwd().access(index_path, .{}));
}

test "dry_run reports sizes without deleting anything" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const tmp_path = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(tmp_path);

    var cfg = config_mod.default();
    cfg.cache_dir = tmp_path;

    try writeCacheFile(allocator, tmp_path, "packages", "a.zpkg", "aaaa");

    const stats = try clean(allocator, cfg, .{ .dry_run = true });
    try std.testing.expectEqual(@as(usize, 1), stats.files);

    const pkg_path = try std.fmt.allocPrint(allocator, "{s}/packages/a.zpkg", .{tmp_path});
    defer allocator.free(pkg_path);
    try std.fs.cwd().access(pkg_path, .{});
}

test "clean on a cache directory that does not exist is a no-op" {
    const allocator = std.testing.allocator;
    var cfg = config_mod.default();
    cfg.cache_dir = "/nonexistent/zdms-cache";
    const stats = try clean(allocator, cfg, .{});
    try std.testing.expectEqual(@as(usize, 0), stats.files);
}

test "usage counts both packages and indexes without removing them" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const tmp_path = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(tmp_path);

    var cfg = config_mod.default();
    cfg.cache_dir = tmp_path;

    try writeCacheFile(allocator, tmp_path, "packages", "a.zpkg", "aaaa");
    try writeCacheFile(allocator, tmp_path, "indexes", "main.json", "{}");

    const stats = try usage(allocator, cfg);
    try std.testing.expectEqual(@as(usize, 2), stats.files);
    try std.testing.expectEqual(@as(u64, 6), stats.bytes);

    const pkg_path = try std.fmt.allocPrint(allocator, "{s}/packages/a.zpkg", .{tmp_path});
    defer allocator.free(pkg_path);
    try std.fs.cwd().access(pkg_path, .{});
}

test "formatBytes scales units" {
    var buf: [32]u8 = undefined;
    try std.testing.expectEqualStrings("512 B", formatBytes(&buf, 512));
    try std.testing.expectEqualStrings("1.0 KiB", formatBytes(&buf, 1024));
    try std.testing.expectEqualStrings("1.5 MiB", formatBytes(&buf, 1024 * 1024 * 3 / 2));
}
