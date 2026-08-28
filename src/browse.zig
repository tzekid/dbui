const std = @import("std");
const sqlite = @import("sqlite.zig");
const schema = @import("schema.zig");
const http_params = @import("http_params.zig");
const row_token = @import("row_token.zig");

pub const maximum_columns = 256;
pub const maximum_materialized_bytes = 4 * 1024 * 1024;
pub const grid_text_preview = 512;
pub const blob_prefix_bytes = 32;

pub const Direction = enum {
    asc,
    desc,

    pub fn sql(self: Direction) []const u8 {
        return if (self == .asc) "ASC" else "DESC";
    }
};

pub const FilterOperator = enum {
    equals,
    not_equals,
    less_than,
    less_than_or_equal,
    greater_than,
    greater_than_or_equal,
    contains,
    starts_with,
    is_null,
    is_not_null,

    pub fn parse(value: []const u8) !FilterOperator {
        inline for (std.meta.tags(FilterOperator)) |operator| {
            if (std.mem.eql(u8, value, @tagName(operator))) return operator;
        }
        return error.InvalidFilterOperator;
    }
};

pub const Filter = struct {
    column: []const u8,
    operator: FilterOperator,
    value: []const u8,
};

pub const Options = struct {
    page: usize = 0,
    size: usize = 100,
    sort: ?[]const u8 = null,
    direction: Direction = .asc,
    filter: ?Filter = null,
};

pub const TextValue = struct {
    bytes: []const u8,
    original_len: usize,
    truncated: bool,
    valid_utf8: bool,
};

pub const BlobValue = struct {
    prefix: []const u8,
    original_len: usize,
    truncated: bool,
};

pub const Value = union(enum) {
    null,
    integer: i64,
    real: f64,
    text: TextValue,
    blob: BlobValue,

    pub fn typeName(self: Value) []const u8 {
        return switch (self) {
            .null => "NULL",
            .integer => "INTEGER",
            .real => "REAL",
            .text => "TEXT",
            .blob => "BLOB",
        };
    }
};

pub const Row = struct {
    values: []const Value,
    key: ?[]const u8 = null,
};

pub const Page = struct {
    options: Options,
    rows: []const Row,
    has_next: bool,
    materialized_bytes: usize,
    display_limit_reached: bool,
    unstable_order: bool,
};

pub fn parseOptions(parameters: http_params.Parameters, columns: []const schema.ColumnMeta) !Options {
    var options = Options{};
    if (parameters.get("page")) |value| options.page = std.fmt.parseInt(usize, value, 10) catch return error.InvalidPage;
    if (parameters.get("size")) |value| {
        options.size = std.fmt.parseInt(usize, value, 10) catch return error.InvalidPageSize;
        if (!(options.size == 25 or options.size == 50 or options.size == 100 or options.size == 250)) return error.InvalidPageSize;
    }
    if (parameters.get("sort")) |value| {
        _ = findColumn(columns, value) orelse return error.InvalidSortColumn;
        options.sort = value;
    }
    if (parameters.get("direction")) |value| {
        if (options.sort == null) return error.DirectionWithoutSort;
        options.direction = if (std.mem.eql(u8, value, "asc"))
            .asc
        else if (std.mem.eql(u8, value, "desc"))
            .desc
        else
            return error.InvalidSortDirection;
    }

    const filter_column = parameters.get("filter_column");
    const filter_operator = parameters.get("filter_operator");
    const filter_value = parameters.get("filter_value") orelse "";
    const blank_filter = std.mem.eql(u8, filter_column orelse "", "") and
        std.mem.eql(u8, filter_operator orelse "", "") and
        std.mem.eql(u8, filter_value, "");
    if (!blank_filter and (filter_column != null or filter_operator != null or parameters.has("filter_value"))) {
        const column_name = filter_column orelse return error.IncompleteFilter;
        const column = findColumn(columns, column_name) orelse return error.InvalidFilterColumn;
        const operator = try FilterOperator.parse(filter_operator orelse return error.IncompleteFilter);
        if (declaredBlob(column.declared_type)) return error.BlobFilterUnsupported;
        options.filter = .{ .column = column_name, .operator = operator, .value = filter_value };
    }
    return options;
}

pub fn load(
    allocator: std.mem.Allocator,
    io: std.Io,
    database: *sqlite.Database,
    details: schema.ObjectDetails,
    options: Options,
) !Page {
    var deadline = sqlite.Deadline.afterSeconds(io, 10);
    database.installProgressHandler(&deadline);
    defer database.clearProgressHandler();
    if (details.columns.len > maximum_columns) return error.ObjectTooWide;
    const offset = std.math.mul(usize, options.page, options.size) catch return error.PageOverflow;
    if (offset > std.math.maxInt(i64)) return error.PageOverflow;

    var sql_writer: std.Io.Writer.Allocating = .init(allocator);
    const writer = &sql_writer.writer;
    try writer.writeAll("SELECT ");
    for (details.columns, 0..) |column, index| {
        if (index != 0) try writer.writeByte(',');
        const quoted = try sqlite.quoteIdentifier(allocator, column.name);
        try writer.writeAll(quoted);
    }
    const quoted_object = try sqlite.quoteIdentifier(allocator, details.object.name);
    try writer.writeAll(" FROM main.");
    try writer.writeAll(quoted_object);

    var bound_filter: ?[]const u8 = null;
    if (options.filter) |filter| {
        const quoted_column = try sqlite.quoteIdentifier(allocator, filter.column);
        try writer.writeAll(" WHERE ");
        try writer.writeAll(quoted_column);
        switch (filter.operator) {
            .equals => try writer.writeAll(" = ?1"),
            .not_equals => try writer.writeAll(" != ?1"),
            .less_than => try writer.writeAll(" < ?1"),
            .less_than_or_equal => try writer.writeAll(" <= ?1"),
            .greater_than => try writer.writeAll(" > ?1"),
            .greater_than_or_equal => try writer.writeAll(" >= ?1"),
            .contains => {
                try writer.writeAll(" LIKE ?1 ESCAPE '\\'");
                bound_filter = try escapedLike(allocator, filter.value, true);
            },
            .starts_with => {
                try writer.writeAll(" LIKE ?1 ESCAPE '\\'");
                bound_filter = try escapedLike(allocator, filter.value, false);
            },
            .is_null => try writer.writeAll(" IS NULL"),
            .is_not_null => try writer.writeAll(" IS NOT NULL"),
        }
        if (bound_filter == null and filter.operator != .is_null and filter.operator != .is_not_null) {
            bound_filter = filter.value;
        }
    }

    var stable_order = false;
    if (options.sort) |sort_column| {
        const quoted_sort = try sqlite.quoteIdentifier(allocator, sort_column);
        try writer.writeAll(" ORDER BY ");
        try writer.writeAll(quoted_sort);
        try writer.writeByte(' ');
        try writer.writeAll(options.direction.sql());
        stable_order = true;
    } else {
        var pk_position: usize = 1;
        var wrote_order = false;
        while (true) : (pk_position += 1) {
            const primary = primaryKeyAt(details.columns, pk_position) orelse break;
            if (!wrote_order) try writer.writeAll(" ORDER BY ") else try writer.writeByte(',');
            const quoted_primary = try sqlite.quoteIdentifier(allocator, primary.name);
            try writer.writeAll(quoted_primary);
            wrote_order = true;
        }
        stable_order = wrote_order;
    }

    const limit_index: usize = if (bound_filter != null) 2 else 1;
    try writer.print(" LIMIT ?{d} OFFSET ?{d}", .{ limit_index, limit_index + 1 });
    var statement = try database.prepare(sql_writer.written());
    defer statement.deinit();
    if (bound_filter) |value| try statement.bindText(1, value);
    try statement.bindInteger(limit_index, @intCast(options.size + 1));
    try statement.bindInteger(limit_index + 1, @intCast(offset));

    var rows: std.ArrayList(Row) = .empty;
    const primary_key_indices = if (details.object.structuredWritable())
        try primaryKeyIndices(allocator, details.columns)
    else
        &.{};
    var materialized: usize = 0;
    var has_next = false;
    var display_limit_reached = false;
    while (try statement.step() == .row) {
        if (rows.items.len == options.size) {
            has_next = true;
            break;
        }
        const values = try allocator.alloc(Value, details.columns.len);
        var row_bytes: usize = 0;
        for (values, 0..) |*value, index| {
            value.* = try copyValue(allocator, &statement, index, &row_bytes);
        }
        if (materialized + row_bytes > maximum_materialized_bytes) {
            display_limit_reached = true;
            break;
        }
        materialized += row_bytes;
        const key = if (primary_key_indices.len == 0)
            null
        else
            try row_token.encodeFromStatement(allocator, &statement, primary_key_indices);
        try rows.append(allocator, .{ .values = values, .key = key });
    }

    return .{
        .options = options,
        .rows = try rows.toOwnedSlice(allocator),
        .has_next = has_next,
        .materialized_bytes = materialized,
        .display_limit_reached = display_limit_reached,
        .unstable_order = !stable_order,
    };
}

pub fn copyValue(
    allocator: std.mem.Allocator,
    statement: *const sqlite.Statement,
    index: usize,
    copied: *usize,
) !Value {
    return copyValueLimited(allocator, statement, index, copied, grid_text_preview);
}

pub fn copyDetailedValue(
    allocator: std.mem.Allocator,
    statement: *const sqlite.Statement,
    index: usize,
    copied: *usize,
) !Value {
    return copyValueLimited(allocator, statement, index, copied, 64 * 1024);
}

fn copyValueLimited(
    allocator: std.mem.Allocator,
    statement: *const sqlite.Statement,
    index: usize,
    copied: *usize,
    text_limit: usize,
) !Value {
    return switch (statement.columnType(index)) {
        sqlite.raw.SQLITE_NULL => .null,
        sqlite.raw.SQLITE_INTEGER => .{ .integer = statement.columnInteger(index) },
        sqlite.raw.SQLITE_FLOAT => .{ .real = statement.columnReal(index) },
        sqlite.raw.SQLITE_TEXT => blk: {
            const source = statement.columnText(index);
            const prefix = source[0..@min(source.len, text_limit)];
            var display: std.Io.Writer.Allocating = .init(allocator);
            try display.writer.print("{f}", .{std.unicode.fmtUtf8(prefix)});
            const bytes = try display.toOwnedSlice();
            copied.* += bytes.len;
            break :blk .{ .text = .{
                .bytes = bytes,
                .original_len = source.len,
                .truncated = prefix.len < source.len,
                .valid_utf8 = std.unicode.utf8ValidateSlice(source),
            } };
        },
        sqlite.raw.SQLITE_BLOB => blk: {
            const source = statement.columnBlob(index);
            const prefix = try allocator.dupe(u8, source[0..@min(source.len, blob_prefix_bytes)]);
            copied.* += prefix.len;
            break :blk .{ .blob = .{
                .prefix = prefix,
                .original_len = source.len,
                .truncated = prefix.len < source.len,
            } };
        },
        else => return error.UnknownRuntimeType,
    };
}

fn findColumn(columns: []const schema.ColumnMeta, name: []const u8) ?schema.ColumnMeta {
    for (columns) |column| {
        if (std.mem.eql(u8, column.name, name)) return column;
    }
    return null;
}

fn primaryKeyAt(columns: []const schema.ColumnMeta, position: usize) ?schema.ColumnMeta {
    for (columns) |column| {
        if (column.primary_key_position == position) return column;
    }
    return null;
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
        for (columns, 0..) |column, index| {
            if (column.primary_key_position == position) {
                indices[position - 1] = index;
                found = true;
                break;
            }
        }
        if (!found) return error.InvalidPrimaryKeyMetadata;
    }
    return indices;
}

fn escapedLike(allocator: std.mem.Allocator, value: []const u8, contains: bool) ![]u8 {
    var output: std.Io.Writer.Allocating = .init(allocator);
    if (contains) try output.writer.writeByte('%');
    for (value) |byte| {
        if (byte == '%' or byte == '_' or byte == '\\') try output.writer.writeByte('\\');
        try output.writer.writeByte(byte);
    }
    try output.writer.writeByte('%');
    return output.toOwnedSlice();
}

fn declaredBlob(declared_type: []const u8) bool {
    return containsIgnoreCase(declared_type, "BLOB");
}

fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len > haystack.len) return false;
    var index: usize = 0;
    while (index + needle.len <= haystack.len) : (index += 1) {
        if (std.ascii.eqlIgnoreCase(haystack[index .. index + needle.len], needle)) return true;
    }
    return needle.len == 0;
}

test "LIKE filter escaping preserves wildcard characters as literals" {
    const escaped = try escapedLike(std.testing.allocator, "50%_off\\today", true);
    defer std.testing.allocator.free(escaped);
    try std.testing.expectEqualStrings("%50\\%\\_off\\\\today%", escaped);
}
