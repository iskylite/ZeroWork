//! Controller updates are sampled immediately before each provider request.
//! One atomic snapshot keeps effort and the thinking toggle consistent.
const std = @import("std");
const provider = @import("provider.zig");
pub const State = struct {
    value: std.atomic.Value(u8) = .init(0),
    pub fn set(self: *State, effort: ?provider.Effort, thinking: ?bool) void {
        const level: u8 = if (effort) |v| @as(u8, @intCast(@backingInt(v))) + 1 else 0;
        const toggle: u8 = if (thinking) |enabled| (if (enabled) @as(u8, 2) else 1) else 0;
        self.value.store(0x80 | level | (toggle << 4), .release);
    }
    pub fn apply(self: *const State, request: provider.ChatRequest) provider.ChatRequest {
        const value = self.value.load(.acquire);
        if (value == 0) return request;
        var result = request;
        const level = value & 0x0f;
        result.effort = if (level == 0) null else @fromBackingInt(@as(u3, @intCast(level - 1)));
        result.thinking = switch ((value >> 4) & 3) {
            1 => false,
            2 => true,
            else => null,
        };
        return result;
    }
};

test "AI reasoning live updates preserve in-flight requests and can clear both controls" {
    var live: State = .{};
    const request: provider.ChatRequest = .{ .model = "model", .system = "", .messages = &.{}, .effort = .low, .thinking = true };
    try std.testing.expectEqual(provider.Effort.low, live.apply(request).effort.?);
    live.set(.ultra, true);
    const in_flight = live.apply(request);
    live.set(null, false);
    try std.testing.expectEqual(provider.Effort.ultra, in_flight.effort.?);
    try std.testing.expectEqual(provider.Effort.low, request.effort.?);
    try std.testing.expect(live.apply(request).effort == null and live.apply(request).thinking == false);
    live.set(null, null);
    try std.testing.expect(live.apply(request).effort == null and live.apply(request).thinking == null);
}
