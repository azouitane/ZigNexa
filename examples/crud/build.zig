const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const zignexa = b.dependency("zignexa", .{ .target = target, .optimize = optimize });
    const exe = b.addExecutable(.{
        .name = "zignexa-crud-demo",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "zignexa", .module = zignexa.module("zignexa") }},
        }),
    });
    b.installArtifact(exe);
    const run_step = b.step("run", "Run the CRUD example on port 8080");
    const run = b.addRunArtifact(exe);
    run_step.dependOn(&run.step);
}
