const std = @import("std");
const web = @import("web_app");
const request = @import("web_request");
const response = @import("web_response");
const config = @import("config.zig");
const params = @import("http_params.zig");
const store_mod = @import("auth_store.zig");
const passkeys = @import("passkeys.zig");
const views = @import("auth_views.zig");

const Store = store_mod.Store;
const Session = store_mod.Session;
const auth_js = @embedFile("auth_js");
pub const Access = union(enum) { responded: std.http.Status, allowed: ?Session };

pub const headers = [_]std.http.Header{
    .{ .name = "referrer-policy", .value = "origin" },
    .{ .name = "x-content-type-options", .value = "nosniff" },
    .{ .name = "x-frame-options", .value = "DENY" },
    .{ .name = "content-security-policy", .value = "default-src 'self'; base-uri 'none'; object-src 'none'; frame-ancestors 'none'; form-action 'self'; script-src 'self'; style-src 'self'; img-src 'self' data:" },
    .{ .name = "permissions-policy", .value = "publickey-credentials-create=(self), publickey-credentials-get=(self)" },
};

pub fn dispatch(registry: *const config.Registry, ctx: *web.RequestContext) !Access {
    const settings = registry.auth;
    const target = request.Target.parse(ctx.request.head.target, 16 * 1024) catch {
        return .{ .responded = try jsonError(ctx, .bad_request, "The request target is invalid.") };
    };
    const path = target.path;
    const method = ctx.request.head.method;
    if (method == .GET and is(path, "/healthz")) return .{ .allowed = null };
    if (!std.ascii.eqlIgnoreCase(request.header(ctx.request, "host") orelse "", settings.host())) {
        return .{ .responded = try jsonError(ctx, .bad_request, "Use the configured dbui address.") };
    }
    if (method == .GET and is(path, "/assets/auth.js")) {
        try send(ctx, auth_js, .ok, "text/javascript; charset=utf-8", null);
        return .{ .responded = .ok };
    }
    if (method == .GET and (is(path, "/assets/app.css") or is(path, "/assets/app.js"))) return .{ .allowed = null };

    var store = try Store.open(ctx.arena, settings);
    defer store.deinit();
    const at = store_mod.now(ctx.io);
    const session = try store.session(ctx.arena, cookie(ctx, sessionCookie(settings)) orelse "", at);
    if (method == .GET and is(path, "/auth/session")) {
        if (session) |current| {
            var output: std.Io.Writer.Allocating = .init(ctx.arena);
            try std.json.Stringify.value(.{ .csrf_token = @as([]const u8, &current.csrf) }, .{}, &output.writer);
            try send(ctx, output.written(), .ok, "application/json; charset=utf-8", null);
            return .{ .responded = .ok };
        }
        return .{ .responded = try jsonError(ctx, .unauthorized, "Sign in again.") };
    }
    if (method == .GET and (is(path, "/login") or is(path, "/setup"))) {
        const enrolled = try store.count("SELECT count(*) FROM passkeys", .{}) > 0;
        const query = params.parseQuery(ctx.arena, target) catch return .{ .responded = try jsonError(ctx, .bad_request, "Invalid destination.") };
        const next = safeNext(query.get("next") orelse "/");
        try send(ctx, try views.entry(ctx.arena, settings, is(path, "/setup") and !enrolled, enrolled, next), .ok, "text/html; charset=utf-8", null);
        return .{ .responded = .ok };
    }

    const public_api = is(path, "/auth/setup/options") or is(path, "/auth/setup/verify") or is(path, "/auth/login/options") or is(path, "/auth/login/verify");
    if (session == null and !public_api) {
        if (method == .GET) {
            const next = try encodeComponent(ctx.arena, safeNext(ctx.request.head.target));
            const location = try std.fmt.allocPrint(ctx.arena, "/login?next={s}", .{next});
            try response.redirect(ctx.request, location, .see_other, &headers);
            return .{ .responded = .see_other };
        }
        return .{ .responded = try jsonError(ctx, .unauthorized, "Your session expired. Sign in again; your unsaved query is kept in this browser.") };
    }
    if (method == .GET and is(path, "/security")) {
        const query = try params.parseQuery(ctx.arena, target);
        const notice: ?[]const u8 = if (is(query.get("saved") orelse "", "1")) "Passkey renamed." else if (is(query.get("removed") orelse "", "1")) "Passkey removed and its sessions signed out." else if (is(query.get("added") orelse "", "1")) "Passkey added." else if (is(query.get("revoked") orelse "", "1")) "Other sessions signed out." else null;
        try send(ctx, try views.security(ctx.arena, &store, session.?, notice, at), .ok, "text/html; charset=utf-8", null);
        return .{ .responded = .ok };
    }
    if (std.mem.startsWith(u8, path, "/auth/")) {
        if (method != .POST) return .{ .responded = try jsonError(ctx, .method_not_allowed, "Use a POST request.") };
        if (!is(request.header(ctx.request, "origin") orelse "", settings.origin)) return .{ .responded = try jsonError(ctx, .forbidden, "Reload dbui and try again from its own address.") };
        if (public_api) {
            const client = request.header(ctx.request, "x-forwarded-for") orelse "loopback";
            const first = std.mem.trim(u8, client[0 .. std.mem.indexOfScalar(u8, client, ',') orelse client.len], " ");
            if (!try store.rateLimit(ctx.io, first)) return .{ .responded = try jsonError(ctx, .too_many_requests, "Too many sign-in attempts. Wait one minute and try again.") };
        }
        const stable_path = try ctx.arena.dupe(u8, path);
        const status = authRoute(ctx, settings, &store, session, stable_path) catch |err| switch (err) {
            error.OutOfMemory, error.WriteFailed, error.Canceled => return err,
            else => blk: {
                // No submitted payloads or tokens belong in logs.
                std.log.warn("event=auth_rejected error={s}", .{@errorName(err)});
                const status: std.http.Status = switch (err) {
                    error.InvalidCsrf, error.InvalidSetup, error.InvalidChallenge, error.PasskeyVerificationFailed, error.InvalidUserHandle => .forbidden,
                    error.RecentSignInRequired => .unauthorized,
                    error.LastPasskey, error.TooManyPasskeys => .conflict,
                    error.BodyTooLarge => .payload_too_large,
                    error.UnsupportedContentType => .unsupported_media_type,
                    error.AuthStateInvalid, error.DatabaseBusy, error.SqliteStepFailed, error.SqlitePrepareFailed => .service_unavailable,
                    else => .bad_request,
                };
                const message = switch (err) {
                    error.InvalidSetup => "This setup link has expired or has already been used. Request a new link from the server administrator.",
                    error.InvalidChallenge => "This passkey request expired or was already used. Try again.",
                    error.RecentSignInRequired => "Confirm with your passkey again before changing security settings.",
                    error.LastPasskey => "Add another passkey before removing your last one.",
                    error.TooManyPasskeys => "Remove an unused passkey before adding another. The limit is 16.",
                    error.InvalidLabel => "Give the passkey a name between 1 and 64 characters.",
                    error.InvalidCsrf => "This page is out of date. Reload it and try again.",
                    error.PasskeyVerificationFailed, error.InvalidUserHandle => "The passkey could not be verified. Use a passkey saved for this dbui address and try again.",
                    else => "The request could not be completed. Reload the page and try again.",
                };
                if (!public_api and !(std.mem.endsWith(u8, path, "/options") or std.mem.endsWith(u8, path, "/verify"))) {
                    try send(ctx, try views.security(ctx.arena, &store, session.?, message, at), status, "text/html; charset=utf-8", null);
                    break :blk status;
                }
                break :blk try jsonError(ctx, status, message);
            },
        };
        return .{ .responded = status };
    }
    // Every database route, including unknown paths and direct POSTs, passes
    // through this gate before introspection or SQL can run.
    if (method != .GET and method != .HEAD and !is(request.header(ctx.request, "origin") orelse "", settings.origin)) {
        return .{ .responded = try jsonError(ctx, .forbidden, "Reload dbui and try again from its own address.") };
    }
    return .{ .allowed = session };
}

const Payload = struct {
    challenge_id: []const u8 = "",
    credential_id: []const u8 = "",
    client_data_json: []const u8 = "",
    attestation_object: []const u8 = "",
    authenticator_data: []const u8 = "",
    signature: []const u8 = "",
    user_handle: ?[]const u8 = null,
    label: []const u8 = "My passkey",
};

fn authRoute(ctx: *web.RequestContext, settings: config.Auth, store: *Store, session: ?Session, path: []const u8) !std.http.Status {
    const is_api = std.mem.endsWith(u8, path, "/options") or std.mem.endsWith(u8, path, "/verify");
    const content_type = request.header(ctx.request, "content-type") orelse "";
    const mime = std.mem.trim(u8, content_type[0 .. std.mem.indexOfScalar(u8, content_type, ';') orelse content_type.len], " \t");
    const csrf_header = try ctx.arena.dupe(u8, request.header(ctx.request, "x-dbui-csrf") orelse "");
    const bootstrap = try ctx.arena.dupe(u8, request.header(ctx.request, "x-dbui-setup") orelse "");
    const ceremony = try ctx.arena.dupe(u8, cookie(ctx, ceremonyCookie(settings)) orelse "");
    // Header slices point into the HTTP read buffer. Copy before body reading.
    if (!std.ascii.eqlIgnoreCase(mime, if (is_api) "application/json" else "application/x-www-form-urlencoded")) return error.UnsupportedContentType;
    const body = try request.readBodyAlloc(ctx.arena, ctx.request, if (is_api) 256 * 1024 else 16 * 1024);
    const at = store_mod.now(ctx.io);
    if (!is_api) {
        const current = session orelse return error.InvalidCsrf;
        const fields = try params.parseFormLimited(ctx.arena, body, 4096);
        if (!csrfValid(current.csrf, fields.get("csrf_token") orelse "")) return error.InvalidCsrf;
        if (is(path, "/auth/logout")) {
            try store.exec("DELETE FROM sessions WHERE hash=?", .{current.hash});
            try redirect(ctx, "/login", try sessionHeader(ctx, settings, "", 0));
            return .see_other;
        }
        if (is(path, "/auth/sessions/revoke")) {
            try requireRecent(current, at);
            try store.exec("DELETE FROM sessions WHERE hash<>?", .{current.hash});
            try redirect(ctx, "/security?revoked=1", null);
            return .see_other;
        }
        const id = std.fmt.parseInt(i64, fields.get("id") orelse "", 10) catch return error.InvalidPasskey;
        if (is(path, "/auth/passkey/rename")) {
            const label = try validLabel(fields.get("label") orelse "");
            try store.exec("UPDATE passkeys SET label=? WHERE id=?", .{ label, id });
            if (store.db.changes() != 1) return error.InvalidPasskey;
            try redirect(ctx, "/security?saved=1", null);
            return .see_other;
        }
        if (is(path, "/auth/passkey/remove")) {
            try requireRecent(current, at);
            try store.db.exec("BEGIN IMMEDIATE");
            errdefer store.db.exec("ROLLBACK") catch {};
            if (try store.count("SELECT count(*) FROM passkeys", .{}) <= 1) return error.LastPasskey;
            try store.exec("DELETE FROM passkeys WHERE id=?", .{id});
            if (store.db.changes() != 1) return error.InvalidPasskey;
            try store.db.exec("COMMIT");
            if (id == current.credential) {
                try redirect(ctx, "/login", try sessionHeader(ctx, settings, "", 0));
            } else try redirect(ctx, "/security?removed=1", null);
            return .see_other;
        }
        return try jsonError(ctx, .not_found, "This action does not exist.");
    }

    const input = try std.json.parseFromSliceLeaky(Payload, ctx.arena, body, .{});
    const setup = std.mem.startsWith(u8, path, "/auth/setup/");
    const login = std.mem.startsWith(u8, path, "/auth/login/");
    const add = std.mem.startsWith(u8, path, "/auth/passkeys/");
    if (!setup and !login and !add) return try jsonError(ctx, .not_found, "This action does not exist.");
    if (add) {
        const current = session orelse return error.InvalidCsrf;
        if (!csrfValid(current.csrf, csrf_header)) return error.InvalidCsrf;
        try requireRecent(current, at);
    }
    if (setup and !try store.setupValid(bootstrap, at)) return error.InvalidSetup;
    const authorization: []const u8 = if (setup) &(store_mod.tokenHash(bootstrap)) else if (add) session.?.hash else "";
    const purpose: []const u8 = if (setup) "setup" else if (login) "login" else "add";
    if (std.mem.endsWith(u8, path, "/options")) {
        if (!login and try store.count("SELECT count(*) FROM passkeys", .{}) >= 16) return error.TooManyPasskeys;
        try store.cleanup(at);
        // Keep pending ceremonies bounded even for authorized clients.
        try store.exec("DELETE FROM challenges WHERE id IN (SELECT id FROM challenges ORDER BY expires DESC LIMIT -1 OFFSET 127)", .{});
        const challenge = store_mod.randomToken(ctx.io);
        const binding = store_mod.randomToken(ctx.io);
        const binding_hash = store_mod.tokenHash(&binding);
        try store.exec("INSERT INTO challenges VALUES (?,?,?,?,?)", .{ &challenge, purpose, &binding_hash, authorization, at + store_mod.challenge_seconds });
        const handle = try userHandle(ctx, store);
        var out: std.Io.Writer.Allocating = .init(ctx.arena);
        const w = &out.writer;
        try w.print("{{\"challenge_id\":\"{s}\",\"publicKey\":{{\"challenge\":\"{s}\",\"timeout\":300000,", .{ challenge, challenge });
        if (login) {
            try w.writeAll("\"rpId\":");
            try std.json.Stringify.value(settings.rpId(), .{}, w);
            try w.writeAll(",\"userVerification\":\"required\"");
        } else {
            try w.writeAll("\"rp\":{\"name\":\"dbui\",\"id\":");
            try std.json.Stringify.value(settings.rpId(), .{}, w);
            try w.writeAll("},\"user\":{\"name\":\"admin\",\"displayName\":\"dbui administrator\",\"id\":");
            try std.json.Stringify.value(handle, .{}, w);
            try w.writeAll("},\"pubKeyCredParams\":[{\"type\":\"public-key\",\"alg\":-7},{\"type\":\"public-key\",\"alg\":-257}],\"authenticatorSelection\":{\"residentKey\":\"required\",\"requireResidentKey\":true,\"userVerification\":\"required\"},\"attestation\":\"none\",\"extensions\":{\"credProps\":true},\"excludeCredentials\":[");
            var existing = try store.prepare("SELECT credential_id FROM passkeys ORDER BY id", .{});
            defer existing.deinit();
            var first = true;
            while (try existing.step() == .row) {
                if (!first) try w.writeByte(',');
                first = false;
                try w.writeAll("{\"type\":\"public-key\",\"id\":");
                try std.json.Stringify.value(existing.columnText(0), .{}, w);
                try w.writeByte('}');
            }
            try w.writeByte(']');
        }
        try w.writeAll("}}");
        const cookie_header = try cookieHeader(ctx, ceremonyCookie(settings), &binding, store_mod.challenge_seconds, settings.secure());
        try send(ctx, out.written(), .ok, "application/json; charset=utf-8", cookie_header);
        return .ok;
    }

    if (!store_mod.validToken(input.challenge_id) or !store_mod.validToken(ceremony)) return error.InvalidChallenge;
    const binding_hash = store_mod.tokenHash(ceremony);
    // DELETE RETURNING consumes a challenge even if the payload is invalid.
    // Browser binding, purpose and authorization are checked atomically.
    var challenge = try store.prepare("DELETE FROM challenges WHERE id=? AND purpose=? AND binding=? AND authorization=? AND expires>? RETURNING id", .{ input.challenge_id, purpose, &binding_hash, authorization, at });
    const found = try challenge.step() == .row;
    if (found) _ = try challenge.step();
    challenge.deinit();
    if (!found) return error.InvalidChallenge;
    if (login) {
        const handle = try userHandle(ctx, store);
        if (input.user_handle == null or !is(input.user_handle.?, handle)) return error.InvalidUserHandle;
        var credential = try store.prepare("SELECT id,public_key,sign_count,backup_eligible FROM passkeys WHERE credential_id=?", .{input.credential_id});
        defer credential.deinit();
        if (try credential.step() != .row) return error.PasskeyVerificationFailed;
        const id = credential.columnInteger(0);
        const verified = passkeys.verifyAuthentication(ctx.arena, .{
            .authenticator_data = input.authenticator_data,
            .client_data_json = input.client_data_json,
            .signature = input.signature,
            .public_key = credential.columnText(1),
            .expected_challenge = input.challenge_id,
            .expected_origin = settings.origin,
            .rp_id = settings.rpId(),
            .known_sign_count = @intCast(credential.columnInteger(2)),
        }) catch return error.PasskeyVerificationFailed;
        if (verified.backup_eligible != (credential.columnInteger(3) != 0)) return error.PasskeyVerificationFailed;
        try store.db.exec("BEGIN IMMEDIATE");
        errdefer store.db.exec("ROLLBACK") catch {};
        // A concurrent CLI recovery must not revive a credential/session.
        try store.exec("UPDATE passkeys SET sign_count=?,backup_state=?,last_used=? WHERE id=?", .{ verified.recommended_sign_count, verified.backup_state, at, id });
        if (store.db.changes() != 1) return error.PasskeyVerificationFailed;
        const token = try store.issueSession(ctx.io, id, session);
        try store.db.exec("COMMIT");
        try send(ctx, "{\"ok\":true}", .ok, "application/json; charset=utf-8", try sessionHeader(ctx, settings, &token, store_mod.session_seconds));
        return .ok;
    }
    const label = try validLabel(input.label);
    const verified = passkeys.verifyRegistration(ctx.arena, .{
        .attestation_object = input.attestation_object,
        .client_data_json = input.client_data_json,
        .expected_challenge = input.challenge_id,
        .expected_origin = settings.origin,
        .rp_id = settings.rpId(),
    }) catch return error.PasskeyVerificationFailed;
    if (!is(verified.credential_id, input.credential_id)) return error.PasskeyVerificationFailed;
    try store.db.exec("BEGIN IMMEDIATE");
    errdefer store.db.exec("ROLLBACK") catch {};
    if (setup and !try store.setupValid(bootstrap, at)) return error.InvalidSetup;
    if (add and try store.count("SELECT count(*) FROM sessions WHERE hash=? AND expires>?", .{ session.?.hash, at }) != 1) return error.InvalidCsrf;
    if (try store.count("SELECT count(*) FROM passkeys", .{}) >= 16) return error.TooManyPasskeys;
    try store.exec("INSERT INTO passkeys (credential_id,public_key,label,sign_count,backup_eligible,backup_state,created,last_used) VALUES (?,?,?,?,?,?,?,?)", .{ verified.credential_id, verified.public_key, label, verified.sign_count, verified.backup_eligible, verified.backup_state, at, at });
    const id = store.db.lastInsertRowId();
    if (setup) {
        try store.db.exec("DELETE FROM bootstrap");
        try store.db.exec("DELETE FROM challenges");
    }
    const token: ?[43]u8 = if (setup) try store.issueSession(ctx.io, id, session) else null;
    try store.db.exec("COMMIT");
    try send(ctx, "{\"ok\":true}", .created, "application/json; charset=utf-8", if (token) |value| try sessionHeader(ctx, settings, &value, store_mod.session_seconds) else null);
    return .created;
}

fn userHandle(ctx: *web.RequestContext, store: *Store) ![]const u8 {
    var statement = try store.prepare("SELECT value FROM metadata WHERE key='user_handle'", .{});
    defer statement.deinit();
    if (try statement.step() != .row) return error.AuthStateInvalid;
    return ctx.arena.dupe(u8, statement.columnText(0));
}

fn validLabel(label: []const u8) ![]const u8 {
    const trimmed = std.mem.trim(u8, label, " \t\r\n");
    if (trimmed.len == 0 or trimmed.len > 256 or !std.unicode.utf8ValidateSlice(trimmed)) return error.InvalidLabel;
    if (try std.unicode.utf8CountCodepoints(trimmed) > 64) return error.InvalidLabel;
    for (trimmed) |byte| if (byte < 32 or byte == 127) return error.InvalidLabel;
    return trimmed;
}

fn requireRecent(session: Session, at: i64) !void {
    if (at - session.created > store_mod.recent_seconds) return error.RecentSignInRequired;
}

fn csrfValid(expected: [64]u8, supplied: []const u8) bool {
    return supplied.len == 64 and std.crypto.timing_safe.eql([64]u8, expected, supplied[0..64].*);
}

fn is(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

pub fn safeNext(value: []const u8) []const u8 {
    if (value.len == 0 or value.len > 8192 or value[0] != '/' or std.mem.startsWith(u8, value, "//") or std.mem.indexOfScalar(u8, value, '\\') != null) return "/";
    for (value) |byte| if (byte < 32 or byte == 127) return "/";
    if (std.mem.startsWith(u8, value, "/login") or std.mem.startsWith(u8, value, "/setup") or std.mem.startsWith(u8, value, "/auth/")) return "/";
    return value;
}

fn encodeComponent(allocator: std.mem.Allocator, value: []const u8) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    const digits = "0123456789ABCDEF";
    for (value) |byte| {
        if (std.ascii.isAlphanumeric(byte) or byte == '-' or byte == '_' or byte == '.' or byte == '~') try out.writer.writeByte(byte) else {
            try out.writer.writeByte('%');
            try out.writer.writeByte(digits[byte >> 4]);
            try out.writer.writeByte(digits[byte & 15]);
        }
    }
    return out.toOwnedSlice();
}

fn cookie(ctx: *web.RequestContext, name: []const u8) ?[]const u8 {
    var parts = std.mem.splitScalar(u8, request.header(ctx.request, "cookie") orelse return null, ';');
    var found: ?[]const u8 = null;
    while (parts.next()) |part| {
        const field = std.mem.trim(u8, part, " \t");
        const equals = std.mem.indexOfScalar(u8, field, '=') orelse continue;
        if (is(field[0..equals], name)) {
            if (found != null) return null;
            found = field[equals + 1 ..];
        }
    }
    return found;
}

fn sessionCookie(settings: config.Auth) []const u8 {
    return if (settings.secure()) "__Host-dbui_session" else "dbui_session";
}

fn ceremonyCookie(settings: config.Auth) []const u8 {
    return if (settings.secure()) "__Host-dbui_ceremony" else "dbui_ceremony";
}

fn sessionHeader(ctx: *web.RequestContext, settings: config.Auth, token: []const u8, max_age: u32) !std.http.Header {
    return cookieHeader(ctx, sessionCookie(settings), token, max_age, settings.secure());
}

fn cookieHeader(ctx: *web.RequestContext, name: []const u8, token: []const u8, max_age: u32, secure: bool) !std.http.Header {
    return .{ .name = "set-cookie", .value = try std.fmt.allocPrint(ctx.arena, "{s}={s}; Path=/; Max-Age={d}; HttpOnly; SameSite=Strict{s}", .{ name, token, max_age, if (secure) @as([]const u8, "; Secure") else "" }) };
}

fn send(ctx: *web.RequestContext, body: []const u8, status: std.http.Status, content_type: []const u8, extra: ?std.http.Header) !void {
    var all = response.Headers{};
    try all.append(&headers);
    if (extra) |header| try all.add(header.name, header.value);
    try response.respond(ctx.request, body, .{ .status = status, .content_type = content_type, .cache_control = "no-store", .extra_headers = all.slice() });
}

fn redirect(ctx: *web.RequestContext, location: []const u8, extra: ?std.http.Header) !void {
    var all = response.Headers{};
    try all.append(&headers);
    if (extra) |header| try all.add(header.name, header.value);
    try response.redirect(ctx.request, location, .see_other, all.slice());
}

fn jsonError(ctx: *web.RequestContext, status: std.http.Status, message: []const u8) !std.http.Status {
    ctx.request.head.keep_alive = false;
    var output: std.Io.Writer.Allocating = .init(ctx.arena);
    try std.json.Stringify.value(.{ .@"error" = message }, .{}, &output.writer);
    try send(ctx, output.written(), status, "application/json; charset=utf-8", null);
    return status;
}
