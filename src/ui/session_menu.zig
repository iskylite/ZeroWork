//! The + menu captures stable saved-asset IDs; it never creates a transport.
const std = @import("std");
const ui = @import("ui");
const Workspace = @import("workspace.zig").Workspace;
const Host = @import("../config/hosts.zig").HostConfig;
const S = @import("session_menu_styles.zig");

pub const Callbacks = struct {
    context: *anyopaque,
    new_profile: *const fn (*anyopaque) void,
    choose_saved: *const fn (*anyopaque, u64) void,
    local: ?*const fn (*anyopaque) void = null,
    local_unavailable_reason: []const u8 = "Local 运行适配器尚未接入",
};
const Selection = union(enum) { none, local, saved: u64, new_profile };

pub const View = struct {
    cx: *ui.Cx,
    scope: *ui.Scope,
    workspace: *Workspace,
    callbacks: Callbacks,
    root: *ui.Node = undefined,
    chrome: *ui.Node = undefined,
    content: *ui.Node = undefined,
    input: ui.widgets.input.InputResult = undefined,
    scroll: ui.widgets.ScrollAreaResult = undefined,
    open: *ui.Signal(bool),
    query: *ui.Signal([]const u8),
    anchor_id: ?u32 = null,
    results: std.ArrayList(u64) = .empty,
    row_scope: ?*ui.Scope = null,
    generation: u64 = 0,
    query_revision: u64 = 0,
    selected: Selection = .none,
    pending: bool = false,
    paint_revision: u32 = 0,
    chosen: bool = false,
    local_button: *ui.Node = undefined,
    new_button: *ui.Node = undefined,
    saved_count: *ui.Node = undefined,

    pub fn mount(cx: *ui.Cx, scope: *ui.Scope, workspace: *Workspace, callbacks: Callbacks) !*View {
        const self = try cx.allocator.create(View);
        var adopted = false;
        errdefer if (!adopted) cx.allocator.destroy(self);
        const open = try scope.createSignal(bool, false);
        const query = try scope.createText("", .{});
        self.* = .{ .cx = cx, .scope = scope, .workspace = workspace, .callbacks = callbacks, .open = open, .query = query };
        try scope.onCleanup(View, self, cleanup);
        adopted = true;
        const popover = try ui.widgets.Popover(.{ .open = open, .trigger = .manual, .anchor = .{ .virtual = .{ .ctx = self, .getRect = anchorRect } }, .position = .bottom_start, .width = S.width, .max_width = S.width, .offset = .{ .static = 4 }, .viewport_padding = 8, .constrain_width_to_viewport = true, .shift_main_axis = true, .size_policy = .fit_content, .close_on_escape = false, .on_open_change = cx.on(View, self, openChanged) }).mount(scope, cx);
        self.scope = popover.scope;
        self.root = popover.wrapper;
        self.chrome = popover.chrome;
        self.content = popover.content;
        popover.chrome.setStyleInline(cx.allocator, S.panel());
        popover.chrome.meta.ownership.meta.test_id = "session.menu";
        popover.chrome.behavior.events.capture_context = self;
        popover.chrome.behavior.events.on_event_capture = onEvent;
        self.input = try ui.widgets.Input(.{ .value = query, .placeholder = "搜索连接…", .leading_icon_asset = ui.icons.search, .on_change = cx.on(View, self, queryChanged), .on_submit = cx.on(View, self, submit) }).mountResult(popover.scope, cx);
        self.input.input_container.setStyleInline(cx.allocator, S.search());
        self.input.node.meta.ownership.meta.test_id = "session.menu.search";
        try self.content.appendChild(cx.allocator, self.input.node);
        const local_tip = try ui.widgets.Tooltip(.{ .text = if (callbacks.local != null) "新建本地 zsh 会话" else callbacks.local_unavailable_reason, .open_delay_ms = 450 }).mount(popover.scope, cx);
        const local = try ui.widgets.Button(.{ .a11y_label = "本地终端 · zsh", .variant = .ghost, .disabled = callbacks.local == null, .on_click = cx.on(View, self, chooseLocal), .base_style = S.row(false, 34, 10), .hover_style = S.hover() }).mount(popover.scope, cx);
        local.setStyleInline(cx.allocator, S.row(false, 34, 10));
        try appendButtonContent(cx, local, ui.icons.terminal, "本地终端", .local);
        local.meta.ownership.meta.test_id = "session.menu.local";
        self.local_button = local;
        try local_tip.trigger.appendChild(cx.allocator, local);
        local_tip.wrapper.style.width = .fill();
        local_tip.wrapper.style.height = .{ .px = 34 };
        local_tip.trigger.style.width = .fill();
        local_tip.trigger.style.height = .{ .px = 34 };
        try self.content.appendChild(cx.allocator, local_tip.wrapper);
        const label = try ui.box(cx, S.savedLabel(), .{});
        const saved_title = try ui.text(cx, "已保存连接", S.savedLabelText());
        saved_title.setStyleInline(cx.allocator, .{ .width = .fill(), .flex = 1, .min_width = 0 });
        saved_title.meta.ownership.meta.test_id = "session.menu.saved_label";
        try label.appendChild(cx.allocator, saved_title);
        var count_style = S.savedLabelText();
        count_style.text_align = .end;
        self.saved_count = try ui.text(cx, "0", count_style);
        self.saved_count.setStyleInline(cx.allocator, .{ .width = .{ .px = 20 }, .flex_shrink = 0 });
        self.saved_count.meta.ownership.meta.test_id = "session.menu.saved_count";
        try label.appendChild(cx.allocator, self.saved_count);
        try self.content.appendChild(cx.allocator, label);
        self.scroll = try ui.widgets.ScrollArea(.{ .direction = .vertical, .height = S.group_max_height, .rubber_band_y = false }).mount(popover.scope, cx);
        self.scroll.content.setStyleInline(cx.allocator, S.group());
        self.scroll.container.meta.ownership.meta.test_id = "session.menu.saved";
        self.scroll.container.style.flex_shrink = 0;
        try self.content.appendChild(cx.allocator, self.scroll.container);
        const add = try ui.widgets.Button(.{ .a11y_label = "新建连接", .variant = .ghost, .on_click = cx.on(View, self, chooseNew), .base_style = S.row(false, 32, 10), .hover_style = S.hover() }).mount(popover.scope, cx);
        add.setStyleInline(cx.allocator, S.row(false, 32, 10));
        try appendButtonContent(cx, add, ui.icons.plus, "新建连接", .none);
        add.meta.ownership.meta.test_id = "session.menu.new_profile";
        self.new_button = add;
        try self.content.appendChild(cx.allocator, add);
        try cx.addAfterLayoutHook(self, afterLayout);
        return self;
    }

    pub fn show(self: *View, anchor: *ui.Node) !void {
        if (self.generation == std.math.maxInt(u64)) return error.GenerationExhausted;
        self.generation += 1;
        self.retheme();
        self.anchor_id = anchor.id;
        self.query.set("");
        self.query_revision = 0;
        self.selected = .none;
        self.chosen = false;
        self.pending = true;
        self.cx.setFocus(anchor);
        self.open.set(true);
        self.cx.setFocus(self.input.input_container);
        self.cx.requestRedraw();
    }
    pub fn hide(self: *View) void {
        self.open.set(false);
        self.restoreFocus();
        self.cx.requestRedraw();
    }
    pub fn isOpen(self: *const View) bool {
        return self.open.peek();
    }
    fn retheme(self: *View) void {
        const c = S.theme.current();
        self.chrome.setBackground(c.overlay);
        self.input.input_container.setBackground(c.well);
        self.input.input_container.setBorderColor(ui.Color.TRANSPARENT);
        self.input.state.tokens = self.cx.tokens;
        self.input.state.placeholder_color = c.fg_3;
        self.input.state.dirty = true;
        if (self.input.state.text_display_node) |node| node.setTextColor(c.fg_1);
        self.scroll.content.setBackground(c.surface_1);
        self.saved_count.setTextColor(c.fg_3);
        self.paint_revision = self.cx.theme_version;
    }
    pub fn handleKey(self: *View, key: ui.events.KeyCode) ui.events.EventResult {
        if (!self.isOpen() or self.input.state.imeIsComposing()) return .ignored;
        switch (key) {
            .escape => self.hide(),
            .up, .down => {
                if (self.pending) return .stop;
                self.move(key == .down);
                self.pending = true;
                self.cx.requestRedraw();
            },
            .@"return" => if (!self.pending) self.activate(self.selected),
            else => return .ignored,
        }
        return .stop;
    }

    /// Called by an after-layout hook, after the input/click callback unwinds.
    pub fn flush(self: *View) !void {
        if (!self.pending or !self.isOpen()) return;
        self.results.clearRetainingCapacity();
        for (self.workspace.registry.hosts, 0..) |host, index| {
            if (!matches(host, self.query.peek())) continue;
            const id = self.workspace.hostId(index) orelse continue;
            try self.results.append(self.cx.allocator, id);
        }
        var count_buffer: [20]u8 = undefined;
        try self.saved_count.setTextContent(self.cx.allocator, try std.fmt.bufPrint(&count_buffer, "{d}", .{self.results.items.len}));
        if (self.selected == .none) {
            self.selected = if (self.query.peek().len == 0 and self.callbacks.local != null) .local else if (self.results.items.len > 0) .{ .saved = self.results.items[0] } else .none;
        }
        if (self.selected == .saved and self.workspace.hostIndex(self.selected.saved) == null) self.selected = .none;
        if (self.row_scope) |old| old.dispose();
        self.row_scope = null;
        while (self.scroll.content.children.items.len > 0) {
            const node = self.scroll.content.children.items[0];
            self.cx.detachChild(self.scroll.content, node);
            self.cx.destroyDetached(node);
        }
        const rows_scope = try self.scope.childScope();
        self.row_scope = rows_scope;
        if (self.results.items.len == 0) {
            const empty = try ui.box(self.cx, .{ .width = .fill(), .height = .{ .px = 32 }, .align_items = .center }, .{try ui.text(self.cx, "没有匹配的连接", S.label())});
            empty.meta.ownership.meta.test_id = "session.menu.empty";
            try self.scroll.content.appendChild(self.cx.allocator, empty);
        }
        for (self.results.items) |id| {
            const index = self.workspace.hostIndex(id) orelse continue;
            if (index >= self.workspace.registry.hosts.len) continue;
            const host = self.workspace.registry.hosts[index];
            const row = try self.cx.allocator.create(Row);
            var adopted = false;
            errdefer if (!adopted) self.cx.allocator.destroy(row);
            const name = try self.cx.allocator.dupe(u8, host.name);
            errdefer if (!adopted) self.cx.allocator.free(name);
            const test_id = try std.fmt.allocPrint(self.cx.allocator, "session.menu.saved.{d}", .{id});
            errdefer if (!adopted) self.cx.allocator.free(test_id);
            row.* = .{ .view = self, .id = id, .generation = self.generation, .revision = self.query_revision, .name = name, .test_id = test_id };
            try rows_scope.onCleanup(Row, row, Row.cleanup);
            adopted = true;
            const active = self.selected == .saved and self.selected.saved == id;
            const button = try ui.widgets.Button(.{ .variant = .ghost, .a11y_label = row.name, .on_click = self.cx.on(Row, row, Row.choose), .base_style = S.row(active, S.row_height, 8), .hover_style = S.hover() }).mount(rows_scope, self.cx);
            button.setStyleInline(self.cx.allocator, S.row(active, S.row_height, 8));
            button.meta.ownership.meta.test_id = row.test_id;
            try appendButtonContent(self.cx, button, if (host.protocol == .sftp) ui.icons.folder_open else ui.icons.server, row.name, if (host.protocol == .sftp) .sftp else .saved);
            try self.scroll.content.appendChild(self.cx.allocator, button);
        }
        const count = @max(@as(usize, 1), @min(self.results.items.len, 3));
        const height = 8 + @as(f32, @floatFromInt(count)) * S.row_height + @as(f32, @floatFromInt(count - 1)) * 2;
        self.scroll.container.style.height = .{ .px = height };
        self.local_button.setBackground(if (self.selected == .local) S.theme.current().selection else ui.Color.TRANSPARENT);
        self.new_button.setBackground(if (self.selected == .new_profile) S.theme.current().selection else ui.Color.TRANSPARENT);
        self.scroll.container.markLayoutDirty();
        self.pending = false;
    }

    fn queryChanged(self: *View, _: []const u8) void {
        if (self.query_revision == std.math.maxInt(u64)) {
            self.hide();
            return;
        }
        self.query_revision += 1;
        self.selected = .none;
        self.pending = true;
        self.cx.requestRedraw();
    }
    fn submit(self: *View, _: []const u8) void {
        _ = self.handleKey(.@"return");
    }
    fn chooseLocal(self: *View) void {
        self.activate(.local);
    }
    fn chooseNew(self: *View) void {
        self.activate(.new_profile);
    }
    fn activate(self: *View, target: Selection) void {
        if (!self.isOpen() or self.chosen) return;
        switch (target) {
            .none => return,
            .local => if (self.callbacks.local == null) return,
            .saved => |id| {
                const index = self.workspace.hostIndex(id) orelse return;
                if (index >= self.workspace.registry.hosts.len or !matches(self.workspace.registry.hosts[index], self.query.peek())) return;
            },
            .new_profile => {},
        }
        self.chosen = true;
        self.hide();
        switch (target) {
            .none => {},
            .local => self.callbacks.local.?(self.callbacks.context),
            .saved => |id| self.callbacks.choose_saved(self.callbacks.context, id),
            .new_profile => self.callbacks.new_profile(self.callbacks.context),
        }
    }
    fn move(self: *View, next: bool) void {
        const local_count: usize = if (self.callbacks.local != null) 1 else 0;
        const count = local_count + self.results.items.len + 1;
        var current: ?usize = null;
        switch (self.selected) {
            .none => {},
            .local => current = 0,
            .new_profile => current = count - 1,
            .saved => |id| for (self.results.items, 0..) |candidate, index| {
                if (id == candidate) {
                    current = local_count + index;
                    break;
                }
            },
        }
        const index = if (current) |i| (if (next) (i + 1) % count else (i + count - 1) % count) else (if (next) @as(usize, 0) else count - 1);
        self.selected = if (index == count - 1) .new_profile else if (local_count == 1 and index == 0) .local else .{ .saved = self.results.items[index - local_count] };
    }
    fn openChanged(self: *View, open: bool) void {
        if (!open) self.restoreFocus();
    }
    fn restoreFocus(self: *View) void {
        if (self.anchorNode()) |anchor| self.cx.setFocus(anchor);
    }
    fn anchorNode(self: *View) ?*ui.Node {
        return find(self.cx.root orelse return null, self.anchor_id orelse return null);
    }
    fn anchorRect(raw: *anyopaque) ui.widgets.popover.AnchorRect {
        const self: *View = @ptrCast(@alignCast(raw));
        const node = self.anchorNode() orelse return .{ .x = 0, .y = 0, .w = 0, .h = 0 };
        const r = node.globalRect();
        const shell = @import("shell_styles.zig");
        return .{ .x = r.x, .y = r.y, .w = r.w, .h = @max(r.h, shell.outer + shell.title_height - r.y) };
    }
    fn afterLayout(raw: *anyopaque, _: u8, _: bool) ui.AfterLayoutResult {
        const self: *View = @ptrCast(@alignCast(raw));
        if (!self.isOpen()) return .done;
        if (self.anchorNode() == null) {
            self.hide();
            return .done;
        }
        if (self.paint_revision != self.cx.theme_version) {
            self.retheme();
            self.pending = true;
        }
        if (!self.pending) return .done;
        self.flush() catch {
            self.selected = .none;
            self.pending = false;
            return .done;
        };
        return .needs_layout;
    }
    fn onEvent(event: ui.events.Event, context: ?*anyopaque) ui.events.EventResult {
        const self: *View = @ptrCast(@alignCast(context orelse return .ignored));
        return if (event == .key_down) self.handleKey(event.key_down.key) else .ignored;
    }
    fn cleanup(self: *View) void {
        self.cx.removeAfterLayoutHook(self);
        self.results.deinit(self.cx.allocator);
        self.cx.allocator.destroy(self);
    }
};
const RowTail = enum { none, local, saved, sftp };
fn appendButtonContent(cx: *ui.Cx, button: *ui.Node, asset: ui.SvgAsset, label: []const u8, tail: RowTail) !void {
    const content = try ui.box(cx, S.rowContent(), .{});
    try button.appendChild(cx.allocator, content);
    try content.appendChild(cx.allocator, try ui.iconTint(cx, asset, S.theme.current().fg_2, .{ .width = .{ .px = 16 }, .height = .{ .px = 16 }, .flex_shrink = 0 }));
    const text = try ui.text(cx, label, S.label());
    text.setStyleInline(cx.allocator, .{ .width = .fill(), .flex = 1, .min_width = 0 });
    try content.appendChild(cx.allocator, text);
    if (tail != .none) {
        var style = S.protocol();
        style.text_align = .end;
        if (tail == .local) style.use_monospace_font = false;
        const protocol = try ui.text(cx, switch (tail) {
            .local => "zsh",
            .sftp => "SFTP",
            else => "SSH",
        }, style);
        protocol.style.width = .{ .px = if (tail == .local) 28 else 40 };
        protocol.style.flex_shrink = 0;
        try content.appendChild(cx.allocator, protocol);
        if (tail == .local) try content.appendChild(cx.allocator, try ui.iconTint(cx, ui.icons.corner_down_left, S.theme.current().fg_3, .{ .width = .{ .px = 12 }, .height = .{ .px = 12 }, .flex_shrink = 0 }));
    }
}
const Row = struct {
    view: *View,
    id: u64,
    generation: u64,
    revision: u64,
    name: []u8,
    test_id: []u8,
    fn choose(self: *Row) void {
        if (self.view.generation != self.generation or self.view.query_revision != self.revision) return;
        self.view.activate(.{ .saved = self.id });
    }
    fn cleanup(self: *Row) void {
        self.view.cx.allocator.free(self.name);
        self.view.cx.allocator.free(self.test_id);
        self.view.cx.allocator.destroy(self);
    }
};
fn find(node: *ui.Node, id: u32) ?*ui.Node {
    if (node.id == id) return node;
    for (node.children.items) |child| if (find(child, id)) |result| return result;
    return null;
}
fn contains(text: []const u8, query: []const u8) bool {
    if (query.len == 0) return true;
    if (query.len > text.len) return false;
    for (0..text.len - query.len + 1) |start| if (std.ascii.eqlIgnoreCase(query, text[start..][0..query.len])) return true;
    return false;
}
fn matches(host: Host, query: []const u8) bool {
    return contains(host.name, query) or contains(host.host, query) or contains(host.user, query) or contains(host.group orelse "", query);
}

test "new session menu filters safely and consumes one stable saved target" {
    const cx = try ui.Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    const root = try ui.box(cx, .{ .width = .{ .px = 1440 }, .height = .{ .px = 900 } }, .{});
    cx.root = root;
    cx.setViewport(1440, 900);
    const anchor = try ui.box(cx, .{ .width = .{ .px = 28 }, .height = .{ .px = 28 } }, .{});
    try root.appendChild(cx.allocator, anchor);
    const scope = try ui.Scope.init(std.testing.allocator, null, cx.owner);
    defer scope.dispose();
    var workspace: Workspace = undefined;
    workspace.registry = try @import("../config/hosts.zig").Registry.parse(std.testing.allocator, "[[hosts]]; name=\"First\"; host=\"127.0.0.1\"; user=\"test\"\n[[hosts]]; name=\"Second\"; host=\"127.0.0.2\"; user=\"test\"\n[[hosts]]; name=\"Third\"; host=\"127.0.0.3\"; user=\"test\"");
    workspace.registry.hosts[2].protocol = .sftp;
    defer workspace.registry.deinit();
    workspace.identities = .{};
    defer workspace.identities.deinit(std.testing.allocator);
    try workspace.identities.appendHosts(std.testing.allocator, 3);
    var probe: MenuProbe = .{};
    const view = try View.mount(cx, scope, &workspace, .{ .context = &probe, .new_profile = MenuProbe.new, .choose_saved = MenuProbe.saved });
    try root.appendChild(cx.allocator, view.root);
    try view.show(anchor);
    try view.flush();
    try std.testing.expectEqual(@as(usize, 3), view.results.items.len);
    cx.layout();
    const panel = view.content.globalRect();
    const search = view.input.input_container.globalRect();
    const local = view.local_button.globalRect();
    const saved = view.scroll.container.globalRect();
    const footer = view.new_button.globalRect();
    try std.testing.expectApproxEqAbs(@as(f32, 336), panel.w, 0.1);
    try std.testing.expectApproxEqAbs(@as(f32, 272), panel.h, 0.1);
    try std.testing.expectApproxEqAbs(@as(f32, 10), search.x - panel.x, 0.1);
    try std.testing.expectApproxEqAbs(@as(f32, 10), search.y - panel.y, 0.1);
    try std.testing.expectApproxEqAbs(@as(f32, 316), search.w, 0.1);
    try std.testing.expectApproxEqAbs(@as(f32, 32), search.h, 0.1);
    try std.testing.expectApproxEqAbs(@as(f32, 48), local.y - panel.y, 0.1);
    try std.testing.expectApproxEqAbs(@as(f32, 34), local.h, 0.1);
    try std.testing.expectApproxEqAbs(@as(f32, 116), saved.y - panel.y, 0.1);
    try std.testing.expectApproxEqAbs(@as(f32, 108), saved.h, 0.1);
    try std.testing.expectApproxEqAbs(@as(f32, 308), view.scroll.content.children.items[0].globalRect().w, 0.1);
    try std.testing.expectApproxEqAbs(@as(f32, 32), view.scroll.content.children.items[0].globalRect().h, 0.1);
    try std.testing.expectApproxEqAbs(@as(f32, 230), footer.y - panel.y, 0.1);
    try std.testing.expectApproxEqAbs(@as(f32, 32), footer.h, 0.1);
    // These are the content rows appended above, not Button's private label slot.
    const local_parts = view.local_button.children.items[view.local_button.children.items.len - 1].children.items;
    try expectPart(local_parts[0], view.local_button, 10, 9, 16, 16);
    try expectPart(local_parts[1], view.local_button, 34, 8, 216, 18);
    try expectPart(local_parts[2], view.local_button, 258, 9, 28, 16);
    try expectPart(local_parts[3], view.local_button, 294, 11, 12, 12);
    const footer_parts = view.new_button.children.items[view.new_button.children.items.len - 1].children.items;
    try expectPart(footer_parts[0], view.new_button, 10, 8, 16, 16);
    try expectPart(footer_parts[1], view.new_button, 34, 7, 272, 18);
    const saved_button = view.scroll.content.children.items[0];
    const saved_parts = saved_button.children.items[saved_button.children.items.len - 1].children.items;
    try expectPart(saved_parts[0], saved_button, 8, 8, 16, 16);
    try expectPart(saved_parts[1], saved_button, 32, 7, 220, 18);
    try expectPart(saved_parts[2], saved_button, 260, 8, 40, 16);
    try std.testing.expectEqualStrings("SSH", saved_parts[2].getText().?.content);
    const sftp_button = view.scroll.content.children.items[2];
    const sftp_parts = sftp_button.children.items[sftp_button.children.items.len - 1].children.items;
    try expectPart(sftp_parts[2], sftp_button, 260, 8, 40, 16);
    try std.testing.expectEqualStrings("SFTP", sftp_parts[2].getText().?.content);
    const id = view.results.items[0];
    const revision = view.query_revision;
    view.query.set("missing");
    view.queryChanged("missing");
    var stale = Row{ .view = view, .id = id, .generation = view.generation, .revision = revision, .name = @constCast(""), .test_id = @constCast("") };
    stale.choose();
    try std.testing.expectEqual(@as(usize, 0), probe.count);
    try view.flush();
    try std.testing.expectEqual(@as(usize, 0), view.results.items.len);
    _ = view.handleKey(.@"return");
    try std.testing.expectEqual(@as(usize, 0), probe.count);
    try std.testing.expect(view.local_button.behavior.interaction.a11y.?.disabled);
    try std.testing.expect(view.new_button.parent != null);
    view.query.set("");
    view.queryChanged("");
    try view.flush();
    const removed = try workspace.identities.removeHost(0);
    workspace.registry.hosts = workspace.registry.hosts[1..];
    view.activate(.{ .saved = removed });
    try std.testing.expectEqual(@as(usize, 0), probe.count);
    const remaining = workspace.hostId(0).?;
    view.activate(.{ .saved = remaining });
    _ = view.handleKey(.@"return");
    try std.testing.expectEqual(@as(usize, 1), probe.count);
    try std.testing.expectEqual(remaining, probe.id);
    try std.testing.expect(cx.focused_node == anchor);
}

test "new session menu leaves composing Enter to the input" {
    const cx = try ui.Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    const root = try ui.box(cx, .{ .width = .{ .px = 1440 }, .height = .{ .px = 900 } }, .{});
    cx.root = root;
    const anchor = try ui.box(cx, .{ .width = .{ .px = 28 }, .height = .{ .px = 28 } }, .{});
    try root.appendChild(cx.allocator, anchor);
    const scope = try ui.Scope.init(std.testing.allocator, null, cx.owner);
    defer scope.dispose();
    var workspace: Workspace = undefined;
    workspace.registry = try @import("../config/hosts.zig").Registry.parse(std.testing.allocator, "");
    defer workspace.registry.deinit();
    workspace.identities = .{};
    defer workspace.identities.deinit(std.testing.allocator);
    var probe: MenuProbe = .{};
    const view = try View.mount(cx, scope, &workspace, .{ .context = &probe, .new_profile = MenuProbe.new, .choose_saved = MenuProbe.saved });
    try root.appendChild(cx.allocator, view.root);
    try view.show(anchor);
    try view.flush();
    const input_events = view.input.input_container.behavior.events;
    const send = input_events.on_event.?;
    _ = send(.{ .ime_preedit = .{ .text = "zhong", .cursor_utf8_offset = 5 } }, input_events.event_context);
    try std.testing.expect(view.input.state.imeIsComposing());
    try std.testing.expectEqual(ui.events.EventResult.ignored, view.handleKey(.@"return"));
    _ = send(.{ .key_down = .{ .key = .@"return", .modifiers = .{} } }, input_events.event_context);
    try std.testing.expectEqual(@as(usize, 0), probe.count);
    _ = send(.{ .ime_commit = .{ .text = "中" } }, input_events.event_context);
    try std.testing.expect(!view.input.state.imeIsComposing());
    try std.testing.expectEqualStrings("中", view.query.peek());
    try std.testing.expect(view.pending);
    try std.testing.expectEqual(@as(usize, 0), probe.count);
    try view.flush();
    _ = view.handleKey(.down);
    try view.flush();
    _ = view.handleKey(.@"return");
    _ = view.handleKey(.@"return");
    try std.testing.expectEqual(@as(usize, 1), probe.count);
    try std.testing.expect(!view.isOpen());
    try std.testing.expect(cx.focused_node == anchor);
}
const MenuProbe = struct {
    count: usize = 0,
    id: u64 = 0,
    fn new(raw: *anyopaque) void {
        const self: *MenuProbe = @ptrCast(@alignCast(raw));
        self.count += 1;
    }
    fn saved(raw: *anyopaque, id: u64) void {
        const self: *MenuProbe = @ptrCast(@alignCast(raw));
        self.count += 1;
        self.id = id;
    }
};

test "global material rethemes an already mounted session popover without clearing its query" {
    const theme = S.theme;
    const previous = theme.currentName();
    const was_visible = theme.materialVisible();
    defer {
        theme.select(previous);
        _ = theme.setMaterialVisible(was_visible);
    }
    _ = theme.setMaterialVisible(false);
    theme.select(.dark);
    const cx = try ui.Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    const publication = try cx.bindState(@import("shell_styles.zig").ThemePublication, .{});
    publication.publish(cx, theme.widgetTheme(.dark));
    cx.setViewport(1440, 900);
    cx.root = try ui.box(cx, .{ .width = .fill(), .height = .fill() }, .{});
    const anchor = try ui.box(cx, .{ .width = .{ .px = 28 }, .height = .{ .px = 28 } }, .{});
    try cx.root.?.appendChild(cx.allocator, anchor);
    const scope = try ui.Scope.init(std.testing.allocator, null, cx.owner);
    defer scope.dispose();
    var workspace: Workspace = undefined;
    workspace.registry = try @import("../config/hosts.zig").Registry.parse(std.testing.allocator, "[[hosts]]; name=\"First\"; host=\"127.0.0.1\"; user=\"test\"");
    defer workspace.registry.deinit();
    workspace.identities = .{};
    defer workspace.identities.deinit(std.testing.allocator);
    try workspace.identities.appendHosts(std.testing.allocator, 1);
    var probe: MenuProbe = .{};
    const view = try View.mount(cx, scope, &workspace, .{ .context = &probe, .new_profile = MenuProbe.new, .choose_saved = MenuProbe.saved });
    try cx.root.?.appendChild(cx.allocator, view.root);
    _ = cx.render();
    try view.show(anchor);
    view.query.set("First");
    view.queryChanged("First");
    try view.flush();
    const id = view.results.items[0];
    const chrome_id = view.chrome.id;
    try std.testing.expectEqual(@as(u8, 255), view.chrome.getBackground().a);
    _ = theme.setMaterialVisible(true);
    publication.publish(cx, theme.widgetTheme(.dark));
    cx.layout();
    _ = cx.render();
    try std.testing.expectEqual(chrome_id, view.chrome.id);
    try std.testing.expectEqual(theme.current().overlay, view.chrome.getBackground());
    try std.testing.expectEqual(theme.current().well, view.input.input_container.getBackground());
    try std.testing.expectEqual(theme.current().surface_1, view.scroll.content.getBackground());
    try std.testing.expectEqualStrings("First", view.query.peek());
    try std.testing.expectEqual(id, view.results.items[0]);
    try std.testing.expect(view.isOpen());
    try std.testing.expectEqual(@as(usize, 0), probe.count);
    view.hide();
    _ = theme.setMaterialVisible(false);
    publication.publish(cx, theme.widgetTheme(.dark));
    try view.show(anchor);
    try std.testing.expectEqual(@as(u8, 255), view.chrome.getBackground().a);
}
fn expectPart(node: *ui.Node, parent: *ui.Node, x: f32, y: f32, w: f32, h: f32) !void {
    const rect = node.globalRect();
    const container = parent.globalRect();
    try std.testing.expectApproxEqAbs(x, rect.x - container.x, 0.1);
    try std.testing.expectApproxEqAbs(y, rect.y - container.y, 0.1);
    try std.testing.expectApproxEqAbs(w, rect.w, 0.1);
    try std.testing.expectApproxEqAbs(h, rect.h, 0.1);
}
