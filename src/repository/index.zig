//! Repository index: the small metadata document a repository publishes
//! listing the packages it offers. `zdms update` fetches these; `search`
//! and `info` read them. Deliberately *not* package contents -- an index
//! entry carries only what's needed to decide what to download.
//!
//! JSON, same reasoning as the manifest: stdlib-only, diffable, cheap to
//! parse. Compression of the fetched bytes is Phase 6.

const std = @import("std");
const errors = @import("../core/errors.zig");
const manifest_mod = @import("../package/manifest.zig");
const arch = @import("../core/arch.zig");

pub const format_version: u32 = 1;

/// One package available from a repository. `path` is relative to the
/// repository's base URL, so mirrors/CDNs can serve the same index.
pub const IndexEntry = struct {
    name: []const u8,
    version: []const u8,
    architecture: []const u8,
    /// Relative path of the .zpkg within the repository.
    path: []const u8,
    /// Hex SHA-256 of the .zpkg payload, verified after download.
    checksum: []const u8,
    /// Size in bytes, used for progress reporting and disk-space checks.
    size: u64 = 0,
    dependencies: []const manifest_mod.Dependency = &.{},
    description: []const u8 = "",
    /// Hex Ed25519 signature over `checksum`, from the repository's
    /// signing key. Empty on an unsigned repository -- see
    /// `security/signature.zig` and `Repository.public_key`.
    signature: []const u8 = "",
};

pub const Index = struct {
    format_version: u32 = format_version,
    packages: []const IndexEntry = &.{},

    pub fn validate(self: Index) errors.RepositoryError!void {
        if (self.format_version != format_version) return error.InvalidIndex;
        for (self.packages) |e| {
            if (e.name.len == 0) return error.InvalidIndex;
            if (e.version.len == 0) return error.InvalidIndex;
            if (e.path.len == 0) return error.InvalidIndex;
            if (e.checksum.len != 64) return error.InvalidIndex;
            if (arch.Architecture.parse(e.architecture) == null) return error.InvalidIndex;
        }
    }

    /// First entry matching `name`, or null. Index order is the
    /// repository's stated preference order.
    pub fn find(self: Index, name: []const u8) ?IndexEntry {
        for (self.packages) |e| {
            if (std.mem.eql(u8, e.name, name)) return e;
        }
        return null;
    }

    /// First entry matching both `name` and `architecture` -- the lookup
    /// an actual install should use, since installing the wrong
    /// architecture's binary is worse than not finding the package.
    pub fn findForArch(self: Index, name: []const u8, architecture: []const u8) ?IndexEntry {
        for (self.packages) |e| {
            if (std.mem.eql(u8, e.name, name) and std.mem.eql(u8, e.architecture, architecture)) return e;
        }
        return null;
    }
};

pub fn toJson(allocator: std.mem.Allocator, idx: Index) ![]u8 {
    return std.json.stringifyAlloc(allocator, idx, .{});
}

/// Caller must `.deinit()` the result.
pub fn fromJson(allocator: std.mem.Allocator, json_text: []const u8) !std.json.Parsed(Index) {
    // .alloc_always: callers (e.g. repository.loadIndex) free their raw
    // bytes right after parsing, so parsed strings must be independent
    // copies, not pointers into that buffer.
    return std.json.parseFromSlice(Index, allocator, json_text, .{ .allocate = .alloc_always }) catch return error.InvalidIndex;
}

const dummy_checksum = "0" ** 64;

test "index round-trips through JSON and finds entries by name" {
    const allocator = std.testing.allocator;
    const original = Index{ .packages = &.{
        .{ .name = "hello", .version = "1.0.0", .architecture = "x86_64", .path = "pool/hello-1.0.0.zpkg", .checksum = dummy_checksum, .size = 42 },
        .{ .name = "world", .version = "2.1.0", .architecture = "x86_64", .path = "pool/world-2.1.0.zpkg", .checksum = dummy_checksum },
    } };

    const json_text = try toJson(allocator, original);
    defer allocator.free(json_text);

    const parsed = try fromJson(allocator, json_text);
    defer parsed.deinit();

    try parsed.value.validate();
    try std.testing.expectEqual(@as(usize, 2), parsed.value.packages.len);

    const found = parsed.value.find("world").?;
    try std.testing.expectEqualStrings("2.1.0", found.version);
    try std.testing.expectEqualStrings("pool/world-2.1.0.zpkg", found.path);

    try std.testing.expectEqual(@as(?IndexEntry, null), parsed.value.find("missing"));
}

test "validate rejects a bad format version and malformed entries" {
    try std.testing.expectError(error.InvalidIndex, (Index{ .format_version = 999 }).validate());

    try std.testing.expectError(error.InvalidIndex, (Index{ .packages = &.{
        .{ .name = "", .version = "1.0.0", .architecture = "x86_64", .path = "p.zpkg", .checksum = dummy_checksum },
    } }).validate());

    // Checksum must be a full 64-char hex SHA-256.
    try std.testing.expectError(error.InvalidIndex, (Index{ .packages = &.{
        .{ .name = "hello", .version = "1.0.0", .architecture = "x86_64", .path = "p.zpkg", .checksum = "abc" },
    } }).validate());
}

test "fromJson rejects malformed JSON as InvalidIndex" {
    try std.testing.expectError(error.InvalidIndex, fromJson(std.testing.allocator, "{not json"));
}

test "findForArch matches only the requested architecture" {
    const idx = Index{ .packages = &.{
        .{ .name = "hello", .version = "1.0.0", .architecture = "x86_64", .path = "a.zpkg", .checksum = dummy_checksum },
        .{ .name = "hello", .version = "1.0.0", .architecture = "aarch64", .path = "b.zpkg", .checksum = dummy_checksum },
    } };

    const x86 = idx.findForArch("hello", "x86_64").?;
    try std.testing.expectEqualStrings("a.zpkg", x86.path);

    const arm = idx.findForArch("hello", "aarch64").?;
    try std.testing.expectEqualStrings("b.zpkg", arm.path);

    try std.testing.expectEqual(@as(?IndexEntry, null), idx.findForArch("hello", "i686"));
}
