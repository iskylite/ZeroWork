//! The tab + menu opens local and saved sessions directly.
const std = @import("std");
const ui = @import("ui");
const S = @import("session_menu_styles.zig");
const identity = @import("../host/identity.zig");
pub const Saved = struct { owner: identity.AssetOwner, name: []const u8, icon: ui.SvgAsset };

pub const Callbacks = struct {
    context: *anyopaque,
    new_profile: *const fn (*anyopaque) void,
    quick: *const fn (*anyopaque) void,
    local: ?*const fn (*anyopaque) void = null,
    saved: ?*const fn (*anyopaque, identity.AssetOwner) void = null,
};
const Action = enum(usize) { local, quick, new_profile };
const labels = [_][]const u8{ "Local Terminal", "SSH / SFTP 快捷连接", "新建已保存连接" };
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
    saved_area: *ui.Node = undefined,
    saved_content: *ui.Node = undefined,
    saved_scroll: *ui.widgets.scroll_area.ScrollState = undefined,
    saved_scope: ?*ui.Scope = null,
    saved_rows: std.ArrayList(SavedRow) = .empty,
    selected_saved: ?usize = null,

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
        const icons = [_]ui.SvgAsset{ @import("session_icon.zig").resolve(.local), @import("quick_connect_icon.zig").asset, ui.icons.plus };
        for (labels, 0..) |label, index| {
            if (index == 1) {
                const area = try ui.widgets.ScrollArea(.{}).mount(self.scope, cx);
                area.container.setStyleInline(cx.allocator, .{ .width = .fill(), .height = .{ .px = 33 }, .max_height = 264, .flex_shrink = 0 });
                area.content.setStyleInline(cx.allocator, .{ .width = .fill(), .direction = .column });
                self.saved_scroll = area.state;
                self.saved_area = area.container;
                self.saved_content = area.content;
                try popup.content.appendChild(cx.allocator, area.container);
            }
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
        try self.setSaved(&.{});
        try cx.addAfterLayoutHook(self, afterLayout);
        return self;
    }
    pub fn show(self: *View, anchor: *ui.Node) !void {
        self.anchor_id = anchor.id;
        self.selected = if (self.callbacks.local != null) .local else .quick;
        self.chosen = false;
        self.selected_saved = null;
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
                const total = self.saved_rows.items.len + 3;
                const current = if (self.selected_saved) |i| i + 1 else switch (self.selected) {
                    .local => @as(usize, 0),
                    .quick => total - 2,
                    .new_profile => total - 1,
                };
                var next = if (key == .down) (current + 1) % total else (current + total - 1) % total;
                if (next == 0 and self.callbacks.local == null) next = if (key == .down) 1 else total - 1;
                self.selected_saved = if (next > 0 and next <= self.saved_rows.items.len) next - 1 else null;
                if (self.selected_saved) |i| {
                    self.cx.setFocus(self.saved_rows.items[i].button);
                    ui.widgets.scroll_area.scrollIntoView(self.saved_scroll, self.saved_content, self.saved_rows.items[i].button, .nearest);
                } else {
                    self.selected = if (next == 0) .local else if (next == total - 2) .quick else .new_profile;
                    self.cx.setFocus(self.buttons[@backingInt(self.selected)]);
                }
                self.paintSelection();
            },
            .@"return", .space => if (self.selected_saved) |i| self.activateSaved(self.saved_rows.items[i].owner) else self.activate(self.selected),
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
        for (self.saved_rows.items, 0..) |row, index| row.button.setBackground(if (self.selected_saved == index) S.theme.current().selection else ui.Color.TRANSPARENT);
        for (self.highlights, 0..) |highlight, index| {
            highlight.setBackground(S.theme.current().selection);
            highlight.setDisplay(if (self.selected_saved == null and index == @backingInt(self.selected)) .flex else .none);
        }
    }
    pub fn setSaved(self: *View, entries: []const Saved) !void {
        // Called before opening, never from one of the rows being replaced.
        self.selected_saved = null;
        while (self.saved_content.children.items.len > 0) {
            const child = self.saved_content.children.items[self.saved_content.children.items.len - 1];
            self.cx.detachChild(self.saved_content, child);
            self.cx.freeNode(child);
        }
        if (self.saved_scope) |scope| scope.dispose();
        self.saved_scope = try self.scope.childScope();
        const scope = self.saved_scope.?;
        self.saved_rows.clearRetainingCapacity();
        self.saved_scroll.scroll_y = 0;
        self.saved_content.setStyle(self.cx.allocator, .translate_y, 0);
        for (entries) |entry| {
            const action = try scope.createState(SavedAction, .{ .view = self, .owner = entry.owner });
            const button = try ui.widgets.Button(.{ .variant = .ghost, .a11y_label = entry.name, .base_style = S.row(), .hover_style = self.hover_style, .on_click = self.cx.on(SavedAction, action, SavedAction.choose) }).mount(scope, self.cx);
            button.setStyleInline(self.cx.allocator, S.row());
            button.meta.ownership.meta.test_id = "session.menu.saved";
            if (button.behavior.interaction.a11y) |*a| a.role = .menuitem;
            const content = try ui.box(self.cx, S.rowContent(), .{});
            const icon = try ui.iconTint(self.cx, entry.icon, S.theme.current().fg_2, .{ .width = .{ .px = 14 }, .height = .{ .px = 14 }, .flex_shrink = 0 });
            const label = try ui.text(self.cx, entry.name, S.label());
            try label.setTextContent(self.cx.allocator, entry.name);
            label.setStyleInline(self.cx.allocator, .{ .min_width = 0, .flex = 1 });
            try content.appendChild(self.cx.allocator, icon);
            try content.appendChild(self.cx.allocator, label);
            try button.appendChild(self.cx.allocator, content);
            try self.saved_content.appendChild(self.cx.allocator, button);
            try self.saved_rows.append(self.cx.allocator, .{ .owner = entry.owner, .button = button, .label = label, .icon = icon });
        }
        if (entries.len == 0) {
            const label = try ui.text(self.cx, "暂无已保存连接", S.label());
            label.meta.ownership.meta.test_id = "session.menu.empty";
            label.setStyleInline(self.cx.allocator, .{ .width = .fill(), .height = .{ .px = 33 }, .padding = .{ .left = 10, .top = 9 } });
            try self.saved_content.appendChild(self.cx.allocator, label);
        }
        self.saved_area.setStyle(self.cx.allocator, .height, .{ .px = @as(f32, @floatFromInt(@min(@max(entries.len, 1), 8))) * 33 });
    }
    fn activateSaved(self: *View, owner: identity.AssetOwner) void {
        if (!self.isOpen() or self.chosen) return;
        const callback = self.callbacks.saved orelse return;
        self.chosen = true;
        self.hide();
        callback(self.callbacks.context, owner);
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
        for (self.saved_rows.items) |row| {
            row.label.setTextColor(colors.fg_1);
            _ = row.icon.setTint(colors.fg_2);
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
        self.saved_rows.deinit(self.cx.allocator);
        self.cx.allocator.destroy(self);
    }
};
const SavedRow = struct { owner: identity.AssetOwner, button: *ui.Node, label: *ui.Node, icon: *ui.Node };
const SavedAction = struct {
    view: *View,
    owner: identity.AssetOwner,
    fn choose(self: *SavedAction) void {
        self.view.activateSaved(self.owner);
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
    try std.testing.expectApproxEqAbs(@as(f32, 153), r.h, 0.5);
    try std.testing.expect(r.x >= 8 and r.x + r.w <= 852.5);
}

test "saved session menu refreshes rows and captures stable owner" {
    const cx = try ui.Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    const scope = try ui.Scope.init(std.testing.allocator, null, cx.owner);
    defer scope.dispose();
    cx.setViewport(860, 480);
    cx.root = try ui.box(cx, .{ .width = .fill(), .height = .fill() }, .{});
    const anchor = try ui.box(cx, .{ .width = .{ .px = 24 }, .height = .{ .px = 24 } }, .{});
    try cx.root.?.appendChild(cx.allocator, anchor);
    const Capture = struct {
        owner: ?identity.AssetOwner = null,
        fn connect(raw: *anyopaque, owner: identity.AssetOwner) void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.owner = owner;
        }
        fn noop(_: *anyopaque) void {}
    };
    var capture: Capture = .{};
    const view = try View.mount(cx, scope, .{ .context = &capture, .local = Capture.noop, .quick = Capture.noop, .new_profile = Capture.noop, .saved = Capture.connect });
    try cx.root.?.appendChild(cx.allocator, view.root);
    const owner: identity.AssetOwner = .{ .id = @fromBackingInt(42), .revision = 7 };
    try view.setSaved(&.{.{ .owner = owner, .name = "Saved SSH", .icon = ui.icons.terminal }});
    try view.show(anchor);
    _ = view.handleKey(.down);
    try std.testing.expectEqual(@as(?usize, 0), view.selected_saved);
    _ = view.handleKey(.@"return");
    try std.testing.expectEqualDeep(owner, capture.owner.?);
    try std.testing.expect(!view.isOpen());
    try view.setSaved(&.{.{ .owner = .{ .id = @fromBackingInt(99), .revision = 2 }, .name = "Changed config", .icon = ui.icons.folder }});
    try std.testing.expectEqualStrings("Changed config", view.saved_rows.items[0].label.getText().?.content);
    var many: [12]Saved = undefined;
    for (&many) |*entry| entry.* = .{ .owner = owner, .name = "Saved row", .icon = ui.icons.terminal };
    try view.setSaved(&many);
    try view.show(anchor);
    try cx.setTestFrameStep(100);
    for (0..8) |_| {
        cx.advanceFrameClock();
        cx.layout();
        _ = cx.render();
    }
    try std.testing.expectApproxEqAbs(@as(f32, 264), view.saved_area.globalRect().h, 0.5);
    try std.testing.expect(view.chrome.globalRect().y + view.chrome.globalRect().h <= 472.5);
    view.hide();
    try view.setSaved(&.{});
    try std.testing.expectEqual(@as(usize, 0), view.saved_rows.items.len);
    try view.show(anchor);
    _ = view.handleKey(.down);
    try std.testing.expectEqual(Action.quick, view.selected);
}
