//! Shared protocol and consumer testing helpers.

const std = @import("std");

pub fn expectContains(haystack: []const u8, needle: []const u8) !void {
    if (std.mem.indexOf(u8, haystack, needle) == null) {
        std.debug.print("expected output to contain: {s}\n", .{needle});
        return error.TestExpectedEqual;
    }
}

pub fn expectNotContains(haystack: []const u8, needle: []const u8) !void {
    if (std.mem.indexOf(u8, haystack, needle) != null) {
        std.debug.print("expected output not to contain: {s}\n", .{needle});
        return error.TestExpectedNotEqual;
    }
}

pub fn expectHeader(headers: []const std.http.Header, name: []const u8, expected: []const u8) !void {
    for (headers) |header| {
        if (std.ascii.eqlIgnoreCase(header.name, name)) {
            try std.testing.expectEqualStrings(expected, header.value);
            return;
        }
    }
    return error.TestExpectedEqual;
}

test "testing helpers describe HTML and header expectations" {
    try expectContains("<main>useful</main>", "useful");
    try expectNotContains("<main>useful</main>", "<script");
    try expectHeader(&.{.{ .name = "content-type", .value = "text/html" }}, "Content-Type", "text/html");
}
