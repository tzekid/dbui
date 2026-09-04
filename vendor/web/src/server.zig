//! Minimal optional `std.http` connection lifecycle helpers.
//!
//! Listener ownership, concurrency, signals, jobs, and application shutdown
//! remain application concerns. This module only removes the repeated,
//! correctness-sensitive per-connection request loop.

const std = @import("std");

pub const ConnectionOptions = struct {
    maximum_requests: usize = 100,
};

pub fn serveConnection(
    comptime Context: type,
    context: Context,
    input: *std.Io.Reader,
    output: *std.Io.Writer,
    options: ConnectionOptions,
    handler: *const fn (Context, *std.http.Server.Request) anyerror!void,
) !void {
    if (options.maximum_requests == 0) return;
    var server = std.http.Server.init(input, output);
    var handled: usize = 0;
    while (handled < options.maximum_requests) {
        var request = server.receiveHead() catch |err| switch (err) {
            error.HttpConnectionClosing => return,
            else => return err,
        };
        handled += 1;
        if (handled == options.maximum_requests) request.head.keep_alive = false;
        try handler(context, &request);
        if (!request.head.keep_alive) return;
    }
}

pub fn writeHeaderTooLarge(output: *std.Io.Writer) !void {
    const body = "request headers too large";
    try output.print(
        "HTTP/1.1 431 Request Header Fields Too Large\r\n" ++
            "Content-Type: text/plain; charset=utf-8\r\n" ++
            "Content-Length: {d}\r\n" ++
            "Connection: close\r\n" ++
            "X-Content-Type-Options: nosniff\r\n\r\n{s}",
        .{ body.len, body },
    );
    try output.flush();
}

fn testHandler(expected_target: []const u8, request: *std.http.Server.Request) !void {
    try std.testing.expectEqualStrings(expected_target, request.head.target);
    try request.respond("complete first response", .{
        .extra_headers = &.{.{ .name = "content-type", .value = "text/plain; charset=utf-8" }},
    });
}

test "connection loop handles a request and honors connection close" {
    const raw_request = "GET /first-view HTTP/1.1\r\nHost: example.test\r\nConnection: close\r\n\r\n";
    var input_buffer: [512]u8 = undefined;
    @memcpy(input_buffer[0..raw_request.len], raw_request);
    var input: std.Io.Reader = .fixed(input_buffer[0..raw_request.len]);
    var output_buffer: [2048]u8 = undefined;
    var output: std.Io.Writer = .fixed(&output_buffer);
    try serveConnection([]const u8, "/first-view", &input, &output, .{}, testHandler);
    try std.testing.expect(std.mem.indexOf(u8, output.buffered(), "200 OK") != null);
    try std.testing.expect(std.mem.endsWith(u8, output.buffered(), "complete first response"));
}

test "header-too-large response is bounded and closes the connection" {
    var output_buffer: [1024]u8 = undefined;
    var output: std.Io.Writer = .fixed(&output_buffer);
    try writeHeaderTooLarge(&output);
    try std.testing.expect(std.mem.startsWith(u8, output.buffered(), "HTTP/1.1 431"));
    try std.testing.expect(std.mem.indexOf(u8, output.buffered(), "Connection: close") != null);
}
