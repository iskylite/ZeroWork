const std = @import("std");
const ui = @import("ui");
const theme = @import("ui/app_theme.zig");
const cleanup_view = @import("ui/application_data_cleanup_view.zig");
const publication = @import("ui/shell_styles.zig").ThemePublication;

const Receipt = struct {
    calls: usize = 0,
    action: ?cleanup_view.Action = null,
    fn handle(raw: *anyopaque, action: cleanup_view.Action) void {
        const self: *Receipt = @ptrCast(@alignCast(raw));
        self.calls += 1;
        self.action = action;
    }
};
const Fixture = struct {
    cx: *ui.Cx,
    scope: *ui.Scope,
    publish: *publication,
    fn init() !Fixture {
        const cx = try ui.Cx.init(std.testing.allocator, std.testing.io);
        errdefer cx.deinit();
        cx.setViewport(1000, 700);
        const scope = try ui.Scope.init(std.testing.allocator, null, cx.owner);
        errdefer scope.dispose();
        cx.root = try ui.box(cx, .{ .width = .fill(), .height = .fill() }, .{});
        const publish = try cx.bindState(publication, .{});
        publish.publish(cx, theme.widgetTheme(theme.currentName()));
        return .{ .cx = cx, .scope = scope, .publish = publish };
    }
    fn deinit(self: Fixture) void {
        self.scope.dispose();
        self.cx.deinit();
    }
    fn frame(self: Fixture) void {
        // Allow the existing Button/Modal paint transitions to settle.
        for (0..24) |_| {
            self.cx.frame_count += 1;
            self.cx.frame_time_ms += 16;
            _ = self.cx.render();
        }
    }
    fn apply(self: Fixture, name: theme.Name, material: bool) void {
        theme.select(name);
        _ = theme.setMaterialVisible(material);
        self.publish.publish(self.cx, theme.widgetTheme(name));
        self.frame();
    }
    fn click(self: Fixture, node: *ui.Node) void {
        const r = node.globalRect();
        self.cx.handleMouseDown(r.x + r.w / 2, r.y + r.h / 2, .{});
        self.cx.handleMouseUp(r.x + r.w / 2, r.y + r.h / 2);
        self.frame();
    }
};

test "application data cleanup opening cancel and Escape never confirms and restores focus" {
    const f = try Fixture.init();
    defer f.deinit();
    var receipt: Receipt = .{};
    const outside = try ui.widgets.Button(.{ .label = "清除全部应用数据" }).mount(f.scope, f.cx);
    try f.cx.root.?.appendChild(f.cx.allocator, outside);
    const view = try cleanup_view.View.mount(f.cx, f.scope, .{ .context = &receipt, .action = Receipt.handle });
    f.frame();
    f.cx.setFocus(outside);
    try view.showConfirmation();
    f.frame();
    try std.testing.expectEqual(@as(f32, 520), view.dialog.globalRect().w);
    try std.testing.expectEqual(@as(f32, 300), view.dialog.globalRect().h);
    try std.testing.expectEqual(@as(f32, 96), view.primary.globalRect().w);
    try std.testing.expect(f.cx.focus_manager.getFocused() == view.cancel);
    try std.testing.expectEqual(@as(usize, 0), receipt.calls);
    f.cx.handleKeyDown(.escape, .{});
    f.frame();
    try std.testing.expect(!view.open.peek());
    try std.testing.expectEqual(cleanup_view.Action.dismiss, receipt.action.?);
    try std.testing.expect(f.cx.focus_manager.getFocused() == outside);
    try view.showConfirmation();
    f.frame();
    f.click(view.cancel);
    try std.testing.expectEqual(@as(usize, 2), receipt.calls);
    try std.testing.expectEqual(cleanup_view.Action.dismiss, receipt.action.?);
    try std.testing.expect(f.cx.focus_manager.getFocused() == outside);
}

test "application data cleanup rechecks blocked working and retryable failure through real Buttons" {
    const f = try Fixture.init();
    defer f.deinit();
    var receipt: Receipt = .{};
    const view = try cleanup_view.View.mount(f.cx, f.scope, .{ .context = &receipt, .action = Receipt.handle });
    try view.showConfirmation();
    try view.setBlocked("请先结束所有窗口中的活动任务。");
    f.frame();
    try std.testing.expect(view.primary.behavior.interaction.a11y.?.disabled);
    f.click(view.primary);
    try std.testing.expectEqual(@as(usize, 0), receipt.calls);
    try view.setBlocked(null);
    f.frame();
    f.click(view.primary);
    try std.testing.expectEqual(cleanup_view.Action.confirm, receipt.action.?);
    try std.testing.expectEqual(@as(usize, 1), receipt.calls);
    try view.updateWorking();
    f.frame();
    f.click(view.primary);
    f.click(view.cancel);
    f.cx.handleKeyDown(.escape, .{});
    f.frame();
    try std.testing.expect(view.open.peek());
    try std.testing.expectEqual(@as(usize, 1), receipt.calls);
    try view.showFailure("钥匙串拒绝访问，部分数据尚未清除。授权后可重试。", true);
    f.frame();
    try std.testing.expectEqual(cleanup_view.Mode.failed, view.mode);
    try std.testing.expectEqualStrings("退出应用", view.cancel_label.getText().?.content);
    try std.testing.expectEqualStrings("退出应用", view.cancel.behavior.interaction.a11y.?.label.?);
    try std.testing.expect(view.open.peek());
    try std.testing.expectEqualStrings("清除未完成，应用尚未退出", view.headline.getText().?.content);
    f.click(view.primary);
    try std.testing.expectEqual(cleanup_view.Action.retry, receipt.action.?);
    try std.testing.expectEqual(@as(usize, 2), receipt.calls);
    try view.showFailure("目录验证失败。未继续删除，请重新启动应用。", false);
    f.frame();
    try std.testing.expect(view.primary.style.display == .none);
    view.dismiss();
    try std.testing.expectEqual(cleanup_view.Action.dismiss, receipt.action.?);
}

test "application data cleanup three themes fit the minimum window without changing owner state" {
    const previous = theme.currentName();
    const material = theme.materialVisible();
    defer {
        theme.select(previous);
        _ = theme.setMaterialVisible(material);
    }
    const f = try Fixture.init();
    defer f.deinit();
    f.cx.setViewport(640, 480);
    var receipt: Receipt = .{};
    const view = try cleanup_view.View.mount(f.cx, f.scope, .{ .context = &receipt, .action = Receipt.handle });
    try view.showConfirmation();
    for ([_]theme.Name{ .dark, .light, .sauber }) |name| {
        f.apply(name, false);
        const r = view.dialog.globalRect();
        try std.testing.expect(r.x >= 0 and r.y >= 0 and r.x + r.w <= 640 and r.y + r.h <= 480);
        try std.testing.expectEqual(theme.current().overlay, view.dialog.getBackground());
        try std.testing.expectEqual(theme.current().fg_1, view.detail.getText().?.color);
        try std.testing.expectEqualStrings(cleanup_view.scope_text, view.detail.getText().?.content);
        try std.testing.expectEqualStrings(cleanup_view.preserved_text, view.preserved.getText().?.content);
        try std.testing.expectEqual(@as(usize, 0), receipt.calls);
        const b = view.primary.globalRect();
        try std.testing.expect(b.y + b.h <= r.y + r.h);
        try std.testing.expect(f.cx.focus_manager.getFocused() == view.cancel);
    }
}
