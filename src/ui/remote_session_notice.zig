//! Per-pane remote session notices. Only captured runtime facts drive state;
//! actions route back through the workspace's existing close/retry controller.
const std = @import("std");
const ui = @import("ui");
const S = @import("local_session_styles.zig");
const theme = @import("app_theme.zig");
const Control = @import("../vt/reconnect.zig").Control;

pub const State = enum { connected, exited, disconnected, reconnecting, retry_failed };
pub const Snapshot = struct {
    state: State = .connected,
    cleanup: @import("../proto/ssh/session.zig").ReleaseReceipt = .released,
    exit_code: ?i32 = null,
    failure: ?anyerror = null,
    buffer_input: bool = false,
    auto_retry_seconds: ?u64 = null,
    initialization_confirmation: bool = false,

    pub fn fromRuntime(value: Control.Snapshot, retrying: bool) Snapshot {
        return .{
            .state = switch (value.phase) {
                .active => .connected,
                .ended => .exited,
                .connecting, .ready => .reconnecting,
                .releasing, .waiting => if (retrying) .retry_failed else .disconnected,
                .closed => .disconnected,
            },
            .cleanup = value.cleanup,
            .exit_code = value.exit_code,
            .failure = value.failure,
        };
    }
    pub fn canRetry(self: Snapshot) bool {
        return self.cleanup == .released and switch (self.state) {
            .exited, .disconnected, .retry_failed => true,
            .connected, .reconnecting => false,
        };
    }
    pub fn title(self: Snapshot) []const u8 {
        if ((self.failure != null and self.failure.? == error.ShellInitializationFailed)) return if (self.initialization_confirmation) "终端自动初始化再次失败" else "终端自动初始化失败，正在自动重连一次…";
        return switch (self.state) {
            .connected => "已连接",
            .exited => "远程终端已退出",
            .disconnected => "与远程主机的连接已断开",
            .reconnecting => "正在重新连接远程主机…",
            .retry_failed => "重新连接失败",
        };
    }
    pub fn detail(self: Snapshot, buffer: []u8) []const u8 {
        if ((self.failure != null and self.failure.? == error.ShellInitializationFailed) and self.cleanup == .released) return if (self.initialization_confirmation)
            "可确认仅本次跳过初始化后重连；全局和主机设置保持不变。未执行或重放业务命令"
        else
            "将使用新连接重新初始化；未执行或重放业务命令";
        if (self.state != .connected and self.state != .reconnecting and self.cleanup != .released) return if (self.cleanup == .unknown)
            "历史输出仍可查看；资源释放结果未知，暂时无法重连"
        else
            "历史输出仍可查看；正在释放旧连接，请稍候再重连";
        if (self.state == .disconnected or self.state == .retry_failed) if (self.auto_retry_seconds) |seconds| {
            return std.fmt.bufPrint(buffer, "历史输出仍可查看；将在 {d} 秒后自动重连，也可点击立即重连", .{seconds}) catch "历史输出仍可查看；即将自动重连，也可点击立即重连";
        };
        const text: []const u8 = switch (self.state) {
            .connected => "",
            .exited => "历史输出仍可查看，继续使用请重新连接",
            .disconnected => "历史输出仍可查看，请检查网络后重新连接",
            .reconnecting => if (self.buffer_input) "历史输出仍可查看；已开启输入缓冲，键入内容将在重连后发送" else "历史输出仍可查看，连接恢复后即可继续输入",
            .retry_failed => "历史输出仍可查看，请检查网络或连接设置后重试",
        };
        if (self.state == .exited) {
            return if (self.exit_code) |code| std.fmt.bufPrint(buffer, "{s} · 退出码 {d}", .{ text, code }) catch text else text;
        }
        if (self.state == .disconnected or self.state == .retry_failed) {
            if (self.failure) |failure| return std.fmt.bufPrint(buffer, "{s} · {s}", .{ text, @errorName(failure) }) catch text;
        }
        return text;
    }
};

pub const Hooks = struct {
    context: *anyopaque,
    session_id: u64,
    reconnect: *const fn (*anyopaque, u64) void,
    close: *const fn (*anyopaque, u64) void,
    without_initialization: ?*const fn (*anyopaque, u64) void = null,
};
pub const View = struct {
    cx: *ui.Cx,
    hooks: Hooks,
    root: *ui.Node,
    title_node: *ui.Node,
    detail_node: *ui.Node,
    icon: *ui.Node,
    spinner: *ui.Node,
    spinner_color: *ui.Signal(?ui.Color),
    painted_colors: ?theme.Colors = null,
    reconnect: *ui.Node,
    retry: *ui.Node,
    close: *ui.Node,
    without_initialization: *ui.Node,
    snapshot: ?Snapshot = null,

    pub fn mount(cx: *ui.Cx, scope: *ui.Scope, parent: *ui.Node, hooks: Hooks) !*View {
        const self = try cx.allocator.create(View);
        errdefer cx.allocator.destroy(self);
        const root = try ui.box(cx, S.banner(false), .{});
        root.meta.ownership.meta.test_id = "remote.notice";
        try parent.appendChild(cx.allocator, root);
        const icon = try ui.iconTint(cx, ui.icons.terminal, theme.current().fg_2, S.icon());
        try root.appendChild(cx.allocator, icon);
        const spinner_color = try scope.createSignal(?ui.Color, theme.current().fg_2);
        const spinner = try ui.widgets.Spinner(.{ .size = 20, .stroke_width = 2, .color = spinner_color }).mount(scope, cx);
        try root.appendChild(cx.allocator, spinner);
        const copy = try ui.box(cx, S.copy(), .{});
        copy.behavior.interaction.a11y = .{ .role = .status, .live = "polite" };
        try root.appendChild(cx.allocator, copy);
        const title_node = try ui.text(cx, "", S.title());
        title_node.meta.ownership.meta.test_id = "remote.notice.title";
        try copy.appendChild(cx.allocator, title_node);
        const detail_node = try ui.text(cx, "", S.detail());
        detail_node.meta.ownership.meta.test_id = "remote.notice.detail";
        try copy.appendChild(cx.allocator, detail_node);
        self.* = .{ .cx = cx, .hooks = hooks, .root = root, .title_node = title_node, .detail_node = detail_node, .icon = icon, .spinner = spinner, .spinner_color = spinner_color, .reconnect = undefined, .retry = undefined, .close = undefined, .without_initialization = undefined };
        self.close = try self.button(scope, "关闭页签", "remote.notice.close", false, onClose);
        self.reconnect = try self.button(scope, "重新连接", "remote.notice.reconnect", true, onReconnect);
        self.retry = try self.button(scope, "重试连接", "remote.notice.retry", true, onReconnect);
        self.without_initialization = try self.button(scope, "确认本次不初始化重连", "remote.notice.without-initialization", true, onWithoutInitialization);
        try scope.onCleanup(View, self, destroy);
        self.update(.{});
        return self;
    }
    fn button(self: *View, scope: *ui.Scope, label: []const u8, id: []const u8, comptime primary: bool, comptime callback: fn (*View) void) !*ui.Node {
        const node = try ui.widgets.Button(.{ .label = label, .variant = @as(ui.widgets.ButtonVariant, if (primary) .primary else .ghost), .size = .sm, .base_style = .{ .font_size = 12, .font_weight = 500 }, .on_click = self.cx.on(View, self, callback) }).mount(scope, self.cx);
        node.setStyleInline(self.cx.allocator, S.action());
        node.meta.ownership.meta.test_id = id;
        try self.root.appendChild(self.cx.allocator, node);
        return node;
    }
    pub fn update(self: *View, value: Snapshot) void {
        const colors = theme.current();
        const same_colors = if (self.painted_colors) |old| std.meta.eql(old, colors) else false;
        if (self.snapshot) |old| if (std.meta.eql(old, value) and same_colors) return;
        self.snapshot = value;
        self.painted_colors = colors;
        self.root.setBackground(colors.surface_2);
        self.title_node.setTextColor(colors.fg_1);
        self.detail_node.setTextColor(colors.fg_2);
        self.spinner_color.set(colors.fg_2);
        var buffer: [512]u8 = undefined;
        self.title_node.setTextContent(self.cx.allocator, value.title()) catch {};
        self.detail_node.setTextContent(self.cx.allocator, value.detail(&buffer)) catch {};
        visible(self.root, value.state != .connected);
        visible(self.icon, value.state != .reconnecting);
        visible(self.spinner, value.state == .reconnecting);
        visible(self.close, value.state != .connected);
        const initialization_failure = (value.failure != null and value.failure.? == error.ShellInitializationFailed);
        visible(self.reconnect, !initialization_failure and value.canRetry() and value.state != .retry_failed);
        visible(self.retry, !initialization_failure and value.canRetry() and value.state == .retry_failed);
        visible(self.without_initialization, initialization_failure and value.initialization_confirmation and value.canRetry() and self.hooks.without_initialization != null);
        _ = self.icon.setTint(if (value.state == .disconnected or value.state == .retry_failed) theme.current().danger else theme.current().fg_2);
        self.cx.requestRedraw();
    }
    fn visible(node: *ui.Node, show: bool) void {
        node.setDisplay(if (show) .flex else .none);
        node.setFocusable(show and node.behavior.events.on_click != null);
    }
    fn onReconnect(self: *View) void {
        if (self.snapshot) |state| if (state.canRetry()) self.hooks.reconnect(self.hooks.context, self.hooks.session_id);
    }
    fn onClose(self: *View) void {
        self.hooks.close(self.hooks.context, self.hooks.session_id);
    }
    fn onWithoutInitialization(self: *View) void {
        const state = self.snapshot orelse return;
        if ((state.failure == null or state.failure.? != error.ShellInitializationFailed) or !state.initialization_confirmation or !state.canRetry()) return;
        if (self.hooks.without_initialization) |call| call(self.hooks.context, self.hooks.session_id);
    }
    fn destroy(self: *View) void {
        self.cx.allocator.destroy(self);
    }
};

test "Remote session notice distinguishes exit loss retry and cleanup gates" {
    var buffer: [512]u8 = undefined;
    const ended = Snapshot.fromRuntime(.{ .key = null, .phase = .ended, .cleanup = .released, .exit_code = 7 }, false);
    try std.testing.expectEqual(State.exited, ended.state);
    try std.testing.expect(ended.canRetry());
    try std.testing.expect(std.mem.endsWith(u8, ended.detail(&buffer), "退出码 7"));
    const loss = Snapshot.fromRuntime(.{ .key = null, .phase = .waiting, .cleanup = .released, .failure = error.ConnectionClosed }, false);
    try std.testing.expectEqual(State.disconnected, loss.state);
    try std.testing.expect(std.mem.indexOf(u8, loss.detail(&buffer), "检查网络") != null);
    const failed = Snapshot.fromRuntime(.{ .key = null, .phase = .waiting, .cleanup = .released, .failure = error.ConnectFailed }, true);
    try std.testing.expectEqual(State.retry_failed, failed.state);
    try std.testing.expect(failed.canRetry());
    for ([_]@FieldType(Snapshot, "cleanup"){ .awaiting, .unknown }) |cleanup| {
        var pending = failed;
        pending.cleanup = cleanup;
        try std.testing.expect(!pending.canRetry());
        try std.testing.expect(std.mem.indexOf(u8, pending.detail(&buffer), "重连") != null);
    }
    const connecting = Snapshot.fromRuntime(.{ .key = null, .phase = .connecting }, false);
    try std.testing.expectEqual(State.reconnecting, connecting.state);
    try std.testing.expect(!connecting.canRetry());
    var buffered = connecting;
    buffered.buffer_input = true;
    try std.testing.expect(std.mem.indexOf(u8, buffered.detail(&buffer), "缓冲") != null);
    var automatic = loss;
    automatic.auto_retry_seconds = 3;
    try std.testing.expect(std.mem.indexOf(u8, automatic.detail(&buffer), "3 秒后自动重连") != null);
}

test "Remote session notice native layout and actions preserve output and reject duplicate retry" {
    const a = std.testing.allocator;
    const cx = try ui.Cx.init(a, std.testing.io);
    defer cx.deinit();
    const scope = try ui.Scope.init(a, null, cx.owner);
    defer scope.dispose();
    cx.root = try ui.box(cx, S.pane(), .{});
    const Recorder = struct {
        retries: usize = 0,
        closes: usize = 0,
        bypasses: usize = 0,
        fn reconnect(raw: *anyopaque, id: u64) void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            std.debug.assert(id == 42);
            self.retries += 1;
        }
        fn close(raw: *anyopaque, id: u64) void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            std.debug.assert(id == 42);
            self.closes += 1;
        }
        fn bypass(raw: *anyopaque, id: u64) void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            std.debug.assert(id == 42);
            self.bypasses += 1;
        }
    };
    var recorder: Recorder = .{};
    const view = try View.mount(cx, scope, cx.root.?, .{ .context = &recorder, .session_id = 42, .reconnect = Recorder.reconnect, .close = Recorder.close, .without_initialization = Recorder.bypass });
    const output = try ui.box(cx, .{ .width = .fill(), .height = .fill(), .flex = 1, .min_height = 0 }, .{});
    try cx.root.?.appendChild(a, output);
    const states = [_]Snapshot{
        .{ .state = .exited, .exit_code = 130 },
        .{ .state = .disconnected, .failure = error.ConnectionClosed },
        .{ .state = .reconnecting },
        .{ .state = .retry_failed, .failure = error.ConnectFailed },
        .{ .state = .disconnected, .cleanup = .unknown },
    };
    for ([_]f32{ 1000, 598, 360 }) |width| {
        cx.setViewport(width, 480);
        for (states) |state| {
            view.update(state);
            cx.layout();
            const bar = view.root.globalRect();
            try std.testing.expectApproxEqAbs(@as(f32, 64), bar.h, 0.1);
            try std.testing.expectApproxEqAbs(bar.y + bar.h, output.globalRect().y, 0.1);
            try std.testing.expect(view.close.globalRect().x >= bar.x);
            const action = if (state.state == .retry_failed) view.retry else view.reconnect;
            if (state.canRetry()) {
                const rect = action.globalRect();
                try std.testing.expect(view.close.globalRect().x + view.close.globalRect().w <= rect.x);
                try std.testing.expect(rect.x + rect.w <= bar.x + bar.w);
            } else {
                try std.testing.expect(view.reconnect.style.display == .none);
                try std.testing.expect(view.retry.style.display == .none);
            }
        }
    }
    view.update(states[0]);
    view.reconnect.behavior.events.on_click.?.invoke();
    try std.testing.expectEqual(@as(usize, 1), recorder.retries);
    view.update(states[2]);
    view.reconnect.behavior.events.on_click.?.invoke();
    try std.testing.expectEqual(@as(usize, 1), recorder.retries);
    view.close.behavior.events.on_click.?.invoke();
    try std.testing.expectEqual(@as(usize, 1), recorder.closes);
    const initialization: Snapshot = .{ .state = .retry_failed, .failure = error.ShellInitializationFailed, .initialization_confirmation = true };
    view.update(initialization);
    for ([_]f32{ 620, 1100 }) |width| {
        cx.setViewport(width, 600);
        cx.layout();
        _ = cx.render();
        const bar = view.root.globalRect();
        const action = view.without_initialization.globalRect();
        try std.testing.expect(action.w > 0 and action.x + action.w <= bar.x + bar.w);
        try std.testing.expect(view.reconnect.style.display == .none and view.retry.style.display == .none);
    }
    view.without_initialization.behavior.events.on_click.?.invoke();
    try std.testing.expectEqual(@as(usize, 1), recorder.bypasses);
    var unconfirmed = initialization;
    unconfirmed.initialization_confirmation = false;
    view.update(unconfirmed);
    view.without_initialization.behavior.events.on_click.?.invoke();
    try std.testing.expectEqual(@as(usize, 1), recorder.bypasses);
    var unreleased = initialization;
    unreleased.cleanup = .unknown;
    view.update(unreleased);
    view.without_initialization.behavior.events.on_click.?.invoke();
    try std.testing.expectEqual(@as(usize, 1), recorder.bypasses);
    const previous_theme = theme.currentName();
    defer theme.select(previous_theme);
    for ([_]theme.Name{ .dark, .light, .sauber }) |name| {
        theme.select(name);
        cx.setTheme(theme.widgetTheme(name));
        view.update(states[0]);
        try std.testing.expectEqual(theme.current().surface_2, view.root.getBackground());
        try std.testing.expectEqual(theme.current().fg_1, view.title_node.getText().?.color);
        try std.testing.expectEqual(theme.current().fg_2, view.detail_node.getText().?.color);
    }
    view.update(.{});
    cx.layout();
    try std.testing.expect(view.root.style.display == .none);
    try std.testing.expectApproxEqAbs(@as(f32, 0), output.globalRect().y, 0.1);
}
