//! UTF-8 legality check, sole copy in the repo.
//!
//! One scan with three thin wrappers, one rule and three return shapes:
//!  - whole-string valid (`ui/devtools/format.zig`)
//!  - longest valid prefix length (`ui/console.zig` validUtf8PrefixLen)
//!  - longest valid prefix slice (`ui/core/text_shaping.zig` validUtf8Prefix)
//!
//! Delegates to std so overlong / surrogate / >U+10FFFF edge cases are not
//! hand-maintained.

const std = @import("std");

/// Longest-valid UTF-8 prefix byte length, scanning at most `limit` bytes.
///
/// Common kernel of the three functions below: 'whole string valid' is
/// 'prefix len == total len'; 'valid prefix slice' is a cut by that length.
pub fn validPrefixLen(bytes: []const u8, limit: usize) usize {
    const end = @min(limit, bytes.len);
    var i: usize = 0;
    while (i < end) {
        const n = std.unicode.utf8ByteSequenceLength(bytes[i]) catch return i;
        if (i + n > end) return i;
        _ = std.unicode.utf8Decode(bytes[i..][0..n]) catch return i;
        i += n;
    }
    return i;
}

/// Complete storage prefix for renderers that explicitly support WTF-8.
/// Keep protocol/JSON validation on isValid/validPrefix instead.
pub fn validStoragePrefix(bytes: []const u8) []const u8 {
    var i: usize = 0;
    while (i < bytes.len) {
        const n = std.unicode.utf8ByteSequenceLength(bytes[i]) catch break;
        if (n > bytes.len - i) break;
        _ = std.unicode.wtf8Decode(bytes[i..][0..n]) catch break;
        i += n;
    }
    return bytes[0..i];
}

/// Whole string is valid UTF-8.
pub fn isValid(bytes: []const u8) bool {
    return validPrefixLen(bytes, bytes.len) == bytes.len;
}

/// Longest-valid UTF-8 prefix slice.
///
/// WARNING: a caller cutting a prefix **by bytes** may land mid-multibyte sequence
/// (half a CJK/emoji). Invalid UTF-8 fails CoreText's NSString construction, the
/// shape layer returns TextShapingFailed, the FontSelector bridge **silently returns
/// 0.0f**, and the width collapses to 0.00. Cutting to the longest valid prefix
/// matches the actual rendered content; valid input passes through at zero cost.
pub fn validPrefix(bytes: []const u8) []const u8 {
    return bytes[0..validPrefixLen(bytes, bytes.len)];
}

/// Single UTF-8 sequence byte length; invalid lead byte returns 0.
///
/// Differs from `std.unicode.utf8ByteSequenceLength` only in error (0 not error),
/// for byte-by-byte truncation loop.
pub fn seqLen(first_byte: u8) usize {
    return std.unicode.utf8ByteSequenceLength(first_byte) catch 0;
}

// ── Tests ──────────────────────────────────────────────────────

test "isValid: 合法输入" {
    try std.testing.expect(isValid(""));
    try std.testing.expect(isValid("hello"));
    try std.testing.expect(isValid("中文"));
    try std.testing.expect(isValid("🎉"));
}

test "isValid: 截断序列与孤立 continuation" {
    try std.testing.expect(!isValid("\xE4\xB8")); // 3-byte sequence given only 2 bytes.
    try std.testing.expect(!isValid("\x80")); // Orphan continuation.
    try std.testing.expect(!isValid("\xFF"));
}

test "isValid: overlong / surrogate / 超出 U+10FFFF 都要拒绝" {
    // These three are easiest to miss in hand-written impl; lock them down.
    try std.testing.expect(!isValid("\xC0\x80")); // overlong NUL
    try std.testing.expect(!isValid("\xE0\x80\x80")); // overlong
    try std.testing.expect(!isValid("\xED\xA0\x80")); // UTF-16 surrogate D800
    try std.testing.expect(!isValid("\xF4\x90\x80\x80")); // > U+10FFFF
    try std.testing.expect(!isValid("\xF5\x80\x80\x80")); // Lead byte out of range.
}

test "validPrefixLen: 切在多字节中间时退回序列起点" {
    const s = "ab中"; // 'a''b' + 3 bytes
    try std.testing.expectEqual(@as(usize, 2), validPrefixLen(s, 3)); // Cut in middle of 'Chinese'.
    try std.testing.expectEqual(@as(usize, 2), validPrefixLen(s, 4));
    try std.testing.expectEqual(@as(usize, 5), validPrefixLen(s, 5)); // Complete.
}

test "validPrefixLen: limit 超过串长时按串长算" {
    try std.testing.expectEqual(@as(usize, 5), validPrefixLen("hello", 999));
}

test "validPrefix: 合法输入零拷贝原样返回" {
    const src = "中文";
    const out = validPrefix(src);
    try std.testing.expectEqualStrings(src, out);
    try std.testing.expect(out.ptr == src.ptr);
}

test "validPrefix: 非法尾部被裁掉" {
    try std.testing.expectEqualStrings("ab", validPrefix("ab\xE4\xB8"));
    try std.testing.expectEqualStrings("", validPrefix("\x80\x80"));
}

test "seqLen: 首字节非法返回 0（供截断循环推进用）" {
    try std.testing.expectEqual(@as(usize, 1), seqLen('a'));
    try std.testing.expectEqual(@as(usize, 3), seqLen(0xE4));
    try std.testing.expectEqual(@as(usize, 4), seqLen(0xF0));
    try std.testing.expectEqual(@as(usize, 0), seqLen(0x80)); // isolated continuation
    try std.testing.expectEqual(@as(usize, 0), seqLen(0xFF));
}

test "storage prefix retains surrogate code units without weakening UTF8 validation" {
    const text = "A\xed\xa0\x80Z";
    try std.testing.expectEqualStrings(text, validStoragePrefix(text));
    try std.testing.expect(!isValid(text));
    try std.testing.expectEqualStrings("A", validPrefix(text));
    try std.testing.expectEqualStrings("A", validStoragePrefix("A\xed\xa0"));
    try std.testing.expectEqualStrings("A", validStoragePrefix("A\xf4\x90\x80\x80"));
}
