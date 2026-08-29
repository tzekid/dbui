const std = @import("std");
const sqlite = @import("sqlite.zig");
const query_files = @import("query_files.zig");

pub const DatabaseConfig = struct {
    id: []const u8,
    label: []const u8,
    path: []const u8,
    mode: sqlite.AccessMode,
    queries_path: ?[]const u8 = null,

    pub fn basename(self: DatabaseConfig) []const u8 {
        return std.fs.path.basename(self.path);
    }
};

pub const Listen = struct {
    host: []const u8,
    port: u16,
};

pub const Registry = struct {
    listen: Listen,
    databases: []const DatabaseConfig,

    pub fn find(self: *const Registry, id: []const u8) ?*const DatabaseConfig {
        for (self.databases) |*database| {
            if (std.mem.eql(u8, database.id, id)) return database;
        }
        return null;
    }

    pub fn load(allocator: std.mem.Allocator, io: std.Io, path: []const u8) !Registry {
        const encoded = std.Io.Dir.cwd().readFileAlloc(
            io,
            path,
            allocator,
            .limited(1024 * 1024),
        ) catch |err| {
            std.log.err("configuration read failed: {s}", .{@errorName(err)});
            return error.InvalidConfiguration;
        };
        const raw = std.json.parseFromSliceLeaky(
            RawConfig,
            allocator,
            encoded,
            .{ .ignore_unknown_fields = false },
        ) catch |err| {
            std.log.err("configuration JSON is invalid: {s}", .{@errorName(err)});
            return error.InvalidConfiguration;
        };

        const listen = parseListen(raw.listen) catch |err| {
            std.log.err("configuration listen is invalid: {s}", .{@errorName(err)});
            return error.InvalidConfiguration;
        };
        if (raw.databases.len == 0) {
            std.log.err("configuration must declare at least one database", .{});
            return error.InvalidConfiguration;
        }

        const databases = try allocator.alloc(DatabaseConfig, raw.databases.len);
        for (raw.databases, 0..) |candidate, index| {
            databases[index] = validateDatabase(allocator, io, candidate, databases[0..index]) catch |err| {
                std.log.err("configuration database={s}: {s}", .{ candidate.id, @errorName(err) });
                return error.InvalidConfiguration;
            };
        }
        return .{ .listen = listen, .databases = databases };
    }
};

const RawConfig = struct {
    listen: []const u8,
    databases: []const RawDatabase,
};

const RawDatabase = struct {
    id: []const u8,
    label: []const u8,
    path: []const u8,
    mode: []const u8,
    queries_path: ?[]const u8 = null,
};

fn parseListen(value: []const u8) !Listen {
    const separator = std.mem.lastIndexOfScalar(u8, value, ':') orelse return error.InvalidAddress;
    const host = value[0..separator];
    if (!(std.mem.eql(u8, host, "127.0.0.1") or std.mem.eql(u8, host, "::1"))) {
        return error.ListenerMustBeLoopback;
    }
    const port = std.fmt.parseInt(u16, value[separator + 1 ..], 10) catch return error.InvalidPort;
    if (port == 0) return error.InvalidPort;
    return .{ .host = host, .port = port };
}

fn validateDatabase(
    allocator: std.mem.Allocator,
    io: std.Io,
    candidate: RawDatabase,
    previous: []const DatabaseConfig,
) !DatabaseConfig {
    if (!validId(candidate.id)) return error.InvalidDatabaseId;
    if (candidate.label.len == 0 or candidate.label.len > 80 or !std.unicode.utf8ValidateSlice(candidate.label)) {
        return error.InvalidDatabaseLabel;
    }
    if (!std.fs.path.isAbsolute(candidate.path)) return error.DatabasePathMustBeAbsolute;
    const mode: sqlite.AccessMode = if (std.mem.eql(u8, candidate.mode, "read-only"))
        .read_only
    else if (std.mem.eql(u8, candidate.mode, "read-write"))
        .read_write
    else
        return error.InvalidDatabaseMode;

    for (previous) |configured| {
        if (std.mem.eql(u8, configured.id, candidate.id)) return error.DuplicateDatabaseId;
    }

    const canonical_z = try std.Io.Dir.realPathFileAbsoluteAlloc(io, candidate.path, allocator);
    const canonical: []const u8 = canonical_z;
    const stat = try std.Io.Dir.cwd().statFile(io, canonical, .{ .follow_symlinks = true });
    if (stat.kind != .file) return error.DatabasePathNotRegularFile;
    for (previous) |configured| {
        if (std.mem.eql(u8, configured.path, canonical)) return error.DuplicateDatabasePath;
    }

    var database = try sqlite.Database.open(allocator, canonical, mode);
    defer database.deinit();
    var schema_check = try database.prepare("SELECT name FROM main.sqlite_schema LIMIT 1");
    defer schema_check.deinit();
    _ = try schema_check.step();

    const queries_path: ?[]const u8 = if (candidate.queries_path) |workspace| block: {
        if (!std.fs.path.isAbsolute(workspace)) return error.QueryPathMustBeAbsolute;
        const workspace_z = try std.Io.Dir.realPathFileAbsoluteAlloc(io, workspace, allocator);
        const canonical_workspace: []const u8 = workspace_z;
        const workspace_stat = try std.Io.Dir.cwd().statFile(io, canonical_workspace, .{ .follow_symlinks = true });
        if (workspace_stat.kind != .directory) return error.QueryPathNotDirectory;
        for (previous) |configured| {
            if (configured.queries_path) |existing| {
                if (std.mem.eql(u8, existing, canonical_workspace)) return error.DuplicateQueryPath;
            }
        }
        try query_files.validateWorkspace(io, canonical_workspace);
        break :block canonical_workspace;
    } else null;

    return .{
        .id = candidate.id,
        .label = candidate.label,
        .path = canonical,
        .mode = mode,
        .queries_path = queries_path,
    };
}

fn validId(value: []const u8) bool {
    if (value.len == 0 or value.len > 64) return false;
    if (!std.ascii.isLower(value[0]) and !std.ascii.isDigit(value[0])) return false;
    for (value[1..]) |byte| {
        if (!(std.ascii.isLower(byte) or std.ascii.isDigit(byte) or byte == '_' or byte == '-')) return false;
    }
    return true;
}

test "database IDs are deliberately narrow" {
    try std.testing.expect(validId("analytico"));
    try std.testing.expect(validId("db-2_archive"));
    try std.testing.expect(!validId("Analytico"));
    try std.testing.expect(!validId("../database"));
}
