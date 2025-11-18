const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    _ = b.standardOptimizeOption(.{}); // Available for future use

    // Build libsecp256k1 static C library from vendor directory
    // In Zig 0.15, we create a library with a dummy Zig root module
    const libsecp256k1_root = b.addModule("secp256k1_lib", .{
        .root_source_file = b.path("vendor/zig-eth-secp256k1/secp256k1_wrapper.zig"),
        .target = target,
    });
    
    const libsecp256k1 = b.addLibrary(.{
        .name = "secp256k1",
        .linkage = .static,
        .root_module = libsecp256k1_root,
    });
    libsecp256k1.addIncludePath(b.path("vendor/zig-eth-secp256k1/libsecp256k1"));
    libsecp256k1.addIncludePath(b.path("vendor/zig-eth-secp256k1/libsecp256k1/src"));
    const cflags = .{
        "-DUSE_FIELD_10X26=1",
        "-DUSE_SCALAR_8X32=1",
        "-DUSE_ENDOMORPHISM=1",
        "-DUSE_NUM_NONE=1",
        "-DUSE_FIELD_INV_BUILTIN=1",
        "-DUSE_SCALAR_INV_BUILTIN=1",
    };
    libsecp256k1.addCSourceFile(.{ .file = b.path("vendor/zig-eth-secp256k1/ext.c"), .flags = &cflags });
    libsecp256k1.linkLibC();
    b.installArtifact(libsecp256k1);

    // Add secp256k1 module (Zig wrapper)
    const secp256k1_mod = b.addModule("secp256k1", .{
        .root_source_file = b.path("vendor/zig-eth-secp256k1/src/secp256k1.zig"),
        .target = target,
    });
    secp256k1_mod.addIncludePath(b.path("vendor/zig-eth-secp256k1"));
    secp256k1_mod.addIncludePath(b.path("vendor/zig-eth-secp256k1/libsecp256k1"));

    const sequencer_module = b.addModule("native-sequencer", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
    });
    sequencer_module.addImport("secp256k1", secp256k1_mod);

    // Library
    const lib = b.addLibrary(.{
        .name = "native-sequencer",
        .linkage = .static,
        .root_module = sequencer_module,
    });
    // Link secp256k1 library
    lib.linkLibrary(libsecp256k1);
    lib.linkLibC();
    b.installArtifact(lib);

    // Main executable
    const exe_module = b.addModule("sequencer_exe", .{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
    });
    const exe = b.addExecutable(.{
        .name = "sequencer",
        .root_module = exe_module,
    });
    exe.root_module.addImport("native-sequencer", sequencer_module);
    exe.root_module.addImport("secp256k1", secp256k1_mod);
    // Link secp256k1 library
    exe.linkLibrary(libsecp256k1);
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
    const test_module = b.addModule("test_module", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
    });
    const unit_tests = b.addTest(.{
        .root_module = test_module,
    });
    unit_tests.root_module.addImport("native-sequencer", sequencer_module);
    unit_tests.root_module.addImport("secp256k1", secp256k1_mod);
    // Link secp256k1 library
    unit_tests.linkLibrary(libsecp256k1);
    unit_tests.linkLibC();
    const run_unit_tests = b.addRunArtifact(unit_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_unit_tests.step);

    // Lint
    const lint_cmd = b.addSystemCommand(&.{ "zig", "fmt", "--check", "src" });
    const lint_step = b.step("lint", "Run lint (zig fmt --check)");
    lint_step.dependOn(&lint_cmd.step);
}


