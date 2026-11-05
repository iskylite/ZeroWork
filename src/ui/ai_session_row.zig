//! Shared history row used by the session list and the welcome page.
const ui = @import("ui");
const S = @import("ai_sessions_styles.zig");
const T = @import("app_theme.zig");
const Phase = @import("../ai/assistant_store.zig").Phase;
pub const Action = enum { view, locate, restore, copy, copy_use, end, new, more };
pub const Entry = struct { id: u64, title: []const u8, owner: []const u8, detail: []const u8 = "", active: bool = false, phase: @import("../ai/assistant_store.zig").Phase = .idle, bound: bool = false, ending: bool = false, can_restore: bool = false, can_copy: bool = false, can_remove: bool = true, first_use: bool = false };
pub const Hooks = struct { context: *anyopaque, select: *const fn (*anyopaque, u64) void, request_close: *const fn (*anyopaque, u64) void, remove: *const fn (*anyopaque, u64) void, act: ?*const fn (*anyopaque, u64, Action) void = null, confirmed: ?*const fn (*anyopaque, u64, bool) void = null };
const Row = struct {
    hooks: Hooks,
    menu_open: ?*ui.Signal(bool),
    phase: Phase,
    action_id: [64]u8 = undefined,
    id: u64,
    select_id: [64]u8 = undefined,
    delete_id: [64]u8 = undefined,
    row_id: [64]u8 = undefined,
    status_icon: ?*ui.Node = null,
    status_tag: ?*ui.Node = null,
    status_text: ?*ui.Node = null,
    action: Action = .view,
    fn select(self: *Row) void {
        if (self.menu_open) |open| open.set(false);
        if (self.hooks.act) |callback| callback(self.hooks.context, self.id, .view) else self.hooks.select(self.hooks.context, self.id);
    }
    fn act(self: *Row) void {
        if (self.hooks.act) |callback| callback(self.hooks.context, self.id, self.action);
    }
    fn remove(self: *Row) void {
        self.hooks.request_close(self.hooks.context, self.id);
    }
};

pub fn mount(cx: *ui.Cx, scope: *ui.Scope, entry: Entry, hooks: Hooks, highlighted: ?*ui.Signal(u64), menu_open: ?*ui.Signal(bool)) !*ui.Node {
    const state = try scope.createState(Row, .{ .hooks = hooks, .menu_open = menu_open, .phase = entry.phase, .id = entry.id });
    const row = try ui.box(cx, S.row(), .{});
    row.meta.ownership.meta.test_id = try @import("std").fmt.bufPrint(&state.row_id, "ai.session.row.{d}", .{entry.id});
    // Retain row data for phase updates without a row click handler.
    row.behavior.events.event_context = state;
    const hovered = try ui.hooks.useHover(scope, row);
    try scope.createEffect(.{ .cx = cx, .row = row, .hovered = hovered, .highlighted = highlighted, .active = entry.active, .id = entry.id, .publication = try cx.themeSignal(scope) }, struct {
        fn run(ctx: anytype) void {
            _ = ctx.publication.get();
            ctx.row.setStyleInline(ctx.cx.allocator, S.rowBackground(if (ctx.highlighted) |signal| signal.get() == ctx.id else ctx.active, ctx.hovered.get()));
            ctx.cx.requestRedraw();
        }
    }.run);
    const copy = try ui.box(cx, S.rowContent(), .{});
    try row.appendChild(cx.allocator, copy);
    const first_line = try ui.box(cx, S.firstLine(), .{});
    first_line.meta.ownership.meta.test_id = "ai.session.first_line";
    try copy.appendChild(cx.allocator, first_line);
    const title = try ui.text(cx, entry.title, S.text(true));
    title.setStyleInline(cx.allocator, .{ .width = .fill(), .height = .{ .px = 16.5 }, .min_width = 0 });
    title.meta.ownership.meta.test_id = "ai.session.title";
    title.setStyleInline(cx.allocator, .{ .overflow_hidden = true });
    const title_hint = try ui.widgets.Tooltip(.{ .text = entry.title, .width = @as(f32, 320), .wrap = .char }).mount(scope, cx);
    title_hint.content.meta.ownership.meta.test_id = "ai.session.title.tooltip";
    title_hint.wrapper.setStyleInline(cx.allocator, .{ .width = .fill(), .min_width = 0, .height = .{ .px = 16.5 } });
    title_hint.trigger.setStyleInline(cx.allocator, .{ .width = .fill(), .min_width = 0, .height = .{ .px = 16.5 } });
    try title_hint.trigger.appendChild(cx.allocator, title);
    try first_line.appendChild(cx.allocator, title_hint.wrapper);
    const tag = try ui.box(cx, S.tag(phaseColor(entry.phase)), .{});
    tag.meta.ownership.meta.test_id = "ai.session.phase_tag";
    state.status_tag = tag;
    state.status_icon = try ui.iconTint(cx, ui.icons.get(phaseIcon(entry.phase)).?, phaseColor(entry.phase), .{ .width = .{ .px = 10 }, .height = .{ .px = 10 }, .flex_shrink = 0 });
    state.status_icon.?.meta.ownership.meta.test_id = phaseTestId(entry.phase);
    try tag.appendChild(cx.allocator, state.status_icon.?);
    state.status_text = try ui.text(cx, phaseLabel(entry.phase), S.tagText(phaseColor(entry.phase)));
    try tag.appendChild(cx.allocator, state.status_text.?);
    try first_line.appendChild(cx.allocator, tag);
    const second_line = try ui.box(cx, S.secondLine(), .{});
    second_line.meta.ownership.meta.test_id = "ai.session.second_line";
    try copy.appendChild(cx.allocator, second_line);
    if (hooks.act != null) {
        const ink = if (entry.bound) T.current().accent_ink else T.current().fg_2;
        const binding = try ui.text(cx, if (entry.bound) "已绑定" else "未绑定", S.tagText(ink));
        binding.setStyleInline(cx.allocator, S.bindingTag(ink));
        binding.setTextColor(ink);
        binding.meta.ownership.meta.test_id = if (entry.bound) "ai.session.bound" else "ai.session.unbound";
        try second_line.appendChild(cx.allocator, binding);
    }
    const owner = try ui.text(cx, "", S.text(false));
    owner.meta.ownership.meta.test_id = "ai.session.owner";
    const summary = if (entry.ending) try @import("std").fmt.allocPrint(cx.allocator, "{s} · 正在停止任务", .{entry.owner}) else try cx.allocator.dupe(u8, entry.owner);
    defer cx.allocator.free(summary);
    try owner.setTextContent(cx.allocator, summary);
    owner.setStyleInline(cx.allocator, .{ .width = .fill(), .min_width = 0, .height = .{ .px = 15 } });
    const owner_hint = try @import("control_hint.zig").mount(cx, scope, owner, summary, .{ .id = "ai.session.owner.tooltip", .width = 320, .wrap = .char, .visible = menu_open, .layout = .{ .width = .fill(), .min_width = 0, .height = .{ .px = 15 }, .flex = 1 } });
    try second_line.appendChild(cx.allocator, owner_hint.wrapper);
    const actions = try ui.box(cx, S.rowActions(), .{});
    try second_line.appendChild(cx.allocator, actions);
    const select = try ui.widgets.Button(.{ .variant = .ghost, .icon_only = true, .icon_asset = ui.icons.get("arrow-up-right").?, .icon_size = 14, .a11y_label = "查看此 AI 会话", .base_style = @as(ui.BoxStyle, .{ .width = .{ .px = 24 }, .height = .{ .px = 24 }, .padding = .{}, .font_size = 11, .font_weight = 400, .text_color = T.current().accent_ink }), .hover_style = S.actionHover(false), .on_click = cx.on(Row, state, Row.select) }).mount(scope, cx);
    select.setStyleInline(cx.allocator, .{ .width = .{ .px = 24 }, .height = .{ .px = 24 }, .padding = .{}, .font_size = 11, .text_color = T.current().accent_ink });
    select.meta.ownership.meta.test_id = try @import("std").fmt.bufPrint(&state.select_id, "ai.session.jump.{d}", .{entry.id});
    try actions.appendChild(cx.allocator, try actionTooltip(cx, scope, select, "查看此 AI 会话"));
    if (hooks.act != null) {
        inline for (.{ .{ Action.locate, "locate-fixed", "locate" }, .{ Action.restore, "rotate-ccw", "restore" }, .{ Action.copy_use, "copy-plus", "copy_use" } }) |spec| {
            const enabled = switch (spec[0]) {
                .locate => entry.bound,
                .restore => entry.can_restore,
                .copy_use => entry.can_copy,
                else => false,
            };
            if (enabled) {
                const action_state = try scope.createState(Row, .{ .hooks = hooks, .menu_open = menu_open, .phase = entry.phase, .id = entry.id, .action = spec[0] });
                const label = if (spec[0] == .locate) "定位原持有者" else if (spec[0] == .copy_use) "复制并使用到当前 Agent" else if (entry.first_use) "使用到当前 Agent" else "恢复到当前 Agent";
                const action_button = try ui.widgets.Button(.{ .icon_only = true, .icon_asset = ui.icons.get(if (spec[0] == .restore and entry.first_use) "play" else spec[1]).?, .icon_size = 14, .variant = .ghost, .a11y_label = label, .base_style = S.rowAction(), .hover_style = S.actionHover(false), .on_click = cx.on(Row, action_state, Row.act) }).mount(scope, cx);
                action_button.meta.ownership.meta.test_id = try @import("std").fmt.bufPrint(&action_state.action_id, "ai.session.{s}.{d}", .{ spec[2], entry.id });
                try actions.appendChild(cx.allocator, try actionTooltip(cx, scope, action_button, label));
            }
        }
    }
    const remove = try ui.widgets.Button(.{ .variant = .ghost, .a11y_label = "删除 AI 会话", .hover_style = S.actionHover(true), .on_click = cx.on(Row, state, Row.remove) }).mount(scope, cx);
    if (!entry.can_remove) remove.setDisplay(.none);
    remove.setStyleInline(cx.allocator, .{ .width = .{ .px = 24 }, .height = .{ .px = 24 }, .padding = .{} });
    remove.meta.ownership.meta.test_id = try @import("std").fmt.bufPrint(&state.delete_id, "ai.session.delete.{d}", .{entry.id});
    try remove.appendChild(cx.allocator, try ui.iconTint(cx, ui.icons.get("trash-2").?, T.current().fg_2, .{ .width = .{ .px = 14 }, .height = .{ .px = 14 } }));
    if (entry.can_remove) try actions.appendChild(cx.allocator, try actionTooltip(cx, scope, remove, "删除 AI 会话")) else try actions.appendChild(cx.allocator, remove);
    return row;
}
fn actionTooltip(cx: *ui.Cx, scope: *ui.Scope, button: *ui.Node, label: []const u8) !*ui.Node {
    const tooltip = try ui.widgets.Tooltip(.{ .text = label }).mount(scope, cx);
    tooltip.wrapper.setStyleInline(cx.allocator, .{ .width = .{ .fit = .{} }, .height = .{ .px = 24 }, .flex_shrink = 0 });
    try tooltip.trigger.appendChild(cx.allocator, button);
    return tooltip.wrapper;
}

pub fn updatePhase(cx: *ui.Cx, row: *ui.Node, phase: Phase) void {
    const state: *Row = @ptrCast(@alignCast(row.behavior.events.event_context orelse return));
    if (state.phase == phase) return;
    state.phase = phase;
    state.status_tag.?.setStyleInline(cx.allocator, S.tag(phaseColor(phase)));
    state.status_text.?.setTextContent(cx.allocator, phaseLabel(phase)) catch {};
    state.status_text.?.setTextColor(phaseColor(phase));
    state.status_icon.?.meta.ownership.meta.test_id = phaseTestId(phase);
    if (state.status_icon.?.getIcon()) |old| {
        var icon = old;
        const asset = ui.icons.get(phaseIcon(phase)).?;
        icon.icon_id = asset.icon_id.?;
        icon.rep = asset.pickRep(14).?;
        icon.tint = phaseColor(phase);
        state.status_icon.?.setIcon(icon);
        state.status_icon.?.markRenderDirty();
    }
}
pub fn phaseTestId(phase: @import("../ai/assistant_store.zig").Phase) []const u8 {
    return switch (phase) {
        .idle => "ai.session.status.idle",
        .running => "ai.session.status.running",
        .approval => "ai.session.status.approval",
        .done => "ai.session.status.done",
        .failed => "ai.session.status.failed",
        .stopped => "ai.session.status.stopped",
    };
}
pub fn phaseIcon(phase: @import("../ai/assistant_store.zig").Phase) []const u8 {
    return switch (phase) {
        .idle => "circle-dashed",
        .running => "loader-circle",
        .approval => "circle-help",
        .done => "circle-check",
        .failed => "circle-alert",
        .stopped => "circle-stop",
    };
}
pub fn phaseColor(phase: @import("../ai/assistant_store.zig").Phase) ui.Color {
    return switch (phase) {
        .idle, .stopped => T.current().fg_2,
        .running => T.current().accent_ink,
        .approval => T.current().warn_ink,
        .done => T.current().ok_ink,
        .failed => T.current().danger_ink,
    };
}
pub fn phaseLabel(phase: @import("../ai/assistant_store.zig").Phase) []const u8 {
    return switch (phase) {
        .idle => "未开始",
        .running => "运行中",
        .approval => "待确认",
        .done => "已完成",
        .failed => "失败",
        .stopped => "已暂停",
    };
}
