//! Frozen local-close details; no process operation occurs before confirmation.
const std = @import("std");
const ui = @import("ui");
const styles = @import("local_close_styles.zig");
const theme = @import("app_theme.zig");
const SessionId = @import("session_lifecycle.zig").SessionId;
const Risk = @import("../host/process_service.zig").CloseRiskSnapshot;
pub const Hooks = struct { context: *anyopaque, resolve: *const fn (*anyopaque, SessionId, bool) void };
pub const View = struct {
    cx: *ui.Cx,
    hooks: Hooks,
    open: *ui.Signal(bool),
    overlay: *ui.Node,
    session: ?SessionId = null,
    identity: *ui.Node,
    risk_title: *ui.Node,
    risk_detail: *ui.Node,
    extra: *ui.Node,
    extra_text: *ui.Node,
    dialog: *ui.Node,
    cancel_button: *ui.Node,
    risk: *ui.Node = undefined,
    title_icon: *ui.Node = undefined,
    title: *ui.Node = undefined,
    notice: *ui.Node = undefined,
    explanation: *ui.Node = undefined,
    colors: theme.Colors = undefined,

    pub fn mount(cx: *ui.Cx, scope: *ui.Scope, hooks: Hooks) !*View {
        const self = try cx.allocator.create(View);
        errdefer cx.allocator.destroy(self);
        const open = try scope.createSignal(bool, false);
        self.* = .{ .cx = cx, .hooks = hooks, .open = open, .overlay = undefined, .identity = undefined, .risk_title = undefined, .risk_detail = undefined, .extra = undefined, .extra_text = undefined, .dialog = undefined, .cancel_button = undefined, .colors = theme.current() };
        const modal = try ui.widgets.Modal(.{ .open = open, .width = 480, .max_height = 500, .background = theme.current().overlay, .on_open_change = cx.on(View, self, changed) }).mount(scope, cx);
        self.overlay = modal.overlay;
        if (!modal.portaled) if (cx.root) |root| try root.appendChild(cx.allocator, modal.overlay);
        self.dialog = modal.dialog;
        modal.dialog.setStyleInline(cx.allocator, styles.dialog());
        modal.dialog.meta.ownership.meta.test_id = "local.close.confirmation";
        modal.body.setStyleInline(cx.allocator, styles.body());
        const head = try ui.box(cx, styles.row(28), .{});
        self.title_icon = try ui.iconTint(cx, ui.icons.terminal, theme.current().accent, .{ .width = .{ .px = 18 }, .height = .{ .px = 18 } });
        try head.appendChild(cx.allocator, self.title_icon);
        self.title = try ui.text(cx, "关闭本地会话？", styles.text(13, true));
        try head.appendChild(cx.allocator, self.title);
        try head.appendChild(cx.allocator, try ui.spacer(cx));
        const close = try ui.widgets.Button(.{ .variant = .ghost, .icon_only = true, .icon_asset = ui.icons.x, .a11y_label = "取消关闭本地会话", .on_click = cx.on(View, self, cancel) }).mount(scope, cx);
        close.setStyleInline(cx.allocator, .{ .width = .{ .px = 24 }, .height = .{ .px = 24 }, .padding = .{}, .border = .{ .radius = 7 } });
        try head.appendChild(cx.allocator, close);
        try modal.body.appendChild(cx.allocator, head);
        self.identity = try self.label(modal.body, "", 18, styles.text(12, true));
        const risk = try ui.box(cx, styles.risk(), .{});
        self.risk = risk;
        self.risk_title = try self.label(risk, "", 18, styles.text(12, true));
        var detail_style = styles.text(11.5, false);
        detail_style.use_monospace_font = true;
        self.risk_detail = try self.label(risk, "", 18, detail_style);
        try modal.body.appendChild(cx.allocator, risk);
        const scroll = try ui.widgets.ScrollArea(.{ .direction = .vertical, .rubber_band_y = false }).mount(scope, cx);
        self.extra = scroll.container;
        scroll.container.setStyleInline(cx.allocator, .{ .width = .fill(), .height = .{ .px = 0 }, .flex_shrink = 0, .display = .none });
        const jobs_style = styles.text(11.5, false);
        const extra_text = try ui.text(cx, "", .{ .font_size = jobs_style.font_size, .color = jobs_style.color, .wrap = .word, .use_monospace_font = true });
        self.extra_text = extra_text;
        try scroll.content.appendChild(cx.allocator, extra_text);
        try modal.body.appendChild(cx.allocator, scroll.container);
        self.notice = try self.label(modal.body, "关闭将结束该本地会话及其进程。历史记录保留。", 18, styles.text(12, false));
        self.explanation = try self.label(modal.body, "取消会回到原终端，进程继续运行。", 16, styles.text(11, false));
        const actions = try ui.box(cx, styles.row(30), .{});
        try actions.appendChild(cx.allocator, try ui.spacer(cx));
        self.cancel_button = try ui.widgets.Button(.{ .label = "取消", .variant = .secondary, .on_click = cx.on(View, self, cancel) }).mount(scope, cx);
        self.cancel_button.setStyleInline(cx.allocator, styles.button(72, false));
        self.cancel_button.meta.ownership.meta.test_id = "local.close.cancel";
        try actions.appendChild(cx.allocator, self.cancel_button);
        const confirm = try ui.widgets.Button(.{ .label = "结束并关闭", .variant = .danger, .on_click = cx.on(View, self, accept) }).mount(scope, cx);
        confirm.setStyleInline(cx.allocator, styles.button(112, true));
        confirm.meta.ownership.meta.test_id = "local.close.accept";
        try actions.appendChild(cx.allocator, confirm);
        try modal.body.appendChild(cx.allocator, actions);
        try scope.onCleanup(View, self, cleanup);
        try cx.addAfterLayoutHook(self, afterLayout);
        return self;
    }
    fn label(self: *View, parent: *ui.Node, value: []const u8, height: f32, style: ui.TextStyle) !*ui.Node {
        const node = try ui.text(self.cx, value, style);
        node.setStyleInline(self.cx.allocator, .{ .width = .fill(), .height = .{ .px = height }, .flex_shrink = 0 });
        try parent.appendChild(self.cx.allocator, node);
        return node;
    }
    pub fn show(self: *View, id: SessionId, snapshot: ?*const Risk) !void {
        if (self.session != null) return error.CloseConfirmationAlreadyOpen;
        self.retheme();
        var buffer: [256]u8 = undefined;
        try self.identity.setTextContent(self.cx.allocator, try std.fmt.bufPrint(&buffer, "本地 · zsh · #{d}", .{id}));
        var title: []const u8 = "无法核实本地进程状态";
        var detail: []const u8 = "进程信息未知，确认关闭后才会尝试清理";
        var extra: std.Io.Writer.Allocating = .init(self.cx.allocator);
        defer extra.deinit();
        if (snapshot) |risk| {
            switch (risk.foreground_state) {
                .task => {
                    title = "仍有前台进程";
                    if (risk.foreground) |fg| detail = try std.fmt.bufPrint(&buffer, "{s} · PID {d}", .{ std.mem.sliceTo(&fg.name, 0), fg.pid });
                },
                .idle_shell => {
                    title = "本地 shell 仍在运行";
                    detail = "关闭将结束本地 shell";
                },
                .not_running => {
                    title = "本地进程已结束";
                    detail = "仍需释放该会话的资源";
                },
                .unknown => {},
            }
            for (risk.active_exec) |job| try extra.writer.print("{s} · PID {?d} · {s}{s}\n", .{ @tagName(job.state), job.pid, job.command, if (job.command_truncated) " …" else "" });
            if (risk.unknown) try extra.writer.writeAll("部分进程状态无法核实\n");
        }
        try self.risk_title.setTextContent(self.cx.allocator, title);
        try self.risk_detail.setTextContent(self.cx.allocator, detail);
        const bytes = extra.writer.buffered();
        try self.extra_text.setTextContent(self.cx.allocator, bytes);
        self.extra.setDisplay(if (bytes.len == 0) .none else .flex);
        self.extra.setStyle(self.cx.allocator, .height, .{ .px = 88 });
        self.dialog.setStyle(self.cx.allocator, .height, .{ .px = if (bytes.len == 0) 220 else 314 });
        self.session = id;
        self.open.set(true);
        self.cx.setFocus(self.cancel_button);
        self.cx.requestRedraw();
    }
    fn retheme(self: *View) void {
        const c = theme.current();
        self.dialog.setStyleInline(self.cx.allocator, styles.dialogPaint());
        self.risk.setBackground(c.surface_2);
        self.cancel_button.setBackground(c.surface_2);
        _ = self.title_icon.setTint(c.accent);
        for ([_]*ui.Node{ self.title, self.identity, self.risk_title }) |node| node.setTextColor(c.fg_1);
        for ([_]*ui.Node{ self.risk_detail, self.extra_text, self.notice, self.explanation }) |node| node.setTextColor(c.fg_2);
        self.colors = c;
        self.cx.requestRedraw();
    }
    fn afterLayout(raw: *anyopaque, _: u8, _: bool) ui.AfterLayoutResult {
        const self: *View = @ptrCast(@alignCast(raw));
        if (!std.meta.eql(self.colors, theme.current())) self.retheme();
        return .done;
    }
    pub fn cancel(self: *View) void {
        self.resolve(false);
    }
    pub fn accept(self: *View) void {
        self.resolve(true);
    }
    fn resolve(self: *View, accepted: bool) void {
        const id = self.session orelse return;
        self.session = null;
        self.open.set(false);
        self.hooks.resolve(self.hooks.context, id, accepted);
        self.cx.requestRedraw();
    }
    fn changed(self: *View, value: bool) void {
        if (!value) self.cancel();
    }
    fn cleanup(self: *View) void {
        self.cx.removeAfterLayoutHook(self);
        self.cx.allocator.destroy(self);
    }
};
