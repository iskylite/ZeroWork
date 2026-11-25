//! V0.8 §3.2.2: Target Chips + `@` target selection for the standalone AI
//! page and grouped AI pane. Rendering only; the host owns selection state.
const std = @import("std");
const ui = @import("ui");
const S = @import("ai_composer_controls_styles.zig");

pub const Kind = enum { session, group, file };

pub const Target = struct {
    id: u64,
    label: []const u8,
    kind: Kind,
};

pub const Callbacks = struct {
    context: *anyopaque,
    /// A candidate was picked from the add menu or `@` completion.
    add: *const fn (*anyopaque, Kind, u64, []const u8) void,
    remove: *const fn (*anyopaque, Kind, u64) void,
    /// `@file:` completion inserts the reference without becoming a target.
    insert: *const fn (*anyopaque, []const u8) void,
};

pub const View = struct {
    cx: *ui.Cx,
    scope: *ui.Scope,
    callbacks: Callbacks,
    root: *ui.Node,
    chips: *ui.Node,
    add_button: *ui.Node,
    popup: ui.widgets.popover.PopoverResult,
    popup_scope: ?*ui.Scope = null,
    popup_list: *ui.Node,
    popup_search: ui.widgets.input.TextareaResult,
    empty: *ui.Node,
    targets: std.ArrayList(Stored) = .empty,
    candidates: std.ArrayList(Stored) = .empty,
    /// `@` completion filters the same candidate set and inserts text.
    completion: bool = false,
    query: [64]u8 = undefined,
    query_len: usize = 0,

    const Stored = struct { id: u64, kind: Kind, label: []u8 };

    pub fn mount(cx: *ui.Cx, scope: *ui.Scope, parent: *ui.Node, callbacks: Callbacks) !*View {
        const self = try scope.createState(View, .{
            .cx = cx,
            .scope = scope,
            .callbacks = callbacks,
            .root = undefined,
            .chips = undefined,
            .add_button = undefined,
            .popup = undefined,
            .popup_list = undefined,
            .popup_search = undefined,
            .empty = undefined,
        });
        try scope.onCleanup(View, self, cleanup);
        self.root = try ui.box(cx, .{ .width = .fill(), .height = .{ .fit = .{} }, .direction = .row, .align_items = .center, .gap = 6, .padding = .{ .left = 14, .right = 14, .top = 4, .bottom = 2 }, .flex_shrink = 0 }, .{});
        self.root.meta.ownership.meta.test_id = "ai.targets.bar";
        self.chips = try ui.box(cx, .{ .width = .{ .fit = .{} }, .height = .{ .fit = .{} }, .direction = .row, .align_items = .center, .gap = 4, .flex_shrink = 1, .min_width = 0 }, .{});
        try self.root.appendChild(cx.allocator, self.chips);
        self.add_button = try ui.widgets.Button(.{ .label = "关联会话 / 组", .a11y_label = "关联会话或会话组", .variant = .ghost, .icon_asset = ui.icons.get("plus").?, .icon_size = 12, .base_style = S.chip(0, 8), .on_click = cx.on(View, self, View.toggle) }).mount(scope, cx);
        self.add_button.meta.ownership.meta.test_id = "ai.targets.add";
        self.add_button.setStyleInline(cx.allocator, .{ .width = .{ .fit = .{} }, .padding = .{ .left = 8, .right = 8 } });
        try self.root.appendChild(cx.allocator, self.add_button);
        try parent.appendChild(cx.allocator, self.root);
        const popup = try ui.widgets.Popover(.{ .trigger = .manual, .anchor = .{ .node = self.add_button }, .position = .top_start, .offset = .{ .static = 6 }, .width = 300, .max_height = 320, .close_on_escape = true, .close_on_outside_click = true, .constrain_width_to_viewport = true }).mount(scope, cx);
        popup.wrapper.setStyleInline(cx.allocator, .{ .position = .absolute, .width = .{ .px = 0 }, .height = .{ .px = 0 } });
        popup.chrome.meta.ownership.meta.test_id = "ai.targets.popup";
        try self.root.appendChild(cx.allocator, popup.wrapper);
        self.popup = popup;
        self.popup_list = try ui.box(cx, .{ .width = .fill(), .height = .{ .fit = .{} }, .direction = .column, .gap = 2 }, .{});
        self.popup_list.meta.ownership.meta.test_id = "ai.targets.list";
        try popup.content.appendChild(cx.allocator, self.popup_list);
        self.empty = try ui.text(cx, "没有可关联的活动会话", .{ .font_size = 12, .line_height = 1.6, .color = S.theme.current().fg_3 });
        self.empty.setDisplay(.none);
        try popup.content.appendChild(cx.allocator, self.empty);
        self.root.setDisplay(.none);
        return self;
    }

    fn cleanup(self: *View) void {
        for (self.targets.items) |item| self.cx.allocator.free(item.label);
        self.targets.deinit(self.cx.allocator);
        for (self.candidates.items) |item| self.cx.allocator.free(item.label);
        self.candidates.deinit(self.cx.allocator);
    }

    pub fn setVisible(self: *View, visible: bool) void {
        self.root.setDisplay(if (visible) .flex else .none);
        if (!visible) self.popup.open.?.set(false);
    }

    pub fn setTargets(self: *View, rows: []const Target) !void {
        if (sameRows(self.targets.items, rows)) return;
        for (self.targets.items) |item| self.cx.allocator.free(item.label);
        self.targets.clearRetainingCapacity();
        for (rows) |row| try self.targets.append(self.cx.allocator, .{ .id = row.id, .kind = row.kind, .label = try self.cx.allocator.dupe(u8, row.label) });
        try self.rebuildChips();
    }

    pub fn setCandidates(self: *View, rows: []const Target) !void {
        if (sameRows(self.candidates.items, rows)) return;
        for (self.candidates.items) |item| self.cx.allocator.free(item.label);
        self.candidates.clearRetainingCapacity();
        for (rows) |row| try self.candidates.append(self.cx.allocator, .{ .id = row.id, .kind = row.kind, .label = try self.cx.allocator.dupe(u8, row.label) });
        // Rebuilding while a candidate row is dispatching its own click would
        // destroy the live button; defer until the next open instead.
        if (self.popup.open.?.peek()) return;
        try self.rebuildPopup();
    }

    fn sameRows(left: []const Stored, right: []const Target) bool {
        if (left.len != right.len) return false;
        for (left, right) |a, b| if (a.id != b.id or a.kind != b.kind or !std.mem.eql(u8, a.label, b.label)) return false;
        return true;
    }

    fn rebuildChips(self: *View) !void {
        while (self.chips.children.items.len != 0) {
            const child = self.chips.children.items[0];
            self.cx.detachChild(self.chips, child);
            self.cx.destroyDetached(child);
        }
        for (self.targets.items, 0..) |target, index| {
            const chip = try ui.widgets.Button(.{ .label = target.label, .variant = .ghost, .icon_asset = ui.icons.get("x").?, .icon_size = 10, .base_style = S.chip(0, 8), .on_click = self.cx.on(ChipClick, try self.scope.createState(ChipClick, .{ .view = self, .index = index }), ChipClick.remove) }).mount(self.scope, self.cx);
            chip.setStyleInline(self.cx.allocator, .{ .width = .{ .fit = .{} }, .padding = .{ .left = 8, .right = 6 } });
            chip.meta.ownership.meta.test_id = "ai.targets.chip";
            try self.chips.appendChild(self.cx.allocator, chip);
        }
        self.root.setDisplay(if (self.targets.items.len != 0 or self.root.style.display != .none) .flex else .none);
    }

    fn rebuildPopup(self: *View) !void {
        while (self.popup_list.children.items.len != 0) {
            const child = self.popup_list.children.items[0];
            self.cx.detachChild(self.popup_list, child);
            self.cx.destroyDetached(child);
        }
        if (self.popup_scope) |scope| scope.dispose();
        self.popup_scope = null;
        if (self.matchCount() == 0) {
            self.empty.setDisplay(.flex);
            return;
        }
        self.empty.setDisplay(.none);
        const scope = try self.popup.scope.childScope();
        self.popup_scope = scope;
        for (self.candidates.items) |candidate| {
            if (!self.matches(candidate.label)) continue;
            const row = try ui.widgets.Button(.{ .label = candidate.label, .variant = .ghost, .a11y_label = candidate.label, .icon_asset = if (candidate.kind == .group) ui.icons.get("group").? else ui.icons.get("server").?, .icon_size = 13, .on_click = self.cx.on(CandidateClick, try scope.createState(CandidateClick, .{ .view = self, .id = candidate.id, .kind = candidate.kind }), CandidateClick.pick) }).mount(scope, self.cx);
            row.setStyleInline(self.cx.allocator, S.option(30, false));
            row.meta.ownership.meta.test_id = "ai.targets.candidate";
            try self.popup_list.appendChild(self.cx.allocator, row);
        }
    }

    fn toggle(self: *View) void {
        self.completion = false;
        self.query_len = 0;
        const open = !self.popup.open.?.peek();
        self.popup.open.?.set(open);
        if (open) self.rebuildPopup() catch return;
        self.cx.requestRedraw();
    }

    /// V0.8 §3.2.2: typing `@` in the composer opens the same candidate list;
    /// picking one both adds the target and inserts its reference token.
    pub fn openCompletion(self: *View, query: []const u8) void {
        const was_open = self.popup.open.?.peek();
        self.completion = true;
        const n = @min(query.len, self.query.len);
        @memcpy(self.query[0..n], query[0..n]);
        self.query_len = n;
        if (!was_open or !self.matchesQueryChange(query)) self.rebuildPopup() catch return;
        self.popup.open.?.set(self.rowsVisible());
        self.cx.requestRedraw();
    }

    fn matchesQueryChange(self: *const View, query: []const u8) bool {
        _ = self;
        _ = query;
        return false;
    }

    pub fn closeCompletion(self: *View) void {
        if (!self.completion) return;
        self.completion = false;
        self.query_len = 0;
        self.popup.open.?.set(false);
    }

    fn rowsVisible(self: *const View) bool {
        if (!self.completion) return true;
        return self.matchCount() != 0;
    }

    fn matches(self: *const View, label: []const u8) bool {
        if (self.query_len == 0) return true;
        return std.ascii.findIgnoreCase(label, self.query[0..self.query_len]) != null;
    }

    fn matchCount(self: *const View) usize {
        var count: usize = 0;
        for (self.candidates.items) |candidate| if (self.matches(candidate.label)) {
            count += 1;
        };
        return count;
    }

    const ChipClick = struct {
        view: *View,
        index: usize,
        fn remove(self: *ChipClick) void {
            if (self.index >= self.view.targets.items.len) return;
            const target = self.view.targets.items[self.index];
            self.view.callbacks.remove(self.view.callbacks.context, target.kind, target.id);
        }
    };

    const CandidateClick = struct {
        view: *View,
        id: u64,
        kind: Kind,
        fn pick(self: *CandidateClick) void {
            const candidate = for (self.view.candidates.items) |candidate| {
                if (candidate.id == self.id and candidate.kind == self.kind) break candidate;
            } else return;
            // `add` refreshes candidates, which frees this row's label; copy it
            // before crossing that boundary.
            var label_buffer: [128]u8 = undefined;
            const label_len = @min(candidate.label.len, label_buffer.len);
            @memcpy(label_buffer[0..label_len], candidate.label[0..label_len]);
            const label = label_buffer[0..label_len];
            self.view.callbacks.add(self.view.callbacks.context, candidate.kind, candidate.id, label);
            if (self.view.completion) {
                var token_buffer: [160]u8 = undefined;
                const token = std.fmt.bufPrint(&token_buffer, "@{s} ", .{label}) catch return;
                self.view.callbacks.insert(self.view.callbacks.context, token);
            }
            self.view.completion = false;
            self.view.query_len = 0;
            self.view.popup.open.?.set(false);
        }
    };
};
