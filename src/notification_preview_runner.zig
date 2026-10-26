//! Isolated production notification presenter acceptance. Explicit local facts
//! exercise presentation only; no SSH, transfer, LLM or OS delivery is claimed.
const std = @import("std");
const ui = @import("ui");
const App = @import("zenit_app").App;
const theme = @import("ui/app_theme.zig");
const host = @import("host/notification_host.zig");
const presenter = @import("ui/notification_presenter.zig");
const owner: host.ContentOwner = .{ .session = .{ .session_id = @fromBackingInt(1), .generation = 1 } };
const Fixture = struct {
    cx: *ui.Cx,
    root: *ui.Node,
    notice_host: host.Host,
    view: *presenter.Presenter = undefined,
    obstacle: *ui.Node,
    result: *ui.Node,
    operation: u64 = 0,
    covered: bool = false,
    local_anchor: ?*ui.Node = null,
    fn publish(self: *Fixture, is_error: bool, has_action: bool) void {
        self.operation += 1;
        const action_id = self.notice_host.registerAction(owner, .view_result, .{ .context = self, .invoke = action }) catch return;
        _ = self.notice_host.coordinator.publishNotification(.{ .definition_id = "fixture.feedback", .owner = .{ .window_id = 1, .content = owner }, .operation_id = self.operation, .event_revision = 1, .phase = if (is_error) .failed else .succeeded, .severity = if (is_error) .failure else .info, .title = if (is_error) "验证错误" else if (has_action) "有结果可查看" else "普通消息", .detail = "仅验证原生展示，未执行远程操作", .actions = if (has_action) &.{.{ .kind = .view_result, .action_id = action_id, .label = "查看" }} else &.{} }, host.localClock() catch return) catch return;
        self.cx.requestRedraw();
    }
    fn long(self: *Fixture) void {
        self.operation += 1;
        var detail: [4000]u8 = undefined;
        const word = "Long notification content for native scroll verification. ";
        for (&detail, 0..) |*byte, index| byte.* = word[index % word.len];
        const action_id = self.notice_host.registerAction(owner, .view_result, .{ .context = self, .invoke = action }) catch return;
        const label = "View the complete retained operation result with its original owner and verification details";
        _ = self.notice_host.coordinator.publishNotification(.{ .definition_id = "fixture.feedback", .owner = .{ .window_id = 1, .content = owner }, .operation_id = self.operation, .event_revision = 1, .phase = .failed, .severity = .failure, .title = "Long persistent notification", .detail = &detail, .actions = &.{ .{ .kind = .view_result, .action_id = action_id, .label = label }, .{ .kind = .view_result, .action_id = action_id, .label = label }, .{ .kind = .view_result, .action_id = action_id, .label = label } } }, host.localClock() catch return) catch return;
        self.cx.requestRedraw();
    }
    fn normal(self: *Fixture) void {
        self.publish(false, false);
    }
    fn actionable(self: *Fixture) void {
        self.publish(false, true);
    }
    fn failure(self: *Fixture) void {
        self.publish(true, false);
    }
    fn action(raw: *anyopaque, _: host.notifications.NotificationEvent) !void {
        const self: *Fixture = @ptrCast(@alignCast(raw));
        try self.result.setTextContent(self.cx.allocator, "已打开结果");
        self.cx.requestRedraw();
    }
    fn local(self: *Fixture) void {
        const node = self.local_anchor orelse return;
        presenter.acknowledgeAt(self.cx, node.globalRect(), "已确认") catch {};
    }
    fn toggle(self: *Fixture) void {
        self.covered = !self.covered;
        self.obstacle.setDisplay(if (self.covered) .flex else .none);
        self.cx.requestRedraw();
    }
    fn frame(raw: *anyopaque, _: u8, _: bool) ui.AfterLayoutResult {
        const self: *Fixture = @ptrCast(@alignCast(raw));
        const rect = self.obstacle.globalRect();
        self.view.update((host.localClock() catch return .done).monotonic_ms, true, owner, .{ .content = self.root.globalRect(), .avoid = if (self.covered) &.{rect} else &.{} }) catch {};
        return .done;
    }
    fn cleanup(self: *Fixture) void {
        self.notice_host.coordinator.deinit();
        self.notice_host.actions.deinit(self.cx.allocator);
    }
};
fn mount(cx: *ui.Cx, scope: *ui.Scope) !*ui.Node {
    theme.select(.dark);
    _ = theme.setMaterialParameters(0, 0);
    cx.setTheme(theme.widgetTheme(.dark));
    const root = try ui.box(cx, .{ .width = .fill(), .height = .fill(), .background = theme.baseColors().app, .padding = ui.Padding.all(24), .direction = .column, .gap = 12 }, .{});
    const obstacle = try ui.box(cx, .{ .position = .absolute, .inset = .{ .right = .{ .px = 8 }, .top = .{ .px = 52 } }, .width = .{ .px = 420 }, .height = .{ .px = 240 }, .background = theme.current().surface_2, .border = .{ .width = 1, .color = theme.current().border, .radius = 12 } }, .{});
    obstacle.meta.ownership.meta.test_id = "fixture.obstacle";
    obstacle.setDisplay(.none);
    try root.appendChild(cx.allocator, obstacle);
    const result = try ui.text(cx, "尚未查看结果", .{ .font_size = 12, .color = theme.current().fg_1 });
    result.meta.ownership.meta.test_id = "fixture.result";
    const self = try scope.createState(Fixture, .{ .cx = cx, .root = root, .notice_host = .{ .allocator = cx.allocator, .driver = undefined, .coordinator = try host.notifications.Coordinator.init(cx.allocator, .{}, .{}) }, .obstacle = obstacle, .result = result });
    try scope.onCleanup(Fixture, self, Fixture.cleanup);
    try self.notice_host.coordinator.registerDefinition(.{ .id = "fixture.feedback", .category = .operation_result, .default_channels = .{ .system = false, .attention = false } });
    self.view = try presenter.Presenter.mount(cx, scope, &self.notice_host, @fromBackingInt(1));
    const row = try ui.box(cx, .{ .direction = .row, .gap = 12 }, .{});
    const Spec = struct { label: []const u8, id: []const u8, callback: *const fn (*Fixture) void };
    inline for ([_]Spec{ .{ .label = "长消息", .id = "fixture.long", .callback = Fixture.long }, .{ .label = "普通消息", .id = "fixture.normal", .callback = Fixture.normal }, .{ .label = "带查看动作", .id = "fixture.action", .callback = Fixture.actionable }, .{ .label = "错误消息", .id = "fixture.error", .callback = Fixture.failure }, .{ .label = "切换遮挡", .id = "fixture.cover", .callback = Fixture.toggle }, .{ .label = "就地确认", .id = "fixture.local", .callback = Fixture.local } }) |spec| {
        const button = try ui.widgets.Button(.{ .label = spec.label, .on_click = cx.on(Fixture, self, spec.callback) }).mount(scope, cx);
        button.meta.ownership.meta.test_id = spec.id;
        if (comptime std.mem.eql(u8, spec.id, "fixture.local")) self.local_anchor = button;
        try row.appendChild(cx.allocator, button);
    }
    try root.appendChild(cx.allocator, row);
    try root.appendChild(cx.allocator, result);
    try cx.addAfterLayoutHook(self, Fixture.frame);
    return root;
}
pub fn main(init: std.process.Init) !void {
    const app = try App.init(std.heap.c_allocator, .{ .io = init.io, .window = .{ .width = 1440, .height = 900, .min_width = 860, .min_height = 480, .title = "ZeroWork · Notification acceptance fixture", .titlebar = .custom_inset, .titlebar_height = 40 } });
    defer app.deinit();
    try app.runWith(mount);
}
