//! Load journey: the performance floor from the ecosystem spec, asserted as
//! a test so architectural regressions (a serial accept loop, a lost worker
//! pool) fail the build rather than surfacing on a VPS.
//!
//! Floor: >= 200 req/s sustained with concurrent keep-alive clients, zero
//! 5xx, bounded RSS, clean drain. Numbers are far below what the pool
//! delivers so slow CI hardware passes with margin; the point is shape, not
//! benchmarking.

const std = @import("std");
const web_app = @import("web_app");

const client_count = 4;
const requests_per_client = 250;

fn onError(err: anyerror, note: []const u8) void {
    std.log.warn("lifecycle: {s}: {s}", .{ @errorName(err), note });
}

fn handler(_: u8, context: *web_app.RequestContext) anyerror!void {
    // A small allocation exercises the request arena the way real handlers do.
    const body = try context.arena.dupe(u8, "load journey response body");
    try context.request.respond(body, .{
        .extra_headers = &.{.{ .name = "content-type", .value = "text/plain" }},
    });
}

const ClientResult = struct {
    completed: u64 = 0,
    failed: u64 = 0,
};

/// Reads exactly one HTTP/1.1 response off a keep-alive connection: header
/// block byte-wise to its terminator, then exactly Content-Length body bytes.
/// Never over-reads into the next response and never waits for bytes that
/// will not come.
fn readOneResponse(reader: *std.Io.Reader) !bool {
    var header: [1024]u8 = undefined;
    var header_len: usize = 0;
    while (std.mem.indexOf(u8, header[0..header_len], "\r\n\r\n") == null) {
        if (header_len == header.len) return error.HeaderTooLarge;
        const n = try reader.readSliceShort(header[header_len .. header_len + 1]);
        if (n == 0) return error.EndOfStream;
        header_len += n;
    }
    const head = header[0..header_len];
    const ok = std.mem.indexOf(u8, head, " 200 ") != null;
    const marker = "content-length: ";
    var content_length: usize = 0;
    var lines = std.mem.splitSequence(u8, head, "\r\n");
    while (lines.next()) |line| {
        if (line.len > marker.len and std.ascii.eqlIgnoreCase(line[0..marker.len], marker)) {
            content_length = try std.fmt.parseInt(usize, std.mem.trim(u8, line[marker.len..], " "), 10);
        }
    }
    var body_remaining = content_length;
    var sink: [256]u8 = undefined;
    while (body_remaining > 0) {
        const step = @min(body_remaining, sink.len);
        const n = try reader.readSliceShort(sink[0..step]);
        if (n == 0) return error.EndOfStream;
        body_remaining -= n;
    }
    return ok;
}

fn clientMain(io: std.Io, port: u16, result: *ClientResult) void {
    var remaining: usize = requests_per_client;
    connection: while (remaining > 0) {
        const address: std.Io.net.IpAddress = .{ .ip4 = .loopback(port) };
        var stream = address.connect(io, .{ .mode = .stream }) catch {
            result.failed += 1;
            remaining -= 1;
            continue;
        };
        defer stream.close(io);
        var write_buffer: [512]u8 = undefined;
        var writer = stream.writer(io, &write_buffer);
        var read_buffer: [2048]u8 = undefined;
        var reader = stream.reader(io, &read_buffer);
        // Up to the keep-alive budget of requests per connection.
        var on_this_connection: usize = 0;
        while (remaining > 0 and on_this_connection < 90) {
            writer.interface.writeAll("GET /load HTTP/1.1\r\nhost: t\r\n\r\n") catch continue :connection;
            writer.interface.flush() catch continue :connection;
            const ok = readOneResponse(&reader.interface) catch false;
            remaining -= 1;
            on_this_connection += 1;
            if (ok) result.completed += 1 else {
                result.failed += 1;
                continue :connection;
            }
        }
    }
}

test "sustained concurrent load stays above the floor with zero 5xx and bounded memory" {
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var app = try web_app.App.init(std.testing.allocator, io, .{
        .address = .{ .ip4 = .loopback(0) },
        .on_error = onError,
    });
    defer app.deinit();

    var run_result: anyerror!void = {};
    const Runner = struct {
        fn main(app_pointer: *web_app.App, out: *anyerror!void) void {
            out.* = app_pointer.run(u8, 0, handler);
        }
    };
    const server_thread = try std.Thread.spawn(.{}, Runner.main, .{ &app, &run_result });
    var attempts: usize = 0;
    while (app.boundPort() == 0) : (attempts += 1) {
        if (attempts > 5_000) return error.ServerNeverBound;
        std.Io.Timeout.sleep(.{ .duration = .{ .raw = .{ .nanoseconds = std.time.ns_per_ms }, .clock = .awake } }, io) catch {};
    }
    const port = app.boundPort();

    const started = std.Io.Timestamp.now(io, .awake);
    var results: [client_count]ClientResult = @splat(.{});
    var clients: [client_count]std.Thread = undefined;
    for (0..client_count) |index| {
        clients[index] = try std.Thread.spawn(.{}, clientMain, .{ io, port, &results[index] });
    }
    for (&clients) |*client| client.join();
    const finished = std.Io.Timestamp.now(io, .awake);

    var completed: u64 = 0;
    var failed: u64 = 0;
    for (results) |result| {
        completed += result.completed;
        failed += result.failed;
    }
    const elapsed_ns: u64 = @intCast(@max(1, started.durationTo(finished).nanoseconds));
    const throughput = completed * std.time.ns_per_s / elapsed_ns;

    app.requestShutdown();
    server_thread.join();
    try run_result;

    std.log.warn("load journey: {d} completed, {d} failed, {d} req/s", .{ completed, failed, throughput });
    try std.testing.expectEqual(@as(u64, 0), app.counters().responses_5xx);
    try std.testing.expect(failed == 0);
    try std.testing.expectEqual(@as(u64, client_count * requests_per_client), completed);
    try std.testing.expect(throughput >= 200);

    // RSS bound: server and clients share this process, so the bound is
    // generous; the assertion catches unbounded growth, not exact footprint.
    // Raw posix read: proc files stat as zero-size, which defeats
    // size-hinted readers.
    const statm_fd = try std.posix.openat(std.posix.AT.FDCWD, "/proc/self/statm", .{}, 0);
    defer _ = std.os.linux.close(statm_fd);
    var statm_buffer: [256]u8 = undefined;
    const statm_len = try std.posix.read(statm_fd, &statm_buffer);
    var fields = std.mem.tokenizeScalar(u8, statm_buffer[0..statm_len], ' ');
    _ = fields.next(); // total program size
    const resident_pages = try std.fmt.parseInt(u64, fields.next() orelse return error.StatmUnreadable, 10);
    const resident_bytes = resident_pages * std.heap.pageSize();
    std.log.warn("load journey rss: {d} MiB", .{resident_bytes / (1024 * 1024)});
    try std.testing.expect(resident_bytes < 256 * 1024 * 1024);
}
