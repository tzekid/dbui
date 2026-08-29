const std = @import("std");
const request = @import("web_request");

pub const Parameters = struct {
    items: []const request.Parameter,

    pub fn get(self: Parameters, name: []const u8) ?[]const u8 {
        for (self.items) |item| {
            if (std.mem.eql(u8, item.name, name)) return item.value;
        }
        return null;
    }

    pub fn has(self: Parameters, name: []const u8) bool {
        return self.get(name) != null;
    }
};

pub fn parseQuery(allocator: std.mem.Allocator, target: request.Target) !Parameters {
    var iterator = request.queryIterator(target, 64);
    return parse(allocator, &iterator, 64 * 1024);
}

pub fn parseForm(allocator: std.mem.Allocator, encoded: []const u8) !Parameters {
    return parseFormLimited(allocator, encoded, 64 * 1024);
}

pub fn parseFormLimited(allocator: std.mem.Allocator, encoded: []const u8, decoded_limit: usize) !Parameters {
    var iterator = request.formIterator(encoded, 64);
    return parse(allocator, &iterator, decoded_limit);
}

fn parse(allocator: std.mem.Allocator, iterator: *request.ParameterIterator, decoded_limit: usize) !Parameters {
    var items: std.ArrayList(request.Parameter) = .empty;
    var decoded_total: usize = 0;
    while (try iterator.next()) |encoded| {
        const name_storage = try allocator.alloc(u8, encoded.name.len);
        const value_storage = try allocator.alloc(u8, encoded.value.len);
        const name = try request.decodeComponent(name_storage, encoded.name, true);
        const value = try request.decodeComponent(value_storage, encoded.value, true);
        decoded_total = std.math.add(usize, decoded_total, name.len + value.len) catch
            return error.ParametersTooLarge;
        if (decoded_total > decoded_limit) return error.ParametersTooLarge;
        for (items.items) |existing| {
            if (std.mem.eql(u8, existing.name, name)) return error.DuplicateParameter;
        }
        try items.append(allocator, .{ .name = name, .value = value });
    }
    return .{ .items = try items.toOwnedSlice(allocator) };
}

test "query parsing decodes once and rejects ambiguity" {
    const target = try request.Target.parse("/x?object=odd+table&direction=asc", 128);
    const parsed = try parseQuery(std.testing.allocator, target);
    defer {
        for (parsed.items) |item| {
            std.testing.allocator.free(item.name);
            std.testing.allocator.free(item.value);
        }
        std.testing.allocator.free(parsed.items);
    }
    try std.testing.expectEqualStrings("odd table", parsed.get("object").?);
    try std.testing.expectEqualStrings("asc", parsed.get("direction").?);

    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const duplicate = try request.Target.parse("/x?a=1&a=2", 128);
    try std.testing.expectError(error.DuplicateParameter, parseQuery(arena_state.allocator(), duplicate));
}
