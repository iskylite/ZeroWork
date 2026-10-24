//! Local-only status presentation. All process/cwd/geometry values come from
//! the captured owner; this view neither probes a process nor writes a PTY.
const std = @import("std");
const ui = @import("ui");
const identity = @import("../host/identity.zig");
const local = @import("../host/process_service.zig");
const status = @import("status_controller.zig");
const S = @import("local_status_styles.zig");

pub const Grid = struct { cols: u16, rows: u16, revision: u64 };
pub const Update = struct {
    owner: identity.SessionHandle,
    source_revision: u64,
    process: ?local.ProcessSnapshot = null,
    cwd: ?[]const u8 = null,
    grid: ?Grid = null,
    encoding: enum { unknown, utf8 } = .unknown,
};
pub const Hooks = struct {
    context: *anyopaque,
    detail: *const fn (*anyopaque, status.Kind, *ui.Node) void,
    theme: ?*const fn (*anyopaque, *ui.Node) void = null,
};

pub const View = struct {
    cx: *ui.Cx,
    hooks: Hooks,
    hover_style: *ui.Signal(?S.ButtonStyle),
    root: *ui.Node = undefined,
    identity_button: *ui.Node = undefined,
    encoding_button: *ui.Node = undefined,
    grid_button: *ui.Node = undefined,
    more_button: *ui.Node = undefined,
    theme_button: *ui.Node = undefined,
    cwd_row: *ui.Node = undefined,
    identity_label: *ui.Node = undefined,
    identity_chevron: *ui.Node = undefined,
    state_dot: *ui.Node = undefined,
    encoding_label: *ui.Node = undefined,
    grid_label: *ui.Node = undefined,
    cwd_label: *ui.Node = undefined,
    identity_icon: *ui.Node = undefined,
    encoding_icon: *ui.Node = undefined,
    grid_icon: *ui.Node = undefined,
    cwd_icon: *ui.Node = undefined,
    more_icon: *ui.Node = undefined,
    theme_icon: *ui.Node = undefined,
    owner: ?identity.SessionHandle = null,
    source_revision: u64 = 0,
    sidebar_collapsed: bool = false,
    width: f32 = -1,
    layout_dirty: bool = true,

    pub fn mount(cx: *ui.Cx, scope: *ui.Scope, hooks: Hooks) !*View {
        const self = try cx.allocator.create(View);
        var adopted = false;
        errdefer if (!adopted) cx.allocator.destroy(self);
        const hover_style = try scope.createSignal(?S.ButtonStyle, S.hover());
        self.* = .{ .cx = cx, .hooks = hooks, .hover_style = hover_style };
        try scope.onCleanup(View, self, cleanup);
        adopted = true;
        self.root = try ui.box(cx, S.bar(), .{});
        self.root.meta.ownership.meta.test_id = "local.statusbar";
        self.root.setDisplay(.none);
        self.identity_button = try ui.widgets.Button(.{ .variant = .ghost, .a11y_label = "本地终端身份", .base_style = S.chip(S.identity_width), .hover_style = hover_style, .on_click = cx.on(View, self, showIdentity) }).mount(scope, cx);
        self.identity_button.setStyleInline(cx.allocator, S.buttonLayout(S.chip(S.identity_width)));
        self.identity_button.meta.ownership.meta.test_id = "local.status.identity";
        self.identity_icon = try ui.iconTint(cx, ui.icons.terminal, S.theme.current().fg_2, S.icon());
        self.identity_icon.setStyleInline(cx.allocator, S.identityIcon());
        self.identity_icon.setDisplay(.none);
        try self.identity_button.appendChild(cx.allocator, self.identity_icon);
        self.state_dot = try ui.box(cx, S.stateDot(), .{});
        try self.identity_button.appendChild(cx.allocator, self.state_dot);
        self.identity_label = try ui.text(cx, "状态未知", S.label(true));
        self.identity_label.setStyleInline(cx.allocator, S.identityTextBox());
        try self.identity_button.appendChild(cx.allocator, self.identity_label);
        self.identity_chevron = try ui.iconTint(cx, ui.icons.chevron_up, S.theme.current().fg_2, .{});
        self.identity_chevron.setStyleInline(cx.allocator, S.chevron());
        try self.identity_button.appendChild(cx.allocator, self.identity_chevron);
        try self.root.appendChild(cx.allocator, self.identity_button);
        const encoding = try self.metric(scope, "终端编码", "local.status.encoding", S.encoding_width, ui.icons.get("type").?, showEncoding);
        self.encoding_button = encoding.button;
        self.encoding_icon = encoding.icon;
        self.encoding_label = try self.metricLabel(encoding.content, "未知", 52);
        const grid = try self.metric(scope, "终端网格", "local.status.grid", S.grid_width, ui.icons.get("move-diagonal").?, showGrid);
        self.grid_button = grid.button;
        self.grid_icon = grid.icon;
        self.grid_label = try self.metricLabel(grid.content, "未知", 70);
        self.cwd_row = try ui.box(cx, S.cwd(S.cwd_width), .{});
        self.cwd_row.meta.ownership.meta.test_id = "local.status.cwd";
        self.cwd_icon = try ui.iconTint(cx, ui.icons.folder, S.theme.current().fg_2, S.icon());
        try self.cwd_row.appendChild(cx.allocator, self.cwd_icon);
        self.cwd_label = try ui.text(cx, "目录未知", S.label(false));
        self.cwd_label.setStyleInline(cx.allocator, .{ .width = .fill(), .height = .{ .px = 16 }, .flex = 1, .min_width = 0, .overflow_hidden = true });
        try self.cwd_row.appendChild(cx.allocator, self.cwd_label);
        try self.root.appendChild(cx.allocator, self.cwd_row);
        try self.root.appendChild(cx.allocator, try ui.spacer(cx));
        const more = try self.action(scope, "更多终端状态", "local.status.more", ui.icons.ellipsis, false, showMore);
        self.more_button = more.button;
        self.more_button.setDisplay(.none);
        self.more_icon = more.icon;
        const theme = try self.action(scope, "全局主题 · 应用与全部终端", "local.status.theme", ui.icons.palette, hooks.theme == null, showTheme);
        self.theme_button = theme.button;
        self.theme_icon = theme.icon;
        self.layoutForWidth(@max(0, cx.viewport.width - 16));
        return self;
    }

    const Metric = struct { button: *ui.Node, content: *ui.Node, icon: *ui.Node };
    fn metric(self: *View, scope: *ui.Scope, label: []const u8, test_id: []const u8, width: f32, asset: ui.SvgAsset, comptime callback: fn (*View) void) !Metric {
        _ = scope;
        _ = label;
        _ = callback;
        const button = try ui.box(self.cx, S.staticMetric(width), .{});
        button.meta.ownership.meta.test_id = test_id;
        const content = try ui.box(self.cx, S.metricContent(), .{});
        try button.appendChild(self.cx.allocator, content);
        const icon = try ui.iconTint(self.cx, asset, S.theme.current().fg_2, S.icon());
        try content.appendChild(self.cx.allocator, icon);
        try self.root.appendChild(self.cx.allocator, button);
        return .{ .button = button, .content = content, .icon = icon };
    }
    fn metricLabel(self: *View, button: *ui.Node, text: []const u8, width: f32) !*ui.Node {
        const label = try ui.text(self.cx, text, S.label(false));
        label.setStyleInline(self.cx.allocator, S.labelBox(width));
        try button.appendChild(self.cx.allocator, label);
        return label;
    }
    const Action = struct { button: *ui.Node, icon: *ui.Node };
    fn action(self: *View, scope: *ui.Scope, label: []const u8, test_id: []const u8, asset: ui.SvgAsset, disabled: bool, comptime callback: fn (*View) void) !Action {
        const button = try ui.widgets.Button(.{ .variant = .ghost, .icon_only = true, .disabled = disabled, .a11y_label = label, .base_style = S.action(), .hover_style = self.hover_style, .on_click = self.cx.on(View, self, callback) }).mount(scope, self.cx);
        button.setStyleInline(self.cx.allocator, S.buttonLayout(S.action()));
        button.meta.ownership.meta.test_id = test_id;
        const icon = try ui.iconTint(self.cx, asset, S.theme.current().fg_2, .{});
        icon.setStyleInline(self.cx.allocator, S.actionIcon());
        try button.appendChild(self.cx.allocator, icon);
        try self.root.appendChild(self.cx.allocator, button);
        return .{ .button = button, .icon = icon };
    }

    pub fn currentOwner(self: *const View) ?identity.SessionHandle {
        return self.owner;
    }

    /// Publish named colors in place. The host refreshes the state dot from
    /// its real process projection; identities, focus and geometry stay intact.
    pub fn retheme(self: *View) void {
        const c = S.theme.current();
        self.root.setStyleInline(self.cx.allocator, S.barPaint());
        self.identity_label.setTextColor(c.fg_1);
        for ([_]*ui.Node{ self.encoding_label, self.grid_label, self.cwd_label }) |node| node.setTextColor(c.fg_2);
        for ([_]*ui.Node{ self.identity_icon, self.identity_chevron, self.encoding_icon, self.grid_icon, self.cwd_icon, self.more_icon, self.theme_icon }) |node| _ = node.setTint(c.fg_2);
        self.hover_style.set(S.hover());
        self.cx.requestRedraw();
    }

    /// Call for meaningful projection changes, not on each frame. Node text
    /// owns its copy, so caller-owned cwd/process snapshots may be released.
    pub fn update(self: *View, value: Update) !void {
        if (@backingInt(value.owner.session_id) == 0 or value.owner.generation == 0) return error.InvalidOwner;
        if (value.source_revision == 0) return error.InvalidRevision;
        if (value.process) |process| if (!process.owner.eql(value.owner)) return error.StaleOwner;
        if (value.grid) |grid| if (grid.cols == 0 or grid.rows == 0 or grid.revision == 0) return error.InvalidGeometry;
        if (value.cwd) |cwd| if (cwd.len == 0 or cwd[0] != '/' or !std.unicode.utf8ValidateSlice(cwd) or std.mem.indexOfScalar(u8, cwd, 0) != null) return error.InvalidDirectory;
        if (self.owner) |current| if (current.eql(value.owner) and value.source_revision <= self.source_revision) return;
        errdefer {
            self.owner = null;
            self.root.setDisplay(.none);
        }
        const state = if (value.process) |process| process.state else null;
        try replaceText(self, self.identity_label, if (state) |actual| switch (actual) {
            .starting => "启动中",
            .running => "运行中",
            .exited, .closed => "已退出",
            .failed => "启动失败",
            .closing => "关闭中",
            .cleanup_unknown => "状态未知",
        } else "状态未知");
        self.state_dot.setBackground(if (state) |actual| switch (actual) {
            .running => S.theme.current().ok,
            .starting, .closing => S.theme.current().warn,
            .failed, .cleanup_unknown => S.theme.current().danger,
            .exited, .closed => S.theme.current().fg_3,
        } else S.theme.current().fg_3);
        try replaceText(self, self.encoding_label, if (value.encoding == .utf8) "UTF-8" else "未知");
        var buffer: [40]u8 = undefined;
        try replaceText(self, self.grid_label, if (value.grid) |grid| try std.fmt.bufPrint(&buffer, "{d}×{d}", .{ grid.cols, grid.rows }) else "未知");
        try replaceText(self, self.cwd_label, value.cwd orelse "目录未知");
        self.owner = value.owner;
        self.source_revision = value.source_revision;
        self.root.setDisplay(.flex);
    }

    pub fn setSidebarCollapsed(self: *View, collapsed: bool) void {
        if (self.sidebar_collapsed == collapsed) return;
        self.sidebar_collapsed = collapsed;
        self.layout_dirty = true;
        self.layoutForWidth(self.width);
    }

    /// Use the actual statusbar width. Hide substitutable details before
    /// removing the global-theme action; More stays reachable at every width.
    pub fn layoutForWidth(self: *View, width: f32) void {
        if (!std.math.isFinite(width) or width < 0) return;
        if (width == self.width and !self.layout_dirty) return;
        self.width = width;
        self.layout_dirty = false;
        const identity_width = S.identity_width;
        var show_theme = self.hooks.theme != null;
        const show_metrics = width >= minimumWidth(identity_width, true, show_theme);
        if (width < minimumWidth(identity_width, show_metrics, show_theme)) show_theme = false;
        const remaining = @min(S.cwd_width, @max(0, width - minimumWidth(identity_width, show_metrics, show_theme) - S.gap));
        self.identity_button.setStyleInline(self.cx.allocator, S.buttonLayout(S.chip(identity_width)));
        self.identity_label.setDisplay(.flex);
        self.identity_chevron.setDisplay(.flex);
        visible(self.encoding_button, show_metrics);
        visible(self.grid_button, show_metrics);
        visible(self.theme_button, show_theme);
        self.cwd_row.setDisplay(if (remaining >= 32) .flex else .none);
        self.cwd_row.setStyleInline(self.cx.allocator, S.cwd(remaining));
    }

    fn minimumWidth(identity_width: f32, metrics: bool, theme: bool) f32 {
        const children: f32 = 3 + @as(f32, if (metrics) 2 else 0) + @as(f32, if (theme) 1 else 0); // identity, spacer, More
        return identity_width + S.chip_height + S.right_padding + (if (metrics) S.encoding_width + S.grid_width else 0) + (if (theme) S.chip_height else 0) + (children - 1) * S.gap;
    }
    fn visible(node: *ui.Node, enabled: bool) void {
        node.setDisplay(if (enabled) .flex else .none);
        node.setFocusable(enabled);
    }
    fn replaceText(self: *View, node: *ui.Node, value: []const u8) !void {
        if (node.getText()) |old| if (std.mem.eql(u8, old.content, value)) return;
        try node.setTextContent(self.cx.allocator, value);
    }
    fn showIdentity(self: *View) void {
        self.show(.identity, self.identity_button);
    }
    fn showEncoding(self: *View) void {
        self.show(.encoding, self.encoding_button);
    }
    fn showGrid(self: *View) void {
        self.show(.grid, self.grid_button);
    }
    fn showMore(self: *View) void {
        self.show(.more, self.more_button);
    }
    fn showTheme(self: *View) void {
        if (self.owner != null) if (self.hooks.theme) |callback| callback(self.hooks.context, self.theme_button);
    }
    fn show(self: *View, kind: status.Kind, trigger: *ui.Node) void {
        if (self.owner != null) self.hooks.detail(self.hooks.context, kind, trigger);
    }
    fn cleanup(self: *View) void {
        self.cx.allocator.destroy(self);
    }
};

const TestHooks = struct {
    kind: ?status.Kind = null,
    trigger: ?*ui.Node = null,
    themes: usize = 0,
    fn detail(raw: *anyopaque, kind: status.Kind, trigger: *ui.Node) void {
        const self: *@This() = @ptrCast(@alignCast(raw));
        self.kind = kind;
        self.trigger = trigger;
    }
    fn theme(raw: *anyopaque, trigger: *ui.Node) void {
        const self: *@This() = @ptrCast(@alignCast(raw));
        self.themes += 1;
        self.trigger = trigger;
    }
};
fn testUpdate() Update {
    const owner: identity.SessionHandle = .{ .session_id = @fromBackingInt(401) };
    return .{ .owner = owner, .source_revision = 1, .process = .{ .owner = owner, .state = .running, .pid = 123, .exit = null, .eof_seen = false, .cleanup = .awaiting, .foreground = null }, .cwd = "/tmp/ZeroWork", .grid = .{ .cols = 132, .rows = 36, .revision = 1 }, .encoding = .utf8 };
}

test "Local status uses exact public widget geometry and real detail triggers" {
    const cx = try ui.Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    cx.setViewport(1424, 32);
    cx.root = try ui.box(cx, .{ .width = .fill(), .height = .fill(), .direction = .column }, .{});
    const scope = try ui.Scope.init(std.testing.allocator, null, cx.owner);
    defer scope.dispose();
    var recorder: TestHooks = .{};
    const view = try View.mount(cx, scope, .{ .context = &recorder, .detail = TestHooks.detail, .theme = TestHooks.theme });
    try cx.root.?.appendChild(cx.allocator, view.root);
    try view.update(testUpdate());
    view.layoutForWidth(1424);
    cx.layout();
    try std.testing.expectApproxEqAbs(@as(f32, 32), view.root.globalRect().h, 0.01);
    const Expected = struct { node: *ui.Node, x: f32, width: f32 };
    const expected = [_]Expected{
        .{ .node = view.identity_button, .x = 0, .width = 112 },
        .{ .node = view.encoding_button, .x = 118, .width = 76 },
        .{ .node = view.grid_button, .x = 200, .width = 94 },
        .{ .node = view.cwd_row, .x = 300, .width = 440 },
        .{ .node = view.theme_button, .x = 1386, .width = 26 },
    };
    for (expected) |item| {
        const rect = item.node.globalRect();
        try std.testing.expectApproxEqAbs(item.x, rect.x, 0.01);
        try std.testing.expectApproxEqAbs(@as(f32, 3), rect.y, 0.01);
        try std.testing.expectApproxEqAbs(item.width, rect.w, 0.01);
        try std.testing.expectApproxEqAbs(@as(f32, 26), rect.h, 0.01);
    }
    try std.testing.expectApproxEqAbs(@as(f32, 145), view.encoding_label.globalRect().x, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 227), view.grid_label.globalRect().x, 0.01);
    const Click = struct { node: *ui.Node, kind: status.Kind };
    for ([_]Click{.{ .node = view.identity_button, .kind = .identity }}) |click| {
        const rect = click.node.globalRect();
        cx.handleMouseDown(rect.x + rect.w / 2, rect.y + 13, .{});
        cx.handleMouseUp(rect.x + rect.w / 2, rect.y + 13);
        try std.testing.expectEqual(click.kind, recorder.kind.?);
        try std.testing.expectEqual(click.node, recorder.trigger.?);
    }
    const theme = view.theme_button.globalRect();
    cx.handleMouseDown(theme.x + 13, theme.y + 13, .{});
    cx.handleMouseUp(theme.x + 13, theme.y + 13);
    try std.testing.expectEqual(@as(usize, 1), recorder.themes);
}

test "Local status owns displayed cwd and keeps narrow actions reachable without invented values" {
    const cx = try ui.Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    cx.setViewport(464, 32); // 480px window with the common 8px outer inset.
    cx.root = try ui.box(cx, .{ .width = .fill(), .height = .fill(), .direction = .column }, .{});
    const scope = try ui.Scope.init(std.testing.allocator, null, cx.owner);
    defer scope.dispose();
    var recorder: TestHooks = .{};
    const view = try View.mount(cx, scope, .{ .context = &recorder, .detail = TestHooks.detail, .theme = TestHooks.theme });
    try cx.root.?.appendChild(cx.allocator, view.root);
    var update = testUpdate();
    var cwd = [_]u8{ '/', 't', 'm', 'p' };
    update.cwd = &cwd;
    try view.update(update);
    cwd[1] = 'x';
    try std.testing.expectEqualStrings("/tmp", view.cwd_label.getText().?.content);
    update.cwd = "/ignored";
    try view.update(update); // Same owner/revision cannot overwrite newer data.
    try std.testing.expectEqualStrings("/tmp", view.cwd_label.getText().?.content);
    view.layoutForWidth(464);
    cx.layout();
    try std.testing.expect(view.encoding_button.style.display != .none);
    try std.testing.expect(view.grid_button.style.display != .none);
    try std.testing.expect(view.more_button.globalRect().x + 26 <= 464);
    try std.testing.expect(view.theme_button.globalRect().x + 26 <= 464);
    view.setSidebarCollapsed(true);
    cx.layout();
    try std.testing.expectApproxEqAbs(S.identity_width, view.identity_button.globalRect().w, 0.01);
    try std.testing.expect(view.identity_label.style.display != .none);
    try std.testing.expect(view.identity_chevron.style.display != .none);
    try std.testing.expect(view.encoding_button.style.display != .none);
    try std.testing.expect(view.grid_button.style.display != .none);
    update.source_revision = 2;
    update.process = null;
    update.cwd = null;
    update.grid = null;
    update.encoding = .unknown;
    try view.update(update);
    try std.testing.expectEqualStrings("状态未知", view.identity_label.getText().?.content);
    try std.testing.expectEqualStrings("目录未知", view.cwd_label.getText().?.content);
    try std.testing.expectEqualStrings("未知", view.grid_label.getText().?.content);
    try std.testing.expectEqualStrings("未知", view.encoding_label.getText().?.content);
    update.owner = try update.owner.nextGeneration();
    update.source_revision = 1;
    try view.update(update);
    try std.testing.expect(view.currentOwner().?.eql(update.owner));
    update.grid = .{ .cols = 0, .rows = 24, .revision = 1 };
    try std.testing.expectError(error.InvalidGeometry, view.update(update));
}

test "Local status rethemes dark to light in place without changing triggers or ownership" {
    const previous = S.theme.currentName();
    defer S.theme.select(previous);
    S.theme.select(.dark);
    const cx = try ui.Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    cx.setTheme(S.theme.widgetTheme(.dark));
    cx.setViewport(1424, 32);
    cx.root = try ui.box(cx, .{ .width = .fill(), .height = .fill(), .direction = .column }, .{});
    const scope = try ui.Scope.init(std.testing.allocator, null, cx.owner);
    defer scope.dispose();
    var recorder: TestHooks = .{};
    const view = try View.mount(cx, scope, .{ .context = &recorder, .detail = TestHooks.detail, .theme = TestHooks.theme });
    try cx.root.?.appendChild(cx.allocator, view.root);
    var value = testUpdate();
    try view.update(value);
    view.setSidebarCollapsed(true);
    cx.layout();
    _ = cx.render();
    cx.setFocus(view.theme_button);
    defer cx.clearFocus();
    const nodes = [_]*ui.Node{ view.root, view.identity_button, view.encoding_button, view.grid_button, view.more_button, view.theme_button, view.cwd_row };
    var ids: [nodes.len]u32 = undefined;
    var rects: [nodes.len]@TypeOf(view.root.globalRect()) = undefined;
    for (nodes, 0..) |node, index| {
        ids[index] = node.id;
        rects[index] = node.globalRect();
    }
    const dark = S.theme.current();
    try std.testing.expectEqual(dark.fg_1, view.identity_label.getText().?.color);
    try std.testing.expectEqual(dark.ok, view.state_dot.getBackground());
    S.theme.select(.light);
    cx.setTheme(S.theme.widgetTheme(.light));
    view.retheme();
    cx.layout();
    const light = S.theme.current();
    try std.testing.expect(!ui.Color.eql(dark.fg_1, light.fg_1));
    try std.testing.expectEqual(light.surface_1, view.root.getBackground());
    try std.testing.expectEqual(light.fg_1, view.identity_label.getText().?.color);
    for ([_]*ui.Node{ view.encoding_label, view.grid_label, view.cwd_label }) |node| try std.testing.expectEqual(light.fg_2, node.getText().?.color);
    for ([_]*ui.Node{ view.identity_icon, view.identity_chevron, view.encoding_icon, view.grid_icon, view.cwd_icon, view.more_icon, view.theme_icon }) |node| {
        const tint = if (node.getIcon()) |icon| icon.tint else node.getImage().?.tint;
        try std.testing.expectEqual(light.fg_2, tint);
    }
    try std.testing.expect(view.currentOwner().?.eql(value.owner));
    try std.testing.expectEqual(value.source_revision, view.source_revision);
    try std.testing.expect(cx.isFocused(view.theme_button));
    for (nodes, 0..) |node, index| {
        try std.testing.expectEqual(ids[index], node.id);
        const rect = node.globalRect();
        try std.testing.expectApproxEqAbs(rects[index].x, rect.x, 0.01);
        try std.testing.expectApproxEqAbs(rects[index].y, rect.y, 0.01);
        try std.testing.expectApproxEqAbs(rects[index].w, rect.w, 0.01);
        try std.testing.expectApproxEqAbs(rects[index].h, rect.h, 0.01);
    }
    // The host's next real projection refreshes process-derived colors.
    try std.testing.expectEqual(dark.ok, view.state_dot.getBackground());
    value.source_revision += 1;
    try view.update(value);
    try std.testing.expectEqual(light.ok, view.state_dot.getBackground());
    const more = view.theme_button.globalRect();
    cx.handleMouseMove(more.x + 13, more.y + 13);
    try cx.setTestFrameStep(16);
    for (0..20) |_| {
        cx.advanceFrameClock();
        cx.layout();
        _ = cx.render();
    }
    try std.testing.expectEqual(cx.tokens.tokens.color.bg_active, view.theme_button.getBackground());
    try std.testing.expect(view.theme_button.style.outline() == null);
    // Clearing keyboard focus must restore the current ghost action surface,
    // even when focus began under the previous theme.
    cx.clearFocus();
    cx.handleMouseMove(0, 0);
    for (0..20) |_| {
        cx.advanceFrameClock();
        cx.layout();
        _ = cx.render();
    }
    try std.testing.expectEqual(ui.Color.TRANSPARENT, view.theme_button.getBackground());
    try std.testing.expect(view.theme_button.style.outline() == null);
    cx.setFocus(view.theme_button);
    for (0..20) |_| {
        cx.advanceFrameClock();
        cx.layout();
        _ = cx.render();
    }
    try std.testing.expect(cx.isFocused(view.theme_button));
    try std.testing.expectEqual(light.selection, view.theme_button.getBackground());
    S.theme.select(.dark);
    cx.setTheme(S.theme.widgetTheme(.dark));
    view.retheme();
    for (0..20) |_| {
        cx.advanceFrameClock();
        cx.layout();
        _ = cx.render();
    }
    try std.testing.expectEqual(dark.selection, view.theme_button.getBackground());
    try std.testing.expect(view.theme_button.style.outline() == null);
    try std.testing.expect(view.currentOwner().?.eql(value.owner));
    try std.testing.expectEqual(value.source_revision, view.source_revision);
    cx.clearFocus();
    for (0..20) |_| {
        cx.advanceFrameClock();
        cx.layout();
        _ = cx.render();
    }
    try std.testing.expectEqual(ui.Color.TRANSPARENT, view.theme_button.getBackground());
}
