const std = @import("std");
const sqlite = @import("sqlite.zig");
const browse = @import("browse.zig");

pub const maximum_sql_bytes = 64 * 1024;
pub const maximum_rows = 500;
pub const maximum_columns = 256;
pub const maximum_materialized_bytes = 4 * 1024 * 1024;
pub const deadline_seconds = 10;
pub const maximum_statement_boundaries = 1024;

pub const Scope = enum {
    whole,
    selection,
    current,

    pub fn parse(value: []const u8) !Scope {
        if (std.mem.eql(u8, value, "whole")) return .whole;
        if (std.mem.eql(u8, value, "selection")) return .selection;
        if (std.mem.eql(u8, value, "current")) return .current;
        return error.InvalidExecutionScope;
    }
};

pub const ResolvedSource = struct {
    sql: []const u8,
    start_byte: usize,
    end_byte: usize,
    line_start: usize,
    line_end: usize,
};

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

pub fn resolveSource(
    allocator: std.mem.Allocator,
    database: *sqlite.Database,
    source: []const u8,
    scope: Scope,
    selection_start: usize,
    selection_end: usize,
    cursor: usize,
) !ResolvedSource {
    if (source.len > maximum_sql_bytes) return error.SqlTooLong;
    if (!std.unicode.utf8ValidateSlice(source) or std.mem.indexOfScalar(u8, source, 0) != null) return error.InvalidSqlEncoding;
    const range = switch (scope) {
        .whole => ByteRange{ .start = 0, .end = source.len },
        .selection => block: {
            try validateOffset(source, selection_start);
            try validateOffset(source, selection_end);
            if (selection_start >= selection_end) return error.EmptySelection;
            break :block ByteRange{ .start = selection_start, .end = selection_end };
        },
        .current => block: {
            try validateOffset(source, cursor);
            break :block try currentStatement(allocator, database, source, cursor);
        },
    };
    const line_start = 1 + std.mem.count(u8, source[0..range.start], "\n");
    var line_end = line_start + std.mem.count(u8, source[range.start..range.end], "\n");
    if (range.end > range.start and source[range.end - 1] == '\n' and line_end > line_start) line_end -= 1;
    return .{
        .sql = source[range.start..range.end],
        .start_byte = range.start,
        .end_byte = range.end,
        .line_start = line_start,
        .line_end = line_end,
    };
}

const ByteRange = struct { start: usize, end: usize };

fn currentStatement(
    allocator: std.mem.Allocator,
    database: *sqlite.Database,
    source: []const u8,
    cursor: usize,
) !ByteRange {
    if (std.mem.count(u8, source, ";") > maximum_statement_boundaries) return error.TooManyStatementBoundaries;
    const source_z = try allocator.dupeSentinel(u8, source, 0);
    var ranges: [maximum_statement_boundaries + 1]ByteRange = undefined;
    var range_count: usize = 0;
    var start: usize = 0;
    for (source, 0..) |byte, index| {
        if (byte != ';') continue;
        const after = index + 1;
        const saved = source_z[after];
        source_z[after] = 0;
        const complete = sqlite.raw.sqlite3_complete(source_z.ptr + start);
        source_z[after] = saved;
        if (complete == 0) continue;
        ranges[range_count] = .{ .start = start, .end = index + 1 };
        range_count += 1;
        start = index + 1;
    }

    if (start < source.len) {
        var tail_has_statement = true;
        const prepared = database.prepareWithTail(source[start..]) catch null;
        if (prepared) |value| {
            var mutable = value;
            if (mutable.statement) |*statement| {
                statement.deinit();
            } else {
                tail_has_statement = false;
            }
        }
        if (tail_has_statement) {
            ranges[range_count] = .{ .start = start, .end = source.len };
            range_count += 1;
        } else if (range_count != 0) {
            ranges[range_count - 1].end = source.len;
        }
    }
    if (range_count == 0) return error.EmptySql;
    for (ranges[0..range_count]) |range| {
        if (cursor >= range.start and cursor < range.end) return range;
    }
    if (cursor == source.len) return ranges[range_count - 1];
    return error.NoStatementAtCursor;
}

fn validateOffset(source: []const u8, offset: usize) !void {
    if (offset > source.len) return error.InvalidSourceOffset;
    if (offset < source.len and source[offset] & 0xc0 == 0x80) return error.InvalidSourceOffset;
}

pub fn execute(
    allocator: std.mem.Allocator,
    io: std.Io,
    database: *sqlite.Database,
    sql: []const u8,
    confirmed_write: bool,
) !Action {
    if (sql.len == 0 or std.mem.trim(u8, sql, " \t\r\n").len == 0) return error.EmptySql;
    if (sql.len > maximum_sql_bytes) return error.SqlTooLong;
    if (!std.unicode.utf8ValidateSlice(sql) or std.mem.indexOfScalar(u8, sql, 0) != null) return error.InvalidSqlEncoding;

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
