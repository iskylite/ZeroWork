//! Attached-window list. All identities/counts are supplied by the registry.
const std = @import("std");
const ui = @import("ui");
const identity = @import("../host/identity.zig");
pub const M = @import("socks_background_model.zig");
pub const S = @import("socks_background_styles.zig");
const Sidebar = @import("sidebar_view.zig");
const ForwardStyle = @import("socks_info_styles.zig");
pub const Action = enum { open_terminal, reconnect, stop };
pub const Hooks = struct {
    context: *anyopaque,
    action: *const fn (*anyopaque, identity.SessionHandle, Action) void,
};
pub const View = struct {
    cx: *ui.Cx,
    hooks: Hooks,
    popover: ui.widgets.popover.PopoverResult,
    header: *ui.Node,
    list: ui.widgets.ScrollAreaResult,
    remote_entry: *ui.Node,
    local_entry: *ui.Node,
    count_text: *ui.Signal([]const u8),
    tint: *ui.Signal(?ui.Color),
    hover: *ui.Signal(?ui.BoxStyle),
    count_style: *ui.Signal(ui.BoxStyle),
    anchor: ui.ComputedRect = .{ .x = 0, .y = 0, .w = 0, .h = 0 },
    filter: ?identity.ConnectionId = null,
    row_scope: ?*ui.Scope = null,
    revision: u64 = 0,
    last_hash: ?u64 = null,
    colors: S.theme.Colors,
    inline_section: ?struct { root: *ui.Node, list: ui.widgets.ScrollAreaResult, count: *ui.Node } = null,
    inline_closed: ?struct { context: *anyopaque, close: *const fn (*anyopaque) void } = null,
    shape_hash: ?u64 = null,
    meters: ?*Meter = null,

    pub fn mount(cx: *ui.Cx, scope: *ui.Scope, hooks: Hooks) !*View {
        const tint = try scope.createSignal(?ui.Color, S.theme.current().fg_2);
        const hover = try scope.createSignal(?ui.BoxStyle, .{ .background = S.theme.states().hover });
        const count_style = try scope.createSignal(ui.BoxStyle, S.count());
        const count_text = try scope.createText("", .{});
        const self = try scope.createState(View, .{ .cx = cx, .hooks = hooks, .popover = undefined, .header = undefined, .list = undefined, .remote_entry = undefined, .local_entry = undefined, .count_text = count_text, .tint = tint, .hover = hover, .count_style = count_style, .colors = S.theme.current() });
        self.popover = try ui.widgets.Popover(.{ .group = @import("floating_surface.zig").workspace_popup, .trigger = .manual, .position = .top_end, .offset = .{ .static = 6 }, .width = @as(f32, 360), .max_width = @as(f32, 360), .max_height = @as(f32, 420), .constrain_width_to_viewport = true, .close_on_escape = true, .close_on_outside_click = false, .anchor = .{ .virtual = .{ .ctx = self, .getRect = anchorRect } } }).mount(scope, cx);
        self.popover.content.meta.ownership.meta.test_id = "socks.background.panel";
        self.popover.content.setStyleInline(cx.allocator, S.panel(128, cx.viewport.width));
        self.popover.trigger.setDisplay(.none);
        const header = try ui.box(cx, .{ .width = .fill(), .height = .{ .px = 30 }, .direction = .row, .align_items = .center, .gap = 6, .flex_shrink = 0 }, .{});
        self.header = header;
        try header.appendChild(cx.allocator, try ui.iconTint(cx, ui.icons.get("plug-zap").?, S.theme.current().accent, .{ .width = .{ .px = 18 }, .height = .{ .px = 18 }, .flex_shrink = 0 }));
        const title = try ui.text(cx, "后台转发", S.text(13, 700, 20, S.theme.current().fg_1));
        title.setStyleInline(cx.allocator, .{ .width = .fill(), .min_width = 0 });
        try header.appendChild(cx.allocator, title);
        const close = try ui.widgets.Button(.{ .icon_only = true, .icon_asset = ui.icons.x, .icon_size = @as(f32, 18), .icon_tint = tint, .variant = .ghost, .a11y_label = "关闭后台转发列表", .base_style = S.action(22), .hover_style = hover, .on_click = self.popover.close }).mount(self.popover.scope, cx);
        close.meta.ownership.meta.test_id = "socks.background.close";
        try header.appendChild(cx.allocator, close);
        try self.popover.content.appendChild(cx.allocator, header);
        self.list = try ui.widgets.ScrollArea(.{}).mount(self.popover.scope, cx);
        self.list.container.setStyleInline(cx.allocator, .{ .width = .fill(), .height = .fill(), .flex = 1, .min_height = 0 });
        self.list.content.setStyleInline(cx.allocator, .{ .width = .fill(), .direction = .column, .gap = 6, .min_width = 0 });
        self.list.content.meta.ownership.meta.test_id = "socks.background.rows";
        try self.popover.content.appendChild(cx.allocator, self.list.container);
        self.remote_entry = try self.entry(scope, "status.background.forward");
        self.local_entry = try self.entry(scope, "local.status.background.forward");
        try scope.createEffect(.{ .view = self, .theme = try cx.themeSignal(scope) }, struct {
            fn run(ctx: anytype) void {
                _ = ctx.theme.get();
                const view = ctx.view;
                Sidebar.styles.repaint(view.popover.content, view.colors);
                if (view.inline_section) |section| Sidebar.styles.repaint(section.root, view.colors);
                view.colors = S.theme.current();
                view.tint.set(view.colors.fg_2);
                view.hover.set(.{ .background = view.colors.hover });
                view.count_style.set(S.count());
                view.last_hash = null;
                view.shape_hash = null;
            }
        }.run);
        return self;
    }
    fn entry(self: *View, scope: *ui.Scope, id: []const u8) !*ui.Node {
        const trigger = try scope.createState(EntryTrigger, .{ .view = self, .node = undefined });
        const node = try ui.widgets.Button(.{ .icon_only = true, .icon_asset = ui.icons.get("plug-zap"), .icon_size = @as(f32, 16), .icon_tint = self.tint, .variant = .ghost, .a11y_label = "后台转发列表", .base_style = self.count_style, .hover_style = self.hover, .on_click = self.cx.on(EntryTrigger, trigger, EntryTrigger.open) }).mount(scope, self.cx);
        @import("shell_styles.zig").titleToolbarButton(self.cx.allocator, node);
        trigger.node = node;
        node.meta.ownership.meta.test_id = id;
        node.setDisplay(.none);
        return node;
    }
    const EntryTrigger = struct {
        view: *View,
        node: *ui.Node,
        fn open(self: *@This()) void {
            self.view.show(null, self.node);
        }
    };
    fn anchorRect(raw: *anyopaque) ui.widgets.popover.AnchorRect {
        const self: *View = @ptrCast(@alignCast(raw));
        return .{ .x = self.anchor.x, .y = self.anchor.y, .w = self.anchor.w, .h = self.anchor.h };
    }
    pub fn show(self: *View, asset: ?identity.ConnectionId, anchor: *ui.Node) void {
        self.showAt(asset, anchor.globalRect());
    }
    pub fn showAt(self: *View, asset: ?identity.ConnectionId, anchor: ui.ComputedRect) void {
        self.filter = asset;
        self.last_hash = null;
        self.anchor = anchor;
        self.popover.show.invoke();
        self.cx.requestRedraw();
    }
    /// The asset menu keeps its filtered popup. The workspace renders the same
    /// row projection inline, independent of that filter and its open state.
    pub fn attachInline(self: *View, parent: *ui.Node) !void {
        if (self.inline_section != null) return error.AlreadyAttached;
        const cx = self.cx;
        const root = try ui.box(cx, .{ .width = .fill(), .height = .{ .fit = .{} }, .direction = .column, .gap = 6, .margin = .{ .top = 14 }, .flex_shrink = 0 }, .{});
        try parent.appendChild(cx.allocator, root);
        root.meta.ownership.meta.test_id = "socks.info.background";
        const header = try ui.box(cx, .{ .width = .fill(), .height = .{ .px = 20 }, .direction = .row, .align_items = .center, .gap = 8, .flex_shrink = 0 }, .{});
        try root.appendChild(cx.allocator, header);
        try header.appendChild(cx.allocator, try ui.text(cx, "后台转发", S.text(13, 600, 20, S.theme.current().fg_1)));
        try header.appendChild(cx.allocator, try ui.spacer(cx));
        const count = try ui.text(cx, "", S.text(11, 400, 16, S.theme.current().fg_2));
        count.meta.ownership.meta.test_id = "socks.info.background.total";
        try header.appendChild(cx.allocator, count);
        const list = try ui.widgets.ScrollArea(.{ .direction = .vertical }).mount(self.popover.scope, cx);
        list.container.setStyleInline(cx.allocator, .{ .width = .fill(), .height = .{ .px = 20 }, .min_height = 0, .flex_shrink = 0 });
        list.content.setStyleInline(cx.allocator, .{ .width = .fill(), .direction = .column, .gap = 6, .min_width = 0 });
        try root.appendChild(cx.allocator, list.container);
        self.inline_section = .{ .root = root, .list = list, .count = count };
        self.shape_hash = null;
        self.last_hash = null;
    }

    fn discardRows(self: *View, content: *ui.Node) void {
        while (content.children.items.len != 0) {
            const node = content.children.items[content.children.items.len - 1];
            self.cx.detachChild(content, node);
            self.cx.destroyDetached(node);
        }
    }
    fn addEmpty(self: *View, content: *ui.Node) !void {
        try content.appendChild(self.cx.allocator, try ui.text(self.cx, "没有后台转发", S.text(11.5, 400, 17, S.theme.current().fg_2)));
    }
    pub fn update(self: *View, rows: []const M.Row) !void {
        var shape = std.hash.Wyhash.init(0);
        var counters = std.hash.Wyhash.init(1);
        std.hash.autoHash(&shape, self.filter);
        var shown: usize = 0;
        for (rows) |row| {
            if (self.filter == null or self.filter.? == row.source.id) shown += 1;
            std.hash.autoHash(&shape, row.owner);
            std.hash.autoHash(&shape, row.source);
            std.hash.autoHash(&shape, row.phase);
            std.hash.autoHash(&shape, row.mode);
            std.hash.autoHash(&shape, row.local_port);
            std.hash.autoHash(&shape, row.bind127);
            std.hash.autoHash(&shape, row.stats != null);
            std.hash.autoHash(&shape, if (row.failure) |err| @as(u32, @intFromError(err)) else @as(u32, 0));
            std.hash.autoHash(&shape, row.name.len);
            shape.update(row.name);
            std.hash.autoHash(&counters, row.stats);
        }
        const structural = shape.final();
        std.hash.autoHash(&counters, structural);
        counters.update(std.mem.asBytes(&self.cx.viewport.width));
        counters.update(std.mem.asBytes(&self.cx.viewport.height));
        const next = counters.final();
        if (self.last_hash == next) return;
        var buffer: [128]u8 = undefined;
        if (self.shape_hash != structural) {
            self.shape_hash = null;
            self.last_hash = null;
            self.meters = null;
            for (self.list.content.children.items) |node| self.cx.invalidateReferencesTo(node);
            if (self.inline_section) |section| for (section.list.content.children.items) |node| self.cx.invalidateReferencesTo(node);
            if (self.row_scope) |old| old.dispose();
            self.row_scope = null;
            self.discardRows(self.list.content);
            if (self.inline_section) |section| self.discardRows(section.list.content);
            self.revision = try std.math.add(u64, self.revision, 1);
            const scope = try self.popover.scope.childScope();
            self.row_scope = scope;
            for (rows, 0..) |row, idx| {
                if (self.filter == null or self.filter.? == row.source.id)
                    try self.addRow(scope, row, idx, self.list.content, false);
                if (self.inline_section) |section| try self.addRow(scope, row, idx, section.list.content, true);
            }
            if (shown == 0) try self.addEmpty(self.list.content);
            if (self.inline_section) |section| {
                if (rows.len == 0) try self.addEmpty(section.list.content);
                try section.count.setTextContent(self.cx.allocator, try std.fmt.bufPrint(&buffer, "{d} 条", .{rows.len}));
                const slots: f32 = @floatFromInt(@min(3, rows.len));
                section.list.container.setStyleInline(self.cx.allocator, .{ .height = .{ .px = if (rows.len == 0) 20 else slots * 62 + (slots - 1) * 6 } });
            }
            self.count_text.set(try std.fmt.bufPrint(&buffer, "后台转发 ×{d}", .{rows.len}));
            self.remote_entry.setDisplay(if (rows.len == 0 or self.inline_section != null) .none else .flex);
            self.local_entry.setDisplay(if (rows.len == 0 or self.inline_section != null) .none else .flex);
            self.shape_hash = structural;
        }
        // Changing traffic must not replace the hovered node, scroll position,
        // keyboard focus, or a pointer-down action on a still-current owner.
        var next_meter = self.meters;
        while (next_meter) |meter| : (next_meter = meter.next) try meter.update(self.cx, rows[meter.index]);
        const height = @min(@max(@as(f32, 128), 67 + @as(f32, @floatFromInt(shown)) * 62 + @as(f32, @floatFromInt(shown -| 1)) * 6), @max(0, @min(420, self.cx.viewport.height - 16)));
        self.popover.content.setStyleInline(self.cx.allocator, S.panel(height, self.cx.viewport.width));
        self.last_hash = next;
        self.cx.requestRedraw();
    }

    const Meter = struct {
        next: ?*Meter,
        index: usize,
        count: ?*ui.Node = null,
        hint: ?*ui.Signal([]const u8) = null,
        traffic: *ui.Node,
        fn update(self: *Meter, cx: *ui.Cx, row: M.Row) !void {
            const stats = row.stats orelse return;
            var buf: [112]u8 = undefined;
            if (self.count) |count| {
                try put(cx, count, try std.fmt.bufPrint(&buf, "#{d}", .{stats.connections_active}));
                const hint = try std.fmt.bufPrint(&buf, "{d} 个活跃 TCP 连接", .{stats.connections_active});
                if (!std.mem.eql(u8, hint, self.hint.?.peek())) self.hint.?.set(hint);
            }
            var down: [32]u8 = undefined;
            var up: [32]u8 = undefined;
            try put(cx, self.traffic, try std.fmt.bufPrint(&buf, "↓ {s}    ↑ {s}", .{ try ForwardStyle.formatBytes(&down, stats.bytes_down), try ForwardStyle.formatBytes(&up, stats.bytes_up) }));
        }
        fn put(cx: *ui.Cx, text: *ui.Node, content: []const u8) !void {
            if (!std.mem.eql(u8, text.getText().?.content, content)) try text.setTextContent(cx.allocator, content);
        }
    };
    fn addRow(self: *View, scope: *ui.Scope, row: M.Row, idx: usize, parent: *ui.Node, embedded: bool) !void {
        const cx = self.cx;
        const colors = S.theme.current();
        const node = try ui.box(cx, S.row(), .{});
        try parent.appendChild(cx.allocator, node);
        node.meta.ownership.meta.test_id = "socks.background.row";
        const top = try ui.box(cx, .{ .width = .fill(), .height = .{ .px = 22 }, .direction = .row, .align_items = .center, .gap = 6, .min_width = 0, .flex_shrink = 0 }, .{});
        try node.appendChild(cx.allocator, top);
        const name = try ui.text(cx, row.name, S.text(12, 550, 18, colors.fg_1));
        name.setStyleInline(cx.allocator, .{ .min_width = 0, .flex_shrink = 1 });
        try top.appendChild(cx.allocator, name);
        const mode = try ui.text(cx, switch (row.mode) {
            .socks5 => "SOCKS5 · 动态目标",
            .local => "本地 L",
            .remote => "远端 R",
        }, S.text(11, 400, 16, colors.fg_2));
        mode.setStyleInline(cx.allocator, .{ .min_width = 0, .flex_shrink = 1 });
        try top.appendChild(cx.allocator, mode);
        try top.appendChild(cx.allocator, try ui.spacer(cx));
        const state = try ui.text(cx, M.phaseLabel(row.phase), S.text(11, 550, 16, S.ink(row.phase)));
        state.meta.ownership.meta.test_id = "socks.background.state";
        state.setStyleInline(cx.allocator, .{ .flex_shrink = 0 });
        try top.appendChild(cx.allocator, state);
        const bottom = try ui.box(cx, .{ .width = .fill(), .height = .{ .px = 25 }, .direction = .row, .align_items = .center, .gap = 6, .min_width = 0, .flex_shrink = 0 }, .{});
        try node.appendChild(cx.allocator, bottom);
        var buffer: [112]u8 = undefined;
        const endpoint: []const u8 = if (row.local_port != null and row.bind127 != null)
            try std.fmt.bufPrint(&buffer, "{s}:{d}", .{ if (row.bind127.?) @as([]const u8, "127.0.0.1") else "0.0.0.0", row.local_port.? })
        else if (row.failure) |err| @errorName(err) else "—";
        const address = try ui.text(cx, endpoint, S.text(11.5, 500, 18, colors.fg_1));
        address.meta.ownership.meta.test_id = "socks.background.endpoint";
        address.setStyleInline(cx.allocator, .{ .min_width = 0, .flex_shrink = 1 });
        try bottom.appendChild(cx.allocator, address);
        const traffic = try ui.text(cx, "", S.text(11, 400, 16, colors.fg_2));
        traffic.meta.ownership.meta.test_id = "socks.background.traffic";
        traffic.setStyleInline(cx.allocator, .{ .min_width = 0, .flex_shrink = 1 });
        try bottom.appendChild(cx.allocator, traffic);
        const meter = try scope.createState(Meter, .{ .next = self.meters, .index = idx, .traffic = traffic });
        self.meters = meter;
        if (row.phase == .listening and row.stats != null) {
            const hint = try scope.createText("", .{});
            const tip = try ui.widgets.Tooltip(.{ .text = hint, .background = colors.overlay, .text_color = colors.fg_1 }).mount(scope, cx);
            const count = try ui.text(cx, "", S.text(11, 400, 16, colors.fg_2));
            count.meta.ownership.meta.test_id = "socks.background.connections";
            tip.content.meta.ownership.meta.test_id = "socks.background.connections.hint";
            try tip.trigger.appendChild(cx.allocator, count);
            tip.wrapper.setStyleInline(cx.allocator, .{ .flex_shrink = 0 });
            try top.appendChild(cx.allocator, tip.wrapper);
            meter.count = count;
            meter.hint = hint;
        }
        try bottom.appendChild(cx.allocator, try ui.spacer(cx));
        for ([_]Action{ .open_terminal, .reconnect, .stop }, [_][]const u8{ "terminal", "refresh-cw", "square" }, [_][]const u8{ "打开终端", "重新连接", "停止后台转发" }) |action, icon, label| {
            if (action == .reconnect and row.phase != .paused and row.phase != .failed) continue;
            if (action == .stop and row.phase == .closing) continue;
            const capture = try scope.createState(RowAction, .{ .view = self, .owner = row.owner, .revision = self.revision, .action = action, .embedded = embedded });
            var appearance = S.action(24);
            appearance.background = S.theme.popupAction();
            const button = try ui.widgets.Button(.{ .variant = .ghost, .icon_only = true, .icon_asset = ui.icons.get(icon), .icon_size = @as(f32, 14), .icon_tint = if (action == .stop) colors.danger_ink else colors.fg_2, .a11y_label = label, .base_style = appearance, .hover_style = self.hover, .on_click = cx.on(RowAction, capture, RowAction.run) }).mount(scope, cx);
            button.meta.ownership.meta.test_id = switch (action) {
                .open_terminal => "socks.background.open_terminal",
                .reconnect => "socks.background.reconnect",
                .stop => "socks.background.stop",
            };
            try bottom.appendChild(cx.allocator, try @import("connection_details_view.zig").iconTooltip(cx, scope, button, label));
        }
    }
    const RowAction = struct {
        view: *View,
        owner: identity.SessionHandle,
        revision: u64,
        action: Action,
        embedded: bool,
        fn run(self: *@This()) void {
            if (self.view.revision != self.revision) return;
            self.view.hooks.action(self.view.hooks.context, self.owner, self.action);
            if (self.action == .open_terminal) {
                if (self.embedded) {
                    if (self.view.inline_closed) |on_close| on_close.close(on_close.context);
                } else self.view.popover.close.invoke();
            }
        }
    };
};
