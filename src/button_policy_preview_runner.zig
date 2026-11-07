//! Production button/view paint in an isolated window; no credential or IO bootstrap.
const std = @import("std");
const ui = @import("ui");
const App = @import("zenit_app").App;
const theme = @import("ui/app_theme.zig");
const Registry = @import("config/theme_registry.zig").Registry;
const Copy = @import("ui/copy_button.zig").Button;
const Notice = @import("ui/remote_session_notice.zig");
const Recovery = @import("ui/ai_recovery_view.zig");
const Style = @FieldType(ui.widgets.ControlShellConfig, "style");
var application: *App = undefined;

const Fixture = struct {
    cx: *ui.Cx,
    registry: Registry,
    index: usize = 0,
    publication: *@import("ui/shell_styles.zig").ThemePublication,
    title: *ui.Node,
    notice: *Notice.View = undefined,
    copy: *Copy = undefined,
    disabled: *ui.Signal(bool),
    outcome: *ui.Node,
    fn next(self: *Fixture) void {
        self.index = (self.index + 1) % self.registry.records.items.len;
        self.publish();
    }
    fn publish(self: *Fixture) void {
        const record = self.registry.records.items[self.index];
        theme.selectTokens(record.ui_tokens);
        self.publication.publish(self.cx, theme.widgetTheme(theme.currentName()));
        self.title.setTextContent(self.cx.allocator, record.id) catch {};
        self.notice.update(.{ .state = .exited, .exit_code = 0 });
        self.cx.requestRedraw();
    }
    fn toggleDisabled(self: *Fixture) void {
        self.disabled.set(!self.disabled.peek());
    }
    fn copied(self: *Fixture) void {
        self.copy.report(true);
    }
    fn failedCopy(self: *Fixture) void {
        self.copy.report(false);
    }
    fn clicked(self: *Fixture) void {
        self.outcome.setTextContent(self.cx.allocator, "clicked") catch {};
    }
    fn noticeAction(raw: *anyopaque, _: u64) void {
        const self: *Fixture = @ptrCast(@alignCast(raw));
        self.clicked();
    }
    fn recoveryAction(raw: *anyopaque, _: Recovery.Envelope) void {
        const self: *Fixture = @ptrCast(@alignCast(raw));
        self.clicked();
    }
    fn quit(_: *Fixture) void {
        application.quit();
    }
    fn release(self: *Fixture) void {
        self.registry.deinit();
    }
};
fn mount(cx: *ui.Cx, scope: *ui.Scope) !*ui.Node {
    const state = try scope.createState(Fixture, .{
        .cx = cx,
        .registry = try Registry.init(cx.allocator),
        .publication = try cx.bindState(@import("ui/shell_styles.zig").ThemePublication, .{}),
        .title = undefined,
        .disabled = try scope.createSignal(bool, true),
        .outcome = undefined,
    });
    try scope.onCleanup(Fixture, state, Fixture.release);
    theme.selectTokens(state.registry.records.items[0].ui_tokens);
    state.publication.publish(cx, theme.widgetTheme(theme.currentName()));
    const root = try ui.boxStyled(cx, struct {
        fn paint(_: *const ui.ThemeTokens) ui.BoxStyle {
            return .{ .width = .fill(), .height = .fill(), .direction = .column, .padding = .{ .top = 48, .left = 16, .right = 16, .bottom = 16 }, .gap = 12, .background = theme.baseColors().overlay };
        }
    }.paint, .{});
    state.title = try ui.text(cx, "", .{ .font_size = 14 });
    theme.bindInk(state.title, "fg_1");
    state.title.meta.ownership.meta.test_id = "fixture.theme";
    try root.appendChild(cx.allocator, state.title);
    const toolbar = try ui.hstack(cx, .{ .width = .fill(), .gap = 8, .flex_shrink = 0 }, .{});
    try root.appendChild(cx.allocator, toolbar);
    inline for (.{ .{ "下个主题", "fixture.next", Fixture.next }, .{ "切换可用状态", "fixture.disabled", Fixture.toggleDisabled }, .{ "复制成功回执", "fixture.copy-ok", Fixture.copied }, .{ "复制失败回执", "fixture.copy-failed", Fixture.failedCopy }, .{ "退出", "fixture.quit", Fixture.quit } }) |item| {
        const button = try ui.widgets.Button(.{ .label = item[0], .variant = .secondary, .size = .sm, .on_click = cx.on(Fixture, state, item[2]) }).mount(scope, cx);
        button.meta.ownership.meta.test_id = item[1];
        try toolbar.appendChild(cx.allocator, button);
    }
    state.notice = try Notice.View.mount(cx, scope, root, .{ .context = state, .session_id = 1, .reconnect = Fixture.noticeAction, .close = Fixture.noticeAction });
    const row = try ui.hstack(cx, .{ .width = .fill(), .gap = 8, .flex_shrink = 0 }, .{});
    try root.appendChild(cx.allocator, row);
    inline for (.{ .{ "停止执行", "sample.execution", @import("ui/ai_execution_result_styles.zig").action }, .{ "取消传输", "sample.transfer", @import("ui/transfer_styles.zig").v3TextAction }, .{ "查看结果", "sample.notification", @import("ui/notification_history_styles.zig").action } }) |item| {
        const button = try ui.widgets.Button(.{ .label = item[0], .variant = .secondary, .base_style = try theme.paintSignal(Style, cx, scope, item[2], .{}), .on_click = cx.on(Fixture, state, Fixture.clicked) }).mount(scope, cx);
        button.meta.ownership.meta.test_id = item[1];
        try row.appendChild(cx.allocator, button);
    }
    const blocked = try ui.widgets.Button(.{ .label = "暂不可用", .variant = .secondary, .size = .sm, .disabled = state.disabled, .on_click = cx.on(Fixture, state, Fixture.clicked) }).mount(scope, cx);
    blocked.meta.ownership.meta.test_id = "sample.blocked";
    try row.appendChild(cx.allocator, blocked);
    state.copy = try Copy.mount(cx, scope, .{ .variant = .ghost, .icon_only = true, .icon_asset = ui.icons.copy, .a11y_label = "复制", .icon_tint = theme.current().fg_2 });
    state.copy.node.meta.ownership.meta.test_id = "sample.copy";
    try row.appendChild(cx.allocator, state.copy.node);
    const recovery = try Recovery.mount(cx, scope, .{ .ticket = .{ .owner = .{ .session = 1 }, .turn = 1 }, .reason = "保留原始答复，可再次请求", .retries = 0, .max_retries = 3, .retry_enabled = true, .regenerate_enabled = false, .cooldown_seconds = 0, .has_tool_calls = true }, .{ .context = state, .enqueue = Fixture.recoveryAction });
    try root.appendChild(cx.allocator, recovery);
    state.outcome = try ui.text(cx, "idle", .{ .font_size = 12 });
    theme.bindInk(state.outcome, "fg_2");
    state.outcome.meta.ownership.meta.test_id = "fixture.outcome";
    try root.appendChild(cx.allocator, state.outcome);
    state.publish();
    return root;
}
pub fn main(init: std.process.Init) !void {
    application = try App.init(std.heap.c_allocator, .{ .io = init.io, .window = .{ .width = 1100, .height = 600, .min_width = 600, .min_height = 400, .title = "ZeroWork Button Policy Acceptance", .titlebar = .custom_inset, .titlebar_height = 40 } });
    defer application.deinit();
    try application.runWith(mount);
}
