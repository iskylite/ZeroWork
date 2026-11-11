//! Container boundaries shared by completed and streamed AI Markdown.
const std = @import("std");

pub const Marker = struct { indent: usize, content: usize, label: []const u8 };
pub fn indent(line: []const u8) usize {
    var n: usize = 0;
    while (n < line.len and line[n] == ' ') : (n += 1) {}
    return n;
}
pub fn listMarker(line: []const u8) ?Marker {
    const leading = indent(line);
    if (leading > 3 or leading >= line.len) return null;
    var end = leading;
    if (line[end] == '-' or line[end] == '*' or line[end] == '+') {
        end += 1;
    } else {
        while (end < line.len and std.ascii.isDigit(line[end]) and end - leading < 9) : (end += 1) {}
        if (end == leading or end >= line.len or (line[end] != '.' and line[end] != ')')) return null;
        end += 1;
    }
    if (end >= line.len or (line[end] != ' ' and line[end] != '\t')) return null;
    const label = line[leading..end];
    var content = end + 1;
    while (content < line.len and content - end < 4 and line[content] == ' ') : (content += 1) {}
    return .{ .indent = leading, .content = content, .label = label };
}
pub fn quoteContent(line: []const u8) ?[]const u8 {
    const leading = indent(line);
    if (leading > 3 or leading >= line.len or line[leading] != '>') return null;
    const start = leading + 1;
    return line[start + @as(usize, if (start < line.len and line[start] == ' ') 1 else 0) ..];
}
pub fn isRule(line: []const u8) bool {
    const t = std.mem.trim(u8, line, " \t\r");
    if (t.len < 3 or (t[0] != '-' and t[0] != '*' and t[0] != '_')) return false;
    var count: usize = 0;
    for (t) |c| {
        if (c == t[0]) count += 1 else if (c != ' ' and c != '\t') return false;
    }
    return count >= 3;
}
pub fn containerEnd(lines: []const []const u8, start: usize) usize {
    if (quoteContent(lines[start]) != null) {
        var end = start + 1;
        while (end < lines.len and quoteContent(lines[end]) != null) : (end += 1) {}
        return end;
    }
    if (isRule(lines[start])) return start;
    const marker = listMarker(lines[start]) orelse return start;
    var end = start + 1;
    while (end < lines.len) : (end += 1) {
        const line = lines[end];
        if (std.mem.trim(u8, line, " \t\r").len != 0 and indent(line) < marker.content) break;
    }
    return end;
}
pub fn containerSource(allocator: std.mem.Allocator, lines: []const []const u8) ![]u8 {
    var result: std.ArrayList(u8) = .empty;
    errdefer result.deinit(allocator);
    const marker = listMarker(lines[0]);
    for (lines, 0..) |line, index| {
        if (index != 0) try result.append(allocator, '\n');
        const content = if (quoteContent(lines[0]) != null) quoteContent(line).? else if (index == 0) line[marker.?.content..] else line[@min(indent(line), marker.?.content)..];
        try result.appendSlice(allocator, content);
    }
    return result.toOwnedSlice(allocator);
}
/// Byte boundary used by Retained so blanks inside list items do not split them.
pub fn sourceEnd(source: []const u8, start: usize) usize {
    const first_end = std.mem.indexOfScalarPos(u8, source, start, '\n') orelse source.len;
    const first = source[start..first_end];
    const quoted = quoteContent(first) != null;
    if (isRule(first)) return start;
    const marker = listMarker(first);
    if (!quoted and marker == null) return start;
    var offset = @min(source.len, first_end + 1);
    while (offset < source.len) {
        const end = std.mem.indexOfScalarPos(u8, source, offset, '\n') orelse source.len;
        const line = source[offset..end];
        if (quoted) {
            if (quoteContent(line) == null) break;
        } else if (std.mem.trim(u8, line, " \t\r").len != 0 and indent(line) < marker.?.content) break;
        offset = @min(source.len, end + 1);
    }
    return offset;
}
