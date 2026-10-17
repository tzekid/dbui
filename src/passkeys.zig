//! WebAuthn verification, shared with cloudio: user verification is always
//! required and synced-passkey counters are recorded, never enforced.
const std = @import("std");
const passcay = @import("passcay");
const zbor = @import("zbor");

const Allocator = std.mem.Allocator;

pub const max_client_data_bytes = 16 * 1024;
pub const max_attestation_bytes = 128 * 1024;
pub const max_authenticator_data_bytes = 8 * 1024;
pub const max_signature_bytes = 8 * 1024;
pub const max_credential_id_bytes = 1024;

pub const Registration = struct {
    credential_id: []const u8,
    public_key: []const u8,
    algorithm: i32,
    sign_count: u32,
    aaguid: []const u8,
    backup_eligible: bool,
    backup_state: bool,

    pub fn deinit(self: Registration, gpa: Allocator) void {
        gpa.free(self.credential_id);
        gpa.free(self.public_key);
        gpa.free(self.aaguid);
    }
};

pub const Authentication = struct {
    sign_count: u32,
    recommended_sign_count: u32,
    backup_eligible: bool,
    backup_state: bool,
    sign_count_regressed: bool,
};

pub const RegistrationInput = struct {
    attestation_object: []const u8,
    client_data_json: []const u8,
    expected_challenge: []const u8,
    expected_origin: []const u8,
    rp_id: []const u8,
};

pub const AuthenticationInput = struct {
    authenticator_data: []const u8,
    client_data_json: []const u8,
    signature: []const u8,
    public_key: []const u8,
    expected_challenge: []const u8,
    expected_origin: []const u8,
    rp_id: []const u8,
    known_sign_count: u32,
};

pub fn verifyRegistration(gpa: Allocator, input: RegistrationInput) !Registration {
    try validateEncodedSize(input.client_data_json, max_client_data_bytes);
    try validateEncodedSize(input.attestation_object, max_attestation_bytes);
    try guardClientData(gpa, input.client_data_json);
    try guardAttestation(gpa, input.attestation_object);

    const verified = try passcay.register.verify(gpa, .{
        .attestation_object = input.attestation_object,
        .client_data_json = input.client_data_json,
    }, .{
        .challenge = input.expected_challenge,
        .origin = input.expected_origin,
        .rp_id = input.rp_id,
        .require_user_verification = true,
        .require_user_presence = true,
        .attestation = null,
    });
    defer verified.deinit(gpa);

    try validateEncodedSize(verified.credential_id, max_credential_id_bytes);
    const public_key = try passcay.util.decodeBase64Url(gpa, verified.public_key);
    defer gpa.free(public_key);
    const algorithm = try coseAlgorithm(public_key);
    if (algorithm != -7 and algorithm != -257) return error.UnsupportedAlgorithm;
    try validateBackupFlags(verified.flags);

    const credential_id = try gpa.dupe(u8, verified.credential_id);
    errdefer gpa.free(credential_id);
    const stored_public_key = try gpa.dupe(u8, verified.public_key);
    errdefer gpa.free(stored_public_key);
    const aaguid = try gpa.dupe(u8, verified.aaguid);
    errdefer gpa.free(aaguid);
    return .{
        .credential_id = credential_id,
        .public_key = stored_public_key,
        .algorithm = algorithm,
        .sign_count = verified.sign_count,
        .aaguid = aaguid,
        .backup_eligible = hasFlag(verified.flags, 0x08),
        .backup_state = hasFlag(verified.flags, 0x10),
    };
}

pub fn verifyAuthentication(gpa: Allocator, input: AuthenticationInput) !Authentication {
    try validateEncodedSize(input.client_data_json, max_client_data_bytes);
    try validateEncodedSize(input.authenticator_data, max_authenticator_data_bytes);
    try validateEncodedSize(input.signature, max_signature_bytes);
    try guardClientData(gpa, input.client_data_json);
    const auth_bytes = try passcay.util.decodeBase64Url(gpa, input.authenticator_data);
    defer gpa.free(auth_bytes);
    if (auth_bytes.len < 37 or auth_bytes[32] & 0x40 != 0) return error.InvalidAuthenticatorData;
    var offset: usize = 37;
    if (auth_bytes[32] & 0x80 != 0) try cborItem(auth_bytes, &offset, 0);
    if (offset != auth_bytes.len) return error.InvalidAuthenticatorData;

    const verified = try passcay.auth.verify(gpa, .{
        .authenticator_data = input.authenticator_data,
        .client_data_json = input.client_data_json,
        .signature = input.signature,
    }, .{
        .public_key = input.public_key,
        .challenge = input.expected_challenge,
        .origin = input.expected_origin,
        .rp_id = input.rp_id,
        .require_user_verification = true,
        .require_user_presence = true,
        // Synced passkeys commonly report zero or non-monotonic counters. The
        // counter is recorded as a risk signal, never treated as proof.
        .enable_sign_count_check = false,
        .known_sign_count = input.known_sign_count,
    });
    defer verified.deinit(gpa);
    try validateBackupFlags(verified.flags);

    return .{
        .sign_count = verified.sign_count,
        .recommended_sign_count = @max(verified.sign_count, input.known_sign_count),
        .backup_eligible = hasFlag(verified.flags, 0x08),
        .backup_state = hasFlag(verified.flags, 0x10),
        .sign_count_regressed = input.known_sign_count > 0 and
            verified.sign_count > 0 and
            verified.sign_count < input.known_sign_count,
    };
}

fn validateEncodedSize(value: []const u8, max_decoded: usize) !void {
    if (value.len == 0) return error.MissingWebAuthnField;
    // Base64url expands by at most 4/3. This check intentionally leaves a
    // small margin and rejects payloads before any expensive parsing.
    if (value.len > (max_decoded * 4 / 3) + 8) return error.WebAuthnFieldTooLarge;
}

const ClientDataGuard = struct {
    crossOrigin: ?bool = null,
    topOrigin: ?[]const u8 = null,
};

fn guardClientData(gpa: Allocator, encoded: []const u8) !void {
    const decoded = try passcay.util.decodeBase64Url(gpa, encoded);
    defer gpa.free(decoded);
    if (decoded.len > max_client_data_bytes) return error.WebAuthnFieldTooLarge;
    const parsed = try std.json.parseFromSlice(
        ClientDataGuard,
        gpa,
        decoded,
        .{ .ignore_unknown_fields = true },
    );
    defer parsed.deinit();
    if (parsed.value.crossOrigin orelse false) return error.CrossOriginCeremony;
    if (parsed.value.topOrigin != null) return error.CrossOriginCeremony;
}

fn validateBackupFlags(flags: u8) !void {
    if (hasFlag(flags, 0x10) and !hasFlag(flags, 0x08)) {
        return error.InvalidBackupFlags;
    }
}

fn coseAlgorithm(public_key: []const u8) !i32 {
    const item = try zbor.DataItem.new(public_key);
    var map = item.map() orelse return error.InvalidCoseKey;
    while (map.next()) |pair| {
        const label = pair.key.int() orelse continue;
        if (label != 3) continue;
        const value = pair.value.int() orelse return error.InvalidCoseKey;
        if (value < std.math.minInt(i32) or value > std.math.maxInt(i32)) {
            return error.UnsupportedAlgorithm;
        }
        return @intCast(value);
    }
    return error.InvalidCoseKey;
}

fn hasFlag(flags: u8, mask: u8) bool {
    return flags & mask != 0;
}

// Bound CBOR depth and lengths before passing untrusted data to the vendored
// parser. WebAuthn's canonical CBOR uses definite-length containers.
fn cborItem(bytes: []const u8, offset: *usize, depth: usize) !void {
    if (depth > 16 or offset.* >= bytes.len) return error.InvalidCbor;
    const head = bytes[offset.*];
    offset.* += 1;
    const major = head >> 5;
    const info = head & 31;
    var value: u64 = info;
    if (info >= 24) {
        const count: usize = switch (info) {
            24 => 1,
            25 => 2,
            26 => 4,
            27 => 8,
            else => return error.InvalidCbor,
        };
        if (count > bytes.len - offset.*) return error.InvalidCbor;
        value = 0;
        for (bytes[offset.*..][0..count]) |byte| value = (value << 8) | byte;
        offset.* += count;
    }
    switch (major) {
        0, 1, 7 => {},
        2, 3 => {
            if (value > bytes.len - offset.*) return error.InvalidCbor;
            offset.* += @intCast(value);
        },
        4, 5 => {
            if (value > bytes.len - offset.*) return error.InvalidCbor;
            const children = std.math.mul(u64, value, if (major == 5) 2 else 1) catch return error.InvalidCbor;
            if (children > bytes.len - offset.*) return error.InvalidCbor;
            for (0..@intCast(children)) |_| try cborItem(bytes, offset, depth + 1);
        },
        6 => try cborItem(bytes, offset, depth + 1),
        else => return error.InvalidCbor,
    }
}

fn guardAttestation(gpa: Allocator, encoded: []const u8) !void {
    const bytes = try passcay.util.decodeBase64Url(gpa, encoded);
    defer gpa.free(bytes);
    var offset: usize = 0;
    try cborItem(bytes, &offset, 0);
    if (offset != bytes.len) return error.InvalidCbor;
    const item = try zbor.DataItem.new(bytes);
    var map = item.map() orelse return error.InvalidCbor;
    var found = false;
    while (map.next()) |pair| {
        const name = pair.key.string() orelse return error.InvalidCbor;
        if (!std.mem.eql(u8, name, "authData")) continue;
        if (found) return error.InvalidCbor;
        found = true;
        const auth_data = pair.value.string() orelse return error.InvalidAuthenticatorData;
        if (auth_data.len < 55 or auth_data[32] & 0x40 == 0) return error.InvalidAuthenticatorData;
        const id_len = std.mem.readInt(u16, auth_data[53..55], .big);
        if (id_len == 0 or id_len > max_credential_id_bytes or id_len > auth_data.len - 55) return error.InvalidAuthenticatorData;
        offset = 55 + @as(usize, id_len);
        try cborItem(auth_data, &offset, 0);
        if (auth_data[32] & 0x80 != 0) try cborItem(auth_data, &offset, 0);
        if (offset != auth_data.len) return error.InvalidAuthenticatorData;
    }
    if (!found) return error.InvalidAuthenticatorData;
}

test "client data guard rejects cross-origin ceremonies" {
    const gpa = std.testing.allocator;
    const json = "{\"type\":\"webauthn.get\",\"challenge\":\"x\",\"origin\":\"https://example.test\",\"crossOrigin\":true}";
    const encoded_len = std.base64.url_safe_no_pad.Encoder.calcSize(json.len);
    const encoded = try gpa.alloc(u8, encoded_len);
    defer gpa.free(encoded);
    _ = std.base64.url_safe_no_pad.Encoder.encode(encoded, json);
    try std.testing.expectError(error.CrossOriginCeremony, guardClientData(gpa, encoded));
}

test "backup state requires backup eligibility" {
    try std.testing.expectError(error.InvalidBackupFlags, validateBackupFlags(0x10));
    try validateBackupFlags(0x18);
}
