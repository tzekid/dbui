const std = @import("std");

const ModuleSpec = struct {
    name: []const u8,
    path: []const u8,
    imports: []const []const u8 = &.{},
};

// Order matters: a module's imports must appear before it.
const modules = [_]ModuleSpec{
    .{ .name = "web_digest", .path = "src/digest.zig" },
    .{ .name = "web_html", .path = "src/html.zig" },
    .{ .name = "web_request", .path = "src/request.zig" },
    .{ .name = "web_response", .path = "src/response.zig" },
    .{ .name = "web_router", .path = "src/router.zig" },
    .{ .name = "web_assets", .path = "src/assets.zig" },
    .{ .name = "web_cache", .path = "src/cache.zig" },
    .{ .name = "web_security_headers", .path = "src/security_headers.zig" },
    .{ .name = "web_server", .path = "src/server.zig" },
    .{ .name = "web_htmx", .path = "src/htmx.zig", .imports = &.{"web_digest"} },
    .{ .name = "web_testing", .path = "src/testing.zig" },
    .{ .name = "web_app", .path = "src/app.zig", .imports = &.{ "web_server", "web_router" } },
    .{ .name = "web", .path = "src/web.zig", .imports = &.{
        "web_digest",  "web_html",  "web_request",          "web_response", "web_router",
        "web_assets",  "web_cache", "web_security_headers", "web_server",   "web_htmx",
        "web_testing", "web_app",
    } },
};

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const test_step = b.step("test", "Run all module tests");

    for (modules) |spec| {
        const module = b.addModule(spec.name, .{
            .root_source_file = b.path(spec.path),
            .target = target,
            .optimize = optimize,
        });
        for (spec.imports) |import_name| {
            module.addImport(import_name, b.modules.get(import_name).?);
        }
        const module_tests = b.addTest(.{
            .root_module = module,
        });
        const run_tests = b.addRunArtifact(module_tests);
        test_step.dependOn(&run_tests.step);
    }

    // Security-sensitive escaping must also pass with asserts compiled out.
    const html_release_fast = b.createModule(.{
        .root_source_file = b.path("src/html.zig"),
        .target = target,
        .optimize = .ReleaseFast,
    });
    const html_release_fast_tests = b.addTest(.{ .root_module = html_release_fast });
    test_step.dependOn(&b.addRunArtifact(html_release_fast_tests).step);

    const first_view_module = b.createModule(.{
        .root_source_file = b.path("tests/first_view.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "web_html", .module = b.modules.get("web_html").? },
            .{ .name = "web_htmx", .module = b.modules.get("web_htmx").? },
            .{ .name = "web_testing", .module = b.modules.get("web_testing").? },
        },
    });
    const first_view_tests = b.addTest(.{ .root_module = first_view_module });
    test_step.dependOn(&b.addRunArtifact(first_view_tests).step);

    const load_module = b.createModule(.{
        .root_source_file = b.path("tests/load.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "web_app", .module = b.modules.get("web_app").? },
        },
    });
    const load_tests = b.addTest(.{ .root_module = load_module });
    const journeys_step = b.step("journeys", "Run the load journey against a real listener");
    journeys_step.dependOn(&b.addRunArtifact(load_tests).step);

    const consumer_command = b.addSystemCommand(&.{ b.graph.zig_exe, "build" });
    consumer_command.setCwd(b.path("tests/consumer"));
    const consumer_step = b.step("consumer", "Build the external path consumer");
    consumer_step.dependOn(&consumer_command.step);
}
