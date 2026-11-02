//! Process-wide producer gate. Cleanup and receipts deliberately remain usable.
const std = @import("std");
var held = std.atomic.Value(bool).init(false);
pub fn blocked() bool {
    return held.load(.acquire);
}
pub fn set(value: bool) void {
    held.store(value, .release);
}
pub fn require() !void {
    if (blocked()) return error.UpdateInProgress;
}
