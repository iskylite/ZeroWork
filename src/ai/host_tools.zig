//! Host authority and receipts are independent of plugin SessionHandle owners.
const std = @import("std");
const identity = @import("../host/identity.zig");
const scope = @import("tool_scope.zig");
const provider = @import("provider.zig");

pub const ChildOrigin = struct {
    agent: identity.AgentId,
    parent: @import("session_input.zig").Fence,
    worker_generation: u64,
    scope_revision: u64,
};
pub const Context = struct {
    conversation_id: identity.ConversationId,
    task_id: identity.TaskId,
    binding: scope.Owner,
    binding_revision: u64,
    grant_revision: u64,
    child_origin: ?ChildOrigin = null,

    pub fn jsonStringify(self: Context, writer: *std.json.Stringify) !void {
        try writer.beginObject();
        inline for (@typeInfo(Context).@"struct".field_names) |name| {
            const emit = if (comptime std.mem.eql(u8, name, "child_origin")) self.child_origin != null else true;
            if (emit) {
                try writer.objectField(name);
                try writer.write(@field(self, name));
            }
        }
        try writer.endObject();
    }
    pub fn validate(self: Context) !void {
        if (!self.conversation_id.valid() or !self.task_id.valid() or self.binding_revision == 0 or self.grant_revision == 0) return error.InvalidHostAuthority;
        if (self.child_origin) |origin| {
            if (!origin.agent.valid() or !origin.parent.agent.valid() or !origin.parent.conversation.valid() or origin.parent.binding == 0 or origin.parent.environment == 0 or origin.worker_generation == 0 or origin.scope_revision == 0 or origin.parent.conversation.eql(self.conversation_id)) return error.InvalidHostAuthority;
        }
        switch (self.binding) {
            .session => |id| if (id == 0) return error.InvalidHostAuthority,
            .group => |id| if (id == 0) return error.InvalidHostAuthority,
        }
    }
    pub fn eql(self: Context, other: Context) bool {
        return self.conversation_id.eql(other.conversation_id) and self.task_id.eql(other.task_id) and self.binding.eql(other.binding) and self.binding_revision == other.binding_revision and self.grant_revision == other.grant_revision and std.meta.eql(self.child_origin, other.child_origin);
    }
};
/// Contributed by the trusted host, never by a provider manifest.
pub const Contribution = struct {
    definition: @import("plugin_tools.zig").ToolDefinition,
    authority: provider.ToolAuthority,
    /// Exact capable sources captured by the controller, independently for
    /// terminal reads, PTY execution and shell attachment. Null uses the legacy
    /// terminal-read projection; an explicit empty set advertises no sources.
    session_targets: ?[]const identity.SessionHandle = null,
};
pub const Invocation = struct {
    dispatch_fence: ?provider.DispatchFence = null,
    /// Reconnect can observe an existing automatic attempt across a transport
    /// transition. Starting a connection still requires this stricter fence.
    mutation_fence: ?provider.DispatchFence = null,
    workspace_revision: ?u64 = null,
    terminal_target: ?identity.SessionHandle = null,
    context: Context,
    authority: provider.ToolAuthority,
    operation_id: u64,
    turn_id: u64,
    call_id: []const u8,
    tool_id: []const u8,
    arguments: std.json.Value,
    arguments_json: []const u8,
    /// Raw wire correlation hash. Lifecycle journaling must separately hash
    /// canonical validated arguments before accepting an idempotency key.
    arguments_hash: [32]u8,
    canonical_arguments_hash: [32]u8,
    /// An internal exact approval token. Never parsed from model arguments or
    /// serialized into provider tool definitions.
    approval_sequence: ?u64 = null,
};
pub const Receipt = struct {
    conversation_id: identity.ConversationId,
    task_id: identity.TaskId,
    operation_id: u64,
    binding_revision: u64,
    local_released: bool = true,
    side_effect_started: bool = false,
    remote_effect_unknown: bool = false,
};
pub const Block = union(enum) { text: []const u8, structured: []const u8 };
pub const DeliveryCheck = struct {
    context: *anyopaque,
    verify: *const fn (*anyopaque) anyerror!void,
    release: *const fn (*anyopaque, std.mem.Allocator) void,
};
pub const Result = struct {
    verification: ?@import("readonly_verification.zig").Anchor = null,
    /// Exact terminal generation of an unknown remote execution, when known.
    uncertain_terminal: ?@import("../host/identity.zig").SessionHandle = null,
    /// Exact old generation and its ready successor, attested by the host.
    reconnected: ?struct { previous: @import("../host/identity.zig").SessionHandle, current: @import("../host/identity.zig").SessionHandle } = null,
    status: @import("plugin_tools.zig").Status,
    blocks: []const Block = &.{},
    images: []@import("image_attachments.zig").ContentRef = &.{},
    receipt: Receipt,
    /// Volatile local authorization for the transcript delivery boundary.
    /// This metadata is owned with the result and never enters the model wire.
    delivery_check: ?DeliveryCheck = null,

    pub fn validate(self: Result, context: Context, operation_id: u64) !void {
        if (!self.receipt.conversation_id.eql(context.conversation_id) or !self.receipt.task_id.eql(context.task_id) or self.receipt.operation_id != operation_id or self.receipt.binding_revision != context.binding_revision or self.blocks.len > 32) return error.InvalidHostToolResult;
        if (self.images.len > 32) return error.InvalidHostToolResult;
        for (self.images) |ref| if (ref.content() == null) return error.InvalidHostToolResult;
        var bytes: usize = 0;
        for (self.blocks) |block| {
            const value = switch (block) {
                .text, .structured => |text| text,
            };
            if (!std.unicode.utf8ValidateSlice(value)) return error.InvalidHostToolResult;
            bytes = std.math.add(usize, bytes, value.len) catch return error.ToolResultTooLarge;
            if (bytes > 64 * 1024) return error.ToolResultTooLarge;
            if (block == .structured) {
                const parsed = try std.json.parseFromSlice(std.json.Value, std.heap.page_allocator, value, .{});
                parsed.deinit();
            }
        }
        if (self.status == .succeeded and (!self.receipt.local_released or self.receipt.remote_effect_unknown)) return error.InvalidHostToolResult;
    }
    pub fn deinit(self: *Result, allocator: std.mem.Allocator) void {
        if (self.delivery_check) |check| check.release(check.context, allocator);
        for (self.blocks) |block| switch (block) {
            .text, .structured => |text| allocator.free(text),
        };
        allocator.free(self.blocks);
        for (self.images) |*ref| ref.release();
        allocator.free(self.images);
        self.* = undefined;
    }
};
