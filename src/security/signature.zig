//! Cryptographic signature verification, on top of `std.crypto.sign.Ed25519`
//! -- no external dependency, matching the project's minimal-dependency
//! goal. This is the "signatures can be added later" architecture the spec
//! asks for, actually wired in rather than left as a comment: a repository
//! that publishes a public key gets its package checksums verified against
//! signatures; one that doesn't stays checksum-only, which remains the
//! hard minimum everywhere (see `package.zig`, `checksum.zig`).
//!
//! What gets signed is the package's hex SHA-256 checksum, not the raw
//! package bytes -- the checksum already commits to the exact bytes, is
//! tiny and fixed-size regardless of package size, and is what's already
//! in hand after `archive`/`http` verification. This mirrors how apt
//! signs a hash list (Release/Release.gpg) rather than every .deb.

const std = @import("std");

const Ed25519 = std.crypto.sign.Ed25519;

pub const public_key_hex_len = 64; // 32 bytes
pub const signature_hex_len = 128; // 64 bytes

fn hexDecode(comptime len: usize, text: []const u8) ?[len / 2]u8 {
    if (text.len != len) return null;
    var out: [len / 2]u8 = undefined;
    var i: usize = 0;
    while (i < out.len) : (i += 1) {
        const hi = hexNibble(text[i * 2]) orelse return null;
        const lo = hexNibble(text[i * 2 + 1]) orelse return null;
        out[i] = (hi << 4) | lo;
    }
    return out;
}

fn hexNibble(c: u8) ?u8 {
    return switch (c) {
        '0'...'9' => c - '0',
        'a'...'f' => c - 'a' + 10,
        'A'...'F' => c - 'A' + 10,
        else => null,
    };
}

pub fn parsePublicKey(hex: []const u8) !Ed25519.PublicKey {
    const bytes = hexDecode(public_key_hex_len, hex) orelse return error.InvalidPublicKey;
    return Ed25519.PublicKey.fromBytes(bytes) catch error.InvalidPublicKey;
}

/// Verifies `signature_hex` (hex Ed25519 signature) over `message` using
/// `public_key_hex` (hex Ed25519 public key). Returns
/// `error.SignatureInvalid` if the signature doesn't check out, rather
/// than a bool -- signature checks are a place where "did you check the
/// return value" bugs are unusually costly, so failing to check is a
/// compile-time-visible unused-error rather than a silently-ignored false.
pub fn verify(message: []const u8, signature_hex: []const u8, public_key_hex: []const u8) !void {
    const sig_bytes = hexDecode(signature_hex_len, signature_hex) orelse return error.InvalidSignature;
    const pk = try parsePublicKey(public_key_hex);
    const sig = Ed25519.Signature.fromBytes(sig_bytes);
    sig.verify(message, pk) catch return error.SignatureInvalid;
}

/// Signs `message`, returning the hex public key and hex signature.
/// `zdms` itself never calls this -- only a repository's index-publishing
/// tooling signs anything, and that tool doesn't exist yet. It's exposed
/// (rather than kept test-private) because that future `zdms-sign` tool
/// and these tests need exactly the same operation.
pub fn signForTest(allocator: std.mem.Allocator, message: []const u8) !struct { public_key_hex: []u8, signature_hex: []u8 } {
    // Zig 0.13.0's Ed25519.KeyPair has no argument-less `generate()`;
    // `create(null)` is the equivalent (null seed = random).
    const kp = try Ed25519.KeyPair.create(null);
    const sig = try kp.sign(message, null);

    const pk_hex = try allocator.alloc(u8, public_key_hex_len);
    hexEncode(&kp.public_key.toBytes(), pk_hex);
    const sig_hex = try allocator.alloc(u8, signature_hex_len);
    hexEncode(&sig.toBytes(), sig_hex);

    return .{ .public_key_hex = pk_hex, .signature_hex = sig_hex };
}

fn hexEncode(bytes: []const u8, out: []u8) void {
    const chars = "0123456789abcdef";
    for (bytes, 0..) |b, i| {
        out[i * 2] = chars[b >> 4];
        out[i * 2 + 1] = chars[b & 0x0f];
    }
}

test "verify accepts a genuine signature and rejects a tampered message" {
    const allocator = std.testing.allocator;
    const message = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855";

    const signed = try signForTest(allocator, message);
    defer allocator.free(signed.public_key_hex);
    defer allocator.free(signed.signature_hex);

    try verify(message, signed.signature_hex, signed.public_key_hex);
    try std.testing.expectError(
        error.SignatureInvalid,
        verify("a different message entirely", signed.signature_hex, signed.public_key_hex),
    );
}

test "verify rejects a signature from the wrong key" {
    const allocator = std.testing.allocator;
    const message = "some checksum";

    const signed = try signForTest(allocator, message);
    defer allocator.free(signed.public_key_hex);
    defer allocator.free(signed.signature_hex);

    const other = try signForTest(allocator, message);
    defer allocator.free(other.public_key_hex);
    defer allocator.free(other.signature_hex);

    try std.testing.expectError(
        error.SignatureInvalid,
        verify(message, signed.signature_hex, other.public_key_hex),
    );
}

test "malformed hex is rejected before any crypto runs" {
    try std.testing.expectError(error.InvalidPublicKey, parsePublicKey("not-hex"));
    try std.testing.expectError(error.InvalidPublicKey, parsePublicKey("ab"));
    try std.testing.expectError(
        error.InvalidSignature,
        verify("msg", "zz", "0" ** public_key_hex_len),
    );
}
