//! MCP schemas use a full JSON Schema validator, separate from the compact
//! schema subset used to register the host's own static tools.
const std = @import("std");
extern fn zw_mcp_schema_create([*:0]const u8) ?*anyopaque;
extern fn zw_mcp_schema_close(*anyopaque) void;
extern fn zw_mcp_schema_validate(*anyopaque, [*:0]const u8, ?[*:0]const u8) c_int;
pub const Validator = struct {
    context: ?*anyopaque = null,
    pub fn deinit(self: *Validator) void {
        if (self.context) |ctx| zw_mcp_schema_close(ctx);
        self.context = null;
    }
    pub fn validate(self: *Validator, a: std.mem.Allocator, schema: []const u8, instance: ?std.json.Value) !void {
        if (!std.unicode.utf8ValidateSlice(schema) or std.mem.indexOfScalar(u8, schema, 0) != null) return error.InvalidMcpSchema;
        if (self.context == null) self.context = zw_mcp_schema_create(@embedFile("vendor/mcp_schema.js")) orelse return error.McpSchemaValidatorUnavailable;
        const schema_z = try a.dupeSentinel(u8, schema, 0);
        defer a.free(schema_z);
        const encoded = if (instance) |value| try std.json.Stringify.valueAlloc(a, value, .{}) else null;
        defer if (encoded) |bytes| a.free(bytes);
        const instance_z = if (encoded) |bytes| try a.dupeSentinel(u8, bytes, 0) else null;
        defer if (instance_z) |bytes| a.free(bytes);
        switch (zw_mcp_schema_validate(self.context.?, schema_z, if (instance_z) |bytes| bytes.ptr else null)) {
            1 => {},
            0 => return error.InvalidToolArguments,
            else => return error.InvalidMcpSchema,
        }
    }
};
