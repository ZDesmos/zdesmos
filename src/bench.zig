//! Benchmarks: `zig build bench`.
//!
//! These measure only what is measurable without a network or a populated
//! system -- resolution, checksumming, and package pack/unpack. Download
//! throughput and real install timings need a live repository and belong
//! in an integration harness, not here.
//!
//! Numbers are wall-clock medians over `iterations`, printed as a table.
//! Treat them as a regression signal, not an absolute score.

const std = @import("std");
const checksum = @import("package/checksum.zig");
const package_mod = @import("package/package.zig");
const resolver = @import("resolver/resolver.zig");
const version_mod = @import("resolver/version.zig");

fn report(name: []const u8, iterations: usize, total_ns: u64) void {
    const stdout = std.io.getStdOut().writer();
    const per_op = total_ns / @max(iterations, 1);
    stdout.print("{s: <34} {d: >8} iters  {d: >10} ns/op\n", .{ name, iterations, per_op }) catch {};
}

fn benchChecksum(allocator: std.mem.Allocator) !void {
    const size = 4 * 1024 * 1024;
    const data = try allocator.alloc(u8, size);
    defer allocator.free(data);
    for (data, 0..) |*b, i| b.* = @truncate(i);

    const iterations = 20;
    var timer = try std.time.Timer.start();
    for (0..iterations) |_| {
        var buf: [64]u8 = undefined;
        checksum.sha256HexBuf(data, &buf);
        std.mem.doNotOptimizeAway(&buf);
    }
    report("sha256 4MiB", iterations, timer.read());
}

fn benchPackRoundTrip(allocator: std.mem.Allocator) !void {
    const content = try allocator.alloc(u8, 256 * 1024);
    defer allocator.free(content);
    @memset(content, 'x');

    const files = [_]package_mod.FileData{
        .{ .path = "bin/app", .content = content },
        .{ .path = "share/doc/app", .content = content },
    };
    const m = package_mod.Manifest{ .name = "app", .version = "1.0.0", .architecture = "x86_64" };

    const iterations = 50;
    var timer = try std.time.Timer.start();
    for (0..iterations) |_| {
        const bytes = try package_mod.create(allocator, m, &files);
        defer allocator.free(bytes);
        var opened = try package_mod.open(allocator, bytes);
        opened.deinit();
    }
    report("zpkg create+open (512KiB)", iterations, timer.read());
}

const BenchRepo = struct {
    candidates: []const resolver.Candidate,

    fn lookup(ctx: *const anyopaque, name: []const u8) ?resolver.Candidate {
        const self: *const BenchRepo = @ptrCast(@alignCast(ctx));
        for (self.candidates) |c| {
            if (std.mem.eql(u8, c.name, name)) return c;
        }
        return null;
    }
};

fn benchResolve(allocator: std.mem.Allocator) !void {
    // A chain of 200 packages, each depending on the next: worst case for
    // recursion depth and memoization.
    const count = 200;
    const names = try allocator.alloc([]u8, count);
    defer {
        for (names) |n| allocator.free(n);
        allocator.free(names);
    }
    for (names, 0..) |*n, i| n.* = try std.fmt.allocPrint(allocator, "pkg{d}", .{i});

    const deps = try allocator.alloc([1]@import("package/manifest.zig").Dependency, count);
    defer allocator.free(deps);
    const candidates = try allocator.alloc(resolver.Candidate, count);
    defer allocator.free(candidates);

    for (candidates, 0..) |*c, i| {
        if (i + 1 < count) {
            deps[i] = .{.{ .name = names[i + 1], .version_constraint = "*" }};
            c.* = .{ .name = names[i], .version = "1.0.0", .dependencies = &deps[i] };
        } else {
            c.* = .{ .name = names[i], .version = "1.0.0" };
        }
    }

    const repo = BenchRepo{ .candidates = candidates };
    const provider = resolver.Provider{ .ctx = &repo, .lookupFn = BenchRepo.lookup };

    const iterations = 100;
    var timer = try std.time.Timer.start();
    for (0..iterations) |_| {
        var diags = resolver.Diagnostics{};
        var plan = try resolver.resolve(allocator, provider, &.{names[0]}, &diags);
        plan.deinit();
    }
    report("resolve 200-package chain", iterations, timer.read());
}

fn benchVersionParse() !void {
    const iterations = 100_000;
    var timer = try std.time.Timer.start();
    for (0..iterations) |_| {
        const v = try version_mod.Version.parse("1.24.3");
        std.mem.doNotOptimizeAway(v);
    }
    report("version parse", iterations, timer.read());
}

pub fn main() !void {
    var gpa_state = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa_state.deinit();
    const allocator = gpa_state.allocator();

    const stdout = std.io.getStdOut().writer();
    try stdout.print("zdms benchmarks (build with -Doptimize=ReleaseFast for meaningful numbers)\n\n", .{});

    try benchVersionParse();
    try benchChecksum(allocator);
    try benchPackRoundTrip(allocator);
    try benchResolve(allocator);
}
