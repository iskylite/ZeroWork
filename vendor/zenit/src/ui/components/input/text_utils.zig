/// Text Utilities for Input Component
///
/// Pure functions: UTF-8 encode/decode, CJK detection, text width estimate/measure, char classify.
/// No UI dependency.
const std = @import("std");
const builtin = @import("builtin");
const core = @import("../../core.zig");
const text_core = @import("text_core");
const grapheme = text_core.grapheme;

pub fn visualCaretX(
    cx: *core.Cx,
    text: []const u8,
    position: text_core.TextPosition,
    font_size: f32,
    font_weight: u16,
) ?f32 {
    const line = cx.text.visualLine(.{
        .text = text,
        .font_family = "system",
        .font_size = font_size,
        .font_weight = font_weight,
    }) catch return null;
    return (line.positionToCaret(position) catch return null).x.value;
}

pub fn visualPositionForX(cx: *core.Cx, text: []const u8, x: f32, font_size: f32, font_weight: u16) ?text_core.TextPosition {
    const line = cx.text.visualLine(.{
        .text = text,
        .font_family = "system",
        .font_size = font_size,
        .font_weight = font_weight,
    }) catch return null;
    return line.xToPosition(.{ .value = @max(x, 0) });
}

/// Safely calculate nanosecond difference between two Instants
/// Return 0 when epoch later than now (time reverse/same-frame resetBlink) instead of panic
pub fn safeElapsedNs(now: @import("zenit_time").Instant, epoch: @import("zenit_time").Instant) u64 {
    if (now.order(epoch) == .lt) return 0;
    return now.since(epoch);
}

fn testInstant(sec: u64, nsec: u32) @import("zenit_time").Instant {
    return .{ .timestamp = @as(i96, sec) * std.time.ns_per_s + nsec };
}

test "safeElapsedNs clamps reversed instants" {
    const earlier = testInstant(10, 0);
    const later = testInstant(11, 0);

    try std.testing.expectEqual(@as(u64, 0), safeElapsedNs(earlier, later));
    try std.testing.expectEqual(@as(u64, std.time.ns_per_s), safeElapsedNs(later, earlier));
}

/// CoreText FFI declarations
pub const native_text = if (builtin.os.tag == .macos and !builtin.is_test) struct {
    extern fn coretext_measure_text_width_utf8(text: [*]const u8, len: c_int, font_size: f32) f32;
    extern fn coretext_measure_text_width_weighted(text: [*]const u8, len: c_int, font_size: f32, font_weight: c_int) f32;
} else struct {};

// ========== UTF-8 encode/decode ==========

pub fn utf8CodepointLen(text: []const u8) usize {
    var i: usize = 0;
    var count: usize = 0;
    while (i < text.len) {
        const n = std.unicode.utf8ByteSequenceLength(text[i]) catch {
            i += 1;
            count += 1;
            continue;
        };
        i += @min(n, text.len - i);
        count += 1;
    }
    return count;
}

/// Given Nth codepoint, return corresponding UTF-8 byte offset.
/// password mode click hit test translates mask codepoint index back to buffer byte offset.
pub fn utf8ByteOffsetForCodepointIndex(text: []const u8, cp_index: usize) usize {
    var i: usize = 0;
    var cp: usize = 0;
    while (i < text.len and cp < cp_index) : (cp += 1) {
        const n = std.unicode.utf8ByteSequenceLength(text[i]) catch {
            i += 1;
            continue;
        };
        i += @min(n, text.len - i);
    }
    return i;
}

pub fn utf8GraphemeLen(text: []const u8) usize {
    return grapheme.count(text);
}

pub fn utf8ByteOffsetForGraphemeIndex(text: []const u8, grapheme_index: usize) usize {
    var index: usize = 0;
    var offset: usize = 0;
    var cursor = grapheme.BoundaryCursor.init(text);
    while (offset < text.len and index < grapheme_index) : (index += 1) {
        offset = cursor.next(offset);
    }
    return offset;
}

pub fn utf8DecodeNext(text: []const u8, i: usize, out_cp: *u21) usize {
    const b = text[i];
    const n = std.unicode.utf8ByteSequenceLength(b) catch {
        out_cp.* = @intCast(b);
        return 1;
    };
    const step = @min(n, text.len - i);
    if (step == n) {
        out_cp.* = std.unicode.utf8Decode(text[i .. i + step]) catch @as(u21, @intCast(b));
    } else {
        out_cp.* = @intCast(b);
    }
    return step;
}

/// Decode one UTF-8 codepoint leftward, return {byte_start, codepoint}
/// Free function version (extracted from TextInputState method)
pub fn utf8DecodePrev(text: []const u8, pos: usize) struct { start: usize, cp: u21 } {
    if (pos == 0) return .{ .start = 0, .cp = 0 };
    var i = pos - 1;
    // Back up to UTF-8 sequence start byte
    while (i > 0 and (text[i] & 0xC0) == 0x80) : (i -= 1) {}
    var cp: u21 = 0;
    _ = utf8DecodeNext(text, i, &cp);
    return .{ .start = i, .cp = cp };
}

// ========== CJK detection ==========

/// Check if codepoint is CJK character (Chinese/Japanese/Korean + fullwidth punctuation + kana)
pub fn isCJKCodepoint(cp: u21) bool {
    return (cp >= 0x4E00 and cp <= 0x9FFF) or // CJK base
        (cp >= 0x3400 and cp <= 0x4DBF) or // CJK extension A
        (cp >= 0x20000 and cp <= 0x2A6DF) or // CJK extension B
        (cp >= 0x2A700 and cp <= 0x2B73F) or // CJK extension C
        (cp >= 0x2B740 and cp <= 0x2B81F) or // CJK extension D
        (cp >= 0xF900 and cp <= 0xFAFF) or // CJK compatibility
        (cp >= 0x3000 and cp <= 0x303F) or // CJK symbols punctuation
        (cp >= 0x3040 and cp <= 0x309F) or // Hiragana
        (cp >= 0x30A0 and cp <= 0x30FF) or // Katakana
        (cp >= 0xFF00 and cp <= 0xFFEF) or // Fullwidth character
        (cp >= 0xAC00 and cp <= 0xD7AF) or // Hangul syllables
        (cp >= 0x1100 and cp <= 0x11FF); // Hangul letter
}

pub fn codepointDisplayUnits(cp: u21) usize {
    return if ((cp >= 0x1100 and cp <= 0x115F) or
        (cp >= 0x2329 and cp <= 0x232A) or
        (cp >= 0x2E80 and cp <= 0xA4CF and cp != 0x303F) or
        (cp >= 0xAC00 and cp <= 0xD7A3) or
        (cp >= 0xF900 and cp <= 0xFAFF) or
        (cp >= 0xFE10 and cp <= 0xFE19) or
        (cp >= 0xFE30 and cp <= 0xFE6F) or
        (cp >= 0xFF00 and cp <= 0xFF60) or
        (cp >= 0xFFE0 and cp <= 0xFFE6) or
        (cp >= 0x20000 and cp <= 0x2FFFD) or
        (cp >= 0x30000 and cp <= 0x3FFFD)) 2 else 1;
}

pub fn utf8DisplayUnits(text: []const u8) usize {
    var i: usize = 0;
    var units: usize = 0;
    while (i < text.len) {
        var cp: u21 = 0;
        const step = utf8DecodeNext(text, i, &cp);
        units += codepointDisplayUnits(cp);
        i += step;
    }
    return units;
}

pub fn utf8DisplayUnitsPrefix(text: []const u8, end_bytes: usize) usize {
    const end = @min(end_bytes, text.len);
    return utf8DisplayUnits(text[0..end]);
}

// ========== estimate measure ==========

pub fn estimateCodepointAdvance(cp: u21, char_width: f32) f32 {
    const units = codepointDisplayUnits(cp);
    return @as(f32, @floatFromInt(units)) * char_width;
}

pub fn utf8EstimatedAdvance(text: []const u8, char_width: f32) f32 {
    var i: usize = 0;
    var advance: f32 = 0;
    while (i < text.len) {
        var cp: u21 = 0;
        const step = utf8DecodeNext(text, i, &cp);
        advance += estimateCodepointAdvance(cp, char_width);
        i += step;
    }
    return advance;
}

pub fn utf8ByteOffsetForEstimatedX(text: []const u8, target_x: f32, char_width: f32) usize {
    if (target_x <= 0) return 0;

    var i: usize = 0;
    var advance: f32 = 0;
    var cursor = grapheme.BoundaryCursor.init(text);
    while (i < text.len) {
        const next = cursor.next(i);
        const glyph_advance = utf8EstimatedAdvance(text[i..next], char_width);
        const next_advance = advance + glyph_advance;

        if (target_x < next_advance) {
            const left = target_x - advance;
            const right = next_advance - target_x;
            return if (left < right) i else next;
        }
        if (target_x == next_advance) return next;

        advance = next_advance;
        i = next;
    }
    return text.len;
}

// ========== platform measure ==========

pub fn usePlatformTextMeasure() bool {
    return builtin.os.tag == .macos and !builtin.is_test;
}

pub fn measureTextWidthPlatform(text: []const u8, font_size: f32, font_weight: u16) ?f32 {
    if (text.len == 0) return 0;
    // Use text_layout unified measure (prefer injected GPU renderer font measure function,
    // consistent with actual render, avoid CoreText vs GPU font width divergence causing scroll_x
    // drift)
    const width = core.text_layout.measureTextWidthByFontKind(text, font_size, font_weight, false, false);
    if (width > 0) return width;
    if (!usePlatformTextMeasure()) return null;
    const ct_width = if (comptime (builtin.os.tag == .macos and !builtin.is_test))
        if (font_weight > 400)
            native_text.coretext_measure_text_width_weighted(text.ptr, @intCast(text.len), font_size, @intCast(font_weight))
        else
            native_text.coretext_measure_text_width_utf8(text.ptr, @intCast(text.len), font_size)
    else
        return null;
    if (!std.math.isFinite(ct_width) or ct_width < 0) return null;
    return ct_width;
}

pub fn utf8MeasuredAdvance(text: []const u8, char_width: f32, font_size: f32, font_weight: u16) f32 {
    return utf8MeasuredAdvanceCx(null, text, char_width, font_size, font_weight);
}

/// cx-aware variant, use cx.shapeText (GlyphRun pipeline + ShapingCache)
/// replace direct platform bridge. cx == null degrade to old path (utf8MeasuredAdvance compat).
/// Failure (NoFontProvider / FontLookupFailed / OOM) silent fallback to platform bridge
/// or ASCII estimate, avoid caller error handling.
pub fn utf8MeasuredAdvanceCx(cx_ref: ?*core.Cx, text: []const u8, char_width: f32, font_size: f32, font_weight: u16) f32 {
    if (text.len == 0) return 0;
    if (cx_ref) |cx| {
        if (cx.text.shapeText(.{
            .text = text,
            .font_family = "system",
            .font_size = font_size,
            .font_weight = font_weight,
            .use_italic = false,
        })) |run| {
            return run.total_advance;
        } else |_| {
            // shape failure (typical NoFontProvider / FontLookupFailed) -> degrade
        }
    }
    if (measureTextWidthPlatform(text, font_size, font_weight)) |w| return w;
    return utf8EstimatedAdvance(text, char_width);
}

pub fn utf8MeasuredAdvancePrefix(text: []const u8, end_bytes: usize, char_width: f32, font_size: f32, font_weight: u16) f32 {
    return utf8MeasuredAdvancePrefixCx(null, text, end_bytes, char_width, font_size, font_weight);
}

pub fn utf8MeasuredAdvancePrefixCx(cx_ref: ?*core.Cx, text: []const u8, end_bytes: usize, char_width: f32, font_size: f32, font_weight: u16) f32 {
    const end = @min(end_bytes, text.len);
    if (cx_ref) |cx| {
        const line = cx.text.visualLine(.{
            .text = text,
            .font_family = "system",
            .font_size = font_size,
            .font_weight = font_weight,
        }) catch return utf8MeasuredAdvanceCx(cx_ref, text[0..end], char_width, font_size, font_weight);
        const clamped = text_core.text_coordinates.clampByteOffset(text, .{ .value = end }, .nearest);
        const position = text_core.TextPosition{ .byte = clamped, .affinity = .downstream };
        const stop = line.positionToCaret(position) catch
            line.positionToCaret(.{ .byte = clamped, .affinity = .upstream }) catch
            return utf8MeasuredAdvanceCx(cx_ref, text[0..end], char_width, font_size, font_weight);
        return stop.x.value;
    }
    return utf8MeasuredAdvanceCx(cx_ref, text[0..end], char_width, font_size, font_weight);
}

pub fn utf8ByteOffsetForMeasuredX(text: []const u8, target_x: f32, char_width: f32, font_size: f32, font_weight: u16) usize {
    return utf8ByteOffsetForMeasuredXCx(null, text, target_x, char_width, font_size, font_weight);
}

pub fn utf8ByteOffsetForMeasuredXCx(cx_ref: ?*core.Cx, text: []const u8, target_x: f32, char_width: f32, font_size: f32, font_weight: u16) usize {
    if (!usePlatformTextMeasure() and cx_ref == null) {
        return utf8ByteOffsetForEstimatedX(text, target_x, char_width);
    }
    if (text.len == 0) return 0;

    if (cx_ref) |cx| {
        const line = cx.text.visualLine(.{
            .text = text,
            .font_family = "system",
            .font_size = font_size,
            .font_weight = font_weight,
        }) catch null;
        if (line) |visual| {
            return visual.xToPosition(.{ .value = @max(target_x, 0) }).byte.value;
        }
    }
    if (target_x <= 0) return 0;

    // Walk extended-grapheme boundaries. Prefix measurement is transitional;
    // the shared VisualLine model will replace it, but it must never return a
    // byte inside a user-perceived character in the meantime.
    var i: usize = 0;
    var previous_advance: f32 = 0;
    var cursor = grapheme.BoundaryCursor.init(text);
    while (i < text.len) {
        const next = cursor.next(i);
        const next_advance = utf8MeasuredAdvancePrefixCx(cx_ref, text, next, char_width, font_size, font_weight);
        if (target_x <= next_advance) {
            return if (target_x - previous_advance < next_advance - target_x) i else next;
        }
        i = next;
        previous_advance = next_advance;
    }
    return text.len;
}

test "hit-test helpers never return inside an extended grapheme" {
    const text = "a👩‍💻b";
    try std.testing.expectEqual(@as(usize, 3), utf8GraphemeLen(text));
    try std.testing.expectEqual(@as(usize, 1), utf8ByteOffsetForGraphemeIndex(text, 1));
    try std.testing.expectEqual(@as(usize, 1 + "👩‍💻".len), utf8ByteOffsetForGraphemeIndex(text, 2));
    const hit = utf8ByteOffsetForEstimatedX(text, 2.0, 1.0);
    try std.testing.expect(grapheme.nextBoundary(text, grapheme.prevBoundary(text, hit)) == hit or hit == 0);
}

test "CoreText VisualLine helper uses visual rather than logical prefix order" {
    var cx = try core.Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    var fonts = try core.FontSystem.init(std.testing.allocator, @import("std").testing.io);
    defer fonts.deinit();
    cx.text.setFontSystem(&fonts);
    defer cx.text.clearFontSystem();

    const content = "abc \u{5D0}\u{5D1}\u{5D2}";
    var line = try cx.text.shapeVisualLine(.{ .text = content, .font_family = "system", .font_size = 16 });
    defer line.deinit();
    const visual_left = line.value.caret_stops[0];
    const hit = utf8ByteOffsetForMeasuredXCx(cx, content, visual_left.x.value, 8, 16, 400);
    try std.testing.expectEqual(visual_left.position.byte.value, hit);
    try std.testing.expect(grapheme.nextBoundary(content, grapheme.prevBoundary(content, hit)) == hit or hit == 0);
}

// ========== char classify ==========

/// Check if char is word separator (ASCII only fallback)
pub fn isWordSeparator(c: u8) bool {
    return switch (c) {
        ' ', '\t', '\n', '\r', '.', ',', ';', ':', '!', '?', '(', ')', '[', ']', '{', '}', '<', '>', '"', '\'', '`', '/', '\\', '|', '@', '#', '$', '%', '^', '&', '*', '-', '+', '=', '~' => true,
        else => false,
    };
}

/// Codepoint category: separator / cjk / word
pub const CpClass = enum { separator, cjk, word };

pub fn classifyCodepoint(cp: u21) CpClass {
    if (cp < 0x80) {
        return if (isWordSeparator(@intCast(cp))) .separator else .word;
    }
    if (isCJKCodepoint(cp)) return .cjk;
    return .word;
}

/// Return max prefix length in `text` not exceeding `max_bytes` and landing on a UTF-8 char
/// boundary.
///
/// Fixed buffer writes must use this, not `@min(text.len, remaining)`: the latter cuts a multibyte
/// sequence mid-char, leaving a half char in the buffer so the on_change consumer gets invalid
/// UTF-8 (e.g. pasting overlong CJK text into a single-line Input).
///
/// Invalid UTF-8 input backtracks conservatively per byte; result is always <= max_bytes.
pub fn utf8TruncateLen(text: []const u8, max_bytes: usize) usize {
    if (text.len <= max_bytes) return text.len;
    var i: usize = 0;
    while (i < text.len) {
        const n = std.unicode.utf8ByteSequenceLength(text[i]) catch 1;
        if (i + n > max_bytes) break;
        i += n;
    }
    return i;
}

test "utf8TruncateLen 不产生半个字符" {
    // ASCII: exact cut
    try std.testing.expectEqual(@as(usize, 3), utf8TruncateLen("abcdef", 3));
    // Not over limit: return as-is
    try std.testing.expectEqual(@as(usize, 6), utf8TruncateLen("abcdef", 100));
    // CJK 3 bytes per char: max=4 only fits 1 char (3 bytes), can't split half
    try std.testing.expectEqual(@as(usize, 3), utf8TruncateLen("中文字", 4));
    try std.testing.expectEqual(@as(usize, 6), utf8TruncateLen("中文字", 8));
    // emoji 4 bytes
    try std.testing.expectEqual(@as(usize, 0), utf8TruncateLen("😀", 3));
    try std.testing.expectEqual(@as(usize, 4), utf8TruncateLen("😀", 4));
    // truncate result always valid UTF-8
    const s = "abc中文😀def";
    var k: usize = 0;
    while (k <= s.len) : (k += 1) {
        const n = utf8TruncateLen(s, k);
        try std.testing.expect(n <= k);
        try std.testing.expect(std.unicode.utf8ValidateSlice(s[0..n]));
    }
}
