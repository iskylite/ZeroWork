//! Session list and one frozen-identity close confirmation. Host applies actions next frame.
const ui = @import("ui");
const S = @import("ai_sessions_styles.zig");
const T = @import("app_theme.zig");
const RowView = @import("ai_session_row.zig");
const Header = @import("ai_assistant_header.zig");
pub const Action = RowView.Action;
pub const Entry = RowView.Entry;
pub const Hooks = RowView.Hooks;
pub const View = struct {
    cx: *ui.Cx,
    scope: *ui.Scope,
    hooks: Hooks,
    overlay_owner: ?*ui.Node,
    open: *ui.Signal(bool),
    confirmation: *ui.Signal(bool),
    highlighted: *ui.Signal(u64),
    content: *ui.Node,
    root: *ui.Node,
    surface: *ui.Node,
    chrome: *ui.Node,
    painted_colors: T.Colors,
    button: *ui.Node,
    badge: *ui.Node,
    a11y_label: [96]u8 = undefined,
    scroll: ui.widgets.ScrollAreaResult,
    rows: ?*ui.Scope = null,
    pending: ?u64 = null,
    desired_height: f32 = 0,
    detail: *ui.Node,
    dialog: *ui.Node,
    title_icon: *ui.Node = undefined,
    control_styles: [2]*ui.Signal(ui.BoxStyle),
    confirmation_title: *ui.Node = undefined,
    accept_label: *ui.Signal([]const u8) = undefined,
    accept_disabled: *ui.Signal(bool) = undefined,
    confirmation_operation: ?u64 = null,
    history_open: *ui.Signal(bool) = undefined,
    history_dialog: *ui.Node = undefined,
    history_title: *ui.Node = undefined,
    history_status: *ui.Node = undefined,
    history_body: *ui.Node = undefined,
    history_scroll: *ui.Node = undefined,
    history_actions: *ui.Node = undefined,
    history_scope: ?*ui.Scope = null,
    history_entry: ?u64 = null,

    pub fn mount(cx: *ui.Cx, scope: *ui.Scope, anchor: *ui.Node, hooks: Hooks) !*View {
        return mountAt(cx, scope, anchor, null, hooks);
    }

    pub fn mountOwned(cx: *ui.Cx, scope: *ui.Scope, anchor: *ui.Node, owner: *ui.Node, hooks: Hooks) !*View {
        return mountAt(cx, scope, anchor, owner, hooks);
    }

    fn mountAt(cx: *ui.Cx, scope: *ui.Scope, anchor: *ui.Node, overlay_owner: ?*ui.Node, hooks: Hooks) !*View {
        const open = try scope.createSignal(bool, false);
        const confirmation = try scope.createSignal(bool, false);
        const popup = try ui.widgets.Popover(.{ .open = open, .trigger = .manual, .anchor = .{ .node = anchor }, .position = .bottom_start, .offset = .{ .static = 6 }, .width = 440, .max_height = 240, .close_on_escape = true, .close_on_outside_click = true, .constrain_width_to_viewport = true, .flip = true, .shift_main_axis = true, .viewport_padding = 8 }).mount(scope, cx);
        popup.wrapper.setStyleInline(cx.allocator, .{ .position = .absolute, .width = .{ .px = 0 }, .height = .{ .px = 0 }, .flex_shrink = 0 });
        popup.chrome.setStyleInline(cx.allocator, S.popover());
        const scroll = try ui.widgets.ScrollArea(.{ .height = 240, .direction = .vertical, .rubber_band_y = false }).mount(popup.scope, cx);
        scroll.container.setStyleInline(cx.allocator, S.listSurface());
        scroll.content.setStyleInline(cx.allocator, S.menu());
        scroll.container.meta.ownership.meta.test_id = "ai.sessions.menu";
        try popup.content.appendChild(cx.allocator, scroll.container);
        const badge = try Header.mountCountBadge(cx, anchor, "ai.sessions.count");
        const self = try scope.createState(View, .{ .cx = cx, .scope = popup.scope, .hooks = hooks, .overlay_owner = overlay_owner, .open = open, .confirmation = confirmation, .highlighted = try scope.createSignal(u64, 0), .content = scroll.content, .root = popup.wrapper, .surface = scroll.container, .chrome = popup.chrome, .painted_colors = T.current(), .button = anchor, .badge = badge, .scroll = scroll, .detail = undefined, .dialog = undefined, .control_styles = .{ try scope.createSignal(ui.BoxStyle, S.control(false)), try scope.createSignal(ui.BoxStyle, S.control(true)) } });
        const modal = try ui.widgets.Modal(.{ .managed_focus = overlay_owner == null, .open = confirmation, .width = 320, .max_height = 220, .background = T.current().overlay }).mount(scope, cx);
        if (overlay_owner) |owner| {
            _ = try @import("scoped_modal.zig").bind(cx, scope, modal, .{ .owner = .{ .node = owner } });
        } else if (!modal.portaled) if (cx.root) |root| try root.appendChild(cx.allocator, modal.overlay);
        self.dialog = modal.dialog;
        modal.dialog.setStyleInline(cx.allocator, S.dialog());
        modal.dialog.meta.ownership.meta.test_id = "ai.session.close.confirmation";
        modal.body.setStyleInline(cx.allocator, S.body());
        const heading = try ui.box(cx, .{ .width = .fill(), .height = .{ .fit = .{} }, .direction = .row, .align_items = .center, .gap = 8 }, .{});
        const heading_icon = try ui.iconTint(cx, ui.icons.circle_alert, T.current().warn_ink, .{ .width = .{ .px = 16 }, .height = .{ .px = 16 }, .flex_shrink = 0 });
        self.title_icon = heading_icon;
        heading_icon.meta.ownership.meta.test_id = "ai.session.close.icon";
        try heading.appendChild(cx.allocator, heading_icon);
        self.confirmation_title = try ui.textStyled(cx, titleStyle, "删除此 AI 会话？");
        try heading.appendChild(cx.allocator, self.confirmation_title);
        try modal.body.appendChild(cx.allocator, heading);
        self.detail = try ui.textStyled(cx, detailStyle, "将停止关联的任务、工具和请求。");
        try modal.body.appendChild(cx.allocator, self.detail);
        const actions = try ui.box(cx, S.actions(), .{});
        const cancel = try ui.widgets.Button(.{ .label = "取消", .variant = .secondary, .base_style = self.control_styles[0], .on_click = cx.on(View, self, cancelClose) }).mount(scope, cx);
        cancel.meta.ownership.meta.test_id = "ai.session.close.cancel";
        try actions.appendChild(cx.allocator, cancel);
        self.accept_label = try scope.createText("删除会话", .{});
        self.accept_disabled = try scope.createSignal(bool, false);
        const accept = try ui.widgets.Button(.{ .label = self.accept_label, .disabled = self.accept_disabled, .variant = .danger, .base_style = self.control_styles[1], .on_click = cx.on(View, self, acceptClose) }).mount(scope, cx);
        accept.meta.ownership.meta.test_id = "ai.session.close.accept";
        try actions.appendChild(cx.allocator, accept);
        try modal.body.appendChild(cx.allocator, actions);
        self.history_open = try scope.createSignal(bool, false);
        const history_modal = try ui.widgets.Modal(.{ .managed_focus = overlay_owner == null, .open = self.history_open, .width = 600, .max_height = 480, .background = T.current().overlay }).mount(scope, cx);
        if (overlay_owner) |owner| {
            _ = try @import("scoped_modal.zig").bind(cx, scope, history_modal, .{ .owner = .{ .node = owner } });
        } else if (!history_modal.portaled) if (cx.root) |root| try root.appendChild(cx.allocator, history_modal.overlay);
        self.history_dialog = history_modal.dialog;
        history_modal.dialog.meta.ownership.meta.test_id = "ai.history";
        history_modal.dialog.setStyleInline(cx.allocator, .{ .width = .{ .px = 600 }, .max_width = 600, .background = T.current().overlay, .border = .{ .radius = 12 } });
        history_modal.body.setStyleInline(cx.allocator, .{ .width = .fill(), .direction = .column, .padding = ui.Padding.all(16), .gap = 12 });
        const history_heading = try ui.box(cx, S.actions(), .{});
        self.history_title = try ui.textStyled(cx, titleStyle, "AI 会话");
        self.history_title.setStyleInline(cx.allocator, .{ .width = .fill(), .min_width = 0 });
        try history_heading.appendChild(cx.allocator, self.history_title);
        const history_close = try ui.widgets.Button(.{ .variant = .ghost, .icon_only = true, .icon_asset = ui.icons.x, .icon_size = 14, .a11y_label = "关闭会话历史", .base_style = S.rowAction(), .on_click = cx.on(View, self, closeHistory) }).mount(scope, cx);
        history_close.meta.ownership.meta.test_id = "ai.history.close";
        const history_close_hint = try @import("control_hint.zig").mount(cx, scope, history_close, "关闭会话历史", .{ .id = "ai.history.close.tooltip", .visible = self.history_open });
        try history_heading.appendChild(cx.allocator, history_close_hint.wrapper);
        try history_modal.body.appendChild(cx.allocator, history_heading);
        self.history_status = try ui.textStyled(cx, detailStyle, "只读查看");
        self.history_status.meta.ownership.meta.test_id = "ai.history.status";
        try history_modal.body.appendChild(cx.allocator, self.history_status);
        const history_scroll = try ui.widgets.ScrollArea(.{ .height = 220, .direction = .vertical }).mount(scope, cx);
        history_scroll.container.setStyleInline(cx.allocator, .{ .width = .fill(), .height = .{ .px = 220 }, .min_height = 0, .flex_shrink = 0 });
        self.history_scroll = history_scroll.container;
        self.history_body = try ui.textStyled(cx, detailStyle, "");
        self.history_body.meta.ownership.meta.test_id = "ai.history.body";
        self.history_body.setStyleInline(cx.allocator, .{ .width = .fill(), .height = .{ .fit = .{} }, .flex_shrink = 0 });
        try history_scroll.content.appendChild(cx.allocator, self.history_body);
        try history_modal.body.appendChild(cx.allocator, history_scroll.container);
        self.history_actions = try ui.box(cx, S.actions(), .{});
        self.history_actions.setStyleInline(cx.allocator, .{ .height = .{ .fit = .{} }, .flex_wrap = .wrap });
        try history_modal.body.appendChild(cx.allocator, self.history_actions);
        try scope.createEffect(.{ .view = self, .open = confirmation }, struct {
            fn apply(ctx: anytype) void {
                if (!ctx.open.get()) if (ctx.view.confirmation_operation) |operation| {
                    ctx.view.confirmation_operation = null;
                    if (ctx.view.hooks.confirmed) |callback| callback(ctx.view.hooks.context, operation, false);
                };
            }
        }.apply);

        try scope.createEffect(.{ .view = self, .publication = try cx.themeSignal(scope) }, struct {
            fn apply(ctx: anytype) void {
                _ = ctx.publication.get();
                ctx.view.retheme();
            }
        }.apply);
        self.reflow();
        return self;
    }
    /// Native Modal is fixed-width by default; constrain our surfaces and give
    /// the scrollable body only the space left by the real footer and heading.
    pub fn reflow(self: *View) void {
        const owner = if (self.overlay_owner) |node| node.globalRect() else ui.ComputedRect.init(0, 0, 0, 0);
        const width = @max(0, (if (owner.w > 0) owner.w else self.cx.viewport.width) - 32);
        const height = if (owner.h > 0) owner.h else self.cx.viewport.height;
        self.setPixels(self.dialog, true, @min(320, width));
        self.setPixels(self.history_dialog, true, @min(600, width));
        const fixed = 32 + 36 + 28 + @max(16, self.history_status.globalRect().h) + @max(28, self.history_actions.globalRect().h);
        const body_height = @min(220, @max(0, height - 32 - fixed));
        self.setPixels(self.history_scroll, false, body_height);
        self.setPixels(self.history_dialog, false, fixed + body_height);
    }
    fn setPixels(self: *View, node: *ui.Node, horizontal: bool, value: f32) void {
        const old = if (horizontal) node.style.width else node.style.height;
        if (old == .px and @abs(old.px - value) < 0.1) return;
        node.setStyleInline(self.cx.allocator, if (horizontal) .{ .width = .{ .px = value } } else .{ .height = .{ .px = value } });
    }
    fn retheme(self: *View) void {
        const next = T.current();
        if (@import("std").meta.eql(self.painted_colors, next)) return;
        repaint(self.content, self.painted_colors);
        repaint(self.dialog, self.painted_colors);
        repaint(self.history_dialog, self.painted_colors);
        self.chrome.setStyleInline(self.cx.allocator, S.popover());
        Header.repaintCountBadge(self.cx, self.badge);
        self.dialog.setStyleInline(self.cx.allocator, S.dialog());
        _ = self.title_icon.setTint(next.warn_ink);
        self.control_styles[0].set(S.control(false));
        self.control_styles[1].set(S.control(true));
        self.reflow();
        self.painted_colors = next;
        self.cx.requestRedraw();
    }
    pub fn updateBoundCount(self: *View, count: usize) !void {
        try Header.updateCountBadge(self.cx, self.badge, count);
        const label = try @import("std").fmt.bufPrint(&self.a11y_label, "AI 会话列表，{d} 个已绑定", .{count});
        if (self.button.behavior.interaction.a11y) |*a11y| a11y.label = label;
    }
    fn repaint(node: *ui.Node, previous: T.Colors) void {
        node.setBackground(remap(node.getBackground(), previous));
        if (node.getText()) |text| node.setTextColor(T.remapUiInk(text.color, previous));
        if (node.getIcon()) |icon| {
            var tint = T.remapUiInk(icon.tint, previous);
            if (node.meta.ownership.meta.test_id) |id| {
                inline for ([_]@import("../ai/assistant_store.zig").Phase{ .idle, .running, .approval, .done, .failed, .stopped }) |phase| {
                    if (@import("std").mem.eql(u8, id, phaseTestId(phase))) tint = phaseColor(phase);
                }
            }
            _ = node.setTint(tint);
        }
        for (node.children.items) |child| repaint(child, previous);
    }
    fn remap(color: ui.Color, previous: T.Colors) ui.Color {
        if (T.remapUiSurface(color, previous)) |next| return next;
        if (ui.Color.eql(color, previous.accent.withAlpha(24))) return T.current().accent.withAlpha(24);
        inline for (@typeInfo(T.Colors).@"struct".field_names) |field| {
            if (ui.Color.eql(color, @field(previous, field).withAlpha(24))) return @field(T.current(), field).withAlpha(24);
            if (ui.Color.eql(color, @field(previous, field))) return @field(T.current(), field);
        }
        return color;
    }
    fn titleStyle(_: *const ui.ThemeTokens) ui.TextStyle {
        var s = S.text(true);
        s.font_weight = 600;
        s.font_size = 13;
        s.line_height = 20.0 / 13.0;
        return s;
    }
    fn detailStyle(_: *const ui.ThemeTokens) ui.TextStyle {
        return S.dialogDetail();
    }
    fn closeMenu(self: *View) void {
        self.open.set(false);
    }
    fn cancelClose(self: *View) void {
        if (self.confirmation_operation) |operation| {
            self.confirmation_operation = null;
            if (self.hooks.confirmed) |callback| callback(self.hooks.context, operation, false);
        }
        self.pending = null;
        self.confirmation.set(false);
    }
    fn acceptClose(self: *View) void {
        if (self.accept_disabled.peek()) return;
        if (self.confirmation_operation) |operation| {
            self.confirmation_operation = null;
            self.confirmation.set(false);
            if (self.hooks.confirmed) |callback| callback(self.hooks.context, operation, true);
            return;
        }
        const id = self.pending orelse return;
        self.pending = null;
        self.confirmation.set(false);
        self.open.set(false);
        self.hooks.remove(self.hooks.context, id);
    }
    pub fn confirm(self: *View, id: u64) void {
        self.confirmation_operation = null;
        self.confirmation_title.setTextContent(self.cx.allocator, "删除此 AI 会话？") catch return;
        self.detail.setTextContent(self.cx.allocator, "将删除此会话及其历史。已绑定的会话须先结束并解绑。") catch return;
        self.accept_label.set("删除会话");
        self.accept_disabled.set(false);
        self.pending = id;
        _ = self.title_icon.setTint(T.current().warn_ink);
        self.dialog.setStyleInline(self.cx.allocator, S.dialog());
        self.control_styles[0].set(S.control(false));
        self.control_styles[1].set(S.control(true));
        self.reflow();
        self.confirmation.set(true);
    }
    pub fn confirmOperation(self: *View, operation: u64, title: []const u8, label: []const u8) !void {
        self.pending = null;
        self.open.set(false);
        self.history_open.set(false);
        try self.confirmation_title.setTextContent(self.cx.allocator, title);
        try self.detail.setTextContent(self.cx.allocator, "当前任务将停止，待处理消息暂停。历史和草稿保留，连接保持打开。");
        self.accept_label.set(label);
        self.accept_disabled.set(false);
        self.dialog.setStyleInline(self.cx.allocator, .{ .height = .{ .fit = .{} } });
        self.confirmation_operation = operation;
        self.reflow();
        self.confirmation.set(true);
        self.cx.requestRedraw();
    }
    pub fn showProgress(self: *View, operation: u64) !void {
        try self.confirmation_title.setTextContent(self.cx.allocator, "已绑定 · 正在停止当前任务");
        try self.detail.setTextContent(self.cx.allocator, "正在等待资源释放。取消只取消后续恢复或使用副本，已受理的结束仍会完成；历史和草稿会保留。");
        self.accept_label.set("等待释放…");
        self.accept_disabled.set(true);
        self.confirmation_operation = operation;
        self.reflow();
        self.confirmation.set(true);
    }
    fn closeHistory(self: *View) void {
        self.history_open.set(false);
    }
    pub fn showHistory(self: *View, entry: Entry, text: []const u8) !void {
        self.open.set(false);
        try self.history_title.setTextContent(self.cx.allocator, entry.title);
        try self.history_status.setTextContent(self.cx.allocator, if (entry.ending) "已绑定 · 正在停止任务 · 只读查看" else if (entry.bound) "已绑定 · 只读查看" else "未绑定 · 历史环境 · 只读查看");
        try self.history_body.setTextContent(self.cx.allocator, if (text.len == 0) "此会话尚无已保存消息，草稿与待处理记录仍保留。" else text);
        if (self.cx.pressed_node) |node| if (node.isDescendantOf(self.history_actions)) self.cx.cancelPointerInteractions(.explicit);
        while (self.history_actions.children.items.len != 0) {
            const child = self.history_actions.children.items[0];
            self.cx.detachChild(self.history_actions, child);
            self.cx.destroyDetached(child);
        }
        if (self.history_scope) |old| old.dispose();
        const scope = try self.scope.childScope();
        self.history_scope = scope;
        self.history_entry = entry.id;
        if (entry.can_copy) {
            try self.historyButton(scope, entry.id, .copy, "复制，不使用", "ai.history.copy");
            try self.historyButton(scope, entry.id, .copy_use, "复制到当前 Agent", "ai.history.copy_use");
        }
        if (entry.bound) {
            try self.historyButton(scope, entry.id, .locate, "定位", "ai.history.locate");
            if (entry.active and !entry.ending) try self.historyButton(scope, entry.id, .end, "结束并解绑", "ai.history.end");
        } else if (entry.can_restore) try self.historyButton(scope, entry.id, .restore, if (entry.first_use) "使用到当前 Agent" else "恢复到当前 Agent", "ai.history.restore");
        if (entry.has_children) try self.historyButton(scope, entry.id, .children, "查看子智能体", "ai.history.children");
        self.reflow();
        self.history_open.set(true);
        self.cx.requestRedraw();
    }
    const HistoryAction = struct {
        view: *View,
        id: u64,
        action: Action,
        fn run(self: *HistoryAction) void {
            if (self.action == .end or self.action == .children) self.view.history_open.set(false);
            if (self.view.hooks.act) |act| act(self.view.hooks.context, self.id, self.action);
        }
    };
    fn historyButton(self: *View, scope: *ui.Scope, id: u64, action: Action, label: []const u8, test_id: []const u8) !void {
        const state = try scope.createState(HistoryAction, .{ .view = self, .id = id, .action = action });
        const button = try ui.widgets.Button(.{ .label = if (action == .children) "" else label, .a11y_label = label, .icon_only = action == .children, .icon_asset = if (action == .children) ui.icons.bot else null, .variant = .secondary, .base_style = @import("ai_close_confirmation_styles.zig").button(false), .on_click = self.cx.on(HistoryAction, state, HistoryAction.run) }).mount(scope, self.cx);
        button.meta.ownership.meta.test_id = test_id;
        try self.history_actions.appendChild(self.cx.allocator, button);
    }
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

        const heading = try ui.box(self.cx, S.heading(), .{});
        heading.meta.ownership.meta.test_id = "ai.sessions.heading";
        try heading.appendChild(self.cx.allocator, try ui.iconTint(self.cx, ui.icons.get("messages-square").?, T.current().fg_2, .{ .width = .{ .px = 12 }, .height = .{ .px = 12 } }));
        var heading_style = S.text(true);
        heading_style.font_weight = 600;
        heading_style.font_size = 11.5;
        heading_style.line_height = 16.0 / 11.5;
        try heading.appendChild(self.cx.allocator, try ui.text(self.cx, "会话", heading_style));
        const close = try ui.widgets.Button(.{ .variant = .ghost, .icon_only = true, .icon_asset = ui.icons.x, .icon_size = 14, .a11y_label = "关闭 AI 会话列表", .base_style = @as(ui.BoxStyle, .{ .width = .{ .px = 24 }, .height = .{ .px = 24 }, .padding = .{} }), .on_click = self.cx.on(View, self, closeMenu) }).mount(scope, self.cx);
        close.meta.ownership.meta.test_id = "ai.sessions.close";
        try heading.appendChild(self.cx.allocator, try ui.spacer(self.cx));
        try heading.appendChild(self.cx.allocator, close);
        try self.content.appendChild(self.cx.allocator, heading);
        if (entries.len == 0) {
            const empty_row = try ui.box(self.cx, .{ .width = .fill(), .height = .{ .px = 33 }, .padding = .{ .left = 8, .right = 8 }, .flex_shrink = 0 }, .{});
            const empty = try ui.text(self.cx, "暂无已保存对话。新建会话时，当前对话和草稿会保留在这里。", .{ .font_size = 10, .line_height = 1.65, .color = T.current().fg_2, .wrap = .word });
            empty.meta.ownership.meta.test_id = "ai.sessions.empty";
            empty.setStyleInline(self.cx.allocator, .{ .width = .fill(), .height = .{ .px = 33 } });
            try empty_row.appendChild(self.cx.allocator, empty);
            try self.content.appendChild(self.cx.allocator, empty_row);
        }
        self.highlighted.set(0);
        for (entries) |entry| if (entry.active) {
            self.highlighted.set(entry.id);
            break;
        };
        for (entries) |entry| {
            try self.content.appendChild(self.cx.allocator, try RowView.mount(self.cx, scope, entry, self.hooks, self.highlighted, self.open));
        }
        if (self.hooks.act != null and entries.len >= 50) {
            const more = try scope.createState(HistoryAction, .{ .view = self, .id = 0, .action = .more });
            const button = try ui.widgets.Button(.{ .label = "显示更多", .variant = .ghost, .on_click = self.cx.on(HistoryAction, more, HistoryAction.run) }).mount(scope, self.cx);
            button.meta.ownership.meta.test_id = "ai.sessions.more";
            try self.content.appendChild(self.cx.allocator, button);
        }
        self.desired_height = @min(if (self.hooks.act != null) @as(f32, 240) else 160, 38 + if (entries.len == 0) @as(f32, 33) else @as(f32, @floatFromInt(entries.len)) * 56 + @as(f32, @floatFromInt(entries.len - 1)) * 2);
        self.surface.setStyleInline(self.cx.allocator, .{ .height = .{ .px = self.desired_height }, .display = .flex });
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
                RowView.updatePhase(self.cx, row, phase);
                break;
            }
        }
    }
    const phaseTestId = RowView.phaseTestId;
    const phaseIcon = RowView.phaseIcon;
    const phaseColor = RowView.phaseColor;
    const phaseLabel = RowView.phaseLabel;
};
