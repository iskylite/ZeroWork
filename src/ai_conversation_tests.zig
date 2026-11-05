const std = @import("std");
const ui = @import("ui");
const a = std.testing.allocator;
const turns = @import("ai/conversation_turn.zig");
const wire = @import("ai/wire_history.zig");
const steps = @import("ai/step_events.zig");
test {
    _ = @import("ai/conversation_turn.zig");
    _ = @import("host/terminal_execution.zig");
}
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
    turn.thinking_scroll = try turns.ThinkingScroll.create(a);
    turn.thinking_scroll.?.offset = 80;
    turn.thinking_scroll.?.following = false;
    try steps.apply(a, &turn.steps, .{ .call_id = "call", .name = "run_command", .command = "date", .phase = .running, .at_ms = 10 });
    try steps.apply(a, &turn.steps, .{ .call_id = "call", .phase = .succeeded, .detail = "actual result", .at_ms = 50 });
    var fork = try turn.clone(a);
    defer fork.deinit(a);
    try std.testing.expect(turn.thinking_scroll.? != fork.thinking_scroll.?);
    turn.deinit(a);
    try std.testing.expectEqual(@as(f32, 80), fork.thinking_scroll.?.offset);
    try std.testing.expect(!fork.thinking_scroll.?.following);
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
    cx.reduced_motion = true;
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
    try std.testing.expectEqualStrings("进行中 · 核对当前时间", find(card, "ai.step.projection").?.getText().?.content);
    const detail = find(card, "ai.step.detail").?;
    try detail.setTextContent(a, "first line\nsecond line\nthird line");
    cx.layout();
    _ = cx.render();
    try std.testing.expectApproxEqAbs(@as(f32, 90), card.globalRect().h, 0.1);
    const wrapped = try std.mem.join(a, " ", &@as([16][]const u8, @splat("wrapped thinking")));
    defer a.free(wrapped);
    try detail.setTextContent(a, wrapped);
    root.setStyleInline(a, .{ .width = .{ .px = 180 } });
    cx.layout();
    _ = cx.render();
    const narrow_height = card.globalRect().h;
    try std.testing.expect(narrow_height > 90 and narrow_height <= 182);
    root.setStyleInline(a, .{ .width = .{ .px = 572 } });
    cx.layout();
    _ = cx.render();
    try std.testing.expect(card.globalRect().h < narrow_height);
    const long_thinking = try std.mem.join(a, "\n", &@as([30][]const u8, @splat("long thinking line")));
    defer a.free(long_thinking);
    try detail.setTextContent(a, long_thinking);
    cx.layout();
    _ = cx.render();
    const viewport = find(card, "ai.step.details").?;
    try std.testing.expectApproxEqAbs(@as(f32, 150), viewport.globalRect().h, 0.1);
    try std.testing.expect(detail.globalRect().h > viewport.globalRect().h);
    header.behavior.events.on_click.?.invoke();
    cx.layout();
    _ = cx.render();
    try std.testing.expectApproxEqAbs(@as(f32, 32), card.globalRect().h, 0.1);
    header.behavior.events.on_click.?.invoke();
    try detail.setTextContent(a, "");
    cx.layout();
    _ = cx.render();
    try std.testing.expect(card.globalRect().h < 70);
}
test "AI conversation table rows contain wrapped inline code at narrow widths" {
    const cx = try ui.Cx.init(a, std.testing.io);
    defer cx.deinit();
    const scope = try ui.Scope.init(a, null, cx.owner);
    defer scope.dispose();
    cx.setViewport(600, 1200);
    const root = try ui.box(cx, .{ .width = .{ .px = 572 }, .height = .fill(), .direction = .column }, .{});
    cx.root = root;
    const message = try @import("ui/ai_message_view.zig").mountWithWidth(cx, scope, "| 文件 | 看起来是什么 |\n| --- | --- |\n" ++
        "| `clusconf-4.5.2-11.20260915+git9751ee03.x86_64.rpm`、`clusconf.yaml` | 集群配置工具及其配置 |\n" ++
        "| `clusbench-4.5.1-1120.x86_64.rpm`、`clusbench.yaml` | 集群基准测试包及其配置 |\n" ++
        "| `cluskit-0.6.2-1...run`、`cluskit-0.6.2-3...run` | 两个版本的 cluskit 安装脚本 |\n\n后续正文", 572);
    try root.appendChild(a, message);
    for ([_]f32{ 572, 400, 240, 572 }) |width| {
        root.setStyleInline(a, .{ .width = .{ .px = width } });
        for (0..3) |_| {
            cx.advanceFrameClock();
            cx.layout();
            _ = cx.render();
        }
        const table = find(root, "ai.message.table").?;
        const content = table.children.items[0];
        for (content.children.items) |row| {
            for (row.children.items) |cell| {
                const bounds = cell.globalRect();
                const markdown = cell.children.items[0];
                for (markdown.children.items) |paragraph| {
                    const rect = paragraph.globalRect();
                    const layout = paragraph.getLayoutOutput().artifacts.text_layout.?;
                    try std.testing.expect(rect.y + layout.total_height <= bounds.y + bounds.h - 6 + 0.1);
                }
            }
        }
        try std.testing.expectApproxEqAbs(content.globalRect().h, table.globalRect().h, 0.1);
        const following = message.children.items[message.children.items.len - 1];
        try std.testing.expect(following.globalRect().y >= table.globalRect().y + table.globalRect().h);
        if (width == 240) {
            const bounds = table.globalRect();
            const before = content.globalRect().x;
            cx.handleScroll(.{ .x = bounds.x + 20, .y = bounds.y + 20, .dx = -80, .dy = 0 });
            cx.layout();
            _ = cx.render();
            try std.testing.expect(content.globalRect().x < before);
        }
    }
}

const ThinkingFixture = struct {
    cx: *ui.Cx,
    scope: *ui.Scope,
    content: *ui.Node = undefined,
    card_scope: ?*ui.Scope = null,
    card: ?*ui.Node = null,
    turn: turns.Turn = .{},
    fn init(self: *ThinkingFixture) !void {
        const cx = try ui.Cx.init(a, std.testing.io);
        self.* = .{ .cx = cx, .scope = try ui.Scope.init(a, null, cx.owner) };
        cx.reduced_motion = true;
        cx.setViewport(600, 400);
        cx.root = try ui.box(cx, .{ .width = .fill(), .height = .fill(), .direction = .column }, .{});
        const outer = try ui.widgets.ScrollArea(.{ .height = 300 }).mount(self.scope, cx);
        try cx.root.?.appendChild(a, outer.container);
        self.content = outer.content;
        self.turn.thinking_scroll = try turns.ThinkingScroll.create(a);
    }
    fn rebuild(self: *ThinkingFixture, lines: usize, phase: steps.Phase) !void {
        try self.mount(lines, phase);
        self.settle();
    }
    fn mount(self: *ThinkingFixture, lines: usize, phase: steps.Phase) !void {
        if (self.card_scope) |scope| scope.dispose();
        if (self.card) |card| {
            self.cx.detachChild(self.content, card);
            self.cx.destroyDetached(card);
        }
        const text = try std.mem.join(a, "\n", @as([60][]const u8, @splat("thinking line"))[0..lines]);
        defer a.free(text);
        self.card_scope = try self.scope.childScope();
        self.card = try @import("ui/ai_step_view.zig").mount(self.cx, self.card_scope.?, .{ .title = "思考", .projection = "latest thought", .detail = text, .copy_detail = false, .phase = phase, .elapsed_ms = 100, .expanded = &self.turn.thinking_expanded, .scroll_position = self.turn.thinking_scroll, .test_id = "ai.thinking" });
        try self.content.appendChild(a, self.card.?);
    }
    fn settle(self: *ThinkingFixture) void {
        for (0..3) |_| {
            self.cx.advanceFrameClock();
            self.cx.layout();
            _ = self.cx.render();
        }
    }
    fn wheel(self: *ThinkingFixture, delta: f32) void {
        const r = find(self.card.?, "ai.step.details").?.globalRect();
        self.cx.handleScroll(.{ .x = r.x + 30, .y = r.y + r.h / 2, .dy = delta, .dx = 0 });
    }
    fn expectTail(self: *ThinkingFixture) !void {
        const viewport = find(self.card.?, "ai.step.details").?.globalRect();
        const text = find(self.card.?, "ai.step.detail").?.globalRect();
        try std.testing.expect(self.turn.thinking_scroll.?.following);
        try std.testing.expect(self.turn.thinking_scroll.?.offset > 0);
        try std.testing.expect(text.y + text.h <= viewport.y + viewport.h + 0.5);
        try std.testing.expect(text.y + text.h >= viewport.y + viewport.h - 12);
    }
    fn deinit(self: *ThinkingFixture) void {
        self.scope.dispose();
        self.turn.deinit(a);
        self.cx.deinit();
    }
};
test "AI conversation expanded thinking follows streamed remounts and preserves reader scroll" {
    var f: ThinkingFixture = undefined;
    try f.init();
    defer f.deinit();
    try f.rebuild(30, .running);
    try std.testing.expectEqual(@as(f32, 0), f.turn.thinking_scroll.?.offset);
    f.card.?.children.items[0].behavior.events.on_click.?.invoke();
    f.settle();
    try f.expectTail();
    try f.rebuild(40, .running);
    try f.expectTail();
    // Rebuild immediately after input, before another layout hook can run.
    f.wheel(80);
    try f.rebuild(45, .running);
    const held = f.turn.thinking_scroll.?.offset;
    try std.testing.expect(!f.turn.thinking_scroll.?.following);
    try std.testing.expect(held > 0);
    const Remount = struct {
        fixture: *ThinkingFixture,
        failed: bool = false,
        fn run(raw: *anyopaque, _: u8, _: bool) ui.AfterLayoutResult {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.fixture.cx.removeAfterLayoutHook(self);
            self.fixture.mount(50, .running) catch {
                self.failed = true;
            };
            return .needs_layout;
        }
    };
    var remount: Remount = .{ .fixture = &f };
    try f.cx.addAfterLayoutHook(&remount, Remount.run);
    f.settle();
    try std.testing.expect(!remount.failed);
    try std.testing.expectApproxEqAbs(held, f.turn.thinking_scroll.?.offset, 0.1);
    f.wheel(-10000);
    try f.rebuild(55, .running);
    try f.expectTail();
    f.wheel(10000);
    f.settle();
    try std.testing.expect(!f.turn.thinking_scroll.?.following);
    try std.testing.expectEqual(@as(f32, 0), f.turn.thinking_scroll.?.offset);
    f.wheel(-10000);
    f.settle();
    try f.expectTail();
    try f.rebuild(60, .succeeded);
    try f.expectTail();
    f.card.?.children.items[0].behavior.events.on_click.?.invoke();
    f.settle();
    try f.rebuild(60, .succeeded);
    try std.testing.expect(!f.turn.thinking_expanded);
    f.card.?.children.items[0].behavior.events.on_click.?.invoke();
    f.settle();
    try f.expectTail();
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
    try std.testing.expectEqualStrings("处理用时3分钟20秒", try Status.elapsedLabel(&buffer, 200000));
    try std.testing.expectEqualStrings("处理用时30分钟20秒", try Status.elapsedLabel(&buffer, 1820000));
    var turn: turns.Turn = .{ .sent_at_ms = 1000, .started_mono_ms = 50 };
    try std.testing.expectEqual(@as(u64, 200000), Status.elapsedMs(&turn, 999999, 200050));
    try std.testing.expectEqualStrings("本回合用量未返回", try Status.usageLabel(&buffer, &turn));
    turn.ended_at_ms = 400000;
    turn.elapsed_ms = 1820000;
    turn.input_tokens = 2400;
    turn.output_tokens = 160;
    turn.request_count = 2;
    var detail_buffer: [320]u8 = undefined;
    try std.testing.expect(std.mem.indexOf(u8, try Status.usageDetails(&detail_buffer, &turn), "请求次数 2") != null);
    try std.testing.expectEqual(@as(u64, 1820000), Status.elapsedMs(&turn, 9999999, 9999999));
    try std.testing.expectEqualStrings("本回合用量 2.6K", try Status.usageLabel(&buffer, &turn));
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

test "AI conversation activity label follows tool phases and prioritizes pending decisions" {
    const Status = @import("ui/ai_turn_status_view.zig");
    var turn: turns.Turn = .{};
    defer turn.deinit(a);
    try std.testing.expectEqualStrings("～大浪淘金中～", Status.turnLabel(&turn).text);
    try steps.apply(a, &turn.steps, .{ .call_id = "command", .name = "run_command", .phase = .assembling, .at_ms = 1 });
    try std.testing.expectEqualStrings("～准备操作中～", Status.turnLabel(&turn).text);
    try steps.apply(a, &turn.steps, .{ .call_id = "command", .phase = .approval, .at_ms = 2 });
    try std.testing.expectEqualStrings("等待确认 · 流程暂停", Status.turnLabel(&turn).text);
    try std.testing.expect(!Status.turnLabel(&turn).animated);
    try steps.apply(a, &turn.steps, .{ .call_id = "command", .phase = .approved, .at_ms = 3 });
    try std.testing.expectEqualStrings("～准备操作中～", Status.turnLabel(&turn).text);
    try steps.apply(a, &turn.steps, .{ .call_id = "command", .phase = .running, .at_ms = 4 });
    try std.testing.expectEqualStrings("～执行命令中～", Status.turnLabel(&turn).text);
    // A planned next call must not hide a currently executing command.
    try steps.apply(a, &turn.steps, .{ .call_id = "next", .name = "read_terminal", .phase = .assembling, .at_ms = 5 });
    try std.testing.expectEqualStrings("～执行命令中～", Status.turnLabel(&turn).text);
    try steps.apply(a, &turn.steps, .{ .call_id = "next", .phase = .approval, .at_ms = 6 });
    try std.testing.expectEqualStrings("等待确认 · 流程暂停", Status.turnLabel(&turn).text);
    try steps.apply(a, &turn.steps, .{ .call_id = "next", .phase = .rejected, .at_ms = 7 });
    try steps.apply(a, &turn.steps, .{ .call_id = "command", .phase = .failed, .at_ms = 8 });
    try std.testing.expectEqualStrings("～大浪淘金中～", Status.turnLabel(&turn).text);
    try std.testing.expect(Status.turnLabel(&turn).animated);
    turn.ended_at_ms = 9;
    try std.testing.expectEqualStrings("～回合结束～", Status.turnLabel(&turn).text);
    try std.testing.expect(!Status.turnLabel(&turn).animated);

    for ([_]struct { name: []const u8, label: []const u8 }{
        .{ .name = "run_command", .label = "～执行命令中～" },
        .{ .name = "read_terminal", .label = "～读取终端中～" },
        .{ .name = "read_remote_file", .label = "～读取文件中～" },
        .{ .name = "list_remote_files", .label = "～查看目录中～" },
        .{ .name = "plugin.custom_tool", .label = "～执行操作中～" },
    }) |case| {
        var tool_turn: turns.Turn = .{};
        defer tool_turn.deinit(a);
        try steps.apply(a, &tool_turn.steps, .{ .call_id = "tool", .name = case.name, .phase = .running, .at_ms = 1 });
        try std.testing.expectEqualStrings(case.label, Status.turnLabel(&tool_turn).text);
        for ([_]steps.Phase{ .succeeded, .failed, .cancelled, .rejected }) |phase| {
            tool_turn.steps.items[0].phase = phase;
            try std.testing.expectEqualStrings("～大浪淘金中～", Status.turnLabel(&tool_turn).text);
        }
    }
}

test "AI conversation activity label renders matching accessible text and pauses approval motion" {
    const Status = @import("ui/ai_turn_status_view.zig");
    for ([_]steps.Phase{ .assembling, .approval, .approved, .running, .succeeded }) |phase| {
        var turn: turns.Turn = .{};
        defer turn.deinit(a);
        try steps.apply(a, &turn.steps, .{ .call_id = "command", .name = "run_command", .phase = phase, .at_ms = 1 });
        const cx = try ui.Cx.init(a, std.testing.io);
        defer cx.deinit();
        const scope = try ui.Scope.init(a, null, cx.owner);
        defer scope.dispose();
        cx.setViewport(320, 80);
        cx.root = try ui.box(cx, .{ .width = .fill(), .height = .fill(), .direction = .column }, .{});
        const row = try Status.mount(cx, scope, &turn, null);
        try cx.root.?.appendChild(a, row);
        cx.layout();
        const label = find(row, "ai.turn.label").?;
        const expected = Status.turnLabel(&turn);
        try std.testing.expectEqualStrings(expected.text, label.behavior.interaction.a11y.?.label.?);
        var text: std.ArrayList(u8) = .empty;
        defer text.deinit(a);
        for (label.children.items) |glyph| try text.appendSlice(a, glyph.getText().?.content);
        try std.testing.expectEqualStrings(expected.text, text.items);
        try std.testing.expectEqual(try std.unicode.utf8CountCodepoints(expected.text), label.children.items.len);
        try std.testing.expectEqual(@as(usize, if (expected.animated) 2 else 1), cx.after_layout_hooks.items.len);
        const bounds = label.globalRect();
        const elapsed = find(row, "ai.turn.elapsed").?.globalRect();
        try std.testing.expect(bounds.x + bounds.w + 7.5 <= elapsed.x);
        try std.testing.expect(elapsed.x + elapsed.w <= 320);
    }
}

test "AI conversation activity label recovers when tool arguments fail before host execution" {
    const provider = @import("ai/provider.zig");
    const Manager = @import("ai/turn_manager.zig").Manager;
    const Loop = @import("ai/tool_loop.zig");
    const Status = @import("ui/ai_turn_status_view.zig");
    const Fixture = struct {
        turn: turns.Turn = .{},
        rounds: usize = 0,
        rejected: usize = 0,
        fn chat(raw: *anyopaque, request: provider.ChatRequest, sink: *const fn (*anyopaque, provider.Delta) void, context: *anyopaque) !provider.ChatStats {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.rounds += 1;
            if (self.rounds == 1) {
                sink(context, .{ .tool_plan = .{ .call_id = "invalid-arguments", .name = "run_command", .arguments = "{}" } });
                try std.testing.expectEqualStrings("～准备操作中～", Status.turnLabel(&self.turn).text);
            } else {
                try std.testing.expectEqual(@as(usize, 1), self.rejected);
                try std.testing.expectEqual(provider.Role.tool, request.messages[2].role);
                try std.testing.expectEqualStrings("～大浪淘金中～", Status.turnLabel(&self.turn).text);
                sink(context, .{ .text = "继续处理参数错误" });
            }
            sink(context, .done);
            return .{};
        }
        fn models(_: *anyopaque, allocator: std.mem.Allocator) ![]provider.ModelInfo {
            return allocator.alloc(provider.ModelInfo, 0);
        }
        fn execute(_: *anyopaque, _: Loop.Invocation, _: std.mem.Allocator, _: ?*provider.CancelToken) !Loop.Outcome {
            return error.InvalidToolMustNotExecute;
        }
        fn reset(_: *anyopaque) void {}
        fn delta(raw: *anyopaque, value: provider.Delta) !void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            if (value == .tool_plan) try steps.apply(a, &self.turn.steps, .{ .call_id = value.tool_plan.call_id.?, .name = value.tool_plan.name.?, .phase = .assembling, .at_ms = 1 });
        }
        fn reject(raw: *anyopaque, call: provider.ToolCall, detail: []const u8) !void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.rejected += 1;
            try std.testing.expect(detail.len > 0);
            try steps.apply(a, &self.turn.steps, .{ .call_id = call.id, .name = call.name, .detail = detail, .phase = .failed, .at_ms = 2 });
        }
    };
    var fixture: Fixture = .{};
    defer fixture.turn.deinit(a);
    var manager = Manager.init(a);
    defer manager.deinit();
    manager.scope = .{ .owner = .{ .session = 101 }, .members = .{ .ids = .{101} ++ @as([15]u64, @splat(0)), .len = 1 } };
    manager.tool_host = .{ .context = &fixture, .execute = Fixture.execute };
    manager.observer = .{ .context = &fixture, .reset = Fixture.reset, .delta = Fixture.delta, .tool_rejected = Fixture.reject };
    _ = try manager.run(.{ .ctx = &fixture, .chat = Fixture.chat, .models = Fixture.models }, .{ .model = "invalid-tool-fixture", .system = "", .messages = &.{.{ .content = "检查参数错误后的状态" }}, .tools = &.{.{ .tool = .run_command, .session_ids = &.{101} }} });
    try std.testing.expectEqual(@as(usize, 2), fixture.rounds);
    try std.testing.expectEqual(steps.Phase.failed, fixture.turn.steps.items[0].phase);
}

test "AI conversation processing time freezes through indefinite approval wait and preserves message boundaries" {
    const events = @import("ai/step_events.zig");
    const Status = @import("ui/ai_turn_status_view.zig");
    var turn: @import("ai/conversation_turn.zig").Turn = .{ .started_mono_ms = 1000 };
    defer turn.deinit(a);
    try turn.prose.appendSlice(a, "先确认命令，再执行。");
    try events.apply(a, &turn.steps, .{ .call_id = "one", .name = "host.run_in_terminal", .phase = .assembling, .text_offset = turn.prose.items.len, .at_ms = 1200 });
    try events.apply(a, &turn.steps, .{ .call_id = "one", .phase = .approval, .at_ms = 2000 });
    try std.testing.expectEqual(@as(u64, 1000), Status.elapsedMs(&turn, 0, 122000));
    try std.testing.expectEqualStrings("等待确认 · 流程暂停", Status.turnLabel(&turn).text);
    try std.testing.expectEqual(@as(u64, 1000), Status.elapsedMs(&turn, 0, 242000));
    try std.testing.expectEqual(@as(u64, 0), turn.steps.items[0].elapsedAt(242000));
    try events.apply(a, &turn.steps, .{ .call_id = "one", .phase = .approved, .at_ms = 242000 });
    try events.apply(a, &turn.steps, .{ .call_id = "one", .phase = .running, .at_ms = 242010 });
    try events.apply(a, &turn.steps, .{ .call_id = "one", .phase = .succeeded, .at_ms = 242100 });
    try turn.prose.appendSlice(a, "命令完成。");
    var copy = try turn.clone(a);
    defer copy.deinit(a);
    try std.testing.expectEqualStrings(turn.prose.items, copy.prose.items);
    try std.testing.expectEqual(@as(usize, "先确认命令，再执行。".len), copy.steps.items[0].text_offset);
    try std.testing.expectEqual(@as(u64, 100), copy.steps.items[0].elapsedAt(300000));
    try std.testing.expectEqual(@as(u64, 1100), Status.elapsedMs(&copy, 0, 242100));
}

const aggregation = @import("ai/step_groups.zig");
test {
    _ = @import("ai/step_failure.zig");
    _ = @import("host/terminal_execution.zig");
}
fn groupEvent(turn: *turns.Turn, event: steps.Event, expanded: bool) !void {
    try turn.applyEvent(a, event);
    try aggregation.sync(a, turn, expanded);
}
test "AI step aggregation groups one or more steps between prose, preserving defaults and manual state" {
    var turn: turns.Turn = .{};
    defer turn.deinit(a);
    try groupEvent(&turn, .{ .kind = .text, .detail = "before", .phase = .running, .at_ms = 1 }, false);
    try groupEvent(&turn, .{ .call_id = "read", .name = "read_terminal", .phase = .running, .at_ms = 2 }, false);
    try std.testing.expectEqual(@as(usize, 1), turn.step_groups.items.len);
    const first = turn.step_groups.items[0];
    try std.testing.expect(!first.expanded);
    first.expanded = true;
    try groupEvent(&turn, .{ .call_id = "read", .phase = .succeeded, .at_ms = 5 }, false);
    try groupEvent(&turn, .{ .kind = .round_start, .phase = .running, .at_ms = 6 }, false);
    try groupEvent(&turn, .{ .kind = .thinking, .detail = "thought", .phase = .running, .at_ms = 7 }, false);
    try groupEvent(&turn, .{ .kind = .thinking, .detail = " tail", .phase = .running, .at_ms = 8 }, false);
    try std.testing.expect(first.expanded);
    try std.testing.expectEqual(@as(usize, 1), turn.step_groups.items.len);
    var summary = aggregation.summarize(&turn, 1, turn.timeline.items.len, 10);
    try std.testing.expectEqual(@as(usize, 2), summary.count);
    try std.testing.expectEqual(steps.Phase.running, summary.phase);
    try std.testing.expectEqualStrings("thought tail", summary.latest.?.thinking.text.items);
    try std.testing.expectEqualStrings("thought tail", summary.thinking_projection.?);
    // Empty deltas do not end a group; a real model message does.
    try groupEvent(&turn, .{ .kind = .text, .detail = " \n", .phase = .running, .at_ms = 9 }, false);
    try std.testing.expectEqual(@as(usize, 1), turn.step_groups.items.len);
    try groupEvent(&turn, .{ .kind = .text, .detail = "between", .phase = .running, .at_ms = 10 }, false);
    try groupEvent(&turn, .{ .kind = .thinking, .detail = "second", .phase = .running, .at_ms = 11 }, true);
    try std.testing.expectEqual(@as(usize, 2), turn.step_groups.items.len);
    const second = turn.step_groups.items[1];
    try std.testing.expect(second.expanded);
    second.expanded = false;
    try groupEvent(&turn, .{ .call_id = "search", .name = "run_command", .phase = .running, .at_ms = 12 }, true);
    try groupEvent(&turn, .{ .call_id = "search", .phase = .succeeded, .at_ms = 14 }, true);
    turn.finishSegment(14);
    try aggregation.sync(a, &turn, true);
    try std.testing.expect(!second.expanded);
    try std.testing.expect(first.expanded);
    summary = aggregation.summarize(&turn, second.first, turn.timeline.items.len, 14);
    try std.testing.expectEqual(@as(usize, 2), summary.count);
    try std.testing.expectEqual(steps.Phase.succeeded, summary.phase);
    try std.testing.expectEqual(@as(u64, 3), summary.elapsed_ms);
    try std.testing.expectEqual(@as(?[]const u8, null), summary.thinking_projection);
}

test "AI step aggregation projects only the current live thinking line" {
    var turn: turns.Turn = .{ .sent_at_ms = 1 };
    defer turn.deinit(a);
    try groupEvent(&turn, .{ .kind = .thinking, .detail = "上一行\n正在核对最新错误\n\t ", .phase = .running, .at_ms = 2 }, false);
    var summary = aggregation.summarize(&turn, 0, turn.timeline.items.len, 3);
    try std.testing.expectEqualStrings("正在核对最新错误", summary.thinking_projection.?);
    try groupEvent(&turn, .{ .kind = .thinking, .detail = "\n已定位新的线索", .phase = .running, .at_ms = 4 }, false);
    summary = aggregation.summarize(&turn, 0, turn.timeline.items.len, 5);
    try std.testing.expectEqualStrings("已定位新的线索", summary.thinking_projection.?);
    try groupEvent(&turn, .{ .kind = .text, .detail = "继续执行检查。", .phase = .running, .at_ms = 6 }, false);
    summary = aggregation.summarize(&turn, 0, aggregation.rangeEnd(&turn, 0), 7);
    try std.testing.expectEqual(@as(?[]const u8, null), summary.thinking_projection);
    try std.testing.expectEqual(@as(usize, 1), summary.count);
}
test "AI step aggregation keeps cloned disclosure independent and resets only discarded groups" {
    var turn: turns.Turn = .{};
    defer turn.deinit(a);
    try groupEvent(&turn, .{ .kind = .thinking, .detail = "retained", .phase = .running, .at_ms = 1 }, true);
    try groupEvent(&turn, .{ .kind = .text, .detail = "retained message", .phase = .running, .at_ms = 2 }, true);
    try groupEvent(&turn, .{ .kind = .round_start, .phase = .running, .at_ms = 3 }, false);
    try groupEvent(&turn, .{ .kind = .thinking, .detail = "discarded", .phase = .running, .at_ms = 4 }, false);
    const discarded = turn.step_groups.items[1];
    discarded.retain();
    defer discarded.release();
    var clone = try turn.clone(a);
    defer clone.deinit(a);
    try std.testing.expect(clone.step_groups.items[0] != turn.step_groups.items[0]);
    clone.step_groups.items[0].expanded = false;
    try std.testing.expect(turn.step_groups.items[0].expanded);
    try groupEvent(&turn, .{ .kind = .reset, .phase = .running, .at_ms = 5 }, true);
    try std.testing.expectEqual(@as(usize, 1), turn.step_groups.items.len);
    try std.testing.expect(!discarded.expanded);
    try groupEvent(&turn, .{ .kind = .thinking, .detail = "retry", .phase = .running, .at_ms = 6 }, true);
    try std.testing.expectEqual(@as(usize, 2), turn.step_groups.items.len);
    try std.testing.expect(turn.step_groups.items[1] != discarded);
    try std.testing.expect(turn.step_groups.items[1].expanded);
}
test "AI step aggregation includes all settled outcomes and leaves only pending approvals outside" {
    var turn: turns.Turn = .{};
    defer turn.deinit(a);
    try groupEvent(&turn, .{ .call_id = "approval", .name = "run_command", .phase = .approval, .at_ms = 1 }, false);
    try std.testing.expectEqual(@as(usize, 0), turn.step_groups.items.len);
    try groupEvent(&turn, .{ .call_id = "approval", .phase = .rejected, .at_ms = 2 }, false);
    try std.testing.expectEqual(@as(usize, 1), turn.step_groups.items.len);
    try groupEvent(&turn, .{ .call_id = "run", .name = "run_command", .phase = .running, .at_ms = 3 }, false);
    try groupEvent(&turn, .{ .call_id = "run", .phase = .failed, .at_ms = 6 }, false);
    try groupEvent(&turn, .{ .kind = .thinking, .detail = "investigate", .phase = .running, .at_ms = 7 }, false);
    const summary = aggregation.summarize(&turn, 0, turn.timeline.items.len, 9);
    try std.testing.expectEqual(@as(usize, 3), summary.count);
    try std.testing.expectEqual(steps.Phase.failed, summary.phase);
    try std.testing.expect(summary.live);
    try groupEvent(&turn, .{ .call_id = "unsent", .name = "host.run_in_terminal", .phase = .failed, .at_ms = 10 }, false);
    try groupEvent(&turn, .{ .call_id = "cancelled", .name = "host.run_in_terminal", .phase = .cancelled, .at_ms = 11 }, false);
    try std.testing.expectEqual(@as(usize, 1), turn.step_groups.items.len);
    try std.testing.expectEqual(@as(usize, 5), aggregation.summarize(&turn, 0, turn.timeline.items.len, 12).count);
    try std.testing.expectEqual(steps.Phase.failed, aggregation.summarize(&turn, 0, turn.timeline.items.len, 12).phase);
    try groupEvent(&turn, .{ .kind = .text, .detail = "model message", .phase = .running, .at_ms = 13 }, false);
    try groupEvent(&turn, .{ .call_id = "next", .name = "read_terminal", .phase = .failed, .at_ms = 14 }, false);
    try std.testing.expectEqual(@as(usize, 2), turn.step_groups.items.len);
}
test "AI step aggregation native disclosure keeps existing step cards and adds only soft edges" {
    const cx = try ui.Cx.init(a, std.testing.io);
    defer cx.deinit();
    const scope = try ui.Scope.init(a, null, cx.owner);
    defer scope.dispose();
    cx.reduced_motion = true;
    cx.setViewport(600, 456);
    const root = try ui.box(cx, .{ .width = .{ .px = 570 }, .height = .fill(), .direction = .column }, .{});
    cx.root = root;
    const group = try aggregation.State.create(a, 0, false);
    defer group.release();
    const view = try @import("ui/ai_step_group_view.zig").mount(cx, scope, .{ .group = group, .title = "思考", .projection = "1 个步骤", .phase = .succeeded, .elapsed_ms = 40 });
    try root.appendChild(a, view.root);
    var step_expanded = false;
    const card = try @import("ui/ai_step_view.zig").mount(cx, scope, .{ .title = "思考", .projection = "original summary", .detail = "original thinking", .phase = .succeeded, .elapsed_ms = 40, .expanded = &step_expanded });
    try view.content.appendChild(a, card);
    for (0..3) |_| {
        cx.advanceFrameClock();
        cx.layout();
        _ = cx.render();
    }
    try std.testing.expectApproxEqAbs(@as(f32, 32), view.root.globalRect().h, 0.1);
    const header = find(view.root, "ai.step_group.header").?;
    header.behavior.events.on_click.?.invoke();
    for (0..3) |_| {
        cx.advanceFrameClock();
        cx.layout();
        _ = cx.render();
    }
    try std.testing.expect(group.expanded);
    try std.testing.expectApproxEqAbs(@as(f32, 32), card.globalRect().h, 0.1);
    try std.testing.expectApproxEqAbs(@as(f32, 76), view.root.globalRect().h, 0.1);
    try std.testing.expectApproxEqAbs(card.globalRect().w, header.globalRect().w, 0.1);
    try std.testing.expectEqualStrings("已完成 · original summary", find(card, "ai.step.projection").?.getText().?.content);
    try std.testing.expect(find(card, "ai.step.separator") != null);
    try std.testing.expectEqual(@as(f32, 0), view.root.style.border.width);
    try std.testing.expectEqual(@as(u8, 0), view.root.getBackground().a);
    try std.testing.expectApproxEqAbs(@as(f32, 6), find(view.root, "ai.step_group.edge.top").?.globalRect().h, 0.1);
    const bottom_edge = find(view.root, "ai.step_group.edge.bottom").?.globalRect();
    try std.testing.expect(bottom_edge.y >= card.globalRect().y + card.globalRect().h - 0.1);
    // Appending cards grows the disclosure; there is no step-count/height cap,
    // and the final card always ends above the soft bottom edge.
    var extra_expanded = [_]bool{ false, false, false };
    var last = card;
    for (&extra_expanded) |*expanded| {
        last = try @import("ui/ai_step_view.zig").mount(cx, scope, .{ .title = "搜索终端内容", .projection = "command not found", .detail = "unchanged result", .phase = .succeeded, .elapsed_ms = 10, .expanded = expanded });
        try view.content.appendChild(a, last);
    }
    for (0..3) |_| {
        cx.advanceFrameClock();
        cx.layout();
        _ = cx.render();
    }
    try std.testing.expectApproxEqAbs(@as(f32, 190), view.root.globalRect().h, 0.1);
    try std.testing.expectApproxEqAbs(@as(f32, 32), last.globalRect().h, 0.1);
    try std.testing.expect(find(view.root, "ai.step_group.edge.bottom").?.globalRect().y >= last.globalRect().y + last.globalRect().h - 0.1);
    find(card, "ai.step.header").?.behavior.events.on_click.?.invoke();
    for (0..3) |_| {
        cx.advanceFrameClock();
        cx.layout();
        _ = cx.render();
    }
    try std.testing.expect(step_expanded);
    header.behavior.events.on_click.?.invoke();
    try std.testing.expect(!group.expanded);
    try std.testing.expect(step_expanded);
}
