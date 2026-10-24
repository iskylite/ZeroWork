//! Current V0.1.3 quick-connect projection. Opening/searching never starts IO;
//! only an explicit submit invokes a frozen saved owner or structured target.
const std = @import("std");
const ui = @import("ui");
const identity = @import("../host/identity.zig");
const hosts = @import("../config/hosts.zig");
const parser = @import("quick_connect.zig");
pub const styles = @import("quick_connect_styles.zig");
const S = styles;
pub const SavedAsset = struct {
    owner: identity.AssetOwner,
    name: []const u8,
    host: []const u8,
    user: []const u8,
    port: u16 = 22,
    group: ?[]const u8 = null,
    hops: usize = 0,
    protocol: hosts.Protocol = .ssh,
};
pub const Callbacks = struct {
    context: *anyopaque,
    saved: *const fn (*anyopaque, identity.AssetOwner) anyerror!void,
    temporary: *const fn (*anyopaque, parser.ParsedTarget) anyerror!void,
    new_profile: *const fn (*anyopaque, ?parser.ParsedTarget, []const u8) anyerror!void,
    closed: ?*const fn (*anyopaque) void = null,
};
const Owned = struct {
    arena: std.heap.ArenaAllocator,
    revision: u64,
    assets: []SavedAsset,
    fn init(allocator: std.mem.Allocator, revision: u64, assets: []const SavedAsset) !Owned {
        var arena = std.heap.ArenaAllocator.init(allocator);
        errdefer arena.deinit();
        const a = arena.allocator();
        const copied = try a.dupe(SavedAsset, assets);
        for (copied) |*asset| {
            asset.name = try a.dupe(u8, asset.name);
            asset.host = try a.dupe(u8, asset.host);
            asset.user = try a.dupe(u8, asset.user);
            if (asset.group) |group| asset.group = try a.dupe(u8, group);
        }
        return .{ .arena = arena, .revision = revision, .assets = copied };
    }
};
const Parts = struct { user: []const u8 = "", host: []const u8 = "", port: []const u8 = "22" };
pub const Mode = enum { saved, temporary, invalid };
pub const View = struct {
    cx: *ui.Cx,
    scope: *ui.Scope,
    callbacks: Callbacks,
    root: *ui.Node,
    chrome: *ui.Node,
    body: *ui.Node,
    input: ui.widgets.input.InputResult,
    clear: *ui.Node,
    query: *ui.Signal([]const u8),
    open: *ui.Signal(bool),
    title: *ui.Node,
    saved_area: *ui.Node,
    result_label: *ui.Node,
    scroll: ui.widgets.ScrollAreaResult,
    empty_area: *ui.Node,
    leading_spacer: *ui.Node,
    middle_spacer: *ui.Node,
    temporary_area: *ui.Node,
    notice: *ui.Node,
    notice_title: *ui.Node,
    notice_message: *ui.Node,
    host_input: ui.widgets.input.InputResult,
    user_input: ui.widgets.input.InputResult,
    port_input: ui.widgets.input.InputResult,
    host_value: *ui.Signal([]const u8),
    user_value: *ui.Signal([]const u8),
    port_value: *ui.Signal([]const u8),
    hint: *ui.Node,
    primary: *ui.Node,
    secondary: *ui.Node,
    primary_label: *ui.Signal([]const u8),
    secondary_label: *ui.Signal([]const u8),
    disabled: *ui.Signal(bool),
    failure: *ui.Node,
    source: ?Owned = null,
    matches: std.ArrayList(usize) = .empty,
    row_scope: ?*ui.Scope = null,
    selected: ?identity.AssetOwner = null,
    focus_return: ?u32 = null,
    generation: u64 = 0,
    mode: Mode = .saved,
    dirty: bool = true,
    submitted: bool = false,
    closing: bool = false,
    paint_version: u32 = 0,
    colors: S.theme.Colors,
    last_problem: ?anyerror = null,

    pub fn mount(cx: *ui.Cx, scope: *ui.Scope, callbacks: Callbacks) !*View {
        const query = try scope.createText("", .{});
        const open = try scope.createSignal(bool, false);
        const self = try cx.allocator.create(View);
        self.* = .{ .cx = cx, .scope = scope, .callbacks = callbacks, .root = undefined, .chrome = undefined, .body = undefined, .input = undefined, .clear = undefined, .query = query, .open = open, .title = undefined, .saved_area = undefined, .result_label = undefined, .scroll = undefined, .empty_area = undefined, .leading_spacer = undefined, .middle_spacer = undefined, .temporary_area = undefined, .notice = undefined, .notice_title = undefined, .notice_message = undefined, .host_input = undefined, .user_input = undefined, .port_input = undefined, .host_value = try scope.createText("", .{}), .user_value = try scope.createText("", .{}), .port_value = try scope.createText("22", .{}), .hint = undefined, .primary = undefined, .secondary = undefined, .primary_label = try scope.createText("连接所选主机", .{}), .secondary_label = try scope.createText("新建主机配置", .{}), .disabled = try scope.createSignal(bool, true), .failure = undefined, .colors = S.theme.current() };
        try scope.onCleanup(View, self, cleanup);
        const popup = try ui.widgets.Popover(.{ .open = open, .trigger = .manual, .anchor = .{ .virtual = .{ .ctx = self, .getRect = anchor } }, .position = .bottom_start, .offset = .{ .static = 0 }, .width = S.width, .max_width = S.width, .viewport_padding = 8, .constrain_width_to_viewport = true, .shift_main_axis = true, .size_policy = .fit_content, .close_on_escape = false, .on_open_change = cx.on(View, self, openChanged) }).mount(scope, cx);
        self.scope = popup.scope;
        self.root = popup.wrapper;
        self.chrome = popup.content;
        self.chrome.setStyleInline(cx.allocator, S.panel());
        self.chrome.meta.ownership.meta.test_id = "quick.connect";
        self.chrome.behavior.events.on_event_capture = onEvent;
        self.chrome.behavior.events.capture_context = self;
        const header = try ui.box(cx, S.header(), .{});
        try self.chrome.appendChild(cx.allocator, header);
        try header.appendChild(cx.allocator, try ui.iconTint(cx, @import("quick_connect_icon.zig").asset, S.theme.current().accent, .{ .width = .{ .px = 18 }, .height = .{ .px = 18 }, .flex_shrink = 0 }));
        self.title = try label(cx, header, "快速连接", 13, 700, false);
        self.title.setStyleInline(cx.allocator, .{ .width = .fill(), .flex = 1, .min_width = 0 });
        const close = try ui.widgets.Button(.{ .variant = .ghost, .icon_only = true, .icon_asset = ui.icons.x, .icon_size = @as(f32, 16), .a11y_label = "关闭快速连接", .base_style = S.iconButton(), .on_click = cx.on(View, self, hide) }).mount(popup.scope, cx);
        close.meta.ownership.meta.test_id = "quick.close";
        try header.appendChild(cx.allocator, close);
        self.body = try ui.box(cx, S.body(), .{});
        try self.chrome.appendChild(cx.allocator, self.body);
        self.input = try ui.widgets.Input(.{ .value = query, .placeholder = "搜索主机或输入 SSH 目标", .leading_icon_asset = ui.icons.search, .on_change = cx.on(View, self, queryChanged), .on_submit = cx.on(View, self, inputSubmit) }).mountResult(popup.scope, cx);
        tune(cx, &self.input, 40, 14);
        self.input.node.meta.ownership.meta.test_id = "quick.query";
        const query_row = try ui.box(cx, S.queryRow(), .{});
        try query_row.appendChild(cx.allocator, self.input.node);
        try self.body.appendChild(cx.allocator, query_row);
        self.saved_area = try ui.box(cx, S.column(), .{});
        try self.body.appendChild(cx.allocator, self.saved_area);
        self.result_label = try label(cx, self.saved_area, "已保存的主机 · 0 个结果", 11, 400, true);
        self.result_label.setStyleInline(cx.allocator, S.line(16));
        self.scroll = try ui.widgets.ScrollArea(.{ .direction = .vertical, .rubber_band_y = false }).mount(popup.scope, cx);
        self.scroll.container.setStyleInline(cx.allocator, .{ .width = .fill(), .height = .{ .px = 28 }, .flex_shrink = 0 });
        self.scroll.content.setStyleInline(cx.allocator, S.column());
        try self.saved_area.appendChild(cx.allocator, self.scroll.container);
        self.empty_area = try ui.box(cx, S.column(), .{});
        try self.body.appendChild(cx.allocator, self.empty_area);
        const empty_card = try ui.box(cx, S.noMatch(), .{});
        try self.empty_area.appendChild(cx.allocator, empty_card);
        try empty_card.appendChild(cx.allocator, try ui.iconTint(cx, ui.icons.search_x, S.theme.current().fg_2, .{ .width = .{ .px = 18 }, .height = .{ .px = 18 }, .flex_shrink = 0 }));
        const empty_title = try label(cx, empty_card, "未找到匹配的主机", 12, 500, false);
        empty_title.setStyleInline(cx.allocator, S.line(21));
        const empty_help = try label(cx, empty_card, "可修改关键词，或输入 user@host:port 临时连接。", 11, 400, true);
        empty_help.setStyleInline(cx.allocator, S.line(16));
        const clear = try ui.widgets.Button(.{ .icon_only = true, .icon_asset = ui.icons.x, .icon_size = @as(f32, 16), .variant = .secondary, .a11y_label = "清空搜索", .base_style = S.clearButton(), .on_click = cx.on(View, self, clearSearch) }).mount(popup.scope, cx);
        clear.setStyleInline(cx.allocator, S.clearPlacement());
        clear.meta.ownership.meta.test_id = "quick.clear";
        self.clear = clear;
        // Overlay a sibling button on the full input well. Input's interaction
        // delegate redirects descendant clicks, so the button must stay outside it.
        try query_row.appendChild(cx.allocator, clear);
        self.temporary_area = try ui.box(cx, S.column(), .{});
        try self.body.appendChild(cx.allocator, self.temporary_area);
        self.notice = try ui.box(cx, S.notice(false), .{});
        try self.temporary_area.appendChild(cx.allocator, self.notice);
        self.notice_title = try label(cx, self.notice, "临时 SSH 目标", 12, 500, false);
        self.notice_title.setStyleInline(cx.allocator, S.line(18));
        self.notice_message = try label(cx, self.notice, "", 11, 400, true);
        self.notice_message.setStyleInline(cx.allocator, S.line(16));
        const field_row = try ui.box(cx, S.fieldRow(), .{});
        try self.temporary_area.appendChild(cx.allocator, field_row);
        self.host_input = try self.field(field_row, "目标地址", "quick.host", self.host_value, 330);
        self.port_input = try self.field(field_row, "端口", "quick.port", self.port_value, 146);
        self.user_input = try self.field(self.temporary_area, "登录用户", "quick.user", self.user_value, null);
        self.hint = try label(cx, self.body, "上下选择 · Enter 打开新会话 · Esc 关闭", 10.5, 400, true);
        self.hint.setStyleInline(cx.allocator, S.line(16));
        const gap = try ui.box(cx, S.line(2), .{});
        try self.body.appendChild(cx.allocator, gap);
        const footer = try ui.box(cx, S.footer(), .{});
        try self.body.appendChild(cx.allocator, footer);
        self.leading_spacer = try ui.spacer(cx);
        self.leading_spacer.setDisplay(.none);
        try footer.appendChild(cx.allocator, self.leading_spacer);
        self.secondary = try ui.widgets.Button(.{ .label = self.secondary_label, .variant = .secondary, .base_style = S.button(false, false), .on_click = cx.on(View, self, secondaryClicked) }).mount(popup.scope, cx);
        self.secondary.meta.ownership.meta.test_id = "quick.save";
        try footer.appendChild(cx.allocator, self.secondary);
        self.middle_spacer = try ui.spacer(cx);
        try footer.appendChild(cx.allocator, self.middle_spacer);
        self.primary = try ui.widgets.Button(.{ .label = self.primary_label, .variant = .primary, .disabled = self.disabled, .base_style = S.button(true, false), .on_click = cx.on(View, self, primaryClicked) }).mount(popup.scope, cx);
        self.primary.meta.ownership.meta.test_id = "quick.submit";
        try footer.appendChild(cx.allocator, self.primary);
        self.failure = try label(cx, self.body, "", 11, 400, true);
        self.failure.setTextColor(S.theme.current().danger_ink);
        self.failure.setDisplay(.none);
        self.failure.meta.ownership.meta.test_id = "quick.failure";
        self.temporary_area.setDisplay(.none);
        try cx.addAfterLayoutHook(self, afterLayout);
        return self;
    }
    fn field(self: *View, parent: *ui.Node, title: []const u8, id: []const u8, value: *ui.Signal([]const u8), width: ?f32) !ui.widgets.input.InputResult {
        const slot = try ui.box(self.cx, S.field(width), .{});
        try parent.appendChild(self.cx.allocator, slot);
        const name = try label(self.cx, slot, title, 11, 500, true);
        name.setStyleInline(self.cx.allocator, S.line(16));
        var input = try ui.widgets.Input(.{ .value = value, .on_change = self.cx.on(View, self, fieldChanged), .on_submit = self.cx.on(View, self, inputSubmit) }).mountResult(self.scope, self.cx);
        tune(self.cx, &input, 32, if (std.mem.eql(u8, id, "quick.user")) 12 else 11.5);
        input.node.meta.ownership.meta.test_id = id;
        try slot.appendChild(self.cx.allocator, input.node);
        return input;
    }
    pub fn update(self: *View, revision: u64, assets: []const SavedAsset) !void {
        if (self.source) |source| if (source.revision == revision) return;
        const owned = try Owned.init(self.cx.allocator, revision, assets);
        if (self.source) |*previous| previous.arena.deinit();
        self.source = owned;
        self.invalidate();
    }
    pub fn show(self: *View) !void {
        if (self.generation == std.math.maxInt(u64)) return error.GenerationExhausted;
        self.generation += 1;
        if (self.cx.focused_node) |node| self.focus_return = node.id;
        self.query.set("");
        self.selected = null;
        self.submitted = false;
        self.last_problem = null;
        self.failure.setDisplay(.none);
        self.open.set(true);
        self.invalidate();
        self.cx.setFocus(self.input.input_container);
    }
    pub fn hide(self: *View) void {
        self.dismiss(true);
    }
    fn dismiss(self: *View, restore: bool) void {
        if (!self.open.peek() or self.closing) return;
        self.closing = true;
        self.open.set(false);
        if (restore) self.restoreFocus();
        if (self.callbacks.closed) |closed| closed(self.callbacks.context);
        self.closing = false;
        self.cx.requestRedraw();
    }
    pub fn isOpen(self: *const View) bool {
        return self.open.peek();
    }
    pub fn setQuery(self: *View, query: []const u8) void {
        self.query.set(query);
        self.queryChanged(query);
    }
    fn queryChanged(self: *View, _: []const u8) void {
        self.selected = null;
        self.last_problem = null;
        self.failure.setDisplay(.none);
        self.invalidate();
    }
    fn fieldChanged(self: *View, _: []const u8) void {
        const host = self.host_value.peek();
        const query = if (std.mem.indexOfScalar(u8, host, ':') != null and !std.mem.startsWith(u8, host, "["))
            std.fmt.allocPrint(self.cx.allocator, "{s}@[{s}]:{s}", .{ self.user_value.peek(), host, self.port_value.peek() })
        else
            std.fmt.allocPrint(self.cx.allocator, "{s}@{s}:{s}", .{ self.user_value.peek(), host, self.port_value.peek() });
        const value = query catch return;
        defer self.cx.allocator.free(value);
        self.setQuery(value);
    }
    fn inputSubmit(self: *View, _: []const u8) void {
        if (!self.composing()) self.activate();
    }
    fn composing(self: *const View) bool {
        return self.input.state.imeIsComposing() or self.host_input.state.imeIsComposing() or self.port_input.state.imeIsComposing() or self.user_input.state.imeIsComposing();
    }
    pub fn handleKey(self: *View, key: ui.events.KeyCode) ui.events.EventResult {
        if (!self.isOpen() or self.composing()) return .ignored;
        switch (key) {
            .escape => self.hide(),
            .up, .down => {
                if (self.dirty or self.mode != .saved or self.matches.items.len == 0) return .stop;
                var current: usize = 0;
                for (self.matches.items, 0..) |index, rank| if (self.selected != null and std.meta.eql(self.source.?.assets[index].owner, self.selected.?)) {
                    current = rank;
                    break;
                };
                const rank = if (key == .down) (current + 1) % self.matches.items.len else (current + self.matches.items.len - 1) % self.matches.items.len;
                self.selected = self.source.?.assets[self.matches.items[rank]].owner;
                self.invalidate();
            },
            .@"return" => if (!self.dirty) self.activate(),
            else => return .ignored,
        }
        return .stop;
    }
    fn activate(self: *View) void {
        if (!self.isOpen() or self.submitted or self.dirty or self.composing()) return;
        if (self.mode == .invalid or (self.mode == .saved and self.selected == null)) return;
        self.submit() catch |err| {
            self.fail(err);
            return;
        };
        self.submitted = true;
        self.dismiss(false);
    }
    fn primaryClicked(self: *View) void {
        if (self.mode == .saved and self.matches.items.len == 0) self.saveProfile() else self.activate();
    }
    fn secondaryClicked(self: *View) void {
        if (self.mode == .saved and self.matches.items.len == 0) self.hide() else self.saveProfile();
    }
    fn clearSearch(self: *View) void {
        self.setQuery("");
        self.cx.setFocus(self.input.input_container);
    }
    fn submit(self: *View) !void {
        if (self.mode == .saved) {
            const owner = self.selected orelse return error.NoSavedSelection;
            for (self.matches.items) |index| if (std.meta.eql(self.source.?.assets[index].owner, owner)) return self.callbacks.saved(self.callbacks.context, owner);
            return error.StaleAsset;
        }
        const target = parser.parseQuickTarget(self.query.peek()) orelse return error.InvalidTarget;
        try self.callbacks.temporary(self.callbacks.context, target);
    }
    fn saveProfile(self: *View) void {
        if (self.dirty or self.submitted) return;
        if (self.mode == .invalid) {
            self.cx.setFocus(self.input.input_container);
            return;
        }
        self.callbacks.new_profile(self.callbacks.context, if (self.mode == .temporary) parser.parseQuickTarget(self.query.peek()) else null, self.query.peek()) catch |err| {
            self.fail(err);
            return;
        };
        self.submitted = true;
        self.dismiss(false);
    }
    fn fail(self: *View, problem: anyerror) void {
        self.last_problem = problem;
        self.failure.setTextContent(self.cx.allocator, switch (problem) {
            error.StaleAsset, error.StaleGroup, error.RevisionConflict => "连接配置已变化，请重新搜索后再试。",
            error.InvalidTarget => "目标输入无效，请检查地址、用户名和端口。",
            else => "操作未能完成，已保留输入，请重试。",
        }) catch {};
        self.failure.setDisplay(.flex);
        self.cx.requestRedraw();
    }
    pub fn flush(self: *View) !void {
        if (!self.dirty or !self.isOpen()) return;
        self.matches.clearRetainingCapacity();
        const query = self.query.peek();
        const temporary = std.mem.startsWith(u8, query, "ssh ") or std.mem.indexOfScalar(u8, query, '@') != null;
        self.mode = if (temporary) if (parser.parseQuickTarget(query) != null) .temporary else .invalid else .saved;
        self.temporary_area.setDisplay(if (self.mode == .saved) .none else .flex);
        if (self.mode == .saved) {
            if (self.source) |source| for (source.assets, 0..) |asset, index| if (matchesAsset(asset, query)) try self.matches.append(self.cx.allocator, index);
            var found = false;
            for (self.matches.items) |index| if (self.selected != null and std.meta.eql(self.source.?.assets[index].owner, self.selected.?)) {
                found = true;
                break;
            };
            if (!found) self.selected = if (self.matches.items.len > 0) self.source.?.assets[self.matches.items[0]].owner else null;
            try self.title.setTextContent(self.cx.allocator, "快速连接");
            const caption = try std.fmt.allocPrint(self.cx.allocator, "已保存的主机 · {d} 个结果", .{self.matches.items.len});
            defer self.cx.allocator.free(caption);
            try self.result_label.setTextContent(self.cx.allocator, caption);
            try self.hint.setTextContent(self.cx.allocator, "上下选择 · Enter 打开新会话 · Esc 关闭");
            self.primary_label.set("连接所选主机");
            self.secondary_label.set("新建主机配置");
            self.disabled.set(self.selected == null);
            try self.rebuildRows();
        } else {
            const parts = splitTarget(query);
            self.host_value.set(parts.host);
            self.port_value.set(parts.port);
            self.user_value.set(parts.user);
            const invalid = self.mode == .invalid;
            try self.title.setTextContent(self.cx.allocator, "快速连接");
            self.notice.setStyleInline(self.cx.allocator, S.notice(invalid));
            self.notice_title.setTextColor(if (invalid) S.theme.current().danger_ink else S.theme.current().fg_1);
            try self.notice_title.setTextContent(self.cx.allocator, if (invalid) invalidTitle(parts) else "临时 SSH 目标");
            const message = if (invalid) try self.cx.allocator.dupe(u8, if (std.mem.eql(u8, invalidTitle(parts), "端口无效")) "端口必须为 1 至 65535 之间的整数。修正后才可连接。" else "请输入登录用户和有效的目标地址。") else try std.fmt.allocPrint(self.cx.allocator, "本次直接连接 {s}@{s}:{s}，不写入已保存的主机列表。", .{ parts.user, parts.host, parts.port });
            defer self.cx.allocator.free(message);
            try self.notice_message.setTextContent(self.cx.allocator, message);
            try self.hint.setTextContent(self.cx.allocator, "默认直连并先尝试 SSH Agent；需要凭据时为此目标继续认证。");
            self.primary_label.set("连接临时目标");
            self.secondary_label.set(if (invalid) "修改输入" else "保存为主机配置");
            self.disabled.set(invalid);
        }
        const no_match = self.mode == .saved and self.matches.items.len == 0;
        self.clear.setDisplay(if (no_match) .flex else .none);
        self.input.input_container.setStyleInline(self.cx.allocator, S.queryInput(no_match));
        self.saved_area.setDisplay(if (self.mode == .saved and !no_match) .flex else .none);
        self.empty_area.setDisplay(if (no_match) .flex else .none);
        self.hint.setDisplay(if (no_match) .none else .flex);
        self.leading_spacer.setDisplay(if (no_match) .flex else .none);
        self.middle_spacer.setDisplay(if (no_match) .none else .flex);
        self.body.setStyleInline(self.cx.allocator, .{ .padding = .{ .top = 8, .left = 16, .right = 16, .bottom = if (no_match) 18 else 16 } });
        if (no_match) {
            try self.title.setTextContent(self.cx.allocator, "快速连接");
            self.primary_label.set("新建主机配置");
            self.secondary_label.set("关闭");
            self.disabled.set(false);
        }
        self.primary.setStyleInline(self.cx.allocator, S.button(true, self.mode != .saved));
        self.secondary.setStyleInline(self.cx.allocator, S.button(false, self.mode != .saved));
        self.secondary.setDisplay(if (no_match) .none else .flex);
        if (no_match) self.secondary.setStyleInline(self.cx.allocator, .{ .width = .{ .px = 84 } });
        self.dirty = false;
        self.chrome.markLayoutDirty();
    }
    fn rebuildRows(self: *View) !void {
        const restore_input = if (self.cx.focused_node) |node| find(self.scroll.content, node.id) != null else false;
        for (self.scroll.content.children.items) |node| self.cx.invalidateReferencesTo(node);
        if (self.row_scope) |scope| scope.dispose();
        self.row_scope = null;
        while (self.scroll.content.children.items.len > 0) {
            const node = self.scroll.content.children.items[self.scroll.content.children.items.len - 1];
            self.cx.detachChild(self.scroll.content, node);
            self.cx.destroyDetached(node);
        }
        const scope = try self.scope.childScope();
        self.row_scope = scope;
        if (self.matches.items.len == 0) {
            const empty = try label(self.cx, self.scroll.content, "无匹配主机", 12, 400, true);
            empty.setStyleInline(self.cx.allocator, S.line(28));
        }
        for (self.matches.items) |index| {
            const asset = self.source.?.assets[index];
            const selected = self.selected != null and std.meta.eql(self.selected.?, asset.owner);
            const cell = try scope.createState(Row, .{ .view = self, .owner = asset.owner, .generation = self.generation });
            const node = try ui.widgets.Button(.{ .variant = .ghost, .a11y_label = try scope.createText(asset.name, .{}), .base_style = S.row(selected), .hover_style = ui.BoxStyle{ .background = S.theme.current().hover }, .on_click = self.cx.on(Row, cell, Row.select) }).mount(scope, self.cx);
            node.meta.ownership.meta.test_id = "quick.saved.row";
            try self.scroll.content.appendChild(self.cx.allocator, node);
            const content = try ui.box(self.cx, S.rowContent(), .{});
            try node.appendChild(self.cx.allocator, content);
            try content.appendChild(self.cx.allocator, try ui.iconTint(self.cx, if (asset.protocol == .sftp) ui.icons.folder_open else ui.icons.server, S.theme.current().fg_2, .{ .width = .{ .px = 14 }, .height = .{ .px = 14 }, .flex_shrink = 0 }));
            const name = try label(self.cx, content, asset.name, 11, 500, false);
            name.setStyleInline(self.cx.allocator, .{ .width = .{ .px = 108 }, .flex_shrink = 0 });
            const endpoint = try std.fmt.allocPrint(self.cx.allocator, "{s}@{s}:{d}", .{ asset.user, asset.host, asset.port });
            defer self.cx.allocator.free(endpoint);
            const detail = try label(self.cx, content, endpoint, 9.5, 400, true);
            detail.setStyleInline(self.cx.allocator, .{ .width = .{ .px = 230 }, .height = .{ .px = 14 }, .min_width = 0, .flex_shrink = 0 });
            if (detail.getText()) |old| {
                var next = old;
                next.use_monospace_font = true;
                next.line_height = 14.0 / 9.5;
                detail.setText(next);
            }
            if (asset.hops > 0) {
                const hops = try std.fmt.allocPrint(self.cx.allocator, "{d} 跳", .{asset.hops});
                defer self.cx.allocator.free(hops);
                const chip = try ui.box(self.cx, S.route(), .{});
                try content.appendChild(self.cx.allocator, chip);
                const route = try label(self.cx, chip, hops, 10.5, 500, true);
                route.setStyleInline(self.cx.allocator, .{ .width = .{ .px = 28 }, .height = .{ .px = 16 }, .flex_shrink = 0 });
            }
        }
        const count = @max(@as(usize, 1), @min(@as(usize, 3), self.matches.items.len));
        const height = @as(f32, @floatFromInt(count)) * 28 + @as(f32, @floatFromInt(count - 1)) * 6;
        self.scroll.container.setStyleInline(self.cx.allocator, .{ .height = .{ .px = height } });
        if (self.selected) |owner| for (self.matches.items, 0..) |index, rank| if (std.meta.eql(owner, self.source.?.assets[index].owner)) {
            const top = @as(f32, @floatFromInt(rank)) * 34;
            if (top < self.scroll.state.scroll_y) self.scroll.state.scroll_y = top;
            if (top + 28 > self.scroll.state.scroll_y + height) self.scroll.state.scroll_y = top + 28 - height;
            break;
        };
        if (restore_input) self.cx.setFocus(self.input.input_container);
    }
    fn invalidate(self: *View) void {
        self.dirty = true;
        self.cx.requestRedraw();
    }
    fn retheme(self: *View) void {
        S.repaint(self.chrome, self.colors);
        self.colors = S.theme.current();
        self.chrome.setBackground(self.colors.overlay);
        inline for (.{ "input", "host_input", "port_input", "user_input" }) |field_name| {
            const input = &@field(self, field_name);
            input.input_container.setBackground(self.colors.well);
            input.state.tokens = self.cx.tokens;
            input.state.dirty = true;
        }
        self.failure.setTextColor(self.colors.danger_ink);
        self.paint_version = self.cx.theme_version;
        self.invalidate();
    }
    fn afterLayout(raw: *anyopaque, _: u8, _: bool) ui.AfterLayoutResult {
        const self: *View = @ptrCast(@alignCast(raw));
        if (!self.isOpen()) return .done;
        if (self.paint_version != self.cx.theme_version) self.retheme();
        if (!self.dirty) return .done;
        self.flush() catch |err| {
            self.fail(err);
            self.dirty = false;
            return .done;
        };
        return .needs_layout;
    }
    fn openChanged(self: *View, open: bool) void {
        if (!open and !self.closing) {
            self.restoreFocus();
            if (self.callbacks.closed) |closed| closed(self.callbacks.context);
        }
    }
    fn restoreFocus(self: *View) void {
        if (self.focus_return) |id| if (find(self.cx.root orelse return, id)) |node| self.cx.setFocus(node);
    }
    fn anchor(raw: *anyopaque) ui.widgets.popover.AnchorRect {
        const self: *View = @ptrCast(@alignCast(raw));
        const width = @min(S.width, self.cx.viewport.width - 16);
        return .{ .x = @max(@as(f32, 8), (self.cx.viewport.width - width) / 2), .y = @min(@as(f32, 90), @max(@as(f32, 8), self.cx.viewport.height - 374)), .w = width, .h = 0 };
    }
    fn onEvent(event: ui.events.Event, raw: ?*anyopaque) ui.events.EventResult {
        const self: *View = @ptrCast(@alignCast(raw orelse return .ignored));
        return if (event == .key_down) self.handleKey(event.key_down.key) else .ignored;
    }
    fn cleanup(self: *View) void {
        self.cx.removeAfterLayoutHook(self);
        if (self.source) |*source| source.arena.deinit();
        self.matches.deinit(self.cx.allocator);
        self.cx.allocator.destroy(self);
    }
};
const Row = struct {
    view: *View,
    owner: identity.AssetOwner,
    generation: u64,
    fn select(self: *Row) void {
        if (!self.view.isOpen() or self.view.dirty or self.view.generation != self.generation) return;
        for (self.view.matches.items) |index| if (std.meta.eql(self.owner, self.view.source.?.assets[index].owner)) {
            self.view.selected = self.owner;
            self.view.invalidate();
            return;
        };
    }
};
fn label(cx: *ui.Cx, parent: *ui.Node, content: []const u8, size: f32, weight: u16, secondary: bool) !*ui.Node {
    const node = try ui.text(cx, "", S.text(size, weight, secondary));
    try node.setTextContent(cx.allocator, content);
    try parent.appendChild(cx.allocator, node);
    return node;
}
fn tune(cx: *ui.Cx, input: *ui.widgets.input.InputResult, height: f32, size: f32) void {
    input.input_container.setStyleInline(cx.allocator, S.input(height));
    input.node.setStyleInline(cx.allocator, .{ .width = .fill(), .height = .{ .px = height }, .flex_shrink = 0 });
    input.state.font_size = size;
    input.state.line_height = if (height == 40) 20 else if (size == 12) 18 else 17;
    input.state.char_width = size * 0.6;
    input.state.dirty = true;
}
fn contains(text: []const u8, query: []const u8) bool {
    if (query.len == 0) return true;
    if (query.len > text.len) return false;
    for (0..text.len - query.len + 1) |i| if (std.ascii.eqlIgnoreCase(query, text[i..][0..query.len])) return true;
    return false;
}
fn matchesAsset(asset: SavedAsset, query: []const u8) bool {
    return contains(asset.name, query) or contains(asset.host, query) or contains(asset.user, query) or contains(asset.group orelse "", query);
}
fn splitTarget(query: []const u8) Parts {
    const value = if (std.mem.startsWith(u8, query, "ssh ")) query[4..] else query;
    const at = std.mem.indexOfScalar(u8, value, '@') orelse return .{ .host = value };
    var parts: Parts = .{ .user = value[0..at], .host = value[at + 1 ..] };
    if (std.mem.startsWith(u8, parts.host, "[")) {
        const close = std.mem.indexOfScalar(u8, parts.host, ']') orelse return parts;
        const suffix = parts.host[close + 1 ..];
        parts.host = parts.host[1..close];
        if (std.mem.startsWith(u8, suffix, ":")) parts.port = suffix[1..];
    } else if (std.mem.indexOfScalar(u8, parts.host, ':')) |colon| {
        parts.port = parts.host[colon + 1 ..];
        parts.host = parts.host[0..colon];
    }
    return parts;
}
fn invalidTitle(parts: Parts) []const u8 {
    const port = std.fmt.parseInt(u16, parts.port, 10) catch return "端口无效";
    if (port == 0) return "端口无效";
    return "目标输入无效";
}
fn find(node: *ui.Node, id: u32) ?*ui.Node {
    if (node.id == id) return node;
    for (node.children.items) |child| if (find(child, id)) |result| return result;
    return null;
}
