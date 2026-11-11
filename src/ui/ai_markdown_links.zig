//! Link destinations for native Markdown text. Selection owns pointer routing;
//! this binding supplies byte ranges and the normal click action, without
//! splitting rich text into separate nodes or changing paragraph wrapping.
const std = @import("std");
const ui = @import("ui");
const S = @import("ai_assistant_styles.zig");
const Range = struct { start: usize, end: usize, url: []const u8 };
const Binding = struct {
    cx: *ui.Cx,
    ranges: std.ArrayList(Range) = .empty,
    armed: ?[]const u8 = null,
    opener: ?ui.Handler([]const u8) = null,
    fn release(self: *Binding) void {
        self.ranges.deinit(self.cx.allocator);
    }
    fn clicked(raw: *anyopaque) void {
        const self: *Binding = @ptrCast(@alignCast(raw));
        const url = self.armed orelse return;
        self.armed = null;
        if (self.opener) |handler| {
            handler.call(url);
            return;
        }
        // Pass a URL as one argument, never as shell text. Only browser/mail
        // destinations are activatable; other Markdown remains selectable.
        var child = std.process.spawn(self.cx.io, .{ .argv = &.{ "/usr/bin/open", "--", url } }) catch return;
        _ = child.wait(self.cx.io) catch {};
    }
};
fn binding(node: *ui.Node) ?*Binding {
    const handler = node.behavior.events.on_click orelse return null;
    if (handler.callback != Binding.clicked) return null;
    return @ptrCast(@alignCast(handler.context));
}
pub fn destination(node: *ui.Node, byte: usize) ?[]const u8 {
    const state = binding(node) orelse return null;
    for (state.ranges.items) |range| if (byte >= range.start and byte < range.end) return range.url;
    return null;
}
pub fn activate(node: *ui.Node, byte: usize) void {
    const state = binding(node) orelse return;
    state.armed = destination(node, byte) orelse return;
    node.behavior.events.on_click.?.invoke();
}
/// Also lets hosts/tests supply an opener without launching an external app.
pub fn setOpener(root: *ui.Node, opener: ui.Handler([]const u8)) void {
    if (binding(root)) |state| state.opener = opener;
    for (root.children.items) |child| setOpener(child, opener);
}
fn safeDestination(url: []const u8) bool {
    const colon = std.mem.indexOfScalar(u8, url, ':') orelse return false;
    for (url) |c| if (c < 0x20 or c == 0x7f) return false;
    for ([_][]const u8{ "http", "https", "mailto" }) |scheme| if (std.ascii.eqlIgnoreCase(url[0..colon], scheme)) return true;
    return false;
}
fn matching(raw: []const u8, start: usize, open: u8, close: u8) ?usize {
    var depth: usize = 1;
    var i = start;
    while (i < raw.len) : (i += 1) {
        if (raw[i] == '\n' or raw[i] == '\r') return null;
        if (raw[i] == '\\') {
            i += @intFromBool(i + 1 < raw.len);
            continue;
        }
        if (open == '[' and raw[i] == '`') {
            var run_end = i + 1;
            while (run_end < raw.len and raw[run_end] == '`') : (run_end += 1) {}
            if (std.mem.indexOfPos(u8, raw, run_end, raw[i..run_end])) |end| {
                const line_end = std.mem.indexOfScalarPos(u8, raw, run_end, '\n') orelse raw.len;
                if (end < line_end) {
                    i = end + run_end - i - 1;
                    continue;
                }
            }
        }
        if (raw[i] == open) depth += 1;
        if (raw[i] == close) {
            depth -= 1;
            if (depth == 0) return i;
        }
    }
    return null;
}
fn collect(node: *ui.Node, allocator: std.mem.Allocator, nodes: *std.ArrayList(*ui.Node)) !void {
    if (node.getText()) |text| for (text.spans) |span| if (span.underline) {
        try nodes.append(allocator, node);
        break;
    };
    for (node.children.items) |child| try collect(child, allocator, nodes);
}
fn covered(node: *ui.Node, start: usize, end: usize) bool {
    var offset = start;
    for (node.getText().?.spans) |span| {
        if (span.start <= offset and span.end > offset and span.underline) offset = @min(end, span.end);
        if (offset == end) return true;
    }
    return false;
}
fn firstText(node: *ui.Node) ?[]const u8 {
    if (node.getText()) |text| return text.content;
    for (node.children.items) |child| if (firstText(child)) |text| return text;
    return null;
}
fn labelText(cx: *ui.Cx, parent: *ui.Scope, label: []const u8) ![]u8 {
    const scope = try parent.childScope();
    defer scope.dispose();
    const source = try std.mem.concat(cx.allocator, u8, &.{ ". ", label });
    defer cx.allocator.free(source);
    const node = try ui.widgets.Markdown(.{ .text = try scope.createText(source, .{}), .options = S.markdownOptions() }).mount(scope, cx);
    defer cx.destroyDetached(node);
    const text = firstText(node) orelse return cx.allocator.dupe(u8, label);
    return cx.allocator.dupe(u8, text[@min(2, text.len)..]);
}
pub fn bind(cx: *ui.Cx, scope: *ui.Scope, root: *ui.Node, source: []const u8) !void {
    if (std.mem.indexOf(u8, source, "](") == null) return;
    var nodes: std.ArrayList(*ui.Node) = .empty;
    defer nodes.deinit(cx.allocator);
    try collect(root, cx.allocator, &nodes);
    var node_index: usize = 0;
    var byte_offset: usize = 0;
    var i: usize = 0;
    while (i < source.len) : (i += 1) {
        if (source[i] == '\\') {
            i += @intFromBool(i + 1 < source.len);
            continue;
        }
        if (source[i] == '`') {
            var run_end = i + 1;
            while (run_end < source.len and source[run_end] == '`') : (run_end += 1) {}
            if (std.mem.indexOfPos(u8, source, run_end, source[i..run_end])) |end| {
                const line_end = std.mem.indexOfScalarPos(u8, source, run_end, '\n') orelse source.len;
                if (end < line_end) {
                    i = end + run_end - i - 1;
                    continue;
                }
            }
        }
        if (source[i] != '[') continue;
        const label_end = matching(source, i + 1, '[', ']') orelse continue;
        if (label_end + 1 >= source.len or source[label_end + 1] != '(') continue;
        const url_end = matching(source, label_end + 2, '(', ')') orelse continue;
        const image = i > 0 and source[i - 1] == '!';
        const label = source[i + 1 .. label_end];
        const url = std.mem.trim(u8, source[label_end + 2 .. url_end], " \t");
        i = url_end;
        if (image) continue;
        const display = try labelText(cx, scope, label);
        defer cx.allocator.free(display);
        if (display.len == 0) continue;
        while (node_index < nodes.items.len) : (node_index += 1) {
            const node = nodes.items[node_index];
            const text = node.getText().?.content;
            var offset = byte_offset;
            byte_offset = 0;
            var found: ?usize = null;
            while (std.mem.indexOfPos(u8, text, offset, display)) |start| {
                if (covered(node, start, start + display.len)) {
                    found = start;
                    break;
                }
                offset = start + 1;
            }
            if (found) |start| {
                byte_offset = start + display.len;
                if (safeDestination(url)) {
                    const state = binding(node) orelse blk: {
                        const value = try scope.createState(Binding, .{ .cx = cx });
                        try scope.onCleanup(Binding, value, Binding.release);
                        node.behavior.events.on_click = .{ .callback = Binding.clicked, .context = value };
                        break :blk value;
                    };
                    const owned_url = try scope.createText(url, .{});
                    try state.ranges.append(cx.allocator, .{ .start = start, .end = byte_offset, .url = owned_url.peek() });
                }
                break;
            }
        }
    }
}
