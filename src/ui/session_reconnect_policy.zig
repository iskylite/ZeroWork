const std = @import("std");
const config = @import("../config/config.zig");

pub const Attempt = struct {
    number: u8,
    delay_seconds: u8,
};

pub fn nextAttempt(attempt: u8, max_attempts: u8, backoff: []const u8) ?Attempt {
    if (attempt >= max_attempts or attempt >= backoff.len) return null;
    return .{ .number = attempt + 1, .delay_seconds = backoff[attempt] };
}

pub fn policy(app_config: config.Config, attempt: u8) ?Attempt {
    return nextAttempt(attempt, app_config.ssh.reconnect_max, &app_config.ssh.reconnect_backoff);
}

test "session reconnect factory follows persisted policy" {
    var cfg: config.Config = .{};
    cfg.ssh.reconnect_max = 3;
    cfg.ssh.reconnect_backoff = .{ 2, 4, 8, 16, 32 };
    try std.testing.expectEqual(Attempt{ .number = 1, .delay_seconds = 2 }, policy(cfg, 0).?);
    try std.testing.expectEqual(Attempt{ .number = 3, .delay_seconds = 8 }, policy(cfg, 2).?);
    try std.testing.expect(policy(cfg, 3) == null);
}
