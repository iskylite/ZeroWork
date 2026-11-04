//! Edge-triggered presentation wakeups. Workers hold numeric generation tokens,
//! never Cx/Node pointers. Window registration/drain are main-thread only.
const std = @import("std");
pub const Target = u64;
const capacity = 128;
const index_bits = 8;
const index_mask = (1 << index_bits) - 1;
const Slot = struct {
    // Token and pending bit share one CAS word: a stale producer cannot mark a
    // reused slot pending after the UI registers its next generation.
    state: std.atomic.Value(u64) = .init(0),
    context: usize = 0, // main-thread identity only; never dereferenced here
};
var slots: [capacity]Slot = @splat(.{});
var next_generation: u64 = 1;
var wake_pending: std.atomic.Value(bool) = .init(false);
var global_pending: std.atomic.Value(bool) = .init(false);
pub var wake_fn: ?*const fn () void = null;

fn wake() void {
    if (!wake_pending.swap(true, .acq_rel)) if (wake_fn) |callback| callback();
}
/// Unknown owners remain reliable and conservatively wake every live window.
pub fn notify() void {
    global_pending.store(true, .release);
    wake();
}
pub fn notifyTarget(target: Target) void {
    if (target == 0) return notify();
    const index = target & index_mask;
    if (index == 0 or index > capacity) return;
    const slot = &slots[index - 1];
    var previous = slot.state.load(.acquire);
    while (previous >> 1 == target) {
        if (previous & 1 != 0) return;
        if (slot.state.cmpxchgWeak(previous, previous | 1, .acq_rel, .acquire)) |actual| {
            previous = actual;
        } else {
            wake();
            return;
        }
    }
    // Closed targets discard only presentation hints. Business receipts and
    // lifecycle results continue through their original reliable queues.
}
pub fn registerWindow(context: usize) Target {
    if (targetForWindow(context) != 0) return targetForWindow(context);
    if (context == 0 or next_generation >= (std.math.maxInt(u64) >> (index_bits + 1))) return 0;
    for (&slots, 0..) |*slot, index| {
        if (slot.context != 0) continue;
        const target = (next_generation << index_bits) | (index + 1);
        next_generation += 1;
        slot.context = context;
        slot.state.store(target << 1, .release);
        return target;
    }
    return 0; // Exhaustion affects routing only; publication falls back globally.
}
pub fn targetForWindow(context: usize) Target {
    if (context == 0) return 0;
    for (&slots) |*slot| if (slot.context == context) return slot.state.load(.acquire) >> 1;
    return 0;
}
pub fn unregisterWindow(context: usize, target: Target) void {
    if (target == 0) return;
    const index = target & index_mask;
    if (index == 0 or index > capacity) return;
    const slot = &slots[index - 1];
    if (slot.context != context or slot.state.load(.acquire) >> 1 != target) return;
    slot.state.store(0, .release);
    slot.context = 0;
}
/// Begin a main-loop drain. Drain each window as well even when an unknown
/// event already requests a global redraw, so old targeted flags do not linger.
pub fn take() bool {
    wake_pending.store(false, .release);
    return global_pending.swap(false, .acq_rel);
}
pub fn takeWindow(context: usize) bool {
    const target = targetForWindow(context);
    if (target == 0) return false;
    const slot = &slots[(target & index_mask) - 1];
    return slot.state.cmpxchgStrong((target << 1) | 1, target << 1, .acq_rel, .acquire) == null;
}

test "presentation targets isolate windows and preserve unknown-owner fallback" {
    _ = take();
    const a = registerWindow(1);
    defer unregisterWindow(1, a);
    const b = registerWindow(2);
    defer unregisterWindow(2, b);
    notifyTarget(a);
    try std.testing.expect(!take());
    try std.testing.expect(takeWindow(1));
    try std.testing.expect(!takeWindow(2));
    try std.testing.expect(!takeWindow(1));
    notify();
    try std.testing.expect(take());
    try std.testing.expect(!takeWindow(1));
}

test "presentation stale generations cannot wake a reused window slot" {
    _ = take();
    const old = registerWindow(1);
    unregisterWindow(1, old);
    const current = registerWindow(1);
    defer unregisterWindow(1, current);
    try std.testing.expect(current != old);
    notifyTarget(old);
    try std.testing.expect(!take());
    try std.testing.expect(!takeWindow(1));
    notifyTarget(current);
    try std.testing.expect(!take());
    try std.testing.expect(takeWindow(1));
}

test "presentation registration exhaustion retains global publication" {
    _ = take();
    var targets: [capacity]Target = undefined;
    for (&targets, 0..) |*target, i| target.* = registerWindow(i + 100);
    defer for (targets, 0..) |target, i| unregisterWindow(i + 100, target);
    try std.testing.expectEqual(@as(Target, 0), registerWindow(999));
    notifyTarget(0);
    try std.testing.expect(take());
}

test "presentation concurrent stale publisher never marks the new generation" {
    _ = take();
    const old = registerWindow(7);
    const Worker = struct {
        target: Target,
        stop: std.atomic.Value(bool) = .init(false),
        fn run(self: *@This()) void {
            while (!self.stop.load(.acquire)) notifyTarget(self.target);
        }
    };
    var worker = Worker{ .target = old };
    const thread = try std.Thread.spawn(.{}, Worker.run, .{&worker});
    unregisterWindow(7, old);
    const current = registerWindow(7);
    defer unregisterWindow(7, current);
    for (0..10000) |_| try std.testing.expect(!takeWindow(7));
    worker.stop.store(true, .release);
    thread.join();
    _ = take();
    try std.testing.expect(!takeWindow(7));
}
