//! Atomic-ish package transactions.
//!
//! Spec: "package operations should be atomic", prevent half-installed
//! packages / corrupted databases / partially completed upgrades,
//! "prepare changes before committing them", design for future rollback.
//!
//! Real package managers (dpkg, rpm, pacman) don't get atomicity by
//! undoing already-applied filesystem changes -- once a file is renamed
//! into `/usr/bin` there's no transactional filesystem to roll it back
//! with. They get it by making `commit` crash-safe and *resumable*: write
//! down exactly what's about to happen (the journal) before touching
//! anything real, then apply it in a way that's safe to run again from
//! any point if interrupted. That's the model here too.
//!
//!   prepare: stage new files under cache_dir/staging/, snapshot what a
//!            remove will delete, write the journal (atomically) -- no
//!            installed file or database entry has been touched yet.
//!   commit:  move staged files into place, write database entries,
//!            delete removed files, remove database entries, then delete
//!            the journal. Every step is safe to repeat, so a crash
//!            partway through commit is fixed by calling commit again
//!            (which `recover` does automatically).
//!
//! Nothing outside `prepare`+`commit` ever partially applies: either the
//! journal doesn't exist yet (nothing has started) or it does (everything
//! in it *will* end up applied, possibly after a `recover`). A single
//! journal file also serializes transactions -- `prepare` refuses to start
//! a second one while one is outstanding, rather than interleaving two.

const std = @import("std");
const config_mod = @import("config.zig");
const log = @import("log.zig");
const db_mod = @import("../database/db.zig");
const manifest_mod = @import("../package/manifest.zig");
const archive_mod = @import("../package/archive.zig");
const checksum_mod = @import("../package/checksum.zig");

/// Chunk size for `addInstallStreamed`'s reads -- matches the downloader
/// (`http.chunk_size`) so peak RAM during install is the same order of
/// magnitude as peak RAM during download, regardless of package size.
const stream_chunk_size: usize = 64 * 1024;

pub const PendingInstall = struct {
    name: []const u8,
    version: []const u8,
    architecture: []const u8,
    dependencies: []const manifest_mod.Dependency = &.{},
    /// Final, install_root-relative destination for each file. Parallel to
    /// nothing else -- the staged bytes live on disk at
    /// `<staging_dir>/<install-index>/<file-index>`, found by position
    /// rather than by name so no path-escaping from a hostile file name
    /// is possible.
    files: []const manifest_mod.FileEntry = &.{},
};

pub const PendingRemove = struct {
    name: []const u8,
    /// Snapshotted from the database at `prepare` time, not looked up
    /// again at `commit` time -- if the database entry is already gone
    /// (e.g. a resumed transaction that got partway through), commit
    /// still knows what files to clean up.
    files: []const manifest_mod.FileEntry = &.{},
};

const Journal = struct {
    installs: []const PendingInstall = &.{},
    removes: []const PendingRemove = &.{},
};

fn journalPath(allocator: std.mem.Allocator, config: config_mod.Config) ![]u8 {
    return std.fmt.allocPrint(allocator, "{s}/.journal.json", .{
        std.mem.trimRight(u8, config.database_path, "/"),
    });
}

fn stagingDir(allocator: std.mem.Allocator, config: config_mod.Config) ![]u8 {
    return std.fmt.allocPrint(allocator, "{s}/staging", .{
        std.mem.trimRight(u8, config.cache_dir, "/"),
    });
}

fn installedPath(allocator: std.mem.Allocator, config: config_mod.Config, rel_path: []const u8) ![]u8 {
    return std.fs.path.join(allocator, &.{ config.install_root, rel_path });
}

fn stagedFilePath(allocator: std.mem.Allocator, staging_dir: []const u8, install_index: usize, file_index: usize) ![]u8 {
    return std.fmt.allocPrint(allocator, "{s}/{d}/{d}", .{ staging_dir, install_index, file_index });
}

/// A transaction being built up: stage files, then `prepare` (write the
/// journal) and `commit` (apply it). Not thread-safe and not meant to
/// outlive a single CLI invocation.
pub const Transaction = struct {
    allocator: std.mem.Allocator,
    config: config_mod.Config,
    /// Owns every string/slice referenced by `installs`/`removes` -- every
    /// `add*` method copies its data in immediately, so nothing queued
    /// here depends on a caller keeping anything else alive.
    arena: std.heap.ArenaAllocator,
    installs: std.ArrayList(PendingInstall),
    removes: std.ArrayList(PendingRemove),

    pub fn init(allocator: std.mem.Allocator, config: config_mod.Config) Transaction {
        return .{
            .allocator = allocator,
            .config = config,
            .arena = std.heap.ArenaAllocator.init(allocator),
            .installs = std.ArrayList(PendingInstall).init(allocator),
            .removes = std.ArrayList(PendingRemove).init(allocator),
        };
    }

    pub fn deinit(self: *Transaction) void {
        self.arena.deinit();
        self.installs.deinit();
        self.removes.deinit();
    }

    fn dupeDependencies(a: std.mem.Allocator, deps: []const manifest_mod.Dependency) ![]const manifest_mod.Dependency {
        const out = try a.alloc(manifest_mod.Dependency, deps.len);
        for (deps, 0..) |d, i| {
            out[i] = .{
                .name = try a.dupe(u8, d.name),
                .version_constraint = try a.dupe(u8, d.version_constraint),
            };
        }
        return out;
    }

    fn dupeFileEntries(a: std.mem.Allocator, files: []const manifest_mod.FileEntry) ![]const manifest_mod.FileEntry {
        const out = try a.alloc(manifest_mod.FileEntry, files.len);
        for (files, 0..) |f, i| {
            out[i] = .{
                .path = try a.dupe(u8, f.path),
                .size = f.size,
                .sha256 = try a.dupe(u8, f.sha256),
            };
        }
        return out;
    }

    /// Stages `files` (already-verified, already-in-memory package
    /// contents) to disk and queues the install. Nothing under
    /// `config.install_root` is touched yet -- that only happens in
    /// `commit`. For a package too large to hold in memory, use
    /// `addInstallStreamed` instead.
    pub fn addInstall(
        self: *Transaction,
        name: []const u8,
        version: []const u8,
        architecture: []const u8,
        dependencies: []const manifest_mod.Dependency,
        files: []const manifest_mod.FileEntry,
        contents: []const []const u8,
    ) !void {
        std.debug.assert(files.len == contents.len);

        const staging = try stagingDir(self.allocator, self.config);
        defer self.allocator.free(staging);

        const install_index = self.installs.items.len;
        for (contents, 0..) |content, file_index| {
            const path = try stagedFilePath(self.allocator, staging, install_index, file_index);
            defer self.allocator.free(path);
            if (std.fs.path.dirname(path)) |dir| try std.fs.cwd().makePath(dir);
            try std.fs.cwd().writeFile(.{ .sub_path = path, .data = content });
        }

        const a = self.arena.allocator();
        try self.installs.append(.{
            .name = try a.dupe(u8, name),
            .version = try a.dupe(u8, version),
            .architecture = try a.dupe(u8, architecture),
            .dependencies = try dupeDependencies(a, dependencies),
            .files = try dupeFileEntries(a, files),
        });
    }

    fn readExact(file: std.fs.File, buf: []u8) !void {
        file.reader().readNoEof(buf) catch |e| switch (e) {
            error.EndOfStream => return error.CorruptArchive,
            else => return e,
        };
    }

    fn readU32(file: std.fs.File) !u32 {
        var buf: [4]u8 = undefined;
        try readExact(file, &buf);
        return std.mem.readInt(u32, &buf, .little);
    }

    fn readU64(file: std.fs.File) !u64 {
        var buf: [8]u8 = undefined;
        try readExact(file, &buf);
        return std.mem.readInt(u64, &buf, .little);
    }

    /// Reads a `.zpkg` in fixed `stream_chunk_size` chunks, hashing and
    /// writing each file's content straight to its staged path as it's
    /// read, then verifies the accumulated checksum against the
    /// manifest's before ever queuing the install (Phase 9: peak RAM
    /// during install is one chunk, not the whole package, the same way
    /// `http.fetchToFile` already downloads). Returns the manifest
    /// (borrowing from this Transaction's arena, so it stays valid for as
    /// long as the Transaction does) so the caller can check
    /// `AlreadyInstalled` and log without a second read of the file.
    pub fn addInstallStreamed(self: *Transaction, zpkg_path: []const u8) !manifest_mod.Manifest {
        var file = try std.fs.cwd().openFile(zpkg_path, .{});
        defer file.close();

        var magic_buf: [archive_mod.magic.len]u8 = undefined;
        try readExact(file, &magic_buf);
        if (!std.mem.eql(u8, &magic_buf, archive_mod.magic)) return error.CorruptArchive;

        var version_buf: [1]u8 = undefined;
        try readExact(file, &version_buf);
        if (version_buf[0] != archive_mod.format_version) return error.UnsupportedFormatVersion;

        const manifest_len = try readU32(file);
        const manifest_json = try self.allocator.alloc(u8, manifest_len);
        defer self.allocator.free(manifest_json);
        try readExact(file, manifest_json);

        var parsed = try manifest_mod.fromJson(self.allocator, manifest_json);
        defer parsed.deinit();
        try parsed.value.validate();
        const m = parsed.value;

        const file_count = try readU32(file);

        const staging = try stagingDir(self.allocator, self.config);
        defer self.allocator.free(staging);
        const install_index = self.installs.items.len;

        var hasher = std.crypto.hash.sha2.Sha256.init(.{});
        var buf: [stream_chunk_size]u8 = undefined;

        var files_written: usize = 0;
        errdefer {
            for (0..files_written) |fi| {
                const p = stagedFilePath(self.allocator, staging, install_index, fi) catch continue;
                defer self.allocator.free(p);
                std.fs.cwd().deleteFile(p) catch {};
            }
        }

        for (0..file_count) |file_index| {
            const path_len = try readU32(file);
            // The path text itself isn't needed here -- the destination
            // path used at commit time comes from the manifest's own
            // `files` list, not from re-deriving it from the archive.
            const path_buf = try self.allocator.alloc(u8, path_len);
            defer self.allocator.free(path_buf);
            try readExact(file, path_buf);

            const content_len = try readU64(file);

            const staged_path = try stagedFilePath(self.allocator, staging, install_index, file_index);
            defer self.allocator.free(staged_path);
            if (std.fs.path.dirname(staged_path)) |dir| try std.fs.cwd().makePath(dir);
            var staged_file = try std.fs.cwd().createFile(staged_path, .{ .truncate = true });
            defer staged_file.close();

            var remaining: u64 = content_len;
            while (remaining > 0) {
                const want: usize = @intCast(@min(remaining, buf.len));
                try readExact(file, buf[0..want]);
                hasher.update(buf[0..want]);
                try staged_file.writeAll(buf[0..want]);
                remaining -= want;
            }
            files_written += 1;
        }

        var digest: [32]u8 = undefined;
        hasher.final(&digest);
        var hex: [64]u8 = undefined;
        checksum_mod.hexEncode(&digest, &hex);
        if (!std.mem.eql(u8, &hex, m.checksum)) return error.ChecksumMismatch;

        const a = self.arena.allocator();
        const owned = PendingInstall{
            .name = try a.dupe(u8, m.name),
            .version = try a.dupe(u8, m.version),
            .architecture = try a.dupe(u8, m.architecture),
            .dependencies = try dupeDependencies(a, m.dependencies),
            .files = try dupeFileEntries(a, m.files),
        };
        try self.installs.append(owned);

        // `m.checksum` (and everything else in `parsed`) dies with
        // `parsed.deinit()` at this function's exit -- return only fields
        // duped into this Transaction's own arena, which outlives it.
        return .{
            .name = owned.name,
            .version = owned.version,
            .architecture = owned.architecture,
            .dependencies = owned.dependencies,
            .checksum = try a.dupe(u8, m.checksum),
            .files = owned.files,
        };
    }

    /// Removes the most recently added install (its staged files and its
    /// queue entry) without touching anything else. For the case where
    /// `addInstallStreamed` already staged a package before the caller
    /// discovers it shouldn't be installed after all (e.g.
    /// `error.AlreadyInstalled`) -- cheaper than aborting the whole
    /// Transaction when other installs/removes may already be queued.
    pub fn discardLastInstall(self: *Transaction) void {
        if (self.installs.items.len == 0) return;
        const install_index = self.installs.items.len - 1;
        const inst = self.installs.items[install_index];
        self.installs.shrinkRetainingCapacity(install_index);

        const staging = stagingDir(self.allocator, self.config) catch return;
        defer self.allocator.free(staging);
        for (inst.files, 0..) |_, file_index| {
            const p = stagedFilePath(self.allocator, staging, install_index, file_index) catch continue;
            defer self.allocator.free(p);
            std.fs.cwd().deleteFile(p) catch {};
        }
    }

    /// Queues a removal, snapshotting `name`'s current file list from the
    /// database so `commit` knows what to delete even if run later, after
    /// something else has already changed the database.
    pub fn addRemove(self: *Transaction, name: []const u8) !void {
        const db = db_mod.Database.init(self.config.database_path);
        const parsed = (try db.get(self.allocator, name)) orelse return error.NotInstalled;
        defer parsed.deinit();

        const a = self.arena.allocator();
        try self.removes.append(.{
            .name = try a.dupe(u8, name),
            .files = try dupeFileEntries(a, parsed.value.files),
        });
    }

    /// Writes the journal describing every staged install and queued
    /// remove, atomically (temp file + rename). Fails with
    /// `error.TransactionInProgress` if one is already outstanding --
    /// call `recover` first.
    pub fn prepare(self: Transaction) !void {
        const path = try journalPath(self.allocator, self.config);
        defer self.allocator.free(path);

        const already_exists = blk: {
            std.fs.cwd().access(path, .{}) catch |e| switch (e) {
                error.FileNotFound => break :blk false,
                else => return e,
            };
            break :blk true;
        };
        if (already_exists) return error.TransactionInProgress;

        try std.fs.cwd().makePath(self.config.database_path);

        const journal = Journal{ .installs = self.installs.items, .removes = self.removes.items };
        const json_text = try std.json.stringifyAlloc(self.allocator, journal, .{});
        defer self.allocator.free(json_text);

        const tmp_path = try std.fmt.allocPrint(self.allocator, "{s}.tmp", .{path});
        defer self.allocator.free(tmp_path);
        try std.fs.cwd().writeFile(.{ .sub_path = tmp_path, .data = json_text });
        try std.fs.cwd().rename(tmp_path, path);
    }

    /// Applies the journal this transaction just wrote and deletes it.
    pub fn commit(self: Transaction) !void {
        try applyJournal(self.allocator, self.config, .{ .installs = self.installs.items, .removes = self.removes.items });
        try deleteJournalAndStaging(self.allocator, self.config);
    }
};

/// If a journal from an interrupted transaction exists, finishes applying
/// it. Safe to call unconditionally (including when nothing is pending) --
/// callers do this once at the start of any command that installs,
/// removes, or upgrades, so an interruption is fixed by the very next
/// invocation rather than requiring a separate repair step.
pub fn recover(allocator: std.mem.Allocator, config: config_mod.Config) !void {
    const path = try journalPath(allocator, config);
    defer allocator.free(path);

    const bytes = std.fs.cwd().readFileAlloc(allocator, path, 64 * 1024 * 1024) catch |e| switch (e) {
        error.FileNotFound => return,
        else => return e,
    };
    defer allocator.free(bytes);

    // .alloc_always: `bytes` is freed by the defer below; the journal's
    // strings must not point into it.
    const parsed = std.json.parseFromSlice(Journal, allocator, bytes, .{ .allocate = .alloc_always }) catch {
        log.err("journal at {s} is corrupt and cannot be replayed automatically", .{path});
        return error.InvalidValue;
    };
    defer parsed.deinit();

    log.warn("resuming an interrupted transaction ({d} install(s), {d} removal(s))", .{
        parsed.value.installs.len,
        parsed.value.removes.len,
    });
    try applyJournal(allocator, config, parsed.value);
    try deleteJournalAndStaging(allocator, config);
    log.info("interrupted transaction recovered", .{});
}

fn applyJournal(allocator: std.mem.Allocator, config: config_mod.Config, journal: Journal) !void {
    const staging = try stagingDir(allocator, config);
    defer allocator.free(staging);

    // Removes before installs: for a combined replace (upgrade removes the
    // old version and installs the new one under the same name in one
    // transaction), doing installs first would let the remove that follows
    // delete the entry/files the install just wrote. Order between
    // unrelated packages doesn't matter, so this is always safe.
    for (journal.removes) |rem| {
        for (rem.files) |f| {
            const dest = try installedPath(allocator, config, f.path);
            defer allocator.free(dest);
            std.fs.cwd().deleteFile(dest) catch |e| switch (e) {
                error.FileNotFound => {},
                else => log.warn("could not remove {s}: {s}", .{ dest, @errorName(e) }),
            };
        }

        const db = db_mod.Database.init(config.database_path);
        db.remove(allocator, rem.name) catch |e| switch (e) {
            error.NotInstalled => {}, // already removed by a prior attempt
            else => return e,
        };
    }

    for (journal.installs, 0..) |inst, install_index| {
        for (inst.files, 0..) |f, file_index| {
            const staged = try stagedFilePath(allocator, staging, install_index, file_index);
            defer allocator.free(staged);
            const dest = try installedPath(allocator, config, f.path);
            defer allocator.free(dest);

            if (std.fs.path.dirname(dest)) |dir| try std.fs.cwd().makePath(dir);

            // Idempotent: if this is a resumed commit and the file is
            // already in place (staged file gone, dest exists), that's
            // success, not a failure to retry.
            std.fs.cwd().rename(staged, dest) catch |e| {
                if (e == error.FileNotFound) {
                    std.fs.cwd().access(dest, .{}) catch return e;
                } else {
                    // Cross-device (EXDEV) or another transient rename
                    // failure: fall back to copy+delete rather than
                    // naming the platform-specific error exactly.
                    copyAndDelete(staged, dest) catch return e;
                }
            };
        }

        const db = db_mod.Database.init(config.database_path);
        try db.put(allocator, .{
            .name = inst.name,
            .version = inst.version,
            .architecture = inst.architecture,
            .dependencies = inst.dependencies,
            .files = inst.files,
        });
    }
}

fn copyAndDelete(src: []const u8, dest: []const u8) !void {
    try std.fs.cwd().copyFile(src, std.fs.cwd(), dest, .{});
    std.fs.cwd().deleteFile(src) catch {};
}

fn deleteJournalAndStaging(allocator: std.mem.Allocator, config: config_mod.Config) !void {
    const path = try journalPath(allocator, config);
    defer allocator.free(path);
    std.fs.cwd().deleteFile(path) catch |e| switch (e) {
        error.FileNotFound => {},
        else => return e,
    };

    const staging = try stagingDir(allocator, config);
    defer allocator.free(staging);
    std.fs.cwd().deleteTree(staging) catch {};
}

// --- tests -----------------------------------------------------------

fn tmpConfig(allocator: std.mem.Allocator, root: []const u8, out: *[3][]u8) !config_mod.Config {
    out[0] = try std.fmt.allocPrint(allocator, "{s}/db", .{root});
    out[1] = try std.fmt.allocPrint(allocator, "{s}/cache", .{root});
    out[2] = try std.fmt.allocPrint(allocator, "{s}/root", .{root});
    var cfg = config_mod.default();
    cfg.database_path = out[0];
    cfg.cache_dir = out[1];
    cfg.install_root = out[2];
    return cfg;
}

test "prepare then commit installs a package and writes its database entry" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(root);

    var paths: [3][]u8 = undefined;
    const cfg = try tmpConfig(allocator, root, &paths);
    defer for (paths) |p| allocator.free(p);

    var txn = Transaction.init(allocator, cfg);
    defer txn.deinit();

    try txn.addInstall(
        "hello",
        "1.0.0",
        "x86_64",
        &.{},
        &.{.{ .path = "bin/hello", .size = 5, .sha256 = "abc" }},
        &.{"hello"},
    );

    try txn.prepare();
    try txn.commit();

    const installed_file = try std.fmt.allocPrint(allocator, "{s}/bin/hello", .{paths[2]});
    defer allocator.free(installed_file);
    const content = try std.fs.cwd().readFileAlloc(allocator, installed_file, 1024);
    defer allocator.free(content);
    try std.testing.expectEqualStrings("hello", content);

    const db = db_mod.Database.init(paths[0]);
    try std.testing.expect(try db.isInstalled(allocator, "hello"));
}

test "a second prepare while one is outstanding fails" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(root);

    var paths: [3][]u8 = undefined;
    const cfg = try tmpConfig(allocator, root, &paths);
    defer for (paths) |p| allocator.free(p);

    var txn1 = Transaction.init(allocator, cfg);
    defer txn1.deinit();
    try txn1.addInstall("a", "1.0.0", "x86_64", &.{}, &.{.{ .path = "a", .size = 1, .sha256 = "x" }}, &.{"a"});
    try txn1.prepare();

    var txn2 = Transaction.init(allocator, cfg);
    defer txn2.deinit();
    try txn2.addInstall("b", "1.0.0", "x86_64", &.{}, &.{.{ .path = "b", .size = 1, .sha256 = "y" }}, &.{"b"});
    try std.testing.expectError(error.TransactionInProgress, txn2.prepare());

    try txn1.commit();
}

test "recover finishes a journal left behind by an interrupted commit" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(root);

    var paths: [3][]u8 = undefined;
    const cfg = try tmpConfig(allocator, root, &paths);
    defer for (paths) |p| allocator.free(p);

    var txn = Transaction.init(allocator, cfg);
    defer txn.deinit();
    try txn.addInstall(
        "hello",
        "1.0.0",
        "x86_64",
        &.{},
        &.{.{ .path = "bin/hello", .size = 2, .sha256 = "hi" }},
        &.{"hi"},
    );
    try txn.prepare();

    const db = db_mod.Database.init(paths[0]);
    try std.testing.expect(!try db.isInstalled(allocator, "hello"));

    try recover(allocator, cfg);

    try std.testing.expect(try db.isInstalled(allocator, "hello"));
    const installed_file = try std.fmt.allocPrint(allocator, "{s}/bin/hello", .{paths[2]});
    defer allocator.free(installed_file);
    try std.fs.cwd().access(installed_file, .{});

    try recover(allocator, cfg);
}

test "recover is a no-op when there is nothing to recover" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(root);

    var paths: [3][]u8 = undefined;
    const cfg = try tmpConfig(allocator, root, &paths);
    defer for (paths) |p| allocator.free(p);

    try recover(allocator, cfg);
}

test "a combined transaction removes the old version and installs the new one together" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(root);

    var paths: [3][]u8 = undefined;
    const cfg = try tmpConfig(allocator, root, &paths);
    defer for (paths) |p| allocator.free(p);

    var setup = Transaction.init(allocator, cfg);
    defer setup.deinit();
    try setup.addInstall("hello", "1.0.0", "x86_64", &.{}, &.{.{ .path = "bin/hello", .size = 2, .sha256 = "v1" }}, &.{"v1"});
    try setup.prepare();
    try setup.commit();

    var upgrade = Transaction.init(allocator, cfg);
    defer upgrade.deinit();
    try upgrade.addRemove("hello");
    try upgrade.addInstall("hello", "2.0.0", "x86_64", &.{}, &.{.{ .path = "bin/hello", .size = 2, .sha256 = "v2" }}, &.{"v2"});
    try upgrade.prepare();
    try upgrade.commit();

    const db = db_mod.Database.init(paths[0]);
    const parsed = (try db.get(allocator, "hello")).?;
    defer parsed.deinit();
    try std.testing.expectEqualStrings("2.0.0", parsed.value.version);

    const installed_file = try std.fmt.allocPrint(allocator, "{s}/bin/hello", .{paths[2]});
    defer allocator.free(installed_file);
    const content = try std.fs.cwd().readFileAlloc(allocator, installed_file, 1024);
    defer allocator.free(content);
    try std.testing.expectEqualStrings("v2", content);
}

test "addInstallStreamed installs a package spanning multiple read chunks" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(root);

    var paths: [3][]u8 = undefined;
    const cfg = try tmpConfig(allocator, root, &paths);
    defer for (paths) |p| allocator.free(p);

    // Bigger than stream_chunk_size (64 KiB) so the read loop inside
    // addInstallStreamed actually iterates more than once.
    const payload = try allocator.alloc(u8, stream_chunk_size * 2 + 777);
    defer allocator.free(payload);
    for (payload, 0..) |*b, i| b.* = @truncate(i);

    const package_mod = @import("../package/package.zig");
    const zpkg_bytes = try package_mod.create(
        allocator,
        .{ .name = "bigpkg", .version = "1.0.0", .architecture = "x86_64" },
        &.{.{ .path = "bin/bigpkg", .content = payload }},
    );
    defer allocator.free(zpkg_bytes);

    const zpkg_path = try std.fmt.allocPrint(allocator, "{s}/bigpkg.zpkg", .{root});
    defer allocator.free(zpkg_path);
    try std.fs.cwd().writeFile(.{ .sub_path = zpkg_path, .data = zpkg_bytes });

    var txn = Transaction.init(allocator, cfg);
    defer txn.deinit();
    const m = try txn.addInstallStreamed(zpkg_path);
    try std.testing.expectEqualStrings("bigpkg", m.name);

    try txn.prepare();
    try txn.commit();

    const installed_file = try std.fmt.allocPrint(allocator, "{s}/bin/bigpkg", .{paths[2]});
    defer allocator.free(installed_file);
    const written = try std.fs.cwd().readFileAlloc(allocator, installed_file, payload.len + 1024);
    defer allocator.free(written);
    try std.testing.expectEqualSlices(u8, payload, written);
}

test "addInstallStreamed rejects a corrupted package and stages nothing" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(root);

    var paths: [3][]u8 = undefined;
    const cfg = try tmpConfig(allocator, root, &paths);
    defer for (paths) |p| allocator.free(p);

    const package_mod = @import("../package/package.zig");
    const zpkg_bytes = try package_mod.create(
        allocator,
        .{ .name = "hello", .version = "1.0.0", .architecture = "x86_64" },
        &.{.{ .path = "bin/hello", .content = "original content" }},
    );
    defer allocator.free(zpkg_bytes);

    // Flip the last byte (inside the file content, well past the header).
    const tampered = try allocator.dupe(u8, zpkg_bytes);
    defer allocator.free(tampered);
    tampered[tampered.len - 1] ^= 0xFF;

    const zpkg_path = try std.fmt.allocPrint(allocator, "{s}/hello.zpkg", .{root});
    defer allocator.free(zpkg_path);
    try std.fs.cwd().writeFile(.{ .sub_path = zpkg_path, .data = tampered });

    var txn = Transaction.init(allocator, cfg);
    defer txn.deinit();
    try std.testing.expectError(error.ChecksumMismatch, txn.addInstallStreamed(zpkg_path));
    // Failure must not leave a queued install behind.
    try std.testing.expectEqual(@as(usize, 0), txn.installs.items.len);
}

test "install() discards a redundant install attempt without corrupting the database" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(root);

    var paths: [3][]u8 = undefined;
    const cfg = try tmpConfig(allocator, root, &paths);
    defer for (paths) |p| allocator.free(p);

    const package_mod = @import("../package/package.zig");
    const install_mod = @import("install.zig");
    const zpkg_bytes = try package_mod.create(
        allocator,
        .{ .name = "hello", .version = "1.0.0", .architecture = "x86_64" },
        &.{.{ .path = "bin/hello", .content = "hi" }},
    );
    defer allocator.free(zpkg_bytes);

    const zpkg_path = try std.fmt.allocPrint(allocator, "{s}/hello.zpkg", .{root});
    defer allocator.free(zpkg_path);
    try std.fs.cwd().writeFile(.{ .sub_path = zpkg_path, .data = zpkg_bytes });

    try install_mod.install(allocator, cfg, zpkg_path);
    try std.testing.expectError(error.AlreadyInstalled, install_mod.install(allocator, cfg, zpkg_path));

    const db = db_mod.Database.init(paths[0]);
    const parsed = (try db.get(allocator, "hello")).?;
    defer parsed.deinit();
    try std.testing.expectEqualStrings("1.0.0", parsed.value.version);
}
