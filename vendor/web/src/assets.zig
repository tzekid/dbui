//! Explicit embedded and disk-backed asset delivery.

const std = @import("std");

pub const Encoding = enum {
    identity,
    gzip,
    brotli,

    pub fn contentEncoding(encoding: Encoding) ?[]const u8 {
        return switch (encoding) {
            .identity => null,
            .gzip => "gzip",
            .brotli => "br",
        };
    }

    pub fn fileSuffix(encoding: Encoding) []const u8 {
        return switch (encoding) {
            .identity => "",
            .gzip => ".gz",
            .brotli => ".br",
        };
    }
};

pub const Embedded = struct {
    path: []const u8,
    data: []const u8,
    content_type: ?[]const u8 = null,
    encoding: Encoding = .identity,
    etag: ?[]const u8 = null,
};

pub const Registry = struct {
    assets: []const Embedded,

    pub fn find(registry: Registry, path: []const u8, encoding: Encoding) ?Embedded {
        for (registry.assets) |asset| {
            if (asset.encoding == encoding and std.mem.eql(u8, asset.path, path)) return asset;
        }
        return null;
    }

    pub fn best(registry: Registry, path: []const u8, accept_encoding: []const u8) ?Embedded {
        const preferred = selectEncoding(accept_encoding);
        if (preferred != .identity) {
            if (registry.find(path, preferred)) |asset| return asset;
        }
        return registry.find(path, .identity);
    }
};

/// Decode and validate an origin-form request path, returning a relative disk
/// path in caller-owned storage. Query strings are ignored.
pub fn relativePath(destination: []u8, request_target: []const u8) ![]const u8 {
    const end = std.mem.indexOfAny(u8, request_target, "?#") orelse request_target.len;
    const raw = request_target[0..end];
    if (raw.len == 0 or raw[0] != '/' or raw.len - 1 > destination.len) return error.InvalidPath;
    var source: usize = 1;
    var output: usize = 0;
    while (source < raw.len) {
        var byte = raw[source];
        if (byte == '%') {
            if (source + 2 >= raw.len) return error.InvalidPercentEncoding;
            const high = std.fmt.charToDigit(raw[source + 1], 16) catch return error.InvalidPercentEncoding;
            const low = std.fmt.charToDigit(raw[source + 2], 16) catch return error.InvalidPercentEncoding;
            byte = @intCast(high * 16 + low);
            source += 3;
        } else {
            source += 1;
        }
        if (byte == 0 or byte == '\\' or byte == '\r' or byte == '\n') return error.InvalidPath;
        if (output == destination.len) return error.NoSpaceLeft;
        destination[output] = byte;
        output += 1;
    }
    const path = destination[0..output];
    if (!validSegments(path)) return error.InvalidPath;
    return path;
}

pub fn diskPath(
    destination: []u8,
    root: []const u8,
    request_target: []const u8,
    encoding: Encoding,
) ![]const u8 {
    var relative_storage: [4096]u8 = undefined;
    const relative = try relativePath(&relative_storage, request_target);
    return std.fmt.bufPrint(destination, "{s}{s}{s}{s}", .{
        root,
        if (root.len > 0 and root[root.len - 1] == '/') "" else "/",
        relative,
        encoding.fileSuffix(),
    });
}

pub fn selectEncoding(accept_encoding: []const u8) Encoding {
    if (tokenAllowed(accept_encoding, "br")) return .brotli;
    if (tokenAllowed(accept_encoding, "gzip")) return .gzip;
    return .identity;
}

pub fn contentType(path: []const u8) []const u8 {
    const uncompressed = if (std.mem.endsWith(u8, path, ".br")) path[0 .. path.len - 3] else if (std.mem.endsWith(u8, path, ".gz")) path[0 .. path.len - 3] else path;
    const extension = std.fs.path.extension(uncompressed);
    const map = .{
        .{ ".html", "text/html; charset=utf-8" },
        .{ ".css", "text/css; charset=utf-8" },
        .{ ".js", "text/javascript; charset=utf-8" },
        .{ ".mjs", "text/javascript; charset=utf-8" },
        .{ ".json", "application/json; charset=utf-8" },
        .{ ".md", "text/markdown; charset=utf-8" },
        .{ ".svg", "image/svg+xml" },
        .{ ".png", "image/png" },
        .{ ".jpg", "image/jpeg" },
        .{ ".jpeg", "image/jpeg" },
        .{ ".gif", "image/gif" },
        .{ ".webp", "image/webp" },
        .{ ".avif", "image/avif" },
        .{ ".ico", "image/x-icon" },
        .{ ".woff", "font/woff" },
        .{ ".woff2", "font/woff2" },
        .{ ".txt", "text/plain; charset=utf-8" },
        .{ ".xml", "application/xml; charset=utf-8" },
        .{ ".pdf", "application/pdf" },
        .{ ".webmanifest", "application/manifest+json" },
    };
    inline for (map) |entry| {
        if (std.ascii.eqlIgnoreCase(extension, entry[0])) return entry[1];
    }
    return "application/octet-stream";
}

fn validSegments(path: []const u8) bool {
    if (path.len == 0) return true;
    if (path[0] == '/' or std.mem.endsWith(u8, path, "/") or std.mem.indexOf(u8, path, "//") != null) return false;
    var segments = std.mem.splitScalar(u8, path, '/');
    while (segments.next()) |segment| {
        if (std.mem.eql(u8, segment, ".") or std.mem.eql(u8, segment, "..")) return false;
    }
    return true;
}

fn tokenAllowed(raw: []const u8, wanted: []const u8) bool {
    var explicit: ?bool = null;
    var wildcard: ?bool = null;
    var values = std.mem.splitScalar(u8, raw, ',');
    while (values.next()) |raw_value| {
        const value = std.mem.trim(u8, raw_value, " \t");
        const semicolon = std.mem.indexOfScalar(u8, value, ';');
        const token = std.mem.trim(u8, value[0 .. semicolon orelse value.len], " \t");
        const allowed = if (semicolon) |index| qualityAllows(value[index + 1 ..]) else true;
        if (std.ascii.eqlIgnoreCase(token, wanted)) {
            explicit = allowed;
        } else if (std.mem.eql(u8, token, "*")) {
            wildcard = allowed;
        }
    }
    return explicit orelse wildcard orelse false;
}

fn qualityAllows(parameters: []const u8) bool {
    var iterator = std.mem.splitScalar(u8, parameters, ';');
    while (iterator.next()) |raw_parameter| {
        const parameter = std.mem.trim(u8, raw_parameter, " \t");
        if (parameter.len < 2 or (parameter[0] != 'q' and parameter[0] != 'Q') or parameter[1] != '=') continue;
        const value = std.mem.trim(u8, parameter[2..], " \t");
        return !(std.mem.eql(u8, value, "0") or std.mem.eql(u8, value, "0.0") or std.mem.eql(u8, value, "0.00") or std.mem.eql(u8, value, "0.000"));
    }
    return true;
}

test "asset paths decode safely without traversal or separator ambiguity" {
    var storage: [256]u8 = undefined;
    try std.testing.expectEqualStrings("assets/app.js", try relativePath(&storage, "/assets/app.js?v=1"));
    try std.testing.expectEqualStrings("files/hello world.txt", try relativePath(&storage, "/files/hello%20world.txt"));
    try std.testing.expectError(error.InvalidPath, relativePath(&storage, "/../secret"));
    try std.testing.expectError(error.InvalidPath, relativePath(&storage, "/%2e%2e/secret"));
    try std.testing.expectError(error.InvalidPath, relativePath(&storage, "/assets//app.js"));
    try std.testing.expectError(error.InvalidPath, relativePath(&storage, "/assets%5csecret"));
}

test "content encoding respects explicit q zero and available variants" {
    const assets = [_]Embedded{
        .{ .path = "/app.css", .data = "plain" },
        .{ .path = "/app.css", .data = "compressed", .encoding = .brotli },
    };
    const registry = Registry{ .assets = &assets };
    try std.testing.expectEqual(Encoding.brotli, registry.best("/app.css", "gzip, br").?.encoding);
    try std.testing.expectEqual(Encoding.identity, registry.best("/app.css", "br;q=0, gzip").?.encoding);
    try std.testing.expect(registry.best("/missing.css", "br") == null);
}

test "MIME detection ignores precompression suffixes" {
    try std.testing.expectEqualStrings("text/css; charset=utf-8", contentType("/assets/app.css.br"));
    try std.testing.expectEqualStrings("application/manifest+json", contentType("/site.webmanifest.gz"));
    try std.testing.expectEqualStrings("text/markdown; charset=utf-8", contentType("/article.md"));
    try std.testing.expectEqualStrings("font/woff", contentType("/font.woff"));
    try std.testing.expectEqualStrings("application/octet-stream", contentType("/data.bin"));
}

test "disk paths append selected precompression suffix" {
    var storage: [256]u8 = undefined;
    try std.testing.expectEqualStrings("/srv/site/assets/app.js.br", try diskPath(&storage, "/srv/site", "/assets/app.js", .brotli));
}
