//! MCP 2026-07-28 x-mcp-header declarations. Only static properties paths
//! can mirror primitive values; names are unique and use RFC 9110 tokens.
const std = @import("std");
const string = @import("mcp_interaction.zig").string;
pub const Declaration = struct { name: []const u8, path: []const []const u8 };
pub fn declarations(a: std.mem.Allocator, schema: std.json.Value) ![]const Declaration {
    var found: std.ArrayList(Declaration) = .empty;
    var path: std.ArrayList([]const u8) = .empty;
    try walk(a, schema, &path, &found, 0);
    return found.items;
}
fn contains(value: std.json.Value, depth: usize) !bool {
    if (depth > 64) return error.InvalidMcpHeaderSchema;
    switch (value) {
        .object => |object| {
            if (object.contains("x-mcp-header")) return true;
            var it = object.iterator();
            while (it.next()) |entry| if (try contains(entry.value_ptr.*, depth + 1)) return true;
        },
        .array => |list| for (list.items) |item| {
            if (try contains(item, depth + 1)) return true;
        },
        else => {},
    }
    return false;
}
fn walk(a: std.mem.Allocator, schema: std.json.Value, path: *std.ArrayList([]const u8), found: *std.ArrayList(Declaration), depth: usize) !void {
    if (depth > 64) return error.InvalidMcpHeaderSchema;
    if (schema != .object) return;
    if (schema.object.get("x-mcp-header")) |annotation| {
        if (annotation != .string or annotation.string.len == 0 or path.items.len == 0) return error.InvalidMcpHeaderSchema;
        const name = annotation.string;
        for (name) |c| if (!std.ascii.isAlphanumeric(c) and std.mem.indexOfScalar(u8, "!#$%&'*+-.^_`|~", c) == null) return error.InvalidMcpHeaderSchema;
        const kind = string(schema, "type") orelse return error.InvalidMcpHeaderSchema;
        if (!std.mem.eql(u8, kind, "string") and !std.mem.eql(u8, kind, "integer") and !std.mem.eql(u8, kind, "boolean")) return error.InvalidMcpHeaderSchema;
        for (found.items) |old| if (std.ascii.eqlIgnoreCase(old.name, name)) return error.InvalidMcpHeaderSchema;
        try found.append(a, .{ .name = name, .path = try a.dupe([]const u8, path.items) });
    }
    var it = schema.object.iterator();
    while (it.next()) |entry| {
        if (std.mem.eql(u8, entry.key_ptr.*, "properties")) {
            if (entry.value_ptr.* != .object) continue;
            var properties = entry.value_ptr.object.iterator();
            while (properties.next()) |property| {
                try path.append(a, property.key_ptr.*);
                defer _ = path.pop();
                try walk(a, property.value_ptr.*, path, found, depth + 1);
            }
        } else {
            // These keywords contain schemas. Annotation values and enum/const
            // examples are data and must not be interpreted as declarations.
            inline for (.{ "items", "prefixItems", "additionalItems", "additionalProperties", "unevaluatedProperties", "unevaluatedItems", "contains", "anyOf", "oneOf", "allOf", "not", "if", "then", "else", "$defs", "definitions", "patternProperties", "dependentSchemas", "propertyNames" }) |keyword| {
                if (std.mem.eql(u8, entry.key_ptr.*, keyword) and try contains(entry.value_ptr.*, depth + 1)) return error.InvalidMcpHeaderSchema;
            }
        }
    }
}
pub fn append(a: std.mem.Allocator, schema: std.json.Value, arguments: std.json.Value, headers: *std.ArrayList([*:0]const u8)) !void {
    for (try declarations(a, schema)) |declaration| {
        var value = arguments;
        for (declaration.path) |part| {
            if (value != .object) {
                value = .null;
                break;
            }
            value = value.object.get(part) orelse .null;
        }
        if (value == .null) continue;
        const raw = switch (value) {
            .string => |text| text,
            .bool, .integer => try std.json.Stringify.valueAlloc(a, value, .{}),
            else => return error.InvalidMcpHeaderValue,
        };
        const encoded = needs_encoding: {
            for (raw) |c| if (c < 32 or c > 126) break :needs_encoding true;
            break :needs_encoding std.mem.startsWith(u8, raw, "=?base64?");
        };
        const text = if (encoded) encode: {
            const bytes = try a.alloc(u8, std.base64.standard.Encoder.calcSize(raw.len));
            break :encode try std.fmt.allocPrint(a, "=?base64?{s}?=", .{std.base64.standard.Encoder.encode(bytes, raw)});
        } else raw;
        try headers.append(a, (try std.fmt.allocPrintSentinel(a, "Mcp-Param-{s}: {s}", .{ declaration.name, text }, 0)).ptr);
    }
}

test "v0.4 extensions modern header mappings cover nested Unicode and reject ambiguous declarations" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const schema = (try std.json.parseFromSlice(std.json.Value, a, "{\"type\":\"object\",\"properties\":{\"filter\":{\"type\":\"object\",\"properties\":{\"region\":{\"type\":\"string\",\"x-mcp-header\":\"Region\"}}},\"flag\":{\"type\":\"boolean\",\"x-mcp-header\":\"Flag\"}}}", .{})).value;
    const arguments = (try std.json.parseFromSlice(std.json.Value, a, "{\"filter\":{\"region\":\"华北\\r\\n\"},\"flag\":true}", .{})).value;
    var headers: std.ArrayList([*:0]const u8) = .empty;
    try append(a, schema, arguments, &headers);
    try std.testing.expectEqual(@as(usize, 2), headers.items.len);
    try std.testing.expect(std.mem.startsWith(u8, std.mem.span(headers.items[0]), "Mcp-Param-Region: =?base64?"));
    try std.testing.expect(std.mem.indexOfAny(u8, std.mem.span(headers.items[0]), "\r\n") == null);
    try std.testing.expectEqualStrings("Mcp-Param-Flag: true", std.mem.span(headers.items[1]));
    const enum_data = (try std.json.parseFromSlice(std.json.Value, a, "{\"properties\":{\"a\":{\"enum\":[{\"x-mcp-header\":\"data\"}]}}}", .{})).value;
    try std.testing.expectEqual(@as(usize, 0), (try declarations(a, enum_data)).len);
    for ([_][]const u8{
        "{\"properties\":{\"a\":{\"type\":\"string\",\"x-mcp-header\":\"X\"},\"b\":{\"type\":\"string\",\"x-mcp-header\":\"x\"}}}",
        "{\"properties\":{\"a\":{\"type\":\"number\",\"x-mcp-header\":\"X\"}}}",
        "{\"anyOf\":[{\"properties\":{\"a\":{\"type\":\"string\",\"x-mcp-header\":\"X\"}}}]}",
        "{\"properties\":{\"a\":{\"type\":\"string\",\"x-mcp-header\":\"bad name\"}}}",
    }) |bad| {
        const value = (try std.json.parseFromSlice(std.json.Value, a, bad, .{})).value;
        try std.testing.expectError(error.InvalidMcpHeaderSchema, declarations(a, value));
    }
}
