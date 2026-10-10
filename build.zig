const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // The gluon public module.
    const gluon_mod = b.addModule("gluon", .{
        .root_source_file = b.path("src/gluon.zig"),
        .target = target,
        .optimize = optimize,
    });

    // The plugin-side ABI module (no Gluon internals — safe to link into .so).
    const gluon_abi_mod = b.createModule(.{
        .root_source_file = b.path("src/ext/gluon_abi.zig"),
        .target = target,
        .optimize = optimize,
    });

    const test_step = b.step("test", "Run unit tests");

    // Unit tests over the whole source tree (via gluon.zig's test refs).
    const tests = b.addTest(.{ .root_module = gluon_mod });
    test_step.dependOn(&b.addRunArtifact(tests).step);

    // Example tests: compile-check the README quickstart against the real API.
    const example_mod = b.createModule(.{
        .root_source_file = b.path("examples/readme_quickstart.zig"),
        .target = target,
        .optimize = optimize,
    });
    example_mod.addImport("gluon", gluon_mod);
    const example_tests = b.addTest(.{ .root_module = example_mod });
    test_step.dependOn(&b.addRunArtifact(example_tests).step);

    // Hello-greeter end-to-end example: tested (deterministic, scripted IO) and
    // runnable (`zig build run-hello`, uses real stdin/stdout).
    const hello_mod = b.createModule(.{
        .root_source_file = b.path("examples/hello_greeter.zig"),
        .target = target,
        .optimize = optimize,
    });
    hello_mod.addImport("gluon", gluon_mod);
    const hello_tests = b.addTest(.{ .root_module = hello_mod });
    test_step.dependOn(&b.addRunArtifact(hello_tests).step);

    // Pattern A — service via coeffect store.
    const pat_a_mod = b.createModule(.{
        .root_source_file = b.path("examples/pattern_a_service.zig"),
        .target = target,
        .optimize = optimize,
    });
    pat_a_mod.addImport("gluon", gluon_mod);
    const pat_a_tests = b.addTest(.{ .root_module = pat_a_mod });
    test_step.dependOn(&b.addRunArtifact(pat_a_tests).step);

    // Pattern B — pub/sub via EventBus.
    const pat_b_mod = b.createModule(.{
        .root_source_file = b.path("examples/pattern_b_eventbus.zig"),
        .target = target,
        .optimize = optimize,
    });
    pat_b_mod.addImport("gluon", gluon_mod);
    const pat_b_tests = b.addTest(.{ .root_module = pat_b_mod });
    test_step.dependOn(&b.addRunArtifact(pat_b_tests).step);

    // Ext end-to-end example (inline vtables, no dlopen).
    const ext_ex_mod = b.createModule(.{
        .root_source_file = b.path("examples/ext/ext_example.zig"),
        .target = target,
        .optimize = optimize,
    });
    ext_ex_mod.addImport("gluon", gluon_mod);
    const ext_ex_tests = b.addTest(.{ .root_module = ext_ex_mod });
    test_step.dependOn(&b.addRunArtifact(ext_ex_tests).step);

    // ── Ext shared libraries ─────────────────────────────────────────────────
    //
    // Build the example extensions as real shared libraries, then run an
    // integration test that loads them via ExtLoader.open (real dlopen).
    const ext_step = b.step("ext-plugins", "Build ext plugin shared libraries");

    // Zig printer plugin (.so / .dylib)
    const zig_printer_mod = b.createModule(.{
        .root_source_file = b.path("examples/ext/ext_printer.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    zig_printer_mod.addImport("gluon_abi", gluon_abi_mod);
    const zig_printer_lib = b.addLibrary(.{
        .name = "gluon_zig_printer",
        .linkage = .dynamic,
        .root_module = zig_printer_mod,
    });
    b.installArtifact(zig_printer_lib);
    ext_step.dependOn(&zig_printer_lib.step);

    // C printer plugin (.so / .dylib) — proves C works with the same ABI.
    const c_printer_mod = b.createModule(.{
        .target = target,
        .optimize = optimize,
    });
    c_printer_mod.addCSourceFile(.{
        .file = b.path("examples/ext/ext_printer.c"),
        .flags = &.{"-std=c99"},
    });
    c_printer_mod.addIncludePath(b.path("include"));
    c_printer_mod.link_libc = true;
    const c_printer_lib = b.addLibrary(.{
        .name = "gluon_c_printer",
        .linkage = .dynamic,
        .root_module = c_printer_mod,
    });
    b.installArtifact(c_printer_lib);
    ext_step.dependOn(&c_printer_lib.step);

    // Zig greeter extension (.so / .dylib) — Pattern A: opaque service via store.
    const zig_greeter_mod = b.createModule(.{
        .root_source_file = b.path("examples/ext/ext_greeter.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    zig_greeter_mod.addImport("gluon_abi", gluon_abi_mod);
    const zig_greeter_lib = b.addLibrary(.{
        .name = "gluon_zig_greeter",
        .linkage = .dynamic,
        .root_module = zig_greeter_mod,
    });
    b.installArtifact(zig_greeter_lib);
    ext_step.dependOn(&zig_greeter_lib.step);

    // C greeter extension.
    const c_greeter_mod = b.createModule(.{
        .target = target,
        .optimize = optimize,
    });
    c_greeter_mod.addCSourceFile(.{
        .file = b.path("examples/ext/ext_greeter.c"),
        .flags = &.{"-std=c99"},
    });
    c_greeter_mod.addIncludePath(b.path("include"));
    c_greeter_mod.link_libc = true;
    const c_greeter_lib = b.addLibrary(.{
        .name = "gluon_c_greeter",
        .linkage = .dynamic,
        .root_module = c_greeter_mod,
    });
    b.installArtifact(c_greeter_lib);
    ext_step.dependOn(&c_greeter_lib.step);

    // Integration test: actual ExtLoader.open with compiled .so files.
    // Lives under a SEPARATE step (test-ext) so `zig build test` doesn't
    // need to compile two shared libraries on every run.
    // Run with: zig build test-ext
    const build_paths = b.addOptions();
    build_paths.addOptionPath("zig_printer_path", zig_printer_lib.getEmittedBin());
    build_paths.addOptionPath("c_printer_path",   c_printer_lib.getEmittedBin());
    build_paths.addOptionPath("zig_greeter_path", zig_greeter_lib.getEmittedBin());
    build_paths.addOptionPath("c_greeter_path",   c_greeter_lib.getEmittedBin());

    const ext_load_mod = b.createModule(.{
        .root_source_file = b.path("examples/ext/ext_load_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    ext_load_mod.addImport("gluon", gluon_mod);
    ext_load_mod.addOptions("build_paths", build_paths);
    // Build as a standalone executable (not under --listen=- IPC), because
    // dlopen inside the Zig 0.17 test runner IPC loop deadlocks on macOS.
    const ext_load_exe = b.addExecutable(.{
        .name = "ext-load-test",
        .root_module = ext_load_mod,
    });
    ext_load_exe.step.dependOn(&zig_printer_lib.step);
    ext_load_exe.step.dependOn(&c_printer_lib.step);
    ext_load_exe.step.dependOn(&zig_greeter_lib.step);
    ext_load_exe.step.dependOn(&c_greeter_lib.step);
    const run_ext_load = b.addRunArtifact(ext_load_exe);
    run_ext_load.setCwd(b.path("."));
    const ext_test_step = b.step("test-ext", "Run ExtLoader integration tests (builds .so extensions)");
    ext_test_step.dependOn(&run_ext_load.step);
    // NOTE: not added to test_step — building two shared libraries is slow.
    // Run separately with: zig build test-ext

    const hello_exe = b.addExecutable(.{ .name = "hello-greeter", .root_module = hello_mod });
    const run_hello = b.addRunArtifact(hello_exe);
    // pass-through args removed (not supported in this Zig version)
    const run_step = b.step("run-hello", "Run the hello-greeter example");
    run_step.dependOn(&run_hello.step);
}
