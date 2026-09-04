//! Writer-first, context-safe HTML rendering.
//!
//! Application renderers own their markup and typed view models. This module
//! only owns the security-sensitive output contexts and a minimal document
//! envelope.

const std = @import("std");

pub const Error = error{ UnsafeUrl, InvalidAttributeName };

pub const Representation = enum {
    document,
    fragment,
};

/// Markup that has been reviewed or produced by a renderer that already
/// applies the correct escaping at every interpolation point.
///
/// Constructing this value is intentionally noisy. Untrusted strings must use
/// `text`, `attribute`, `urlAttribute`, or `scriptData` instead.
pub const TrustedHtml = struct {
    bytes: []const u8,

    pub fn audited(bytes: []const u8) TrustedHtml {
        return .{ .bytes = bytes };
    }
};

pub const DocumentOptions = struct {
    lang: []const u8 = "en",
    html_class: ?[]const u8 = null,
    title: []const u8,
    description: ?[]const u8 = null,
    canonical_url: ?[]const u8 = null,
    head: TrustedHtml = .{ .bytes = "" },
    body_class: ?[]const u8 = null,
};

/// Escape an untrusted value for an HTML text node.
pub fn text(writer: *std.Io.Writer, value: []const u8) !void {
    for (value) |byte| switch (byte) {
        '&' => try writer.writeAll("&amp;"),
        '<' => try writer.writeAll("&lt;"),
        '>' => try writer.writeAll("&gt;"),
        '"' => try writer.writeAll("&quot;"),
        '\'' => try writer.writeAll("&#39;"),
        0...8, 11, 12, 14...31, 127 => try writeControlReference(writer, byte),
        else => try writer.writeByte(byte),
    };
}

/// Escape an untrusted value inside a quoted HTML attribute.
pub fn attribute(writer: *std.Io.Writer, value: []const u8) !void {
    for (value) |byte| switch (byte) {
        '&' => try writer.writeAll("&amp;"),
        '<' => try writer.writeAll("&lt;"),
        '>' => try writer.writeAll("&gt;"),
        '"' => try writer.writeAll("&quot;"),
        '\'' => try writer.writeAll("&#39;"),
        0...31, 127 => try writeControlReference(writer, byte),
        else => try writer.writeByte(byte),
    };
}

/// Escape a URL-valued attribute and reject executable or ambiguous schemes.
///
/// Relative references, fragments, and the explicit HTTP(S), mail, and
/// telephone schemes are accepted. Applications that intentionally need a
/// different scheme should validate it and use `attribute` explicitly.
pub fn urlAttribute(writer: *std.Io.Writer, value: []const u8) !void {
    if (!isSafeUrl(value)) return Error.UnsafeUrl;
    try attribute(writer, value);
}

pub fn isSafeUrl(value: []const u8) bool {
    if (value.len == 0) return true;
    for (value) |byte| {
        if (byte <= 0x20 or byte == 0x7f) return false;
    }
    if (value[0] == '/' or value[0] == '#' or value[0] == '?' or value[0] == '.') return true;

    const colon = std.mem.indexOfScalar(u8, value, ':') orelse return true;
    const scheme = value[0..colon];
    if (scheme.len == 0) return false;
    if (!std.ascii.isAlphabetic(scheme[0])) return false;
    for (scheme[1..]) |byte| {
        if (!(std.ascii.isAlphanumeric(byte) or byte == '+' or byte == '-' or byte == '.')) return false;
    }
    return std.ascii.eqlIgnoreCase(scheme, "http") or
        std.ascii.eqlIgnoreCase(scheme, "https") or
        std.ascii.eqlIgnoreCase(scheme, "mailto") or
        std.ascii.eqlIgnoreCase(scheme, "tel");
}

/// Write already-encoded JSON or other script data so it cannot terminate its
/// containing script element. This does not JSON-encode arbitrary Zig values.
pub fn scriptData(writer: *std.Io.Writer, encoded: []const u8) !void {
    var index: usize = 0;
    while (index < encoded.len) {
        const byte = encoded[index];
        switch (byte) {
            '<' => try writer.writeAll("\\u003C"),
            '>' => try writer.writeAll("\\u003E"),
            '&' => try writer.writeAll("\\u0026"),
            else => {
                if (index + 2 < encoded.len and
                    byte == 0xe2 and
                    encoded[index + 1] == 0x80 and
                    (encoded[index + 2] == 0xa8 or encoded[index + 2] == 0xa9))
                {
                    try writer.writeAll(if (encoded[index + 2] == 0xa8) "\\u2028" else "\\u2029");
                    index += 2;
                } else {
                    try writer.writeByte(byte);
                }
            },
        }
        index += 1;
    }
}

pub fn trusted(writer: *std.Io.Writer, markup: TrustedHtml) !void {
    try writer.writeAll(markup.bytes);
}

/// Begin a complete semantic HTML document. Call `documentEnd` after the
/// application renderer has written the body.
pub fn documentStart(writer: *std.Io.Writer, options: DocumentOptions) !void {
    try writer.writeAll("<!doctype html>\n<html lang=\"");
    try attribute(writer, options.lang);
    try writer.writeByte('"');
    if (options.html_class) |class| {
        try writer.writeAll(" class=\"");
        try attribute(writer, class);
        try writer.writeByte('"');
    }
    try writer.writeAll(">\n<head>\n<meta charset=\"utf-8\">\n");
    try writer.writeAll("<meta name=\"viewport\" content=\"width=device-width,initial-scale=1\">\n<title>");
    try text(writer, options.title);
    try writer.writeAll("</title>\n");
    if (options.description) |description| {
        try writer.writeAll("<meta name=\"description\" content=\"");
        try attribute(writer, description);
        try writer.writeAll("\">\n");
    }
    if (options.canonical_url) |url| {
        try writer.writeAll("<link rel=\"canonical\" href=\"");
        try urlAttribute(writer, url);
        try writer.writeAll("\">\n");
    }
    try trusted(writer, options.head);
    try writer.writeAll("</head>\n<body");
    if (options.body_class) |class| {
        try writer.writeAll(" class=\"");
        try attribute(writer, class);
        try writer.writeByte('"');
    }
    try writer.writeAll(">\n");
}

pub fn documentEnd(writer: *std.Io.Writer) !void {
    try writer.writeAll("\n</body>\n</html>\n");
}

pub fn optionalAttribute(writer: *std.Io.Writer, name: []const u8, value: ?[]const u8) !void {
    if (value) |present| {
        if (!validAttributeName(name)) return Error.InvalidAttributeName;
        try writer.writeByte(' ');
        try writer.writeAll(name);
        try writer.writeAll("=\"");
        try attribute(writer, present);
        try writer.writeByte('"');
    }
}

pub fn booleanAttribute(writer: *std.Io.Writer, name: []const u8, enabled: bool) !void {
    if (!enabled) return;
    if (!validAttributeName(name)) return Error.InvalidAttributeName;
    try writer.writeByte(' ');
    try writer.writeAll(name);
}

/// A dynamically supplied attribute name is an injection vector, so this is an
/// error contract that must hold in ReleaseFast too, never an assert. Names
/// are validated before any byte is written.
fn validAttributeName(name: []const u8) bool {
    if (name.len == 0) return false;
    for (name) |byte| {
        if (!(std.ascii.isAlphanumeric(byte) or byte == '-' or byte == '_' or byte == ':')) {
            return false;
        }
    }
    return true;
}

fn writeControlReference(writer: *std.Io.Writer, byte: u8) !void {
    const hex = "0123456789ABCDEF";
    try writer.writeAll("&#x");
    try writer.writeByte(hex[byte >> 4]);
    try writer.writeByte(hex[byte & 0x0f]);
    try writer.writeByte(';');
}

test "text and attribute escaping cover markup and control bytes" {
    var storage: [512]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&storage);
    try text(&writer, "<script x=\"'\">&\x00\n");
    try writer.writeByte('|');
    try attribute(&writer, "<script x=\"'\">&\x00\n");
    try std.testing.expectEqualStrings(
        "&lt;script x=&quot;&#39;&quot;&gt;&amp;&#x00;\n|" ++
            "&lt;script x=&quot;&#39;&quot;&gt;&amp;&#x00;&#x0A;",
        writer.buffered(),
    );
}

test "URL attributes reject executable and obscured schemes" {
    const accepted = [_][]const u8{
        "",
        "/account?tab=a&b=1",
        "../page",
        "#details",
        "https://example.com/a",
        "HTTP://example.com",
        "mailto:hello@example.com",
        "tel:+49123",
    };
    for (accepted) |value| try std.testing.expect(isSafeUrl(value));

    const rejected = [_][]const u8{
        "javascript:alert(1)",
        "JaVaScRiPt:alert(1)",
        "data:text/html,<script>",
        "vbscript:msgbox(1)",
        "java\nscript:alert(1)",
        " https://example.com",
        "1bad:scheme",
    };
    for (rejected) |value| try std.testing.expect(!isSafeUrl(value));
}

test "script data cannot terminate its element" {
    var storage: [256]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&storage);
    try scriptData(&writer, "{\"x\":\"</script>&\xe2\x80\xa8\"}");
    try std.testing.expectEqualStrings(
        "{\"x\":\"\\u003C/script\\u003E\\u0026\\u2028\"}",
        writer.buffered(),
    );
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "</script>") == null);
}

test "document envelope escapes metadata and permits explicit audited head markup" {
    var storage: [1024]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&storage);
    try documentStart(&writer, .{
        .lang = "en\"><script>",
        .html_class = "theme-\"dark\"",
        .title = "A & <B>",
        .description = "\"quoted\"",
        .canonical_url = "/a?x=1&y=2",
        .head = .audited("<link rel=\"stylesheet\" href=\"/app.css\">\n"),
        .body_class = "app \"wide\"",
    });
    try writer.writeAll("<main>audited application markup</main>");
    try documentEnd(&writer);
    const rendered = writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, rendered, "<title>A &amp; &lt;B&gt;</title>") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "lang=\"en&quot;&gt;&lt;script&gt;\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "class=\"theme-&quot;dark&quot;\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "href=\"/a?x=1&amp;y=2\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "<link rel=\"stylesheet\" href=\"/app.css\">") != null);
}

test "hostile attribute names are rejected in every build mode and write nothing" {
    const hostile = [_][]const u8{
        "",
        "x y",
        "x=\"y\"",
        "x>",
        "x\x00",
        "x\n",
        "x<img",
    };
    var storage: [128]u8 = undefined;
    for (hostile) |name| {
        var writer: std.Io.Writer = .fixed(&storage);
        try std.testing.expectError(Error.InvalidAttributeName, optionalAttribute(&writer, name, "v"));
        try std.testing.expectEqualStrings("", writer.buffered());
        try std.testing.expectError(Error.InvalidAttributeName, booleanAttribute(&writer, name, true));
        try std.testing.expectEqualStrings("", writer.buffered());
    }
}

test "optional and boolean attributes have explicit syntax" {
    var storage: [128]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&storage);
    try writer.writeAll("<input");
    try optionalAttribute(&writer, "aria-label", "A & B");
    try optionalAttribute(&writer, "data-empty", null);
    try booleanAttribute(&writer, "required", true);
    try booleanAttribute(&writer, "disabled", false);
    try writer.writeByte('>');
    try std.testing.expectEqualStrings("<input aria-label=\"A &amp; B\" required>", writer.buffered());
}
