//! Bounded-concurrency download pool.
//!
//! Spec: `max_parallel_downloads = 4` by default, never unlimited. Workers
//! pull jobs off a shared queue guarded by a mutex, so concurrency is
//! capped by thread count rather than by job count -- 500 packages still
//! opens at most `max_parallel` connections.
//!
//! Each worker owns its own `http.Client` (and therefore its own
//! connection pool), because std.http.Client is not safe to share across
//! threads. Connections are still reused *within* a worker across its
//! jobs, which is where the reuse actually pays off.

const std = @import("std");
const http = @import("http.zig");
const log = @import("../core/log.zig");

pub const Job = struct {
    url: []const u8,
    dest_path: []const u8,
    expected_sha256: []const u8 = "",
    max_bytes: usize,
    /// Set by the worker. `null` means success.
    err: ?anyerror = null,
};

const Queue = struct {
    jobs: []Job,
    next: usize = 0,
    mutex: std.Thread.Mutex = .{},

    fn take(self: *Queue) ?*Job {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.next >= self.jobs.len) return null;
        const job = &self.jobs[self.next];
        self.next += 1;
        return job;
    }
};

const Worker = struct {
    allocator: std.mem.Allocator,
    queue: *Queue,
    retries: u32,

    fn run(self: Worker) void {
        var client = http.Client.init(self.allocator, self.retries);
        defer client.deinit();

        while (self.queue.take()) |job| {
            client.fetchToFile(job.url, job.dest_path, job.expected_sha256, job.max_bytes) catch |e| {
                job.err = e;
                continue;
            };
        }
    }
};

/// Runs every job with at most `max_parallel` concurrent downloads.
/// Returns the number that failed; per-job errors are left in `job.err` so
/// the caller can report which package failed and why.
///
/// A single job is run inline -- spawning a thread to wait on one download
/// only adds latency.
pub fn runAll(
    allocator: std.mem.Allocator,
    jobs: []Job,
    max_parallel: u32,
    retries: u32,
) !usize {
    if (jobs.len == 0) return 0;

    var queue = Queue{ .jobs = jobs };

    if (jobs.len == 1 or max_parallel <= 1) {
        (Worker{ .allocator = allocator, .queue = &queue, .retries = retries }).run();
        return countFailures(jobs);
    }

    const thread_count = @min(@as(usize, max_parallel), jobs.len);
    const threads = try allocator.alloc(std.Thread, thread_count);
    defer allocator.free(threads);

    var spawned: usize = 0;
    for (threads) |*t| {
        t.* = std.Thread.spawn(.{}, Worker.run, .{Worker{
            .allocator = allocator,
            .queue = &queue,
            .retries = retries,
        }}) catch |e| {
            // Out of threads: the already-spawned ones plus this thread
            // will drain the queue, so this is a degradation, not a
            // failure.
            log.debug("could not spawn download worker: {s}", .{@errorName(e)});
            break;
        };
        spawned += 1;
    }

    // The calling thread helps drain the queue instead of blocking idle.
    (Worker{ .allocator = allocator, .queue = &queue, .retries = retries }).run();

    for (threads[0..spawned]) |t| t.join();

    return countFailures(jobs);
}

fn countFailures(jobs: []const Job) usize {
    var failures: usize = 0;
    for (jobs) |j| {
        if (j.err != null) failures += 1;
    }
    return failures;
}

test "an empty job list succeeds without spawning anything" {
    var jobs = [_]Job{};
    try std.testing.expectEqual(@as(usize, 0), try runAll(std.testing.allocator, &jobs, 4, 0));
}

test "queue hands out each job exactly once across concurrent takers" {
    const allocator = std.testing.allocator;

    const jobs = try allocator.alloc(Job, 100);
    defer allocator.free(jobs);
    for (jobs) |*j| j.* = .{ .url = "", .dest_path = "", .max_bytes = 0 };

    var queue = Queue{ .jobs = jobs };

    const Counter = struct {
        queue: *Queue,
        taken: *std.atomic.Value(usize),

        fn drain(self: @This()) void {
            while (self.queue.take()) |_| {
                _ = self.taken.fetchAdd(1, .monotonic);
            }
        }
    };

    var taken = std.atomic.Value(usize).init(0);
    var threads: [4]std.Thread = undefined;
    for (&threads) |*t| {
        t.* = try std.Thread.spawn(.{}, Counter.drain, .{Counter{ .queue = &queue, .taken = &taken }});
    }
    for (threads) |t| t.join();

    try std.testing.expectEqual(@as(usize, 100), taken.load(.monotonic));
    try std.testing.expectEqual(@as(?*Job, null), queue.take());
}

test "failures are counted and recorded per job" {
    var jobs = [_]Job{
        .{ .url = "", .dest_path = "", .max_bytes = 0, .err = error.HttpError },
        .{ .url = "", .dest_path = "", .max_bytes = 0 },
        .{ .url = "", .dest_path = "", .max_bytes = 0, .err = error.RequestFailed },
    };
    try std.testing.expectEqual(@as(usize, 2), countFailures(&jobs));
}
