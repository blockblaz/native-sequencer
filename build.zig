const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    _ = b.standardOptimizeOption(.{}); // Available for future use

    // Enable address sanitizer option
    const sanitize = b.option(bool, "sanitize", "Enable address sanitizer (default: false)") orelse false;

    // LMDB is used for persistence
    // Helper function to add LMDB linking with cross-compilation support
    const addLmdbLink = struct {
        fn add(_: *std.Build, comp: *std.Build.Step.Compile, resolved_target: std.Build.ResolvedTarget) void {
            // Skip LMDB on Windows (not easily available, use in-memory state instead)
            if (resolved_target.result.os.tag == .windows) {
                return;
            }
            // Add library search paths for cross-compilation (Linux only)
            if (resolved_target.result.os.tag == .linux) {
                // Common paths for cross-compilation libraries
                // Use cwd_relative for absolute paths
                comp.addLibraryPath(.{ .cwd_relative = "/usr/lib/x86_64-linux-gnu" });
                comp.addLibraryPath(.{ .cwd_relative = "/usr/x86_64-linux-gnu/lib" });
            }
            // For macOS, try to link LMDB - if cross-compiling to different arch, it will fail gracefully
            // (Homebrew installs architecture-specific libraries, so cross-compilation may not work)
            // We let the linker fail if the library architecture doesn't match
            comp.linkSystemLibrary("lmdb");
        }
    }.add;

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
    var cflags = std.ArrayList([]const u8).init(b.allocator);
    defer cflags.deinit();
    cflags.appendSlice(&.{
        "-DUSE_FIELD_10X26=1",
        "-DUSE_SCALAR_8X32=1",
        "-DUSE_ENDOMORPHISM=1",
        "-DUSE_NUM_NONE=1",
        "-DUSE_FIELD_INV_BUILTIN=1",
        "-DUSE_SCALAR_INV_BUILTIN=1",
    }) catch @panic("OOM");
    if (sanitize) {
        cflags.append("-fsanitize=address") catch @panic("OOM");
    }
    libsecp256k1.addCSourceFile(.{ .file = b.path("vendor/zig-eth-secp256k1/ext.c"), .flags = cflags.items });
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

    // Add LMDB include paths for cross-compilation
    if (target.result.os.tag == .linux) {
        sequencer_module.addIncludePath(.{ .cwd_relative = "/usr/include" });
        sequencer_module.addIncludePath(.{ .cwd_relative = "/usr/x86_64-linux-gnu/include" });
    }

    // LMDB is linked as a system library (liblmdb)

    // Library
    const lib = b.addLibrary(.{
        .name = "native-sequencer",
        .linkage = .static,
        .root_module = sequencer_module,
    });
    // Add LMDB include paths for C imports (needed for @cImport)
    if (target.result.os.tag == .linux) {
        lib.addIncludePath(.{ .cwd_relative = "/usr/include" });
        lib.addIncludePath(.{ .cwd_relative = "/usr/x86_64-linux-gnu/include" });
    }
    // Link secp256k1 library
    lib.linkLibrary(libsecp256k1);
    // Link LMDB system library (with cross-compilation support)
    addLmdbLink(b, lib, target);
    lib.linkLibC();
    if (sanitize) {
        lib.linkSystemLibrary("asan");
    }
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
    // Add LMDB include paths for C imports (needed for @cImport)
    if (target.result.os.tag == .linux) {
        exe.addIncludePath(.{ .cwd_relative = "/usr/include" });
        exe.addIncludePath(.{ .cwd_relative = "/usr/x86_64-linux-gnu/include" });
    }
    // Link secp256k1 library
    exe.linkLibrary(libsecp256k1);
    // Link LMDB system library (with cross-compilation support)
    addLmdbLink(b, exe, target);
    exe.linkLibC();
    if (sanitize) {
        exe.linkSystemLibrary("asan");
    }

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
    // Add LMDB include paths for C imports (needed for @cImport)
    if (target.result.os.tag == .linux) {
        unit_tests.addIncludePath(.{ .cwd_relative = "/usr/include" });
        unit_tests.addIncludePath(.{ .cwd_relative = "/usr/x86_64-linux-gnu/include" });
    }
    // Link secp256k1 library
    unit_tests.linkLibrary(libsecp256k1);
    // Link LMDB system library (with cross-compilation support)
    addLmdbLink(b, unit_tests, target);
    unit_tests.linkLibC();
    if (sanitize) {
        unit_tests.linkSystemLibrary("asan");
    }
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
