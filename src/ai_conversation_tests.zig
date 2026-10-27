const std = @import("std");
const ui = @import("ui");
const a = std.testing.allocator;
const turns = @import("ai/conversation_turn.zig");
const wire = @import("ai/wire_history.zig");
const steps = @import("ai/step_events.zig");
fn find(root: *ui.Node, id: []const u8) ?*ui.Node {
    if (std.mem.eql(u8, root.meta.ownership.meta.test_id orelse "", id)) return root;
    for (root.children.items) |child| if (find(child, id)) |node| return node;
    return null;
}
test "AI conversation context snapshots and steps clone independently with real tool roles" {
    var turn: turns.Turn = .{ .id = 7, .sent_at_ms = 1793060229000 };
    defer turn.deinit(a);
    turn.before = try wire.History.copy(a, &.{.{ .content = "prior question" }}, "prior answer");
    turn.after = try wire.History.copy(a, &.{
        .{ .content = "prior question" },                                                                                      .{ .role = .assistant, .content = "prior answer" },                     .{ .content = "this question" },
        .{ .role = .assistant, .content = "", .tool_calls = &.{.{ .id = "call", .name = "run_command", .arguments = "{}" }} }, .{ .role = .tool, .tool_call_id = "call", .content = "actual result" },
    }, "formal answer");
    turn.answer = try a.dupe(u8, "formal answer");
    try turn.thinking.appendSlice(a, "provider thinking");
    try steps.apply(a, &turn.steps, .{ .call_id = "call", .name = "run_command", .command = "date", .phase = .running, .at_ms = 10 });
    try steps.apply(a, &turn.steps, .{ .call_id = "call", .phase = .succeeded, .detail = "actual result", .at_ms = 50 });
    var fork = try turn.clone(a);
    defer fork.deinit(a);
    turn.deinit(a);
    try std.testing.expectEqual(@as(usize, 2), fork.before.messages.len);
    try std.testing.expectEqual(@as(usize, 6), fork.after.messages.len);
    try std.testing.expectEqualStrings("call", fork.after.messages[4].tool_call_id.?);
    try std.testing.expectEqualStrings("actual result", fork.steps.items[0].detail);
    try std.testing.expectEqualStrings("formal answer", fork.answer);
    try std.testing.expectEqualStrings("provider thinking", fork.thinking.items);
}
test "AI conversation renders Markdown tables and live thought disclosure at native bounds" {
    const cx = try ui.Cx.init(a, std.testing.io);
    defer cx.deinit();
    const scope = try ui.Scope.init(a, null, cx.owner);
    defer scope.dispose();
    cx.setViewport(600, 500);
    const root = try ui.box(cx, .{ .width = .{ .px = 572 }, .height = .fill(), .direction = .column }, .{});
    cx.root = root;
    const markdown = try @import("ui/ai_message_view.zig").mountWithWidth(cx, scope, "## 系统时间\n\n| 项目 | 值 |\n| --- | --- |\n| 时间 | **16:17** |\n\n```sh\ndate\n```", 572);
    try root.appendChild(a, markdown);
    var expanded = false;
    const card = try @import("ui/ai_step_view.zig").mount(cx, scope, .{ .title = "思考", .projection = "核对当前时间", .detail = "provider thinking", .copy_detail = false, .phase = .running, .elapsed_ms = 1200, .expanded = &expanded, .test_id = "ai.thinking" });
    try root.appendChild(a, card);
    for (0..3) |_| {
        cx.advanceFrameClock();
        cx.layout();
        _ = cx.render();
    }
    try std.testing.expect(find(root, "ai.message.table") != null);
    try std.testing.expectApproxEqAbs(@as(f32, 32), card.globalRect().h, 0.1);
    const header = card.children.items[0];
    header.behavior.events.on_click.?.invoke();
    for (0..3) |_| {
        cx.advanceFrameClock();
        cx.layout();
        _ = cx.render();
    }
    try std.testing.expect(expanded);
    try std.testing.expectApproxEqAbs(@as(f32, 58), card.globalRect().h, 0.1);
    try std.testing.expect(find(card, "ai.step.copy") == null);
    try std.testing.expectEqualStrings("核对当前时间", find(card, "ai.step.projection").?.getText().?.content);
    const detail = find(card, "ai.step.detail").?;
    try detail.setTextContent(a, "first line\nsecond line\nthird line");
    cx.layout();
    try std.testing.expectApproxEqAbs(@as(f32, 90), card.globalRect().h, 0.1);
    const wrapped = try std.mem.join(a, " ", &@as([16][]const u8, @splat("wrapped thinking")));
    defer a.free(wrapped);
    try detail.setTextContent(a, wrapped);
    root.setStyleInline(a, .{ .width = .{ .px = 180 } });
    cx.layout();
    const narrow_height = card.globalRect().h;
    try std.testing.expect(narrow_height > 90 and narrow_height <= 182);
    root.setStyleInline(a, .{ .width = .{ .px = 572 } });
    cx.layout();
    try std.testing.expect(card.globalRect().h < narrow_height);
    const long_thinking = try std.mem.join(a, "\n", &@as([30][]const u8, @splat("long thinking line")));
    defer a.free(long_thinking);
    try detail.setTextContent(a, long_thinking);
    cx.layout();
    const viewport = find(card, "ai.step.details").?;
    try std.testing.expectApproxEqAbs(@as(f32, 150), viewport.globalRect().h, 0.1);
    try std.testing.expect(detail.globalRect().h > viewport.globalRect().h);
    header.behavior.events.on_click.?.invoke();
    cx.layout();
    try std.testing.expectApproxEqAbs(@as(f32, 32), card.globalRect().h, 0.1);
    header.behavior.events.on_click.?.invoke();
    try detail.setTextContent(a, "");
    cx.layout();
    try std.testing.expect(card.globalRect().h < 70);
}
test "AI conversation attachment restore retains captured content after old turn is released" {
    const files = @import("ai/local_text_attachments.zig");
    var original = try files.Draft.init(a, .{ .session = 1 });
    defer original.deinit();
    const ticket = try original.begin();
    var ref = try files.ContentRef.create(a, "/tmp/source.txt", "original snapshot", 123);
    defer ref.release();
    _ = try original.complete(ticket, &ref);
    var bundle = try original.freeze();
    defer bundle.deinit();
    var restored = try files.Draft.init(a, .{ .session = 1 });
    defer restored.deinit();
    const stale = try restored.begin();
    try restored.restore(&bundle);
    bundle.deinit();
    try std.testing.expect(!restored.contains(stale));
    try std.testing.expectEqualStrings("original snapshot", restored.items.items[0].reference.content().?.bytes);
}
test {
    _ = steps;
}

test "AI conversation inline edit preserves actual call results and clone truncation" {
    var history = try wire.History.copy(a, &.{
        .{ .content = "first" },                                                                                                        .{ .role = .assistant, .content = "answer" },                                  .{ .content = "old request" },
        .{ .role = .assistant, .content = "", .tool_calls = &.{.{ .id = "actual-call", .name = "read_terminal", .arguments = "{}" }} }, .{ .role = .tool, .tool_call_id = "actual-call", .content = "actual stdout" },
    }, "formal answer");
    defer history.deinit();
    var edited = (try history.editedUser(a, 2, "old request", "new request")).?;
    defer edited.deinit();
    try std.testing.expectEqualStrings("old request", history.messages[2].content);
    try std.testing.expectEqualStrings("new request", edited.messages[2].content);
    try std.testing.expectEqualStrings("actual-call", edited.messages[4].tool_call_id.?);
    try std.testing.expectEqualStrings("actual stdout", edited.messages[4].content);
    try std.testing.expect((try history.editedUser(a, 0, "old request", "wrong target")) == null);
    const facts = @import("ai/tool_results.zig");
    const loop = @import("ai/tool_loop.zig");
    var ledger = loop.Loop.init(a, .{ .owner = .{ .session = 1 }, .members = .{} }, 7, .{});
    defer ledger.deinit();
    try ledger.records.append(ledger.arena.allocator(), .{ .key = .{ .owner = .{ .session = 1 }, .turn_id = 7, .call_id = "actual-call" }, .name = "read_terminal", .arguments = "{}", .arguments_hash = @splat(0), .dispatched = true, .outcome = try loop.Outcome.copy(a, &.{.{ .session_id = 1, .status = .succeeded, .stdout = "actual stdout" }}) });
    var store = facts.Store.init(a);
    defer store.deinit();
    _ = try store.capture(&ledger, &.{});
    const messages = [_]@import("ai/assistant_store.zig").Message{.{ .user = true, .text = @constCast("request"), .turn = .{ .id = 7 } }};
    store.retained_bytes = facts.Store.max_bytes; // Discarded turns must not consume the fork budget.
    var fork = try store.cloneTurns(&messages);
    defer fork.deinit();
    store.keepTurns(&.{});
    try std.testing.expectEqual(@as(usize, 0), store.records.items.len);
    try std.testing.expectEqualStrings("actual stdout", fork.records.items[0].targets[0].result.stdout);
    try std.testing.expect(fork.retained_bytes < facts.Store.max_bytes);
}

test "AI conversation rollback clears manager transcript while preserving prepared next request" {
    const Manager = @import("ai/turn_manager.zig").Manager;
    var manager = Manager.init(a);
    defer manager.deinit();
    manager.turn_id = 9;
    manager.scope = .{ .owner = .{ .session = 1 }, .members = .{} };
    _ = try manager.cards.append(.{ .text = "discarded response" });
    try manager.reasoning.appendSlice(a, "discarded thinking");
    try manager.round_text.appendSlice(a, "discarded context");
    manager.discardTranscript();
    try std.testing.expectEqual(@as(u64, 9), manager.turn_id);
    try std.testing.expect(manager.scope.?.owner.eql(.{ .session = 1 }));
    try std.testing.expectEqual(@as(usize, 0), manager.cards.count());
    try std.testing.expectEqual(@as(usize, 0), manager.reasoning.items.len);
    try std.testing.expectEqual(@as(usize, 0), manager.round_text.items.len);
}

test "AI conversation lifecycle row formats elapsed time and actual token usage without borders" {
    const Status = @import("ui/ai_turn_status_view.zig");
    var buffer: [96]u8 = undefined;
    try std.testing.expectEqualStrings("已运行3分钟20秒", try Status.elapsedLabel(&buffer, 200000));
    try std.testing.expectEqualStrings("已运行30分钟20秒", try Status.elapsedLabel(&buffer, 1820000));
    var turn: turns.Turn = .{ .sent_at_ms = 1000, .started_mono_ms = 50 };
    try std.testing.expectEqual(@as(u64, 200000), Status.elapsedMs(&turn, 999999, 200050));
    try std.testing.expectEqualStrings("Token 用量未返回", try Status.usageLabel(&buffer, &turn));
    turn.ended_at_ms = 400000;
    turn.elapsed_ms = 1820000;
    turn.input_tokens = 2400;
    turn.output_tokens = 160;
    try std.testing.expectEqual(@as(u64, 1820000), Status.elapsedMs(&turn, 9999999, 9999999));
    try std.testing.expectEqualStrings("Token 2560", try Status.usageLabel(&buffer, &turn));
    const cx = try ui.Cx.init(a, std.testing.io);
    defer cx.deinit();
    const scope = try ui.Scope.init(a, null, cx.owner);
    defer scope.dispose();
    cx.setViewport(600, 200);
    cx.root = try ui.box(cx, .{ .width = .fill(), .height = .fill(), .direction = .column }, .{});
    const row = try Status.mount(cx, scope, &turn, null);
    try cx.root.?.appendChild(a, row);
    cx.layout();
    try std.testing.expectEqualStrings("～回合结束～", find(row, "ai.turn.label").?.getText().?.content);
    try std.testing.expectEqual(@as(f32, 16), find(row, "ai.turn.logo").?.globalRect().w);
    try std.testing.expectEqual(@as(f32, 0), @import("ui/ai_tool_results_styles.zig").card(cx.tokens).border.?.width);
}

test "AI conversation planned step updates parameters before execution with the same identity" {
    var list: std.ArrayList(steps.Step) = .empty;
    defer {
        for (list.items) |*step| step.deinit(a);
        list.deinit(a);
    }
    try steps.apply(a, &list, .{ .call_id = "stream-call", .name = "run_command", .command = "{\"command\":", .phase = .assembling, .at_ms = 1 });
    try steps.apply(a, &list, .{ .call_id = "stream-call", .name = "run_command", .command = "date", .phase = .assembling, .at_ms = 5 });
    try std.testing.expectEqualStrings("date", list.items[0].command);
    try std.testing.expectEqual(steps.Phase.assembling, list.items[0].phase);
    try steps.apply(a, &list, .{ .call_id = "stream-call", .phase = .running, .at_ms = 10 });
    try std.testing.expectEqual(@as(usize, 1), list.items.len);
    try std.testing.expectEqual(@as(u64, 1), list.items[0].started_ms);
    try std.testing.expectEqual(steps.Phase.running, list.items[0].phase);
}

test "AI conversation wave is subtle phased and disabled by reduced motion" {
    const Status = @import("ui/ai_turn_status_view.zig");
    try std.testing.expectApproxEqAbs(@as(f32, 1.5), Status.waveOffset(350, 0, false), 0.001);
    try std.testing.expect(@abs(Status.waveOffset(350, 0, false) - Status.waveOffset(350, 2, false)) > 0.5);
    for (0..7) |index| {
        try std.testing.expectEqual(@as(f32, 0), Status.waveOffset(350, index, true));
        try std.testing.expect(@abs(Status.waveOffset(1000, index, false)) <= 1.5);
    }
}
