const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const dep_opts = .{ .target = target, .optimize = optimize };
    const metrics_module = b.dependency("metrics", dep_opts).module("metrics");
    const websocket_module = b.dependency("websocket", dep_opts).module("websocket");

    const httpz_module = b.addModule("httpz", .{
        .root_source_file = b.path("src/httpz.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "metrics", .module = metrics_module },
            .{ .name = "websocket", .module = websocket_module },
        },
    });
    const options = b.addOptions();
    options.addOption(bool, "httpz_blocking", false);
    httpz_module.addOptions("build", options);

    const tests = b.addTest(.{
        .root_module = httpz_module,
        .filters = &.{"startup failure closes listener"},
    });
    tests.linkLibC();
    const test_step = b.step("test", "Run focused listener lifecycle regression test");
    test_step.dependOn(&b.addRunArtifact(tests).step);
}
