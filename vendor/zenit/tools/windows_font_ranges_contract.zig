const std = @import("std");
const text = @import("text");
const Range = extern struct { font: ?*anyopaque, start: u32, length: u32, size: f32, italic_override: i32 = -1 };
const Glyph = extern struct { index: u32, cluster: u32, advance: f32, y_advance: f32, x: f32, y: f32, flags: u32, fallback: ?*anyopaque };
const Stop = extern struct { byte: u32, primary: f32, secondary: f32, split: u32 };
const Metrics = extern struct { width: f32, ascent: f32, descent: f32, leading: f32, rtl: u32 };
extern fn zenit_dwrite_create_font_ranges(?[*]const Range, u32, u32) ?*anyopaque;
extern fn zenit_dwrite_retain_font_ranges(*anyopaque) void;
extern fn zenit_dwrite_release_font_ranges(*anyopaque) void;
extern fn zenit_dwrite_measure_utf8_with_ranges(*anyopaque, [*]const u8, u32, ?*anyopaque) f32;
extern fn zenit_dwrite_shape_utf8_with_ranges(*anyopaque, [*]const u8, u32, c_int, *?[*]Glyph, *u32, ?*anyopaque) c_int;
extern fn zenit_dwrite_free_shaped_glyphs(?[*]Glyph) void;
extern fn zenit_dwrite_line_caret_stops_with_ranges(*anyopaque, [*]const u8, u32, [*]const u32, u32, [*]Stop, *Metrics, ?*anyopaque) c_int;
extern fn zenit_dwrite_font_identity(*anyopaque) u64;
fn require(ok: bool) !void {
    if (!ok) return error.FontRangesContractFailed;
}
fn freeGlyphs(glyphs: ?[*]Glyph, count: u32) void {
    if (glyphs) |items| for (items[0..count]) |glyph| {
        if (glyph.fallback) |font| text.releaseFallbackFontRef(font);
    };
    zenit_dwrite_free_shaped_glyphs(glyphs);
}
fn reject(specs: []const Range, length: u32) !void {
    const result = zenit_dwrite_create_font_ranges(specs.ptr, @intCast(specs.len), length);
    if (result) |r| {
        zenit_dwrite_release_font_ranges(r);
        return error.AcceptedInvalidFontRanges;
    }
}
pub fn run(fonts: *text.FontSystem) !void {
    const primary = try fonts.findFont(.{ .family = "Segoe UI", .size = 16 });
    defer primary.deinit();
    const japanese = try fonts.findFont(.{ .family = "Yu Gothic UI", .size = 16 });
    var source_alive = true;
    defer if (source_alive) japanese.deinit();
    const identity = zenit_dwrite_font_identity(japanese.native);
    try checkZigApi(primary, japanese);
    try checkTextContext(fonts, primary, japanese);
    const sample = "A中文B";
    const original = primary.measureWidth(sample);
    var specs = [_]Range{.{ .font = japanese.native, .start = 1, .length = 2, .size = 24 }};
    try reject(&.{.{ .font = primary.native, .start = 0, .length = 1, .size = 16, .italic_override = 2 }}, 4);
    try reject(&.{.{ .font = null, .start = 0, .length = 1, .size = 16 }}, 4);
    try reject(&.{.{ .font = primary.native, .start = 0, .length = 0, .size = 16 }}, 4);
    try reject(&.{.{ .font = primary.native, .start = 0, .length = 5, .size = 16 }}, 4);
    try reject(&.{.{ .font = primary.native, .start = 0xffffffff, .length = 1, .size = 16 }}, 4);
    try reject(&.{.{ .font = primary.native, .start = 0, .length = 1, .size = std.math.nan(f32) }}, 4);
    try reject(&.{.{ .font = primary.native, .start = 0, .length = 1, .size = std.math.inf(f32) }}, 4);
    try reject(&.{ specs[0], .{ .font = primary.native, .start = 2, .length = 1, .size = 16 } }, 4);
    const ranges = zenit_dwrite_create_font_ranges(&specs, 1, 4) orelse return error.FontRangesCreationFailed;
    defer zenit_dwrite_release_font_ranges(ranges);
    zenit_dwrite_retain_font_ranges(ranges);
    zenit_dwrite_release_font_ranges(ranges);
    specs[0] = .{ .font = null, .start = 0xffffffff, .length = 0, .size = 0 }; // Borrowed array is copied.
    japanese.deinit();
    source_alive = false; // Snapshot owns the source native font.
    const width = zenit_dwrite_measure_utf8_with_ranges(primary.native, sample.ptr, sample.len, ranges);
    try require(width > original + 10 and @abs(primary.measureWidth(sample) - original) < 0.01);
    var glyphs: ?[*]Glyph = null;
    var count: u32 = 0;
    try require(zenit_dwrite_shape_utf8_with_ranges(primary.native, sample.ptr, sample.len, 0, &glyphs, &count, ranges) == 0);
    defer freeGlyphs(glyphs, count);
    try require(count == 4);
    var total: f32 = 0;
    var selected: u32 = 0;
    for (glyphs.?[0..count]) |glyph| {
        total += glyph.advance;
        if (glyph.cluster == 1 or glyph.cluster == 4) {
            const ref = glyph.fallback orelse return error.MissingExplicitFont;
            try require(zenit_dwrite_font_identity(ref) == identity and text.fallbackFontRefSize(ref) == 24);
            selected += 1;
        }
    }
    try require(selected == 2 and @abs(total - width) < 0.01);
    const boundaries = [_]u32{ 0, 1, 4, 7, 8 };
    var stops: [5]Stop = undefined;
    var metrics: Metrics = undefined;
    try require(zenit_dwrite_line_caret_stops_with_ranges(primary.native, sample.ptr, sample.len, &boundaries, 5, &stops, &metrics, ranges) == 0);
    try require(@abs(metrics.width - width) < 0.01 and @abs(stops[4].primary - width) < 0.01 and
        @abs(stops[2].primary - stops[1].primary - 24) < 0.01 and @abs(stops[3].primary - stops[2].primary - 24) < 0.01);
    try require(metrics.ascent + metrics.descent > primary.getAscent() + primary.getDescent() + 4 and
        metrics.ascent > 0 and metrics.descent >= 0 and metrics.leading == 0);
    // Applying this snapshot to a different text length must fail, not truncate.
    var invalid_glyphs: ?[*]Glyph = null;
    var invalid_count: u32 = 0;
    try require(zenit_dwrite_shape_utf8_with_ranges(primary.native, "AB", 2, 0, &invalid_glyphs, &invalid_count, ranges) == -1);
    try require(invalid_glyphs == null and invalid_count == 0);
    const split = zenit_dwrite_create_font_ranges(&.{.{ .font = primary.native, .start = 2, .length = 1, .size = 16 }}, 1, 4) orelse return error.FontRangesCreationFailed;
    defer zenit_dwrite_release_font_ranges(split);
    const emoji = "A😀B";
    try require(zenit_dwrite_shape_utf8_with_ranges(primary.native, emoji.ptr, emoji.len, 0, &invalid_glyphs, &invalid_count, split) == -1);
    try require(invalid_glyphs == null and invalid_count == 0);
    std.debug.print("Font ranges: selected Japanese face at 24px; owned snapshot after source free; shape/measure/caret width={d:.2}, unchanged base, invalid ranges and surrogate split rejection PASS\n", .{width});
}

// A range must keep the application's private collection, weight and italic
// style, rather than resolving the family name against the system collection.
pub fn checkPrivate(primary: *text.Font, source: *text.Font) !void {
    const sample = "AV ffi Windows";
    const derived = try source.derive(24);
    defer derived.deinit();
    const expected = derived.measureWidth(sample);
    const ranges = zenit_dwrite_create_font_ranges(&.{.{ .font = source.native, .start = 0, .length = sample.len, .size = 24 }}, 1, sample.len) orelse return error.FontRangesCreationFailed;
    defer zenit_dwrite_release_font_ranges(ranges);
    const width = zenit_dwrite_measure_utf8_with_ranges(primary.native, sample.ptr, sample.len, ranges);
    try require(@abs(width - expected) < 0.01);
    var glyphs: ?[*]Glyph = null;
    var count: u32 = 0;
    // Deliberately request the opposite primary style. The selected range's
    // own style wins, including the regular fixture's nonitalic style.
    try require(zenit_dwrite_shape_utf8_with_ranges(primary.native, sample.ptr, sample.len, if (source.italic) 0 else 1, &glyphs, &count, ranges) == 0);
    defer freeGlyphs(glyphs, count);
    try require(count > 0);
    var advance: f32 = 0;
    for (glyphs.?[0..count]) |glyph| {
        advance += glyph.advance;
        const ref = glyph.fallback orelse return error.MissingPrivateRangeFont;
        try require(zenit_dwrite_font_identity(ref) == zenit_dwrite_font_identity(source.native) and text.fallbackFontRefSize(ref) == 24);
    }
    try require(@abs(advance - width) < 0.01);
    const boundaries = [_]u32{ 0, sample.len };
    var stops: [2]Stop = undefined;
    var metrics: Metrics = undefined;
    try require(zenit_dwrite_line_caret_stops_with_ranges(primary.native, sample.ptr, sample.len, &boundaries, 2, &stops, &metrics, ranges) == 0);
    try require(@abs(metrics.width - width) < 0.01 and @abs(stops[1].primary - width) < 0.01);
    std.debug.print("Private font range: weight={d} italic={} private face, shape/measure/caret width={d:.2} PASS\n", .{ source.weight, source.italic, width });
}

fn checkZigApi(primary: *text.Font, selected: *text.Font) !void {
    const allocator = std.heap.page_allocator;
    var content = [_]u8{ 'A', 0xe4, 0xb8, 0xad, 0xe6, 0x96, 0x87, 'B' };
    const sample = "A中文B";
    var snapshot = try text.FontRanges.init(allocator, &content, &.{.{ .font = selected, .start = 1, .length = 6, .size = 24 }});
    defer snapshot.deinit();
    content[0] = 'Z'; // The snapshot must own its text.
    const width = try primary.measureWidthWithRanges(sample, &snapshot);
    var shaper = try text.TextShaper.init(allocator);
    defer shaper.deinit();
    const glyphs = try shaper.shapeWithRanges(sample, primary, false, &snapshot);
    defer allocator.free(glyphs);
    defer for (glyphs) |glyph| if (glyph.fallback_font_ref) |ref| text.releaseFallbackFontRef(ref);
    var advance: f32 = 0;
    var selected_count: u32 = 0;
    for (glyphs) |glyph| {
        advance += glyph.x_advance;
        if (glyph.cluster == 1 or glyph.cluster == 4) {
            const ref = glyph.fallback_font_ref orelse return error.MissingExplicitFont;
            try require(zenit_dwrite_font_identity(ref) == zenit_dwrite_font_identity(selected.native) and text.fallbackFontRefSize(ref) == 24);
            selected_count += 1;
        }
    }
    try require(selected_count == 2 and @abs(width - advance) < 0.01);
    const boundaries = [_]u32{ 0, 1, 4, 7, 8 };
    var stops: [5]text.LineCaretStop = undefined;
    const metrics = try primary.lineCaretStopsWithRanges(sample, &boundaries, &stops, &snapshot);
    try require(@abs(metrics.width - width) < 0.01 and @abs(stops[4].primary_x - width) < 0.01);
    try std.testing.expectError(error.FontRangeTextMismatch, primary.measureWidthWithRanges("A文中B", &snapshot));
    try std.testing.expectError(error.FontRangeTextMismatch, shaper.shapeWithRanges("A文中B", primary, false, &snapshot));
    try std.testing.expectError(error.FontRangeTextMismatch, primary.lineCaretStopsWithRanges("A文中B", &boundaries, &stops, &snapshot));
    try std.testing.expectError(error.InvalidUtf8, text.FontRanges.init(allocator, "\xff", &.{}));
    try std.testing.expectError(error.InvalidFontRangeBoundary, text.FontRanges.init(allocator, sample, &.{.{ .font = selected, .start = 2, .length = 2, .size = 24 }}));
    try std.testing.expectError(error.InvalidFontRangeBoundary, text.FontRanges.init(allocator, sample, &.{.{ .font = selected, .start = 1, .length = 1, .size = 24 }}));
    try std.testing.expectError(error.InvalidFontRange, text.FontRanges.init(allocator, sample, &.{.{ .font = selected, .start = 7, .length = 2, .size = 24 }}));
    // A supplementary scalar is four UTF-8 bytes and two UTF-16 units.
    const emoji = "A😀B";
    var emoji_snapshot = try text.FontRanges.init(allocator, emoji, &.{.{ .font = primary, .start = 1, .length = 4, .size = 24 }});
    defer emoji_snapshot.deinit();
    const emoji_width = try primary.measureWidthWithRanges(emoji, &emoji_snapshot);
    const emoji_boundaries = [_]u32{ 0, 1, 5, 6 };
    var emoji_stops: [4]text.LineCaretStop = undefined;
    const emoji_metrics = try primary.lineCaretStopsWithRanges(emoji, &emoji_boundaries, &emoji_stops, &emoji_snapshot);
    try require(emoji_width > 0 and @abs(emoji_metrics.width - emoji_width) < 0.01 and @abs(emoji_stops[3].primary_x - emoji_width) < 0.01);
    std.debug.print("Zig font ranges: UTF-8/UTF-16 conversion, owned text, same-length text mismatch, invalid scalar boundaries, selected face and shape/measure/caret parity PASS\n", .{});
}

const ContextProvider = struct {
    primary: *text.Font,
    selected: *text.Font,
    calls: u32 = 0,
    const ui = @import("ui");
    fn resolve(raw: *anyopaque, _: ui.Cx.ShapeTextOpts) ?*text.Font {
        const self: *ContextProvider = @ptrCast(@alignCast(raw));
        return self.primary;
    }
    fn ranges(raw: *anyopaque, opts: ui.Cx.ShapeTextOpts, font: *text.Font, allocator: std.mem.Allocator) !?*text.FontRanges {
        const self: *ContextProvider = @ptrCast(@alignCast(raw));
        try require(std.mem.eql(u8, opts.text, "A中文B") and font == self.primary);
        const snapshot = try allocator.create(text.FontRanges);
        errdefer allocator.destroy(snapshot);
        snapshot.* = try text.FontRanges.init(allocator, opts.text, &.{
            .{ .font = self.selected, .start = 1, .length = 6, .size = opts.font_size },
        });
        self.calls += 1;
        return snapshot;
    }
};
fn checkTextContext(fonts: *text.FontSystem, primary: *text.Font, selected: *text.Font) !void {
    const ui = @import("ui");
    const TextContext = @TypeOf(@as(ui.Cx, undefined).text);
    var context = TextContext.init(std.heap.page_allocator, 32);
    defer context.deinit();
    context.setFontSystem(fonts);
    var provider = ContextProvider{ .primary = primary, .selected = selected };
    context.font_resolve_fn = ContextProvider.resolve;
    context.font_resolve_ctx = &provider;
    const opts = ui.Cx.ShapeTextOpts{ .text = "A中文B", .font_family = "system", .font_size = 24 };
    // Prime both caches without a provider. Installing one must invalidate them.
    _ = try context.shapeText(opts);
    _ = try context.visualLine(opts);
    context.setFontRangesProvider(&provider, ContextProvider.ranges);
    const shaped_run = try context.shapeText(opts);
    const line = try context.visualLine(opts);
    const requested_primary = try primary.derive(opts.font_size);
    defer requested_primary.deinit();
    var snapshot = (try ContextProvider.ranges(&provider, opts, primary, std.heap.page_allocator)).?;
    defer {
        snapshot.deinit();
        std.heap.page_allocator.destroy(snapshot);
    }
    const expected = try requested_primary.measureWidthWithRanges(opts.text, snapshot);
    std.debug.print("TextContext range widths shape={d:.4} visual={d:.4} expected={d:.4} calls={d}\n", .{ shaped_run.total_advance, line.width, expected, provider.calls });
    try require(@abs(shaped_run.total_advance - expected) < 0.01 and @abs(line.width - expected) < 0.01);
    try require(@abs(context.measureTextWidth(opts.text, opts.font_size, 400, false) - expected) < 0.01);
    const calls = provider.calls;
    _ = try context.shapeText(opts);
    _ = try context.visualLine(opts);
    std.debug.print("TextContext range cache calls={d} expected={d}\n", .{ provider.calls, calls });
    try require(provider.calls == calls);
    // A second context must retain its own provider and selection.
    const mono = try fonts.findFont(.{ .family = "Consolas", .size = 16 });
    defer mono.deinit();
    var other = TextContext.init(std.heap.page_allocator, 32);
    defer other.deinit();
    other.setFontSystem(fonts);
    other.font_resolve_fn = ContextProvider.resolve;
    var other_provider = ContextProvider{ .primary = mono, .selected = selected };
    other.font_resolve_ctx = &other_provider;
    other.setFontRangesProvider(&other_provider, ContextProvider.ranges);
    const other_line = try other.visualLine(opts);
    std.debug.print("TextContext range contexts first={d:.4} other={d:.4} calls={d}/{d}\n", .{ line.width, other_line.width, provider.calls, calls });
    try require(@abs(other_line.width - line.width) > 0.1 and provider.calls == calls);
    // Rebind changed selection, including same context and callback addresses.
    provider.primary = mono;
    provider.selected = selected;
    context.setFontRangesProvider(&provider, ContextProvider.ranges);
    const rebound = try context.visualLine(opts);
    std.debug.print("TextContext range rebound={d:.4} expected={d:.4}\n", .{ rebound.width, other_line.width });
    try require(@abs(rebound.width - other_line.width) < 0.01);
    context.setFontRangesProvider(null, null);
    _ = try context.shapeText(opts);
    std.debug.print("TextContext ranges: shared selected-width shape/measure/VisualLine, cache hits, rebind invalidation and independent contexts PASS\n", .{});
}
