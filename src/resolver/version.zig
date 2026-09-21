//! Semantic-version parsing, comparison, and constraint matching.
//!
//! Versions are `MAJOR.MINOR.PATCH` with an optional `-prerelease` suffix.
//! Missing components default to 0, so "1" and "1.0.0" compare equal --
//! repository metadata in the wild is rarely fully normalized.
//!
//! Constraints supported (a comma-separated list, all of which must hold):
//!   *            any version
//!   1.2.3        exactly 1.2.3
//!   =1.2.3       exactly 1.2.3
//!   >1.2.3  >=1.2.3  <1.2.3  <=1.2.3
//!   ^1.2.3       >=1.2.3 and <2.0.0   (compatible-with)
//!   ~1.2.3       >=1.2.3 and <1.3.0   (approximately-equivalent)

const std = @import("std");

pub const ParseError = error{InvalidVersion};
pub const ConstraintError = error{InvalidConstraint};

pub const Version = struct {
    major: u32 = 0,
    minor: u32 = 0,
    patch: u32 = 0,
    /// Empty means a normal release. A prerelease sorts *before* the same
    /// version without one (1.0.0-rc1 < 1.0.0), per semver.
    prerelease: []const u8 = "",

    pub fn parse(text: []const u8) ParseError!Version {
        if (text.len == 0) return error.InvalidVersion;

        var core = text;
        var prerelease: []const u8 = "";
        if (std.mem.indexOfScalar(u8, text, '-')) |dash| {
            core = text[0..dash];
            prerelease = text[dash + 1 ..];
            if (core.len == 0) return error.InvalidVersion;
        }

        var parts = std.mem.splitScalar(u8, core, '.');
        var nums: [3]u32 = .{ 0, 0, 0 };
        var count: usize = 0;
        while (parts.next()) |part| {
            if (count >= 3) return error.InvalidVersion;
            if (part.len == 0) return error.InvalidVersion;
            nums[count] = std.fmt.parseInt(u32, part, 10) catch return error.InvalidVersion;
            count += 1;
        }
        if (count == 0) return error.InvalidVersion;

        return .{ .major = nums[0], .minor = nums[1], .patch = nums[2], .prerelease = prerelease };
    }

    pub fn order(a: Version, b: Version) std.math.Order {
        if (a.major != b.major) return std.math.order(a.major, b.major);
        if (a.minor != b.minor) return std.math.order(a.minor, b.minor);
        if (a.patch != b.patch) return std.math.order(a.patch, b.patch);

        // A version with a prerelease is lower than one without.
        const a_pre = a.prerelease.len > 0;
        const b_pre = b.prerelease.len > 0;
        if (a_pre and !b_pre) return .lt;
        if (!a_pre and b_pre) return .gt;
        if (!a_pre and !b_pre) return .eq;
        return std.mem.order(u8, a.prerelease, b.prerelease);
    }

    pub fn eql(a: Version, b: Version) bool {
        return a.order(b) == .eq;
    }
};

const Op = enum { any, eq, gt, gte, lt, lte, caret, tilde };

const Term = struct {
    op: Op,
    version: Version,

    fn matches(self: Term, v: Version) bool {
        return switch (self.op) {
            .any => true,
            .eq => v.order(self.version) == .eq,
            .gt => v.order(self.version) == .gt,
            .gte => v.order(self.version) != .lt,
            .lt => v.order(self.version) == .lt,
            .lte => v.order(self.version) != .gt,
            // ^1.2.3 -> >=1.2.3, <2.0.0. For 0.x, the minor acts as the
            // breaking-change axis: ^0.2.3 -> >=0.2.3, <0.3.0.
            .caret => blk: {
                if (v.order(self.version) == .lt) break :blk false;
                const upper: Version = if (self.version.major > 0)
                    .{ .major = self.version.major + 1 }
                else
                    .{ .major = 0, .minor = self.version.minor + 1 };
                break :blk v.order(upper) == .lt;
            },
            // ~1.2.3 -> >=1.2.3, <1.3.0
            .tilde => blk: {
                if (v.order(self.version) == .lt) break :blk false;
                const upper: Version = .{ .major = self.version.major, .minor = self.version.minor + 1 };
                break :blk v.order(upper) == .lt;
            },
        };
    }
};

fn parseTerm(text: []const u8) ConstraintError!Term {
    const trimmed = std.mem.trim(u8, text, " \t");
    if (trimmed.len == 0) return error.InvalidConstraint;
    if (std.mem.eql(u8, trimmed, "*")) return .{ .op = .any, .version = .{} };

    const prefixes = [_]struct { text: []const u8, op: Op }{
        .{ .text = ">=", .op = .gte },
        .{ .text = "<=", .op = .lte },
        .{ .text = ">", .op = .gt },
        .{ .text = "<", .op = .lt },
        .{ .text = "^", .op = .caret },
        .{ .text = "~", .op = .tilde },
        .{ .text = "=", .op = .eq },
    };

    for (prefixes) |p| {
        if (std.mem.startsWith(u8, trimmed, p.text)) {
            const rest = std.mem.trim(u8, trimmed[p.text.len..], " \t");
            const v = Version.parse(rest) catch return error.InvalidConstraint;
            return .{ .op = p.op, .version = v };
        }
    }

    const v = Version.parse(trimmed) catch return error.InvalidConstraint;
    return .{ .op = .eq, .version = v };
}

/// True if `version_text` satisfies every term in `constraint`.
/// Terms are comma-separated and ANDed together: ">=1.0.0, <2.0.0".
pub fn satisfies(version_text: []const u8, constraint: []const u8) ConstraintError!bool {
    const v = Version.parse(version_text) catch return error.InvalidConstraint;

    var terms = std.mem.splitScalar(u8, constraint, ',');
    var saw_any = false;
    while (terms.next()) |term_text| {
        const trimmed = std.mem.trim(u8, term_text, " \t");
        if (trimmed.len == 0) continue;
        saw_any = true;
        const term = try parseTerm(trimmed);
        if (!term.matches(v)) return false;
    }
    if (!saw_any) return error.InvalidConstraint;
    return true;
}

test "parse handles full, partial, and prerelease versions" {
    const full = try Version.parse("1.2.3");
    try std.testing.expectEqual(@as(u32, 1), full.major);
    try std.testing.expectEqual(@as(u32, 2), full.minor);
    try std.testing.expectEqual(@as(u32, 3), full.patch);

    const partial = try Version.parse("2");
    try std.testing.expectEqual(@as(u32, 2), partial.major);
    try std.testing.expectEqual(@as(u32, 0), partial.minor);

    const pre = try Version.parse("1.0.0-rc1");
    try std.testing.expectEqualStrings("rc1", pre.prerelease);

    try std.testing.expectError(error.InvalidVersion, Version.parse(""));
    try std.testing.expectError(error.InvalidVersion, Version.parse("1.2.3.4"));
    try std.testing.expectError(error.InvalidVersion, Version.parse("1..3"));
    try std.testing.expectError(error.InvalidVersion, Version.parse("abc"));
}

test "order sorts by component and places prereleases first" {
    const a = try Version.parse("1.2.3");
    const b = try Version.parse("1.10.0");
    try std.testing.expectEqual(std.math.Order.lt, a.order(b));

    // "1" and "1.0.0" are the same version.
    try std.testing.expect((try Version.parse("1")).eql(try Version.parse("1.0.0")));

    const rc = try Version.parse("1.0.0-rc1");
    const release = try Version.parse("1.0.0");
    try std.testing.expectEqual(std.math.Order.lt, rc.order(release));
}

test "satisfies handles every supported operator" {
    try std.testing.expect(try satisfies("1.2.3", "*"));
    try std.testing.expect(try satisfies("1.2.3", "1.2.3"));
    try std.testing.expect(!try satisfies("1.2.4", "1.2.3"));
    try std.testing.expect(try satisfies("1.2.3", "=1.2.3"));

    try std.testing.expect(try satisfies("2.0.0", ">1.0.0"));
    try std.testing.expect(!try satisfies("1.0.0", ">1.0.0"));
    try std.testing.expect(try satisfies("1.0.0", ">=1.0.0"));
    try std.testing.expect(try satisfies("0.9.0", "<1.0.0"));
    try std.testing.expect(try satisfies("1.0.0", "<=1.0.0"));
}

test "caret allows compatible updates and stops at the breaking boundary" {
    try std.testing.expect(try satisfies("1.5.0", "^1.2.3"));
    try std.testing.expect(!try satisfies("2.0.0", "^1.2.3"));
    try std.testing.expect(!try satisfies("1.2.2", "^1.2.3"));

    // For 0.x the minor is the breaking axis.
    try std.testing.expect(try satisfies("0.2.5", "^0.2.3"));
    try std.testing.expect(!try satisfies("0.3.0", "^0.2.3"));
}

test "tilde allows patch updates only" {
    try std.testing.expect(try satisfies("1.2.9", "~1.2.3"));
    try std.testing.expect(!try satisfies("1.3.0", "~1.2.3"));
}

test "comma-separated terms are ANDed" {
    try std.testing.expect(try satisfies("1.5.0", ">=1.0.0, <2.0.0"));
    try std.testing.expect(!try satisfies("2.5.0", ">=1.0.0, <2.0.0"));
}

test "malformed constraints and versions are rejected" {
    try std.testing.expectError(error.InvalidConstraint, satisfies("1.0.0", ""));
    try std.testing.expectError(error.InvalidConstraint, satisfies("1.0.0", ">=abc"));
    try std.testing.expectError(error.InvalidConstraint, satisfies("not-a-version", "*"));
}
