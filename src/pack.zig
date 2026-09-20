//! zdms-pack: build `.zpkg` files and repository `index.json` files.
//! A separate tool from `zdms`, the same way `dpkg-deb` is separate from
//! `apt` -- zdms only installs, this only builds. Not part of the spec's
//! CLI surface; built to close the "how do I actually make a package"
//! gap. Kept deliberately small: no tests, minimal error handling beyond
//! printing and exiting -- this runs once per release, by a person, not
//! unattended.
//!
//! Usage:
//!   zdms-pack build <output.zpkg> <name> <version> <architecture> <files-dir>
//!   zdms-pack index <output-index.json> <pool-dir>

const std = @import("std");
const package_mod = @import("package/package.zig");
const index_mod = @import("repository/index.zig");
const checksum_mod = @import("package/checksum.zig");

fn usage() void {
    std.debug.print(
        \\zdms-pack build <output.zpkg> <name> <version> <architecture> <files-dir>
        \\zdms-pack index <output-index.json> <pool-dir>
        \\
    , .{});
}

pub fn main() u8 {
    // page_allocator, not GeneralPurposeAllocator: this is a one-shot
    // build-time tool that exits right after doing its job, and several
    // paths below deliberately skip frees (see runBuild's comment) since
    // the OS reclaims everything on exit anyway. GPA's leak checker would
    // just print noisy, harmless warnings for exactly those frees.
    const allocator = std.heap.page_allocator;

    const argv = std.process.argsAlloc(allocator) catch return 1;
    defer std.process.argsFree(allocator, argv);

    if (argv.len < 2) {
        usage();
        return 1;
    }

    if (std.mem.eql(u8, argv[1], "build")) return runBuild(allocator, argv[2..]);
    if (std.mem.eql(u8, argv[1], "index")) return runIndex(allocator, argv[2..]);

    usage();
    return 1;
}

/// Walks `files_dir` recursively; every regular file found becomes a
/// package file, installed at the path relative to `files_dir` (so
/// `files-dir/bin/hello` becomes `bin/hello` once installed).
fn runBuild(allocator: std.mem.Allocator, args: [][:0]u8) u8 {
    if (args.len != 5) {
        usage();
        return 1;
    }
    const output_path = args[0];
    const name = args[1];
    const version = args[2];
    const architecture = args[3];
    const files_dir = args[4];

    var dir = std.fs.cwd().openDir(files_dir, .{ .iterate = true }) catch |e| {
        std.debug.print("cannot open {s}: {s}\n", .{ files_dir, @errorName(e) });
        return 1;
    };
    defer dir.close();

    var files = std.ArrayList(package_mod.FileData).init(allocator);
    // Deliberately not freeing file contents/paths on the way out: this
    // process exits right after, success or failure, and the OS reclaims
    // it -- not worth the code for a one-shot build tool.

    var walker = dir.walk(allocator) catch |e| {
        std.debug.print("cannot walk {s}: {s}\n", .{ files_dir, @errorName(e) });
        return 1;
    };
    defer walker.deinit();

    while (walker.next() catch |e| {
        std.debug.print("walk error: {s}\n", .{@errorName(e)});
        return 1;
    }) |entry| {
        if (entry.kind != .file) continue;
        const content = dir.readFileAlloc(allocator, entry.path, 512 * 1024 * 1024) catch |e| {
            std.debug.print("cannot read {s}: {s}\n", .{ entry.path, @errorName(e) });
            return 1;
        };
        const path_copy = allocator.dupe(u8, entry.path) catch return 1;
        files.append(.{ .path = path_copy, .content = content }) catch return 1;
    }

    if (files.items.len == 0) {
        std.debug.print("no files found under {s}\n", .{files_dir});
        return 1;
    }

    const manifest = package_mod.Manifest{
        .name = name,
        .version = version,
        .architecture = architecture,
    };

    const zpkg_bytes = package_mod.create(allocator, manifest, files.items) catch |e| {
        std.debug.print("failed to build package: {s}\n", .{@errorName(e)});
        return 1;
    };

    std.fs.cwd().writeFile(.{ .sub_path = output_path, .data = zpkg_bytes }) catch |e| {
        std.debug.print("cannot write {s}: {s}\n", .{ output_path, @errorName(e) });
        return 1;
    };

    std.debug.print("built {s} ({s} {s}, {d} file(s), {d} bytes)\n", .{
        output_path, name, version, files.items.len, zpkg_bytes.len,
    });
    return 0;
}

/// Scans every `.zpkg` directly inside `pool_dir` and writes an
/// `index.json` listing them, with `path` set to the bare filename --
/// matching a repository layout where `index.json` and the pool sit in
/// the same directory (adjust by hand if yours doesn't).
fn runIndex(allocator: std.mem.Allocator, args: [][:0]u8) u8 {
    if (args.len != 2) {
        usage();
        return 1;
    }
    const output_path = args[0];
    const pool_dir = args[1];

    var dir = std.fs.cwd().openDir(pool_dir, .{ .iterate = true }) catch |e| {
        std.debug.print("cannot open {s}: {s}\n", .{ pool_dir, @errorName(e) });
        return 1;
    };
    defer dir.close();

    var entries = std.ArrayList(index_mod.IndexEntry).init(allocator);

    var it = dir.iterate();
    while (it.next() catch |e| {
        std.debug.print("iterate error: {s}\n", .{@errorName(e)});
        return 1;
    }) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".zpkg")) continue;

        const bytes = dir.readFileAlloc(allocator, entry.name, 512 * 1024 * 1024) catch |e| {
            std.debug.print("cannot read {s}: {s}\n", .{ entry.name, @errorName(e) });
            return 1;
        };

        var opened = package_mod.open(allocator, bytes) catch |e| {
            std.debug.print("skipping {s} (invalid package): {s}\n", .{ entry.name, @errorName(e) });
            continue;
        };
        defer opened.deinit();
        const m = opened.manifest();

        const checksum_hex = checksum_mod.sha256Hex(allocator, bytes) catch return 1;

        entries.append(.{
            .name = allocator.dupe(u8, m.name) catch return 1,
            .version = allocator.dupe(u8, m.version) catch return 1,
            .architecture = allocator.dupe(u8, m.architecture) catch return 1,
            .path = allocator.dupe(u8, entry.name) catch return 1,
            .checksum = checksum_hex,
            .size = @intCast(bytes.len),
        }) catch return 1;
    }

    const idx = index_mod.Index{ .packages = entries.items };
    const json_text = index_mod.toJson(allocator, idx) catch |e| {
        std.debug.print("failed to serialize index: {s}\n", .{@errorName(e)});
        return 1;
    };

    std.fs.cwd().writeFile(.{ .sub_path = output_path, .data = json_text }) catch |e| {
        std.debug.print("cannot write {s}: {s}\n", .{ output_path, @errorName(e) });
        return 1;
    };

    std.debug.print("wrote {s} ({d} package(s))\n", .{ output_path, entries.items.len });
    return 0;
}
