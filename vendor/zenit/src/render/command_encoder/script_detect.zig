//! Text script detection / ASCII classification: pure functions decoupled from encoder state.
//!
//! This cluster **sees bytes only, not the encoder**: params are `[]const u8` + scalars, returns
//! bool/f32, no self, no allocation, no side effects. Common question: 'which writing system is
//! this text / can we take the fixed-width ASCII fast path', used by the encoder's font fallback
//! selection (selectCjkFallbackFont) and fixed-width advance (fixedMonospaceAdvance).
//!
//! Division with font_selector.zig: that picks the **font tier** (returns a Font handle); this only
//! does **script detection** (pure predicate). font_selector's own isAllAscii is an inline hot-path
//! private copy; the two are deliberately independent.
//!
//! command_encoder.zig re-exports the same names.

const std = @import("std");

/// entire segment is ASCII (no 0x80+ bytes). Precondition for fixed-width fast path.
pub fn isAllAscii(content: []const u8) bool {
    for (content) |b| {
        if (b >= 0x80) return false;
    }
    return true;
}

/// fixed advance per char under monospace font; return 0 if inapplicable.
///
/// Monospace long-line path measurement, scroll, hit, selection all use same fixed ASCII cell,
/// rendering must use same width or accumulate glyph-advance drift under large horizontal offset.
pub fn fixedMonospaceAdvance(content: []const u8, use_monospace_font: bool, monospace_char_width: f32) f32 {
    // Explicit grid advances are independent of selecting the global mono face.
    _ = use_monospace_font;
    if (monospace_char_width <= 0) return 0;
    return if (isAllAscii(content)) monospace_char_width else 0;
}

/// Korean preferred fallback: contains Hangul and no Han/Kana.
///
/// Mixed (Korean + Han/Kanji) doesn't take Korean tier, Korean font Han glyphs differ from
/// Han/Kanji typography.
pub fn preferKoreanFallback(text: []const u8) bool {
    return containsHangul(text) and !containsHanOrKana(text);
}

/// CJK fallback: contains Han or Kana.
pub fn preferCjkFallback(text: []const u8) bool {
    return containsHanOrKana(text);
}

/// Per-codepoint scan common skeleton: invalid UTF-8 bytes skip not error (render path can't fail
/// on one bad byte), truncated tail sequence stops immediately.
fn anyCodepoint(text: []const u8, comptime pred: fn (u21) bool) bool {
    var i: usize = 0;
    while (i < text.len) {
        if (text[i] < 0x80) {
            if (pred(text[i])) return true;
            i += 1;
            continue;
        }
        const seq_len = std.unicode.utf8ByteSequenceLength(text[i]) catch {
            i += 1;
            continue;
        };
        if (i + seq_len > text.len) break;
        const cp = std.unicode.utf8Decode(text[i .. i + seq_len]) catch {
            i += seq_len;
            continue;
        };
        if (pred(cp)) return true;
        i += seq_len;
    }
    return false;
}

fn isHangulCodepoint(cp: u21) bool {
    return (cp >= 0x1100 and cp <= 0x11FF) or // Hangul Jamo
        (cp >= 0x3130 and cp <= 0x318F) or // Hangul Compatibility Jamo
        (cp >= 0xAC00 and cp <= 0xD7AF); // Hangul Syllables
}

fn isHanOrKanaCodepoint(cp: u21) bool {
    return (cp >= 0x3000 and cp <= 0x303F) or // CJK Symbols and Punctuation
        (cp >= 0x3040 and cp <= 0x309F) or // Hiragana
        (cp >= 0x30A0 and cp <= 0x30FF) or // Katakana
        (cp >= 0x3400 and cp <= 0x4DBF) or // CJK Ext A
        (cp >= 0x4E00 and cp <= 0x9FFF) or // CJK Unified Ideographs
        (cp >= 0xF900 and cp <= 0xFAFF); // CJK Compatibility Ideographs
}

pub fn containsHangul(text: []const u8) bool {
    return anyCodepoint(text, isHangulCodepoint);
}

pub fn containsHanOrKana(text: []const u8) bool {
    return anyCodepoint(text, isHanOrKanaCodepoint);
}
