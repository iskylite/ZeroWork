//! Per-original-call read-only observation. The UI never accepts a target address or command.
const std = @import("std");
const ui = @import("ui");
const facts = @import("../ai/tool_results.zig");
const V = facts.Verification;
const identity = @import("../host/identity.zig");
const S = @import("ai_recovery_styles.zig");
pub const Ticket = struct {
    conversation_id: ?identity.ConversationId,
    owner: @import("../ai/tool_scope.zig").Owner,
    turn_id: u64,
    call_hash: [32]u8,
    arguments_hash: [32]u8,
    target_index: ?usize,
    anchor: ?V.Anchor = null,

    pub fn resolve(self: Ticket, record: *const facts.Record) ?V.Anchor {
        if (!record.owner.eql(self.owner) or record.turn_id != self.turn_id or !std.mem.eql(u8, &V.digest(record.call_id), &self.call_hash) or !std.mem.eql(u8, &record.arguments_hash, &self.arguments_hash) or !std.meta.eql(record.conversation_id, self.conversation_id)) return null;
        const original = self.anchor orelse return null;
        if (!original.matches(record.turn_id, record.call_id, record.arguments_hash)) return null;
        if (original.context) |context| {
            const conversation = record.conversation_id orelse return null;
            if (!context.conversation_id.eql(conversation) or !context.binding.eql(record.owner)) return null;
        }
        const retained = if (self.target_index) |index| blk: {
            if (index >= record.targets.len) return null;
            const target = record.targets[index];
            if (!unknown(target) or target.result.session_id != @backingInt(original.owner.session_id)) return null;
            if (target.source) |source| if (!source.eql(original.owner)) return null;
            break :blk target.verification orelse return null;
        } else blk: {
            if (!record.hasUnknown()) return null;
            break :blk record.verification orelse return null;
        };
        return if (std.meta.eql(original, retained)) original else null;
    }
};
pub const Actions = struct { context: *anyopaque, enqueue: *const fn (*anyopaque, Ticket) void };
const Click = struct {
    actions: Actions,
    ticket: Ticket,
    fn click(self: *Click) void {
        self.actions.enqueue(self.actions.context, self.ticket);
    }
};
pub fn unknown(target: facts.Target) bool {
    return target.result.status == .unknown or target.result.remote_effect_unknown or !target.result.local_released;
}
pub fn mount(cx: *ui.Cx, scope: *ui.Scope, parent: *ui.Node, record: *facts.Record, actions: ?Actions) !void {
    if (record.targets.len == 0 and record.host == null and record.error_status == .unknown) try entry(cx, scope, parent, record, null, null, "", record.checks, actions);
    for (record.targets, 0..) |target, index| {
        if (unknown(target)) try entry(cx, scope, parent, record, index, target.verification, target.label, target.checks, actions);
    }
    if (record.host) |host| {
        const needs_check = host.status == .outcome_unknown or host.receipt.remote_effect_unknown or !host.receipt.local_released;
        if (needs_check) try entry(cx, scope, parent, record, null, record.verification, if (record.execution) |execution| execution.target_label else "", record.checks, actions);
    }
}
fn entry(cx: *ui.Cx, scope: *ui.Scope, parent: *ui.Node, record: *facts.Record, index: ?usize, anchor: ?V.Anchor, label: []const u8, history: V.History, actions: ?Actions) !void {
    const body = try ui.boxStyled(cx, S.body, .{});
    body.meta.ownership.meta.test_id = "ai.verification";
    const target = if (anchor) |original| try std.fmt.allocPrint(cx.allocator, "原目标：{s} · #{d} · generation {d}", .{ label, @backingInt(original.owner.session_id), original.owner.generation }) else try cx.allocator.dupe(u8, "原目标身份信息不足，无法自动核查。");
    defer cx.allocator.free(target);
    try appendText(cx, body, target);
    try appendText(cx, body, "查询原执行回执与状态，不执行命令、不重连。");
    const ticket: Ticket = .{ .conversation_id = record.conversation_id, .owner = record.owner, .turn_id = record.turn_id, .call_hash = V.digest(record.call_id), .arguments_hash = record.arguments_hash, .target_index = index, .anchor = anchor };
    const valid = ticket.resolve(record) != null;
    const enabled = valid and actions != null;
    const callback = if (actions) |value| try scope.createState(Click, .{ .actions = value, .ticket = ticket }) else null;
    const button = try ui.widgets.Button(.{ .label = "只读核查", .a11y_label = "只读核查原调用和原目标", .disabled = !enabled, .variant = .secondary, .base_style = S.action(false, false, enabled), .on_click = if (callback) |click| cx.on(Click, click, Click.click) else null }).mount(scope, cx);
    button.meta.ownership.meta.test_id = "ai.verification.check";
    try body.appendChild(cx.allocator, button);
    if (!valid and anchor != null) try body.appendChild(cx.allocator, try ui.textStyled(cx, S.hint, "定位信息与原调用不匹配，无法核查。"));
    for (history.items.items) |observed| try appendObservation(cx, body, observed);
    try parent.appendChild(cx.allocator, body);
}

fn appendText(cx: *ui.Cx, parent: *ui.Node, text: []const u8) !void {
    const node = try ui.textStyled(cx, S.text, text);
    node.setStyleInline(cx.allocator, .{ .width = .fill(), .min_width = 0, .flex_shrink = 0 });
    try parent.appendChild(cx.allocator, node);
}

pub fn appendObservation(cx: *ui.Cx, body: *ui.Node, observed: V.Observation) !void {
    var text: [768]u8 = undefined;
    var stamp: [19]u8 = undefined;
    const time = @import("terminal_surface_input.zig").localDateTimestamp(&stamp, observed.observed_at_ms) catch "时间不可用";
    const description = try std.fmt.allocPrint(cx.allocator, "{s} · {s}", .{ time, observed.describe(&text) });
    defer cx.allocator.free(description);
    const evidence = try ui.textStyled(cx, S.text, description);
    evidence.meta.ownership.meta.test_id = "ai.verification.evidence";
    evidence.setStyleInline(cx.allocator, .{ .width = .fill(), .min_width = 0, .flex_shrink = 0 });
    try body.appendChild(cx.allocator, evidence);
    for ([_][]const u8{ observed.stdout[0..observed.stdout_len], observed.stderr[0..observed.stderr_len] }) |bytes| {
        if (bytes.len == 0) continue;
        try appendText(cx, body, if (std.unicode.utf8ValidateSlice(bytes)) bytes else "核查输出包含非文本字节，原始证据已保留。");
    }
    if (observed.truncated) try body.appendChild(cx.allocator, try ui.textStyled(cx, S.hint, "仅展示有界输出片段，不能据此认定输出完整。"));
}
