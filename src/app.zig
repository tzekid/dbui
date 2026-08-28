const std = @import("std");
const web_app = @import("web_app");
const request = @import("web_request");
const response = @import("web_response");
const router = @import("web_router");
const config = @import("config.zig");
const sqlite = @import("sqlite.zig");
const schema = @import("schema.zig");
const browse = @import("browse.zig");
const http_params = @import("http_params.zig");
const query_mod = @import("query.zig");
const mutate = @import("mutate.zig");
const views = @import("views.zig");

const app_css = @embedFile("app_css");
const app_js = @embedFile("app_js");

pub const Context = struct {
    registry: *const config.Registry,
    csrf_token: [64]u8,
    next_request_id: std.atomic.Value(u64) = .init(0),
};

const Handler = enum {
    index,
    health,
    asset_css,
    asset_js,
    overview,
    data,
    schema,
    query_get,
    query_post,
    row,
    row_edit,
    row_update,
    row_delete,
};

const Route = struct {
    method: std.http.Method,
    pattern: []const u8,
    handler: Handler,
};

const routes = [_]Route{
    .{ .method = .GET, .pattern = "/", .handler = .index },
    .{ .method = .GET, .pattern = "/healthz", .handler = .health },
    .{ .method = .GET, .pattern = "/assets/app.css", .handler = .asset_css },
    .{ .method = .GET, .pattern = "/assets/app.js", .handler = .asset_js },
    .{ .method = .GET, .pattern = "/db/:database_id", .handler = .overview },
    .{ .method = .GET, .pattern = "/db/:database_id/data", .handler = .data },
    .{ .method = .GET, .pattern = "/db/:database_id/schema", .handler = .schema },
    .{ .method = .GET, .pattern = "/db/:database_id/query", .handler = .query_get },
    .{ .method = .POST, .pattern = "/db/:database_id/query", .handler = .query_post },
    .{ .method = .GET, .pattern = "/db/:database_id/row", .handler = .row },
    .{ .method = .GET, .pattern = "/db/:database_id/row/edit", .handler = .row_edit },
    .{ .method = .POST, .pattern = "/db/:database_id/row/update", .handler = .row_update },
    .{ .method = .POST, .pattern = "/db/:database_id/row/delete", .handler = .row_delete },
};

const Outcome = struct {
    status: std.http.Status,
    database_id: []const u8 = "-",
    route_name: []const u8,
};

pub fn run(gpa: std.mem.Allocator, io: std.Io, context: *Context) !void {
    const address = try std.Io.net.IpAddress.parse(context.registry.listen.host, context.registry.listen.port);
    var server = try web_app.App.init(gpa, io, .{
        .address = address,
        .workers = 1,
        .queue_depth = 8,
        // A single worker must not wait on an idle browser keep-alive while
        // that same page's CSS/JS connections sit behind it in the queue.
        .connection = .{ .maximum_requests = 1 },
        .healthz = false,
        .on_error = lifecycleError,
    });
    defer server.deinit();
    std.log.info("event=server_start listen={s}:{d} databases={d}", .{
        context.registry.listen.host,
        context.registry.listen.port,
        context.registry.databases.len,
    });
    defer std.log.info("event=server_stop", .{});
    try server.run(*Context, context, handle);
}

fn lifecycleError(err: anyerror, note: []const u8) void {
    std.log.err("event=lifecycle_error error={s} note={s}", .{ @errorName(err), note });
}

fn handle(context: *Context, request_context: *web_app.RequestContext) anyerror!void {
    const id = context.next_request_id.fetchAdd(1, .monotonic) + 1;
    const started = std.Io.Timestamp.now(request_context.io, .awake);
    const outcome = dispatch(context, request_context, id) catch |err| blk: {
        std.log.err("event=request_error request_id={d} error={s}", .{ id, @errorName(err) });
        const body = views.errorPage(
            request_context.arena,
            context.registry,
            null,
            .internal_server_error,
            "Unexpected error",
            "The request could not be completed.",
            id,
        ) catch {
            try request_context.request.respond("internal error", .{ .status = .internal_server_error });
            break :blk Outcome{ .status = .internal_server_error, .route_name = "internal" };
        };
        try respondHtml(request_context.request, body, .internal_server_error);
        break :blk Outcome{ .status = .internal_server_error, .route_name = "internal" };
    };
    const finished = std.Io.Timestamp.now(request_context.io, .awake);
    std.log.info(
        "timestamp={d} request_id={d} method={s} route={s} database={s} status={d} duration_ns={d}",
        .{
            std.Io.Timestamp.now(request_context.io, .real).toSeconds(),
            id,
            @tagName(request_context.request.head.method),
            outcome.route_name,
            outcome.database_id,
            @backingInt(outcome.status),
            @max(0, started.durationTo(finished).nanoseconds),
        },
    );
}

fn dispatch(context: *Context, request_context: *web_app.RequestContext, request_id: u64) !Outcome {
    const target = request.Target.parse(request_context.request.head.target, 16 * 1024) catch {
        try problem(context, request_context, null, .bad_request, "Invalid request", "The request target is invalid.", request_id);
        return .{ .status = .bad_request, .route_name = "invalid" };
    };
    const result = router.match(Route, &routes, request_context.request.head.method, target.path);
    switch (result) {
        .not_found => {
            try problem(context, request_context, null, .not_found, "Not found", "The requested page does not exist.", request_id);
            return .{ .status = .not_found, .route_name = "not_found" };
        },
        .method_not_allowed => {
            try problem(context, request_context, null, .method_not_allowed, "Method not allowed", "This route does not accept that method.", request_id);
            return .{ .status = .method_not_allowed, .route_name = "method_not_allowed" };
        },
        .matched => |matched| {
            const database_id = matched.params.get("database_id") orelse "-";
            return switch (matched.route.handler) {
                .index => index(context, request_context),
                .health => health(request_context),
                .asset_css => asset(request_context, app_css, "text/css; charset=utf-8", "asset_css"),
                .asset_js => asset(request_context, app_js, "text/javascript; charset=utf-8", "asset_js"),
                .overview => overview(context, request_context, target, database_id, request_id),
                .data => data(context, request_context, target, database_id, request_id),
                .schema => schemaPage(context, request_context, target, database_id, request_id),
                .query_get => queryGet(context, request_context, target, database_id, request_id),
                .query_post => queryPost(context, request_context, target, database_id, request_id),
                .row => rowGet(context, request_context, target, database_id, request_id),
                .row_edit => rowEdit(context, request_context, target, database_id, request_id),
                .row_update => rowUpdate(context, request_context, database_id, request_id),
                .row_delete => rowDelete(context, request_context, database_id, request_id),
            };
        },
    }
}

fn index(context: *Context, request_context: *web_app.RequestContext) !Outcome {
    if (context.registry.databases.len == 1) {
        const location = try std.fmt.allocPrint(request_context.arena, "/db/{s}", .{context.registry.databases[0].id});
        try response.redirect(request_context.request, location, .found, &security_headers);
        return .{ .status = .found, .route_name = "database_index" };
    }
    const summaries = try request_context.arena.alloc(views.DatabaseSummary, context.registry.databases.len);
    for (context.registry.databases, 0..) |*configured, index_value| {
        var database = try sqlite.Database.open(request_context.arena, configured.path, configured.mode);
        defer database.deinit();
        const stat = try std.Io.Dir.cwd().statFile(request_context.io, configured.path, .{ .follow_symlinks = true });
        summaries[index_value] = .{
            .database = configured,
            .file_size = stat.size,
            .modified_seconds = stat.mtime.toSeconds(),
            .overview = try schema.loadOverview(request_context.arena, &database),
        };
    }
    const body = try views.databaseIndex(request_context.arena, context.registry, summaries);
    try respondHtml(request_context.request, body, .ok);
    return .{ .status = .ok, .route_name = "database_index" };
}

fn overview(
    context: *Context,
    request_context: *web_app.RequestContext,
    target: request.Target,
    database_id: []const u8,
    request_id: u64,
) !Outcome {
    const configured = context.registry.find(database_id) orelse {
        try problem(context, request_context, null, .not_found, "Database not found", "That database is not configured.", request_id);
        return .{ .status = .not_found, .database_id = database_id, .route_name = "database_overview" };
    };
    var database = sqlite.Database.open(request_context.arena, configured.path, configured.mode) catch |err| {
        std.log.err("event=sqlite_open database={s} error={s}", .{ configured.id, @errorName(err) });
        try problem(context, request_context, configured, .service_unavailable, "Database unavailable", "The configured database cannot be opened right now.", request_id);
        return .{ .status = .service_unavailable, .database_id = configured.id, .route_name = "database_overview" };
    };
    defer database.deinit();
    const parameters = http_params.parseQuery(request_context.arena, target) catch {
        try problem(context, request_context, configured, .bad_request, "Invalid parameters", "The query parameters are malformed or ambiguous.", request_id);
        return .{ .status = .bad_request, .database_id = configured.id, .route_name = "database_overview" };
    };
    const sidebar = loadSidebar(request_context.arena, &database, configured, parameters, null) catch |err| {
        if (err == error.SearchTooLong) {
            try problem(context, request_context, configured, .bad_request, "Search too long", "Object search is limited to 256 bytes.", request_id);
            return .{ .status = .bad_request, .database_id = configured.id, .route_name = "database_overview" };
        }
        return err;
    };
    const stat = try std.Io.Dir.cwd().statFile(request_context.io, configured.path, .{ .follow_symlinks = true });
    const body = try views.databaseOverview(request_context.arena, .{
        .registry = context.registry,
        .database = configured,
        .file_size = stat.size,
        .modified_seconds = stat.mtime.toSeconds(),
        .overview = try schema.loadOverview(request_context.arena, &database),
        .sidebar = sidebar,
    });
    try respondHtml(request_context.request, body, .ok);
    return .{ .status = .ok, .database_id = configured.id, .route_name = "database_overview" };
}

fn data(
    context: *Context,
    request_context: *web_app.RequestContext,
    target: request.Target,
    database_id: []const u8,
    request_id: u64,
) !Outcome {
    const configured = context.registry.find(database_id) orelse {
        try problem(context, request_context, null, .not_found, "Database not found", "That database is not configured.", request_id);
        return .{ .status = .not_found, .database_id = database_id, .route_name = "data" };
    };
    const parameters = http_params.parseQuery(request_context.arena, target) catch {
        try problem(context, request_context, configured, .bad_request, "Invalid parameters", "The query parameters are malformed or ambiguous.", request_id);
        return .{ .status = .bad_request, .database_id = configured.id, .route_name = "data" };
    };
    const object_name = parameters.get("object") orelse {
        try problem(context, request_context, configured, .bad_request, "Missing object", "Choose a table or view from the object list.", request_id);
        return .{ .status = .bad_request, .database_id = configured.id, .route_name = "data" };
    };
    var database = sqlite.Database.open(request_context.arena, configured.path, configured.mode) catch |err| {
        return unavailable(context, request_context, configured, "data", request_id, err);
    };
    defer database.deinit();
    const object = (try schema.findObject(request_context.arena, &database, object_name)) orelse {
        try problem(context, request_context, configured, .not_found, "Missing object", "The selected table or view no longer exists.", request_id);
        return .{ .status = .not_found, .database_id = configured.id, .route_name = "data" };
    };
    const show_internal = std.mem.eql(u8, parameters.get("internal") orelse "", "1");
    if (object.internal and !show_internal) {
        try problem(context, request_context, configured, .not_found, "Missing object", "Reveal internal objects before browsing this object.", request_id);
        return .{ .status = .not_found, .database_id = configured.id, .route_name = "data" };
    }
    const sidebar = loadSidebar(request_context.arena, &database, configured, parameters, object.name) catch |err| {
        if (err == error.SearchTooLong) {
            try problem(context, request_context, configured, .bad_request, "Search too long", "Object search is limited to 256 bytes.", request_id);
            return .{ .status = .bad_request, .database_id = configured.id, .route_name = "data" };
        }
        return err;
    };
    const details = try schema.loadObjectDetails(request_context.arena, &database, object);
    if (details.columns.len > browse.maximum_columns) {
        const body = try views.objectTooWidePage(request_context.arena, context.registry, configured, sidebar, object);
        try respondHtml(request_context.request, body, .ok);
        return .{ .status = .ok, .database_id = configured.id, .route_name = "data" };
    }
    const options = browse.parseOptions(parameters, details.columns) catch |err| {
        const status: std.http.Status = switch (err) {
            error.InvalidFilterOperator, error.InvalidFilterColumn, error.IncompleteFilter, error.BlobFilterUnsupported => .unprocessable_entity,
            else => .bad_request,
        };
        try problem(context, request_context, configured, status, "Invalid data view", browseErrorMessage(err), request_id);
        return .{ .status = status, .database_id = configured.id, .route_name = "data" };
    };
    const result = browse.load(request_context.arena, request_context.io, &database, details, options) catch |err| switch (err) {
        error.DatabaseBusy => {
            try problem(context, request_context, configured, .conflict, "Database busy", "The database is currently busy. No changes were made.", request_id);
            return .{ .status = .conflict, .database_id = configured.id, .route_name = "data" };
        },
        error.QueryInterrupted => {
            try problem(context, request_context, configured, .unprocessable_entity, "Browse interrupted", "Browsing was interrupted after 10 seconds. Refine the view or filter.", request_id);
            return .{ .status = .unprocessable_entity, .database_id = configured.id, .route_name = "data" };
        },
        else => return err,
    };
    const body = try views.dataPage(request_context.arena, .{
        .registry = context.registry,
        .database = configured,
        .sidebar = sidebar,
        .details = details,
        .result = result,
        .deleted_notice = std.mem.eql(u8, parameters.get("deleted") orelse "", "1"),
    });
    try respondHtml(request_context.request, body, .ok);
    return .{ .status = .ok, .database_id = configured.id, .route_name = "data" };
}

fn schemaPage(
    context: *Context,
    request_context: *web_app.RequestContext,
    target: request.Target,
    database_id: []const u8,
    request_id: u64,
) !Outcome {
    const configured = context.registry.find(database_id) orelse {
        try problem(context, request_context, null, .not_found, "Database not found", "That database is not configured.", request_id);
        return .{ .status = .not_found, .database_id = database_id, .route_name = "schema" };
    };
    const parameters = http_params.parseQuery(request_context.arena, target) catch {
        try problem(context, request_context, configured, .bad_request, "Invalid parameters", "The query parameters are malformed or ambiguous.", request_id);
        return .{ .status = .bad_request, .database_id = configured.id, .route_name = "schema" };
    };
    const object_name = parameters.get("object") orelse {
        try problem(context, request_context, configured, .bad_request, "Missing object", "Choose an object from the sidebar.", request_id);
        return .{ .status = .bad_request, .database_id = configured.id, .route_name = "schema" };
    };
    var database = sqlite.Database.open(request_context.arena, configured.path, configured.mode) catch |err| {
        return unavailable(context, request_context, configured, "schema", request_id, err);
    };
    defer database.deinit();
    const object = (try schema.findObject(request_context.arena, &database, object_name)) orelse {
        try problem(context, request_context, configured, .not_found, "Missing object", "The selected object no longer exists.", request_id);
        return .{ .status = .not_found, .database_id = configured.id, .route_name = "schema" };
    };
    const show_internal = std.mem.eql(u8, parameters.get("internal") orelse "", "1");
    if (object.internal and !show_internal) {
        try problem(context, request_context, configured, .not_found, "Missing object", "Reveal internal objects before inspecting this object.", request_id);
        return .{ .status = .not_found, .database_id = configured.id, .route_name = "schema" };
    }
    const sidebar = try loadSidebar(request_context.arena, &database, configured, parameters, object.name);
    const details = try schema.loadObjectDetails(request_context.arena, &database, object);
    const body = try views.schemaPage(request_context.arena, .{
        .registry = context.registry,
        .database = configured,
        .sidebar = sidebar,
        .details = details,
    });
    try respondHtml(request_context.request, body, .ok);
    return .{ .status = .ok, .database_id = configured.id, .route_name = "schema" };
}

fn queryGet(
    context: *Context,
    request_context: *web_app.RequestContext,
    target: request.Target,
    database_id: []const u8,
    request_id: u64,
) !Outcome {
    const configured = context.registry.find(database_id) orelse {
        try problem(context, request_context, null, .not_found, "Database not found", "That database is not configured.", request_id);
        return .{ .status = .not_found, .database_id = database_id, .route_name = "query" };
    };
    const parameters = http_params.parseQuery(request_context.arena, target) catch {
        try problem(context, request_context, configured, .bad_request, "Invalid parameters", "The query parameters are malformed or ambiguous.", request_id);
        return .{ .status = .bad_request, .database_id = configured.id, .route_name = "query" };
    };
    var database = sqlite.Database.open(request_context.arena, configured.path, configured.mode) catch |err| {
        return unavailable(context, request_context, configured, "query", request_id, err);
    };
    defer database.deinit();
    const sidebar = loadSidebar(request_context.arena, &database, configured, parameters, null) catch |err| {
        if (err == error.SearchTooLong) {
            try problem(context, request_context, configured, .bad_request, "Search too long", "Object search is limited to 256 bytes.", request_id);
            return .{ .status = .bad_request, .database_id = configured.id, .route_name = "query" };
        }
        return err;
    };
    const body = try views.queryPage(request_context.arena, .{
        .registry = context.registry,
        .database = configured,
        .sidebar = sidebar,
        .csrf_token = &context.csrf_token,
    });
    try respondHtml(request_context.request, body, .ok);
    return .{ .status = .ok, .database_id = configured.id, .route_name = "query" };
}

fn queryPost(
    context: *Context,
    request_context: *web_app.RequestContext,
    _: request.Target,
    database_id: []const u8,
    request_id: u64,
) !Outcome {
    const configured = context.registry.find(database_id) orelse {
        request_context.request.head.keep_alive = false;
        try problem(context, request_context, null, .not_found, "Database not found", "That database is not configured.", request_id);
        return .{ .status = .not_found, .database_id = database_id, .route_name = "query" };
    };
    if (!formContentType(request.header(request_context.request, "content-type") orelse "")) {
        request_context.request.head.keep_alive = false;
        try problem(context, request_context, configured, .unsupported_media_type, "Unsupported form", "Use an ordinary URL-encoded form submission.", request_id);
        return .{ .status = .unsupported_media_type, .database_id = configured.id, .route_name = "query" };
    }
    // std.http header slices belong to the received-head state. Copy the two
    // mutation-boundary headers before body consumption advances that state.
    const origin = if (request.header(request_context.request, "origin")) |value|
        try request_context.arena.dupe(u8, value)
    else
        null;
    const host = if (request.header(request_context.request, "host")) |value|
        try request_context.arena.dupe(u8, value)
    else
        null;
    const encoded = request.readBodyAlloc(request_context.arena, request_context.request, 128 * 1024) catch |err| switch (err) {
        error.BodyTooLarge => {
            request_context.request.head.keep_alive = false;
            try problem(context, request_context, configured, .payload_too_large, "Request too large", "The form body exceeds 128 KiB.", request_id);
            return .{ .status = .payload_too_large, .database_id = configured.id, .route_name = "query" };
        },
        else => return err,
    };
    const fields = http_params.parseForm(request_context.arena, encoded) catch {
        try problem(context, request_context, configured, .bad_request, "Invalid form", "The form is malformed or ambiguous.", request_id);
        return .{ .status = .bad_request, .database_id = configured.id, .route_name = "query" };
    };
    if (!csrfValid(context.csrf_token, fields.get("csrf_token") orelse "") or !originMatchesHost(origin, host)) {
        try problem(context, request_context, configured, .forbidden, "Request rejected", "The form token or request origin is invalid. Reload the page and try again.", request_id);
        return .{ .status = .forbidden, .database_id = configured.id, .route_name = "query" };
    }
    const sql = fields.get("sql") orelse "";
    var database = sqlite.Database.open(request_context.arena, configured.path, configured.mode) catch |err| {
        return unavailable(context, request_context, configured, "query", request_id, err);
    };
    defer database.deinit();
    const sidebar = loadSidebar(request_context.arena, &database, configured, fields, null) catch |err| {
        if (err == error.SearchTooLong) {
            try problem(context, request_context, configured, .bad_request, "Search too long", "Object search is limited to 256 bytes.", request_id);
            return .{ .status = .bad_request, .database_id = configured.id, .route_name = "query" };
        }
        return err;
    };
    const confirmed = std.mem.eql(u8, fields.get("confirm_write") orelse "", "1");
    const action = query_mod.execute(request_context.arena, request_context.io, &database, sql, confirmed) catch |err| {
        const status: std.http.Status = queryErrorStatus(err);
        std.log.warn(
            "event=sqlite_query_error database={s} primary={d} extended={d} error={s}",
            .{ configured.id, database.primaryCode(), database.extendedCode(), @errorName(err) },
        );
        const message = try queryErrorMessage(request_context.arena, &database, err);
        const body = try views.queryPage(request_context.arena, .{
            .registry = context.registry,
            .database = configured,
            .sidebar = sidebar,
            .csrf_token = &context.csrf_token,
            .sql = sql,
            .error_message = message,
        });
        try respondHtml(request_context.request, body, status);
        return .{ .status = status, .database_id = configured.id, .route_name = "query" };
    };
    const body = switch (action) {
        .confirmation_required => try views.queryPage(request_context.arena, .{
            .registry = context.registry,
            .database = configured,
            .sidebar = sidebar,
            .csrf_token = &context.csrf_token,
            .sql = sql,
            .confirmation_required = true,
        }),
        .result => |result| try views.queryPage(request_context.arena, .{
            .registry = context.registry,
            .database = configured,
            .sidebar = sidebar,
            .csrf_token = &context.csrf_token,
            .sql = sql,
            .result = result,
        }),
    };
    try respondHtml(request_context.request, body, .ok);
    return .{ .status = .ok, .database_id = configured.id, .route_name = "query" };
}

fn rowGet(
    context: *Context,
    request_context: *web_app.RequestContext,
    target: request.Target,
    database_id: []const u8,
    request_id: u64,
) !Outcome {
    const configured = context.registry.find(database_id) orelse {
        try problem(context, request_context, null, .not_found, "Database not found", "That database is not configured.", request_id);
        return .{ .status = .not_found, .database_id = database_id, .route_name = "row" };
    };
    const parameters = http_params.parseQuery(request_context.arena, target) catch {
        try problem(context, request_context, configured, .bad_request, "Invalid row link", "The row link is malformed or ambiguous.", request_id);
        return .{ .status = .bad_request, .database_id = configured.id, .route_name = "row" };
    };
    const object_name = parameters.get("object") orelse "";
    const key = parameters.get("key") orelse "";
    var database = sqlite.Database.open(request_context.arena, configured.path, configured.mode) catch |err| {
        return unavailable(context, request_context, configured, "row", request_id, err);
    };
    defer database.deinit();
    const loaded = loadStructuredRow(request_context.arena, &database, object_name, key) catch |err| {
        return rowLoadError(context, request_context, configured, "row", request_id, err);
    };
    const sidebar = try loadSidebar(request_context.arena, &database, configured, parameters, object_name);
    const body = try views.rowPage(request_context.arena, .{
        .registry = context.registry,
        .database = configured,
        .sidebar = sidebar,
        .row = loaded,
        .csrf_token = &context.csrf_token,
        .updated_notice = std.mem.eql(u8, parameters.get("updated") orelse "", "1"),
    });
    try respondHtml(request_context.request, body, .ok);
    return .{ .status = .ok, .database_id = configured.id, .route_name = "row" };
}

fn rowEdit(
    context: *Context,
    request_context: *web_app.RequestContext,
    target: request.Target,
    database_id: []const u8,
    request_id: u64,
) !Outcome {
    const configured = context.registry.find(database_id) orelse {
        try problem(context, request_context, null, .not_found, "Database not found", "That database is not configured.", request_id);
        return .{ .status = .not_found, .database_id = database_id, .route_name = "row_edit" };
    };
    if (configured.mode != .read_write) {
        try problem(context, request_context, configured, .forbidden, "Read-only", "This database is configured as read-only.", request_id);
        return .{ .status = .forbidden, .database_id = configured.id, .route_name = "row_edit" };
    }
    const parameters = http_params.parseQuery(request_context.arena, target) catch {
        try problem(context, request_context, configured, .bad_request, "Invalid row link", "The row link is malformed or ambiguous.", request_id);
        return .{ .status = .bad_request, .database_id = configured.id, .route_name = "row_edit" };
    };
    const object_name = parameters.get("object") orelse "";
    const key = parameters.get("key") orelse "";
    var database = sqlite.Database.open(request_context.arena, configured.path, .read_write) catch |err| {
        return unavailable(context, request_context, configured, "row_edit", request_id, err);
    };
    defer database.deinit();
    const loaded = loadStructuredRow(request_context.arena, &database, object_name, key) catch |err| {
        return rowLoadError(context, request_context, configured, "row_edit", request_id, err);
    };
    if (!mutate.supportsEdit(loaded)) {
        try problem(context, request_context, configured, .unprocessable_entity, "Unsupported row editing", "This row has no supported editable scalar fields. Use the SQL console.", request_id);
        return .{ .status = .unprocessable_entity, .database_id = configured.id, .route_name = "row_edit" };
    }
    const sidebar = try loadSidebar(request_context.arena, &database, configured, parameters, object_name);
    const body = try views.editPage(request_context.arena, .{
        .registry = context.registry,
        .database = configured,
        .sidebar = sidebar,
        .row = loaded,
        .csrf_token = &context.csrf_token,
    });
    try respondHtml(request_context.request, body, .ok);
    return .{ .status = .ok, .database_id = configured.id, .route_name = "row_edit" };
}

fn rowUpdate(
    context: *Context,
    request_context: *web_app.RequestContext,
    database_id: []const u8,
    request_id: u64,
) !Outcome {
    const configured = context.registry.find(database_id) orelse {
        request_context.request.head.keep_alive = false;
        try problem(context, request_context, null, .not_found, "Database not found", "That database is not configured.", request_id);
        return .{ .status = .not_found, .database_id = database_id, .route_name = "row_update" };
    };
    const fields = readMutationForm(context, request_context) catch |err| {
        return mutationFormError(context, request_context, configured, "row_update", request_id, err);
    };
    if (configured.mode != .read_write) {
        try problem(context, request_context, configured, .forbidden, "Read-only", "This database is configured as read-only.", request_id);
        return .{ .status = .forbidden, .database_id = configured.id, .route_name = "row_update" };
    }
    const object_name = fields.get("object") orelse "";
    const key = fields.get("key") orelse "";
    var database = sqlite.Database.open(request_context.arena, configured.path, .read_write) catch |err| {
        return unavailable(context, request_context, configured, "row_update", request_id, err);
    };
    defer database.deinit();
    const loaded = loadStructuredRow(request_context.arena, &database, object_name, key) catch |err| {
        return rowLoadError(context, request_context, configured, "row_update", request_id, err);
    };
    var update_deadline = sqlite.Deadline.afterSeconds(request_context.io, 10);
    database.installProgressHandler(&update_deadline);
    defer database.clearProgressHandler();
    mutate.update(request_context.arena, &database, loaded, fields) catch |err| switch (err) {
        error.DatabaseBusy, error.SqliteConstraint, error.QueryInterrupted => {
            database.clearProgressHandler();
            std.log.warn("event=sqlite_mutation_error database={s} primary={d} extended={d} error={s}", .{ configured.id, database.primaryCode(), database.extendedCode(), @errorName(err) });
            const status: std.http.Status = .conflict;
            const message = if (err == error.DatabaseBusy)
                "The database is currently busy. No changes were made."
            else if (err == error.QueryInterrupted)
                "The update was interrupted after 10 seconds. No changes were made."
            else
                "SQLite rejected the update because a constraint or trigger failed.";
            const sidebar = try loadSidebar(request_context.arena, &database, configured, .{ .items = &.{} }, object_name);
            const body = try views.editPage(request_context.arena, .{ .registry = context.registry, .database = configured, .sidebar = sidebar, .row = loaded, .csrf_token = &context.csrf_token, .error_message = message });
            try respondHtml(request_context.request, body, status);
            return .{ .status = status, .database_id = configured.id, .route_name = "row_update" };
        },
        error.RowStale, error.SchemaChanged => {
            try problem(context, request_context, configured, .conflict, "Schema or row changed", "The row or table schema changed while this form was open. Reload it before editing.", request_id);
            return .{ .status = .conflict, .database_id = configured.id, .route_name = "row_update" };
        },
        error.InvalidInteger, error.InvalidReal, error.InvalidText, error.InvalidSubmittedType, error.NullNotAllowed, error.TextTooLong, error.StructuredEditingUnsupported => {
            database.clearProgressHandler();
            const sidebar = try loadSidebar(request_context.arena, &database, configured, .{ .items = &.{} }, object_name);
            const body = try views.editPage(request_context.arena, .{
                .registry = context.registry,
                .database = configured,
                .sidebar = sidebar,
                .row = loaded,
                .csrf_token = &context.csrf_token,
                .error_message = mutationValueMessage(err),
            });
            try respondHtml(request_context.request, body, .unprocessable_entity);
            return .{ .status = .unprocessable_entity, .database_id = configured.id, .route_name = "row_update" };
        },
        else => return err,
    };
    const location = try std.fmt.allocPrint(
        request_context.arena,
        "/db/{s}/row?object={s}&key={s}&updated=1",
        .{ configured.id, try encodeUrlComponent(request_context.arena, object_name), key },
    );
    try response.redirect(request_context.request, location, .see_other, &security_headers);
    return .{ .status = .see_other, .database_id = configured.id, .route_name = "row_update" };
}

fn rowDelete(
    context: *Context,
    request_context: *web_app.RequestContext,
    database_id: []const u8,
    request_id: u64,
) !Outcome {
    const configured = context.registry.find(database_id) orelse {
        request_context.request.head.keep_alive = false;
        try problem(context, request_context, null, .not_found, "Database not found", "That database is not configured.", request_id);
        return .{ .status = .not_found, .database_id = database_id, .route_name = "row_delete" };
    };
    const fields = readMutationForm(context, request_context) catch |err| {
        return mutationFormError(context, request_context, configured, "row_delete", request_id, err);
    };
    if (configured.mode != .read_write) {
        try problem(context, request_context, configured, .forbidden, "Read-only", "This database is configured as read-only.", request_id);
        return .{ .status = .forbidden, .database_id = configured.id, .route_name = "row_delete" };
    }
    if (!std.mem.eql(u8, fields.get("confirm_delete") orelse "", "1")) {
        try problem(context, request_context, configured, .unprocessable_entity, "Deletion not confirmed", "Confirm the destructive action from the row detail page.", request_id);
        return .{ .status = .unprocessable_entity, .database_id = configured.id, .route_name = "row_delete" };
    }
    const object_name = fields.get("object") orelse "";
    const key = fields.get("key") orelse "";
    var database = sqlite.Database.open(request_context.arena, configured.path, .read_write) catch |err| {
        return unavailable(context, request_context, configured, "row_delete", request_id, err);
    };
    defer database.deinit();
    const loaded = loadStructuredRow(request_context.arena, &database, object_name, key) catch |err| {
        return rowLoadError(context, request_context, configured, "row_delete", request_id, err);
    };
    var delete_deadline = sqlite.Deadline.afterSeconds(request_context.io, 10);
    database.installProgressHandler(&delete_deadline);
    defer database.clearProgressHandler();
    mutate.delete(request_context.arena, &database, loaded) catch |err| switch (err) {
        error.DatabaseBusy, error.SqliteConstraint, error.QueryInterrupted => {
            std.log.warn("event=sqlite_mutation_error database={s} primary={d} extended={d} error={s}", .{ configured.id, database.primaryCode(), database.extendedCode(), @errorName(err) });
            const message = if (err == error.DatabaseBusy)
                "The database is currently busy. No changes were made."
            else if (err == error.QueryInterrupted)
                "The delete was interrupted after 10 seconds. No changes were made."
            else
                "SQLite rejected the delete because a constraint or trigger failed.";
            try problem(context, request_context, configured, .conflict, "Delete failed", message, request_id);
            return .{ .status = .conflict, .database_id = configured.id, .route_name = "row_delete" };
        },
        error.RowStale, error.SchemaChanged => {
            try problem(context, request_context, configured, .conflict, "Row changed", "The row no longer exists or its schema changed.", request_id);
            return .{ .status = .conflict, .database_id = configured.id, .route_name = "row_delete" };
        },
        else => return err,
    };
    const location = try std.fmt.allocPrint(
        request_context.arena,
        "/db/{s}/data?object={s}&deleted=1",
        .{ configured.id, try encodeUrlComponent(request_context.arena, object_name) },
    );
    try response.redirect(request_context.request, location, .see_other, &security_headers);
    return .{ .status = .see_other, .database_id = configured.id, .route_name = "row_delete" };
}

fn loadStructuredRow(
    allocator: std.mem.Allocator,
    database: *sqlite.Database,
    object_name: []const u8,
    key: []const u8,
) !mutate.RowDetail {
    if (object_name.len == 0 or key.len == 0) return error.MalformedToken;
    const object = (try schema.findObject(allocator, database, object_name)) orelse return error.ObjectNotFound;
    const details = try schema.loadObjectDetails(allocator, database, object);
    return mutate.loadRow(allocator, database, details, key);
}

fn rowLoadError(
    context: *Context,
    request_context: *web_app.RequestContext,
    configured: *const config.DatabaseConfig,
    route_name: []const u8,
    request_id: u64,
    err: anyerror,
) !Outcome {
    const status: std.http.Status = switch (err) {
        error.ObjectNotFound, error.RowNotFound => .not_found,
        error.StructuredEditingUnsupported => .unprocessable_entity,
        error.SchemaChanged => .conflict,
        else => .bad_request,
    };
    const message = switch (err) {
        error.ObjectNotFound => "The selected table no longer exists.",
        error.RowNotFound => "The selected row no longer exists.",
        error.StructuredEditingUnsupported => "Structured editing is unavailable because this object has no usable declared primary key.",
        error.SchemaChanged => "The table schema changed. Return to the data browser and open the row again.",
        else => "The row identity token is malformed or no longer matches the table schema.",
    };
    try problem(context, request_context, configured, status, "Row unavailable", message, request_id);
    return .{ .status = status, .database_id = configured.id, .route_name = route_name };
}

fn readMutationForm(context: *Context, request_context: *web_app.RequestContext) !http_params.Parameters {
    if (!formContentType(request.header(request_context.request, "content-type") orelse "")) return error.UnsupportedFormType;
    const origin = if (request.header(request_context.request, "origin")) |value| try request_context.arena.dupe(u8, value) else null;
    const host = if (request.header(request_context.request, "host")) |value| try request_context.arena.dupe(u8, value) else null;
    const encoded = try request.readBodyAlloc(request_context.arena, request_context.request, 128 * 1024);
    const fields = http_params.parseForm(request_context.arena, encoded) catch return error.MalformedForm;
    if (!csrfValid(context.csrf_token, fields.get("csrf_token") orelse "") or !originMatchesHost(origin, host)) return error.InvalidFormToken;
    return fields;
}

fn mutationFormError(
    context: *Context,
    request_context: *web_app.RequestContext,
    configured: *const config.DatabaseConfig,
    route_name: []const u8,
    request_id: u64,
    err: anyerror,
) !Outcome {
    const status: std.http.Status = switch (err) {
        error.BodyTooLarge => .payload_too_large,
        error.InvalidFormToken => .forbidden,
        error.UnsupportedFormType => .unsupported_media_type,
        else => .bad_request,
    };
    if (err == error.BodyTooLarge or err == error.UnsupportedFormType) request_context.request.head.keep_alive = false;
    const message = switch (err) {
        error.BodyTooLarge => "The form body exceeds 128 KiB.",
        error.InvalidFormToken => "The form token or request origin is invalid. Reload the page and try again.",
        error.UnsupportedFormType => "Use an ordinary URL-encoded form submission.",
        else => "The form is malformed or ambiguous.",
    };
    try problem(context, request_context, configured, status, "Mutation rejected", message, request_id);
    return .{ .status = status, .database_id = configured.id, .route_name = route_name };
}

fn mutationValueMessage(err: anyerror) []const u8 {
    return switch (err) {
        error.InvalidInteger => "An INTEGER value contains invalid or trailing characters.",
        error.InvalidReal => "A REAL value contains invalid or trailing characters.",
        error.NullNotAllowed => "A NOT NULL column cannot be set to NULL.",
        error.TextTooLong => "A structured text value is limited to 64 KiB.",
        error.InvalidText => "Structured TEXT values must be valid UTF-8.",
        error.InvalidSubmittedType => "Choose NULL, INTEGER, REAL, or TEXT for every editable value.",
        else => "This row cannot be edited through the structured form.",
    };
}

fn encodeUrlComponent(allocator: std.mem.Allocator, value: []const u8) ![]u8 {
    var output: std.Io.Writer.Allocating = .init(allocator);
    const digits = "0123456789ABCDEF";
    for (value) |byte| {
        if (std.ascii.isAlphanumeric(byte) or byte == '-' or byte == '_' or byte == '.' or byte == '~') {
            try output.writer.writeByte(byte);
        } else {
            try output.writer.writeByte('%');
            try output.writer.writeByte(digits[byte >> 4]);
            try output.writer.writeByte(digits[byte & 0x0f]);
        }
    }
    return output.toOwnedSlice();
}

fn loadSidebar(
    allocator: std.mem.Allocator,
    database: *sqlite.Database,
    configured: *const config.DatabaseConfig,
    parameters: http_params.Parameters,
    current_object: ?[]const u8,
) !views.Sidebar {
    const search = parameters.get("q") orelse "";
    if (search.len > 256) return error.SearchTooLong;
    const show_internal = std.mem.eql(u8, parameters.get("internal") orelse "", "1");
    return .{
        .database = configured,
        .objects = try schema.listObjects(allocator, database, show_internal, search),
        .current_object = current_object,
        .search = search,
        .show_internal = show_internal,
    };
}

fn unavailable(
    context: *Context,
    request_context: *web_app.RequestContext,
    configured: *const config.DatabaseConfig,
    route_name: []const u8,
    request_id: u64,
    err: anyerror,
) !Outcome {
    std.log.err("event=sqlite_open database={s} error={s}", .{ configured.id, @errorName(err) });
    try problem(context, request_context, configured, .service_unavailable, "Database unavailable", "The configured database cannot be opened right now.", request_id);
    return .{ .status = .service_unavailable, .database_id = configured.id, .route_name = route_name };
}

fn browseErrorMessage(err: anyerror) []const u8 {
    return switch (err) {
        error.InvalidPage => "The page value is invalid.",
        error.InvalidPageSize => "Page size must be 25, 50, 100, or 250.",
        error.InvalidSortColumn => "The sort column does not exist in the current schema.",
        error.InvalidSortDirection, error.DirectionWithoutSort => "Sort direction must be asc or desc and requires a sort column.",
        error.InvalidFilterOperator => "Choose one of the supported filter operators.",
        error.InvalidFilterColumn => "The filter column does not exist in the current schema.",
        error.IncompleteFilter => "Choose both a filter column and operator.",
        error.BlobFilterUnsupported => "Structured filtering is unavailable for BLOB columns. Use the SQL console.",
        else => "The requested data view is invalid.",
    };
}

fn formContentType(value: []const u8) bool {
    const semicolon = std.mem.indexOfScalar(u8, value, ';') orelse value.len;
    return std.ascii.eqlIgnoreCase(std.mem.trim(u8, value[0..semicolon], " \t"), "application/x-www-form-urlencoded");
}

fn csrfValid(expected: [64]u8, supplied: []const u8) bool {
    if (supplied.len != expected.len) return false;
    return std.crypto.timing_safe.eql([64]u8, expected, supplied[0..64].*);
}

fn originMatchesHost(origin_optional: ?[]const u8, host_optional: ?[]const u8) bool {
    const origin = origin_optional orelse return true;
    const host = host_optional orelse return false;
    const remainder = if (std.mem.startsWith(u8, origin, "https://"))
        origin[8..]
    else if (std.mem.startsWith(u8, origin, "http://"))
        origin[7..]
    else
        return false;
    const slash = std.mem.indexOfScalar(u8, remainder, '/') orelse remainder.len;
    if (slash != remainder.len) return false;
    return std.ascii.eqlIgnoreCase(remainder, host);
}

fn queryErrorStatus(err: anyerror) std.http.Status {
    return switch (err) {
        error.StatementProhibited, error.DatabaseReadOnly => .forbidden,
        error.DatabaseBusy, error.SqliteConstraint => .conflict,
        else => .unprocessable_entity,
    };
}

fn queryErrorMessage(allocator: std.mem.Allocator, database: *sqlite.Database, err: anyerror) ![]const u8 {
    const fixed: ?[]const u8 = switch (err) {
        error.EmptySql => "Enter one SQLite statement.",
        error.SqlTooLong => "SQL source is limited to 64 KiB.",
        error.InvalidSqlEncoding => "SQL source must be valid UTF-8.",
        error.MultipleStatements => "Enter exactly one executable SQLite statement.",
        error.StatementProhibited => "ATTACH, DETACH, transaction control, and savepoint control are prohibited.",
        error.DatabaseReadOnly => "This database is configured as read-only.",
        error.QueryInterrupted => "Query interrupted after 10 seconds.",
        error.TooManyResultColumns => "The result exceeds the 256-column display limit.",
        error.DatabaseBusy => "The database is currently busy. No changes were made.",
        else => null,
    };
    if (fixed) |message| return message;
    var output: std.Io.Writer.Allocating = .init(allocator);
    try output.writer.print("{f}", .{std.unicode.fmtUtf8(database.errorMessage())});
    return output.toOwnedSlice();
}

fn health(request_context: *web_app.RequestContext) !Outcome {
    try response.respond(request_context.request, "ok\n", .{
        .content_type = "text/plain; charset=utf-8",
        .cache_control = "no-store",
        .extra_headers = &security_headers,
    });
    return .{ .status = .ok, .route_name = "healthz" };
}

fn asset(request_context: *web_app.RequestContext, bytes: []const u8, content_type: []const u8, route_name: []const u8) !Outcome {
    try response.respond(request_context.request, bytes, .{
        .content_type = content_type,
        .cache_control = "public, max-age=3600",
        .extra_headers = &security_headers,
    });
    return .{ .status = .ok, .route_name = route_name };
}

fn problem(
    context: *Context,
    request_context: *web_app.RequestContext,
    database: ?*const config.DatabaseConfig,
    status: std.http.Status,
    title: []const u8,
    message: []const u8,
    request_id: u64,
) !void {
    const body = try views.errorPage(request_context.arena, context.registry, database, status, title, message, request_id);
    try respondHtml(request_context.request, body, status);
}

fn respondHtml(http_request: *std.http.Server.Request, body: []const u8, status: std.http.Status) !void {
    try response.respond(http_request, body, .{
        .status = status,
        .content_type = "text/html; charset=utf-8",
        .cache_control = "no-store",
        .extra_headers = &security_headers,
    });
}

const security_headers = [_]std.http.Header{
    // `no-referrer` causes native same-origin POSTs in Chromium to carry
    // `Origin: null`, defeating the host-match defense. `same-origin` keeps
    // cross-site referrers suppressed while preserving a verifiable Origin.
    .{ .name = "referrer-policy", .value = "same-origin" },
    .{ .name = "x-content-type-options", .value = "nosniff" },
    .{ .name = "x-frame-options", .value = "DENY" },
    .{ .name = "content-security-policy", .value = "default-src 'self'; base-uri 'none'; object-src 'none'; frame-ancestors 'none'; form-action 'self'; script-src 'self'; style-src 'self'; img-src 'self' data:" },
};
