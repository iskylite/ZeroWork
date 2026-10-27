const std = @import("std");
const ui = @import("ui");
pub const policy = @import("../ai/command_error_hint.zig");
const vt = @import("../vt/snapshot.zig");
const SessionHandle = @import("../host/identity.zig").SessionHandle;
const theme = @import("app_theme.zig");
const S = @import("command_error_hint_styles.zig");
const T = @import("terminal_styles.zig");
const N = @import("notification_styles.zig");

pub const View = struct {
    cx: *ui.Cx,
    scope: *ui.Scope,
    root: *ui.Node,
    icon: *ui.Node,
    title: *ui.Node,
    detail: *ui.Node,
    exit_tag: *ui.Node,
    command: *ui.Node,
    output: *ui.Node,
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
        const icon = try ui.iconTint(cx, ui.icons.circle_alert, theme.current().danger_ink, N.icon());
        try header.appendChild(cx.allocator, icon);
        const title = try ui.textStyled(cx, S.title, "命令执行失败");
        title.setStyleInline(cx.allocator, S.textBox(cx.tokens));
        try header.appendChild(cx.allocator, title);
        const close = try ui.widgets.Button(.{ .variant = .ghost, .icon_only = true, .a11y_label = "关闭命令失败提示", .base_style = N.close(cx.tokens), .hover_style = T.messageCloseHover(), .on_click = cx.on(View, self, dismiss) }).mount(scope, cx);
        close.setStyleInline(cx.allocator, N.close(cx.tokens));
        close.meta.ownership.meta.test_id = "terminal.ai-error-hint.dismiss";
        const close_icon = try ui.iconTint(cx, ui.icons.x, theme.current().fg_2, N.closeIcon());
        try close.appendChild(cx.allocator, close_icon);
        try header.appendChild(cx.allocator, close);
        const summary_box = try ui.box(cx, .{ .width = .fill(), .height = .{ .px = 40 }, .direction = .column, .gap = 4, .flex_shrink = 0 }, .{});
        try root.appendChild(cx.allocator, summary_box);
        const command = try ui.textStyled(cx, S.summary, "");
        const output = try ui.textStyled(cx, S.summary, "");
        for ([_]*ui.Node{ command, output }) |line| {
            line.setStyleInline(cx.allocator, .{ .width = .fill(), .height = .{ .px = 18 }, .min_width = 0, .overflow = .hidden, .flex_shrink = 0 });
            try summary_box.appendChild(cx.allocator, line);
        }
        command.meta.ownership.meta.test_id = "terminal.ai-error-hint.command";
        output.meta.ownership.meta.test_id = "terminal.ai-error-hint.output";
        const detail = try ui.textStyled(cx, S.detail, "");
        detail.setStyleInline(cx.allocator, .{ .height = .{ .px = 18 }, .flex_shrink = 0 });
        const exit_tag = try ui.boxStyled(cx, S.exitTag, .{});
        exit_tag.meta.ownership.meta.test_id = "terminal.ai-error-hint.exit";
        try exit_tag.appendChild(cx.allocator, detail);
        const actions = try ui.boxStyled(cx, S.actions, .{});
        try root.appendChild(cx.allocator, actions);
        try actions.appendChild(cx.allocator, exit_tag);
        const open = try ui.widgets.Button(.{ .variant = .primary, .a11y_label = "在原会话 AI 助手中分析失败命令", .base_style = S.open(cx.tokens), .hover_style = S.openHover(), .on_click = cx.on(View, self, activate) }).mount(scope, cx);
        open.setStyleInline(cx.allocator, S.open(cx.tokens));
        open.meta.ownership.meta.test_id = "terminal.ai-error-hint.open";
        const open_text = try ui.textStyled(cx, S.actionText, "询问 AI");
        try open.appendChild(cx.allocator, open_text);
        try actions.appendChild(cx.allocator, open);
        root.setDisplay(.none);
        self.* = .{ .cx = cx, .scope = scope, .root = root, .icon = icon, .title = title, .detail = detail, .exit_tag = exit_tag, .command = command, .output = output, .close = close, .close_icon = close_icon, .open = open, .open_text = open_text, .model = policy.Model.init(cx.allocator) };
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
            const preview = try policy.outputPreview(self.cx.allocator, projection);
            defer self.cx.allocator.free(preview);
            const command_text = try std.fmt.allocPrint(self.cx.allocator, "命令  {s}", .{if (hint.command.len == 0) "（未提供）" else hint.command});
            defer self.cx.allocator.free(command_text);
            const output_text = try std.fmt.allocPrint(self.cx.allocator, "输出  {s}", .{if (preview.len == 0) "命令未返回错误详情" else preview});
            defer self.cx.allocator.free(output_text);
            for (command_text) |*byte| if (byte.* == '\n' or byte.* == '\r' or byte.* == '\t') {
                byte.* = ' ';
            };
            for (output_text) |*byte| if (byte.* == '\n' or byte.* == '\r' or byte.* == '\t') {
                byte.* = ' ';
            };
            try self.command.setTextContent(self.cx.allocator, command_text);
            try self.output.setTextContent(self.cx.allocator, output_text);
            var buffer: [64]u8 = undefined;
            try self.detail.setTextContent(self.cx.allocator, try std.fmt.bufPrint(&buffer, "退出码 {d}", .{hint.exit_code}));
            self.colors = null; // Repaint the tag even when only the exit code changed.
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
        const exit_code = if (self.model.pending) |hint| hint.exit_code else 1;
        self.detail.setTextColor(S.exitInk(exit_code));
        self.exit_tag.setStyleInline(self.cx.allocator, S.exitTagFor(exit_code));
        self.command.setTextColor(c.fg_1);
        self.output.setTextColor(c.fg_2);
        self.open_text.setTextColor(theme.actionForeground(c.action_accent));
        self.close.setStyleInline(self.cx.allocator, N.close(self.cx.tokens));
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
