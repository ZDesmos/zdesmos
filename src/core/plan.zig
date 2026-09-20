//! Bridges the repository layer and the local database to the resolver,
//! then executes a resolved plan.
//!
//! The resolver is deliberately ignorant of both -- this module is where
//! `Candidate`s are sourced from cached repository indexes and where the
//! local database supplies "already installed".

const std = @import("std");
const config_mod = @import("config.zig");
const log = @import("log.zig");
const install_mod = @import("install.zig");
const transaction_mod = @import("transaction.zig");
const package_mod = @import("../package/package.zig");
const db_mod = @import("../database/db.zig");
const index_mod = @import("../repository/index.zig");
const repository = @import("../repository/repository.zig");
const parallel = @import("../downloader/parallel.zig");
const resolver = @import("../resolver/resolver.zig");
const version_mod = @import("../resolver/version.zig");

/// Snapshot of every candidate across cached indexes, plus every installed
/// package, in a form the resolver can query without touching disk again.
pub const Context = struct {
    allocator: std.mem.Allocator,
    arena: std.heap.ArenaAllocator,
    candidates: []resolver.Candidate,
    installed: []resolver.Candidate,
    /// Repository each candidate came from, parallel to `candidates`.
    sources: []repository.Found,

    pub fn deinit(self: *Context) void {
        self.arena.deinit();
    }

    fn lookup(ctx: *const anyopaque, name: []const u8) ?resolver.Candidate {
        const self: *const Context = @ptrCast(@alignCast(ctx));
        for (self.candidates) |c| {
            if (std.mem.eql(u8, c.name, name)) return c;
        }
        return null;
    }

    fn installedLookup(ctx: *const anyopaque, name: []const u8) ?resolver.Candidate {
        const self: *const Context = @ptrCast(@alignCast(ctx));
        for (self.installed) |c| {
            if (std.mem.eql(u8, c.name, name)) return c;
        }
        return null;
    }

    pub fn provider(self: *const Context) resolver.Provider {
        return .{ .ctx = self, .lookupFn = lookup, .installedFn = installedLookup };
    }

    /// The repository entry a planned candidate came from, for download.
    pub fn sourceOf(self: Context, name: []const u8) ?repository.Found {
        for (self.candidates, self.sources) |c, src| {
            if (std.mem.eql(u8, c.name, name)) return src;
        }
        return null;
    }
};

/// Builds a resolution context from cached repository indexes and the
/// local database. Everything is copied into an arena owned by the
/// returned Context, so nothing borrows from transient parses.
pub fn buildContext(
    allocator: std.mem.Allocator,
    config: config_mod.Config,
    mgr: repository.Manager,
) !Context {
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const a = arena.allocator();

    var candidates = std.ArrayList(resolver.Candidate).init(a);
    var sources = std.ArrayList(repository.Found).init(a);

    for (mgr.repositories) |repo| {
        if (!repo.enabled) continue;
        const parsed = mgr.loadIndex(repo) catch continue;
        defer parsed.deinit();

        for (parsed.value.packages) |e| {
            // Only the configured architecture -- matches Manager.find/search,
            // so a plan never resolves a dependency it can't actually install.
            if (!std.mem.eql(u8, e.architecture, config.architecture)) continue;

            // Same policy as Manager.find/search: a dependency that fails
            // its repository's signing check is excluded from what the
            // resolver can see at all, rather than being resolved and
            // failing later at install time.
            mgr.verifySignature(repo, e) catch |err| {
                log.warn("excluding '{s}' from '{s}': {s}", .{ e.name, repo.name, @errorName(err) });
                continue;
            };

            // First repository listing a name wins, matching `find()`.
            var already = false;
            for (candidates.items) |c| {
                if (std.mem.eql(u8, c.name, e.name)) already = true;
            }
            if (already) continue;

            const entry = index_mod.IndexEntry{
                .name = try a.dupe(u8, e.name),
                .version = try a.dupe(u8, e.version),
                .architecture = try a.dupe(u8, e.architecture),
                .path = try a.dupe(u8, e.path),
                .checksum = try a.dupe(u8, e.checksum),
                .size = e.size,
                .dependencies = try dupeDeps(a, e.dependencies),
                .description = try a.dupe(u8, e.description),
            };
            try candidates.append(.{
                .name = entry.name,
                .version = entry.version,
                .dependencies = entry.dependencies,
            });
            try sources.append(.{
                .repo_name = try a.dupe(u8, repo.name),
                .repo_url = try a.dupe(u8, repo.url),
                .entry = entry,
            });
        }
    }

    var installed = std.ArrayList(resolver.Candidate).init(a);
    const db = db_mod.Database.init(config.database_path);
    const names = db.list(allocator) catch &[_][]const u8{};
    defer {
        for (names) |n| allocator.free(n);
        allocator.free(names);
    }
    for (names) |n| {
        const parsed = (db.get(allocator, n) catch continue) orelse continue;
        defer parsed.deinit();
        try installed.append(.{
            .name = try a.dupe(u8, parsed.value.name),
            .version = try a.dupe(u8, parsed.value.version),
            .dependencies = try dupeDeps(a, parsed.value.dependencies),
        });
    }

    return .{
        .allocator = allocator,
        .arena = arena,
        .candidates = try candidates.toOwnedSlice(),
        .installed = try installed.toOwnedSlice(),
        .sources = try sources.toOwnedSlice(),
    };
}

fn dupeDeps(a: std.mem.Allocator, deps: []const @import("../package/manifest.zig").Dependency) ![]const @import("../package/manifest.zig").Dependency {
    const Dependency = @import("../package/manifest.zig").Dependency;
    const out = try a.alloc(Dependency, deps.len);
    for (deps, 0..) |d, i| {
        out[i] = .{
            .name = try a.dupe(u8, d.name),
            .version_constraint = try a.dupe(u8, d.version_constraint),
        };
    }
    return out;
}

/// Downloads every package in `plan` with bounded concurrency, then
/// installs the whole plan (plus any `removes`) as a single Phase 8
/// transaction: staged, journaled, and committed together, so an upgrade
/// that replaces old versions with new ones never leaves neither in place.
///
/// Download and transaction are separated on purpose: downloads
/// parallelize safely, the transaction must stage everything before
/// committing anything. It also means a network failure aborts before
/// anything has been written to the system.
pub fn execute(
    allocator: std.mem.Allocator,
    config: config_mod.Config,
    mgr: repository.Manager,
    ctx: Context,
    plan: resolver.Plan,
    removes: []const []const u8,
) !void {
    try transaction_mod.recover(allocator, config);
    try prefetch(allocator, config, mgr, ctx, plan);

    const opened_list = try allocator.alloc(package_mod.Opened, plan.order.len);
    var opened_count: usize = 0;
    defer {
        for (opened_list[0..opened_count]) |*o| o.deinit();
        allocator.free(opened_list);
    }

    var txn = transaction_mod.Transaction.init(allocator, config);
    defer txn.deinit();

    for (removes) |name| {
        txn.addRemove(name) catch |e| switch (e) {
            // Already gone (e.g. listed twice) isn't a failure to
            // upgrade the rest.
            error.NotInstalled => continue,
            else => return e,
        };
    }

    for (plan.order, 0..) |candidate, i| {
        const found = ctx.sourceOf(candidate.name) orelse return error.PackageNotFound;
        const cached_path = try mgr.ensureDownloaded(found);
        defer allocator.free(cached_path);

        const bytes = try std.fs.cwd().readFileAlloc(allocator, cached_path, install_mod.max_zpkg_bytes);
        defer allocator.free(bytes);

        opened_list[i] = try package_mod.open(allocator, bytes);
        opened_count += 1;
        const m = opened_list[i].manifest();

        const contents = try allocator.alloc([]const u8, opened_list[i].files.len);
        defer allocator.free(contents);
        for (opened_list[i].files, 0..) |f, fi| contents[fi] = f.content;

        try txn.addInstall(m.name, m.version, m.architecture, m.dependencies, m.files, contents);
    }

    if (plan.order.len == 0 and removes.len == 0) return;

    try txn.prepare();
    try txn.commit();
}

/// Downloads everything the plan needs that isn't already validly cached,
/// at most `config.max_parallel_downloads` at a time.
fn prefetch(
    allocator: std.mem.Allocator,
    config: config_mod.Config,
    mgr: repository.Manager,
    ctx: Context,
    plan: resolver.Plan,
) !void {
    var jobs = std.ArrayList(parallel.Job).init(allocator);
    defer {
        for (jobs.items) |j| {
            allocator.free(j.url);
            allocator.free(j.dest_path);
        }
        jobs.deinit();
    }
    // Parallel to jobs: which package each job is for, so a failure can
    // name the package rather than a URL.
    var names = std.ArrayList([]const u8).init(allocator);
    defer names.deinit();

    for (plan.order) |candidate| {
        const found = ctx.sourceOf(candidate.name) orelse return error.PackageNotFound;
        if (try mgr.downloadJob(found)) |job| {
            try jobs.append(job);
            try names.append(candidate.name);
        }
    }

    if (jobs.items.len == 0) return;

    log.info("downloading {d} package(s)", .{jobs.items.len});
    const failures = try parallel.runAll(
        allocator,
        jobs.items,
        config.max_parallel_downloads,
        config.download_retries,
    );

    if (failures > 0) {
        for (jobs.items, names.items) |job, name| {
            if (job.err) |e| log.err("failed to download {s}: {s}", .{ name, @errorName(e) });
        }
        return error.RequestFailed;
    }
}

/// Names of installed packages whose repository offers a strictly newer
/// version. Caller owns the slice (strings borrow from `ctx`).
pub fn outdated(allocator: std.mem.Allocator, ctx: Context) ![][]const u8 {
    var out = std.ArrayList([]const u8).init(allocator);
    errdefer out.deinit();

    for (ctx.installed) |inst| {
        for (ctx.candidates) |cand| {
            if (!std.mem.eql(u8, cand.name, inst.name)) continue;
            const installed_v = version_mod.Version.parse(inst.version) catch continue;
            const available_v = version_mod.Version.parse(cand.version) catch continue;
            if (available_v.order(installed_v) == .gt) try out.append(cand.name);
            break;
        }
    }
    return out.toOwnedSlice();
}

// --- tests -----------------------------------------------------------

const dummy_checksum = "0" ** 64;

fn seedIndexFile(allocator: std.mem.Allocator, mgr: repository.Manager, repo: repository.Repository, idx: index_mod.Index) !void {
    const path = try mgr.cachedIndexPath(repo);
    defer allocator.free(path);
    if (std.fs.path.dirname(path)) |dir| try std.fs.cwd().makePath(dir);
    const json_text = try index_mod.toJson(allocator, idx);
    defer allocator.free(json_text);
    try std.fs.cwd().writeFile(.{ .sub_path = path, .data = json_text });
}

test "buildContext exposes repository candidates with their dependencies" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const tmp_path = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(tmp_path);

    const cache_dir = try std.fmt.allocPrint(allocator, "{s}/cache", .{tmp_path});
    defer allocator.free(cache_dir);
    const db_path = try std.fmt.allocPrint(allocator, "{s}/db", .{tmp_path});
    defer allocator.free(db_path);

    var cfg = config_mod.default();
    cfg.cache_dir = cache_dir;
    cfg.database_path = db_path;

    const repos = [_]repository.Repository{.{ .name = "main", .url = "https://repo.example.com" }};
    const mgr = repository.Manager.init(allocator, cfg, &repos);

    try seedIndexFile(allocator, mgr, repos[0], .{ .packages = &.{
        .{ .name = "app", .version = "1.0.0", .architecture = "x86_64", .path = "app.zpkg", .checksum = dummy_checksum, .dependencies = &.{.{ .name = "lib", .version_constraint = ">=1.0.0" }} },
        .{ .name = "lib", .version = "1.2.0", .architecture = "x86_64", .path = "lib.zpkg", .checksum = dummy_checksum },
    } });

    var ctx = try buildContext(allocator, cfg, mgr);
    defer ctx.deinit();

    try std.testing.expectEqual(@as(usize, 2), ctx.candidates.len);
    try std.testing.expectEqual(@as(usize, 0), ctx.installed.len);

    var diags = resolver.Diagnostics{};
    var p = try resolver.resolve(allocator, ctx.provider(), &.{"app"}, &diags);
    defer p.deinit();

    try std.testing.expectEqual(@as(usize, 2), p.order.len);
    try std.testing.expectEqualStrings("lib", p.order[0].name);
    try std.testing.expectEqualStrings("app", p.order[1].name);

    const src = ctx.sourceOf("lib").?;
    try std.testing.expectEqualStrings("lib.zpkg", src.entry.path);
}

test "installed packages are reflected in the context and skipped by the resolver" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const tmp_path = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(tmp_path);

    const cache_dir = try std.fmt.allocPrint(allocator, "{s}/cache", .{tmp_path});
    defer allocator.free(cache_dir);
    const db_path = try std.fmt.allocPrint(allocator, "{s}/db", .{tmp_path});
    defer allocator.free(db_path);

    var cfg = config_mod.default();
    cfg.cache_dir = cache_dir;
    cfg.database_path = db_path;

    const repos = [_]repository.Repository{.{ .name = "main", .url = "https://repo.example.com" }};
    const mgr = repository.Manager.init(allocator, cfg, &repos);

    try seedIndexFile(allocator, mgr, repos[0], .{ .packages = &.{
        .{ .name = "app", .version = "1.0.0", .architecture = "x86_64", .path = "app.zpkg", .checksum = dummy_checksum, .dependencies = &.{.{ .name = "lib", .version_constraint = ">=1.0.0" }} },
        .{ .name = "lib", .version = "1.2.0", .architecture = "x86_64", .path = "lib.zpkg", .checksum = dummy_checksum },
    } });

    const db = db_mod.Database.init(db_path);
    try db.put(allocator, .{ .name = "lib", .version = "1.2.0", .architecture = "x86_64" });

    var ctx = try buildContext(allocator, cfg, mgr);
    defer ctx.deinit();
    try std.testing.expectEqual(@as(usize, 1), ctx.installed.len);

    var diags = resolver.Diagnostics{};
    var p = try resolver.resolve(allocator, ctx.provider(), &.{"app"}, &diags);
    defer p.deinit();

    try std.testing.expectEqual(@as(usize, 1), p.order.len);
    try std.testing.expectEqualStrings("app", p.order[0].name);
}

test "outdated reports only installed packages with a newer repository version" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const tmp_path = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(tmp_path);

    const cache_dir = try std.fmt.allocPrint(allocator, "{s}/cache", .{tmp_path});
    defer allocator.free(cache_dir);
    const db_path = try std.fmt.allocPrint(allocator, "{s}/db", .{tmp_path});
    defer allocator.free(db_path);

    var cfg = config_mod.default();
    cfg.cache_dir = cache_dir;
    cfg.database_path = db_path;

    const repos = [_]repository.Repository{.{ .name = "main", .url = "https://repo.example.com" }};
    const mgr = repository.Manager.init(allocator, cfg, &repos);

    try seedIndexFile(allocator, mgr, repos[0], .{ .packages = &.{
        .{ .name = "old", .version = "2.0.0", .architecture = "x86_64", .path = "old.zpkg", .checksum = dummy_checksum },
        .{ .name = "current", .version = "1.0.0", .architecture = "x86_64", .path = "cur.zpkg", .checksum = dummy_checksum },
    } });

    const db = db_mod.Database.init(db_path);
    try db.put(allocator, .{ .name = "old", .version = "1.0.0", .architecture = "x86_64" });
    try db.put(allocator, .{ .name = "current", .version = "1.0.0", .architecture = "x86_64" });

    var ctx = try buildContext(allocator, cfg, mgr);
    defer ctx.deinit();

    const names = try outdated(allocator, ctx);
    defer allocator.free(names);

    try std.testing.expectEqual(@as(usize, 1), names.len);
    try std.testing.expectEqualStrings("old", names[0]);
}
