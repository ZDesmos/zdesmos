//! Local package database. Deliberately not SQLite (spec: "do not
//! introduce SQLite or another heavy dependency unless there is a
//! demonstrated technical reason") — one small JSON file per installed
//! package under `database_path`, named `<name>.json`. This also means a
//! single corrupt entry can't take down the whole database, and later
//! phases can make writing one file atomic (write-temp + rename) without
//! touching the rest.

const std = @import("std");
const errors = @import("../core/errors.zig");
const manifest_mod = @import("../package/manifest.zig");

pub const InstalledPackage = struct {
    name: []const u8,
    version: []const u8,
    architecture: []const u8,
    dependencies: []const manifest_mod.Dependency = &.{},
    files: []const manifest_mod.FileEntry = &.{},
};

pub const Database = struct {
    /// Directory containing one `<name>.json` file per installed package.
    dir: []const u8,

    pub fn init(dir: []const u8) Database {
        return .{ .dir = dir };
    }

    fn entryPath(self: Database, allocator: std.mem.Allocator, name: []const u8) ![]u8 {
        return std.fmt.allocPrint(allocator, "{s}/{s}.json", .{ self.dir, name });
    }

    pub fn isInstalled(self: Database, allocator: std.mem.Allocator, name: []const u8) !bool {
        const path = try self.entryPath(allocator, name);
        defer allocator.free(path);
        std.fs.cwd().access(path, .{}) catch |e| switch (e) {
            error.FileNotFound => return false,
            else => return e,
        };
        return true;
    }

    /// Returns `null` if `name` isn't installed. Caller must `.deinit()`
    /// the result otherwise.
    pub fn get(self: Database, allocator: std.mem.Allocator, name: []const u8) !?std.json.Parsed(InstalledPackage) {
        const path = try self.entryPath(allocator, name);
        defer allocator.free(path);

        const bytes = std.fs.cwd().readFileAlloc(allocator, path, 16 * 1024 * 1024) catch |e| switch (e) {
            error.FileNotFound => return null,
            else => return e,
        };
        defer allocator.free(bytes);

        // .alloc_always: `bytes` is freed right after this returns (see
        // defer above); without forcing a copy, std.json may hand back
        // strings pointing into it, a use-after-free.
        return std.json.parseFromSlice(InstalledPackage, allocator, bytes, .{ .allocate = .alloc_always }) catch return error.CorruptEntry;
    }

    /// Overwrites any existing entry for `pkg.name`.
    pub fn put(self: Database, allocator: std.mem.Allocator, pkg: InstalledPackage) !void {
        try std.fs.cwd().makePath(self.dir);
        const path = try self.entryPath(allocator, pkg.name);
        defer allocator.free(path);

        const json_text = try std.json.stringifyAlloc(allocator, pkg, .{});
        defer allocator.free(json_text);

        try std.fs.cwd().writeFile(.{ .sub_path = path, .data = json_text });
    }

    pub fn remove(self: Database, allocator: std.mem.Allocator, name: []const u8) !void {
        const path = try self.entryPath(allocator, name);
        defer allocator.free(path);
        std.fs.cwd().deleteFile(path) catch |e| switch (e) {
            error.FileNotFound => return error.NotInstalled,
            else => return e,
        };
    }

    /// Names of all installed packages. Caller owns the returned slice and
    /// each string in it.
    pub fn list(self: Database, allocator: std.mem.Allocator) ![][]const u8 {
        var dir = std.fs.cwd().openDir(self.dir, .{ .iterate = true }) catch |e| switch (e) {
            error.FileNotFound => return allocator.alloc([]const u8, 0),
            else => return e,
        };
        defer dir.close();

        var names = std.ArrayList([]const u8).init(allocator);
        errdefer {
            for (names.items) |n| allocator.free(n);
            names.deinit();
        }

        var it = dir.iterate();
        while (try it.next()) |entry| {
            if (entry.kind != .file) continue;
            if (!std.mem.endsWith(u8, entry.name, ".json")) continue;
            const name = entry.name[0 .. entry.name.len - ".json".len];
            try names.append(try allocator.dupe(u8, name));
        }
        return names.toOwnedSlice();
    }
};

test "put, get, isInstalled, list, remove round-trip in a temp dir" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir_path = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(dir_path);
    const db_path = try std.fmt.allocPrint(allocator, "{s}/db", .{dir_path});
    defer allocator.free(db_path);

    const db = Database.init(db_path);

    try std.testing.expect(!try db.isInstalled(allocator, "hello"));
    const empty_names = try db.list(allocator);
    defer allocator.free(empty_names);
    try std.testing.expectEqual(@as(usize, 0), empty_names.len);

    try db.put(allocator, .{
        .name = "hello",
        .version = "1.0.0",
        .architecture = "x86_64",
        .files = &.{.{ .path = "bin/hello", .size = 5, .sha256 = "abc" }},
    });

    try std.testing.expect(try db.isInstalled(allocator, "hello"));

    const names = try db.list(allocator);
    defer {
        for (names) |n| allocator.free(n);
        allocator.free(names);
    }
    try std.testing.expectEqual(@as(usize, 1), names.len);
    try std.testing.expectEqualStrings("hello", names[0]);

    const got = (try db.get(allocator, "hello")).?;
    defer got.deinit();
    try std.testing.expectEqualStrings("1.0.0", got.value.version);
    try std.testing.expectEqualStrings("bin/hello", got.value.files[0].path);

    try db.remove(allocator, "hello");
    try std.testing.expect(!try db.isInstalled(allocator, "hello"));
    try std.testing.expectError(error.NotInstalled, db.remove(allocator, "hello"));
}

test "get returns null for a package that was never installed" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir_path = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(dir_path);

    const db = Database.init(dir_path);
    try std.testing.expectEqual(@as(?std.json.Parsed(InstalledPackage), null), try db.get(allocator, "nope"));
}
