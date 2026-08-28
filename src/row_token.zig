const std = @import("std");
const sqlite = @import("sqlite.zig");

pub const maximum_decoded_bytes = 4096;
pub const maximum_encoded_bytes = 8192;
const version: u8 = 1;

pub const KeyValue = union(enum) {
    integer: i64,
    real: f64,
    text: []const u8,
    blob: []const u8,

    pub fn bind(self: KeyValue, statement: *sqlite.Statement, index: usize) !void {
        return switch (self) {
            .integer => |value| statement.bindInteger(index, value),
            .real => |value| statement.bindReal(index, value),
            .text => |value| statement.bindText(index, value),
            .blob => |value| statement.bindBlob(index, value),
        };
    }
};

pub const Decoded = struct {
    values: []const KeyValue,
};

pub fn encodeFromStatement(
    allocator: std.mem.Allocator,
    statement: *const sqlite.Statement,
    column_indices: []const usize,
) !?[]u8 {
    if (column_indices.len == 0 or column_indices.len > 256) return null;
    const values = try allocator.alloc(KeyValue, column_indices.len);
    for (column_indices, 0..) |column_index, index| {
        values[index] = switch (statement.columnType(column_index)) {
            sqlite.raw.SQLITE_NULL => return null,
            sqlite.raw.SQLITE_INTEGER => .{ .integer = statement.columnInteger(column_index) },
            sqlite.raw.SQLITE_FLOAT => .{ .real = statement.columnReal(column_index) },
            sqlite.raw.SQLITE_TEXT => .{ .text = statement.columnText(column_index) },
            sqlite.raw.SQLITE_BLOB => .{ .blob = statement.columnBlob(column_index) },
            else => return error.InvalidKeyType,
        };
    }
    return encodeValues(allocator, values) catch |err| switch (err) {
        error.TokenTooLarge => null,
        else => return err,
    };
}

pub fn encodeValues(allocator: std.mem.Allocator, values: []const KeyValue) ![]u8 {
    if (values.len == 0 or values.len > 256) return error.InvalidKeyCount;
    var binary: std.Io.Writer.Allocating = .init(allocator);
    try binary.writer.writeByte(version);
    try writeInt(&binary.writer, u16, @intCast(values.len));
    for (values) |value| {
        switch (value) {
            .integer => |integer| {
                try binary.writer.writeByte(1);
                try writeInt(&binary.writer, u32, 8);
                try writeInt(&binary.writer, u64, @bitCast(integer));
            },
            .real => |real| {
                try binary.writer.writeByte(2);
                try writeInt(&binary.writer, u32, 8);
                try writeInt(&binary.writer, u64, @bitCast(real));
            },
            .text => |text| {
                try binary.writer.writeByte(3);
                try writeBytes(&binary.writer, text);
            },
            .blob => |blob| {
                try binary.writer.writeByte(4);
                try writeBytes(&binary.writer, blob);
            },
        }
        if (binary.written().len > maximum_decoded_bytes) return error.TokenTooLarge;
    }
    const bytes = binary.written();
    const encoded_length = std.base64.url_safe_no_pad.Encoder.calcSize(bytes.len);
    if (encoded_length > maximum_encoded_bytes) return error.TokenTooLarge;
    const encoded = try allocator.alloc(u8, encoded_length);
    _ = std.base64.url_safe_no_pad.Encoder.encode(encoded, bytes);
    return encoded;
}

pub fn decode(allocator: std.mem.Allocator, encoded: []const u8) !Decoded {
    if (encoded.len == 0 or encoded.len > maximum_encoded_bytes) return error.MalformedToken;
    const decoded_length = std.base64.url_safe_no_pad.Decoder.calcSizeForSlice(encoded) catch return error.MalformedToken;
    if (decoded_length > maximum_decoded_bytes) return error.MalformedToken;
    const bytes = try allocator.alloc(u8, decoded_length);
    std.base64.url_safe_no_pad.Decoder.decode(bytes, encoded) catch return error.MalformedToken;
    var cursor: usize = 0;
    if (try takeByte(bytes, &cursor) != version) return error.UnknownTokenVersion;
    const count = try takeInt(bytes, &cursor, u16);
    if (count == 0 or count > 256) return error.MalformedToken;
    const values = try allocator.alloc(KeyValue, count);
    for (values) |*value| {
        const kind = try takeByte(bytes, &cursor);
        const length = try takeInt(bytes, &cursor, u32);
        const raw_value = try take(bytes, &cursor, length);
        value.* = switch (kind) {
            1 => if (length == 8) .{ .integer = @bitCast(std.mem.readInt(u64, raw_value[0..8], .big)) } else return error.MalformedToken,
            2 => if (length == 8) .{ .real = @bitCast(std.mem.readInt(u64, raw_value[0..8], .big)) } else return error.MalformedToken,
            3 => .{ .text = raw_value },
            4 => .{ .blob = raw_value },
            else => return error.MalformedToken,
        };
    }
    if (cursor != bytes.len) return error.MalformedToken;
    return .{ .values = values };
}

fn writeBytes(writer: *std.Io.Writer, bytes: []const u8) !void {
    if (bytes.len > std.math.maxInt(u32)) return error.TokenTooLarge;
    try writeInt(writer, u32, @intCast(bytes.len));
    try writer.writeAll(bytes);
}

fn writeInt(writer: *std.Io.Writer, comptime T: type, value: T) !void {
    var buffer: [@sizeOf(T)]u8 = undefined;
    std.mem.writeInt(T, &buffer, value, .big);
    try writer.writeAll(&buffer);
}

fn takeByte(bytes: []const u8, cursor: *usize) !u8 {
    const result = try take(bytes, cursor, 1);
    return result[0];
}

fn takeInt(bytes: []const u8, cursor: *usize, comptime T: type) !T {
    const result = try take(bytes, cursor, @sizeOf(T));
    return std.mem.readInt(T, result[0..@sizeOf(T)], .big);
}

fn take(bytes: []const u8, cursor: *usize, length: usize) ![]const u8 {
    const end = std.math.add(usize, cursor.*, length) catch return error.MalformedToken;
    if (end > bytes.len) return error.MalformedToken;
    const result = bytes[cursor.*..end];
    cursor.* = end;
    return result;
}

test "composite row token round-trips exact typed values and rejects trailing bytes" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();
    const encoded = try encodeValues(allocator, &.{
        .{ .text = "tenant/β" },
        .{ .integer = -9223372036854775807 },
        .{ .real = -0.0 },
        .{ .blob = "\x00\xff" },
    });
    const decoded = try decode(allocator, encoded);
    try std.testing.expectEqual(@as(usize, 4), decoded.values.len);
    try std.testing.expectEqualStrings("tenant/β", decoded.values[0].text);
    try std.testing.expectEqual(@as(i64, -9223372036854775807), decoded.values[1].integer);
    try std.testing.expectEqual(@as(u64, @bitCast(@as(f64, -0.0))), @as(u64, @bitCast(decoded.values[2].real)));
    try std.testing.expectEqualSlices(u8, "\x00\xff", decoded.values[3].blob);

    const malformed = try std.fmt.allocPrint(allocator, "{s}A", .{encoded});
    try std.testing.expectError(error.MalformedToken, decode(allocator, malformed));
}
