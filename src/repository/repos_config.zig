//! Loading the configured repository list from disk.
//!
//! A missing file is not an error: a fresh install with no repositories
//! configured is a legitimate state (local .zpkg installs still work), and
//! the commands that actually need a repository report `NoRepositories`
//! themselves with a useful message.

const std = @import("std");
const errors = @import("../core/errors.zig");
const config_mod = @import("../core/config.zig");
const repository = @import("repository.zig");

/// Caller must `.deinit()` the result. `value` is the repository slice.
pub const Loaded = std.json.Parsed([]const repository.Repository);

pub fn load(allocator: std.mem.Allocator, config: config_mod.Config) !?Loaded {
    const bytes = std.fs.cwd().readFileAlloc(allocator, config.repositories_path, 1024 * 1024) catch |e| switch (e) {
        error.FileNotFound => return null,
        else => return e,
    };
    defer allocator.free(bytes);

    // .alloc_always: without it, std.json may return strings pointing
    // directly into `bytes`, which is freed by the `defer` above -- a
    // use-after-free that only crashes once something reuses that memory.
    return std.json.parseFromSlice([]const repository.Repository, allocator, bytes, .{ .allocate = .alloc_always }) catch
        return error.InvalidIndex;
}

test "load returns null when no repositories file exists" {
    const allocator = std.testing.allocator;
    var cfg = config_mod.default();
    cfg.repositories_path = "/nonexistent/zdms/repositories.json";
    try std.testing.expectEqual(@as(?Loaded, null), try load(allocator, cfg));
}

test "load parses a repositories file" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const tmp_path = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(tmp_path);

    const repos_path = try std.fmt.allocPrint(allocator, "{s}/repositories.json", .{tmp_path});
    defer allocator.free(repos_path);
    try std.fs.cwd().writeFile(.{
        .sub_path = repos_path,
        .data =
        \\[{"name":"main","url":"https://repo.example.com","index_path":"index.json","enabled":true}]
        ,
    });

    var cfg = config_mod.default();
    cfg.repositories_path = repos_path;

    const loaded = (try load(allocator, cfg)).?;
    defer loaded.deinit();
    try std.testing.expectEqual(@as(usize, 1), loaded.value.len);
    try std.testing.expectEqualStrings("main", loaded.value[0].name);
    try std.testing.expect(loaded.value[0].enabled);
}

test "load reports malformed JSON rather than silently ignoring it" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const tmp_path = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(tmp_path);

    const repos_path = try std.fmt.allocPrint(allocator, "{s}/repositories.json", .{tmp_path});
    defer allocator.free(repos_path);
    try std.fs.cwd().writeFile(.{ .sub_path = repos_path, .data = "{not json" });

    var cfg = config_mod.default();
    cfg.repositories_path = repos_path;

    try std.testing.expectError(error.InvalidIndex, load(allocator, cfg));
}
