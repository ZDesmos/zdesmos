//! `zig build test` runs this file. Zig only discovers `test {}` blocks
//! reachable from the given root, so every module with tests must be
//! referenced here.

test {
    _ = @import("cli/args.zig");
    _ = @import("cli/commands.zig");
    _ = @import("core/arch.zig");
    _ = @import("core/cache.zig");
    _ = @import("core/config.zig");
    _ = @import("core/log.zig");
    _ = @import("core/install.zig");
    _ = @import("core/plan.zig");
    _ = @import("core/transaction.zig");
    _ = @import("database/db.zig");
    _ = @import("downloader/http.zig");
    _ = @import("downloader/parallel.zig");
    _ = @import("package/checksum.zig");
    _ = @import("package/manifest.zig");
    _ = @import("package/archive.zig");
    _ = @import("package/package.zig");
    _ = @import("repository/index.zig");
    _ = @import("repository/repository.zig");
    _ = @import("repository/repos_config.zig");
    _ = @import("resolver/version.zig");
    _ = @import("resolver/resolver.zig");
    _ = @import("security/signature.zig");
}
