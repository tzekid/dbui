const std = @import("std");
const sqlite = @import("sqlite.zig");
const config = @import("config.zig");

pub const session_seconds = 12 * 60 * 60;
pub const setup_seconds = 60 * 60;
pub const challenge_seconds = 5 * 60;
pub const recent_seconds = 10 * 60;

pub const Session = struct {
    hash: []const u8,
    csrf: [64]u8,
    credential: i64,
    created: i64,
    expires: i64,
};

pub const Store = struct {
    db: sqlite.Database,

    pub fn check(allocator: std.mem.Allocator, io: std.Io, settings: config.Auth) !void {
        const stat = std.Io.Dir.cwd().statFile(io, settings.state_path, .{ .follow_symlinks = false }) catch |err| switch (err) {
            error.FileNotFound => return,
            else => return err,
        };
        if (stat.kind != .file or stat.nlink != 1 or stat.permissions.toMode() & 0o077 != 0) return error.AuthDatabaseMustBePrivate;
        var db = try sqlite.Database.open(allocator, settings.state_path, .read_only);
        defer db.deinit();
        var origin = try db.prepare("SELECT value FROM metadata WHERE key='origin'");
        defer origin.deinit();
        if (try origin.step() != .row or !std.mem.eql(u8, origin.columnText(0), settings.origin)) return error.AuthOriginChanged;
    }

    pub fn open(allocator: std.mem.Allocator, settings: config.Auth) !Store {
        return .{ .db = try sqlite.Database.open(allocator, settings.state_path, .read_write) };
    }

    pub fn init(allocator: std.mem.Allocator, io: std.Io, settings: config.Auth) !Store {
        const file = std.Io.Dir.cwd().createFile(io, settings.state_path, .{
            .exclusive = true,
            .permissions = .fromMode(0o600),
        }) catch |err| switch (err) {
            error.PathAlreadyExists => null,
            else => return err,
        };
        if (file) |created| created.close(io);
        const stat = try std.Io.Dir.cwd().statFile(io, settings.state_path, .{ .follow_symlinks = false });
        if (stat.kind != .file or stat.nlink != 1 or stat.permissions.toMode() & 0o077 != 0) return error.AuthDatabaseMustBePrivate;
        var store = try open(allocator, settings);
        errdefer store.deinit();
        // FULL durability, rollback journal and a private directory also protect
        // the sidecar files when the operator invokes the CLI outside systemd.
        try store.db.exec("PRAGMA synchronous=FULL");
        try store.db.exec("BEGIN IMMEDIATE");
        errdefer store.db.exec("ROLLBACK") catch {};
        for ([_][]const u8{
            "CREATE TABLE IF NOT EXISTS metadata (key TEXT PRIMARY KEY, value TEXT NOT NULL) STRICT",
            "CREATE TABLE IF NOT EXISTS passkeys (id INTEGER PRIMARY KEY, credential_id TEXT NOT NULL UNIQUE, public_key TEXT NOT NULL, label TEXT NOT NULL, sign_count INTEGER NOT NULL, backup_eligible INTEGER NOT NULL, backup_state INTEGER NOT NULL, created INTEGER NOT NULL, last_used INTEGER) STRICT",
            "CREATE TABLE IF NOT EXISTS sessions (hash TEXT PRIMARY KEY, csrf TEXT NOT NULL, credential INTEGER NOT NULL REFERENCES passkeys(id) ON DELETE CASCADE, created INTEGER NOT NULL, expires INTEGER NOT NULL) STRICT",
            "CREATE TABLE IF NOT EXISTS challenges (id TEXT PRIMARY KEY, purpose TEXT NOT NULL, binding TEXT NOT NULL, authorization TEXT NOT NULL, expires INTEGER NOT NULL) STRICT",
            "CREATE TABLE IF NOT EXISTS bootstrap (id INTEGER PRIMARY KEY CHECK(id=1), hash TEXT NOT NULL, expires INTEGER NOT NULL) STRICT",
            "CREATE TABLE IF NOT EXISTS rate_limits (key TEXT PRIMARY KEY, window INTEGER NOT NULL, attempts INTEGER NOT NULL) STRICT",
        }) |sql| try store.db.exec(sql);
        try store.exec("INSERT OR IGNORE INTO metadata VALUES ('origin',?)", .{settings.origin});
        var origin = try store.prepare("SELECT value FROM metadata WHERE key='origin'", .{});
        defer origin.deinit();
        if (try origin.step() != .row or !std.mem.eql(u8, origin.columnText(0), settings.origin)) return error.AuthOriginChanged;
        try store.exec("INSERT OR IGNORE INTO metadata VALUES ('user_handle',?)", .{&randomToken(io)});
        try store.db.exec("COMMIT");
        return store;
    }

    pub fn deinit(self: *Store) void {
        self.db.deinit();
    }

    pub fn prepare(self: *Store, sql: []const u8, values: anytype) !sqlite.Statement {
        var statement = try self.db.prepare(sql);
        errdefer statement.deinit();
        inline for (values, 0..) |value, index| {
            switch (@typeInfo(@TypeOf(value))) {
                .int, .comptime_int => try statement.bindInteger(index + 1, @intCast(value)),
                .bool => try statement.bindInteger(index + 1, @intFromBool(value)),
                else => try statement.bindText(index + 1, value),
            }
        }
        return statement;
    }

    pub fn exec(self: *Store, sql: []const u8, values: anytype) !void {
        var statement = try self.prepare(sql, values);
        defer statement.deinit();
        while (try statement.step() == .row) {}
    }

    pub fn count(self: *Store, sql: []const u8, values: anytype) !i64 {
        var statement = try self.prepare(sql, values);
        defer statement.deinit();
        if (try statement.step() != .row) return error.AuthStateInvalid;
        return statement.columnInteger(0);
    }

    pub fn session(self: *Store, allocator: std.mem.Allocator, token: []const u8, at: i64) !?Session {
        if (!validToken(token)) return null;
        const hash = tokenHash(token);
        var statement = try self.prepare("SELECT csrf,credential,created,expires FROM sessions WHERE hash=? AND expires>?", .{ &hash, at });
        defer statement.deinit();
        if (try statement.step() != .row) return null;
        const csrf = statement.columnText(0);
        if (csrf.len != 64) return error.AuthStateInvalid;
        return .{
            .hash = try allocator.dupe(u8, &hash),
            .csrf = csrf[0..64].*,
            .credential = statement.columnInteger(1),
            .created = statement.columnInteger(2),
            .expires = statement.columnInteger(3),
        };
    }

    pub fn issueSession(self: *Store, io: std.Io, credential: i64, previous: ?Session) ![43]u8 {
        const token = randomToken(io);
        const hash = tokenHash(&token);
        const csrf = tokenHash(&randomToken(io));
        const at = now(io);
        try self.cleanup(at);
        // Bound the store even when one credential repeatedly signs in.
        try self.exec("DELETE FROM sessions WHERE hash IN (SELECT hash FROM sessions ORDER BY created DESC LIMIT -1 OFFSET 31)", .{});
        if (previous) |old| try self.exec("DELETE FROM sessions WHERE hash=?", .{old.hash});
        try self.exec("INSERT INTO sessions VALUES (?,?,?,?,?)", .{ &hash, &csrf, credential, at, at + session_seconds });
        return token;
    }

    pub fn cleanup(self: *Store, at: i64) !void {
        try self.exec("DELETE FROM challenges WHERE expires<=?", .{at});
        try self.exec("DELETE FROM sessions WHERE expires<=?", .{at});
        try self.exec("DELETE FROM bootstrap WHERE expires<=?", .{at});
        try self.exec("DELETE FROM rate_limits WHERE window<?", .{at - 120});
    }

    pub fn setupValid(self: *Store, token: []const u8, at: i64) !bool {
        if (!validToken(token)) return false;
        const hash = tokenHash(token);
        return try self.count("SELECT count(*) FROM bootstrap WHERE id=1 AND hash=? AND expires>? AND NOT EXISTS(SELECT 1 FROM passkeys)", .{ &hash, at }) == 1;
    }

    pub fn setup(self: *Store, io: std.Io) ![43]u8 {
        try self.db.exec("BEGIN IMMEDIATE");
        errdefer self.db.exec("ROLLBACK") catch {};
        if (try self.count("SELECT count(*) FROM passkeys", .{}) != 0) return error.AlreadyEnrolled;
        const token = randomToken(io);
        const hash = tokenHash(&token);
        try self.exec("INSERT OR REPLACE INTO bootstrap VALUES (1,?,?)", .{ &hash, now(io) + setup_seconds });
        try self.db.exec("DELETE FROM challenges");
        try self.db.exec("COMMIT");
        return token;
    }

    // Apply both a per-client budget and a global ceiling. Only Caddy's direct
    // loopback connection may supply X-Forwarded-For; changing that trust
    // boundary requires changing this application's loopback-only listener.
    pub fn rateLimit(self: *Store, io: std.Io, client: []const u8) !bool {
        const at = now(io);
        const client_hash = tokenHash(client);
        try self.cleanup(at);
        var allowed = true;
        inline for (.{ .{ "global", @as(i64, 240) }, .{ &client_hash, @as(i64, 40) } }) |limit| {
            try self.exec("INSERT INTO rate_limits VALUES (?,?,1) ON CONFLICT(key) DO UPDATE SET window=CASE WHEN window<=? THEN excluded.window ELSE window END, attempts=CASE WHEN window<=? THEN 1 ELSE attempts+1 END", .{ limit[0], at, at - 60, at - 60 });
            if (try self.count("SELECT attempts FROM rate_limits WHERE key=?", .{limit[0]}) > limit[1]) allowed = false;
        }
        return allowed;
    }

    pub fn backup(self: *Store, allocator: std.mem.Allocator, io: std.Io, path: []const u8) !void {
        if (!std.fs.path.isAbsolute(path)) return error.BackupPathMustBeAbsolute;
        const file = try std.Io.Dir.cwd().createFile(io, path, .{ .exclusive = true, .permissions = .fromMode(0o600) });
        file.close(io);
        var destination = try sqlite.Database.open(allocator, path, .read_write);
        defer destination.deinit();
        const operation = sqlite.raw.sqlite3_backup_init(destination.handle, "main", self.db.handle, "main") orelse return error.AuthBackupFailed;
        const step = sqlite.raw.sqlite3_backup_step(operation, -1);
        const finish = sqlite.raw.sqlite3_backup_finish(operation);
        if (step != sqlite.raw.SQLITE_DONE or finish != sqlite.raw.SQLITE_OK) return error.AuthBackupFailed;
        var integrity = try destination.prepare("PRAGMA integrity_check");
        defer integrity.deinit();
        if (try integrity.step() != .row or !std.mem.eql(u8, integrity.columnText(0), "ok")) return error.AuthBackupFailed;
    }

    pub fn reset(self: *Store) !void {
        try self.db.exec("BEGIN IMMEDIATE");
        errdefer self.db.exec("ROLLBACK") catch {};
        for ([_][]const u8{ "sessions", "passkeys", "challenges", "bootstrap", "rate_limits" }) |table| {
            // All table names are fixed above, never request input.
            var buffer: [64]u8 = undefined;
            try self.db.exec(try std.fmt.bufPrint(&buffer, "DELETE FROM {s}", .{table}));
        }
        try self.db.exec("COMMIT");
    }
};

pub fn now(io: std.Io) i64 {
    return std.Io.Timestamp.now(io, .real).toSeconds();
}

pub fn randomToken(io: std.Io) [43]u8 {
    var bytes: [32]u8 = undefined;
    io.random(&bytes);
    var encoded: [43]u8 = undefined;
    _ = std.base64.url_safe_no_pad.Encoder.encode(&encoded, &bytes);
    return encoded;
}

pub fn tokenHash(token: []const u8) [64]u8 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(token, &digest, .{});
    return std.fmt.bytesToHex(digest, .lower);
}

pub fn validToken(value: []const u8) bool {
    if (value.len != 43) return false;
    for (value) |byte| if (!(std.ascii.isAlphanumeric(byte) or byte == '-' or byte == '_')) return false;
    return true;
}
