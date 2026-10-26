const std = @import("std");
const ui = @import("ui");
const styles = @import("record_cleanup_styles.zig");
const theme = @import("app_theme.zig");
const Progress = @import("../host/record_cleanup.zig").Progress;
pub const Action = enum { confirm, retry, dismiss };
pub const Hooks = struct { context: *anyopaque, action: *const fn (*anyopaque, Action) void };
pub const Mode = enum { confirm, running, failed, cleared };

pub const View = struct {
    cx: *ui.Cx,
    hooks: Hooks,
    open: *ui.Signal(bool),
    dialog: *ui.Node,
    content_stack: *ui.Node,
    title: *ui.Node,
    title_icon: *ui.Node,
    headline: *ui.Node,
    detail: *ui.Node,
    receipt: *ui.Node,
    close: *ui.Node,
    close_icon: *ui.Node,
    cancel: *ui.Node,
    cancel_label: *ui.Node,
    primary: *ui.Node,
    primary_label: *ui.Node,
    mode: Mode = .confirm,
    colors: theme.Colors,
    close_style: *ui.Signal(ui.BoxStyle),
    cancel_style: *ui.Signal(ui.BoxStyle),
    primary_style: *ui.Signal(ui.BoxStyle),
    focus_cancel_pending: bool = false,

    pub fn mount(cx: *ui.Cx, scope: *ui.Scope, hooks: Hooks) !*View {
        const self = try cx.allocator.create(View);
        errdefer cx.allocator.destroy(self);
        const open = try scope.createSignal(bool, false);
        const close_style = try scope.createSignal(ui.BoxStyle, styles.close());
        const cancel_style = try scope.createSignal(ui.BoxStyle, styles.button(false, false));
        const primary_style = try scope.createSignal(ui.BoxStyle, styles.button(true, true));
        const modal = try ui.widgets.Modal(.{ .open = open, .width = 440, .max_height = 208, .background = theme.current().overlay, .close_on_overlay = false, .on_open_change = cx.on(View, self, changed) }).mount(scope, cx);
        if (!modal.portaled) if (cx.root) |root| try root.appendChild(cx.allocator, modal.overlay);
        modal.dialog.setStyleInline(cx.allocator, styles.dialog(false));
        modal.dialog.meta.ownership.meta.test_id = "settings.record-cleanup";
        if (modal.dialog.behavior.interaction.a11y) |*a11y| a11y.label = "会话记录清理";
        modal.body.setStyleInline(cx.allocator, styles.body());
        const header = try ui.box(cx, styles.row(28), .{});
        const icon = try ui.iconTint(cx, ui.icons.triangle_alert, styles.warning(), .{ .width = .{ .px = 18 }, .height = .{ .px = 18 }, .flex_shrink = 0 });
        try header.appendChild(cx.allocator, icon);
        const title = try ui.text(cx, "清空会话记录？", styles.text(13, 20, 700));
        try header.appendChild(cx.allocator, title);
        try header.appendChild(cx.allocator, try ui.spacer(cx));
        const close = try ui.widgets.Button(.{ .variant = .ghost, .icon_only = true, .a11y_label = "返回设置", .base_style = close_style, .on_click = cx.on(View, self, dismiss) }).mount(scope, cx);
        close.setStyleInline(cx.allocator, styles.close());
        close.meta.ownership.meta.test_id = "settings.record-cleanup.close";
        const close_icon = try ui.iconTint(cx, ui.icons.x, theme.current().fg_2, .{ .width = .{ .px = 14 }, .height = .{ .px = 14 } });
        try close.appendChild(cx.allocator, close_icon);
        try header.appendChild(cx.allocator, close);
        try modal.body.appendChild(cx.allocator, header);
        const stack = try ui.box(cx, styles.stack(false), .{});
        const headline = try ui.text(cx, "", styles.text(14, 22, 700));
        headline.setStyleInline(cx.allocator, styles.textBox(22));
        headline.meta.ownership.meta.test_id = "settings.record-cleanup.headline";
        try stack.appendChild(cx.allocator, headline);
        const detail = try ui.text(cx, "", styles.text(11.5, 18, 400));
        detail.setStyleInline(cx.allocator, styles.textBox(18));
        detail.meta.ownership.meta.test_id = "settings.record-cleanup.detail";
        try stack.appendChild(cx.allocator, detail);
        const receipt = try ui.text(cx, "", styles.text(10.5, 16, 400));
        receipt.setStyleInline(cx.allocator, styles.textBox(16));
        receipt.setStyle(cx.allocator, .margin, .{ .top = 6 });
        receipt.meta.ownership.meta.test_id = "settings.record-cleanup.receipt";
        receipt.behavior.interaction.a11y = .{ .role = .status, .live = "polite" };
        try stack.appendChild(cx.allocator, receipt);
        try modal.body.appendChild(cx.allocator, stack);
        // Header y17, content y56, actions y160, exactly as the Bridge panel.
        const actions = try ui.box(cx, styles.row(34), .{});
        const cancel = try ui.widgets.Button(.{ .variant = .secondary, .a11y_label = "取消清理并返回设置", .base_style = cancel_style, .on_click = cx.on(View, self, dismiss) }).mount(scope, cx);
        cancel.setStyleInline(cx.allocator, styles.button(false, false));
        cancel.meta.ownership.meta.test_id = "settings.record-cleanup.cancel";
        const cancel_label = try ui.text(cx, "取消", styles.text(12, 18, 500));
        try cancel.appendChild(cx.allocator, cancel_label);
        try actions.appendChild(cx.allocator, cancel);
        try actions.appendChild(cx.allocator, try ui.spacer(cx));
        const primary = try ui.widgets.Button(.{ .variant = .danger, .a11y_label = "清空已结束会话记录", .base_style = primary_style, .on_click = cx.on(View, self, activate) }).mount(scope, cx);
        primary.setStyleInline(cx.allocator, styles.button(true, true));
        primary.meta.ownership.meta.test_id = "settings.record-cleanup.confirm";
        const primary_label = try ui.text(cx, "清空", styles.text(12, 18, 500));
        try primary.appendChild(cx.allocator, primary_label);
        try actions.appendChild(cx.allocator, primary);
        try modal.body.appendChild(cx.allocator, actions);
        self.* = .{ .cx = cx, .hooks = hooks, .open = open, .dialog = modal.dialog, .content_stack = stack, .title = title, .title_icon = icon, .headline = headline, .detail = detail, .receipt = receipt, .close = close, .close_icon = close_icon, .cancel = cancel, .cancel_label = cancel_label, .primary = primary, .primary_label = primary_label, .colors = theme.current(), .close_style = close_style, .cancel_style = cancel_style, .primary_style = primary_style };
        try scope.onCleanup(View, self, cleanup);
        try cx.addAfterLayoutHook(self, afterLayout);
        return self;
    }
    pub fn showConfirmation(self: *View) !void {
        self.mode = .confirm;
        try self.title.setTextContent(self.cx.allocator, "清空会话记录？");
        try self.headline.setTextContent(self.cx.allocator, "将删除所有已结束会话的输出与快照。");
        try self.detail.setTextContent(self.cx.allocator, "不可撤销。主机、设置草稿与诊断日志保留。");
        try self.receipt.setTextContent(self.cx.allocator, "");
        try self.cancel_label.setTextContent(self.cx.allocator, "取消");
        try self.primary_label.setTextContent(self.cx.allocator, "清空");
        if (self.primary.behavior.interaction.a11y) |*a11y| a11y.label = "清空已结束会话记录";
        self.primary.setDisplay(.flex);
        self.retheme();
        self.open.set(true);
        self.focus_cancel_pending = true;
        self.cx.requestRedraw();
    }
    pub fn update(self: *View, progress: Progress, failure: ?anyerror, index_missing: bool) !void {
        self.mode = if (!progress.done()) .running else if (progress.failed != 0) .failed else .cleared;
        try self.title.setTextContent(self.cx.allocator, "会话记录清理");
        var headline: [192]u8 = undefined;
        const value = switch (self.mode) {
            .confirm => unreachable,
            .running => "正在清理会话记录…",
            .failed => try std.fmt.bufPrint(&headline, "{s} · {s}", .{ if (index_missing) "文件缺失，索引提交失败" else "部分记录未清理", @errorName(failure orelse error.RecordCleanupFailed) }),
            .cleared => if (progress.total == 0) "暂无可清理的会话记录" else "会话记录已清空",
        };
        try self.headline.setTextContent(self.cx.allocator, value);
        try self.detail.setTextContent(self.cx.allocator, if (self.mode == .failed) failureDetail(failure) else if (self.mode == .running) "正在处理本次确认的记录。" else "主机、设置与应用诊断日志保留。");
        var receipt: [128]u8 = undefined;
        try self.receipt.setTextContent(self.cx.allocator, try std.fmt.bufPrint(&receipt, "已清理 {d} 项 · 失败 {d} 项{s}", .{ progress.deleted, progress.failed, if (progress.pending == 0) "" else " · 处理中" }));
        try self.cancel_label.setTextContent(self.cx.allocator, "返回");
        try self.primary_label.setTextContent(self.cx.allocator, if (self.mode == .failed) "重试失败项" else "完成");
        if (self.primary.behavior.interaction.a11y) |*a11y| a11y.label = if (self.mode == .failed) "仅重试本次清理失败的记录" else "完成并返回设置";
        self.primary.setDisplay(if (self.mode == .running) .none else .flex);
        self.retheme();
        self.cx.requestRedraw();
    }
    pub fn showResult(self: *View) void {
        self.open.set(true);
        self.focus_cancel_pending = true;
        self.cx.requestRedraw();
    }
    pub fn showProblem(self: *View, err: anyerror) void {
        self.mode = .failed;
        self.title.setTextContent(self.cx.allocator, "会话记录清理") catch {};
        var buffer: [192]u8 = undefined;
        self.headline.setTextContent(self.cx.allocator, std.fmt.bufPrint(&buffer, "无法开始清理 · {s}", .{@errorName(err)}) catch "无法开始清理") catch {};
        self.detail.setTextContent(self.cx.allocator, failureDetail(err)) catch {};
        self.receipt.setTextContent(self.cx.allocator, "") catch {};
        self.cancel_label.setTextContent(self.cx.allocator, "返回") catch {};
        self.primary_label.setTextContent(self.cx.allocator, "重试") catch {};
        self.primary.setDisplay(.flex);
        self.retheme();
        self.cx.requestRedraw();
    }
    pub fn hide(self: *View) void {
        self.open.set(false);
    }
    pub fn dismiss(self: *View) void {
        self.open.set(false);
        self.hooks.action(self.hooks.context, .dismiss);
        self.cx.requestRedraw();
    }
    fn activate(self: *View) void {
        switch (self.mode) {
            .confirm => self.hooks.action(self.hooks.context, .confirm),
            .failed => self.hooks.action(self.hooks.context, .retry),
            .cleared => self.dismiss(),
            .running => {},
        }
    }
    fn changed(self: *View, open: bool) void {
        if (!open) self.dismiss();
    }
    pub fn retheme(self: *View) void {
        const c = theme.current();
        const has_receipt = if (self.receipt.getText()) |value| value.content.len != 0 else false;
        self.receipt.setDisplay(if (has_receipt) .flex else .none);
        self.content_stack.setStyleInline(self.cx.allocator, styles.stack(has_receipt));
        self.dialog.setStyleInline(self.cx.allocator, styles.dialog(has_receipt));
        self.title.setTextColor(c.fg_1);
        self.headline.setTextColor(if (self.mode == .confirm or self.mode == .failed) styles.warning() else if (self.mode == .cleared) c.ok_ink else c.fg_1);
        self.detail.setTextColor(c.fg_1);
        self.receipt.setTextColor(c.fg_2);
        self.close_style.set(styles.close());
        self.cancel_style.set(styles.button(false, false));
        self.cancel_label.setTextColor(c.fg_2);
        self.primary_style.set(styles.button(true, self.mode == .confirm));
        self.primary_label.setTextColor(if (self.mode == .confirm) ui.Color.WHITE else c.accent_ink);
        _ = self.title_icon.setTint(if (self.mode == .confirm or self.mode == .failed) styles.warning() else c.accent);
        _ = self.close_icon.setTint(c.fg_2);
        self.colors = c;
    }
    fn afterLayout(raw: *anyopaque, _: u8, _: bool) ui.AfterLayoutResult {
        const self: *View = @ptrCast(@alignCast(raw));
        if (!std.meta.eql(self.colors, theme.current())) self.retheme();
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
fn failureDetail(failure: ?anyerror) []const u8 {
    const err = failure orelse return "未完成的记录保留，可重试失败项。";
    return switch (err) {
        error.RecordBusy => "记录正被读取，请关闭预览或等待导出结束后重试。",
        error.LiveSessionActive => "请先结束活动会话。",
        error.AccessDenied => "未删除的记录保留；检查目录权限后重试。",
        error.RecordingChanged => "记录内容已变化；本次不会删除被替换的文件。",
        else => "未完成的记录保留，可重试失败项。",
    };
}
