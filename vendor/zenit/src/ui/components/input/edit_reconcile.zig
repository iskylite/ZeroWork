//! Cursor/selection mapping when a parent rewrites user edits (in-place correction for
//! value bindings, binding.zig).
//!
//! Scenario: user edits the buffer to 'proposed', the parent (via ui.split) lands
//! 'landed' (uppercase enforcement, filtered chars, max-length truncation). The buffer
//! is modified in place to 'landed'; cursor/selection are remapped, not jumped to end.
//!
//! Rules (single-change region): find the longest common prefix P and non-overlapping
//! longest common suffix S; the middle is the region replaced by the parent:
//! proposed[P .. old_end] -> landed[P .. new_end]. Offset x (proposed coordinates) maps:
//! - x <= P (before change): unchanged
//! - x >= old_end (after change): keep distance to text end, x - old_end + new_end
//! - inside the region: keep distance from region start, clamped: P + min(x - P, new_end - P)
//!
//! Then snap to grapheme boundaries of 'landed' (post-change snaps forward, others
//! backward, so the insertion point never rewinds into inserted text). Common
//! prefix/suffix are first backed to UTF-8 code point boundaries, never splitting
//! multibyte chars.
//!
//! Examples: 'AB|C' type 'x', parent uppercases: proposed='ABx|C', landed='ABX|C', P=2
//! S=1, cursor 3=old_end -> 3. Number field, letter filtered: proposed='12a|34',
//! landed='12|34', cursor 3=old_end -> 2. Max-length truncate: proposed='abX|cde',
//! landed='abX|cd', P=4 -> cursor 3 unchanged.
//!
//! The rule is edit-agnostic: insert, delete, paste, range replace, IME commit and
//! undo/redo all use the same mapping.

const std = @import("std");
const text_coordinates = @import("text_core").text_coordinates;

pub const Rewrite = struct {
    /// common prefix length (both texts at UTF-8 boundary)
    prefix: usize,
    /// end offset of changed region in proposed (= proposed.len - common suffix)
    old_end: usize,
    /// end offset of changed region in landed (= landed.len - common suffix)
    new_end: usize,

    pub fn diff(proposed: []const u8, landed: []const u8) Rewrite {
        const max_common = @min(proposed.len, landed.len);
        var prefix: usize = 0;
        while (prefix < max_common and proposed[prefix] == landed[prefix]) prefix += 1;
        // common bytes may stop mid-character: back to code point start
        while (prefix > 0 and (isContinuation(proposed, prefix) or isContinuation(landed, prefix))) prefix -= 1;

        var suffix: usize = 0;
        const suffix_limit = max_common - prefix;
        while (suffix < suffix_limit and proposed[proposed.len - 1 - suffix] == landed[landed.len - 1 - suffix]) suffix += 1;
        // suffix start must be code point start (suffix bytes identical on both sides, check
        // either)
        while (suffix > 0 and isContinuation(proposed, proposed.len - suffix)) suffix -= 1;

        return .{ .prefix = prefix, .old_end = proposed.len - suffix, .new_end = landed.len - suffix };
    }

    /// map offset from proposed to landed, snap to grapheme boundary
    pub fn mapOffset(self: Rewrite, landed: []const u8, x: usize) usize {
        if (x <= self.prefix) {
            return text_coordinates.clampByteOffset(landed, .{ .value = @min(x, landed.len) }, .backward).value;
        }
        if (x >= self.old_end) {
            const mapped = @min(x - self.old_end + self.new_end, landed.len);
            return text_coordinates.clampByteOffset(landed, .{ .value = mapped }, .forward).value;
        }
        const mapped = self.prefix + @min(x - self.prefix, self.new_end - self.prefix);
        return text_coordinates.clampByteOffset(landed, .{ .value = mapped }, .backward).value;
    }

    fn isContinuation(text: []const u8, index: usize) bool {
        return index < text.len and (text[index] & 0xC0) == 0x80;
    }
};

/// cursor position on reject / no checkpoint: clamp to new length and snap to grapheme boundary
pub fn clampOffset(text: []const u8, x: usize) usize {
    return text_coordinates.clampByteOffset(text, .{ .value = @min(x, text.len) }, .backward).value;
}

const testing = std.testing;

fn expectMap(proposed: []const u8, landed: []const u8, x: usize, want: usize) !void {
    const r = Rewrite.diff(proposed, landed);
    try testing.expectEqual(want, r.mapOffset(landed, x));
}

test "Rewrite: 中间插入被大写化，光标留在插入点之后" {
    try expectMap("ABxC", "ABXC", 3, 3);
    // other positions before/after cursor unchanged
    try expectMap("ABxC", "ABXC", 1, 1);
    try expectMap("ABxC", "ABXC", 4, 4);
}

test "Rewrite: 过滤掉非法字符，光标回到原插入点" {
    try expectMap("12a34", "1234", 3, 2);
    // paste mixed content keep only digits: 12|34 paste 'a5b' -> 12a5b|34 -> 125|34
    try expectMap("12a5b34", "12534", 5, 3);
}

test "Rewrite: 截断尾部不移动插入点" {
    try expectMap("abXcde", "abXcd", 3, 3);
    try expectMap("Xabcde", "Xabcd", 1, 1);
}

test "Rewrite: 删除被改写（父组件补回分隔符）" {
    // 12-34 delete '-' -> 1234, parent formats back to 12-34: cursor 2 -> 2
    try expectMap("1234", "12-34", 2, 2);
}

test "Rewrite: 全局变换（整段大写化）光标保持到末尾的距离" {
    try expectMap("abc", "ABC", 3, 3);
    try expectMap("abc", "ABC", 1, 1);
}

test "Rewrite: 多字节字符不被劈开" {
    // 'e-acute'(C3 A9) and 'e-grave'(C3 A8) share first byte: common prefix must back to code point
    // start
    const r = Rewrite.diff("a\xc3\xa9b", "a\xc3\xa8b");
    try testing.expectEqual(@as(usize, 1), r.prefix);
    try testing.expectEqual(@as(usize, 3), r.old_end);
    try testing.expectEqual(@as(usize, 3), r.new_end);
    // same for suffix: different first byte sharing last byte
    const s = Rewrite.diff("\xe4\xb8\xad", "\xe6\xb8\xad");
    try testing.expectEqual(@as(usize, 0), s.prefix);
    try testing.expectEqual(@as(usize, 3), s.old_end);
    try testing.expectEqual(@as(usize, 3), s.new_end);
    // offsets within changed region snap to boundary if mid-character
    try expectMap("中文x", "中文X", 7, 7);
    // One ASCII char plus one CJK char -> a different ASCII char plus two CJK chars: after the
    // changed region, keep the distance to the text end
    try expectMap("x中", "y中中", 1, 4);
}

test "Rewrite: 相同文本是恒等映射" {
    const r = Rewrite.diff("same", "same");
    try testing.expectEqual(@as(usize, 4), r.prefix);
    try testing.expectEqual(@as(usize, 4), r.old_end);
    try testing.expectEqual(@as(usize, 4), r.new_end);
    try testing.expectEqual(@as(usize, 2), r.mapOffset("same", 2));
}

test "Rewrite: 空文本两端" {
    try expectMap("", "abc", 0, 0);
    try expectMap("abc", "", 2, 0);
}
