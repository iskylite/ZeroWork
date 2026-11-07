const std = @import("std");
const ui = @import("ui");
const S = @import("ai_recovery_styles.zig");
pub const Action = enum { answer, edit, regenerate };
pub const Ticket = struct { owner: @import("../ai/tool_scope.zig").Owner, turn: u64, conversation_id: ?@import("../host/identity.zig").ConversationId = null };
pub const Envelope = struct { ticket: Ticket, action: Action };
pub const Snapshot = struct {
    ticket: Ticket,
    reason: []const u8,
    detail: ?[]const u8 = null,
    title: []const u8 = "请求失败",
    retries: u8,
    max_retries: u8,
    retry_enabled: bool,
    regenerate_enabled: bool,
    retry_disabled_reason: ?[]const u8 = null,
    regenerate_disabled_reason: ?[]const u8 = null,
    cooldown_seconds: u64,
    retained_answer: bool = true,
    has_tool_calls: bool = false,
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
    @import("layer_materials.zig").card(root, .action);
    root.meta.ownership.meta.test_id = "ai.recovery";
    const status = try ui.boxStyled(cx, S.statusRow, .{});

    const icon_slot = try ui.box(cx, .{ .width = .{ .px = 22 }, .height = .{ .px = 22 }, .align_items = .center, .justify = .center, .flex_shrink = 0 }, .{});
    try icon_slot.appendChild(cx.allocator, try @import("app_theme.zig").icon(cx, ui.icons.circle_alert, "warn_ink", S.icon()));
    try status.appendChild(cx.allocator, icon_slot);
    const title = try ui.textStyled(cx, S.title, state.title);
    title.setStyleInline(cx.allocator, .{ .flex_shrink = 0 });
    try status.appendChild(cx.allocator, title);
    const first_line = std.mem.trim(u8, state.reason[0 .. std.mem.indexOfScalar(u8, state.reason, '\n') orelse state.reason.len], " \t\r");
    const separator = if (std.mem.startsWith(u8, first_line, "HTTP ")) std.mem.indexOf(u8, first_line, " · ") else null;
    const code = if (separator) |offset| first_line[0..offset] else "";
    const summary = if (separator) |offset| first_line[offset + " · ".len ..] else first_line;
    const code_node = try ui.textStyled(cx, S.summary, code);
    code_node.meta.ownership.meta.test_id = "ai.recovery.http";
    code_node.setStyleInline(cx.allocator, .{ .width = .fill(), .flex = 1, .min_width = 0 });
    if (code_node.getText()) |text| {
        var value = text;
        value.text_align = .end;
        code_node.setText(value);
    }
    try status.appendChild(cx.allocator, code_node);
    try root.appendChild(cx.allocator, status);
    const body = try ui.boxStyled(cx, S.body, .{});
    const problem = try ui.textStyled(cx, S.text, summary);
    problem.meta.ownership.meta.test_id = "ai.recovery.reason";
    problem.setStyleInline(cx.allocator, .{ .width = .fill(), .min_width = 0 });
    try body.appendChild(cx.allocator, problem);
    const answer_hint = try ui.textStyled(cx, S.hint, "仅根据已有结果生成答复，不执行命令。");
    answer_hint.meta.ownership.meta.test_id = "ai.recovery.answer.hint";
    answer_hint.setStyleInline(cx.allocator, .{ .width = .fill(), .min_width = 0 });
    try body.appendChild(cx.allocator, answer_hint);
    if (!state.retry_enabled) if (state.retry_disabled_reason) |reason| try appendDisabledReason(cx, body, "ai.recovery.answer.disabled_reason", reason);
    if (!state.regenerate_enabled and state.has_tool_calls) if (state.regenerate_disabled_reason) |reason| try appendDisabledReason(cx, body, "ai.recovery.regenerate.disabled_reason", reason);
    if (state.cooldown_seconds != 0) {
        const reason = try std.fmt.allocPrint(cx.allocator, "服务冷却中，{d} 秒后可重试。", .{state.cooldown_seconds});
        defer cx.allocator.free(reason);
        try appendDisabledReason(cx, body, "ai.recovery.cooldown", reason);
    }
    try root.appendChild(cx.allocator, body);
    const row = try ui.boxStyled(cx, S.row, .{});
    const retained = if (state.retained_answer) "已保留部分答复" else "问题和附件已保留";
    const attempts = if (state.retries > 0) try std.fmt.allocPrint(cx.allocator, "{s} · 重试 {d}/{d}", .{ retained, state.retries, state.max_retries }) else try cx.allocator.dupe(u8, retained);
    defer cx.allocator.free(attempts);
    const hint = try ui.textStyled(cx, S.hint, attempts);
    hint.setStyleInline(cx.allocator, .{ .width = .fill(), .min_width = 0, .flex = 1, .flex_shrink = 1 });
    try row.appendChild(cx.allocator, hint);
    const action_row = try ui.box(cx, .{ .direction = .row, .align_items = .center, .gap = 6, .flex_shrink = 0 }, .{});
    try row.appendChild(cx.allocator, action_row);
    for ([_]Action{ .edit, .regenerate, .answer }) |action| {
        const label: []const u8 = switch (action) {
            .answer => "仅重试答复",
            .edit => "编辑问题",
            .regenerate => "重新生成计划",
        };
        const id: []const u8 = switch (action) {
            .answer => "ai.recovery.answer",
            .edit => "ai.recovery.edit",
            .regenerate => "ai.recovery.regenerate",
        };
        if (action == .regenerate and !state.has_tool_calls) continue;
        const enabled = switch (action) {
            .answer => state.retry_enabled,
            .regenerate => state.regenerate_enabled,
            .edit => true,
        };
        const click = try scope.createState(Click, .{ .actions = actions, .envelope = .{ .ticket = state.ticket, .action = action } });
        var cooldown: [64]u8 = undefined;
        const action_label = if (action == .answer and state.cooldown_seconds != 0) try std.fmt.bufPrint(&cooldown, "仅重试答复 · {d}s", .{state.cooldown_seconds}) else label;
        const button_style = try @import("app_theme.zig").paintSignal(ui.BoxStyle, cx, scope, S.action, .{ action == .answer, action == .edit, enabled });
        const button = try ui.widgets.Button(.{ .label = if (action == .answer) action_label else if (action == .regenerate) "新计划" else label, .icon_only = false, .icon_asset = null, .icon_size = @as(f32, 12), .a11y_label = label, .variant = @as(ui.widgets.button.ButtonVariant, if (action == .answer) .primary else .secondary), .disabled = !enabled, .base_style = button_style, .on_click = cx.on(Click, click, Click.click) }).mount(scope, cx);
        if (action == .answer and state.cooldown_seconds != 0) button.setStyle(cx.allocator, .min_width, @as(f32, 53));
        if (action == .answer) try @import("app_theme.zig").stylePrimary(cx, scope, button, null);
        button.meta.ownership.meta.test_id = id;
        try action_row.appendChild(cx.allocator, button);
    }
    const details = try ui.widgets.ScrollArea(.{ .direction = .vertical }).mount(scope, cx);
    @import("ai_card_scroll.zig").containVertical(details);
    details.container.setStyleInline(cx.allocator, S.details(cx.tokens));
    details.container.meta.ownership.meta.test_id = "ai.recovery.details";
    details.container.setDisplay(.none);
    const raw_diagnostic = std.mem.trim(u8, state.detail orelse state.reason, " \t\r\n");
    const diagnostic = if (std.mem.eql(u8, raw_diagnostic, first_line)) "" else if (std.mem.startsWith(u8, raw_diagnostic, first_line) and raw_diagnostic[first_line.len] == '\n') std.mem.trim(u8, raw_diagnostic[first_line.len + 1 ..], " \t\r\n") else raw_diagnostic;
    if (diagnostic.len > 0) {
        const full_reason = try ui.textStyled(cx, S.text, diagnostic);
        full_reason.setStyleInline(cx.allocator, .{ .width = .fill(), .min_width = 0, .flex_shrink = 0 });
        try details.content.appendChild(cx.allocator, full_reason);
    }
    if (state.has_tool_calls) try details.content.appendChild(cx.allocator, try ui.textStyled(cx, S.text, "已完成调用不会重放；结果未知的操作需先核实。"));
    if (details.content.children.items.len > 0) {
        const disclosure = try scope.createState(Details, .{ .cx = cx, .content = details.container });
        const toggle = try ui.widgets.Button(.{ .icon_only = true, .icon_asset = ui.icons.chevron_down, .icon_size = @as(f32, 12), .a11y_label = "展开错误详情", .variant = .ghost, .base_style = @import("notification_history_styles.zig").expand(), .on_click = cx.on(Details, disclosure, Details.toggle) }).mount(scope, cx);
        toggle.meta.ownership.meta.test_id = "ai.recovery.details.toggle";
        toggle.behavior.interaction.a11y.?.expanded = false;
        disclosure.button = toggle;
        try status.appendChild(cx.allocator, toggle);
    }
    try root.appendChild(cx.allocator, details.container);
    try root.appendChild(cx.allocator, row);
    return root;
}

const Details = struct {
    cx: *ui.Cx,
    content: *ui.Node,
    button: *ui.Node = undefined,
    expanded: bool = false,
    fn toggle(self: *Details) void {
        self.expanded = !self.expanded;
        self.content.setDisplay(if (self.expanded) .flex else .none);
        self.button.setStyle(self.cx.allocator, .rotate, if (self.expanded) @as(f32, std.math.pi) else @as(f32, 0));
        if (self.button.behavior.interaction.a11y) |*attrs| {
            attrs.expanded = self.expanded;
            attrs.label = if (self.expanded) "收起错误详情" else "展开错误详情";
        }
        self.cx.requestRedraw();
    }
};

fn appendDisabledReason(cx: *ui.Cx, parent: *ui.Node, id: []const u8, reason: []const u8) !void {
    const node = try ui.textStyled(cx, S.hint, reason);
    node.meta.ownership.meta.test_id = id;
    node.setStyleInline(cx.allocator, .{ .width = .fill(), .min_width = 0 });
    try parent.appendChild(cx.allocator, node);
}
