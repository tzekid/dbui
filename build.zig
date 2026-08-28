const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const web = b.dependency("web", .{ .target = target, .optimize = optimize });

    const sqlite_translate = b.addTranslateC(.{
        .root_source_file = b.path("vendor/sqlite/sqlite3.h"),
        .target = target,
        .optimize = optimize,
    });
    sqlite_translate.addIncludePath(b.path("vendor/sqlite"));

    const module = applicationModule(b, target, optimize, web, sqlite_translate.createModule());
    const executable = b.addExecutable(.{ .name = "dbui", .root_module = module });
    b.installArtifact(executable);

    const run = b.addRunArtifact(executable);
    run.step.dependOn(b.getInstallStep());
    run.addPassthruArgs();
    b.step("run", "Run dbui").dependOn(&run.step);

    const tests = b.addTest(.{
        .root_module = applicationModule(b, target, optimize, web, sqlite_translate.createModule()),
    });
    b.step("test", "Run focused unit and integration tests").dependOn(&b.addRunArtifact(tests).step);

    const acceptance = b.addSystemCommand(&.{ "bash", "tests/e2e.sh" });
    acceptance.addArtifactArg(executable);
    b.step("acceptance", "Run the disposable real-process product journey").dependOn(&acceptance.step);
}

fn applicationModule(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    web: *std.Build.Dependency,
    sqlite_c: *std.Build.Module,
) *std.Build.Module {
    const module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{
            .{ .name = "sqlite_c", .module = sqlite_c },
            .{ .name = "web_app", .module = web.module("web_app") },
            .{ .name = "web_html", .module = web.module("web_html") },
            .{ .name = "web_request", .module = web.module("web_request") },
            .{ .name = "web_response", .module = web.module("web_response") },
            .{ .name = "web_router", .module = web.module("web_router") },
        },
    });
    module.addIncludePath(b.path("vendor/sqlite"));
    module.addCSourceFile(.{
        .file = b.path("vendor/sqlite/sqlite3.c"),
        .flags = &.{
            "-std=c99",
            "-DSQLITE_THREADSAFE=1",
            "-DSQLITE_DQS=0",
            "-DSQLITE_OMIT_LOAD_EXTENSION",
        },
    });
    module.addAnonymousImport("app_css", .{ .root_source_file = b.path("assets/app.css") });
    module.addAnonymousImport("app_js", .{ .root_source_file = b.path("assets/app.js") });
    return module;
}
