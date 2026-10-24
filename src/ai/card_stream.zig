const std = @import("std");
const Card = @import("card.zig").Card;
pub const Stream = struct {
    allocator: std.mem.Allocator,
    cards: std.ArrayList(Card) = .empty,
    pub fn init(allocator: std.mem.Allocator) Stream {
        return .{ .allocator = allocator };
    }
    pub fn deinit(self: *Stream) void {
        for (self.cards.items) |card| freeCard(self.allocator, card);
        self.cards.deinit(self.allocator);
        self.* = undefined;
    }
    pub fn append(self: *Stream, card: Card) !usize {
        const owned = try cloneCard(self.allocator, card);
        errdefer freeCard(self.allocator, owned);
        try self.cards.append(self.allocator, owned);
        return self.cards.items.len - 1;
    }

    /// Streaming delta aggregation: append text to the .text card at `index`.
    /// One logical response should be ONE card, not one card per network
    /// chunk (a real mimo turn produced 108 fragment cards before this).
    pub fn appendText(self: *Stream, index: usize, text: []const u8) !void {
        if (index >= self.cards.items.len) return error.CardOutOfBounds;
        const card = &self.cards.items[index];
        if (card.* != .text) return error.NotATextCard;
        const existing = card.text;
        const combined = try self.allocator.alloc(u8, existing.len + text.len);
        @memcpy(combined[0..existing.len], existing);
        @memcpy(combined[existing.len..], text);
        card.* = .{ .text = combined };
        self.allocator.free(existing);
    }
    pub fn clearRetainingCapacity(self: *Stream) void {
        for (self.cards.items) |card| freeCard(self.allocator, card);
        self.cards.clearRetainingCapacity();
    }

    fn cloneBytes(allocator: std.mem.Allocator, value: []const u8) ![]const u8 {
        return try allocator.dupe(u8, value);
    }

    fn cloneCard(allocator: std.mem.Allocator, card: Card) !Card {
        return switch (card) {
            .text => |value| .{ .text = try cloneBytes(allocator, value) },
            .code => |value| .{ .code = .{ .lang = try cloneBytes(allocator, value.lang), .body = try cloneBytes(allocator, value.body) } },
            .exec_plan => |value| .{ .exec_plan = .{ .cmd = try cloneBytes(allocator, value.cmd), .verdict = value.verdict, .call_id = if (value.call_id) |id| try cloneBytes(allocator, id) else null, .tool = value.tool, .owner = value.owner, .targets = value.targets } },
            .exec_state => |value| .{ .exec_state = .{ .handle = value.handle, .phase = value.phase, .exit = value.exit, .elapsed_ms = value.elapsed_ms, .summary = try cloneBytes(allocator, value.summary) } },
            .file_ref => |value| .{ .file_ref = .{ .path = try cloneBytes(allocator, value.path), .head_bytes = value.head_bytes } },
        };
    }

    fn freeCard(allocator: std.mem.Allocator, card: Card) void {
        switch (card) {
            .text => |value| allocator.free(value),
            .code => |value| {
                allocator.free(value.lang);
                allocator.free(value.body);
            },
            .exec_plan => |value| {
                allocator.free(value.cmd);
                if (value.call_id) |id| allocator.free(id);
            },
            .exec_state => |value| allocator.free(value.summary),
            .file_ref => |value| allocator.free(value.path),
        }
    }

    pub fn updateExecution(self: *Stream, call_id: []const u8, state: @import("card.zig").ExecState) !void {
        const index = self.findExecution(call_id) orelse return error.UnknownCall;
        const owned = try cloneCard(self.allocator, .{ .exec_state = state });
        freeCard(self.allocator, self.cards.items[index]);
        self.cards.items[index] = owned;
    }

    pub fn findExecution(self: Stream, call_id: []const u8) ?usize {
        for (self.cards.items, 0..) |card, index| switch (card) {
            .exec_plan => |plan| if (plan.call_id) |id| if (std.mem.eql(u8, id, call_id)) return index,
            else => {},
        };
        return null;
    }

    pub fn count(self: Stream) usize {
        return self.cards.items.len;
    }
};
test "card stream appends incremental cards" {
    var stream = Stream.init(std.testing.allocator);
    defer stream.deinit();
    _ = try stream.append(.{ .text = "hello" });
    _ = try stream.append(.{ .code = .{ .lang = "zig", .body = "const x = 1;" } });
    try std.testing.expectEqual(@as(usize, 2), stream.count());
}

test "card stream aggregates streamed deltas into one card" {
    var stream = Stream.init(std.testing.allocator);
    defer stream.deinit();
    const index = try stream.append(.{ .text = "Hel" });
    try stream.appendText(index, "lo, ");
    try stream.appendText(index, "world!");
    try std.testing.expectEqual(@as(usize, 1), stream.count());
    try std.testing.expectEqualStrings("Hello, world!", stream.cards.items[0].text);
    // Non-text cards reject aggregation.
    const code_index = try stream.append(.{ .code = .{ .lang = "zig", .body = "x" } });
    try std.testing.expectError(error.NotATextCard, stream.appendText(code_index, "!"));
}

test "card stream updates execution state by call id" {
    var stream = Stream.init(std.testing.allocator);
    defer stream.deinit();
    _ = try stream.append(.{ .exec_plan = .{ .cmd = "ls", .verdict = .allow_auto, .call_id = "call-1" } });
    try stream.updateExecution("call-1", .{ .handle = 3, .phase = .done, .exit = 0, .elapsed_ms = 8, .summary = "ok" });
    try std.testing.expectEqual(@import("card.zig").Phase.done, stream.cards.items[0].exec_state.phase);
}

test "card stream finds execution by call id" {
    var stream = Stream.init(std.testing.allocator);
    defer stream.deinit();
    _ = try stream.append(.{ .exec_plan = .{ .cmd = "ls", .verdict = .allow_auto, .call_id = "call-1" } });
    try std.testing.expectEqual(@as(?usize, 0), stream.findExecution("call-1"));
    try std.testing.expectEqual(@as(?usize, null), stream.findExecution("missing"));
}
