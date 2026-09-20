//! Minimal leveled logger. Writes to stderr so stdout stays clean for
//! machine-parseable command output. No allocations on the hot path.

const std = @import("std");

pub const Level = enum(u8) {
    debug = 0,
    info = 1,
    warn = 2,
    err = 3,

    fn label(self: Level) []const u8 {
        return switch (self) {
            .debug => "debug",
            .info => "info",
            .warn => "warn",
            .err => "error",
        };
    }
};

/// Global minimum level; messages below this are dropped without formatting
/// their arguments. Defaults to `.info`. `zdms --verbose` (wired up in a
/// later phase) will lower this to `.debug`.
var min_level: Level = .info;

pub fn setLevel(level: Level) void {
    min_level = level;
}

pub fn debug(comptime fmt: []const u8, args: anytype) void {
    log(.debug, fmt, args);
}

pub fn info(comptime fmt: []const u8, args: anytype) void {
    log(.info, fmt, args);
}

pub fn warn(comptime fmt: []const u8, args: anytype) void {
    log(.warn, fmt, args);
}

pub fn err(comptime fmt: []const u8, args: anytype) void {
    log(.err, fmt, args);
}

fn log(level: Level, comptime fmt: []const u8, args: anytype) void {
    if (@intFromEnum(level) < @intFromEnum(min_level)) return;
    const stderr = std.io.getStdErr().writer();
    // Three small writes instead of concatenating the format string/tuple:
    // simpler to get right than comptime tuple concatenation.
    stderr.print("[{s}] ", .{level.label()}) catch return;
    stderr.print(fmt, args) catch return;
    stderr.print("\n", .{}) catch return;
}

test "messages below min_level are suppressed without error" {
    setLevel(.warn);
    defer setLevel(.info);
    // debug/info calls must be no-ops here; this just checks they don't crash.
    debug("hidden {d}", .{1});
    info("hidden {d}", .{2});
    warn("shown {d}", .{3});
}
