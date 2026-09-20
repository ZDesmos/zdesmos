//! High-level `.zpkg` API: `create` builds a package from a manifest and
//! its files (computing the checksum for you); `open` parses one back and
//! verifies that checksum before handing anything to the caller. Nothing
//! below this file should need to touch `archive.zig` directly.

const std = @import("std");
const errors = @import("../core/errors.zig");
const manifest_mod = @import("manifest.zig");
const archive = @import("archive.zig");
const checksum = @import("checksum.zig");

pub const Manifest = manifest_mod.Manifest;
pub const FileData = archive.FileData;

/// A package opened from `.zpkg` bytes. Owns all of its memory; call
/// `deinit()` when done.
pub const Opened = struct {
    manifest_parsed: std.json.Parsed(Manifest),
    files: []FileData,
    archive_arena: std.heap.ArenaAllocator,

    pub fn manifest(self: *const Opened) Manifest {
        return self.manifest_parsed.value;
    }

    pub fn deinit(self: *Opened) void {
        self.manifest_parsed.deinit();
        self.archive_arena.deinit();
    }
};

fn hashFiles(files: []const FileData) [64]u8 {
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    for (files) |f| hasher.update(f.content);
    var digest: [32]u8 = undefined;
    hasher.final(&digest);
    var hex: [64]u8 = undefined;
    checksum.hexEncode(&digest, &hex);
    return hex;
}

/// Builds the manifest's per-file entries from the actual payload, so the
/// recorded paths/sizes/hashes can't disagree with what's packed. Entries
/// are allocated with `allocator`; caller frees the slice and each
/// `sha256` string.
fn buildFileEntries(allocator: std.mem.Allocator, files: []const FileData) ![]manifest_mod.FileEntry {
    const entries = try allocator.alloc(manifest_mod.FileEntry, files.len);
    var filled: usize = 0;
    errdefer {
        for (entries[0..filled]) |e| allocator.free(e.sha256);
        allocator.free(entries);
    }
    for (files, 0..) |f, i| {
        entries[i] = .{
            .path = f.path,
            .size = f.content.len,
            .sha256 = try checksum.sha256Hex(allocator, f.content),
        };
        filled += 1;
    }
    return entries;
}

fn freeFileEntries(allocator: std.mem.Allocator, entries: []manifest_mod.FileEntry) void {
    for (entries) |e| allocator.free(e.sha256);
    allocator.free(entries);
}

/// Builds a `.zpkg` byte buffer. `manifest_in.checksum` and
/// `manifest_in.files` are ignored (and overwritten) — both are derived
/// from `files`, in order, so they can't drift from what's actually packed.
pub fn create(allocator: std.mem.Allocator, manifest_in: Manifest, files: []const FileData) ![]u8 {
    var m = manifest_in;
    try m.validate();

    const checksum_hex = hashFiles(files);
    m.checksum = &checksum_hex;

    const entries = try buildFileEntries(allocator, files);
    defer freeFileEntries(allocator, entries);
    m.files = entries;

    const manifest_json = try manifest_mod.toJson(allocator, m);
    defer allocator.free(manifest_json);

    return archive.pack(allocator, manifest_json, files);
}

/// Parses and verifies a `.zpkg` buffer: structural manifest validation,
/// then checksum verification against the actual file payload. Returns
/// `error.ChecksumMismatch` on a corrupted or tampered archive rather than
/// silently returning bad data.
pub fn open(allocator: std.mem.Allocator, zpkg_bytes: []const u8) !Opened {
    var unpacked = try archive.unpack(allocator, zpkg_bytes);
    errdefer unpacked.deinit();

    var parsed = try manifest_mod.fromJson(allocator, unpacked.manifest_json);
    errdefer parsed.deinit();

    try parsed.value.validate();

    const actual_checksum = hashFiles(unpacked.files);
    if (!std.mem.eql(u8, &actual_checksum, parsed.value.checksum)) {
        return error.ChecksumMismatch;
    }

    return .{
        .manifest_parsed = parsed,
        .files = unpacked.files,
        .archive_arena = unpacked.arena,
    };
}

test "create then open round-trips and verifies checksum" {
    const allocator = std.testing.allocator;
    const files = [_]FileData{
        .{ .path = "bin/hello", .content = "#!/bin/sh\necho hi\n" },
    };
    const m = Manifest{ .name = "hello", .version = "1.0.0", .architecture = "x86_64" };

    const zpkg_bytes = try create(allocator, m, &files);
    defer allocator.free(zpkg_bytes);

    var opened = try open(allocator, zpkg_bytes);
    defer opened.deinit();

    try std.testing.expectEqualStrings("hello", opened.manifest().name);
    try std.testing.expectEqual(@as(usize, 64), opened.manifest().checksum.len);
    try std.testing.expectEqualStrings("bin/hello", opened.files[0].path);

    // create() must record the payload in manifest.files -- remove() relies
    // on that list to know what to delete.
    const entries = opened.manifest().files;
    try std.testing.expectEqual(@as(usize, 1), entries.len);
    try std.testing.expectEqualStrings("bin/hello", entries[0].path);
    try std.testing.expectEqual(@as(u64, files[0].content.len), entries[0].size);
    try std.testing.expectEqual(@as(usize, 64), entries[0].sha256.len);
}

test "open rejects a package with a corrupted payload" {
    const allocator = std.testing.allocator;
    const files = [_]FileData{.{ .path = "bin/hello", .content = "original" }};
    const m = Manifest{ .name = "hello", .version = "1.0.0", .architecture = "x86_64" };

    const zpkg_bytes = try create(allocator, m, &files);
    defer allocator.free(zpkg_bytes);

    // Flip a byte inside the packed file content (well past the header)
    // to simulate on-disk corruption or tampering.
    const tampered = try allocator.dupe(u8, zpkg_bytes);
    defer allocator.free(tampered);
    tampered[tampered.len - 1] ^= 0xFF;

    try std.testing.expectError(error.ChecksumMismatch, open(allocator, tampered));
}
