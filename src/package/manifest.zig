//! Package manifest — the metadata half of a `.zpkg` (the other half being
//! the file payload, see `archive.zig`). Serialized as JSON: readable,
//! diffable, and `std.json` is already in the stdlib so this adds no
//! external dependency.

const std = @import("std");
const errors = @import("../core/errors.zig");

/// A dependency requirement. `version_constraint` is kept as an opaque
/// string for now (e.g. "*", ">=1.2.0") — real constraint parsing/solving
/// is the resolver's job (Phase 5), not the manifest's.
pub const Dependency = struct {
    name: []const u8,
    version_constraint: []const u8 = "*",
};

/// One installed file: where it goes and its own checksum, so a corrupted
/// single file can be detected/repaired without re-verifying the whole
/// package.
pub const FileEntry = struct {
    path: []const u8,
    size: u64,
    sha256: []const u8,
};

pub const Manifest = struct {
    name: []const u8,
    version: []const u8,
    architecture: []const u8,
    dependencies: []const Dependency = &.{},
    /// Hex SHA-256 over the packed file payload. Empty until `package.create`
    /// fills it in — a manifest you're about to pack doesn't have it yet.
    checksum: []const u8 = "",
    files: []const FileEntry = &.{},

    pub fn validate(self: Manifest) errors.PackageError!void {
        if (self.name.len == 0) return error.InvalidManifest;
        if (self.version.len == 0) return error.InvalidManifest;
        if (self.architecture.len == 0) return error.InvalidManifest;
        for (self.dependencies) |dep| {
            if (dep.name.len == 0) return error.InvalidManifest;
        }
        for (self.files) |file| {
            if (file.path.len == 0) return error.InvalidManifest;
        }
    }
};

pub fn toJson(allocator: std.mem.Allocator, manifest: Manifest) ![]u8 {
    return std.json.stringifyAlloc(allocator, manifest, .{});
}

/// Caller must call `.deinit()` on the result to free the parsed manifest.
pub fn fromJson(allocator: std.mem.Allocator, json_text: []const u8) !std.json.Parsed(Manifest) {
    // .alloc_always: keeps the parsed Manifest independent of json_text's
    // lifetime, regardless of what the caller does with it afterward.
    return std.json.parseFromSlice(Manifest, allocator, json_text, .{ .allocate = .alloc_always });
}

test "manifest round-trips through JSON" {
    const allocator = std.testing.allocator;
    const original = Manifest{
        .name = "hello",
        .version = "1.0.0",
        .architecture = "x86_64",
        .dependencies = &.{.{ .name = "libc", .version_constraint = ">=1.0" }},
        .checksum = "deadbeef",
        .files = &.{.{ .path = "bin/hello", .size = 1024, .sha256 = "cafebabe" }},
    };

    const json_text = try toJson(allocator, original);
    defer allocator.free(json_text);

    const parsed = try fromJson(allocator, json_text);
    defer parsed.deinit();

    try std.testing.expectEqualStrings("hello", parsed.value.name);
    try std.testing.expectEqualStrings("1.0.0", parsed.value.version);
    try std.testing.expectEqualStrings("x86_64", parsed.value.architecture);
    try std.testing.expectEqual(@as(usize, 1), parsed.value.dependencies.len);
    try std.testing.expectEqualStrings("libc", parsed.value.dependencies[0].name);
    try std.testing.expectEqualStrings("bin/hello", parsed.value.files[0].path);
}

test "validate rejects missing required fields" {
    try std.testing.expectError(error.InvalidManifest, (Manifest{
        .name = "",
        .version = "1.0.0",
        .architecture = "x86_64",
    }).validate());
    try std.testing.expectError(error.InvalidManifest, (Manifest{
        .name = "hello",
        .version = "",
        .architecture = "x86_64",
    }).validate());
    try std.testing.expectError(error.InvalidManifest, (Manifest{
        .name = "hello",
        .version = "1.0.0",
        .architecture = "",
    }).validate());
}

test "validate accepts a minimal manifest" {
    try (Manifest{ .name = "hello", .version = "1.0.0", .architecture = "x86_64" }).validate();
}
