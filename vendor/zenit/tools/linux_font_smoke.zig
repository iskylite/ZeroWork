//! System font discovery, fractional size and physical/logical scaling gate.
const std = @import("std");
const text = @import("text");
fn freeGlyphs(a: std.mem.Allocator, glyphs: []text.ShapedGlyph) void {
    for (glyphs) |glyph| if (glyph.fallback_font_ref) |ref| text.releaseFallbackFontRef(ref);
    a.free(glyphs);
}
pub fn main(init: std.process.Init) !void {
    const a = init.arena.allocator();
    var system = try text.FontSystem.init(a, init.io);
    defer system.deinit();
    system.setDefaultFamily("sans-serif");
    const font = try system.findFont(.{ .family = "system", .size = 12.5 });
    defer font.deinit();
    if (@abs(font.pixelSize() - 12.5) > 0.001) return error.FractionalFontSizeLost;
    var shaper = try text.TextShaper.init(a);
    defer shaper.deinit();
    const glyphs1 = try shaper.shape("AV", font);
    defer freeGlyphs(a, glyphs1);
    if (glyphs1.len != 2 or glyphs1[0].glyph_index == 0) return error.LatinShapeFailed;
    const raster1 = try text.Font.fromFallbackRef(a, glyphs1[0].fallback_font_ref orelse return error.MissingFontReference, font);
    defer raster1.deinit();
    const bitmap1 = try raster1.rasterizeGlyph(glyphs1[0].glyph_index);
    defer bitmap1.deinit(a);
    // font_smoothing = false (iOS-idiom glass labels) means "no macOS stem darkening", never
    // monochrome: the glyph keeps antialiased (intermediate) coverage.
    raster1.smooth_fonts = false;
    const unsmoothed = try raster1.rasterizeGlyph(glyphs1[0].glyph_index);
    defer unsmoothed.deinit(a);
    raster1.smooth_fonts = true;
    var partial: usize = 0;
    for (unsmoothed.pixels) |v| {
        if (v > 16 and v < 240) partial += 1;
    }
    if (partial == 0) return error.UnsmoothedGlyphNotAntialiased;
    const ascent1 = font.getAscent();
    font.setScaleFactor(2);
    const glyphs2 = try shaper.shape("AV", font);
    defer freeGlyphs(a, glyphs2);
    const raster2 = try text.Font.fromFallbackRef(a, glyphs2[0].fallback_font_ref orelse return error.MissingFontReference, font);
    defer raster2.deinit();
    const bitmap2 = try raster2.rasterizeGlyph(glyphs2[0].glyph_index);
    defer bitmap2.deinit(a);
    if (bitmap2.height <= bitmap1.height or bitmap2.width <= bitmap1.width) return error.PhysicalRasterDidNotScale;
    var width1: f32 = 0;
    var width2: f32 = 0;
    for (glyphs1) |glyph| width1 += glyph.x_advance;
    for (glyphs2) |glyph| width2 += glyph.x_advance;
    if (@abs(width1 - width2) > 1 or @abs(font.getAscent() - ascent1) > 1) return error.LogicalMetricsChangedWithScale;
    font.setScaleFactor(0);
    if (font.scale_factor != 2) return error.InvalidScaleAccepted;
    const arabic = try shaper.shape("مرحبا", font);
    defer freeGlyphs(a, arabic);
    if (arabic.len == 0 or arabic[0].cluster <= arabic[arabic.len - 1].cluster) return error.ArabicDirectionNotGuessed;
    for (arabic) |glyph| if (glyph.glyph_index == 0) return error.ArabicGlyphMissing;
    const arabic_face = try text.Font.fromFallbackRef(a, arabic[0].fallback_font_ref orelse return error.MissingFontReference, font);
    defer arabic_face.deinit();
    const arabic_bitmap = try arabic_face.rasterizeGlyph(arabic[0].glyph_index);
    defer arabic_bitmap.deinit(a);
    if (arabic_bitmap.width == 0 or arabic_bitmap.height == 0) return error.FallbackRasterEmpty;
    const sample = "abc אבג xyz";
    const boundaries = [_]u32{ 0, 1, 2, 3, 4, 6, 8, 10, 11, 12, 13, 14 };
    var stops: [boundaries.len]text.LineCaretStop = undefined;
    const metrics = try font.lineCaretStops(sample, &boundaries, &stops);
    if (metrics.width <= 0 or metrics.base_rtl or @abs(stops[stops.len - 1].primary_x - metrics.width) > 0.01) return error.MixedBidiCaretMetricsFailed;
    var secondary = false;
    for (stops) |stop| {
        if (!std.math.isFinite(stop.primary_x) or stop.primary_x < -0.01 or stop.primary_x > metrics.width + 0.01) return error.CaretOutsideLine;
        secondary = secondary or stop.has_secondary;
    }
    if (!secondary) return error.BidiSecondaryCaretMissing;
    if (stops[5].primary_x <= stops[6].primary_x) return error.RtlCaretOrderFailed;
    const mixed = try shaper.shape(sample, font);
    defer freeGlyphs(a, mixed);
    var shaped_width: f32 = 0;
    for (mixed) |glyph| shaped_width += glyph.x_advance;
    if (@abs(shaped_width - metrics.width) > 0.01) return error.CaretShapeGeometryMismatch;
    if (font.lineCaretStops(sample, &.{5}, &stops)) |_| return error.InvalidUtf8CaretAccepted else |_| {}
    const bold = try system.findFont(.{ .family = "sans-serif", .size = 14, .weight = .bold, .style = .italic });
    defer bold.deinit();
    var stroke_mass: [2]u64 = .{ 0, 0 };
    for ([_]text.FontWeight{ .regular, .semibold }, 0..) |weight, tier| {
        const weighted = try system.findFont(.{ .family = "Helvetica Neue", .size = 13, .weight = weight });
        defer weighted.deinit();
        const shaped = try shaper.shape("H", weighted);
        defer freeGlyphs(a, shaped);
        if (shaped.len != 1) return error.WeightedShapeFailed;
        const ref = shaped[0].fallback_font_ref orelse return error.MissingFontReference;
        const name = text.fallbackFontRefDebugName(a, ref) orelse return error.InvalidFallbackFontRef;
        defer a.free(name);
        const face = try text.Font.fromFallbackRef(a, ref, weighted);
        defer face.deinit();
        const bitmap = try face.rasterizeGlyph(shaped[0].glyph_index);
        defer bitmap.deinit(a);
        if (bitmap.is_color or bitmap.width == 0 or bitmap.height == 0) return error.WeightedRasterMissing;
        for (bitmap.pixels) |coverage| stroke_mass[tier] += coverage;
        std.debug.print("LINUX_WEIGHTED_FONT: weight={s} face={s} stroke_mass={d}\n", .{ @tagName(weight), name, stroke_mass[tier] });
    }
    if (stroke_mass[1] <= stroke_mass[0]) return error.SemiboldRasterDidNotGainWeight;
    const emoji_font = try system.findFont(.{ .family = "system", .size = 64 });
    defer emoji_font.deinit();
    for ([_][]const u8{ "🟥", "🟩", "🟦" }, 0..) |sample_emoji, channel| {
        const emoji = try shaper.shape(sample_emoji, emoji_font);
        defer freeGlyphs(a, emoji);
        if (emoji.len != 1 or emoji[0].glyph_index == 0) return error.ColorEmojiShapeFailed;
        const ref = emoji[0].fallback_font_ref orelse return error.MissingFontReference;
        const name = text.fallbackFontRefDebugName(a, ref) orelse return error.InvalidFallbackFontRef;
        defer a.free(name);
        std.debug.print("LINUX_COLOR_FONT: {s}\n", .{name});
        const face = try text.Font.fromFallbackRef(a, ref, emoji_font);
        defer face.deinit();
        const bitmap = try face.rasterizeGlyph(emoji[0].glyph_index);
        defer bitmap.deinit(a);
        if (!bitmap.is_color or bitmap.width == 0 or bitmap.height == 0) return error.ColorEmojiRasterMissing;
        const center = ((bitmap.height / 2) * bitmap.width + bitmap.width / 2) * 4;
        // GlyphBitmap is premultiplied BGRA. The three squares must retain
        // their distinct color through the actual fallback font rasterizer.
        const dominant = 2 - channel;
        for (0..3) |other| if (other != dominant and bitmap.pixels[center + dominant] <= bitmap.pixels[center + other] +| 30) return error.ColorEmojiChannelsLost;
        if (bitmap.pixels[center + 3] < 200) return error.ColorEmojiCenterTransparent;
    }
    if (system.findFont(.{ .family = "system", .size = 0 })) |invalid| {
        invalid.deinit();
        return error.InvalidFontSizeAccepted;
    } else |_| {}
    std.debug.print("LINUX_FONT PASS: family_discovery=true fractional_size=true scale_2x=true logical_metrics=true arabic_rtl=true fallback_raster=true bidi_carets=true shape_caret_width=true bold_italic=true color_emoji=true\n", .{});
}
