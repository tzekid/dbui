//! Explicit browser security-header policies.

const std = @import("std");

pub const Policy = struct {
    content_security_policy: ?[]const u8 = null,
    referrer_policy: []const u8 = "strict-origin-when-cross-origin",
    permissions_policy: []const u8 = "camera=(), microphone=(), geolocation=()",
    frame_options: ?[]const u8 = "DENY",
    strict_transport_security: ?[]const u8 = "max-age=31536000",
    secure_transport: bool = false,
    development: bool = false,
    noindex: bool = false,
    same_origin_isolation: bool = false,
};

pub const HeaderSet = struct {
    items: [10]std.http.Header = undefined,
    len: usize = 0,

    pub fn slice(set: *const HeaderSet) []const std.http.Header {
        return set.items[0..set.len];
    }

    pub fn get(set: *const HeaderSet, name: []const u8) ?[]const u8 {
        for (set.slice()) |header| {
            if (std.ascii.eqlIgnoreCase(header.name, name)) return header.value;
        }
        return null;
    }

    fn add(set: *HeaderSet, name: []const u8, value: []const u8) void {
        set.items[set.len] = .{ .name = name, .value = value };
        set.len += 1;
    }
};

pub fn build(policy: Policy) HeaderSet {
    var headers = HeaderSet{};
    headers.add("x-content-type-options", "nosniff");
    headers.add("referrer-policy", policy.referrer_policy);
    headers.add("permissions-policy", policy.permissions_policy);
    if (policy.frame_options) |value| headers.add("x-frame-options", value);
    if (policy.content_security_policy) |value| headers.add("content-security-policy", value);
    if (policy.secure_transport and !policy.development) {
        if (policy.strict_transport_security) |value| headers.add("strict-transport-security", value);
    }
    if (policy.noindex) headers.add("x-robots-tag", "noindex, nofollow");
    if (policy.same_origin_isolation) {
        headers.add("cross-origin-opener-policy", "same-origin");
        headers.add("cross-origin-resource-policy", "same-origin");
    }
    return headers;
}

test "production HTML policy emits explicit browser boundaries" {
    const headers = build(.{
        .content_security_policy = "default-src 'self'",
        .secure_transport = true,
        .noindex = true,
    });
    try std.testing.expectEqualStrings("nosniff", headers.get("x-content-type-options").?);
    try std.testing.expectEqualStrings("default-src 'self'", headers.get("content-security-policy").?);
    try std.testing.expect(headers.get("strict-transport-security") != null);
    try std.testing.expect(headers.get("x-robots-tag") != null);
}

test "development never emits HSTS" {
    const headers = build(.{ .secure_transport = true, .development = true });
    try std.testing.expect(headers.get("strict-transport-security") == null);
}
