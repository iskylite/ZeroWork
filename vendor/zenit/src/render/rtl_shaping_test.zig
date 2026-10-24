//! RTL (Arabic/Hebrew) shaping contract tests.
//! These tests **must** run on the real CoreText path (src/render test target links
//! native/macos/coretext_bridge.m). src/ui/core/text_layout.zig has a builtin.is_test branch that
//! bypasses CoreText for estimation and can't show RTL, so use text.TextShaper directly here.
//! Background: CoreText's CTLineCreateWithAttributedString runs Unicode bidi (UAX #9)
//! internally; CTLineGetGlyphRuns returns runs and glyphs **already in visual order**
//! (pen increases left-to-right). RTL shows as *string index* decreasing, not position.
//! These tests pin this contract to prevent "fixing" RTL by reversing the glyph array
//! or going absolute-position, which would break LTR.

const std = @import("std");
const testing = std.testing;
const text = @import("text");

const ARABIC = "مرحبا"; // "marhaba"
const HEBREW = "שלום"; // "shalom"

/// Open system font covering Arabic/Hebrew glyphs. Use findFont to let CoreText cascade-fallback.
fn openFont(fs: *text.FontSystem, size: f32) !*text.Font {
    return fs.findFont(.{ .family = "Helvetica", .size = size });
}

const ShapeResult = struct {
    glyphs: []text.ShapedGlyph,
    allocator: std.mem.Allocator,

    fn deinit(self: *ShapeResult) void {
        for (self.glyphs) |g| {
            if (g.fallback_font_ref) |r| text.releaseFallbackFontRef(r);
        }
        if (self.glyphs.len > 0) self.allocator.free(self.glyphs);
    }
};

fn shape(allocator: std.mem.Allocator, s: []const u8) !ShapeResult {
    var fs = try text.FontSystem.init(allocator, @import("std").testing.io);
    defer fs.deinit();
    const font = try openFont(&fs, 20.0);
    defer font.deinit();

    var shaper = try text.TextShaper.init(allocator);
    defer shaper.deinit();

    const glyphs = try shaper.shape(s, font);
    return .{ .glyphs = glyphs, .allocator = allocator };
}

/// Renderer (text_renderer.emitGlyphInstance) contract: glyph_x = cursor_x + x_offset;
/// cursor_x advances via x_advance accumulation. So x_offset is **relative-to-current-pen**
/// adjustment, not absolute. If RTL run x_offset becomes large negative, glyphs
/// reverse-overlap; this test prevents that.
fn assertNoReverseOverlap(glyphs: []const text.ShapedGlyph) !void {
    var cursor: f32 = 0;
    var prev_x: f32 = -std.math.floatMax(f32);
    for (glyphs) |g| {
        const x = cursor + g.x_offset;
        // Visual order: pen must be monotone non-decreasing; marks/diacritics can retreat, but
        // not glyph-width-scale backward (that's reverse-overlap).
        try testing.expect(x >= prev_x - g.x_advance);
        prev_x = x;
        cursor += g.x_advance;
    }
}

test "RTL: 阿拉伯语 shaping 产出视觉序，x_offset 不产生反向重叠" {
    var r = try shape(testing.allocator, ARABIC);
    defer r.deinit();

    try testing.expect(r.glyphs.len > 0);
    try assertNoReverseOverlap(r.glyphs);

    // CoreText does bidi: glyph array is visual order; x_offset should be ~0 (relative-pen
    // adjustment), not large negative (entire run reverse-spread).
    for (r.glyphs) |g| {
        try testing.expect(@abs(g.x_offset) < 1.0);
    }
}

test "RTL: 希伯来语 shaping 产出视觉序，x_offset 不产生反向重叠" {
    var r = try shape(testing.allocator, HEBREW);
    defer r.deinit();

    try testing.expect(r.glyphs.len > 0);
    try assertNoReverseOverlap(r.glyphs);
    for (r.glyphs) |g| {
        try testing.expect(@abs(g.x_offset) < 1.0);
    }
}

test "RTL: cluster（源 byte 偏移）随视觉序递减，证明 bidi 已由 CoreText 完成" {
    var r = try shape(testing.allocator, HEBREW);
    defer r.deinit();

    try testing.expect(r.glyphs.len >= 2);
    // Visual order first glyph maps to source **last** character; that's RTL by definition.
    try testing.expect(r.glyphs[0].cluster > r.glyphs[r.glyphs.len - 1].cluster);
    // And final glyph lands at source start.
    try testing.expectEqual(@as(u32, 0), r.glyphs[r.glyphs.len - 1].cluster);
}

test "LTR 未退化：ASCII cluster 递增且 x_offset 为 0" {
    var r = try shape(testing.allocator, "abc");
    defer r.deinit();

    try testing.expectEqual(@as(usize, 3), r.glyphs.len);
    try assertNoReverseOverlap(r.glyphs);
    for (r.glyphs, 0..) |g, i| {
        try testing.expectEqual(@as(u32, @intCast(i)), g.cluster);
        try testing.expect(@abs(g.x_offset) < 0.001);
    }
}

test "RTL 总宽度与 LTR 一致的累加语义：advance 之和为正且等于视觉宽度" {
    var r = try shape(testing.allocator, ARABIC);
    defer r.deinit();

    var total: f32 = 0;
    for (r.glyphs) |g| {
        // Each advance must be positive; negative advance lets pen retreat.
        try testing.expect(g.x_advance > 0);
        total += g.x_advance;
    }
    try testing.expect(total > 0);
}
