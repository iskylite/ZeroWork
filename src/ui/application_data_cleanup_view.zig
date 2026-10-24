//! Confirmation and truthful failure UI only. The application host owns all IO.
const std = @import("std");
const ui = @import("ui");
const S = @import("application_data_cleanup_styles.zig");
pub const Action = enum { confirm, retry, dismiss };
pub const Hooks = struct { context: *anyopaque, action: *const fn (*anyopaque, Action) void };
pub const Mode = enum { confirm, working, failed };
pub const scope_text = "删除本应用的配置、主机、会话记录、缓存与诊断日志。\n同时删除此应用范围的钥匙串凭据，以及旧 ~/.zerowork\n中的迁移残余。";
pub const preserved_text = "保留共享 ~/.ssh/known_hosts、外部私钥，\n以及用户下载或导出的文件。";
pub const outcome_text = "不可撤销。清除后退出应用，重启恢复初始状态。";

pub const View = struct {
    cx: *ui.Cx,
    hooks: Hooks,
    open: *ui.Signal(bool),
    disabled: *ui.Signal(bool),
    busy: *ui.Signal(bool),
    dialog: *ui.Node,
    title: *ui.Node,
    headline: *ui.Node,
    detail: *ui.Node,
    preserved: *ui.Node,
    outcome: *ui.Node,
    message: *ui.Node,
    cancel: *ui.Node,
    cancel_label: *ui.Node,
    primary: *ui.Node,
    primary_label: *ui.Node,
    mode: Mode = .confirm,
    blocked: bool = false,
    retryable: bool = false,
    focus_cancel_pending: bool = false,
    colors: S.theme.Colors,

    pub fn mount(cx: *ui.Cx, scope: *ui.Scope, hooks: Hooks) !*View {
        const self = try cx.allocator.create(View);
        errdefer cx.allocator.destroy(self);
        const open = try scope.createSignal(bool, false);
        const disabled = try scope.createSignal(bool, false);
        const busy = try scope.createSignal(bool, false);
        const modal = try ui.widgets.Modal(.{ .open = ui.split(open, cx.on(View, self, openChanged)), .width = S.width, .max_height = S.max_height, .background = S.theme.current().overlay, .close_on_overlay = false }).mount(scope, cx);
        if (!modal.portaled) if (cx.root) |root| try root.appendChild(cx.allocator, modal.overlay);
        modal.dialog.setStyleInline(cx.allocator, S.dialog(cx.viewport.width));
        modal.dialog.meta.ownership.meta.test_id = "data.cleanup.modal";
        if (modal.dialog.behavior.interaction.a11y) |*a| a.label = "清除全部应用数据";
        modal.body.setStyleInline(cx.allocator, S.body());
        const title = try text(cx, modal.body, "清除全部应用数据？", 13, 28, 700, 28);
        const headline = try text(cx, modal.body, "将清除全部应用数据", 14, 22, 700, 22);
        const detail = try text(cx, modal.body, scope_text, 11.5, 18, 400, 54);
        const preserved = try text(cx, modal.body, preserved_text, 11.5, 18, 400, 36);
        const outcome = try text(cx, modal.body, outcome_text, 11.5, 18, 400, 18);
        const message = try text(cx, modal.body, "", 11.5, 18, 400, 36);
        message.meta.ownership.meta.test_id = "data.cleanup.message";
        message.behavior.interaction.a11y = .{ .role = .status, .live = "polite" };
        const actions = try ui.box(cx, S.row(), .{});
        const cancel = try ui.widgets.Button(.{ .variant = .secondary, .disabled = busy, .a11y_label = "取消清除并返回设置", .base_style = S.button(false, false), .on_click = cx.on(View, self, dismiss) }).mount(scope, cx);
        cancel.setStyleInline(cx.allocator, S.button(false, false));
        cancel.meta.ownership.meta.test_id = "data.cleanup.cancel";
        const cancel_label = try ui.text(cx, "取消", S.text(12, 18, 500));
        try cancel.appendChild(cx.allocator, cancel_label);
        try actions.appendChild(cx.allocator, cancel);
        const primary = try ui.widgets.Button(.{ .variant = .danger, .disabled = disabled, .a11y_label = "清除全部应用数据并退出", .base_style = S.button(true, false), .on_click = cx.on(View, self, activate) }).mount(scope, cx);
        primary.setStyleInline(cx.allocator, S.button(true, false));
        primary.meta.ownership.meta.test_id = "data.cleanup.confirm";
        const primary_label = try ui.text(cx, "清除并退出", S.text(12, 18, 500));
        try primary.appendChild(cx.allocator, primary_label);
        try actions.appendChild(cx.allocator, primary);
        try modal.body.appendChild(cx.allocator, actions);
        self.* = .{ .cx = cx, .hooks = hooks, .open = open, .disabled = disabled, .busy = busy, .dialog = modal.dialog, .title = title, .headline = headline, .detail = detail, .preserved = preserved, .outcome = outcome, .message = message, .cancel = cancel, .cancel_label = cancel_label, .primary = primary, .primary_label = primary_label, .colors = S.theme.current() };
        try scope.onCleanup(View, self, cleanup);
        try cx.addAfterLayoutHook(self, afterLayout);
        self.retheme();
        return self;
    }
    pub fn showConfirmation(self: *View) !void {
        self.mode = .confirm;
        self.blocked = false;
        self.retryable = false;
        self.busy.set(false);
        self.disabled.set(false);
        try self.title.setTextContent(self.cx.allocator, "清除全部应用数据？");
        try self.headline.setTextContent(self.cx.allocator, "将清除全部应用数据");
        try self.message.setTextContent(self.cx.allocator, "");
        try self.cancel_label.setTextContent(self.cx.allocator, "取消");
        try self.primary_label.setTextContent(self.cx.allocator, "清除并退出");
        if (self.primary.behavior.interaction.a11y) |*a| a.label = "清除全部应用数据并退出";
        if (self.cancel.behavior.interaction.a11y) |*a| a.label = "取消清除并返回设置";
        self.primary.setDisplay(.flex);
        self.open.set(true);
        self.focus_cancel_pending = true;
        self.retheme();
        self.cx.requestRedraw();
    }
    /// Host supplies current whole-application idle state; host must check again at dispatch.
    pub fn setBlocked(self: *View, reason: ?[]const u8) !void {
        self.blocked = reason != null;
        self.disabled.set(self.blocked or self.mode == .working or (self.mode == .failed and !self.retryable));
        if (self.mode == .confirm) try self.message.setTextContent(self.cx.allocator, reason orelse "");
        self.retheme();
        self.cx.requestRedraw();
    }
    pub fn updateWorking(self: *View) !void {
        self.mode = .working;
        self.busy.set(true);
        self.disabled.set(true);
        try self.title.setTextContent(self.cx.allocator, "清除应用数据");
        try self.headline.setTextContent(self.cx.allocator, "正在清除应用数据…");
        try self.message.setTextContent(self.cx.allocator, "请稍候。全部清除成功后，应用将退出。");
        try self.primary_label.setTextContent(self.cx.allocator, "正在清除…");
        self.retheme();
        self.cx.requestRedraw();
    }
    /// Caller passes a concise concrete error. Never presents partial deletion as success.
    pub fn showFailure(self: *View, message: []const u8, retryable: bool) !void {
        self.mode = .failed;
        self.retryable = retryable;
        self.busy.set(false);
        self.disabled.set(self.blocked or !retryable);
        try self.title.setTextContent(self.cx.allocator, "清除应用数据");
        try self.headline.setTextContent(self.cx.allocator, "清除未完成，应用尚未退出");
        try self.message.setTextContent(self.cx.allocator, message);
        try self.cancel_label.setTextContent(self.cx.allocator, "退出应用");
        try self.primary_label.setTextContent(self.cx.allocator, "重试清除");
        if (self.primary.behavior.interaction.a11y) |*a| a.label = "重试清除全部应用数据并退出";
        if (self.cancel.behavior.interaction.a11y) |*a| a.label = "退出应用";
        self.primary.setDisplay(if (retryable) .flex else .none);
        self.open.set(true);
        self.focus_cancel_pending = true;
        self.retheme();
        self.cx.requestRedraw();
    }
    pub fn hide(self: *View) void {
        self.open.set(false);
        self.cx.requestRedraw();
    }
    pub fn dismiss(self: *View) void {
        if (self.mode == .working or !self.open.peek()) return;
        self.open.set(false);
        self.hooks.action(self.hooks.context, .dismiss);
        self.cx.requestRedraw();
    }
    fn activate(self: *View) void {
        if (!self.open.peek() or self.disabled.peek() or self.blocked) return;
        switch (self.mode) {
            .confirm => self.hooks.action(self.hooks.context, .confirm),
            .failed => if (self.retryable) self.hooks.action(self.hooks.context, .retry),
            .working => {},
        }
    }
    fn openChanged(self: *View, open: bool) void {
        if (!open) self.dismiss();
    }
    pub fn retheme(self: *View) void {
        const c = S.theme.current();
        self.dialog.setStyleInline(self.cx.allocator, S.dialog(self.cx.viewport.width));
        self.title.setTextColor(c.fg_1);
        self.headline.setTextColor(if (self.mode == .working) c.fg_1 else S.warning());
        self.detail.setTextColor(c.fg_1);
        self.preserved.setTextColor(c.fg_1);
        self.outcome.setTextColor(c.fg_2);
        self.message.setTextColor(if (self.mode == .failed or self.blocked) S.warning() else c.fg_2);
        self.cancel.setStyleInline(self.cx.allocator, S.button(false, self.busy.peek()));
        self.cancel_label.setTextColor(c.fg_2);
        self.primary.setStyleInline(self.cx.allocator, S.button(true, self.disabled.peek()));
        self.primary_label.setTextColor(ui.Color.WHITE);
        self.colors = c;
    }
    fn afterLayout(raw: *anyopaque, _: u8, _: bool) ui.AfterLayoutResult {
        const self: *View = @ptrCast(@alignCast(raw));
        if (!std.meta.eql(self.colors, S.theme.current())) self.retheme();
        if (self.focus_cancel_pending and self.open.peek()) {
            self.focus_cancel_pending = false;
            self.cx.setFocus(self.cancel);
        }
        return .done;
    }
    fn cleanup(self: *View) void {
        self.cx.removeAfterLayoutHook(self);
        self.cx.allocator.destroy(self);
    }
};
fn text(cx: *ui.Cx, parent: *ui.Node, value: []const u8, size: f32, line: f32, weight: u16, height: f32) !*ui.Node {
    const node = try ui.text(cx, value, S.text(size, line, weight));
    node.setStyleInline(cx.allocator, S.textBox(height));
    try parent.appendChild(cx.allocator, node);
    return node;
}
