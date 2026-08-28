const std = @import("std");
const sqlite = @import("sqlite.zig");
const browse = @import("browse.zig");

pub const maximum_sql_bytes = 64 * 1024;
pub const maximum_rows = 500;
pub const maximum_columns = 256;
pub const maximum_materialized_bytes = 4 * 1024 * 1024;
pub const deadline_seconds = 10;

pub const Truncation = enum { row_limit, byte_limit };

pub const Result = struct {
    column_names: []const []const u8,
    rows: []const browse.Row,
    read_only: bool,
    affected_rows: usize,
    last_insert_row_id: ?i64,
    duration_ns: i64,
    materialized_bytes: usize,
    truncation: ?Truncation,
};

pub const Action = union(enum) {
    confirmation_required,
    result: Result,
};

pub fn execute(
    allocator: std.mem.Allocator,
    io: std.Io,
    database: *sqlite.Database,
    sql: []const u8,
    confirmed_write: bool,
) !Action {
    if (sql.len == 0 or std.mem.trim(u8, sql, " \t\r\n").len == 0) return error.EmptySql;
    if (sql.len > maximum_sql_bytes) return error.SqlTooLong;
    if (!std.unicode.utf8ValidateSlice(sql)) return error.InvalidSqlEncoding;

    try database.installQueryAuthorizer();
    var deadline = sqlite.Deadline.afterSeconds(io, deadline_seconds);
    database.installProgressHandler(&deadline);
    defer database.clearProgressHandler();
    const started = std.Io.Timestamp.now(io, .awake);

    const prepared = try database.prepareWithTail(sql);
    var statement = prepared.statement orelse return error.EmptySql;
    defer statement.deinit();
    var trailing = try database.prepareWithTail(prepared.tail);
    if (trailing.statement) |*second| {
        second.deinit();
        return error.MultipleStatements;
    }

    const read_only = statement.isReadOnly();
    if (database.mode == .read_only and !read_only) return error.DatabaseReadOnly;
    if (!read_only and !confirmed_write) return .confirmation_required;

    const column_count = statement.columnCount();
    if (column_count > maximum_columns) return error.TooManyResultColumns;
    const column_names = try allocator.alloc([]const u8, column_count);
    var materialized: usize = 0;
    for (column_names, 0..) |*name, index| {
        name.* = try allocator.dupe(u8, statement.columnName(index));
        materialized = std.math.add(usize, materialized, name.*.len) catch return error.ResultTooLarge;
    }

    var rows: std.ArrayList(browse.Row) = .empty;
    var truncation: ?Truncation = null;
    while (try statement.step() == .row) {
        if (truncation != null) {
            if (read_only) break;
            continue;
        }
        if (rows.items.len == maximum_rows) {
            truncation = .row_limit;
            if (read_only) break;
            continue;
        }
        const values = try allocator.alloc(browse.Value, column_count);
        var row_bytes: usize = 0;
        for (values, 0..) |*value, index| value.* = try browse.copyValue(allocator, &statement, index, &row_bytes);
        const next_total = std.math.add(usize, materialized, row_bytes) catch maximum_materialized_bytes + 1;
        if (next_total > maximum_materialized_bytes) {
            truncation = .byte_limit;
            if (read_only) break;
            continue;
        }
        materialized = next_total;
        try rows.append(allocator, .{ .values = values });
    }

    const finished = std.Io.Timestamp.now(io, .awake);
    const changed = if (read_only) 0 else database.changes();
    const last_id = if (!read_only and changed != 0) database.lastInsertRowId() else 0;
    return .{ .result = .{
        .column_names = column_names,
        .rows = try rows.toOwnedSlice(allocator),
        .read_only = read_only,
        .affected_rows = changed,
        .last_insert_row_id = if (last_id == 0) null else last_id,
        .duration_ns = @intCast(@max(0, started.durationTo(finished).nanoseconds)),
        .materialized_bytes = materialized,
        .truncation = truncation,
    } };
}
