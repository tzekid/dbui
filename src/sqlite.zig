const std = @import("std");
const c = @import("sqlite_c");

pub const raw = c;

pub const AccessMode = enum {
    read_only,
    read_write,

    pub fn label(self: AccessMode) []const u8 {
        return switch (self) {
            .read_only => "READ-ONLY",
            .read_write => "READ/WRITE",
        };
    }
};

pub const Step = enum { row, done };

pub const Database = struct {
    handle: *c.sqlite3,
    mode: AccessMode,
    authorizer_denied: bool = false,

    pub fn open(allocator: std.mem.Allocator, path: []const u8, mode: AccessMode) !Database {
        const path_z = try allocator.dupeSentinel(u8, path, 0);
        defer allocator.free(path_z);

        var raw_handle: ?*c.sqlite3 = null;
        const access_flags: c_int = switch (mode) {
            .read_only => c.SQLITE_OPEN_READONLY,
            .read_write => c.SQLITE_OPEN_READWRITE,
        };
        const rc = c.sqlite3_open_v2(
            path_z.ptr,
            &raw_handle,
            access_flags | c.SQLITE_OPEN_EXRESCODE,
            null,
        );
        if (rc != c.SQLITE_OK or raw_handle == null) {
            if (raw_handle) |handle| _ = c.sqlite3_close(handle);
            return error.DatabaseOpenFailed;
        }

        var database: Database = .{ .handle = raw_handle.?, .mode = mode };
        errdefer database.deinit();
        try database.configure();

        const readonly = c.sqlite3_db_readonly(database.handle, "main");
        if (readonly < 0) return error.DatabaseStateUnavailable;
        if (mode == .read_write and readonly != 0) return error.DatabaseOpenedReadOnly;
        if (mode == .read_only and readonly == 0) return error.DatabaseOpenedWritable;
        return database;
    }

    fn configure(self: *Database) !void {
        if (c.sqlite3_extended_result_codes(self.handle, 1) != c.SQLITE_OK) return error.DatabaseConfigurationFailed;
        if (c.sqlite3_busy_timeout(self.handle, 1500) != c.SQLITE_OK) return error.DatabaseConfigurationFailed;

        var applied: c_int = 0;
        if (c.sqlite3_db_config(self.handle, c.SQLITE_DBCONFIG_DEFENSIVE, @as(c_int, 1), &applied) != c.SQLITE_OK)
            return error.DatabaseConfigurationFailed;
        if (c.sqlite3_db_config(self.handle, c.SQLITE_DBCONFIG_ENABLE_LOAD_EXTENSION, @as(c_int, 0), &applied) != c.SQLITE_OK)
            return error.DatabaseConfigurationFailed;
        if (c.sqlite3_db_config(self.handle, c.SQLITE_DBCONFIG_TRUSTED_SCHEMA, @as(c_int, 0), &applied) != c.SQLITE_OK)
            return error.DatabaseConfigurationFailed;

        if (self.mode == .read_only) {
            try self.exec("PRAGMA query_only=ON");
        } else {
            try self.exec("PRAGMA foreign_keys=ON");
        }
    }

    pub fn deinit(self: *Database) void {
        _ = c.sqlite3_close_v2(self.handle);
        self.* = undefined;
    }

    pub fn errorMessage(self: *const Database) []const u8 {
        return std.mem.span(c.sqlite3_errmsg(self.handle));
    }

    pub fn primaryCode(self: *const Database) c_int {
        return c.sqlite3_errcode(self.handle);
    }

    pub fn extendedCode(self: *const Database) c_int {
        return c.sqlite3_extended_errcode(self.handle);
    }

    pub fn prepare(self: *Database, sql: []const u8) !Statement {
        var raw_statement: ?*c.sqlite3_stmt = null;
        const rc = c.sqlite3_prepare_v3(
            self.handle,
            sql.ptr,
            @intCast(sql.len),
            0,
            &raw_statement,
            null,
        );
        if (rc != c.SQLITE_OK) {
            if (self.authorizer_denied) return error.StatementProhibited;
            return sqliteError(c.sqlite3_extended_errcode(self.handle), error.SqlitePrepareFailed);
        }
        if (raw_statement == null) return error.EmptyStatement;
        return .{ .database = self, .handle = raw_statement.? };
    }

    pub fn prepareWithTail(self: *Database, sql: []const u8) !Prepared {
        var raw_statement: ?*c.sqlite3_stmt = null;
        var tail: [*c]const u8 = null;
        const rc = c.sqlite3_prepare_v3(
            self.handle,
            sql.ptr,
            @intCast(sql.len),
            0,
            &raw_statement,
            &tail,
        );
        if (rc != c.SQLITE_OK) {
            if (self.authorizer_denied) return error.StatementProhibited;
            return sqliteError(c.sqlite3_extended_errcode(self.handle), error.SqlitePrepareFailed);
        }
        const consumed = @intFromPtr(tail) - @intFromPtr(sql.ptr);
        return .{
            .statement = if (raw_statement) |handle| .{ .database = self, .handle = handle } else null,
            .tail = sql[@min(consumed, sql.len)..],
        };
    }

    pub fn installQueryAuthorizer(self: *Database) !void {
        self.authorizer_denied = false;
        if (c.sqlite3_set_authorizer(self.handle, queryAuthorizer, self) != c.SQLITE_OK) {
            return error.DatabaseConfigurationFailed;
        }
    }

    pub fn installProgressHandler(self: *Database, deadline: *Deadline) void {
        c.sqlite3_progress_handler(self.handle, 1000, progressHandler, deadline);
    }

    pub fn clearProgressHandler(self: *Database) void {
        c.sqlite3_progress_handler(self.handle, 0, null, null);
    }

    pub fn exec(self: *Database, sql: []const u8) !void {
        var statement = try self.prepare(sql);
        defer statement.deinit();
        while (try statement.step() == .row) {}
    }

    pub fn changes(self: *const Database) usize {
        return @intCast(c.sqlite3_changes64(self.handle));
    }

    pub fn lastInsertRowId(self: *const Database) i64 {
        return c.sqlite3_last_insert_rowid(self.handle);
    }
};

pub const Prepared = struct {
    statement: ?Statement,
    tail: []const u8,
};

pub const Deadline = struct {
    io: std.Io,
    expires_ns: i96,

    pub fn afterSeconds(io: std.Io, seconds: i64) Deadline {
        return .{
            .io = io,
            .expires_ns = std.Io.Timestamp.now(io, .awake).toNanoseconds() + @as(i96, seconds) * std.time.ns_per_s,
        };
    }
};

pub const Statement = struct {
    database: *Database,
    handle: *c.sqlite3_stmt,

    pub fn deinit(self: *Statement) void {
        _ = c.sqlite3_finalize(self.handle);
        self.* = undefined;
    }

    pub fn step(self: *Statement) !Step {
        const rc = c.sqlite3_step(self.handle);
        return switch (rc) {
            c.SQLITE_ROW => .row,
            c.SQLITE_DONE => .done,
            else => sqliteError(rc, error.SqliteStepFailed),
        };
    }

    pub fn isReadOnly(self: *const Statement) bool {
        return c.sqlite3_stmt_readonly(self.handle) != 0;
    }

    pub fn bindNull(self: *Statement, index: usize) !void {
        try bindResult(c.sqlite3_bind_null(self.handle, @intCast(index)));
    }

    pub fn bindInteger(self: *Statement, index: usize, value: i64) !void {
        try bindResult(c.sqlite3_bind_int64(self.handle, @intCast(index), value));
    }

    pub fn bindReal(self: *Statement, index: usize, value: f64) !void {
        try bindResult(c.sqlite3_bind_double(self.handle, @intCast(index), value));
    }

    pub fn bindText(self: *Statement, index: usize, value: []const u8) !void {
        try bindResult(c.sqlite3_bind_text64(
            self.handle,
            @intCast(index),
            value.ptr,
            @intCast(value.len),
            null,
            c.SQLITE_UTF8,
        ));
    }

    pub fn bindBlob(self: *Statement, index: usize, value: []const u8) !void {
        try bindResult(c.sqlite3_bind_blob64(
            self.handle,
            @intCast(index),
            value.ptr,
            @intCast(value.len),
            null,
        ));
    }

    pub fn columnCount(self: *const Statement) usize {
        return @intCast(c.sqlite3_column_count(self.handle));
    }

    pub fn columnName(self: *const Statement, index: usize) []const u8 {
        const name = c.sqlite3_column_name(self.handle, @intCast(index));
        return if (name == null) "" else std.mem.span(name);
    }

    pub fn columnType(self: *const Statement, index: usize) c_int {
        return c.sqlite3_column_type(self.handle, @intCast(index));
    }

    pub fn columnInteger(self: *const Statement, index: usize) i64 {
        return c.sqlite3_column_int64(self.handle, @intCast(index));
    }

    pub fn columnReal(self: *const Statement, index: usize) f64 {
        return c.sqlite3_column_double(self.handle, @intCast(index));
    }

    /// Borrowed until the next step/finalize. Callers copy into request memory.
    pub fn columnText(self: *const Statement, index: usize) []const u8 {
        const length: usize = @intCast(c.sqlite3_column_bytes(self.handle, @intCast(index)));
        const pointer = c.sqlite3_column_text(self.handle, @intCast(index));
        if (pointer == null or length == 0) return "";
        return @as([*]const u8, @ptrCast(pointer))[0..length];
    }

    /// Borrowed until the next step/finalize. Callers copy into request memory.
    pub fn columnBlob(self: *const Statement, index: usize) []const u8 {
        const length: usize = @intCast(c.sqlite3_column_bytes(self.handle, @intCast(index)));
        const pointer = c.sqlite3_column_blob(self.handle, @intCast(index));
        if (pointer == null or length == 0) return "";
        return @as([*]const u8, @ptrCast(pointer))[0..length];
    }
};

fn bindResult(rc: c_int) !void {
    if (rc != c.SQLITE_OK) return sqliteError(rc, error.SqliteBindFailed);
}

fn sqliteError(rc: c_int, fallback: anyerror) anyerror {
    return switch (rc & 0xff) {
        c.SQLITE_BUSY, c.SQLITE_LOCKED => error.DatabaseBusy,
        c.SQLITE_CONSTRAINT => error.SqliteConstraint,
        c.SQLITE_INTERRUPT => error.QueryInterrupted,
        c.SQLITE_READONLY => error.DatabaseReadOnly,
        c.SQLITE_AUTH => error.StatementProhibited,
        c.SQLITE_CORRUPT, c.SQLITE_NOTADB => error.InvalidDatabase,
        else => fallback,
    };
}

fn queryAuthorizer(
    userdata: ?*anyopaque,
    action: c_int,
    _: [*c]const u8,
    _: [*c]const u8,
    _: [*c]const u8,
    _: [*c]const u8,
) callconv(.c) c_int {
    switch (action) {
        c.SQLITE_ATTACH, c.SQLITE_DETACH, c.SQLITE_TRANSACTION, c.SQLITE_SAVEPOINT => {
            const database: *Database = @ptrCast(@alignCast(userdata orelse return c.SQLITE_DENY));
            database.authorizer_denied = true;
            return c.SQLITE_DENY;
        },
        else => return c.SQLITE_OK,
    }
}

fn progressHandler(userdata: ?*anyopaque) callconv(.c) c_int {
    const deadline: *Deadline = @ptrCast(@alignCast(userdata orelse return 1));
    return @intFromBool(std.Io.Timestamp.now(deadline.io, .awake).toNanoseconds() >= deadline.expires_ns);
}

pub fn quoteIdentifier(allocator: std.mem.Allocator, identifier: []const u8) ![]u8 {
    var output: std.Io.Writer.Allocating = .init(allocator);
    errdefer output.deinit();
    try output.writer.writeByte('"');
    for (identifier) |byte| {
        if (byte == '"') try output.writer.writeByte('"');
        try output.writer.writeByte(byte);
    }
    try output.writer.writeByte('"');
    return output.toOwnedSlice();
}

test "vendored SQLite and central identifier quoting" {
    try std.testing.expectEqualStrings("3.53.4", std.mem.span(c.sqlite3_libversion()));
    const quoted = try quoteIdentifier(std.testing.allocator, "odd\"name");
    defer std.testing.allocator.free(quoted);
    try std.testing.expectEqualStrings("\"odd\"\"name\"", quoted);
}
