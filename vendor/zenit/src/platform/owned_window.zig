//! Owned windows (palette, find panel): placement relative to the owner and
//! where keyboard focus went when the owned window lost it.
//!
//! Placement is pure geometry shared by every window backend, so the rule is
//! unit-tested once; native code only reads frames and writes the origin.

/// Where keyboard focus went when an owned window stopped being the key /
/// active window. Panels typically close when the user returns to another
/// window of the same application, and stay open across an app switch so the
/// query is still there on return.
pub const FocusLoss = enum { same_application, other_application };

/// Rectangle in the backend's native window coordinates.
pub const Rect = struct { x: f64, y: f64, w: f64, h: f64 };

/// Direction of the native y axis: AppKit grows upward from the bottom-left
/// corner, Win32 and Wayland grow downward from the top-left corner.
pub const YAxis = enum { up, down };

/// Upward bias as a fraction of the owner height. Geometric centre reads as
/// low; command palettes conventionally sit slightly above it. Proportional so
/// a small owner never pushes the panel outside itself.
pub const vertical_bias_ratio: f64 = 0.08;

/// Origin that centres a `panel_w` x `panel_h` window on `owner`, nudged
/// upward, then clamped to `visible` (the owner's screen work area, excluding
/// menu bar, Dock and taskbar). When the panel is larger than the work area,
/// the leading edge (left, and top on screen) stays visible.
pub fn centerOnOwner(owner: Rect, panel_w: f64, panel_h: f64, visible: Rect, axis: YAxis) struct { x: f64, y: f64 } {
    const bias = owner.h * vertical_bias_ratio;
    var x = owner.x + (owner.w - panel_w) / 2.0;
    var y = owner.y + (owner.h - panel_h) / 2.0 + switch (axis) {
        .up => bias,
        .down => -bias,
    };
    x = @max(@min(x, visible.x + visible.w - panel_w), visible.x);
    y = switch (axis) {
        // Clamp the bottom first so an oversized panel keeps its top on screen.
        .up => @min(@max(y, visible.y), visible.y + visible.h - panel_h),
        .down => @max(@min(y, visible.y + visible.h - panel_h), visible.y),
    };
    return .{ .x = @round(x), .y = @round(y) };
}

const testing = @import("std").testing;

test "centres on the owner with an upward bias in both axis conventions" {
    const owner: Rect = .{ .x = 100, .y = 100, .w = 1000, .h = 800 };
    const screen: Rect = .{ .x = 0, .y = 0, .w = 3000, .h = 3000 };
    const up = centerOnOwner(owner, 400, 300, screen, .up);
    try testing.expectEqual(@as(f64, 400), up.x);
    try testing.expectEqual(@as(f64, 350 + 64), up.y);
    const down = centerOnOwner(owner, 400, 300, screen, .down);
    try testing.expectEqual(@as(f64, 400), down.x);
    try testing.expectEqual(@as(f64, 350 - 64), down.y);
}

test "stays inside the owner's work area" {
    const owner: Rect = .{ .x = -200, .y = 900, .w = 600, .h = 400 };
    const screen: Rect = .{ .x = 0, .y = 0, .w = 1920, .h = 1080 };
    const p = centerOnOwner(owner, 500, 400, screen, .down);
    try testing.expectEqual(@as(f64, 0), p.x);
    try testing.expectEqual(@as(f64, 680), p.y);
}

test "an oversized panel keeps its top edge on screen" {
    const owner: Rect = .{ .x = 0, .y = 0, .w = 800, .h = 600 };
    const screen: Rect = .{ .x = 0, .y = 0, .w = 800, .h = 600 };
    // AppKit: the top edge is y + h, so the origin is pinned to visible top.
    const up = centerOnOwner(owner, 400, 700, screen, .up);
    try testing.expectEqual(@as(f64, -100), up.y);
    const down = centerOnOwner(owner, 400, 700, screen, .down);
    try testing.expectEqual(@as(f64, 0), down.y);
}
