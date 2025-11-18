const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Get zigeth dependency
    const zigeth_dep = b.dependency("zigeth", .{
        .target = target,
        .optimize = optimize,
    });
    const zigeth_mod = zigeth_dep.module("zigeth");

    const sequencer_module = b.addModule("native-sequencer", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    sequencer_module.addImport("zigeth", zigeth_mod);

    // Library
    const lib = b.addLibrary(.{
        .name = "native-sequencer",
        .linkage = .static,
        .root_module = sequencer_module,
    });
    // Link zigeth's secp256k1 dependency
    const secp256k1_dep = b.dependency("zig_eth_secp256k1", .{
        .target = target,
        .optimize = optimize,
    });
    const secp256k1_artifact = secp256k1_dep.artifact("secp256k1");
    lib.linkLibrary(secp256k1_artifact);
    lib.linkLibC();
    b.installArtifact(lib);

    // Main executable
    const exe = b.addExecutable(.{
        .name = "sequencer",
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    exe.root_module.addImport("native-sequencer", sequencer_module);
    // Add zigeth to executable so it's available to all files
    exe.root_module.addImport("zigeth", zigeth_mod);
    
    // Link zigeth's secp256k1 dependency
    const secp256k1_dep_exe = b.dependency("zig_eth_secp256k1", .{
        .target = target,
        .optimize = optimize,
    });
    const secp256k1_artifact_exe = secp256k1_dep_exe.artifact("secp256k1");
    exe.linkLibrary(secp256k1_artifact_exe);
    exe.linkLibC();
    
    b.installArtifact(exe);

    // Run step
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }
    const run_step = b.step("run", "Run the sequencer");
    run_step.dependOn(&run_cmd.step);

    // Tests
    const unit_tests = b.addTest(.{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    unit_tests.root_module.addImport("native-sequencer", sequencer_module);
    // unit_tests.root_module already has zigeth import via sequencer_module
    const secp256k1_dep_test = b.dependency("zig_eth_secp256k1", .{
        .target = target,
        .optimize = optimize,
    });
    const secp256k1_artifact_test = secp256k1_dep_test.artifact("secp256k1");
    unit_tests.linkLibrary(secp256k1_artifact_test);
    unit_tests.linkLibC();
    const run_unit_tests = b.addRunArtifact(unit_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_unit_tests.step);

    // Lint
    const lint_cmd = b.addSystemCommand(&.{ "zig", "fmt", "--check", "src" });
    const lint_step = b.step("lint", "Run lint (zig fmt --check)");
    lint_step.dependOn(&lint_cmd.step);
}

