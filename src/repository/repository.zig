//! The repository layer: configured repositories, their cached indexes,
//! and lookups across them.
//!
//! `update` refreshes cached index metadata only -- never package contents
//! (spec). Indexes are cached under `<cache_dir>/indexes/<repo>.json`, so
//! `search`/`info`/`install` work offline against the last `update`.

const std = @import("std");
const errors = @import("../core/errors.zig");
const config_mod = @import("../core/config.zig");
const log = @import("../core/log.zig");
const index_mod = @import("index.zig");
const http = @import("../downloader/http.zig");
const parallel = @import("../downloader/parallel.zig");
const checksum = @import("../package/checksum.zig");
const signature = @import("../security/signature.zig");

/// Indexes are metadata: small by design. This cap is a sanity bound
/// against a hostile or broken repository, not a real-world limit.
pub const max_index_bytes: usize = 64 * 1024 * 1024;
pub const max_package_bytes: usize = 2 * 1024 * 1024 * 1024;

pub const Repository = struct {
    name: []const u8,
    /// Base URL; package `path`s and the index are resolved against it.
    url: []const u8,
    /// Relative path of the index document within the repository.
    index_path: []const u8 = "index.json",
    enabled: bool = true,
    /// Hex Ed25519 public key. Empty means this repository is unsigned:
    /// checksum verification still applies (it always does), but there is
    /// no signature to check. Set it to require every entry from this
    /// repository to carry a valid `IndexEntry.signature`.
    public_key: []const u8 = "",
};

/// A package found in a specific repository.
pub const Found = struct {
    repo_name: []const u8,
    repo_url: []const u8,
    entry: index_mod.IndexEntry,
};

pub const Manager = struct {
    allocator: std.mem.Allocator,
    config: config_mod.Config,
    repositories: []const Repository,

    pub fn init(allocator: std.mem.Allocator, config: config_mod.Config, repositories: []const Repository) Manager {
        return .{ .allocator = allocator, .config = config, .repositories = repositories };
    }

    /// Local path of a repository's cached index.
    pub fn cachedIndexPath(self: Manager, repo: Repository) ![]u8 {
        return std.fmt.allocPrint(self.allocator, "{s}/indexes/{s}.json", .{
            std.mem.trimRight(u8, self.config.cache_dir, "/"),
            repo.name,
        });
    }

    /// Loads a repository's cached index. Returns `error.IndexNotFetched`
    /// if `update` hasn't been run for it yet. Caller must `.deinit()`.
    ///
    /// A repository may publish its index gzip-compressed (spec:
    /// "compressed metadata"); that is detected from the gzip magic bytes
    /// rather than the filename, so a mirror serving `.json` that is
    /// actually compressed still works.
    pub fn loadIndex(self: Manager, repo: Repository) !std.json.Parsed(index_mod.Index) {
        const path = try self.cachedIndexPath(repo);
        defer self.allocator.free(path);

        const raw = std.fs.cwd().readFileAlloc(self.allocator, path, max_index_bytes) catch |e| switch (e) {
            error.FileNotFound => return error.IndexNotFetched,
            else => return e,
        };
        defer self.allocator.free(raw);

        const json_bytes = if (isGzip(raw)) try gunzip(self.allocator, raw) else raw;
        defer if (isGzip(raw)) self.allocator.free(json_bytes);

        const parsed = try index_mod.fromJson(self.allocator, json_bytes);
        errdefer parsed.deinit();
        try parsed.value.validate();
        return parsed;
    }

    /// Refreshes cached index metadata for every enabled repository.
    /// Downloads no package contents. A repository that fails to update is
    /// logged and skipped so one bad mirror doesn't break the whole run;
    /// the error is only surfaced if *every* repository failed.
    pub fn update(self: Manager) !void {
        if (self.repositories.len == 0) return error.NoRepositories;

        var client = http.Client.init(self.allocator, self.config.download_retries);
        defer client.deinit();

        var succeeded: usize = 0;
        var attempted: usize = 0;
        for (self.repositories) |repo| {
            if (!repo.enabled) continue;
            attempted += 1;

            const url = try http.joinUrl(self.allocator, repo.url, repo.index_path);
            defer self.allocator.free(url);
            const dest = try self.cachedIndexPath(repo);
            defer self.allocator.free(dest);

            // Index checksums aren't known ahead of time (that's what
            // signatures are for, Phase 7), so pass an empty expectation
            // and validate structurally after writing.
            client.fetchToFile(url, dest, "", max_index_bytes) catch |e| {
                log.warn("could not update repository '{s}': {s}", .{ repo.name, @errorName(e) });
                continue;
            };
            succeeded += 1;
            log.info("updated repository '{s}'", .{repo.name});
        }

        if (attempted == 0) return error.NoRepositories;
        if (succeeded == 0) return error.RequestFailed;
    }

    /// Finds `name` for `config.architecture` across all enabled
    /// repositories, in configured order. Repositories without a cached
    /// index are skipped rather than failing the lookup.
    pub fn find(self: Manager, name: []const u8) !?Found {
        for (self.repositories) |repo| {
            if (!repo.enabled) continue;
            const parsed = self.loadIndex(repo) catch |e| switch (e) {
                error.IndexNotFetched => continue,
                error.InvalidIndex => {
                    log.warn("repository '{s}' has an invalid index", .{repo.name});
                    continue;
                },
                else => return e,
            };
            defer parsed.deinit();

            if (parsed.value.findForArch(name, self.config.architecture)) |entry| {
                // Enforced here, not left to the caller: the package about
                // to be installed must pass this repository's signing
                // policy before it's ever handed back.
                try self.verifySignature(repo, entry);
                // The parsed arena dies with `parsed`, so hand back copies.
                return Found{
                    .repo_name = repo.name,
                    .repo_url = repo.url,
                    .entry = try self.dupeEntry(entry),
                };
            }
        }
        return null;
    }

    fn dupeEntry(self: Manager, e: index_mod.IndexEntry) !index_mod.IndexEntry {
        return .{
            .name = try self.allocator.dupe(u8, e.name),
            .version = try self.allocator.dupe(u8, e.version),
            .architecture = try self.allocator.dupe(u8, e.architecture),
            .path = try self.allocator.dupe(u8, e.path),
            .checksum = try self.allocator.dupe(u8, e.checksum),
            .size = e.size,
            .description = try self.allocator.dupe(u8, e.description),
            .signature = try self.allocator.dupe(u8, e.signature),
        };
    }

    pub fn freeFound(self: Manager, f: Found) void {
        self.allocator.free(f.entry.name);
        self.allocator.free(f.entry.version);
        self.allocator.free(f.entry.architecture);
        self.allocator.free(f.entry.path);
        self.allocator.free(f.entry.checksum);
        self.allocator.free(f.entry.description);
        self.allocator.free(f.entry.signature);
    }

    /// Enforces this repository's signing policy for one found package.
    /// An unsigned repository (`public_key` empty) passes trivially --
    /// checksum verification, which already happened via
    /// `ensureDownloaded`/`downloadJob`, remains the actual security
    /// boundary in that case. A signed repository requires a valid
    /// signature over the entry's checksum.
    pub fn verifySignature(self: Manager, repo: Repository, entry: index_mod.IndexEntry) !void {
        _ = self;
        if (repo.public_key.len == 0) return;
        if (entry.signature.len == 0) return error.SignatureMissing;
        try signature.verify(entry.checksum, entry.signature, repo.public_key);
    }

    /// Substring search over names and descriptions of every cached index.
    /// Caller owns the returned slice and must `freeFound` each element.
    pub fn search(self: Manager, query: []const u8) ![]Found {
        var results = std.ArrayList(Found).init(self.allocator);
        errdefer {
            for (results.items) |f| self.freeFound(f);
            results.deinit();
        }

        for (self.repositories) |repo| {
            if (!repo.enabled) continue;
            const parsed = self.loadIndex(repo) catch continue;
            defer parsed.deinit();

            for (parsed.value.packages) |e| {
                if (!std.mem.eql(u8, e.architecture, self.config.architecture)) continue;
                const matches = std.mem.indexOf(u8, e.name, query) != null or
                    std.mem.indexOf(u8, e.description, query) != null;
                if (!matches) continue;

                // Search is informational and scans many entries at once;
                // one badly-signed entry shouldn't hide the rest of the
                // results, so it's skipped rather than aborting the search.
                self.verifySignature(repo, e) catch |err| {
                    log.warn("skipping '{s}' from '{s}': {s}", .{ e.name, repo.name, @errorName(err) });
                    continue;
                };

                try results.append(.{
                    .repo_name = repo.name,
                    .repo_url = repo.url,
                    .entry = try self.dupeEntry(e),
                });
            }
        }
        return results.toOwnedSlice();
    }

    /// Local cache path a repository package is downloaded to.
    pub fn cachedPackagePath(self: Manager, entry: index_mod.IndexEntry) ![]u8 {
        return std.fmt.allocPrint(self.allocator, "{s}/packages/{s}-{s}.zpkg", .{
            std.mem.trimRight(u8, self.config.cache_dir, "/"),
            entry.name,
            entry.version,
        });
    }

    /// True if a valid cached copy of `found` already exists. Verification
    /// streams the file rather than loading it, so checking a 2 GB cached
    /// package costs one chunk of RAM.
    pub fn isCached(self: Manager, found: Found) !bool {
        const dest = try self.cachedPackagePath(found.entry);
        defer self.allocator.free(dest);
        return checksum.verifyFile(dest, found.entry.checksum);
    }

    /// Ensures the package for `found` is present in the local cache and
    /// returns its path (caller frees). A cached copy whose checksum still
    /// verifies is reused instead of re-downloading (spec: cache rules).
    pub fn ensureDownloaded(self: Manager, found: Found) ![]u8 {
        const dest = try self.cachedPackagePath(found.entry);
        errdefer self.allocator.free(dest);

        if (checksum.verifyFile(dest, found.entry.checksum)) {
            log.debug("using cached {s}", .{dest});
            return dest;
        }

        var client = http.Client.init(self.allocator, self.config.download_retries);
        defer client.deinit();

        const url = try http.joinUrl(self.allocator, found.repo_url, found.entry.path);
        defer self.allocator.free(url);

        try client.fetchToFile(url, dest, found.entry.checksum, max_package_bytes);
        return dest;
    }

    /// Builds a download job for `found`, or null when a valid cached copy
    /// already exists. `dest_path` is allocated; caller frees it.
    pub fn downloadJob(self: Manager, found: Found) !?parallel.Job {
        const dest = try self.cachedPackagePath(found.entry);
        errdefer self.allocator.free(dest);

        if (checksum.verifyFile(dest, found.entry.checksum)) {
            self.allocator.free(dest);
            return null;
        }

        return parallel.Job{
            .url = try http.joinUrl(self.allocator, found.repo_url, found.entry.path),
            .dest_path = dest,
            .expected_sha256 = found.entry.checksum,
            .max_bytes = max_package_bytes,
        };
    }
};

/// gzip member header: 0x1f 0x8b, then the deflate method byte.
fn isGzip(data: []const u8) bool {
    return data.len >= 3 and data[0] == 0x1f and data[1] == 0x8b and data[2] == 0x08;
}

fn gunzip(allocator: std.mem.Allocator, data: []const u8) ![]u8 {
    var in = std.io.fixedBufferStream(data);
    var out = std.ArrayList(u8).init(allocator);
    errdefer out.deinit();
    std.compress.gzip.decompress(in.reader(), out.writer()) catch return error.InvalidIndex;
    return out.toOwnedSlice();
}

const dummy_checksum = "0" ** 64;

/// Writes a cached index straight to disk, so repository lookups can be
/// tested without a network or an HTTP server.
fn seedIndex(allocator: std.mem.Allocator, mgr: Manager, repo: Repository, idx: index_mod.Index) !void {
    const path = try mgr.cachedIndexPath(repo);
    defer allocator.free(path);
    if (std.fs.path.dirname(path)) |dir| try std.fs.cwd().makePath(dir);
    const json_text = try index_mod.toJson(allocator, idx);
    defer allocator.free(json_text);
    try std.fs.cwd().writeFile(.{ .sub_path = path, .data = json_text });
}

test "find locates a package in a cached index and reports its repository" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const tmp_path = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(tmp_path);

    var cfg = config_mod.default();
    cfg.cache_dir = tmp_path;

    const repos = [_]Repository{
        .{ .name = "main", .url = "https://repo.example.com" },
    };
    const mgr = Manager.init(allocator, cfg, &repos);

    try seedIndex(allocator, mgr, repos[0], .{ .packages = &.{
        .{ .name = "hello", .version = "1.0.0", .architecture = "x86_64", .path = "pool/hello.zpkg", .checksum = dummy_checksum, .description = "a greeting" },
    } });

    const found = (try mgr.find("hello")).?;
    defer mgr.freeFound(found);
    try std.testing.expectEqualStrings("main", found.repo_name);
    try std.testing.expectEqualStrings("1.0.0", found.entry.version);

    try std.testing.expectEqual(@as(?Found, null), try mgr.find("nonexistent"));
}

test "find skips repositories with no cached index instead of failing" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const tmp_path = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(tmp_path);

    var cfg = config_mod.default();
    cfg.cache_dir = tmp_path;

    const repos = [_]Repository{
        .{ .name = "never-updated", .url = "https://a.example.com" },
        .{ .name = "main", .url = "https://b.example.com" },
    };
    const mgr = Manager.init(allocator, cfg, &repos);

    try seedIndex(allocator, mgr, repos[1], .{ .packages = &.{
        .{ .name = "hello", .version = "2.0.0", .architecture = "x86_64", .path = "pool/hello.zpkg", .checksum = dummy_checksum },
    } });

    const found = (try mgr.find("hello")).?;
    defer mgr.freeFound(found);
    try std.testing.expectEqualStrings("main", found.repo_name);
}

test "search matches on name and description across repositories" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const tmp_path = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(tmp_path);

    var cfg = config_mod.default();
    cfg.cache_dir = tmp_path;

    const repos = [_]Repository{.{ .name = "main", .url = "https://repo.example.com" }};
    const mgr = Manager.init(allocator, cfg, &repos);

    try seedIndex(allocator, mgr, repos[0], .{ .packages = &.{
        .{ .name = "hello", .version = "1.0.0", .architecture = "x86_64", .path = "a.zpkg", .checksum = dummy_checksum, .description = "greeting tool" },
        .{ .name = "editor", .version = "3.0.0", .architecture = "x86_64", .path = "b.zpkg", .checksum = dummy_checksum, .description = "a text editor" },
        .{ .name = "unrelated", .version = "1.0.0", .architecture = "x86_64", .path = "c.zpkg", .checksum = dummy_checksum },
    } });

    const by_name = try mgr.search("hell");
    defer {
        for (by_name) |f| mgr.freeFound(f);
        allocator.free(by_name);
    }
    try std.testing.expectEqual(@as(usize, 1), by_name.len);
    try std.testing.expectEqualStrings("hello", by_name[0].entry.name);

    const by_desc = try mgr.search("text");
    defer {
        for (by_desc) |f| mgr.freeFound(f);
        allocator.free(by_desc);
    }
    try std.testing.expectEqual(@as(usize, 1), by_desc.len);
    try std.testing.expectEqualStrings("editor", by_desc[0].entry.name);

    const none = try mgr.search("zzzz");
    defer allocator.free(none);
    try std.testing.expectEqual(@as(usize, 0), none.len);
}

test "update with no repositories configured reports NoRepositories" {
    const allocator = std.testing.allocator;
    var cfg = config_mod.default();
    cfg.cache_dir = "/tmp/zdms-test-unused";
    const mgr = Manager.init(allocator, cfg, &.{});
    try std.testing.expectError(error.NoRepositories, mgr.update());
}

test "loadIndex reports IndexNotFetched before the first update" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const tmp_path = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(tmp_path);

    var cfg = config_mod.default();
    cfg.cache_dir = tmp_path;

    const repos = [_]Repository{.{ .name = "main", .url = "https://repo.example.com" }};
    const mgr = Manager.init(allocator, cfg, &repos);

    try std.testing.expectError(error.IndexNotFetched, mgr.loadIndex(repos[0]));
}

test "ensureDownloaded reuses a valid cached package without any network" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const tmp_path = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(tmp_path);

    var cfg = config_mod.default();
    cfg.cache_dir = tmp_path;

    const repos = [_]Repository{.{ .name = "main", .url = "https://repo.example.com" }};
    const mgr = Manager.init(allocator, cfg, &repos);

    const payload = "pretend this is a .zpkg";
    const hex = try checksum.sha256Hex(allocator, payload);
    defer allocator.free(hex);

    const entry = index_mod.IndexEntry{
        .name = "hello",
        .version = "1.0.0",
        .architecture = "x86_64",
        .path = "pool/hello.zpkg",
        .checksum = hex,
    };

    // Pre-populate the cache so no download is attempted.
    const cached = try mgr.cachedPackagePath(entry);
    defer allocator.free(cached);
    if (std.fs.path.dirname(cached)) |dir| try std.fs.cwd().makePath(dir);
    try std.fs.cwd().writeFile(.{ .sub_path = cached, .data = payload });

    const got = try mgr.ensureDownloaded(.{ .repo_name = "main", .repo_url = repos[0].url, .entry = entry });
    defer allocator.free(got);
    try std.testing.expectEqualStrings(cached, got);
}

test "isGzip detects the gzip magic and ignores plain JSON" {
    try std.testing.expect(isGzip(&[_]u8{ 0x1f, 0x8b, 0x08, 0x00 }));
    try std.testing.expect(!isGzip("{\"packages\":[]}"));
    try std.testing.expect(!isGzip(&[_]u8{0x1f}));
}

test "loadIndex transparently reads a gzip-compressed index" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const tmp_path = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(tmp_path);

    var cfg = config_mod.default();
    cfg.cache_dir = tmp_path;

    const repos = [_]Repository{.{ .name = "main", .url = "https://repo.example.com" }};
    const mgr = Manager.init(allocator, cfg, &repos);

    const idx = index_mod.Index{ .packages = &.{
        .{ .name = "hello", .version = "1.0.0", .architecture = "x86_64", .path = "a.zpkg", .checksum = dummy_checksum },
    } };
    const json_text = try index_mod.toJson(allocator, idx);
    defer allocator.free(json_text);

    var compressed = std.ArrayList(u8).init(allocator);
    defer compressed.deinit();
    var in = std.io.fixedBufferStream(json_text);
    try std.compress.gzip.compress(in.reader(), compressed.writer(), .{});

    const path = try mgr.cachedIndexPath(repos[0]);
    defer allocator.free(path);
    if (std.fs.path.dirname(path)) |dir| try std.fs.cwd().makePath(dir);
    try std.fs.cwd().writeFile(.{ .sub_path = path, .data = compressed.items });

    const parsed = try mgr.loadIndex(repos[0]);
    defer parsed.deinit();
    try std.testing.expectEqual(@as(usize, 1), parsed.value.packages.len);
    try std.testing.expectEqualStrings("hello", parsed.value.packages[0].name);
}

test "find only returns the entry matching config.architecture" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const tmp_path = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(tmp_path);

    var cfg = config_mod.default();
    cfg.cache_dir = tmp_path;
    cfg.architecture = "aarch64";

    const repos = [_]Repository{.{ .name = "main", .url = "https://repo.example.com" }};
    const mgr = Manager.init(allocator, cfg, &repos);

    try seedIndex(allocator, mgr, repos[0], .{ .packages = &.{
        .{ .name = "hello", .version = "1.0.0", .architecture = "x86_64", .path = "hello-x86_64.zpkg", .checksum = dummy_checksum },
        .{ .name = "hello", .version = "1.0.0", .architecture = "aarch64", .path = "hello-aarch64.zpkg", .checksum = dummy_checksum },
    } });

    const found = (try mgr.find("hello")).?;
    defer mgr.freeFound(found);
    try std.testing.expectEqualStrings("hello-aarch64.zpkg", found.entry.path);
}

test "find succeeds on a signed repository with a valid signature" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const tmp_path = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(tmp_path);

    const signed = try signature.signForTest(allocator, dummy_checksum);
    defer allocator.free(signed.public_key_hex);
    defer allocator.free(signed.signature_hex);

    var cfg = config_mod.default();
    cfg.cache_dir = tmp_path;

    const repos = [_]Repository{.{ .name = "main", .url = "https://repo.example.com", .public_key = signed.public_key_hex }};
    const mgr = Manager.init(allocator, cfg, &repos);

    try seedIndex(allocator, mgr, repos[0], .{ .packages = &.{
        .{ .name = "hello", .version = "1.0.0", .architecture = "x86_64", .path = "a.zpkg", .checksum = dummy_checksum, .signature = signed.signature_hex },
    } });

    const found = (try mgr.find("hello")).?;
    defer mgr.freeFound(found);
    try std.testing.expectEqualStrings("hello", found.entry.name);
}

test "find fails on a signed repository when the signature is missing or wrong" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const tmp_path = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(tmp_path);

    const signed = try signature.signForTest(allocator, dummy_checksum);
    defer allocator.free(signed.public_key_hex);
    defer allocator.free(signed.signature_hex);
    const other = try signature.signForTest(allocator, "something else");
    defer allocator.free(other.public_key_hex);
    defer allocator.free(other.signature_hex);

    var cfg = config_mod.default();
    cfg.cache_dir = tmp_path;

    const repos = [_]Repository{.{ .name = "main", .url = "https://repo.example.com", .public_key = signed.public_key_hex }};
    const mgr = Manager.init(allocator, cfg, &repos);

    try seedIndex(allocator, mgr, repos[0], .{ .packages = &.{
        .{ .name = "unsigned-entry", .version = "1.0.0", .architecture = "x86_64", .path = "a.zpkg", .checksum = dummy_checksum },
        .{ .name = "wrong-sig", .version = "1.0.0", .architecture = "x86_64", .path = "b.zpkg", .checksum = dummy_checksum, .signature = other.signature_hex },
    } });

    try std.testing.expectError(error.SignatureMissing, mgr.find("unsigned-entry"));
    try std.testing.expectError(error.SignatureInvalid, mgr.find("wrong-sig"));
}

test "search silently excludes entries that fail signature verification" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const tmp_path = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(tmp_path);

    const signed = try signature.signForTest(allocator, dummy_checksum);
    defer allocator.free(signed.public_key_hex);
    defer allocator.free(signed.signature_hex);

    var cfg = config_mod.default();
    cfg.cache_dir = tmp_path;

    const repos = [_]Repository{.{ .name = "main", .url = "https://repo.example.com", .public_key = signed.public_key_hex }};
    const mgr = Manager.init(allocator, cfg, &repos);

    try seedIndex(allocator, mgr, repos[0], .{ .packages = &.{
        .{ .name = "good", .version = "1.0.0", .architecture = "x86_64", .path = "a.zpkg", .checksum = dummy_checksum, .signature = signed.signature_hex },
        .{ .name = "bad", .version = "1.0.0", .architecture = "x86_64", .path = "b.zpkg", .checksum = dummy_checksum },
    } });

    const results = try mgr.search("");
    defer {
        for (results) |f| mgr.freeFound(f);
        allocator.free(results);
    }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("good", results[0].entry.name);
}

test "verifySignature is a no-op for an unsigned repository" {
    const cfg = config_mod.default();
    const repo = Repository{ .name = "main", .url = "https://repo.example.com" };
    const mgr = Manager.init(std.testing.allocator, cfg, &.{});
    try mgr.verifySignature(repo, .{ .name = "x", .version = "1.0.0", .architecture = "x86_64", .path = "x.zpkg", .checksum = dummy_checksum });
}
