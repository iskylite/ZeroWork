const std = @import("std");
pub const Effort = enum { low, medium, high, xhigh, max, none, ultra };
pub const Role = enum { user, assistant, tool };
pub const Tool = @import("tool_scope.zig").Tool;
pub const max_tool_definitions = 16;
pub const max_tool_calls = 16;
pub const max_tool_call_id_bytes = 256;
pub const max_tool_name_bytes = 64;
pub const max_tool_arguments_bytes = 64 * 1024;

/// The host supplies a separate allowed target set for each real capability.
/// Parameter schemas are fixed by Tool; callers cannot inject arbitrary JSON.
pub const ToolDefinition = struct {
    tool: Tool = .read_terminal,
    session_ids: []const u64,
    dynamic: ?DynamicDefinition = null,
    pub fn name(self: ToolDefinition) []const u8 {
        return if (self.dynamic) |definition| definition.name else @tagName(self.tool);
    }
    pub const DynamicDefinition = struct { id: []const u8, name: []const u8, schema: []const u8, description: []const u8 };
};

/// A transcript of the provider's original call, not execution authority.
/// Unknown tool names and invalid argument JSON can be retained here so the
/// host can return a structured rejection against the original call ID.
pub const ToolCall = struct {
    id: []const u8,
    name: []const u8,
    arguments: []const u8,
};
pub const Message = struct {
    role: Role = .user,
    content: []const u8,
    images: []const @import("image_attachments.zig").ContentRef = &.{},
    tool_calls: []const ToolCall = &.{},
    tool_call_id: ?[]const u8 = null,
};
pub const CancelToken = struct {
    cancelled: std.atomic.Value(bool) = .init(false),
    pub fn cancel(self: *CancelToken) void {
        self.cancelled.store(true, .release);
    }
    pub fn isCancelled(self: *const CancelToken) bool {
        return self.cancelled.load(.acquire);
    }
};
pub const ReasoningWire = enum { none, thinking_type, openrouter, ollama, anthropic_adaptive };
pub const ChatRequest = struct {
    thinking: ?bool = null,
    native_effort: bool = false,
    reasoning_wire: ReasoningWire = .none,
    model: []const u8,
    effort: ?Effort = null,
    system: []const u8,
    messages: []const Message,
    tools: []const ToolDefinition = &.{},
    tool_table: ?*const @import("plugin_tools.zig").RequestTable = null,
    /// Tool image results are an explicit model capability, separate from text tools.
    tool_images: bool = false,
    /// Explicit conservative admission reservation for image-capable custom
    /// models whose tokenizer is not known locally; never reported as usage.
    image_token_reservation: ?u32 = null,
    vision: bool = false,
    max_output: u32 = 4096,
    timeout_ms: u32 = 60_000,
    cancel: ?*CancelToken = null,
    /// Transport writes a retry hint for this attempt; owned by the caller's
    /// worker thread, and never exposed as a pointer into a response header.
    retry_after_ms: ?*?u32 = null,
};
pub const Delta = union(enum) { text: []const u8, thinking: []const u8, tool_plan: struct { call_id: ?[]const u8, name: ?[]const u8 = null, index: u32 = 0, arguments: []const u8 }, done, err: []const u8 };
pub const ChatStats = struct { input_tokens: u32 = 0, output_tokens: u32 = 0, usage_reported: bool = true };
pub const Provider = struct {
    ctx: *anyopaque,
    chat: *const fn (*anyopaque, ChatRequest, *const fn (*anyopaque, Delta) void, *anyopaque) anyerror!ChatStats,
    models: *const fn (*anyopaque, std.mem.Allocator) anyerror![]ModelInfo,
};
pub const ModelInfo = struct { id: []const u8, context_window: u32 = 8192 };

test "provider schema preserves effort and model window" {
    const model: ModelInfo = .{ .id = "local", .context_window = 4096 };
    const req: ChatRequest = .{ .model = model.id, .effort = .high, .system = "", .messages = &.{} };
    try std.testing.expectEqual(Effort.high, req.effort.?);
    const unspecified: ChatRequest = .{ .model = model.id, .system = "", .messages = &.{} };
    try std.testing.expect(unspecified.effort == null);
    try std.testing.expectEqual(@as(u32, 4096), model.context_window);
    const messages = [_]Message{ .{ .role = .assistant, .content = "answer" }, .{ .role = .tool, .content = "result" } };
    try std.testing.expectEqual(Role.assistant, messages[0].role);
    try std.testing.expectEqual(Role.tool, messages[1].role);
}
