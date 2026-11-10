//! Read-only message selection. Uses the same native glyph carets and wrapped
//! lines as rendering; selection overlays never alter Markdown spans or layout.
const std = @import("std");
const ui = @import("ui");
const drag = ui.interaction.drag;
const S = @import("ai_assistant_styles.zig");
const Position = struct { index: usize, byte: usize };
const Entry = struct {
    owner: *Selection,
    node: *ui.Node,
    index: usize,
    highlights: std.ArrayList(*ui.Node) = .empty,
    used: usize = 0,
    content_hash: u64 = 0,
    fn release(self: *Entry) void {
        self.highlights.deinit(self.owner.cx.allocator);
    }
};

pub fn ownsFocus(cx: *ui.Cx) bool {
    const focused = cx.focus_manager.getFocused() orelse return false;
    return focused.behavior.events.on_event == Selection.event;
}

/// Clear overlays while every referenced text node is still alive.
pub fn clear(root: *ui.Node) void {
    if (root.behavior.events.on_event != Selection.event) return;
    const self: *Selection = @ptrCast(@alignCast(root.behavior.events.event_context orelse return));
    self.anchor = null;
    self.head = null;
    self.paint() catch {};
}

pub fn attach(cx: *ui.Cx, scope: *ui.Scope, root: *ui.Node) !void {
    _ = try retained(cx, scope, root);
}
pub fn retained(cx: *ui.Cx, scope: *ui.Scope, root: *ui.Node) !*Selection {
    const generation = try cx.node_registry.trackGeneration(root);
    const self = try scope.createState(Selection, .{ .cx = cx, .root = root, .handle = .{ .id = root.id, .generation = generation } });
    try scope.onCleanup(Selection, self, Selection.release);
    try self.collect(scope, root);
    try cx.addAfterLayoutHook(self, Selection.afterLayout);
    root.setFocusable(true);
    root.behavior.events.on_event = Selection.event;
    root.behavior.events.event_context = self;
    return self;
}
pub const Selection = struct {
    cx: *ui.Cx,
    root: *ui.Node,
    handle: ui.hit.NodeHandle,
    entries: std.ArrayList(*Entry) = .empty,
    anchor: ?Position = null,
    head: ?Position = null,
    geometry: u64 = 0,

    /// New bindings belong to the chunk scope, while the selection owner stays stable.
    pub fn append(self: *Selection, scope: *ui.Scope, root: *ui.Node) !void {
        const count = self.entries.items.len;
        errdefer self.truncate(count);
        try self.collect(scope, root);
    }
    pub fn truncate(self: *Selection, count: usize) void {
        if (self.anchor != null) {
            // Clear before any removed chunk or highlight is freed.
            self.anchor = null;
            self.head = null;
            self.paint() catch {};
        }
        self.entries.shrinkRetainingCapacity(count);
    }
    fn release(self: *Selection) void {
        self.cx.removeAfterLayoutHook(self);
        if (self.cx.node_registry.resolve(self.handle, null)) |root| {
            if (root.behavior.events.event_context == @as(*anyopaque, @ptrCast(self))) {
                root.behavior.events.on_event = null;
                root.behavior.events.event_context = null;
            }
        }
        self.entries.deinit(self.cx.allocator);
    }
    fn afterLayout(raw: *anyopaque, _: u8, _: bool) ui.AfterLayoutResult {
        const self: *Selection = @ptrCast(@alignCast(raw));
        if (self.anchor == null) return .done;
        var hash = std.hash.Wyhash.init(0);
        for (self.entries.items) |entry| {
            const text = entry.node.getText() orelse continue;
            if (std.hash.Wyhash.hash(0, text.content) != entry.content_hash) {
                self.anchor = null;
                self.head = null;
                self.paint() catch {};
                return .needs_layout;
            }
            const rect = entry.node.globalRect();
            hash.update(std.mem.asBytes(&rect));
        }
        const next = hash.final();
        if (next == self.geometry) return .done;
        self.geometry = next;
        self.paint() catch {};
        return .needs_layout;
    }
    fn collect(self: *Selection, scope: *ui.Scope, node: *ui.Node) !void {
        // Controls and their labels keep their existing pointer/keyboard paths.
        if (node.behavior.interaction.focusable) return;
        if (node.getText()) |text| if (text.selectable) {
            const entry = try scope.createState(Entry, .{ .owner = self, .node = node, .index = self.entries.items.len });
            try scope.onCleanup(Entry, entry, Entry.release);
            try self.entries.append(self.cx.allocator, entry);
            node.setStyleInline(self.cx.allocator, .{ .cursor = .text });
            _ = try drag.Binding.attach(scope, self.cx, node, .{ .activation_distance = 0, .active_cursor = .text }, changed, entry);
        };
        for (node.children.items) |child| try self.collect(scope, child);
    }
    fn changed(e: drag.Event, raw: *anyopaque) void {
        const entry: *Entry = @ptrCast(@alignCast(raw));
        const self = entry.owner;
        if (e.phase == .cancel) return;
        if (e.phase == .start) {
            for (self.entries.items) |item| item.content_hash = std.hash.Wyhash.hash(0, item.node.getText().?.content);
            self.cx.setFocus(self.root);
            self.anchor = .{ .index = entry.index, .byte = self.hit(entry.node, e.origin_window) };
        }
        const target = self.nearest(e.position_window);
        self.head = .{ .index = target.index, .byte = self.hit(target.node, e.position_window) };
        self.paint() catch {};
        self.cx.requestRedraw();
    }
    fn nearest(self: *Selection, point: drag.Point) *Entry {
        var best = self.entries.items[0];
        var best_dy = std.math.inf(f32);
        var best_dx = std.math.inf(f32);
        for (self.entries.items) |entry| {
            if (!entry.node.isDisplayedInTree()) continue;
            const r = entry.node.globalRect();
            const dx = @max(r.x - point.x, @max(point.x - r.x - r.w, 0));
            const dy = @max(r.y - point.y, @max(point.y - r.y - r.h, 0));
            if (dy < best_dy or (dy == best_dy and dx < best_dx)) {
                best = entry;
                best_dy = dy;
                best_dx = dx;
            }
        }
        return best;
    }
    fn hit(self: *Selection, node: *ui.Node, point: drag.Point) usize {
        const text = node.getText() orelse return 0;
        const layout = node.getLayoutOutput().artifacts.text_layout orelse {
            return self.walk(node, .{ .byte_start = 0, .byte_end = @intCast(text.content.len), .width = node.globalRect().w }, 0, point.x - node.globalRect().x, null, 0, 0) catch 0;
        };
        if (layout.line_count == 0) return 0;
        const rect = node.globalRect();
        const height = text.font_size * text.line_height;
        const row: usize = @intFromFloat(std.math.clamp(@floor((point.y - rect.y) / height), 0, @as(f32, @floatFromInt(layout.line_count - 1))));
        const line = layout.lines[row];
        const x = point.x - rect.x;
        return self.walk(node, line, row, x, null, 0, 0) catch line.byte_start;
    }
    // Shape each original rich-text run without splitting at selection edges.
    // This preserves ligatures, grapheme clusters, inline padding and font weight.
    fn walk(self: *Selection, node: *ui.Node, line: ui.LineInfo, row: usize, hit_x: ?f32, entry: ?*Entry, lo: usize, hi: usize) !usize {
        const text = node.getText().?;
        var pos: usize = line.byte_start;
        var x: f32 = ui.textAlignLineOffset(text.text_align, node.globalRect().w, line.width);
        while (pos < line.byte_end) {
            var end: usize = line.byte_end;
            var weight = text.font_weight;
            var mono = text.use_monospace_font;
            var italic = text.use_italic_font;
            var left: f32 = 0;
            var right: f32 = 0;
            for (text.spans) |span| {
                if (span.start > pos) end = @min(end, span.start);
                if (span.start <= pos and span.end > pos) {
                    end = @min(end, span.end);
                    weight = span.font_weight orelse weight;
                    mono = span.use_monospace_font or mono;
                    italic = span.use_italic_font or italic;
                    if (pos == span.start) left = span.inline_box_padding_left;
                    if (end == span.end) right = span.inline_box_padding_right;
                    break;
                }
            }
            x += left;
            const visual = try self.cx.text.visualLine(.{ .text = text.content[pos..end], .font_family = "system", .font_family_id = text.font_family, .font_size = text.font_size, .font_weight = weight, .use_monospace = mono, .use_italic = italic, .use_symbols = text.use_symbols_font });
            if (hit_x) |target| {
                if (target <= x + visual.width + right or end == line.byte_end) return pos + visual.xToPosition(.{ .value = target - x }).byte.value;
            } else if (entry) |item| {
                var segments = visual.selectionSegments();
                var start_x: ?f32 = null;
                var end_x: f32 = 0;
                while (segments.next()) |segment| {
                    if (pos + segment.end.value <= lo or pos + segment.start.value >= hi) continue;
                    if (start_x != null and @abs(end_x - segment.rect.x) > 0.1) {
                        try self.highlight(item, x + start_x.?, row, end_x - start_x.?);
                        start_x = null;
                    }
                    if (start_x == null) start_x = segment.rect.x;
                    end_x = segment.rect.x + segment.rect.width;
                }
                if (start_x) |start| try self.highlight(item, x + start, row, end_x - start);
            }
            x += visual.width + right;
            pos = end;
        }
        return line.byte_end;
    }
    fn highlight(self: *Selection, entry: *Entry, x: f32, row: usize, width: f32) !void {
        const node = if (entry.used < entry.highlights.items.len) entry.highlights.items[entry.used] else blk: {
            const node = try ui.box(self.cx, .{ .position = .absolute, .hit_behavior = .pass_through, .background = S.textSelection() }, .{});
            node.meta.ownership.meta.test_id = "ai.message.selection";
            try entry.node.parent.?.appendChild(self.cx.allocator, node);
            try entry.highlights.append(self.cx.allocator, node);
            break :blk node;
        };
        const text = entry.node.getText().?;
        const height = text.font_size * text.line_height;
        const rect = entry.node.globalRect();
        const parent = entry.node.parent.?.globalRect();
        node.setDisplay(.flex);
        node.setStyleInline(self.cx.allocator, .{ .inset = .{ .left = .{ .px = rect.x - parent.x + x }, .top = .{ .px = rect.y - parent.y + @as(f32, @floatFromInt(row)) * height } }, .width = .{ .px = width }, .height = .{ .px = height } });
        entry.used += 1;
    }
    fn ordered(self: *Selection) ?struct { lo: Position, hi: Position } {
        const a = self.anchor orelse return null;
        const b = self.head orelse return null;
        return if (a.index < b.index or (a.index == b.index and a.byte <= b.byte)) .{ .lo = a, .hi = b } else .{ .lo = b, .hi = a };
    }
    fn paint(self: *Selection) !void {
        for (self.entries.items) |entry| {
            entry.used = 0;
            if (self.ordered()) |range| if (entry.node.isDisplayedInTree() and entry.index >= range.lo.index and entry.index <= range.hi.index) {
                const text = entry.node.getText().?;
                const lo = if (entry.index == range.lo.index) range.lo.byte else 0;
                const hi = if (entry.index == range.hi.index) range.hi.byte else text.content.len;
                if (entry.node.getLayoutOutput().artifacts.text_layout) |layout| {
                    for (layout.lines[0..layout.line_count], 0..) |line, row| {
                        if (line.byte_end > lo and line.byte_start < hi) _ = try self.walk(entry.node, line, row, null, entry, lo, hi);
                    }
                } else if (hi > lo) {
                    _ = try self.walk(entry.node, .{ .byte_start = 0, .byte_end = @intCast(text.content.len), .width = entry.node.globalRect().w }, 0, null, entry, lo, hi);
                }
            };
            for (entry.highlights.items[entry.used..]) |node| node.setDisplay(.none);
        }
    }
    fn selectedText(self: *Selection, allocator: std.mem.Allocator) ![]u8 {
        var output: std.ArrayList(u8) = .empty;
        errdefer output.deinit(allocator);
        if (self.ordered()) |range| {
            var first = true;
            for (self.entries.items[range.lo.index .. range.hi.index + 1]) |entry| {
                if (!entry.node.isDisplayedInTree()) continue;
                if (!first) try output.append(allocator, '\n');
                first = false;
                const text = entry.node.getText().?.content;
                if (std.mem.eql(u8, entry.node.meta.ownership.meta.test_id orelse "", "ai.message.code.blank")) continue;
                try output.appendSlice(allocator, text[if (entry.index == range.lo.index) range.lo.byte else 0..if (entry.index == range.hi.index) range.hi.byte else text.len]);
            }
        }
        return output.toOwnedSlice(allocator);
    }
    fn event(e: ui.events.Event, raw: ?*anyopaque) ui.events.EventResult {
        const self: *Selection = @ptrCast(@alignCast(raw orelse return .ignored));
        switch (e) {
            .mouse_down => |mouse| {
                if (mouse.button == .left) {
                    self.anchor = null;
                    self.head = null;
                    self.paint() catch {};
                }
            },
            .blur => {
                self.anchor = null;
                self.head = null;
                self.paint() catch {};
            },
            .key_down => |key| {
                if (key.key == .c and (key.modifiers.super or key.modifiers.ctrl)) {
                    const text = self.selectedText(self.cx.allocator) catch return .stop;
                    defer self.cx.allocator.free(text);
                    if (text.len > 0) _ = ui.platform_services.clipboardSetText(self.cx.system_sdk, text);
                    return .stop;
                }
                if (key.key == .escape and self.anchor != null) {
                    self.anchor = null;
                    self.head = null;
                    self.paint() catch {};
                    return .stop;
                }
            },
            else => {},
        }
        return .ignored;
    }
};
