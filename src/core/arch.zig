//! Known target architectures for the reference repository
//! (https://github.com/ZDesmos/zdesmos-package): glibc and musl builds of
//! aarch64, armv6l, armv7l, i686, and x86_64.
//!
//! This is a closed list on purpose. A package manager that accepts any
//! string as an "architecture" will happily let a repository publish
//! typos as separate architectures forever; validating against a known
//! set catches that at index-parse time instead of at "why won't this
//! binary run" time.

const std = @import("std");

pub const Architecture = enum {
    aarch64,
    aarch64_musl,
    armv6l,
    armv6l_musl,
    armv7l,
    armv7l_musl,
    i686,
    x86_64,
    x86_64_musl,

    pub fn toString(self: Architecture) []const u8 {
        return switch (self) {
            .aarch64 => "aarch64",
            .aarch64_musl => "aarch64-musl",
            .armv6l => "armv6l",
            .armv6l_musl => "armv6l-musl",
            .armv7l => "armv7l",
            .armv7l_musl => "armv7l-musl",
            .i686 => "i686",
            .x86_64 => "x86_64",
            .x86_64_musl => "x86_64-musl",
        };
    }

    /// Matches the on-disk/manifest spelling ("x86_64-musl", with a dash).
    pub fn parse(text: []const u8) ?Architecture {
        inline for (std.meta.fields(Architecture)) |field| {
            const arch: Architecture = @enumFromInt(field.value);
            if (std.mem.eql(u8, text, arch.toString())) return arch;
        }
        return null;
    }
};

test "toString and parse round-trip for every architecture" {
    inline for (std.meta.fields(Architecture)) |field| {
        const arch: Architecture = @enumFromInt(field.value);
        try std.testing.expectEqual(arch, Architecture.parse(arch.toString()).?);
    }
}

test "parse rejects unknown architectures" {
    try std.testing.expectEqual(@as(?Architecture, null), Architecture.parse("sparc64"));
    try std.testing.expectEqual(@as(?Architecture, null), Architecture.parse(""));
    try std.testing.expectEqual(@as(?Architecture, null), Architecture.parse("x86_64_musl"));
}

test "toString uses a dash, not an underscore, for the musl suffix" {
    try std.testing.expectEqualStrings("x86_64-musl", Architecture.x86_64_musl.toString());
    try std.testing.expectEqualStrings("armv7l-musl", Architecture.armv7l_musl.toString());
}
