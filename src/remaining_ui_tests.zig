const std = @import("std");
const ui = @import("ui");
const History = @import("ui/ai_history_view.zig");
const a = std.testing.allocator;
fn frames(cx: *ui.Cx, outer: ui.widgets.ScrollAreaResult, count: usize) void {
    for (0..count) |_| {
        cx.advanceFrameClock();
        _ = cx.render();
        outer.state.content_height = outer.content.globalRect().h;
        outer.state.viewport_height = outer.container.globalRect().h;
    }
}
test "remaining UI virtual history bounds resident rows preserves live content and uses one scroll transform" {
    const cx = try ui.Cx.init(a, std.testing.io);
    defer cx.deinit();
    try cx.setTestFrameStep(16);
    cx.reduced_motion = true;
    cx.setViewport(700, 500);
    const scope = try ui.Scope.init(a, null, cx.owner);
    defer scope.dispose();
    cx.root = try ui.box(cx, .{ .width = .fill(), .height = .fill(), .direction = .column }, .{});
    const outer = try ui.widgets.ScrollArea(.{ .height = 400, .rubber_band_y = false }).mount(scope, cx);
    try cx.root.?.appendChild(a, outer.container);
    var heights: History.Heights = .{};
    defer heights.deinit(a);
    var keys: [1000]usize = undefined;
    for (&keys, 0..) |*key, i| key.* = i;
    var context: u8 = 0;
    const renderer = struct {
        fn render(_: *anyopaque, i: usize, row_scope: *ui.Scope, c: *ui.Cx) !*ui.Node {
            const row = try ui.box(c, .{ .width = .fill(), .height = .{ .px = 72 }, .flex_shrink = 0 }, .{});
            const value = try std.fmt.allocPrint(c.allocator, "历史 {d}", .{i});
            defer c.allocator.free(value);
            const text = try row_scope.createText(value, .{});
            try row.appendChild(c.allocator, try ui.text(c, text.peek(), .{ .font_size = 12 }));
            return row;
        }
    };
    const view = try History.View.mount(cx, scope, outer, &keys, &heights, &context, renderer.render);
    try outer.content.appendChild(a, view.root);
    const live = try ui.box(cx, .{ .width = .fill(), .height = .{ .px = 100 }, .flex_shrink = 0 }, .{});
    try outer.content.appendChild(a, live);
    frames(cx, outer, 8);
    try std.testing.expect(view.state.pool_size < 40);
    for ([_]f32{ 40000, 90000, 0 }) |offset| {
        ui.widgets.setScrollY(outer.state, outer.content, offset);
        frames(cx, outer, 8);
        const actual = view.state.content_node.style.translate_y;
        try std.testing.expectApproxEqAbs(@as(f32, 0), actual, 0.01);
        try std.testing.expectEqual(live, outer.content.children.items[1]);
        try std.testing.expect(view.state.prev_end - view.state.prev_start < 32);
        if (offset > 0) try std.testing.expect(view.state.prev_start > 50);
    }
    // Retired rows leave only their measurements, never a full historical tree.
    try std.testing.expect(heights.count() < 100);
    frames(cx, outer, 80);
    try std.testing.expect(!cx.hasPendingSceneWork());
}

test "remaining UI virtual history remeasures a collapsed row instead of reserving its old height" {
    const cx = try ui.Cx.init(a, std.testing.io);
    defer cx.deinit();
    try cx.setTestFrameStep(16);
    cx.reduced_motion = true;
    cx.setViewport(700, 500);
    const scope = try ui.Scope.init(a, null, cx.owner);
    defer scope.dispose();
    cx.root = try ui.box(cx, .{ .width = .fill(), .height = .fill(), .direction = .column }, .{});
    const outer = try ui.widgets.ScrollArea(.{ .height = 400, .rubber_band_y = false }).mount(scope, cx);
    try cx.root.?.appendChild(a, outer.container);
    var heights: History.Heights = .{};
    defer heights.deinit(a);
    const Context = struct {
        body: ?*ui.Node = null,
        fn render(raw: *anyopaque, _: usize, _: *ui.Scope, c: *ui.Cx) !*ui.Node {
            const self: *@This() = @ptrCast(@alignCast(raw));
            const row = try ui.box(c, .{ .width = .fill(), .height = .{ .fit = .{} }, .direction = .column, .flex_shrink = 0 }, .{});
            self.body = try ui.box(c, .{ .width = .fill(), .height = .{ .px = 800 }, .flex_shrink = 0 }, .{});
            try row.appendChild(c.allocator, self.body.?);
            return row;
        }
    };
    var context: Context = .{};
    const view = try History.View.mount(cx, scope, outer, &.{0}, &heights, &context, Context.render);
    try outer.content.appendChild(a, view.root);
    const next = try ui.box(cx, .{ .width = .fill(), .height = .{ .px = 60 }, .flex_shrink = 0 }, .{});
    try outer.content.appendChild(a, next);
    frames(cx, outer, 8);
    try std.testing.expectApproxEqAbs(@as(f32, 800), view.state.totalContentHeight(), 0.1);
    context.body.?.setStyleInline(a, .{ .height = .{ .px = 60 } });
    frames(cx, outer, 8);
    try std.testing.expectApproxEqAbs(@as(f32, 60), view.state.totalContentHeight(), 0.1);
    try std.testing.expectApproxEqAbs(@as(f32, 60), next.globalRect().y - outer.content.globalRect().y, 0.1);
    context.body.?.setStyleInline(a, .{ .height = .{ .px = 900 } });
    frames(cx, outer, 8);
    try std.testing.expectApproxEqAbs(@as(f32, 900), view.state.totalContentHeight(), 0.1);
    frames(cx, outer, 80);
    try std.testing.expect(!cx.hasPendingSceneWork());
}

test "remaining UI completed turn lazily folds only process content and keeps its final reply" {
    const Summary = @import("ui/ai_turn_summary_view.zig").View;
    const turns = @import("ai/conversation_turn.zig");
    var turn: turns.Turn = .{ .sent_at_ms = 1, .started_mono_ms = 1, .ended_at_ms = 56001, .elapsed_ms = 56000 };
    defer turn.deinit(a);
    const cx = try ui.Cx.init(a, std.testing.io);
    defer cx.deinit();
    cx.setViewport(700, 500);
    const scope = try ui.Scope.init(a, null, cx.owner);
    defer scope.dispose();
    cx.root = try ui.box(cx, .{ .width = .fill(), .height = .fill(), .direction = .column, .gap = 8 }, .{});
    // Render callback owns no execution state and never runs while collapsed.
    const Renderer = struct {
        cx: *ui.Cx,
        renders: usize = 0,
        toggles: usize = 0,
        fn render(raw: *anyopaque, parent: *ui.Node, _: *ui.Scope) !void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.renders += 1;
            try parent.appendChild(a, try ui.text(self.cx, "tool and intermediate messages", .{}));
        }
        fn toggled(self: *@This()) void {
            self.toggles += 1;
        }
    };
    var renderer: Renderer = .{ .cx = cx };
    const view = try Summary.mount(cx, scope, cx.root.?, &turn, &renderer, Renderer.render, cx.on(Renderer, &renderer, Renderer.toggled));
    const answer = try ui.text(cx, "FINAL_ANSWER", .{});
    try cx.root.?.appendChild(a, answer);
    _ = cx.render();
    try std.testing.expectEqual(@as(usize, 0), renderer.renders);
    try std.testing.expect(view.process.style.display == .none);
    try std.testing.expectApproxEqAbs(@as(f32, 1), view.divider.globalRect().h, 0.01);
    try std.testing.expectApproxEqAbs(view.root.globalRect().w, view.divider.globalRect().w, 0.1);
    const final_id = answer.id;
    for (0..4) |i| {
        const rect = view.button.globalRect();
        cx.handleMouseDown(rect.x + rect.w / 2, rect.y + rect.h / 2, .{});
        cx.handleMouseUp(rect.x + rect.w / 2, rect.y + rect.h / 2);
        _ = cx.render();
        try std.testing.expectEqual(i % 2 == 0, turn.process_expanded);
        try std.testing.expectEqual(@as(usize, 1), renderer.renders);
        try std.testing.expectEqual(final_id, answer.id);
        try std.testing.expectEqual(i % 2 == 0, view.button.behavior.interaction.a11y.?.expanded.?);
    }
}

test "remaining UI completed turn final response excludes earlier tool commentary and preserves split text" {
    var turn: @import("ai/conversation_turn.zig").Turn = .{};
    defer turn.deinit(a);
    try turn.applyEvent(a, .{ .phase = .assembling, .kind = .text, .detail = "checking", .at_ms = 1 });
    try turn.applyEvent(a, .{ .phase = .assembling, .kind = .plan, .call_id = "call1", .name = "host.run_in_terminal", .at_ms = 2 });
    try turn.applyEvent(a, .{ .phase = .succeeded, .kind = .step, .call_id = "call1", .name = "host.run_in_terminal", .at_ms = 2 });
    try turn.applyEvent(a, .{ .phase = .assembling, .kind = .round_start, .at_ms = 3 });
    try turn.applyEvent(a, .{ .phase = .assembling, .kind = .thinking, .detail = "reasoning", .at_ms = 4 });
    try turn.applyEvent(a, .{ .phase = .assembling, .kind = .text, .detail = "final ", .at_ms = 5 });
    try turn.applyEvent(a, .{ .phase = .assembling, .kind = .thinking, .detail = "more reasoning", .at_ms = 6 });
    try turn.applyEvent(a, .{ .phase = .assembling, .kind = .text, .detail = "answer", .at_ms = 7 });
    turn.answer = try a.dupe(u8, "final answer");
    turn.ended_at_ms = 8;
    try std.testing.expectEqual(@as(usize, 3), turn.finalResponseStart());
    try std.testing.expect(!turn.process_expanded);
    turn.process_expanded = true;
    var copy = try turn.clone(a);
    defer copy.deinit(a);
    try std.testing.expect(copy.process_expanded);
    try std.testing.expectEqual(@as(usize, 3), copy.finalResponseStart());
}
