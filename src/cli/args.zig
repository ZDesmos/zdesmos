//! CLI argument parsing.
//!
//! Contract (see project spec, STARTUP_RULE): `parse` is pure — it never
//! touches the filesystem, network, or database. `--help` and `--version`
//! must be resolvable from argv alone so main.zig can short-circuit before
//! any subsystem is initialized.

const std = @import("std");
const errors = @import("../core/errors.zig");

pub const version_string = "0.1.0";

pub const Command = union(enum) {
    install: []const u8,
    remove: []const u8,
    update,
    upgrade,
    search: []const u8,
    info: []const u8,
    list,
    clean,
    doctor,
};

pub const ParseResult = union(enum) {
    help,
    version,
    command: Command,
};

const NamedCommand = enum {
    install,
    remove,
    update,
    upgrade,
    search,
    info,
    list,
    clean,
    doctor,
};

/// `argv` excludes the program name (i.e. pass `args[1..]`).
pub fn parse(argv: []const []const u8) errors.CliError!ParseResult {
    if (argv.len == 0) return .help;

    const first = argv[0];
    if (std.mem.eql(u8, first, "--help") or std.mem.eql(u8, first, "-h")) return .help;
    if (std.mem.eql(u8, first, "--version") or std.mem.eql(u8, first, "-v")) return .version;

    const named = std.meta.stringToEnum(NamedCommand, first) orelse return error.UnknownCommand;
    const rest = argv[1..];

    return switch (named) {
        .install => .{ .command = .{ .install = try requireOneArg(rest) } },
        .remove => .{ .command = .{ .remove = try requireOneArg(rest) } },
        .search => .{ .command = .{ .search = try requireOneArg(rest) } },
        .info => .{ .command = .{ .info = try requireOneArg(rest) } },
        .update => .{ .command = try requireNoArgs(rest, .update) },
        .upgrade => .{ .command = try requireNoArgs(rest, .upgrade) },
        .list => .{ .command = try requireNoArgs(rest, .list) },
        .clean => .{ .command = try requireNoArgs(rest, .clean) },
        .doctor => .{ .command = try requireNoArgs(rest, .doctor) },
    };
}

fn requireOneArg(rest: []const []const u8) errors.CliError![]const u8 {
    if (rest.len == 0) return error.MissingArgument;
    if (rest.len > 1) return error.TooManyArguments;
    return rest[0];
}

fn requireNoArgs(rest: []const []const u8, comptime cmd: Command) errors.CliError!Command {
    if (rest.len > 0) return error.TooManyArguments;
    return cmd;
}

pub fn printVersion() void {
    const stdout = std.io.getStdOut().writer();
    stdout.print("zdms {s}\n", .{version_string}) catch return;
}

pub fn printHelp() void {
    const stdout = std.io.getStdOut().writer();
    stdout.writeAll(
        \\zdms - Zig Dependency Management System
        \\
        \\USAGE:
        \\    zdms <COMMAND> [ARGS]
        \\
        \\COMMANDS:
        \\    install <package>   Install a package
        \\    remove <package>    Remove a package
        \\    update              Refresh repository metadata
        \\    upgrade             Upgrade installed packages
        \\    search <package>    Search available packages
        \\    info <package>      Show package details
        \\    list                List installed packages
        \\    clean               Clean the local cache
        \\    doctor              Diagnose common issues
        \\
        \\GLOBAL:
        \\    -h, --help          Show this help message
        \\    -v, --version       Show version information
        \\
    ) catch return;
}

pub fn printParseError(e: errors.CliError) void {
    const stderr = std.io.getStdErr().writer();
    const msg = switch (e) {
        error.UnknownCommand => "unknown command",
        error.UnknownFlag => "unknown flag",
        error.MissingArgument => "missing argument",
        error.TooManyArguments => "too many arguments",
    };
    stderr.print("zdms: error: {s}\n", .{msg}) catch return;
    stderr.print("Run 'zdms --help' for usage.\n", .{}) catch return;
}

test "no args yields help" {
    try std.testing.expectEqual(ParseResult.help, try parse(&.{}));
}

test "--help and -h yield help" {
    try std.testing.expectEqual(ParseResult.help, try parse(&.{"--help"}));
    try std.testing.expectEqual(ParseResult.help, try parse(&.{"-h"}));
}

test "--version and -v yield version" {
    try std.testing.expectEqual(ParseResult.version, try parse(&.{"--version"}));
    try std.testing.expectEqual(ParseResult.version, try parse(&.{"-v"}));
}

test "install requires exactly one package argument" {
    const result = try parse(&.{ "install", "foo" });
    try std.testing.expectEqualStrings("foo", result.command.install);

    try std.testing.expectError(error.MissingArgument, parse(&.{"install"}));
    try std.testing.expectError(error.TooManyArguments, parse(&.{ "install", "foo", "bar" }));
}

test "remove, search, info follow the same one-arg contract" {
    try std.testing.expectEqualStrings("foo", (try parse(&.{ "remove", "foo" })).command.remove);
    try std.testing.expectEqualStrings("foo", (try parse(&.{ "search", "foo" })).command.search);
    try std.testing.expectEqualStrings("foo", (try parse(&.{ "info", "foo" })).command.info);
}

test "zero-arg commands reject extra arguments" {
    try std.testing.expectEqual(Command.update, (try parse(&.{"update"})).command);
    try std.testing.expectEqual(Command.upgrade, (try parse(&.{"upgrade"})).command);
    try std.testing.expectEqual(Command.list, (try parse(&.{"list"})).command);
    try std.testing.expectEqual(Command.clean, (try parse(&.{"clean"})).command);
    try std.testing.expectEqual(Command.doctor, (try parse(&.{"doctor"})).command);

    try std.testing.expectError(error.TooManyArguments, parse(&.{ "list", "extra" }));
}

test "unknown command is rejected" {
    try std.testing.expectError(error.UnknownCommand, parse(&.{"frobnicate"}));
}
