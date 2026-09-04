const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const web = b.dependency("web", .{
        .target = target,
        .optimize = optimize,
    });
    const executable = b.addExecutable(.{
        .name = "web-consumer-smoke",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "web_html", .module = web.module("web_html") },
                .{ .name = "web_router", .module = web.module("web_router") },
            },
        }),
    });
    const run = b.addRunArtifact(executable);
    b.getInstallStep().dependOn(&run.step);
}
