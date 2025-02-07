const std = @import("std");
pub fn build(bld: *std.Build) void {
    const target = bld.standardTargetOptions(.{});
    const optimize = bld.standardOptimizeOption(.{});

    // vanish executable
    //
    const vsh_mod = bld.createModule(.{
        .root_source_file = bld.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    const vsh_exe = bld.addExecutable(.{
        .name = "vanish",
        .root_module = vsh_mod,
    });

    bld.installArtifact(vsh_exe);

    const run_exe = bld.addRunArtifact(vsh_exe);
    run_exe.step.dependOn(bld.getInstallStep());

    if (bld.args) |args| {
        run_exe.addArgs(args);
    }

    const run_step = bld.step("run", "Run the app");
    run_step.dependOn(&run_exe.step);

    // Test executable
    //
    const test_mod = bld.createModule(.{
        .root_source_file = bld.path("src/test_main.zig"),
        .target = target,
        .optimize = optimize,
    });

    const test_exe = bld.addExecutable(.{
        .name = "test",
        .root_module = test_mod,
    });
    bld.installArtifact(test_exe);

    const run_test = bld.addRunArtifact(test_exe);
    const test_step = bld.step("test", "Run the test suite");
    test_step.dependOn(&run_test.step);
}
