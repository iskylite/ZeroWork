//! Paint-only log hierarchy. The original bytes and copy/export data stay intact.
const std = @import("std");
const ui = @import("ui");
const theme = @import("app_theme.zig");
pub fn apply(cx: *ui.Cx, node: *ui.Node) !void {
    var text = node.getText() orelse return;
    const Span = @TypeOf(text.spans[0]);
    var spans: std.ArrayList(Span) = .empty;
    defer spans.deinit(cx.allocator);
    var lines = std.mem.splitScalar(u8, text.content, '\n');
    var start: usize = 0;
    while (lines.next()) |line| {
        var prefix: usize = 0;
        while (prefix < line.len and (std.ascii.isDigit(line[prefix]) or std.mem.indexOfScalar(u8, "[]:.- +T", line[prefix]) != null)) : (prefix += 1) {}
        if (prefix > 0) try spans.append(cx.allocator, .{ .start = @intCast(start), .end = @intCast(start + prefix), .color = theme.current().fg_2 });
        if (line.len > prefix and (line[0] == ' ' or line[0] == '\t')) try spans.append(cx.allocator, .{ .start = @intCast(start), .end = @intCast(start + line.len), .color = theme.current().fg_2 });
        start += line.len + 1;
    }
    const owned = try spans.toOwnedSlice(cx.allocator);
    if (text.spans_owned) cx.allocator.free(text.spans);
    text.spans = owned;
    text.spans_owned = true;
    text.spans_affect_layout = false;
    node.setText(text);
}
