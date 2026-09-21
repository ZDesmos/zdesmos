//! Binary framing for a `.zpkg` file: magic + version, then the manifest
//! JSON, then each file's path and content, all length-prefixed. No
//! compression yet (Phase 6) — the goal here is a format simple enough to
//! parse in a straight line with bounds checks, nothing more.
//!
//! Layout:
//!   "ZPKG"            (4 bytes)
//!   format_version    (1 byte)
//!   manifest_len      (u32 LE)
//!   manifest_json     (manifest_len bytes)
//!   file_count        (u32 LE)
//!   for each file:
//!     path_len        (u32 LE)
//!     path             (path_len bytes)
//!     content_len     (u64 LE)
//!     content          (content_len bytes)

const std = @import("std");

pub const magic = "ZPKG";
pub const format_version: u8 = 1;

pub const FileData = struct {
    path: []const u8,
    content: []const u8,
};

/// Owns every allocation produced by `unpack` via a single arena, so
/// cleanup is one `deinit()` call regardless of file count.
pub const Unpacked = struct {
    manifest_json: []u8,
    files: []FileData,
    arena: std.heap.ArenaAllocator,

    pub fn deinit(self: *Unpacked) void {
        self.arena.deinit();
    }
};

fn writeU32LE(list: *std.ArrayList(u8), v: u32) !void {
    var buf: [4]u8 = undefined;
    std.mem.writeInt(u32, &buf, v, .little);
    try list.appendSlice(&buf);
}

fn writeU64LE(list: *std.ArrayList(u8), v: u64) !void {
    var buf: [8]u8 = undefined;
    std.mem.writeInt(u64, &buf, v, .little);
    try list.appendSlice(&buf);
}

fn readU32LE(data: []const u8, pos: *usize) !u32 {
    if (pos.* + 4 > data.len) return error.CorruptArchive;
    const v = std.mem.readInt(u32, data[pos.*..][0..4], .little);
    pos.* += 4;
    return v;
}

fn readU64LE(data: []const u8, pos: *usize) !u64 {
    if (pos.* + 8 > data.len) return error.CorruptArchive;
    const v = std.mem.readInt(u64, data[pos.*..][0..8], .little);
    pos.* += 8;
    return v;
}

/// `manifest_json` and each file's bytes are copied into the returned
/// buffer; the caller's originals aren't retained.
pub fn pack(allocator: std.mem.Allocator, manifest_json: []const u8, files: []const FileData) ![]u8 {
    var list = std.ArrayList(u8).init(allocator);
    errdefer list.deinit();

    try list.appendSlice(magic);
    try list.append(format_version);
    try writeU32LE(&list, @intCast(manifest_json.len));
    try list.appendSlice(manifest_json);
    try writeU32LE(&list, @intCast(files.len));
    for (files) |f| {
        try writeU32LE(&list, @intCast(f.path.len));
        try list.appendSlice(f.path);
        try writeU64LE(&list, @intCast(f.content.len));
        try list.appendSlice(f.content);
    }
    return list.toOwnedSlice();
}

pub fn unpack(allocator: std.mem.Allocator, data: []const u8) !Unpacked {
    if (data.len < magic.len + 1) return error.CorruptArchive;
    if (!std.mem.eql(u8, data[0..magic.len], magic)) return error.CorruptArchive;

    var pos: usize = magic.len;
    const ver = data[pos];
    pos += 1;
    if (ver != format_version) return error.UnsupportedFormatVersion;

    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const arena_alloc = arena.allocator();

    const manifest_len: usize = try readU32LE(data, &pos);
    if (pos + manifest_len > data.len) return error.CorruptArchive;
    const manifest_json = try arena_alloc.dupe(u8, data[pos .. pos + manifest_len]);
    pos += manifest_len;

    const file_count: usize = try readU32LE(data, &pos);
    const files = try arena_alloc.alloc(FileData, file_count);
    for (0..file_count) |i| {
        const path_len: usize = try readU32LE(data, &pos);
        if (pos + path_len > data.len) return error.CorruptArchive;
        const path = try arena_alloc.dupe(u8, data[pos .. pos + path_len]);
        pos += path_len;

        const content_len: usize = @intCast(try readU64LE(data, &pos));
        if (pos + content_len > data.len) return error.CorruptArchive;
        const content = try arena_alloc.dupe(u8, data[pos .. pos + content_len]);
        pos += content_len;

        files[i] = .{ .path = path, .content = content };
    }

    return .{ .manifest_json = manifest_json, .files = files, .arena = arena };
}

test "pack/unpack round-trip preserves manifest and files" {
    const allocator = std.testing.allocator;
    const manifest_json = "{\"name\":\"hello\"}";
    const files = [_]FileData{
        .{ .path = "bin/hello", .content = "binary-data" },
        .{ .path = "share/doc/hello.txt", .content = "docs" },
    };

    const packed_bytes = try pack(allocator, manifest_json, &files);
    defer allocator.free(packed_bytes);

    var unpacked = try unpack(allocator, packed_bytes);
    defer unpacked.deinit();

    try std.testing.expectEqualStrings(manifest_json, unpacked.manifest_json);
    try std.testing.expectEqual(@as(usize, 2), unpacked.files.len);
    try std.testing.expectEqualStrings("bin/hello", unpacked.files[0].path);
    try std.testing.expectEqualStrings("binary-data", unpacked.files[0].content);
    try std.testing.expectEqualStrings("share/doc/hello.txt", unpacked.files[1].path);
    try std.testing.expectEqualStrings("docs", unpacked.files[1].content);
}

test "unpack rejects bad magic, truncated data, and unknown version" {
    const allocator = std.testing.allocator;

    try std.testing.expectError(error.CorruptArchive, unpack(allocator, "not-a-zpkg"));
    try std.testing.expectError(error.CorruptArchive, unpack(allocator, "ZPKG"));

    const bad_version = [_]u8{ 'Z', 'P', 'K', 'G', 99 };
    try std.testing.expectError(error.UnsupportedFormatVersion, unpack(allocator, &bad_version));

    // Valid header claiming a manifest far longer than the data actually has.
    var truncated = std.ArrayList(u8).init(allocator);
    defer truncated.deinit();
    try truncated.appendSlice(magic);
    try truncated.append(format_version);
    try truncated.appendSlice(&[_]u8{ 0xFF, 0xFF, 0xFF, 0x00 }); // manifest_len = huge
    try std.testing.expectError(error.CorruptArchive, unpack(allocator, truncated.items));
}
