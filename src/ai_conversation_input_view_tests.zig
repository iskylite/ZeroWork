//! Native queue-card flow, immutable callback tickets, and read-only history.
const std = @import("std");
const ui = @import("ui");
const V = @import("ui/ai_pending_view.zig");
const Sessions = @import("ui/ai_sessions_view.zig");
const T = @import("ui/app_theme.zig");
const a = std.testing.allocator;
fn find(node: *ui.Node, id: []const u8) ?*ui.Node {
    if (node.meta.ownership.meta.test_id) |value| if (std.mem.eql(u8, value, id)) return node;
    for (node.children.items) |child| if (find(child, id)) |result| return result;
    return null;
}
const Fixture = struct {
    cx: *ui.Cx,
    scope: *ui.Scope,
    pending: *V.View,
    transcript: *ui.Node,
    composer: *ui.Node,
    calls: usize = 0,
    last: ?V.Ticket = null,
    last_action: ?V.Action = null,
    fn init(self: *Fixture, width: f32, height: f32) !void {
        self.* = .{ .cx = try ui.Cx.init(a, std.testing.io), .scope = undefined, .pending = undefined, .transcript = undefined, .composer = undefined };
        self.cx.reduced_motion = true;
        self.cx.setTheme(T.widgetTheme(T.currentName()));
        self.cx.setViewport(width, height);
        self.cx.root = try ui.box(self.cx, .{ .width = .fill(), .height = .fill(), .direction = .column, .hit_behavior = .@"opaque" }, .{});
        self.scope = try ui.Scope.init(a, null, self.cx.owner);
        self.transcript = try ui.box(self.cx, .{ .width = .fill(), .height = .fill(), .flex = 1, .min_height = 0 }, .{});
        try self.cx.root.?.appendChild(a, self.transcript);
        self.pending = try V.View.mount(self.cx, self.scope, .{ .context = self, .act = act });
        try self.cx.root.?.appendChild(a, self.pending.root);
        self.composer = try ui.box(self.cx, .{ .width = .fill(), .height = .{ .px = 90 }, .flex_shrink = 0 }, .{});
        try self.cx.root.?.appendChild(a, self.composer);
    }
    fn deinit(self: *Fixture) void {
        self.cx.clearFocus();
        self.scope.dispose();
        self.cx.deinit();
    }
    fn act(raw: *anyopaque, ticket: V.Ticket, action: V.Action, _: []const u8) !void {
        const self: *Fixture = @ptrCast(@alignCast(raw));
        self.calls += 1;
        self.last = ticket;
        self.last_action = action;
    }
    fn settle(self: *Fixture) void {
        for (0..5) |_| {
            self.cx.layout();
            _ = self.cx.render();
        }
    }
    fn click(self: *Fixture, id: []const u8) void {
        const r = (find(self.cx.root.?, id) orelse @panic("missing action")).globalRect();
        self.cx.handleMouseMove(r.x + r.w / 2, r.y + r.h / 2);
        self.settle();
        self.cx.handleMouseDown(r.x + r.w / 2, r.y + r.h / 2, .{});
        self.cx.handleMouseUp(r.x + r.w / 2, r.y + r.h / 2);
        self.settle();
    }
};
fn item(index: u8) V.Item {
    return .{ .text = "检查服务日志与配置，保留所有原始约束。", .attachments = 1, .receipt = .{ .id = .{ .bytes = @splat(index) }, .fence = .{ .agent = .{ .bytes = @splat(1) }, .conversation = .{ .bytes = @splat(2) }, .binding = 2, .environment = 1 }, .sequence = index, .mode = .queue, .route = .queue } };
}
test "conversation UI cards occupy layout above composer without covering transcript in three themes" {
    for ([_]@TypeOf(T.currentName()){ .dark, .light, .sauber }) |name| {
        T.select(name);
        defer T.select(.dark);
        for ([_][2]f32{ .{ 600, 456 }, .{ 360, 358 } }) |size| {
            var f: Fixture = undefined;
            try f.init(size[0], size[1]);
            defer f.deinit();
            var items: [32]V.Item = undefined;
            for (&items, 0..) |*entry, i| entry.* = item(@intCast(i + 1));
            _ = try f.pending.update(&items, 7, size[1] < 400, false);
            f.settle();
            const transcript = f.transcript.globalRect();
            const queue = f.pending.root.globalRect();
            const composer = f.composer.globalRect();
            try std.testing.expect(queue.h > 0 and queue.h <= 140.1);
            try std.testing.expect(transcript.y + transcript.h <= queue.y + 0.1);
            try std.testing.expect(queue.y + queue.h <= composer.y + 0.1);
            try std.testing.expectApproxEqAbs(@as(f32, 90), composer.h, 0.1);
            try std.testing.expectApproxEqAbs(size[1], composer.y + composer.h, 0.1);
            const card = find(f.cx.root.?, "ai.pending.card.0").?;
            try std.testing.expect(card.style.border.width == 0 and card.getBackground().a == 0 and card.globalRect().h == 18);
            ui.widgets.setScrollY(f.pending.scroll.state, f.pending.scroll.content, 40);
            f.pending.scrollToTop();
            _ = try f.pending.update(&items, 7, size[1] < 400, false);
            f.settle();
            try std.testing.expectApproxEqAbs(f.pending.scroll.container.globalRect().y, card.globalRect().y, 0.1);
        }
    }
}
test "conversation UI cards invalidate an old press and preserve an edit draft on receipt change" {
    var f: Fixture = undefined;
    try f.init(600, 456);
    defer f.deinit();
    var original = [_]V.Item{ item(1), item(2) };
    _ = try f.pending.update(&original, 1, false, false);
    f.settle();
    const r = find(f.cx.root.?, "ai.pending.now.0").?.globalRect();
    f.cx.handleMouseDown(r.x + r.w / 2, r.y + r.h / 2, .{});
    original[0].receipt.revision = 2;
    _ = try f.pending.update(&original, 2, false, false);
    f.settle();
    f.cx.handleMouseUp(r.x + r.w / 2, r.y + r.h / 2);
    try std.testing.expectEqual(@as(usize, 0), f.calls);
    f.click("ai.pending.edit.0");
    _ = try f.pending.update(&original, 2, false, false);
    f.settle();
    f.pending.edit_text.set("保留尚未保存的编辑");
    original[0].receipt.revision = 3;
    _ = try f.pending.update(&original, 3, false, false);
    f.settle();
    try std.testing.expectEqualStrings("保留尚未保存的编辑", f.pending.edit_text.peek());
    f.click("ai.pending.save");
    try std.testing.expectEqual(@as(u64, 2), f.last.?.receipt.revision);
    try std.testing.expectEqual(@as(u64, 2), f.last.?.queue_revision);
}
const SessionFixture = struct {
    actions: usize = 0,
    last: ?Sessions.Action = null,
    fn ignore(_: *anyopaque, _: u64) void {}
    fn act(raw: *anyopaque, _: u64, action: Sessions.Action) void {
        const self: *SessionFixture = @ptrCast(@alignCast(raw));
        self.actions += 1;
        self.last = action;
    }
};
test "conversation UI history separates view locate restore and copy without a send control" {
    var f: Fixture = undefined;
    try f.init(600, 456);
    defer f.deinit();
    var callbacks: SessionFixture = .{};
    const view = try Sessions.View.mount(f.cx, f.scope, f.composer, .{ .context = &callbacks, .select = SessionFixture.ignore, .request_close = SessionFixture.ignore, .remove = SessionFixture.ignore, .act = SessionFixture.act });
    try f.cx.root.?.appendChild(a, view.root);
    try view.show(&.{ .{ .id = 1, .title = "来源仍在运行", .owner = "来源连接", .bound = true, .can_copy = true, .can_remove = false }, .{ .id = 2, .title = "已结束的历史", .owner = "历史环境", .can_restore = true, .can_copy = true } });
    f.settle();
    try std.testing.expect(find(view.content, "ai.session.restore.1") == null);
    try std.testing.expect(find(view.content, "ai.session.locate.1") != null);
    try std.testing.expect(find(view.content, "ai.session.restore.2") != null);
    try view.showHistory(.{ .id = 2, .title = "已结束的历史", .owner = "历史环境", .can_restore = true, .can_copy = true, .has_children = true }, "只读历史正文");
    f.settle();
    try std.testing.expect(find(view.history_dialog, "ai.send") == null);
    try std.testing.expect(find(view.history_dialog, "ai.history.restore") != null);
    try std.testing.expect(find(view.history_dialog, "ai.history.children") != null);
    try std.testing.expect(find(view.history_dialog, "ai.history.copy") != null);
    try std.testing.expectEqualStrings("只读历史正文", view.history_body.getText().?.content);
}

test "conversation UI one-line queue keeps icon actions and expanded editor reachable at minimum width" {
    for ([_]bool{ false, true }) |compact| {
        var f: Fixture = undefined;
        try f.init(360, 358);
        defer f.deinit();
        const entries = [_]V.Item{item(1)};
        _ = try f.pending.update(&entries, 1, compact, false);
        f.settle();
        const card = find(f.cx.root.?, "ai.pending.card.0").?.globalRect();
        try std.testing.expectApproxEqAbs(@as(f32, 18), card.h, 0.1);
        inline for (.{ "edit", "remove", "now", "more" }) |name| {
            const button = find(f.cx.root.?, "ai.pending." ++ name ++ ".0").?;
            const rect = button.globalRect();
            try std.testing.expect(rect.x >= card.x and rect.x + rect.w <= card.x + card.w);
            try std.testing.expect(rect.y >= card.y and rect.y + rect.h <= card.y + card.h);
            try std.testing.expect(button.behavior.interaction.a11y.?.label != null);
        }
        f.click("ai.pending.edit.0");
        _ = try f.pending.update(&entries, 1, compact, false);
        f.settle();
        const scroll = f.pending.scroll.container.globalRect();
        const editor = find(f.cx.root.?, "ai.pending.editor").?.globalRect();
        const save = find(f.cx.root.?, "ai.pending.save").?.globalRect();
        try std.testing.expect(editor.y >= scroll.y and save.y + save.h <= scroll.y + scroll.h + 0.1);
        try std.testing.expect(f.pending.root.globalRect().y + f.pending.root.globalRect().h <= f.composer.globalRect().y);
        f.pending.finishEdit();
        const pair = [_]V.Item{ item(1), item(2) };
        _ = try f.pending.update(&pair, 2, compact, false);
        f.settle();
        const queue_bounds = f.pending.scroll.container.globalRect();
        const second_action = find(f.cx.root.?, "ai.pending.now.1").?.globalRect();
        try std.testing.expect(second_action.y + second_action.h <= queue_bounds.y + queue_bounds.h);
        var ending = entries;
        ending[0].mutable = false;
        ending[0].receipt.pause = .end;
        _ = try f.pending.update(&ending, 2, compact, false);
        f.settle();
        try std.testing.expect(find(f.cx.root.?, "ai.pending.edit.0") == null);
        try std.testing.expect(find(f.cx.root.?, "ai.pending.now.0") == null);
        try std.testing.expect(find(f.cx.root.?, "ai.pending.inspect") != null);
    }
}
test "conversation UI compact history and confirmation remain bounded after resize and theme publication" {
    defer T.select(.dark);
    var f: Fixture = undefined;
    try f.init(360, 358);
    defer f.deinit();
    var callbacks: SessionFixture = .{};
    const view = try Sessions.View.mount(f.cx, f.scope, f.composer, .{ .context = &callbacks, .select = SessionFixture.ignore, .request_close = SessionFixture.ignore, .remove = SessionFixture.ignore, .act = SessionFixture.act });
    try f.cx.root.?.appendChild(a, view.root);
    try view.showHistory(.{ .id = 1, .title = "很长的历史会话名称，检查恢复与复制操作", .owner = "来源连接", .bound = true, .active = true, .can_copy = true }, "只读历史正文");
    for (0..3) |_| {
        f.settle();
        view.reflow();
    }
    f.settle();
    const history = view.history_dialog.globalRect();
    try std.testing.expect(history.x >= 15.9 and history.x + history.w <= 344.1);
    try std.testing.expect(history.y >= 15.9 and history.y + history.h <= 342.1);
    const footer = view.history_actions.globalRect();
    for (view.history_actions.children.items) |button| {
        const r = button.globalRect();
        try std.testing.expect(r.x >= history.x and r.x + r.w <= history.x + history.w + 0.1);
        try std.testing.expect(r.y + r.h <= footer.y + footer.h + 0.1);
    }
    f.click("ai.history.end");
    try std.testing.expect(!view.history_open.peek());
    try std.testing.expectEqual(Sessions.Action.end, callbacks.last.?);
    try view.confirmOperation(1, "结束当前会话并使用副本？", "结束并使用副本");
    T.select(.light);
    f.cx.setTheme(T.widgetTheme(.light));
    view.reflow();
    f.settle();
    const dialog = view.dialog.globalRect();
    const accept = find(view.dialog, "ai.session.close.accept").?.globalRect();
    try std.testing.expect(dialog.y >= 15.9 and dialog.y + dialog.h <= 342.1);
    try std.testing.expect(accept.y + accept.h <= dialog.y + dialog.h - 15.9);
    try std.testing.expect(accept.w >= 100);
}

fn findText(node: *ui.Node, value: []const u8) ?*ui.Node {
    if (node.getText()) |text| if (std.mem.eql(u8, text.content, value)) return node;
    for (node.children.items) |child| if (findText(child, value)) |result| return result;
    return null;
}
fn opacity(node: *ui.Node) f32 {
    var result: f32 = 1;
    var ancestor: ?*ui.Node = node;
    while (ancestor) |n| {
        result *= n.getOpacity();
        ancestor = n.parent;
    }
    return result;
}
test "conversation UI single card reveals stable actions on hover and keyboard focus with a real menu" {
    for ([_]@TypeOf(T.currentName()){ .dark, .light, .sauber }) |name| {
        T.select(name);
        defer T.select(.dark);
        var f: Fixture = undefined;
        try f.init(360, 358);
        defer f.deinit();
        const entries = [_]V.Item{ item(1), item(2) };
        _ = try f.pending.update(&entries, 1, true, false);
        f.settle();
        const surface = f.pending.surface.globalRect();
        try std.testing.expectApproxEqAbs(@as(f32, 58), surface.h, 0.1);
        try std.testing.expectApproxEqAbs(@as(f32, 62), f.pending.root.globalRect().h, 0.1);
        try std.testing.expect(f.pending.surface.style.border.width == 0 and f.pending.surface.style.border.radius == 8);
        const edit = find(f.cx.root.?, "ai.pending.edit.0").?;
        const remove = find(f.cx.root.?, "ai.pending.remove.0").?;
        const now = find(f.cx.root.?, "ai.pending.now.0").?;
        const before = now.globalRect();
        try std.testing.expect(opacity(edit) == 0 and opacity(remove) == 0 and opacity(now) == 1);
        const card = find(f.cx.root.?, "ai.pending.card.0").?.globalRect();
        f.cx.handleMouseMove(card.x + 40, card.y + 12);
        f.settle();
        try std.testing.expect(opacity(edit) == 1 and opacity(remove) == 1);
        try std.testing.expectEqual(before, now.globalRect());
        try std.testing.expectEqual(surface, f.pending.surface.globalRect());
        f.cx.handleMouseMove(0, 0);
        f.cx.clearFocus();
        f.settle();
        try std.testing.expect(opacity(edit) == 0 and opacity(remove) == 0);
        // Tab into the initially hidden secondary action: focus reveals the row.
        f.cx.setFocus(find(f.cx.root.?, "ai.pending.toggle").?);
        f.cx.handleKeyDown(.tab, .{});
        f.settle();
        try std.testing.expect(f.cx.isFocused(edit));
        try std.testing.expect(opacity(edit) == 1 and opacity(remove) == 1);
        try std.testing.expectEqual(before, now.globalRect());
        try std.testing.expect(ui.Color.eql(edit.parent.?.parent.?.getBackground(), T.popupAction()));
        try std.testing.expectEqual(@as(u8, 0), edit.getBackground().a);
        if (edit.style.outline()) |outline| try std.testing.expectEqual(@as(u8, 0), outline.color.a);
        f.cx.handleKeyDown(.@"return", .{});
        _ = try f.pending.update(&entries, 1, true, false);
        f.settle();
        try std.testing.expect(find(f.cx.root.?, "ai.pending.editor") != null);
        f.pending.finishEdit();
        _ = try f.pending.update(&entries, 1, true, false);
        f.settle();
        f.click("ai.pending.more.1");
        try std.testing.expect(f.pending.menus[1].?.peek());
        if (findText(f.cx.root.?, "更多消息操作")) |hint| try std.testing.expect(opacity(hint) == 0);
        f.cx.handleKeyDown(.down, .{});
        f.cx.handleKeyDown(.down, .{});
        f.cx.handleKeyDown(.@"return", .{});
        f.settle();
        try std.testing.expectEqual(V.Action.up, f.last_action.?);
        try std.testing.expectEqual(@as(u64, 1), f.last.?.queue_revision);
        f.click("ai.pending.more.1");
        f.cx.handleKeyDown(.escape, .{});
        f.settle();
        try std.testing.expect(!f.pending.menus[1].?.peek());
        try std.testing.expect(f.cx.isFocused(find(f.cx.root.?, "ai.pending.more.1").?));
        f.click("ai.pending.toggle");
        _ = try f.pending.update(&entries, 1, true, false);
        f.settle();
        try std.testing.expect(f.pending.collapsed and f.pending.scroll.container.style.display == .none);
        try std.testing.expect(f.cx.isFocused(find(f.cx.root.?, "ai.pending.toggle").?));
        f.cx.handleKeyDown(.@"return", .{});
        _ = try f.pending.update(&entries, 1, true, false);
        f.settle();
        try std.testing.expect(!f.pending.collapsed);
    }
}

test "conversation UI long queue preserves single-line bounds and scrolls keyboard focus into compact viewport" {
    const samples = [_][]const u8{
        "检查很长的中文消息与组合字符 é 🧑‍💻，不改变原始输入。" ++ "检查很长的中文消息与组合字符 é 🧑‍💻，不改变原始输入。" ++ "检查很长的中文消息与组合字符 é 🧑‍💻，不改变原始输入。" ++ "检查很长的中文消息与组合字符 é 🧑‍💻，不改变原始输入。",
        "https://example.invalid/very_long_unbroken_path_and_query_parameter_" ++ "https://example.invalid/very_long_unbroken_path_and_query_parameter_" ++ "https://example.invalid/very_long_unbroken_path_and_query_parameter_" ++ "https://example.invalid/very_long_unbroken_path_and_query_parameter_",
        "第一行保留原文\r\n第二行保留原文\t第三段，不能挤占操作位置。" ++ "第一行保留原文\r\n第二行保留原文\t第三段，不能挤占操作位置。" ++ "第一行保留原文\r\n第二行保留原文\t第三段，不能挤占操作位置。" ++ "第一行保留原文\r\n第二行保留原文\t第三段，不能挤占操作位置。",
        "最后一条也要能通过键盘编辑并完整保存。" ++ "最后一条也要能通过键盘编辑并完整保存。" ++ "最后一条也要能通过键盘编辑并完整保存。" ++ "最后一条也要能通过键盘编辑并完整保存。",
    };
    for ([_]@TypeOf(T.currentName()){ .dark, .light, .sauber }) |name| {
        T.select(name);
        defer T.select(.dark);
        for ([_][2]f32{ .{ 600, 456 }, .{ 360, 358 } }) |size| {
            var f: Fixture = undefined;
            try f.init(size[0], size[1]);
            defer f.deinit();
            var entries: [4]V.Item = undefined;
            for (&entries, 0..) |*entry, i| {
                entry.* = item(@intCast(i + 1));
                entry.text = samples[i];
            }
            entries[0].attachments = 32;
            _ = try f.pending.update(&entries, 1, size[1] < 400, false);
            f.settle();
            const surface = f.pending.surface.globalRect();
            const composer = f.composer.globalRect();
            try std.testing.expectApproxEqAbs(@as(f32, if (size[1] < 400) 62 else 80), f.pending.root.globalRect().h, 0.1);
            for (entries, 0..) |entry, i| {
                var idbuf: [64]u8 = undefined;
                const row = find(f.cx.root.?, try std.fmt.bufPrint(&idbuf, "ai.pending.card.{d}", .{i})).?;
                var body: ?*ui.Node = null;
                for (row.children.items) |child| if (child.getText()) |t| {
                    if (std.mem.eql(u8, t.content, entry.text)) {
                        body = child;
                        break;
                    }
                };
                const text_node = body orelse return error.MissingLongMessage;
                const rect = text_node.globalRect();
                const edit = find(f.cx.root.?, try std.fmt.bufPrint(&idbuf, "ai.pending.edit.{d}", .{i})).?.globalRect();
                try std.testing.expect(rect.w > 0 and rect.x + rect.w <= edit.x + 0.1);
                try std.testing.expect(rect.y >= row.globalRect().y and rect.y + rect.h <= row.globalRect().y + row.globalRect().h + 0.1);
                try std.testing.expect(text_node.getText().?.wrap == .none and text_node.getText().?.text_overflow == .ellipsis);
            }
            f.cx.handleMouseMove(surface.x + 40, f.pending.scroll.container.globalRect().y + 9);
            f.settle();
            try std.testing.expectEqual(surface, f.pending.surface.globalRect());
            try std.testing.expectEqual(composer, f.composer.globalRect());
            f.cx.handleMouseMove(0, 0);
            f.cx.setFocus(find(f.cx.root.?, "ai.pending.toggle").?);
            for (0..16) |_| {
                f.cx.handleKeyDown(.tab, .{});
                f.settle();
                const focused = f.cx.focus_manager.current_focus orelse return error.MissingKeyboardFocus;
                const rect = focused.globalRect();
                const viewport = f.pending.scroll.container.globalRect();
                try std.testing.expect(rect.y >= viewport.y - 0.1 and rect.y + rect.h <= viewport.y + viewport.h + 0.1);
                try std.testing.expect(rect.x + rect.w <= viewport.x + viewport.w - 16 + 0.1);
                try std.testing.expectEqual(surface, f.pending.surface.globalRect());
                try std.testing.expectEqual(composer, f.composer.globalRect());
            }
            // Reverse Tab must reveal the preceding rows again, rather than leaving
            // focus inside a clipped part of the scroll area.
            for (0..15) |_| {
                f.cx.handleKeyDown(.tab, .{ .shift = true });
                f.settle();
                const rect = f.cx.focus_manager.current_focus.?.globalRect();
                const viewport = f.pending.scroll.container.globalRect();
                try std.testing.expect(rect.y >= viewport.y - 0.1 and rect.y + rect.h <= viewport.y + viewport.h + 0.1);
            }
            f.cx.handleKeyDown(.@"return", .{});
            _ = try f.pending.update(&entries, 1, size[1] < 400, false);
            f.settle();
            try std.testing.expectEqualStrings(samples[0], f.pending.edit_text.peek());
            try std.testing.expect(f.cx.isFocused(find(f.cx.root.?, "ai.pending.editor").?));
            f.pending.finishEdit();
            _ = try f.pending.update(&entries, 1, size[1] < 400, false);
            f.settle();
            f.cx.setFocus(find(f.cx.root.?, "ai.pending.toggle").?);
            for (0..13) |_| {
                f.cx.handleKeyDown(.tab, .{});
                f.settle();
            }
            f.cx.handleKeyDown(.@"return", .{});
            _ = try f.pending.update(&entries, 1, size[1] < 400, false);
            f.settle();
            // The host applies the requested editor offset after layout.
            _ = try f.pending.update(&entries, 1, size[1] < 400, false);
            f.settle();
            try std.testing.expectEqualStrings(samples[3], f.pending.edit_text.peek());
            try std.testing.expect(f.cx.isFocused(find(f.cx.root.?, "ai.pending.editor").?));
            const editor_bounds = f.pending.scroll.container.globalRect();
            const editor_rect = find(f.cx.root.?, "ai.pending.editor").?.globalRect();
            const save_rect = find(f.cx.root.?, "ai.pending.save").?.globalRect();
            try std.testing.expect(editor_rect.y >= editor_bounds.y - 0.1 and save_rect.y + save_rect.h <= editor_bounds.y + editor_bounds.h + 0.1);
        }
    }
}

test "conversation UI session list keeps phase and binding tags with icon actions on the second line" {
    defer T.select(.dark);
    for ([_]@TypeOf(T.currentName()){ .dark, .light, .sauber }) |name| {
        T.select(name);
        for ([_]f32{ 360, 600 }) |width| {
            var f: Fixture = undefined;
            try f.init(width, 456);
            defer f.deinit();
            var callbacks: SessionFixture = .{};
            const view = try Sessions.View.mount(f.cx, f.scope, f.composer, .{ .context = &callbacks, .select = SessionFixture.ignore, .request_close = SessionFixture.ignore, .remove = SessionFixture.ignore, .act = SessionFixture.act });
            try f.cx.root.?.appendChild(a, view.root);
            try view.show(&.{
                .{ .id = 1, .title = "很长的会话标题，用于检查图标操作与状态标签不会挤压或重叠", .owner = "来源连接与环境信息", .bound = true, .phase = .running, .can_copy = true, .can_remove = false },
                .{ .id = 2, .title = "历史会话", .owner = "历史连接环境", .phase = .stopped, .can_restore = true, .can_copy = true },
            });
            f.settle();
            for ([_]u64{ 1, 2 }) |id| {
                var buf: [64]u8 = undefined;
                const row = find(view.content, try std.fmt.bufPrint(&buf, "ai.session.row.{d}", .{id})).?;
                const first = find(row, "ai.session.first_line").?.globalRect();
                const second = find(row, "ai.session.second_line").?.globalRect();
                const tag = find(row, "ai.session.phase_tag").?.globalRect();
                try std.testing.expect(first.y + first.h <= second.y);
                try std.testing.expectApproxEqAbs(first.x + first.w, tag.x + tag.w, 0.1);
                try std.testing.expect(tag.x >= first.x + first.w / 2);
                const binding = find(row, if (id == 1) "ai.session.bound" else "ai.session.unbound").?;
                try std.testing.expectApproxEqAbs(second.x, binding.globalRect().x, 0.1);
                inline for (.{ "jump", "copy_use", "locate", "restore", "delete" }) |action| {
                    if (find(row, try std.fmt.bufPrint(&buf, "ai.session.{s}.{d}", .{ action, id }))) |button| {
                        if (button.style.display != .none) {
                            const rect = button.globalRect();
                            try std.testing.expectEqual(@as(f32, 24), rect.w);
                            try std.testing.expectEqual(@as(f32, 24), rect.h);
                            try std.testing.expect(rect.y >= second.y and rect.y + rect.h <= second.y + second.h + 0.1);
                            try std.testing.expect(rect.x >= second.x and rect.x + rect.w <= second.x + second.w + 0.1);
                            try std.testing.expect(button.behavior.interaction.a11y.?.label != null);
                            for (button.children.items) |child| try std.testing.expect(child.getText() == null);
                        }
                    }
                }
            }
            f.click("ai.session.row.1");
            f.click("ai.session.first_line");
            f.click("ai.session.phase_tag");
            f.click("ai.session.bound");
            try std.testing.expectEqual(@as(usize, 0), callbacks.actions);
            try std.testing.expect(view.open.peek());
            f.click("ai.session.copy_use.2");
            try std.testing.expectEqual(@as(usize, 1), callbacks.actions);
            try std.testing.expectEqual(Sessions.Action.copy_use, callbacks.last.?);
            f.click("ai.session.restore.2");
            try std.testing.expectEqual(@as(usize, 2), callbacks.actions);
            try std.testing.expectEqual(Sessions.Action.restore, callbacks.last.?);
            f.click("ai.session.locate.1");
            try std.testing.expectEqual(@as(usize, 3), callbacks.actions);
            try std.testing.expectEqual(Sessions.Action.locate, callbacks.last.?);
            const row = find(view.content, "ai.session.row.1").?;
            inline for (.{ .idle, .running, .approval, .done, .failed, .stopped }, .{ "未开始", "运行中", "待确认", "已完成", "失败", "已暂停" }) |phase, label| {
                view.updatePhase(1, phase);
                f.settle();
                try std.testing.expect(findText(find(row, "ai.session.phase_tag").?, label) != null);
            }
        }
    }
}

test "conversation UI retained queue changes one row and keeps the editor and current callback ticket" {
    var f: Fixture = undefined;
    try f.init(600, 456);
    defer f.deinit();
    var entries = [_]V.Item{ item(1), item(2), item(3) };
    _ = try f.pending.update(&entries, 1, false, false);
    f.settle();
    const first = find(f.cx.root.?, "ai.pending.card.0").?.id;
    const last = find(f.cx.root.?, "ai.pending.card.2").?.id;
    entries[1].text = "只更新中间一项";
    _ = try f.pending.update(&entries, 2, false, false);
    f.settle();
    try std.testing.expectEqual(first, find(f.cx.root.?, "ai.pending.card.0").?.id);
    try std.testing.expectEqual(last, find(f.cx.root.?, "ai.pending.card.2").?.id);
    f.click("ai.pending.now.2");
    try std.testing.expectEqual(@as(u64, 2), f.last.?.queue_revision);
    f.click("ai.pending.edit.0");
    _ = try f.pending.update(&entries, 2, false, false);
    f.settle();
    const editor = find(f.cx.root.?, "ai.pending.editor").?;
    f.pending.edit_text.set("输入不应因别的行变化而被打断");
    entries[1].text = "其他行继续变化";
    _ = try f.pending.update(&entries, 3, false, false);
    f.settle();
    try std.testing.expectEqual(editor, find(f.cx.root.?, "ai.pending.editor").?);
    try std.testing.expect(f.cx.isFocused(editor));
    try std.testing.expectEqualStrings("输入不应因别的行变化而被打断", f.pending.edit_text.peek());
}
