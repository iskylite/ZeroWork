const std = @import("std");

pub const State = struct {
    offscreen_depth: usize = 0,
    opacity_depth: usize = 0,
    blur_depth: usize = 0,
    rounded_depth: usize = 0,
    clip_overflow: bool = false,
    transformed: bool = false,
    animated: bool = false,
    alpha: f32 = 1,

    pub fn allowsLCD(self: State, is_opaque: bool) bool {
        return is_opaque and self.offscreen_depth == 0 and self.opacity_depth == 0 and
            self.blur_depth == 0 and self.rounded_depth == 0 and !self.clip_overflow and
            !self.transformed and !self.animated and self.alpha == 1;
    }
};

/// Fixed coverage grid: only completely opaque tiles are recorded. Evidence is
/// monotonic within a frame; additional rectangles cannot erase earlier proof.
pub const Backdrop = struct {
    width: f32 = 0,
    height: f32 = 0,
    rows: [64]u64 = @splat(0),
    any_opaque: bool = false,

    pub fn reset(self: *Backdrop, width: f32, height: f32, is_opaque: bool) void {
        self.* = .{ .width = width, .height = height, .any_opaque = is_opaque, .rows = @splat(if (is_opaque) std.math.maxInt(u64) else 0) };
    }

    pub fn add(self: *Backdrop, rect: [4]f32) void {
        if (!valid(rect) or !std.math.isFinite(self.width) or !std.math.isFinite(self.height) or self.width <= 0 or self.height <= 0) return;
        const x0 = index(@ceil(@as(f64, rect[0]) * 64 / @as(f64, self.width)));
        const y0 = index(@ceil(@as(f64, rect[1]) * 64 / @as(f64, self.height)));
        const x1 = index(@floor(@as(f64, rect[2]) * 64 / @as(f64, self.width)));
        const y1 = index(@floor(@as(f64, rect[3]) * 64 / @as(f64, self.height)));
        if (x1 <= x0 or y1 <= y0) return;
        const mask = bits(x0, x1);
        self.any_opaque = true;
        for (y0..y1) |y| self.rows[y] |= mask;
    }

    pub fn contains(self: Backdrop, rect: [4]f32) bool {
        if (!valid(rect) or !std.math.isFinite(self.width) or !std.math.isFinite(self.height) or self.width <= 0 or self.height <= 0) return false;
        const x0 = index(@floor(@as(f64, rect[0]) * 64 / @as(f64, self.width)));
        const y0 = index(@floor(@as(f64, rect[1]) * 64 / @as(f64, self.height)));
        const x1 = index(@ceil(@as(f64, rect[2]) * 64 / @as(f64, self.width)));
        const y1 = index(@ceil(@as(f64, rect[3]) * 64 / @as(f64, self.height)));
        if (x1 <= x0 or y1 <= y0) return false;
        const mask = bits(x0, x1);
        for (y0..y1) |y| if (self.rows[y] & mask != mask) return false;
        return true;
    }

    fn valid(rect: [4]f32) bool {
        for (rect) |v| if (!std.math.isFinite(v)) return false;
        return rect[2] > rect[0] and rect[3] > rect[1];
    }
    fn index(value: f64) usize {
        return @intFromFloat(@min(64, @max(0, value)));
    }
    fn bits(start: usize, end: usize) u64 {
        const hi: u64 = if (end == 64) std.math.maxInt(u64) else (@as(u64, 1) << @intCast(end)) - 1;
        const lo: u64 = if (start == 0) 0 else (@as(u64, 1) << @intCast(start)) - 1;
        return hi & ~lo;
    }
};

test "LCD eligibility excludes every layer and unsafe text state" {
    const states = [_]State{
        .{ .offscreen_depth = 1 }, .{ .opacity_depth = 1 },    .{ .blur_depth = 1 },
        .{ .rounded_depth = 1 },   .{ .clip_overflow = true }, .{ .transformed = true },
        .{ .animated = true },     .{ .alpha = 0.5 },          .{ .alpha = std.math.nan(f32) },
    };
    try std.testing.expect((State{}).allowsLCD(true));
    try std.testing.expect(!(State{}).allowsLCD(false));
    for (states) |state| try std.testing.expect(!state.allowsLCD(true));
}

test "opaque proof remains monotonic past 64 rectangles and respects partial tiles" {
    var backdrop = Backdrop{};
    backdrop.reset(640, 640, false);
    backdrop.add(.{ 0, 0, 320, 320 });
    for (0..1000) |i| {
        const x: f32 = @floatFromInt(i % 20);
        backdrop.add(.{ 400 + x, 400, 410 + x, 410 });
    }
    try std.testing.expect(backdrop.contains(.{ 1, 1, 319, 319 }));
    try std.testing.expect(!backdrop.contains(.{ 319, 319, 321, 321 }));
    backdrop.reset(640, 640, false);
    backdrop.add(.{ 0.1, 0, 10, 10 });
    try std.testing.expect(!backdrop.contains(.{ 1, 1, 9, 9 }));
}
