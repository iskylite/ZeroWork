//! Tab-strip arithmetic shared by drawing, hit testing and scrolling.
//! Callers supply actual shaped title advances, never UTF-8 byte counts.
const std = @import("std");

pub const Mode = enum { normal, compressed, overflow };
pub const Result = struct {
    mode: Mode,
    viewport: f32,
    content: f32,
    offset: f32,
    can_scroll_left: bool,
    can_scroll_right: bool,
};
pub const minimum: f32 = 96;
pub const maximum: f32 = 200;
pub const gap: f32 = 4;

pub fn calculate(header_width: f32, title_advances: []const f32, widths: []f32, requested_offset: f32) !Result {
    if (!std.math.isFinite(header_width) or header_width < 0 or !std.math.isFinite(requested_offset)) return error.InvalidGeometry;
    if (widths.len != title_advances.len) return error.InvalidOutput;
    var natural: f32 = 0;
    for (title_advances, widths) |advance, *width| {
        if (!std.math.isFinite(advance) or advance < 0) return error.InvalidGeometry;
        width.* = std.math.clamp(advance + 76, minimum, maximum);
        natural += width.*;
    }
    const gaps = if (widths.len > 0) @as(f32, @floatFromInt(widths.len - 1)) * gap else 0;
    natural += gaps;
    const budget = @max(0, header_width - 82 - 150 - 40);
    const min_total = @as(f32, @floatFromInt(widths.len)) * minimum + gaps;
    var mode: Mode = .normal;
    var content = natural;
    var viewport = budget;
    if (natural > budget) {
        if (min_total <= budget) {
            mode = .compressed;
            const remaining = budget - min_total;
            const flexibility = natural - min_total;
            for (widths) |*width| width.* = minimum + (width.* - minimum) * remaining / flexibility;
            content = budget;
        } else {
            mode = .overflow;
            viewport = @max(0, header_width - 82 - 150 - 130);
        }
    }
    const offset = if (mode == .overflow) std.math.clamp(requested_offset, 0, @max(0, content - viewport)) else 0;
    return .{ .mode = mode, .viewport = viewport, .content = content, .offset = offset, .can_scroll_left = offset > 0, .can_scroll_right = offset < @max(0, content - viewport) };
}

/// Use for explicit activation, rename and resize. Output-only status changes
/// should retain Result.offset so background traffic never steals scrolling.
pub fn reveal(layout: Result, widths: []const f32, index: usize) !f32 {
    if (index >= widths.len) return error.InvalidTab;
    if (layout.mode != .overflow) return 0;
    var left: f32 = 0;
    for (widths[0..index]) |width| left += width + gap;
    const right = left + widths[index];
    var offset = layout.offset;
    if (left < offset) offset = left else if (right > offset + layout.viewport) offset = right - layout.viewport;
    return std.math.clamp(offset, 0, @max(0, layout.content - layout.viewport));
}

test "header budgets follow logical card width at default and compact sizes" {
    var widths: [3]f32 = undefined;
    for ([_]struct { header: f32, budget: f32 }{ .{ .header = 1424, .budget = 1152 }, .{ .header = 1008, .budget = 736 }, .{ .header = 844, .budget = 572 } }) |sample| {
        const layout = try calculate(sample.header, &.{ 72, 84, 47 }, &widths, 0);
        try std.testing.expectEqual(Mode.normal, layout.mode);
        try std.testing.expectEqual(sample.budget, layout.viewport);
        try std.testing.expectEqualSlices(f32, &.{ 148, 160, 123 }, &widths);
    }
}

test "compression distributes flexible width and overflow restores natural width" {
    var widths: [5]f32 = undefined;
    const compressed = try calculate(844, &.{ 124, 104, 84, 64, 44 }, &widths, 80);
    try std.testing.expectEqual(Mode.compressed, compressed.mode);
    var sum: f32 = 16;
    for (widths) |width| {
        try std.testing.expect(width >= minimum);
        sum += width;
    }
    try std.testing.expectApproxEqAbs(@as(f32, 572), sum, 0.001);
    try std.testing.expectEqual(@as(f32, 0), compressed.offset);
    var overflow_widths: [6]f32 = undefined;
    const overflow = try calculate(844, &.{ 124, 104, 84, 64, 44, 24 }, &overflow_widths, 0);
    try std.testing.expectEqual(Mode.overflow, overflow.mode);
    try std.testing.expectEqual(@as(f32, 482), overflow.viewport);
    try std.testing.expectEqualSlices(f32, &.{ 200, 180, 160, 140, 120, 100 }, &overflow_widths);
    try std.testing.expect(!overflow.can_scroll_left and overflow.can_scroll_right);
    const end = try calculate(844, &.{ 124, 104, 84, 64, 44, 24 }, &overflow_widths, 9999);
    try std.testing.expect(end.can_scroll_left and !end.can_scroll_right);
    try std.testing.expectEqual(end.offset, try reveal(overflow, &overflow_widths, 5));
    try std.testing.expectEqual(@as(f32, 0), try reveal(end, &overflow_widths, 0));
}
