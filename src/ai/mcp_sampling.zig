const std = @import("std");
const provider = @import("provider.zig");
const interaction = @import("mcp_interaction.zig");
pub fn generate(a: std.mem.Allocator, backend: provider.Provider, model: []const u8, max_output: u32, params: std.json.Value, cancel: ?*provider.CancelToken) ![]u8 {
    const wire = params.object.get("messages") orelse return error.InvalidMcpSamplingRequest;
    const maximum = params.object.get("maxTokens") orelse return error.InvalidMcpSamplingRequest;
    if (wire != .array or wire.array.items.len == 0 or maximum != .integer or maximum.integer <= 0) return error.InvalidMcpSamplingRequest;
    const limit: u32 = @intCast(@min(maximum.integer, max_output));
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const owned = arena.allocator();
    var messages: std.ArrayList(provider.Message) = .empty;
    var refs: std.ArrayList(@import("image_attachments.zig").ContentRef) = .empty;
    defer for (refs.items) |*ref| ref.release();
    for (wire.array.items) |item| {
        const role = interaction.string(item, "role") orelse return error.InvalidMcpSamplingRequest;
        if (!std.mem.eql(u8, role, "user") and !std.mem.eql(u8, role, "assistant")) return error.InvalidMcpSamplingRequest;
        const content = item.object.get("content") orelse return error.InvalidMcpSamplingRequest;
        const blocks = if (content == .array) content.array.items else &.{content};
        var text: std.ArrayList(u8) = .empty;
        var images: std.ArrayList(@import("image_attachments.zig").ContentRef) = .empty;
        for (blocks) |block| {
            const kind = interaction.string(block, "type") orelse return error.InvalidMcpSamplingRequest;
            if (std.mem.eql(u8, kind, "text")) {
                if (text.items.len != 0) try text.append(owned, '\n');
                try text.appendSlice(owned, interaction.string(block, "text") orelse return error.InvalidMcpSamplingRequest);
            } else if (std.mem.eql(u8, kind, "image")) {
                const encoded = interaction.string(block, "data") orelse return error.InvalidMcpSamplingRequest;
                const size = try std.base64.standard.Decoder.calcSizeForSlice(encoded);
                const bytes = try owned.alloc(u8, size);
                try std.base64.standard.Decoder.decode(bytes, encoded);
                const ref = try @import("image_attachments.zig").ContentRef.create(a, "mcp-sampling", bytes, 0, .{});
                try refs.append(owned, ref);
                try images.append(owned, ref);
            } else return error.McpSamplingContentNotSupported;
        }
        try messages.append(owned, .{ .role = if (std.mem.eql(u8, role, "user")) .user else .assistant, .content = text.items, .images = images.items });
    }
    const Capture = struct {
        a: std.mem.Allocator,
        text: std.ArrayList(u8) = .empty,
        problem: ?anyerror = null,
        fn receive(raw: *anyopaque, delta: provider.Delta) void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            switch (delta) {
                .text => |text| {
                    if (self.text.items.len + text.len > 256 * 1024) {
                        self.problem = error.McpSamplingResultLimit;
                        return;
                    }
                    self.text.appendSlice(self.a, text) catch {
                        self.problem = error.OutOfMemory;
                    };
                },
                .err => self.problem = error.McpSamplingProviderFailure,
                .tool_plan => self.problem = error.McpSamplingToolsNotNegotiated,
                else => {},
            }
        }
    };
    var capture: Capture = .{ .a = owned };
    // A dedicated, tool-free request: includeContext never leaks host history.
    const stats = try backend.chat(backend.ctx, .{ .model = model, .system = interaction.string(params, "systemPrompt") orelse "", .messages = messages.items, .max_output = limit, .vision = refs.items.len != 0, .cancel = cancel }, Capture.receive, &capture);
    if (capture.problem) |problem| return problem;
    return std.json.Stringify.valueAlloc(a, .{ .model = model, .role = "assistant", .content = .{ .type = "text", .text = capture.text.items }, .stopReason = if (stats.usage_reported and stats.output_tokens >= limit) "maxTokens" else "endTurn" }, .{});
}
