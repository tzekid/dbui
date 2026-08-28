const std = @import("std");
const config = @import("config.zig");
const app = @import("app.zig");

const version = "0.1.0-dev";

pub fn main(init: std.process.Init) void {
    run(init) catch |err| {
        var buffer: [1024]u8 = undefined;
        var stderr = std.Io.File.stderr().writer(init.io, &buffer);
        stderr.interface.print("dbui: {s}\n", .{@errorName(err)}) catch {};
        stderr.interface.flush() catch {};
        std.process.exit(1);
    };
}

fn run(init: std.process.Init) !void {
    const allocator = init.arena.allocator();
    const args = try init.minimal.args.toSlice(allocator);
    var output_buffer: [4096]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(init.io, &output_buffer);
    defer stdout.interface.flush() catch {};

    if (args.len == 2 and (std.mem.eql(u8, args[1], "--help") or std.mem.eql(u8, args[1], "-h"))) {
        try usage(&stdout.interface);
        return;
    }
    if (args.len == 2 and std.mem.eql(u8, args[1], "--version")) {
        try stdout.interface.print("dbui {s} (SQLite 3.53.4)\n", .{version});
        return;
    }
    if (args.len < 3 or !std.mem.eql(u8, args[1], "--config") or args.len > 4) {
        try usage(&stdout.interface);
        return error.InvalidArguments;
    }
    const check_only = args.len == 4 and std.mem.eql(u8, args[3], "--check");
    if (args.len == 4 and !check_only) return error.InvalidArguments;

    const registry = try config.Registry.load(allocator, init.io, args[2]);
    if (check_only) {
        try stdout.interface.print("configuration valid: {d} database(s)\n", .{registry.databases.len});
        return;
    }

    var random_token: [32]u8 = undefined;
    init.io.random(&random_token);
    var context: app.Context = .{
        .registry = &registry,
        .csrf_token = std.fmt.bytesToHex(random_token, .lower),
    };
    try app.run(init.gpa, init.io, &context);
}

fn usage(writer: *std.Io.Writer) !void {
    try writer.writeAll(
        \\Usage:
        \\  dbui --config /etc/dbui/config.json
        \\  dbui --config /etc/dbui/config.json --check
        \\  dbui --help
        \\  dbui --version
        \\
    );
}
