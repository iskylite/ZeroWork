const std = @import("std");
const ui = @import("ui");
const theme = @import("app_theme.zig");
const Sidebar = @import("sidebar_view.zig");
const S = Sidebar.styles;
const Workspace = @import("workspace.zig").Workspace;
const identity = @import("../host/identity.zig");
pub const HostAction = enum { edit, connect };
pub const Actions = struct {
    context: *anyopaque,
    search: *const fn (*anyopaque) void,
    new_host: *const fn (*anyopaque) void,
    expand: *const fn (*anyopaque) void,
    host_action: ?*const fn (*anyopaque, identity.AssetOwner, HostAction) void = null,
};
pub const View = struct {
    cx: *ui.Cx,
    scope: *ui.Scope,
    workspace: *Workspace,
    root: *ui.Node,
    list: *ui.Node,
    items_scope: ?*ui.Scope = null,
    items: std.ArrayList(*HostItem) = .empty,
    fingerprint: ?u64 = null,
    chosen: ?identity.ConnectionId = null,
    icon_tint: *ui.Signal(?ui.Color),
    hover: *ui.Signal(?ui.BoxStyle),
    actions: Actions,
    colors: theme.Colors,

    pub fn mount(cx: *ui.Cx, scope: *ui.Scope, workspace: *Workspace, actions: Actions) !*View {
        const root = try ui.boxStyled(cx, S.rail, .{});
        root.meta.ownership.meta.test_id = "workspace.sidebar.collapsed";
        const tint = try scope.createSignal(?ui.Color, theme.current().fg_2);
        const hover = try scope.createSignal(?ui.BoxStyle, .{ .background = theme.current().hover });
        const list = try ui.box(cx, .{ .width = .fill(), .height = .{ .fit = .{} }, .direction = .column, .align_items = .center, .gap = 10 }, .{});
        const self = try scope.createState(View, .{ .cx = cx, .scope = scope, .workspace = workspace, .root = root, .list = list, .icon_tint = tint, .hover = hover, .actions = actions, .colors = theme.current() });
        try scope.onCleanup(View, self, cleanup);
        const expand = try Sidebar.iconButton(cx, scope, "panel-left-open", "展开侧栏 ⌘B", "sidebar.rail.expand", S.railAction(32), tint, hover, ui.Cx.simpleHandler(actions.expand, actions.context), null);
        try root.appendChild(cx.allocator, try Sidebar.hint(cx, scope, expand, "展开侧栏 ⌘B", .right));
        const scroll = try ui.widgets.ScrollArea(.{}).mount(scope, cx);
        scroll.container.setStyleInline(cx.allocator, .{ .width = .{ .px = 32 }, .height = .fill(), .flex = 1, .min_height = 0 });
        scroll.content.setStyleInline(cx.allocator, .{ .width = .fill(), .direction = .column });
        try scroll.content.appendChild(cx.allocator, list);
        try root.appendChild(cx.allocator, scroll.container);
        const plus = try Sidebar.iconButton(cx, scope, "plus", "新建主机", "sidebar.rail.new", S.railAction(28), tint, hover, ui.Cx.simpleHandler(actions.new_host, actions.context), null);
        try root.appendChild(cx.allocator, try Sidebar.hint(cx, scope, plus, "新建主机", .right));
        try self.refresh();
        root.setDisplay(.none);
        return self;
    }
    pub fn setCollapsed(self: *View, collapsed: bool) void {
        if (!collapsed) for (self.items.items) |item| {
            item.pending_show = false;
            item.popup.close.invoke();
        };
        self.root.setDisplay(if (collapsed) .flex else .none);
        self.cx.requestRedraw();
    }
    pub fn ownsSidebar(_: *const View) bool {
        return false;
    }
    fn cleanup(self: *View) void {
        self.items.deinit(self.cx.allocator);
    }
    pub fn refresh(self: *View) !void {
        var hash = std.hash.Wyhash.init(0);
        std.hash.autoHash(&hash, self.workspace.registry.revision);
        for (self.workspace.registry.hosts) |host| {
            std.hash.autoHash(&hash, host.connection_id);
            std.hash.autoHash(&hash, host.revision);
        }
        const fingerprint = hash.final();
        if (self.fingerprint == null or self.fingerprint.? != fingerprint) {
            for (self.items.items) |item| item.popup.close.invoke();
            if (self.items_scope) |old| old.dispose();
            self.items_scope = null;
            self.items.clearRetainingCapacity();
            while (self.list.children.items.len > 0) {
                const old = self.list.children.items[self.list.children.items.len - 1];
                self.cx.detachChild(self.list, old);
                self.cx.destroyDetached(old);
            }
            const child_scope = try self.scope.childScope();
            self.items_scope = child_scope;
            for (self.workspace.registry.hosts) |host| {
                if (@backingInt(host.connection_id) == 0) continue;
                const item = try HostItem.mount(self, child_scope, host.owner());
                try self.items.append(self.cx.allocator, item);
                try self.list.appendChild(self.cx.allocator, item.popup.wrapper);
            }
            self.fingerprint = fingerprint;
        }
        const changed = !std.meta.eql(self.colors, theme.current());
        if (changed) {
            // The rail and Buttons already own themed/dynamic style bindings.
            // Repainting that subtree imperatively installs a background override
            // above each host's current railHost base style.
            for (self.items.items) |item| S.repaint(item.popup.chrome, self.colors);
            self.colors = theme.current();
            self.icon_tint.set(self.colors.fg_2);
            self.hover.set(.{ .background = self.colors.hover });
        }
        for (self.items.items) |item| try item.refresh(changed);
    }
};
const HostItem = struct {
    view: *View,
    owner: identity.AssetOwner,
    node: *ui.Node,
    popup: ui.widgets.popover.PopoverResult,
    base: *ui.Signal(ui.BoxStyle),
    tint: *ui.Signal(?ui.Color),
    meta: *ui.Node,
    selected: ?bool = null,
    online: ?bool = null,
    sessions: ?usize = null,
    last_focus: bool = false,
    dismissing: bool = false,
    last_pointer: ?[2]f32 = null,
    pending_show: bool = false,

    fn mount(view: *View, scope: *ui.Scope, owner: identity.AssetOwner) !*HostItem {
        const host = try view.workspace.registry.get(owner);
        const base = try scope.createSignal(ui.BoxStyle, S.railHost(false));
        const tint = try scope.createSignal(?ui.Color, theme.current().fg_2);
        const item = try scope.createState(HostItem, .{ .view = view, .owner = owner, .popup = undefined, .node = undefined, .base = base, .tint = tint, .meta = undefined });
        const popup = try ui.widgets.Popover(.{ .trigger = .manual, .position = .right_start, .offset = .{ .static = 14 }, .anchor = .{ .virtual = .{ .ctx = item, .getRect = anchorRect } }, .width = @as(f32, 320), .max_width = @as(f32, 320), .max_height = @as(f32, 154), .open_delay_ms = @as(f32, 450), .close_on_escape = true, .close_on_outside_click = true }).mount(scope, view.cx);
        item.popup = popup;
        const content_scope = popup.scope;
        popup.chrome.setStyleInline(view.cx.allocator, .{ .padding = ui.Padding.all(0), .background = theme.current().overlay, .border = .{ .radius = 11 } });
        popup.content.setStyleInline(view.cx.allocator, S.railDetail());
        popup.content.meta.ownership.meta.test_id = "sidebar.rail.detail";
        const button = try ui.widgets.Button(.{ .variant = .ghost, .icon_only = true, .icon_asset = @import("session_icon.zig").resolve(if (host.protocol == .sftp) .file else .terminal), .icon_size = @as(f32, 16), .icon_tint = tint, .a11y_label = try content_scope.createText(host.name, .{}), .base_style = base, .hover_style = view.hover, .on_click = view.cx.on(HostItem, item, show), .on_event = detailEvent, .event_context = @as(?*anyopaque, item) }).mount(content_scope, view.cx);
        button.meta.ownership.meta.test_id = try scopeText(scope, view.cx, owner);
        item.node = button;
        Sidebar.setFocusRing(button);
        try popup.trigger.appendChild(view.cx.allocator, button);
        popup.wrapper.setStyleInline(view.cx.allocator, .{ .width = .{ .px = 32 }, .height = .{ .px = 32 }, .flex_shrink = 0 });
        popup.trigger.setStyleInline(view.cx.allocator, .{ .width = .{ .px = 32 }, .height = .{ .px = 32 }, .flex_shrink = 0 });
        _ = try Sidebar.text(view.cx, popup.content, host.name, 13, 500, false);
        const endpoint = try std.fmt.allocPrint(view.cx.allocator, "{s}@{s}:{d}", .{ host.user, host.host, host.port });
        defer view.cx.allocator.free(endpoint);
        const endpoint_node = try Sidebar.text(view.cx, popup.content, endpoint, 11, 400, true);
        if (endpoint_node.getText()) |old| {
            var next = old;
            next.use_monospace_font = true;
            next.line_height = 17.0 / 11.0;
            endpoint_node.setText(next);
        }
        endpoint_node.setStyleInline(view.cx.allocator, .{ .width = .fill(), .height = .{ .px = 17 }, .flex_shrink = 0 });
        item.meta = try Sidebar.text(view.cx, popup.content, "", 11, 400, true);
        item.meta.setStyleInline(view.cx.allocator, .{ .width = .fill(), .height = .{ .px = 16 }, .flex_shrink = 0 });
        const row = try ui.box(view.cx, .{ .width = .fill(), .height = .{ .px = 30 }, .direction = .row, .justify = .end, .gap = 6, .flex_shrink = 0 }, .{});
        for ([_]HostAction{ .edit, .connect }, [_][]const u8{ "编辑配置", "新标签连接" }) |action, label| {
            const click = try content_scope.createState(HostClick, .{ .item = item, .action = action });
            const control = try ui.widgets.Button(.{ .label = label, .variant = @as(ui.widgets.button.ButtonVariant, if (action == .connect) .primary else .secondary), .size = .sm, .disabled = view.actions.host_action == null, .base_style = S.railDetailButton(if (action == .connect) 128 else 108), .on_click = view.cx.on(HostClick, click, HostClick.run) }).mount(content_scope, view.cx);
            control.meta.ownership.meta.test_id = if (action == .connect) "sidebar.rail.detail.connect" else "sidebar.rail.detail.edit";
            try row.appendChild(view.cx.allocator, control);
        }
        try popup.content.appendChild(view.cx.allocator, row);
        popup.content.behavior.events.event_context = item;
        popup.content.behavior.events.on_event_capture = detailEvent;
        // Escape is consumed by the public overlay stack before node events.
        // Pointer dismissal below covers the trigger, gap and portaled panel.
        // It must not restore focus onto the trigger and reopen the panel.
        if (view.cx.overlay_stack.findLayerForNode(popup.chrome)) |found| {
            if (view.cx.overlay_stack.findLayer(found.handle)) |layer| {
                layer.config.on_dismiss_request = view.cx.on(HostItem, item, dismiss);
                layer.config.focus.restore = false;
                layer.config.dismiss.outside_click = .close;
            }
        }
        popup.wrapper.behavior.events.on_hover = view.cx.on(HostItem, item, show);
        const focus = try ui.hooks.useFocusState(content_scope, view.cx, button);
        try content_scope.createEffect(.{ .item = item, .focus = focus.visible }, struct {
            fn run(ctx: anytype) void {
                const focused = ctx.focus.get();
                if (!focused) ctx.item.dismissing = false;
                if (focused and !ctx.item.last_focus and !ctx.item.dismissing) {
                    ctx.item.pending_show = true;
                    ctx.item.view.cx.requestRedraw();
                }
                ctx.item.last_focus = focused;
            }
        }.run);
        return item;
    }
    fn anchorRect(raw: *anyopaque) ui.widgets.popover.AnchorRect {
        const self: *HostItem = @ptrCast(@alignCast(raw));
        const rect = self.node.globalRect();
        return .{ .x = rect.x, .y = rect.y - 4, .w = rect.w, .h = rect.h };
    }
    fn scopeText(scope: *ui.Scope, cx: *ui.Cx, owner: identity.AssetOwner) ![]const u8 {
        const value = try std.fmt.allocPrint(cx.allocator, "sidebar.rail.host.{d}", .{@backingInt(owner.id)});
        defer cx.allocator.free(value);
        return (try scope.createText(value, .{})).peek();
    }
    fn show(self: *HostItem) void {
        self.dismissing = false;
        _ = self.view.workspace.registry.get(self.owner) catch return;
        for (self.view.items.items) |other| if (other != self) other.popup.close.invoke();
        self.view.chosen = self.owner.id;
        self.popup.show.invoke();
        self.refresh(true) catch {};
    }
    fn refresh(self: *HostItem, force: bool) !void {
        const view = self.view;
        const host = try view.workspace.registry.get(self.owner);
        if (self.pending_show) {
            self.pending_show = false;
            self.show();
        }
        // Click and keyboard opening can bypass the wrapper's hover-enter.
        // Dismiss after an actual pointer move outside both interactive surfaces.
        if (view.cx.dispatcher.has_last_mouse) {
            const pointer = view.cx.dispatcher.last_mouse_pos;
            if (self.last_pointer) |previous| {
                if (!std.meta.eql(previous, pointer) and self.popup.open.?.peek()) {
                    const trigger = self.node.globalRect();
                    const panel = self.popup.chrome.globalRect();
                    const on_trigger = pointer[0] >= trigger.x and pointer[0] <= trigger.x + trigger.w and pointer[1] >= trigger.y and pointer[1] <= trigger.y + trigger.h;
                    const on_panel = pointer[0] >= panel.x and pointer[0] <= panel.x + panel.w and pointer[1] >= panel.y and pointer[1] <= panel.y + panel.h;
                    const on_bridge = pointer[0] >= trigger.x + trigger.w and pointer[0] <= panel.x and pointer[1] >= trigger.y and pointer[1] <= trigger.y + trigger.h;
                    if (!on_trigger and !on_panel and !on_bridge) self.popup.close.invoke();
                }
            }
            self.last_pointer = pointer;
        }
        const selected = if (view.chosen) |chosen| chosen == self.owner.id else if (view.workspace.selected_host) |index| index < view.workspace.registry.hosts.len and view.workspace.registry.hosts[index].connection_id == self.owner.id else false;
        if (force or self.selected == null or self.selected.? != selected) {
            self.base.set(S.railHost(selected));
            self.tint.set(if (self.online orelse false) theme.current().ok else theme.current().fg_3);
            self.selected = selected;
        }
        const online = if (view.workspace.registry.indexOf(self.owner.id)) |index| view.workspace.hostOnline(index) else false;
        var sessions: usize = 0;
        if (view.workspace.registry.indexOf(self.owner.id)) |index| {
            const host_id = view.workspace.identities.hostAt(index);
            for (view.workspace.tabs.items) |tab| if (tab.host_id == host_id and !tab.archived) {
                sessions += 1;
            };
        }
        if (!force and self.online != null and self.online.? == online and self.sessions == sessions) return;
        self.sessions = sessions;
        self.online = online;
        self.tint.set(if (online) theme.current().ok else theme.current().fg_3);
        var route: std.Io.Writer.Allocating = .init(view.cx.allocator);
        defer route.deinit();
        const group = if (host.asset_group_id) |id| if (view.workspace.registry.groupIndex(id)) |index| view.workspace.registry.groups[index].name else "未分组" else host.group orelse "未分组";
        try route.writer.print("{s} · ", .{group});
        if (host.route.len > 0) {
            try route.writer.writeAll("经 ");
            for (host.route, 0..) |id, index| {
                if (index != 0) try route.writer.writeAll(" → ");
                try route.writer.writeAll(if (view.workspace.registry.indexOf(id)) |at| view.workspace.registry.hosts[at].name else "缺失的跳板");
            }
        } else if (host.jump_chain.len > 0) {
            try route.writer.writeAll("经 ");
            for (host.jump_chain, 0..) |name, index| {
                if (index != 0) try route.writer.writeAll(" → ");
                try route.writer.writeAll(name);
            }
        } else try route.writer.writeAll("直连");
        try route.writer.print(" · {s} {s} · {d} 个会话", .{ if (host.protocol == .sftp) "SFTP" else "SSH", if (online) "在线" else "离线", sessions });
        try self.meta.setTextContent(view.cx.allocator, route.writer.buffered());
    }
    fn dismiss(self: *HostItem) void {
        self.dismissing = true;
        self.popup.close.invoke();
        self.view.cx.setFocus(self.node);
    }
    fn detailEvent(event: ui.events.Event, raw: ?*anyopaque) ui.events.EventResult {
        const self: *HostItem = @ptrCast(@alignCast(raw orelse return .ignored));
        if (event == .key_down and event.key_down.key == .escape) {
            self.dismiss();
            return .stop;
        }
        return .ignored;
    }
};
const HostClick = struct {
    item: *HostItem,
    action: HostAction,
    fn run(self: *HostClick) void {
        const view = self.item.view;
        _ = view.workspace.registry.get(self.item.owner) catch {
            self.item.popup.close.invoke();
            return;
        };
        self.item.popup.close.invoke();
        if (view.actions.host_action) |callback| callback(view.actions.context, self.item.owner, self.action);
    }
};
