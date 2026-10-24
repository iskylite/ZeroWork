/// DocCursor - generic document cursor
///
/// Byte-offset cursor system with selection and line-col mapping support.
///
/// Generic parameter Doc: any type providing these APIs:
///   totalLength() -> usize
///   offsetToLineCol(offset) -> LineCol
///   lineColToOffset(line, col) -> usize
///   lineCount() -> usize
///   getLineStart(line) -> usize
///   getLineEnd(line) -> usize
///   getByteAt(offset) -> ?u8
///   deleteRange(start, len) -> !void   (only mutation operation)
/// Line-column coordinates
pub const LineCol = struct {
    line: usize,
    col: usize,
};

const grapheme = @import("grapheme.zig");

/// DocCursor - generic document cursor
/// Doc: any type providing
/// totalLength/offsetToLineCol/lineColToOffset/lineCount/getLineStart/getLineEnd/getByteAt/deleteRange
pub fn DocCursor(comptime Doc: type) type {
    return struct {
        const Self = @This();

        /// Byte offset
        offset: usize = 0,
        /// Selection anchor (non-null when selection exists)
        anchor: ?usize = null,
        /// Target column preserved during up/down movement
        preferred_col: ?usize = null,

        pub fn selection(self: *const Self) ?struct { start: usize, end: usize } {
            const a = self.anchor orelse return null;
            if (a == self.offset) return null;
            return .{
                .start = @min(a, self.offset),
                .end = @max(a, self.offset),
            };
        }

        pub fn hasSelection(self: *const Self) bool {
            if (self.anchor) |a| return a != self.offset;
            return false;
        }

        pub fn moveTo(self: *Self, offset: usize) void {
            self.offset = offset;
            self.anchor = null;
            self.preferred_col = null;
        }

        pub fn selectTo(self: *Self, offset: usize) void {
            if (self.anchor == null) {
                self.anchor = self.offset;
            }
            self.offset = offset;
        }

        pub fn clearSelection(self: *Self) void {
            self.anchor = null;
        }

        pub fn selectAll(self: *Self, doc: *const Doc) void {
            self.anchor = 0;
            self.offset = doc.totalLength();
        }

        pub fn deleteSelection(self: *Self, doc: *Doc) !?usize {
            const sel = self.selection() orelse return null;
            try doc.deleteRange(sel.start, sel.end - sel.start);
            self.offset = sel.start;
            self.anchor = null;
            return sel.start;
        }

        // ===== Navigation =====

        pub fn moveLeft(self: *Self, doc: *const Doc, shift: bool) void {
            if (!shift and self.hasSelection()) {
                self.moveTo(self.selection().?.start);
                return;
            }
            if (self.offset == 0) return;
            const new_off = prevCharBoundary(doc, self.offset);
            if (shift) self.selectTo(new_off) else self.moveTo(new_off);
        }

        pub fn moveRight(self: *Self, doc: *const Doc, shift: bool) void {
            if (!shift and self.hasSelection()) {
                self.moveTo(self.selection().?.end);
                return;
            }
            if (self.offset >= doc.totalLength()) return;
            const new_off = nextCharBoundary(doc, self.offset);
            if (shift) self.selectTo(new_off) else self.moveTo(new_off);
        }

        pub fn moveUp(self: *Self, doc: *const Doc, shift: bool) void {
            const lc = doc.offsetToLineCol(self.offset);
            if (lc.line == 0) {
                if (shift) self.selectTo(0) else self.moveTo(0);
                return;
            }
            const target_col = self.preferred_col orelse lc.col;
            const new_off = floorCharBoundary(doc, doc.lineColToOffset(lc.line - 1, target_col));
            if (shift) self.selectTo(new_off) else {
                self.offset = new_off;
                self.anchor = null;
            }
            self.preferred_col = target_col;
        }

        pub fn moveDown(self: *Self, doc: *const Doc, shift: bool) void {
            const lc = doc.offsetToLineCol(self.offset);
            if (lc.line + 1 >= doc.lineCount()) {
                const end = doc.totalLength();
                if (shift) self.selectTo(end) else self.moveTo(end);
                return;
            }
            const target_col = self.preferred_col orelse lc.col;
            const new_off = floorCharBoundary(doc, doc.lineColToOffset(lc.line + 1, target_col));
            if (shift) self.selectTo(new_off) else {
                self.offset = new_off;
                self.anchor = null;
            }
            self.preferred_col = target_col;
        }

        pub fn moveToLineStart(self: *Self, doc: *const Doc, shift: bool) void {
            const lc = doc.offsetToLineCol(self.offset);
            const target = doc.getLineStart(lc.line);
            if (shift) self.selectTo(target) else self.moveTo(target);
        }

        pub fn moveToLineEnd(self: *Self, doc: *const Doc, shift: bool) void {
            const lc = doc.offsetToLineCol(self.offset);
            const target = doc.getLineEnd(lc.line);
            if (shift) self.selectTo(target) else self.moveTo(target);
        }

        // ===== Word navigation =====

        pub fn moveWordLeft(self: *Self, doc: *const Doc, shift: bool) void {
            if (!shift and self.hasSelection()) {
                self.moveTo(self.selection().?.start);
                return;
            }
            const new_off = prevWordBoundary(doc, self.offset);
            if (shift) self.selectTo(new_off) else self.moveTo(new_off);
        }

        pub fn moveWordRight(self: *Self, doc: *const Doc, shift: bool) void {
            if (!shift and self.hasSelection()) {
                self.moveTo(self.selection().?.end);
                return;
            }
            const new_off = nextWordBoundary(doc, self.offset);
            if (shift) self.selectTo(new_off) else self.moveTo(new_off);
        }

        /// Return {start, end} range of word containing offset (for double-click select)
        /// CJK characters each form individual words; ASCII word chars form continuous words
        pub fn wordBoundsAt(doc: *const Doc, offset: usize) struct { start: usize, end: usize } {
            const total = doc.totalLength();
            if (total == 0) return .{ .start = 0, .end = 0 };

            // `offset` is normally a cursor/grapheme boundary, but pointer
            // hit-testing and callers at EOF can hand us any byte offset. Probe
            // through the byte under the pointer and walk back to the containing
            // grapheme start. In particular, `total - 1` is a UTF-8 continuation
            // byte when the document ends in CJK/emoji.
            const probe_end = if (offset < total) offset + 1 else total;
            const cur_off = prevCharBoundary(doc, probe_end);
            const b = doc.getByteAt(cur_off) orelse return .{ .start = offset, .end = offset };

            // Ideographic/emoji (3/4-byte lead): each grapheme is separate word.
            // Use grapheme boundary not manual char_len: ZWJ families / flags are multi-codepoint
            // clusters.
            if (b >= 0xE0) {
                return .{ .start = cur_off, .end = nextCharBoundary(doc, cur_off) };
            }

            if (b < 0x80 and isWordSeparator(b)) {
                // On delimiter: select consecutive delimiters
                var start = cur_off;
                while (start > 0) {
                    const pb = doc.getByteAt(start - 1) orelse break;
                    if (!isWordSeparator(pb)) break;
                    start -= 1;
                }
                var end = cur_off;
                while (end < total) {
                    const nb = doc.getByteAt(end) orelse break;
                    if (!isWordSeparator(nb)) break;
                    end += 1;
                }
                return .{ .start = start, .end = end };
            }

            // Word characters (ASCII word chars + 2-byte scripts like Greek/Cyrillic/Latin
            // Extended):
            // expand both directions, stop at ASCII delimiter or ideographic (>= 0xE0 lead).
            // Historical bug: previously used `pb >= 0x80` cutoff, double-click on 2-byte chars
            // selected empty.
            var start = cur_off;
            while (start > 0) {
                const pb = doc.getByteAt(start - 1) orelse break;
                if (pb < 0x80) {
                    if (isWordSeparator(pb)) break;
                    start -= 1;
                } else {
                    const q = prevCharBoundary(doc, start);
                    const lead = doc.getByteAt(q) orelse break;
                    if (lead >= 0xE0) break;
                    start = q;
                }
            }
            var end = cur_off;
            while (end < total) {
                const nb = doc.getByteAt(end) orelse break;
                if (nb < 0x80 and isWordSeparator(nb)) break;
                if (nb >= 0xE0) break;
                end += 1;
            }
            return .{ .start = start, .end = end };
        }

        /// Find previous word boundary (skip delimiters then word chars)
        /// Each CJK character is an independent boundary
        pub fn prevWordBoundary(doc: *const Doc, offset: usize) usize {
            if (offset == 0) return 0;
            var p = offset;
            // Skip whitespace/delimiters to the left
            while (p > 0) {
                const b = doc.getByteAt(p - 1) orelse break;
                if (!isWordSeparator(b)) break;
                p -= 1;
            }
            if (p == 0) return 0;
            // If previous char is ideographic/emoji (>= 0xE0 lead): single cluster is word, retreat
            // one grapheme
            {
                const q = prevCharBoundary(doc, p);
                const lead = doc.getByteAt(q) orelse return q;
                if (lead >= 0xE0) return q;
            }
            // Word characters (ASCII word chars + 2-byte scripts like Greek/Cyrillic/Latin
            // Extended): retreat continuously,
            // stop at ASCII delimiter or ideographic.
            // Historical bug: 2-byte chars only retreat one char not whole word (asymmetric with
            // nextWordBoundary).
            while (p > 0) {
                const b = doc.getByteAt(p - 1) orelse break;
                if (b < 0x80) {
                    if (isWordSeparator(b)) break;
                    p -= 1;
                } else {
                    const q = prevCharBoundary(doc, p);
                    const lead = doc.getByteAt(q) orelse break;
                    if (lead >= 0xE0) break;
                    p = q;
                }
            }
            return p;
        }

        /// Find next word boundary (skip word chars then delimiters)
        /// Each CJK character is an independent boundary
        pub fn nextWordBoundary(doc: *const Doc, offset: usize) usize {
            const total = doc.totalLength();
            if (offset >= total) return total;
            var p = offset;
            const first = doc.getByteAt(p) orelse return p;
            if (first >= 0xE0) {
                // Ideographic/emoji: skip one complete grapheme (ZWJ families / flags are
                // multi-codepoint clusters, manual char_len lands mid-cluster), then skip
                // delimiters
                p = nextCharBoundary(doc, p);
            } else if (first >= 0x80 or !isWordSeparator(first)) {
                // Word characters (ASCII word chars + 2-byte scripts like Greek/Cyrillic/Latin
                // Extended):
                // skip continuously, stop at an ASCII delimiter or ideographic char.
                // Do not cut off at `b >= 0x80`: on 2-byte chars the cursor would not move
                // (Alt+Right).
                // A continuation byte (0x80-0xBF) in this scan domain can only belong to a 2-byte
                // char;
                // an ideographic lead stops before it.
                while (p < total) {
                    const b = doc.getByteAt(p) orelse break;
                    if (b < 0x80 and isWordSeparator(b)) break;
                    if (b >= 0xE0) break;
                    p += 1;
                }
            }
            // Skip whitespace/delimiters to the right
            while (p < total) {
                const b = doc.getByteAt(p) orelse break;
                if (!isWordSeparator(b)) break;
                p += 1;
            }
            return @min(p, total);
        }

        pub fn isWordSeparator(c: u8) bool {
            return switch (c) {
                ' ', '\t', '\n', '\r', '.', ',', ';', ':', '!', '?', '(', ')', '[', ']', '{', '}', '<', '>', '"', '\'', '`', '/', '\\', '|', '@', '#', '$', '%', '^', '&', '*', '-', '+', '=', '~' => true,
                else => false,
            };
        }

        /// Test if ASCII byte is 'word-internal character' (letter/digit/underscore).
        /// Complement to isWordSeparator (for ASCII).
        pub fn isWordChar(c: u8) bool {
            return (c >= 'a' and c <= 'z') or
                (c >= 'A' and c <= 'Z') or
                (c >= '0' and c <= '9') or
                c == '_';
        }

        // ===== Subword navigation =====
        //
        // Subword breaks words further by camelCase/snake_case/letter<->digit.
        // Example: "getUserName_v2" -> ["get", "User", "Name", "_", "v", "2"]
        //
        // Boundary rules (adjacent bytes p, c):
        //   1. Original word boundaries are still subword boundaries (isWordSeparator splits)
        //   2. lower->Upper / Upper->lower (`aB` -> `a|B`; `AB`+`a` -> `AB|a` needs lookahead)
        //   3. letter <-> digit (`v2` -> `v|2`)
        //   4. char <-> `_` or `-`
        //
        // Multi-byte chars: each char is its own subword boundary (like CJK).

        fn byteClass(c: u8) enum { lower, upper, digit, underscore, dash, other } {
            if (c >= 'a' and c <= 'z') return .lower;
            if (c >= 'A' and c <= 'Z') return .upper;
            if (c >= '0' and c <= '9') return .digit;
            if (c == '_') return .underscore;
            if (c == '-') return .dash;
            return .other;
        }

        /// Test if subword boundary exists between p -> c (within word).
        /// Requires p and c both ASCII word chars (caller filters delimiters).
        fn isSubwordBoundaryAscii(p: u8, c: u8) bool {
            const pc = byteClass(p);
            const cc = byteClass(c);
            if (pc == cc) return false;
            // lower -> Upper (camelCase boundary)
            if (pc == .lower and cc == .upper) return true;
            // letter ↔ digit
            const p_is_letter = pc == .lower or pc == .upper;
            const c_is_letter = cc == .lower or cc == .upper;
            if (p_is_letter and cc == .digit) return true;
            if (pc == .digit and c_is_letter) return true;
            // any char <-> _ or -
            if (pc == .underscore or pc == .dash or cc == .underscore or cc == .dash) return true;
            return false;
        }

        /// Find previous subword boundary; return nearest boundary <= offset.
        pub fn prevSubwordBoundary(doc: *const Doc, offset: usize) usize {
            if (offset == 0) return 0;
            var p = offset;

            // Skip whitespace/delimiters to left (consistent with prevWordBoundary)
            while (p > 0) {
                const b = doc.getByteAt(p - 1) orelse break;
                if (!isWordSeparator(b)) break;
                p -= 1;
            }
            if (p == 0) return 0;

            // If previous byte is multi-byte (>=0x80), retreat one complete UTF-8 char = one
            // subword
            const prev_b = doc.getByteAt(p - 1) orelse return p;
            if (prev_b >= 0x80) {
                return prevCharBoundary(doc, p);
            }

            // ASCII path: scan left to subword or word boundary
            // First step: retreat at least one byte
            p -= 1;
            while (p > 0) {
                const cur = doc.getByteAt(p) orelse break;
                const prev = doc.getByteAt(p - 1) orelse break;
                if (isWordSeparator(prev) or prev >= 0x80) break;
                if (isSubwordBoundaryAscii(prev, cur)) break;
                p -= 1;
            }
            return p;
        }

        /// Find next subword boundary; return nearest boundary >= offset.
        pub fn nextSubwordBoundary(doc: *const Doc, offset: usize) usize {
            const total = doc.totalLength();
            if (offset >= total) return total;
            var p = offset;

            const first = doc.getByteAt(p) orelse return p;

            // Multi-byte char: skip one complete char = one subword.
            // Historical bug: only checked >= 0xE0, 2-byte chars fell into ASCII path p += 1,
            // stopped mid-char.
            if (first >= 0x80) {
                p = nextCharBoundary(doc, p);
                // Skip right-side delimiters to match word version
                while (p < total) {
                    const b = doc.getByteAt(p) orelse break;
                    if (!isWordSeparator(b)) break;
                    p += 1;
                }
                return p;
            }

            // ASCII delimiters: first skip all delimiters (preprocessing consistent with
            // nextWordBoundary)
            if (isWordSeparator(first)) {
                while (p < total) {
                    const b = doc.getByteAt(p) orelse break;
                    if (!isWordSeparator(b)) break;
                    p += 1;
                }
                return p;
            }

            // Within word: scan to next subword boundary
            p += 1;
            while (p < total) {
                const cur = doc.getByteAt(p) orelse break;
                const prev = doc.getByteAt(p - 1) orelse break;
                if (isWordSeparator(cur) or cur >= 0x80) break;
                if (isSubwordBoundaryAscii(prev, cur)) break;
                p += 1;
            }
            while (p < total) {
                const b = doc.getByteAt(p) orelse break;
                if (!isWordSeparator(b)) break;
                p += 1;
            }
            return p;
        }

        pub fn moveSubwordLeft(self: *Self, doc: *const Doc, shift: bool) void {
            if (!shift and self.hasSelection()) {
                self.moveTo(self.selection().?.start);
                return;
            }
            const new_off = prevSubwordBoundary(doc, self.offset);
            if (shift) self.selectTo(new_off) else self.moveTo(new_off);
        }

        pub fn moveSubwordRight(self: *Self, doc: *const Doc, shift: bool) void {
            if (!shift and self.hasSelection()) {
                self.moveTo(self.selection().?.end);
                return;
            }
            const new_off = nextSubwordBoundary(doc, self.offset);
            if (shift) self.selectTo(new_off) else self.moveTo(new_off);
        }

        // ===== Paragraph navigation =====
        //
        // Paragraph = text block separated by blank lines. Blank line = no content or only
        // whitespace.
        //
        // moveToPrevParagraph: jump to the start of the current paragraph; if already there, to the
        // start of the previous one.
        // moveToNextParagraph: jump to the blank line after the current paragraph (or document
        // end).

        fn isBlankLine(doc: *const Doc, line: usize) bool {
            const start = doc.getLineStart(line);
            const end = doc.getLineEnd(line);
            var p = start;
            while (p < end) : (p += 1) {
                const b = doc.getByteAt(p) orelse return true;
                if (b != ' ' and b != '\t') return false;
            }
            return true;
        }

        pub fn moveToPrevParagraph(self: *Self, doc: *const Doc, shift: bool) void {
            const lc = doc.offsetToLineCol(self.offset);
            var line = lc.line;

            // If not at line start or blank, try continuing up from current line.
            // Rule: find first blank line up (skip current non-blank lines), continue skipping
            // blank lines above (gap between paragraphs), stop at col 0 of 'non-blank paragraph
            // start line'.

            // Step 1: if current line is not blank, skip current paragraph first (up to blank or
            // doc start)
            if (!isBlankLine(doc, line)) {
                while (line > 0 and !isBlankLine(doc, line - 1)) : (line -= 1) {}
                // line stops at paragraph start
            } else {
                // Current is blank -> skip consecutive blank lines
                while (line > 0 and isBlankLine(doc, line - 1)) : (line -= 1) {}
                // then skip previous paragraph
                while (line > 0 and !isBlankLine(doc, line - 1)) : (line -= 1) {}
            }

            const target = doc.getLineStart(line);
            // If didn't move (already at paragraph start with cursor at line start) -> try next up
            if (target == self.offset and line > 0) {
                var l2 = line - 1;
                while (l2 > 0 and isBlankLine(doc, l2)) : (l2 -= 1) {}
                while (l2 > 0 and !isBlankLine(doc, l2 - 1)) : (l2 -= 1) {}
                const t2 = doc.getLineStart(l2);
                if (shift) self.selectTo(t2) else self.moveTo(t2);
                return;
            }

            if (shift) self.selectTo(target) else self.moveTo(target);
        }

        pub fn moveToNextParagraph(self: *Self, doc: *const Doc, shift: bool) void {
            const lc = doc.offsetToLineCol(self.offset);
            const total_lines = doc.lineCount();
            var line = lc.line;

            // Current is non-blank: skip current paragraph to first blank line
            if (!isBlankLine(doc, line)) {
                while (line + 1 < total_lines and !isBlankLine(doc, line + 1)) : (line += 1) {}
                // Land at paragraph end; target = start of next line (blank line)
                line += 1;
            } else {
                // Current is blank: skip consecutive blank lines then next paragraph
                while (line + 1 < total_lines and isBlankLine(doc, line + 1)) : (line += 1) {}
                while (line + 1 < total_lines and !isBlankLine(doc, line + 1)) : (line += 1) {}
                line += 1;
            }

            const target = if (line >= total_lines) doc.totalLength() else doc.getLineStart(line);
            if (shift) self.selectTo(target) else self.moveTo(target);
        }

        // ===== UTF-8 character boundaries =====

        /// Keep an existing grapheme boundary, or floor an interior byte offset
        /// to the containing cluster's start. Retains byte-column navigation.
        pub fn floorCharBoundary(doc: *const Doc, offset: usize) usize {
            if (offset >= doc.totalLength()) return doc.totalLength();
            // prevBoundary is exclusive. Probing one byte later includes offset
            // itself, and its decoder first backs up to a codepoint start.
            return prevCharBoundary(doc, offset + 1);
        }

        /// Find start of previous grapheme cluster (UAX #29 extended grapheme cluster).
        /// Cannot retreat by codepoint: family emoji / combining marks / flags / skin-tone
        /// modifiers are multi-codepoint; retreating by codepoint splits them into fragments.
        pub fn prevCharBoundary(doc: *const Doc, offset: usize) usize {
            if (offset == 0) return 0;
            return grapheme.prevBoundaryDoc(Doc, doc, offset);
        }

        /// Find start of next grapheme cluster
        pub fn nextCharBoundary(doc: *const Doc, offset: usize) usize {
            const total = doc.totalLength();
            if (offset >= total) return total;
            return grapheme.nextBoundaryDoc(Doc, doc, offset);
        }
    };
}

// ===== Multi-line Doc grapheme boundary regression tests =====

const std_t = @import("std");

/// Minimal Doc implementing only methods needed for prev/nextCharBoundary
const StubDoc = struct {
    bytes: []const u8,
    pub fn totalLength(self: *const StubDoc) usize {
        return self.bytes.len;
    }
    pub fn getByteAt(self: *const StubDoc, offset: usize) ?u8 {
        if (offset >= self.bytes.len) return null;
        return self.bytes[offset];
    }
};

test "DocCursor 边界按 grapheme cluster 而非 codepoint" {
    const C = DocCursor(StubDoc);
    const family = "\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}\u{200D}\u{1F466}";
    const doc = StubDoc{ .bytes = "a" ++ family ++ "\u{1F1E8}\u{1F1F3}" };

    try std_t.testing.expectEqual(@as(usize, 1), C.nextCharBoundary(&doc, 0));
    try std_t.testing.expectEqual(@as(usize, 1 + family.len), C.nextCharBoundary(&doc, 1));
    try std_t.testing.expectEqual(@as(usize, doc.bytes.len), C.nextCharBoundary(&doc, 1 + family.len));

    // Flag pairs retreat intact
    try std_t.testing.expectEqual(@as(usize, 1 + family.len), C.prevCharBoundary(&doc, doc.bytes.len));
    // Family emoji retreat intact
    try std_t.testing.expectEqual(@as(usize, 1), C.prevCharBoundary(&doc, 1 + family.len));
}

test "DocCursor 组合记号与肤色修饰符不被拆开" {
    const C = DocCursor(StubDoc);
    const doc = StubDoc{ .bytes = "e\u{0301}\u{1F44D}\u{1F3FB}" };
    try std_t.testing.expectEqual(@as(usize, 3), C.nextCharBoundary(&doc, 0));
    try std_t.testing.expectEqual(@as(usize, 3), C.prevCharBoundary(&doc, doc.bytes.len));
    try std_t.testing.expectEqual(@as(usize, 0), C.prevCharBoundary(&doc, 3));
}

// ===== 2-byte scripts (Greek/Cyrillic/Latin Extended) word navigation =====
//
// nextWordBoundary/wordBoundsAt must treat 2-byte leads (0xC2-0xDF) as multi-byte, not only
// >= 0xE0 (3/4-byte). Otherwise they fall into the ASCII word path and break at once on
// `b >= 0x80`: cursor unmoved (Alt+Right) and double-click selects an empty range.

test "DocCursor 词导航：希腊/西里尔词按整词跳，不原地卡住" {
    const C = DocCursor(StubDoc);
    const greek = "λόγος"; // Each char 2 bytes
    const cyr = "слово";
    const doc = StubDoc{ .bytes = greek ++ " " ++ cyr ++ " test" };

    // Alt+Right: whole word + trailing delimiters
    try std_t.testing.expectEqual(@as(usize, greek.len + 1), C.nextWordBoundary(&doc, 0));
    try std_t.testing.expectEqual(
        @as(usize, greek.len + 1 + cyr.len + 1),
        C.nextWordBoundary(&doc, greek.len + 1),
    );

    // Alt+Left: from word end back to word start
    try std_t.testing.expectEqual(@as(usize, 0), C.prevWordBoundary(&doc, greek.len));
    // From "test" word start retreat: skip space, land at Cyrillic word start
    try std_t.testing.expectEqual(
        @as(usize, greek.len + 1),
        C.prevWordBoundary(&doc, greek.len + 1 + cyr.len + 1),
    );

    // Double-click select word: select entire non-empty word
    const bounds = C.wordBoundsAt(&doc, 2);
    try std_t.testing.expectEqual(@as(usize, 0), bounds.start);
    try std_t.testing.expectEqual(@as(usize, greek.len), bounds.end);
}

test "DocCursor 词导航：ASCII 与 2 字节字符混排聚成一个词，CJK 仍单字成词" {
    const C = DocCursor(StubDoc);
    // "naive CJKx": naive is ASCII+2byte mixed word; each separate; x independent
    const doc = StubDoc{ .bytes = "naïve 中文x" };
    const naive_len = "naïve".len; // 6

    try std_t.testing.expectEqual(@as(usize, naive_len + 1), C.nextWordBoundary(&doc, 0));
    // CJK: single char per hop
    try std_t.testing.expectEqual(@as(usize, naive_len + 1 + 3), C.nextWordBoundary(&doc, naive_len + 1));
    try std_t.testing.expectEqual(@as(usize, 0), C.prevWordBoundary(&doc, naive_len));

    const bounds = C.wordBoundsAt(&doc, 1);
    try std_t.testing.expectEqual(@as(usize, 0), bounds.start);
    try std_t.testing.expectEqual(@as(usize, naive_len), bounds.end);
}

test "DocCursor subword 导航：2 字节字符不落在字符中间" {
    const C = DocCursor(StubDoc);
    const doc = StubDoc{ .bytes = "λω x" };
    // Old impl: p += 1 landed on λ's continuation byte
    const n1 = C.nextSubwordBoundary(&doc, 0);
    try std_t.testing.expect(n1 == 2 or n1 == 4 or n1 == 5); // Any valid char boundary
    try std_t.testing.expect(n1 != 1 and n1 != 3); // Not mid-character
    try std_t.testing.expect(n1 > 0); // Not unmoved
}

test "DocCursor 词导航：ZWJ 家庭 emoji 整簇一跳" {
    const C = DocCursor(StubDoc);
    const family = "\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}\u{200D}\u{1F466}";
    const doc = StubDoc{ .bytes = family ++ "ab" };
    // Old impl manual char_len=4 skipped one codepoint, landed mid-ZWJ sequence
    try std_t.testing.expectEqual(@as(usize, family.len), C.nextWordBoundary(&doc, 0));
}

test "DocCursor 双击文末 CJK/emoji 始终返回完整 UTF-8 边界" {
    const C = DocCursor(StubDoc);
    const cjk = "你";
    const thumbs = "\u{1F44D}";
    const doc = StubDoc{ .bytes = "a" ++ cjk ++ thumbs };

    // Hits on CJK continuation bytes also normalize to char start.
    const cjk_bounds = C.wordBoundsAt(&doc, 2);
    try std_t.testing.expectEqual(@as(usize, 1), cjk_bounds.start);
    try std_t.testing.expectEqual(@as(usize, 1 + cjk.len), cjk_bounds.end);

    // EOF after 4-byte emoji; old impl started selection at total-1 (continuation byte).
    const eof_bounds = C.wordBoundsAt(&doc, doc.bytes.len);
    try std_t.testing.expectEqual(@as(usize, 1 + cjk.len), eof_bounds.start);
    try std_t.testing.expectEqual(@as(usize, doc.bytes.len), eof_bounds.end);

    // Continuation bytes within emoji also cannot be selection boundaries.
    const emoji_bounds = C.wordBoundsAt(&doc, 1 + cjk.len + 2);
    try std_t.testing.expectEqual(eof_bounds.start, emoji_bounds.start);
    try std_t.testing.expectEqual(eof_bounds.end, emoji_bounds.end);
}

test "cursor floors every interior grapheme byte and preserves exact boundaries" {
    const chunks = [_][]const u8{ "a", "😀", "e\u{301}", "👨‍👩‍👧‍👦", "🇯🇵", "👍🏽", "\r\n", "z" };
    const bytes = "a😀e\u{301}👨‍👩‍👧‍👦🇯🇵👍🏽\r\nz";
    const doc = StubDoc{ .bytes = bytes };
    const C = DocCursor(StubDoc);
    var start: usize = 0;
    for (chunks) |chunk| {
        for (0..chunk.len) |inside| {
            try std_t.testing.expectEqual(start, C.floorCharBoundary(&doc, start + inside));
        }
        start += chunk.len;
    }
    try std_t.testing.expectEqual(bytes.len, C.floorCharBoundary(&doc, bytes.len));
    try std_t.testing.expectEqual(bytes.len, C.floorCharBoundary(&doc, std_t.math.maxInt(usize)));
}
