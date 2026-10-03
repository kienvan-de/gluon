const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // The gluon module (public API will grow as phases land).
    const gluon_mod = b.addModule("gluon", .{
        .root_source_file = b.path("src/gluon.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Unit tests over the whole source tree (via gluon.zig's test refs).
    const tests = b.addTest(.{
        .root_module = gluon_mod,
    });
    const run_tests = b.addRunArtifact(tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_tests.step);
}
