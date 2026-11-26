//! The standalone composer selects its exact terminal scope. The chip and
//! @ completion share one menu; the host alone can grant or revoke access.
const std = @import("std");
const ui = @import("ui");
const S = @import("ai_composer_controls_styles.zig");
const Handle = @import("../host/identity.zig").SessionHandle;
pub const Kind = enum { session, group, file };
pub const Target = struct { id: u64, label: []const u8, kind: Kind, generation: u64 = 0 };
pub const Callbacks = struct {
    context: *anyopaque,
    add: *const fn (*anyopaque, Kind, u64, []const u8) void,
    remove: *const fn (*anyopaque, Kind, u64) void,
    insert: *const fn (*anyopaque, []const u8) void,
    create_local: *const fn (*anyopaque) void,
};
pub const View = struct {
    cx: *ui.Cx,
    callbacks: Callbacks,
    root: *ui.Node = undefined,
    add_button: *ui.Node = undefined,
    name: *ui.Node = undefined,
    glyph: *ui.Node = undefined,
    chevron: *ui.Node = undefined,
    button_style: *ui.Signal(ui.BoxStyle) = undefined,
    short: bool = false,
    available: bool = false,
    interaction: bool = false,
    owner: ?Handle = null,
    opened_for: ?Handle = null,
    popup: ui.widgets.popover.PopoverResult = undefined,
    scroll: ui.widgets.ScrollAreaResult = undefined,
    create: *ui.Node = undefined,
    popup_scope: ?*ui.Scope = null,
    targets: std.ArrayList(Stored) = .empty,
    candidates: std.ArrayList(Stored) = .empty,
    completion: bool = false,
    dirty: bool = true,
    query: [128]u8 = undefined,
    query_len: usize = 0,

    const Stored = struct { id: u64, kind: Kind, generation: u64, label: []u8 };
    pub fn mount(cx: *ui.Cx, scope: *ui.Scope, parent: *ui.Node, before: *ui.Node, callbacks: Callbacks) !*View {
        const self = try scope.createState(View, .{ .cx = cx, .callbacks = callbacks });
        try scope.onCleanup(View, self, cleanup);
        self.root = try ui.box(cx, .{ .width = .{ .fit = .{} }, .height = .{ .px = 24 }, .flex_shrink = 0 }, .{});
        self.root.meta.ownership.meta.test_id = "ai.targets.bar";
        self.button_style = try scope.createSignal(ui.BoxStyle, S.executionChip());
        const hover = try S.theme.paintSignal(?ui.BoxStyle, cx, scope, S.hoverOptional, .{});
        self.add_button = try ui.widgets.Button(.{ .a11y_label = "关联会话或会话组", .variant = .ghost, .base_style = self.button_style, .hover_style = hover, .on_click = cx.on(View, self, View.toggle) }).mount(scope, cx);
        self.add_button.meta.ownership.meta.test_id = "ai.targets.add";
        for (self.add_button.children.items) |child| child.setDisplay(.none);
        self.glyph = try S.theme.icon(cx, ui.icons.link, "fg_2", S.icon(12));
        self.name = try ui.text(cx, "关联会话", S.text(10, 400, 14, false));
        self.chevron = try S.theme.icon(cx, ui.icons.chevron_down, "fg_2", S.icon(10));
        for ([_]*ui.Node{ self.glyph, self.name, self.chevron }) |child| try self.add_button.appendChild(cx.allocator, child);
        try self.root.appendChild(cx.allocator, self.add_button);
        try parent.insertChildBefore(cx.allocator, self.root, before);
        self.popup = try ui.widgets.Popover(.{ .trigger = .manual, .anchor = .{ .node = self.add_button }, .position = .top_start, .offset = .{ .static = 6 }, .width = 276, .max_height = 306, .viewport_padding = 8, .shift_main_axis = true, .flip = true, .close_on_escape = true, .close_on_outside_click = true, .constrain_width_to_viewport = true }).mount(scope, cx);
        self.popup.wrapper.setStyleInline(cx.allocator, S.wrapper());
        self.popup.chrome.meta.ownership.meta.test_id = "ai.targets.popup";
        try self.root.appendChild(cx.allocator, self.popup.wrapper);
        self.scroll = try ui.widgets.ScrollArea(.{}).mount(self.popup.scope, cx);
        self.scroll.container.setStyleInline(cx.allocator, S.models());
        self.scroll.content.setStyleInline(cx.allocator, .{ .width = .fill(), .direction = .column, .gap = 3 });
        self.scroll.content.meta.ownership.meta.test_id = "ai.targets.list";
        try self.popup.content.appendChild(cx.allocator, self.scroll.container);
        self.create = try ui.widgets.Button(.{ .label = "新建本地终端并关联", .icon_asset = ui.icons.plus, .icon_size = 12, .variant = .ghost, .base_style = S.option(30, false), .hover_style = hover, .on_click = cx.on(View, self, createLocal) }).mount(scope, cx);
        self.create.meta.ownership.meta.test_id = "ai.targets.create_local";
        try self.popup.content.appendChild(cx.allocator, self.create);
        self.root.setDisplay(.none);
        try scope.createEffect(.{ .view = self, .theme = try cx.themeSignal(scope) }, struct {
            fn run(state: anytype) void {
                _ = state.theme.get();
                state.view.paintChip();
                state.view.dirty = true;
            }
        }.run);
        try cx.addAfterLayoutHook(self, afterLayout);
        return self;
    }
    fn cleanup(self: *View) void {
        self.cx.removeAfterLayoutHook(self);
        for (self.targets.items) |item| self.cx.allocator.free(item.label);
        self.targets.deinit(self.cx.allocator);
        for (self.candidates.items) |item| self.cx.allocator.free(item.label);
        self.candidates.deinit(self.cx.allocator);
    }

    pub fn setOwner(self: *View, owner: ?Handle) void {
        if (self.owner) |old| if (owner) |next| {
            if (old.eql(next)) return;
        };
        self.dismiss();
        self.owner = owner;
    }
    pub fn setVisible(self: *View, value: bool) void {
        self.available = value;
        self.root.setDisplay(if (value and !self.interaction) .flex else .none);
        if (!value) self.dismiss();
    }
    pub fn setInteraction(self: *View, active: bool) void {
        self.interaction = active;
        self.setVisible(self.available);
        if (active) self.dismiss();
    }
    pub fn setCompact(self: *View, value: bool) bool {
        if (self.short == value) return false;
        self.short = value;
        self.paintChip();
        return true;
    }
    fn paintChip(self: *View) void {
        self.button_style.set(if (self.short) S.iconButton(8) else S.executionChip());
        self.name.setTextColor(S.theme.current().fg_2);
        self.name.setDisplay(if (self.short) .none else .flex);
        self.chevron.setDisplay(if (self.short) .none else .flex);
        const accent = self.targets.items.len > 0;
        _ = self.glyph.setTint(if (accent) S.theme.current().accent_ink else S.theme.current().fg_2);
    }
    pub fn setTargets(self: *View, rows: []const Target) !void {
        if (!try self.replace(&self.targets, rows)) return;
        var buf: [48]u8 = undefined;
        try self.name.setTextContent(self.cx.allocator, if (rows.len == 0) "关联会话" else try std.fmt.bufPrint(&buf, "已关联 {d}", .{rows.len}));
        self.paintChip();
    }
    pub fn setCandidates(self: *View, rows: []const Target) !void {
        _ = try self.replace(&self.candidates, rows);
    }
    fn replace(self: *View, list: *std.ArrayList(Stored), rows: []const Target) !bool {
        const a = self.cx.allocator;
        if (list.items.len == rows.len) {
            for (list.items, rows) |previous, next| {
                if (previous.id != next.id or previous.kind != next.kind or previous.generation != next.generation or !std.mem.eql(u8, previous.label, next.label)) break;
            } else return false;
        }
        var next_list: std.ArrayList(Stored) = .empty;
        errdefer {
            for (next_list.items) |item| a.free(item.label);
            next_list.deinit(a);
        }
        try next_list.ensureTotalCapacity(a, rows.len);
        for (rows) |item| next_list.appendAssumeCapacity(.{ .id = item.id, .kind = item.kind, .generation = item.generation, .label = try a.dupe(u8, item.label) });
        for (list.items) |item| a.free(item.label);
        list.deinit(a);
        list.* = next_list;
        self.dirty = true;
        self.cx.requestRedraw();
        return true;
    }
    fn dismiss(self: *View) void {
        self.opened_for = null;
        self.completion = false;
        self.query_len = 0;
        self.popup.open.?.set(false);
    }
    fn live(self: *View) bool {
        return self.available and !self.interaction and self.popup.open.?.peek() and self.owner != null and self.opened_for != null and self.owner.?.eql(self.opened_for.?);
    }
    fn createLocal(self: *View) void {
        if (!self.live() or self.completion or self.targets.items.len >= 16) return;
        self.dismiss();
        self.callbacks.create_local(self.callbacks.context);
    }
    fn toggle(self: *View) void {
        if (self.popup.open.?.peek()) self.dismiss() else self.open();
    }
    pub fn open(self: *View) void {
        if (!self.available or self.interaction or self.owner == null) return;
        self.completion = false;
        self.query_len = 0;
        self.opened_for = self.owner;
        self.dirty = true;
        self.popup.open.?.set(true);
        self.cx.requestRedraw();
    }
    pub fn openCompletion(self: *View, query: []const u8) void {
        if (!self.available or self.interaction or self.owner == null or query.len > self.query.len) return self.closeCompletion();
        if (self.completion and std.mem.eql(u8, self.query[0..self.query_len], query)) return;
        self.completion = true;
        self.opened_for = self.owner;
        self.query_len = query.len;
        @memcpy(self.query[0..query.len], query);
        self.dirty = true;
        self.popup.open.?.set(self.matchCount() > 0);
        self.cx.requestRedraw();
    }
    pub fn closeCompletion(self: *View) void {
        if (self.completion) self.dismiss();
    }
    fn matches(self: *const View, label: []const u8) bool {
        return self.query_len == 0 or std.ascii.findIgnoreCase(label, self.query[0..self.query_len]) != null;
    }
    fn matchCount(self: *const View) usize {
        var count: usize = 0;
        for (self.candidates.items) |candidate| if (self.matches(candidate.label)) {
            count += 1;
        };
        return count;
    }
    fn afterLayout(raw: *anyopaque, _: u8, _: bool) ui.AfterLayoutResult {
        const self: *View = @ptrCast(@alignCast(raw));
        if (!self.live() or !self.dirty) return .done;
        self.rebuild() catch return .done;
        self.dirty = false;
        return .needs_layout;
    }
    fn heading(self: *View, value: []const u8) !void {
        const node = try ui.text(self.cx, value, S.text(11, 500, 20, true));
        node.setStyleInline(self.cx.allocator, .{ .width = .fill(), .height = .{ .px = 24 }, .padding = .{ .left = 7, .top = 2 } });
        try self.scroll.content.appendChild(self.cx.allocator, node);
    }
    fn rebuild(self: *View) !void {
        // Only rebuild after event dispatch; never free the clicked row or
        // its captured label from inside the click that changes the grants.
        if (self.popup_scope) |scope| scope.dispose();
        self.popup_scope = null;
        while (self.scroll.content.children.items.len != 0) {
            const child = self.scroll.content.children.items[0];
            self.cx.detachChild(self.scroll.content, child);
            self.cx.destroyDetached(child);
        }
        const scope = try self.popup.scope.childScope();
        self.popup_scope = scope;
        var height: f32 = 20;
        if (!self.completion and self.targets.items.len != 0) {
            try self.heading("已关联 · 点击移除");
            height += 28;
            for (self.targets.items) |item| {
                try self.row(scope, item, true);
                height += 33;
            }
        }
        const count = self.matchCount();
        if (count != 0) {
            if (!self.completion) {
                try self.heading("可关联会话与组");
                height += 28;
            }
            for (self.candidates.items) |item| if (self.matches(item.label)) {
                try self.row(scope, item, false);
                height += 33;
            };
        } else if (!self.completion and self.targets.items.len == 0) {
            try self.heading("暂无可关联的活动会话");
            height += 28;
        }
        const create_visible = !self.completion and self.targets.items.len < 16;
        self.create.setDisplay(if (create_visible) .flex else .none);
        if (create_visible) height += 36;
        var style = S.panel(.attachment, self.cx.viewport);
        style.width = .{ .px = @min(276, @max(1, self.cx.viewport.width - 16)) };
        style.height = .{ .px = @min(height, @min(306, @max(1, self.cx.viewport.height - 16))) };
        style.min_height = 0;
        style.padding = ui.Padding.all(6);
        self.popup.chrome.setStyleInline(self.cx.allocator, style);
    }
    fn row(self: *View, scope: *ui.Scope, item: Stored, selected: bool) !void {
        const pick = try scope.createState(Pick, .{ .view = self, .id = item.id, .kind = item.kind, .generation = item.generation, .remove = selected });
        const text = try scope.createText(item.label, .{});
        const button = try ui.widgets.Button(.{ .label = text, .a11y_label = text, .variant = .ghost, .icon_asset = if (selected) ui.icons.check else if (item.kind == .group) ui.icons.get("group").? else ui.icons.get("server").?, .icon_size = 13, .base_style = S.option(30, selected), .hover_style = S.hoverOptional(), .on_click = self.cx.on(Pick, pick, Pick.click) }).mount(scope, self.cx);
        button.meta.ownership.meta.test_id = if (selected) "ai.targets.chip" else "ai.targets.candidate";
        if (button.behavior.interaction.a11y) |*a11y| a11y.selected = selected;
        try self.scroll.content.appendChild(self.cx.allocator, button);
    }
    const Pick = struct {
        view: *View,
        id: u64,
        kind: Kind,
        generation: u64,
        remove: bool,
        fn click(p: *Pick) void {
            const self = p.view;
            if (!self.live()) return;
            const list = if (p.remove) self.targets.items else self.candidates.items;
            const item = for (list) |v| {
                if (v.id == p.id and v.kind == p.kind and v.generation == p.generation) break v;
            } else return;
            // Callbacks may reproject/free list entries. Own the label until
            // both the authorization and possible text insertion are complete.
            const label = self.cx.allocator.dupe(u8, item.label) catch return;
            defer self.cx.allocator.free(label);
            const complete = self.completion;
            self.dismiss();
            if (p.remove) self.callbacks.remove(self.callbacks.context, item.kind, item.id) else {
                self.callbacks.add(self.callbacks.context, item.kind, item.id, label);
                if (complete) {
                    const token = std.fmt.allocPrint(self.cx.allocator, "@{s} ", .{label}) catch return;
                    defer self.cx.allocator.free(token);
                    self.callbacks.insert(self.callbacks.context, token);
                }
            }
        }
    };
};
