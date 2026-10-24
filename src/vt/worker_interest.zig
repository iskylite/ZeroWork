const std = @import("std");
const BatchResult = @import("channel_pump.zig").BatchResult;

pub const Interest = packed struct {
    read: bool = true,
    write: bool = false,
    paused_for_ui: bool = false,
};

/// Pure policy used by the kqueue worker to update socket interests.
pub fn afterInput(result: BatchResult, has_pending_input: bool) Interest {
    return .{ .read = true, .write = switch (result.state) {
        .would_block => has_pending_input,
        .iteration_limit => has_pending_input,
        .empty => false,
    } };
}

pub fn afterOutputPublishError(err: anyerror, has_pending_input: bool) Interest {
    return switch (err) {
        error.ConsumerBehind => .{ .read = false, .write = has_pending_input, .paused_for_ui = true },
        else => .{ .read = true, .write = has_pending_input },
    };
}

pub fn afterUiConsumed(has_pending_input: bool) Interest {
    return .{ .read = true, .write = has_pending_input, .paused_for_ui = false };
}

test "worker interest requests writable event only while needed" {
    try std.testing.expect(afterInput(.{ .written = 0, .state = .empty }, false).write == false);
    try std.testing.expect(afterInput(.{ .written = 0, .state = .would_block }, true).write);
    try std.testing.expect(afterInput(.{ .written = 4, .state = .iteration_limit }, true).write);
}

test "worker pauses reads when UI dirty consumer falls behind" {
    const paused = afterOutputPublishError(error.ConsumerBehind, true);
    try std.testing.expect(!paused.read and paused.write and paused.paused_for_ui);
    const resumed = afterUiConsumed(false);
    try std.testing.expect(resumed.read and !resumed.write and !resumed.paused_for_ui);
}
