const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const httpz = b.dependency("httpz", .{ .target = target, .optimize = optimize });

    const library_module = b.addModule("zignexa", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    library_module.addImport("httpz", httpz.module("httpz"));

    const tests = b.addTest(.{ .root_module = library_module });
    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run ZigNexa tests");
    test_step.dependOn(&run_tests.step);

    const example = b.addExecutable(.{
        .name = "zignexa-hello-world",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/hello-world/src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "zignexa", .module = library_module }},
        }),
    });
    const example_step = b.step("example", "Build the Hello World example");
    example_step.dependOn(&b.addInstallArtifact(example, .{}).step);
    const run_example_step = b.step("run-example", "Run the Hello World example");
    const run_example = b.addRunArtifact(example);
    run_example_step.dependOn(&run_example.step);
    const run_step = b.step("run", "Run the Hello World example");
    run_step.dependOn(&run_example.step);
    if (b.args) |args| run_example.addArgs(args);
}
