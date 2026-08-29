const std = @import("std");

pub const maximum_source_bytes = 64 * 1024;
pub const maximum_transported_source_bytes = maximum_source_bytes * 2;
pub const maximum_files = 128;
pub const maximum_directory_entries = 512;
pub const maximum_filename_bytes = 80;

const scratch_file_name = ".dbui-scratch.sql";

pub const Revision = [64]u8;

pub const NewlineStyle = enum {
    lf,
    crlf,
};

pub const Item = struct {
    name: []const u8,
    modified_ns: i96,
};

pub const Listing = struct {
    items: []const Item,
    incompatible_entries: usize,
    scratch_modified_ns: ?i96,

    pub fn latest(self: Listing) ?Latest {
        var result: ?Latest = null;
        var modified_ns: i96 = 0;
        if (self.scratch_modified_ns) |value| {
            result = .scratch;
            modified_ns = value;
        }
        for (self.items) |item| {
            if (result == null or item.modified_ns > modified_ns) {
                result = .{ .file = item.name };
                modified_ns = item.modified_ns;
            }
        }
        return result;
    }
};

pub const Latest = union(enum) {
    scratch,
    file: []const u8,
};

pub const Issue = enum {
    too_large,
    invalid_utf8,
    contains_nul,
    unsupported_line_endings,

    pub fn message(self: Issue) []const u8 {
        return switch (self) {
            .too_large => "This file exceeds the 64 KiB editor limit.",
            .invalid_utf8 => "This file is not valid UTF-8.",
            .contains_nul => "This file contains a NUL byte.",
            .unsupported_line_endings => "This file uses mixed or bare-CR line endings.",
        };
    }
};

pub const DocumentKind = enum { scratch, file };

pub const Document = struct {
    kind: DocumentKind = .file,
    name: []const u8 = "",
    source: []const u8 = "",
    revision: ?Revision = null,
    newline_style: NewlineStyle = .lf,
    issue: ?Issue = null,

    pub fn editable(self: Document) bool {
        return self.issue == null and (self.kind == .scratch or self.revision != null);
    }
};

pub const SaveResult = struct {
    revision: Revision,
    changed: bool,
};

const RawFile = struct {
    bytes: []const u8,
    revision: Revision,
    permissions: std.Io.File.Permissions,
};

const Normalized = struct {
    source: []const u8,
    style: NewlineStyle,
};

pub fn validateWorkspace(io: std.Io, path: []const u8) !void {
    var directory = try std.Io.Dir.openDirAbsolute(io, path, .{
        .iterate = true,
        .follow_symlinks = false,
    });
    defer directory.close(io);

    var random: [8]u8 = undefined;
    var attempts: usize = 0;
    while (attempts < 4) : (attempts += 1) {
        io.random(&random);
        const suffix = std.fmt.bytesToHex(random, .lower);
        var name_buffer: [40]u8 = undefined;
        const name = std.fmt.bufPrint(&name_buffer, ".dbui-check-{s}.tmp", .{&suffix}) catch unreachable;
        var probe = directory.createFile(io, name, .{
            .exclusive = true,
            .permissions = @fromBackingInt(@intCast(0o600)),
            .resolve_beneath = true,
        }) catch |err| switch (err) {
            error.PathAlreadyExists => continue,
            else => |actual| return actual,
        };
        probe.close(io);
        directory.deleteFile(io, name) catch return error.WorkspaceProbeCleanupFailed;
        return;
    }
    return error.WorkspaceProbeCollision;
}

pub fn list(
    allocator: std.mem.Allocator,
    io: std.Io,
    workspace_path: []const u8,
) !Listing {
    var directory = try openWorkspace(io, workspace_path);
    defer directory.close(io);

    var items: std.ArrayList(Item) = .empty;
    var incompatible_entries: usize = 0;
    var directory_entries: usize = 0;
    var scratch_modified_ns: ?i96 = null;
    var iterator = directory.iterate();
    while (try iterator.next(io)) |entry| {
        directory_entries += 1;
        if (directory_entries > maximum_directory_entries) return error.TooManyWorkspaceEntries;
        if (std.mem.eql(u8, entry.name, scratch_file_name)) {
            if (entry.kind == .file) {
                const file_stat = directory.statFile(io, entry.name, .{ .follow_symlinks = false }) catch |err| switch (err) {
                    error.FileNotFound => continue,
                    else => |actual| return actual,
                };
                if (file_stat.kind == .file) scratch_modified_ns = file_stat.mtime.nanoseconds;
            }
            continue;
        }
        if (!std.mem.endsWith(u8, entry.name, ".sql")) continue;
        if (entry.kind != .file) {
            incompatible_entries += 1;
            continue;
        }
        validateFilename(entry.name) catch {
            incompatible_entries += 1;
            continue;
        };
        const file_stat = directory.statFile(io, entry.name, .{ .follow_symlinks = false }) catch |err| switch (err) {
            error.FileNotFound => continue,
            else => |actual| return actual,
        };
        if (file_stat.kind != .file) {
            incompatible_entries += 1;
            continue;
        }
        if (items.items.len == maximum_files) return error.TooManyQueryFiles;
        try items.append(allocator, .{
            .name = try allocator.dupe(u8, entry.name),
            .modified_ns = file_stat.mtime.nanoseconds,
        });
    }
    std.mem.sort(Item, items.items, {}, lessThanItem);
    return .{
        .items = try items.toOwnedSlice(allocator),
        .incompatible_entries = incompatible_entries,
        .scratch_modified_ns = scratch_modified_ns,
    };
}

pub fn load(
    allocator: std.mem.Allocator,
    io: std.Io,
    workspace_path: []const u8,
    name: []const u8,
) !Document {
    try validateFilename(name);
    return loadLeaf(allocator, io, workspace_path, name, .file);
}

pub fn loadScratch(
    allocator: std.mem.Allocator,
    io: std.Io,
    workspace_path: []const u8,
) !Document {
    return loadLeaf(allocator, io, workspace_path, scratch_file_name, .scratch) catch |err| switch (err) {
        error.FileNotFound => .{ .kind = .scratch },
        else => |actual| return actual,
    };
}

fn loadLeaf(
    allocator: std.mem.Allocator,
    io: std.Io,
    workspace_path: []const u8,
    name: []const u8,
    kind: DocumentKind,
) !Document {
    var directory = try openWorkspace(io, workspace_path);
    defer directory.close(io);

    const display_name = if (kind == .scratch) "" else name;
    const raw = readRaw(allocator, io, directory, name) catch |err| switch (err) {
        error.FileTooLarge => return .{ .kind = kind, .name = try allocator.dupe(u8, display_name), .issue = .too_large },
        else => |actual| return actual,
    };
    const normalized = normalize(allocator, raw.bytes) catch |err| switch (err) {
        error.InvalidUtf8 => return .{ .kind = kind, .name = try allocator.dupe(u8, display_name), .revision = raw.revision, .issue = .invalid_utf8 },
        error.ContainsNul => return .{ .kind = kind, .name = try allocator.dupe(u8, display_name), .revision = raw.revision, .issue = .contains_nul },
        error.UnsupportedLineEndings => return .{ .kind = kind, .name = try allocator.dupe(u8, display_name), .revision = raw.revision, .issue = .unsupported_line_endings },
        else => |actual| return actual,
    };
    return .{
        .kind = kind,
        .name = try allocator.dupe(u8, display_name),
        .source = normalized.source,
        .revision = raw.revision,
        .newline_style = normalized.style,
    };
}

pub fn create(
    allocator: std.mem.Allocator,
    io: std.Io,
    workspace_path: []const u8,
    name: []const u8,
    source: []const u8,
) !Document {
    try validateFilename(name);
    return createLeaf(allocator, io, workspace_path, name, source, .file);
}

fn createLeaf(
    allocator: std.mem.Allocator,
    io: std.Io,
    workspace_path: []const u8,
    name: []const u8,
    source: []const u8,
    kind: DocumentKind,
) !Document {
    const canonical_source = try canonicalizeEditorSource(allocator, source);
    var directory = try openWorkspace(io, workspace_path);
    defer directory.close(io);

    var atomic = try directory.createFileAtomic(io, name, .{
        .permissions = @fromBackingInt(@intCast(0o600)),
    });
    defer atomic.deinit(io);
    try atomic.file.writeStreamingAll(io, canonical_source);
    try atomic.file.sync(io);
    try atomic.link(io);
    try syncDirectory(io, directory);

    return .{
        .kind = kind,
        .name = if (kind == .scratch) "" else try allocator.dupe(u8, name),
        .source = try allocator.dupe(u8, canonical_source),
        .revision = hash(canonical_source),
        .newline_style = .lf,
    };
}

pub fn save(
    allocator: std.mem.Allocator,
    io: std.Io,
    workspace_path: []const u8,
    name: []const u8,
    base_revision: []const u8,
    source: []const u8,
) !SaveResult {
    try validateFilename(name);
    try validateRevision(base_revision);
    return saveLeaf(allocator, io, workspace_path, name, base_revision, source);
}

pub fn saveScratch(
    allocator: std.mem.Allocator,
    io: std.Io,
    workspace_path: []const u8,
    base_revision: []const u8,
    source: []const u8,
) !SaveResult {
    if (base_revision.len == 0) {
        const document = try createLeaf(allocator, io, workspace_path, scratch_file_name, source, .scratch);
        return .{ .revision = document.revision.?, .changed = true };
    }
    try validateRevision(base_revision);
    return saveLeaf(allocator, io, workspace_path, scratch_file_name, base_revision, source);
}

fn saveLeaf(
    allocator: std.mem.Allocator,
    io: std.Io,
    workspace_path: []const u8,
    name: []const u8,
    base_revision: []const u8,
    source: []const u8,
) !SaveResult {
    const canonical_source = try canonicalizeEditorSource(allocator, source);
    var directory = try openWorkspace(io, workspace_path);
    defer directory.close(io);

    const original = try readRaw(allocator, io, directory, name);
    if (!std.mem.eql(u8, &original.revision, base_revision)) return error.FileConflict;
    const normalized = normalize(allocator, original.bytes) catch return error.FileNotEditable;
    const encoded = try encode(allocator, canonical_source, normalized.style);
    const next_revision = hash(encoded);
    if (std.mem.eql(u8, &original.revision, &next_revision)) {
        return .{ .revision = next_revision, .changed = false };
    }

    var atomic = try directory.createFileAtomic(io, name, .{
        .permissions = ordinaryPermissions(original.permissions),
        .replace = true,
    });
    defer atomic.deinit(io);
    try atomic.file.setPermissions(io, ordinaryPermissions(original.permissions));
    try atomic.file.writeStreamingAll(io, encoded);
    try atomic.file.sync(io);

    const current = try readRaw(allocator, io, directory, name);
    if (!std.mem.eql(u8, &current.revision, base_revision)) return error.FileConflict;
    try atomic.replace(io);
    try syncDirectory(io, directory);
    return .{ .revision = next_revision, .changed = true };
}

/// HTML form submission transports textarea line breaks as CRLF even though
/// the browser editor value uses LF. Keep that transport detail out of query
/// execution and file storage while continuing to reject ambiguous input.
pub fn canonicalizeEditorSource(allocator: std.mem.Allocator, source: []const u8) ![]const u8 {
    if (source.len > maximum_transported_source_bytes) return error.SourceTooLarge;
    if (std.mem.indexOfScalar(u8, source, '\r') == null) {
        try validateEditorSource(source);
        return source;
    }
    const normalized = try normalize(allocator, source);
    try validateEditorSource(normalized.source);
    return normalized.source;
}

pub fn rename(
    allocator: std.mem.Allocator,
    io: std.Io,
    workspace_path: []const u8,
    old_name: []const u8,
    new_name: []const u8,
    base_revision: []const u8,
) !void {
    try validateFilename(old_name);
    try validateFilename(new_name);
    try validateRevision(base_revision);
    var directory = try openWorkspace(io, workspace_path);
    defer directory.close(io);

    const current = try readRaw(allocator, io, directory, old_name);
    if (!std.mem.eql(u8, &current.revision, base_revision)) return error.FileConflict;
    if (std.mem.eql(u8, old_name, new_name)) return;
    try directory.renamePreserve(old_name, directory, new_name, io);
    try syncDirectory(io, directory);
}

pub fn delete(
    allocator: std.mem.Allocator,
    io: std.Io,
    workspace_path: []const u8,
    name: []const u8,
    base_revision: []const u8,
) !void {
    try validateFilename(name);
    try validateRevision(base_revision);
    var directory = try openWorkspace(io, workspace_path);
    defer directory.close(io);

    const current = try readRaw(allocator, io, directory, name);
    if (!std.mem.eql(u8, &current.revision, base_revision)) return error.FileConflict;
    try directory.deleteFile(io, name);
    try syncDirectory(io, directory);
}

pub fn validateFilename(name: []const u8) !void {
    if (name.len == 0 or name.len > maximum_filename_bytes) return error.InvalidFilename;
    if (!std.unicode.utf8ValidateSlice(name)) return error.InvalidFilename;
    if (!std.mem.endsWith(u8, name, ".sql")) return error.InvalidFilename;
    if (name[0] == '.') return error.InvalidFilename;
    for (name) |byte| {
        if (byte == '/' or byte == '\\' or byte == 0 or byte < 0x20 or byte == 0x7f) return error.InvalidFilename;
    }
}

fn validateRevision(value: []const u8) !void {
    if (value.len != 64) return error.InvalidRevision;
    for (value) |byte| if (!std.ascii.isHex(byte)) return error.InvalidRevision;
}

fn validateEditorSource(source: []const u8) !void {
    if (source.len > maximum_source_bytes) return error.SourceTooLarge;
    if (!std.unicode.utf8ValidateSlice(source)) return error.InvalidUtf8;
    if (std.mem.indexOfScalar(u8, source, 0) != null) return error.ContainsNul;
    if (std.mem.indexOfScalar(u8, source, '\r') != null) return error.UnsupportedLineEndings;
}

fn openWorkspace(io: std.Io, path: []const u8) !std.Io.Dir {
    return std.Io.Dir.openDirAbsolute(io, path, .{
        .iterate = true,
        .follow_symlinks = false,
    });
}

fn readRaw(
    allocator: std.mem.Allocator,
    io: std.Io,
    directory: std.Io.Dir,
    name: []const u8,
) !RawFile {
    var file = try directory.openFile(io, name, .{
        .allow_directory = false,
        .follow_symlinks = false,
        .resolve_beneath = true,
    });
    defer file.close(io);
    const before = try file.stat(io);
    if (before.kind != .file) return error.FileNotRegular;
    if (before.size > maximum_source_bytes) return error.FileTooLarge;
    const bytes = try allocator.alloc(u8, @intCast(before.size));
    const read = try file.readPositionalAll(io, bytes, 0);
    if (read != bytes.len) return error.FileChangedDuringRead;
    const after = try file.stat(io);
    if (after.size != before.size or after.inode != before.inode or after.mtime.nanoseconds != before.mtime.nanoseconds) {
        return error.FileChangedDuringRead;
    }
    return .{
        .bytes = bytes,
        .revision = hash(bytes),
        .permissions = before.permissions,
    };
}

fn normalize(allocator: std.mem.Allocator, raw: []const u8) !Normalized {
    if (!std.unicode.utf8ValidateSlice(raw)) return error.InvalidUtf8;
    if (std.mem.indexOfScalar(u8, raw, 0) != null) return error.ContainsNul;

    var saw_lf = false;
    var saw_crlf = false;
    var cr_count: usize = 0;
    var index: usize = 0;
    while (index < raw.len) {
        switch (raw[index]) {
            '\r' => {
                if (index + 1 >= raw.len or raw[index + 1] != '\n') return error.UnsupportedLineEndings;
                saw_crlf = true;
                cr_count += 1;
                index += 2;
            },
            '\n' => {
                saw_lf = true;
                index += 1;
            },
            else => index += 1,
        }
    }
    if (saw_lf and saw_crlf) return error.UnsupportedLineEndings;
    if (!saw_crlf) return .{ .source = try allocator.dupe(u8, raw), .style = .lf };

    const source = try allocator.alloc(u8, raw.len - cr_count);
    var output: usize = 0;
    index = 0;
    while (index < raw.len) {
        if (raw[index] == '\r') {
            source[output] = '\n';
            output += 1;
            index += 2;
        } else {
            source[output] = raw[index];
            output += 1;
            index += 1;
        }
    }
    return .{ .source = source, .style = .crlf };
}

fn encode(allocator: std.mem.Allocator, source: []const u8, style: NewlineStyle) ![]const u8 {
    try validateEditorSource(source);
    if (style == .lf) return allocator.dupe(u8, source);
    const newline_count = std.mem.count(u8, source, "\n");
    const encoded_len = std.math.add(usize, source.len, newline_count) catch return error.SourceTooLarge;
    if (encoded_len > maximum_source_bytes) return error.SourceTooLarge;
    const encoded = try allocator.alloc(u8, encoded_len);
    var output: usize = 0;
    for (source) |byte| {
        if (byte == '\n') {
            encoded[output] = '\r';
            output += 1;
        }
        encoded[output] = byte;
        output += 1;
    }
    return encoded;
}

fn hash(bytes: []const u8) Revision {
    var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
    return std.fmt.bytesToHex(digest, .lower);
}

fn syncDirectory(io: std.Io, directory: std.Io.Dir) !void {
    const file: std.Io.File = .{
        .handle = directory.handle,
        .flags = .{ .nonblocking = false },
    };
    try file.sync(io);
}

fn ordinaryPermissions(permissions: std.Io.File.Permissions) std.Io.File.Permissions {
    return @fromBackingInt(@backingInt(permissions) & 0o777);
}

fn lessThanItem(_: void, left: Item, right: Item) bool {
    const order = std.ascii.orderIgnoreCase(left.name, right.name);
    return if (order == .eq) std.mem.order(u8, left.name, right.name) == .lt else order == .lt;
}

test "query files preserve CRLF and reject stale revisions" {
    var temporary = std.testing.tmpDir(.{ .iterate = true });
    defer temporary.cleanup();
    try temporary.dir.writeFile(std.testing.io, .{
        .sub_path = "workflow.sql",
        .data = "select 1;\r\nselect 2;\r\n",
    });
    try temporary.dir.setFilePermissions(std.testing.io, "workflow.sql", @fromBackingInt(@intCast(0o640)), .{});
    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path_length = try temporary.dir.realPath(std.testing.io, &path_buffer);
    const path = path_buffer[0..path_length];

    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();
    const document = try load(allocator, std.testing.io, path, "workflow.sql");
    try std.testing.expect(document.editable());
    try std.testing.expectEqual(NewlineStyle.crlf, document.newline_style);
    try std.testing.expectEqualStrings("select 1;\nselect 2;\n", document.source);

    const result = try save(allocator, std.testing.io, path, document.name, &document.revision.?, "select 1;\nselect 3;\n");
    try std.testing.expect(result.changed);
    const raw = try temporary.dir.readFileAlloc(std.testing.io, "workflow.sql", allocator, .limited(maximum_source_bytes + 1));
    try std.testing.expectEqualStrings("select 1;\r\nselect 3;\r\n", raw);
    const saved_stat = try temporary.dir.statFile(std.testing.io, "workflow.sql", .{});
    try std.testing.expectEqual(@as(u32, 0o640), @as(u32, @intCast(@backingInt(saved_stat.permissions) & 0o777)));
    try std.testing.expectError(error.FileConflict, save(allocator, std.testing.io, path, document.name, &document.revision.?, "select 4;\n"));
}

test "submitted editor source canonicalizes browser CRLF and rejects ambiguous endings" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();

    const lf = "select 1;\nselect 2;\n";
    try std.testing.expectEqualStrings(lf, try canonicalizeEditorSource(allocator, lf));
    try std.testing.expectEqualStrings(lf, try canonicalizeEditorSource(allocator, "select 1;\r\nselect 2;\r\n"));
    try std.testing.expectError(error.UnsupportedLineEndings, canonicalizeEditorSource(allocator, "select 1;\rselect 2;"));
    try std.testing.expectError(error.UnsupportedLineEndings, canonicalizeEditorSource(allocator, "select 1;\r\nselect 2;\n"));

    const maximum_transport = try allocator.alloc(u8, maximum_transported_source_bytes);
    for (0..maximum_source_bytes) |index| {
        maximum_transport[index * 2] = '\r';
        maximum_transport[index * 2 + 1] = '\n';
    }
    const maximum_canonical = try canonicalizeEditorSource(allocator, maximum_transport);
    try std.testing.expectEqual(maximum_source_bytes, maximum_canonical.len);
    try std.testing.expect(std.mem.allEqual(u8, maximum_canonical, '\n'));

    const oversized_transport = try allocator.alloc(u8, maximum_transported_source_bytes + 1);
    @memset(oversized_transport, '\r');
    try std.testing.expectError(error.SourceTooLarge, canonicalizeEditorSource(allocator, oversized_transport));
}

test "query filenames remain direct SQL leaves" {
    try validateFilename("daily-health.sql");
    try validateFilename("odd name ☃.sql");
    try std.testing.expectError(error.InvalidFilename, validateFilename("../escape.sql"));
    try std.testing.expectError(error.InvalidFilename, validateFilename("nested/file.sql"));
    try std.testing.expectError(error.InvalidFilename, validateFilename(".dbui-save.sql"));
    try std.testing.expectError(error.InvalidFilename, validateFilename("notes.txt"));
}
