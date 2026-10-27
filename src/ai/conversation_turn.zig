//! A user submission owns its display steps and exact model context boundaries.
const std = @import("std");
const wire = @import("wire_history.zig");
const events = @import("step_events.zig");
pub const Turn = struct {
    id: u64 = 0,
    sent_at_ms: u64 = 0,
    ended_at_ms: ?u64 = null,
    started_mono_ms: u64 = 0,
    elapsed_ms: u64 = 0,
    input_tokens: ?u64 = null,
    output_tokens: ?u64 = null,
    before: wire.History = .{},
    after: wire.History = .{},
    answer: []u8 = &.{},
    thinking: std.ArrayList(u8) = .empty,
    thinking_started_ms: ?u64 = null,
    thinking_ended_ms: ?u64 = null,
    thinking_expanded: bool = false,
    steps: std.ArrayList(events.Step) = .empty,
    pub fn deinit(self: *Turn, a: std.mem.Allocator) void {
        self.before.deinit();
        self.after.deinit();
        a.free(self.answer);
        self.thinking.deinit(a);
        for (self.steps.items) |*step| step.deinit(a);
        self.steps.deinit(a);
        self.* = .{};
    }
    pub fn clone(self: *const Turn, a: std.mem.Allocator) !Turn {
        var result: Turn = .{ .id = self.id, .sent_at_ms = self.sent_at_ms, .ended_at_ms = self.ended_at_ms, .started_mono_ms = self.started_mono_ms, .elapsed_ms = self.elapsed_ms, .input_tokens = self.input_tokens, .output_tokens = self.output_tokens, .thinking_started_ms = self.thinking_started_ms, .thinking_ended_ms = self.thinking_ended_ms, .thinking_expanded = self.thinking_expanded };
        errdefer result.deinit(a);
        result.before = try wire.History.copy(a, self.before.messages, "");
        result.after = try wire.History.copy(a, self.after.messages, "");
        result.answer = try a.dupe(u8, self.answer);
        try result.thinking.appendSlice(a, self.thinking.items);
        for (self.steps.items) |step| {
            var copy = try step.clone(a);
            result.steps.append(a, copy) catch |err| {
                copy.deinit(a);
                return err;
            };
        }
        return result;
    }
};
