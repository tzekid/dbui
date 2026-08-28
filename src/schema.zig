const std = @import("std");
const sqlite = @import("sqlite.zig");

pub const Overview = struct {
    sqlite_version: []const u8,
    user_version: i64,
    application_id: i64,
    journal_mode: []const u8,
    tables: usize,
    views: usize,
    indexes: usize,
    triggers: usize,
    strict_tables: usize,
    without_rowid_tables: usize,
};

pub const ObjectKind = enum {
    table,
    view,
    virtual,
    shadow,

    pub fn label(self: ObjectKind) []const u8 {
        return switch (self) {
            .table => "TABLE",
            .view => "VIEW",
            .virtual => "VIRTUAL",
            .shadow => "INTERNAL",
        };
    }
};

pub const ObjectMeta = struct {
    name: []const u8,
    kind: ObjectKind,
    column_count: usize,
    without_rowid: bool,
    strict: bool,
    internal: bool,

    pub fn structuredWritable(self: ObjectMeta) bool {
        return self.kind == .table and !self.internal;
    }
};

pub const ColumnMeta = struct {
    position: i64,
    name: []const u8,
    declared_type: []const u8,
    not_null: bool,
    default_sql: ?[]const u8,
    primary_key_position: usize,
    hidden: usize,

    pub fn normal(self: ColumnMeta) bool {
        return self.hidden == 0;
    }

    pub fn generated(self: ColumnMeta) bool {
        return self.hidden == 2 or self.hidden == 3;
    }
};

pub const IndexColumn = struct {
    sequence: i64,
    cid: i64,
    name: ?[]const u8,
    descending: bool,
    collation: ?[]const u8,
    key: bool,
};

pub const IndexMeta = struct {
    name: []const u8,
    unique: bool,
    origin: []const u8,
    partial: bool,
    sql: ?[]const u8,
    columns: []const IndexColumn,
};

pub const ForeignKeyMeta = struct {
    id: i64,
    sequence: i64,
    target_table: []const u8,
    source_column: []const u8,
    target_column: ?[]const u8,
    on_update: []const u8,
    on_delete: []const u8,
    match: []const u8,
};

pub const TriggerMeta = struct {
    name: []const u8,
    sql: ?[]const u8,
};

pub const ObjectDetails = struct {
    object: ObjectMeta,
    sql: ?[]const u8,
    columns: []const ColumnMeta,
    indexes: []const IndexMeta,
    foreign_keys: []const ForeignKeyMeta,
    triggers: []const TriggerMeta,
};

pub fn loadOverview(allocator: std.mem.Allocator, database: *sqlite.Database) !Overview {
    return .{
        .sqlite_version = std.mem.span(sqlite.raw.sqlite3_libversion()),
        .user_version = try scalarInteger(database, "PRAGMA main.user_version"),
        .application_id = try scalarInteger(database, "PRAGMA main.application_id"),
        .journal_mode = try scalarText(allocator, database, "PRAGMA main.journal_mode"),
        .tables = @intCast(try scalarInteger(database, "SELECT count(*) FROM main.sqlite_schema WHERE type='table' AND name NOT LIKE 'sqlite_%'")),
        .views = @intCast(try scalarInteger(database, "SELECT count(*) FROM main.sqlite_schema WHERE type='view' AND name NOT LIKE 'sqlite_%'")),
        .indexes = @intCast(try scalarInteger(database, "SELECT count(*) FROM main.sqlite_schema WHERE type='index' AND name NOT LIKE 'sqlite_%'")),
        .triggers = @intCast(try scalarInteger(database, "SELECT count(*) FROM main.sqlite_schema WHERE type='trigger' AND name NOT LIKE 'sqlite_%'")),
        .strict_tables = @intCast(try scalarInteger(database, "SELECT count(*) FROM pragma_table_list WHERE schema='main' AND type='table' AND strict=1 AND name NOT LIKE 'sqlite_%'")),
        .without_rowid_tables = @intCast(try scalarInteger(database, "SELECT count(*) FROM pragma_table_list WHERE schema='main' AND type='table' AND wr=1 AND name NOT LIKE 'sqlite_%'")),
    };
}

pub fn listObjects(
    allocator: std.mem.Allocator,
    database: *sqlite.Database,
    include_internal: bool,
    search: []const u8,
) ![]ObjectMeta {
    var statement = try database.prepare("PRAGMA main.table_list");
    defer statement.deinit();
    var objects: std.ArrayList(ObjectMeta) = .empty;
    while (try statement.step() == .row) {
        if (!std.mem.eql(u8, statement.columnText(0), "main")) continue;
        const raw_kind = statement.columnText(2);
        const kind: ObjectKind = if (std.mem.eql(u8, raw_kind, "table"))
            .table
        else if (std.mem.eql(u8, raw_kind, "view"))
            .view
        else if (std.mem.eql(u8, raw_kind, "virtual"))
            .virtual
        else if (std.mem.eql(u8, raw_kind, "shadow"))
            .shadow
        else
            continue;
        const borrowed_name = statement.columnText(1);
        const internal = kind == .shadow or std.mem.startsWith(u8, borrowed_name, "sqlite_");
        if (internal and !include_internal) continue;
        if (search.len != 0 and !containsIgnoreCase(borrowed_name, search)) continue;
        try objects.append(allocator, .{
            .name = try allocator.dupe(u8, borrowed_name),
            .kind = kind,
            .column_count = @intCast(statement.columnInteger(3)),
            .without_rowid = statement.columnInteger(4) != 0,
            .strict = statement.columnInteger(5) != 0,
            .internal = internal,
        });
    }
    std.mem.sort(ObjectMeta, objects.items, {}, objectLessThan);
    return objects.toOwnedSlice(allocator);
}

pub fn findObject(allocator: std.mem.Allocator, database: *sqlite.Database, name: []const u8) !?ObjectMeta {
    const objects = try listObjects(allocator, database, true, "");
    for (objects) |object| {
        if (std.mem.eql(u8, object.name, name)) return object;
    }
    return null;
}

pub fn loadObjectDetails(
    allocator: std.mem.Allocator,
    database: *sqlite.Database,
    object: ObjectMeta,
) !ObjectDetails {
    const columns = try loadColumns(allocator, database, object.name);
    return .{
        .object = object,
        .sql = try storedSql(allocator, database, object.name, null),
        .columns = columns,
        .indexes = if (object.kind == .table) try loadIndexes(allocator, database, object.name) else &.{},
        .foreign_keys = if (object.kind == .table) try loadForeignKeys(allocator, database, object.name) else &.{},
        .triggers = try loadTriggers(allocator, database, object.name),
    };
}

pub fn loadColumns(allocator: std.mem.Allocator, database: *sqlite.Database, object_name: []const u8) ![]ColumnMeta {
    const quoted = try sqlite.quoteIdentifier(allocator, object_name);
    const sql = try std.fmt.allocPrint(allocator, "PRAGMA main.table_xinfo({s})", .{quoted});
    var statement = try database.prepare(sql);
    defer statement.deinit();
    var columns: std.ArrayList(ColumnMeta) = .empty;
    while (try statement.step() == .row) {
        try columns.append(allocator, .{
            .position = statement.columnInteger(0),
            .name = try allocator.dupe(u8, statement.columnText(1)),
            .declared_type = try allocator.dupe(u8, statement.columnText(2)),
            .not_null = statement.columnInteger(3) != 0,
            .default_sql = try copyOptionalText(allocator, &statement, 4),
            .primary_key_position = @intCast(statement.columnInteger(5)),
            .hidden = @intCast(statement.columnInteger(6)),
        });
    }
    return columns.toOwnedSlice(allocator);
}

fn loadIndexes(allocator: std.mem.Allocator, database: *sqlite.Database, object_name: []const u8) ![]IndexMeta {
    const quoted = try sqlite.quoteIdentifier(allocator, object_name);
    const sql = try std.fmt.allocPrint(allocator, "PRAGMA main.index_list({s})", .{quoted});
    var statement = try database.prepare(sql);
    defer statement.deinit();
    var indexes: std.ArrayList(IndexMeta) = .empty;
    while (try statement.step() == .row) {
        const name = try allocator.dupe(u8, statement.columnText(1));
        try indexes.append(allocator, .{
            .name = name,
            .unique = statement.columnInteger(2) != 0,
            .origin = try allocator.dupe(u8, statement.columnText(3)),
            .partial = statement.columnInteger(4) != 0,
            .sql = try storedSql(allocator, database, name, "index"),
            .columns = try loadIndexColumns(allocator, database, name),
        });
    }
    return indexes.toOwnedSlice(allocator);
}

fn loadIndexColumns(allocator: std.mem.Allocator, database: *sqlite.Database, index_name: []const u8) ![]IndexColumn {
    const quoted = try sqlite.quoteIdentifier(allocator, index_name);
    const sql = try std.fmt.allocPrint(allocator, "PRAGMA main.index_xinfo({s})", .{quoted});
    var statement = try database.prepare(sql);
    defer statement.deinit();
    var columns: std.ArrayList(IndexColumn) = .empty;
    while (try statement.step() == .row) {
        try columns.append(allocator, .{
            .sequence = statement.columnInteger(0),
            .cid = statement.columnInteger(1),
            .name = try copyOptionalText(allocator, &statement, 2),
            .descending = statement.columnInteger(3) != 0,
            .collation = try copyOptionalText(allocator, &statement, 4),
            .key = statement.columnInteger(5) != 0,
        });
    }
    return columns.toOwnedSlice(allocator);
}

fn loadForeignKeys(allocator: std.mem.Allocator, database: *sqlite.Database, object_name: []const u8) ![]ForeignKeyMeta {
    const quoted = try sqlite.quoteIdentifier(allocator, object_name);
    const sql = try std.fmt.allocPrint(allocator, "PRAGMA main.foreign_key_list({s})", .{quoted});
    var statement = try database.prepare(sql);
    defer statement.deinit();
    var foreign_keys: std.ArrayList(ForeignKeyMeta) = .empty;
    while (try statement.step() == .row) {
        try foreign_keys.append(allocator, .{
            .id = statement.columnInteger(0),
            .sequence = statement.columnInteger(1),
            .target_table = try allocator.dupe(u8, statement.columnText(2)),
            .source_column = try allocator.dupe(u8, statement.columnText(3)),
            .target_column = try copyOptionalText(allocator, &statement, 4),
            .on_update = try allocator.dupe(u8, statement.columnText(5)),
            .on_delete = try allocator.dupe(u8, statement.columnText(6)),
            .match = try allocator.dupe(u8, statement.columnText(7)),
        });
    }
    return foreign_keys.toOwnedSlice(allocator);
}

fn loadTriggers(allocator: std.mem.Allocator, database: *sqlite.Database, object_name: []const u8) ![]TriggerMeta {
    var statement = try database.prepare(
        "SELECT name, sql FROM main.sqlite_schema WHERE type='trigger' AND tbl_name=?1 ORDER BY name COLLATE NOCASE, name",
    );
    defer statement.deinit();
    try statement.bindText(1, object_name);
    var triggers: std.ArrayList(TriggerMeta) = .empty;
    while (try statement.step() == .row) {
        try triggers.append(allocator, .{
            .name = try allocator.dupe(u8, statement.columnText(0)),
            .sql = try copyOptionalText(allocator, &statement, 1),
        });
    }
    return triggers.toOwnedSlice(allocator);
}

fn storedSql(
    allocator: std.mem.Allocator,
    database: *sqlite.Database,
    name: []const u8,
    object_type: ?[]const u8,
) !?[]const u8 {
    const sql = if (object_type == null)
        "SELECT sql FROM main.sqlite_schema WHERE name=?1"
    else
        "SELECT sql FROM main.sqlite_schema WHERE name=?1 AND type=?2";
    var statement = try database.prepare(sql);
    defer statement.deinit();
    try statement.bindText(1, name);
    if (object_type) |kind| try statement.bindText(2, kind);
    if (try statement.step() != .row) return null;
    return copyOptionalText(allocator, &statement, 0);
}

fn copyOptionalText(allocator: std.mem.Allocator, statement: *sqlite.Statement, index: usize) !?[]const u8 {
    if (statement.columnType(index) == sqlite.raw.SQLITE_NULL) return null;
    return try allocator.dupe(u8, statement.columnText(index));
}

fn objectLessThan(_: void, left: ObjectMeta, right: ObjectMeta) bool {
    const order = std.ascii.orderIgnoreCase(left.name, right.name);
    return order == .lt or (order == .eq and std.mem.order(u8, left.name, right.name) == .lt);
}

fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (needle.len > haystack.len) return false;
    var index: usize = 0;
    while (index + needle.len <= haystack.len) : (index += 1) {
        if (std.ascii.eqlIgnoreCase(haystack[index .. index + needle.len], needle)) return true;
    }
    return false;
}

fn scalarInteger(database: *sqlite.Database, sql: []const u8) !i64 {
    var statement = try database.prepare(sql);
    defer statement.deinit();
    if (try statement.step() != .row) return error.MissingScalarResult;
    if (statement.columnType(0) != sqlite.raw.SQLITE_INTEGER) return error.InvalidScalarResult;
    return statement.columnInteger(0);
}

fn scalarText(allocator: std.mem.Allocator, database: *sqlite.Database, sql: []const u8) ![]u8 {
    var statement = try database.prepare(sql);
    defer statement.deinit();
    if (try statement.step() != .row) return error.MissingScalarResult;
    return allocator.dupe(u8, statement.columnText(0));
}
