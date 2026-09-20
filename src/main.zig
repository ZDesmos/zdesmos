const std = @import("std");
const args_mod = @import("cli/args.zig");
const commands = @import("cli/commands.zig");
const config_mod = @import("core/config.zig");
const log = @import("core/log.zig");

pub fn main() u8 {
    var gpa_state = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa_state.deinit();
    const allocator = gpa_state.allocator();

    const argv = std.process.argsAlloc(allocator) catch {
        log.err("failed to read command-line arguments", .{});
        return 1;
    };
    defer std.process.argsFree(allocator, argv);

    // argsAlloc returns `[][:0]u8`; parse() wants the plain `[]const []const
    // u8` it shares with its unit tests, so copy element-by-element rather
    // than relying on a nested-slice coercion.
    const rest = if (argv.len > 1) argv[1..] else argv[0..0];
    const arg_slices = allocator.alloc([]const u8, rest.len) catch {
        log.err("out of memory", .{});
        return 1;
    };
    defer allocator.free(arg_slices);
    for (rest, 0..) |a, i| arg_slices[i] = a;

    // Parsing is pure (no filesystem/network/database access), which is
    // what lets --help and --version stay instant regardless of config or
    // repository state.
    const parsed = args_mod.parse(arg_slices) catch |e| {
        args_mod.printParseError(e);
        return 1;
    };

    switch (parsed) {
        .help => {
            args_mod.printHelp();
            return 0;
        },
        .version => {
            args_mod.printVersion();
            return 0;
        },
        .command => |cmd| {
            const config = config_mod.default();
            config.validate() catch {
                log.err("invalid configuration", .{});
                return 1;
            };
            commands.dispatch(allocator, config, cmd) catch |e| {
                if (e != error.NotImplemented) log.err("{s}", .{@errorName(e)});
                return 1;
            };
            return 0;
        },
    }
}
