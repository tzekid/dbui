const std = @import("std");
const html = @import("web_html");
const config = @import("config.zig");
const schema = @import("schema.zig");
const browse = @import("browse.zig");
const query_mod = @import("query.zig");
const mutate = @import("mutate.zig");

pub const Section = enum { overview, data, schema, query };

pub const Sidebar = struct {
    database: *const config.DatabaseConfig,
    objects: []const schema.ObjectMeta,
    current_object: ?[]const u8 = null,
    search: []const u8 = "",
    show_internal: bool = false,
};

pub const DatabaseSummary = struct {
    database: *const config.DatabaseConfig,
    file_size: u64,
    modified_seconds: i64,
    overview: schema.Overview,
};

pub const OverviewPage = struct {
    registry: *const config.Registry,
    database: *const config.DatabaseConfig,
    file_size: u64,
    modified_seconds: i64,
    overview: schema.Overview,
    sidebar: Sidebar,
};

pub const DataPage = struct {
    registry: *const config.Registry,
    database: *const config.DatabaseConfig,
    sidebar: Sidebar,
    details: schema.ObjectDetails,
    result: browse.Page,
    deleted_notice: bool = false,
};

pub const SchemaPage = struct {
    registry: *const config.Registry,
    database: *const config.DatabaseConfig,
    sidebar: Sidebar,
    details: schema.ObjectDetails,
};

pub const QueryPage = struct {
    registry: *const config.Registry,
    database: *const config.DatabaseConfig,
    sidebar: Sidebar,
    csrf_token: []const u8,
    sql: []const u8 = "",
    result: ?query_mod.Result = null,
    error_message: ?[]const u8 = null,
    confirmation_required: bool = false,
};

pub const RowPage = struct {
    registry: *const config.Registry,
    database: *const config.DatabaseConfig,
    sidebar: Sidebar,
    row: mutate.RowDetail,
    csrf_token: []const u8,
    updated_notice: bool = false,
};

pub const EditPage = struct {
    registry: *const config.Registry,
    database: *const config.DatabaseConfig,
    sidebar: Sidebar,
    row: mutate.RowDetail,
    csrf_token: []const u8,
    error_message: ?[]const u8 = null,
};

pub fn databaseIndex(
    allocator: std.mem.Allocator,
    registry: *const config.Registry,
    databases: []const DatabaseSummary,
) ![]u8 {
    var output: std.Io.Writer.Allocating = .init(allocator);
    errdefer output.deinit();
    const writer = &output.writer;
    try shellStart(writer, "Databases · dbui", registry, null, .overview, null);
    try writer.writeAll("<main class=\"main main--index\"><header class=\"page-header\"><div><h1>Databases</h1><p>Configured SQLite files, in operator-defined order.</p></div></header><div class=\"database-list\">");
    for (databases) |item| {
        try writer.writeAll("<article class=\"database-row\"><div><h2><a href=\"/db/");
        try html.attribute(writer, item.database.id);
        try writer.writeAll("\">");
        try html.text(writer, item.database.label);
        try writer.writeAll("</a></h2><p class=\"meta\">");
        try writer.print("{d} tables · {d} views · ", .{ item.overview.tables, item.overview.views });
        try writeSize(writer, item.file_size);
        try writer.writeAll(" · Modified ");
        try writeModifiedTime(writer, item.modified_seconds);
        try writer.writeAll("</p></div>");
        try modeBadge(writer, item.database);
        try writer.writeAll("</article>");
    }
    try writer.writeAll("</div></main>");
    try shellEnd(writer);
    return output.toOwnedSlice();
}

pub fn databaseOverview(allocator: std.mem.Allocator, page: OverviewPage) ![]u8 {
    var output: std.Io.Writer.Allocating = .init(allocator);
    errdefer output.deinit();
    const writer = &output.writer;
    const title = try std.fmt.allocPrint(allocator, "{s} · dbui", .{page.database.label});
    try shellStart(writer, title, page.registry, page.database, .overview, page.sidebar);
    try writer.writeAll("<main class=\"main\"><header class=\"page-header\"><div><p class=\"eyebrow\">Database overview</p><h1>");
    try html.text(writer, page.database.label);
    try writer.writeAll("</h1><p>");
    try html.text(writer, page.database.basename());
    try writer.writeAll("</p></div>");
    try modeBadge(writer, page.database);
    try writer.writeAll("</header><dl class=\"facts\">");
    try factText(writer, "File", page.database.basename());
    try writer.writeAll("<div><dt>Size</dt><dd>");
    try writeSize(writer, page.file_size);
    try writer.writeAll("</dd></div>");
    try writer.writeAll("<div><dt>Modified</dt><dd>");
    try writeModifiedTime(writer, page.modified_seconds);
    try writer.writeAll("</dd></div>");
    try factText(writer, "SQLite library", page.overview.sqlite_version);
    try writer.print("<div><dt>user_version</dt><dd>{d}</dd></div><div><dt>application_id</dt><dd>{d}</dd></div>", .{ page.overview.user_version, page.overview.application_id });
    try factText(writer, "Journal mode", page.overview.journal_mode);
    try writer.print(
        "<div><dt>Tables</dt><dd>{d}</dd></div><div><dt>Views</dt><dd>{d}</dd></div><div><dt>Indexes</dt><dd>{d}</dd></div><div><dt>Triggers</dt><dd>{d}</dd></div><div><dt>STRICT tables</dt><dd>{d}</dd></div><div><dt>WITHOUT ROWID</dt><dd>{d}</dd></div>",
        .{ page.overview.tables, page.overview.views, page.overview.indexes, page.overview.triggers, page.overview.strict_tables, page.overview.without_rowid_tables },
    );
    try writer.writeAll("</dl></main>");
    try shellEnd(writer);
    return output.toOwnedSlice();
}

pub fn dataPage(allocator: std.mem.Allocator, page: DataPage) ![]u8 {
    var output: std.Io.Writer.Allocating = .init(allocator);
    errdefer output.deinit();
    const writer = &output.writer;
    const title = try std.fmt.allocPrint(allocator, "{s} · {s} · dbui", .{ page.details.object.name, page.database.label });
    try shellStart(writer, title, page.registry, page.database, .data, page.sidebar);
    try writer.writeAll("<main class=\"main main--data\"><header class=\"page-header\"><div><p class=\"eyebrow\">Data · ");
    try html.text(writer, page.details.object.kind.label());
    try writer.writeAll("</p><h1>");
    try html.text(writer, page.details.object.name);
    try writer.writeAll("</h1></div><a class=\"button\" href=\"/db/");
    try html.attribute(writer, page.database.id);
    try writer.writeAll("/schema?object=");
    try urlComponent(writer, page.details.object.name);
    if (page.sidebar.show_internal) try writer.writeAll("&amp;internal=1");
    try writer.writeAll("\">View schema</a></header>");
    if (page.deleted_notice) try writer.writeAll("<p class=\"notice notice--success\">Row deleted.</p>");
    if (page.result.unstable_order) try writer.writeAll("<p class=\"notice\">This object has no declared primary key. Row order may change between requests.</p>");
    if (page.result.display_limit_reached) try writer.writeAll("<p class=\"notice notice--warning\">The 4 MiB display limit was reached. Refine the filter or use a smaller page.</p>");
    try renderFilterForm(writer, page);
    try writer.writeAll("<div class=\"grid-scroll\"><table class=\"data-grid\"><thead><tr>");
    if (page.details.object.structuredWritable()) try writer.writeAll("<th scope=\"col\" class=\"action-column\">Row</th>");
    for (page.details.columns) |column| {
        try writer.writeAll("<th scope=\"col\"><a title=\"");
        try html.attribute(writer, column.name);
        try writer.writeAll("\" href=\"");
        const next_direction: browse.Direction = if (page.result.options.sort) |selected|
            if (std.mem.eql(u8, selected, column.name) and page.result.options.direction == .asc) .desc else .asc
        else
            .asc;
        try dataHref(writer, page, .{ .page = 0, .sort = column.name, .direction = next_direction });
        try writer.writeAll("\">");
        try html.text(writer, column.name);
        if (page.result.options.sort) |selected| {
            if (std.mem.eql(u8, selected, column.name)) try writer.writeAll(if (page.result.options.direction == .asc) " ↑" else " ↓");
        }
        try writer.writeAll("</a></th>");
    }
    try writer.writeAll("</tr></thead><tbody>");
    if (page.result.rows.len == 0) {
        const column_span = page.details.columns.len + @intFromBool(page.details.object.structuredWritable());
        try writer.print("<tr><td class=\"empty-cell\" colspan=\"{d}\">No rows match this view.</td></tr>", .{@max(1, column_span)});
    } else {
        for (page.result.rows) |row| {
            try writer.writeAll("<tr>");
            if (page.details.object.structuredWritable()) {
                try writer.writeAll("<td class=\"action-column\">");
                if (row.key) |key| {
                    try writer.writeAll("<a href=\"/db/");
                    try html.attribute(writer, page.database.id);
                    try writer.writeAll("/row?object=");
                    try urlComponent(writer, page.details.object.name);
                    try writer.writeAll("&amp;key=");
                    try urlComponent(writer, key);
                    try writer.writeAll("\">Open</a>");
                } else {
                    try writer.writeAll("—");
                }
                try writer.writeAll("</td>");
            }
            for (row.values) |value| try renderValueCell(writer, value);
            try writer.writeAll("</tr>");
        }
    }
    try writer.writeAll("</tbody></table></div>");
    try renderPagination(writer, page);
    try writer.writeAll("</main>");
    try shellEnd(writer);
    return output.toOwnedSlice();
}

pub fn objectTooWidePage(
    allocator: std.mem.Allocator,
    registry: *const config.Registry,
    database: *const config.DatabaseConfig,
    sidebar_view: Sidebar,
    object: schema.ObjectMeta,
) ![]u8 {
    var output: std.Io.Writer.Allocating = .init(allocator);
    errdefer output.deinit();
    const writer = &output.writer;
    try shellStart(writer, "Object too wide · dbui", registry, database, .data, sidebar_view);
    try writer.writeAll("<main class=\"main\"><section class=\"problem\"><p class=\"eyebrow\">Data browser</p><h1>Object too wide</h1><p><code>");
    try html.text(writer, object.name);
    try writer.print("</code> has {d} columns. The standard browser is limited to {d} columns.</p><p><a class=\"button\" href=\"/db/{s}/query\">Open the SQL console</a></p></section></main>", .{ object.column_count, browse.maximum_columns, database.id });
    try shellEnd(writer);
    return output.toOwnedSlice();
}

pub fn schemaPage(allocator: std.mem.Allocator, page: SchemaPage) ![]u8 {
    var output: std.Io.Writer.Allocating = .init(allocator);
    errdefer output.deinit();
    const writer = &output.writer;
    const title = try std.fmt.allocPrint(allocator, "Schema · {s} · dbui", .{page.details.object.name});
    try shellStart(writer, title, page.registry, page.database, .schema, page.sidebar);
    try writer.writeAll("<main class=\"main\"><header class=\"page-header\"><div><p class=\"eyebrow\">Schema · ");
    try html.text(writer, page.details.object.kind.label());
    try writer.writeAll("</p><h1>");
    try html.text(writer, page.details.object.name);
    try writer.writeAll("</h1><div class=\"badges\">");
    if (page.details.object.strict) try writer.writeAll("<span class=\"mode\">STRICT</span>");
    if (page.details.object.without_rowid) try writer.writeAll("<span class=\"mode\">WITHOUT ROWID</span>");
    if (!page.details.object.structuredWritable() or page.database.mode == .read_only) try writer.writeAll("<span class=\"mode\">READ-ONLY</span>");
    try writer.writeAll("</div></div><a class=\"button\" href=\"/db/");
    try html.attribute(writer, page.database.id);
    try writer.writeAll("/data?object=");
    try urlComponent(writer, page.details.object.name);
    if (page.sidebar.show_internal) try writer.writeAll("&amp;internal=1");
    try writer.writeAll("\">Browse data</a></header><section class=\"schema-section\"><h2>Definition</h2>");
    if (page.details.sql) |sql| {
        try writer.writeAll("<pre><code>");
        try html.text(writer, sql);
        try writer.writeAll("</code></pre>");
    } else {
        try writer.writeAll("<p class=\"empty-state\">No CREATE SQL is stored for this object.</p>");
    }
    try writer.writeAll("</section><section class=\"schema-section\"><h2>Columns</h2><div class=\"grid-scroll\"><table><thead><tr><th>Position</th><th>Name</th><th>Declared type</th><th>Not null</th><th>Default</th><th>Primary key</th><th>Generated/hidden</th></tr></thead><tbody>");
    for (page.details.columns) |column| {
        try writer.print("<tr><td>{d}</td><td><code>", .{column.position});
        try html.text(writer, column.name);
        try writer.writeAll("</code></td><td><code>");
        try html.text(writer, column.declared_type);
        try writer.writeAll("</code></td><td>");
        try writer.writeAll(if (column.not_null) "Yes" else "No");
        try writer.writeAll("</td><td><code>");
        if (column.default_sql) |value| try html.text(writer, value) else try writer.writeAll("—");
        try writer.print("</code></td><td>{d}</td><td>", .{column.primary_key_position});
        try writer.writeAll(hiddenLabel(column.hidden));
        try writer.writeAll("</td></tr>");
    }
    try writer.writeAll("</tbody></table></div></section>");
    try renderIndexes(writer, page.details.indexes);
    try renderForeignKeys(writer, page.details.foreign_keys);
    try renderTriggers(writer, page.details.triggers);
    try writer.writeAll("</main>");
    try shellEnd(writer);
    return output.toOwnedSlice();
}

pub fn queryPage(allocator: std.mem.Allocator, page: QueryPage) ![]u8 {
    var output: std.Io.Writer.Allocating = .init(allocator);
    errdefer output.deinit();
    const writer = &output.writer;
    const title = try std.fmt.allocPrint(allocator, "Query · {s} · dbui", .{page.database.label});
    try shellStart(writer, title, page.registry, page.database, .query, page.sidebar);
    try writer.writeAll("<main class=\"main main--query\"><header class=\"page-header\"><div><p class=\"eyebrow\">SQL console</p><h1>Query</h1><p>One SQLite statement. Results and execution are bounded.</p></div>");
    try modeBadge(writer, page.database);
    try writer.writeAll("</header>");
    if (page.error_message) |message| {
        try writer.writeAll("<section class=\"notice notice--error\" role=\"alert\"><strong>Query failed.</strong> ");
        try html.text(writer, message);
        try writer.writeAll("</section>");
    }
    if (page.confirmation_required) {
        try writer.writeAll("<section class=\"notice notice--warning\" role=\"alert\"><strong>This statement may modify the database.</strong> Review it, check the confirmation below, and submit again.</section>");
    }
    try writer.writeAll("<form class=\"query-form\" method=\"post\" data-query-form><input type=\"hidden\" name=\"csrf_token\" value=\"");
    try html.attribute(writer, page.csrf_token);
    try writer.writeAll("\">");
    if (page.sidebar.show_internal) try writer.writeAll("<input type=\"hidden\" name=\"internal\" value=\"1\">");
    if (page.sidebar.search.len != 0) {
        try writer.writeAll("<input type=\"hidden\" name=\"q\" value=\"");
        try html.attribute(writer, page.sidebar.search);
        try writer.writeAll("\">");
    }
    try writer.writeAll("<label for=\"sql\">SQL</label><textarea id=\"sql\" name=\"sql\" data-sql rows=\"12\" spellcheck=\"false\" required>");
    try html.text(writer, page.sql);
    try writer.writeAll("</textarea>");
    if (page.confirmation_required) try writer.writeAll("<label class=\"write-confirmation\"><input type=\"checkbox\" name=\"confirm_write\" value=\"1\" required> Execute this write statement</label>");
    try writer.writeAll("<div class=\"query-actions\"><button type=\"submit\">");
    try writer.writeAll(if (page.confirmation_required) "Execute confirmed write" else "Run statement");
    try writer.writeAll("</button><span class=\"meta\">Ctrl/⌘ + Enter with JavaScript; ordinary submit always works.</span></div></form>");
    if (page.result) |result| try renderQueryResult(writer, result);
    try writer.writeAll("</main>");
    try shellEnd(writer);
    return output.toOwnedSlice();
}

pub fn rowPage(allocator: std.mem.Allocator, page: RowPage) ![]u8 {
    var output: std.Io.Writer.Allocating = .init(allocator);
    errdefer output.deinit();
    const writer = &output.writer;
    const title = try std.fmt.allocPrint(allocator, "Row · {s} · dbui", .{page.row.details.object.name});
    try shellStart(writer, title, page.registry, page.database, .data, page.sidebar);
    try writer.writeAll("<main class=\"main main--row\"><header class=\"page-header\"><div><p class=\"eyebrow\">Row detail</p><h1>");
    try html.text(writer, page.row.details.object.name);
    try writer.writeAll("</h1></div><a class=\"button\" href=\"/db/");
    try html.attribute(writer, page.database.id);
    try writer.writeAll("/data?object=");
    try urlComponent(writer, page.row.details.object.name);
    try writer.writeAll("\">Back to table</a></header>");
    if (page.updated_notice) try writer.writeAll("<p class=\"notice notice--success\">Row updated.</p>");
    try writer.writeAll("<dl class=\"row-fields\">");
    for (page.row.details.columns, page.row.values) |column, value| {
        try writer.writeAll("<div><dt><code>");
        try html.text(writer, column.name);
        try writer.writeAll("</code><span>");
        try html.text(writer, column.declared_type);
        try writer.writeAll(" · ");
        try writer.writeAll(value.typeName());
        if (column.primary_key_position != 0) try writer.print(" · PK {d}", .{column.primary_key_position});
        try writer.writeAll("</span></dt><dd>");
        try renderValueContent(writer, value);
        try writer.writeAll("</dd></div>");
    }
    try writer.writeAll("</dl><div class=\"row-actions\">");
    if (page.database.mode == .read_write and mutate.supportsEdit(page.row)) {
        try writer.writeAll("<a class=\"button\" href=\"/db/");
        try html.attribute(writer, page.database.id);
        try writer.writeAll("/row/edit?object=");
        try urlComponent(writer, page.row.details.object.name);
        try writer.writeAll("&amp;key=");
        try urlComponent(writer, page.row.key);
        try writer.writeAll("\">Edit row</a>");
    } else if (page.database.mode == .read_write and mutate.editableCount(page.row) > mutate.maximum_editable_columns) {
        try writer.writeAll("<p class=\"notice\">This row has too many editable columns for the bounded form. Use the SQL console.</p>");
    }
    try writer.writeAll("</div>");
    if (page.database.mode == .read_write) {
        try writer.writeAll("<section class=\"danger-zone\"><h2>Delete row</h2><p>This permanently deletes exactly this primary-key row.</p><form method=\"post\" action=\"/db/");
        try html.attribute(writer, page.database.id);
        try writer.writeAll("/row/delete\"><input type=\"hidden\" name=\"csrf_token\" value=\"");
        try html.attribute(writer, page.csrf_token);
        try writer.writeAll("\"><input type=\"hidden\" name=\"object\" value=\"");
        try html.attribute(writer, page.row.details.object.name);
        try writer.writeAll("\"><input type=\"hidden\" name=\"key\" value=\"");
        try html.attribute(writer, page.row.key);
        try writer.writeAll("\"><label><input type=\"checkbox\" name=\"confirm_delete\" value=\"1\" required> Delete this row permanently</label><button class=\"button button--danger\" type=\"submit\">Delete row</button></form></section>");
    }
    try writer.writeAll("</main>");
    try shellEnd(writer);
    return output.toOwnedSlice();
}

pub fn editPage(allocator: std.mem.Allocator, page: EditPage) ![]u8 {
    var output: std.Io.Writer.Allocating = .init(allocator);
    errdefer output.deinit();
    const writer = &output.writer;
    const title = try std.fmt.allocPrint(allocator, "Edit row · {s} · dbui", .{page.row.details.object.name});
    try shellStart(writer, title, page.registry, page.database, .data, page.sidebar);
    try writer.writeAll("<main class=\"main main--row\"><header class=\"page-header\"><div><p class=\"eyebrow\">Structured update</p><h1>Edit row</h1><p>");
    try html.text(writer, page.row.details.object.name);
    try writer.writeAll("</p></div></header>");
    if (page.error_message) |message| {
        try writer.writeAll("<p class=\"notice notice--error\" role=\"alert\">");
        try html.text(writer, message);
        try writer.writeAll("</p>");
    }
    try writer.writeAll("<form class=\"edit-form\" method=\"post\" action=\"/db/");
    try html.attribute(writer, page.database.id);
    try writer.writeAll("/row/update\"><input type=\"hidden\" name=\"csrf_token\" value=\"");
    try html.attribute(writer, page.csrf_token);
    try writer.writeAll("\"><input type=\"hidden\" name=\"object\" value=\"");
    try html.attribute(writer, page.row.details.object.name);
    try writer.writeAll("\"><input type=\"hidden\" name=\"key\" value=\"");
    try html.attribute(writer, page.row.key);
    try writer.writeAll("\">");
    for (page.row.details.columns, page.row.values, 0..) |column, value, index| {
        try writer.writeAll("<fieldset><legend><code>");
        try html.text(writer, column.name);
        try writer.writeAll("</code> <span>");
        try html.text(writer, column.declared_type);
        try writer.writeAll("</span></legend>");
        if (mutate.editable(page.row, index)) {
            try writer.writeAll("<label>SQLite type<select name=\"type_");
            try writer.print("{d}\">", .{column.position});
            inline for (.{ "text", "integer", "real" }) |kind| {
                try writer.writeAll("<option value=\"");
                try writer.writeAll(kind);
                try writer.writeAll("\"");
                if (std.mem.eql(u8, kind, @tagName(value))) try writer.writeAll(" selected");
                try writer.writeAll(">");
                try writer.writeAll(kind);
                try writer.writeAll("</option>");
            }
            if (!column.not_null) {
                try writer.writeAll("<option value=\"null\"");
                if (value == .null) try writer.writeAll(" selected");
                try writer.writeAll(">NULL</option>");
            }
            try writer.writeAll("</select></label><label>Value<textarea name=\"value_");
            try writer.print("{d}\" rows=\"3\">", .{column.position});
            try renderInputValue(writer, value);
            try writer.writeAll("</textarea></label>");
        } else {
            try writer.writeAll("<div class=\"read-only-value\">");
            try renderValueContent(writer, value);
            try writer.writeAll("</div><p class=\"meta\">Primary keys, generated/hidden columns, BLOBs, invalid UTF-8, and truncated values are not editable here.</p>");
        }
        try writer.writeAll("</fieldset>");
    }
    try writer.writeAll("<div class=\"query-actions\"><button type=\"submit\">Save row</button><a class=\"button button--quiet\" href=\"/db/");
    try html.attribute(writer, page.database.id);
    try writer.writeAll("/row?object=");
    try urlComponent(writer, page.row.details.object.name);
    try writer.writeAll("&amp;key=");
    try urlComponent(writer, page.row.key);
    try writer.writeAll("\">Cancel</a></div></form></main>");
    try shellEnd(writer);
    return output.toOwnedSlice();
}

fn renderInputValue(writer: *std.Io.Writer, value: browse.Value) !void {
    switch (value) {
        .null => {},
        .integer => |integer| try writer.print("{d}", .{integer}),
        .real => |real| try writer.print("{d}", .{real}),
        .text => |text_value| try html.text(writer, text_value.bytes),
        .blob => {},
    }
}

fn renderQueryResult(writer: *std.Io.Writer, result: query_mod.Result) !void {
    try writer.writeAll("<section class=\"query-result\"><header><h2>Result</h2><p class=\"meta\">Completed in ");
    try writeDuration(writer, result.duration_ns);
    if (result.rows.len != 0 or result.column_names.len != 0) try writer.print(" · {d} row{s}", .{ result.rows.len, if (result.rows.len == 1) "" else "s" });
    if (!result.read_only) try writer.print(" · {d} row{s} changed", .{ result.affected_rows, if (result.affected_rows == 1) "" else "s" });
    if (result.last_insert_row_id) |row_id| try writer.print(" · last insert row ID {d}", .{row_id});
    try writer.writeAll("</p></header>");
    if (result.truncation) |truncation| {
        try writer.writeAll("<p class=\"notice notice--warning\">");
        try writer.writeAll(switch (truncation) {
            .row_limit => "Result truncated after 500 rows.",
            .byte_limit => "Result exceeded the 4 MiB display limit.",
        });
        try writer.writeAll("</p>");
    }
    if (result.column_names.len != 0) {
        try writer.writeAll("<div class=\"grid-scroll\"><table class=\"data-grid\"><thead><tr>");
        for (result.column_names) |name| {
            try writer.writeAll("<th scope=\"col\">");
            try html.text(writer, name);
            try writer.writeAll("</th>");
        }
        try writer.writeAll("</tr></thead><tbody>");
        for (result.rows) |row| {
            try writer.writeAll("<tr>");
            for (row.values) |value| try renderValueCell(writer, value);
            try writer.writeAll("</tr>");
        }
        if (result.rows.len == 0) try writer.print("<tr><td class=\"empty-cell\" colspan=\"{d}\">Statement returned no rows.</td></tr>", .{@max(1, result.column_names.len)});
        try writer.writeAll("</tbody></table></div>");
    } else {
        try writer.writeAll("<p class=\"empty-state\">Statement completed without a result grid.</p>");
    }
    try writer.writeAll("</section>");
}

fn writeDuration(writer: *std.Io.Writer, nanoseconds: i64) !void {
    if (nanoseconds < std.time.ns_per_ms) return writer.print("{d:.1} µs", .{@as(f64, @floatFromInt(nanoseconds)) / std.time.ns_per_us});
    if (nanoseconds < std.time.ns_per_s) return writer.print("{d:.1} ms", .{@as(f64, @floatFromInt(nanoseconds)) / std.time.ns_per_ms});
    return writer.print("{d:.2} s", .{@as(f64, @floatFromInt(nanoseconds)) / std.time.ns_per_s});
}

const DataHrefOptions = struct {
    page: usize,
    sort: ?[]const u8 = null,
    direction: browse.Direction = .asc,
};

fn dataHref(writer: *std.Io.Writer, page: DataPage, override: DataHrefOptions) !void {
    try writer.writeAll("/db/");
    try html.attribute(writer, page.database.id);
    try writer.writeAll("/data?object=");
    try urlComponent(writer, page.details.object.name);
    try writer.print("&amp;page={d}&amp;size={d}", .{ override.page, page.result.options.size });
    const sort = override.sort orelse page.result.options.sort;
    const direction = if (override.sort != null) override.direction else page.result.options.direction;
    if (sort) |column| {
        try writer.writeAll("&amp;sort=");
        try urlComponent(writer, column);
        try writer.writeAll("&amp;direction=");
        try writer.writeAll(@tagName(direction));
    }
    if (page.result.options.filter) |filter| {
        try writer.writeAll("&amp;filter_column=");
        try urlComponent(writer, filter.column);
        try writer.writeAll("&amp;filter_operator=");
        try writer.writeAll(@tagName(filter.operator));
        if (filter.operator != .is_null and filter.operator != .is_not_null) {
            try writer.writeAll("&amp;filter_value=");
            try urlComponent(writer, filter.value);
        }
    }
    if (page.sidebar.show_internal) try writer.writeAll("&amp;internal=1");
    if (page.sidebar.search.len != 0) {
        try writer.writeAll("&amp;q=");
        try urlComponent(writer, page.sidebar.search);
    }
}

fn renderFilterForm(writer: *std.Io.Writer, page: DataPage) !void {
    try writer.writeAll("<form class=\"filter-bar\" method=\"get\"><input type=\"hidden\" name=\"object\" value=\"");
    try html.attribute(writer, page.details.object.name);
    try writer.writeAll("\"><label>Column<select name=\"filter_column\"><option value=\"\">Choose…</option>");
    for (page.details.columns) |column| {
        try writer.writeAll("<option value=\"");
        try html.attribute(writer, column.name);
        if (page.result.options.filter) |filter| if (std.mem.eql(u8, filter.column, column.name)) try writer.writeAll("\" selected") else try writer.writeAll("\"") else try writer.writeAll("\"");
        try writer.writeAll(">");
        try html.text(writer, column.name);
        try writer.writeAll("</option>");
    }
    try writer.writeAll("</select></label><label>Operator<select name=\"filter_operator\"><option value=\"\">Choose…</option>");
    inline for (std.meta.tags(browse.FilterOperator)) |operator| {
        try writer.writeAll("<option value=\"");
        try writer.writeAll(@tagName(operator));
        if (page.result.options.filter) |filter| if (filter.operator == operator) try writer.writeAll("\" selected>") else try writer.writeAll("\">") else try writer.writeAll("\">");
        try writer.writeAll(filterLabel(operator));
        try writer.writeAll("</option>");
    }
    try writer.writeAll("</select></label><label>Value<input name=\"filter_value\" value=\"");
    if (page.result.options.filter) |filter| try html.attribute(writer, filter.value);
    try writer.writeAll("\"></label><label>Page size<select name=\"size\">");
    for ([_]usize{ 25, 50, 100, 250 }) |size| {
        try writer.print("<option value=\"{d}\"", .{size});
        if (size == page.result.options.size) try writer.writeAll(" selected");
        try writer.print(">{d}</option>", .{size});
    }
    try writer.writeAll("</select></label>");
    if (page.result.options.sort) |sort| {
        try writer.writeAll("<input type=\"hidden\" name=\"sort\" value=\"");
        try html.attribute(writer, sort);
        try writer.writeAll("\"><input type=\"hidden\" name=\"direction\" value=\"");
        try writer.writeAll(@tagName(page.result.options.direction));
        try writer.writeAll("\">");
    }
    if (page.sidebar.show_internal) try writer.writeAll("<input type=\"hidden\" name=\"internal\" value=\"1\">");
    if (page.sidebar.search.len != 0) {
        try writer.writeAll("<input type=\"hidden\" name=\"q\" value=\"");
        try html.attribute(writer, page.sidebar.search);
        try writer.writeAll("\">");
    }
    try writer.writeAll("<button type=\"submit\">Apply</button><a class=\"button button--quiet\" href=\"/db/");
    try html.attribute(writer, page.database.id);
    try writer.writeAll("/data?object=");
    try urlComponent(writer, page.details.object.name);
    if (page.sidebar.show_internal) try writer.writeAll("&amp;internal=1");
    if (page.sidebar.search.len != 0) {
        try writer.writeAll("&amp;q=");
        try urlComponent(writer, page.sidebar.search);
    }
    try writer.writeAll("\">Clear</a></form>");
}

fn renderValueCell(writer: *std.Io.Writer, value: browse.Value) !void {
    try writer.writeAll("<td class=\"value value--");
    try writer.writeAll(@tagName(value));
    try writer.writeAll("\" data-type=\"");
    try writer.writeAll(value.typeName());
    try writer.writeAll("\">");
    try renderValueContent(writer, value);
    try writer.writeAll("</td>");
}

fn renderValueContent(writer: *std.Io.Writer, value: browse.Value) !void {
    switch (value) {
        .null => try writer.writeAll("<span class=\"null-token\">NULL</span>"),
        .integer => |integer| try writer.print("{d}", .{integer}),
        .real => |real| try writer.print("{d}", .{real}),
        .text => |text_value| {
            try html.text(writer, text_value.bytes);
            if (text_value.truncated) try writer.writeAll("<span class=\"truncation\">…</span>");
            if (!text_value.valid_utf8) try writer.writeAll(" <span class=\"value-note\">invalid UTF-8</span>");
        },
        .blob => |blob| {
            try writer.writeAll("BLOB · ");
            try writeSize(writer, @intCast(blob.original_len));
            if (blob.prefix.len != 0) {
                try writer.writeAll(" · <code>");
                try writeHex(writer, blob.prefix);
                if (blob.truncated) try writer.writeAll(" …");
                try writer.writeAll("</code>");
            }
        },
    }
}

fn renderPagination(writer: *std.Io.Writer, page: DataPage) !void {
    if (page.result.rows.len == 0 and page.result.options.page == 0) return;
    const start = page.result.options.page * page.result.options.size + 1;
    const end = if (page.result.rows.len == 0) start - 1 else start + page.result.rows.len - 1;
    try writer.writeAll("<nav class=\"pagination\" aria-label=\"Data pages\">");
    if (page.result.rows.len == 0) {
        try writer.writeAll("<span></span>");
    } else {
        try writer.print("<p>Rows {d}–{d}</p>", .{ start, end });
    }
    try writer.writeAll("<div>");
    if (page.result.options.page > 0) {
        try writer.writeAll("<a class=\"button\" href=\"");
        try dataHref(writer, page, .{ .page = page.result.options.page - 1 });
        try writer.writeAll("\">Previous</a>");
    }
    if (page.result.has_next) {
        try writer.writeAll("<a class=\"button\" href=\"");
        try dataHref(writer, page, .{ .page = page.result.options.page + 1 });
        try writer.writeAll("\">Next</a>");
    }
    try writer.writeAll("</div></nav>");
}

fn renderIndexes(writer: *std.Io.Writer, indexes: []const schema.IndexMeta) !void {
    try writer.writeAll("<section class=\"schema-section\"><h2>Indexes</h2>");
    if (indexes.len == 0) try writer.writeAll("<p class=\"empty-state\">No indexes.</p>");
    for (indexes) |index| {
        try writer.writeAll("<article class=\"schema-item\"><h3><code>");
        try html.text(writer, index.name);
        try writer.writeAll("</code></h3><p class=\"meta\">");
        try writer.writeAll(if (index.unique) "Unique" else "Non-unique");
        try writer.writeAll(" · origin ");
        try html.text(writer, index.origin);
        if (index.partial) try writer.writeAll(" · partial");
        try writer.writeAll("</p><ul class=\"technical-list\">");
        for (index.columns) |column| {
            if (!column.key) continue;
            try writer.writeAll("<li>");
            if (column.name) |name| try html.text(writer, name) else if (column.cid == -1) try writer.writeAll("rowid") else try writer.writeAll("expression");
            if (column.descending) try writer.writeAll(" DESC");
            if (column.collation) |collation| {
                try writer.writeAll(" · ");
                try html.text(writer, collation);
            }
            try writer.writeAll("</li>");
        }
        try writer.writeAll("</ul>");
        if (index.sql) |sql| {
            try writer.writeAll("<pre><code>");
            try html.text(writer, sql);
            try writer.writeAll("</code></pre>");
        }
        try writer.writeAll("</article>");
    }
    try writer.writeAll("</section>");
}

fn renderForeignKeys(writer: *std.Io.Writer, foreign_keys: []const schema.ForeignKeyMeta) !void {
    try writer.writeAll("<section class=\"schema-section\"><h2>Foreign keys</h2>");
    if (foreign_keys.len == 0) {
        try writer.writeAll("<p class=\"empty-state\">No foreign keys.</p></section>");
        return;
    }
    try writer.writeAll("<div class=\"grid-scroll\"><table><thead><tr><th>Constraint</th><th>Sequence</th><th>Source</th><th>Target table</th><th>Target column</th><th>On update</th><th>On delete</th><th>Match</th></tr></thead><tbody>");
    for (foreign_keys) |foreign_key| {
        try writer.print("<tr><td>{d}</td><td>{d}</td><td><code>", .{ foreign_key.id, foreign_key.sequence });
        try html.text(writer, foreign_key.source_column);
        try writer.writeAll("</code></td><td><code>");
        try html.text(writer, foreign_key.target_table);
        try writer.writeAll("</code></td><td><code>");
        if (foreign_key.target_column) |column| try html.text(writer, column) else try writer.writeAll("—");
        try writer.writeAll("</code></td><td>");
        try html.text(writer, foreign_key.on_update);
        try writer.writeAll("</td><td>");
        try html.text(writer, foreign_key.on_delete);
        try writer.writeAll("</td><td>");
        try html.text(writer, foreign_key.match);
        try writer.writeAll("</td></tr>");
    }
    try writer.writeAll("</tbody></table></div></section>");
}

fn renderTriggers(writer: *std.Io.Writer, triggers: []const schema.TriggerMeta) !void {
    try writer.writeAll("<section class=\"schema-section\"><h2>Triggers</h2>");
    if (triggers.len == 0) try writer.writeAll("<p class=\"empty-state\">No triggers.</p>");
    for (triggers) |trigger| {
        try writer.writeAll("<article class=\"schema-item\"><h3><code>");
        try html.text(writer, trigger.name);
        try writer.writeAll("</code></h3>");
        if (trigger.sql) |sql| {
            try writer.writeAll("<pre><code>");
            try html.text(writer, sql);
            try writer.writeAll("</code></pre>");
        }
        try writer.writeAll("</article>");
    }
    try writer.writeAll("</section>");
}

fn hiddenLabel(value: usize) []const u8 {
    return switch (value) {
        0 => "Normal",
        1 => "Hidden",
        2 => "Generated virtual",
        3 => "Generated stored",
        else => "Unknown",
    };
}

fn filterLabel(operator: browse.FilterOperator) []const u8 {
    return switch (operator) {
        .equals => "equals",
        .not_equals => "does not equal",
        .less_than => "less than",
        .less_than_or_equal => "less than or equal",
        .greater_than => "greater than",
        .greater_than_or_equal => "greater than or equal",
        .contains => "contains",
        .starts_with => "starts with",
        .is_null => "is NULL",
        .is_not_null => "is not NULL",
    };
}

fn writeHex(writer: *std.Io.Writer, bytes: []const u8) !void {
    const digits = "0123456789ABCDEF";
    for (bytes, 0..) |byte, index| {
        if (index != 0) try writer.writeByte(' ');
        try writer.writeByte(digits[byte >> 4]);
        try writer.writeByte(digits[byte & 0x0f]);
    }
}

fn writeModifiedTime(writer: *std.Io.Writer, seconds: i64) !void {
    if (seconds < 0) {
        try writer.print("{d}", .{seconds});
        return;
    }
    const epoch = std.time.epoch.EpochSeconds{ .secs = @intCast(seconds) };
    const year_day = epoch.getEpochDay().calculateYearDay();
    const month_day = year_day.calculateMonthDay();
    const day_seconds = epoch.getDaySeconds();
    const month = month_day.month.numeric();
    const day = month_day.day_index + 1;
    const hour = day_seconds.getHoursIntoDay();
    const minute = day_seconds.getMinutesIntoHour();
    const second = day_seconds.getSecondsIntoMinute();
    try writer.print(
        "<time datetime=\"{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}Z\">{d:0>4}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2} UTC</time>",
        .{ year_day.year, month, day, hour, minute, second, year_day.year, month, day, hour, minute },
    );
}

fn urlComponent(writer: *std.Io.Writer, value: []const u8) !void {
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

pub fn errorPage(
    allocator: std.mem.Allocator,
    registry: *const config.Registry,
    database: ?*const config.DatabaseConfig,
    status: std.http.Status,
    title: []const u8,
    message: []const u8,
    request_id: u64,
) ![]u8 {
    var output: std.Io.Writer.Allocating = .init(allocator);
    errdefer output.deinit();
    const writer = &output.writer;
    const page_title = try std.fmt.allocPrint(allocator, "{s} · dbui", .{title});
    try shellStart(writer, page_title, registry, database, .overview, null);
    try writer.writeAll("<main class=\"main\"><section class=\"problem\"><p class=\"eyebrow\">");
    try writer.print("{d}", .{@backingInt(status)});
    try writer.writeAll("</p><h1>");
    try html.text(writer, title);
    try writer.writeAll("</h1><p>");
    try html.text(writer, message);
    try writer.print("</p><p class=\"meta\">Request {d}</p></section></main>", .{request_id});
    try shellEnd(writer);
    return output.toOwnedSlice();
}

fn shellStart(
    writer: *std.Io.Writer,
    title: []const u8,
    registry: *const config.Registry,
    current: ?*const config.DatabaseConfig,
    active: Section,
    sidebar_view: ?Sidebar,
) !void {
    try html.documentStart(writer, .{
        .title = title,
        .head = .audited("<link rel=\"icon\" href=\"data:,\"><link rel=\"stylesheet\" href=\"/assets/app.css\"><script src=\"/assets/app.js\" defer></script>"),
    });
    try writer.writeAll("<header class=\"topbar\"><a class=\"brand\" href=\"/\">dbui</a>");
    if (current) |database| {
        try writer.writeAll("<details class=\"database-switcher\"><summary>");
        try html.text(writer, database.label);
        try writer.writeAll("</summary><ul>");
        for (registry.databases) |candidate| {
            try writer.writeAll("<li><a href=\"/db/");
            try html.attribute(writer, candidate.id);
            try writer.writeAll("\">");
            try html.text(writer, candidate.label);
            try writer.writeAll("</a></li>");
        }
        try writer.writeAll("</ul></details>");
        try modeBadge(writer, database);
        try writer.writeAll("<nav class=\"sections\" aria-label=\"Database views\">");
        const selected_object = if (sidebar_view) |value| value.current_object orelse firstObject(value.objects) else null;
        const preserve_internal = if (sidebar_view) |value| value.show_internal else false;
        try sectionLink(writer, database.id, "", "Overview", active == .overview, null, preserve_internal);
        try sectionLink(writer, database.id, "/data", "Data", active == .data, selected_object, preserve_internal);
        try sectionLink(writer, database.id, "/schema", "Schema", active == .schema, selected_object, preserve_internal);
        try sectionLink(writer, database.id, "/query", "Query", active == .query, null, preserve_internal);
        try writer.writeAll("</nav>");
    }
    try writer.writeAll("</header><div class=\"app-shell\">");
    if (sidebar_view) |value| try renderSidebar(writer, value, active);
}

fn shellEnd(writer: *std.Io.Writer) !void {
    try writer.writeAll("</div>");
    try html.documentEnd(writer);
}

fn sectionLink(
    writer: *std.Io.Writer,
    id: []const u8,
    suffix: []const u8,
    label: []const u8,
    current: bool,
    object: ?[]const u8,
    show_internal: bool,
) !void {
    try writer.writeAll("<a href=\"/db/");
    try html.attribute(writer, id);
    try html.attribute(writer, suffix);
    if (object) |name| {
        try writer.writeAll("?object=");
        try urlComponent(writer, name);
    }
    if (show_internal) try writer.writeAll(if (object == null) "?internal=1" else "&amp;internal=1");
    if (current) try writer.writeAll("\" aria-current=\"page\">") else try writer.writeAll("\">");
    try html.text(writer, label);
    try writer.writeAll("</a>");
}

fn firstObject(objects: []const schema.ObjectMeta) ?[]const u8 {
    for (objects) |object| {
        if (!object.internal) return object.name;
    }
    return if (objects.len == 0) null else objects[0].name;
}

fn renderSidebar(writer: *std.Io.Writer, sidebar: Sidebar, active: Section) !void {
    try writer.writeAll("<aside class=\"sidebar\"><details class=\"sidebar-disclosure\" open><summary>Objects</summary><div class=\"sidebar-body\"><form class=\"object-search\" method=\"get\" action=\"/db/");
    try html.attribute(writer, sidebar.database.id);
    try writer.writeAll(switch (active) {
        .schema => "/schema",
        .query => "/query",
        .overview => "",
        .data => "/data",
    });
    try writer.writeAll("\"><label for=\"object-search\">Search objects</label><input id=\"object-search\" data-object-search name=\"q\" type=\"search\" value=\"");
    try html.attribute(writer, sidebar.search);
    try writer.writeAll("\" placeholder=\"Search objects…\">");
    if (sidebar.current_object) |name| {
        try writer.writeAll("<input type=\"hidden\" name=\"object\" value=\"");
        try html.attribute(writer, name);
        try writer.writeAll("\">");
    }
    if (sidebar.show_internal) try writer.writeAll("<input type=\"hidden\" name=\"internal\" value=\"1\">");
    try writer.writeAll("<button type=\"submit\">Search</button></form>");
    try objectGroup(writer, sidebar, active, .table, "Tables", false);
    try objectGroup(writer, sidebar, active, .view, "Views", false);
    try objectGroup(writer, sidebar, active, .virtual, "Virtual", false);
    try objectGroup(writer, sidebar, active, .shadow, "Internal", true);
    try writer.writeAll("<a class=\"internal-toggle\" href=\"/db/");
    try html.attribute(writer, sidebar.database.id);
    try writer.writeAll(switch (active) {
        .schema => "/schema?",
        .query => "/query?",
        .overview => "?",
        .data => "/data?",
    });
    var has_parameter = false;
    if (sidebar.current_object) |name| {
        try writer.writeAll("object=");
        try urlComponent(writer, name);
        has_parameter = true;
    }
    if (sidebar.search.len != 0) {
        if (has_parameter) try writer.writeAll("&amp;");
        try writer.writeAll("q=");
        try urlComponent(writer, sidebar.search);
        has_parameter = true;
    }
    if (!sidebar.show_internal) {
        if (has_parameter) try writer.writeAll("&amp;");
        try writer.writeAll("internal=1");
    }
    try writer.writeAll("\">");
    try writer.writeAll(if (sidebar.show_internal) "Hide internal objects" else "Show internal objects");
    try writer.writeAll("</a></div></details></aside>");
}

test "modified timestamps render as human UTC with machine-readable datetime" {
    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    try writeModifiedTime(&output.writer, 1781655600);
    try std.testing.expectEqualStrings(
        "<time datetime=\"2026-06-17T00:20:00Z\">2026-06-17 00:20 UTC</time>",
        output.written(),
    );
}

fn objectGroup(
    writer: *std.Io.Writer,
    sidebar: Sidebar,
    active: Section,
    kind: schema.ObjectKind,
    title: []const u8,
    internal_only: bool,
) !void {
    var count: usize = 0;
    for (sidebar.objects) |object| {
        const matches = if (internal_only) object.internal else object.kind == kind and !object.internal;
        if (matches) count += 1;
    }
    if (count == 0) return;
    try writer.writeAll("<section class=\"object-group\"><h2>");
    try html.text(writer, title);
    try writer.writeAll("</h2><ul>");
    for (sidebar.objects) |object| {
        const matches = if (internal_only) object.internal else object.kind == kind and !object.internal;
        if (!matches) continue;
        try writer.writeAll("<li data-object-name=\"");
        try html.attribute(writer, object.name);
        try writer.writeAll("\"><a href=\"/db/");
        try html.attribute(writer, sidebar.database.id);
        try writer.writeAll(if (active == .schema) "/schema?object=" else "/data?object=");
        try urlComponent(writer, object.name);
        if (sidebar.show_internal) try writer.writeAll("&amp;internal=1");
        if (sidebar.search.len != 0) {
            try writer.writeAll("&amp;q=");
            try urlComponent(writer, sidebar.search);
        }
        if (sidebar.current_object) |current| {
            if (std.mem.eql(u8, current, object.name)) try writer.writeAll("\" aria-current=\"page");
        }
        try writer.writeAll("\">");
        try html.text(writer, object.name);
        try writer.writeAll("</a></li>");
    }
    try writer.writeAll("</ul></section>");
}

fn modeBadge(writer: *std.Io.Writer, database: *const config.DatabaseConfig) !void {
    try writer.writeAll("<span class=\"mode mode--");
    try writer.writeAll(if (database.mode == .read_write) "write" else "read");
    try writer.writeAll("\">");
    try writer.writeAll(database.mode.label());
    try writer.writeAll("</span>");
}

fn factText(writer: *std.Io.Writer, name: []const u8, value: []const u8) !void {
    try writer.writeAll("<div><dt>");
    try html.text(writer, name);
    try writer.writeAll("</dt><dd>");
    try html.text(writer, value);
    try writer.writeAll("</dd></div>");
}

fn writeSize(writer: *std.Io.Writer, bytes: u64) !void {
    if (bytes < 1024) return writer.print("{d} B", .{bytes});
    if (bytes < 1024 * 1024) return writer.print("{d:.1} KiB", .{@as(f64, @floatFromInt(bytes)) / 1024.0});
    if (bytes < 1024 * 1024 * 1024) return writer.print("{d:.1} MiB", .{@as(f64, @floatFromInt(bytes)) / (1024.0 * 1024.0)});
    return writer.print("{d:.1} GiB", .{@as(f64, @floatFromInt(bytes)) / (1024.0 * 1024.0 * 1024.0)});
}
