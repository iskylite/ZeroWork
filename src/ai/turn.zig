const std = @import("std");
pub const State = enum { idle, gathering, streaming, await_confirm, executing, done, aborting };
pub const Turn = struct {
    state: State = .idle,
    scratchpad: std.ArrayList(u32) = .empty,
    allocator: std.mem.Allocator,
    pub fn init(allocator: std.mem.Allocator) Turn {
        return .{ .allocator = allocator };
    }
    pub fn deinit(self: *Turn) void {
        self.scratchpad.deinit(self.allocator);
        self.* = undefined;
    }
    pub fn resetForRun(self: *Turn) !void {
        if (self.state == .done) {
            self.state = .idle;
            self.scratchpad.clearRetainingCapacity();
        }
        if (self.state != .idle) return error.InvalidTransition;
    }

    pub fn begin(self: *Turn) !void {
        if (self.state != .idle) return error.InvalidTransition;
        self.state = .gathering;
    }
    pub fn stream(self: *Turn) !void {
        if (self.state != .gathering) return error.InvalidTransition;
        self.state = .streaming;
    }
    pub fn abort(self: *Turn) void {
        self.state = .aborting;
        self.scratchpad.clearRetainingCapacity();
        self.state = .idle;
    }
    pub fn done(self: *Turn) !void {
        if (self.state != .executing and self.state != .streaming) return error.InvalidTransition;
        self.scratchpad.clearRetainingCapacity();
        self.state = .done;
    }
};
test "turn cleanup invariant clears scratchpad" {
    var t = Turn.init(std.testing.allocator);
    defer t.deinit();
    try t.begin();
    try t.stream();
    try t.done();
    try std.testing.expectEqual(@as(usize, 0), t.scratchpad.items.len);
}
