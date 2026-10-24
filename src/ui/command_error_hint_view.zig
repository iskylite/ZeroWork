const std = @import("std");
const ui = @import("ui");
pub const policy = @import("../ai/command_error_hint.zig");
const vt = @import("../vt/snapshot.zig");
const SessionHandle = @import("../host/identity.zig").SessionHandle;
const theme = @import("app_theme.zig");
const S = @import("command_error_hint_styles.zig");
const T = @import("terminal_styles.zig");

pub const View = struct {
    cx: *ui.Cx,
    scope: *ui.Scope,
    root: *ui.Node,
    icon: *ui.Node,
    title: *ui.Node,
    detail: *ui.Node,
    close: *ui.Node,
    close_icon: *ui.Node,
    open: *ui.Node,
    open_text: *ui.Node,
    model: policy.Model,
    handler: ?policy.Handler = null,
    colors: ?theme.Colors = null,
    pub fn create(cx: *ui.Cx, parent: *ui.Node) !*View {
        const self = try cx.allocator.create(View);
        errdefer cx.allocator.destroy(self);
        const scope = try ui.Scope.init(cx.allocator, null, cx.owner);
        errdefer scope.dispose();
        const root = try ui.box(cx, S.panel(parent.rectFromWorldOrFallback().w), .{});
        errdefer cx.destroyDetached(root);
        root.meta.ownership.meta.test_id = "terminal.ai-error-hint";
        root.behavior.interaction.a11y = .{ .role = .status, .live = "polite" };
        root.behavior.events.on_event = blockPointer;
        const header = try ui.boxStyled(cx, S.header, .{});
        try root.appendChild(cx.allocator, header);
        const icon = try ui.iconTint(cx, ui.icons.circle_alert, theme.current().danger_ink, T.messageIcon());
        try header.appendChild(cx.allocator, icon);
        const title = try ui.textStyled(cx, S.title, "命令执行失败");
        title.setStyleInline(cx.allocator, S.textBox(cx.tokens));
        try header.appendChild(cx.allocator, title);
        const close = try ui.widgets.Button(.{ .variant = .ghost, .icon_only = true, .a11y_label = "关闭命令失败提示", .base_style = T.messageClose(cx.tokens), .hover_style = T.messageCloseHover(), .on_click = cx.on(View, self, dismiss) }).mount(scope, cx);
        close.setStyleInline(cx.allocator, T.messageClose(cx.tokens));
        close.meta.ownership.meta.test_id = "terminal.ai-error-hint.dismiss";
        const close_icon = try ui.iconTint(cx, ui.icons.x, theme.current().fg_2, T.messageIcon());
        try close.appendChild(cx.allocator, close_icon);
        try header.appendChild(cx.allocator, close);
        const detail = try ui.textStyled(cx, S.detail, "");
        detail.setStyleInline(cx.allocator, .{ .width = .fill(), .height = .{ .px = 16 }, .overflow = .hidden });
        try root.appendChild(cx.allocator, detail);
        const actions = try ui.boxStyled(cx, S.actions, .{});
        try root.appendChild(cx.allocator, actions);
        const open = try ui.widgets.Button(.{ .variant = .secondary, .a11y_label = "在原会话 AI 助手中分析失败命令", .base_style = S.open(cx.tokens), .hover_style = T.messageCloseHover(), .on_click = cx.on(View, self, activate) }).mount(scope, cx);
        open.setStyleInline(cx.allocator, S.open(cx.tokens));
        open.meta.ownership.meta.test_id = "terminal.ai-error-hint.open";
        const open_text = try ui.textStyled(cx, S.actionText, "询问 AI");
        try open.appendChild(cx.allocator, open_text);
        try actions.appendChild(cx.allocator, open);
        root.setDisplay(.none);
        self.* = .{ .cx = cx, .scope = scope, .root = root, .icon = icon, .title = title, .detail = detail, .close = close, .close_icon = close_icon, .open = open, .open_text = open_text, .model = policy.Model.init(cx.allocator) };
        try parent.appendChild(cx.allocator, root);
        return self;
    }
    pub fn destroy(self: *View) void {
        self.scope.dispose();
        self.model.deinit();
        if (self.root.parent) |parent| self.cx.detachChild(parent, self.root);
        self.cx.destroyDetached(self.root);
        self.cx.allocator.destroy(self);
    }
    pub fn configure(self: *View, owner: SessionHandle, enabled: bool, handler: ?policy.Handler) void {
        self.model.configure(owner, enabled and handler != null);
        self.handler = handler;
        if (self.model.pending == null) self.root.setDisplay(.none);
        self.retheme();
    }
    pub fn observe(self: *View, owner: SessionHandle, projection: *const vt.Projection) !void {
        if (try self.model.observe(owner, projection)) {
            const hint = self.model.pending.?;
            var buffer: [64]u8 = undefined;
            try self.detail.setTextContent(self.cx.allocator, try std.fmt.bufPrint(&buffer, "退出码 {d}", .{hint.exit_code}));
            self.root.setDisplay(.flex);
            self.cx.requestRedraw();
        }
        self.retheme();
    }
    pub fn dismiss(self: *View) void {
        self.model.dismiss();
        self.root.setDisplay(.none);
        self.cx.requestRedraw();
    }
    pub fn resetFacts(self: *View) void {
        self.model.resetFacts();
        self.root.setDisplay(.none);
        self.cx.requestRedraw();
    }
    pub fn activate(self: *View) void {
        const handler = self.handler orelse return;
        const pending = self.model.pending orelse return;
        const hint = self.model.current(pending.owner, pending.command_id) orelse return;
        handler.on_open(handler.context, hint) catch return;
        self.dismiss();
    }
    pub fn retheme(self: *View) void {
        const c = theme.current();
        const width = if (self.root.parent) |parent| parent.rectFromWorldOrFallback().w else T.message_width;
        const style = S.panel(width);
        if (self.colors != null and std.meta.eql(self.colors.?, c) and self.root.style.width == .px and self.root.style.width.px == style.width.?.px) return;
        self.root.setStyleInline(self.cx.allocator, style);
        self.title.setTextColor(c.fg_1);
        self.detail.setTextColor(c.fg_2);
        self.open_text.setTextColor(c.fg_2);
        self.close.setStyleInline(self.cx.allocator, T.messageClose(self.cx.tokens));
        self.open.setStyleInline(self.cx.allocator, S.open(self.cx.tokens));
        _ = self.icon.setTint(c.danger_ink);
        _ = self.close_icon.setTint(c.fg_2);
        self.colors = c;
        self.cx.requestRedraw();
    }
    fn blockPointer(event: ui.events.Event, _: ?*anyopaque) ui.events.EventResult {
        return switch (event) {
            .mouse_down, .mouse_up, .click => .stop,
            else => .ignored,
        };
    }
};
