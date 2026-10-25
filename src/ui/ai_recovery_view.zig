const std = @import("std");
const ui = @import("ui");
const S = @import("ai_recovery_styles.zig");
pub const Action = enum { answer, edit, regenerate };
pub const Ticket = struct { owner: @import("../ai/tool_scope.zig").Owner, turn: u64 };
pub const Envelope = struct { ticket: Ticket, action: Action };
pub const Snapshot = struct {
    ticket: Ticket,
    reason: []const u8,
    retries: u8,
    max_retries: u8,
    retry_enabled: bool,
    regenerate_enabled: bool,
    cooldown_seconds: u64,
    retained_answer: bool = true,
};
pub const Actions = struct { context: *anyopaque, enqueue: *const fn (*anyopaque, Envelope) void };
const Click = struct {
    actions: Actions,
    envelope: Envelope,
    fn click(self: *Click) void {
        self.actions.enqueue(self.actions.context, self.envelope);
    }
};
pub fn mount(cx: *ui.Cx, scope: *ui.Scope, state: Snapshot, actions: Actions) !*ui.Node {
    const root = try ui.boxStyled(cx, S.root, .{});
    root.meta.ownership.meta.test_id = "ai.recovery";
    const status = try ui.boxStyled(cx, S.statusRow, .{});

    const problem = try ui.textStyled(cx, S.warning, state.reason);
    problem.meta.ownership.meta.test_id = "ai.recovery.reason";
    problem.setStyleInline(cx.allocator, .{ .width = .fill(), .flex = 1, .min_width = 0 });
    try status.appendChild(cx.allocator, problem);
    try root.appendChild(cx.allocator, status);
    const attempts = try std.fmt.allocPrint(cx.allocator, "重试 {d}/{d} · {s}", .{ state.retries, state.max_retries, if (state.retained_answer) "保留部分答复" else "草稿保留" });
    defer cx.allocator.free(attempts);
    try root.appendChild(cx.allocator, try ui.textStyled(cx, S.text, attempts));
    const row = try ui.boxStyled(cx, S.row, .{});
    try root.appendChild(cx.allocator, row);
    const labels = [_][]const u8{ "重试", "编辑问题", "重新生成计划" };
    const ids = [_][]const u8{ "ai.recovery.answer", "ai.recovery.edit", "ai.recovery.regenerate" };
    for (std.enums.values(Action), labels, ids) |action, label, id| {
        const enabled = switch (action) {
            .answer => state.retry_enabled,
            .regenerate => state.regenerate_enabled,
            .edit => true,
        };
        const click = try scope.createState(Click, .{ .actions = actions, .envelope = .{ .ticket = state.ticket, .action = action } });
        var cooldown: [64]u8 = undefined;
        const action_label = if (action == .answer and state.cooldown_seconds != 0) try std.fmt.bufPrint(&cooldown, "重试答复 · {d}s", .{state.cooldown_seconds}) else label;
        const button = try ui.widgets.Button(.{ .label = if (action == .answer) action_label else if (action == .regenerate) "新计划" else "", .icon_only = action == .edit, .icon_asset = if (action == .edit) ui.icons.pencil else if (action == .regenerate) ui.icons.rotate_cw else null, .icon_size = @as(f32, 14), .a11y_label = label, .variant = @as(ui.widgets.button.ButtonVariant, if (action == .answer) .primary else .secondary), .disabled = !enabled, .base_style = S.action(action == .answer, action == .edit, enabled), .on_click = cx.on(Click, click, Click.click) }).mount(scope, cx);
        button.meta.ownership.meta.test_id = id;
        if (action == .regenerate) {
            const notice = try ui.boxStyled(cx, S.statusRow, .{});
            try notice.appendChild(cx.allocator, try ui.iconTint(cx, ui.icons.get("shield-check").?, S.text(undefined).color, S.icon()));
            try notice.appendChild(cx.allocator, try ui.textStyled(cx, S.text, "已完成调用不重放；未知写入先核查。"));
            try root.appendChild(cx.allocator, notice);
            try row.appendChild(cx.allocator, button);
        } else try row.appendChild(cx.allocator, button);
    }
    return root;
}
