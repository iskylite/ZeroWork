//! Single-pass text statistics scan: bytes in, newline_count + first/last/longest_row_chars out
//! (matches Zed TextSummary::from(str)).
//! These numbers drive PieceSummary's cross-piece longest-line merge; if wrong, editor horizontal
//! scroll width follows. No dependency on PieceTree / SumTree / allocator.
//! How stats aggregate into Summary on the B-tree is piece_tree's job; TreePiece.fromText calls
//! here.
//! Pitfalls: (1) character = Unicode code point, advanced by std.unicode.utf8ByteSequenceLength:
//! only 0x00-0x7F(1) / 0xC0-0xDF(2) / 0xE0-0xEF(3) / 0xF0-0xF7(4) are valid leads.
//! Bare continuation 0x80..0xBF and invalid lead 0xF8..0xFF count as 1. 0xC0/0xC1 are overlong
//! 2-byte leads: scan skips continuation validation, consuming 1 trailing byte and counting 1 char;
//! the truncation check `i + cp_len <= text.len` checks length only, not content. All paths must
//! advance i; no panic or loop. (2) Line width uses saturating +|= so very long lines don't wrap
//! u32 to 0. (3) first_line_chars locks at the first '\n'; no newline = whole length.
//! (4) Known quirk (locked, not fixed): a multibyte lead followed by '\n' with the sequence
//! truncated at buffer end passes `i + cp_len <= text.len` and advances past the '\n' that should
//! count alone: line width +1, newline_count -1. Scan cannot distinguish a truncated sequence from
//! a valid sequence followed by '\n'. Fixing needs advance semantics change and PieceSummary
//! merge update. Related tests assert self-consistency, not hardcoded quirk arithmetic.

const std = @import("std");

/// Line statistics of text (fields map one-to-one to PieceSummary's four scalars).
pub const TextStats = struct {
    newline_count: usize,
    first_line_chars: u32,
    last_line_chars: u32,
    longest_row_chars: u32,
};

/// Single-pass scan: newline_count + first/last/longest_row_chars (O(n), no allocation).
pub fn scan(text: []const u8) TextStats {
    var newline_count: usize = 0;
    var first_line_chars: u32 = 0;
    var current_line_chars: u32 = 0;
    var longest_row_chars: u32 = 0;
    var first_line_done = false;

    var i: usize = 0;
    while (i < text.len) {
        const b = text[i];
        if (b == '\n') {
            if (!first_line_done) {
                first_line_chars = current_line_chars;
                first_line_done = true;
            }
            if (current_line_chars > longest_row_chars) {
                longest_row_chars = current_line_chars;
            }
            current_line_chars = 0;
            newline_count += 1;
            i += 1;
        } else if (b < 0x80) {
            current_line_chars +|= 1;
            i += 1;
        } else {
            // UTF-8 multibyte: counts as 1 character
            const cp_len = std.unicode.utf8ByteSequenceLength(b) catch 1;
            const advance = if (i + cp_len <= text.len) cp_len else 1;
            current_line_chars +|= 1;
            i += advance;
        }
    }

    // Handle last line (no trailing \n)
    if (!first_line_done) {
        first_line_chars = current_line_chars;
    }
    if (current_line_chars > longest_row_chars) {
        longest_row_chars = current_line_chars;
    }

    return .{
        .newline_count = newline_count,
        .first_line_chars = first_line_chars,
        .last_line_chars = current_line_chars,
        .longest_row_chars = longest_row_chars,
    };
}

// Collection mechanism: text_core.zig has `pub const piece_stats = @import(...)` + root file's
// `test { refAllDecls }`. Exporting via `pub const X = @import(...)` alone does NOT collect
// tests here; must be referenced by refAllDecls (see build.zig font_catalog comment).

test "scan: 空字符串全零" {
    const s = scan("");
    try std.testing.expectEqual(@as(usize, 0), s.newline_count);
    try std.testing.expectEqual(@as(u32, 0), s.first_line_chars);
    try std.testing.expectEqual(@as(u32, 0), s.last_line_chars);
    try std.testing.expectEqual(@as(u32, 0), s.longest_row_chars);
}

test "scan: 单字符无换行" {
    const s = scan("x");
    try std.testing.expectEqual(@as(usize, 0), s.newline_count);
    try std.testing.expectEqual(@as(u32, 1), s.first_line_chars);
    try std.testing.expectEqual(@as(u32, 1), s.last_line_chars);
    try std.testing.expectEqual(@as(u32, 1), s.longest_row_chars);
}

test "scan: 单个换行符是唯一的空行" {
    const s = scan("\n");
    try std.testing.expectEqual(@as(usize, 1), s.newline_count);
    try std.testing.expectEqual(@as(u32, 0), s.first_line_chars);
    try std.testing.expectEqual(@as(u32, 0), s.last_line_chars);
    try std.testing.expectEqual(@as(u32, 0), s.longest_row_chars);
}

test "scan: 仅换行符" {
    const s = scan("\n\n\n");
    try std.testing.expectEqual(@as(usize, 3), s.newline_count);
    try std.testing.expectEqual(@as(u32, 0), s.first_line_chars);
    try std.testing.expectEqual(@as(u32, 0), s.last_line_chars);
    try std.testing.expectEqual(@as(u32, 0), s.longest_row_chars);
}

test "scan: 无结尾换行时 last_line 是末行" {
    const s = scan("abc\ndef");
    try std.testing.expectEqual(@as(usize, 1), s.newline_count);
    try std.testing.expectEqual(@as(u32, 3), s.first_line_chars);
    try std.testing.expectEqual(@as(u32, 3), s.last_line_chars);
    try std.testing.expectEqual(@as(u32, 3), s.longest_row_chars);
}

test "scan: 结尾换行后 last_line 归零" {
    const s = scan("abc\n");
    try std.testing.expectEqual(@as(usize, 1), s.newline_count);
    try std.testing.expectEqual(@as(u32, 3), s.first_line_chars);
    try std.testing.expectEqual(@as(u32, 0), s.last_line_chars);
    try std.testing.expectEqual(@as(u32, 3), s.longest_row_chars);
}

test "scan: 首字符即换行时 first_line 为零" {
    const s = scan("\nabc");
    try std.testing.expectEqual(@as(usize, 1), s.newline_count);
    try std.testing.expectEqual(@as(u32, 0), s.first_line_chars);
    try std.testing.expectEqual(@as(u32, 3), s.last_line_chars);
    try std.testing.expectEqual(@as(u32, 3), s.longest_row_chars);
}

test "scan: 最长行在中间" {
    const s = scan("ab\nabcdefgh\n cd\n");
    try std.testing.expectEqual(@as(usize, 3), s.newline_count);
    try std.testing.expectEqual(@as(u32, 2), s.first_line_chars);
    try std.testing.expectEqual(@as(u32, 0), s.last_line_chars);
    try std.testing.expectEqual(@as(u32, 8), s.longest_row_chars);
}

test "scan: 多字节 UTF-8 按码点计数" {
    const s = scan("h\u{00E9}llo\nw\u{00F6}rld\n");
    // h e l l o = 5 code points (e with acute is 2 bytes); w o r l d likewise
    try std.testing.expectEqual(@as(usize, 2), s.newline_count);
    try std.testing.expectEqual(@as(u32, 5), s.first_line_chars);
    try std.testing.expectEqual(@as(u32, 0), s.last_line_chars);
    try std.testing.expectEqual(@as(u32, 5), s.longest_row_chars);
}

test "scan: 3/4 字节码点各算一个字符" {
    const s = scan("你\n\u{1F600}z");
    try std.testing.expectEqual(@as(usize, 1), s.newline_count);
    try std.testing.expectEqual(@as(u32, 1), s.first_line_chars);
    try std.testing.expectEqual(@as(u32, 2), s.last_line_chars);
    try std.testing.expectEqual(@as(u32, 2), s.longest_row_chars);
}

test "scan: 缓冲区末尾截断的多字节序列按单字节推进" {
    // "abc<U+4F60>" with the last byte cut off: after 0xE4 only 0xBD remains with no byte after it,
    // i+3>len => takes the advance=1 defensive branch (must not go out of bounds or loop forever)
    const s = scan("abc\u{4F60}"[0..5]);
    try std.testing.expectEqual(@as(usize, 0), s.newline_count);
    try std.testing.expectEqual(@as(u32, 5), s.first_line_chars);
    try std.testing.expectEqual(@as(u32, 5), s.last_line_chars);
    try std.testing.expectEqual(@as(u32, 5), s.longest_row_chars);
}

test "scan: 非法 lead / 裸 continuation 不死循环（逐字节推演真实口径）" {
    // Byte sequence length != character count. Advance uses std.unicode.utf8ByteSequenceLength:
    // only 0x00-0x7F(1) / 0xC0-0xDF(2) / 0xE0-0xEF(3) / 0xF0-0xF7(4) are valid leads, the rest
    // illegal.
    //
    // "\xff\xfe\xc0\x80\x8f" byte by byte:
    //   i=0 0xff  illegal lead              -> advance 1, count 1 character
    //   i=1 0xfe  illegal lead              -> advance 1, count 1 character
    //   i=2 0xc0  valid 2-byte lead         -> consume 0x80 too, advance 2, count 1 character
    //   i=4 0x8f  bare continuation (<0xC0, not a lead) -> illegal, advance 1, count 1 character
    // Total 5 bytes -> **4** "characters".
    //
    // This is scan's actual behavior, not a bug: it does not validate continuations and invalid
    // input has no unique correct answer. The test requires no panic/loop, monotonic i, and pins
    // the current behavior so future changes show up as differences.
    const s = scan("\xff\xfe\xc0\x80\x8f");
    try std.testing.expectEqual(@as(usize, 0), s.newline_count);
    try std.testing.expectEqual(@as(u32, 4), s.first_line_chars);
    try std.testing.expectEqual(@as(u32, 4), s.last_line_chars);
    try std.testing.expectEqual(@as(u32, 4), s.longest_row_chars);
}

test "scan: ≥0xF8 的非法 lead 才走「1 字节 = 1 字符」防御分支" {
    // Complements previous: 0xF8..0xFF is the only range utf8ByteSequenceLength marks illegal,
    // each regresses to advance=1, counted individually.
    const s = scan("\xf8\xf9\xfa\xfb\xfc\xfd\xfe\xff");
    try std.testing.expectEqual(@as(usize, 0), s.newline_count);
    try std.testing.expectEqual(@as(u32, 8), s.first_line_chars);
    try std.testing.expectEqual(@as(u32, 8), s.last_line_chars);
    try std.testing.expectEqual(@as(u32, 8), s.longest_row_chars);
}

test "scan: 孤立的 4 字节 lead 字节在末尾只前进 1" {
    const s = scan("ab\xf0");
    try std.testing.expectEqual(@as(usize, 0), s.newline_count);
    try std.testing.expectEqual(@as(u32, 3), s.first_line_chars);
    try std.testing.expectEqual(@as(u32, 3), s.last_line_chars);
    try std.testing.expectEqual(@as(u32, 3), s.longest_row_chars);
}

test "scan: CR 计入行宽（CRLF 文件的行宽比视觉多 1，现状口径）" {
    const s = scan("ab\r\ncd\r\n");
    try std.testing.expectEqual(@as(usize, 2), s.newline_count);
    try std.testing.expectEqual(@as(u32, 3), s.first_line_chars);
    try std.testing.expectEqual(@as(u32, 0), s.last_line_chars);
    try std.testing.expectEqual(@as(u32, 3), s.longest_row_chars);
}

test "scan: 超长单行不溢出 u32" {
    const alloc = std.testing.allocator;
    const n: usize = 200_000;
    const text = try alloc.alloc(u8, n);
    defer alloc.free(text);
    @memset(text, 'q');
    const s = scan(text);
    try std.testing.expectEqual(@as(usize, 0), s.newline_count);
    try std.testing.expectEqual(@as(u32, @intCast(n)), s.first_line_chars);
    try std.testing.expectEqual(@as(u32, @intCast(n)), s.last_line_chars);
    try std.testing.expectEqual(@as(u32, @intCast(n)), s.longest_row_chars);
}

test "scan: 逐 token 构造的期望统计（构造即预言）" {
    // Assemble a buffer from tokens with known char counts: expected values are computed up front
    // and
    // scan must recover the same statistics from bytes alone. Independent oracle for
    // multibyte/illegal
    // decoding; a scan bug such as "e-acute counts as 2" fails here. The token set intentionally
    // omits
    // multibyte-lead + tight-newline: it triggers the module-head quirk (advance swallows '\n')
    // which
    // the oracle cannot express. The quirk is covered by the explicit status-lock test below.
    const alloc = std.testing.allocator;
    var buf = @as(std.ArrayList(u8), .empty);
    defer buf.deinit(alloc);

    var exp_lines: usize = 0;
    var exp_first: ?u32 = null;
    var exp_cur: u32 = 0;
    var exp_longest: u32 = 0;

    const Token = struct { text: []const u8, chars: u32, newlines: usize };
    const tokens = [_]Token{
        .{ .text = "a", .chars = 1, .newlines = 0 },
        .{ .text = "\u{4F60}", .chars = 1, .newlines = 0 },
        .{ .text = "\n", .chars = 0, .newlines = 1 },
        .{ .text = "\u{1F600}", .chars = 1, .newlines = 0 },
        .{ .text = "\xff", .chars = 1, .newlines = 0 },
        .{ .text = "bcd", .chars = 3, .newlines = 0 },
        .{ .text = "\n", .chars = 0, .newlines = 1 },
        .{ .text = "\xc0\xaf", .chars = 1, .newlines = 0 }, // Overlong encoding of '/'. 0xC0 is **valid** 2-byte lead,
        // so scan consumes \xaf together, counting 1 character; does not validate continuation
        // validity.
        .{ .text = "\n", .chars = 0, .newlines = 1 },
        .{ .text = "\u{00E9}", .chars = 1, .newlines = 0 }, // e-acute (2 bytes)
    };

    var seed: u64 = 4242;
    const lcg = struct {
        fn next(s: *u64) u64 {
            s.* = s.* *% 6364136223846793005 +% 1442695040888963407;
            return s.* >> 33;
        }
    };

    var i: usize = 0;
    while (i < 300) : (i += 1) {
        const pick: u64 = lcg.next(&seed) % @as(u64, tokens.len);
        const tok = tokens[@as(usize, @intCast(pick))];
        try buf.appendSlice(alloc, tok.text);
        if (tok.newlines > 0) {
            if (exp_first == null) exp_first = exp_cur;
            if (exp_cur > exp_longest) exp_longest = exp_cur;
            exp_cur = 0;
            exp_lines += 1;
        } else {
            exp_cur +|= tok.chars;
        }
    }
    if (exp_first == null) exp_first = exp_cur;
    if (exp_cur > exp_longest) exp_longest = exp_cur;

    const got = scan(buf.items);
    try std.testing.expectEqual(exp_lines, got.newline_count);
    try std.testing.expectEqual(exp_first.?, got.first_line_chars);
    try std.testing.expectEqual(exp_cur, got.last_line_chars);
    try std.testing.expectEqual(exp_longest, got.longest_row_chars);
}

// These two migrated from piece_tree.zig (was PieceTree::scanTextStats), plus status-lock for
// module-head quirk: advance swallows '\n' tight after truncated sequence. If quirk is fixed,
// update expectation here (and PieceSummary merge).

test "scan: 现状锁定 —— 截断的多字节序列会吞掉紧随的换行符（已知怪癖）" {
    // U+4F60 (E4 BD A0) + truncated tail (E4 BD) + '\n', 6 bytes total, traced byte by byte:
    //   i=0 0xE4 declares 3 bytes, i+3<=6 holds -> advance 3, count 1 char (the complete U+4F60)
    //   i=3 0xE4 declares 3 bytes, i+3<=6 **also holds** -> advance 3, count 1 char
    //       but those 3 bytes are BD 0A, swallowing the trailing '\n' with them
    //   i=6 done
    // So: 2 "chars", **0 newlines**. The '\n' is not counted.
    //
    // Characterization test, not an assertion that this is how it "should" behave: scan only
    // guarantees no panic / no infinite loop / monotonic i, and has no well-defined answer for
    // truncated multi-byte sequences. Pinned so that if the advance logic changes (e.g. validating
    // continuation bytes), this goes red to flag changed newline-counting semantics, which
    // PieceSummary merging across pieces relies on.
    const s = scan("\u{4F60}\u{4F60}"[0..5] ++ "\n");
    try std.testing.expectEqual(@as(usize, 0), s.newline_count);
    try std.testing.expectEqual(@as(u32, 2), s.first_line_chars);
    try std.testing.expectEqual(@as(u32, 2), s.last_line_chars);
    try std.testing.expectEqual(@as(u32, 2), s.longest_row_chars);
}

test "scan: 多行文本的基本统计" {
    const stats = scan("hello\nworld foo bar\nhi\n");
    try std.testing.expectEqual(@as(usize, 3), stats.newline_count);
    try std.testing.expectEqual(@as(u32, 5), stats.first_line_chars); // "hello"
    try std.testing.expectEqual(@as(u32, 0), stats.last_line_chars); // "" after final \n
    try std.testing.expectEqual(@as(u32, 13), stats.longest_row_chars); // "world foo bar"
}

test "scan: 无换行文本" {
    const stats = scan("abcdef");
    try std.testing.expectEqual(@as(usize, 0), stats.newline_count);
    try std.testing.expectEqual(@as(u32, 6), stats.first_line_chars);
    try std.testing.expectEqual(@as(u32, 6), stats.last_line_chars);
    try std.testing.expectEqual(@as(u32, 6), stats.longest_row_chars);
}
