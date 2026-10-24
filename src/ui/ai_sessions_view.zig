//! Session list and one frozen-identity close confirmation. Host applies actions next frame.
const ui = @import("ui");
const S = @import("ai_sessions_styles.zig");
const T = @import("app_theme.zig");
pub const Entry = struct { id: u64, title: []const u8, owner: []const u8, active: bool = false, phase: @import("../ai/assistant_store.zig").Phase = .idle };
pub const Hooks = struct { context: *anyopaque, select: *const fn (*anyopaque, u64) void, remove: *const fn (*anyopaque, u64) void };
pub const View = struct {
    cx: *ui.Cx,
    scope: *ui.Scope,
    hooks: Hooks,
    open: *ui.Signal(bool),
    confirmation: *ui.Signal(bool),
    highlighted: *ui.Signal(u64),
    content: *ui.Node,
    root: *ui.Node,
    scroll: ui.widgets.ScrollAreaResult,
    rows: ?*ui.Scope = null,
    pending: ?u64 = null,
    desired_height: f32 = 0,
    detail: *ui.Node,
    dialog: *ui.Node,
    control_styles: [2]*ui.Signal(ui.BoxStyle),
    pub fn mount(cx: *ui.Cx, scope: *ui.Scope, anchor: *ui.Node, hooks: Hooks) !*View {
        const open = try scope.createSignal(bool, false);
        const confirmation = try scope.createSignal(bool, false);
        _ = anchor;
        const scroll = try ui.widgets.ScrollArea(.{ .height = 168, .direction = .vertical, .rubber_band_y = false }).mount(scope, cx);
        scroll.container.setStyleInline(cx.allocator, S.listSurface());
        scroll.content.setStyleInline(cx.allocator, S.menu());
        scroll.container.meta.ownership.meta.test_id = "ai.sessions.menu";
        const self = try scope.createState(View, .{ .cx = cx, .scope = scope, .hooks = hooks, .open = open, .confirmation = confirmation, .highlighted = try scope.createSignal(u64, 0), .content = scroll.content, .root = scroll.container, .scroll = scroll, .detail = undefined, .dialog = undefined, .control_styles = .{ try scope.createSignal(ui.BoxStyle, S.control(false)), try scope.createSignal(ui.BoxStyle, S.control(true)) } });
        try scope.createEffect(.{ .self = self }, struct {
            fn run(ctx: anytype) void {
                ctx.self.root.setDisplay(if (ctx.self.open.get()) .flex else .none);
                ctx.self.cx.requestRedraw();
            }
        }.run);
        const modal = try ui.widgets.Modal(.{ .open = confirmation, .width = 320, .max_height = 220, .background = T.current().overlay }).mount(scope, cx);
        if (!modal.portaled) if (cx.root) |root| try root.appendChild(cx.allocator, modal.overlay);
        self.dialog = modal.dialog;
        modal.dialog.setStyleInline(cx.allocator, S.dialog());
        modal.dialog.meta.ownership.meta.test_id = "ai.session.close.confirmation";
        modal.body.setStyleInline(cx.allocator, S.body());
        try modal.body.appendChild(cx.allocator, try ui.textStyled(cx, titleStyle, "关闭此 AI 会话？"));
        self.detail = try ui.textStyled(cx, detailStyle, "将停止关联的任务、工具和请求。");
        try modal.body.appendChild(cx.allocator, self.detail);
        const actions = try ui.box(cx, S.actions(), .{});
        const cancel = try ui.widgets.Button(.{ .label = "取消", .variant = .secondary, .base_style = self.control_styles[0], .on_click = cx.on(View, self, cancelClose) }).mount(scope, cx);
        cancel.meta.ownership.meta.test_id = "ai.session.close.cancel";
        try actions.appendChild(cx.allocator, cancel);
        const accept = try ui.widgets.Button(.{ .label = "关闭会话", .variant = .danger, .base_style = self.control_styles[1], .on_click = cx.on(View, self, acceptClose) }).mount(scope, cx);
        accept.meta.ownership.meta.test_id = "ai.session.close.accept";
        try actions.appendChild(cx.allocator, accept);
        try modal.body.appendChild(cx.allocator, actions);
        return self;
    }
    fn titleStyle(_: *const ui.ThemeTokens) ui.TextStyle {
        var s = S.text(true);
        s.font_weight = 600;
        s.font_size = 12;
        s.line_height = 18.0 / 12.0;
        return s;
    }
    fn detailStyle(_: *const ui.ThemeTokens) ui.TextStyle {
        return S.dialogDetail();
    }
    fn cancelClose(self: *View) void {
        self.pending = null;
        self.confirmation.set(false);
    }
    fn acceptClose(self: *View) void {
        const id = self.pending orelse return;
        self.pending = null;
        self.confirmation.set(false);
        self.open.set(false);
        self.hooks.remove(self.hooks.context, id);
    }
    pub fn confirm(self: *View, id: u64) void {
        self.pending = id;
        self.dialog.setStyleInline(self.cx.allocator, S.dialog());
        self.control_styles[0].set(S.control(false));
        self.control_styles[1].set(S.control(true));
        self.confirmation.set(true);
    }
    const Row = struct {
        view: *View,
        id: u64,
        select_id: [64]u8 = undefined,
        delete_id: [64]u8 = undefined,
        row_id: [64]u8 = undefined,
        status_icon: ?*ui.Node = null,
        status_label: ?*ui.Signal([]const u8) = null,
        fn event(event_value: ui.events.Event, raw: ?*anyopaque) ui.events.EventResult {
            const self: *Row = @ptrCast(@alignCast(raw orelse return .ignored));
            if (event_value != .mouse_down or event_value.mouse_down.button != .left) return .ignored;
            self.view.highlighted.set(self.id);
            return .handled;
        }
        fn select(self: *Row) void {
            self.view.open.set(false);
            self.view.hooks.select(self.view.hooks.context, self.id);
        }
        fn remove(self: *Row) void {
            self.view.confirm(self.id);
        }
    };
    pub fn show(self: *View, entries: []const Entry) !void {
        self.open.set(false);
        if (self.rows) |old| old.dispose();
        while (self.content.children.items.len > 0) {
            const child = self.content.children.items[0];
            self.content.removeChild(child);
            self.cx.destroyDetached(child);
        }
        const scope = try self.scope.childScope();
        self.rows = scope;
        self.content.setStyleInline(self.cx.allocator, S.menu());
        if (entries.len == 0) try self.content.appendChild(self.cx.allocator, try ui.text(self.cx, "暂无 AI 会话", S.text(false)));
        const heading = try ui.box(self.cx, S.heading(), .{});
        heading.meta.ownership.meta.test_id = "ai.sessions.heading";
        try heading.appendChild(self.cx.allocator, try ui.iconTint(self.cx, ui.icons.get("messages-square").?, T.current().fg_2, .{ .width = .{ .px = 12 }, .height = .{ .px = 12 } }));
        var heading_style = S.text(true);
        heading_style.font_weight = 600;
        try heading.appendChild(self.cx.allocator, try ui.text(self.cx, "会话", heading_style));
        try self.content.appendChild(self.cx.allocator, heading);
        var highlight_exists = false;
        for (entries) |entry| if (entry.id == self.highlighted.peek()) {
            highlight_exists = true;
        };
        if (!highlight_exists) for (entries) |entry| {
            if (entry.active) {
                self.highlighted.set(entry.id);
                break;
            }
        };
        for (entries) |entry| {
            const state = try scope.createState(Row, .{ .view = self, .id = entry.id });
            const row = try ui.box(self.cx, S.row(), .{});
            row.meta.ownership.meta.test_id = try @import("std").fmt.bufPrint(&state.row_id, "ai.session.row.{d}", .{entry.id});
            row.behavior.events.on_event = Row.event;
            row.behavior.events.event_context = state;
            const hovered = try ui.hooks.useHover(scope, row);
            try scope.createEffect(.{ .cx = self.cx, .row = row, .hovered = hovered, .highlighted = self.highlighted, .id = entry.id }, struct {
                fn run(ctx: anytype) void {
                    ctx.row.setStyleInline(ctx.cx.allocator, S.rowBackground(ctx.highlighted.get() == ctx.id, ctx.hovered.get()));
                    ctx.cx.requestRedraw();
                }
            }.run);
            state.status_label = try scope.createText(phaseLabel(entry.phase), .{});
            const hint = try ui.widgets.Tooltip(.{ .text = state.status_label.? }).mount(scope, self.cx);
            state.status_icon = try ui.iconTint(self.cx, ui.icons.get(phaseIcon(entry.phase)).?, phaseColor(entry.phase), .{ .width = .{ .px = 14 }, .height = .{ .px = 14 } });
            state.status_icon.?.meta.ownership.meta.test_id = phaseTestId(entry.phase);
            try hint.trigger.appendChild(self.cx.allocator, state.status_icon.?);
            hint.wrapper.setStyleInline(self.cx.allocator, .{ .width = .{ .px = 20 }, .height = .{ .px = 20 }, .flex_shrink = 0, .align_items = .center, .justify = .center });
            try row.appendChild(self.cx.allocator, hint.wrapper);
            const title = try ui.text(self.cx, entry.title, S.text(true));
            title.setStyleInline(self.cx.allocator, .{ .width = .fill(), .height = .{ .px = 16 }, .min_width = 0 });
            try row.appendChild(self.cx.allocator, title);
            const owner = try ui.text(self.cx, entry.owner, S.text(false));
            owner.setStyleInline(self.cx.allocator, .{ .width = .{ .px = 170 }, .height = .{ .px = 14 }, .flex_shrink = 1 });
            try row.appendChild(self.cx.allocator, owner);
            const select = try ui.widgets.Button(.{ .variant = .ghost, .a11y_label = "跳转到此 AI 会话", .hover_style = S.actionHover(false), .on_click = self.cx.on(Row, state, Row.select) }).mount(scope, self.cx);
            select.setStyleInline(self.cx.allocator, .{ .width = .{ .px = 24 }, .height = .{ .px = 24 }, .padding = .{} });
            select.meta.ownership.meta.test_id = try @import("std").fmt.bufPrint(&state.select_id, "ai.session.jump.{d}", .{entry.id});
            try select.appendChild(self.cx.allocator, try ui.iconTint(self.cx, ui.icons.get("arrow-up-right").?, T.current().fg_2, .{ .width = .{ .px = 14 }, .height = .{ .px = 14 } }));
            try row.appendChild(self.cx.allocator, select);
            const remove = try ui.widgets.Button(.{ .variant = .ghost, .a11y_label = "删除 AI 会话", .hover_style = S.actionHover(true), .on_click = self.cx.on(Row, state, Row.remove) }).mount(scope, self.cx);
            remove.setStyleInline(self.cx.allocator, .{ .width = .{ .px = 24 }, .height = .{ .px = 24 }, .padding = .{} });
            remove.meta.ownership.meta.test_id = try @import("std").fmt.bufPrint(&state.delete_id, "ai.session.delete.{d}", .{entry.id});
            try remove.appendChild(self.cx.allocator, try ui.iconTint(self.cx, ui.icons.get("trash-2").?, T.current().fg_2, .{ .width = .{ .px = 14 }, .height = .{ .px = 14 } }));
            try row.appendChild(self.cx.allocator, remove);
            try self.content.appendChild(self.cx.allocator, row);
        }
        self.desired_height = @min(168, @as(f32, @floatFromInt(@max(1, entries.len))) * 32 + 32);
        self.root.setStyleInline(self.cx.allocator, .{ .height = .{ .px = self.desired_height } });
        ui.widgets.setScrollY(self.scroll.state, self.scroll.content, 0);
        self.open.set(true);
    }
    pub fn updatePhase(self: *View, id: u64, phase: @import("../ai/assistant_store.zig").Phase) void {
        if (!self.open.peek()) return;
        var buf: [64]u8 = undefined;
        const expected = @import("std").fmt.bufPrint(&buf, "ai.session.row.{d}", .{id}) catch return;
        for (self.content.children.items) |row| {
            const test_id = row.meta.ownership.meta.test_id orelse continue;
            if (@import("std").mem.eql(u8, test_id, expected) and row.children.items.len > 0) {
                const state: *Row = @ptrCast(@alignCast(row.behavior.events.event_context orelse continue));
                state.status_label.?.set(phaseLabel(phase));
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
                break;
            }
        }
    }
    pub fn fitWithin(self: *View, available: f32) void {
        if (self.open.peek()) self.root.setStyleInline(self.cx.allocator, .{ .height = .{ .px = @min(self.desired_height, @max(40, @min(168, available))) } });
    }
    pub fn height(self: *View) f32 {
        return if (self.open.peek()) self.root.style.height.px else 0;
    }
    fn phaseTestId(phase: @import("../ai/assistant_store.zig").Phase) []const u8 {
        return switch (phase) {
            .idle => "ai.session.status.idle",
            .running => "ai.session.status.running",
            .approval => "ai.session.status.approval",
            .done => "ai.session.status.done",
            .failed => "ai.session.status.failed",
            .stopped => "ai.session.status.stopped",
        };
    }
    fn phaseIcon(phase: @import("../ai/assistant_store.zig").Phase) []const u8 {
        return switch (phase) {
            .idle => "circle-dashed",
            .running => "loader-circle",
            .approval => "circle-help",
            .done => "circle-check",
            .failed => "circle-alert",
            .stopped => "circle-stop",
        };
    }
    fn phaseColor(phase: @import("../ai/assistant_store.zig").Phase) ui.Color {
        return switch (phase) {
            .idle, .stopped => T.current().fg_2,
            .running => T.current().accent_ink,
            .approval => T.current().warn_ink,
            .done => T.current().ok_ink,
            .failed => T.current().danger_ink,
        };
    }
    fn phaseLabel(phase: @import("../ai/assistant_store.zig").Phase) []const u8 {
        return switch (phase) {
            .idle => "待开始",
            .running => "运行中",
            .approval => "待确认",
            .done => "已完成",
            .failed => "失败",
            .stopped => "已停止",
        };
    }
};
