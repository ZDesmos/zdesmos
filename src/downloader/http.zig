//! HTTP downloader built on std.http.Client -- no external dependency, and
//! the client is reused across requests so connections are kept alive.
//!
//! `fetchToFile` streams: it reads the response in fixed-size chunks and
//! writes each chunk straight to a temporary file while hashing it, so
//! peak RAM is the chunk size regardless of package size (spec: "never
//! allocate package_size bytes simply because a package has that size").
//! The temp file is renamed into place only after the hash matches, which
//! also makes an interrupted download leave no half-file behind.

const std = @import("std");
const errors = @import("../core/errors.zig");
const log = @import("../core/log.zig");
const checksum = @import("../package/checksum.zig");

/// Streaming chunk size. Big enough to keep syscall overhead low, small
/// enough that peak RSS stays flat on multi-hundred-MB packages.
pub const chunk_size: usize = 64 * 1024;

pub const Client = struct {
    allocator: std.mem.Allocator,
    http: std.http.Client,
    retries: u32,

    pub fn init(allocator: std.mem.Allocator, retries: u32) Client {
        return .{
            .allocator = allocator,
            .http = .{ .allocator = allocator },
            .retries = retries,
        };
    }

    pub fn deinit(self: *Client) void {
        self.http.deinit();
    }

    /// Fetches `url` fully into memory. Only for small documents whose size
    /// is known to be bounded (repository indexes); packages go through
    /// `fetchToFile`.
    pub fn fetch(self: *Client, url: []const u8, max_bytes: usize) ![]u8 {
        var attempt: u32 = 0;
        while (true) : (attempt += 1) {
            return self.fetchOnce(url, max_bytes) catch |e| {
                if (!isRetryable(e) or attempt >= self.retries) return e;
                log.debug("retrying {s} (attempt {d})", .{ url, attempt + 1 });
                continue;
            };
        }
    }

    /// A 404 or an oversized body will not fix itself; only transport-level
    /// failures are worth another attempt.
    fn isRetryable(e: anyerror) bool {
        return switch (e) {
            error.HttpError, error.TooLarge, error.ChecksumMismatch => false,
            else => true,
        };
    }

    fn fetchOnce(self: *Client, url: []const u8, max_bytes: usize) ![]u8 {
        var body = std.ArrayList(u8).init(self.allocator);
        errdefer body.deinit();

        const result = self.http.fetch(.{
            .location = .{ .url = url },
            .method = .GET,
            .response_storage = .{ .dynamic = &body },
            .max_append_size = max_bytes,
        }) catch |e| {
            log.debug("request to {s} failed: {s}", .{ url, @errorName(e) });
            return error.RequestFailed;
        };

        if (result.status != .ok) {
            log.err("{s} returned HTTP {d}", .{ url, @intFromEnum(result.status) });
            return error.HttpError;
        }

        return body.toOwnedSlice();
    }

    /// Streams `url` to `dest_path`, verifying `expected_sha256` as it
    /// goes. Writes to `<dest_path>.part` and renames on success, so a
    /// failed or interrupted download never leaves a corrupt file where a
    /// valid one is expected. An empty `expected_sha256` skips
    /// verification (used for repository indexes, whose hash isn't known
    /// in advance).
    pub fn fetchToFile(
        self: *Client,
        url: []const u8,
        dest_path: []const u8,
        expected_sha256: []const u8,
        max_bytes: usize,
    ) !void {
        var attempt: u32 = 0;
        while (true) : (attempt += 1) {
            return self.fetchToFileOnce(url, dest_path, expected_sha256, max_bytes) catch |e| {
                if (!isRetryable(e) or attempt >= self.retries) return e;
                log.debug("retrying {s} (attempt {d})", .{ url, attempt + 1 });
                continue;
            };
        }
    }

    fn fetchToFileOnce(
        self: *Client,
        url: []const u8,
        dest_path: []const u8,
        expected_sha256: []const u8,
        max_bytes: usize,
    ) !void {
        if (std.fs.path.dirname(dest_path)) |dir| try std.fs.cwd().makePath(dir);

        const part_path = try std.fmt.allocPrint(self.allocator, "{s}.part", .{dest_path});
        defer self.allocator.free(part_path);

        const uri = std.Uri.parse(url) catch return error.RequestFailed;

        var header_buf: [16 * 1024]u8 = undefined;
        var req = self.http.open(.GET, uri, .{ .server_header_buffer = &header_buf }) catch |e| {
            log.debug("request to {s} failed: {s}", .{ url, @errorName(e) });
            return error.RequestFailed;
        };
        defer req.deinit();

        req.send() catch return error.RequestFailed;
        req.finish() catch return error.RequestFailed;
        req.wait() catch return error.RequestFailed;

        if (req.response.status != .ok) {
            log.err("{s} returned HTTP {d}", .{ url, @intFromEnum(req.response.status) });
            return error.HttpError;
        }

        var file = try std.fs.cwd().createFile(part_path, .{ .truncate = true });
        // On any failure below, drop the partial file rather than leaving
        // it to be mistaken for a resumable download.
        errdefer {
            file.close();
            std.fs.cwd().deleteFile(part_path) catch {};
        }

        var hasher = std.crypto.hash.sha2.Sha256.init(.{});
        var buf: [chunk_size]u8 = undefined;
        var total: usize = 0;
        const reader = req.reader();

        while (true) {
            const n = reader.read(&buf) catch return error.RequestFailed;
            if (n == 0) break;

            total += n;
            if (total > max_bytes) return error.TooLarge;

            hasher.update(buf[0..n]);
            try file.writeAll(buf[0..n]);
        }

        if (expected_sha256.len != 0) {
            var digest: [32]u8 = undefined;
            hasher.final(&digest);
            var hex: [64]u8 = undefined;
            checksum.hexEncode(&digest, &hex);
            if (!std.mem.eql(u8, &hex, expected_sha256)) return error.ChecksumMismatch;
        }

        file.close();
        try std.fs.cwd().rename(part_path, dest_path);
    }
};

/// Joins a repository base URL and a relative path with exactly one slash.
pub fn joinUrl(allocator: std.mem.Allocator, base: []const u8, rel: []const u8) ![]u8 {
    const trimmed_base = std.mem.trimRight(u8, base, "/");
    const trimmed_rel = std.mem.trimLeft(u8, rel, "/");
    return std.fmt.allocPrint(allocator, "{s}/{s}", .{ trimmed_base, trimmed_rel });
}

test "joinUrl normalizes slashes on both sides" {
    const allocator = std.testing.allocator;

    const a = try joinUrl(allocator, "https://repo.example.com", "pool/hello.zpkg");
    defer allocator.free(a);
    try std.testing.expectEqualStrings("https://repo.example.com/pool/hello.zpkg", a);

    const b = try joinUrl(allocator, "https://repo.example.com/", "/pool/hello.zpkg");
    defer allocator.free(b);
    try std.testing.expectEqualStrings("https://repo.example.com/pool/hello.zpkg", b);
}

test "only transport failures are retried" {
    try std.testing.expect(!Client.isRetryable(error.HttpError));
    try std.testing.expect(!Client.isRetryable(error.TooLarge));
    try std.testing.expect(!Client.isRetryable(error.ChecksumMismatch));
    try std.testing.expect(Client.isRetryable(error.RequestFailed));
    try std.testing.expect(Client.isRetryable(error.ConnectionResetByPeer));
}
