//! V3 shortcut recorder. Only explicit confirmation writes the outer settings draft.
const std = @import("std");
const ui = @import("ui");
const theme = @import("../ui/app_theme.zig");
const keys = @import("keybindings.zig");
pub const Callbacks = struct { context: *anyopaque, changed: *const fn (*anyopaque) void, dismiss: *const fn (*anyopaque) void };
pub fn mount(cx: *ui.Cx, scope: *ui.Scope, _: *ui.Node, _: *ui.Node, map: *keys.Map, label: []const u8, callbacks: Callbacks) !*Recorder {
    const action = std.meta.stringToEnum(keys.Action, label) orelse return error.FixedMouseRow;
    if (action == .recent_tab or action == .accept_completion) return error.FixedMouseRow;
    const self = try cx.allocator.create(Recorder);
    self.* = .{ .cx = cx, .map = map, .action = action, .draft = map.*, .callbacks = callbacks, .root = undefined, .status = undefined, .capture = undefined, .open = try scope.createSignal(bool, true), .invalid = try scope.createSignal(bool, true) };
    try scope.onCleanup(Recorder, self, Recorder.cleanup);
    const c = theme.current();
    const modal = try ui.widgets.Modal(.{ .open = self.open, .width = 390, .max_height = @max(@as(f32, 180), cx.viewport.height - 48), .background = c.overlay, .overlay_color = ui.Color.rgba(6, 6, 9, 153), .close_on_overlay = false, .enter_transition = .none, .exit_transition = .none, .on_open_change = cx.on(Recorder, self, Recorder.openChanged) }).mount(scope, cx);
    self.root = modal.overlay;
    self.portaled = modal.portaled;
    self.root.meta.ownership.meta.test_id = "settings.keybinding.overlay";
    modal.dialog.meta.ownership.meta.test_id = "settings.keybinding.dialog";
    if (modal.dialog.behavior.interaction.a11y) |*a| a.label = "录制快捷键";
    modal.dialog.setStyleInline(cx.allocator, .{ .padding = .{}, .gap = 0, .border = .{ .width = 0, .radius = 14 } });
    modal.body.setStyleInline(cx.allocator, .{ .padding = .{}, .gap = 0, .width = .fill(), .min_height = 0, .direction = .column });
    modal.dialog.behavior.events.key_context = @ptrCast(self);
    modal.dialog.behavior.events.on_key_down = Recorder.keyDown;
    const header = try ui.box(cx, .{ .width = .fill(), .min_height = 60, .padding = .{ .top = 16, .left = 20, .right = 20, .bottom = 10 }, .direction = .row, .align_items = .center, .gap = 8, .flex_shrink = 0 }, .{});
    header.meta.ownership.meta.test_id = "settings.keybinding.header";
    const title_icon = try ui.iconTint(cx, ui.icons.keyboard, c.accent, .{ .width = .{ .px = 18 }, .height = .{ .px = 18 }, .flex_shrink = 0 });
    title_icon.meta.ownership.meta.test_id = "settings.keybinding.title.icon";
    try header.appendChild(cx.allocator, title_icon);
    const title = try ui.text(cx, "录制快捷键", .{ .font_size = 13, .font_weight = 650, .line_height = 20.0 / 13.0, .color = c.fg_1 });
    title.style.width = .fill();
    title.style.flex = 1;
    try header.appendChild(cx.allocator, title);
    try header.appendChild(cx.allocator, try self.button(scope, "✕", "settings.keybinding.close", Recorder.cancel, false, false));
    try modal.body.appendChild(cx.allocator, header);
    const body = try ui.widgets.ScrollArea(.{ .padding = .{ .top = 8, .left = 20, .right = 20, .bottom = 18 } }).mount(scope, cx);
    body.container.setStyleInline(cx.allocator, .{ .width = .fill(), .height = .{ .fit = .{} }, .min_height = 0, .flex_shrink = 1 });
    body.container.meta.ownership.meta.test_id = "settings.keybinding.body";
    body.content.style.gap = 12;
    try body.content.appendChild(cx.allocator, try ui.text(cx, actionName(action), .{ .font_size = 12, .line_height = 20.0 / 12.0, .color = c.fg_2 }));
    const well = try ui.box(cx, .{ .width = .fill(), .padding = .{ .top = 24, .right = 24, .bottom = 24, .left = 24 }, .align_items = .center, .justify = .center, .background = c.well, .border = .{ .radius = 8 }, .flex_shrink = 0 }, .{});
    well.meta.ownership.meta.test_id = "settings.keybinding.capture";
    self.capture = try ui.text(cx, "请按下快捷键组合", .{ .font_size = 20, .color = c.fg_1 });
    self.capture.meta.ownership.meta.test_id = "settings.keybinding.recorded";
    try well.appendChild(cx.allocator, self.capture);
    well.setFocusable(true);
    self.focus_node = well;
    try body.content.appendChild(cx.allocator, well);
    self.status = try ui.text(cx, "", .{ .font_size = 12, .line_height = 20.0 / 12.0, .color = c.danger, .wrap = .word });
    self.status.style.width = .fill();
    self.status.setDisplay(.none);
    self.status.meta.ownership.meta.test_id = "settings.keybinding.error";
    try body.content.appendChild(cx.allocator, self.status);
    const help = try ui.text(cx, "使用 Command 组合；Control 与 Tab 保留给远端。", .{ .font_size = 12, .line_height = 20.0 / 12.0, .color = c.fg_2, .wrap = .word });
    help.style.width = .fill();
    try body.content.appendChild(cx.allocator, help);
    try modal.body.appendChild(cx.allocator, body.container);
    const footer = try ui.box(cx, .{ .width = .fill(), .direction = .row, .justify = .end, .gap = 8, .padding = .{ .top = 12, .left = 20, .right = 20, .bottom = 16 }, .flex_shrink = 0 }, .{});
    footer.meta.ownership.meta.test_id = "settings.keybinding.footer";
    try footer.appendChild(cx.allocator, try self.button(scope, "取消", "settings.keybinding.cancel", Recorder.cancel, false, false));
    try footer.appendChild(cx.allocator, try self.button(scope, "恢复默认", "settings.keybinding.reset", Recorder.reset, false, false));
    // Runtime Map currently has no unbound value; keep this unavailable honestly.
    const unavailable = try ui.widgets.Tooltip(.{ .text = "当前运行时不支持解除绑定", .open_delay_ms = 450 }).mount(scope, cx);
    try unavailable.trigger.appendChild(cx.allocator, try self.button(scope, "解除绑定", "settings.keybinding.unbind", Recorder.cancel, false, true));
    try footer.appendChild(cx.allocator, unavailable.wrapper);
    try footer.appendChild(cx.allocator, try self.button(scope, "使用快捷键", "settings.keybinding.confirm", Recorder.confirm, true, false));
    try modal.body.appendChild(cx.allocator, footer);
    return self;
}
pub const Recorder = struct {
    cx: *ui.Cx,
    map: *keys.Map,
    action: keys.Action,
    draft: keys.Map,
    callbacks: Callbacks,
    root: *ui.Node,
    status: *ui.Node,
    capture: *ui.Node,
    focus_node: *ui.Node = undefined,
    open: *ui.Signal(bool),
    invalid: *ui.Signal(bool),
    portaled: bool = false,
    dismissed: bool = false,
    fn cleanup(self: *Recorder) void {
        self.cx.allocator.destroy(self);
    }
    /// Host calls this before hiding the overlay, so Modal releases its focus scope.
    pub fn close(self: *Recorder) void {
        self.open.set(false);
        self.dismissed = true;
    }
    pub fn focus(self: *Recorder) void {
        self.cx.setFocus(self.focus_node);
    }
    fn openChanged(self: *Recorder, value: bool) void {
        if (!value and !self.dismissed) {
            self.dismissed = true;
            self.callbacks.dismiss(self.callbacks.context);
        }
    }
    fn cancel(self: *Recorder) void {
        self.close();
        self.callbacks.dismiss(self.callbacks.context);
    }
    pub fn confirm(self: *Recorder) void {
        if (self.invalid.peek() or self.dismissed) return;
        self.map.* = self.draft;
        self.close();
        self.callbacks.changed(self.callbacks.context);
        self.callbacks.dismiss(self.callbacks.context);
    }
    fn reset(self: *Recorder) void {
        self.record((keys.Map{}).get(self.action));
        self.focus();
    }
    fn button(self: *Recorder, scope: *ui.Scope, label: []const u8, comptime id: []const u8, comptime action: *const fn (*Recorder) void, primary: bool, disabled: bool) !*ui.Node {
        const c = theme.current();
        const is_close = comptime std.mem.eql(u8, id, "settings.keybinding.close");
        const n = try ui.widgets.Button(.{ .label = if (is_close) "" else label, .icon_only = is_close, .icon_asset = @as(?ui.SvgAsset, if (is_close) ui.icons.x else null), .icon_size = @as(f32, 16), .a11y_label = if (is_close) "关闭快捷键录制" else label, .variant = @as(ui.widgets.ButtonVariant, if (is_close) .ghost else if (primary) .primary else .secondary), .disabled = if (primary) ui.Source(bool){ .signal = self.invalid } else ui.Source(bool){ .value = disabled }, .on_click = self.cx.on(Recorder, self, action), .base_style = .{ .height = .{ .px = if (is_close) 30 else 32 }, .width = if (is_close) .{ .px = 30 } else .{ .fit = .{} }, .padding = .{ .left = if (is_close) 0 else 10, .right = if (is_close) 0 else 10 }, .font_size = 12, .border = .{ .radius = 8, .width = 0 }, .background = if (is_close) ui.Color.TRANSPARENT else if (primary) c.accent else c.hover, .text_color = if (primary) ui.Color.WHITE else c.fg_1 } }).mount(scope, self.cx);
        n.meta.ownership.meta.test_id = id;
        return n;
    }
    fn record(self: *Recorder, chord: keys.Chord) void {
        var candidate = self.draft;
        var buffer: [96]u8 = undefined;
        const shown = chordText(chord, &buffer) catch "?";
        self.capture.setTextContent(self.cx.allocator, shown) catch {};
        candidate.set(self.action, chord) catch |err| {
            self.invalid.set(true);
            self.status.setDisplay(.flex);
            var error_buffer: [160]u8 = undefined;
            const message = if (err == error.Conflict) std.fmt.bufPrint(&error_buffer, "已用于“{s}”，请重新录制。", .{actionName(self.draft.conflict(self.action, chord).?)}) catch "键位冲突，请重新录制。" else "请使用 Command 组合，Control 与 Tab 保留给远端。";
            self.status.setTextContent(self.cx.allocator, message) catch {};
            self.cx.requestRedraw();
            return;
        };
        self.draft = candidate;
        self.invalid.set(false);
        self.status.setDisplay(.none);
        self.cx.requestRedraw();
    }
    fn keyDown(key: ui.events.KeyCode, mods: ui.events.Modifiers, raw: ?*anyopaque) ui.events.EventResult {
        const self: *Recorder = @ptrCast(@alignCast(raw orelse return .ignored));
        if (self.dismissed) return .ignored;
        if (self.cx.focus_manager.getFocused()) |focused| if (focused.behavior.interaction.text_input_client) |client| if (client.is_composing) |composing| if (composing(client.context)) return .ignored;
        if (key == .tab) return .ignored;
        if (key == .escape) {
            self.cancel();
            return .stop;
        }
        switch (key) {
            .left_super, .right_super, .left_shift, .right_shift, .left_ctrl, .right_ctrl, .left_alt, .right_alt => return .stop,
            else => {},
        }
        self.record(.{ .key = keys.fromKey(key), .command = mods.super, .control = mods.ctrl, .shift = mods.shift, .option = mods.alt });
        return .stop;
    }
};
fn chordText(chord: keys.Chord, buffer: []u8) ![]const u8 {
    var upper: [32]u8 = undefined;
    const raw = @tagName(chord.key);
    for (raw, 0..) |char, i| upper[i] = std.ascii.toUpper(char);
    const name = switch (chord.key) {
        .space => "Space",
        .semicolon => ";",
        .left_bracket => "[",
        .right_bracket => "]",
        .slash => "/",
        .minus => "-",
        .equal => "=",
        .period => ".",
        .comma => ",",
        .quote => "'",
        .backslash => "\\",
        .grave => "`",
        .@"return" => "↩",
        .delete => "⌫",
        else => upper[0..raw.len],
    };
    return std.fmt.bufPrint(buffer, "{s}{s}{s}{s}{s}", .{ if (chord.command) "⌘" else "", if (chord.control) "⌃" else "", if (chord.shift) "⇧" else "", if (chord.option) "⌥" else "", name });
}
fn actionName(action: keys.Action) []const u8 {
    return switch (action) {
        .new_tab => "新建页签",
        .close_tab => "关闭页签",
        .tab_1 => "直达第 1 个页签",
        .tab_2 => "直达第 2 个页签",
        .tab_3 => "直达第 3 个页签",
        .tab_4 => "直达第 4 个页签",
        .tab_5 => "直达第 5 个页签",
        .tab_6 => "直达第 6 个页签",
        .tab_7 => "直达第 7 个页签",
        .tab_8 => "直达第 8 个页签",
        .tab_9 => "直达第 9 个页签",
        .previous_tab => "上一个页签",
        .next_tab => "下一个页签",
        .split_vertical => "垂直分栏",
        .split_horizontal => "水平分栏",
        .copy => "复制",
        .paste => "粘贴",
        .search => "搜索当前终端",
        .completion => "打开补全菜单",
        .quick_connect => "快速连接",
        .reconnect => "立即重连",
        .sidebar => "显示或隐藏侧栏",
        .ai => "显示或隐藏 AI 辅助",
        .upload => "上传面板",
        .broadcast => "广播输入",
        else => "此快捷键不可修改",
    };
}
