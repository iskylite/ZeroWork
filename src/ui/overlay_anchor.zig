const std = @import("std");

pub const Anchor = enum { pane_top_center, status_chip, pane_center, tab_bottom };
pub const Rect = struct { x: f32, y: f32, width: f32, height: f32 };
pub const Size = struct { width: f32, height: f32 };

pub fn place(anchor: Anchor, pane: Rect, overlay: Size, window: Size, margin: f32) Rect {
    var x: f32 = switch (anchor) {
        .pane_top_center, .pane_center => pane.x + (pane.width - overlay.width) / 2,
        .status_chip => pane.x + pane.width - overlay.width - margin,
        .tab_bottom => pane.x + margin,
    };
    var y: f32 = switch (anchor) {
        .pane_top_center, .status_chip => pane.y + margin,
        .pane_center => pane.y + (pane.height - overlay.height) / 2,
        .tab_bottom => pane.y + pane.height - overlay.height - margin,
    };
    x = clamp(x, margin, @max(margin, window.width - overlay.width - margin));
    y = clamp(y, margin, @max(margin, window.height - overlay.height - margin));
    return .{ .x = x, .y = y, .width = overlay.width, .height = overlay.height };
}

fn clamp(value: f32, low: f32, high: f32) f32 {
    return @min(@max(value, low), high);
}

test "overlay anchors center and clamp to window" {
    const pane: Rect = .{ .x = 10, .y = 20, .width = 400, .height = 200 };
    const window: Size = .{ .width = 500, .height = 300 };
    const center = place(.pane_center, pane, .{ .width = 100, .height = 40 }, window, 8);
    try std.testing.expectEqual(@as(f32, 160), center.x);
    try std.testing.expectEqual(@as(f32, 100), center.y);
    const huge = place(.pane_center, pane, .{ .width = 900, .height = 500 }, window, 8);
    try std.testing.expectEqual(@as(f32, 8), huge.x);
    try std.testing.expectEqual(@as(f32, 8), huge.y);
}

test "status chip stays inside narrow window" {
    const chip = place(.status_chip, .{ .x = 0, .y = 0, .width = 1000, .height = 40 }, .{ .width = 120, .height = 20 }, .{ .width = 200, .height = 100 }, 8);
    try std.testing.expect(chip.x >= 8 and chip.x + chip.width <= 192);
}
