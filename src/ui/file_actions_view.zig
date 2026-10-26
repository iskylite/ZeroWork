//! Original-card context/history menus. Every action carries the frozen
//! controller envelope; later navigation or selection cannot retarget it.
const std = @import("std");
const ui = @import("ui");
const Files = @import("file_workspace_view.zig");
const Controller = @import("../host/file_workspace_controller.zig");
const S = @import("file_actions_styles.zig");
const receipts = @import("notification_presenter.zig");
const Frozen = struct { arena: std.heap.ArenaAllocator, envelope: Files.Envelope, directory: []const u8, destination: Files.Stamp, target: []const u8, history: []const Controller.HistoryEntry };
pub const View = struct {
    cx: *ui.Cx,
    scope: *ui.Scope,
    pane: *Files.Pane,
    model: *Controller.Controller,
    root: *ui.Node = undefined,
    chrome: *ui.Node = undefined,
    content: *ui.Node = undefined,
    open: *ui.Signal(bool),
    rows_scope: ?*ui.Scope = null,
    frozen: ?Frozen = null,
    pending: ?Frozen = null,
    history: bool = false,
    anchor_rect: ui.ComputedRect = .{ .x = 0, .y = 0, .w = 0, .h = 0 },
    rebuild: bool = false,
    feedback: ?*ui.Node = null,
    rows: *ui.Node = undefined,

    pub fn mount(cx: *ui.Cx, scope: *ui.Scope, pane: *Files.Pane, model: *Controller.Controller) !*View {
        const self = try scope.createState(View, .{ .cx = cx, .scope = scope, .pane = pane, .model = model, .open = try scope.createSignal(bool, false) });
        try scope.onCleanup(View, self, cleanup);
        const popup = try ui.widgets.Popover(.{ .open = self.open, .trigger = .manual, .anchor = .{ .virtual = .{ .ctx = self, .getRect = anchor } }, .position = .bottom_start, .max_width = @as(f32, 340), .max_height = @as(f32, 380), .offset = .{ .static = 4 }, .viewport_padding = 8, .constrain_width_to_viewport = true, .size_policy = .fit_content, .close_on_escape = true, .close_on_outside_click = true }).mount(scope, cx);
        self.scope = popup.scope;
        self.root = popup.wrapper;
        self.chrome = popup.chrome;
        self.content = popup.content;
        return self;
    }
    fn anchor(raw: *anyopaque) ui.widgets.popover.AnchorRect {
        const self: *View = @ptrCast(@alignCast(raw));
        const rect = self.anchor_rect;
        return .{ .x = rect.x, .y = rect.y, .w = rect.w, .h = rect.h };
    }
    pub fn show(self: *View, envelope: Files.Envelope, entries: ?[]const Controller.HistoryEntry) !void {
        const projection = self.model.projection() orelse return error.FileProjectionUnavailable;
        self.anchor_rect = if (entries != null) self.pane.history_button.globalRect() else self.pane.context_anchor orelse self.pane.context_button.globalRect();
        var arena = std.heap.ArenaAllocator.init(self.cx.allocator);
        errdefer arena.deinit();
        const a = arena.allocator();
        var frozen = envelope;
        if (envelope.action == .context) {
            var selected = envelope.action.context;
            const keys = try a.alloc([]const u8, selected.keys.len);
            for (selected.keys, keys) |key, *copy| copy.* = try a.dupe(u8, key);
            selected.keys = keys;
            if (selected.anchor) |key| selected.anchor = try a.dupe(u8, key);
            if (selected.focused_key) |key| selected.focused_key = try a.dupe(u8, key);
            frozen.action = .{ .context = selected };
        }
        const history = try a.alloc(Controller.HistoryEntry, if (entries) |values| values.len else 0);
        if (entries) |values| {
            for (values, history) |value, *copy| copy.* = .{ .path = try a.dupe(u8, value.path), .succeeded = value.succeeded, .failure = try a.dupe(u8, value.failure) };
        }
        const opposite = projection.panes[if (envelope.side == .local) 1 else 0];
        const directory = try a.dupe(u8, projection.panes[@backingInt(envelope.side)].resolved_path);
        const target = try a.dupe(u8, opposite.resolved_path);
        const next: Frozen = .{ .arena = arena, .envelope = frozen, .directory = directory, .destination = opposite.stamp, .target = target, .history = history };
        if (self.pending) |*old| old.arena.deinit();
        self.pending = next;
        self.history = entries != null;
        self.rebuild = true;
        self.open.set(false);
        self.cx.requestRedraw();
    }
    /// Presentation calls only after handlers unwind; old rows may be freed.
    pub fn sync(self: *View) !void {
        if (!self.rebuild) return;
        self.rebuild = false;
        if (self.rows_scope) |old| old.dispose();
        self.rows_scope = null;
        while (self.content.children.items.len > 0) {
            const child = self.content.children.items[0];
            self.cx.detachChild(self.content, child);
            self.cx.destroyDetached(child);
        }
        if (self.frozen) |*old| old.arena.deinit();
        self.frozen = self.pending;
        self.pending = null;
        const frozen = if (self.frozen) |*value| value else return;
        self.rows_scope = try self.scope.childScope();
        self.chrome.setStyleInline(self.cx.allocator, S.panel(self.history));
        self.rows = self.content;
        self.chrome.meta.ownership.meta.test_id = if (self.history) "files.history.menu" else "files.context.menu";
        if (self.history) {
            const heading = try ui.textStyled(self.cx, S.heading, if (self.pane.side == .local) "本地路径历史" else "远程路径历史");
            heading.setStyleInline(self.cx.allocator, .{ .height = .{ .px = 24 }, .flex_shrink = 0 });
            try self.content.appendChild(self.cx.allocator, heading);
            var row_count: usize = @max(1, frozen.history.len);
            for (frozen.history) |item| if (!item.succeeded) {
                row_count += 1;
            };
            const height: f32 = @min(104, @as(f32, @floatFromInt(row_count)) * 28 + @as(f32, @floatFromInt(row_count - 1)) * 6);
            const scroll = try ui.widgets.ScrollArea(.{ .direction = .vertical, .height = height, .rubber_band_y = false }).mount(self.rows_scope.?, self.cx);
            scroll.container.setStyleInline(self.cx.allocator, .{ .width = .fill(), .height = .{ .px = height }, .flex_shrink = 0 });
            scroll.content.setStyleInline(self.cx.allocator, .{ .width = .fill(), .direction = .column, .gap = 6 });
            try self.content.appendChild(self.cx.allocator, scroll.container);
            self.rows = scroll.content;
            if (frozen.history.len == 0) try self.add("暂无路径历史", "files.history.empty", .none, null, true);
            var position = frozen.history.len;
            while (position > 0) {
                position -= 1;
                const entry = frozen.history[position];
                const label = if (entry.succeeded) entry.path else try std.fmt.allocPrint(frozen.arena.allocator(), "{s} · {s}", .{ entry.path, entry.failure });
                try self.add(label, "files.history.navigate", .navigate, entry.path, false);
                if (!entry.succeeded) try self.add("移除当前记录", "files.history.remove", .remove, entry.path, false);
            }
        } else {
            self.rows = try ui.box(self.cx, .{ .width = .{ .px = 212 }, .height = .{ .fit = .{} }, .direction = .column, .gap = 2 }, .{});
            try self.content.appendChild(self.cx.allocator, self.rows);
            const source = self.model.projection().?.panes[@backingInt(self.pane.side)];
            try self.add(if (self.pane.side == .local) "上传所选…" else "下载所选…", "files.context.transfer", .transfer, null, !source.can_transfer or frozen.envelope.action.context.keys.len == 0);
            try self.add("复制完整路径", "files.context.copy", .copy, null, frozen.envelope.action.context.keys.len == 0);
            try self.add("重命名", "files.context.rename", .none, null, true);
            try self.add("新建文件夹…", "files.context.mkdir", .mkdir, null, !source.can_mkdir);
        }
        self.feedback = try ui.textStyled(self.cx, S.feedback, "");
        self.feedback.?.meta.ownership.meta.test_id = "files.menu.feedback";
        self.feedback.?.setDisplay(.none);
        try self.content.appendChild(self.cx.allocator, self.feedback.?);
        self.open.set(true);
        self.cx.requestRedraw();
    }
    const Kind = enum { none, transfer, copy, mkdir, navigate, remove };
    const Action = struct {
        menu: *View,
        kind: Kind,
        path: ?[]const u8,
        node: ?*ui.Node = null,
        fn click(self: *Action) void {
            const menu = self.menu;
            const clicked_rect = if (self.node) |node| node.globalRect() else menu.pane.context_button.globalRect();
            const frozen = menu.frozen orelse return;
            var envelope = frozen.envelope;
            envelope.action = switch (self.kind) {
                .transfer => .{ .transfer = .{ .selection = frozen.envelope.action.context, .destination = frozen.destination, .directory = frozen.target } },
                .copy => .{ .copy_paths = frozen.envelope.action.context },
                .mkdir => .new_folder,
                .navigate => .{ .navigate = .{ .requested_path = self.path.?, .base_directory = frozen.directory } },
                .remove => {
                    menu.model.removeHistory(envelope, self.path.?) catch |err| {
                        menu.fail(err);
                        return;
                    };
                    menu.open.set(false);
                    return;
                },
                .none => return,
            };
            menu.model.handle(envelope) catch |err| {
                menu.fail(err);
                return;
            };
            if (self.kind == .copy) receipts.acknowledgeAt(menu.cx, clicked_rect, "路径已复制") catch {};
            menu.open.set(false);
            menu.cx.requestRedraw();
        }
    };
    fn add(self: *View, label: []const u8, id: []const u8, kind: Kind, path: ?[]const u8, disabled: bool) !void {
        const scope = self.rows_scope.?;
        const action = try scope.createState(Action, .{ .menu = self, .kind = kind, .path = path });
        const icon: ?ui.SvgAsset = if (self.history) null else switch (kind) {
            .transfer => if (self.pane.side == .local) ui.icons.arrow_up_from_line else ui.icons.arrow_down_to_line,
            .copy => ui.icons.copy,
            .mkdir => ui.icons.folder_plus,
            else => ui.icons.pencil,
        };
        const button = try ui.widgets.Button(.{ .label = label, .icon_asset = icon, .icon_size = @as(f32, 14), .variant = .ghost, .disabled = disabled, .base_style = S.row(self.history), .hover_style = S.hover(), .on_click = self.cx.on(Action, action, Action.click) }).mount(scope, self.cx);
        action.node = button;
        button.meta.ownership.meta.test_id = id;
        button.setStyleInline(self.cx.allocator, .{ .width = .{ .px = if (self.history) 320 else 212 }, .height = .{ .px = if (self.history) 28 else 34 }, .direction = .row, .justify = .start, .gap = 10, .padding = .{ .left = 10, .right = 10 }, .flex_shrink = 0 });
        try self.rows.appendChild(self.cx.allocator, button);
    }
    fn fail(self: *View, err: anyerror) void {
        if (self.feedback) |node| {
            node.setDisplay(.flex);
            node.setTextContent(self.cx.allocator, @errorName(err)) catch {};
        }
        self.cx.requestRedraw();
    }
    fn cleanup(self: *View) void {
        if (self.pending) |*value| value.arena.deinit();
        if (self.frozen) |*value| value.arena.deinit();
    }
};
