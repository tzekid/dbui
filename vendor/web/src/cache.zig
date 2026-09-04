//! Conditional request and cache policy helpers.

const std = @import("std");

pub const Policy = enum {
    no_store,
    private_revalidate,
    public_revalidate,
    immutable,

    pub fn headerValue(policy: Policy) []const u8 {
        return switch (policy) {
            .no_store => "private, no-store",
            .private_revalidate => "private, no-cache",
            .public_revalidate => "public, no-cache",
            .immutable => "public, max-age=31536000, immutable",
        };
    }
};

pub const Etag = struct {
    bytes: [34]u8,

    pub fn fromBytes(content: []const u8) Etag {
        return fromParts(&.{content});
    }

    /// Hash a structured sequence without making concatenation boundaries
    /// ambiguous. This is useful for disk assets whose validator includes path,
    /// representation, size, and modification time.
    pub fn fromParts(parts: []const []const u8) Etag {
        var hash = std.crypto.hash.sha2.Sha256.init(.{});
        for (parts) |part| {
            var length: [8]u8 = undefined;
            std.mem.writeInt(u64, &length, @intCast(part.len), .big);
            hash.update(&length);
            hash.update(part);
        }
        var digest: [32]u8 = undefined;
        hash.final(&digest);
        var result: Etag = undefined;
        result.bytes[0] = '"';
        _ = std.fmt.bufPrint(result.bytes[1..33], "{x}", .{digest[0..16]}) catch unreachable;
        result.bytes[33] = '"';
        return result;
    }

    pub fn slice(etag: *const Etag) []const u8 {
        return &etag.bytes;
    }
};

pub fn matches(if_none_match: []const u8, current: []const u8) bool {
    var values = std.mem.splitScalar(u8, if_none_match, ',');
    while (values.next()) |raw| {
        var value = std.mem.trim(u8, raw, " \t");
        if (std.mem.eql(u8, value, "*")) return true;
        if (std.mem.startsWith(u8, value, "W/")) value = std.mem.trimStart(u8, value[2..], " \t");
        if (std.mem.eql(u8, value, current)) return true;
    }
    return false;
}

pub const HttpDate = struct {
    bytes: [29]u8,

    pub fn fromUnix(seconds: i64) !HttpDate {
        if (seconds < 0) return error.InvalidTimestamp;
        const epoch_seconds = std.time.epoch.EpochSeconds{ .secs = @intCast(seconds) };
        const epoch_day = epoch_seconds.getEpochDay();
        const year_day = epoch_day.calculateYearDay();
        const month_day = year_day.calculateMonthDay();
        const day_seconds = epoch_seconds.getDaySeconds();
        const weekdays = [_][]const u8{ "Thu", "Fri", "Sat", "Sun", "Mon", "Tue", "Wed" };
        const months = [_][]const u8{ "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec" };
        var result: HttpDate = undefined;
        const rendered = try std.fmt.bufPrint(&result.bytes, "{s}, {d:0>2} {s} {d:0>4} {d:0>2}:{d:0>2}:{d:0>2} GMT", .{
            weekdays[@as(usize, @intCast(epoch_day.day % 7))],
            month_day.day_index + 1,
            months[month_day.month.numeric() - 1],
            year_day.year,
            day_seconds.getHoursIntoDay(),
            day_seconds.getMinutesIntoHour(),
            day_seconds.getSecondsIntoMinute(),
        });
        std.debug.assert(rendered.len == result.bytes.len);
        return result;
    }

    pub fn slice(date: *const HttpDate) []const u8 {
        return &date.bytes;
    }
};

pub fn appendVary(buffer: []u8, existing: []const u8, token: []const u8) ![]const u8 {
    var values = std.mem.splitScalar(u8, existing, ',');
    while (values.next()) |value| {
        if (std.ascii.eqlIgnoreCase(std.mem.trim(u8, value, " \t"), token)) {
            if (existing.len > buffer.len) return error.NoSpaceLeft;
            @memcpy(buffer[0..existing.len], existing);
            return buffer[0..existing.len];
        }
    }
    if (existing.len == 0) return std.fmt.bufPrint(buffer, "{s}", .{token});
    return std.fmt.bufPrint(buffer, "{s}, {s}", .{ existing, token });
}

test "ETags are deterministic quoted and support weak request validators" {
    const first = Etag.fromBytes("hello");
    const second = Etag.fromBytes("hello");
    const other = Etag.fromBytes("world");
    try std.testing.expectEqualStrings(first.slice(), second.slice());
    try std.testing.expect(!std.mem.eql(u8, first.slice(), other.slice()));
    try std.testing.expect(first.slice()[0] == '"' and first.slice()[33] == '"');
    try std.testing.expect(matches(first.slice(), first.slice()));
    var weak_buffer: [36]u8 = undefined;
    const weak = try std.fmt.bufPrint(&weak_buffer, "W/{s}", .{first.slice()});
    try std.testing.expect(matches(weak, first.slice()));
    try std.testing.expect(matches("*", first.slice()));
}

test "multipart ETags preserve value boundaries" {
    const separated = Etag.fromParts(&.{ "ab", "c" });
    const joined = Etag.fromParts(&.{ "a", "bc" });
    try std.testing.expect(!std.mem.eql(u8, separated.slice(), joined.slice()));
}

test "cache policies make personalized and fingerprinted intent explicit" {
    try std.testing.expectEqualStrings("private, no-store", Policy.no_store.headerValue());
    try std.testing.expectEqualStrings("public, max-age=31536000, immutable", Policy.immutable.headerValue());
}

test "HTTP dates and Vary values are stable" {
    const epoch = try HttpDate.fromUnix(0);
    try std.testing.expectEqualStrings("Thu, 01 Jan 1970 00:00:00 GMT", epoch.slice());
    var buffer: [128]u8 = undefined;
    try std.testing.expectEqualStrings("Accept-Encoding, HX-Request-Type", try appendVary(&buffer, "Accept-Encoding", "HX-Request-Type"));
    try std.testing.expectEqualStrings("accept-encoding", try appendVary(&buffer, "accept-encoding", "Accept-Encoding"));
}
