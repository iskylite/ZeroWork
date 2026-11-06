//! Only live, unsaved background composers participate in update preflight.
const std = @import("std");
pub fn blocks(state: anytype, displayed: ?u64) bool {
    // Deleted entries can remain until workers/readers release their state.
    // Ended history is journaled; the displayed composer is checked separately.
    if (state.closed or state.ended or displayed == state.id) return false;
    return std.mem.trim(u8, state.draft orelse "", " \t\r\n").len != 0;
}
