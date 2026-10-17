const std = @import("std");
const html = @import("web_html");
const store_mod = @import("auth_store.zig");
const config = @import("config.zig");

fn start(writer: *std.Io.Writer, title: []const u8) !void {
    try html.documentStart(writer, .{
        .title = title,
        .head = .audited("<link rel=\"icon\" href=\"data:,\"><link rel=\"stylesheet\" href=\"/assets/app.css?v=6\"><script src=\"/assets/auth.js?v=1\" defer></script>"),
    });
    try writer.writeAll("<header class=\"topbar\"><a class=\"brand\" href=\"/\">dbui</a></header>");
}

pub fn entry(allocator: std.mem.Allocator, settings: config.Auth, setup: bool, enrolled: bool, next: []const u8) ![]u8 {
    var output: std.Io.Writer.Allocating = .init(allocator);
    const w = &output.writer;
    try start(w, if (setup) "Create a passkey · dbui" else "Sign in · dbui");
    try w.writeAll("<main class=\"auth-main\"><section class=\"auth-panel\"><svg class=\"auth-key\" width=\"40\" height=\"40\" viewBox=\"0 0 24 24\" fill=\"none\" stroke=\"currentColor\" stroke-width=\"1.5\" aria-hidden=\"true\"><circle cx=\"8\" cy=\"9\" r=\"5\"/><path d=\"m12 12 8 8m-4-4 3-3m-6 0 3-3\"/></svg><h1>");
    try w.writeAll(if (setup) "Create your passkey" else "Sign in to dbui");
    try w.writeAll("</h1><p class=\"auth-origin\">");
    try html.text(w, settings.host());
    try w.writeAll("</p>");
    if (setup) {
        try w.writeAll("<p>Save a passkey in Apple Passwords or your preferred password manager. Use Face ID, Touch ID, or your device passcode to sign in.</p><form data-passkey=\"setup\"><label for=\"passkey-label\">Passkey name</label><input id=\"passkey-label\" name=\"label\" value=\"My passkey\" maxlength=\"64\" required autocomplete=\"off\"><button class=\"button button--primary\" type=\"submit\">Create a passkey</button></form><p class=\"auth-hint\">This setup link expires after one hour and can be used once.</p>");
    } else if (enrolled) {
        try w.writeAll("<p>Use Face ID, Touch ID, your device passcode, or a security key.</p><form data-passkey=\"login\" data-next=\"");
        try html.attribute(w, next);
        try w.writeAll("\"><button class=\"button button--primary\" type=\"submit\">Sign in with passkey</button></form><p class=\"auth-hint\">Your passkey may be available on another device through your password manager.</p>");
    } else {
        try w.writeAll("<p>Open your private setup link to create the first passkey.</p><p class=\"auth-hint\">If the link has expired, request a new one from the server administrator.</p>");
    }
    try w.writeAll("<div class=\"notice notice--error\" data-auth-error role=\"alert\" hidden></div><noscript><p class=\"notice\">Passkey sign-in needs JavaScript. Enable it in your browser and reload this page.</p></noscript>");
    if (setup) try w.writeAll("<a href=\"/login\">Already have a passkey? Sign in</a>");
    try w.writeAll("</section></main>");
    try html.documentEnd(w);
    return output.toOwnedSlice();
}

pub fn security(allocator: std.mem.Allocator, store: *store_mod.Store, session: store_mod.Session, message: ?[]const u8, at: i64) ![]u8 {
    var output: std.Io.Writer.Allocating = .init(allocator);
    const w = &output.writer;
    try start(w, "Sign-in & security · dbui");
    try w.writeAll("<main class=\"security-main\"><a href=\"/\">Back to databases</a><header class=\"page-header\"><div><h1>Sign-in &amp; security</h1><p>Manage the passkeys and sessions that can access dbui.</p></div></header>");
    if (message) |text| {
        try w.writeAll("<p class=\"notice\" role=\"status\">");
        try html.text(w, text);
        try w.writeAll("</p>");
    }
    if (at - session.created > store_mod.recent_seconds) try w.writeAll("<p class=\"notice\">For security, <a href=\"/login?next=%2Fsecurity\">confirm with your passkey</a> before adding or removing passkeys or signing out other sessions.</p>");
    try w.writeAll("<section class=\"security-section\"><h2>Passkeys</h2><p>Apple Passwords can sync your passkey across your Apple devices. Keep another passkey in a separate password manager or security key for recovery.</p><div class=\"passkey-list\">");
    var keys = try store.prepare("SELECT id,label,created,last_used FROM passkeys ORDER BY created,id", .{});
    defer keys.deinit();
    const count = try store.count("SELECT count(*) FROM passkeys", .{});
    while (try keys.step() == .row) {
        const id = keys.columnInteger(0);
        try w.writeAll("<article class=\"passkey-row\"><div><h3>");
        try html.text(w, keys.columnText(1));
        try w.writeAll("</h3><p class=\"meta\">Created ");
        try time(w, keys.columnInteger(2));
        if (keys.columnType(3) != @import("sqlite.zig").raw.SQLITE_NULL) {
            try w.writeAll(" · Last used ");
            try time(w, keys.columnInteger(3));
        }
        if (id == session.credential) try w.writeAll(" · This session");
        try w.writeAll("</p></div><details class=\"passkey-actions\"><summary>Manage</summary><form method=\"post\" action=\"/auth/passkey/rename\">");
        try fields(w, session, id);
        try w.print("<label for=\"label-{d}\">Passkey name</label><input id=\"label-{d}\" name=\"label\" maxlength=\"64\" required value=\"", .{ id, id });
        try html.attribute(w, keys.columnText(1));
        try w.writeAll("\"><button class=\"button\" type=\"submit\">Save name</button></form>");
        if (count > 1) {
            try w.writeAll("<form method=\"post\" action=\"/auth/passkey/remove\" data-remove-passkey>");
            try fields(w, session, id);
            try w.writeAll("<p>Removing this passkey also signs out its sessions.</p><button class=\"button button--danger\" type=\"submit\">Remove passkey</button></form>");
        } else try w.writeAll("<p>Add another passkey before removing this one.</p>");
        try w.writeAll("</details></article>");
    }
    try w.writeAll("</div><form class=\"add-passkey\" data-passkey=\"add\" data-csrf=\"");
    try html.attribute(w, &session.csrf);
    try w.writeAll("\"><label for=\"new-passkey-name\">New passkey name</label><div class=\"auth-inline\"><input id=\"new-passkey-name\" name=\"label\" placeholder=\"e.g. Backup security key\" maxlength=\"64\" required><button class=\"button button--primary\" type=\"submit\">Add a passkey</button></div></form><div class=\"notice notice--error\" data-auth-error role=\"alert\" hidden></div></section><section class=\"security-section\"><h2>Sessions</h2><p>");
    const sessions = try store.count("SELECT count(*) FROM sessions WHERE expires>?", .{at});
    try w.print("{d} active session{s}. Sessions expire 12 hours after sign-in.</p><p class=\"meta\">This session expires ", .{ sessions, if (sessions == 1) @as([]const u8, "") else "s" });
    try time(w, session.expires);
    try w.writeAll(" UTC.</p><div class=\"auth-inline\"><form method=\"post\" action=\"/auth/logout\">");
    try fields(w, session, null);
    try w.writeAll("<button class=\"button\" type=\"submit\">Sign out</button></form>");
    if (sessions > 1) {
        try w.writeAll("<form method=\"post\" action=\"/auth/sessions/revoke\">");
        try fields(w, session, null);
        try w.writeAll("<button class=\"button\" type=\"submit\">Sign out other sessions</button></form>");
    }
    try w.writeAll("</div></section><section class=\"security-section\"><h2>Lost access?</h2><p>Try your synced passkey on another device or use a backup passkey. If all passkeys are lost, the server administrator can issue a new setup link.</p></section></main>");
    try html.documentEnd(w);
    return output.toOwnedSlice();
}

fn fields(w: *std.Io.Writer, session: store_mod.Session, id: ?i64) !void {
    try w.writeAll("<input type=\"hidden\" name=\"csrf_token\" value=\"");
    try html.attribute(w, &session.csrf);
    try w.writeAll("\">");
    if (id) |value| try w.print("<input type=\"hidden\" name=\"id\" value=\"{d}\">", .{value});
}

fn time(w: *std.Io.Writer, timestamp: i64) !void {
    const epoch: std.time.epoch.EpochSeconds = .{ .secs = @intCast(@max(0, timestamp)) };
    const day = epoch.getEpochDay();
    const year = day.calculateYearDay();
    const month = year.calculateMonthDay();
    const seconds = epoch.getDaySeconds();
    try w.print("{d}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2}", .{ year.year, month.month.numeric(), month.day_index + 1, seconds.getHoursIntoDay(), seconds.getMinutesIntoHour() });
}
