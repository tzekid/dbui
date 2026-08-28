const std = @import("std");
const sqlite = @import("sqlite.zig");
const schema = @import("schema.zig");
const browse = @import("browse.zig");
const row_token = @import("row_token.zig");
const http_params = @import("http_params.zig");

pub const maximum_editable_columns = 28;

pub const RowDetail = struct {
    details: schema.ObjectDetails,
    key: []const u8,
    values: []const browse.Value,
};

const SubmittedValue = union(enum) {
    null,
    integer: i64,
    real: f64,
    text: []const u8,

    fn bind(self: SubmittedValue, statement: *sqlite.Statement, index: usize) !void {
        return switch (self) {
            .null => statement.bindNull(index),
            .integer => |value| statement.bindInteger(index, value),
            .real => |value| statement.bindReal(index, value),
            .text => |value| statement.bindText(index, value),
        };
    }
};

const Change = struct {
    column: schema.ColumnMeta,
    value: SubmittedValue,
};

pub fn loadRow(
    allocator: std.mem.Allocator,
    database: *sqlite.Database,
    details: schema.ObjectDetails,
    encoded_key: []const u8,
) !RowDetail {
    if (!details.object.structuredWritable()) return error.StructuredEditingUnsupported;
    const decoded = try row_token.decode(allocator, encoded_key);
    const primary_keys = try primaryKeyIndices(allocator, details.columns);
    if (primary_keys.len == 0) return error.StructuredEditingUnsupported;
    if (decoded.values.len != primary_keys.len) return error.SchemaChanged;

    var sql: std.Io.Writer.Allocating = .init(allocator);
    try sql.writer.writeAll("SELECT ");
    for (details.columns, 0..) |column, index| {
        if (index != 0) try sql.writer.writeByte(',');
        try sql.writer.writeAll(try sqlite.quoteIdentifier(allocator, column.name));
    }
    try sql.writer.writeAll(" FROM main.");
    try sql.writer.writeAll(try sqlite.quoteIdentifier(allocator, details.object.name));
    try sql.writer.writeAll(" WHERE ");
    for (primary_keys, 0..) |column_index, index| {
        if (index != 0) try sql.writer.writeAll(" AND ");
        try sql.writer.writeAll(try sqlite.quoteIdentifier(allocator, details.columns[column_index].name));
        try sql.writer.print("=?{d}", .{index + 1});
    }

    var statement = try database.prepare(sql.written());
    defer statement.deinit();
    for (decoded.values, 0..) |value, index| try value.bind(&statement, index + 1);
    if (try statement.step() != .row) return error.RowNotFound;
    const values = try allocator.alloc(browse.Value, details.columns.len);
    var copied: usize = 0;
    for (values, 0..) |*value, index| value.* = try browse.copyDetailedValue(allocator, &statement, index, &copied);
    if (try statement.step() != .done) return error.RowIdentityInvariant;
    return .{ .details = details, .key = encoded_key, .values = values };
}

pub fn editableCount(row: RowDetail) usize {
    var count: usize = 0;
    for (row.details.columns, 0..) |_, index| if (editable(row, index)) {
        count += 1;
    };
    return count;
}

pub fn supportsEdit(row: RowDetail) bool {
    const count = editableCount(row);
    return count != 0 and count <= maximum_editable_columns;
}

pub fn editable(row: RowDetail, index: usize) bool {
    const column = row.details.columns[index];
    if (!column.normal() or column.generated() or column.primary_key_position != 0 or declaredBlob(column.declared_type)) return false;
    return switch (row.values[index]) {
        .blob => false,
        .text => |value| value.valid_utf8 and !value.truncated,
        else => true,
    };
}

pub fn update(
    allocator: std.mem.Allocator,
    database: *sqlite.Database,
    row: RowDetail,
    fields: http_params.Parameters,
) !void {
    if (!supportsEdit(row)) return error.StructuredEditingUnsupported;
    try validateFieldNames(allocator, row, fields);
    var changes: std.ArrayList(Change) = .empty;
    for (row.details.columns, 0..) |column, index| {
        if (!editable(row, index)) continue;
        const type_name = try std.fmt.allocPrint(allocator, "type_{d}", .{column.position});
        const value_name = try std.fmt.allocPrint(allocator, "value_{d}", .{column.position});
        const submitted_type = fields.get(type_name) orelse return error.SchemaChanged;
        const submitted_text = fields.get(value_name) orelse return error.SchemaChanged;
        const submitted = try parseSubmitted(column, submitted_type, submitted_text);
        if (!submittedEqual(submitted, row.values[index])) {
            try changes.append(allocator, .{ .column = column, .value = submitted });
        }
    }
    if (changes.items.len == 0) return;
    const decoded = try row_token.decode(allocator, row.key);
    const primary_keys = try primaryKeyIndices(allocator, row.details.columns);
    if (decoded.values.len != primary_keys.len) return error.SchemaChanged;

    var sql: std.Io.Writer.Allocating = .init(allocator);
    try sql.writer.writeAll("UPDATE main.");
    try sql.writer.writeAll(try sqlite.quoteIdentifier(allocator, row.details.object.name));
    try sql.writer.writeAll(" SET ");
    for (changes.items, 0..) |change, index| {
        if (index != 0) try sql.writer.writeByte(',');
        try sql.writer.writeAll(try sqlite.quoteIdentifier(allocator, change.column.name));
        try sql.writer.print("=?{d}", .{index + 1});
    }
    try sql.writer.writeAll(" WHERE ");
    for (primary_keys, 0..) |column_index, index| {
        if (index != 0) try sql.writer.writeAll(" AND ");
        try sql.writer.writeAll(try sqlite.quoteIdentifier(allocator, row.details.columns[column_index].name));
        try sql.writer.print("=?{d}", .{changes.items.len + index + 1});
    }
    try sql.writer.writeAll(" RETURNING 1");

    try database.exec("BEGIN IMMEDIATE");
    var committed = false;
    defer if (!committed) database.exec("ROLLBACK") catch {};
    {
        var statement = try database.prepare(sql.written());
        defer statement.deinit();
        for (changes.items, 0..) |change, index| try change.value.bind(&statement, index + 1);
        for (decoded.values, 0..) |value, index| try value.bind(&statement, changes.items.len + index + 1);
        if (try statement.step() != .row) return error.RowStale;
        if (try statement.step() != .done) return error.RowIdentityInvariant;
    }
    try database.exec("COMMIT");
    committed = true;
}

pub fn delete(
    allocator: std.mem.Allocator,
    database: *sqlite.Database,
    row: RowDetail,
) !void {
    const decoded = try row_token.decode(allocator, row.key);
    const primary_keys = try primaryKeyIndices(allocator, row.details.columns);
    if (primary_keys.len == 0 or decoded.values.len != primary_keys.len) return error.SchemaChanged;
    var sql: std.Io.Writer.Allocating = .init(allocator);
    try sql.writer.writeAll("DELETE FROM main.");
    try sql.writer.writeAll(try sqlite.quoteIdentifier(allocator, row.details.object.name));
    try sql.writer.writeAll(" WHERE ");
    for (primary_keys, 0..) |column_index, index| {
        if (index != 0) try sql.writer.writeAll(" AND ");
        try sql.writer.writeAll(try sqlite.quoteIdentifier(allocator, row.details.columns[column_index].name));
        try sql.writer.print("=?{d}", .{index + 1});
    }
    try sql.writer.writeAll(" RETURNING 1");

    try database.exec("BEGIN IMMEDIATE");
    var committed = false;
    defer if (!committed) database.exec("ROLLBACK") catch {};
    {
        var statement = try database.prepare(sql.written());
        defer statement.deinit();
        for (decoded.values, 0..) |value, index| try value.bind(&statement, index + 1);
        if (try statement.step() != .row) return error.RowStale;
        if (try statement.step() != .done) return error.RowIdentityInvariant;
    }
    try database.exec("COMMIT");
    committed = true;
}

fn validateFieldNames(allocator: std.mem.Allocator, row: RowDetail, fields: http_params.Parameters) !void {
    for (fields.items) |field| {
        if (std.mem.eql(u8, field.name, "csrf_token") or std.mem.eql(u8, field.name, "object") or std.mem.eql(u8, field.name, "key")) continue;
        var allowed = false;
        for (row.details.columns, 0..) |column, index| {
            if (!editable(row, index)) continue;
            const type_name = try std.fmt.allocPrint(allocator, "type_{d}", .{column.position});
            const value_name = try std.fmt.allocPrint(allocator, "value_{d}", .{column.position});
            if (std.mem.eql(u8, field.name, type_name) or std.mem.eql(u8, field.name, value_name)) {
                allowed = true;
                break;
            }
        }
        if (!allowed) return error.SchemaChanged;
    }
}

fn parseSubmitted(column: schema.ColumnMeta, kind: []const u8, text: []const u8) !SubmittedValue {
    if (std.mem.eql(u8, kind, "null")) {
        if (column.not_null) return error.NullNotAllowed;
        return .null;
    }
    if (std.mem.eql(u8, kind, "integer")) {
        return .{ .integer = std.fmt.parseInt(i64, text, 10) catch return error.InvalidInteger };
    }
    if (std.mem.eql(u8, kind, "real")) {
        const value = std.fmt.parseFloat(f64, text) catch return error.InvalidReal;
        if (!std.math.isFinite(value)) return error.InvalidReal;
        return .{ .real = value };
    }
    if (std.mem.eql(u8, kind, "text")) {
        if (text.len > 64 * 1024) return error.TextTooLong;
        if (!std.unicode.utf8ValidateSlice(text)) return error.InvalidText;
        return .{ .text = text };
    }
    return error.InvalidSubmittedType;
}

fn submittedEqual(submitted: SubmittedValue, current: browse.Value) bool {
    return switch (submitted) {
        .null => current == .null,
        .integer => |value| switch (current) {
            .integer => |existing| value == existing,
            else => false,
        },
        .real => |value| switch (current) {
            .real => |existing| @as(u64, @bitCast(value)) == @as(u64, @bitCast(existing)),
            else => false,
        },
        .text => |value| switch (current) {
            .text => |existing| std.mem.eql(u8, value, existing.bytes) and !existing.truncated and existing.valid_utf8,
            else => false,
        },
    };
}

fn primaryKeyIndices(allocator: std.mem.Allocator, columns: []const schema.ColumnMeta) ![]usize {
    var count: usize = 0;
    for (columns) |column| if (column.primary_key_position != 0) {
        count += 1;
    };
    if (count == 0) return &.{};
    const indices = try allocator.alloc(usize, count);
    var position: usize = 1;
    while (position <= count) : (position += 1) {
        var found = false;
        for (columns, 0..) |column, index| if (column.primary_key_position == position) {
            indices[position - 1] = index;
            found = true;
            break;
        };
        if (!found) return error.InvalidPrimaryKeyMetadata;
    }
    return indices;
}

fn declaredBlob(declared_type: []const u8) bool {
    if (declared_type.len < 4) return false;
    var index: usize = 0;
    while (index + 4 <= declared_type.len) : (index += 1) {
        if (std.ascii.eqlIgnoreCase(declared_type[index .. index + 4], "BLOB")) return true;
    }
    return false;
}

test "structured value parsing keeps empty text distinct and rejects numeric junk" {
    const nullable: schema.ColumnMeta = .{
        .position = 0,
        .name = "value",
        .declared_type = "TEXT",
        .not_null = false,
        .default_sql = null,
        .primary_key_position = 0,
        .hidden = 0,
    };
    try std.testing.expectEqualStrings("", (try parseSubmitted(nullable, "text", "")).text);
    try std.testing.expect(try parseSubmitted(nullable, "null", "ignored") == .null);
    try std.testing.expectError(error.InvalidInteger, parseSubmitted(nullable, "integer", "12x"));
    try std.testing.expectError(error.InvalidReal, parseSubmitted(nullable, "real", "1.2x"));
}
