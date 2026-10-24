/// Shared render pacing configuration.
///
/// Keep CAMetalLayer drawable depth and CPU in-flight frame slots aligned with
/// the renderers' triple-buffered instance storage. Letting these drift apart
/// reintroduces acquire/pacing jitter during sustained editor scroll.
pub const maximum_frame_latency: u32 = 2;
pub const frames_in_flight: u32 = maximum_frame_latency + 1;

/// An event-pump wake is not necessarily a new display tick. Only continuous
/// animation work is coalesced; inputs and ready deadlines remain immediate.
pub const DisplayTickGate = struct {
    last_rendered_tick: ?u64 = null,

    pub const Request = struct {
        wants_frame: bool,
        forced: bool = false,
        deadline_due: bool = false,
    };

    /// A null tick keeps poll pacing/custom platforms unrestricted.
    pub fn shouldRender(self: *const DisplayTickGate, tick: ?u64, request: Request) bool {
        if (!request.wants_frame) return false;
        if (tick == null or request.forced or request.deadline_due) return true;
        return self.last_rendered_tick == null or self.last_rendered_tick != tick;
    }

    /// Call after a real submission. A skipped/failed attempt must not consume
    /// the tick, and an idle wake must not postpone the next active frame.
    pub fn didRender(self: *DisplayTickGate, tick: ?u64) void {
        self.last_rendered_tick = tick;
    }
};

test "display tick gate rejects the extra animation submission in a single tick" {
    const t = @import("std").testing;
    var gate: DisplayTickGate = .{};
    try t.expect(gate.shouldRender(17, .{ .wants_frame = true }));
    gate.didRender(17);
    // R9: an ordinary pump wake 0.618ms later queued another drawable.
    try t.expect(!gate.shouldRender(17, .{ .wants_frame = true }));
    try t.expect(gate.shouldRender(18, .{ .wants_frame = true }));
    gate.didRender(18);
    try t.expect(!gate.shouldRender(18, .{ .wants_frame = true }));
}

test "display tick gate keeps input resize and deadline frames immediate" {
    const t = @import("std").testing;
    var gate: DisplayTickGate = .{};
    gate.didRender(17);
    try t.expect(gate.shouldRender(17, .{ .wants_frame = true, .forced = true }));
    gate.didRender(17);
    try t.expect(!gate.shouldRender(17, .{ .wants_frame = true }));
    try t.expect(gate.shouldRender(17, .{ .wants_frame = true, .deadline_due = true }));
    gate.didRender(17);
    try t.expect(!gate.shouldRender(17, .{ .wants_frame = true }));
    try t.expect(gate.shouldRender(18, .{ .wants_frame = true }));
}

test "display tick gate preserves first idle resume and unsubmitted attempts" {
    const t = @import("std").testing;
    var gate: DisplayTickGate = .{};
    try t.expect(!gate.shouldRender(0, .{ .wants_frame = false }));
    try t.expect(gate.shouldRender(0, .{ .wants_frame = true }));
    // No submission occurred; the retry is still eligible.
    try t.expect(gate.shouldRender(0, .{ .wants_frame = true }));
    gate.didRender(0);
    try t.expect(!gate.shouldRender(1, .{ .wants_frame = false }));
    try t.expect(gate.shouldRender(1, .{ .wants_frame = true }));
    gate.didRender(1);
    // Input restarts an idle link before its first new callback.
    try t.expect(gate.shouldRender(1, .{ .wants_frame = true, .forced = true }));
    gate.didRender(1);
    try t.expect(!gate.shouldRender(1, .{ .wants_frame = true }));
}

test "display tick gates are independent between windows and skipped ticks" {
    const t = @import("std").testing;
    var first: DisplayTickGate = .{};
    var second: DisplayTickGate = .{};
    first.didRender(17);
    try t.expect(!first.shouldRender(17, .{ .wants_frame = true }));
    try t.expect(second.shouldRender(17, .{ .wants_frame = true }));
    second.didRender(17);
    try t.expect(first.shouldRender(20, .{ .wants_frame = true }));
    first.didRender(20);
    try t.expect(!first.shouldRender(20, .{ .wants_frame = true }));
    try t.expect(second.shouldRender(20, .{ .wants_frame = true }));
}

test "display tick gate leaves poll pacing unrestricted" {
    const t = @import("std").testing;
    var gate: DisplayTickGate = .{};
    gate.didRender(17);
    try t.expect(gate.shouldRender(null, .{ .wants_frame = true }));
    gate.didRender(null);
    try t.expect(gate.shouldRender(null, .{ .wants_frame = true }));
    try t.expect(!gate.shouldRender(null, .{ .wants_frame = false }));
}
