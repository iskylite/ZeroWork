const std = @import("std");
const provider = @import("provider.zig");
pub const Mock = struct {
    allocator: std.mem.Allocator,
    response: []const u8,
    pub fn chat(ctx: *anyopaque, request: provider.ChatRequest, sink: *const fn (*anyopaque, provider.Delta) void, sink_ctx: *anyopaque) !provider.ChatStats {
        _ = request;
        const self: *Mock = @ptrCast(@alignCast(ctx));
        sink(sink_ctx, .{ .text = self.response });
        sink(sink_ctx, .done);
        return .{ .output_tokens = @intCast(self.response.len), .usage_reported = false };
    }
    pub fn models(ctx: *anyopaque, allocator: std.mem.Allocator) ![]provider.ModelInfo {
        _ = ctx;
        var result = try allocator.alloc(provider.ModelInfo, 1);
        result[0] = .{ .id = "mock", .context_window = 8192 };
        return result;
    }
    pub fn interface(self: *Mock) provider.Provider {
        return .{ .ctx = self, .chat = chat, .models = models };
    }
};
test "mock provider emits text and done deltas" {
    var mock: Mock = .{ .allocator = std.testing.allocator, .response = "ok" };
    var count: usize = 0;
    const Sink = struct {
        fn receive(ctx: *anyopaque, delta: provider.Delta) void {
            const n: *usize = @ptrCast(@alignCast(ctx));
            switch (delta) {
                .text => n.* += 1,
                .done => n.* += 1,
                else => {},
            }
        }
    };
    _ = try mock.interface().chat(mock.interface().ctx, .{ .model = "mock", .effort = .low, .system = "", .messages = &.{} }, Sink.receive, &count);
    try std.testing.expectEqual(@as(usize, 2), count);
}
