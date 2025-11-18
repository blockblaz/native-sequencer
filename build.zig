const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    _ = b.standardOptimizeOption(.{}); // Available for future use
    
    // Note: For Linux builds, specify glibc 2.38+ in the target (e.g., x86_64-linux-gnu.2.38)
    // This is required for RocksDB compatibility (uses __isoc23_* symbols from glibc 2.38+)

    // Build libsecp256k1 static C library from vendor directory
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

    // Add RocksDB dependency (using Syndica/rocksdb-zig like zeam)
    // Note: RocksDB doesn't support Windows, so we conditionally include it
    const is_windows = target.result.os.tag == .windows;
    if (!is_windows) {
        const dep_rocksdb = b.dependency("rocksdb", .{
            .target = target,
        });
        sequencer_module.addImport("rocksdb", dep_rocksdb.module("bindings"));
    }

    // Library
    const lib = b.addLibrary(.{
        .name = "native-sequencer",
        .linkage = .static,
        .root_module = sequencer_module,
    });
    // Link secp256k1 library
    lib.linkLibrary(libsecp256k1);
    // Add RocksDB module and link library (only on non-Windows)
    if (!is_windows) {
        const dep_rocksdb = b.dependency("rocksdb", .{
            .target = target,
        });
        lib.root_module.addImport("rocksdb", dep_rocksdb.module("bindings"));
        lib.linkLibrary(dep_rocksdb.artifact("rocksdb"));
        lib.linkLibCpp(); // RocksDB requires C++ standard library
        lib.linkSystemLibrary("pthread"); // Required for pthread functions
        // librt is Linux-specific (gettid, etc.) - not needed on macOS
        if (target.result.os.tag == .linux) {
            lib.linkSystemLibrary("rt");
        }
    }
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
    // Add RocksDB module and link library (only on non-Windows)
    if (!is_windows) {
        const dep_rocksdb = b.dependency("rocksdb", .{
            .target = target,
        });
        exe.root_module.addImport("rocksdb", dep_rocksdb.module("bindings"));
        exe.linkLibrary(dep_rocksdb.artifact("rocksdb"));
        exe.linkLibCpp(); // RocksDB requires C++ standard library
        exe.linkSystemLibrary("pthread"); // Required for pthread functions
        // librt is Linux-specific (gettid, etc.) - not needed on macOS
        if (target.result.os.tag == .linux) {
            exe.linkSystemLibrary("rt");
        }
    }
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
    // Add RocksDB module and link library (only on non-Windows)
    if (!is_windows) {
        const dep_rocksdb = b.dependency("rocksdb", .{
            .target = target,
        });
        unit_tests.root_module.addImport("rocksdb", dep_rocksdb.module("bindings"));
        unit_tests.linkLibrary(dep_rocksdb.artifact("rocksdb"));
        unit_tests.linkLibCpp(); // RocksDB requires C++ standard library
        unit_tests.linkSystemLibrary("pthread"); // Required for pthread functions
        // librt is Linux-specific (gettid, etc.) - not needed on macOS
        if (target.result.os.tag == .linux) {
            unit_tests.linkSystemLibrary("rt");
        }
    }
    unit_tests.linkLibC();
    const run_unit_tests = b.addRunArtifact(unit_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_unit_tests.step);

    // Linting steps
    // Format check
    const fmt_check_cmd = b.addSystemCommand(&.{ "zig", "fmt", "--check", "src", "build.zig" });
    const lint_step = b.step("lint", "Run all linting checks (format + AST)");
    lint_step.dependOn(&fmt_check_cmd.step);

    // Format fix
    const fmt_fix_cmd = b.addSystemCommand(&.{ "zig", "fmt", "src", "build.zig" });
    const fmt_fix_step = b.step("fmt", "Format source code");
    fmt_fix_step.dependOn(&fmt_fix_cmd.step);

    // AST check for main source files
    const ast_check_main = b.addSystemCommand(&.{ "zig", "ast-check", "src/main.zig" });
    lint_step.dependOn(&ast_check_main.step);

    // AST check for core modules
    const ast_check_core = b.addSystemCommand(&.{ "zig", "ast-check", "src/core/root.zig" });
    lint_step.dependOn(&ast_check_core.step);

    // AST check for API modules
    const ast_check_api = b.addSystemCommand(&.{ "zig", "ast-check", "src/api/root.zig" });
    lint_step.dependOn(&ast_check_api.step);

    // AST check for L1 client
    const ast_check_l1 = b.addSystemCommand(&.{ "zig", "ast-check", "src/l1/client.zig" });
    lint_step.dependOn(&ast_check_l1.step);

    // Lint-fix: format code automatically
    const lint_fix_step = b.step("lint-fix", "Run lint-fix (format code)");
    lint_fix_step.dependOn(&fmt_fix_cmd.step);
}
