//! Process-wide edge-triggered UI notification. Workers never touch a Cx.
//! Install the platform callback before starting workers; consume on main only.
const std = @import("std");
var pending: std.atomic.Value(bool) = .init(false);
pub var wake_fn: ?*const fn () void = null;
pub fn notify() void {
    if (!pending.swap(true, .acq_rel)) if (wake_fn) |wake| wake();
}
pub fn take() bool {
    return pending.swap(false, .acq_rel);
}
