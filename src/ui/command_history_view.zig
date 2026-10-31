//! Per-execution terminal history. Opening or locating a record never writes PTY input.
//! Showing a card never replays a command or changes PTY input.
const std = @import("std");
const ui = @import("ui");
const Workspace = @import("workspace.zig").Workspace;
const Terminal = @import("terminal_view.zig").TerminalViewNode;
const Command = @import("../vt/snapshot.zig").Command;
const annotations = @import("command_annotations.zig");
const S = @import("command_history_styles.zig");
const clock = @import("../platform/realtime.zig");

pub const Mode = enum { closed, preview, pinned };
pub const View = struct {
    cx: *ui.Cx,
    scope: *ui.Scope,
    workspace: *Workspace,
    root: *ui.Node,
    title: *ui.Node,
    count: *ui.Node,
    scroll: ui.widgets.ScrollAreaResult,
    empty: *ui.Node,
    virtual: *ui.widgets.VirtualListState,
    records: std.ArrayList(Command) = .empty,
    buttons: [2]*ui.Node,
    rows: std.ArrayList(Row) = .empty,
    mode: Mode = .closed,
    suppressed: bool = false,
    leave_ns: ?i128 = null,
    signature: u64 = 0,
    active_id: u64 = 0,
    visible_count: usize = 0,
    colors: S.theme.Colors,
    const Action = struct {
        view: *View,
        id: u64 = 0,
        owner_id: u64 = 0,
        fn invoke(action: *Action) void {
            const self = action.view;
            if (self.active_id != action.owner_id) return;
            const terminal_node = self.terminal() orelse return;
            self.mode = .pinned;
            _ = terminal_node.locateCommand(action.id);
            self.cx.requestRedraw();
        }
    };
    const Row = struct { root: *ui.Node, card: *ui.Node, state: *ui.Node, command: *ui.Node, meta: *ui.Node, tip: *ui.Node, tip_open: ?*ui.Signal(bool), action: *Action };

    pub fn mount(cx: *ui.Cx, scope: *ui.Scope, workspace: *Workspace, ssh_bar: *ui.Node, local_bar: *ui.Node) !*View {
        const self = try cx.allocator.create(View);
        const root = try ui.box(cx, S.panel(), .{});
        root.meta.ownership.meta.test_id = "terminal.command-history";
        root.setDisplay(.none);
        const header = try ui.box(cx, .{ .width = .fill(), .height = .{ .px = 24 }, .direction = .row, .align_items = .center, .gap = 7, .flex_shrink = 0 }, .{});
        try header.appendChild(cx.allocator, try ui.iconTint(cx, ui.icons.list_restart, S.theme.current().fg_2, .{ .width = .{ .px = 14 }, .height = .{ .px = 14 } }));
        try header.appendChild(cx.allocator, try ui.text(cx, "命令历史", S.text(13, 600, false)));
        try header.appendChild(cx.allocator, try ui.spacer(cx));
        const close = try ui.widgets.Button(.{ .variant = .ghost, .icon_only = true, .a11y_label = "关闭命令历史", .base_style = @import("socks_info_styles.zig").iconButton(24), .on_click = cx.on(View, self, hide) }).mount(scope, cx);
        close.meta.ownership.meta.test_id = "terminal.command-history.close";
        try close.appendChild(cx.allocator, try ui.iconTint(cx, ui.icons.x, S.theme.current().fg_2, .{ .width = .{ .px = 14 }, .height = .{ .px = 14 } }));
        try header.appendChild(cx.allocator, close);
        try root.appendChild(cx.allocator, header);
        const info = try ui.box(cx, .{ .width = .fill(), .height = .{ .px = 18 }, .direction = .row, .align_items = .center, .gap = 8, .flex_shrink = 0 }, .{});
        const title = try ui.text(cx, "", S.text(11, 400, true));
        title.setStyleInline(cx.allocator, .{ .width = .fill(), .flex = 1, .min_width = 0 });
        const count = try ui.text(cx, "", S.text(11, 400, true));
        try info.appendChild(cx.allocator, title);
        try info.appendChild(cx.allocator, count);
        try root.appendChild(cx.allocator, info);
        const list = try ui.widgets.VirtualList(.{ .item_count = @as(usize, 0), .measure_items = true, .estimate_item_height = 79, .overscan = 2 }).mountWithContext(scope, cx, self, null, renderItem);
        const scroll: ui.widgets.ScrollAreaResult = .{ .container = list.container, .content = list.state.content_node, .state = list.state.scroll_state };
        scroll.container.setStyleInline(cx.allocator, .{ .width = .fill(), .height = .fill(), .flex = 1, .min_height = 0 });
        scroll.content.setStyleInline(cx.allocator, .{ .width = .fill(), .padding = .{} });
        try root.appendChild(cx.allocator, scroll.container);
        const empty = try ui.text(cx, "本会话还没有命令记录", S.text(12, 400, true));
        empty.meta.ownership.meta.test_id = "terminal.command-history.empty";
        empty.setStyleInline(cx.allocator, .{ .width = .fill(), .height = .{ .px = 70 }, .padding = .{ .top = 18 } });
        try root.appendChild(cx.allocator, empty);
        self.* = .{ .cx = cx, .scope = scope, .workspace = workspace, .root = root, .title = title, .count = count, .scroll = scroll, .empty = empty, .virtual = list.state, .buttons = undefined, .colors = S.theme.current() };
        try scope.onCleanup(View, self, cleanup);
        self.buttons = .{ try self.button(ssh_bar, "status.command-history"), try self.button(local_bar, "local.status.command-history") };
        try cx.root.?.appendChild(cx.allocator, root);
        try cx.addAfterLayoutHook(self, tick);
        return self;
    }
    fn button(self: *View, bar: *ui.Node, id: []const u8) !*ui.Node {
        const trigger = try ui.widgets.Button(.{ .variant = .ghost, .icon_only = true, .a11y_label = "命令历史 · ⇧⌘B", .base_style = @import("status_connection_styles.zig").metricTrigger(28), .hover_style = .{ .background = S.theme.current().hover }, .on_click = self.cx.on(View, self, toggle) }).mount(self.scope, self.cx);
        trigger.setStyleInline(self.cx.allocator, .{ .align_items = .center, .justify = .center, .padding = .{}, .gap = 0 });
        trigger.meta.ownership.meta.test_id = id;
        try trigger.appendChild(self.cx.allocator, try ui.iconTint(self.cx, ui.icons.list_restart, S.theme.current().fg_2, .{ .width = .{ .px = 15 }, .height = .{ .px = 15 } }));
        try bar.appendChild(self.cx.allocator, trigger);
        return trigger;
    }
    fn terminal(self: *View) ?*Terminal {
        const index = self.workspace.active_tab orelse return null;
        if (index >= self.workspace.tabs.items.len) return null;
        const tab = self.workspace.tabs.items[index];
        if (tab.terminal == null) return null;
        return &tab.terminal.?;
    }
    pub fn show(self: *View, enabled: bool) void {
        if (enabled and self.terminal() == null) return;
        self.mode = if (enabled) .pinned else .closed;
        if (enabled) if (self.terminal()) |terminal_node| terminal_node.refreshCommandHistory(true);
        self.suppressed = !enabled;
        self.leave_ns = null;
        self.cx.requestRedraw();
    }
    pub fn toggle(self: *View) void {
        self.show(self.mode != .pinned);
    }
    pub fn hide(self: *View) void {
        self.show(false);
    }
    fn contains(self: *View, node: *ui.Node) bool {
        if (!node.isDisplayedInTree()) return false;
        const r = node.globalRect();
        return r.w > 0 and r.h > 0 and self.cx.mouse_x >= r.x and self.cx.mouse_x <= r.x + r.w and self.cx.mouse_y >= r.y and self.cx.mouse_y <= r.y + r.h;
    }
    fn tick(raw: *anyopaque, _: u8, _: bool) ui.AfterLayoutResult {
        const self: *View = @ptrCast(@alignCast(raw));
        self.update() catch |err| std.log.debug("command history: {s}", .{@errorName(err)});
        return .done;
    }
    fn update(self: *View) !void {
        const active = self.terminal();
        for (self.buttons) |button_node| button_node.setDisplay(if (active != null) .flex else .none);
        if (active == null) self.mode = .closed;
        const inside = self.contains(self.buttons[0]) or self.contains(self.buttons[1]);
        if (!inside) self.suppressed = false;
        if (inside and self.mode == .closed and !self.suppressed) self.mode = .preview;
        if (self.mode == .preview) {
            if (inside or self.contains(self.root)) self.leave_ns = null else {
                const now = clock.monotonicNs();
                if (self.leave_ns) |start| {
                    if (now - start >= 150 * std.time.ns_per_ms) self.mode = .closed;
                } else self.leave_ns = now;
            }
            self.cx.scheduleRedrawAfterNs(50 * std.time.ns_per_ms);
        }
        self.root.setDisplay(if (self.mode == .closed) .none else .flex);
        if (self.mode == .closed) return;
        const terminal_node = active.?;
        const tab = self.workspace.tabs.items[self.workspace.active_tab.?];
        const pane = tab.root.globalRect();
        const id = @as(u64, @intCast(tab.id));
        var hasher = std.hash.Wyhash.init(id);
        terminal_node.refreshCommandHistory(false);
        const commands = terminal_node.commandHistory();
        for (commands) |command| {
            std.hash.autoHash(&hasher, .{ command.id, command.state, command.exit_code, command.ai_execution_id, command.start_ms });
            if (command.command) |text| hasher.update(text);
            const elapsed = if (terminal_node.commandElapsed(command)) |ms| ms / 250 else 0;
            hasher.update(std.mem.asBytes(&elapsed));
            if (command.state == .running) self.cx.scheduleRedrawAfterNs(250 * std.time.ns_per_ms);
        }
        hasher.update(std.mem.asBytes(&terminal_node.command_history_partial));
        hasher.update(std.mem.asBytes(&terminal_node.command_history_pending));
        self.cx.scheduleRedrawAfterNs(500 * std.time.ns_per_ms);
        if (self.signature != hasher.final() or self.active_id != id or !std.meta.eql(self.colors, S.theme.current())) {
            self.colors = S.theme.current();
            self.root.setStyleInline(self.cx.allocator, .{ .background = self.colors.overlay, .glass = S.theme.overlayGlass() });
            self.signature = hasher.final();
            self.active_id = id;
            try self.rebuild(terminal_node, commands, tab.titleSlice());
        }
        const w = @min(if (self.cx.viewport.width < 1000) @as(f32, 320) else S.width, @max(0, pane.w - 24));
        const content_height: f32 = if (self.visible_count == 0) 70 else self.virtual.totalContentHeight();
        const h = @min(@min(@as(f32, 475), @max(120, pane.h - 24)), 86 + content_height);
        self.root.setStyleInline(self.cx.allocator, .{ .inset = .{ .left = .{ .px = pane.x + pane.w - w - 12 }, .top = .{ .px = pane.y + pane.h - h - 12 } }, .width = .{ .px = w }, .height = .{ .px = h } });
    }
    fn clearRecords(self: *View) void {
        for (self.records.items) |command| if (command.command) |text| self.cx.allocator.free(text);
        self.records.deinit(self.cx.allocator);
        self.records = .empty;
    }
    fn rebuild(self: *View, _: *Terminal, commands: []const Command, owner_name: []const u8) !void {
        self.clearRecords();
        try self.records.ensureTotalCapacity(self.cx.allocator, commands.len);
        for (commands) |command| {
            var copy = command;
            copy.command = if (command.command) |text| try self.cx.allocator.dupe(u8, text) else null;
            self.records.appendAssumeCapacity(copy);
        }
        std.mem.sort(Command, self.records.items, {}, struct {
            fn less(_: void, left: Command, right: Command) bool {
                return left.id > right.id;
            }
        }.less);
        self.visible_count = self.records.items.len;
        self.empty.setDisplay(if (self.visible_count == 0) .flex else .none);
        self.scroll.container.setDisplay(if (self.visible_count == 0) .none else .flex);
        try self.title.setTextContent(self.cx.allocator, owner_name);
        const terminal_node = self.terminal().?;
        var count: [80]u8 = undefined;
        try self.count.setTextContent(self.cx.allocator, try std.fmt.bufPrint(&count, "{d} 条{s}", .{ self.visible_count, if (terminal_node.command_history_partial) " · 部分记录" else if (terminal_node.command_history_pending) " · 同步中" else "" }));
        ui.widgets.virtual_list.updateItemCount(self.virtual, self.visible_count);
        ui.widgets.virtual_list.refreshRange(self.virtual, 0, self.visible_count);
    }
    fn renderItem(node: *ui.Node, index: usize, _: *ui.Cx, raw: ?*anyopaque) void {
        const self: *View = @ptrCast(@alignCast(raw orelse return));
        self.renderRecord(node, index) catch |err| std.log.debug("command history row: {s}", .{@errorName(err)});
    }
    fn renderRecord(self: *View, node: *ui.Node, index: usize) !void {
        if (index >= self.records.items.len) return;
        node.setStyleInline(self.cx.allocator, .{ .width = .fill(), .height = .{ .fit = .{} }, .padding = .{ .bottom = 8 }, .flex_shrink = 0 });
        var found: ?Row = null;
        for (self.rows.items) |row| if (row.root.parent == node) {
            found = row;
            break;
        };
        const row = found orelse try self.makeRow(node);
        const value = self.records.items[index];
        const terminal_node = self.terminal() orelse return;
        row.action.id = value.id;
        row.action.owner_id = self.active_id;
        row.root.setDisplay(.flex);
        row.card.setStyleInline(self.cx.allocator, S.row());
        row.command.setTextColor(self.colors.fg_1);
        row.state.setTextColor(switch (value.state) {
            .running => self.colors.accent,
            .succeeded => self.colors.ok_ink,
            .failed => self.colors.danger,
            .unknown => self.colors.fg_3,
        });
        try row.state.setTextContent(self.cx.allocator, annotations.glyph(value.state));
        row.meta.setTextColor(self.colors.fg_2);
        try row.command.setTextContent(self.cx.allocator, value.command orelse "命令文本未知");
        const location_available = terminal_node.commandLocationAvailable(value.id);
        if (location_available) try row.tip.setTextContent(self.cx.allocator, value.command orelse "命令文本未知") else {
            const tooltip = try std.fmt.allocPrint(self.cx.allocator, "{s}\n\n原输出位置不在当前保留范围中，可在会话记录中回看。", .{value.command orelse "命令文本未知"});
            defer self.cx.allocator.free(tooltip);
            try row.tip.setTextContent(self.cx.allocator, tooltip);
        }
        var date: [48]u8 = undefined;
        const date_text = if (value.start_ms > 0) @import("history_styles.zig").dateLabel(&date, value.start_ms) else "时间未知";
        var elapsed: [40]u8 = undefined;
        const elapsed_text = try annotations.duration(&elapsed, terminal_node.commandElapsed(value));
        var code: [30]u8 = undefined;
        const code_text = if (value.exit_code) |exit| try std.fmt.bufPrint(&code, "{d}", .{exit}) else "—";
        var meta: [180]u8 = undefined;
        try row.meta.setTextContent(self.cx.allocator, try std.fmt.bufPrint(&meta, "{s}{s} · {s} · {s}{s}", .{ date_text, if (value.ai_execution_id != null) " · AI" else "", code_text, elapsed_text, if (location_available) "" else " · 定位不可用" }));
    }
    fn makeRow(self: *View, host_node: *ui.Node) !Row {
        const tip = try ui.widgets.Tooltip(.{ .text = "", .open_delay_ms = 450, .position = .left, .width = @as(f32, 400), .wrap = .char, .font_size = 12, .background = self.colors.overlay, .text_color = self.colors.fg_1 }).mount(self.scope, self.cx);
        tip.wrapper.setStyleInline(self.cx.allocator, .{ .width = .fill(), .height = .{ .fit = .{} }, .min_width = 0, .flex_shrink = 0 });
        const row = tip.trigger;
        row.setStyleInline(self.cx.allocator, S.row());
        row.meta.ownership.meta.test_id = "terminal.command-history.record";
        tip.content.meta.ownership.meta.test_id = "terminal.command-history.tooltip";
        const headline = try ui.box(self.cx, .{ .width = .fill(), .height = .{ .fit = .{} }, .direction = .row, .align_items = .start, .gap = 7, .min_width = 0 }, .{});
        const state = try ui.text(self.cx, "", S.text(12, 500, false));
        state.setStyleInline(self.cx.allocator, .{ .width = .{ .px = 12 }, .flex_shrink = 0 });
        try headline.appendChild(self.cx.allocator, state);
        var command_style = S.text(12, 400, false);
        command_style.use_monospace_font = true;
        command_style.wrap = .char;
        const command = try ui.text(self.cx, "", command_style);
        command.setStyleInline(self.cx.allocator, .{ .width = .fill(), .height = .{ .fit = .{} }, .max_height = 54, .min_width = 0, .flex = 1, .overflow = .hidden });
        command.meta.ownership.meta.test_id = "terminal.command-history.command";
        try headline.appendChild(self.cx.allocator, command);
        const meta = try ui.text(self.cx, "", S.text(10.5, 400, true));
        meta.setStyleInline(self.cx.allocator, .{ .width = .fill(), .height = .{ .px = 18 }, .padding = .{ .left = 19 } });
        try row.appendChild(self.cx.allocator, headline);
        try row.appendChild(self.cx.allocator, meta);
        const action = try self.scope.createState(Action, .{ .view = self });
        _ = ui.clickable(row, self.cx.on(Action, action, Action.invoke));
        try host_node.appendChild(self.cx.allocator, tip.wrapper);
        const result: Row = .{ .root = tip.wrapper, .card = row, .state = state, .command = command, .meta = meta, .tip = tip.content.children.items[0], .tip_open = tip.open, .action = action };
        try self.rows.append(self.cx.allocator, result);
        return result;
    }
    fn cleanup(self: *View) void {
        self.cx.removeAfterLayoutHook(self);
        self.clearRecords();
        self.rows.deinit(self.cx.allocator);
        self.cx.allocator.destroy(self);
    }
};
