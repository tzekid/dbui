//! SHA-256 hex digests: the one implementation for asset pinning, plan
//! digests, and checksum verification across the ecosystem.

const std = @import("std");

pub const Error = error{InvalidHexDigest};

pub const sha256_hex_len = 64;

/// Lowercase hex digest of `bytes`.
pub fn sha256Hex(bytes: []const u8, out: *[sha256_hex_len]u8) void {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
    const hex = "0123456789abcdef";
    for (digest, 0..) |byte, index| {
        out[index * 2] = hex[byte >> 4];
        out[index * 2 + 1] = hex[byte & 0x0f];
    }
}

/// Parse a 64-character hex digest, accepting either case.
pub fn parseSha256Hex(text: []const u8) Error![32]u8 {
    if (text.len != sha256_hex_len) return Error.InvalidHexDigest;
    var out: [32]u8 = undefined;
    for (0..32) |index| {
        const high = nibble(text[index * 2]) orelse return Error.InvalidHexDigest;
        const low = nibble(text[index * 2 + 1]) orelse return Error.InvalidHexDigest;
        out[index] = high << 4 | low;
    }
    return out;
}

/// Whether `bytes` hashes to `expected_hex`. Comparison is constant-time so a
/// digest check can never become a byte-by-byte oracle.
pub fn matches(expected_hex: []const u8, bytes: []const u8) Error!bool {
    const expected = try parseSha256Hex(expected_hex);
    var actual: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &actual, .{});
    return std.crypto.timing_safe.eql([32]u8, expected, actual);
}

fn nibble(character: u8) ?u8 {
    return switch (character) {
        '0'...'9' => character - '0',
        'a'...'f' => character - 'a' + 10,
        'A'...'F' => character - 'A' + 10,
        else => null,
    };
}

test "digest round trip and case insensitivity" {
    var hex: [sha256_hex_len]u8 = undefined;
    sha256Hex("abc", &hex);
    try std.testing.expectEqualStrings(
        "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad",
        &hex,
    );
    try std.testing.expect(try matches(&hex, "abc"));
    var upper: [sha256_hex_len]u8 = undefined;
    for (hex, 0..) |character, index| upper[index] = std.ascii.toUpper(character);
    try std.testing.expect(try matches(&upper, "abc"));
    try std.testing.expect(!try matches(&hex, "abd"));
}

test "malformed digests are rejected, not misread" {
    try std.testing.expectError(Error.InvalidHexDigest, parseSha256Hex("abc"));
    const bad_char = "zz7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad";
    try std.testing.expectError(Error.InvalidHexDigest, parseSha256Hex(bad_char));
    try std.testing.expectError(Error.InvalidHexDigest, matches("", "abc"));
}
