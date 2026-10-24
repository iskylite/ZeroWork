/// Range Hover Registry
///
/// Framework-level interaction primitive: register multiple content-space child
/// rectangles on a host Node, each with enter/leave callbacks + hover delay.
/// Typical consumers:
///   - Underlines/annotations in text -> hover shows detail popup
///   - Annotated canvas / chart data points
///   - Inline hint supplemental info
///
/// Why not the Node-level hit runtime:
///   - Target region is not a node (e.g., byte-range annotation in text)
///   - Per frame, host maps byte range -> screen rect for the registry
///   - Queries resolve lazily: no re-register on scroll/reflow, rects_fn returns fresh coords
///
/// Usage:
/// ```zig
/// const registry = try RangeHoverRegistry.attach(cx, host_node);
/// const id = try registry.register(.{
///     .rects_fn = myEditor.diagnosticRectsFn,
///     .ctx = @ptrCast(&my_diag_ctx),
///     .on_enter = onDiagEnter,
///     .on_leave = onDiagLeave,
/// });
/// // Unregister: registry.unregister(id); or registry.clear();
/// // On host mouse events, registry.tickMouseMove(x, y) queries regions and fires callbacks.
/// ```
///
/// Notes:
///   - Coordinates are host Node content-local (caller transforms global -> local)
///   - rects_fn is called every tick; caller need not cache
///   - registry is auto-released on scope cleanup
const std = @import("std");

/// Minimal forward decl; range_hover only stores `*Node` as marker, never calls
/// Node methods. Lets unit tests run without full UI stack (all paths except
/// `attach`).
const Node = opaque {};
const UIContext = opaque {};

pub const RangeId = u32;

/// Content-local rect (relative to host Node top-left).
pub const RangeRect = struct {
    x: f32,
    y: f32,
    w: f32,
    h: f32,

    pub fn contains(self: RangeRect, px: f32, py: f32) bool {
        return px >= self.x and px < self.x + self.w and py >= self.y and py < self.y + self.h;
    }
};

/// One region's registration entry.
pub const RangeHoverRegion = struct {
    /// Supplier: maps (byte_range or other) to 0..N content-local rects in buf,
    /// returns actual count (<= buf.len).
    rects_fn: *const fn (ctx: *anyopaque, buf: []RangeRect) usize,
    ctx: *anyopaque,
    /// Fire after mouse hover delay. mx/my are content-local coordinates.
    on_enter: *const fn (ctx: *anyopaque, mx: f32, my: f32) void,
    /// Fire when mouse leaves region (no delay).
    on_leave: *const fn (ctx: *anyopaque) void,
    /// Delay in milliseconds before firing on_enter (typical 300-500 ms).
    hover_delay_ms: u32 = 300,
};

/// Registry itself: one per host Node.
pub const RangeHoverRegistry = struct {
    allocator: std.mem.Allocator,
    host: *Node,
    /// Registered region list; IDs monotonically increasing; unregister uses
    /// tombstone method (entry set to null).
    entries: std.ArrayListUnmanaged(?Entry) = .empty,
    next_id: RangeId = 1,

    /// Currently hovered region ID (recorded even before delay reached).
    active_id: ?RangeId = null,
    /// Timestamp (ms) when active_id first entered that region.
    active_enter_ms: i64 = 0,
    /// Whether active_id's on_enter has fired.
    entered: bool = false,
    /// Most recent mouse coordinates (from tickMouseMove).
    last_mx: f32 = 0,
    last_my: f32 = 0,

    const Entry = struct {
        id: RangeId,
        region: RangeHoverRegion,
    };

    /// Attach registry to host node. Caller holds *RangeHoverRegistry; scope handles
    /// cleanup. Caller's responsibility to avoid multiple attach to same node.
    /// allocator must outlive registry; caller destroys in scope cleanup. Constructor
    /// doesn't take UIContext so registry unit-tests without full UI stack.
    pub fn attach(allocator: std.mem.Allocator, host: *Node) !*RangeHoverRegistry {
        const self = try allocator.create(RangeHoverRegistry);
        self.* = .{
            .allocator = allocator,
            .host = host,
        };
        return self;
    }

    pub fn deinit(self: *RangeHoverRegistry) void {
        self.entries.deinit(self.allocator);
    }

    /// Destroy and free from allocator; equivalent to deinit + destroy.
    pub fn destroy(self: *RangeHoverRegistry) void {
        const a = self.allocator;
        self.deinit();
        a.destroy(self);
    }

    pub fn register(self: *RangeHoverRegistry, region: RangeHoverRegion) !RangeId {
        const id = self.next_id;
        self.next_id += 1;
        try self.entries.append(self.allocator, .{ .id = id, .region = region });
        return id;
    }

    pub fn unregister(self: *RangeHoverRegistry, id: RangeId) void {
        for (self.entries.items, 0..) |entry_opt, i| {
            if (entry_opt) |e| {
                if (e.id == id) {
                    self.entries.items[i] = null;
                    if (self.active_id == id) {
                        if (self.entered) {
                            e.region.on_leave(e.region.ctx);
                        }
                        self.active_id = null;
                        self.entered = false;
                    }
                    return;
                }
            }
        }
    }

    pub fn clear(self: *RangeHoverRegistry) void {
        if (self.active_id) |aid| {
            if (self.entered) {
                for (self.entries.items) |entry_opt| {
                    if (entry_opt) |e| if (e.id == aid) e.region.on_leave(e.region.ctx);
                }
            }
        }
        self.entries.clearRetainingCapacity();
        self.active_id = null;
        self.entered = false;
    }

    /// Dispatch per frame / on mouse move (mx/my = host-local coords; now_ms = current
    /// monotonic time). Registry runs state machine: hover delay -> on_enter -> on_leave.
    pub fn tickMouseMove(self: *RangeHoverRegistry, mx: f32, my: f32, now_ms: i64) void {
        self.last_mx = mx;
        self.last_my = my;
        var buf: [8]RangeRect = undefined;

        // Find which region current coordinates fall into.
        var hit: ?RangeId = null;
        var hit_region: ?RangeHoverRegion = null;
        for (self.entries.items) |entry_opt| {
            const e = entry_opt orelse continue;
            const count = e.region.rects_fn(e.region.ctx, &buf);
            for (buf[0..@min(count, buf.len)]) |r| {
                if (r.contains(mx, my)) {
                    hit = e.id;
                    hit_region = e.region;
                    break;
                }
            }
            if (hit != null) break;
        }

        if (hit) |new_id| {
            if (self.active_id != new_id) {
                // Switch to new region: leave old, start timer on new.
                if (self.active_id) |old_id| {
                    if (self.entered) fireLeaveById(self, old_id);
                }
                self.active_id = new_id;
                self.active_enter_ms = now_ms;
                self.entered = false;
            }
            // Check delay (including just-switched case; fire same frame when delay=0).
            if (!self.entered) {
                const elapsed = now_ms - self.active_enter_ms;
                if (elapsed >= @as(i64, @intCast(hit_region.?.hover_delay_ms))) {
                    hit_region.?.on_enter(hit_region.?.ctx, mx, my);
                    self.entered = true;
                }
            }
        } else {
            // Leave all regions.
            if (self.active_id) |old_id| {
                if (self.entered) fireLeaveById(self, old_id);
                self.active_id = null;
                self.entered = false;
            }
        }
    }

    /// Called when mouse leaves host Node; force-leave current active region.
    pub fn onMouseLeaveHost(self: *RangeHoverRegistry) void {
        if (self.active_id) |old_id| {
            if (self.entered) fireLeaveById(self, old_id);
            self.active_id = null;
            self.entered = false;
        }
    }

    fn fireLeaveById(self: *RangeHoverRegistry, id: RangeId) void {
        for (self.entries.items) |entry_opt| {
            const e = entry_opt orelse continue;
            if (e.id == id) {
                e.region.on_leave(e.region.ctx);
                return;
            }
        }
    }
};

// ============================================================================
// Tests
// ============================================================================

const testing = std.testing;

const TestState = struct {
    rects: []const RangeRect,
    enter_count: u32 = 0,
    leave_count: u32 = 0,
    last_enter_x: f32 = 0,
    last_enter_y: f32 = 0,

    fn rectsFn(ctx: *anyopaque, buf: []RangeRect) usize {
        const self: *TestState = @ptrCast(@alignCast(ctx));
        const n = @min(self.rects.len, buf.len);
        for (0..n) |i| buf[i] = self.rects[i];
        return n;
    }

    fn onEnter(ctx: *anyopaque, mx: f32, my: f32) void {
        const self: *TestState = @ptrCast(@alignCast(ctx));
        self.enter_count += 1;
        self.last_enter_x = mx;
        self.last_enter_y = my;
    }

    fn onLeave(ctx: *anyopaque) void {
        const self: *TestState = @ptrCast(@alignCast(ctx));
        self.leave_count += 1;
    }
};

fn newRegistry() RangeHoverRegistry {
    return .{
        .allocator = testing.allocator,
        .host = undefined, // Not really attaching to Node in tests.
    };
}

test "range_hover: enter fires only after delay elapses" {
    var registry = newRegistry();
    defer registry.deinit();

    var state = TestState{ .rects = &[_]RangeRect{.{ .x = 0, .y = 0, .w = 10, .h = 10 }} };
    _ = try registry.register(.{
        .rects_fn = TestState.rectsFn,
        .ctx = @ptrCast(&state),
        .on_enter = TestState.onEnter,
        .on_leave = TestState.onLeave,
        .hover_delay_ms = 100,
    });

    // t=0 enter region.
    registry.tickMouseMove(5, 5, 0);
    try testing.expectEqual(@as(u32, 0), state.enter_count); // Delay not reached.

    // t=50 still in region
    registry.tickMouseMove(6, 5, 50);
    try testing.expectEqual(@as(u32, 0), state.enter_count);

    // t=100 delay reached.
    registry.tickMouseMove(6, 5, 100);
    try testing.expectEqual(@as(u32, 1), state.enter_count);
}

test "range_hover: leave fires when moving outside" {
    var registry = newRegistry();
    defer registry.deinit();

    var state = TestState{ .rects = &[_]RangeRect{.{ .x = 0, .y = 0, .w = 10, .h = 10 }} };
    _ = try registry.register(.{
        .rects_fn = TestState.rectsFn,
        .ctx = @ptrCast(&state),
        .on_enter = TestState.onEnter,
        .on_leave = TestState.onLeave,
        .hover_delay_ms = 0,
    });

    registry.tickMouseMove(5, 5, 0);
    try testing.expectEqual(@as(u32, 1), state.enter_count);

    registry.tickMouseMove(20, 20, 1);
    try testing.expectEqual(@as(u32, 1), state.leave_count);
}

test "range_hover: switching regions fires leave+enter" {
    var registry = newRegistry();
    defer registry.deinit();

    var a = TestState{ .rects = &[_]RangeRect{.{ .x = 0, .y = 0, .w = 10, .h = 10 }} };
    var b = TestState{ .rects = &[_]RangeRect{.{ .x = 20, .y = 0, .w = 10, .h = 10 }} };

    _ = try registry.register(.{
        .rects_fn = TestState.rectsFn,
        .ctx = @ptrCast(&a),
        .on_enter = TestState.onEnter,
        .on_leave = TestState.onLeave,
        .hover_delay_ms = 0,
    });
    _ = try registry.register(.{
        .rects_fn = TestState.rectsFn,
        .ctx = @ptrCast(&b),
        .on_enter = TestState.onEnter,
        .on_leave = TestState.onLeave,
        .hover_delay_ms = 0,
    });

    registry.tickMouseMove(5, 5, 0);
    try testing.expectEqual(@as(u32, 1), a.enter_count);

    registry.tickMouseMove(25, 5, 1);
    try testing.expectEqual(@as(u32, 1), a.leave_count);
    try testing.expectEqual(@as(u32, 1), b.enter_count);
}

test "range_hover: unregister while hovering fires leave" {
    var registry = newRegistry();
    defer registry.deinit();

    var state = TestState{ .rects = &[_]RangeRect{.{ .x = 0, .y = 0, .w = 10, .h = 10 }} };
    const id = try registry.register(.{
        .rects_fn = TestState.rectsFn,
        .ctx = @ptrCast(&state),
        .on_enter = TestState.onEnter,
        .on_leave = TestState.onLeave,
        .hover_delay_ms = 0,
    });

    registry.tickMouseMove(5, 5, 0);
    try testing.expectEqual(@as(u32, 1), state.enter_count);

    registry.unregister(id);
    try testing.expectEqual(@as(u32, 1), state.leave_count);
}

test "range_hover: onMouseLeaveHost fires leave on active region" {
    var registry = newRegistry();
    defer registry.deinit();

    var state = TestState{ .rects = &[_]RangeRect{.{ .x = 0, .y = 0, .w = 10, .h = 10 }} };
    _ = try registry.register(.{
        .rects_fn = TestState.rectsFn,
        .ctx = @ptrCast(&state),
        .on_enter = TestState.onEnter,
        .on_leave = TestState.onLeave,
        .hover_delay_ms = 0,
    });

    registry.tickMouseMove(5, 5, 0);
    try testing.expectEqual(@as(u32, 1), state.enter_count);

    registry.onMouseLeaveHost();
    try testing.expectEqual(@as(u32, 1), state.leave_count);
}
