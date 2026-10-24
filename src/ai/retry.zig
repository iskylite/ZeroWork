const std = @import("std");
pub const Policy = struct {
    max_attempts: u8 = 3,
    delays_ms: [3]u32 = .{ 1000, 2000, 4000 },
    pub fn delay(self: Policy, attempt: u8) !u32 {
        if (attempt >= self.max_attempts) return error.Exhausted;
        return self.delays_ms[@min(attempt, self.delays_ms.len - 1)];
    }
};

/// Configuration/authentication failures and cancellation cannot be repaired
/// by repeating the same request. Unknown transport failures retain the
/// existing bounded retry behavior.
pub fn isRetryable(err: anyerror) bool {
    return switch (err) {
        error.Cancelled, error.Timeout, error.ProviderFailure, error.MissingApiKey, error.ResponseTooLarge, error.RequestTooLarge, error.InsecureEndpoint, error.StreamCallbackFailed, error.MissingEndpoint, error.MissingModel, error.InvalidContextWindow, error.MissingAuthEnvironment, error.InvalidAuth, error.ProviderDisabled, error.MissingProviderConfiguration, error.ProviderMissingDone, error.OutOfMemory, error.UnsupportedToolProtocol, error.InvalidToolDefinition, error.InvalidToolCall, error.InvalidToolMessage, error.ToolRequestTooLarge, error.InvalidUtf8, error.UnsupportedEffort, error.ProviderProtocolMismatch, error.InvalidToolArguments => false,
        else => true,
    };
}

/// Short waits keep Stop/close cancellation responsive during rate limiting.
/// Interrupted sleeps repeat their remaining duration rather than retry early.
pub fn wait(delay_ms: u32, token: ?*@import("provider.zig").CancelToken) !void {
    var remaining = delay_ms;
    while (true) {
        if (token) |cancel| if (cancel.isCancelled()) return error.Cancelled;
        if (remaining == 0) return;
        const step: u32 = @min(remaining, 50);
        var duration = std.c.timespec{ .sec = 0, .nsec = @intCast(step * std.time.ns_per_ms) };
        while (std.c.nanosleep(&duration, &duration) != 0) {
            if (token) |cancel| if (cancel.isCancelled()) return error.Cancelled;
        }
        remaining -= step;
    }
}
test "provider retry policy backs off and exhausts" {
    const p: Policy = .{};
    try std.testing.expectEqual(@as(u32, 1000), try p.delay(0));
    try std.testing.expectError(error.Exhausted, p.delay(3));
}

test "cancelled rate limit wait never sleeps or retries" {
    var token: @import("provider.zig").CancelToken = .{};
    token.cancel();
    try std.testing.expectError(error.Cancelled, wait(60_000, &token));
    try std.testing.expect(!isRetryable(error.Cancelled));
    try std.testing.expect(!isRetryable(error.ProviderFailure));
    try std.testing.expect(isRetryable(error.RequestRejected));
}

test "invalid tool wire requests never retry an unchanged payload" {
    for ([_]anyerror{ error.UnsupportedToolProtocol, error.InvalidToolDefinition, error.InvalidToolCall, error.InvalidToolMessage, error.RequestTooLarge, error.ToolRequestTooLarge, error.InvalidUtf8, error.UnsupportedEffort, error.ProviderProtocolMismatch, error.InvalidToolArguments }) |err| {
        try std.testing.expect(!isRetryable(err));
    }
    try std.testing.expect(isRetryable(error.RequestRejected));
}
