//! Optional HTMX 4 request and response semantics.
//!
//! This module has no dependency on the HTMX browser asset. Applications may
//! self-host the pinned, verified asset while keeping native links and forms
//! as the functional baseline.

const std = @import("std");
const digest = @import("web_digest");

pub const pinned_version = "v4.0.0-beta6";
pub const pinned_commit = "6ca11fbdc881a96c5fbeb0d7094a77183120ea22";
pub const pinned_asset_url = "https://github.com/bigskysoftware/htmx/releases/download/v4.0.0-beta6/htmx.min.js";
pub const pinned_asset_sha256 = "28fae7bbe8e8142b702debb9d5234a9a436d9435a4b5165b195aa1a7ed840d25";
pub const cache_vary = "HX-Request-Type";

pub const RequestType = enum {
    none,
    full,
    partial,
};

pub const Metadata = struct {
    request_type: RequestType = .none,
    boosted: bool = false,
    history_restore: bool = false,
    current_url: ?[]const u8 = null,
    source: ?[]const u8 = null,
    target: ?[]const u8 = null,

    pub fn enhanced(metadata: Metadata) bool {
        return metadata.request_type != .none;
    }

    pub fn wantsFragment(metadata: Metadata) bool {
        return metadata.request_type == .partial;
    }

    pub fn fromRequest(request: *const std.http.Server.Request) !Metadata {
        var headers: [16]std.http.Header = undefined;
        var count: usize = 0;
        var iterator = request.iterateHeaders();
        while (iterator.next()) |header| {
            if (!isRelevantHeader(header.name)) continue;
            if (count == headers.len) return error.TooManyRelevantHeaders;
            headers[count] = header;
            count += 1;
        }
        return fromHeaders(headers[0..count]);
    }

    pub fn fromHeaders(headers: []const std.http.Header) !Metadata {
        if (!headerIsTrue(headers, "HX-Request")) return .{};
        const raw_type = findHeader(headers, "HX-Request-Type") orelse return error.MissingRequestType;
        const request_type: RequestType = if (std.ascii.eqlIgnoreCase(raw_type, "full"))
            .full
        else if (std.ascii.eqlIgnoreCase(raw_type, "partial"))
            .partial
        else
            return error.InvalidRequestType;
        return .{
            .request_type = request_type,
            .boosted = headerIsTrue(headers, "HX-Boosted"),
            .history_restore = headerIsTrue(headers, "HX-History-Restore-Request"),
            .current_url = findHeader(headers, "HX-Current-URL"),
            .source = findHeader(headers, "HX-Source"),
            .target = findHeader(headers, "HX-Target"),
        };
    }
};

pub const Commands = struct {
    location: ?[]const u8 = null,
    redirect: ?[]const u8 = null,
    refresh: bool = false,
    push_url: ?[]const u8 = null,
    replace_url: ?[]const u8 = null,
    retarget: ?[]const u8 = null,
    reswap: ?[]const u8 = null,
    reselect: ?[]const u8 = null,
    trigger: ?[]const u8 = null,

    pub fn headers(commands: Commands) !HeaderSet {
        var navigation_count: usize = 0;
        if (commands.location != null) navigation_count += 1;
        if (commands.redirect != null) navigation_count += 1;
        if (commands.refresh) navigation_count += 1;
        if (navigation_count > 1) return error.ConflictingNavigation;

        var result = HeaderSet{};
        if (commands.location) |value| try result.add("HX-Location", value);
        if (commands.redirect) |value| try result.add("HX-Redirect", value);
        if (commands.refresh) try result.add("HX-Refresh", "true");
        if (commands.push_url) |value| try result.add("HX-Push-Url", value);
        if (commands.replace_url) |value| try result.add("HX-Replace-Url", value);
        if (commands.retarget) |value| try result.add("HX-Retarget", value);
        if (commands.reswap) |value| try result.add("HX-Reswap", value);
        if (commands.reselect) |value| try result.add("HX-Reselect", value);
        if (commands.trigger) |value| try result.add("HX-Trigger", value);
        return result;
    }
};

pub const HeaderSet = struct {
    items: [9]std.http.Header = undefined,
    len: usize = 0,

    pub fn slice(set: *const HeaderSet) []const std.http.Header {
        return set.items[0..set.len];
    }

    pub fn get(set: *const HeaderSet, name: []const u8) ?[]const u8 {
        return findHeader(set.slice(), name);
    }

    fn add(set: *HeaderSet, name: []const u8, value: []const u8) !void {
        if (std.mem.indexOfAny(u8, value, "\r\n\x00") != null) return error.InvalidHeaderValue;
        set.items[set.len] = .{ .name = name, .value = value };
        set.len += 1;
    }
};

pub fn verifyPinnedAsset(asset: []const u8) bool {
    return verifyChecksum(asset, pinned_asset_sha256);
}

pub fn verifyChecksum(asset: []const u8, expected_hex: []const u8) bool {
    return digest.matches(expected_hex, asset) catch false;
}

fn findHeader(headers: []const std.http.Header, wanted: []const u8) ?[]const u8 {
    for (headers) |header| {
        if (std.ascii.eqlIgnoreCase(header.name, wanted)) return std.mem.trim(u8, header.value, " \t");
    }
    return null;
}

fn headerIsTrue(headers: []const std.http.Header, name: []const u8) bool {
    const value = findHeader(headers, name) orelse return false;
    return std.ascii.eqlIgnoreCase(value, "true");
}

fn isRelevantHeader(name: []const u8) bool {
    const relevant = [_][]const u8{
        "HX-Request",
        "HX-Request-Type",
        "HX-Boosted",
        "HX-History-Restore-Request",
        "HX-Current-URL",
        "HX-Source",
        "HX-Target",
    };
    for (relevant) |candidate| {
        if (std.ascii.eqlIgnoreCase(name, candidate)) return true;
    }
    return false;
}

test "normal full and partial requests remain distinct" {
    const normal = try Metadata.fromHeaders(&.{.{ .name = "Accept", .value = "text/html" }});
    try std.testing.expectEqual(RequestType.none, normal.request_type);
    try std.testing.expect(!normal.enhanced());

    const full = try Metadata.fromHeaders(&.{
        .{ .name = "HX-Request", .value = "true" },
        .{ .name = "HX-Request-Type", .value = "full" },
        .{ .name = "HX-Boosted", .value = "true" },
    });
    try std.testing.expectEqual(RequestType.full, full.request_type);
    try std.testing.expect(full.boosted and !full.wantsFragment());

    const partial = try Metadata.fromHeaders(&.{
        .{ .name = "hx-request", .value = "TRUE" },
        .{ .name = "hx-request-type", .value = "partial" },
        .{ .name = "hx-target", .value = "main#content" },
    });
    try std.testing.expect(partial.wantsFragment());
    try std.testing.expectEqualStrings("main#content", partial.target.?);
}

test "enhanced requests require the HTMX 4 representation header" {
    try std.testing.expectError(error.MissingRequestType, Metadata.fromHeaders(&.{
        .{ .name = "HX-Request", .value = "true" },
    }));
    try std.testing.expectError(error.InvalidRequestType, Metadata.fromHeaders(&.{
        .{ .name = "HX-Request", .value = "true" },
        .{ .name = "HX-Request-Type", .value = "unknown" },
    }));
}

test "unrelated headers do not consume the relevant-header bound" {
    var headers: [32]std.http.Header = undefined;
    for (&headers) |*header| header.* = .{ .name = "X-Unrelated", .value = "value" };
    try std.testing.expectEqual(RequestType.none, (try Metadata.fromHeaders(headers[0..])).request_type);
}

test "response commands reject conflicts and header injection" {
    try std.testing.expectError(error.ConflictingNavigation, (Commands{
        .location = "/next",
        .redirect = "/other",
    }).headers());
    try std.testing.expectError(error.InvalidHeaderValue, (Commands{
        .push_url = "/safe\r\nset-cookie: stolen",
    }).headers());
    const headers = try (Commands{
        .push_url = "/events?page=2",
        .retarget = "main#content",
        .reswap = "innerHTML",
    }).headers();
    try std.testing.expectEqualStrings("/events?page=2", headers.get("HX-Push-Url").?);
}

test "checksum verification is deterministic" {
    try std.testing.expect(verifyChecksum(
        "",
        "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
    ));
    try std.testing.expect(!verifyChecksum("changed", "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"));
}
