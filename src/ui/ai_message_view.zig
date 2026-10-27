//! Presentation-only Markdown: compact headings and bounded code scrolling.
const ui = @import("ui");
const std = @import("std");
const S = @import("ai_assistant_styles.zig");
pub fn mount(cx: *ui.Cx, scope: *ui.Scope, value: []const u8) !*ui.Node {
    return mountWithWidth(cx, scope, value, 540);
}
pub fn mountWithWidth(cx: *ui.Cx, scope: *ui.Scope, value: []const u8, width: f32) !*ui.Node {
    const prepared = try preserveCodeLines(cx.allocator, value);
    defer cx.allocator.free(prepared);
    const root = try ui.box(cx, S.assistantMessage(), .{});
    var lines: std.ArrayList([]const u8) = .empty;
    defer lines.deinit(cx.allocator);
    var iterator = std.mem.splitScalar(u8, prepared, '\n');
    while (iterator.next()) |line| try lines.append(cx.allocator, line);
    var start: usize = 0;
    var i: usize = 0;
    var fenced = false;
    while (i + 1 < lines.items.len) : (i += 1) {
        const trimmed = std.mem.trim(u8, lines.items[i], " \t\r");
        if (std.mem.startsWith(u8, trimmed, "```") or std.mem.startsWith(u8, trimmed, "~~~")) fenced = !fenced;
        if (fenced or std.mem.indexOfScalar(u8, trimmed, '|') == null or !tableSeparator(lines.items[i + 1])) continue;
        try appendMarkdown(cx, scope, root, lines.items[start..i]);
        var end = i + 2;
        while (end < lines.items.len and std.mem.indexOfScalar(u8, lines.items[end], '|') != null and std.mem.trim(u8, lines.items[end], " \t\r").len != 0) : (end += 1) {}
        try appendTable(cx, scope, root, lines.items[i..end], width);
        i = end - 1;
        start = end;
    }
    try appendMarkdown(cx, scope, root, lines.items[start..]);
    return root;
}
fn appendMarkdown(cx: *ui.Cx, scope: *ui.Scope, parent: *ui.Node, lines: []const []const u8) !void {
    if (lines.len == 0) return;
    const joined = try std.mem.join(cx.allocator, "\n", lines);
    defer cx.allocator.free(joined);
    const node = try ui.widgets.Markdown(.{ .text = try scope.createText(joined, .{}), .options = S.markdownOptions() }).mount(scope, cx);
    try compact(cx, scope, node);
    try parent.appendChild(cx.allocator, node);
}
pub fn tableSeparator(line: []const u8) bool {
    const value = std.mem.trim(u8, line, " \t\r|");
    if (value.len == 0) return false;
    var cells = std.mem.splitScalar(u8, value, '|');
    while (cells.next()) |cell| {
        const rule = std.mem.trim(u8, cell, " \t:");
        if (rule.len < 3) return false;
        for (rule) |byte| if (byte != '-') return false;
    }
    return true;
}
fn appendTable(cx: *ui.Cx, scope: *ui.Scope, parent: *ui.Node, lines: []const []const u8, width: f32) !void {
    var columns: usize = 1;
    for (std.mem.trim(u8, lines[0], " \t\r|")) |byte| if (byte == '|') {
        columns += 1;
    };
    columns = @min(columns, 16);
    const column_width = @max(120, width / @as(f32, @floatFromInt(columns)));
    var heights: std.ArrayList(f32) = .empty;
    defer heights.deinit(cx.allocator);
    var total_height: f32 = 0;
    for (lines, 0..) |line, index| {
        if (index == 1) {
            try heights.append(cx.allocator, 0);
            continue;
        }
        var cells = std.mem.splitScalar(u8, std.mem.trim(u8, line, " \t\r|"), '|');
        var height: f32 = 34;
        while (cells.next()) |cell| {
            const measured = cx.text.measureTextWidth(cell, S.body_font_size, 400, false);
            height = @max(height, @ceil(measured / (column_width - 16)) * 21 + 12);
        }
        try heights.append(cx.allocator, height);
        total_height += height;
    }
    const scroll = try ui.widgets.ScrollArea(.{ .direction = .horizontal, .height = total_height, .rubber_band_x = false }).mount(scope, cx);
    scroll.container.meta.ownership.meta.test_id = "ai.message.table";
    scroll.container.setStyleInline(cx.allocator, .{ .width = .fill(), .min_width = 0, .flex_shrink = 0 });
    scroll.content.setStyleInline(cx.allocator, .{ .width = .{ .px = @as(f32, @floatFromInt(columns)) * column_width }, .direction = .column, .flex_shrink = 0 });
    for (lines, 0..) |line, index| {
        if (index == 1) continue;
        const row_height = heights.items[index];
        const row = try ui.box(cx, .{ .width = .fill(), .height = .{ .px = row_height }, .direction = .row, .flex_shrink = 0 }, .{});
        var cells = std.mem.splitScalar(u8, std.mem.trim(u8, line, " \t\r|"), '|');
        for (0..columns) |_| {
            const cell = try ui.box(cx, .{ .width = .{ .px = column_width }, .height = .{ .px = row_height }, .padding = .{ .left = 8, .right = 8, .top = 6, .bottom = 6 }, .border = .{ .width = 1, .color = @import("app_theme.zig").current().border }, .background = if (index == 0) @import("app_theme.zig").current().well else ui.Color.TRANSPARENT, .overflow = .hidden, .flex_shrink = 0 }, .{});
            const value = std.mem.trim(u8, cells.next() orelse "", " \t\r");
            const text = try ui.widgets.Markdown(.{ .text = try scope.createText(value, .{}), .options = S.markdownOptions() }).mount(scope, cx);
            try compact(cx, scope, text);
            try cell.appendChild(cx.allocator, text);
            try row.appendChild(cx.allocator, cell);
        }
        try scroll.content.appendChild(cx.allocator, row);
    }
    try parent.appendChild(cx.allocator, scroll.container);
}

fn compact(cx: *ui.Cx, scope: *ui.Scope, node: *ui.Node) !void {
    if (node.getText()) |text| if (text.font_size > S.heading_font_size) {
        var style = text;
        style.font_size = S.heading_font_size;
        style.line_height = 18.0 / S.heading_font_size;
        node.setText(style);
    };
    // Fenced code is emitted as a well containing only monospace line nodes.
    // Preserve spaces/columns; long code scrolls without widening the float.
    const code_block = node.children.items.len > 0 and blk: {
        for (node.children.items) |child| {
            const text = child.getText() orelse break :blk false;
            if (!text.use_monospace_font) break :blk false;
        }
        break :blk true;
    };
    if (code_block) {
        const lines = node.children.items.len;
        const retained = try cx.allocator.dupe(*ui.Node, node.children.items);
        defer cx.allocator.free(retained);
        const scroll = try ui.widgets.ScrollArea(.{ .direction = .both, .rubber_band_x = false, .rubber_band_y = false, .height = @min(@as(f32, @floatFromInt(lines)) * 16 + 8, 136) }).mount(scope, cx);
        scroll.container.meta.ownership.meta.test_id = "ai.message.code.scroll";
        scroll.container.setStyleInline(cx.allocator, .{ .width = .fill(), .min_width = 0, .flex_shrink = 0 });
        scroll.content.setStyleInline(cx.allocator, .{ .direction = .column, .gap = 0, .width = .{ .fit = .{} }, .flex_shrink = 0 });
        var content_width: f32 = 1;
        for (retained) |line| {
            cx.detachChild(node, line);
            if (line.getText()) |old| {
                var text = old;
                text.wrap = .none;
                line.setText(text);
                const width = textWidth(cx, text.content, text.font_size, text.font_weight);
                content_width = @max(content_width, width);
                line.setStyleInline(cx.allocator, .{ .width = .{ .px = width }, .flex_shrink = 0 });
            }
            try scroll.content.appendChild(cx.allocator, line);
        }
        scroll.content.setStyleInline(cx.allocator, .{ .width = .{ .px = content_width } });
        try node.appendChild(cx.allocator, scroll.container);
        return;
    }
    for (node.children.items) |child| try compact(cx, scope, child);
}

// Zenit's Markdown emitter skips empty code lines. Keep a visual blank line
// in the display projection; the conversation and copy source remain original.
pub fn preserveCodeLines(allocator: std.mem.Allocator, value: []const u8) ![]u8 {
    var output: std.ArrayList(u8) = .empty;
    errdefer output.deinit(allocator);
    var lines = std.mem.splitScalar(u8, value, '\n');
    var fence: u8 = 0;
    var fence_length: usize = 0;
    var first = true;
    while (lines.next()) |line| {
        if (!first) try output.append(allocator, '\n');
        first = false;
        const trimmed = std.mem.trimStart(u8, line, " ");
        if (line.len - trimmed.len <= 3 and trimmed.len >= 3 and (trimmed[0] == '`' or trimmed[0] == '~')) {
            var count: usize = 0;
            while (count < trimmed.len and trimmed[count] == trimmed[0]) : (count += 1) {}
            if (fence == 0 and count >= 3) {
                fence = trimmed[0];
                fence_length = count;
            } else if (fence == trimmed[0] and count >= fence_length and std.mem.trim(u8, trimmed[count..], " \t\r").len == 0) {
                fence = 0;
            }
        }
        if (fence != 0 and line.len == 0) try output.append(allocator, ' ') else try output.appendSlice(allocator, line);
    }
    return output.toOwnedSlice(allocator);
}

pub fn textWidth(cx: *ui.Cx, value: []const u8, size: f32, weight: u16) f32 {
    var width: f32 = 1;
    var lines = std.mem.splitScalar(u8, value, '\n');
    while (lines.next()) |line| {
        const visual = cx.text.visualLine(.{ .text = line, .font_family = "system", .font_size = size, .font_weight = weight, .use_monospace = true }) catch {
            width = @max(width, cx.text.measureTextWidth(line, size, weight, false) * 1.25 + 1);
            continue;
        };
        width = @max(width, visual.width + 1);
    }
    return width;
}
