const std = @import("std");
const ui = @import("ui");
const styles = @import("workspace_tab_styles.zig");
const theme = @import("app_theme.zig");

pub fn normalize(name: []const u8) ![]const u8 {
    const trimmed = std.mem.trim(u8, name, " \t\r\n");
    if (trimmed.len == 0) return error.EmptyName;
    if (trimmed.len > 64) return error.NameTooLong;
    if (!std.unicode.utf8ValidateSlice(trimmed)) return error.InvalidName;
    for (trimmed) |byte| if (byte < 0x20 or byte == 0x7f) return error.InvalidName;
    return trimmed;
}

pub const Hooks = struct {
    context: *anyopaque,
    anchor: ?*const fn (*anyopaque, u64) ?ui.ComputedRect = null,
    commit: *const fn (*anyopaque, u64, []const u8) bool,
    cancel: *const fn (*anyopaque, u64) void,
    change: ?*const fn (*anyopaque, u64, []const u8) void = null,
};

/// Scope-owned anchored editor. The captured ID is a TabId backing value; no
/// callback resolves a later active tab. Workspace disposes it after dispatch.
pub const Editor = struct {
    allocator: std.mem.Allocator,
    cx: *ui.Cx,
    node: *ui.Node,
    input: ui.widgets.input.InputResult,
    dialog: *ui.Node,
    body: *ui.Node,
    colors: theme.Colors,
    overlay: *ui.Node,
    hint: *ui.Node,
    value: *ui.Signal([]const u8),
    open: *ui.Signal(bool),
    session_id: u64,
    hooks: Hooks,
    finished: bool = false,
    has_error: bool = false,

    pub fn mount(cx: *ui.Cx, scope: *ui.Scope, session_id: u64, title: []const u8, hooks: Hooks) !*Editor {
        const self = try cx.allocator.create(Editor);
        var registered = false;
        errdefer if (!registered) cx.allocator.destroy(self);
        const value = try scope.createText(title, .{});
        const open = try scope.createSignal(bool, true);
        self.* = .{ .allocator = cx.allocator, .cx = cx, .node = undefined, .input = undefined, .dialog = undefined, .body = undefined, .colors = theme.current(), .overlay = undefined, .hint = undefined, .value = value, .open = open, .session_id = session_id, .hooks = hooks };
        try scope.onCleanup(Editor, self, cleanup);
        registered = true;
        const c = theme.current();
        const popup = try ui.widgets.Popover(.{ .open = open, .trigger = .manual, .anchor = .{ .virtual = .{ .ctx = self, .getRect = anchorRect } }, .position = .bottom_start, .offset = .{ .static = 6 }, .width = styles.rename_width, .max_height = styles.rename_height + 24, .constrain_width_to_viewport = true, .viewport_padding = 8, .shift_main_axis = true, .consume_outside_click = true, .a11y_role = .dialog, .on_open_change = cx.on(Editor, self, openChanged) }).mount(scope, cx);
        self.dialog = popup.chrome;
        self.body = try ui.box(cx, styles.renameBody(), .{});
        try popup.content.appendChild(cx.allocator, self.body);
        self.overlay = popup.wrapper;
        self.dialog.setStyleInline(cx.allocator, styles.renameDialog(self.has_error));
        self.dialog.meta.ownership.meta.test_id = "tabs.rename";
        try theme.bindMaterial(cx, scope, self.dialog, "overlay");
        self.body.setStyleInline(cx.allocator, styles.renameBody());
        const header = try ui.box(cx, styles.renameHeader(), .{});
        try header.appendChild(cx.allocator, try ui.iconTint(cx, ui.icons.pencil, c.accent, styles.renameIcon()));
        try header.appendChild(cx.allocator, try ui.text(cx, "重命名页签", styles.renameTitle()));
        try header.appendChild(cx.allocator, try ui.spacer(cx));
        const close = try ui.widgets.Button(.{ .variant = .ghost, .icon_only = true, .icon_asset = ui.icons.x, .icon_size = @as(f32, 16), .a11y_label = "取消重命名", .base_style = styles.renameClose(), .on_click = cx.on(Editor, self, cancel) }).mount(scope, cx);
        close.meta.ownership.meta.test_id = "tabs.rename.close";
        try header.appendChild(cx.allocator, close);
        try self.body.appendChild(cx.allocator, header);
        const body = try ui.box(cx, styles.renameContent(), .{});
        self.input = try ui.widgets.Input(.{ .value = value, .on_change = cx.on(Editor, self, change), .on_submit = cx.on(Editor, self, submit) }).mountResult(scope, cx);
        @import("app_theme.zig").styleInput(self.input);
        self.input.input_container.setStyleInline(cx.allocator, styles.renameField());
        styles.tuneInput(&self.input);
        self.node = self.input.input_container;
        self.node.meta.ownership.meta.test_id = "tabs.rename.input";
        self.input.node.behavior.events.capture_context = self;
        self.input.node.behavior.events.on_event_capture = onEvent;
        // Keep the compatibility capture entry on the actual focusable control.
        self.node.behavior.events.capture_context = self;
        self.node.behavior.events.on_event_capture = onEvent;
        try body.appendChild(cx.allocator, self.input.node);
        self.hint = try ui.text(cx, "", styles.renameHint());
        self.hint.setStyleInline(cx.allocator, .{ .width = .fill(), .height = .{ .px = 16 }, .display = .none, .flex_shrink = 0 });
        try body.appendChild(cx.allocator, self.hint);
        const buttons = try ui.box(cx, styles.renameActions(), .{});
        const cancel_button = try ui.widgets.Button(.{ .label = "取消", .variant = .secondary, .size = .sm, .base_style = styles.renameButton(62), .on_click = cx.on(Editor, self, cancel) }).mount(scope, cx);
        cancel_button.meta.ownership.meta.test_id = "tabs.rename.cancel";
        const save_button = try ui.widgets.Button(.{ .label = "保存名称", .variant = .primary, .size = .sm, .base_style = styles.renameButton(76), .on_click = cx.on(Editor, self, save) }).mount(scope, cx);
        save_button.meta.ownership.meta.test_id = "tabs.rename.save";
        try buttons.appendChild(cx.allocator, cancel_button);
        try buttons.appendChild(cx.allocator, save_button);
        try body.appendChild(cx.allocator, buttons);
        try self.body.appendChild(cx.allocator, body);
        if (cx.root) |root| try root.appendChild(cx.allocator, popup.wrapper);
        try cx.addAfterLayoutHook(self, afterLayout);
        return self;
    }
    fn anchorRect(raw: *anyopaque) ui.widgets.popover.AnchorRect {
        const self: *Editor = @ptrCast(@alignCast(raw));
        if (self.hooks.anchor) |resolve| if (resolve(self.hooks.context, self.session_id)) |rect| return .{ .x = rect.x, .y = rect.y, .w = rect.w, .h = rect.h };
        return .{ .x = 8, .y = 40, .w = 0, .h = 32 };
    }
    fn afterLayout(raw: *anyopaque, _: u8, _: bool) ui.AfterLayoutResult {
        const self: *Editor = @ptrCast(@alignCast(raw));
        if (!self.isVisible()) return .done;
        var needs_layout = false;
        const padding = self.body.style.padding;
        if (padding.top != 0 or padding.right != 0 or padding.bottom != 0 or padding.left != 0) {
            self.body.setStyleInline(self.allocator, styles.renameBody());
            self.dialog.setStyleInline(self.allocator, styles.renameDialog(self.has_error));
            needs_layout = true;
        }
        if (!std.meta.eql(self.colors, theme.current())) {
            styles.repaintRename(self.dialog, self.colors);
            self.colors = theme.current();
            self.dialog.setStyleInline(self.allocator, styles.renameDialog(self.has_error));
            self.input.input_container.setStyleInline(self.allocator, styles.renameField());
            needs_layout = true;
        }
        return if (needs_layout) .needs_layout else .done;
    }
    pub fn isVisible(self: *const Editor) bool {
        return self.open.peek() and !self.finished;
    }
    pub fn handleKey(self: *Editor, key: ui.events.KeyCode) ui.events.EventResult {
        if (!self.isVisible() or self.input.state.imeIsComposing()) return .ignored;
        switch (key) {
            .escape => self.cancel(),
            .@"return" => self.save(),
            else => return .ignored,
        }
        return .stop;
    }
    fn change(self: *Editor, name: []const u8) void {
        self.has_error = false;
        self.hint.setDisplay(.none);
        self.dialog.setStyleInline(self.allocator, styles.renameDialog(false));
        if (self.hooks.change) |callback| callback(self.hooks.context, self.session_id, name);
    }
    fn submit(self: *Editor, _: []const u8) void {
        self.save();
    }
    fn save(self: *Editor) void {
        if (!self.isVisible() or self.input.state.imeIsComposing()) return;
        const name = normalize(self.value.peek()) catch |err| {
            self.hint.setTextContent(self.allocator, switch (err) {
                error.EmptyName => "名称不能为空",
                error.NameTooLong => "名称不能超过 64 个 UTF-8 字节",
                else => "请输入有效的名称",
            }) catch {};
            self.showError();
            return;
        };
        if (self.hooks.commit(self.hooks.context, self.session_id, name)) {
            self.finished = true;
            self.open.set(false);
        } else {
            self.hint.setTextContent(self.allocator, "页签已变化，请重新打开重命名。") catch {};
            self.showError();
        }
    }
    fn showError(self: *Editor) void {
        self.has_error = true;
        self.hint.setDisplay(.flex);
        self.hint.setTextColor(theme.current().danger_ink);
        self.dialog.setStyleInline(self.allocator, styles.renameDialog(true));
    }
    fn cancel(self: *Editor) void {
        if (self.finished) return;
        self.finished = true;
        self.open.set(false);
        self.hooks.cancel(self.hooks.context, self.session_id);
    }
    fn openChanged(self: *Editor, open: bool) void {
        if (!open) self.cancel();
    }
    fn cleanup(self: *Editor) void {
        self.cx.removeAfterLayoutHook(self);
        self.allocator.destroy(self);
    }
    fn onEvent(event: ui.events.Event, raw: ?*anyopaque) ui.events.EventResult {
        const self: *Editor = @ptrCast(@alignCast(raw orelse return .ignored));
        return if (event == .key_down) self.handleKey(event.key_down.key) else .ignored;
    }
};

test "rename popover validates UTF8 and submits the captured tab once" {
    var cx = try ui.Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    const scope = try ui.Scope.init(std.testing.allocator, null, cx.owner);
    defer scope.dispose();
    const Sink = struct {
        id: u64 = 0,
        calls: usize = 0,
        cancels: usize = 0,
        fn commit(raw: *anyopaque, id: u64, name: []const u8) bool {
            const s: *@This() = @ptrCast(@alignCast(raw));
            std.debug.assert(std.mem.eql(u8, name, "生产"));
            s.id = id;
            s.calls += 1;
            return true;
        }
        fn cancel(raw: *anyopaque, id: u64) void {
            const s: *@This() = @ptrCast(@alignCast(raw));
            s.id = id;
            s.cancels += 1;
        }
    };
    const root = try ui.box(cx, .{ .width = .fill(), .height = .fill() }, .{});
    cx.root = root;
    var sink = Sink{};
    const editor = try Editor.mount(cx, scope, 91, "old", .{ .context = &sink, .commit = Sink.commit, .cancel = Sink.cancel });
    cx.setViewport(480, 400);
    cx.layout();
    try std.testing.expectApproxEqAbs(styles.rename_width, editor.dialog.globalRect().w, 0.01);
    try std.testing.expectApproxEqAbs(styles.rename_height, editor.dialog.globalRect().h, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 296), editor.node.globalRect().w, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 32), editor.node.globalRect().h, 0.01);
    const event = editor.node.behavior.events.on_event_capture.?;
    editor.value.set("   ");
    try std.testing.expectEqual(ui.events.EventResult.stop, event(.{ .key_down = .{ .key = .@"return", .modifiers = .{} } }, editor));
    try std.testing.expectEqual(@as(usize, 0), sink.calls);
    editor.value.set(" 生产 ");
    const input_event = editor.input.input_container.behavior.events.on_event.?;
    _ = input_event(.{ .ime_preedit = .{ .text = "sheng", .cursor_utf8_offset = 5 } }, editor.input.input_container.behavior.events.event_context);
    try std.testing.expectEqual(ui.events.EventResult.ignored, editor.handleKey(.@"return"));
    try std.testing.expectEqual(@as(usize, 0), sink.calls);
    _ = input_event(.{ .ime_preedit = .{ .text = "", .cursor_utf8_offset = 0 } }, editor.input.input_container.behavior.events.event_context);
    _ = event(.{ .key_down = .{ .key = .@"return", .modifiers = .{} } }, editor);
    try std.testing.expectEqual(@as(u64, 91), sink.id);
    try std.testing.expectEqual(@as(usize, 1), sink.calls);
    _ = event(.{ .key_down = .{ .key = .escape, .modifiers = .{} } }, editor);
    try std.testing.expectEqual(@as(usize, 0), sink.cancels);
    try std.testing.expectError(error.InvalidName, normalize("\xff"));
}

test "rename popover outer mount and theme keep prototype body and pointer actions" {
    const previous = theme.currentName();
    defer theme.select(previous);
    theme.select(.dark);
    var cx = try ui.Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    const scope = try ui.Scope.init(std.testing.allocator, null, cx.owner);
    defer scope.dispose();
    cx.setTheme(theme.widgetTheme(.dark));
    cx.setViewport(860, 480);
    const root = try ui.box(cx, .{ .width = .fill(), .height = .fill() }, .{});
    cx.root = root;
    const Capture = struct {
        calls: usize = 0,
        id: u64 = 0,
        fn commit(raw: *anyopaque, id: u64, name: []const u8) bool {
            const self: *@This() = @ptrCast(@alignCast(raw));
            std.debug.assert(std.mem.eql(u8, name, "original"));
            self.calls += 1;
            self.id = id;
            return true;
        }
        fn cancel(_: *anyopaque, _: u64) void {}
    };
    var capture = Capture{};
    cx.owner.enterMount();
    const editor = Editor.mount(cx, scope, 77, "original", .{ .context = &capture, .commit = Capture.commit, .cancel = Capture.cancel }) catch |err| {
        cx.owner.exitMount();
        return err;
    };
    cx.owner.exitMount();
    const body = editor.dialog.children.items[0];
    for ([_]theme.Name{ .dark, .light, .sauber }) |name| {
        theme.select(name);
        cx.setTheme(theme.widgetTheme(name));
        for (0..6) |_| {
            cx.frame_count += 1;
            cx.frame_time_ms += 16;
            _ = cx.render();
        }
        try std.testing.expectEqual(@as(f32, 0), body.style.padding.top);
        try std.testing.expectEqual(@as(f32, 0), body.style.padding.left);
        try std.testing.expectApproxEqAbs(styles.rename_width, editor.dialog.globalRect().w, 0.01);
        try std.testing.expectApproxEqAbs(styles.rename_height, editor.dialog.globalRect().h, 0.01);
        const input = editor.node.globalRect();
        const dialog = editor.dialog.globalRect();
        try std.testing.expectApproxEqAbs(@as(f32, 12), input.x - dialog.x, 0.01);
        try std.testing.expectApproxEqAbs(@as(f32, 36), input.y - dialog.y, 0.01);
    }
    const save = renameFind(editor.dialog, "tabs.rename.save").?;
    const rect = save.globalRect();
    cx.handleMouseDown(rect.x + rect.w / 2, rect.y + rect.h / 2, .{});
    cx.handleMouseUp(rect.x + rect.w / 2, rect.y + rect.h / 2);
    try std.testing.expectEqual(@as(usize, 1), capture.calls);
    try std.testing.expectEqual(@as(u64, 77), capture.id);
}
fn renameFind(root: *ui.Node, test_id: []const u8) ?*ui.Node {
    if (root.meta.ownership.meta.test_id) |id| if (std.mem.eql(u8, id, test_id)) return root;
    for (root.children.items) |child| if (renameFind(child, test_id)) |found| return found;
    return null;
}
