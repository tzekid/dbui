//! Explicit HTTP response helpers.

const std = @import("std");

pub const max_headers = 32;

pub const Headers = struct {
    items: [max_headers]std.http.Header = undefined,
    len: usize = 0,

    pub fn add(headers: *Headers, name: []const u8, value: []const u8) !void {
        if (headers.len == headers.items.len) return error.TooManyHeaders;
        if (!validHeaderName(name) or !validHeaderValue(value)) return error.InvalidHeader;
        headers.items[headers.len] = .{ .name = name, .value = value };
        headers.len += 1;
    }

    pub fn append(headers: *Headers, values: []const std.http.Header) !void {
        for (values) |header| try headers.add(header.name, header.value);
    }

    pub fn slice(headers: *const Headers) []const std.http.Header {
        return headers.items[0..headers.len];
    }

    pub fn get(headers: *const Headers, name: []const u8) ?[]const u8 {
        for (headers.slice()) |header| {
            if (std.ascii.eqlIgnoreCase(header.name, name)) return header.value;
        }
        return null;
    }
};

pub const Options = struct {
    status: std.http.Status = .ok,
    content_type: ?[]const u8 = null,
    cache_control: ?[]const u8 = null,
    extra_headers: []const std.http.Header = &.{},
};

pub fn respond(request: *std.http.Server.Request, body: []const u8, options: Options) !void {
    var headers = Headers{};
    if (options.content_type) |value| try headers.add("content-type", value);
    if (options.cache_control) |value| try headers.add("cache-control", value);
    try headers.append(options.extra_headers);
    try request.respond(body, .{ .status = options.status, .extra_headers = headers.slice() });
}

pub fn html(request: *std.http.Server.Request, body: []const u8, status: std.http.Status, extra: []const std.http.Header) !void {
    try respond(request, body, .{
        .status = status,
        .content_type = "text/html; charset=utf-8",
        .extra_headers = extra,
    });
}

pub fn json(request: *std.http.Server.Request, body: []const u8, status: std.http.Status, extra: []const std.http.Header) !void {
    try respond(request, body, .{
        .status = status,
        .content_type = "application/json; charset=utf-8",
        .extra_headers = extra,
    });
}

pub fn redirect(
    request: *std.http.Server.Request,
    location: []const u8,
    status: std.http.Status,
    extra: []const std.http.Header,
) !void {
    switch (status) {
        .moved_permanently, .found, .see_other, .temporary_redirect, .permanent_redirect => {},
        else => return error.InvalidRedirectStatus,
    }
    var headers = Headers{};
    try headers.add("location", location);
    try headers.add("cache-control", "no-store");
    try headers.append(extra);
    try request.respond("", .{ .status = status, .extra_headers = headers.slice() });
}

pub fn validHeaderName(name: []const u8) bool {
    if (name.len == 0) return false;
    for (name) |byte| {
        if (!(std.ascii.isAlphanumeric(byte) or
            byte == '!' or byte == '#' or byte == '$' or byte == '%' or byte == '&' or
            byte == '\'' or byte == '*' or byte == '+' or byte == '-' or byte == '.' or
            byte == '^' or byte == '_' or byte == '`' or byte == '|' or byte == '~')) return false;
    }
    return true;
}

pub fn validHeaderValue(value: []const u8) bool {
    return std.mem.indexOfAny(u8, value, "\r\n\x00") == null;
}

test "header collection is bounded searchable and injection safe" {
    var headers = Headers{};
    try headers.add("content-type", "text/html; charset=utf-8");
    try headers.add("x-test", "yes");
    try std.testing.expectEqualStrings("text/html; charset=utf-8", headers.get("Content-Type").?);
    try std.testing.expectError(error.InvalidHeader, headers.add("bad:name", "value"));
    try std.testing.expectError(error.InvalidHeader, headers.add("x-test", "yes\r\nset-cookie: stolen"));
}

test "header grammar accepts extension names and visible values" {
    try std.testing.expect(validHeaderName("x-content-type-options"));
    try std.testing.expect(validHeaderName("HX-Push-Url"));
    try std.testing.expect(!validHeaderName(""));
    try std.testing.expect(!validHeaderName("has space"));
    try std.testing.expect(validHeaderValue("camera=(), microphone=()"));
}
