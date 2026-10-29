//! Host authority and receipts are independent of plugin SessionHandle owners.
const std = @import("std");
const identity = @import("../host/identity.zig");
const scope = @import("tool_scope.zig");
const provider = @import("provider.zig");

pub const Context = struct {
    conversation_id: identity.ConversationId,
    task_id: identity.TaskId,
    binding: scope.Owner,
    binding_revision: u64,
    grant_revision: u64,

    pub fn validate(self: Context) !void {
        if (!self.conversation_id.valid() or !self.task_id.valid() or self.binding_revision == 0 or self.grant_revision == 0) return error.InvalidHostAuthority;
        switch (self.binding) {
            .session => |id| if (id == 0) return error.InvalidHostAuthority,
            .group => |id| if (id == 0) return error.InvalidHostAuthority,
        }
    }
    pub fn eql(self: Context, other: Context) bool {
        return self.conversation_id.eql(other.conversation_id) and self.task_id.eql(other.task_id) and self.binding.eql(other.binding) and self.binding_revision == other.binding_revision and self.grant_revision == other.grant_revision;
    }
};
/// Contributed by the trusted host, never by a provider manifest.
pub const Contribution = struct {
    definition: @import("plugin_tools.zig").ToolDefinition,
    authority: provider.ToolAuthority,
};
pub const Invocation = struct {
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
pub const Result = struct {
    status: @import("plugin_tools.zig").Status,
    blocks: []const Block = &.{},
    receipt: Receipt,

    pub fn validate(self: Result, context: Context, operation_id: u64) !void {
        if (!self.receipt.conversation_id.eql(context.conversation_id) or !self.receipt.task_id.eql(context.task_id) or self.receipt.operation_id != operation_id or self.receipt.binding_revision != context.binding_revision or self.blocks.len > 32) return error.InvalidHostToolResult;
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
        for (self.blocks) |block| switch (block) {
            .text, .structured => |text| allocator.free(text),
        };
        allocator.free(self.blocks);
        self.* = undefined;
    }
};
