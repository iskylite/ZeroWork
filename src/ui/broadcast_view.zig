//! V3 member list over the existing captured, single-source broadcast approval.
const std = @import("std");
const ui = @import("ui");
const S = @import("broadcast_styles.zig");
const Handle = @import("../host/identity.zig").SessionHandle;
pub const Member = struct { id: u64, owner: ?Handle = null, name: []const u8, endpoint: []const u8, source: bool = false, selected: bool = false, available: bool = false, unavailable_reason: []const u8 = "不可用" };
pub const Snapshot = struct { group: u32, name: []const u8, running: bool, can_enable: bool, members: []const Member };
const Owned = struct {
    arena: std.heap.ArenaAllocator,
    snapshot: Snapshot,
    fn init(allocator: std.mem.Allocator, source: Snapshot) !Owned {
        var self: Owned = .{ .arena = .init(allocator), .snapshot = source };
        errdefer self.arena.deinit();
        const a = self.arena.allocator();
        self.snapshot.name = try a.dupe(u8, source.name);
        const members = try a.dupe(Member, source.members);
        self.snapshot.members = members;
        for (members) |*member| {
            member.name = try a.dupe(u8, member.name);
            member.endpoint = try a.dupe(u8, member.endpoint);
            member.unavailable_reason = try a.dupe(u8, member.unavailable_reason);
        }
        return self;
    }
};
pub const View = struct {
    cx: *ui.Cx,
    scope: *ui.Scope,
    root: *ui.Node,
    open: *ui.Signal(bool),
    content: *ui.Node,
    control: *ui.Node,
    control_label: *ui.Signal([]const u8),
    control_style: *ui.Signal(@FieldType(ui.widgets.ControlShellConfig, "style")),
    disabled: *ui.Signal(bool),
    control_hover: *ui.Signal(?@FieldType(ui.widgets.ControlShellConfig, "style")),
    render_scope: ?*ui.Scope = null,
    current: ?Owned = null,
    pending: ?Owned = null,
    anchor_id: ?u32 = null,
    anchor_rect: ui.widgets.popover.AnchorRect = .{ .x = 8, .y = 8, .w = 0, .h = 0 },
    focus_member: ?u64 = null,
    requested: bool = false,
    group_id: u32 = 0,
    running: bool = false,
    hooks: struct { context: *anyopaque, resolve: *const fn (*anyopaque, u32, bool) void, select: ?*const fn (*anyopaque, u32, Handle, bool) void = null },

    pub fn mount(cx: *ui.Cx, scope: *ui.Scope, hooks: @FieldType(View, "hooks")) !*View {
        const self = try cx.allocator.create(View);
        self.* = .{ .cx = cx, .scope = undefined, .root = undefined, .open = try scope.createSignal(bool, false), .content = undefined, .control = undefined, .control_label = try scope.createText("开启广播", .{}), .control_style = try scope.createSignal(@FieldType(ui.widgets.ControlShellConfig, "style"), S.control(true)), .disabled = try scope.createSignal(bool, false), .control_hover = try scope.createSignal(?@FieldType(ui.widgets.ControlShellConfig, "style"), S.controlHover(true)), .hooks = hooks };
        try scope.onCleanup(View, self, cleanup);
        const popup = try ui.widgets.Popover(.{ .trigger = .manual, .position = .top_end, .open = self.open, .width = S.width, .max_height = S.maximum_height, .offset = .{ .static = @as(f32, 6) }, .constrain_width_to_viewport = true, .viewport_padding = 8, .on_open_change = cx.on(View, self, changed), .anchor = .{ .virtual = .{ .ctx = self, .getRect = anchorRect } } }).mount(scope, cx);
        self.scope = popup.scope;
        self.root = popup.content;
        self.root.setStyleInline(cx.allocator, S.panel());
        try cx.root.?.appendChild(cx.allocator, popup.wrapper);
        self.root.meta.ownership.meta.test_id = "group.broadcast.card";
        const head = try ui.box(cx, S.header(), .{});
        try head.appendChild(cx.allocator, try ui.iconTint(cx, ui.icons.get("radio").?, S.theme.current().accent, .{ .width = .{ .px = 16 }, .height = .{ .px = 16 } }));
        try head.appendChild(cx.allocator, try ui.text(cx, "输入广播", S.text(true)));
        try head.appendChild(cx.allocator, try ui.spacer(cx));
        const close = try ui.widgets.Button(.{ .icon_only = true, .icon_asset = ui.icons.x, .variant = .ghost, .a11y_label = "收起广播信息", .base_style = S.close(), .hover_style = S.controlHover(false), .on_click = cx.on(View, self, hide) }).mount(self.scope, cx);
        close.meta.ownership.meta.test_id = "group.broadcast.close";
        try head.appendChild(cx.allocator, close);
        try self.root.appendChild(cx.allocator, head);
        const scroll = try ui.widgets.ScrollArea(.{ .direction = .vertical, .rubber_band_y = false }).mount(self.scope, cx);
        scroll.container.setStyleInline(cx.allocator, .{ .width = .fill(), .height = .fill(), .min_height = 0 });
        scroll.container.meta.ownership.meta.test_id = "group.broadcast.viewport";
        scroll.content.setStyleInline(cx.allocator, S.body());
        self.content = scroll.content;
        try self.root.appendChild(cx.allocator, scroll.container);
        const footer = try ui.box(cx, S.row(), .{});
        footer.meta.ownership.meta.test_id = "group.broadcast.footer";
        const minimum = try ui.text(cx, "至少 2 个在线会话", S.text(false));
        minimum.setStyleInline(cx.allocator, .{ .width = .fill(), .flex = 1, .min_width = 0, .height = .{ .px = 16 } });
        try footer.appendChild(cx.allocator, minimum);
        self.control = try ui.widgets.Button(.{ .label = self.control_label, .variant = .primary, .base_style = self.control_style, .hover_style = self.control_hover, .disabled = self.disabled, .on_click = cx.on(View, self, accept) }).mount(self.scope, cx);
        self.control.meta.ownership.meta.test_id = "group.broadcast.accept";
        try footer.appendChild(cx.allocator, self.control);
        try self.root.appendChild(cx.allocator, footer);
        try @import("compact_overlay_layout.zig").mount(cx, self.scope, self.root, scroll.container, scroll.content, S.fixed_height, S.maximum_height - S.fixed_height, null, 0);
        try cx.addAfterLayoutHook(self, afterLayout);
        return self;
    }
    pub fn show(self: *View, snapshot: Snapshot, trigger: *ui.Node) !void {
        var owned = try Owned.init(self.cx.allocator, snapshot);
        errdefer owned.arena.deinit();
        if (self.pending) |*old| old.arena.deinit();
        self.pending = owned;
        self.group_id = snapshot.group;
        self.running = snapshot.running;
        self.anchor_id = trigger.id;
        self.control_label.set(if (snapshot.running) "关闭广播" else "开启广播");
        self.control_style.set(S.control(true));
        self.control_hover.set(S.controlHover(true));
        self.disabled.set(!snapshot.running and !snapshot.can_enable);
        if (!self.open.peek()) self.requested = true;
        self.root.markLayoutDirty();
        self.cx.requestRedraw();
    }
    fn afterLayout(raw: *anyopaque, _: u8, _: bool) ui.AfterLayoutResult {
        const self: *View = @ptrCast(@alignCast(raw));
        if (self.pending != null) {
            self.render() catch return .done;
            return .needs_layout;
        }
        if (!self.open.peek() and !self.requested) return .done;
        const trigger = find(self.cx.root orelse return .done, self.anchor_id orelse return .done) orelse {
            self.dismiss();
            return .done;
        };
        if (!trigger.isDisplayedInTree() or trigger.globalRect().w <= 0) {
            if (self.open.peek()) self.dismiss();
            return .done;
        }
        const rect = trigger.globalRect();
        const next: ui.widgets.popover.AnchorRect = .{ .x = rect.x, .y = rect.y, .w = rect.w, .h = rect.h };
        if (self.requested) {
            self.requested = false;
            self.anchor_rect = next;
            self.root.setDisplay(.flex);
            self.open.set(true);
            self.cx.setFocus(self.control);
            self.cx.requestRedraw();
            return .needs_layout;
        }
        if (!std.meta.eql(next, self.anchor_rect)) {
            self.anchor_rect = next;
            self.root.markLayoutDirty();
            self.cx.requestRedraw();
            return .needs_layout;
        }
        return .done;
    }
    fn render(self: *View) !void {
        self.cx.invalidateReferencesTo(self.content);
        if (self.render_scope) |old| old.dispose();
        self.render_scope = null;
        while (self.content.children.items.len > 0) {
            const child = self.content.children.items[self.content.children.items.len - 1];
            self.cx.detachChild(self.content, child);
            self.cx.destroyDetached(child);
        }
        if (self.current) |*old| old.arena.deinit();
        self.current = self.pending;
        self.pending = null;
        const scope = try self.scope.childScope();
        self.render_scope = scope;
        const snapshot = self.current.?.snapshot;
        var count: usize = 0;
        for (snapshot.members) |member| if (member.selected) {
            count += 1;
        };
        const summary = try ui.text(self.cx, try std.fmt.allocPrint(self.current.?.arena.allocator(), "{s} · {s} · {d} 个参与会话", .{ snapshot.name, if (snapshot.running) @as([]const u8, "已开启") else "已关闭", count }), S.text(false));
        summary.setStyleInline(self.cx.allocator, .{ .width = .fill(), .height = .{ .px = 16 }, .min_width = 0 });
        summary.meta.ownership.meta.test_id = "group.broadcast.summary";
        try self.content.appendChild(self.cx.allocator, summary);
        const members = try ui.box(self.cx, .{ .width = .fill(), .height = .{ .fit = .{} }, .direction = .column, .gap = 7, .flex_shrink = 0 }, .{});
        for (snapshot.members) |member| {
            const row = try ui.box(self.cx, S.member(), .{});
            row.meta.ownership.meta.test_id = try std.fmt.allocPrint(self.current.?.arena.allocator(), "group.broadcast.member.{d}", .{member.id});
            const action = try scope.createState(Selection, .{ .view = self, .group = snapshot.group, .owner = member.owner, .id = member.id });
            const selected = try scope.createSignal(bool, member.selected);
            const check = try ui.widgets.Checkbox(.{ .checked = ui.split(selected, self.cx.on(Selection, action, Selection.changed)), .disabled = member.source or !member.available, .box_size = @as(f32, 14) }).mount(scope, self.cx);
            check.meta.ownership.meta.test_id = try std.fmt.allocPrint(self.current.?.arena.allocator(), "group.broadcast.member.{d}.select", .{member.id});
            if (check.behavior.interaction.a11y) |*attrs| attrs.label = member.name;
            try row.appendChild(self.cx.allocator, check);
            const dot = try ui.box(self.cx, .{ .width = .{ .px = 5 }, .height = .{ .px = 5 }, .background = if (member.available) S.theme.current().ok else S.theme.current().fg_3, .border = .{ .radius = 3 }, .flex_shrink = 0 }, .{});
            try row.appendChild(self.cx.allocator, dot);
            const identity = try ui.box(self.cx, .{ .width = .fill(), .flex = 1, .min_width = 0, .direction = .column, .gap = 3 }, .{});
            const name = try ui.text(self.cx, member.name, .{ .font_size = 11, .line_height = 1.5, .font_weight = 500, .color = S.theme.current().fg_1, .text_overflow = .ellipsis });
            name.setStyleInline(self.cx.allocator, .{ .width = .fill(), .height = .{ .px = 16 }, .min_width = 0 });
            try identity.appendChild(self.cx.allocator, name);
            const endpoint = try ui.text(self.cx, member.endpoint, .{ .font_size = 9, .line_height = 1.5, .color = S.theme.current().fg_2, .text_overflow = .ellipsis });
            endpoint.setStyleInline(self.cx.allocator, .{ .width = .fill(), .height = .{ .px = 14 }, .min_width = 0 });
            try identity.appendChild(self.cx.allocator, endpoint);
            try row.appendChild(self.cx.allocator, identity);
            const state = if (!member.available) member.unavailable_reason else if (member.source) "当前输入" else if (member.selected) "参与" else "未参与";
            try row.appendChild(self.cx.allocator, try ui.text(self.cx, state, .{ .font_size = 8, .color = S.theme.current().fg_2 }));
            try members.appendChild(self.cx.allocator, row);
            if (self.focus_member == member.id) {
                self.cx.setFocus(check);
                self.focus_member = null;
            }
        }
        try self.content.appendChild(self.cx.allocator, members);
        const note_box = try ui.box(self.cx, .{ .width = .fill(), .height = .{ .fit = .{} }, .padding = .{ .left = 10, .right = 10, .top = 9, .bottom = 9 }, .background = S.theme.current().well, .border = .{ .radius = 8 }, .flex_shrink = 0 }, .{});
        const note = try ui.text(self.cx, "在当前输入会话发送的 Shell 输入会同步到参与会话。内置指令不广播；新增或重连成员需重新开启确认。", S.note());
        note.setStyleInline(self.cx.allocator, .{ .width = .fill() });
        try note_box.appendChild(self.cx.allocator, note);
        try self.content.appendChild(self.cx.allocator, note_box);
    }
    pub fn dismiss(self: *View) void {
        self.requested = false;
        self.open.set(false);
        self.root.setDisplay(.none);
        self.cx.requestRedraw();
    }
    pub fn hide(self: *View) void {
        self.dismiss();
        if (!self.running) self.hooks.resolve(self.hooks.context, self.group_id, false);
    }
    fn anchorRect(raw: *anyopaque) ui.widgets.popover.AnchorRect {
        const self: *View = @ptrCast(@alignCast(raw));
        if (self.cx.root) |root| if (self.anchor_id) |id| if (find(root, id)) |trigger| {
            const rect = trigger.globalRect();
            if (trigger.isDisplayedInTree() and rect.w > 0) return .{ .x = rect.x, .y = rect.y, .w = rect.w, .h = rect.h };
        };
        return self.anchor_rect;
    }
    fn changed(self: *View, value: bool) void {
        if (!value) self.hide();
    }
    fn accept(self: *View) void {
        if (!self.disabled.peek()) self.hooks.resolve(self.hooks.context, self.group_id, true);
    }
    fn cleanup(self: *View) void {
        self.cx.removeAfterLayoutHook(self);
        if (self.current) |*owned| owned.arena.deinit();
        if (self.pending) |*owned| owned.arena.deinit();
        self.cx.allocator.destroy(self);
    }
    const Selection = struct {
        view: *View,
        group: u32,
        owner: ?Handle,
        id: u64,
        fn changed(self: *Selection, value: bool) void {
            const callback = self.view.hooks.select orelse return;
            const owner = self.owner orelse return;
            self.view.focus_member = self.id;
            callback(self.view.hooks.context, self.group, owner, value);
        }
    };
    fn find(node: *ui.Node, id: u32) ?*ui.Node {
        if (node.id == id) return node;
        for (node.children.items) |child| if (find(child, id)) |found| return found;
        return null;
    }
};
