//! A grace period preserves fast reopen and postpones scratch trimming while
//! the user is interacting. Live font/render caches are retained.
const std = @import("std");
pub const grace_ns = 3 * std.time.ns_per_s;
pub const Policy = struct {
    seen_active: bool = false,
    deadline: ?u64 = null,
    reclaimed: bool = false,
    pub const Action = union(enum) { none, wait: u64, reclaim };
    pub fn noteInput(self: *Policy, now: u64) void {
        if (self.deadline != null and !self.reclaimed) self.deadline = now +| grace_ns;
    }
    pub fn observe(self: *Policy, active: bool, now: u64) Action {
        if (active) {
            self.seen_active = true;
            self.deadline = null;
            self.reclaimed = false;
            return .none;
        }
        if (!self.seen_active or self.reclaimed) return .none;
        if (self.deadline == null) self.deadline = now +| grace_ns;
        if (now < self.deadline.?) return .{ .wait = self.deadline.? - now };
        self.reclaimed = true;
        return .reclaim;
    }
};
test "terminal idle reclaim waits for grace and cancels when a view reopens" {
    var policy: Policy = .{};
    try std.testing.expectEqual(Policy.Action.none, policy.observe(false, 0));
    _ = policy.observe(true, 1);
    try std.testing.expectEqual(Policy.Action{ .wait = grace_ns }, policy.observe(false, 2));
    _ = policy.observe(true, grace_ns);
    try std.testing.expectEqual(Policy.Action{ .wait = grace_ns }, policy.observe(false, grace_ns + 1));
    try std.testing.expectEqual(Policy.Action.reclaim, policy.observe(false, 2 * grace_ns + 1));
    try std.testing.expectEqual(Policy.Action.none, policy.observe(false, 3 * grace_ns));
    _ = policy.observe(true, 4 * grace_ns);
    _ = policy.observe(false, 4 * grace_ns);
    policy.noteInput(5 * grace_ns);
    try std.testing.expectEqual(Policy.Action{ .wait = grace_ns }, policy.observe(false, 5 * grace_ns));
}
