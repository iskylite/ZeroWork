//! UTF-8 snapshots and relative deletion bounds for text-input-v3.
const std = @import("std");
pub const Snapshot = struct { text: []const u8, cursor: u32, anchor: u32 };
pub fn boundary(text: []const u8, offset: usize) bool {
    return offset <= text.len and (offset == text.len or text[offset] & 0xc0 != 0x80);
}
/// Copy a bounded window containing the whole selection. Secure clients are
/// never queried for document bytes. Null means no valid surrounding snapshot.
pub fn surrounding(client: anytype, buffer: []u8) ?Snapshot {
    if (client.secure) return .{ .text = "", .cursor = 0, .anchor = 0 };
    const length = client.text_len(client.context);
    const selection = client.selection(client.context);
    const cursor: usize = selection.caret;
    const anchor: usize = if (cursor == selection.start) selection.end else selection.start;
    if (cursor > length or anchor > length) return null;
    const lo = @min(cursor, anchor);
    const hi = @max(cursor, anchor);
    const capacity = @min(buffer.len, 4000);
    if (hi - lo > capacity) return null;
    var start = lo -| ((capacity - (hi - lo)) / 2);
    start = @min(start, length -| capacity);
    const wanted = @min(capacity, length - start);
    const copied = client.copy_text(client.context, start, buffer[0..wanted]);
    if (copied != wanted) return null;
    var first: usize = 0;
    while (first < copied and buffer[first] & 0xc0 == 0x80) : (first += 1) {}
    if (first > 3) return null;
    var end = copied;
    // Only a partial trailing scalar can be omitted. Never silently repair
    // malformed interior bytes supplied by a client.
    while (end >= first and copied - end <= 3) : (end -= 1) {
        const text = buffer[first..end];
        if (std.unicode.utf8ValidateSlice(text)) {
            const origin = start + first;
            if (cursor < origin or anchor < origin or cursor > start + end or anchor > start + end) return null;
            const c = cursor - origin;
            const a = anchor - origin;
            if (!boundary(text, c) or !boundary(text, a)) return null;
            return .{ .text = text, .cursor = @intCast(c), .anchor = @intCast(a) };
        }
        if (end == first) break;
    }
    return null;
}
pub const DeleteRange = struct { start: usize, end: usize, selection_start: usize, selection_end: usize };
/// The protocol excludes the selection from before/after byte counts.
pub fn deletion(text: []const u8, cursor: usize, anchor: usize, before: u32, after: u32) ?DeleteRange {
    const lo = @min(cursor, anchor);
    const hi = @max(cursor, anchor);
    if (hi > text.len or before > lo or after > text.len - hi) return null;
    const start = lo - before;
    const end = hi + after;
    if (!boundary(text, start) or !boundary(text, end) or !boundary(text, lo) or !boundary(text, hi)) return null;
    return .{ .start = start, .end = end, .selection_start = lo, .selection_end = hi };
}
const Reader = struct {
    text: []const u8,
    caret: u32,
    anchor: u32,
    secure: bool = false,
    copies: usize = 0,
    fn textLen(ctx: *anyopaque) usize {
        const self: *Reader = @ptrCast(@alignCast(ctx));
        return self.text.len;
    }
    fn copy(ctx: *anyopaque, start: usize, out: []u8) usize {
        const self: *Reader = @ptrCast(@alignCast(ctx));
        self.copies += 1;
        @memcpy(out, self.text[start..][0..out.len]);
        return out.len;
    }
    fn selection(ctx: *anyopaque) struct { caret: u32, start: u32, end: u32 } {
        const self: *Reader = @ptrCast(@alignCast(ctx));
        return .{ .caret = self.caret, .start = @min(self.caret, self.anchor), .end = @max(self.caret, self.anchor) };
    }
    fn client(self: *Reader) struct { context: *anyopaque, secure: bool, text_len: *const fn (*anyopaque) usize, copy_text: *const fn (*anyopaque, usize, []u8) usize, selection: *const fn (*anyopaque) @typeInfo(@TypeOf(selection)).@"fn".return_type.? } {
        return .{ .context = self, .secure = self.secure, .text_len = textLen, .copy_text = copy, .selection = selection };
    }
};
test "surrounding snapshot crops long UTF-8 at scalar boundaries and never reads secure text" {
    var text: [6000]u8 = undefined;
    for (0..2000) |i| @memcpy(text[i * 3 ..][0..3], "候");
    var reader: Reader = .{ .text = &text, .caret = 3000, .anchor = 3006 };
    var buffer: [4000]u8 = undefined;
    const snapshot = surrounding(reader.client(), &buffer).?;
    try std.testing.expect(snapshot.text.len <= 4000);
    try std.testing.expect(std.unicode.utf8ValidateSlice(snapshot.text));
    try std.testing.expectEqual(@as(u32, 6), snapshot.anchor - snapshot.cursor);
    reader.secure = true;
    const secure = surrounding(reader.client(), &buffer).?;
    try std.testing.expectEqual(@as(usize, 0), secure.text.len);
    try std.testing.expectEqual(@as(usize, 1), reader.copies);
    reader.secure = false;
    reader.caret = 0;
    reader.anchor = 6000;
    try std.testing.expect(surrounding(reader.client(), &buffer) == null);
}
test "relative deletion preserves selected bytes and rejects mid-scalar and stale bounds" {
    const text = "A你SEL好Z";
    const range = deletion(text, 4, 7, 3, 3).?;
    try std.testing.expectEqual(@as(usize, 1), range.start);
    try std.testing.expectEqual(@as(usize, 10), range.end);
    try std.testing.expectEqualStrings("SEL", text[range.selection_start..range.selection_end]);
    try std.testing.expect(deletion(text, 4, 7, 1, 3) == null);
    try std.testing.expect(deletion(text, 4, 7, 5, 3) == null);
    try std.testing.expect(deletion(text, 4, 7, 3, 5) == null);
}
