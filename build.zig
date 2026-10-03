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
}
