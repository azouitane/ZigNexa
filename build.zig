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

    const httpz_lifecycle_tests = b.addTest(.{
        .root_module = httpz.module("httpz"),
        .filters = &.{"startup failure closes listener"},
    });
    httpz_lifecycle_tests.linkLibC();
    const run_httpz_lifecycle_tests = b.addRunArtifact(httpz_lifecycle_tests);
    test_step.dependOn(&run_httpz_lifecycle_tests.step);
    const listener_test_step = b.step("test-listener-cleanup", "Run httpz listener startup cleanup regression tests");
    listener_test_step.dependOn(&run_httpz_lifecycle_tests.step);

    const integration_tests = b.addTest(.{
        .root_module = library_module,
        .filters = &.{"live HTTP requests exercise routes middleware and shutdown"},
    });
    const run_integration_tests = b.addRunArtifact(integration_tests);
    test_step.dependOn(&run_integration_tests.step);
    const integration_test_step = b.step("test-http-integration", "Run loopback HTTP integration test");
    integration_test_step.dependOn(&run_integration_tests.step);

    const example = b.addExecutable(.{
        .name = "zignexa-basic",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/basic.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "zignexa", .module = library_module }},
        }),
    });
    const example_step = b.step("example", "Build the basic ZigNexa example");
    example_step.dependOn(&b.addInstallArtifact(example, .{}).step);
    const run_example_step = b.step("run-example", "Run the basic ZigNexa example");
    const run_example = b.addRunArtifact(example);
    run_example_step.dependOn(&run_example.step);
    const run_step = b.step("run", "Run the basic ZigNexa example");
    run_step.dependOn(&run_example.step);
    if (b.args) |args| {
        run_example.addArgs(args);
    }
}
