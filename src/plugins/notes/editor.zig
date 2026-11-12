//! Byte ranges are derived from Markdown. The editor replaces only the
//! active range and rebuilds the block boundaries after it leaves that range.
const std = @import("std");

pub const Kind = enum { text, markdown, raw, image, table };

pub const Block = struct {
    start: usize,
    end: usize,
    kind: Kind,

    pub fn text(self: Block, body: []const u8) []const u8 {
        return body[self.start..self.end];
    }
};

const Fence = struct {
    marker: u8,
    count: usize,

    fn opening(line: []const u8) ?Fence {
        const clean = std.mem.trimStart(u8, line, " ");
        if (line.len - clean.len > 3 or clean.len < 3) return null;
        const marker = clean[0];
        if (marker != '`' and marker != '~') return null;
        var count: usize = 1;
        while (count < clean.len and clean[count] == marker) count += 1;
        if (count < 3 or (marker == '`' and std.mem.indexOfScalar(u8, clean[count..], marker) != null)) return null;
        return .{ .marker = marker, .count = count };
    }

    fn closes(self: Fence, line: []const u8) bool {
        const clean = std.mem.trimStart(u8, line, " ");
        if (line.len - clean.len > 3 or clean.len < self.count) return false;
        var count: usize = 0;
        while (count < clean.len and clean[count] == self.marker) count += 1;
        return count >= self.count and std.mem.trim(u8, clean[count..], " \t\r").len == 0;
    }
};

fn lineEnd(text: []const u8, start: usize) usize {
    return std.mem.indexOfScalarPos(u8, text, start, '\n') orelse text.len;
}

fn blank(line: []const u8) bool {
    return std.mem.trim(u8, line, " \t\r").len == 0;
}

pub fn heading(line: []const u8) ?struct { level: usize, title: []const u8 } {
    const clean = std.mem.trimStart(u8, line, " ");
    if (line.len - clean.len > 3 or clean.len < 2 or clean[0] != '#') return null;
    var depth: usize = 1;
    while (depth < clean.len and clean[depth] == '#') depth += 1;
    if (depth > 6 or depth == clean.len or (clean[depth] != ' ' and clean[depth] != '\t')) return null;
    const title = std.mem.trim(u8, clean[depth + 1 ..], " \t\r");
    const without_hashes = std.mem.trimEnd(u8, title, "#");
    const label = if (without_hashes.len != title.len and (without_hashes.len == 0 or std.ascii.isWhitespace(without_hashes[without_hashes.len - 1])))
        std.mem.trimEnd(u8, without_hashes, " \t")
    else
        title;
    return .{ .level = depth, .title = label };
}

fn hasInlineMarkup(line: []const u8) bool {
    for ([_][]const u8{ "**", "__", "~~", "](", "`" }) |marker| {
        if (std.mem.indexOf(u8, line, marker) != null) return true;
    }
    for ([_]u8{ '*', '_' }) |marker| {
        const start = std.mem.indexOfScalar(u8, line, marker) orelse continue;
        if (std.mem.indexOfScalarPos(u8, line, start + 1, marker) != null) return true;
    }
    return false;
}

fn markdownLine(line: []const u8) bool {
    const clean = std.mem.trimStart(u8, line, " \t");
    if (heading(line) != null or clean.len == 0) return clean.len != 0;
    if (clean[0] == '>') return true;
    for ([_][]const u8{ "- ", "* ", "+ ", "---", "***", "___" }) |prefix| {
        if (std.mem.startsWith(u8, clean, prefix)) return true;
    }
    var digits: usize = 0;
    while (digits < clean.len and std.ascii.isDigit(clean[digits])) digits += 1;
    if (digits != 0 and digits + 1 < clean.len and
        (clean[digits] == '.' or clean[digits] == ')') and clean[digits + 1] == ' ') return true;
    if (std.mem.indexOfScalar(u8, clean, '|') != null) return true;
    return hasInlineMarkup(line);
}

/// A table header line contains a `|` but does not start with a list or task
/// marker such as `- [ ]`.
fn tableHeadLine(line: []const u8) bool {
    const clean = std.mem.trimStart(u8, line, " \t");
    if (clean.len == 0) return false;
    if (std.mem.indexOfScalar(u8, clean, '|') == null) return false;
    if (clean[0] == '-' or clean[0] == '*' or clean[0] == '+') return false;
    return true;
}

/// An alignment separator row: starts with `|` or with a `-`/`|`/`:` run,
/// contains only `|`, `-`, `:`, spaces (and tabs/CR), and at least one `-`.
fn tableSeparatorLine(line: []const u8) bool {
    const clean = std.mem.trim(u8, line, " \t\r");
    if (clean.len == 0) return false;
    const first = clean[0];
    if (first != '|' and first != '-' and first != ':') return false;
    var dashes: usize = 0;
    for (clean) |c| {
        switch (c) {
            '|', ':', ' ' => {},
            '-' => dashes += 1,
            else => return false,
        }
    }
    return dashes > 0;
}

pub fn blocks(allocator: std.mem.Allocator, body: []const u8) ![]Block {
    var result: std.ArrayList(Block) = .empty;
    errdefer result.deinit(allocator);
    var start: usize = 0;
    while (skipBlankLines(body, start)) |next| {
        const block = readBlock(body, next);
        try result.append(allocator, block);
        start = @min(block.end + 1, body.len);
    }
    return result.toOwnedSlice(allocator);
}

fn skipBlankLines(body: []const u8, start: usize) ?usize {
    var next = start;
    while (next < body.len) {
        const end = lineEnd(body, next);
        if (!blank(body[next..end])) return next;
        next = end + 1;
    }
    return null;
}

fn readBlock(body: []const u8, start: usize) Block {
    var end = lineEnd(body, start);
    const first = body[start..end];
    var kind: Kind = .text;
    if (Fence.opening(first)) |fence| {
        kind = .raw;
        while (end < body.len) {
            const next = end + 1;
            end = lineEnd(body, next);
            if (fence.closes(body[next..end])) {
                kind = .markdown;
                break;
            }
        }
    } else if (heading(first) != null) {
        kind = .markdown;
    } else if (std.mem.startsWith(u8, std.mem.trim(u8, first, " \t\r"), "![") and
        std.mem.endsWith(u8, std.mem.trim(u8, first, " \t\r"), ")"))
    {
        kind = .image;
    } else if (end < body.len and tableHeadLine(first) and
        tableSeparatorLine(body[end + 1 .. lineEnd(body, end + 1)]))
    {
        kind = .table;
        while (end < body.len) {
            const next = end + 1;
            const next_end = lineEnd(body, next);
            const line = body[next..next_end];
            if (blank(line) or std.mem.indexOfScalar(u8, line, '|') == null) break;
            end = next_end;
        }
    } else {
        if (markdownLine(first)) kind = .markdown;
        while (end < body.len) {
            const next = end + 1;
            const next_end = lineEnd(body, next);
            const line = body[next..next_end];
            if (blank(line) or heading(line) != null or Fence.opening(line) != null) break;
            if (markdownLine(line)) kind = .markdown;
            end = next_end;
        }
    }
    return .{ .start = start, .end = end, .kind = kind };
}

/// Replace the affected part of the previously parsed block table. The parser
/// may stop only at a block boundary in the unchanged suffix of both bodies.
pub fn reparseBlocks(allocator: std.mem.Allocator, old_body: []const u8, old_blocks: []const Block, new_body: []const u8) ![]Block {
    const prefix = std.mem.indexOfDiff(u8, old_body, new_body) orelse return allocator.dupe(Block, old_blocks);
    var old_suffix = old_body.len;
    var new_suffix = new_body.len;
    while (old_suffix > prefix and new_suffix > prefix and old_body[old_suffix - 1] == new_body[new_suffix - 1]) {
        old_suffix -= 1;
        new_suffix -= 1;
    }

    var first_affected: usize = 0;
    while (first_affected < old_blocks.len and old_blocks[first_affected].end < prefix) : (first_affected += 1) {}
    // The preceding paragraph can absorb a line whose heading, fence or
    // separator was edited. Restart from its beginning before retaining a prefix.
    const keep = first_affected -| 1;
    const restart = if (keep == 0) 0 else old_blocks[keep].start;
    var result: std.ArrayList(Block) = .empty;
    errdefer result.deinit(allocator);
    try result.appendSlice(allocator, old_blocks[0..keep]);
    var start = restart;
    var old_cursor = keep;
    while (skipBlankLines(new_body, start)) |next| {
        if (next >= new_suffix) {
            const old_start = old_suffix + (next - new_suffix);
            while (old_cursor < old_blocks.len and old_blocks[old_cursor].start < old_start) : (old_cursor += 1) {}
            if (old_cursor < old_blocks.len and old_blocks[old_cursor].start == old_start) {
                for (old_blocks[old_cursor..]) |block| {
                    try result.append(allocator, .{
                        .start = new_suffix + (block.start - old_suffix),
                        .end = new_suffix + (block.end - old_suffix),
                        .kind = block.kind,
                    });
                }
                break;
            }
        }
        const block = readBlock(new_body, next);
        try result.append(allocator, block);
        start = @min(block.end + 1, new_body.len);
    }
    return result.toOwnedSlice(allocator);
}

const BlockText = struct {
    kind: Kind,
    content: []const u8,

    fn of(block: Block, body: []const u8) BlockText {
        return .{ .kind = block.kind, .content = block.text(body) };
    }

    fn hash(self: BlockText) u64 {
        return std.hash.Wyhash.hash(@backingInt(self.kind), self.content);
    }

    fn eql(a: BlockText, b: BlockText) bool {
        return a.kind == b.kind and std.mem.eql(u8, a.content, b.content);
    }

    fn eqlOptional(a: ?BlockText, b: ?BlockText) bool {
        if (a) |left| return left.eql(b orelse return false);
        return b == null;
    }
};

const MatchKey = struct {
    current: BlockText,
    previous: ?BlockText = null,
    following: ?BlockText = null,

    fn of(body: []const u8, ranges: []const Block, index: usize, anchored: bool) MatchKey {
        return .{
            .current = .of(ranges[index], body),
            .previous = if (anchored and index > 0) .of(ranges[index - 1], body) else null,
            .following = if (anchored and index + 1 < ranges.len) .of(ranges[index + 1], body) else null,
        };
    }

    const Context = struct {
        pub fn hash(_: @This(), key: MatchKey) u64 {
            const hashes = [2]u64{
                if (key.previous) |block| block.hash() else 0,
                if (key.following) |block| block.hash() else 0,
            };
            return std.hash.Wyhash.hash(key.current.hash(), std.mem.asBytes(&hashes));
        }

        pub fn eql(_: @This(), a: MatchKey, b: MatchKey) bool {
            return a.current.eql(b.current) and
                BlockText.eqlOptional(a.previous, b.previous) and BlockText.eqlOptional(a.following, b.following);
        }
    };
};

/// Map each new block to at most one old block with the same kind and bytes.
/// Prefer the shared prefix and suffix, then blocks with unchanged neighbors.
/// The remaining repeated blocks are consumed in old-document order.
pub fn matchBlocks(allocator: std.mem.Allocator, old_body: []const u8, old_blocks: []const Block, new_body: []const u8, new_blocks: []const Block) ![]?usize {
    const matches = try allocator.alloc(?usize, new_blocks.len);
    errdefer allocator.free(matches);
    @memset(matches, null);

    var first: usize = 0;
    while (first < @min(old_blocks.len, new_blocks.len)) : (first += 1) {
        if (!BlockText.of(old_blocks[first], old_body).eql(.of(new_blocks[first], new_body))) break;
        matches[first] = first;
    }
    var old_end = old_blocks.len;
    var new_end = new_blocks.len;
    while (old_end > first and new_end > first) {
        if (!BlockText.of(old_blocks[old_end - 1], old_body).eql(.of(new_blocks[new_end - 1], new_body))) break;
        old_end -= 1;
        new_end -= 1;
        matches[new_end] = old_end;
    }
    if (old_end == first or new_end == first) return matches;

    // One linked occurrence list per exact key. Traverse the old range in
    // reverse to build ascending queues without an allocation per key.
    const next = try allocator.alloc(?usize, old_end - first);
    defer allocator.free(next);
    const used = try allocator.alloc(bool, old_end - first);
    defer allocator.free(used);
    @memset(used, false);
    var heads: std.HashMapUnmanaged(MatchKey, ?usize, MatchKey.Context, std.hash_map.default_max_load_percentage) = .empty;
    defer heads.deinit(allocator);
    for ([_]bool{ true, false }) |anchored| {
        var index = old_end;
        while (index > first) {
            index -= 1;
            if (used[index - first]) continue;
            const entry = try heads.getOrPut(allocator, MatchKey.of(old_body, old_blocks, index, anchored));
            next[index - first] = if (entry.found_existing) entry.value_ptr.* else null;
            entry.value_ptr.* = index;
        }
        for (matches[first..new_end], first..) |*match, new_index| {
            if (match.* != null) continue;
            const head = heads.getPtr(MatchKey.of(new_body, new_blocks, new_index, anchored)) orelse continue;
            const old_index = head.* orelse continue;
            match.* = old_index;
            used[old_index - first] = true;
            head.* = next[old_index - first];
        }
        heads.clearRetainingCapacity();
    }
    return matches;
}

pub fn replace(allocator: std.mem.Allocator, body: []const u8, range: Block, replacement: []const u8) ![]u8 {
    if (range.start > range.end or range.end > body.len) return error.InvalidBlockRange;
    return std.mem.concat(allocator, u8, &.{ body[0..range.start], replacement, body[range.end..] });
}

/// A rendered inline link `[label](url)`. All ranges are byte offsets into
/// the same body, `end` points one past the closing paren.
pub const LinkSpan = struct {
    start: usize,
    end: usize,
    url_start: usize,
    url_end: usize,

    pub fn url(self: LinkSpan, body: []const u8) []const u8 {
        return body[self.url_start..self.url_end];
    }
};

fn escapedAt(text: []const u8, index: usize) bool {
    var backslashes: usize = 0;
    var i = index;
    while (i > 0 and text[i - 1] == '\\') : (i -= 1) backslashes += 1;
    return backslashes % 2 == 1;
}

fn matchingClose(text: []const u8, open: usize, open_char: u8, close_char: u8) ?usize {
    var depth: usize = 0;
    var i = open;
    while (i < text.len) : (i += 1) {
        const c = text[i];
        if (c == '\n') return null;
        if (c == '\\' and i + 1 < text.len) {
            i += 1;
            continue;
        }
        if (c == open_char) depth += 1 else if (c == close_char) {
            depth -= 1;
            if (depth == 0) return i;
        }
    }
    return null;
}

/// Locate the innermost `[label](url)` link whose bytes contain `offset`.
/// Mirrors the read renderer: links never span a line break and the URL must
/// stay clear of whitespace. Images (`![alt](url)`) are excluded; the image
/// viewer already handles those.
pub fn findLinkAt(text: []const u8, offset: usize) ?LinkSpan {
    var scan = @min(offset + 1, text.len);
    while (scan > 0) {
        scan -= 1;
        if (text[scan] != '[' or (scan > 0 and text[scan - 1] == '!') or escapedAt(text, scan)) continue;
        const close = matchingClose(text, scan, '[', ']') orelse continue;
        if (close + 1 >= text.len or text[close + 1] != '(') continue;
        const paren = matchingClose(text, close + 1, '(', ')') orelse continue;
        if (offset < scan or offset > paren) continue;
        const url = text[close + 2 .. paren];
        if (std.mem.indexOfAny(u8, url, " \t\r\n") != null) continue;
        return .{ .start = scan, .end = paren + 1, .url_start = close + 2, .url_end = paren };
    }
    return null;
}

/// The offset of the check-state byte in a task list line whose `- ` marker
/// starts at `marker_start` (expects `[ ]`, `[x]` or `[X]` directly after the
/// marker), or null when the line is not a task item.
pub fn taskStateOffset(body: []const u8, marker_start: usize) ?usize {
    if (marker_start + 5 >= body.len) return null;
    if (body[marker_start] != '-' or body[marker_start + 1] != ' ') return null;
    if (body[marker_start + 2] != '[' or body[marker_start + 4] != ']') return null;
    if (body[marker_start + 5] != ' ') return null;
    return switch (body[marker_start + 3]) {
        ' ', 'x', 'X' => marker_start + 3,
        else => null,
    };
}

/// Toggle an inline emphasis mark (`**`, `*`, `~~` or other exact pairs)
/// around `[start, end)` of `body`. When the range is already delimited by
/// `mark` the delimiters are removed instead. The result keeps the selection
/// inside the marks so repeated invocations round-trip.
pub const MarkToggle = struct {
    body: []u8,
    // Selection in the returned body, pointing at the wrapped text.
    start: usize,
    end: usize,
};

pub fn toggleInlineMark(allocator: std.mem.Allocator, body: []const u8, start: usize, end: usize, mark: []const u8) !MarkToggle {
    const lo = @min(start, end);
    const hi = @max(start, end);
    if (mark.len == 0) return error.InvalidMark;
    if (lo > hi or hi > body.len) return error.InvalidRange;
    // Already marked: strip the delimiters.
    if (lo >= mark.len and hi + mark.len <= body.len and
        std.mem.eql(u8, body[lo - mark.len .. lo], mark) and
        std.mem.eql(u8, body[hi .. hi + mark.len], mark))
    {
        const next = try std.mem.concat(allocator, u8, &.{ body[0 .. lo - mark.len], body[lo..hi], body[hi + mark.len ..] });
        return .{ .body = next, .start = lo - mark.len, .end = hi - mark.len };
    }
    const next = try std.mem.concat(allocator, u8, &.{ body[0..lo], mark, body[lo..hi], mark, body[hi..] });
    return .{ .body = next, .start = lo + mark.len, .end = hi + mark.len };
}

/// Wrap `[start, end)` as `[label](url)`. A non-empty selection becomes the
/// label; an empty selection inserts `[](url)` and selects the label slot.
pub const LinkEdit = struct {
    body: []u8,
    start: usize,
    end: usize,
};

pub fn insertLink(allocator: std.mem.Allocator, body: []const u8, start: usize, end: usize, url: []const u8) !LinkEdit {
    const lo = @min(start, end);
    const hi = @max(start, end);
    if (lo > hi or hi > body.len) return error.InvalidRange;
    const label = body[lo..hi];
    var result = std.ArrayList(u8).empty;
    errdefer result.deinit(allocator);
    try result.appendSlice(allocator, body[0..lo]);
    try result.appendSlice(allocator, "[");
    const label_start = result.items.len;
    try result.appendSlice(allocator, label);
    const label_end = result.items.len;
    try result.appendSlice(allocator, "](");
    try result.appendSlice(allocator, url);
    try result.appendSlice(allocator, ")");
    try result.appendSlice(allocator, body[hi..]);
    return .{ .body = try result.toOwnedSlice(allocator), .start = label_start, .end = label_end };
}

/// Inline emphasis marks the editor can toggle around a selection.
pub const InlineMark = enum { bold, italic, strikethrough, code };

pub fn markString(mark: InlineMark) []const u8 {
    return switch (mark) {
        .bold => "**",
        .italic => "*",
        .strikethrough => "~~",
        .code => "`",
    };
}

/// Range-replacement toggle edit. Instead of rebuilding the whole body the
/// result describes the single slice to replace, which lets callers feed it to
/// a textarea's `replaceRangeChecked(start, end, replacement)` and keep undo
/// history intact.
pub const MarkEdit = struct {
    // Replacement range start, in the original body.
    start: usize,
    // Replacement range end, in the original body.
    end: usize,
    // Replacement text (may embed the wrapped selection).
    replacement: []u8,
    // Caret/selection start after applying, as an offset into `replacement`.
    sel_start: usize,
    sel_end: usize,
};

pub fn toggleInlineMarkEdit(allocator: std.mem.Allocator, body: []const u8, start: usize, end: usize, mark: InlineMark) !MarkEdit {
    const m = markString(mark);
    const lo = @min(start, end);
    const hi = @max(start, end);
    if (hi > body.len) return error.InvalidRange;
    // Already wrapped in the same mark: strip it.
    if (lo >= m.len and hi + m.len <= body.len and
        std.mem.eql(u8, body[lo - m.len .. lo], m) and
        std.mem.eql(u8, body[hi .. hi + m.len], m))
    {
        const inner = try allocator.dupe(u8, body[lo..hi]);
        return .{
            .start = lo - m.len,
            .end = hi + m.len,
            .replacement = inner,
            .sel_start = 0,
            .sel_end = inner.len,
        };
    }
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);
    try buf.appendSlice(allocator, m);
    try buf.appendSlice(allocator, body[lo..hi]);
    try buf.appendSlice(allocator, m);
    return .{
        .start = lo,
        .end = hi,
        .replacement = try buf.toOwnedSlice(allocator),
        .sel_start = m.len,
        .sel_end = m.len + (hi - lo),
    };
}

/// Range-replacement link edit, mirroring `insertLink` without rebuilding the
/// body. The selection offsets point into `replacement` at the label slot.
pub const LinkEditRange = struct {
    start: usize,
    end: usize,
    replacement: []u8,
    sel_start: usize,
    sel_end: usize,
};

pub fn insertLinkEdit(allocator: std.mem.Allocator, body: []const u8, start: usize, end: usize, url: []const u8) !LinkEditRange {
    const lo = @min(start, end);
    const hi = @max(start, end);
    if (hi > body.len) return error.InvalidRange;
    const label = body[lo..hi];
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);
    try buf.appendSlice(allocator, "[");
    const label_start = buf.items.len;
    try buf.appendSlice(allocator, label);
    const label_end = buf.items.len;
    try buf.appendSlice(allocator, "](");
    try buf.appendSlice(allocator, url);
    try buf.appendSlice(allocator, ")");
    return .{
        .start = lo,
        .end = hi,
        .replacement = try buf.toOwnedSlice(allocator),
        .sel_start = label_start,
        .sel_end = label_end,
    };
}

/// Byte range of a table cell's text within the block's `text(body)` slice.
pub const TableCell = struct { start: usize, end: usize };

/// Parse a table block's text into a row-major matrix of cell ranges. Rows
/// are split on newlines; each line is cut on `|` after dropping the leading
/// and trailing pipes, and cell text is trimmed of surrounding spaces. The
/// separator row is kept as a row so callers can skip it when rendering. All
/// ranges index into `table_text` itself; no per-cell copies are made.
pub fn parseTableCells(allocator: std.mem.Allocator, table_text: []const u8) ![][]TableCell {
    var rows: std.ArrayList([]TableCell) = .empty;
    errdefer {
        for (rows.items) |row| allocator.free(row);
        rows.deinit(allocator);
    }
    var line_start: usize = 0;
    while (line_start <= table_text.len) {
        const line_end = std.mem.indexOfScalarPos(u8, table_text, line_start, '\n') orelse table_text.len;
        const line = table_text[line_start..line_end];
        var cells: std.ArrayList(TableCell) = .empty;
        errdefer cells.deinit(allocator);
        var cell_start: usize = 0;
        if (line.len > 0 and line[0] == '|') cell_start = 1;
        const scan_end = if (line.len > 0 and line[line.len - 1] == '|' and line.len > cell_start) line.len - 1 else line.len;
        var i: usize = cell_start;
        while (i <= scan_end) : (i += 1) {
            if (i == scan_end or line[i] == '|') {
                var s = cell_start;
                var e = i;
                while (s < e and line[s] == ' ') s += 1;
                while (e > s and line[e - 1] == ' ') e -= 1;
                try cells.append(allocator, .{ .start = line_start + s, .end = line_start + e });
                cell_start = i + 1;
            }
        }
        try rows.append(allocator, try cells.toOwnedSlice(allocator));
        if (line_end == table_text.len) break;
        line_start = line_end + 1;
    }
    return rows.toOwnedSlice(allocator);
}

test "notes inline mark toggle wraps unwrapped selections and strips marked ones" {
    const allocator = std.testing.allocator;
    const body = "前 plain 后";
    const wrapped = try toggleInlineMark(allocator, body, 4, 9, "**");
    defer allocator.free(wrapped.body);
    try std.testing.expectEqualStrings("前 **plain** 后", wrapped.body);
    try std.testing.expectEqual(@as(usize, 6), wrapped.start);
    try std.testing.expectEqual(@as(usize, 11), wrapped.end);
    const stripped = try toggleInlineMark(allocator, wrapped.body, wrapped.start, wrapped.end, "**");
    defer allocator.free(stripped.body);
    try std.testing.expectEqualStrings(body, stripped.body);
    try std.testing.expectEqual(@as(usize, 4), stripped.start);
    try std.testing.expectEqual(@as(usize, 9), stripped.end);
}

test "notes link insert wraps selection as label and points selection at label slot" {
    const allocator = std.testing.allocator;
    const body = "看 这里 继续";
    // 「这里」占字节 4..10（每字 3 字节）；选区按字节偏移，不按字符数。
    const linked = try insertLink(allocator, body, 4, 10, "https://example.com");
    defer allocator.free(linked.body);
    try std.testing.expectEqualStrings("看 [这里](https://example.com) 继续", linked.body);
    try std.testing.expectEqual(@as(usize, 5), linked.start);
    try std.testing.expectEqual(@as(usize, 11), linked.end);
    const caret_only = try insertLink(allocator, body, 4, 4, "https://example.com");
    defer allocator.free(caret_only.body);
    // 原空格在插入点之前，插入选区后紧跟「这里」。
    try std.testing.expectEqualStrings("看 [](https://example.com)这里 继续", caret_only.body);
    try std.testing.expectEqual(@as(usize, 5), caret_only.start);
    try std.testing.expectEqual(@as(usize, 5), caret_only.end);
}

test "notes link finder resolves innermost spans and rejects images and wrapped urls" {
    const body = "pre [doc](https://example.com/a) mid ![pic](img.png) tail [deep [nest]](https://example.com/b) end";
    const first = findLinkAt(body, std.mem.indexOf(u8, body, "doc").? + 1).?;
    try std.testing.expectEqual(@as(usize, 4), first.start);
    try std.testing.expectEqualStrings("https://example.com/a", first.url(body));
    try std.testing.expect(std.mem.eql(u8, body[first.start..first.end], "[doc](https://example.com/a)"));
    // 「[nest]」不带自己的 (url)，不是链接；命中其中的字节解析到
    // 包住它的最内层真实链接 [deep [nest]](…)。
    const nested = findLinkAt(body, std.mem.indexOf(u8, body, "nest").? + 1).?;
    try std.testing.expectEqualStrings("https://example.com/b", nested.url(body));
    try std.testing.expect(std.mem.startsWith(u8, body[nested.start..], "[deep [nest]]"));
    // 命中外层标签其他位置得到同一个 span。
    const outer = findLinkAt(body, std.mem.indexOf(u8, body, "deep").? + 1).?;
    try std.testing.expectEqualStrings("https://example.com/b", outer.url(body));
    try std.testing.expect(std.mem.startsWith(u8, body[outer.start..], "[deep [nest]]"));
    // Image syntax is not a link.
    const image = findLinkAt(body, std.mem.indexOf(u8, body, "pic").?);
    try std.testing.expect(image == null);
    // Escaped open bracket is literal text.
    const escaped = findLinkAt("\\[not](x)", 2);
    try std.testing.expect(escaped == null);
    // Whitespace inside the url is not a link.
    const spaced = findLinkAt("[bad](a b)", 5);
    try std.testing.expect(spaced == null);
}

test "notes task state offset reads check byte of task lines only" {
    const body = "- [ ] open\n- [x] done\n- [X] loud\n- plain\n-[ ]tight";
    // 偏移按字节计：三条 task 行的标记分别在 0、11、22，状态字节是标记后第 3 字节。
    try std.testing.expectEqual(@as(usize, 3), taskStateOffset(body, 0).?);
    try std.testing.expectEqual(@as(usize, 14), taskStateOffset(body, 11).?);
    try std.testing.expectEqual(@as(usize, 25), taskStateOffset(body, 22).?);
    // 「- plain」不是 task 项；「-[ ]tight」的 - 后没有空格。
    try std.testing.expect(taskStateOffset(body, 33) == null);
    try std.testing.expect(taskStateOffset(body, 41) == null);
}

test "notes blocks preserve UTF-8 byte ranges and fence boundaries" {
    const source = "\n# 标题\n说明 **粗体**\n\n```zig\n\nconst a = 1;\n````\n\n正文\n\n```\n未闭合\n";
    const parsed = try blocks(std.testing.allocator, source);
    defer std.testing.allocator.free(parsed);
    try std.testing.expectEqual(@as(usize, 5), parsed.len);
    try std.testing.expectEqualStrings("# 标题", parsed[0].text(source));
    try std.testing.expectEqualStrings("说明 **粗体**", parsed[1].text(source));
    try std.testing.expectEqualStrings("```zig\n\nconst a = 1;\n````", parsed[2].text(source));
    try std.testing.expectEqual(.text, parsed[3].kind);
    try std.testing.expectEqual(.raw, parsed[4].kind);
    const edited = try replace(std.testing.allocator, source, parsed[3], "改写\n\n新段落");
    defer std.testing.allocator.free(edited);
    try std.testing.expectEqualStrings("\n# 标题\n说明 **粗体**\n\n```zig\n\nconst a = 1;\n````\n\n改写\n\n新段落\n\n```\n未闭合\n", edited);
}

test "notes incremental parse agrees with full parsing around fences and separators" {
    const allocator = std.testing.allocator;
    const original = "\n# heading\nparagraph\n\n```zig\ncode\n```\n\n![image](asset)\n\nlast\n";
    const old_blocks = try blocks(allocator, original);
    defer allocator.free(old_blocks);
    for (0..original.len + 1) |start| {
        for ([_][]const u8{ "", "x", "\n\n", "\n~~~\n" }) |replacement| {
            const end = @min(start + 1, original.len);
            const edited = try std.mem.concat(allocator, u8, &.{ original[0..start], replacement, original[end..] });
            defer allocator.free(edited);
            const actual = try reparseBlocks(allocator, original, old_blocks, edited);
            defer allocator.free(actual);
            const expected = try blocks(allocator, edited);
            defer allocator.free(expected);
            try std.testing.expectEqualSlices(Block, expected, actual);
        }
    }
}

test "notes block matching anchors shifted suffixes and consumes duplicate identities once" {
    const allocator = std.testing.allocator;
    const original = "前缀\n\n甲\n\n重复\n\n乙\n\n重复\n\n末尾\n\n收尾";
    const edited = "前缀\n\n改写乙\n\n重复\n\n甲\n\n重复\n\n重复\n\n收尾";
    const old_blocks = try blocks(allocator, original);
    defer allocator.free(old_blocks);
    const new_blocks = try reparseBlocks(allocator, original, old_blocks, edited);
    defer allocator.free(new_blocks);
    const matches = try matchBlocks(allocator, original, old_blocks, edited, new_blocks);
    defer allocator.free(matches);
    try std.testing.expectEqualSlices(?usize, &.{ 0, null, 2, 1, 4, null, 6 }, matches);
}

test "notes block matching distinguishes identical bytes with different kinds" {
    const allocator = std.testing.allocator;
    const body = "同样";
    const original: Block = .{ .start = 0, .end = body.len, .kind = .raw };
    const edited: Block = .{ .start = 0, .end = body.len, .kind = .markdown };
    const matches = try matchBlocks(allocator, body, &.{original}, body, &.{edited});
    defer allocator.free(matches);
    try std.testing.expectEqualSlices(?usize, &.{null}, matches);
}

test "notes block matching keeps repeated text with moved neighboring blocks" {
    const allocator = std.testing.allocator;
    const original = "start\n\nA\n\nrepeat\n\nB\n\nC\n\nrepeat\n\nD\n\nend";
    const edited = "start\n\nC\n\nrepeat\n\nD\n\nA\n\nrepeat\n\nB\n\nend";
    const old_blocks = try blocks(allocator, original);
    defer allocator.free(old_blocks);
    const new_blocks = try reparseBlocks(allocator, original, old_blocks, edited);
    defer allocator.free(new_blocks);
    const matches = try matchBlocks(allocator, original, old_blocks, edited, new_blocks);
    defer allocator.free(matches);
    try std.testing.expectEqualSlices(?usize, &.{ 0, 4, 5, 6, 1, 2, 3, 7 }, matches);
}

test "notes inline mark edit wraps selection and strips wrapped marks" {
    const allocator = std.testing.allocator;
    const body = "前 plain 后";

    const bold = try toggleInlineMarkEdit(allocator, body, 4, 9, .bold);
    defer allocator.free(bold.replacement);
    try std.testing.expectEqual(@as(usize, 4), bold.start);
    try std.testing.expectEqual(@as(usize, 9), bold.end);
    try std.testing.expectEqualStrings("**plain**", bold.replacement);
    try std.testing.expectEqual(@as(usize, 2), bold.sel_start);
    try std.testing.expectEqual(@as(usize, 7), bold.sel_end);

    const italic = try toggleInlineMarkEdit(allocator, body, 4, 9, .italic);
    defer allocator.free(italic.replacement);
    try std.testing.expectEqualStrings("*plain*", italic.replacement);
    try std.testing.expectEqual(@as(usize, 1), italic.sel_start);
    try std.testing.expectEqual(@as(usize, 6), italic.sel_end);

    // 已被 ** 包裹：剥掉标记，替换区间含两侧的 **。
    const marked = "前 **plain** 后";
    const stripped = try toggleInlineMarkEdit(allocator, marked, 6, 11, .bold);
    defer allocator.free(stripped.replacement);
    try std.testing.expectEqual(@as(usize, 4), stripped.start);
    try std.testing.expectEqual(@as(usize, 13), stripped.end);
    try std.testing.expectEqualStrings("plain", stripped.replacement);
    try std.testing.expectEqual(@as(usize, 0), stripped.sel_start);
    try std.testing.expectEqual(@as(usize, 5), stripped.sel_end);

    // 单星号文本对 .bold 不算已包裹，会再裹一层 **；对 .italic 才能剥掉。
    const italic_marked = "前 *plain* 后";
    const stripped_i = try toggleInlineMarkEdit(allocator, italic_marked, 5, 10, .italic);
    defer allocator.free(stripped_i.replacement);
    try std.testing.expectEqual(@as(usize, 4), stripped_i.start);
    try std.testing.expectEqual(@as(usize, 11), stripped_i.end);
    try std.testing.expectEqualStrings("plain", stripped_i.replacement);
    const wrapped_b = try toggleInlineMarkEdit(allocator, italic_marked, 5, 10, .bold);
    defer allocator.free(wrapped_b.replacement);
    try std.testing.expectEqualStrings("**plain**", wrapped_b.replacement);
    try std.testing.expectEqual(@as(usize, 5), wrapped_b.start);
    try std.testing.expectEqual(@as(usize, 10), wrapped_b.end);
}

test "notes link edit wraps selection as label and selects label slot when empty" {
    const allocator = std.testing.allocator;
    const body = "看 这里 继续";

    const linked = try insertLinkEdit(allocator, body, 4, 10, "https://example.com");
    defer allocator.free(linked.replacement);
    try std.testing.expectEqual(@as(usize, 4), linked.start);
    try std.testing.expectEqual(@as(usize, 10), linked.end);
    try std.testing.expectEqualStrings("[这里](https://example.com)", linked.replacement);
    try std.testing.expectEqual(@as(usize, 1), linked.sel_start);
    try std.testing.expectEqual(@as(usize, 7), linked.sel_end);
    try std.testing.expectEqualStrings("这里", linked.replacement[linked.sel_start..linked.sel_end]);

    const caret_only = try insertLinkEdit(allocator, body, 4, 4, "https://example.com");
    defer allocator.free(caret_only.replacement);
    try std.testing.expectEqual(@as(usize, 4), caret_only.start);
    try std.testing.expectEqual(@as(usize, 4), caret_only.end);
    try std.testing.expectEqualStrings("[](https://example.com)", caret_only.replacement);
    try std.testing.expectEqual(@as(usize, 1), caret_only.sel_start);
    try std.testing.expectEqual(@as(usize, 1), caret_only.sel_end);
}

test "notes blocks recognize table blocks and keep paragraphs with pipes as markdown" {
    const allocator = std.testing.allocator;
    const source = "| 名称 | 值 |\n| --- | ---: |\n| a | 1 |\n| b | 2 |\n\n后段 **粗体**\n\n行内 a | b 不是表格\n只有一行\n";
    const parsed = try blocks(allocator, source);
    defer allocator.free(parsed);
    try std.testing.expectEqual(@as(usize, 3), parsed.len);
    try std.testing.expectEqual(.table, parsed[0].kind);
    try std.testing.expectEqualStrings("| 名称 | 值 |\n| --- | ---: |\n| a | 1 |\n| b | 2 |", parsed[0].text(source));
    try std.testing.expectEqual(.markdown, parsed[1].kind);
    // 含 | 但下一行不是分隔行的段落不判为表格。
    try std.testing.expect(parsed[2].kind != .table);
    try std.testing.expectEqualStrings("行内 a | b 不是表格\n只有一行", parsed[2].text(source));
}

test "notes table cells parse rows with trimmed ranges and keep separator row" {
    const allocator = std.testing.allocator;
    const text = "| 名称 | 值 |\n| --- | ---: |\n| a | 1 |";
    const rows = try parseTableCells(allocator, text);
    defer {
        for (rows) |row| allocator.free(row);
        allocator.free(rows);
    }
    try std.testing.expectEqual(@as(usize, 3), rows.len);
    for (rows) |row| try std.testing.expectEqual(@as(usize, 2), row.len);

    try std.testing.expectEqualStrings("名称", text[rows[0][0].start..rows[0][0].end]);
    try std.testing.expectEqualStrings("值", text[rows[0][1].start..rows[0][1].end]);
    try std.testing.expectEqualStrings("---", text[rows[1][0].start..rows[1][0].end]);
    try std.testing.expectEqualStrings("---:", text[rows[1][1].start..rows[1][1].end]);
    try std.testing.expectEqualStrings("a", text[rows[2][0].start..rows[2][0].end]);
    try std.testing.expectEqualStrings("1", text[rows[2][1].start..rows[2][1].end]);
}
