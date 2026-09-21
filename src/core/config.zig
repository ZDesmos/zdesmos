//! Runtime configuration for zdms. Phase 1 ships hardcoded defaults only;
//! loading `/etc/zdms/config.*` is left for a later phase (the struct shape
//! is stable so that loader can just populate it).

const std = @import("std");
const errors = @import("errors.zig");
const arch = @import("arch.zig");

pub const Config = struct {
    /// Directory holding downloaded/cached .zpkg files.
    cache_dir: []const u8 = "/var/cache/zdms/",
    /// Directory holding the local package database: one JSON file per
    /// installed package (`<database_path>/<name>.json`).
    database_path: []const u8 = "/var/lib/zdms/db",
    /// Filesystem root that package file paths are installed relative to.
    /// "/" for a real system install; tests and `--root` (future) point
    /// this elsewhere so nothing touches the real filesystem.
    install_root: []const u8 = "/",
    /// Bounded concurrency for package downloads.
    max_parallel_downloads: u32 = 4,
    /// Network timeout, in milliseconds, for a single request.
    network_timeout_ms: u32 = 30_000,
    /// Number of retry attempts for a failed download.
    download_retries: u32 = 3,
    /// Path to the repositories list (JSON array of `Repository`).
    /// Loading it is `repos.load`; an absent file simply means "no
    /// repositories configured" rather than an error.
    repositories_path: []const u8 = "/etc/zdms/repositories.json",
    /// Which architecture's packages to install. Repository lookups only
    /// match index entries with this exact architecture string (see
    /// `arch.Architecture`), so a multi-arch repository -- like
    /// https://github.com/ZDesmos/zdesmos-package -- serves the right
    /// build without the resolver ever seeing the others.
    architecture: []const u8 = "x86_64",

    pub fn validate(self: Config) errors.ConfigError!void {
        if (self.max_parallel_downloads == 0) return error.InvalidValue;
        if (self.cache_dir.len == 0) return error.InvalidPath;
        if (self.database_path.len == 0) return error.InvalidPath;
        if (self.install_root.len == 0) return error.InvalidPath;
        if (arch.Architecture.parse(self.architecture) == null) return error.InvalidValue;
    }
};

pub fn default() Config {
    return Config{};
}

test "default config is valid" {
    try default().validate();
}

test "zero concurrency is rejected" {
    var cfg = default();
    cfg.max_parallel_downloads = 0;
    try std.testing.expectError(error.InvalidValue, cfg.validate());
}

test "empty cache_dir is rejected" {
    var cfg = default();
    cfg.cache_dir = "";
    try std.testing.expectError(error.InvalidPath, cfg.validate());
}
