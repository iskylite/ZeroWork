const std = @import("std");
const ui = @import("ui");
const styles = @import("terminal_search_styles.zig");
const theme = @import("app_theme.zig");

/// Search state for one terminal pane. Source is caller-owned while searching;
/// setSource copies text so results remain valid across VT frames.
pub const Model = struct {
    allocator: std.mem.Allocator,
    source: std.ArrayList(u8) = .empty,
    query: std.ArrayList(u8) = .empty,
    matches: std.ArrayList(Match) = .empty,
    current: usize = 0,
    open: bool = false,
    composing: bool = false,

    pub const Match = struct { start: usize, end: usize };
    pub fn init(allocator: std.mem.Allocator) Model {
        return .{ .allocator = allocator };
    }
    pub fn deinit(self: *Model) void {
        self.source.deinit(self.allocator);
        self.query.deinit(self.allocator);
        self.matches.deinit(self.allocator);
    }
    pub fn setSource(self: *Model, text: []const u8) !void {
        self.source.clearRetainingCapacity();
        try self.source.appendSlice(self.allocator, text);
        self.recompute();
    }
    pub fn setQuery(self: *Model, text: []const u8) !void {
        self.query.clearRetainingCapacity();
        try self.query.appendSlice(self.allocator, text);
        self.current = 0;
        self.recompute();
    }
    fn recompute(self: *Model) void {
        self.matches.clearRetainingCapacity();
        if (self.query.items.len == 0) return;
        var at: usize = 0;
        while (at + self.query.items.len <= self.source.items.len) : (at += 1) {
            if (std.mem.eql(u8, self.source.items[at .. at + self.query.items.len], self.query.items)) {
                self.matches.append(self.allocator, .{ .start = at, .end = at + self.query.items.len }) catch return;
                at += self.query.items.len - 1;
            }
        }
        if (self.current >= self.matches.items.len) self.current = 0;
    }
    pub fn next(self: *Model) void {
        if (self.matches.items.len > 0) self.current = (self.current + 1) % self.matches.items.len;
    }
    pub fn previous(self: *Model) void {
        if (self.matches.items.len > 0) self.current = if (self.current == 0) self.matches.items.len - 1 else self.current - 1;
    }
    pub fn count(self: *const Model) usize {
        return self.matches.items.len;
    }
    pub fn currentIndex(self: *const Model) ?usize {
        return if (self.matches.items.len == 0) null else self.current;
    }
    pub fn match(self: *const Model, index: usize) ?Match {
        return if (index < self.matches.items.len) self.matches.items[index] else null;
    }
    pub fn close(self: *Model) void {
        self.open = false;
    }
};

pub const Hooks = struct {
    context: ?*anyopaque = null,
    on_query: ?*const fn (?*anyopaque, []const u8) void = null,
    on_next: ?*const fn (?*anyopaque) void = null,
    on_previous: ?*const fn (?*anyopaque) void = null,
    on_close: ?*const fn (?*anyopaque) void = null,
};

/// Production search bar matching mockup-search: 360px, top-right, query input,
/// count and ↑/↓/✕ controls. Caller owns model and invokes refresh after source/query changes.
pub const View = struct {
    root: *ui.Node,
    input: *ui.Node,
    input_result: ui.widgets.input.InputResult,
    focus_ring: *ui.Node,
    actions: [3]*ui.Node,
    navigation_enabled: *ui.Signal(bool),
    count: *ui.Node,
    model: *Model,
    cx: *ui.Cx,
    pub fn refresh(self: *View) void {
        self.retheme();
        paintCount(self.cx, self.model, self.count, self.navigation_enabled);
    }
    /// Called by the owning terminal's global appearance publication, including
    /// hidden search bars. Only paint changes; the Input and query stay mounted.
    pub fn retheme(self: *View) void {
        const c = theme.current();
        self.root.setStyleInline(self.cx.allocator, styles.panelPaint());
        self.count.setTextColor(c.fg_2);
        styles.paintInput(self.cx, self.input_result, self.focus_ring);
        for (self.actions) |action| {
            action.setStyleInline(self.cx.allocator, styles.buttonPaint());
            tintIcons(action, c.fg_2);
        }
        self.cx.requestRedraw();
    }
    pub fn fitPane(self: *View, pane_width: f32) void {
        const width = @min(styles.panel_width, @max(0, pane_width - styles.pane_right * 2));
        if (self.root.style.width == .px and self.root.style.width.px == width) return;
        self.root.style.width = .{ .px = width };
        self.root.markLayoutDirty();
    }
    pub fn focus(self: *View) void {
        self.cx.setFocus(self.input_result.input_container);
    }
};
fn paintCount(cx: *ui.Cx, model: *Model, count: *ui.Node, navigation_enabled: *ui.Signal(bool)) void {
    var buffer: [64]u8 = undefined;
    const label = if (model.composing) "组字中" else if (model.query.items.len > 0 and model.count() == 0) "无匹配" else std.fmt.bufPrint(&buffer, "{d}/{d}", .{ if (model.currentIndex()) |index| index + 1 else @as(usize, 0), model.count() }) catch return;
    navigation_enabled.set(!model.composing and model.query.items.len > 0 and model.count() > 0);
    count.setTextContent(cx.allocator, label) catch {};
    count.markRenderDirty();
    cx.requestRedraw();
}
fn tintIcons(node: *ui.Node, color: ui.Color) void {
    if (node.getIcon() != null or node.getImage() != null) _ = node.setTint(color);
    for (node.children.items) |child| tintIcons(child, color);
}
pub fn mount(cx: *ui.Cx, scope: *ui.Scope, model: *Model, hooks: Hooks) !View {
    const panel = try ui.box(cx, styles.panel(), .{});
    panel.meta.ownership.meta.test_id = "terminal.search";
    const row = try ui.box(cx, styles.row(), .{});
    const sig = try scope.createText(model.query.items, .{});
    const navigation_enabled = try scope.createSignal(bool, model.query.items.len > 0 and model.count() > 0);
    const qctx = try cx.allocator.create(QueryCtx);
    qctx.* = .{ .hooks = hooks, .model = model, .allocator = cx.allocator, .cx = cx };
    try scope.onCleanup(QueryCtx, qctx, QueryCtx.cleanup);
    const input = try ui.widgets.Input(.{ .value = sig, .placeholder = "搜索当前会话…", .embedded = true, .placeholder_color = theme.current().fg_2, .on_change = cx.on(QueryCtx, qctx, QueryCtx.change) }).mountResult(scope, cx);
    styles.tuneInput(input);
    input.input_container.meta.ownership.meta.test_id = "terminal.search.query";
    input.input_container.behavior.interaction.a11y.?.label = "搜索当前会话";
    const focus_ring = try ui.box(cx, styles.focusRing(), .{});
    try input.node.appendChild(cx.allocator, focus_ring);
    qctx.input = input;
    qctx.focus_ring = focus_ring;
    qctx.original_focus = input.input_container.behavior.events.on_focus;
    qctx.original_blur = input.input_container.behavior.events.on_blur;
    input.input_container.behavior.events.on_focus = .{ .callback = QueryCtx.focused, .context = qctx };
    input.input_container.behavior.events.on_blur = .{ .callback = QueryCtx.blurred, .context = qctx };
    try row.appendChild(cx.allocator, input.node);
    const count = try ui.text(cx, "0/0", styles.counter());
    count.setStyleInline(cx.allocator, styles.counterBox());
    count.meta.ownership.meta.test_id = "terminal.search.count";
    qctx.count = count;
    qctx.navigation_enabled = navigation_enabled;
    panel.behavior.events.capture_context = @ptrCast(qctx);
    panel.behavior.events.on_event_capture = QueryCtx.key;
    panel.behavior.events.event_context = qctx;
    panel.behavior.events.on_event = QueryCtx.afterInput;
    try row.appendChild(cx.allocator, count);
    const previous = try button(cx, scope, ui.icons.chevron_up, "上一个匹配 · ⇧Enter", "terminal.search.previous", hooks.on_previous, hooks.context, navigation_enabled);
    const next = try button(cx, scope, ui.icons.chevron_down, "下一个匹配 · Enter", "terminal.search.next", hooks.on_next, hooks.context, navigation_enabled);
    const close = try button(cx, scope, ui.icons.x, "关闭搜索 · Esc", "terminal.search.close", hooks.on_close, hooks.context, null);
    for ([_]*ui.Node{ previous, next, close }) |action| try row.appendChild(cx.allocator, action);
    try panel.appendChild(cx.allocator, row);
    var view: View = .{ .root = panel, .input = input.node, .input_result = input, .focus_ring = focus_ring, .actions = .{ previous, next, close }, .navigation_enabled = navigation_enabled, .count = count, .model = model, .cx = cx };
    view.refresh();
    return view;
}
const QueryCtx = struct {
    hooks: Hooks,
    model: *Model,
    allocator: std.mem.Allocator,
    cx: *ui.Cx,
    input: ui.widgets.input.InputResult = undefined,
    focus_ring: *ui.Node = undefined,
    count: *ui.Node = undefined,
    navigation_enabled: *ui.Signal(bool) = undefined,
    original_focus: @TypeOf(@as(ui.Node, undefined).behavior.events.on_focus) = null,
    original_blur: @TypeOf(@as(ui.Node, undefined).behavior.events.on_blur) = null,
    fn focused(raw: *anyopaque) void {
        const self: *QueryCtx = @ptrCast(@alignCast(raw));
        if (self.original_focus) |handler| handler.invoke();
        styles.paintInput(self.cx, self.input, self.focus_ring);
    }
    fn blurred(raw: *anyopaque) void {
        const self: *QueryCtx = @ptrCast(@alignCast(raw));
        if (self.original_blur) |handler| handler.invoke();
        styles.paintInput(self.cx, self.input, self.focus_ring);
    }
    fn change(self: *QueryCtx, text: []const u8) void {
        if (self.input.state.imeIsComposing()) return;
        self.model.composing = false;
        self.model.setQuery(text) catch {};
        if (self.hooks.on_query) |f| f(self.hooks.context, text);
    }
    fn cleanup(self: *QueryCtx) void {
        self.allocator.destroy(self);
    }
    fn afterInput(event: ui.events.Event, raw: ?*anyopaque) ui.events.EventResult {
        const self: *QueryCtx = @ptrCast(@alignCast(raw orelse return .ignored));
        const composing = self.input.state.imeIsComposing();
        if (composing != self.model.composing) {
            self.model.composing = composing;
            paintCount(self.cx, self.model, self.count, self.navigation_enabled);
        }
        // Input's .handled deliberately bubbles. A search bar is a pointer
        // boundary: its editor and icon buttons must never select the PTY.
        return switch (event) {
            .mouse_down, .mouse_move, .mouse_up, .click, .scroll => .stop,
            else => .ignored,
        };
    }
    fn key(event: ui.events.Event, raw: ?*anyopaque) ui.events.EventResult {
        const self: *QueryCtx = @ptrCast(@alignCast(raw orelse return .ignored));
        if (event != .key_down) return .ignored;
        // Native Input owns composition; focused icon buttons own activation.
        if (!self.input.state.focused or self.input.state.imeIsComposing()) return .ignored;
        const key_event = event.key_down;
        if (key_event.key == .escape) {
            if (self.hooks.on_close) |callback| callback(self.hooks.context);
            return .stop;
        }
        if (key_event.key == .@"return") {
            if (key_event.modifiers.shift) {
                if (self.hooks.on_previous) |callback| callback(self.hooks.context);
            } else if (self.hooks.on_next) |callback| callback(self.hooks.context);
            return .stop;
        }
        return .ignored;
    }
};
const Click = struct {
    cb: *const fn (?*anyopaque) void,
    ctx: ?*anyopaque,
    allocator: std.mem.Allocator,
    fn cleanup(self: *Click) void {
        self.allocator.destroy(self);
    }
    fn run(raw: ?*anyopaque) void {
        const self: *Click = @ptrCast(@alignCast(raw.?));
        self.cb(self.ctx);
    }
};
fn button(cx: *ui.Cx, scope: *ui.Scope, icon: ui.SvgAsset, label: []const u8, test_id: []const u8, cb: ?*const fn (?*anyopaque) void, ctx: ?*anyopaque, enabled: ?*ui.Signal(bool)) !*ui.Node {
    var on_click: ?ui.Handler(void) = null;
    if (cb) |f| {
        const c = try cx.allocator.create(Click);
        c.* = .{ .cb = f, .ctx = ctx, .allocator = cx.allocator };
        on_click = ui.Cx.simpleHandler(Click.run, c);
        try scope.onCleanup(Click, c, Click.cleanup);
    }
    const disabled: ui.Source(bool) = if (enabled) |signal| .{ .derived = ui.not(signal) } else .{ .value = false };
    const n = try ui.widgets.Button(.{ .variant = .ghost, .icon_only = true, .icon_asset = icon, .icon_size = styles.action_icon_size, .icon_tint = theme.current().fg_2, .a11y_label = label, .base_style = styles.button(), .on_click = on_click, .disabled = disabled }).mount(scope, cx);
    n.setStyleInline(cx.allocator, styles.button());
    n.meta.ownership.meta.test_id = test_id;
    return n;
}

test "search model finds and cycles matches" {
    var m = Model.init(std.testing.allocator);
    defer m.deinit();
    try m.setSource("a crash crash");
    try m.setQuery("crash");
    try std.testing.expectEqual(@as(usize, 2), m.count());
    m.next();
    try std.testing.expectEqual(@as(usize, 1), m.currentIndex().?);
    m.previous();
    try std.testing.expectEqual(@as(usize, 0), m.currentIndex().?);
}
