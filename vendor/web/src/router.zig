//! Allocation-free route matching.

const std = @import("std");

pub const max_params = 8;

pub const Param = struct {
    name: []const u8,
    value: []const u8,
};

pub const Params = struct {
    items: [max_params]Param = undefined,
    len: usize = 0,

    pub fn get(self: Params, name: []const u8) ?[]const u8 {
        for (self.items[0..self.len]) |item| {
            if (std.mem.eql(u8, item.name, name)) return item.value;
        }
        return null;
    }
};

pub fn Match(comptime Route: type) type {
    return struct {
        route: *const Route,
        params: Params,
    };
}

pub fn Result(comptime Route: type) type {
    return union(enum) {
        matched: Match(Route),
        method_not_allowed,
        not_found,
    };
}

/// Route values need `method: std.http.Method` and `pattern: []const u8`
/// fields. A `:name` segment captures one non-empty segment. A final `*name`
/// segment captures the remaining non-empty path.
pub fn match(comptime Route: type, routes: []const Route, method: std.http.Method, path: []const u8) Result(Route) {
    var path_exists = false;
    for (routes) |*route| {
        const params = matchPattern(route.pattern, path) orelse continue;
        path_exists = true;
        if (route.method == method) return .{ .matched = .{ .route = route, .params = params } };
    }
    return if (path_exists) .method_not_allowed else .not_found;
}

pub fn matchPattern(pattern_raw: []const u8, path_raw: []const u8) ?Params {
    if (!validPattern(pattern_raw) or !validPath(path_raw)) return null;
    const pattern = normalized(pattern_raw);
    const path = normalized(path_raw);
    if (std.mem.eql(u8, pattern, "/") or std.mem.eql(u8, path, "/")) {
        return if (std.mem.eql(u8, pattern, path)) Params{} else null;
    }

    var patterns = std.mem.splitScalar(u8, pattern[1..], '/');
    var parts = std.mem.splitScalar(u8, path[1..], '/');
    var params = Params{};
    while (patterns.next()) |expected| {
        if (expected.len > 1 and expected[0] == '*') {
            const consumed = path.len - parts.rest().len;
            const remaining = std.mem.trim(u8, path[consumed..], "/");
            if (remaining.len == 0 or params.len == max_params or patterns.next() != null) return null;
            params.items[params.len] = .{ .name = expected[1..], .value = remaining };
            params.len += 1;
            return params;
        }
        const actual = parts.next() orelse return null;
        if (expected.len > 1 and expected[0] == ':') {
            if (actual.len == 0 or params.len == max_params) return null;
            params.items[params.len] = .{ .name = expected[1..], .value = actual };
            params.len += 1;
        } else if (!std.mem.eql(u8, expected, actual)) {
            return null;
        }
    }
    return if (parts.next() == null) params else null;
}

fn normalized(path: []const u8) []const u8 {
    if (path.len > 1) return std.mem.trimEnd(u8, path, "/");
    return path;
}

fn validPattern(pattern: []const u8) bool {
    if (!validPath(pattern)) return false;
    var segments = std.mem.splitScalar(u8, normalized(pattern), '/');
    _ = segments.next();
    while (segments.next()) |segment| {
        if (segment.len == 1 and (segment[0] == ':' or segment[0] == '*')) return false;
        if (segment.len > 1 and segment[0] == '*' and segments.rest().len != 0) return false;
    }
    return true;
}

fn validPath(path: []const u8) bool {
    return path.len > 0 and path[0] == '/' and
        std.mem.indexOfAny(u8, path, "?#\r\n\x00\\") == null and
        std.mem.indexOf(u8, path, "//") == null;
}

/// Patterns are static data, so authoring mistakes fail the build instead of
/// surfacing as runtime "not found". Rejects invalid patterns, capture counts
/// beyond `max_params`, and duplicate (method, pattern) entries.
pub fn validateRoutes(comptime Route: type, comptime routes: []const Route) void {
    if (comptime routeTableDefect(Route, routes)) |defect| @compileError(defect);
}

fn routeTableDefect(comptime Route: type, comptime routes: []const Route) ?[]const u8 {
    @setEvalBranchQuota(routes.len * 10_000 + 10_000);
    for (routes, 0..) |route, index| {
        if (!validPattern(route.pattern)) {
            return "invalid route pattern: \"" ++ route.pattern ++ "\"";
        }
        var captures: usize = 0;
        var segments = std.mem.splitScalar(u8, route.pattern[1..], '/');
        while (segments.next()) |segment| {
            if (segment.len > 1 and (segment[0] == ':' or segment[0] == '*')) captures += 1;
        }
        if (captures > max_params) {
            return "route pattern captures more than max_params segments: \"" ++ route.pattern ++ "\"";
        }
        for (routes[index + 1 ..]) |other| {
            if (route.method == other.method and std.mem.eql(u8, route.pattern, other.pattern)) {
                return "duplicate route: \"" ++ route.pattern ++ "\"";
            }
        }
    }
    return null;
}

test "router distinguishes matches method misses and unknown paths" {
    const Route = struct { method: std.http.Method, pattern: []const u8, id: u8 };
    const routes = [_]Route{
        .{ .method = .GET, .pattern = "/apps", .id = 1 },
        .{ .method = .GET, .pattern = "/apps/:name/deploys", .id = 2 },
        .{ .method = .POST, .pattern = "/apps/:name/deploys", .id = 3 },
    };
    try std.testing.expectEqual(@as(u8, 1), match(Route, &routes, .GET, "/apps").matched.route.id);
    const dynamic = match(Route, &routes, .POST, "/apps/cloudio/deploys/").matched;
    try std.testing.expectEqual(@as(u8, 3), dynamic.route.id);
    try std.testing.expectEqualStrings("cloudio", dynamic.params.get("name").?);
    try std.testing.expect(match(Route, &routes, .DELETE, "/apps/cloudio/deploys") == .method_not_allowed);
    try std.testing.expect(match(Route, &routes, .GET, "/unknown") == .not_found);
}

test "wildcards are final bounded captures" {
    const params = matchPattern("/assets/*path", "/assets/css/app.css").?;
    try std.testing.expectEqualStrings("css/app.css", params.get("path").?);
    try std.testing.expect(matchPattern("/assets/*path/more", "/assets/a/more") == null);
    try std.testing.expect(matchPattern("/assets/*path", "/assets") == null);
}

test "route table validation flags authoring mistakes at comptime" {
    const Route = struct { method: std.http.Method, pattern: []const u8 };
    comptime {
        const good = [_]Route{
            .{ .method = .GET, .pattern = "/" },
            .{ .method = .GET, .pattern = "/a/:b/:c/*rest" },
            .{ .method = .POST, .pattern = "/a/:b/:c" },
        };
        validateRoutes(Route, &good);
        std.debug.assert(routeTableDefect(Route, &good) == null);

        const overflow = [_]Route{
            .{ .method = .GET, .pattern = "/:a/:b/:c/:d/:e/:f/:g/:h/:i" },
        };
        std.debug.assert(routeTableDefect(Route, &overflow) != null);

        const bad_pattern = [_]Route{.{ .method = .GET, .pattern = "/a/*rest/more" }};
        std.debug.assert(routeTableDefect(Route, &bad_pattern) != null);

        const no_slash = [_]Route{.{ .method = .GET, .pattern = "a" }};
        std.debug.assert(routeTableDefect(Route, &no_slash) != null);

        const duplicate = [_]Route{
            .{ .method = .GET, .pattern = "/a" },
            .{ .method = .GET, .pattern = "/a" },
        };
        std.debug.assert(routeTableDefect(Route, &duplicate) != null);
    }
}

test "route paths reject ambiguous separators queries and backslashes" {
    try std.testing.expect(matchPattern("/a/:id", "/a/1?x=2") == null);
    try std.testing.expect(matchPattern("/a/:id", "/a//1") == null);
    try std.testing.expect(matchPattern("/a/:id", "/a\\1") == null);
    try std.testing.expect(matchPattern("/", "/") != null);
}
