//! Anchored transient chip editor; all commits enter the owned settings Controller.
const std = @import("std");
const ui = @import("ui");
const design = @import("../ui/design.zig");
const Controller = @import("settings_controller.zig").Controller;
const values = @import("settings_values.zig");
pub const Key = @import("settings_content_view.zig").Key;
pub const Callbacks = struct {
    context: *anyopaque,
    committed: *const fn (*anyopaque) void,
    dismiss: *const fn (*anyopaque) void,
    /// Native directory chooser must edit the same Controller, then refresh the host.
    choose_directory: *const fn (*anyopaque, *Controller, Key) void,
};
pub const Choice = struct { label: []const u8, value: []const u8 };
const fonts = [_]Choice{ .{ .label = "JetBrains Mono", .value = "JetBrains Mono" }, .{ .label = "Menlo", .value = "Menlo" }, .{ .label = "Monaco", .value = "Monaco" } };
const cursors = [_]Choice{ .{ .label = "█ Block", .value = "block" }, .{ .label = "▏ Bar", .value = "bar" }, .{ .label = "▁ Underline", .value = "underline" } };
const terms = [_]Choice{ .{ .label = "xterm-256color", .value = "xterm-256color" }, .{ .label = "xterm", .value = "xterm" }, .{ .label = "vt100", .value = "vt100" } };
const binds = [_]Choice{ .{ .label = "127.0.0.1", .value = "127.0.0.1" }, .{ .label = "0.0.0.0", .value = "0.0.0.0" } };
const permissions = [_]Choice{ .{ .label = "确认后执行", .value = "confirm" }, .{ .label = "自动执行", .value = "auto" } };
const formats = [_]Choice{ .{ .label = ".txt / .cast", .value = "txt_cast" }, .{ .label = ".txt", .value = "txt" }, .{ .label = ".cast", .value = "cast" } };
const conflicts = [_]Choice{.{ .label = "每次询问", .value = "ask" }};
pub fn choices(key: Key) []const Choice {
    if (std.mem.eql(u8, key.key, "font_family")) return &fonts;
    if (std.mem.eql(u8, key.key, "cursor_style")) return &cursors;
    if (std.mem.eql(u8, key.key, "term")) return &terms;
    if (std.mem.eql(u8, key.key, "socks_bind")) return &binds;
    if (std.mem.eql(u8, key.key, "permission_mode")) return &permissions;
    if (std.mem.eql(u8, key.key, "export_format")) return &formats;
    if (std.mem.eql(u8, key.key, "conflict_policy")) return &conflicts;
    return &.{};
}
/// overlay_parent coordinates are used to anchor below the clicked chip. The host
/// owns outside-click/Escape dismissal and disposes the picker scope with the node.
pub fn mount(cx: *ui.Cx, scope: *ui.Scope, overlay_parent: *ui.Node, anchor: *ui.Node, controller: *Controller, key: Key, callbacks: Callbacks) !*Picker {
    if (std.mem.eql(u8, key.key, "download_dir")) {
        callbacks.choose_directory(callbacks.context, controller, key);
        return error.NativeDirectoryPickerDelegated;
    }
    const self = try cx.allocator.create(Picker);
    self.* = .{ .cx = cx, .scope = scope, .controller = controller, .key = key, .callbacks = callbacks, .anchor_id = anchor.id, .parent_id = overlay_parent.id, .root = undefined, .body = undefined, .error_label = undefined };
    try scope.onCleanup(Picker, self, Picker.cleanup);
    self.root = try ui.box(cx, .{ .position = .absolute, .inset = .{ .left = .{ .px = 8 }, .top = .{ .px = 8 } }, .width = .{ .px = 220 }, .direction = .column, .gap = 4, .padding = .{ .left = 8, .right = 8, .top = 8, .bottom = 8 }, .background = ui.Color.hex(0xF7FFFB), .border = .{ .width = 0, .color = design.color.border, .radius = 8 }, .shadow = .{ .blur = 20, .offset_y = 8, .color = ui.Color.rgba(0, 0, 0, 35) }, .z_index = 100 }, .{});
    self.body = try ui.widgets.ScrollArea(.{ .width = 204 }).mount(scope, cx);
    try self.root.appendChild(cx.allocator, self.body.container);
    self.body.container.style.height = .{ .fit = .{} };
    self.body.content.style.gap = 4;
    for (choices(key)) |choice| {
        const row = try ui.box(cx, .{ .width = .fill(), .padding = .{ .left = 8, .right = 8, .top = 5, .bottom = 5 }, .border = .{ .width = 0, .color = design.color.border, .radius = 5 } }, .{});
        try row.appendChild(cx.allocator, try ui.text(cx, choice.label, .{ .font_size = 12, .color = design.color.fg }));
        const click = try cx.allocator.create(ChoiceClick);
        click.* = .{ .picker = self, .value = choice.value };
        try scope.onCleanup(ChoiceClick, click, ChoiceClick.cleanup);
        row.behavior.events.on_click = .{ .callback = ChoiceClick.run, .context = @ptrCast(click) };
        try self.body.content.appendChild(cx.allocator, row);
    }
    // Text/numeric editing commits on Enter; choices and custom values share validation.
    if (!std.mem.eql(u8, key.key, "permission_mode") and !std.mem.eql(u8, key.key, "conflict_policy") and !std.mem.eql(u8, key.key, "export_format") and !std.mem.eql(u8, key.key, "cursor_style") and !std.mem.eql(u8, key.key, "socks_bind")) {
        var buffer: [256]u8 = undefined;
        const initial = try editText(controller, key, &buffer);
        const input = try design.input(cx, scope, .{ .value = initial, .placeholder = "输入数值后按 Enter", .on_submit = cx.on(Picker, self, Picker.onSubmit) }, .{ .font_size = 12, .height = 28 });
        try self.body.content.appendChild(cx.allocator, input);
        self.input_node = findFocusable(input);
    }
    self.error_label = try ui.text(cx, "", .{ .font_size = 10, .color = design.color.danger });
    try self.body.content.appendChild(cx.allocator, self.error_label);
    try cx.addAfterLayoutHook(self, Picker.reposition);
    return self;
}
pub fn editText(controller: *Controller, key: Key, buffer: []u8) ![]const u8 {
    if (std.mem.eql(u8, key.key, "window_chunks")) return std.fmt.bufPrint(buffer, "{d} × {d}", .{ controller.model.value.transfer.window_chunks, controller.model.value.transfer.chunk_kb });
    if (std.mem.eql(u8, key.key, "reconnect_backoff")) {
        const v = controller.model.value.ssh.reconnect_backoff;
        return std.fmt.bufPrint(buffer, "[{d},{d},{d},{d},{d}]", .{ v[0], v[1], v[2], v[3], v[4] });
    }
    const current = values.read(controller.model.value, key.section, key.key) orelse return error.UnknownKey;
    return switch (current) {
        .text => |v| v,
        .unsigned => |v| std.fmt.bufPrint(buffer, "{d}", .{v}),
        .decimal => |v| std.fmt.bufPrint(buffer, "{d}", .{v}),
        else => error.InvalidType,
    };
}
pub fn commit(controller: *Controller, key: Key, text: []const u8) !void {
    const input = std.mem.trim(u8, text, " \t");
    if (std.mem.eql(u8, key.key, "window_chunks")) {
        var parts = std.mem.splitSequence(u8, input, "×");
        const chunks = try std.fmt.parseInt(u32, std.mem.trim(u8, parts.next().?, " "), 10);
        const size = try std.fmt.parseInt(u32, std.mem.trim(u8, parts.next() orelse return error.InvalidValue, " "), 10);
        if (parts.next() != null) return error.InvalidValue;
        // Validate both values before committing either to avoid a partial compound edit.
        var candidate = controller.model.value;
        try values.writeConfig(&candidate, "transfer", "window_chunks", .{ .unsigned = chunks });
        try values.writeConfig(&candidate, "transfer", "chunk_kb", .{ .unsigned = size });
        const owned = try @import("runtime_config.zig").Snapshot.init(controller.allocator, candidate);
        if (controller.draft) |*old| old.deinit();
        controller.draft = owned;
        controller.model.value = owned.value;
        controller.model.dirty = true;
        controller.last_error = null;
        return;
    }
    const current = values.read(controller.model.value, key.section, key.key) orelse return error.UnknownKey;
    const next: values.Value = switch (current) {
        .text => .{ .text = input },
        .unsigned => .{ .unsigned = try std.fmt.parseInt(u32, input, 10) },
        .decimal => .{ .decimal = try std.fmt.parseFloat(f32, input) },
        else => return error.InvalidType,
    };
    if (next == .decimal and !std.math.isFinite(next.decimal)) return error.InvalidValue;
    try controller.editKey(key.section, key.key, next);
}
pub const Picker = struct {
    cx: *ui.Cx,
    scope: *ui.Scope,
    controller: *Controller,
    key: Key,
    callbacks: Callbacks,
    root: *ui.Node,
    error_label: *ui.Node,
    body: ui.widgets.ScrollAreaResult,
    input_node: ?*ui.Node = null,
    focused: bool = false,
    anchor_id: u32,
    parent_id: u32,
    dismissed: bool = false,
    fn reposition(raw: *anyopaque, _: u8, _: bool) ui.AfterLayoutResult {
        const self: *Picker = @ptrCast(@alignCast(raw));
        if (self.dismissed or self.root.style.display == .none) return .done;
        const tree = self.cx.root orelse return .done;
        const anchor = findNode(tree, self.anchor_id) orelse {
            self.dismissed = true;
            self.callbacks.dismiss(self.callbacks.context);
            return .done;
        };
        const parent = findNode(tree, self.parent_id) orelse return .done;
        var ancestor: ?*ui.Node = anchor;
        while (ancestor) |n| : (ancestor = n.parent) if (n.style.display == .none) {
            self.dismissed = true;
            self.callbacks.dismiss(self.callbacks.context);
            return .done;
        };
        const a = anchor.globalRect();
        var clip_parent = anchor.parent;
        while (clip_parent) |clip| : (clip_parent = clip.parent) {
            if (clip.tag != .scroll) continue;
            const bounds = clip.globalRect();
            if (a.x + a.w <= bounds.x or a.x >= bounds.x + bounds.w or a.y + a.h <= bounds.y or a.y >= bounds.y + bounds.h) {
                self.dismissed = true;
                self.callbacks.dismiss(self.callbacks.context);
                return .done;
            }
        }
        const p = parent.globalRect();
        const r = self.root.globalRect();
        if (r.w <= 0 or r.h <= 0 or p.w <= 0 or p.h <= 0) return .done;
        const width = @max(@as(f32, 1), @min(@as(f32, 220), p.w - 16));
        const natural = self.body.content.globalRect().h + 16;
        const height = @max(@as(f32, 1), @min(natural, p.h - 16));
        if (@abs(r.w - width) > 0.5 or @abs(r.h - height) > 0.5) {
            self.root.style.width = .{ .px = width };
            self.root.style.height = .{ .px = height };
            self.body.container.style.width = .{ .px = @max(1, width - 16) };
            self.body.container.style.height = .{ .px = @max(1, height - 16) };
            self.root.markLayoutDirty();
            return .needs_layout;
        }
        if (!self.focused) if (self.input_node) |input| {
            const before = self.body.state.scroll_y;
            ui.widgets.scrollIntoView(self.body.state, self.body.content, input, .nearest);
            if (before != self.body.state.scroll_y) return .needs_layout;
            self.cx.setFocus(input);
            self.focused = true;
        };
        const left = std.math.clamp(a.x - p.x, @as(f32, 8), @max(@as(f32, 8), p.w - r.w - 8));
        const below = a.y - p.y + a.h + 4;
        const above = a.y - p.y - r.h - 4;
        const top = std.math.clamp(if (below + r.h <= p.h - 8) below else above, @as(f32, 8), @max(@as(f32, 8), p.h - r.h - 8));
        const ext = self.root.style.ensureExtPanic(self.cx.allocator);
        if (@abs(r.x - p.x - left) <= 0.5 and @abs(r.y - p.y - top) <= 0.5) return .done;
        ext.inset.left = .{ .px = left };
        ext.inset.top = .{ .px = top };
        self.root.markLayoutDirty();
        return .needs_layout;
    }
    fn cleanup(self: *Picker) void {
        self.cx.removeAfterLayoutHook(self);
        self.scope.allocator.destroy(self);
    }
    pub fn onSubmit(self: *Picker, text: []const u8) void {
        commit(self.controller, self.key, text) catch |err| {
            self.error_label.setTextContent(self.cx.allocator, @errorName(err)) catch {};
            self.error_label.markRenderDirty();
            self.cx.requestRedraw();
            return;
        };
        const callbacks = self.callbacks;
        callbacks.committed(callbacks.context);
        callbacks.dismiss(callbacks.context);
    }
};
const ChoiceClick = struct {
    picker: *Picker,
    value: []const u8,
    fn cleanup(self: *ChoiceClick) void {
        self.picker.scope.allocator.destroy(self);
    }
    fn run(raw: *anyopaque) void {
        const self: *ChoiceClick = @ptrCast(@alignCast(raw));
        self.picker.onSubmit(self.value);
    }
};

fn findNode(node: *ui.Node, id: u32) ?*ui.Node {
    if (node.id == id) return node;
    for (node.children.items) |child| if (findNode(child, id)) |found| return found;
    return null;
}

fn findFocusable(node: *ui.Node) ?*ui.Node {
    if (node.behavior.interaction.focusable) return node;
    for (node.children.items) |child| if (findFocusable(child)) |found| return found;
    return null;
}
