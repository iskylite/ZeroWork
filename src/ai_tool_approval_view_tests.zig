//! Real Cx layout, hit testing, scrolling and Button events. No native window,
//! clipboard, provider requests or host execution is involved.
const std = @import("std");
const ui = @import("ui");
const ApprovalView = @import("ui/ai_tool_approval_view.zig");
const tools = @import("ui/ai_local_tools.zig");
const a = std.testing.allocator;

const Fixture = struct {
    cx: *ui.Cx,
    scope: *ui.Scope,
    view: *ApprovalView.View,
    panel: *ui.Node,
    live_sequence: ?u64 = null,
    live_hash: [32]u8 = @splat(0),
    attempts: usize = 0,
    decisions: usize = 0,
    last_sequence: ?u64 = null,
    last_hash: [32]u8 = @splat(0),
    last_approved: ?bool = null,

    fn init(self: *Fixture) !void {
        self.* = .{ .cx = try ui.Cx.init(a, std.testing.io), .scope = undefined, .view = undefined, .panel = undefined };
        self.cx.setViewport(860, 480);
        self.cx.root = try ui.box(self.cx, .{ .width = .fill(), .height = .fill() }, .{});
        self.scope = try ui.Scope.init(a, null, self.cx.owner);
        self.panel = try ui.box(self.cx, .{ .position = .absolute, .inset = .{ .left = .{ .px = 130 }, .top = .{ .px = 76 } }, .width = .{ .px = 600 }, .height = .{ .px = 354 }, .direction = .column }, .{});
        try self.cx.root.?.appendChild(a, self.panel);
        try self.panel.appendChild(a, try ui.box(self.cx, .{ .width = .fill(), .height = .{ .px = 48 }, .flex_shrink = 0 }, .{}));
        try self.panel.appendChild(a, try ui.box(self.cx, .{ .width = .fill(), .height = .{ .px = 64 }, .flex_shrink = 0 }, .{}));
        self.view = try ApprovalView.View.mount(self.cx, self.scope, .{ .context = self, .decide = decide });
        try self.panel.appendChild(a, self.view.root);
        try self.panel.appendChild(a, try ui.box(self.cx, .{ .width = .fill(), .height = .{ .px = 90 }, .flex_shrink = 0 }, .{}));
        self.settle();
    }
    fn deinit(self: *Fixture) void {
        self.cx.clearFocus();
        self.scope.dispose();
        self.cx.deinit();
    }
    fn decide(raw: *anyopaque, sequence: u64, hash: [32]u8, approved: bool) !void {
        const self: *Fixture = @ptrCast(@alignCast(raw));
        self.attempts += 1;
        if (self.live_sequence != sequence or !std.mem.eql(u8, &self.live_hash, &hash)) return error.StaleApproval;
        self.decisions += 1;
        self.last_sequence = sequence;
        self.last_hash = hash;
        self.last_approved = approved;
        self.live_sequence = null; // Real host consumes one exact decision.
    }
    fn source(sequence: u64, command: []const u8) tools.Approval {
        return .{ .target = "本机 · zsh", .owner = .{ .session_id = @fromBackingInt(101), .generation = 9 }, .cwd = "/tmp/approval fixture", .sequence = sequence, .arguments_hash = @splat(@intCast(sequence)), .command = command, .call_id = "fixture-call" };
    }
    fn show(self: *Fixture, sequence: u64, command: []const u8) !void {
        const approval = source(sequence, command);
        self.live_sequence = sequence;
        self.live_hash = approval.arguments_hash;
        try self.view.update(approval);
        self.settle();
    }
    fn settle(self: *Fixture) void {
        self.cx.setTestFrameStep(16) catch unreachable;
        for (0..12) |_| {
            self.cx.advanceFrameClock();
            self.cx.layout();
            _ = self.cx.render();
        }
    }
    fn node(self: *Fixture, id: []const u8) *ui.Node {
        return find(self.view.root, id) orelse @panic("missing approval test node");
    }
    fn click(self: *Fixture, node_: *ui.Node) void {
        const r = node_.globalRect();
        self.cx.handleMouseDown(r.x + r.w / 2, r.y + r.h / 2, .{});
        self.cx.handleMouseUp(r.x + r.w / 2, r.y + r.h / 2);
        self.settle();
    }
    fn enter(self: *Fixture, node_: *ui.Node) void {
        self.cx.setFocus(node_);
        self.cx.handleKeyDown(.@"return", .{});
        self.settle();
    }
    fn visibleActions(self: *Fixture) !void {
        const card = self.view.card.globalRect();
        for ([_][]const u8{ "ai.approval.accept", "ai.approval.reject" }) |id| {
            const button = self.node(id);
            const r = button.globalRect();
            try std.testing.expectEqual(@as(f32, 66), r.w);
            try std.testing.expectEqual(@as(f32, 26.5), r.h);
            try std.testing.expect(r.x >= card.x and r.y >= card.y);
            try std.testing.expect(r.x + r.w <= card.x + card.w + 0.1 and r.y + r.h <= card.y + card.h + 0.1);
            try std.testing.expect(r.x >= 0 and r.y >= 0 and r.x + r.w <= 860 and r.y + r.h <= 480);
            try std.testing.expect(!isDescendant(self.view.body, button));
        }
    }
};
fn find(node: *ui.Node, id: []const u8) ?*ui.Node {
    if (node.meta.ownership.meta.test_id) |value| if (std.mem.eql(u8, value, id)) return node;
    for (node.children.items) |child| if (find(child, id)) |result| return result;
    return null;
}
fn isDescendant(parent: *ui.Node, node: *ui.Node) bool {
    var current: ?*ui.Node = node;
    while (current) |value| {
        if (value == parent) return true;
        current = value.parent;
    }
    return false;
}
fn longCommand() ![]u8 {
    var command: std.ArrayList(u8) = .empty;
    errdefer command.deinit(a);
    for (0..80) |index| {
        const line = try std.fmt.allocPrint(a, "printf '%s\\n' 'FULL_COMMAND_LINE_{d:0>3} bounded fixture text with spaces';\n", .{index});
        defer a.free(line);
        try command.appendSlice(a, line);
    }
    return command.toOwnedSlice(a);
}

test "AI approval view is hidden until a captured call and owns complete command text" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    try std.testing.expectEqual(@as(f32, 0), f.view.height());
    try std.testing.expect(f.view.sequence == null);
    var command = "printf captured-command".*;
    try f.show(1, &command);
    @memset(&command, 'x');
    try std.testing.expectEqualStrings("printf captured-command", f.view.command.getText().?.content);
    try std.testing.expectEqualStrings("printf captured-command", f.view.command_owned.?);
    try std.testing.expectEqualStrings("本机 · zsh · #101 · 目录 /tmp/approval fixture", f.view.identity.getText().?.content);
    try std.testing.expectEqual(@as(f32, 572), f.view.card.globalRect().w);
    try std.testing.expectEqual(@as(f32, 167.625), f.view.card.globalRect().h);
    try std.testing.expectEqual(@as(f32, 90.625), f.view.body.globalRect().h);
    try f.visibleActions();
    try std.testing.expectEqual(@as(usize, 0), f.attempts);
}

test "AI approval default short command shows entire risk feedback without scrolling" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    var approval = Fixture.source(1, "printf 'APPROVAL_CLIP_OK\\n'");
    approval.cwd = "/Users/iskylite";
    try f.view.update(approval);
    f.settle();
    const body = f.view.body.globalRect();
    const feedback = f.view.feedback.globalRect();
    const content = f.view.command.parent.?.parent.?;
    try std.testing.expectEqual(@as(f32, 90.625), body.h);
    try std.testing.expectEqual(@as(f32, 167.625), f.view.height());
    try std.testing.expectEqual(@as(f32, 0), content.style.translate_y);
    try std.testing.expectEqualStrings("影响 · 尚未核实", f.view.feedback.getText().?.content);
    const title = f.view.title.globalRect();
    const target = f.view.header_identity.globalRect();
    try std.testing.expectEqualStrings(f.view.identity.getText().?.content, f.view.header_identity.getText().?.content);
    try std.testing.expect(target.x > title.x + title.w);
    try std.testing.expect(@abs((target.y + target.h / 2) - (title.y + title.h / 2)) < 1);
    try std.testing.expect(f.view.identity.style.display == .none);
    const notice = f.node("ai.approval.impact_notice").globalRect();
    try std.testing.expectEqual(@as(f32, 28), notice.h);
    try std.testing.expect(feedback.y >= notice.y and feedback.y + feedback.h <= notice.y + notice.h + 0.01);
    try std.testing.expect(feedback.w > 0 and feedback.h > 0);
    try std.testing.expect(feedback.x >= body.x and feedback.x + feedback.w <= body.x + body.w + 0.01);
    try std.testing.expect(feedback.y >= body.y and feedback.y + feedback.h <= body.y + body.h + 0.01);
    try f.visibleActions();
}

test "AI approval long command scrolls with fixed visible accept reject at minimum window" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    const command = try longCommand();
    defer a.free(command);
    try f.show(1, command);
    const accept_before = f.node("ai.approval.accept").globalRect();
    const reject_before = f.node("ai.approval.reject").globalRect();
    const body = f.view.body.globalRect();
    const command_scroll = f.node("ai.approval.command_scroll");
    const viewport = command_scroll.globalRect();
    const content = f.view.command.parent.?;
    const feedback_before = f.view.feedback.globalRect();
    try std.testing.expectEqual(command_scroll, content.parent.?);
    try std.testing.expect(isDescendant(f.view.body, command_scroll));
    try std.testing.expectEqual(@as(f32, 37), viewport.h);
    try std.testing.expect(content.globalRect().h > viewport.h);
    try std.testing.expect(feedback_before.y >= body.y and feedback_before.y + feedback_before.h <= body.y + body.h + 0.01);
    const content_y = content.globalRect().y;
    f.cx.handleScroll(.{ .x = viewport.x + 20, .y = viewport.y + viewport.h / 2, .dx = 0, .dy = -10_000 });
    f.settle();
    try std.testing.expect(content.globalRect().y < content_y - 20);
    try std.testing.expect(content.style.translate_y < 0);
    try std.testing.expectEqualStrings(command, f.view.command.getText().?.content);
    try std.testing.expectEqualStrings(command, f.view.command_owned.?);
    try std.testing.expectEqual(feedback_before, f.view.feedback.globalRect());
    try std.testing.expectEqual(accept_before, f.node("ai.approval.accept").globalRect());
    try std.testing.expectEqual(reject_before, f.node("ai.approval.reject").globalRect());
    try f.visibleActions();
    f.cx.handleScroll(.{ .x = viewport.x + 20, .y = viewport.y + viewport.h / 2, .dx = 0, .dy = 10_000 });
    f.settle();
    try std.testing.expect(content.globalRect().y > content_y - 20);
    try std.testing.expectEqual(feedback_before, f.view.feedback.globalRect());
    try std.testing.expectEqual(accept_before, f.node("ai.approval.accept").globalRect());
    try f.visibleActions();
    f.click(f.node("ai.approval.accept"));
    try std.testing.expectEqual(@as(usize, 1), f.decisions);
    try std.testing.expect(f.last_approved.?);
}

test "AI approval disclosure keeps target arguments and impact visible without authorizing" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    try f.show(1, "printf disclosure");
    const hash = f.view.arguments_hash;
    f.click(f.node("ai.approval.disclosure"));
    try std.testing.expectEqual(@as(f32, 167.625), f.view.height());
    try std.testing.expectEqual(@as(f32, 167.625), f.view.card.globalRect().h);
    try std.testing.expect(f.view.body.style.display == .flex);
    try f.visibleActions();
    try f.view.update(Fixture.source(1, "printf disclosure"));
    f.settle();
    try std.testing.expectEqual(@as(f32, 167.625), f.view.height());
    f.enter(f.node("ai.approval.disclosure"));
    try std.testing.expectEqual(@as(f32, 167.625), f.view.height());
    try std.testing.expectEqual(@as(f32, 167.625), f.view.card.globalRect().h);
    try std.testing.expect(f.view.body.style.display == .flex);
    try f.visibleActions();
    try std.testing.expectEqual(@as(u64, 1), f.view.sequence.?);
    try std.testing.expectEqualSlices(u8, &hash, &f.view.arguments_hash);
    try std.testing.expectEqual(@as(usize, 0), f.attempts);
}

test "AI approval accepts or rejects once and disables both decisions until new sequence" {
    for ([_]bool{ true, false }) |approved| {
        var f: Fixture = undefined;
        try f.init();
        defer f.deinit();
        try f.show(1, "printf decide");
        const chosen = f.node(if (approved) "ai.approval.accept" else "ai.approval.reject");
        f.click(chosen);
        try std.testing.expect(f.view.decision_pending.peek());
        try std.testing.expectEqual(@as(usize, 1), f.decisions);
        try std.testing.expectEqual(approved, f.last_approved.?);
        try std.testing.expectEqual(@as(u64, 1), f.last_sequence.?);
        try std.testing.expectEqualSlices(u8, &f.live_hash, &f.last_hash);
        for ([_][]const u8{ "ai.approval.accept", "ai.approval.reject" }) |id| {
            const button = f.node(id);
            try std.testing.expect(button.behavior.interaction.a11y.?.disabled);
            f.click(button);
            f.enter(button);
        }
        try std.testing.expectEqual(@as(usize, 1), f.attempts);
        try f.view.update(Fixture.source(1, "printf decide"));
        f.settle();
        try std.testing.expect(f.view.decision_pending.peek());
        try f.show(2, "printf next-decision");
        try std.testing.expect(!f.view.decision_pending.peek());
        f.click(f.node("ai.approval.reject"));
        try std.testing.expectEqual(@as(usize, 2), f.decisions);
        try std.testing.expectEqual(@as(u64, 2), f.last_sequence.?);
    }
}

test "AI approval stale host sequence shows error then fresh sequence can decide" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    try f.show(1, "printf stale");
    f.live_sequence = 2;
    f.live_hash = @splat(2);
    f.click(f.node("ai.approval.accept"));
    try std.testing.expectEqual(@as(usize, 0), f.decisions);
    try std.testing.expect(!f.view.decision_pending.peek());
    try std.testing.expectEqualStrings("StaleApproval", f.view.feedback.getText().?.content);
    try f.show(2, "printf fresh");
    try std.testing.expectEqualStrings("影响 · 尚未核实", f.view.feedback.getText().?.content);
    f.click(f.node("ai.approval.reject"));
    try std.testing.expectEqual(@as(usize, 1), f.decisions);
    try std.testing.expectEqual(@as(u64, 2), f.last_sequence.?);
    try std.testing.expectEqualSlices(u8, &@as([32]u8, @splat(2)), &f.last_hash);
}

test "AI approval hide invalidates an already captured button event" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    try f.show(1, "printf hidden");
    const accept = f.node("ai.approval.accept");
    const r = accept.globalRect();
    f.cx.handleMouseDown(r.x + r.w / 2, r.y + r.h / 2, .{});
    try f.view.update(null);
    f.live_sequence = null;
    f.settle();
    f.cx.handleMouseUp(r.x + r.w / 2, r.y + r.h / 2);
    f.settle();
    // A queued event can outlive hit testing; the View's own identity guard
    // must also reject it after hide.
    _ = f.cx.dispatcher.dispatch(.{ .click = .{ .x = r.x + r.w / 2, .y = r.y + r.h / 2 } }, accept);
    try std.testing.expectEqual(@as(usize, 0), f.attempts);
    try std.testing.expectEqual(@as(f32, 0), f.view.height());
    try std.testing.expect(f.view.sequence == null);
}

test "AI approval press from an old sequence cannot approve a replacement call on release" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    try f.show(1, "printf old-command");
    const r = f.node("ai.approval.accept").globalRect();
    f.cx.handleMouseDown(r.x + r.w / 2, r.y + r.h / 2, .{});
    try f.show(2, "printf replacement-command");
    f.cx.handleMouseUp(r.x + r.w / 2, r.y + r.h / 2);
    f.settle();
    try std.testing.expectEqual(@as(usize, 0), f.decisions);
    try std.testing.expectEqual(@as(u64, 2), f.view.sequence.?);
    f.click(f.node("ai.approval.accept"));
    try std.testing.expectEqual(@as(usize, 1), f.decisions);
    try std.testing.expectEqual(@as(u64, 2), f.last_sequence.?);
}

test "group AI approval preserves complete frozen targets and fixed actions at compact and standard heights" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    var approval = Fixture.source(42, "printf GROUP_APPROVED");
    approval.group = true;
    approval.target = "组 #7 · 2 个目标 · 成员快照 r4\n#101 · generation 9 · 本机 · zsh · 目录 /tmp/first\n#102 · generation 2 · SSH · root@example:22 · 目录 /srv/worker";
    f.live_sequence = approval.sequence;
    f.live_hash = approval.arguments_hash;
    try f.view.update(approval);
    f.settle();
    try std.testing.expectEqual(@as(f32, 207.625), f.view.height());
    try std.testing.expectEqual(@as(f32, 130.625), f.view.body.globalRect().h);
    try std.testing.expectEqual(@as(f32, 572), f.view.card.globalRect().w);
    try std.testing.expectEqualStrings(approval.target, f.view.identity.getText().?.content);
    try std.testing.expectEqualStrings(approval.target, f.view.target_owned.?);
    const button = f.node("ai.approval.accept");
    const reject = f.node("ai.approval.reject");
    try std.testing.expectEqual(@as(f32, 66), button.globalRect().w);
    try std.testing.expectEqual(@as(f32, 66), reject.globalRect().w);
    try std.testing.expectEqual(@as(f32, 26.5), button.globalRect().h);
    try std.testing.expect(button.globalRect().y >= f.view.body.globalRect().y + f.view.body.globalRect().h);
    const original_hash = f.view.arguments_hash;
    f.panel.setStyleInline(a, .{ .height = .{ .px = 420 } });
    f.settle();
    try f.view.update(approval);
    f.settle();
    try std.testing.expectEqual(@as(f32, 207.625), f.view.height());
    try std.testing.expectEqual(@as(f32, 130.625), f.view.body.globalRect().h);
    try std.testing.expectEqualSlices(u8, &original_hash, &f.view.arguments_hash);
    try std.testing.expectEqual(@as(usize, 0), f.attempts);
    try std.testing.expectEqual(@as(f32, 572), f.view.card.globalRect().w);
    const standard_accept = f.node("ai.approval.accept");
    try std.testing.expectEqual(@as(f32, 66), standard_accept.globalRect().w);
    f.click(standard_accept);
    try std.testing.expectEqual(@as(usize, 1), f.decisions);
    try std.testing.expectEqual(@as(?bool, true), f.last_approved);
}

test "AI generic tool approval names the tool call and never invents a working directory" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    var approval = Fixture.source(11, "{\"action\":\"power\"}");
    approval.tool_id = "fixture_probe.write";
    approval.target = "模拟电源";
    approval.cwd = null;
    try f.view.update(approval);
    f.settle();
    try std.testing.expectEqualStrings("工具调用", f.node("ai.approval.title").getText().?.content);
    try std.testing.expectEqualStrings("模拟电源 · #101", f.view.identity.getText().?.content);
    try std.testing.expectEqualStrings("复制调用参数", f.node("ai.approval.copy").behavior.interaction.a11y.?.label.?);
    approval.sequence = 12;
    approval.tool_id = "run_command";
    try f.view.update(approval);
    try std.testing.expectEqualStrings("执行命令", f.node("ai.approval.title").getText().?.content);
    try std.testing.expect(std.mem.endsWith(u8, f.view.identity.getText().?.content, "目录 未知"));
}
