const std = @import("std");
const ui = @import("ui");
const V = @import("ui/sidebar_view.zig");
const T = V.styles.theme;
test "sidebar native declarations" {
    std.testing.refAllDecls(V);
}

test "sidebar informational hover does not consume Escape before an open command menu" {
    const h = try H.init();
    defer h.deinit();
    const anchor = try ui.box(h.cx, .{ .width = .{ .px = 24 }, .height = .{ .px = 24 } }, .{});
    try h.root.appendChild(h.cx.allocator, anchor);
    const help = try ui.widgets.Button(.{ .label = "Help" }).mount(h.scope, h.cx);
    const hint = try V.hint(h.cx, h.scope, help, "展开侧栏", .right);
    try h.root.appendChild(h.cx.allocator, hint);
    var callbacks: usize = 0;
    const Callback = struct {
        fn run(raw: *anyopaque) void {
            @as(*usize, @ptrCast(@alignCast(raw))).* += 1;
        }
    };
    const menu = try @import("ui/session_menu.zig").View.mount(h.cx, h.scope, .{ .context = &callbacks, .quick = Callback.run, .new_profile = Callback.run, .new_web = Callback.run });
    try h.root.appendChild(h.cx.allocator, menu.root);
    try menu.show(anchor);
    h.frames();
    hint.behavior.events.on_hover.?.invoke();
    for (0..5) |_| h.frames();
    // The real tooltip layer must exist above the menu for this regression.
    var tooltip_visible = false;
    for (h.cx.overlay_stack.layers) |entry| if (entry) |layer| {
        if (!layer.suspended and layer.state == .visible and layer.config.tier == .tooltip) tooltip_visible = true;
    };
    try std.testing.expect(tooltip_visible);
    h.cx.handleKeyDown(.escape, .{});
    h.frames();
    try std.testing.expect(!menu.isOpen());
    try std.testing.expectEqual(@as(usize, 0), callbacks);
}

test "background SOCKS sidebar badge preserves row geometry route actions and connection dot" {
    T.select(.dark);
    defer T.select(.dark);
    const h = try H.init();
    defer h.deinit();
    const column = try ui.box(h.cx, .{ .width = .{ .px = 208 }, .height = .fill(), .direction = .column }, .{});
    try h.root.appendChild(h.cx.allocator, column);
    var capture: Capture = .{};
    const row = try V.HostRow.mount(h.cx, h.scope, .{ .name = "后台主机", .detail = "root@192.0.2.1:22", .route = "本机 → 跳板 → 后台主机", .hops = 1, .online = false, .forward = .{ .port = 65535, .phase = .listening } }, .{ .context = &capture, .select = Capture.select, .connect = Capture.connect, .menu = Capture.menu, .action = Capture.hostAction });
    try column.appendChild(h.cx.allocator, row.node);
    h.frames();
    try std.testing.expectEqual(@as(f32, 36), row.node.globalRect().h);
    try std.testing.expectApproxEqAbs(V.styles.forward_badge_width + V.styles.host_action_gap + row.route.globalRect().w, row.trailing.globalRect().w, 0.1);
    try std.testing.expectEqualStrings(":65535后台", row.forward_label.getText().?.content);
    try std.testing.expect(row.forward.style.display == .flex and row.route.style.display == .flex);
    const route_with_forward = row.route.globalRect();
    const name_with_forward = row.name.globalRect();
    try std.testing.expect(row.forward.globalRect().x + row.forward.globalRect().w <= route_with_forward.x);
    try std.testing.expect(ui.Color.eql(T.current().fg_2, row.dot.getIcon().?.tint));
    try std.testing.expect(ui.Color.eql(T.current().ok_ink, row.forward_label.getText().?.color));
    row.setMenuOpen(true);
    h.frames();
    try std.testing.expect(row.forward.style.display == .none and row.actions.style.display == .flex);
    try std.testing.expectApproxEqAbs(route_with_forward.x, row.route.globalRect().x, 0.1);
    try std.testing.expectApproxEqAbs(name_with_forward.w + V.styles.forward_badge_width - V.styles.host_connect_size, row.name.globalRect().w, 0.1);
    row.setMenuOpen(false);
    h.frames();
    try std.testing.expect(row.forward.style.display == .flex and row.actions.style.display == .none);
    T.select(.light);
    h.cx.setTheme(T.widgetTheme(.light));
    h.frames();
    try std.testing.expect(ui.Color.eql(T.current().fg_2, row.dot.getIcon().?.tint));
    try std.testing.expect(ui.Color.eql(T.current().ok_ink, row.forward_label.getText().?.color));
    row.setForwardBadge(.{ .port = 65535, .phase = .paused });
    try std.testing.expectEqualStrings("已暂停", row.node.behavior.interaction.a11y.?.description.?);
    try std.testing.expect(ui.Color.eql(T.current().warn_ink, row.forward_label.getText().?.color));
    row.setForwardBadge(.{ .port = null, .phase = .connecting });
    try std.testing.expectEqualStrings("连接中", row.forward_label.getText().?.content);
    row.setForwardBadge(null);
    h.frames();
    try std.testing.expect(row.forward.style.display == .none and row.route.style.display == .flex);
    try std.testing.expectApproxEqAbs(route_with_forward.x, row.route.globalRect().x, 0.1);
    try std.testing.expectApproxEqAbs(row.route.globalRect().w, row.trailing.globalRect().w, 0.1);
}
const Capture = struct {
    selected: usize = 0,
    connected: usize = 0,
    menus: usize = 0,
    edited: usize = 0,
    copied: usize = 0,
    collapsed: usize = 0,
    new_host: usize = 0,
    new_group: usize = 0,
    group: ?V.GroupRef = null,
    group_action: ?V.GroupAction = null,
    rail_owner: ?@import("host/identity.zig").AssetOwner = null,
    rail_action: ?@import("ui/sidebar_collapsed_view.zig").HostAction = null,
    chains: usize = 0,
    fn chain(raw: *anyopaque) void {
        const self: *@This() = @ptrCast(@alignCast(raw));
        self.chains += 1;
    }
    fn hostAction(raw: *anyopaque, value: V.HostAction) void {
        const self: *Capture = @ptrCast(@alignCast(raw));
        if (value == .copy) self.copied += 1 else self.edited += 1;
    }
    fn railAction(raw: *anyopaque, owner: @import("host/identity.zig").AssetOwner, action: @import("ui/sidebar_collapsed_view.zig").HostAction) void {
        const self: *@This() = @ptrCast(@alignCast(raw));
        self.rail_owner = owner;
        self.rail_action = action;
    }
    fn select(raw: *anyopaque) void {
        const s: *@This() = @ptrCast(@alignCast(raw));
        s.selected += 1;
    }
    fn connect(raw: *anyopaque) void {
        const s: *@This() = @ptrCast(@alignCast(raw));
        s.connected += 1;
    }
    fn menu(raw: *anyopaque, _: *ui.Node) void {
        const s: *@This() = @ptrCast(@alignCast(raw));
        s.menus += 1;
    }
    fn collapse(raw: *anyopaque) void {
        const s: *@This() = @ptrCast(@alignCast(raw));
        s.collapsed += 1;
    }
    fn search(_: *@This(), _: []const u8) void {}
    fn newHost(raw: ?*anyopaque, group: ?V.GroupRef) void {
        const s: *@This() = @ptrCast(@alignCast(raw.?));
        s.new_host += 1;
        s.group = group;
    }
    fn newGroup(raw: ?*anyopaque) void {
        const s: *@This() = @ptrCast(@alignCast(raw.?));
        s.new_group += 1;
    }
    fn groupAction(raw: ?*anyopaque, group: V.GroupRef, action: V.GroupAction) void {
        const s: *@This() = @ptrCast(@alignCast(raw.?));
        s.group = group;
        s.group_action = action;
    }
    fn bridge(s: *@This()) V.Bridge {
        return .{ .context = s, .new_host = newHost, .new_group = newGroup, .group_action = groupAction };
    }
};
const H = struct {
    cx: *ui.Cx,
    scope: *ui.Scope,
    root: *ui.Node,
    fn init() !H {
        const cx = try ui.Cx.init(std.testing.allocator, std.testing.io);
        errdefer cx.deinit();
        cx.setViewport(900, 794);
        cx.bindFrameClock();
        cx.svg_textures.setLoader(.{ .load_fn = struct {
            fn load(_: ?*anyopaque, _: []const u8, _: u32, _: u32) !u32 {
                return 9001;
            }
        }.load });
        cx.setTheme(T.widgetTheme(T.currentName()));
        const scope = try ui.Scope.init(std.testing.allocator, null, cx.owner);
        const root = try ui.box(cx, .{ .width = .fill(), .height = .fill(), .direction = .row }, .{});
        cx.root = root;
        return .{ .cx = cx, .scope = scope, .root = root };
    }
    fn deinit(s: H) void {
        s.scope.dispose();
        s.cx.deinit();
    }
    fn frames(s: H) void {
        for (0..12) |_| {
            s.cx.frame_count += 1;
            s.cx.frame_time_ms += 16;
            s.cx.bindFrameClock();
            _ = s.cx.render();
        }
    }
    fn click(s: H, node: *ui.Node) void {
        const r = node.globalRect();
        s.cx.handleMouseDown(r.x + r.w / 2, r.y + r.h / 2, .{});
        s.cx.handleMouseUp(r.x + r.w / 2, r.y + r.h / 2);
        s.frames();
    }
};
fn find(node: *ui.Node, id: []const u8) ?*ui.Node {
    if (node.meta.ownership.meta.test_id) |value| if (std.mem.eql(u8, value, id)) return node;
    for (node.children.items) |child| if (find(child, id)) |result| return result;
    return null;
}
fn firstIcon(node: *ui.Node) ?*ui.Node {
    if (node.getIcon() != null) return node;
    for (node.children.items) |child| if (firstIcon(child)) |result| return result;
    return null;
}
fn firstText(node: *ui.Node) ?*ui.Node {
    if (node.getText() != null) return node;
    for (node.children.items) |child| if (firstText(child)) |result| return result;
    return null;
}
test "sidebar native chrome gives host names the unused width and keeps route badges right aligned" {
    var c: Capture = .{};
    const h = try H.init();
    defer h.deinit();
    const list = try ui.box(h.cx, V.styles.list(), .{});
    const v = try V.View.mount(h.cx, h.scope, list, .{ .context = &c, .collapse = Capture.collapse, .search_changed = h.cx.on(Capture, &c, Capture.search), .bridge = c.bridge() });
    v.empty.setDisplay(.none);
    try h.root.appendChild(h.cx.allocator, v.root);
    const row = try V.HostRow.mount(h.cx, h.scope, .{ .name = "prod-eu-central-db-master-01", .detail = "root@10.0.0.1:22", .route = "本机 → 跳板 → 目标", .hops = 2, .online = true }, .{ .context = &c, .select = Capture.select, .connect = Capture.connect, .menu = Capture.menu, .action = Capture.hostAction });
    try list.appendChild(h.cx.allocator, row.node);
    h.frames();
    try std.testing.expect(row.route.style.display == .flex);
    try std.testing.expectApproxEqAbs(@as(f32, 238), v.root.globalRect().w, 0.1);
    try std.testing.expectApproxEqAbs(@as(f32, 24), v.search_box.globalRect().h, 0.1);
    try std.testing.expectApproxEqAbs(@as(f32, 66), v.search_box.globalRect().y, 0.1);
    try std.testing.expectApproxEqAbs(@as(f32, 36), row.node.globalRect().h, 0.1);
    const before = row.name.globalRect().w;
    const route_x = row.route.globalRect().x;
    try std.testing.expect(find(row.node, "sidebar.host.protocol") == null);
    const rect = row.node.globalRect();
    try std.testing.expectApproxEqAbs(rect.x + rect.w - V.styles.content().padding.?.right, route_x + row.route.globalRect().w, 0.1);
    h.cx.handleMouseMove(rect.x + 20, rect.y + 12);
    h.frames();
    try std.testing.expectEqual(@as(@TypeOf(row.route.style.display), .flex), row.route.style.display);
    try std.testing.expectEqual(T.current().overlay, row.actions.getBackground());
    try std.testing.expect(find(row.node, "sidebar.host.protocol") == null);
    try std.testing.expectApproxEqAbs(before - V.styles.host_connect_size - V.styles.host_action_gap, row.name.globalRect().w, 0.1);
    try std.testing.expectApproxEqAbs(route_x, row.route.globalRect().x, 0.1);
    h.click(find(row.node, "sidebar.host.connect").?);
    try std.testing.expectEqual(@as(usize, 1), c.connected);
    try std.testing.expect(find(row.node, "sidebar.host.edit") == null);
    try std.testing.expect(find(row.node, "sidebar.host.copy") == null);
    try std.testing.expectEqual(@as(usize, 0), c.selected);
    try std.testing.expectEqual(@as(usize, 1), c.connected);
    const collapse = find(v.root, "sidebar.collapse").?;
    try std.testing.expectApproxEqAbs(@as(f32, 6), collapse.globalRect().y, 0.1);
    h.click(collapse);
    try std.testing.expectEqual(@as(usize, 1), c.collapsed);
    h.click(find(v.root, "sidebar.footer.new").?);
    try std.testing.expectEqual(@as(usize, 1), c.new_host);
}
test "sidebar host route status never activates the row connection" {
    const h = try H.init();
    defer h.deinit();
    const column = try ui.box(h.cx, .{ .width = .{ .px = 212 }, .height = .fill(), .direction = .column }, .{});
    try h.root.appendChild(h.cx.allocator, column);
    var capture: Capture = .{};
    const row = try V.HostRow.mount(h.cx, h.scope, .{ .name = "ScaleX40-AI01", .detail = "root@127.0.0.1:1", .route = "本机 → 主机", .hops = 0, .online = false }, .{ .context = &capture, .select = Capture.select, .connect = Capture.connect, .menu = Capture.menu });
    try column.appendChild(h.cx.allocator, row.node);
    h.frames();
    try std.testing.expect(!row.route.isDisplayedInTree());
    try std.testing.expect(!row.actions.isDisplayedInTree());
    const name_width = row.name.globalRect().w;
    const r = row.node.globalRect();
    try std.testing.expectApproxEqAbs(r.x + r.w - V.styles.content().padding.?.right, row.name.globalRect().x + name_width, 0.1);
    h.cx.handleMouseMove(r.x + 20, r.y + r.h / 2);
    h.frames();
    try std.testing.expect(row.route.style.display == .flex);
    try std.testing.expect(name_width > row.name.globalRect().w);
    const route = row.route.globalRect();
    const count = find(row.node, "sidebar.host.hops").?.globalRect();
    const action = row.actions.globalRect();
    for ([_]f32{ route.x + 4, count.x + count.w / 2, (action.x + action.w + route.x) / 2 }) |x| {
        h.cx.handleMouseDown(x, route.y + route.h / 2, .{});
        h.cx.handleMouseUp(x, route.y + route.h / 2);
        h.frames();
        try std.testing.expectEqual(@as(usize, 0), capture.selected);
        try std.testing.expectEqual(@as(usize, 0), capture.connected);
    }
    h.click(find(row.node, "sidebar.host.connect").?);
    try std.testing.expectEqual(@as(usize, 1), capture.connected);
    try std.testing.expectEqual(@as(usize, 0), capture.selected);
    h.click(row.name);
    try std.testing.expectEqual(@as(usize, 1), capture.selected);
    try std.testing.expectEqual(@as(usize, 1), capture.connected);
    h.cx.setFocus(null);
    h.cx.handleMouseMove(800, 700);
    h.frames();
    try std.testing.expect(!row.route.isDisplayedInTree());
    row.setForwardBadge(.{ .port = 8080, .phase = .listening });
    h.frames();
    try std.testing.expect(row.forward.isDisplayedInTree() and !row.route.isDisplayedInTree());
    row.setForwardBadge(null);
    h.frames();
    try std.testing.expect(!row.forward.isDisplayedInTree() and !row.route.isDisplayedInTree());
}

test "sidebar host route marker names the chain and its hop count" {
    const h = try H.init();
    defer h.deinit();
    const column = try ui.box(h.cx, .{ .width = .{ .px = 212 }, .height = .fill(), .direction = .column }, .{});
    try h.root.appendChild(h.cx.allocator, column);
    var capture: Capture = .{};
    const callbacks: V.HostCallbacks = .{ .context = &capture, .select = Capture.select, .connect = Capture.connect, .menu = Capture.menu, .action = Capture.hostAction, .chain = Capture.chain };
    const routed = try V.HostRow.mount(h.cx, h.scope, .{ .name = "ScaleX40-AI01", .detail = "root@192.0.2.1:22", .route = "本机 → 跳板 → ScaleX40-AI01", .hops = 1, .online = true }, callbacks);
    try column.appendChild(h.cx.allocator, routed.node);
    const direct = try V.HostRow.mount(h.cx, h.scope, .{ .name = "直连主机", .detail = "root@192.0.2.2:22", .route = "本机 → 直连主机", .hops = 0, .online = false }, callbacks);
    try column.appendChild(h.cx.allocator, direct.node);
    h.frames();
    try std.testing.expectEqualStrings("连接链路 · 经 1 台跳板\n本机 → 跳板 → ScaleX40-AI01\n点击查看连接链路", routed.route.behavior.interaction.a11y.?.description.?);
    try std.testing.expectEqualStrings("连接链路 · 直连\n本机 → 直连主机\n点击查看连接链路", direct.route.behavior.interaction.a11y.?.description.?);
    try std.testing.expect(routed.route.behavior.interaction.a11y.?.role == .button);
}

test "sidebar host route marker hints on hover and opens the chain without selecting" {
    const h = try H.init();
    defer h.deinit();
    const column = try ui.box(h.cx, .{ .width = .{ .px = 212 }, .height = .fill(), .direction = .column }, .{});
    try h.root.appendChild(h.cx.allocator, column);
    var capture: Capture = .{};
    const row = try V.HostRow.mount(h.cx, h.scope, .{ .name = "ScaleX40-AI01", .detail = "root@192.0.2.1:22", .route = "本机 → 跳板 → ScaleX40-AI01", .hops = 1, .online = true }, .{ .context = &capture, .select = Capture.select, .connect = Capture.connect, .menu = Capture.menu, .action = Capture.hostAction, .chain = Capture.chain });
    try column.appendChild(h.cx.allocator, row.node);
    h.frames();
    const route = row.route.globalRect();
    h.cx.handleMouseMove(route.x + route.w / 2, route.y + route.h / 2);
    for (0..40) |_| h.frames();
    var tooltip_visible = false;
    for (h.cx.overlay_stack.layers) |entry| if (entry) |layer| {
        if (!layer.suspended and layer.state == .visible and layer.config.tier == .tooltip) tooltip_visible = true;
    };
    try std.testing.expect(tooltip_visible);
    const label = firstText(row.chain_hint.?.content) orelse return error.MissingChainHint;
    try std.testing.expect(std.mem.indexOf(u8, label.getText().?.content, "点击查看连接链路") != null);
    h.click(row.route);
    try std.testing.expectEqual(@as(usize, 1), capture.chains);
    try std.testing.expectEqual(@as(usize, 0), capture.selected);
    try std.testing.expectEqual(@as(usize, 0), capture.connected);
    try std.testing.expect(row.route.behavior.interaction.focusable);
    h.cx.setFocus(row.route);
    h.cx.handleKeyDown(.@"return", .{});
    h.cx.handleKeyDown(.space, .{});
    h.frames();
    try std.testing.expectEqual(@as(usize, 3), capture.chains);
    try std.testing.expectEqual(@as(usize, 0), capture.selected);
    try std.testing.expectEqual(@as(usize, 0), capture.connected);
}

test "sidebar chain retains long UTF8 paths and describes SFTP capability" {
    const h = try H.init();
    defer h.deinit();
    const route = "本机 → 第一台生产环境入口跳板服务器 → 第二台生产环境网络隔离跳板服务器 → 第三台生产环境数据库入口跳板服务器 → 第四台数据库安全隔离跳板服务器 → 最终数据库服务器";
    try std.testing.expect(route.len > 192);
    var capture: Capture = .{};
    const row = try V.HostRow.mount(h.cx, h.scope, .{ .name = "数据库", .detail = "ops@db", .route = route, .hops = 3, .online = false }, .{ .context = &capture, .select = Capture.select, .connect = Capture.connect, .menu = Capture.menu });
    try h.root.appendChild(h.cx.allocator, row.node);
    h.frames();
    const description = row.route.behavior.interaction.a11y.?.description.?;
    try std.testing.expect(std.mem.indexOf(u8, description, route) != null);
    try std.testing.expect(std.mem.endsWith(u8, description, "点击查看连接链路"));
    const file = try V.HostRow.mount(h.cx, h.scope, .{ .protocol = "sftp", .name = "文件", .detail = "ops@files", .route = "本机 → 文件", .hops = 0, .online = true }, .{ .context = &capture, .select = Capture.select, .connect = Capture.connect, .menu = Capture.menu });
    try h.root.appendChild(h.cx.allocator, file.node);
    h.frames();
    try std.testing.expect(std.mem.endsWith(u8, file.route.behavior.interaction.a11y.?.description.?, "SFTP 暂不支持查看实时连接链路"));
}

test "sidebar host hover exposes only connect without activating the row" {
    const h = try H.init();
    defer h.deinit();
    const column = try ui.box(h.cx, .{ .width = .{ .px = 212 }, .height = .fill(), .direction = .column }, .{});
    try h.root.appendChild(h.cx.allocator, column);
    var capture: Capture = .{};
    const row = try V.HostRow.mount(h.cx, h.scope, .{ .name = "ScaleX40-AI01", .detail = "root@192.0.2.1:22", .route = "本机 → 跳板 → ScaleX40-AI01", .hops = 1, .online = false }, .{ .context = &capture, .select = Capture.select, .connect = Capture.connect, .menu = Capture.menu, .action = Capture.hostAction });
    try column.appendChild(h.cx.allocator, row.node);
    h.frames();
    try std.testing.expect(find(row.node, "sidebar.host.protocol") == null);
    const rect = row.node.globalRect();
    h.cx.handleMouseMove(rect.x + 10, rect.y + 12);
    h.frames();
    try std.testing.expect(row.hot);
    try std.testing.expect(row.actions.style.display == .flex);
    try std.testing.expect(find(row.node, "sidebar.host.protocol") == null);
    h.cx.handleMouseMove(800, 700);
    h.frames();
    try std.testing.expect(find(row.node, "sidebar.host.protocol") == null);
    h.cx.handleMouseMove(rect.x + 10, rect.y + 12);
    h.frames();
    for ([_][]const u8{"sidebar.host.connect"}) |id| {
        const button = find(row.node, id) orelse return error.MissingHostShortcut;
        try std.testing.expect(button.globalRect().w >= 24);
        h.click(button);
    }
    try std.testing.expectEqual(@as(usize, 1), capture.connected);
    try std.testing.expectEqual(@as(usize, 0), capture.copied);
    try std.testing.expectEqual(@as(usize, 0), capture.edited);
    try std.testing.expectEqual(@as(usize, 0), capture.menus);
    try std.testing.expectEqual(@as(usize, 0), capture.selected);
    try std.testing.expect(find(row.node, "sidebar.host.copy") == null);
    try std.testing.expect(find(row.node, "sidebar.host.edit") == null);
    h.cx.setFocus(find(row.node, "sidebar.host.connect").?);
    h.cx.handleKeyDown(.@"return", .{});
    h.frames();
    try std.testing.expectEqual(@as(usize, 2), capture.connected);
    try std.testing.expectEqual(@as(usize, 0), capture.selected);
}
test "sidebar native group menu freezes revision and never changes persistent collapse before commit" {
    var c: Capture = .{};
    const h = try H.init();
    defer h.deinit();
    const reference: V.GroupRef = .{ .id = @fromBackingInt(42), .revision = 7 };
    const row = try V.GroupRow.mount(h.cx, h.scope, .{ .reference = reference, .name = "PRODUCTION", .count = 2, .collapsed = false }, c.bridge());
    row.root.setStyleInline(h.cx.allocator, .{ .width = .{ .px = 208 } });
    try h.root.appendChild(h.cx.allocator, row.root);
    h.frames();
    try std.testing.expectApproxEqAbs(@as(f32, 28), row.header.globalRect().h, 0.1);
    h.click(row.header);
    try std.testing.expectEqual(reference, c.group.?);
    try std.testing.expectEqual(V.GroupAction.toggle_collapsed, c.group_action.?);
    try std.testing.expect(!row.collapsed);
    try std.testing.expectEqual(@as(@TypeOf(row.members.style.display), .flex), row.members.style.display);
    row.menu.show.invoke();
    h.frames();
    try std.testing.expectApproxEqAbs(@as(f32, 258), row.menu.content.globalRect().w, 0.1);
    try std.testing.expectApproxEqAbs(@as(f32, 199), row.menu.content.globalRect().h, 0.1);
    for (row.menu.content.children.items[1..]) |item| {
        const icon = item.children.items[0].globalRect();
        const label = item.children.items[1].globalRect();
        try std.testing.expectApproxEqAbs(item.globalRect().x + 6, icon.x, 0.1);
        try std.testing.expectApproxEqAbs(icon.x + 20, label.x, 0.1);
    }
}
test "sidebar group hover actions remain inside the header" {
    const h = try H.init();
    defer h.deinit();
    var capture: Capture = .{};
    const reference: V.GroupRef = .{ .id = @fromBackingInt(42), .revision = 7 };
    const row = try V.GroupRow.mount(h.cx, h.scope, .{ .reference = reference, .name = "Long group name for a narrow sidebar", .count = 2, .collapsed = false }, capture.bridge());
    try h.root.appendChild(h.cx.allocator, row.root);
    for ([_]f32{ 200, 218, 434 }) |width| {
        row.root.setStyleInline(h.cx.allocator, .{ .width = .{ .px = width } });
        h.frames();
        const header = row.header.globalRect();
        h.cx.handleMouseMove(header.x + 12, header.y + header.h / 2);
        h.frames();
        const plus = find(row.header, "sidebar.group.new").?.globalRect();
        const more = find(row.header, "sidebar.group.more").?.globalRect();
        try std.testing.expectApproxEqAbs(@as(f32, 24), plus.w, 0.1);
        try std.testing.expectApproxEqAbs(@as(f32, 24), more.w, 0.1);
        try std.testing.expect(plus.x >= header.x and plus.x + plus.w <= more.x);
        try std.testing.expectApproxEqAbs(header.x + header.w - 5, more.x + more.w, 0.1);
    }
    h.click(find(row.header, "sidebar.group.more").?);
    try std.testing.expect(row.menu.open.?.peek());
    try std.testing.expect(capture.group_action == null);
    row.menu.close.invoke();
    h.frames();
    h.click(find(row.header, "sidebar.group.new").?);
    try std.testing.expectEqual(@as(usize, 1), capture.new_host);
    try std.testing.expectEqual(reference, capture.group.?);
    try std.testing.expect(capture.group_action == null);
    h.cx.setFocus(find(row.header, "sidebar.group.more").?);
    h.cx.handleKeyDown(.@"return", .{});
    h.frames();
    try std.testing.expect(row.menu.open.?.peek());
    try std.testing.expect(capture.group_action == null);
    row.menu.close.invoke();
    h.frames();
    h.click(row.header);
    try std.testing.expectEqual(V.GroupAction.toggle_collapsed, capture.group_action.?);
}
test "sidebar native group count renders digits without ellipsis at prototype badge geometry" {
    const h = try H.init();
    defer h.deinit();
    for ([_]usize{ 1, 12, 999 }) |count| {
        const row = try V.GroupRow.mount(h.cx, h.scope, .{ .reference = null, .name = "GROUP", .count = count, .collapsed = false }, .{});
        row.root.setStyleInline(h.cx.allocator, .{ .width = .{ .px = 208 } });
        try h.root.appendChild(h.cx.allocator, row.root);
        h.frames();
        const badge = find(row.header, "sidebar.group.badge").?;
        const label = find(badge, "sidebar.group.count").?;
        try std.testing.expectApproxEqAbs(@as(f32, 32), badge.globalRect().w, 0.1);
        try std.testing.expectApproxEqAbs(@as(f32, 14), badge.globalRect().h, 0.1);
        try std.testing.expect(label.globalRect().w >= 6);
        try std.testing.expectApproxEqAbs(@as(f32, 14), label.globalRect().h, 0.1);
        try std.testing.expectApproxEqAbs(@as(f32, 0), label.globalRect().x - badge.globalRect().x, 0.1);
        var buffer: [24]u8 = undefined;
        const expected = try std.fmt.bufPrint(&buffer, "{d}", .{count});
        var rendered_digits = false;
        for (h.cx.display_list.items.items) |item| switch (item) {
            .text_run => |run| if (run.header.node_id == label.id) {
                try std.testing.expect(!std.mem.eql(u8, run.content, "\xe2\x80\xa6"));
                if (std.mem.eql(u8, run.content, expected)) rendered_digits = true;
            },
            else => {},
        };
        try std.testing.expect(rendered_digits);
    }
}
test "sidebar native late callbacks reenable new group without remount" {
    var c: Capture = .{};
    const h = try H.init();
    defer h.deinit();
    const list = try ui.box(h.cx, V.styles.list(), .{});
    const v = try V.View.mount(h.cx, h.scope, list, .{ .context = &c, .collapse = Capture.collapse, .search_changed = h.cx.on(Capture, &c, Capture.search), .bridge = .{} });
    v.empty.setDisplay(.none);
    try h.root.appendChild(h.cx.allocator, v.root);
    try std.testing.expect(v.group_disabled.peek());
    v.setBridge(c.bridge());
    try std.testing.expect(!v.group_disabled.peek());
    h.frames();
    v.new_menu.show.invoke();
    h.frames();
    for ([_][]const u8{ "sidebar.new.host", "sidebar.new.group" }) |id| {
        const button = find(v.new_menu.content, id).?;
        const row = button.globalRect();
        const icon = firstIcon(button).?.globalRect();
        const label = firstText(button).?.globalRect();
        try std.testing.expectApproxEqAbs(row.x + 6, icon.x, 0.1);
        try std.testing.expect(label.x >= icon.x + icon.w);
        try std.testing.expect(label.x + label.w <= row.x + row.w);
    }
    h.cx.handleKeyDown(.down, .{});
    h.frames();
    try std.testing.expect(h.cx.isFocused(find(v.new_menu.content, "sidebar.new.group").?));
    h.cx.handleKeyDown(.@"return", .{});
    h.frames();
    try std.testing.expectEqual(@as(usize, 1), c.new_group);
}
test "sidebar native retained chrome and rows follow three themes and global material" {
    const saved_parameters = T.materialParameters();
    defer _ = T.setMaterialParameters(saved_parameters.transparency, saved_parameters.blur);
    _ = T.setMaterialParameters(75, 24);
    const original = T.currentName();
    const material = T.materialVisible();
    defer {
        T.select(original);
        _ = T.setMaterialVisible(material);
    }
    T.select(.dark);
    _ = T.setMaterialVisible(false);
    const h = try H.init();
    defer h.deinit();
    var capture: Capture = .{};
    const list = try ui.box(h.cx, V.styles.list(), .{});
    const v = try V.View.mount(h.cx, h.scope, list, .{ .context = &capture, .collapse = Capture.collapse, .search_changed = h.cx.on(Capture, &capture, Capture.search), .bridge = capture.bridge() });
    v.empty.setDisplay(.none);
    try h.root.appendChild(h.cx.allocator, v.root);
    const row = try V.HostRow.mount(h.cx, h.scope, .{ .name = "主机", .detail = "ops@10.0.0.1:22", .route = "本机 → 主机", .hops = 0, .online = false, .selected = true }, .{ .context = &capture, .select = Capture.select, .connect = Capture.connect, .menu = Capture.menu, .action = Capture.hostAction });
    try list.appendChild(h.cx.allocator, row.node);
    try std.testing.expectEqualStrings("0", find(row.node, "sidebar.host.hops").?.getText().?.content);
    try std.testing.expect(firstIcon(row.route) != null);
    const publication = try h.cx.bindState(@import("ui/shell_styles.zig").ThemePublication, .{});
    const node_id = row.node.id;
    for ([_]T.Name{ .light, .sauber, .dark }) |name| {
        T.select(name);
        publication.publish(h.cx, T.widgetTheme(name));
        h.frames();
        try std.testing.expectEqual(T.current().surface_1, v.root.getBackground());
        try std.testing.expectEqual(ui.Color.TRANSPARENT, v.search_box.getBackground());
        try std.testing.expectEqual(V.styles.hostSelection(), row.node.getBackground());
        const badge = find(row.node, "sidebar.host.route-badge").?;
        const count = find(row.node, "sidebar.host.hops").?;
        try std.testing.expectEqual(ui.Color.TRANSPARENT, badge.getBackground());
        try std.testing.expectEqual(T.current().fg_2, count.getText().?.color);
        try std.testing.expect(@import("ui/theme_states.zig").contrast(T.current().surface_1.withAlpha(255), count.getText().?.color) >= 4.5);
        try std.testing.expectEqual(node_id, row.node.id);
        try std.testing.expectEqual(ui.Color.TRANSPARENT, find(v.root, "sidebar.footer.new").?.getBackground());
        try std.testing.expectEqual(ui.Color.TRANSPARENT, find(v.root, "sidebar.empty.new").?.getBackground());
    }
    _ = T.setMaterialVisible(true);
    publication.publish(h.cx, T.widgetTheme(T.currentName()));
    h.frames();
    try std.testing.expect(v.root.getBackground().a < 255);
    try std.testing.expectEqual(ui.Color.TRANSPARENT, find(v.root, "sidebar.footer.new").?.getBackground());
    try std.testing.expectEqual(ui.Color.TRANSPARENT, find(v.root, "sidebar.empty.new").?.getBackground());
    try std.testing.expect(v.search_box.getBackground().a < 255);
    try std.testing.expectEqual(T.current().fg_1, row.name.getText().?.color);
}
test "sidebar search expands in header with saved hosts" {
    var capture: Capture = .{};
    const h = try H.init();
    defer h.deinit();
    const list = try ui.box(h.cx, V.styles.list(), .{});
    const v = try V.View.mount(h.cx, h.scope, list, .{ .context = &capture, .collapse = Capture.collapse, .search_changed = h.cx.on(Capture, &capture, Capture.search), .bridge = capture.bridge() });
    v.empty.setDisplay(.none);
    try h.root.appendChild(h.cx.allocator, v.root);
    h.frames();
    const toggle = find(v.full, "sidebar.search.toggle").?;
    const new_button = find(v.full, "sidebar.new").?;
    const initial_x = toggle.globalRect().x;
    try std.testing.expect(toggle.globalRect().x < new_button.globalRect().x);
    try std.testing.expect(v.search.node.style.display == .none);
    const toggle_rect = toggle.globalRect();
    h.cx.handleMouseDown(toggle_rect.x + toggle_rect.w / 2, toggle_rect.y + toggle_rect.h / 2, .{});
    h.cx.handleMouseUp(toggle_rect.x + toggle_rect.w / 2, toggle_rect.y + toggle_rect.h / 2);
    h.cx.frame_count += 1;
    h.cx.frame_time_ms += 64;
    h.cx.bindFrameClock();
    _ = h.cx.render();
    try std.testing.expect(v.search_box.globalRect().w > 24 and v.search_box.globalRect().w < 185);
    h.frames();
    try std.testing.expect(v.search.node.style.display == .flex);
    try std.testing.expectEqual(v.search.input_container, h.cx.focus_manager.getFocused().?);
    try std.testing.expectApproxEqAbs(initial_x, toggle.globalRect().x, 0.1);
    for ([_]f32{ 238, 220, 320, 480, 238 }) |width| {
        v.root.setStyle(h.cx.allocator, .width, .{ .px = width });
        h.frames();
        const search = v.search_box.globalRect();
        const header = v.header.globalRect();
        const new_action = new_button.globalRect();
        try std.testing.expectApproxEqAbs(header.x + 17 + 6, search.x, 0.1);
        try std.testing.expectApproxEqAbs(new_action.x - 6, search.x + search.w, 0.1);
        try std.testing.expectApproxEqAbs(header.x + header.w, new_action.x + new_action.w, 0.1);
    }
    try std.testing.expectEqual(T.current().well_border, v.search_box.getBackground());
    v.search_value.set("demo");
    h.frames();
    const clear = find(v.full, "sidebar.search.clear").?;
    try std.testing.expect(clear.style.display == .flex);
    h.click(clear);
    try std.testing.expectEqualStrings("", v.search_value.peek());
    h.click(toggle);
    h.frames();
    try std.testing.expect(v.search.node.style.display == .none);
    try std.testing.expectApproxEqAbs(@as(f32, 24), v.search_box.globalRect().w, 0.1);
}

test "sidebar native precise empty state keeps new host footer at bottom" {
    var capture: Capture = .{};
    const h = try H.init();
    defer h.deinit();
    const list = try ui.box(h.cx, V.styles.list(), .{});
    const v = try V.View.mount(h.cx, h.scope, list, .{ .context = &capture, .collapse = Capture.collapse, .search_changed = h.cx.on(Capture, &capture, Capture.search), .bridge = capture.bridge() });
    v.full.setDisplay(.none);
    try h.root.appendChild(h.cx.allocator, v.root);
    h.frames();
    const explanation = find(v.empty, "sidebar.empty.explanation").?;
    try std.testing.expectApproxEqAbs(@as(f32, 206), explanation.globalRect().w, 0.1);
    try std.testing.expectApproxEqAbs(@as(f32, 18), explanation.globalRect().h, 0.1);
    try std.testing.expect(find(v.empty, "sidebar.search.toggle") == null);
    const button = find(v.empty, "sidebar.empty.new").?;
    const rect = button.globalRect();
    try std.testing.expectApproxEqAbs(@as(f32, 8), rect.x, 0.1);
    try std.testing.expectApproxEqAbs(@as(f32, 758), rect.y, 0.1);
    try std.testing.expectApproxEqAbs(@as(f32, 222), rect.w, 0.1);
    try std.testing.expectApproxEqAbs(@as(f32, 34), rect.h, 0.1);
    try std.testing.expectApproxEqAbs(@as(f32, 2), v.root.globalRect().h - rect.y - rect.h, 0.1);
    try std.testing.expect(find(button.parent.?, "sidebar.footer.frame") == null);
    const icon = firstIcon(button).?.globalRect();
    const label = firstText(button).?.globalRect();
    try std.testing.expectApproxEqAbs(rect.x + rect.w / 2, (icon.x + label.x + label.w) / 2, 1);
    h.click(button);
    try std.testing.expectEqual(@as(usize, 1), capture.new_host);
    try std.testing.expect(find(v.empty, "sidebar.empty.collapse") == null);
    try std.testing.expectEqual(@as(usize, 0), capture.collapsed);
}

test "sidebar native workspace actual groups search captured assets and collapsed host details" {
    const W = @import("ui/workspace.zig");
    const Collapsed = @import("ui/sidebar_collapsed_view.zig");
    const h = try H.init();
    defer h.cx.deinit();
    const list = try ui.box(h.cx, V.styles.list(), .{});
    const config: @import("config/config.zig").Config = .{};
    const registry = try @import("config/hosts.zig").Registry.parse(std.testing.allocator,
        \\[[hosts]]
        \\name="K8s-Node01"; host="10.0.0.1"; user="root"; group="PRODUCTION"
        \\[[hosts]]
        \\name="DB-Master"; host="10.0.0.2"; user="ops"
    );
    var workspace: W.Workspace = .{ .allocator = std.testing.allocator, .cx = h.cx, .scope = h.scope, .io = std.testing.io, .app_config = &config, .palette = W.Palette.fromTheme(), .registry = registry, .hosts_path = "", .sidebar_list = list, .tab_bar = h.root, .model = .{ .allocator = std.testing.allocator, .window = @fromBackingInt(1), .workspace = @fromBackingInt(1) }, .terminal_area = h.root, .empty_state = h.root };
    // h owns scopes/nodes; the model-only fixture owns these arrays/registry.
    defer {
        h.scope.dispose();
        for (workspace.click_ctxs.items) |cell| std.testing.allocator.destroy(cell);
        workspace.click_ctxs.deinit(std.testing.allocator);
        workspace.host_rows.deinit(std.testing.allocator);
        workspace.group_headers.deinit(std.testing.allocator);
        workspace.group_rows.deinit(std.testing.allocator);
        workspace.identities.deinit(std.testing.allocator);
        workspace.model.deinit();
        workspace.registry.deinit();
    }
    _ = try workspace.registry.addGroup("EMPTY", "#6366f1");
    var capture: Capture = .{};
    const chrome = try V.View.mount(h.cx, h.scope, list, .{ .context = &capture, .collapse = Capture.collapse, .search_changed = h.cx.on(Capture, &capture, Capture.search), .bridge = capture.bridge() });
    workspace.sidebar_chrome = chrome;
    chrome.empty.setDisplay(.none);
    try h.root.appendChild(h.cx.allocator, chrome.root);
    try workspace.setSidebarBridge(capture.bridge());
    h.frames();
    try std.testing.expectEqual(@as(usize, 3), workspace.group_headers.items.len);
    try std.testing.expectEqual(@as(usize, 2), workspace.host_rows.items.len);
    try std.testing.expectApproxEqAbs(@as(f32, 218), list.globalRect().w, 0.1);
    for (workspace.group_headers.items) |group| try std.testing.expectApproxEqAbs(@as(f32, 218), group.globalRect().w, 0.1);
    for (workspace.host_rows.items) |row| {
        try std.testing.expectApproxEqAbs(@as(f32, 206), row.node.globalRect().w, 0.1);
        try std.testing.expectApproxEqAbs(@as(f32, 36), row.node.globalRect().h, 0.1);
        try std.testing.expect(row.name_node.globalRect().w > 0);
    }
    chrome.root.setDisplay(.none);
    try workspace.rebuildSidebar();
    h.frames();
    chrome.root.setDisplay(.flex);
    h.frames();
    for (workspace.group_headers.items) |group| try std.testing.expectApproxEqAbs(@as(f32, 218), group.globalRect().w, 0.1);
    for (workspace.host_rows.items) |row| {
        try std.testing.expectApproxEqAbs(@as(f32, 206), row.node.globalRect().w, 0.1);
        try std.testing.expect(row.name_node.globalRect().w > 0);
    }
    h.click(workspace.default_group_row.?.header);
    try std.testing.expect(workspace.default_group_row.?.collapsed);
    workspace.setSearch("DB");
    h.frames();
    try std.testing.expect(!workspace.default_group_row.?.collapsed);
    workspace.setSearch("");
    h.frames();
    try std.testing.expect(workspace.default_group_row.?.collapsed);
    workspace.setSearch("k8S");
    h.frames();
    try std.testing.expectEqual(@as(usize, 1), workspace.host_rows.items.len);
    const host_rect = workspace.host_rows.items[0].node.globalRect();
    h.cx.handleMouseMove(host_rect.x + host_rect.w / 2, host_rect.y + host_rect.h / 2);
    h.frames();
    h.click(workspace.host_rows.items[0].node);
    try std.testing.expectEqual(@as(?usize, 0), workspace.selected_host);
    workspace.registry.hosts[0].revision += 1;
    workspace.selected_host = null;
    h.click(workspace.host_rows.items[0].node);
    try std.testing.expect(workspace.selected_host == null);
    workspace.setSearch("");
    h.frames();
    const rail = try Collapsed.View.mount(h.cx, h.scope, &workspace, .{ .context = &capture, .search = Capture.collapse, .new_host = Capture.collapse, .expand = Capture.collapse, .host_action = Capture.railAction });
    try h.root.appendChild(h.cx.allocator, rail.root);
    rail.root.setDisplay(.flex);
    chrome.root.setDisplay(.none);
    try rail.refresh();
    h.frames();
    try std.testing.expectApproxEqAbs(@as(f32, 36), rail.root.globalRect().w, 0.1);
    try std.testing.expect(find(rail.root, "sidebar.rail.host.1") == null);
    const restore = find(rail.root, "sidebar.restore").?;
    h.click(restore);
    try std.testing.expectEqual(@as(usize, 1), capture.collapsed);
    try std.testing.expect(!rail.ownsSidebar());
    rail.setCollapsed(false);
    chrome.root.setDisplay(.flex);
    h.frames();
    // The default group deliberately remains collapsed above; validate the
    // visible PRODUCTION row instead of that hidden group's zero-width row.
    for (workspace.host_rows.items) |row| if (row.host_index == 0) {
        try std.testing.expectApproxEqAbs(@as(f32, 206), row.node.globalRect().w, 0.1);
        try std.testing.expect(row.name_node.globalRect().w > 0);
    };
}

test "main workspace sidebar follows V4 measured group search and footer geometry in three themes" {
    const previous = T.currentName();
    defer T.select(previous);
    for ([_]T.Name{ .dark, .light, .sauber }) |name| {
        T.select(name);
        var capture: Capture = .{};
        const h = try H.init();
        defer h.deinit();
        const list = try ui.box(h.cx, V.styles.list(), .{});
        const view = try V.View.mount(h.cx, h.scope, list, .{ .context = &capture, .collapse = Capture.collapse, .search_changed = h.cx.on(Capture, &capture, Capture.search), .bridge = capture.bridge() });
        view.empty.setDisplay(.none);
        try h.root.appendChild(h.cx.allocator, view.root);
        const group = try V.GroupRow.mount(h.cx, h.scope, .{ .reference = null, .name = "PRODUCTION", .count = 1, .collapsed = false }, capture.bridge());
        try list.appendChild(h.cx.allocator, group.root);
        const row = try V.HostRow.mount(h.cx, h.scope, .{ .name = "Captured target", .detail = "audit@127.0.0.1:1", .route = "本机 → Captured target", .hops = 0, .online = false }, .{ .context = &capture, .select = Capture.select, .connect = Capture.connect, .menu = Capture.menu, .action = Capture.hostAction });
        try group.members.appendChild(h.cx.allocator, row.node);
        h.frames();
        try std.testing.expectApproxEqAbs(@as(f32, 66), view.search_box.globalRect().y, 0.1);
        try std.testing.expectApproxEqAbs(@as(f32, 24), view.search_box.globalRect().w, 0.1);
        try std.testing.expect(view.search.node.style.display == .none);
        try std.testing.expectEqual(T.current().fg_2, view.search.state.placeholder_color.?);
        try std.testing.expectApproxEqAbs(@as(f32, 10), group.root.globalRect().x, 0.1);
        try std.testing.expectApproxEqAbs(@as(f32, 102), group.root.globalRect().y, 0.1);
        try std.testing.expectApproxEqAbs(@as(f32, 218), group.root.globalRect().w, 0.1);
        try std.testing.expectEqual(ui.Color.TRANSPARENT, group.root.getBackground());
        try std.testing.expectApproxEqAbs(firstIcon(view.header).?.globalRect().x, firstIcon(group.header).?.globalRect().x, 0.1);
        try std.testing.expectApproxEqAbs(@as(f32, 22), row.node.globalRect().x, 0.1);
        try std.testing.expectApproxEqAbs(@as(f32, 206), row.node.globalRect().w, 0.1);
        try std.testing.expectApproxEqAbs(@as(f32, 36), row.node.globalRect().h, 0.1);
        const guide = find(group.members, "sidebar.group.guide").?.globalRect();
        try std.testing.expectApproxEqAbs(@as(f32, 15.5), guide.x, 0.1);
        try std.testing.expectApproxEqAbs(group.header.globalRect().y + 37, guide.y, 0.1);
        try std.testing.expectApproxEqAbs(row.node.globalRect().y + 18, guide.y + guide.h, 0.1);
        try std.testing.expect(find(row.node, "sidebar.host.protocol") == null);
        try std.testing.expectEqualStrings("0", find(row.node, "sidebar.host.hops").?.getText().?.content);
        try std.testing.expectEqual(T.current().fg_3, find(group.header, "sidebar.group.count").?.getText().?.color);
        try std.testing.expect(row.trailing.style.display == .none);
        try std.testing.expect(!row.route.isDisplayedInTree());

        const width = row.name.globalRect().w;
        row.setMenuOpen(true);
        h.frames();
        try std.testing.expect(row.actions.style.display == .flex);
        try std.testing.expect(row.route.style.display == .flex);
        try std.testing.expect(width > row.name.globalRect().w);
        try std.testing.expectApproxEqAbs(row.route.globalRect().w + V.styles.host_action_gap + V.styles.host_connect_size, row.trailing.globalRect().w, 0.1);
        const footer = find(view.root, "sidebar.footer.new").?;
        try std.testing.expect(find(footer.parent.?, "sidebar.footer.frame") == null);
        try std.testing.expectApproxEqAbs(@as(f32, 218), footer.globalRect().w, 0.1);
        try std.testing.expectEqual(ui.Color.TRANSPARENT, footer.getBackground());
        try std.testing.expectApproxEqAbs(@as(f32, 750), footer.globalRect().y, 0.1);
        try std.testing.expectApproxEqAbs(@as(f32, 34), footer.globalRect().h, 0.1);
        try std.testing.expectApproxEqAbs(@as(f32, 10), view.root.globalRect().h - footer.globalRect().y - footer.globalRect().h, 0.1);
    }
}

test "sidebar production mount keeps a centered borderless new connection action" {
    const h = try H.init();
    defer h.deinit();
    // The production app does not install a runtime SVG texture loader.
    // Remove the test helper's fake loader before mounting the actual view.
    h.cx.svg_textures.setLoader(null);
    var capture: Capture = .{};
    const list = try ui.box(h.cx, V.styles.list(), .{});
    const view = try V.View.mount(h.cx, h.scope, list, .{ .context = &capture, .collapse = Capture.collapse, .search_changed = h.cx.on(Capture, &capture, Capture.search), .bridge = capture.bridge() });
    view.empty.setDisplay(.none);
    try h.root.appendChild(h.cx.allocator, view.root);
    h.frames();
    const footer = find(view.root, "sidebar.footer.new").?;
    try std.testing.expect(find(footer.parent.?, "sidebar.footer.frame") == null);
    try std.testing.expectEqual(ui.Color.TRANSPARENT, footer.getBackground());
    const focus: *ui.hooks.FocusRingAnimState = @ptrCast(@alignCast(footer.meta.per_frame.hooks.slots.focus_ring_anim.?));
    try std.testing.expect(focus.surface_cx == null);
    try std.testing.expectEqual(@as(f32, 0), footer.style.border.width);
    try std.testing.expectEqual(@as(f32, 0), focus.focus_width);
    const rect = footer.globalRect();
    const icon = firstIcon(footer).?.globalRect();
    const label = firstText(footer).?.globalRect();
    try std.testing.expectApproxEqAbs(@as(f32, 218), rect.w, 0.1);
    try std.testing.expectApproxEqAbs(@as(f32, 34), rect.h, 0.1);
    try std.testing.expectApproxEqAbs(rect.x + rect.w / 2, (icon.x + label.x + label.w) / 2, 1);
    try std.testing.expect(h.cx.svg_textures.loader == null);
}

test "sidebar new connection retains theme states and input semantics in all palettes" {
    const previous = T.currentName();
    const parameters = T.materialParameters();
    const material = T.materialVisible();
    defer {
        T.select(previous);
        _ = T.setMaterialParameters(parameters.transparency, parameters.blur);
        _ = T.setMaterialVisible(material);
    }
    const h = try H.init();
    defer h.deinit();
    var capture: Capture = .{};
    const list = try ui.box(h.cx, V.styles.list(), .{});
    const view = try V.View.mount(h.cx, h.scope, list, .{ .context = &capture, .collapse = Capture.collapse, .search_changed = h.cx.on(Capture, &capture, Capture.search), .bridge = capture.bridge() });
    view.empty.setDisplay(.none);
    try h.root.appendChild(h.cx.allocator, view.root);
    const footer = find(view.root, "sidebar.footer.new").?;
    try std.testing.expect(find(footer.parent.?, "sidebar.footer.frame") == null);
    const node_id = footer.id;
    const publication = try h.cx.bindState(@import("ui/shell_styles.zig").ThemePublication, .{});
    const Label = struct {
        fn findLabel(node: *ui.Node) ?*ui.Node {
            if (node.getText()) |text| if (std.mem.eql(u8, text.content, "新建连接")) return node;
            for (node.children.items) |child| if (findLabel(child)) |label| return label;
            return null;
        }
    };
    const label = Label.findLabel(footer).?;
    const palettes = @import("config/theme_presets.zig").ids ++ [_][]const u8{"custom"};
    for (palettes) |id| {
        errdefer std.debug.print("new connection palette: {s}\n", .{id});
        var tokens = @import("config/theme_registry.zig").builtinTokens(if (std.mem.eql(u8, id, "custom")) "light" else id);
        if (std.mem.eql(u8, id, "custom")) {
            tokens.accent = 0x357153ff;
            tokens.accent_ink = 0x24583dff;
            tokens.selection = 0xd9ecdeff;
            tokens.well_border = 0x829c8aff;
        }
        T.selectTokens(tokens);
        for ([_]f32{ 0, 75, 100 }) |transparency| {
            _ = T.setMaterialVisible(true);
            _ = T.setMaterialParameters(transparency, 0);
            h.cx.clearFocus();
            h.cx.handleMouseMove(600, 400);
            publication.publish(h.cx, T.widgetTheme(T.currentName()));
            h.frames();
            try std.testing.expectEqual(node_id, footer.id);
            try std.testing.expectEqual(ui.Color.TRANSPARENT, footer.getBackground());
            try std.testing.expectEqual(T.current().fg_2, label.getText().?.color);
            try std.testing.expectEqual(@as(f32, 0), footer.style.border.width);
            const rect = footer.globalRect();
            h.cx.handleMouseMove(rect.x + rect.w / 2, rect.y + rect.h / 2);
            h.frames();
            const hover = footer.getBackground();
            try std.testing.expectEqual(T.current().hover.a, hover.a);
            if (transparency == 0) {
                const actual = ui.Color.lerp(T.baseColors().surface_1, hover.withAlpha(255), @as(f32, @floatFromInt(hover.a)) / 255);
                try std.testing.expect(@import("ui/theme_states.zig").contrast(actual, T.current().fg_2) >= 4.5);
                if (std.mem.eql(u8, id, "reference-light") or std.mem.eql(u8, id, "dark")) {
                    const expected = T.baseColors().hover;
                    inline for (.{ "r", "g", "b" }) |channel| {
                        try std.testing.expectApproxEqAbs(@as(f32, @floatFromInt(@field(expected, channel))), @as(f32, @floatFromInt(@field(actual, channel))), 1);
                    }
                }
            }
            try std.testing.expectEqual(T.current().fg_2, label.getText().?.color);
            h.cx.handleMouseDown(rect.x + rect.w / 2, rect.y + rect.h / 2, .{});
            h.frames();
            try std.testing.expectEqual(T.states().pressed.a, footer.getBackground().a);
            h.cx.handleMouseMove(600, 400);
            h.cx.handleMouseUp(600, 400);
            h.cx.focus_manager.setFocusWithVisibility(footer, .programmatic, .show);
            h.frames();
            try std.testing.expectEqual(T.states().focus.a, footer.getBackground().a);
            try std.testing.expectEqual(@as(f32, 0), footer.style.border.width);
            if (footer.style.outline()) |outline| {
                try std.testing.expectEqual(@as(f32, 0), outline.width);
                try std.testing.expectEqual(@as(u8, 0), outline.color.a);
            }
            view.setBridge(.{});
            h.frames();
            h.click(footer);
            h.cx.handleKeyDown(.@"return", .{});
            h.frames();
            try std.testing.expectEqual(@as(usize, 0), capture.new_host);
            try std.testing.expectEqual(ui.Color.TRANSPARENT, footer.getBackground());
            view.setBridge(capture.bridge());
        }
    }
    h.cx.clearFocus();
    h.click(footer);
    try std.testing.expectEqual(@as(usize, 1), capture.new_host);
    h.cx.focus_manager.setFocusWithVisibility(footer, .programmatic, .show);
    h.frames();
    h.cx.handleKeyDown(.@"return", .{});
    h.frames();
    try std.testing.expectEqual(@as(usize, 2), capture.new_host);
}

test "sidebar icons share Tab artwork and keep source colours across session state changes in three themes" {
    const Icon = @import("ui/session_icon.zig");
    const previous = T.currentName();
    defer T.select(previous);
    for ([_]T.Name{ .dark, .light, .sauber }) |name| {
        T.select(name);
        const h = try H.init();
        defer h.deinit();
        var capture: Capture = .{};
        for ([_]Icon.Kind{ .local, .terminal, .file }) |kind| {
            const row = try V.HostRow.mount(h.cx, h.scope, .{ .kind = kind, .name = "same target", .detail = "audit@127.0.0.1:1", .route = "本机 → same target", .hops = 0, .online = false }, .{ .context = &capture, .select = Capture.select, .connect = Capture.connect, .menu = Capture.menu, .action = Capture.hostAction });
            try h.root.appendChild(h.cx.allocator, row.node);
            row.node.setStyleInline(h.cx.allocator, .{ .width = .{ .px = 202 } });
            h.frames();
            const tab_icon = Icon.forTab(kind == .local, false, kind != .file);
            const host_ink = if (kind == .local) ui.Color.hex(0xa1a1aa) else T.current().fg_2;
            try std.testing.expectEqual(tab_icon.icon_id.?, row.dot.getIcon().?.icon_id);
            try std.testing.expectEqual(host_ink, row.dot.getIcon().?.tint);
            row.setSelected(true);
            h.frames();
            try std.testing.expectEqual(host_ink, row.dot.getIcon().?.tint);
            row.setOnline(true);
            h.frames();
            try std.testing.expectEqual(host_ink, row.dot.getIcon().?.tint);
            row.setOnline(false);
            h.frames();
            try std.testing.expectEqual(host_ink, row.dot.getIcon().?.tint);
            try std.testing.expectApproxEqAbs(@as(f32, 18), row.dot.globalRect().w, 0.1);
            try std.testing.expectApproxEqAbs(@as(f32, 18), row.dot.globalRect().h, 0.1);
        }
    }
}

test "sidebar KVM ink follows every retained theme while uploaded OS artwork keeps source colours" {
    const icons = @import("ui/session_icon.zig");
    const previous = T.currentName();
    const parameters = T.materialParameters();
    const material = T.materialVisible();
    defer {
        T.select(previous);
        _ = T.setMaterialParameters(parameters.transparency, parameters.blur);
        _ = T.setMaterialVisible(material);
    }
    T.select(.dark);
    _ = T.setMaterialParameters(75, 24);
    _ = T.setMaterialVisible(true);
    const h = try H.init();
    defer h.deinit();
    var capture: Capture = .{};
    const callbacks: V.HostCallbacks = .{ .context = &capture, .select = Capture.select, .connect = Capture.connect, .menu = Capture.menu, .action = Capture.hostAction };
    const row = try V.HostRow.mount(h.cx, h.scope, .{ .protocol = "bmc_ikvm", .supports_route = false, .icon = icons.forHost(.{}, "bmc_ikvm", .unknown), .name = "P3C9-KVM", .detail = "console", .route = "", .hops = 0, .online = false }, callbacks);
    try h.root.appendChild(h.cx.allocator, row.node);
    const os = try V.HostRow.mount(h.cx, h.scope, .{ .icon = icons.forHost(.{}, "ssh", .linux), .name = "Linux", .detail = "ops@host", .route = "", .hops = 0, .online = false }, callbacks);
    try h.root.appendChild(h.cx.allocator, os.node);
    try std.testing.expectEqual(ui.Color.WHITE, os.dot.getIcon().?.tint);
    // Match the production upload, which replaces the coloured SVG with an image.
    os.dot.setIcon(null);
    os.dot.setImage(.{ .texture_id = 1, .tint = ui.Color.WHITE });
    const publication = try h.cx.bindState(@import("ui/shell_styles.zig").ThemePublication, .{});
    const retained_id = row.dot.id;
    for (@import("config/theme_presets.zig").ids) |id| {
        T.selectTokens(@import("config/theme_registry.zig").builtinTokens(id));
        publication.publish(h.cx, T.widgetTheme(T.currentName()));
        for ([_]bool{ false, true }) |selected| {
            row.setSelected(selected);
            row.setOnline(selected);
            h.frames();
            const rect = row.node.globalRect();
            h.cx.handleMouseMove(if (selected) rect.x + 10 else 899, if (selected) rect.y + 10 else 793);
            h.frames();
            try std.testing.expectEqual(retained_id, row.dot.id);
            try std.testing.expectEqual(ui.icons.screen_share.icon_id.?, row.dot.getIcon().?.icon_id);
            try std.testing.expectEqual(V.styles.kvmIconInk(), row.dot.getIcon().?.tint);
            try std.testing.expectEqual(ui.Color.WHITE, os.dot.getImage().?.tint);
        }
    }
    try std.testing.expectEqual(ui.icons.screen_share.icon_id, icons.forHost(.{}, "bmc_ikvm", .linux).icon_id);
    icons.setHostNode(row.dot, .{}, "ssh", .rocky);
    try std.testing.expectEqual(ui.Color.WHITE, row.dot.getIcon().?.tint);
    icons.setHostNode(row.dot, .{}, "bmc_ikvm", .unknown);
    try std.testing.expectEqual(V.styles.kvmIconInk(), row.dot.getIcon().?.tint);
}

test "sidebar selected rail preserves theme hues as translucent surfaces" {
    defer T.select(.dark);
    const names = [_]@import("ui/app_theme.zig").Name{ .dark, .light, .sauber };
    const selected = [_]ui.Color{ ui.Color.hex(0x6164ec).withAlpha(64), ui.Color.hex(0x4f46e5).withAlpha(64), ui.Color.hex(0x1345f6).withAlpha(64) };
    for (names, selected) |name, expected| {
        T.select(name);
        const style = V.styles.railHost(true);
        try std.testing.expect(ui.Color.eql(expected, style.background.?));
        try std.testing.expect(style.gradient == null);
        try std.testing.expectEqual(@as(f32, 32), style.width.?.px);
        try std.testing.expectEqual(@as(f32, 32), style.height.?.px);
        try std.testing.expectEqual(@as(f32, 8), style.border.?.radius);
        const idle = V.styles.railHost(false);
        try std.testing.expect(idle.gradient == null);
        try std.testing.expect(ui.Color.eql(ui.Color.TRANSPARENT, idle.background.?));
    }
    // Imported/custom palettes must not inherit the default Dark exception
    // merely because they reuse its accent or the startup preset name.
    var custom = @import("config/theme_registry.zig").builtinTokens("dark");
    custom.surface_1 = 0x202030ff;
    T.selectTokens(custom);
    try std.testing.expectEqual(T.current().accent.withAlpha(64), V.styles.railHost(true).background.?);
    custom.accent = 0xabcdefFF;
    T.selectTokens(custom);
    try std.testing.expectEqual(ui.Color.hex(0xabcdef).withAlpha(64), V.styles.railHost(true).background.?);
    T.selectTokens(@import("config/theme_registry.zig").builtinTokens("dark"));
    const old_material = T.materialVisible();
    defer _ = T.setMaterialVisible(old_material);
    _ = T.setMaterialVisible(true);
    try std.testing.expectEqual(ui.Color.hex(0x6164ec).withAlpha(64), V.styles.railHost(true).background.?);
}

test "sidebar Rocky discovery replaces cached Linux texture and tab retains state tint" {
    const h = try H.init();
    defer h.deinit();
    const icons = @import("ui/session_icon.zig");
    const node = try ui.iconTint(h.cx, icons.forHost(.{}, "ssh", .linux), ui.Color.WHITE, .{ .width = .{ .px = 18 }, .height = .{ .px = 18 } });
    try h.root.appendChild(h.cx.allocator, node);
    node.setIcon(null);
    node.setImage(.{ .texture_id = 1, .tint = ui.Color.WHITE });
    icons.setHostNode(node, .{}, "ssh", .rocky);
    try std.testing.expect(node.getImage() == null);
    try std.testing.expectEqual(icons.forHost(.{}, "ssh", .rocky).icon_id.?, node.getIcon().?.icon_id);
    const status = ui.Color.rgb(0x22, 0xc5, 0x5e);
    const tab = try ui.iconTint(h.cx, icons.forOs(.linux).?, status, .{ .width = .{ .px = 14 }, .height = .{ .px = 14 } });
    try h.root.appendChild(h.cx.allocator, tab);
    icons.setNode(tab, .rocky);
    try std.testing.expectEqual(icons.forOs(.rocky).?.icon_id.?, tab.getIcon().?.icon_id);
    try std.testing.expect(ui.Color.eql(status, tab.getIcon().?.tint));
}

test "domestic OS discovery replaces uploaded host and tab textures" {
    const icons = @import("ui/session_icon.zig");
    const h = try H.init();
    defer h.deinit();
    const host = try ui.iconTint(h.cx, icons.forHost(.{}, "ssh", .linux), ui.Color.WHITE, V.styles.icon(18));
    const tab = try ui.iconTint(h.cx, icons.forOs(.linux).?, T.current().ok_ink, V.styles.icon(14));
    try h.root.appendChild(h.cx.allocator, host);
    try h.root.appendChild(h.cx.allocator, tab);
    // The renderer has already uploaded the previously cached Linux artwork.
    host.setIcon(null);
    host.setImage(.{ .texture_id = 1, .tint = ui.Color.WHITE });
    icons.setHostNode(host, .{}, "ssh", .kylin);
    icons.setNode(tab, .kylin);
    try std.testing.expect(host.getImage() == null);
    try std.testing.expectEqual(icons.forHost(.{}, "ssh", .kylin).icon_id.?, host.getIcon().?.icon_id);
    try std.testing.expectEqual(icons.forOs(.kylin).?.icon_id.?, tab.getIcon().?.icon_id);
    // A later discovery must also replace a tab's uploaded distribution logo.
    tab.setIcon(null);
    tab.setImage(.{ .texture_id = 2, .tint = ui.Color.WHITE });
    icons.setNode(tab, .uos);
    try std.testing.expect(tab.getImage() == null);
    try std.testing.expectEqual(icons.forOs(.uos).?.icon_id.?, tab.getIcon().?.icon_id);
}

test "reported input typography and narrow host hover geometry" {
    const h = try H.init();
    defer h.deinit();
    const column = try ui.box(h.cx, .{ .width = .{ .px = 194 }, .height = .fill(), .direction = .column }, .{});
    try h.root.appendChild(h.cx.allocator, column);
    var capture: Capture = .{};
    const row = try V.HostRow.mount(h.cx, h.scope, .{ .name = "X40-AI01-long-host-name", .detail = "root@host", .route = "本机 → 跳板 → 主机", .hops = 12, .online = true }, .{ .context = &capture, .select = Capture.select, .connect = Capture.connect, .menu = Capture.menu, .action = Capture.hostAction });
    try column.appendChild(h.cx.allocator, row.node);
    const input = try ui.widgets.Input(.{ .value = try h.scope.createText("X40-AI01", .{}) }).mountResult(h.scope, h.cx);
    input.input_container.setStyleInline(h.cx.allocator, .{ .font_size = 12, .font_weight = 500 });
    input.state.font_size = 11;
    try column.appendChild(h.cx.allocator, input.node);
    h.frames();
    try std.testing.expectEqual(@as(f32, 12), input.state.font_size);
    try std.testing.expectEqual(@as(u16, 500), input.state.font_weight);
    for ([_]f32{ 194, 212, 454 }) |width| {
        column.setStyleInline(h.cx.allocator, .{ .width = .{ .px = width } });
        h.frames();
        const rect = row.node.globalRect();
        h.cx.handleMouseMove(rect.x + 10, rect.y + 10);
        h.frames();
        const actions = row.actions.globalRect();
        const route = row.route.globalRect();
        try std.testing.expect(actions.x + actions.w + 3.9 <= route.x);
        try std.testing.expect(find(row.node, "sidebar.host.protocol") == null);
        try std.testing.expect(row.route.style.display == .flex);
        try std.testing.expect(row.name.globalRect().w > 0);
        try std.testing.expect(row.name.globalRect().x + row.name.globalRect().w <= actions.x + 0.1);
        try std.testing.expectApproxEqAbs(rect.x + rect.w - V.styles.content().padding.?.right, route.x + route.w, 0.1);
        h.cx.handleMouseMove(800, 700);
        h.frames();
    }
}

test "monospace styled input uses the painted font for caret selection scrolling and hit testing" {
    const NativeSystem = @typeInfo(@typeInfo(@TypeOf(@as(ui.Cx, undefined).text.font_system)).optional.child).pointer.child;
    var fonts = try NativeSystem.init(std.testing.allocator, std.testing.io);
    defer fonts.deinit();
    const h = try H.init();
    defer h.deinit();
    h.cx.text.setFontSystem(&fonts);
    const FontPointer = @typeInfo(@typeInfo(@TypeOf(NativeSystem.findFont)).@"fn".return_type.?).error_union.payload;
    const mono = try fonts.findFont(.{ .family = "Menlo", .size = 14, .weight = .regular });
    defer mono.deinit();
    const proportional = try fonts.findFont(.{ .family = "Helvetica Neue", .size = 14, .weight = .regular });
    defer proportional.deinit();
    const Provider = struct {
        mono: FontPointer,
        proportional: FontPointer,
        fn resolve(raw: *anyopaque, options: ui.Cx.ShapeTextOpts) ?FontPointer {
            const self: *@This() = @ptrCast(@alignCast(raw));
            return if (options.use_monospace) self.mono else self.proportional;
        }
    };
    var provider: Provider = .{ .mono = mono, .proportional = proportional };
    h.cx.text.font_resolve_fn = Provider.resolve;
    h.cx.text.font_resolve_ctx = &provider;

    const value = try h.scope.createText("WiWi中😀", .{});
    const input = try ui.widgets.Input(.{ .value = value }).mountResult(h.scope, h.cx);
    try h.root.appendChild(h.cx.allocator, input.node);
    const display = input.state.text_display_node.?;
    var props = display.getText().?;
    props.use_monospace_font = true;
    display.setText(props);
    h.frames();
    const state = input.state;
    const line = try h.cx.text.visualLine(.{ .text = value.peek(), .font_family = "system", .font_size = state.font_size, .font_weight = state.font_weight, .use_monospace = true });
    const end = try line.positionToCaret(.{ .byte = .{ .value = value.peek().len }, .affinity = .downstream });
    const proportional_line = try h.cx.text.visualLine(.{ .text = value.peek(), .font_family = "system", .font_size = state.font_size, .font_weight = state.font_weight });
    const proportional_end = try proportional_line.positionToCaret(.{ .byte = .{ .value = value.peek().len }, .affinity = .downstream });
    try std.testing.expect(@abs(end.x.value - proportional_end.x.value) > 0.5);
    try std.testing.expectApproxEqAbs(end.x.value, state.visualCursorAdvance(), 0.01);
    try std.testing.expectApproxEqAbs(end.x.value, state.displayedTextAdvance(), 0.01);
    h.cx.setFocus(input.input_container);
    const stop = try line.positionToCaret(.{ .byte = .{ .value = 2 }, .affinity = .downstream });
    const rect = input.input_container.globalRect();
    h.cx.handleMouseDown(rect.x + state.padding_h + stop.x.value, rect.y + rect.h / 2, .{});
    h.cx.handleMouseUp(rect.x + state.padding_h + stop.x.value, rect.y + rect.h / 2);
    h.frames();
    try std.testing.expectEqual(@as(usize, 2), state.cursor_pos);
}

test "sidebar theme state selection acquired after focus survives focused paint and blur" {
    const previous = T.currentName();
    defer T.select(previous);
    for (@import("config/theme_presets.zig").ids) |id| {
        errdefer std.debug.print("sidebar selection theme: {s}\n", .{id});
        T.selectTokens(@import("config/theme_registry.zig").builtinTokens(id));
        const h = try H.init();
        defer h.deinit();
        var capture: Capture = .{};
        const row = try V.HostRow.mount(h.cx, h.scope, .{ .name = "主机", .detail = "fixture@192.0.2.1", .route = "本机", .hops = 0, .online = false }, .{ .context = &capture, .select = Capture.select, .connect = Capture.connect, .menu = Capture.menu, .action = Capture.hostAction });
        try h.root.appendChild(h.cx.allocator, row.node);
        h.frames();
        try std.testing.expect(!row.route.isDisplayedInTree());
        h.cx.setFocus(row.node);
        h.frames();
        try std.testing.expect(row.route.style.display == .flex);
        const focused = row.node.getBackground();
        row.setSelected(true);
        h.frames();
        try std.testing.expectEqual(T.states().selected_hover, row.node.getBackground());
        try std.testing.expect(row.node.behavior.interaction.a11y.?.selected);
        try std.testing.expect(!ui.Color.eql(focused, row.node.getBackground()));
        h.cx.setFocus(row.route);
        h.frames();
        try std.testing.expect(row.route.isDisplayedInTree() and row.actions.isDisplayedInTree());
        h.cx.clearFocus();
        h.frames();
        try std.testing.expect(!row.route.isDisplayedInTree() and !row.actions.isDisplayedInTree());
        try std.testing.expectEqual(V.styles.hostSelection(), row.node.getBackground());
        const selection = V.styles.hostSelection();
        const opacity = @as(f32, @floatFromInt(selection.a)) / 255;
        const surface = ui.Color.lerp(T.baseColors().surface_1.withAlpha(255), selection.withAlpha(255), opacity);
        try std.testing.expect(@import("ui/theme_states.zig").contrast(surface, T.current().fg_1) >= 4.5);
        try std.testing.expectEqual(@as(usize, 0), capture.connected);
    }
}

test "sidebar selected host follows material transparency" {
    const previous = T.currentName();
    const parameters = T.materialParameters();
    defer {
        T.select(previous);
        _ = T.setMaterialParameters(parameters.transparency, parameters.blur);
    }
    T.selectTokens(@import("config/theme_registry.zig").builtinTokens("reference-light"));
    _ = T.setMaterialParameters(0, 0);
    try std.testing.expectEqual(@as(u8, 255), V.styles.hostSelection().a);
    _ = T.setMaterialParameters(100, 0);
    try std.testing.expectEqual(T.states().selected.a, V.styles.hostSelection().a);
}
