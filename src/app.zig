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
const query_files = @import("query_files.zig");
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
    query_file_create,
    query_file_save,
    query_file_rename,
    query_file_delete,
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
    .{ .method = .POST, .pattern = "/db/:database_id/query/file/create", .handler = .query_file_create },
    .{ .method = .POST, .pattern = "/db/:database_id/query/file/save", .handler = .query_file_save },
    .{ .method = .POST, .pattern = "/db/:database_id/query/file/rename", .handler = .query_file_rename },
    .{ .method = .POST, .pattern = "/db/:database_id/query/file/delete", .handler = .query_file_delete },
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
            const outcome = switch (matched.route.handler) {
                .index => index(context, request_context),
                .health => health(request_context),
                .asset_css => asset(request_context, app_css, "text/css; charset=utf-8", "asset_css"),
                .asset_js => asset(request_context, app_js, "text/javascript; charset=utf-8", "asset_js"),
                .overview => overview(context, request_context, target, database_id, request_id),
                .data => data(context, request_context, target, database_id, request_id),
                .schema => schemaPage(context, request_context, target, database_id, request_id),
                .query_get => queryGet(context, request_context, target, database_id, request_id),
                .query_post => queryPost(context, request_context, target, database_id, request_id),
                .query_file_create => queryFileCreate(context, request_context, database_id, request_id),
                .query_file_save => queryFileSave(context, request_context, database_id, request_id),
                .query_file_rename => queryFileRename(context, request_context, database_id, request_id),
                .query_file_delete => queryFileDelete(context, request_context, database_id, request_id),
                .row => rowGet(context, request_context, target, database_id, request_id),
                .row_edit => rowEdit(context, request_context, target, database_id, request_id),
                .row_update => rowUpdate(context, request_context, database_id, request_id),
                .row_delete => rowDelete(context, request_context, database_id, request_id),
            };
            return outcome catch |err| {
                if (err == error.InvalidDatabase) {
                    const configured = context.registry.find(database_id) orelse return err;
                    return unavailable(context, request_context, configured, @tagName(matched.route.handler), request_id, err);
                }
                return err;
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
        const details = loadIndexSummary(request_context.arena, request_context.io, configured) catch |err| switch (err) {
            error.OutOfMemory => return err,
            else => {
                std.log.warn("event=database_summary database={s} state=unavailable error={s}", .{ configured.id, @errorName(err) });
                summaries[index_value] = .{ .database = configured, .details = null };
                continue;
            },
        };
        summaries[index_value] = .{ .database = configured, .details = details };
    }
    const body = try views.databaseIndex(request_context.arena, context.registry, summaries);
    try respondHtml(request_context.request, body, .ok);
    return .{ .status = .ok, .route_name = "database_index" };
}

fn loadIndexSummary(
    allocator: std.mem.Allocator,
    io: std.Io,
    configured: *const config.DatabaseConfig,
) !views.DatabaseSummary.Details {
    var database = try sqlite.Database.open(allocator, configured.path, configured.mode);
    defer database.deinit();
    const stat = try std.Io.Dir.cwd().statFile(io, configured.path, .{ .follow_symlinks = true });
    return .{
        .file_size = stat.size,
        .modified_seconds = stat.mtime.toSeconds(),
        .overview = try schema.loadOverview(allocator, &database),
    };
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
    var sidebar = loadSidebar(request_context.arena, &database, configured, parameters, null) catch |err| {
        if (err == error.SearchTooLong) {
            try problem(context, request_context, configured, .bad_request, "Search too long", "Object search is limited to 256 bytes.", request_id);
            return .{ .status = .bad_request, .database_id = configured.id, .route_name = "query" };
        }
        return err;
    };
    const document = loadQueryWorkspace(request_context.arena, request_context.io, configured, parameters, &sidebar) catch |err| {
        return queryWorkspaceError(context, request_context, configured, "query", request_id, err);
    };
    const body = try views.queryPage(request_context.arena, .{
        .registry = context.registry,
        .database = configured,
        .sidebar = sidebar,
        .csrf_token = &context.csrf_token,
        .document = document,
        .sql = if (document) |value| value.source else "",
        .notice = queryNotice(parameters),
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
    const fields = readSourceForm(context, request_context) catch |err| {
        return sourceFormError(context, request_context, configured, "query", request_id, err);
    };
    const fragment_requested = std.mem.eql(u8, fields.get("fragment") orelse "", "query-result");
    const sql = fields.get("sql") orelse "";
    var database = sqlite.Database.open(request_context.arena, configured.path, configured.mode) catch |err| {
        return unavailable(context, request_context, configured, "query", request_id, err);
    };
    defer database.deinit();
    var sidebar = loadSidebar(request_context.arena, &database, configured, fields, null) catch |err| {
        if (err == error.SearchTooLong) {
            try problem(context, request_context, configured, .bad_request, "Search too long", "Object search is limited to 256 bytes.", request_id);
            return .{ .status = .bad_request, .database_id = configured.id, .route_name = "query" };
        }
        return err;
    };
    var document = loadQueryWorkspace(request_context.arena, request_context.io, configured, fields, &sidebar) catch |err| {
        return queryWorkspaceError(context, request_context, configured, "query", request_id, err);
    };
    var saved_before_run = false;
    if (fields.get("file")) |file_name| {
        const workspace_path = configured.queries_path orelse {
            return queryWorkspaceError(context, request_context, configured, "query", request_id, error.QueryWorkspaceUnavailable);
        };
        if (document == null or !document.?.editable()) {
            return renderQueryFileFailure(context, request_context, configured, sidebar, document, sql, "This SQL file cannot be edited in dbui.", .unprocessable_entity, request_id, false, false, "", "query");
        }
        const base_revision = fields.get("base_revision") orelse "";
        const saved = query_files.save(
            request_context.arena,
            request_context.io,
            workspace_path,
            file_name,
            base_revision,
            sql,
        ) catch |err| {
            if (err == error.FileConflict) {
                var conflict_document = document.?;
                conflict_document.source = sql;
                if (formRevision(base_revision)) |revision| conflict_document.revision = revision;
                return renderQueryFileFailure(
                    context,
                    request_context,
                    configured,
                    sidebar,
                    conflict_document,
                    sql,
                    "The file changed on disk. Your edits were not saved or executed.",
                    .conflict,
                    request_id,
                    true,
                    true,
                    "",
                    "query",
                );
            }
            return renderQueryFileFailure(
                context,
                request_context,
                configured,
                sidebar,
                document,
                sql,
                queryFileErrorMessage(err),
                queryFileErrorStatus(err),
                request_id,
                false,
                true,
                "",
                "query",
            );
        };
        saved_before_run = saved.changed;
        document = query_files.load(request_context.arena, request_context.io, workspace_path, file_name) catch |err| {
            return queryWorkspaceError(context, request_context, configured, "query", request_id, err);
        };
        sidebar.current_file = file_name;
    }
    const scope = query_mod.Scope.parse(fields.get("scope") orelse "whole") catch {
        return renderQueryExecutionFailure(context, request_context, configured, &database, sidebar, document, sql, saved_before_run, error.InvalidExecutionScope, .whole, 0, 0, 0, request_id, fragment_requested);
    };
    const selection_start = parseFormOffset(fields.get("selection_start_byte") orelse "0") catch {
        return renderQueryExecutionFailure(context, request_context, configured, &database, sidebar, document, sql, saved_before_run, error.InvalidSourceOffset, scope, 0, 0, 0, request_id, fragment_requested);
    };
    const selection_end = parseFormOffset(fields.get("selection_end_byte") orelse "0") catch {
        return renderQueryExecutionFailure(context, request_context, configured, &database, sidebar, document, sql, saved_before_run, error.InvalidSourceOffset, scope, selection_start, 0, 0, request_id, fragment_requested);
    };
    const cursor = parseFormOffset(fields.get("cursor_byte") orelse "0") catch {
        return renderQueryExecutionFailure(context, request_context, configured, &database, sidebar, document, sql, saved_before_run, error.InvalidSourceOffset, scope, selection_start, selection_end, 0, request_id, fragment_requested);
    };
    try database.installQueryAuthorizer();
    const resolved = query_mod.resolveSource(
        request_context.arena,
        &database,
        sql,
        scope,
        selection_start,
        selection_end,
        cursor,
    ) catch |err| {
        return renderQueryExecutionFailure(context, request_context, configured, &database, sidebar, document, sql, saved_before_run, err, scope, selection_start, selection_end, cursor, request_id, fragment_requested);
    };
    const confirmed = std.mem.eql(u8, fields.get("confirm_write") orelse "", "1");
    const action = query_mod.execute(request_context.arena, request_context.io, &database, resolved.sql, confirmed) catch |err| {
        const status: std.http.Status = queryErrorStatus(err);
        std.log.warn(
            "event=sqlite_query_error database={s} primary={d} extended={d} error={s}",
            .{ configured.id, database.primaryCode(), database.extendedCode(), @errorName(err) },
        );
        const message = try queryErrorMessage(request_context.arena, &database, err);
        if (fragment_requested) {
            const fragment = try views.queryFragment(request_context.arena, .{
                .error_message = message,
                .saved_before_run = saved_before_run,
            });
            try respondQueryFragment(request_context, fragment, queryErrorStatus(err), document);
            return .{ .status = queryErrorStatus(err), .database_id = configured.id, .route_name = "query" };
        }
        const body = try views.queryPage(request_context.arena, .{
            .registry = context.registry,
            .database = configured,
            .sidebar = sidebar,
            .csrf_token = &context.csrf_token,
            .sql = sql,
            .document = document,
            .error_message = message,
            .saved_before_run = saved_before_run,
            .notice = if (saved_before_run) "SQL file saved before execution." else null,
            .scope = scope,
            .selection_start_byte = selection_start,
            .selection_end_byte = selection_end,
            .cursor_byte = cursor,
        });
        try respondHtml(request_context.request, body, status);
        return .{ .status = status, .database_id = configured.id, .route_name = "query" };
    };
    if (fragment_requested) {
        const fragment = switch (action) {
            .confirmation_required => try views.queryFragment(request_context.arena, .{
                .confirmation_required = true,
                .saved_before_run = saved_before_run,
            }),
            .result => |result| try views.queryFragment(request_context.arena, .{
                .result = result,
                .result_context = .{
                    .file_name = fields.get("file"),
                    .line_start = resolved.line_start,
                    .line_end = resolved.line_end,
                },
            }),
        };
        try respondQueryFragment(request_context, fragment, .ok, document);
        return .{ .status = .ok, .database_id = configured.id, .route_name = "query" };
    }
    const body = switch (action) {
        .confirmation_required => try views.queryPage(request_context.arena, .{
            .registry = context.registry,
            .database = configured,
            .sidebar = sidebar,
            .csrf_token = &context.csrf_token,
            .sql = sql,
            .document = document,
            .confirmation_required = true,
            .saved_before_run = saved_before_run,
            .scope = scope,
            .selection_start_byte = selection_start,
            .selection_end_byte = selection_end,
            .cursor_byte = cursor,
        }),
        .result => |result| try views.queryPage(request_context.arena, .{
            .registry = context.registry,
            .database = configured,
            .sidebar = sidebar,
            .csrf_token = &context.csrf_token,
            .sql = sql,
            .document = document,
            .result = result,
            .result_context = .{
                .file_name = fields.get("file"),
                .line_start = resolved.line_start,
                .line_end = resolved.line_end,
            },
            .saved_before_run = saved_before_run,
            .scope = scope,
            .selection_start_byte = selection_start,
            .selection_end_byte = selection_end,
            .cursor_byte = cursor,
        }),
    };
    try respondHtml(request_context.request, body, .ok);
    return .{ .status = .ok, .database_id = configured.id, .route_name = "query" };
}

fn queryFileCreate(
    context: *Context,
    request_context: *web_app.RequestContext,
    database_id: []const u8,
    request_id: u64,
) !Outcome {
    const configured = context.registry.find(database_id) orelse {
        request_context.request.head.keep_alive = false;
        try problem(context, request_context, null, .not_found, "Database not found", "That database is not configured.", request_id);
        return .{ .status = .not_found, .database_id = database_id, .route_name = "query_file_create" };
    };
    const workspace_path = configured.queries_path orelse {
        request_context.request.head.keep_alive = false;
        try problem(context, request_context, configured, .not_found, "SQL files unavailable", "This database has no configured query directory.", request_id);
        return .{ .status = .not_found, .database_id = configured.id, .route_name = "query_file_create" };
    };
    const fields = readSourceForm(context, request_context) catch |err| {
        return sourceFormError(context, request_context, configured, "query_file_create", request_id, err);
    };
    const name = fields.get("new_name") orelse "";
    const source = fields.get("sql") orelse "";
    _ = query_files.create(request_context.arena, request_context.io, workspace_path, name, source) catch |err| {
        std.log.warn("event=query_file_error database={s} route=create error={s}", .{ configured.id, @errorName(err) });
        return renderQueryFieldsFailure(
            context,
            request_context,
            configured,
            fields,
            source,
            queryFileErrorMessage(err),
            queryFileErrorStatus(err),
            request_id,
            fields.get("file") != null,
            "query_file_create",
        );
    };
    try redirectQuery(request_context, configured.id, name, fields, "created");
    return .{ .status = .see_other, .database_id = configured.id, .route_name = "query_file_create" };
}

fn queryFileSave(
    context: *Context,
    request_context: *web_app.RequestContext,
    database_id: []const u8,
    request_id: u64,
) !Outcome {
    const configured = context.registry.find(database_id) orelse {
        request_context.request.head.keep_alive = false;
        try problem(context, request_context, null, .not_found, "Database not found", "That database is not configured.", request_id);
        return .{ .status = .not_found, .database_id = database_id, .route_name = "query_file_save" };
    };
    const workspace_path = configured.queries_path orelse {
        request_context.request.head.keep_alive = false;
        try problem(context, request_context, configured, .not_found, "SQL files unavailable", "This database has no configured query directory.", request_id);
        return .{ .status = .not_found, .database_id = configured.id, .route_name = "query_file_save" };
    };
    const fields = readSourceForm(context, request_context) catch |err| {
        return sourceFormError(context, request_context, configured, "query_file_save", request_id, err);
    };
    const name = fields.get("file") orelse "";
    const source = fields.get("sql") orelse "";
    const saved = query_files.save(
        request_context.arena,
        request_context.io,
        workspace_path,
        name,
        fields.get("base_revision") orelse "",
        source,
    ) catch |err| {
        std.log.warn("event=query_file_error database={s} route=save error={s}", .{ configured.id, @errorName(err) });
        return renderQueryFieldsFailure(
            context,
            request_context,
            configured,
            fields,
            source,
            if (err == error.FileConflict) "The file changed on disk. Your edits were not saved." else queryFileErrorMessage(err),
            queryFileErrorStatus(err),
            request_id,
            err == error.FileConflict,
            "query_file_save",
        );
    };
    if (std.mem.eql(u8, fields.get("fragment") orelse "", "save-state")) {
        try respondSaveState(request_context, saved.revision);
        return .{ .status = .ok, .database_id = configured.id, .route_name = "query_file_save" };
    }
    try redirectQuery(request_context, configured.id, name, fields, "saved");
    return .{ .status = .see_other, .database_id = configured.id, .route_name = "query_file_save" };
}

fn queryFileRename(
    context: *Context,
    request_context: *web_app.RequestContext,
    database_id: []const u8,
    request_id: u64,
) !Outcome {
    const configured = context.registry.find(database_id) orelse {
        request_context.request.head.keep_alive = false;
        try problem(context, request_context, null, .not_found, "Database not found", "That database is not configured.", request_id);
        return .{ .status = .not_found, .database_id = database_id, .route_name = "query_file_rename" };
    };
    const workspace_path = configured.queries_path orelse {
        try problem(context, request_context, configured, .not_found, "SQL files unavailable", "This database has no configured query directory.", request_id);
        return .{ .status = .not_found, .database_id = configured.id, .route_name = "query_file_rename" };
    };
    const fields = readMutationForm(context, request_context) catch |err| {
        return mutationFormError(context, request_context, configured, "query_file_rename", request_id, err);
    };
    const old_name = fields.get("file") orelse "";
    const new_name = fields.get("new_name") orelse "";
    query_files.rename(
        request_context.arena,
        request_context.io,
        workspace_path,
        old_name,
        new_name,
        fields.get("base_revision") orelse "",
    ) catch |err| {
        std.log.warn("event=query_file_error database={s} route=rename error={s}", .{ configured.id, @errorName(err) });
        try problem(context, request_context, configured, queryFileErrorStatus(err), "Rename failed", queryFileErrorMessage(err), request_id);
        return .{ .status = queryFileErrorStatus(err), .database_id = configured.id, .route_name = "query_file_rename" };
    };
    try redirectQuery(request_context, configured.id, new_name, fields, "renamed");
    return .{ .status = .see_other, .database_id = configured.id, .route_name = "query_file_rename" };
}

fn queryFileDelete(
    context: *Context,
    request_context: *web_app.RequestContext,
    database_id: []const u8,
    request_id: u64,
) !Outcome {
    const configured = context.registry.find(database_id) orelse {
        request_context.request.head.keep_alive = false;
        try problem(context, request_context, null, .not_found, "Database not found", "That database is not configured.", request_id);
        return .{ .status = .not_found, .database_id = database_id, .route_name = "query_file_delete" };
    };
    const workspace_path = configured.queries_path orelse {
        try problem(context, request_context, configured, .not_found, "SQL files unavailable", "This database has no configured query directory.", request_id);
        return .{ .status = .not_found, .database_id = configured.id, .route_name = "query_file_delete" };
    };
    const fields = readMutationForm(context, request_context) catch |err| {
        return mutationFormError(context, request_context, configured, "query_file_delete", request_id, err);
    };
    if (!std.mem.eql(u8, fields.get("confirm_delete") orelse "", "1")) {
        try problem(context, request_context, configured, .unprocessable_entity, "Delete not confirmed", "Confirm the named SQL file before deleting it.", request_id);
        return .{ .status = .unprocessable_entity, .database_id = configured.id, .route_name = "query_file_delete" };
    }
    const name = fields.get("file") orelse "";
    query_files.delete(
        request_context.arena,
        request_context.io,
        workspace_path,
        name,
        fields.get("base_revision") orelse "",
    ) catch |err| {
        std.log.warn("event=query_file_error database={s} route=delete error={s}", .{ configured.id, @errorName(err) });
        try problem(context, request_context, configured, queryFileErrorStatus(err), "Delete failed", queryFileErrorMessage(err), request_id);
        return .{ .status = queryFileErrorStatus(err), .database_id = configured.id, .route_name = "query_file_delete" };
    };
    try redirectQuery(request_context, configured.id, null, fields, "deleted");
    return .{ .status = .see_other, .database_id = configured.id, .route_name = "query_file_delete" };
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

fn readSourceForm(context: *Context, request_context: *web_app.RequestContext) !http_params.Parameters {
    if (!formContentType(request.header(request_context.request, "content-type") orelse "")) return error.UnsupportedFormType;
    // Header slices are invalidated when body consumption advances the HTTP
    // receive state, so copy the two mutation-boundary values first.
    const origin = if (request.header(request_context.request, "origin")) |value| try request_context.arena.dupe(u8, value) else null;
    const host = if (request.header(request_context.request, "host")) |value| try request_context.arena.dupe(u8, value) else null;
    const encoded = try request.readBodyAlloc(request_context.arena, request_context.request, 256 * 1024);
    const fields = http_params.parseFormLimited(request_context.arena, encoded, 80 * 1024) catch return error.MalformedForm;
    if (!csrfValid(context.csrf_token, fields.get("csrf_token") orelse "") or !originMatchesHost(origin, host)) return error.InvalidFormToken;
    return fields;
}

fn sourceFormError(
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
        error.BodyTooLarge => "The encoded form body exceeds 256 KiB.",
        error.InvalidFormToken => "The form token or request origin is invalid. Reload the page and try again.",
        error.UnsupportedFormType => "Use an ordinary URL-encoded form submission.",
        else => "The form is malformed, ambiguous, or exceeds the decoded source boundary.",
    };
    try problem(context, request_context, configured, status, "Query form rejected", message, request_id);
    return .{ .status = status, .database_id = configured.id, .route_name = route_name };
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

fn loadQueryWorkspace(
    allocator: std.mem.Allocator,
    io: std.Io,
    configured: *const config.DatabaseConfig,
    parameters: http_params.Parameters,
    sidebar: *views.Sidebar,
) !?query_files.Document {
    const file_name = parameters.get("file");
    const workspace_path = configured.queries_path orelse {
        if (file_name != null) return error.QueryWorkspaceUnavailable;
        return null;
    };
    sidebar.query_files = try query_files.list(allocator, io, workspace_path);
    if (file_name) |name| {
        const document = try query_files.load(allocator, io, workspace_path, name);
        sidebar.current_file = document.name;
        return document;
    }
    return null;
}

fn queryNotice(parameters: http_params.Parameters) ?[]const u8 {
    if (std.mem.eql(u8, parameters.get("created") orelse "", "1")) return "SQL file created.";
    if (std.mem.eql(u8, parameters.get("saved") orelse "", "1")) return "SQL file saved.";
    if (std.mem.eql(u8, parameters.get("renamed") orelse "", "1")) return "SQL file renamed.";
    if (std.mem.eql(u8, parameters.get("deleted") orelse "", "1")) return "SQL file deleted.";
    return null;
}

fn queryWorkspaceError(
    context: *Context,
    request_context: *web_app.RequestContext,
    configured: *const config.DatabaseConfig,
    route_name: []const u8,
    request_id: u64,
    err: anyerror,
) !Outcome {
    const status = queryFileErrorStatus(err);
    try problem(context, request_context, configured, status, "SQL file unavailable", queryFileErrorMessage(err), request_id);
    return .{ .status = status, .database_id = configured.id, .route_name = route_name };
}

fn renderQueryFieldsFailure(
    context: *Context,
    request_context: *web_app.RequestContext,
    configured: *const config.DatabaseConfig,
    fields: http_params.Parameters,
    source: []const u8,
    message: []const u8,
    status: std.http.Status,
    request_id: u64,
    conflict: bool,
    route_name: []const u8,
) !Outcome {
    var database = sqlite.Database.open(request_context.arena, configured.path, configured.mode) catch |err| {
        return unavailable(context, request_context, configured, route_name, request_id, err);
    };
    defer database.deinit();
    var sidebar = loadSidebar(request_context.arena, &database, configured, fields, null) catch |err| {
        if (err == error.SearchTooLong) {
            try problem(context, request_context, configured, .bad_request, "Search too long", "Object search is limited to 256 bytes.", request_id);
            return .{ .status = .bad_request, .database_id = configured.id, .route_name = route_name };
        }
        return err;
    };
    var effective_conflict = conflict;
    var document = loadQueryWorkspace(request_context.arena, request_context.io, configured, fields, &sidebar) catch |err| block: {
        const file_name = fields.get("file") orelse {
            return queryWorkspaceError(context, request_context, configured, route_name, request_id, err);
        };
        const revision = formRevision(fields.get("base_revision") orelse "") orelse {
            return queryWorkspaceError(context, request_context, configured, route_name, request_id, err);
        };
        const workspace_path = configured.queries_path orelse {
            return queryWorkspaceError(context, request_context, configured, route_name, request_id, err);
        };
        sidebar.query_files = query_files.list(request_context.arena, request_context.io, workspace_path) catch |list_err| {
            return queryWorkspaceError(context, request_context, configured, route_name, request_id, list_err);
        };
        sidebar.current_file = file_name;
        effective_conflict = true;
        break :block query_files.Document{
            .name = file_name,
            .source = source,
            .revision = revision,
        };
    };
    if (effective_conflict) {
        if (document) |*value| {
            value.source = source;
            if (formRevision(fields.get("base_revision") orelse "")) |revision| value.revision = revision;
        }
    }
    return renderQueryFileFailure(
        context,
        request_context,
        configured,
        sidebar,
        document,
        source,
        message,
        status,
        request_id,
        effective_conflict,
        fields.get("file") != null,
        fields.get("new_name") orelse "",
        route_name,
    );
}

fn renderQueryFileFailure(
    context: *Context,
    request_context: *web_app.RequestContext,
    configured: *const config.DatabaseConfig,
    sidebar: views.Sidebar,
    document: ?query_files.Document,
    source: []const u8,
    message: []const u8,
    status: std.http.Status,
    request_id: u64,
    conflict: bool,
    initial_unsaved: bool,
    new_file_name: []const u8,
    route_name: []const u8,
) !Outcome {
    _ = request_id;
    const body = try views.queryPage(request_context.arena, .{
        .registry = context.registry,
        .database = configured,
        .sidebar = sidebar,
        .csrf_token = &context.csrf_token,
        .sql = source,
        .document = document,
        .error_message = message,
        .file_conflict = conflict,
        .initial_unsaved = initial_unsaved,
        .new_file_name = new_file_name,
    });
    try respondHtml(request_context.request, body, status);
    return .{ .status = status, .database_id = configured.id, .route_name = route_name };
}

fn queryFileErrorStatus(err: anyerror) std.http.Status {
    return switch (err) {
        error.FileNotFound, error.QueryWorkspaceUnavailable, error.SymLinkLoop, error.FileNotRegular, error.IsDir => .not_found,
        error.FileConflict, error.FileChangedDuringRead, error.PathAlreadyExists => .conflict,
        error.InvalidFilename, error.InvalidRevision => .bad_request,
        error.SourceTooLarge, error.InvalidUtf8, error.ContainsNul, error.UnsupportedLineEndings, error.FileNotEditable, error.FileTooLarge, error.TooManyWorkspaceEntries, error.TooManyQueryFiles => .unprocessable_entity,
        error.NoSpaceLeft, error.DiskQuota => .insufficient_storage,
        error.AccessDenied, error.PermissionDenied, error.ReadOnlyFileSystem => .service_unavailable,
        else => .internal_server_error,
    };
}

fn queryFileErrorMessage(err: anyerror) []const u8 {
    return switch (err) {
        error.QueryWorkspaceUnavailable => "This database has no configured query directory.",
        error.FileNotFound, error.SymLinkLoop, error.FileNotRegular, error.IsDir => "That SQL file no longer exists.",
        error.FileConflict, error.FileChangedDuringRead => "The SQL file changed on disk. Reload it before making another change.",
        error.PathAlreadyExists => "A SQL file with that name already exists.",
        error.InvalidFilename => "Use a direct UTF-8 filename ending in .sql, with at most 80 bytes and no path separators or control characters.",
        error.InvalidRevision => "The SQL file revision is malformed. Reload the page and try again.",
        error.SourceTooLarge, error.FileTooLarge => "SQL files are limited to 64 KiB.",
        error.InvalidUtf8 => "SQL files must contain valid UTF-8.",
        error.ContainsNul => "SQL files cannot contain NUL bytes.",
        error.UnsupportedLineEndings => "Mixed or bare-CR line endings are not editable in dbui.",
        error.FileNotEditable => "This SQL file cannot be edited in dbui.",
        error.TooManyWorkspaceEntries => "The query directory exceeds the 512-entry inspection limit.",
        error.TooManyQueryFiles => "The query directory exceeds the 128-file limit.",
        error.NoSpaceLeft, error.DiskQuota => "The SQL file could not be saved because the filesystem has no available space.",
        error.AccessDenied, error.PermissionDenied, error.ReadOnlyFileSystem => "The configured query directory is not writable by dbui.",
        else => "The SQL file operation could not be completed.",
    };
}

fn redirectQuery(
    request_context: *web_app.RequestContext,
    database_id: []const u8,
    file_name: ?[]const u8,
    fields: http_params.Parameters,
    notice: []const u8,
) !void {
    var location: std.Io.Writer.Allocating = .init(request_context.arena);
    try location.writer.print("/db/{s}/query?", .{database_id});
    var has_parameter = false;
    if (file_name) |name| {
        try location.writer.writeAll("file=");
        try writeUrlComponent(&location.writer, name);
        has_parameter = true;
    }
    if (fields.get("q")) |search| {
        if (search.len != 0) {
            if (has_parameter) try location.writer.writeByte('&');
            try location.writer.writeAll("q=");
            try writeUrlComponent(&location.writer, search);
            has_parameter = true;
        }
    }
    if (std.mem.eql(u8, fields.get("internal") orelse "", "1")) {
        if (has_parameter) try location.writer.writeByte('&');
        try location.writer.writeAll("internal=1");
        has_parameter = true;
    }
    if (has_parameter) try location.writer.writeByte('&');
    try location.writer.print("{s}=1", .{notice});
    try response.redirect(request_context.request, location.written(), .see_other, &security_headers);
}

fn encodeUrlComponent(allocator: std.mem.Allocator, value: []const u8) ![]u8 {
    var output: std.Io.Writer.Allocating = .init(allocator);
    try writeUrlComponent(&output.writer, value);
    return output.toOwnedSlice();
}

fn writeUrlComponent(writer: *std.Io.Writer, value: []const u8) !void {
    const digits = "0123456789ABCDEF";
    for (value) |byte| {
        if (std.ascii.isAlphanumeric(byte) or byte == '-' or byte == '_' or byte == '.' or byte == '~') {
            try writer.writeByte(byte);
        } else {
            try writer.writeByte('%');
            try writer.writeByte(digits[byte >> 4]);
            try writer.writeByte(digits[byte & 0x0f]);
        }
    }
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
    std.log.err("event=database_unavailable database={s} error={s}", .{ configured.id, @errorName(err) });
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

fn parseFormOffset(value: []const u8) !usize {
    if (value.len == 0) return error.InvalidSourceOffset;
    return std.fmt.parseInt(usize, value, 10) catch error.InvalidSourceOffset;
}

fn formRevision(value: []const u8) ?query_files.Revision {
    if (value.len != 64) return null;
    for (value) |byte| if (!std.ascii.isHex(byte)) return null;
    var revision: query_files.Revision = undefined;
    @memcpy(&revision, value[0..64]);
    return revision;
}

fn renderQueryExecutionFailure(
    context: *Context,
    request_context: *web_app.RequestContext,
    configured: *const config.DatabaseConfig,
    database: *sqlite.Database,
    sidebar: views.Sidebar,
    document: ?query_files.Document,
    source: []const u8,
    saved_before_run: bool,
    err: anyerror,
    scope: query_mod.Scope,
    selection_start: usize,
    selection_end: usize,
    cursor: usize,
    request_id: u64,
    fragment_requested: bool,
) !Outcome {
    const status = queryErrorStatus(err);
    std.log.warn(
        "event=sqlite_query_error database={s} primary={d} extended={d} error={s}",
        .{ configured.id, database.primaryCode(), database.extendedCode(), @errorName(err) },
    );
    const message = try queryErrorMessage(request_context.arena, database, err);
    if (fragment_requested) {
        const fragment = try views.queryFragment(request_context.arena, .{
            .error_message = message,
            .saved_before_run = saved_before_run,
        });
        try respondQueryFragment(request_context, fragment, status, document);
        return .{ .status = status, .database_id = configured.id, .route_name = "query" };
    }
    const body = try views.queryPage(request_context.arena, .{
        .registry = context.registry,
        .database = configured,
        .sidebar = sidebar,
        .csrf_token = &context.csrf_token,
        .sql = source,
        .document = document,
        .error_message = message,
        .notice = if (saved_before_run) "SQL file saved before execution." else null,
        .saved_before_run = saved_before_run,
        .scope = scope,
        .selection_start_byte = selection_start,
        .selection_end_byte = selection_end,
        .cursor_byte = cursor,
    });
    try respondHtml(request_context.request, body, status);
    _ = request_id;
    return .{ .status = status, .database_id = configured.id, .route_name = "query" };
}

fn queryErrorMessage(allocator: std.mem.Allocator, database: *sqlite.Database, err: anyerror) ![]const u8 {
    const fixed: ?[]const u8 = switch (err) {
        error.EmptySql => "Enter one SQLite statement.",
        error.SqlTooLong => "SQL source is limited to 64 KiB.",
        error.InvalidSqlEncoding => "SQL source must be valid UTF-8.",
        error.MultipleStatements => "Enter exactly one executable SQLite statement.",
        error.InvalidExecutionScope => "Choose whole-editor, selection, or current-statement execution.",
        error.InvalidSourceOffset => "The editor selection no longer matches the submitted UTF-8 source.",
        error.EmptySelection => "Select executable SQL or place the caret inside a statement.",
        error.NoStatementAtCursor => "No SQLite statement exists at the current caret position.",
        error.TooManyStatementBoundaries => "This SQL source has too many semicolon boundaries for caret execution. Select one statement explicitly and run the selection.",
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
        .cache_control = "no-store",
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

fn respondQueryFragment(
    request_context: *web_app.RequestContext,
    body: []const u8,
    status: std.http.Status,
    document: ?query_files.Document,
) !void {
    var headers = response.Headers{};
    try headers.append(&security_headers);
    if (document) |value| {
        if (value.revision) |revision| {
            const etag = try std.fmt.allocPrint(request_context.arena, "\"{s}\"", .{&revision});
            try headers.add("etag", etag);
        }
    }
    try response.respond(request_context.request, body, .{
        .status = status,
        .content_type = "text/html; charset=utf-8",
        .cache_control = "no-store",
        .extra_headers = headers.slice(),
    });
}

fn respondSaveState(request_context: *web_app.RequestContext, revision: query_files.Revision) !void {
    var headers = response.Headers{};
    try headers.append(&security_headers);
    const etag = try std.fmt.allocPrint(request_context.arena, "\"{s}\"", .{&revision});
    try headers.add("etag", etag);
    try response.respond(request_context.request, "saved\n", .{
        .status = .ok,
        .content_type = "text/plain; charset=utf-8",
        .cache_control = "no-store",
        .extra_headers = headers.slice(),
    });
}

const security_headers = [_]std.http.Header{
    // `no-referrer` causes native same-origin POSTs in Chromium to carry
    // `Origin: null`, defeating the host-match defense. `origin` keeps paths
    // and query filenames out of referrers while preserving a verifiable Origin.
    .{ .name = "referrer-policy", .value = "origin" },
    .{ .name = "x-content-type-options", .value = "nosniff" },
    .{ .name = "x-frame-options", .value = "DENY" },
    .{ .name = "content-security-policy", .value = "default-src 'self'; base-uri 'none'; object-src 'none'; frame-ancestors 'none'; form-action 'self'; script-src 'self'; style-src 'self'; img-src 'self' data:" },
};
