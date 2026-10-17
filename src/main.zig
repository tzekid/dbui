const std = @import("std");
const config = @import("config.zig");
const app = @import("app.zig");
const auth = @import("auth_store.zig");

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
    if (args.len < 3 or !std.mem.eql(u8, args[1], "--config")) {
        try usage(&stdout.interface);
        return error.InvalidArguments;
    }
    const check_only = args.len == 4 and std.mem.eql(u8, args[3], "--check");
    const registry = try config.Registry.load(allocator, init.io, args[2]);
    if (args.len >= 5 and std.mem.eql(u8, args[3], "auth")) {
        var store = try auth.Store.init(allocator, init.io, registry.auth);
        defer store.deinit();
        if (args.len == 5 and std.mem.eql(u8, args[4], "status")) {
            try stdout.interface.print("passkeys={d} sessions={d} setup_links={d}\n", .{
                try store.count("SELECT count(*) FROM passkeys", .{}),
                try store.count("SELECT count(*) FROM sessions WHERE expires>?", .{auth.now(init.io)}),
                try store.count("SELECT count(*) FROM bootstrap WHERE expires>?", .{auth.now(init.io)}),
            });
            return;
        }
        if (args.len == 8 and std.mem.eql(u8, args[4], "recover") and std.mem.eql(u8, args[5], "--backup") and std.mem.eql(u8, args[7], "--confirm")) {
            try store.backup(allocator, init.io, args[6]);
            try store.reset();
        } else if (!(args.len == 5 and std.mem.eql(u8, args[4], "setup"))) return error.InvalidArguments;
        const token = try store.setup(init.io);
        try stdout.interface.print("{s}/setup#{s}\n", .{ registry.auth.origin, token });
        return;
    }
    if (args.len > 4 or (args.len == 4 and !check_only)) return error.InvalidArguments;
    if (check_only) {
        try auth.Store.check(allocator, init.io, registry.auth);
        try stdout.interface.print("configuration valid: {d} database(s)\n", .{registry.databases.len});
        return;
    }

    var store = try auth.Store.init(allocator, init.io, registry.auth);
    defer store.deinit();

    var context: app.Context = .{
        .registry = &registry,
        .csrf_token = undefined,
    };
    try app.run(init.gpa, init.io, &context);
}

fn usage(writer: *std.Io.Writer) !void {
    try writer.writeAll(
        \\Usage:
        \\  dbui --config /etc/dbui/config.json
        \\  dbui --config /etc/dbui/config.json --check
        \\  dbui --config /etc/dbui/config.json auth status
        \\  dbui --config /etc/dbui/config.json auth setup
        \\  dbui --config /etc/dbui/config.json auth recover --backup /absolute/new-backup.db --confirm
        \\  dbui --help
        \\  dbui --version
        \\
    );
}

test {
    _ = @import("config.zig");
    _ = @import("http_params.zig");
    _ = @import("row_token.zig");
    _ = @import("query_files.zig");
    _ = @import("views.zig");
    _ = @import("passkeys.zig");
}
