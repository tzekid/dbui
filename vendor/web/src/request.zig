//! Bounded HTTP request parsing helpers.

const std = @import("std");

pub const Limits = struct {
    target_bytes: usize = 8 * 1024,
    body_bytes: u64 = 1024 * 1024,
    parameter_count: usize = 256,
    decoded_parameter_bytes: usize = 64 * 1024,
};

pub const Target = struct {
    raw: []const u8,
    path: []const u8,
    query: []const u8,

    pub fn parse(raw: []const u8, maximum: usize) !Target {
        if (raw.len == 0 or raw.len > maximum) return error.TargetTooLong;
        if (raw[0] != '/' or std.mem.indexOfAny(u8, raw, "\r\n\x00") != null) return error.InvalidTarget;
        const fragment = std.mem.indexOfScalar(u8, raw, '#') orelse raw.len;
        const query = std.mem.indexOfScalar(u8, raw[0..fragment], '?');
        return .{
            .raw = raw,
            .path = raw[0 .. query orelse fragment],
            .query = if (query) |index| raw[index + 1 .. fragment] else "",
        };
    }
};

pub const Parameter = struct {
    name: []const u8,
    value: []const u8,
};

pub const ParameterIterator = struct {
    remaining: []const u8,
    separator: u8,
    count: usize = 0,
    maximum: usize,

    pub fn init(encoded: []const u8, separator: u8, maximum: usize) ParameterIterator {
        return .{ .remaining = encoded, .separator = separator, .maximum = maximum };
    }

    pub fn next(iterator: *ParameterIterator) !?Parameter {
        if (iterator.remaining.len == 0) return null;
        if (iterator.count == iterator.maximum) return error.TooManyParameters;
        const end = std.mem.indexOfScalar(u8, iterator.remaining, iterator.separator) orelse iterator.remaining.len;
        const pair = iterator.remaining[0..end];
        iterator.remaining = if (end == iterator.remaining.len) "" else iterator.remaining[end + 1 ..];
        iterator.count += 1;
        const equals = std.mem.indexOfScalar(u8, pair, '=') orelse pair.len;
        return .{
            .name = pair[0..equals],
            .value = if (equals == pair.len) "" else pair[equals + 1 ..],
        };
    }
};

pub fn queryIterator(target: Target, maximum: usize) ParameterIterator {
    return .init(target.query, '&', maximum);
}

pub fn formIterator(body: []const u8, maximum: usize) ParameterIterator {
    return .init(body, '&', maximum);
}

pub fn decodeComponent(destination: []u8, encoded: []const u8, plus_as_space: bool) ![]u8 {
    if (encoded.len > destination.len) return error.NoSpaceLeft;
    var source: usize = 0;
    var output: usize = 0;
    while (source < encoded.len) {
        const byte = encoded[source];
        if (byte == '%') {
            if (source + 2 >= encoded.len) return error.InvalidPercentEncoding;
            const high = std.fmt.charToDigit(encoded[source + 1], 16) catch return error.InvalidPercentEncoding;
            const low = std.fmt.charToDigit(encoded[source + 2], 16) catch return error.InvalidPercentEncoding;
            const decoded: u8 = @intCast(high * 16 + low);
            if (decoded == 0) return error.DecodedNul;
            destination[output] = decoded;
            source += 3;
        } else {
            if (byte == 0) return error.DecodedNul;
            destination[output] = if (plus_as_space and byte == '+') ' ' else byte;
            source += 1;
        }
        output += 1;
    }
    return destination[0..output];
}

pub fn findCookie(header_value: []const u8, wanted: []const u8) ?[]const u8 {
    var cookies = std.mem.splitScalar(u8, header_value, ';');
    while (cookies.next()) |raw_cookie| {
        const cookie = std.mem.trim(u8, raw_cookie, " \t");
        const equals = std.mem.indexOfScalar(u8, cookie, '=') orelse continue;
        if (std.mem.eql(u8, cookie[0..equals], wanted)) return cookie[equals + 1 ..];
    }
    return null;
}

pub fn header(request: *const std.http.Server.Request, name: []const u8) ?[]const u8 {
    var iterator = request.iterateHeaders();
    while (iterator.next()) |entry| {
        if (std.ascii.eqlIgnoreCase(entry.name, name)) return entry.value;
    }
    return null;
}

pub fn acceptsToken(raw: []const u8, wanted: []const u8) bool {
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

pub fn readBodyAlloc(
    allocator: std.mem.Allocator,
    request: *std.http.Server.Request,
    maximum: u64,
) ![]u8 {
    if (!request.head.method.requestHasBody()) return allocator.alloc(u8, 0);
    if (request.head.content_length) |length| {
        if (length > maximum) return error.BodyTooLarge;
    }
    var transfer_buffer: [8 * 1024]u8 = undefined;
    const reader = try request.readerExpectContinue(&transfer_buffer);
    return reader.allocRemaining(allocator, .limited(maximum)) catch |err| switch (err) {
        error.StreamTooLong => error.BodyTooLarge,
        else => err,
    };
}

pub fn consumeBody(request: *std.http.Server.Request, maximum: u64) !void {
    if (!request.head.method.requestHasBody()) return;
    if (request.head.content_length) |length| {
        if (length > maximum) return error.BodyTooLarge;
    }
    var transfer_buffer: [8 * 1024]u8 = undefined;
    const reader = try request.readerExpectContinue(&transfer_buffer);
    var discard_buffer: [8 * 1024]u8 = undefined;
    var discard: std.Io.Writer.Discarding = .init(&discard_buffer);
    var total: u64 = 0;
    while (true) {
        const allowance = maximum - total + 1;
        const consumed = reader.stream(&discard.writer, .limited64(allowance)) catch |err| switch (err) {
            error.EndOfStream => break,
            else => return err,
        };
        total += consumed;
        if (total > maximum) return error.BodyTooLarge;
    }
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

test "target parsing separates path and query and rejects unsafe forms" {
    const target = try Target.parse("/events?city=Frankfurt&open=1#ignored", 128);
    try std.testing.expectEqualStrings("/events", target.path);
    try std.testing.expectEqualStrings("city=Frankfurt&open=1", target.query);
    try std.testing.expectError(error.InvalidTarget, Target.parse("https://example.com/", 128));
    try std.testing.expectError(error.InvalidTarget, Target.parse("/bad\r\nheader", 128));
    try std.testing.expectError(error.TargetTooLong, Target.parse("/too-long", 4));
}

test "parameter iteration is allocation free and bounded" {
    const target = try Target.parse("/search?q=zig&empty&x=1", 128);
    var iterator = queryIterator(target, 3);
    try std.testing.expectEqualStrings("q", (try iterator.next()).?.name);
    const empty = (try iterator.next()).?;
    try std.testing.expectEqualStrings("empty", empty.name);
    try std.testing.expectEqualStrings("", empty.value);
    try std.testing.expectEqualStrings("1", (try iterator.next()).?.value);
    try std.testing.expect((try iterator.next()) == null);

    var limited = formIterator("a=1&b=2", 1);
    _ = try limited.next();
    try std.testing.expectError(error.TooManyParameters, limited.next());
}

test "component decoding handles form spaces and rejects malformed input" {
    var buffer: [64]u8 = undefined;
    try std.testing.expectEqualStrings("hello world/zig", try decodeComponent(&buffer, "hello+world%2Fzig", true));
    try std.testing.expectEqualStrings("hello+world", try decodeComponent(&buffer, "hello+world", false));
    try std.testing.expectError(error.InvalidPercentEncoding, decodeComponent(&buffer, "%2", true));
    try std.testing.expectError(error.InvalidPercentEncoding, decodeComponent(&buffer, "%GG", true));
    try std.testing.expectError(error.DecodedNul, decodeComponent(&buffer, "%00", true));
}

test "cookie and token parsing honor boundaries and q zero" {
    try std.testing.expectEqualStrings("secret", findCookie("a=1; session=secret; theme=dark", "session").?);
    try std.testing.expect(findCookie("sessionish=no", "session") == null);
    try std.testing.expect(acceptsToken("br, gzip;q=0.7", "gzip"));
    try std.testing.expect(!acceptsToken("gzip;q=0, br", "gzip"));
    try std.testing.expect(acceptsToken("*;q=0.5", "zstd"));
}
