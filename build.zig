const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Main executable: zdms
    const exe = b.addExecutable(.{
        .name = "zdms",
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);

    const run_step = b.step("run", "Run zdms");
    run_step.dependOn(&run_cmd.step);

    // Unit tests: root file pulls in every module under test.
    const unit_tests = b.addTest(.{
        .root_source_file = b.path("src/tests.zig"),
        .target = target,
        .optimize = optimize,
    });
    const run_unit_tests = b.addRunArtifact(unit_tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_unit_tests.step);

    // Benchmarks. Build these in ReleaseFast for numbers worth reading:
    //   zig build bench -Doptimize=ReleaseFast
    const bench = b.addExecutable(.{
        .name = "zdms-bench",
        .root_source_file = b.path("src/bench.zig"),
        .target = target,
        .optimize = optimize,
    });
    const run_bench = b.addRunArtifact(bench);
    const bench_step = b.step("bench", "Run benchmarks");
    bench_step.dependOn(&run_bench.step);

    // zdms-pack: builds .zpkg files and repository index.json files.
    // Separate tool, not part of the spec's client CLI -- see src/pack.zig.
    const pack = b.addExecutable(.{
        .name = "zdms-pack",
        .root_source_file = b.path("src/pack.zig"),
        .target = target,
        .optimize = optimize,
    });
    b.installArtifact(pack);

    const run_pack = b.addRunArtifact(pack);
    run_pack.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_pack.addArgs(args);
    const pack_step = b.step("pack", "Run zdms-pack");
    pack_step.dependOn(&run_pack.step);
}
