//! Sidebar widgets. Callbacks capture identities in the host; this view owns
//! only copied display strings and transient interaction state.
const std = @import("std");
const ui = @import("ui");
pub const styles = @import("sidebar_styles.zig");
const S = styles;
const T = S.theme;
pub const GroupRef = @import("../config/asset_actions.zig").GroupRef;
pub const GroupAction = enum { new_host, rename, color, toggle_collapsed, delete_empty };
pub const Bridge = struct {
    context: ?*anyopaque = null,
    set_anchor: ?*const fn (?*anyopaque, ui.ComputedRect) void = null,
    new_host: ?*const fn (?*anyopaque, ?GroupRef) void = null,
    new_group: ?*const fn (?*anyopaque) void = null,
    group_action: ?*const fn (?*anyopaque, GroupRef, GroupAction) void = null,
};
pub const Actions = struct {
    context: *anyopaque,
    collapse: *const fn (*anyopaque) void,
    search_changed: ui.Handler([]const u8),
    bridge: Bridge,
    local: ?*const fn (*anyopaque) void = null,
};
pub const View = struct {
    cx: *ui.Cx,
    root: *ui.Node,
    full: *ui.Node,
    empty: *ui.Node,
    list: *ui.Node,
    list_visible: bool = false,
    title: *ui.Node,
    search_box: *ui.Node,
    search: ui.widgets.input.InputResult,
    search_button: *ui.Node,
    search_clear: *ui.Node,
    search_spacer: *ui.Node,
    header: *ui.Node,
    search_open: bool = false,
    search_available: bool = true,
    search_start_ms: f64 = 0,
    search_start_width: f32 = 24,
    search_width: f32 = 24,
    search_animating: bool = false,
    search_value: *ui.Signal([]const u8),
    footer: *ui.Node,
    new_menu: ui.widgets.popover.PopoverResult,
    colors: T.Colors,
    actions: Actions,
    tint: *ui.Signal(?ui.Color),
    hover: *ui.Signal(?ui.BoxStyle),
    host_disabled: *ui.Signal(bool),
    group_disabled: *ui.Signal(bool),
    footer_style: *ui.Signal(ui.BoxStyle),
    empty_footer_style: *ui.Signal(ui.BoxStyle),

    pub fn mount(cx: *ui.Cx, scope: *ui.Scope, list: *ui.Node, actions: Actions) !*View {
        const root = try ui.boxStyled(cx, S.panel, .{});
        root.meta.ownership.meta.test_id = "workspace.sidebar";
        const full = try ui.box(cx, S.full(), .{});
        try root.appendChild(cx.allocator, full);
        const header = try ui.box(cx, S.header(), .{});
        header.meta.ownership.meta.test_id = "sidebar.header";
        header.setStyleInline(cx.allocator, .{ .width = .fill(), .min_width = 0 });
        try full.appendChild(cx.allocator, header);
        try header.appendChild(cx.allocator, try ui.iconTint(cx, ui.icons.get("server").?, T.current().accent, S.icon(17)));
        const title = try text(cx, header, "主机与连接", 13, 700, false);
        title.setStyleInline(cx.allocator, .{ .width = .{ .grow = .{ .min = 0 } }, .min_width = 0 });
        const tint = try scope.createSignal(?ui.Color, T.current().fg_2);
        const hover = try scope.createSignal(?ui.BoxStyle, .{ .background = T.current().hover });
        const host_disabled = try scope.createSignal(bool, actions.bridge.new_host == null);
        const group_disabled = try scope.createSignal(bool, actions.bridge.new_group == null);
        const footer_style = try scope.createSignal(ui.BoxStyle, S.footer());
        const empty_footer_style = try scope.createSignal(ui.BoxStyle, S.emptyFooter());
        const new_menu = try ui.widgets.Popover(.{ .trigger = .click, .position = .bottom_start, .close_on_escape = true, .close_on_outside_click = true, .width = @as(f32, 258), .max_width = @as(f32, 258), .max_height = @as(f32, 106) }).mount(scope, cx);
        new_menu.content.setStyleInline(cx.allocator, S.menu(106));
        new_menu.content.meta.ownership.meta.test_id = "sidebar.new.menu";
        const plus = try iconButton(cx, scope, "plus", "新建", "sidebar.new", S.headerAction(), tint, hover, null, null);
        try new_menu.trigger.appendChild(cx.allocator, plus);
        const search_value = try scope.createText("", .{});
        const search = try mountSearchInput(cx, scope, search_value, actions.search_changed, "sidebar.search");
        search.node.setDisplay(.none);
        const search_box = try ui.box(cx, .{ .width = .{ .px = 24 }, .height = .{ .px = 24 }, .direction = .row, .align_items = .center, .border = .{ .radius = 8 }, .min_width = 0, .overflow = .hidden, .flex_shrink = 0 }, .{});
        search_box.meta.ownership.meta.test_id = "sidebar.search.well";
        const search_spacer = try ui.spacer(cx);
        search_spacer.setDisplay(.none);
        try header.appendChild(cx.allocator, search_spacer);
        const viewport = try ui.widgets.ScrollArea(.{}).mount(scope, cx);
        viewport.container.meta.ownership.meta.test_id = "sidebar.viewport";
        viewport.container.setStyleInline(cx.allocator, S.viewport());
        viewport.content.setStyleInline(cx.allocator, .{ .direction = .column, .width = .fill() });
        list.setStyleInline(cx.allocator, S.list());
        try viewport.content.appendChild(cx.allocator, list);
        try full.appendChild(cx.allocator, viewport.container);
        const self = try scope.createState(View, .{ .cx = cx, .root = root, .full = full, .empty = undefined, .list = list, .title = title, .header = header, .search_box = search_box, .search = search, .search_button = undefined, .search_clear = undefined, .search_spacer = search_spacer, .search_value = search_value, .footer = undefined, .new_menu = new_menu, .colors = T.current(), .actions = actions, .tint = tint, .hover = hover, .host_disabled = host_disabled, .group_disabled = group_disabled, .footer_style = footer_style, .empty_footer_style = empty_footer_style });
        try search_box.appendChild(cx.allocator, search.node);
        const clear = try iconButton(cx, scope, "x", "清空搜索", "sidebar.search.clear", S.headerAction(), tint, hover, cx.on(View, self, View.clearSearch), null);
        clear.setDisplay(.none);
        self.search_clear = clear;
        try search_box.appendChild(cx.allocator, clear);
        const search_button = try iconButton(cx, scope, "search", "搜索主机", "sidebar.search.toggle", S.headerAction(), tint, hover, cx.on(View, self, View.toggleSearch), null);
        self.search_button = search_button;
        try search_box.appendChild(cx.allocator, try hint(cx, scope, search_button, "搜索主机", .right));
        try header.appendChild(cx.allocator, search_box);
        const collapse = try iconButton(cx, scope, "chevron-left", "隐藏侧栏 ⌘B", "sidebar.collapse", S.headerAction(), tint, hover, ui.Cx.simpleHandler(actions.collapse, actions.context), null);
        try header.appendChild(cx.allocator, try hint(cx, scope, collapse, "隐藏侧栏 ⌘B", .right));
        try header.appendChild(cx.allocator, new_menu.wrapper);
        _ = try text(cx, new_menu.content, "新建", 10.5, 400, true);
        try self.newItem(new_menu.scope, "新建主机", "server", false);
        try self.newItem(new_menu.scope, "新建分组", "folder-plus", true);
        try MenuKeyboard.install(cx, new_menu);
        const bottom = try ui.box(cx, .{ .width = .fill(), .direction = .column, .gap = 8, .flex_shrink = 0 }, .{});
        bottom.meta.ownership.meta.test_id = "sidebar.bottom";
        const footer = try self.footerButton(scope, "sidebar.footer.new", false);
        try bottom.appendChild(cx.allocator, footer);
        try full.appendChild(cx.allocator, bottom);
        self.footer = footer;
        var empty_style = S.full();
        empty_style.padding = .{};
        empty_style.gap = 0;
        const empty = try ui.box(cx, empty_style, .{});
        empty.meta.ownership.meta.test_id = "sidebar.empty";
        const guide = try ui.box(cx, .{ .width = .fill(), .direction = .column, .gap = 12, .padding = .{ .top = 16, .left = 16, .right = 16 }, .flex_shrink = 0 }, .{});
        try empty.appendChild(cx.allocator, guide);
        const empty_header = try ui.box(cx, .{ .width = .fill(), .height = .{ .px = 24 }, .direction = .row, .align_items = .center, .flex_shrink = 0 }, .{});
        try guide.appendChild(cx.allocator, empty_header);
        try empty_header.appendChild(cx.allocator, try ui.iconTint(cx, ui.icons.get("server").?, T.current().accent, S.icon(18)));
        try empty_header.appendChild(cx.allocator, try ui.spacer(cx));
        const empty_collapse = try iconButton(cx, scope, "chevron-left", "隐藏侧栏 ⌘B", "sidebar.empty.collapse", S.headerAction(), tint, hover, ui.Cx.simpleHandler(actions.collapse, actions.context), null);
        try empty_header.appendChild(cx.allocator, try hint(cx, scope, empty_collapse, "隐藏侧栏 ⌘B", .right));
        _ = try text(cx, guide, "还没有主机", 13, 500, false);
        const explanation = try text(cx, guide, "添加连接配置后，主机会显示在这里。", 12, 400, true);
        explanation.meta.ownership.meta.test_id = "sidebar.empty.explanation";
        explanation.setStyleInline(cx.allocator, .{ .width = .fill() });
        if (explanation.getText()) |current| {
            var next = current;
            next.wrap = .word;
            explanation.setText(next);
        }
        try empty.appendChild(cx.allocator, try ui.spacer(cx));
        try empty.appendChild(cx.allocator, try self.footerButton(scope, "sidebar.empty.new", true));
        try root.appendChild(cx.allocator, empty);
        self.empty = empty;
        try scope.createEffect(.{ .view = self, .value = search_value }, struct {
            fn run(ctx: anytype) void {
                _ = ctx.value.get();
                ctx.view.syncSearchClear();
            }
        }.run);
        try scope.createEffect(.{ .view = self, .theme = try cx.themeSignal(scope) }, struct {
            fn run(ctx: anytype) void {
                _ = ctx.theme.get();
                ctx.view.retheme();
            }
        }.run);
        try cx.addAfterLayoutHook(self, afterLayout);
        try scope.onCleanup(View, self, cleanup);
        return self;
    }
    pub fn setSearchAvailable(self: *View, available: bool) void {
        if (self.search_available == available) return;
        self.search_available = available;
        if (!available) {
            self.search_open = false;
            self.search_animating = false;
            self.search_width = 24;
            self.search.node.setDisplay(.none);
            self.search_clear.setDisplay(.none);
            self.search_spacer.setDisplay(.none);
            self.title.setDisplay(.flex);
            self.search_box.setStyle(self.cx.allocator, .width, .{ .px = 24 });
            self.search_box.setStyle(self.cx.allocator, .height, .{ .px = 24 });
            self.search_box.setStyle(self.cx.allocator, .padding, .{});
            self.search_box.setBackground(ui.Color.TRANSPARENT);
            if (self.search_value.peek().len != 0) {
                self.search_value.set("");
                self.actions.search_changed.call("");
            }
        }
        self.search_box.setDisplay(if (available) .flex else .none);
    }
    pub fn focusSearchFallback(self: *View) void {
        if (self.search_available and self.full.style.display != .none) {
            self.cx.setFocus(if (self.search_open) self.search.input_container else self.search_button);
        }
    }
    fn toggleSearch(self: *View) void {
        self.search_open = !self.search_open;
        self.search_start_width = self.search_width;
        self.search_start_ms = self.cx.frame_time_ms;
        self.search_animating = true;
        if (self.search_open) {
            self.title.setDisplay(.none);
            self.search_spacer.setDisplay(.flex);
            self.search.node.setDisplay(.flex);
            self.search_box.setStyle(self.cx.allocator, .height, .{ .px = 30 });
            self.search_box.setStyle(self.cx.allocator, .padding, .{ .left = 8 });
            self.search_box.setBackground(self.colors.well_border);
            self.cx.setFocus(self.search.input_container);
        } else {
            if (self.search_value.peek().len != 0) {
                self.search_value.set("");
                self.actions.search_changed.call("");
            }
            self.search.node.setDisplay(.none);
            self.cx.setFocus(self.search_button);
        }
        self.syncSearchClear();
        self.cx.scheduleRedrawAfterNs(16 * std.time.ns_per_ms);
    }
    fn syncSearchClear(self: *View) void {
        self.search_clear.setDisplay(if (self.search_open and self.search_value.peek().len != 0) .flex else .none);
    }
    fn clearSearch(self: *View) void {
        self.search_value.set("");
        self.actions.search_changed.call("");
        self.cx.setFocus(self.search.input_container);
    }
    fn animateSearch(self: *View) bool {
        if (!self.search_animating) return false;
        const target: f32 = if (self.search_open) @max(24, self.header.globalRect().w - 95) else 24;
        const elapsed = @max(0, self.cx.frame_time_ms - self.search_start_ms);
        const progress: f32 = @floatCast(@min(1, elapsed / 200.0));
        const eased = 1 - (1 - progress) * (1 - progress);
        const width = self.search_start_width + (target - self.search_start_width) * eased;
        const changed = @abs(width - self.search_width) > 0.01;
        if (changed) {
            self.search_width = width;
            self.search_box.setStyle(self.cx.allocator, .width, .{ .px = width });
        }
        if (progress >= 1) {
            self.search_animating = false;
            if (!self.search_open) {
                self.search_box.setStyle(self.cx.allocator, .height, .{ .px = 24 });
                self.search_box.setStyle(self.cx.allocator, .padding, .{});
                self.search_box.setBackground(ui.Color.TRANSPARENT);
                self.search_spacer.setDisplay(.none);
                self.title.setDisplay(.flex);
            }
        } else self.cx.scheduleRedrawAfterNs(16 * std.time.ns_per_ms);
        return changed;
    }
    fn afterLayout(raw: *anyopaque, _: u8, _: bool) ui.AfterLayoutResult {
        const self: *View = @ptrCast(@alignCast(raw));
        const animated = self.animateSearch();
        var visible = self.full.style.display != .none and self.root.globalRect().w > 0 and self.root.globalRect().h > 0;
        var ancestor: ?*ui.Node = self.root;
        while (ancestor) |node| : (ancestor = node.parent) if (node.style.display == .none) {
            visible = false;
            break;
        };
        if (visible == self.list_visible) return if (animated) .needs_layout else .done;
        self.list_visible = visible;
        if (!visible) return if (animated) .needs_layout else .done;
        // Rows rebuilt while hidden can retain zero-width layout entries.
        // Re-layout the list once when it becomes visible in either location.
        self.list.markLayoutDirty();
        return .needs_layout;
    }
    fn cleanup(self: *View) void {
        self.cx.removeAfterLayoutHook(self);
    }
    fn footerButton(self: *View, scope: *ui.Scope, id: []const u8, empty: bool) !*ui.Node {
        const slot = try ui.box(self.cx, S.footerSlot(empty), .{});
        const button = try ui.widgets.Button(.{ .label = "新建连接", .icon_asset = ui.icons.plus, .icon_size = @as(f32, 14), .icon_tint = self.tint, .variant = .ghost, .a11y_label = "新建连接", .base_style = if (empty) self.empty_footer_style else self.footer_style, .hover_style = self.hover, .disabled = self.host_disabled, .on_click = self.cx.on(View, self, View.newHost) }).mount(scope, self.cx);
        try slot.appendChild(self.cx.allocator, button);
        button.meta.ownership.meta.test_id = id;
        // The border is an independent decorative overlay on the slot. It
        // must not depend on Button's content-slot layout or swallow failures.
        const frame = try ui.box(self.cx, .{ .position = .absolute, .width = .fill(), .height = .{ .px = 34 }, .border = .{ .width = 0, .color = ui.Color.TRANSPARENT, .radius = 8 } }, .{});
        frame.setStyleInline(self.cx.allocator, .{ .inset = .{ .left = .{ .px = 0 }, .top = .{ .px = 0 } } });
        frame.meta.ownership.meta.test_id = "sidebar.footer.frame";
        frame.setHitTestVisible(false);
        try slot.appendChild(self.cx.allocator, frame);
        setFocusRing(button);
        return slot;
    }
    fn newItem(self: *View, scope: *ui.Scope, label: []const u8, icon_name: []const u8, group: bool) !void {
        var item = S.menuRow();
        item.font_size = 11.5;
        item.font_weight = 400;
        const button = try ui.widgets.Button(.{ .label = label, .icon_asset = ui.icons.get(icon_name), .icon_size = @as(f32, 14), .icon_tint = self.tint, .variant = .ghost, .a11y_label = label, .disabled = if (group) self.group_disabled else self.host_disabled, .base_style = item, .hover_style = self.hover, .on_click = if (group) self.cx.on(View, self, View.newGroup) else self.cx.on(View, self, View.newHost) }).mount(scope, self.cx);
        button.meta.ownership.meta.test_id = if (group) "sidebar.new.group" else "sidebar.new.host";
        if (button.behavior.interaction.a11y) |*a11y| a11y.role = .menuitem;
        try self.new_menu.content.appendChild(self.cx.allocator, button);
    }
    fn newLocal(self: *View) void {
        if (self.actions.local) |run| run(self.actions.context);
    }
    fn newHost(self: *View) void {
        self.new_menu.close.invoke();
        if (self.actions.bridge.new_host) |call| call(self.actions.bridge.context, null);
    }
    fn newGroup(self: *View) void {
        if (self.actions.bridge.set_anchor) |call| call(self.actions.bridge.context, self.new_menu.trigger.globalRect());
        self.new_menu.close.invoke();
        if (self.actions.bridge.new_group) |call| call(self.actions.bridge.context);
    }
    pub fn setBridge(self: *View, bridge: Bridge) void {
        self.actions.bridge = bridge;
        self.host_disabled.set(bridge.new_host == null);
        self.group_disabled.set(bridge.new_group == null);
    }
    pub fn retheme(self: *View) void {
        S.repaint(self.root, self.colors);
        S.repaint(self.new_menu.content, self.colors);
        self.colors = T.current();
        self.tint.set(self.colors.fg_2);
        self.hover.set(.{ .background = self.colors.hover });
        self.footer_style.set(S.footer());
        self.empty_footer_style.set(S.emptyFooter());
        self.search_box.setBackground(if (self.search_open or self.search_animating) self.colors.well_border else ui.Color.TRANSPARENT);
        self.search.state.tokens = self.cx.tokens;
        self.search.state.placeholder_color = self.colors.fg_2;
        self.search.state.dirty = true;
        if (self.search.state.text_display_node) |label| if (label.getText()) |old| {
            var next = old;
            next.font_size = 12;
            next.font_weight = 400;
            next.line_height = 1.5;
            next.color = if (self.search_value.peek().len == 0) self.colors.fg_2 else self.colors.fg_1;
            label.setText(next);
        };
    }
};

fn mountSearchInput(cx: *ui.Cx, scope: *ui.Scope, value: *ui.Signal([]const u8), changed: ui.Handler([]const u8), id: []const u8) !ui.widgets.input.InputResult {
    const input = try ui.widgets.Input(.{ .value = value, .placeholder = "搜索主机、标签、地址…", .placeholder_color = T.current().fg_2, .embedded = true, .on_change = changed }).mountResult(scope, cx);
    input.node.meta.ownership.meta.test_id = id;
    input.node.setStyleInline(cx.allocator, .{ .width = .fill(), .height = .fill(), .flex = 1, .min_width = 0, .justify = .center });
    input.state.font_size = 11;
    input.state.line_height = 16.5;
    input.state.char_width = 11 * 0.6;
    input.state.dirty = true;
    if (input.state.text_display_node) |label| if (label.getText()) |old| {
        var next = old;
        next.font_size = 11;
        next.font_weight = 400;
        next.line_height = 1.5;
        next.color = T.current().fg_2;
        label.setText(next);
    };
    return input;
}

pub const HostAction = enum { copy, edit };
pub const HostCallbacks = struct {
    action: ?*const fn (*anyopaque, HostAction) void = null,
    context: *anyopaque,
    select: *const fn (*anyopaque) void,
    connect: *const fn (*anyopaque) void,
    menu: *const fn (*anyopaque, *ui.Node) void,
};
pub const ForwardBadge = struct { port: ?u16, phase: @import("socks_background_model.zig").Phase };
pub const HostData = struct { protocol: []const u8 = "SSH", supports_route: bool = true, icon: ?ui.SvgAsset = null, kind: @import("session_icon.zig").Kind = .terminal, name: []const u8, detail: []const u8, route: []const u8, hops: usize, online: bool, selected: bool = false, forward: ?ForwardBadge = null };
pub const HostRow = struct {
    cx: *ui.Cx,
    node: *ui.Node,
    name: *ui.Node,
    trailing: *ui.Node,
    tail: *ui.Node,
    supports_route: bool,
    route: *ui.Node,
    actions: *ui.Node,
    dot: *ui.Node,
    online: bool,
    forward: *ui.Node,
    forward_label: *ui.Node,
    forward_badge: ?ForwardBadge = null,
    hot: bool = false,
    selected: *ui.Signal(bool),
    menu_open: *ui.Signal(bool),
    menu_trigger: *ui.Node = undefined,
    base: *ui.Signal(ui.BoxStyle),
    hover: *ui.Signal(?ui.BoxStyle),
    tint: *ui.Signal(?ui.Color),
    callbacks: HostCallbacks,
    colors: T.Colors,

    pub fn mount(cx: *ui.Cx, scope: *ui.Scope, data: HostData, callbacks: HostCallbacks) !*HostRow {
        const selected = try scope.createSignal(bool, data.selected);
        const menu_open = try scope.createSignal(bool, false);
        const base = try scope.createSignal(ui.BoxStyle, S.host(data.selected, false));
        const hover = try scope.createSignal(?ui.BoxStyle, .{ .background = T.current().hover });
        const tint = try scope.createSignal(?ui.Color, T.current().fg_2);
        const self = try scope.createState(HostRow, .{ .cx = cx, .node = undefined, .name = undefined, .trailing = undefined, .tail = undefined, .supports_route = data.supports_route, .route = undefined, .actions = undefined, .dot = undefined, .online = data.online, .forward = undefined, .forward_label = undefined, .selected = selected, .menu_open = menu_open, .base = base, .hover = hover, .tint = tint, .callbacks = callbacks, .colors = T.current() });
        const node = try ui.widgets.Button(.{ .variant = .ghost, .a11y_label = try scope.createText(data.name, .{}), .base_style = base, .hover_style = ui.BoxStyle{}, .on_click = cx.on(HostRow, self, HostRow.select), .on_event = onEvent, .event_context = @as(?*anyopaque, self) }).mount(scope, cx);
        node.meta.ownership.meta.test_id = "sidebar.host";
        setFocusRing(node);
        self.node = node;
        const content = try ui.box(cx, S.content(), .{});
        try node.appendChild(cx.allocator, content);
        self.dot = try ui.iconTint(cx, data.icon orelse @import("session_icon.zig").resolve(data.kind), ui.Color.WHITE, S.icon(18));
        self.dot.meta.ownership.meta.test_id = "sidebar.host.icon";
        try content.appendChild(cx.allocator, self.dot);
        const metadata = try ui.box(cx, .{ .width = .{ .grow = .{ .min = 0 } }, .flex_shrink = 1, .height = .{ .px = 24 }, .direction = .row, .align_items = .center, .gap = 6, .min_width = 0 }, .{});
        const name = try ui.text(cx, data.name, S.text(12, 500, false));
        name.meta.ownership.meta.test_id = "sidebar.host.name";
        name.setStyleInline(cx.allocator, .{ .width = .{ .grow = .{ .min = 0 } }, .max_width = cx.text.measureTextWidth(data.name, 12, 500, false), .min_width = 0, .flex_shrink = 1, .overflow_hidden = true });
        self.name = name;
        try metadata.appendChild(cx.allocator, name);
        if (!std.ascii.eqlIgnoreCase(data.protocol, "ssh")) {
            const tag = try ui.box(cx, .{ .height = .{ .px = 12 }, .padding = .{ .left = 3, .right = 3 }, .margin = .{ .top = 8 }, .direction = .row, .align_items = .center, .justify = .center, .background = T.current().well, .border = .{ .radius = 3 }, .flex_shrink = 0 }, .{});
            tag.meta.ownership.meta.test_id = "sidebar.host.protocol";
            const upper = try std.ascii.allocUpperString(cx.allocator, data.protocol);
            defer cx.allocator.free(upper);
            const protocol_text = try ui.text(cx, upper, .{ .font_size = 7, .font_weight = 400, .line_height = 10.0 / 7.0, .color = T.current().fg_2, .selectable = false });
            try protocol_text.setTextContent(cx.allocator, upper);
            protocol_text.setStyleInline(cx.allocator, .{ .height = .{ .px = 10 }, .flex_shrink = 0 });
            try tag.appendChild(cx.allocator, protocol_text);
            try metadata.appendChild(cx.allocator, tag);
        }
        const identity = try std.fmt.allocPrint(cx.allocator, "{s}\n{s}\n{s}", .{ data.name, data.detail, data.route });
        defer cx.allocator.free(identity);
        const identity_hint = try mountHostHint(cx, scope, metadata, identity, node);
        var metadata_viewport = S.titleViewport();
        metadata_viewport.height = .{ .px = 24 };
        identity_hint.wrapper.setStyleInline(cx.allocator, metadata_viewport);
        identity_hint.trigger.setStyleInline(cx.allocator, .{ .width = .{ .grow = .{ .min = 0 } }, .height = .fill(), .min_width = 0, .flex_shrink = 1, .overflow = .hidden });
        try content.appendChild(cx.allocator, identity_hint.wrapper);
        const trailing = try ui.box(cx, .{ .width = .{ .fit = .{} }, .height = .{ .px = 24 }, .direction = .row, .align_items = .center, .gap = 4, .flex_shrink = 0 }, .{});
        self.trailing = trailing;
        trailing.meta.ownership.meta.test_id = "sidebar.host.trailing";
        try content.appendChild(cx.allocator, trailing);
        const tail = try ui.box(cx, S.tail(), .{});
        self.tail = tail;
        tail.meta.ownership.meta.test_id = "sidebar.host.tail";
        try trailing.appendChild(cx.allocator, tail);
        const route = try ui.box(cx, S.route(), .{});
        if (data.supports_route) {
            try route.appendChild(cx.allocator, try ui.iconTint(cx, ui.icons.get("route").?, T.current().fg_2, S.icon(12)));
            var count: [24]u8 = undefined;
            const hops = try text(cx, route, try std.fmt.bufPrint(&count, "{d}", .{data.hops}), 10.5, 400, true);
            hops.meta.ownership.meta.test_id = "sidebar.host.hops";
            hops.setStyleInline(cx.allocator, .{ .width = .{ .px = 12 }, .height = .{ .px = 18 }, .flex_shrink = 0 });
            if (hops.getText()) |old| {
                var next = old;
                next.use_monospace_font = true;
                hops.setText(next);
            }
        }
        self.route = route;
        try tail.appendChild(cx.allocator, route);
        self.forward = try ui.box(cx, .{ .width = .{ .px = S.tail_width }, .height = .{ .px = 20 }, .direction = .row, .align_items = .center, .justify = .end, .flex_shrink = 0, .display = .none }, .{});
        self.forward.meta.ownership.meta.test_id = "sidebar.host.background";
        self.forward_label = try ui.text(cx, "", S.text(9, 500, true));
        self.forward_label.setStyleInline(cx.allocator, .{ .width = .fill(), .min_width = 0 });
        try self.forward.appendChild(cx.allocator, self.forward_label);
        try tail.appendChild(cx.allocator, self.forward);
        const actions = try ui.box(cx, .{ .width = .{ .px = 72 }, .height = .{ .px = 24 }, .direction = .row, .align_items = .center, .gap = 0, .flex_shrink = 0 }, .{});
        self.actions = actions;
        const connect_button = try iconButton(cx, scope, "play", "新标签连接", "sidebar.host.connect", S.action(24), tint, hover, cx.on(HostRow, self, HostRow.connect), swallowDoubleClick);
        try actions.appendChild(cx.allocator, try hint(cx, scope, connect_button, "新标签连接", .right));
        const copy_button = try iconButton(cx, scope, "copy", "复制配置", "sidebar.host.copy", S.action(24), tint, hover, cx.on(HostRow, self, HostRow.copy), swallowDoubleClick);
        const edit_button = try iconButton(cx, scope, "pencil", "编辑配置", "sidebar.host.edit", S.action(24), tint, hover, cx.on(HostRow, self, HostRow.edit), swallowDoubleClick);
        try actions.appendChild(cx.allocator, try hint(cx, scope, copy_button, "复制配置", .right));
        try actions.appendChild(cx.allocator, try hint(cx, scope, edit_button, "编辑配置", .right));
        const menu_button = edit_button;
        self.menu_trigger = edit_button;
        // The complete host menu remains available on right click.

        try trailing.appendChild(cx.allocator, actions);
        const hovered = try ui.hooks.useHover(scope, node);
        const name_hover = try ui.hooks.useHover(scope, identity_hint.trigger);
        const connect_hover = try ui.hooks.useHover(scope, connect_button);
        const menu_hover = try ui.hooks.useHover(scope, menu_button);
        const copy_hover = try ui.hooks.useHover(scope, copy_button);
        const focus = try ui.hooks.useFocusState(scope, cx, node);
        const connect_focus = try ui.hooks.useFocusState(scope, cx, connect_button);
        const menu_focus = try ui.hooks.useFocusState(scope, cx, menu_button);
        const copy_focus = try ui.hooks.useFocusState(scope, cx, copy_button);
        try scope.createEffect(.{ .self = self, .hovered = hovered, .name_hover = name_hover, .connect_hover = connect_hover, .menu_hover = menu_hover, .copy_hover = copy_hover, .copy_focus = copy_focus.focused, .focus = focus.focused, .focus_visible = focus.visible, .connect_focus = connect_focus.focused, .menu_focus = menu_focus.focused, .identity_open = identity_hint.open.?, .last_identity_focus = try scope.createState(bool, false), .theme = try cx.themeSignal(scope) }, struct {
            fn run(ctx: anytype) void {
                _ = ctx.theme.get();
                const picked = ctx.self.selected.get();
                const hot = ctx.hovered.get() or ctx.name_hover.get() or ctx.connect_hover.get() or ctx.menu_hover.get() or ctx.copy_hover.get() or ctx.copy_focus.get() or ctx.focus.get() or ctx.connect_focus.get() or ctx.menu_focus.get() or ctx.self.menu_open.get();
                const identity_focus = ctx.focus_visible.get();
                if (ctx.last_identity_focus.* != identity_focus) {
                    ctx.last_identity_focus.* = identity_focus;
                    ctx.identity_open.set(identity_focus);
                }
                S.repaint(ctx.self.node, ctx.self.colors);
                ctx.self.colors = T.current();
                ctx.self.tint.set(T.current().fg_2);
                ctx.self.hover.set(.{ .background = T.current().well });
                ctx.self.base.set(S.host(picked, hot));
                ctx.self.node.setStyleInline(ctx.self.cx.allocator, S.host(picked, hot));
                setFocusRing(ctx.self.node);
                ctx.self.hot = hot;
                ctx.self.updateTrailing();
                if (ctx.self.forward_badge) |badge| ctx.self.forward_label.setTextColor(@import("socks_background_styles.zig").ink(badge.phase));
                if (ctx.self.name.getText()) |current| {
                    var next = current;
                    next.font_weight = 500;
                    next.color = T.current().fg_1;
                    ctx.self.name.setText(next);
                }
                if (ctx.self.node.behavior.interaction.a11y) |*a11y| a11y.selected = picked;
            }
        }.run);
        self.setForwardBadge(data.forward);
        return self;
    }
    pub fn setForwardBadge(self: *HostRow, badge: ?ForwardBadge) void {
        if (std.meta.eql(self.forward_badge, badge)) return;
        self.forward_badge = badge;
        var buffer: [64]u8 = undefined;
        const label = if (badge) |value| if (value.port) |port| std.fmt.bufPrint(&buffer, ":{d}后台", .{port}) catch "后台" else @import("socks_background_model.zig").phaseLabel(value.phase) else "";
        self.forward_label.setTextContent(self.cx.allocator, label) catch return;
        if (badge) |value| self.forward_label.setTextColor(@import("socks_background_styles.zig").ink(value.phase));
        self.updateTrailing();
        if (self.node.behavior.interaction.a11y) |*props| props.description = if (badge) |value| @import("socks_background_model.zig").phaseLabel(value.phase) else null;
    }
    fn updateTrailing(self: *HostRow) void {
        const show_route = self.supports_route and (self.hot or self.forward_badge == null);
        const show_forward = !self.hot and self.forward_badge != null;
        // Route and actions are siblings in flow, so both remain visible without overlap.
        self.trailing.setDisplay(if (show_route or show_forward or self.hot) .flex else .none);
        self.tail.setStyle(self.cx.allocator, .width, .{ .px = if (show_forward) S.action_size * 3 else S.tail_width });
        self.tail.setDisplay(if (show_route or show_forward) .flex else .none);
        self.route.setDisplay(if (show_route) .flex else .none);
        self.forward.setDisplay(if (show_forward) .flex else .none);
        self.actions.setDisplay(if (self.hot) .flex else .none);
    }
    pub fn setOnline(self: *HostRow, online: bool) void {
        if (self.online == online) return;
        self.online = online;
        _ = self.dot.setTint(ui.Color.WHITE);
    }
    pub fn setSelected(self: *HostRow, selected: bool) void {
        self.selected.set(selected);
    }
    pub fn setMenuOpen(self: *HostRow, open: bool) void {
        self.menu_open.set(open);
    }
    fn select(self: *HostRow) void {
        self.callbacks.select(self.callbacks.context);
    }
    fn connect(self: *HostRow) void {
        self.callbacks.connect(self.callbacks.context);
    }
    fn copy(self: *HostRow) void {
        if (self.callbacks.action) |action| action(self.callbacks.context, .copy);
    }
    fn edit(self: *HostRow) void {
        if (self.callbacks.action) |action| action(self.callbacks.context, .edit);
    }
    fn menu(self: *HostRow) void {
        self.callbacks.menu(self.callbacks.context, self.node);
    }
    fn onEvent(event: ui.events.Event, raw: ?*anyopaque) ui.events.EventResult {
        const self: *HostRow = @ptrCast(@alignCast(raw orelse return .ignored));
        switch (event) {
            .mouse_down => |mouse| if (mouse.button == .right) {
                self.menu();
                return .handled;
            },
            .click => |click| {
                // Child action buttons have already handled their own click.
                // Stop the row's connect callback when that click bubbles.
                const actions = self.actions.globalRect();
                if (click.x >= actions.x and click.x < actions.x + actions.w and click.y >= actions.y and click.y < actions.y + actions.h) return .handled;
            },
            .double_click => return .handled,
            .key_down => |key| if (key.key == .@"return") {
                self.connect();
                return .handled;
            },
            else => {},
        }
        return .ignored;
    }
};

pub const GroupData = struct { reference: ?GroupRef, name: []const u8, count: usize, collapsed: bool, color: ?ui.Color = null };
pub const GroupRow = struct {
    cx: *ui.Cx,
    root: *ui.Node,
    header: *ui.Node,
    members: *ui.Node,
    reference: ?GroupRef,
    bridge: Bridge,
    collapsed: bool,
    disclosure: *@import("layout_motion.zig").Disclosure = undefined,
    chevron: *ui.Node,
    menu: ui.widgets.popover.PopoverResult,
    count: usize,
    pub fn mount(cx: *ui.Cx, scope: *ui.Scope, data: GroupData, bridge: Bridge) !*GroupRow {
        const root = try ui.box(cx, S.groupCard(), .{});
        root.meta.ownership.meta.test_id = "sidebar.group.card";
        const self = try scope.createState(GroupRow, .{ .cx = cx, .root = root, .header = undefined, .members = undefined, .reference = data.reference, .bridge = bridge, .collapsed = data.collapsed, .chevron = undefined, .menu = undefined, .count = data.count });
        const header = try ui.widgets.Button(.{ .variant = .ghost, .a11y_label = try scope.createText(data.name, .{}), .base_style = S.group(), .hover_style = ui.BoxStyle{ .background = T.current().hover }, .on_click = cx.on(GroupRow, self, GroupRow.toggle), .on_event = groupEvent, .event_context = @as(?*anyopaque, self) }).mount(scope, cx);
        header.meta.ownership.meta.test_id = "sidebar.group";
        setFocusRing(header);
        self.header = header;
        try root.appendChild(cx.allocator, header);
        const content = try ui.box(cx, S.groupContent(), .{});
        try header.appendChild(cx.allocator, content);
        const chevron = try ui.iconTint(cx, ui.icons.chevron_down, T.current().fg_2, S.icon(12));
        chevron.setStyle(cx.allocator, .rotate, if (data.collapsed) -std.math.pi / 2.0 else @as(f32, 0));
        self.chevron = chevron;
        try content.appendChild(cx.allocator, chevron);
        const name = try text(cx, content, data.name, 10, 700, true);
        name.setStyleInline(cx.allocator, .{ .width = .fill(), .min_width = 0, .flex = 1 });
        if (data.color) |color| name.setTextColor(color);
        const tint = try scope.createSignal(?ui.Color, T.current().fg_2);
        const hover = try scope.createSignal(?ui.BoxStyle, .{ .background = T.current().well });
        const badge = try ui.box(cx, S.badge(), .{});
        badge.meta.ownership.meta.test_id = "sidebar.group.badge";
        var count: [24]u8 = undefined;
        const count_label = try ui.text(cx, "", S.badgeText());
        const count_text = try std.fmt.bufPrint(&count, "{d}", .{data.count});
        try count_label.setTextContent(cx.allocator, count_text);
        const count_width = @ceil(cx.text.measureTextWidth(count_text, 10, 400, false));
        badge.setStyleInline(cx.allocator, .{ .width = .{ .px = count_width + 14 } });
        var count_style = S.badgeLabel();
        count_style.width = .{ .px = count_width };
        count_label.setStyleInline(cx.allocator, count_style);
        count_label.meta.ownership.meta.test_id = "sidebar.group.count";
        try badge.appendChild(cx.allocator, count_label);
        const trailing = try ui.box(cx, S.tail(), .{});
        try content.appendChild(cx.allocator, trailing);
        try trailing.appendChild(cx.allocator, badge);
        const actions = try ui.box(cx, .{ .direction = .row, .align_items = .center, .gap = 4, .flex_shrink = 0 }, .{});
        const plus = try iconButton(cx, scope, "plus", "组内新建主机", "sidebar.group.new", S.action(24), tint, hover, cx.on(GroupRow, self, GroupRow.newHost), swallowDoubleClick);
        if (bridge.new_host == null) plus.behavior.interaction.focusable = false;
        try actions.appendChild(cx.allocator, plus);
        const menu = try ui.widgets.Popover(.{ .trigger = .click, .position = .bottom_start, .close_on_escape = true, .close_on_outside_click = true, .width = @as(f32, 258), .max_width = @as(f32, 258), .max_height = @as(f32, 199) }).mount(scope, cx);
        menu.content.setStyleInline(cx.allocator, S.menu(199));
        menu.content.meta.ownership.meta.test_id = "sidebar.group.menu";
        self.menu = menu;
        const more = try iconButton(cx, scope, "ellipsis", "更多分组操作", "sidebar.group.more", S.action(24), tint, hover, null, swallowDoubleClick);
        try menu.trigger.appendChild(cx.allocator, more);
        try actions.appendChild(cx.allocator, menu.wrapper);
        try trailing.appendChild(cx.allocator, actions);
        const caption = try std.fmt.allocPrint(cx.allocator, "资产组 · {s}", .{data.name});
        defer cx.allocator.free(caption);
        _ = try text(cx, menu.content, caption, 10.5, 400, true);
        for ([_]GroupAction{ .new_host, .rename, .color, .toggle_collapsed, .delete_empty }, [_][]const u8{ "组内新建主机", "重命名分组", "更改组色", if (data.collapsed) "展开分组" else "折叠分组", "删除空分组" }, [_][]const u8{ "server", "pencil", "palette", if (data.collapsed) "chevron-down" else "chevron-up", "trash-2" }) |action, label, icon_name| {
            const control = try menu.scope.createState(GroupControl, .{ .group = self, .action = action });
            const enabled = if (action == .new_host) bridge.new_host != null else if (action == .toggle_collapsed and data.reference == null) true else bridge.group_action != null and data.reference != null and (action != .delete_empty or data.count == 0);
            var item_style = S.menuRow();
            item_style.text_color = if (action == .delete_empty) T.current().danger_ink else T.current().fg_1;
            item_style.font_size = 11.5;
            item_style.font_weight = 400;
            const button = try ui.widgets.Button(.{ .label = label, .icon_asset = ui.icons.get(icon_name), .icon_size = @as(f32, 14), .icon_tint = if (action == .delete_empty) T.current().danger_ink else T.current().fg_2, .variant = .ghost, .a11y_label = label, .disabled = !enabled, .base_style = item_style, .hover_style = ui.BoxStyle{ .background = T.current().hover }, .on_click = cx.on(GroupControl, control, GroupControl.run) }).mount(menu.scope, cx);
            if (button.behavior.interaction.a11y) |*a11y| a11y.role = .menuitem;
            try menu.content.appendChild(cx.allocator, button);
        }
        try MenuKeyboard.install(cx, menu);
        const members = try ui.box(cx, S.members(), .{});
        self.members = members;
        self.disclosure = try @import("layout_motion.zig").Disclosure.mount(cx, scope, members, !data.collapsed);
        try root.appendChild(cx.allocator, self.disclosure.root);
        const hovered = try ui.hooks.useHover(scope, header);
        const focused = try ui.hooks.useFocusState(scope, cx, header);
        const plus_focus = try ui.hooks.useFocusState(scope, cx, plus);
        const more_focus = try ui.hooks.useFocusState(scope, cx, more);
        try scope.createEffect(.{ .self = self, .hovered = hovered, .focused = focused.focused, .plus_focus = plus_focus.focused, .more_focus = more_focus.focused, .actions = actions, .badge = badge, .open = menu.open.?, .tint = tint, .hover = hover, .theme = try cx.themeSignal(scope) }, struct {
            fn run(ctx: anytype) void {
                _ = ctx.theme.get();
                const hot = ctx.hovered.get() or ctx.focused.get() or ctx.plus_focus.get() or ctx.more_focus.get() or ctx.open.get();
                ctx.actions.setDisplay(if (hot) .flex else .none);
                ctx.badge.setDisplay(if (hot) .none else .flex);
                ctx.tint.set(T.current().fg_2);
                ctx.hover.set(.{ .background = T.current().well });
            }
        }.run);
        return self;
    }
    fn toggle(self: *GroupRow) void {
        if (self.reference) |group| {
            if (self.bridge.group_action) |call| call(self.bridge.context, group, .toggle_collapsed);
        } else {
            self.collapsed = !self.collapsed;
            self.disclosure.setExpanded(!self.collapsed);
            self.header.behavior.interaction.a11y.?.expanded = !self.collapsed;
            self.chevron.setStyle(self.cx.allocator, .rotate, if (self.collapsed) -std.math.pi / 2.0 else @as(f32, 0));
        }
    }
    fn newHost(self: *GroupRow) void {
        if (self.bridge.new_host) |call| call(self.bridge.context, self.reference);
    }
    fn groupEvent(event: ui.events.Event, raw: ?*anyopaque) ui.events.EventResult {
        const self: *GroupRow = @ptrCast(@alignCast(raw orelse return .ignored));
        switch (event) {
            .mouse_down => |mouse| if (mouse.button == .right) {
                self.menu.show.invoke();
                return .handled;
            },
            .double_click => return .handled,
            else => {},
        }
        return .ignored;
    }
};
const GroupControl = struct {
    group: *GroupRow,
    action: GroupAction,
    fn run(self: *GroupControl) void {
        if (self.group.bridge.set_anchor) |call| call(self.group.bridge.context, self.group.menu.trigger.globalRect());
        self.group.menu.close.invoke();
        if (self.action == .new_host) return self.group.newHost();
        if (self.action == .toggle_collapsed and self.group.reference == null) return self.group.toggle();
        if (self.group.reference) |group| if (self.group.bridge.group_action) |call| call(self.group.bridge.context, group, self.action);
    }
};

// Menu's stock API has no header/content/style slots. The exact prototype
// headers therefore use Popover + Button, with this small focus adapter.
// Button still owns activation, focus rings, disabled state and accessibility.
const MenuKeyboard = struct {
    cx: *ui.Cx,
    popup: ui.widgets.popover.PopoverResult,
    focus_pending: bool = false,
    fn install(cx: *ui.Cx, popup: ui.widgets.popover.PopoverResult) !void {
        const state = try popup.scope.createState(MenuKeyboard, .{ .cx = cx, .popup = popup });
        popup.content.behavior.interaction.a11y = .{ .role = .menu };
        popup.content.behavior.events.on_key_down = onKey;
        popup.content.behavior.events.key_context = state;
        try cx.addAfterLayoutHook(state, afterLayout);
        try popup.scope.onCleanup(MenuKeyboard, state, cleanup);
        try popup.scope.createEffect(.{ .state = state, .open = popup.open.? }, struct {
            fn run(ctx: anytype) void {
                ctx.state.focus_pending = ctx.open.get();
            }
        }.run);
    }
    fn cleanup(self: *MenuKeyboard) void {
        self.cx.removeAfterLayoutHook(self);
    }
    fn afterLayout(raw: *anyopaque, _: u8, _: bool) ui.AfterLayoutResult {
        const self: *MenuKeyboard = @ptrCast(@alignCast(raw));
        if (!self.focus_pending or !self.popup.open_read.peek()) return .done;
        if (self.popup.content.globalRect().w <= 0) return .done;
        self.focus_pending = false;
        for (self.popup.content.children.items) |node| if (enabled(node)) {
            self.cx.setFocus(node);
            break;
        };
        return .done;
    }
    fn enabled(node: *ui.Node) bool {
        const a11y = node.behavior.interaction.a11y orelse return false;
        const item = a11y.role == .menuitem or a11y.role == .button;
        if (item) node.behavior.interaction.a11y.?.role = .menuitem;
        return item and !a11y.disabled;
    }
    fn onKey(key: ui.events.KeyCode, _: ui.events.Modifiers, raw: ?*anyopaque) ui.events.EventResult {
        const state: *MenuKeyboard = @ptrCast(@alignCast(raw orelse return .ignored));
        if (key == .escape) {
            state.popup.close.invoke();
            return .stop;
        }
        if (key != .up and key != .down) return .ignored;
        const nodes = state.popup.content.children.items;
        if (nodes.len == 0) return .stop;
        var current: usize = if (key == .down) nodes.len - 1 else 0;
        for (nodes, 0..) |node, i| if (state.cx.isFocused(node)) {
            current = i;
            break;
        };
        for (0..nodes.len) |_| {
            current = if (key == .down) (current + 1) % nodes.len else (current + nodes.len - 1) % nodes.len;
            if (enabled(nodes[current])) {
                state.cx.setFocus(nodes[current]);
                break;
            }
        }
        return .stop;
    }
};

pub fn text(cx: *ui.Cx, parent: *ui.Node, value: []const u8, size: f32, weight: u16, secondary: bool) !*ui.Node {
    const node = try ui.text(cx, "", S.text(size, weight, secondary));
    try node.setTextContent(cx.allocator, value);
    try parent.appendChild(cx.allocator, node);
    return node;
}
pub fn iconButton(cx: *ui.Cx, scope: *ui.Scope, icon_name: []const u8, label: []const u8, id: []const u8, base: ui.BoxStyle, tint: *ui.Signal(?ui.Color), hover: *ui.Signal(?ui.BoxStyle), click: ?ui.Handler(void), event: ?*const fn (ui.events.Event, ?*anyopaque) ui.events.EventResult) !*ui.Node {
    const node = try ui.widgets.Button(.{ .variant = .ghost, .icon_only = true, .icon_asset = ui.icons.get(icon_name), .icon_size = @as(f32, 16), .icon_tint = tint, .a11y_label = label, .base_style = base, .hover_style = hover, .on_click = click, .on_event = event }).mount(scope, cx);
    node.meta.ownership.meta.test_id = id;
    setFocusRing(node);
    return node;
}
pub fn setFocusRing(node: *ui.Node) void {
    // Button owns this public hook state. Adjust its existing ring rather than
    // installing another focus handler with an independent lifetime.
    if (node.meta.per_frame.hooks.slots.focus_ring_anim) |raw| {
        const state: *ui.hooks.FocusRingAnimState = @ptrCast(@alignCast(raw));
        state.focus_width = 0;
        state.focus_offset = -1;
        state.focus_color = ui.Color.TRANSPARENT;
    }
}
fn swallowDoubleClick(event: ui.events.Event, _: ?*anyopaque) ui.events.EventResult {
    return switch (event) {
        .double_click, .mouse_down => .handled,
        else => .ignored,
    };
}
pub fn hint(cx: *ui.Cx, scope: *ui.Scope, node: *ui.Node, value: []const u8, position: ui.widgets.PopoverPosition) !*ui.Node {
    return (try mountHint(cx, scope, node, value, position)).wrapper;
}
fn mountHint(cx: *ui.Cx, scope: *ui.Scope, node: *ui.Node, value: []const u8, position: ui.widgets.PopoverPosition) !ui.widgets.popover.PopoverResult {
    return mountHintAnchored(cx, scope, node, value, position, null);
}
fn mountHintAnchored(cx: *ui.Cx, scope: *ui.Scope, node: *ui.Node, value: []const u8, position: ui.widgets.PopoverPosition, anchor: ?*HostHintAnchor) !ui.widgets.popover.PopoverResult {
    const popup = try ui.widgets.Popover(.{ .trigger = .hover, .position = position, .anchor = if (anchor) |host| @as(ui.widgets.popover.Anchor, .{ .virtual = .{ .ctx = host, .getRect = HostHintAnchor.rect } }) else null, .offset = .{ .static = 8 }, .tier = .tooltip, .open_delay_ms = @as(f32, 450), .close_on_escape = false, .close_on_outside_click = false, .max_width = @as(f32, 320), .max_height = @as(f32, 120), .size_policy = .fit_content }).mount(scope, cx);
    popup.content.setStyleInline(cx.allocator, S.hint());
    popup.content.behavior.interaction.a11y = .{ .role = .tooltip };
    const label = try text(cx, popup.content, value, 11, 400, true);
    if (label.getText()) |old| {
        var next = old;
        next.wrap = .word;
        label.setText(next);
    }
    label.setStyleInline(cx.allocator, .{ .max_width = 300 });
    try popup.trigger.appendChild(cx.allocator, node);
    const focus = try ui.hooks.useFocusState(scope, cx, node);
    const last = try scope.createState(bool, false);
    try scope.createEffect(.{ .focus = focus.visible, .open = popup.open.?, .last = last, .theme = try cx.themeSignal(scope), .content = popup.content, .old = try scope.createState(T.Colors, T.current()) }, struct {
        fn run(ctx: anytype) void {
            _ = ctx.theme.get();
            const focused = ctx.focus.get();
            if (focused != ctx.last.*) {
                ctx.open.set(focused);
                ctx.last.* = focused;
            }
            S.repaint(ctx.content, ctx.old.*);
            ctx.old.* = T.current();
        }
    }.run);
    return popup;
}

const HostHintAnchor = struct {
    row: *ui.Node,
    fn rect(raw: *anyopaque) ui.widgets.popover.AnchorRect {
        const self: *@This() = @ptrCast(@alignCast(raw));
        const row = self.row.globalRect();
        var parent: ?*ui.Node = self.row;
        while (parent) |node| : (parent = node.parent) {
            if (node.meta.ownership.meta.test_id) |id| if (std.mem.eql(u8, id, "workspace.sidebar")) {
                const panel = node.globalRect();
                return .{ .x = panel.x + panel.w, .y = row.y, .w = 0, .h = row.h };
            };
        }
        return .{ .x = row.x + row.w, .y = row.y, .w = 0, .h = row.h };
    }
};
fn mountHostHint(cx: *ui.Cx, scope: *ui.Scope, node: *ui.Node, value: []const u8, row: *ui.Node) !ui.widgets.popover.PopoverResult {
    const anchor = try scope.createState(HostHintAnchor, .{ .row = row });
    const popup = try mountHintAnchored(cx, scope, node, value, .right, anchor);
    popup.content.meta.ownership.meta.test_id = "sidebar.host.info";
    return popup;
}
