//! Standalone AI scope is managed through /session; @ completes a target in the
//! draft. Both use the same composer-anchored list. Only the host grants access.
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

const Origin = struct {
    owner: Handle,
    conversation: u64,

    fn eql(self: Origin, other: Origin) bool {
        return self.owner.eql(other.owner) and self.conversation == other.conversation;
    }
};

pub const View = struct {
    cx: *ui.Cx,
    composer: *ui.Node,
    editor: *ui.widgets.input.TextareaState,
    input: *ui.Node,
    callbacks: Callbacks,
    popup: ui.widgets.popover.PopoverResult,
    scroll: ui.widgets.ScrollAreaResult,
    popup_scope: ?*ui.Scope = null,
    targets: std.ArrayList(Stored) = .empty,
    candidates: std.ArrayList(Stored) = .empty,
    rows: std.ArrayList(Row) = .empty,
    origin: ?Origin = null,
    opened_for: ?Origin = null,
    interaction: bool = false,
    completion: bool = false,
    dirty: bool = true,
    reveal_selection: bool = false,
    selected: usize = 0,
    desired_height: f32 = 0,
    query: [128]u8 = undefined,
    query_len: usize = 0,
    editor_revision: u64 = 0,

    const Stored = struct { id: u64, kind: Kind, generation: u64, label: []u8 };

    pub fn mount(cx: *ui.Cx, scope: *ui.Scope, composer: *ui.Node, input: ui.widgets.input.TextareaResult, callbacks: Callbacks) !*View {
        const popup = try ui.widgets.Popover(S.completionPopover(composer)).mount(scope, cx);
        popup.wrapper.setStyleInline(cx.allocator, S.wrapper());
        popup.chrome.meta.ownership.meta.test_id = "ai.targets.popup";
        popup.chrome.setStyleInline(cx.allocator, S.completionPanel(cx.viewport));
        try composer.appendChild(cx.allocator, popup.wrapper);
        const scroll = try ui.widgets.ScrollArea(.{ .direction = .vertical, .background = ui.Color.TRANSPARENT, .rubber_band_y = false }).mount(popup.scope, cx);
        scroll.container.setStyleInline(cx.allocator, S.models());
        scroll.content.setStyleInline(cx.allocator, .{ .width = .fill(), .direction = .column, .gap = S.completion_row_gap });
        scroll.content.meta.ownership.meta.test_id = "ai.targets.list";
        try popup.content.appendChild(cx.allocator, scroll.container);
        const self = try scope.createState(View, .{ .cx = cx, .composer = composer, .editor = input.state, .input = input.input, .callbacks = callbacks, .popup = popup, .scroll = scroll });
        try scope.createEffect(.{ .view = self, .theme = try cx.themeSignal(scope) }, struct {
            fn run(state: anytype) void {
                _ = state.theme.get();
                state.view.dirty = true;
            }
        }.run);
        try cx.addAfterLayoutHook(self, afterLayout);
        try scope.onCleanup(View, self, cleanup);
        return self;
    }

    fn cleanup(self: *View) void {
        self.cx.removeAfterLayoutHook(self);
        for (self.targets.items) |item| self.cx.allocator.free(item.label);
        self.targets.deinit(self.cx.allocator);
        for (self.candidates.items) |item| self.cx.allocator.free(item.label);
        self.candidates.deinit(self.cx.allocator);
        self.rows.deinit(self.cx.allocator);
    }

    pub fn setOwner(self: *View, owner: ?Handle, conversation: ?u64) void {
        const next: ?Origin = if (owner != null and conversation != null) .{ .owner = owner.?, .conversation = conversation.? } else null;
        if (self.origin == null and next == null) return;
        if (self.origin != null and next != null and self.origin.?.eql(next.?)) return;
        self.dismiss();
        self.origin = next;
    }

    pub fn canOpen(self: *const View) bool {
        return self.origin != null and !self.interaction and !self.editor.disabled and !self.editor.imeIsComposing();
    }

    pub fn setInteraction(self: *View, active: bool) void {
        self.interaction = active;
        if (active) self.dismiss();
    }

    pub fn setTargets(self: *View, rows: []const Target) !void {
        try self.replace(&self.targets, rows);
    }

    pub fn setCandidates(self: *View, rows: []const Target) !void {
        try self.replace(&self.candidates, rows);
    }

    fn replace(self: *View, list: *std.ArrayList(Stored), rows: []const Target) !void {
        const a = self.cx.allocator;
        if (list.items.len == rows.len) {
            for (list.items, rows) |previous, next| {
                if (previous.id != next.id or previous.kind != next.kind or previous.generation != next.generation or !std.mem.eql(u8, previous.label, next.label)) break;
            } else return;
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
    }

    pub fn dismiss(self: *View) void {
        self.opened_for = null;
        self.completion = false;
        self.query_len = 0;
        self.popup.open.?.set(false);
    }

    fn live(self: *const View) bool {
        return self.canOpen() and self.popup.open.?.peek() and self.opened_for != null and self.origin.?.eql(self.opened_for.?) and
            (!self.completion or (self.editor.doc.revision == self.editor_revision and self.editor.cursor.offset == self.editor.getText().len));
    }

    pub fn open(self: *View) void {
        if (!self.canOpen()) return;
        self.completion = false;
        self.query_len = 0;
        self.opened_for = self.origin;
        self.begin();
    }

    pub fn openCompletion(self: *View, query: []const u8) void {
        if (!self.canOpen() or self.cx.focus_manager.getFocused() != self.input or self.editor.cursor.offset != self.editor.getText().len or query.len > self.query.len) return self.closeCompletion();
        const revision = self.editor.doc.revision;
        if (self.completion and revision == self.editor_revision and std.mem.eql(u8, self.query[0..self.query_len], query)) return;
        self.completion = true;
        self.opened_for = self.origin;
        self.editor_revision = revision;
        self.query_len = query.len;
        @memcpy(self.query[0..query.len], query);
        if (self.matchCount() > 0) {
            self.begin();
        } else {
            self.popup.open.?.set(false);
        }
    }

    fn begin(self: *View) void {
        self.selected = 0;
        self.reveal_selection = true;
        self.dirty = true;
        self.popup.open.?.set(true);
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
        if (!self.popup.open.?.peek()) return .done;
        if (!self.live() or (self.completion and self.matchCount() == 0)) {
            self.dismiss();
            return .done;
        }
        if (self.dirty) {
            self.rebuild() catch {
                self.dismiss();
                return .done;
            };
            self.dirty = false;
            _ = S.layoutCompletion(self.cx, self.popup.chrome, self.composer, self.desired_height);
            return .needs_layout;
        }
        if (S.layoutCompletion(self.cx, self.popup.chrome, self.composer, self.desired_height)) return .needs_layout;
        if (self.reveal_selection and self.scroll.state.viewport_height > 0 and self.selected < self.rows.items.len) {
            ui.widgets.scrollRectIntoView(self.scroll.state, self.scroll.content, self.rows.items[self.selected].top, S.completion_row_height, .nearest);
            self.reveal_selection = false;
        }
        return .done;
    }

    const heading_height: f32 = 23;

    fn heading(self: *View, value: []const u8) !void {
        const node = try ui.text(self.cx, value, S.completionHint());
        node.setStyleInline(self.cx.allocator, .{ .width = .fill(), .height = .{ .px = heading_height }, .padding = .{ .left = 8, .top = 4 } });
        node.setHitTestVisible(false);
        try self.scroll.content.appendChild(self.cx.allocator, node);
    }

    fn rebuild(self: *View) !void {
        // Called only after event dispatch, outside the clicked row's callback.
        while (self.scroll.content.children.items.len != 0) {
            const child = self.scroll.content.children.items[0];
            self.cx.detachChild(self.scroll.content, child);
            self.cx.destroyDetached(child);
        }
        if (self.popup_scope) |scope| scope.dispose();
        self.popup_scope = null;
        self.rows.clearRetainingCapacity();
        const scope = try self.popup.scope.childScope();
        self.popup_scope = scope;
        const row_stride = S.completion_row_height + S.completion_row_gap;
        const heading_stride = heading_height + S.completion_row_gap;
        var y: f32 = 0;
        if (!self.completion and self.targets.items.len != 0) {
            try self.heading("已关联");
            y += heading_stride;
            for (self.targets.items) |item| {
                try self.row(scope, .{ .target = .{ .id = item.id, .kind = item.kind, .generation = item.generation, .remove = true } }, item.label, y);
                y += row_stride;
            }
        }
        if (self.matchCount() != 0) {
            if (!self.completion) {
                try self.heading("可关联会话与组");
                y += heading_stride;
            }
            for (self.candidates.items) |item| if (self.matches(item.label)) {
                try self.row(scope, .{ .target = .{ .id = item.id, .kind = item.kind, .generation = item.generation } }, item.label, y);
                y += row_stride;
            };
        } else if (!self.completion and self.targets.items.len == 0) {
            try self.heading("暂无可关联的活动会话");
            y += heading_stride;
        }
        if (!self.completion and self.targets.items.len < 16) {
            try self.row(scope, .create, "新建本地终端并关联", y);
            y += row_stride;
        }
        self.selected = @min(self.selected, self.rows.items.len -| 1);
        if (self.selected < self.rows.items.len) self.paintRow(self.selected, true);
        self.desired_height = @min(@as(f32, if (self.completion) 207 else 306), S.completion_padding * 2 + @max(0, y - S.completion_row_gap));
        S.paintCompletionPanel(self.cx, self.popup.chrome);
        self.reveal_selection = true;
    }

    const Action = union(enum) {
        target: struct { id: u64, kind: Kind, generation: u64, remove: bool = false },
        create,
    };
    const Row = struct { button: *ui.Node, style: *ui.Signal(ui.BoxStyle), pick: *Pick, top: f32 };

    fn paintRow(self: *View, index: usize, active: bool) void {
        const r = self.rows.items[index];
        r.style.set(S.completionRow(active));
        if (r.button.behavior.interaction.a11y) |*a11y| a11y.selected = active;
    }

    fn row(self: *View, scope: *ui.Scope, action: Action, title: []const u8, top: f32) !void {
        const pick = try scope.createState(Pick, .{ .view = self, .action = action });
        const style = try scope.createSignal(ui.BoxStyle, S.completionRow(false));
        const visible = try scope.createText(title, .{});
        const remove = action == .target and action.target.remove;
        const ax = if (remove) try std.fmt.allocPrint(scope.allocator, "移除关联：{s}", .{title}) else visible.peek();
        const button = try ui.widgets.Button(.{ .a11y_label = ax, .variant = .ghost, .base_style = style, .hover_style = S.hoverOptional(), .on_click = self.cx.on(Pick, pick, Pick.click) }).mount(scope, self.cx);
        errdefer self.cx.destroyDetached(button);
        for (button.children.items) |child| child.setDisplay(.none);
        button.setStyleInline(self.cx.allocator, .{ .justify = .start });
        button.meta.ownership.meta.test_id = if (action == .create) "ai.targets.create_local" else if (remove) "ai.targets.chip" else "ai.targets.candidate";
        const asset = if (action == .create) ui.icons.plus else if (remove) ui.icons.check else if (action.target.kind == .group) ui.icons.get("group").? else ui.icons.server;
        const glyph = try ui.iconTint(self.cx, asset, S.theme.current().fg_2, S.icon(14));
        glyph.setHitTestVisible(false);
        try button.appendChild(self.cx.allocator, glyph);
        const label = try ui.text(self.cx, visible.peek(), S.completionLabel());
        label.setStyleInline(self.cx.allocator, S.flexibleLabel(17));
        label.setHitTestVisible(false);
        try button.appendChild(self.cx.allocator, label);
        if (remove) {
            const label_remove = try ui.text(self.cx, "移除", S.completionHint());
            label_remove.setHitTestVisible(false);
            try button.appendChild(self.cx.allocator, label_remove);
        }
        try self.rows.ensureUnusedCapacity(self.cx.allocator, 1);
        try self.scroll.content.appendChild(self.cx.allocator, button);
        self.rows.appendAssumeCapacity(.{ .button = button, .style = style, .pick = pick, .top = top });
    }

    pub fn handleKey(self: *View, key: ui.events.KeyEvent) bool {
        if (!self.live() or key.modifiers.super or key.modifiers.ctrl or key.modifiers.alt or key.modifiers.shift) return false;
        switch (key.key) {
            .escape => self.dismiss(),
            .@"return", .tab => {
                if (!self.dirty and self.selected < self.rows.items.len) self.rows.items[self.selected].pick.click();
            },
            .up, .down => {
                if (self.dirty or self.rows.items.len == 0) return true;
                const old = self.selected;
                self.selected = if (key.key == .up) old -| 1 else @min(old + 1, self.rows.items.len - 1);
                if (old != self.selected) {
                    self.paintRow(old, false);
                    self.paintRow(self.selected, true);
                    self.reveal_selection = true;
                }
            },
            else => return false,
        }
        self.cx.requestRedraw();
        return true;
    }

    const Pick = struct {
        view: *View,
        action: Action,

        fn click(p: *Pick) void {
            const self = p.view;
            if (!self.live()) return;
            if (p.action == .create) {
                if (self.completion or self.targets.items.len >= 16) return;
                self.dismiss();
                self.callbacks.create_local(self.callbacks.context);
                return;
            }
            const action = p.action.target;
            const list = if (action.remove) self.targets.items else self.candidates.items;
            const item = for (list) |v| {
                if (v.id == action.id and v.kind == action.kind and v.generation == action.generation) break v;
            } else return;
            const complete = self.completion;
            if (complete and (action.remove or !self.matches(item.label))) return;
            // The host may reproject/free the old list as its grant changes.
            const label = self.cx.allocator.dupe(u8, item.label) catch return;
            defer self.cx.allocator.free(label);
            self.dismiss();
            if (action.remove) {
                self.callbacks.remove(self.callbacks.context, item.kind, item.id);
            } else {
                self.callbacks.add(self.callbacks.context, item.kind, item.id, label);
                if (complete) {
                    const token = std.fmt.allocPrint(self.cx.allocator, "@{s} ", .{label}) catch return;
                    defer self.cx.allocator.free(token);
                    self.callbacks.insert(self.callbacks.context, token);
                }
            }
            self.cx.setFocus(self.input);
        }
    };
};
