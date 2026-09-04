const web_html = @import("web_html");
const web_router = @import("web_router");
const std = @import("std");

pub fn main() !void {
    var storage: [256]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&storage);
    try web_html.documentStart(&writer, .{ .title = "Consumer" });
    try writer.writeAll("<main>");
    try web_html.text(&writer, "Useful on the first response");
    try writer.writeAll("</main>");
    try web_html.documentEnd(&writer);
    const Route = struct { method: std.http.Method, pattern: []const u8 };
    const routes = [_]Route{.{ .method = .GET, .pattern = "/" }};
    _ = web_router.match(Route, &routes, .GET, "/").matched;
}
