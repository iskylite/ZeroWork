//! Isolated production notification presenter acceptance. Explicit local facts
//! exercise presentation only; no SSH, transfer, LLM or OS delivery is claimed.
const std = @import("std");
const ui = @import("ui");
const App = @import("zenit_app").App;
const theme = @import("ui/app_theme.zig");
const host = @import("host/notification_host.zig");
const CommandHint = @import("ui/command_error_hint_view.zig").View;
const vt = @import("vt/snapshot.zig");
const presenter = @import("ui/notification_presenter.zig");
const owner: host.ContentOwner = .{ .session = .{ .session_id = @fromBackingInt(1), .generation = 1 } };
const Fixture = struct {
    cx: *ui.Cx,
    root: *ui.Node,
    notice_host: host.Host,
    view: *presenter.Presenter = undefined,
    history: ?*@import("ui/notification_history.zig").View = null,
    obstacle: *ui.Node,
    result: *ui.Node,
    operation: u64 = 0,
    covered: bool = false,
    local_anchor: ?*ui.Node = null,
    command_hint: ?*CommandHint = null,
    fn owns(_: *anyopaque, _: host.notifications.Target) bool {
        return true;
    }
    fn activate(raw: *anyopaque, target: host.notifications.Target) bool {
        const self: *Fixture = @ptrCast(@alignCast(raw));
        self.result.setTextContent(self.cx.allocator, switch (target.kind) {
            .transfer_done => "已定位传输任务",
            .reconnect => "已定位 SSH 连接",
            .ai_ready => "已定位 AI 对话",
        }) catch return false;
        self.cx.requestRedraw();
        return true;
    }
    fn feedback(_: *anyopaque, _: []const u8) void {}
    fn ownerName(_: *anyopaque, value: host.ContentOwner) []const u8 {
        return if (value == .session and @backingInt(value.session.session_id) == 2) "prod-api-02" else "prod-web-01";
    }
    fn scenes(self: *Fixture) void {
        self.operation += 10;
        self.notice_host.publishTransfer(owner, self.operation, 1, .{ .result = .failed, .resources_released = true, .notify_complete = false, .details = .{ .object = "backup-2026-10-27.tar.gz", .detail = "没有文件访问权限" } }) catch return;
        self.notice_host.publishReconnectDetails(.{ .session = .{ .session_id = @fromBackingInt(2), .generation = 1 } }, self.operation + 1, 1, .disconnected, .{ .object = "prod-api-02", .detail = "连接超时，远端未响应。" }) catch return;
        self.notice_host.publishAi(owner, self.operation + 2, 1, .{ .result = .unverified, .resources_released = true }) catch return;
        self.cx.requestRedraw();
    }
    fn outcomes(self: *Fixture) void {
        for (self.view.slots) |slot| if (slot.fact_id) |id| self.notice_host.coordinator.dismissNotification(id);
        self.operation += 10;
        self.notice_host.publishTransfer(owner, self.operation, 1, .{ .result = .cancelled, .resources_released = true, .notify_complete = false, .details = .{ .object = "archive.tar.gz" } }) catch return;
        self.notice_host.publishReconnectDetails(.{ .session = .{ .session_id = @fromBackingInt(2), .generation = 1 } }, self.operation + 1, 2, .recovered, .{ .object = "prod-api-02" }) catch return;
        self.notice_host.publishAi(owner, self.operation + 2, 1, .{ .result = .succeeded, .resources_released = true, .final_answer = true }) catch return;
        self.cx.requestRedraw();
    }
    fn publish(self: *Fixture, is_error: bool, has_action: bool) void {
        self.operation += 1;
        const action_id = self.notice_host.registerAction(owner, .view_result, .{ .context = self, .invoke = action }) catch return;
        _ = self.notice_host.coordinator.publishNotification(.{ .definition_id = "fixture.feedback", .owner = .{ .window_id = 1, .content = owner }, .operation_id = self.operation, .event_revision = 1, .phase = if (is_error) .failed else .succeeded, .severity = if (is_error) .failure else .info, .owner_name = "prod-web-01", .title = if (is_error) "验证错误" else if (has_action) "有结果可查看" else "普通消息", .detail = "仅验证原生展示，未执行远程操作", .actions = if (has_action) &.{.{ .kind = .view_result, .action_id = action_id, .label = "查看" }} else &.{} }, host.localClock() catch return) catch return;
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
    fn connectionFailure(self: *Fixture) void {
        self.operation += 1;
        const ended_owner: host.ContentOwner = .{ .session = .{ .session_id = @fromBackingInt(99), .generation = 1 } };
        _ = self.notice_host.coordinator.publishNotification(.{ .definition_id = "fixture.feedback", .owner = .{ .window_id = 1, .content = ended_owner }, .owner_name = "ScaleX40-AI01", .operation_id = self.operation, .event_revision = 1, .phase = .failed, .severity = .failure, .title = "连接失败: HandshakeFailed" }, host.localClock() catch return) catch return;
        self.notice_host.coordinator.ownerEnded(ended_owner);
        self.cx.requestRedraw();
    }
    fn action(raw: *anyopaque, _: host.notifications.NotificationEvent) !void {
        const self: *Fixture = @ptrCast(@alignCast(raw));
        try self.result.setTextContent(self.cx.allocator, "已打开结果");
        self.cx.requestRedraw();
    }
    fn commandOpened(raw: ?*anyopaque, _: @import("ai/command_error_hint.zig").Hint) !void {
        const self: *Fixture = @ptrCast(@alignCast(raw.?));
        try self.result.setTextContent(self.cx.allocator, "已打开命令分析");
    }
    fn commandHint(self: *Fixture) void {
        if (self.command_hint == null) self.command_hint = CommandHint.create(self.cx, self.root) catch return;
        const hint = self.command_hint.?;
        hint.configure(owner.session, true, .{ .context = self, .on_open = commandOpened });
        hint.resetFacts();
        hint.model.primeSequence(owner.session, 0) catch return;
        const command = "cat /tmp/zerowork-missing.conf";
        const output = "cat: /tmp/zerowork-missing.conf: No such file or directory";
        const bytes = command ++ output;
        var cells: [bytes.len]vt.Cell = undefined;
        for (&cells, 0..) |*cell, index| cell.* = .{ .grapheme_start = @intCast(index), .grapheme_len = 1, .semantic = if (index < command.len) 1 else 0 };
        const rows = [_]vt.Row{
            .{ .id = .{ 0, 0 }, .viewport_y = 0, .cell_start = 0, .cell_count = command.len, .wraps = false, .continuation = false, .logical_start_id = null, .dirty = true, .semantic_prompt = 1 },
            .{ .id = .{ 0, 1 }, .viewport_y = 1, .cell_start = command.len, .cell_count = output.len, .wraps = false, .continuation = false, .logical_start_id = null, .dirty = true, .semantic_prompt = 0 },
        };
        const events = [_]vt.Event{ .{ .sequence = 1, .kind = .output_start, .text = command }, .{ .sequence = 2, .kind = .command_end, .text = "", .exit_code = 1 } };
        const projection: vt.Projection = .{ .version = 1, .style_version = 1, .mode_revision = 1, .modes = .{}, .colors = .{ .foreground = 0xffffff, .background = 0, .cursor = null, .palette = @splat(0) }, .cursor = .{}, .active_cursor = .{}, .cols = 80, .rows = 2, .visible_rows = &rows, .cells = &cells, .graphemes = bytes, .scrollback = .{}, .events = &events };
        hint.observe(owner.session, &projection) catch return;
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
        var avoid: [2]ui.ComputedRect = undefined;
        var count: usize = 0;
        if (self.covered) {
            avoid[count] = self.obstacle.globalRect();
            count += 1;
        }
        // Match the application's host: an open notification list is an
        // overlay obstacle, including for persistent failure toasts.
        if (self.history) |history| if (history.open.peek()) {
            avoid[count] = history.root.globalRect();
            count += 1;
        };
        self.view.update((host.localClock() catch return .done).monotonic_ms, true, owner, .{ .content = self.root.globalRect(), .avoid = avoid[0..count] }) catch {};
        return .done;
    }
    fn cleanup(self: *Fixture) void {
        if (self.command_hint) |hint| hint.destroy();
        self.notice_host.coordinator.deinit();
        self.notice_host.actions.deinit(self.cx.allocator);
        self.notice_host.windows.deinit(self.cx.allocator);
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
    _ = try self.notice_host.registerWindow(.{ .context = self, .owns = Fixture.owns, .activate = Fixture.activate, .feedback = Fixture.feedback, .owner_name = Fixture.ownerName });
    self.view = try presenter.Presenter.mount(cx, scope, &self.notice_host, @fromBackingInt(1));
    const bell = try ui.widgets.Button(.{ .icon_only = true, .icon_asset = ui.icons.bell, .a11y_label = "通知", .variant = .ghost }).mount(scope, cx);
    bell.setStyleInline(cx.allocator, .{ .position = .absolute, .inset = .{ .right = .{ .px = 12 }, .top = .{ .px = 6 } }, .width = .{ .px = 30 }, .height = .{ .px = 28 } });
    bell.meta.ownership.meta.test_id = "toolbar.notifications";
    try root.appendChild(cx.allocator, bell);
    self.history = try @import("ui/notification_history.zig").View.mount(cx, scope, &self.notice_host, bell);
    const row = try ui.box(cx, .{ .direction = .row, .gap = 12 }, .{});
    const Spec = struct { label: []const u8, id: []const u8, callback: *const fn (*Fixture) void };
    inline for ([_]Spec{ .{ .label = "命令失败", .id = "fixture.command-error", .callback = Fixture.commandHint }, .{ .label = "典型通知", .id = "fixture.scenes", .callback = Fixture.scenes }, .{ .label = "完成与取消", .id = "fixture.outcomes", .callback = Fixture.outcomes }, .{ .label = "长消息", .id = "fixture.long", .callback = Fixture.long }, .{ .label = "普通消息", .id = "fixture.normal", .callback = Fixture.normal }, .{ .label = "带查看动作", .id = "fixture.action", .callback = Fixture.actionable }, .{ .label = "错误消息", .id = "fixture.error", .callback = Fixture.failure }, .{ .label = "连接失败", .id = "fixture.connection-failure", .callback = Fixture.connectionFailure }, .{ .label = "切换遮挡", .id = "fixture.cover", .callback = Fixture.toggle }, .{ .label = "就地确认", .id = "fixture.local", .callback = Fixture.local } }) |spec| {
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
