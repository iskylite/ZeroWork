//! Line breaking, simplified UAX #14: line-break-class based decisions (not ASCII punctuation
//! plus 'allow break after CJK' heuristics).
//!
//! Scope:
//! - codepoint -> line-break class (most common 18 classes)
//! - canBreakBetween(prev, next): minimal pair table
//! - findBreakOpportunities(text, out): all byte-position break opportunities
//!
//! Not implemented:
//! - emoji ZWJ sequence break suppression
//! - full LB rules (30+ clauses)
//! - locale-specific breaking (Thai/Lao requires ICU dictionary)
//!
//! Goal: CJK/Latin/Arabic text breaks at reasonable positions, not ASCII-only.

const std = @import("std");
const testing = std.testing;

/// line break class (UAX #14)
pub const LineBreakClass = enum(u8) {
    /// mandatory break (\n, U+2028 etc)
    bk,
    /// Carriage return
    cr,
    /// Line feed
    lf,
    /// combining mark (follows preceding character)
    cm,
    /// zero width joiner (emoji/script binding)
    zwj,
    /// Word joiner / non-breaking
    wj,
    /// glue / no-break ' ' (NBSP)
    gl,
    /// Space
    sp,
    /// break after (but can break after SP too)
    ba,
    /// Break before
    bb,
    /// Break opportunity ambiguous
    al,
    /// Numeric
    nu,
    /// Symbols allowing break before / after
    sy,
    /// CJK ideograph (default break around)
    id,
    /// Hyphen
    hy,
    /// In-separable (chains, \t)
    in,
    /// Quotation
    qu,
    /// Open punctuation (
    op,
    /// Close punctuation )
    cl,
    /// Closing parenthesis
    cp,
    /// Exclamation/interrogation ! ?
    ex,
    /// Other (unclassified)
    xx,
    /// Infix separator (. , ; :), UAX #14 IS
    is,
};

pub fn classify(cp: u32) LineBreakClass {
    if (cp < 0x80) return classify_ascii(@intCast(cp));

    // Hangul (CJK-like break)
    if (cp >= 0xAC00 and cp <= 0xD7A3) return .id;
    if (cp >= 0x3041 and cp <= 0x309F) return .id; // Hiragana
    if (cp >= 0x30A0 and cp <= 0x30FF) return .id; // Katakana
    if (cp >= 0x3400 and cp <= 0x4DBF) return .id; // CJK Ext A
    if (cp >= 0x4E00 and cp <= 0x9FFF) return .id; // CJK Unified
    if (cp >= 0xF900 and cp <= 0xFAFF) return .id; // CJK Compat
    if (cp >= 0x20000 and cp <= 0x2FFFF) return .id; // CJK Ext B-F

    // Mandatory breaks
    if (cp == 0x2028) return .bk; // LINE SEPARATOR
    if (cp == 0x2029) return .bk; // PARAGRAPH SEPARATOR

    // Common joiners / no-break
    if (cp == 0x00A0) return .gl; // NBSP
    if (cp == 0x200D) return .zwj;
    if (cp == 0x2060) return .wj;

    // Zero-width
    if (cp == 0x200B) return .ba; // ZWSP -> can break

    // Hyphens
    if (cp == 0x2010 or cp == 0x2011 or cp == 0x2012 or cp == 0x2013 or cp == 0x2014) return .hy;

    // default: breakable alphanumeric (Latin Extended, Cyrillic, Greek treated as AL)
    return .al;
}

fn classify_ascii(c: u8) LineBreakClass {
    return switch (c) {
        '\n' => .lf,
        '\r' => .cr,
        '\t' => .ba, // currently simplified to break-after; actual is BA
        ' ' => .sp,
        '0'...'9' => .nu,
        'A'...'Z', 'a'...'z' => .al,
        '-' => .hy,
        '/' => .sy,
        '(', '[', '{' => .op,
        ')', ']', '}' => .cl,
        '"', '\'' => .qu,
        '!', '?' => .ex,
        ',', '.', ';', ':' => .is,
        else => .xx,
    };
}

/// determine if character is CJK (unified CJK ideograph range, can break at any position). Single
/// source of truth: ui/core/text_layout.isCJK and text_core/wrap_map precise wrap breakpoints both
/// use this, ensuring editor WrapMap and renderer line breaks stay consistent.
pub fn isCJK(codepoint: u21) bool {
    return (codepoint >= 0x4E00 and codepoint <= 0x9FFF) or // CJK basic
        (codepoint >= 0x3400 and codepoint <= 0x4DBF) or // CJK extension A
        (codepoint >= 0x20000 and codepoint <= 0x2A6DF) or // CJK extension B
        (codepoint >= 0x2A700 and codepoint <= 0x2B73F) or // CJK extension C
        (codepoint >= 0x2B740 and codepoint <= 0x2B81F) or // CJK extension D
        (codepoint >= 0xF900 and codepoint <= 0xFAFF) or // CJK compatibility
        (codepoint >= 0x3000 and codepoint <= 0x303F) or // CJK symbols and punctuation
        (codepoint >= 0xFF00 and codepoint <= 0xFFEF); // Fullwidth characters
}

/// Minimal pair table: can break between prev and next.
/// Return true means break allowed after prev (i.e. next start is break point).
///
/// Rules (UAX #14 subset, priority-ordered):
/// 1. \n / \r / BK mandatory break
/// 2. SP after + non CL/CP/IS etc -> breakable
/// 3. WJ / GL / ZWJ / NBSP no break
/// 4. AL/NU between no break (same-kind continuity)
/// 5. ID (CJK) breaks before/after (except punctuation adjacent)
/// 6. HY breakable after
/// 7. Default: Latin AL and ID breakable between
pub fn canBreakBetween(prev: LineBreakClass, next: LineBreakClass) bool {
    // No-break around joiners
    if (prev == .wj or next == .wj) return false;
    if (prev == .gl or next == .gl) return false;
    if (prev == .zwj) return false;

    // Mandatory after BK / LF / CR
    if (prev == .bk or prev == .lf) return true;
    if (prev == .cr and next != .lf) return true;
    if (prev == .cr and next == .lf) return false;

    // SP-NEXT: usually breakable (SP after any non close-punctuation)
    if (prev == .sp) {
        if (next == .cl or next == .cp or next == .ex or next == .is) return false;
        return true;
    }

    // Don't break before break-before (that class is start-of-line, shouldn't precede)
    if (next == .cm) return false;

    // ID (CJK) breaks before/after (unless close-punctuation adjacent)
    if (prev == .id) {
        return switch (next) {
            .cl, .cp, .ex, .is, .sy, .hy => false,
            else => true,
        };
    }
    if (next == .id) {
        // Break before ID unless prev is open-punctuation
        return switch (prev) {
            .op, .qu => false,
            else => true,
        };
    }

    // Break after HY
    if (prev == .hy) return true;

    // Break after BA (break-after)
    if (prev == .ba) return true;

    // Break before BB (break-before)
    if (next == .bb) return true;

    // No break between numeric
    if (prev == .nu and next == .nu) return false;
    if (prev == .al and next == .al) return false;
    if (prev == .nu and next == .al) return false;
    if (prev == .al and next == .nu) return false;

    // Default: don't break
    return false;
}

/// Find all break opportunities in text (byte position, relative to text start).
/// Returns all 'can start new line at this byte position' positions.
pub fn findBreakOpportunities(
    text: []const u8,
    out: *std.ArrayListUnmanaged(u32),
    allocator: std.mem.Allocator,
) !void {
    var view = std.unicode.Utf8View.init(text) catch return error.InvalidUtf8;
    var iter = view.iterator();

    var prev_class: ?LineBreakClass = null;
    var byte_pos: u32 = 0;

    while (iter.nextCodepoint()) |cp| {
        const cls = classify(cp);
        const seq_len = std.unicode.utf8CodepointSequenceLength(cp) catch 1;

        if (prev_class) |pc| {
            if (canBreakBetween(pc, cls)) {
                try out.append(allocator, byte_pos);
            }
        }

        byte_pos += seq_len;
        prev_class = cls;
    }
}

// ============================================================================
// Tests
// ============================================================================

test "classify: ASCII space + letter" {
    try testing.expectEqual(LineBreakClass.sp, classify(' '));
    try testing.expectEqual(LineBreakClass.al, classify('a'));
    try testing.expectEqual(LineBreakClass.nu, classify('5'));
}

test "classify: CJK is ID" {
    try testing.expectEqual(LineBreakClass.id, classify(0x4E2D)); // Chinese character U+4E2D
    try testing.expectEqual(LineBreakClass.id, classify(0x6587)); // Chinese character U+6587
    try testing.expectEqual(LineBreakClass.id, classify(0x3042)); // あ Hiragana
}

test "classify: hyphen" {
    try testing.expectEqual(LineBreakClass.hy, classify('-'));
    try testing.expectEqual(LineBreakClass.hy, classify(0x2010));
}

test "classify: NBSP is GL (no-break)" {
    try testing.expectEqual(LineBreakClass.gl, classify(0x00A0));
}

test "canBreakBetween: SP + AL = break" {
    try testing.expect(canBreakBetween(.sp, .al));
}

test "canBreakBetween: AL + AL = no break" {
    try testing.expect(!canBreakBetween(.al, .al));
}

test "canBreakBetween: NBSP doesn't allow break" {
    try testing.expect(!canBreakBetween(.gl, .al));
    try testing.expect(!canBreakBetween(.al, .gl));
}

test "canBreakBetween: ID surrounded by AL allows break" {
    try testing.expect(canBreakBetween(.id, .al));
    try testing.expect(canBreakBetween(.al, .id));
    try testing.expect(canBreakBetween(.id, .id));
}

test "canBreakBetween: ID + close punctuation = no break" {
    try testing.expect(!canBreakBetween(.id, .cl));
    try testing.expect(!canBreakBetween(.id, .ex));
}

test "canBreakBetween: HY allows break after" {
    try testing.expect(canBreakBetween(.hy, .al));
}

test "findBreakOpportunities: simple ASCII spaces" {
    var out: std.ArrayListUnmanaged(u32) = .empty;
    defer out.deinit(testing.allocator);

    try findBreakOpportunities("hello world foo", &out, testing.allocator);
    // Expect break after 'hello ' (byte 6) and after 'world ' (byte 12)
    try testing.expect(out.items.len >= 2);
    try testing.expectEqual(@as(u32, 6), out.items[0]);
    try testing.expectEqual(@as(u32, 12), out.items[1]);
}

test "findBreakOpportunities: CJK every char is breakable" {
    var out: std.ArrayListUnmanaged(u32) = .empty;
    defer out.deinit(testing.allocator);

    // 'Chinese text' = 6 bytes (UTF-8 each 3 bytes)
    try findBreakOpportunities("\xE4\xB8\xAD\xE6\x96\x87", &out, testing.allocator);
    // Break between Chinese and Chinese should exist
    try testing.expect(out.items.len >= 1);
    try testing.expectEqual(@as(u32, 3), out.items[0]);
}

test "findBreakOpportunities: NBSP suppresses break" {
    var out: std.ArrayListUnmanaged(u32) = .empty;
    defer out.deinit(testing.allocator);

    // 'a' + NBSP + 'b', NBSP is 0xC2 0xA0
    try findBreakOpportunities("a\xC2\xA0b", &out, testing.allocator);
    try testing.expectEqual(@as(usize, 0), out.items.len);
}
