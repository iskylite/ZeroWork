//! V3 + menu: creation commands only. Saved asset search uses the existing quick-connect view.
const std = @import("std");
const ui = @import("ui");
const S = @import("session_menu_styles.zig");

pub const Callbacks = struct {
    context: *anyopaque,
    new_profile: *const fn (*anyopaque) void,
    quick: *const fn (*anyopaque) void,
    local: ?*const fn (*anyopaque) void = null,
};
const Action = enum(usize) { local, quick, new_profile };
const labels = [_][]const u8{ "本地终端 · zsh", "SSH / SFTP 快捷连接", "新建已保存连接" };
const ids = [_][]const u8{ "session.menu.local", "session.menu.quick", "session.menu.new_profile" };

pub const View = struct {
    cx: *ui.Cx,
    scope: *ui.Scope,
    callbacks: Callbacks,
    root: *ui.Node = undefined,
    chrome: *ui.Node = undefined,
    open: *ui.Signal(bool),
    hover_style: *ui.Signal(?ui.BoxStyle),
    anchor_id: ?u32 = null,
    selected: Action = .local,
    chosen: bool = false,
    paint_revision: u32 = 0,
    buttons: [3]*ui.Node = undefined,
    highlights: [3]*ui.Node = undefined,
    labels: [3]*ui.Node = undefined,
    icons: [3]*ui.Node = undefined,
    separator: *ui.Node = undefined,

    pub fn mount(cx: *ui.Cx, scope: *ui.Scope, callbacks: Callbacks) !*View {
        const self = try cx.allocator.create(View);
        var adopted = false;
        errdefer if (!adopted) cx.allocator.destroy(self);
        self.* = .{ .cx = cx, .scope = scope, .callbacks = callbacks, .open = try scope.createSignal(bool, false), .hover_style = try scope.createSignal(?ui.BoxStyle, .{ .background = S.theme.current().hover }) };
        try scope.onCleanup(View, self, cleanup);
        adopted = true;
        const popup = try ui.widgets.Popover(.{ .open = self.open, .trigger = .manual, .anchor = .{ .virtual = .{ .ctx = self, .getRect = anchorRect } }, .position = .bottom_start, .width = S.width, .max_width = S.width, .offset = .{ .static = 0 }, .viewport_padding = 8, .constrain_width_to_viewport = true, .shift_main_axis = true, .size_policy = .fit_content, .close_on_escape = true, .on_open_change = cx.on(View, self, openChanged) }).mount(scope, cx);
        self.scope = popup.scope;
        self.root = popup.wrapper;
        self.chrome = popup.chrome;
        self.chrome.setStyleInline(cx.allocator, S.panel());
        self.chrome.meta.ownership.meta.test_id = "session.menu";
        self.chrome.behavior.interaction.a11y = .{ .role = .menu, .label = "新建会话" };
        self.chrome.behavior.events.capture_context = self;
        self.chrome.behavior.events.on_event_capture = onEvent;
        const icons = [_]ui.SvgAsset{ ui.icons.terminal, @import("quick_connect_icon.zig").asset, ui.icons.plus };
        for (labels, 0..) |label, index| {
            if (index == 2) {
                const divider = try ui.box(cx, S.separator(), .{});
                self.separator = try ui.box(cx, .{ .width = .fill(), .height = .{ .px = 1 }, .background = S.theme.current().border, .flex_shrink = 0 }, .{});
                try divider.appendChild(cx.allocator, self.separator);
                try popup.content.appendChild(cx.allocator, divider);
            }
            const action = try self.scope.createState(Row, .{ .view = self, .action = @fromBackingInt(@intCast(index)) });
            const node = try ui.widgets.Button(.{ .a11y_label = label, .variant = .ghost, .disabled = index == 0 and callbacks.local == null, .base_style = S.row(), .hover_style = self.hover_style, .on_click = cx.on(Row, action, Row.choose) }).mount(self.scope, cx);
            node.setStyleInline(cx.allocator, S.row());
            node.meta.ownership.meta.test_id = ids[index];
            if (node.behavior.interaction.a11y) |*a| a.role = .menuitem;
            self.buttons[index] = node;
            const highlight = try ui.box(cx, S.highlight(), .{});
            try node.appendChild(cx.allocator, highlight);
            self.highlights[index] = highlight;
            const content = try ui.box(cx, S.rowContent(), .{});
            self.icons[index] = try ui.iconTint(cx, icons[index], S.theme.current().fg_2, .{ .width = .{ .px = 14 }, .height = .{ .px = 14 }, .flex_shrink = 0 });
            try content.appendChild(cx.allocator, self.icons[index]);
            self.labels[index] = try ui.text(cx, label, S.label());
            try content.appendChild(cx.allocator, self.labels[index]);
            try node.appendChild(cx.allocator, content);
            try popup.content.appendChild(cx.allocator, node);
        }
        try cx.addAfterLayoutHook(self, afterLayout);
        return self;
    }
    pub fn show(self: *View, anchor: *ui.Node) !void {
        self.anchor_id = anchor.id;
        self.selected = if (self.callbacks.local != null) .local else .quick;
        self.chosen = false;
        self.retheme();
        self.open.set(true);
        self.cx.setFocus(self.buttons[@backingInt(self.selected)]);
        self.cx.requestRedraw();
    }
    pub fn hide(self: *View) void {
        self.open.set(false);
        self.restoreFocus();
        self.cx.requestRedraw();
    }
    pub fn isOpen(self: *const View) bool {
        return self.open.peek();
    }
    pub fn handleKey(self: *View, key: ui.events.KeyCode) ui.events.EventResult {
        if (!self.isOpen()) return .ignored;
        switch (key) {
            .escape => self.hide(),
            .up, .down => {
                const current = @backingInt(self.selected);
                var next = if (key == .down) (current + 1) % 3 else (current + 2) % 3;
                if (next == 0 and self.callbacks.local == null) next = if (key == .down) 1 else 2;
                self.selected = @fromBackingInt(@intCast(next));
                self.paintSelection();
                self.cx.setFocus(self.buttons[next]);
            },
            .@"return", .space => self.activate(self.selected),
            else => return .ignored,
        }
        return .stop;
    }
    fn activate(self: *View, action: Action) void {
        if (!self.isOpen() or self.chosen or (action == .local and self.callbacks.local == null)) return;
        self.chosen = true;
        self.hide();
        switch (action) {
            .local => self.callbacks.local.?(self.callbacks.context),
            .quick => self.callbacks.quick(self.callbacks.context),
            .new_profile => self.callbacks.new_profile(self.callbacks.context),
        }
    }
    fn paintSelection(self: *View) void {
        for (self.highlights, 0..) |highlight, index| {
            highlight.setBackground(S.theme.current().selection);
            highlight.setDisplay(if (index == @backingInt(self.selected)) .flex else .none);
        }
    }
    fn retheme(self: *View) void {
        const colors = S.theme.current();
        self.chrome.setStyleInline(self.cx.allocator, S.panel());
        self.hover_style.set(.{ .background = colors.hover });
        self.separator.setBackground(colors.border);
        for (self.labels, self.icons) |label, icon| {
            label.setTextColor(colors.fg_1);
            _ = icon.setTint(colors.fg_2);
        }
        self.paintSelection();
        self.paint_revision = self.cx.theme_version;
    }
    fn openChanged(self: *View, open: bool) void {
        if (!open) self.restoreFocus();
    }
    fn restoreFocus(self: *View) void {
        if (self.anchorNode()) |node| self.cx.setFocus(node);
    }
    fn anchorNode(self: *View) ?*ui.Node {
        return find(self.cx.root orelse return null, self.anchor_id orelse return null);
    }
    fn anchorRect(raw: *anyopaque) ui.widgets.popover.AnchorRect {
        const self: *View = @ptrCast(@alignCast(raw));
        const r = (self.anchorNode() orelse return .{ .x = 0, .y = 0, .w = 0, .h = 0 }).globalRect();
        const shell = @import("shell_styles.zig");
        return .{ .x = r.x, .y = r.y, .w = r.w, .h = @max(r.h, shell.outer + shell.title_height - r.y) };
    }
    fn afterLayout(raw: *anyopaque, _: u8, _: bool) ui.AfterLayoutResult {
        const self: *View = @ptrCast(@alignCast(raw));
        if (!self.isOpen()) return .done;
        if (self.anchorNode() == null) self.hide() else if (self.paint_revision != self.cx.theme_version) self.retheme();
        return .done;
    }
    fn onEvent(event: ui.events.Event, raw: ?*anyopaque) ui.events.EventResult {
        const self: *View = @ptrCast(@alignCast(raw orelse return .ignored));
        return if (event == .key_down) self.handleKey(event.key_down.key) else .ignored;
    }
    fn cleanup(self: *View) void {
        self.cx.removeAfterLayoutHook(self);
        self.cx.allocator.destroy(self);
    }
};
const Row = struct {
    view: *View,
    action: Action,
    fn choose(self: *Row) void {
        self.view.activate(self.action);
    }
};
fn find(node: *ui.Node, id: u32) ?*ui.Node {
    if (node.id == id) return node;
    for (node.children.items) |child| if (find(child, id)) |result| return result;
    return null;
}

const Probe = struct {
    local: usize = 0,
    quick: usize = 0,
    saved: usize = 0,
    fn onLocal(raw: *anyopaque) void {
        const self: *Probe = @ptrCast(@alignCast(raw));
        self.local += 1;
    }
    fn onQuick(raw: *anyopaque) void {
        const self: *Probe = @ptrCast(@alignCast(raw));
        self.quick += 1;
    }
    fn onSaved(raw: *anyopaque) void {
        const self: *Probe = @ptrCast(@alignCast(raw));
        self.saved += 1;
    }
};
test "new session menu maps each creation command once and restores focus" {
    const cx = try ui.Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    const scope = try ui.Scope.init(std.testing.allocator, null, cx.owner);
    defer scope.dispose();
    cx.setViewport(860, 480);
    cx.root = try ui.box(cx, .{ .width = .fill(), .height = .fill() }, .{});
    const anchor = try ui.box(cx, .{ .width = .{ .px = 24 }, .height = .{ .px = 24 } }, .{});
    anchor.behavior.interaction.focusable = true;
    try cx.root.?.appendChild(cx.allocator, anchor);
    var probe: Probe = .{};
    const view = try View.mount(cx, scope, .{ .context = &probe, .local = Probe.onLocal, .quick = Probe.onQuick, .new_profile = Probe.onSaved });
    try cx.root.?.appendChild(cx.allocator, view.root);
    for ([_]Action{ .local, .quick, .new_profile }) |action| {
        try view.show(anchor);
        for (0..@backingInt(action)) |_| _ = view.handleKey(.down);
        _ = view.handleKey(.@"return");
        _ = view.handleKey(.@"return");
        try std.testing.expect(!view.isOpen());
        try std.testing.expect(cx.focused_node == anchor);
    }
    try std.testing.expectEqual(@as(usize, 1), probe.local);
    try std.testing.expectEqual(@as(usize, 1), probe.quick);
    try std.testing.expectEqual(@as(usize, 1), probe.saved);
    try view.show(anchor);
    _ = view.handleKey(.escape);
    try std.testing.expectEqual(@as(usize, 1), probe.local);
    const old_theme = S.theme.currentName();
    defer S.theme.select(old_theme);
    try view.show(anchor);
    const retained_id = view.chrome.id;
    S.theme.select(if (old_theme == .dark) .light else .dark);
    cx.setTheme(S.theme.widgetTheme(S.theme.currentName()));
    view.retheme();
    cx.layout();
    _ = cx.render();
    try std.testing.expectEqual(retained_id, view.chrome.id);
    try std.testing.expect(view.isOpen());
    try std.testing.expectEqual(S.theme.current().hover, view.hover_style.get().?.background.?);
    try std.testing.expectEqual(@as(usize, 1), probe.local);
    for ([_]S.theme.Name{ .light, .dark }) |target| {
        S.theme.select(target);
        cx.setTheme(S.theme.widgetTheme(target));
        view.retheme();
        cx.layout();
        _ = cx.render();
        for (view.labels) |label| try std.testing.expectEqual(S.theme.current().fg_1, label.getText().?.color);
        try std.testing.expectEqual(S.theme.current().hover, view.hover_style.get().?.background.?);
    }
    view.hide();
}
test "new session menu skips unavailable local command and clamps compact menu" {
    const cx = try ui.Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    const scope = try ui.Scope.init(std.testing.allocator, null, cx.owner);
    defer scope.dispose();
    cx.setViewport(860, 480);
    cx.root = try ui.box(cx, .{ .width = .fill(), .height = .fill(), .justify = .end, .direction = .row }, .{});
    const anchor = try ui.box(cx, .{ .width = .{ .px = 24 }, .height = .{ .px = 24 } }, .{});
    try cx.root.?.appendChild(cx.allocator, anchor);
    var probe: Probe = .{};
    const view = try View.mount(cx, scope, .{ .context = &probe, .quick = Probe.onQuick, .new_profile = Probe.onSaved });
    try cx.root.?.appendChild(cx.allocator, view.root);
    try view.show(anchor);
    _ = view.handleKey(.up);
    try std.testing.expectEqual(Action.new_profile, view.selected);
    _ = view.handleKey(.down);
    try std.testing.expectEqual(Action.quick, view.selected);
    view.activate(.local);
    try std.testing.expect(view.isOpen());
    try cx.setTestFrameStep(100);
    for (0..8) |_| {
        cx.advanceFrameClock();
        cx.layout();
        _ = cx.render();
    }
    const r = view.chrome.globalRect();
    try std.testing.expectApproxEqAbs(@as(f32, 210), r.w, 0.5);
    try std.testing.expectApproxEqAbs(@as(f32, 120), r.h, 0.5);
    try std.testing.expect(r.x >= 8 and r.x + r.w <= 852.5);
}
