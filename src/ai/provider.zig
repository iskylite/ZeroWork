const std = @import("std");
pub const Effort = enum {
    low,
    medium,
    high,
    xhigh,
    max,
    none,
    ultra,

    pub fn lowestSupported(supported: [7]bool) ?Effort {
        for ([_]Effort{ .none, .low, .medium, .high, .xhigh, .max, .ultra }) |effort| {
            if (supported[@backingInt(effort)]) return effort;
        }
        return null;
    }
};
pub const Role = enum { user, assistant, tool };
pub const Tool = @import("tool_scope.zig").Tool;
pub const max_plugin_tool_definitions = 16;
pub const max_host_tool_definitions = 32;
pub const max_tool_definitions = max_plugin_tool_definitions + max_host_tool_definitions;
pub const max_tool_catalog_text_bytes = 96 * 1024;
pub const max_tool_calls = 16;
pub const max_tool_call_id_bytes = 256;
pub const max_tool_name_bytes = 64;
pub const max_tool_arguments_bytes = 64 * 1024;

/// Internal admission metadata. This never becomes a model-supplied parameter
/// and does not by itself authorize dispatch; the captured host table does that.
pub const ToolAuthority = enum { session_targets, conversation_context, lifecycle, execution_control, local_network_read };

/// The host supplies a separate allowed target set for each real capability.
/// Parameter schemas are fixed by Tool; callers cannot inject arbitrary JSON.
pub const ToolDefinition = struct {
    tool: Tool = .read_terminal,
    session_ids: []const u64,
    dynamic: ?DynamicDefinition = null,
    authority: ToolAuthority = .session_targets,
    pub fn name(self: ToolDefinition) []const u8 {
        return if (self.dynamic) |definition| definition.name else @tagName(self.tool);
    }
    pub const DynamicDefinition = struct { id: []const u8, name: []const u8, schema: []const u8, description: []const u8 };
};

/// Shared by initial submission and subsequent tool rounds. The framing
/// allowance is accounted for separately, as with the existing byte/4 estimate.
pub fn catalogTextBytes(definitions: []const ToolDefinition) !usize {
    var bytes: usize = 0;
    for (definitions) |definition| if (definition.dynamic) |dynamic| {
        for ([_][]const u8{ dynamic.name, dynamic.description, dynamic.schema }) |text| {
            bytes = std.math.add(usize, bytes, text.len) catch return error.ToolCatalogLimit;
            if (bytes > max_tool_catalog_text_bytes) return error.ToolCatalogLimit;
        }
    };
    return bytes;
}

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
    /// Retained evidence, never serialized as image input. Offload decisions
    /// belong to this occurrence and survive history copies/model changes.
    offloaded_images: []const OffloadedImage = &.{},
    image_owner: ?@import("../host/identity.zig").SessionHandle = null,
    /// Crop/coordinate mapping identity. Equal pixels do not merge different mappings.
    image_transform: u64 = 0,
    tool_calls: []const ToolCall = &.{},
    tool_call_id: ?[]const u8 = null,
};
pub const OffloadedImage = struct {
    reference: @import("image_attachments.zig").ContentRef,
    owner: ?@import("../host/identity.zig").SessionHandle = null,
};
pub const CancelToken = struct {
    cancelled: std.atomic.Value(bool) = .init(false),
    /// Borrowed for this operation only. The source and its thread-safe poll
    /// must outlive every consumer, including child work through its join.
    source: ?struct {
        context: *const anyopaque,
        poll: *const fn (*const anyopaque) bool,
        /// Human decisions suspend the active-run budget, not Stop or scope checks.
        user_wait: ?*const fn (*const anyopaque, bool) void = null,
    } = null,
    pub const UserWait = struct {
        token: ?*const CancelToken,
        pub fn end(self: UserWait) void {
            if (self.token) |token| if (token.source) |source| if (source.user_wait) |notify| notify(source.context, false);
        }
    };
    /// Worker-owned guard. Always end it, including rejection and cancellation.
    pub fn beginUserWait(self: ?*const CancelToken) UserWait {
        if (self) |token| if (token.source) |source| if (source.user_wait) |notify| notify(source.context, true);
        return .{ .token = self };
    }
    pub fn cancel(self: *CancelToken) void {
        self.cancelled.store(true, .release);
    }
    pub fn isCancelled(self: *const CancelToken) bool {
        return self.cancelled.load(.acquire) or if (self.source) |source| source.poll(source.context) else false;
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
    image_token_max_width: ?u32 = null,
    image_token_max_height: ?u32 = null,
    vision: bool = false,
    max_output: u32 = 4096,
    /// Active automatic-run budget across provider/tool rounds and retries.
    /// Time awaiting an explicit user decision does not consume this budget.
    /// An explicit manual answer retry starts a new budget, retaining results.
    timeout_ms: u32 = 10 * 60_000,
    /// Stream inactivity limit, reset by received bytes.
    idle_timeout_ms: u32 = 60_000,
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
