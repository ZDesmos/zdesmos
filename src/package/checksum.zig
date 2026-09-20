//! SHA-256 checksum helpers. Hex is the on-disk/manifest representation
//! (readable, diffable, matches the spec's `checksum: string` field).

const std = @import("std");

const hex_chars = "0123456789abcdef";

fn hexEncodeInto(bytes: []const u8, out: []u8) void {
    for (bytes, 0..) |b, i| {
        out[i * 2] = hex_chars[b >> 4];
        out[i * 2 + 1] = hex_chars[b & 0x0f];
    }
}

/// Public so callers computing a checksum incrementally (e.g. hashing
/// several files with one `Sha256` instance, as `package.zig` does) can
/// reuse the same hex encoding as `sha256Hex`/`verify` below.
pub const hexEncode = hexEncodeInto;

/// Lowercase hex SHA-256 of `data`, written into a 64-byte stack buffer.
pub fn sha256HexBuf(data: []const u8, out: *[64]u8) void {
    var hash: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(data, &hash, .{});
    hexEncodeInto(&hash, out);
}

/// Lowercase hex SHA-256 of `data`, allocated. Caller owns the result.
pub fn sha256Hex(allocator: std.mem.Allocator, data: []const u8) ![]u8 {
    var buf: [64]u8 = undefined;
    sha256HexBuf(data, &buf);
    return allocator.dupe(u8, &buf);
}

/// Streaming chunk size for `verifyFile`.
const file_chunk_size: usize = 64 * 1024;

/// True if the file at `path` hashes to `expected_hex`, read in fixed-size
/// chunks so peak RAM stays flat regardless of file size. Returns false if
/// the file is missing or unreadable -- callers treat that the same as
/// "not a valid cached copy".
pub fn verifyFile(path: []const u8, expected_hex: []const u8) bool {
    if (expected_hex.len != 64) return false;

    var file = std.fs.cwd().openFile(path, .{}) catch return false;
    defer file.close();

    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    var buf: [file_chunk_size]u8 = undefined;
    while (true) {
        const n = file.read(&buf) catch return false;
        if (n == 0) break;
        hasher.update(buf[0..n]);
    }

    var digest: [32]u8 = undefined;
    hasher.final(&digest);
    var hex: [64]u8 = undefined;
    hexEncodeInto(&digest, &hex);
    return std.mem.eql(u8, &hex, expected_hex);
}

/// True if `data` hashes to `expected_hex` (case-sensitive lowercase hex).
pub fn verify(data: []const u8, expected_hex: []const u8) bool {
    if (expected_hex.len != 64) return false;
    var buf: [64]u8 = undefined;
    sha256HexBuf(data, &buf);
    return std.mem.eql(u8, &buf, expected_hex);
}

test "sha256Hex matches the well-known test vector for \"abc\"" {
    const digest = try sha256Hex(std.testing.allocator, "abc");
    defer std.testing.allocator.free(digest);
    try std.testing.expectEqualStrings(
        "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad",
        digest,
    );
}

test "verify accepts the correct checksum and rejects a wrong one" {
    try std.testing.expect(verify("abc", "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"));
    try std.testing.expect(!verify("abc", "0000000000000000000000000000000000000000000000000000000000000000"[0..64]));
    try std.testing.expect(!verify("abc", "too-short"));
}

test "verifyFile streams a file and matches sha256Hex" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const tmp_path = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(tmp_path);

    const path = try std.fmt.allocPrint(allocator, "{s}/data.bin", .{tmp_path});
    defer allocator.free(path);

    // Larger than one chunk, to exercise the loop.
    const payload = try allocator.alloc(u8, file_chunk_size * 2 + 123);
    defer allocator.free(payload);
    for (payload, 0..) |*b, i| b.* = @truncate(i);
    try std.fs.cwd().writeFile(.{ .sub_path = path, .data = payload });

    const expected = try sha256Hex(allocator, payload);
    defer allocator.free(expected);

    try std.testing.expect(verifyFile(path, expected));
    try std.testing.expect(!verifyFile(path, "0" ** 64));
    try std.testing.expect(!verifyFile("/nonexistent/file", expected));
}
