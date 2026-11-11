//! Exact line changes for one submitted operation, with bounded material.
const std = @import("std");

pub const Kind = enum { remove, add };
pub const Line = struct {
    kind: Kind,
    number: usize,
    text: []const u8,
};
pub const Diff = struct {
    added: ?usize = null,
    removed: ?usize = null,
    lines: []const Line = &.{},
    truncated: bool = false,
};

const max_cells = 256_000;
const max_rows = 96;
const max_bytes = 8 * 1024;
// JSON escape expansion plus line fields and the enclosing object.
pub const max_encoded_bytes = max_bytes * 6 + max_rows * 96 + 1024;

/// Lines retain their terminators so changing CRLF or the final newline is
/// reflected in the difference. Report uncomputed counts as null.
pub fn between(a: std.mem.Allocator, before: []const u8, after: []const u8) !Diff {
    if (std.mem.eql(u8, before, after)) return .{ .added = 0, .removed = 0 };
    const old = try splitLines(a, before);
    defer a.free(old);
    const new = try splitLines(a, after);
    defer a.free(new);
    var prefix: usize = 0;
    while (prefix < @min(old.len, new.len) and std.mem.eql(u8, old[prefix], new[prefix])) prefix += 1;
    var old_end = old.len;
    var new_end = new.len;
    while (old_end > prefix and new_end > prefix and std.mem.eql(u8, old[old_end - 1], new[new_end - 1])) {
        old_end -= 1;
        new_end -= 1;
    }
    const width = new_end - prefix + 1;
    const height = old_end - prefix + 1;
    if (height > max_cells / width) return .{ .truncated = true };
    const lcs = try a.alloc(u32, width * height);
    defer a.free(lcs);
    @memset(lcs, 0);
    var row = height - 1;
    while (row > 0) {
        row -= 1;
        var col = width - 1;
        while (col > 0) {
            col -= 1;
            const i = row * width + col;
            lcs[i] = if (std.mem.eql(u8, old[prefix + row], new[prefix + col]))
                1 + lcs[i + width + 1]
            else
                @max(lcs[i + 1], lcs[i + width]);
        }
    }

    var lines: std.ArrayList(Line) = .empty;
    errdefer lines.deinit(a);
    var result: Diff = .{ .added = width - 1 - lcs[0], .removed = height - 1 - lcs[0] };
    var i = prefix;
    var j = prefix;
    var bytes: usize = 0;
    while (i < old_end or j < new_end) {
        if (i < old_end and j < new_end and std.mem.eql(u8, old[i], new[j])) {
            i += 1;
            j += 1;
            continue;
        }
        const k = (i - prefix) * width + j - prefix;
        const line: Line = if (i < old_end and (j == new_end or lcs[k + width] >= lcs[k + 1])) blk: {
            i += 1;
            break :blk .{ .kind = .remove, .number = i, .text = old[i - 1] };
        } else blk: {
            j += 1;
            break :blk .{ .kind = .add, .number = j, .text = new[j - 1] };
        };
        if (lines.items.len == max_rows or line.text.len > max_bytes - bytes) {
            result.truncated = true;
            break;
        }
        try lines.append(a, line);
        bytes += line.text.len;
    }
    result.lines = try lines.toOwnedSlice(a);
    return result;
}

fn splitLines(a: std.mem.Allocator, text: []const u8) ![][]const u8 {
    var lines: std.ArrayList([]const u8) = .empty;
    errdefer lines.deinit(a);
    var start: usize = 0;
    while (start < text.len) {
        const end = if (std.mem.indexOfScalarPos(u8, text, start, '\n')) |newline| newline + 1 else text.len;
        try lines.append(a, text[start..end]);
        start = end;
    }
    return lines.toOwnedSlice(a);
}

test "disjoint edits count just the affected lines and preserve original line numbers" {
    const a = std.testing.allocator;
    const d = try between(a, "a\r\nkeep\nold\nend\n", "b\r\nkeep\nnew\nend\n");
    defer a.free(d.lines);
    try std.testing.expectEqual(@as(?usize, 2), d.added);
    try std.testing.expectEqual(@as(?usize, 2), d.removed);
    try std.testing.expectEqual(@as(usize, 3), d.lines[2].number);
    try std.testing.expectEqualStrings("a\r\n", d.lines[0].text);
}
