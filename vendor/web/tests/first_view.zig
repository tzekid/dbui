const std = @import("std");
const html = @import("web_html");
const htmx = @import("web_htmx");
const testing = @import("web_testing");

const Page = struct {
    project_count: usize,
    projects: []const []const u8,
};

fn render(writer: *std.Io.Writer, page: Page) !void {
    try html.documentStart(writer, .{ .title = "Projects" });
    try writer.print("<main><h1>Projects</h1><p>{d} projects are available.</p><ul>", .{page.project_count});
    for (page.projects) |project| {
        try writer.writeAll("<li>");
        try html.text(writer, project);
        try writer.writeAll("</li>");
    }
    try writer.writeAll(
        "</ul><form method=\"post\" action=\"/projects\" " ++
            "hx-post=\"/projects\" hx-target=\"main#content\">" ++
            "<label>Name <input name=\"name\" required></label>" ++
            "<button type=\"submit\">Create project</button></form></main>",
    );
    try html.documentEnd(writer);
}

test "first response is useful and operable before HTMX runs" {
    var storage: [4096]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&storage);
    try render(&writer, .{
        .project_count = 2,
        .projects = &.{ "cloudio", "plosca.ru" },
    });
    const page = writer.buffered();
    try testing.expectContains(page, "<!doctype html>");
    try testing.expectContains(page, "2 projects are available.");
    try testing.expectContains(page, "<li>cloudio</li>");
    try testing.expectContains(page, "method=\"post\"");
    try testing.expectContains(page, "action=\"/projects\"");
    try testing.expectContains(page, "name=\"name\"");
    try testing.expectNotContains(page, "<script");
    try std.testing.expectEqualStrings("HX-Request-Type", htmx.cache_vary);
}
