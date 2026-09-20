//! Dependency resolution.
//!
//! Given a set of requested packages and a `Provider` that can look up
//! candidates by name, produces a deterministic install order:
//! dependencies always precede the packages that need them.
//!
//! Design notes:
//!  - Resolution is a DFS with memoization, so a shared dependency is
//!    visited once no matter how many packages require it (spec: "avoid
//!    resolving the same dependency repeatedly").
//!  - Circular dependencies are detected via the "in progress" state of a
//!    node rather than a depth limit, so the error names the real cycle.
//!  - Conflicts are reported when two requirements on the same package
//!    can't both be satisfied by the single available version -- full
//!    multi-version backtracking isn't needed while the repository model
//!    offers one version per name.
//!  - Order is deterministic: the requested list is processed in order and
//!    each package's dependencies in manifest order.

const std = @import("std");
const version_mod = @import("version.zig");
const manifest_mod = @import("../package/manifest.zig");

pub const ResolveError = error{
    PackageNotFound,
    CircularDependency,
    VersionConflict,
    InvalidConstraint,
};

/// A resolvable package candidate, as offered by a `Provider`.
pub const Candidate = struct {
    name: []const u8,
    version: []const u8,
    dependencies: []const manifest_mod.Dependency = &.{},
};

/// Where candidates come from. The resolver doesn't care whether that's a
/// repository index, the local database, or a test fixture.
pub const Provider = struct {
    ctx: *const anyopaque,
    lookupFn: *const fn (ctx: *const anyopaque, name: []const u8) ?Candidate,
    /// Packages already installed and satisfying their requirement are
    /// skipped. Optional: null means "treat nothing as installed".
    installedFn: ?*const fn (ctx: *const anyopaque, name: []const u8) ?Candidate = null,

    pub fn lookup(self: Provider, name: []const u8) ?Candidate {
        return self.lookupFn(self.ctx, name);
    }

    pub fn installed(self: Provider, name: []const u8) ?Candidate {
        const f = self.installedFn orelse return null;
        return f(self.ctx, name);
    }
};

/// The resolved plan. `order` lists packages to install, dependencies
/// first. Caller owns the slice; the `Candidate`s inside borrow from the
/// provider and stay valid as long as it does.
pub const Plan = struct {
    order: []Candidate,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *Plan) void {
        self.allocator.free(self.order);
    }

    pub fn contains(self: Plan, name: []const u8) bool {
        for (self.order) |c| {
            if (std.mem.eql(u8, c.name, name)) return true;
        }
        return false;
    }
};

const State = enum { unvisited, in_progress, done };

/// Details about the last failure, for a useful error message. Populated
/// on error; the error set stays small so callers can match on it.
pub const Diagnostics = struct {
    /// Package involved in the failure.
    package: []const u8 = "",
    /// Constraint that could not be satisfied, for VersionConflict.
    constraint: []const u8 = "",
    /// Version that was available, for VersionConflict.
    available: []const u8 = "",
};

const Resolver = struct {
    allocator: std.mem.Allocator,
    provider: Provider,
    /// Pointers, not copies: StringHashMap and ArrayList are structs, so
    /// holding them by value here would leave the caller's variables stale
    /// and make its defer/errdefer free the wrong (pre-growth) state.
    states: *std.StringHashMap(State),
    result: *std.ArrayList(Candidate),
    diagnostics: *Diagnostics,

    fn visit(self: *Resolver, name: []const u8, constraint: []const u8) ResolveError!void {
        // An already-installed package satisfying the constraint needs no
        // work -- and must not be re-added to the plan.
        if (self.provider.installed(name)) |inst| {
            const ok = version_mod.satisfies(inst.version, constraint) catch {
                self.diagnostics.* = .{ .package = name, .constraint = constraint };
                return error.InvalidConstraint;
            };
            if (ok) return;
        }

        if (self.states.get(name)) |state| switch (state) {
            .done => {
                // Already planned: just check the new constraint against
                // the version we settled on.
                try self.checkPlanned(name, constraint);
                return;
            },
            .in_progress => {
                self.diagnostics.* = .{ .package = name };
                return error.CircularDependency;
            },
            .unvisited => {},
        };

        const candidate = self.provider.lookup(name) orelse {
            self.diagnostics.* = .{ .package = name };
            return error.PackageNotFound;
        };

        const ok = version_mod.satisfies(candidate.version, constraint) catch {
            self.diagnostics.* = .{ .package = name, .constraint = constraint };
            return error.InvalidConstraint;
        };
        if (!ok) {
            self.diagnostics.* = .{ .package = name, .constraint = constraint, .available = candidate.version };
            return error.VersionConflict;
        }

        self.states.put(name, .in_progress) catch return error.PackageNotFound;

        for (candidate.dependencies) |dep| {
            try self.visit(dep.name, dep.version_constraint);
        }

        self.states.put(name, .done) catch return error.PackageNotFound;
        // Appended after its dependencies, which is what makes the final
        // order a valid install order.
        self.result.append(candidate) catch return error.PackageNotFound;
    }

    fn checkPlanned(self: *Resolver, name: []const u8, constraint: []const u8) ResolveError!void {
        for (self.result.items) |c| {
            if (!std.mem.eql(u8, c.name, name)) continue;
            const ok = version_mod.satisfies(c.version, constraint) catch {
                self.diagnostics.* = .{ .package = name, .constraint = constraint };
                return error.InvalidConstraint;
            };
            if (!ok) {
                self.diagnostics.* = .{ .package = name, .constraint = constraint, .available = c.version };
                return error.VersionConflict;
            }
            return;
        }
    }
};

/// Resolves `requested` package names into an install order.
/// `diagnostics` is filled in on failure and may be ignored on success.
pub fn resolve(
    allocator: std.mem.Allocator,
    provider: Provider,
    requested: []const []const u8,
    diagnostics: *Diagnostics,
) !Plan {
    var states = std.StringHashMap(State).init(allocator);
    defer states.deinit();

    var result = std.ArrayList(Candidate).init(allocator);
    errdefer result.deinit();

    var r = Resolver{
        .allocator = allocator,
        .provider = provider,
        .states = &states,
        .result = &result,
        .diagnostics = diagnostics,
    };

    for (requested) |name| {
        try r.visit(name, "*");
    }

    return .{ .order = try result.toOwnedSlice(), .allocator = allocator };
}

// --- tests -----------------------------------------------------------

const TestRepo = struct {
    candidates: []const Candidate,
    installed_pkgs: []const Candidate = &.{},

    fn lookup(ctx: *const anyopaque, name: []const u8) ?Candidate {
        const self: *const TestRepo = @ptrCast(@alignCast(ctx));
        for (self.candidates) |c| {
            if (std.mem.eql(u8, c.name, name)) return c;
        }
        return null;
    }

    fn installed(ctx: *const anyopaque, name: []const u8) ?Candidate {
        const self: *const TestRepo = @ptrCast(@alignCast(ctx));
        for (self.installed_pkgs) |c| {
            if (std.mem.eql(u8, c.name, name)) return c;
        }
        return null;
    }

    fn provider(self: *const TestRepo) Provider {
        return .{ .ctx = self, .lookupFn = lookup, .installedFn = installed };
    }
};

fn indexOfName(plan: Plan, name: []const u8) ?usize {
    for (plan.order, 0..) |c, i| {
        if (std.mem.eql(u8, c.name, name)) return i;
    }
    return null;
}

test "dependencies are ordered before the packages that need them" {
    const allocator = std.testing.allocator;
    const repo = TestRepo{ .candidates = &.{
        .{ .name = "app", .version = "1.0.0", .dependencies = &.{
            .{ .name = "libfoo", .version_constraint = ">=1.0.0" },
        } },
        .{ .name = "libfoo", .version = "1.2.0", .dependencies = &.{
            .{ .name = "libc", .version_constraint = "*" },
        } },
        .{ .name = "libc", .version = "2.0.0" },
    } };

    var diags = Diagnostics{};
    var plan = try resolve(allocator, repo.provider(), &.{"app"}, &diags);
    defer plan.deinit();

    try std.testing.expectEqual(@as(usize, 3), plan.order.len);
    try std.testing.expect(indexOfName(plan, "libc").? < indexOfName(plan, "libfoo").?);
    try std.testing.expect(indexOfName(plan, "libfoo").? < indexOfName(plan, "app").?);
}

test "a shared dependency appears exactly once" {
    const allocator = std.testing.allocator;
    const repo = TestRepo{ .candidates = &.{
        .{ .name = "a", .version = "1.0.0", .dependencies = &.{.{ .name = "shared", .version_constraint = "*" }} },
        .{ .name = "b", .version = "1.0.0", .dependencies = &.{.{ .name = "shared", .version_constraint = "*" }} },
        .{ .name = "shared", .version = "1.0.0" },
    } };

    var diags = Diagnostics{};
    var plan = try resolve(allocator, repo.provider(), &.{ "a", "b" }, &diags);
    defer plan.deinit();

    try std.testing.expectEqual(@as(usize, 3), plan.order.len);
    var shared_count: usize = 0;
    for (plan.order) |c| {
        if (std.mem.eql(u8, c.name, "shared")) shared_count += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), shared_count);
}

test "circular dependencies are detected" {
    const allocator = std.testing.allocator;
    const repo = TestRepo{ .candidates = &.{
        .{ .name = "a", .version = "1.0.0", .dependencies = &.{.{ .name = "b", .version_constraint = "*" }} },
        .{ .name = "b", .version = "1.0.0", .dependencies = &.{.{ .name = "a", .version_constraint = "*" }} },
    } };

    var diags = Diagnostics{};
    try std.testing.expectError(
        error.CircularDependency,
        resolve(allocator, repo.provider(), &.{"a"}, &diags),
    );
    try std.testing.expectEqualStrings("a", diags.package);
}

test "self-dependency is caught as a cycle" {
    const allocator = std.testing.allocator;
    const repo = TestRepo{ .candidates = &.{
        .{ .name = "a", .version = "1.0.0", .dependencies = &.{.{ .name = "a", .version_constraint = "*" }} },
    } };

    var diags = Diagnostics{};
    try std.testing.expectError(
        error.CircularDependency,
        resolve(allocator, repo.provider(), &.{"a"}, &diags),
    );
}

test "a missing package is reported with its name" {
    const allocator = std.testing.allocator;
    const repo = TestRepo{ .candidates = &.{
        .{ .name = "a", .version = "1.0.0", .dependencies = &.{.{ .name = "ghost", .version_constraint = "*" }} },
    } };

    var diags = Diagnostics{};
    try std.testing.expectError(
        error.PackageNotFound,
        resolve(allocator, repo.provider(), &.{"a"}, &diags),
    );
    try std.testing.expectEqualStrings("ghost", diags.package);
}

test "an unsatisfiable constraint is a version conflict" {
    const allocator = std.testing.allocator;
    const repo = TestRepo{ .candidates = &.{
        .{ .name = "a", .version = "1.0.0", .dependencies = &.{
            .{ .name = "libfoo", .version_constraint = ">=2.0.0" },
        } },
        .{ .name = "libfoo", .version = "1.0.0" },
    } };

    var diags = Diagnostics{};
    try std.testing.expectError(
        error.VersionConflict,
        resolve(allocator, repo.provider(), &.{"a"}, &diags),
    );
    try std.testing.expectEqualStrings("libfoo", diags.package);
    try std.testing.expectEqualStrings("1.0.0", diags.available);
}

test "two packages requiring incompatible versions of one dependency conflict" {
    const allocator = std.testing.allocator;
    const repo = TestRepo{ .candidates = &.{
        .{ .name = "a", .version = "1.0.0", .dependencies = &.{.{ .name = "lib", .version_constraint = "^1.0.0" }} },
        .{ .name = "b", .version = "1.0.0", .dependencies = &.{.{ .name = "lib", .version_constraint = "^2.0.0" }} },
        .{ .name = "lib", .version = "1.5.0" },
    } };

    var diags = Diagnostics{};
    try std.testing.expectError(
        error.VersionConflict,
        resolve(allocator, repo.provider(), &.{ "a", "b" }, &diags),
    );
    try std.testing.expectEqualStrings("lib", diags.package);
}

test "already-installed dependencies are skipped" {
    const allocator = std.testing.allocator;
    const repo = TestRepo{
        .candidates = &.{
            .{ .name = "app", .version = "1.0.0", .dependencies = &.{.{ .name = "lib", .version_constraint = ">=1.0.0" }} },
            .{ .name = "lib", .version = "1.0.0" },
        },
        .installed_pkgs = &.{.{ .name = "lib", .version = "1.4.0" }},
    };

    var diags = Diagnostics{};
    var plan = try resolve(allocator, repo.provider(), &.{"app"}, &diags);
    defer plan.deinit();

    try std.testing.expectEqual(@as(usize, 1), plan.order.len);
    try std.testing.expectEqualStrings("app", plan.order[0].name);
}

test "an installed version that does not satisfy the constraint is still resolved" {
    const allocator = std.testing.allocator;
    const repo = TestRepo{
        .candidates = &.{
            .{ .name = "app", .version = "1.0.0", .dependencies = &.{.{ .name = "lib", .version_constraint = ">=2.0.0" }} },
            .{ .name = "lib", .version = "2.1.0" },
        },
        .installed_pkgs = &.{.{ .name = "lib", .version = "1.0.0" }},
    };

    var diags = Diagnostics{};
    var plan = try resolve(allocator, repo.provider(), &.{"app"}, &diags);
    defer plan.deinit();

    try std.testing.expectEqual(@as(usize, 2), plan.order.len);
    try std.testing.expect(plan.contains("lib"));
}

test "resolution order is deterministic across runs" {
    const allocator = std.testing.allocator;
    const repo = TestRepo{ .candidates = &.{
        .{ .name = "app", .version = "1.0.0", .dependencies = &.{
            .{ .name = "x", .version_constraint = "*" },
            .{ .name = "y", .version_constraint = "*" },
            .{ .name = "z", .version_constraint = "*" },
        } },
        .{ .name = "x", .version = "1.0.0" },
        .{ .name = "y", .version = "1.0.0" },
        .{ .name = "z", .version = "1.0.0" },
    } };

    var diags = Diagnostics{};
    var first = try resolve(allocator, repo.provider(), &.{"app"}, &diags);
    defer first.deinit();
    var second = try resolve(allocator, repo.provider(), &.{"app"}, &diags);
    defer second.deinit();

    try std.testing.expectEqual(first.order.len, second.order.len);
    for (first.order, second.order) |a, b| {
        try std.testing.expectEqualStrings(a.name, b.name);
    }
}
