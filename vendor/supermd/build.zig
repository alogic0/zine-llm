const std = @import("std");

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const scripty = b.dependency("scripty", .{
        .target = target,
        .optimize = optimize,
        .tracy = false,
    });

    const ziggy = b.dependency("ziggy", .{}).module("ziggy");

    const supermd = b.addModule("supermd", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    supermd.addImport("scripty", scripty.module("scripty"));
    supermd.addImport("ziggy", ziggy);

    const docgen = b.addExecutable(.{
        .name = "docgen",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/docgen.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    docgen.root_module.addImport("ziggy", ziggy);

    b.installArtifact(docgen);

    const unit_tests = b.addTest(.{
        .root_module = supermd,
    });
    const run_unit_tests = b.addRunArtifact(unit_tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_unit_tests.step);

    const check_step = b.step("check", "Check the project");
    check_step.dependOn(&run_unit_tests.step);
}
