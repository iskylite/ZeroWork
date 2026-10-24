const std = @import("std");
pub const State = enum { idle, thinking, streaming, success, failed, warning };
pub const Status = struct { state: State = .idle, pulse: u8 = 0, message: []const u8 = "" };

pub fn nextPulse(status: *Status) void {
    if (status.state == .thinking or status.state == .streaming or status.state == .warning) status.pulse = (status.pulse + 1) % 3 else status.pulse = 0;
}
pub fn colorName(state: State) []const u8 {
    return switch (state) {
        .idle => "secondary",
        .thinking, .streaming => "accent",
        .success => "green",
        .failed => "red",
        .warning => "amber",
    };
}

test "AI status cycles active pulse and maps colors" {
    var status: Status = .{ .state = .thinking };
    nextPulse(&status);
    try std.testing.expectEqual(@as(u8, 1), status.pulse);
    try std.testing.expectEqualStrings("accent", colorName(status.state));
}
