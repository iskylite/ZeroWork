//! Scoped keyboard recording anchored to an existing shortcut chip.
const std = @import("std");
const ui = @import("ui");
const design = @import("../ui/design.zig");
const keys = @import("keybindings.zig");
pub const Callbacks = struct { context: *anyopaque, changed: *const fn (*anyopaque) void, dismiss: *const fn (*anyopaque) void };
pub fn mount(cx: *ui.Cx, scope: *ui.Scope, parent: *ui.Node, anchor: *ui.Node, map: *keys.Map, label: []const u8, callbacks: Callbacks) !*Recorder {
    var actions: []const keys.Action = &.{};
    const single = std.meta.stringToEnum(keys.Action, label);
    if (single == .recent_tab or single == .accept_completion) return error.FixedMouseRow;
    for (keys.rows) |row| if (std.mem.eql(u8, row.label, label)) {
        actions = row.actions;
        break;
    };
    if (actions.len == 0 and single == null) return error.FixedMouseRow;
    const self = try cx.allocator.create(Recorder);
    self.* = .{ .cx = cx, .scope = scope, .map = map, .draft = map.*, .actions = actions, .callbacks = callbacks, .anchor_id = anchor.id, .parent_id = parent.id, .root = undefined, .status = undefined };
    if (single) |action| {
        self.single_action[0] = action;
        self.actions = &self.single_action;
    }
    try scope.onCleanup(Recorder, self, Recorder.cleanup);
    self.root = try ui.box(cx, .{ .position = .absolute, .inset = .{ .left = .{ .px = 8 }, .top = .{ .px = 8 } }, .width = .{ .px = 240 }, .direction = .column, .gap = 6, .padding = .{ .left = 10, .right = 10, .top = 10, .bottom = 10 }, .background = ui.Color.hex(0xF7FFFB), .border = .{ .width = 0, .color = design.color.border, .radius = 8 }, .z_index = 110 }, .{});
    self.status = try ui.text(cx, "按下第一个键位；Esc 取消", .{ .font_size = 12, .color = design.color.fg });
    self.status.style.width = .fill();
    try self.root.appendChild(cx.allocator, self.status);
    self.root.behavior.events.event_context = @ptrCast(self);
    self.root.behavior.events.key_context = @ptrCast(self);
    self.root.behavior.events.on_key_down = Recorder.keyDown;
    self.root.setFocusable(true);
    try cx.addAfterLayoutHook(self, Recorder.reposition);
    return self;
}
pub const Recorder = struct {
    single_action: [1]keys.Action = .{.new_tab},
    cx: *ui.Cx,
    scope: *ui.Scope,
    map: *keys.Map,
    draft: keys.Map,
    actions: []const keys.Action,
    index: usize = 0,
    callbacks: Callbacks,
    root: *ui.Node,
    status: *ui.Node,
    anchor_id: u32,
    parent_id: u32,
    dismissed: bool = false,
    fn reposition(raw: *anyopaque, _: u8, _: bool) ui.AfterLayoutResult {
        const self: *Recorder = @ptrCast(@alignCast(raw));
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
        const width = @max(@as(f32, 1), @min(@as(f32, 240), p.w - 16));
        if (@abs(r.w - width) > 0.5) {
            self.root.style.width = .{ .px = width };
            self.root.markLayoutDirty();
            return .needs_layout;
        }
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
    fn cleanup(self: *Recorder) void {
        self.cx.removeAfterLayoutHook(self);
        self.scope.allocator.destroy(self);
    }
    /// Call after appending root, so this transient recorder owns key events.
    pub fn focus(self: *Recorder) void {
        self.cx.setFocus(self.root);
    }
    fn keyDown(key: ui.events.KeyCode, mods: ui.events.Modifiers, raw: ?*anyopaque) ui.events.EventResult {
        const self: *Recorder = @ptrCast(@alignCast(raw orelse return .ignored));
        if (key == .escape) {
            self.callbacks.dismiss(self.callbacks.context);
            return .stop;
        }
        switch (key) {
            .left_super, .right_super, .left_shift, .right_shift, .left_ctrl, .right_ctrl, .left_alt, .right_alt => return .stop,
            else => {},
        }
        const chord = keys.Chord{ .key = keys.fromKey(key), .command = mods.super, .control = mods.ctrl, .shift = mods.shift, .option = mods.alt };
        self.draft.set(self.actions[self.index], chord) catch |err| {
            self.root.style.border = .{ .width = 0, .color = design.color.danger, .radius = 8 };
            self.status.setTextContent(self.cx.allocator, if (err == error.Conflict) "键位冲突，请重录" else "⌃、Tab 与方向键保留给远端") catch {};
            self.cx.requestRedraw();
            return .stop;
        };
        self.index += 1;
        if (self.index == self.actions.len) {
            self.map.* = self.draft;
            const callbacks = self.callbacks;
            callbacks.changed(callbacks.context);
            callbacks.dismiss(callbacks.context);
            return .stop;
        }
        self.status.setTextContent(self.cx.allocator, "已录入，请按下下一个键位") catch {};
        self.cx.requestRedraw();
        return .stop;
    }
};

fn findNode(node: *ui.Node, id: u32) ?*ui.Node {
    if (node.id == id) return node;
    for (node.children.items) |child| if (findNode(child, id)) |found| return found;
    return null;
}
