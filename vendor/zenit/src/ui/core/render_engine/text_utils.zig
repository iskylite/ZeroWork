/// Text render utility functions: UTF-8 handling, char width, monospace fast path
/// detect. Stateless pure functions, no NodeExecutionState or render context.
const std = @import("std");

const text_layout = @import("../text_layout.zig");
const layout_engine = @import("../layout_engine.zig");
const render_context_mod = @import("render_context.zig");

pub inline fn measureSegmentWidth(text: []const u8, font_size: f32, font_weight: u16, use_italic: bool, use_monospace: bool) f32 {
    return text_layout.measureTextWidthByFontKind(text, font_size, font_weight, use_italic, use_monospace);
}

/// cx-aware variant: uses RenderContext.shaping_cache (GlyphRun pipeline) instead of the
/// direct platform bridge measureTextWidthByFontKind. The authoritative width-as-drawn
/// callback is independent of shaping_cache / font_system; only the compat shaper needs them
/// when the host lacks the callback. Falls back to platform measure when both paths are
/// unavailable.
pub fn measureSegmentWidthCtx(
    cx: *render_context_mod.RenderContext,
    text: []const u8,
    font_size: f32,
    font_weight: u16,
    use_italic: bool,
    use_monospace: bool,
    font_family: u16,
    use_symbols: bool,
    monospace_char_width: f32,
) f32 {
    if (text.len == 0) return 0;
    if (cx.measure_font_fn) |measure| {
        if (cx.measure_font_context) |ctx| {
            if (measure(ctx, text, font_size, font_weight, use_italic, use_monospace, font_family, use_symbols, monospace_char_width)) |width| return width;
        }
    }
    return layout_engine.shapeViaPipeline(
        cx.shaping_cache,
        cx.font_system,
        text,
        font_size,
        font_weight,
        use_italic,
        use_monospace,
        font_family,
        use_symbols,
        monospace_char_width,
    ) orelse measureSegmentWidth(text, font_size, font_weight, use_italic, use_monospace);
}

pub fn nextUtf8Boundary(text: []const u8, pos: usize) usize {
    if (pos >= text.len) return text.len;
    const char_len = std.unicode.utf8ByteSequenceLength(text[pos]) catch 1;
    return @min(text.len, pos + char_len);
}

/// Calculate display pixel width of UTF-8 text (monospace: ASCII=1cw,
/// CJK/fullwidth=2cw)
pub fn utf8DisplayWidth(text: []const u8, char_width: f32) f32 {
    var width: f32 = 0;
    var i: usize = 0;
    while (i < text.len) {
        const byte = text[i];
        if (byte < 0x80) {
            width += char_width;
            i += 1;
        } else {
            const cp_len = std.unicode.utf8ByteSequenceLength(byte) catch {
                width += char_width;
                i += 1;
                continue;
            };
            if (i + cp_len > text.len) break;
            const cp = std.unicode.utf8Decode(text[i..][0..cp_len]) catch {
                width += char_width;
                i += cp_len;
                continue;
            };
            width += if (isWideChar(cp)) char_width * 2 else char_width;
            i += cp_len;
        }
    }
    return width;
}

/// Check if fullwidth/CJK char (occupies 2 monospace char widths)
pub fn isWideChar(cp: u21) bool {
    if (cp >= 0x4E00 and cp <= 0x9FFF) return true; // CJK Unified Ideographs
    if (cp >= 0x3400 and cp <= 0x4DBF) return true; // CJK Extension A
    if (cp >= 0x20000 and cp <= 0x2A6DF) return true; // CJK Extension B+
    if (cp >= 0xF900 and cp <= 0xFAFF) return true; // CJK Compatibility Ideographs
    if (cp >= 0xFF01 and cp <= 0xFF60) return true; // Fullwidth forms
    if (cp >= 0xFFE0 and cp <= 0xFFE6) return true;
    if (cp >= 0xAC00 and cp <= 0xD7AF) return true; // Hangul Syllables
    if (cp >= 0x3000 and cp <= 0x303F) return true; // CJK Symbols and Punctuation
    if (cp >= 0x3040 and cp <= 0x30FF) return true; // Hiragana + Katakana
    if (cp >= 0x3100 and cp <= 0x312F) return true; // Bopomofo
    if (cp >= 0x3200 and cp <= 0x32FF) return true; // Enclosed CJK
    if (cp >= 0x3300 and cp <= 0x33FF) return true; // CJK Compatibility
    return false;
}
