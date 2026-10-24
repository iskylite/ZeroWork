const std = @import("std");
const ui = @import("ui");
const V = @import("ui/sidebar_view.zig");
const T = V.styles.theme;
test "sidebar native declarations" {
    std.testing.refAllDecls(V);
}

test "background SOCKS sidebar badge preserves row geometry route actions and connection dot" {
    T.select(.dark);
    defer T.select(.dark);
    const h = try H.init();
    defer h.deinit();
    const column = try ui.box(h.cx, .{ .width = .{ .px = 208 }, .height = .fill(), .direction = .column }, .{});
    try h.root.appendChild(h.cx.allocator, column);
    var capture: Capture = .{};
    const row = try V.HostRow.mount(h.cx, h.scope, .{ .name = "后台主机", .detail = "root@192.0.2.1:22", .route = "本机 → 跳板 → 后台主机", .hops = 1, .online = false, .forward = .{ .port = 65535, .phase = .listening } }, .{ .context = &capture, .select = Capture.select, .connect = Capture.connect, .menu = Capture.menu });
    try column.appendChild(h.cx.allocator, row.node);
    h.frames();
    try std.testing.expectEqual(@as(f32, 32), row.node.globalRect().h);
    try std.testing.expectEqual(@as(f32, 52), find(row.node, "sidebar.host.tail").?.globalRect().w);
    try std.testing.expectEqualStrings(":65535后台", row.forward_label.getText().?.content);
    try std.testing.expect(row.forward.style.display == .flex and row.route.style.display == .none);
    try std.testing.expect(ui.Color.eql(T.current().fg_3, row.dot.getIcon().?.tint));
    try std.testing.expect(ui.Color.eql(T.current().ok_ink, row.forward_label.getText().?.color));
    row.setMenuOpen(true);
    h.frames();
    try std.testing.expect(row.forward.style.display == .none and row.actions.style.display == .flex);
    row.setMenuOpen(false);
    h.frames();
    try std.testing.expect(row.forward.style.display == .flex and row.actions.style.display == .none);
    T.select(.light);
    h.cx.setTheme(T.widgetTheme(.light));
    h.frames();
    try std.testing.expect(ui.Color.eql(T.current().fg_3, row.dot.getIcon().?.tint));
    try std.testing.expect(ui.Color.eql(T.current().ok_ink, row.forward_label.getText().?.color));
    row.setForwardBadge(.{ .port = 65535, .phase = .paused });
    try std.testing.expectEqualStrings("已暂停", row.node.behavior.interaction.a11y.?.description.?);
    try std.testing.expect(ui.Color.eql(T.current().warn_ink, row.forward_label.getText().?.color));
    row.setForwardBadge(.{ .port = null, .phase = .connecting });
    try std.testing.expectEqualStrings("连接中", row.forward_label.getText().?.content);
    row.setForwardBadge(null);
    h.frames();
    try std.testing.expect(row.forward.style.display == .none and row.route.style.display == .flex);
    try std.testing.expectEqual(@as(f32, 52), find(row.node, "sidebar.host.tail").?.globalRect().w);
}
const Capture = struct {
    selected: usize = 0,
    connected: usize = 0,
    menus: usize = 0,
    collapsed: usize = 0,
    new_host: usize = 0,
    new_group: usize = 0,
    group: ?V.GroupRef = null,
    group_action: ?V.GroupAction = null,
    rail_owner: ?@import("host/identity.zig").AssetOwner = null,
    rail_action: ?@import("ui/sidebar_collapsed_view.zig").HostAction = null,
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
test "sidebar native exact chrome and host tail remain fixed across hover focus" {
    var c: Capture = .{};
    const h = try H.init();
    defer h.deinit();
    const list = try ui.box(h.cx, V.styles.list(), .{});
    const v = try V.View.mount(h.cx, h.scope, list, .{ .context = &c, .collapse = Capture.collapse, .search_changed = h.cx.on(Capture, &c, Capture.search), .bridge = c.bridge() });
    v.empty.setDisplay(.none);
    try h.root.appendChild(h.cx.allocator, v.root);
    const row = try V.HostRow.mount(h.cx, h.scope, .{ .name = "prod-eu-central-db-master-01", .detail = "root@10.0.0.1:22", .route = "本机 → 跳板 → 目标", .hops = 2, .online = true }, .{ .context = &c, .select = Capture.select, .connect = Capture.connect, .menu = Capture.menu });
    try list.appendChild(h.cx.allocator, row.node);
    h.frames();
    try std.testing.expectApproxEqAbs(@as(f32, 224), v.root.globalRect().w, 0.1);
    try std.testing.expectApproxEqAbs(@as(f32, 31), v.search_box.globalRect().h, 0.1);
    try std.testing.expectApproxEqAbs(@as(f32, 46), v.search_box.globalRect().y, 0.1);
    try std.testing.expectApproxEqAbs(@as(f32, 32), row.node.globalRect().h, 0.1);
    const before = row.name.globalRect().w;
    const rect = row.node.globalRect();
    h.cx.handleMouseMove(rect.x + 20, rect.y + 12);
    h.frames();
    try std.testing.expectEqual(@as(@TypeOf(row.route.style.display), .none), row.route.style.display);
    try std.testing.expectApproxEqAbs(before, row.name.globalRect().w, 0.1);
    h.click(find(row.node, "sidebar.host.connect").?);
    try std.testing.expectEqual(@as(usize, 1), c.connected);
    h.click(find(row.node, "sidebar.host.more").?);
    try std.testing.expectEqual(@as(usize, 1), c.menus);
    h.click(find(v.root, "sidebar.collapse").?);
    try std.testing.expectEqual(@as(usize, 1), c.collapsed);
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
        try std.testing.expect(badge.globalRect().w >= 29);
        try std.testing.expectApproxEqAbs(@as(f32, 24), badge.globalRect().h, 0.1);
        try std.testing.expect(label.globalRect().w >= 11);
        try std.testing.expectApproxEqAbs(@as(f32, 16), label.globalRect().h, 0.1);
        try std.testing.expectApproxEqAbs(@as(f32, 9), label.globalRect().x - badge.globalRect().x, 0.1);
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
    h.cx.handleKeyDown(.down, .{});
    h.frames();
    try std.testing.expect(h.cx.isFocused(find(v.new_menu.content, "sidebar.new.group").?));
    h.cx.handleKeyDown(.@"return", .{});
    h.frames();
    try std.testing.expectEqual(@as(usize, 1), c.new_group);
}
test "sidebar native retained chrome and rows follow three themes and global material" {
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
    const row = try V.HostRow.mount(h.cx, h.scope, .{ .name = "主机", .detail = "ops@10.0.0.1:22", .route = "本机 → 主机", .hops = 0, .online = false, .selected = true }, .{ .context = &capture, .select = Capture.select, .connect = Capture.connect, .menu = Capture.menu });
    try list.appendChild(h.cx.allocator, row.node);
    const publication = try h.cx.bindState(@import("ui/shell_styles.zig").ThemePublication, .{});
    const node_id = row.node.id;
    for ([_]T.Name{ .light, .sauber, .dark }) |name| {
        T.select(name);
        publication.publish(h.cx, T.widgetTheme(name));
        h.frames();
        try std.testing.expectEqual(T.current().surface_1, v.root.getBackground());
        try std.testing.expectEqual(T.current().well, v.search_box.getBackground());
        try std.testing.expectEqual(T.current().selection, row.node.getBackground());
        try std.testing.expectEqual(node_id, row.node.id);
    }
    _ = T.setMaterialVisible(true);
    publication.publish(h.cx, T.widgetTheme(T.currentName()));
    h.frames();
    try std.testing.expect(v.root.getBackground().a < 255);
    try std.testing.expect(v.search_box.getBackground().a < 255);
    try std.testing.expectEqual(T.current().fg_1, row.name.getText().?.color);
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
    const button = find(v.empty, "sidebar.empty.new").?;
    const rect = button.globalRect();
    try std.testing.expectApproxEqAbs(@as(f32, 8), rect.x, 0.1);
    try std.testing.expectApproxEqAbs(@as(f32, 758), rect.y, 0.1);
    try std.testing.expectApproxEqAbs(@as(f32, 208), rect.w, 0.1);
    try std.testing.expectApproxEqAbs(@as(f32, 34), rect.h, 0.1);
    try std.testing.expectApproxEqAbs(@as(f32, 2), v.root.globalRect().h - rect.y - rect.h, 0.1);
    const frame = find(button.parent.?, "sidebar.footer.frame").?;
    try std.testing.expectApproxEqAbs(rect.y, frame.globalRect().y, 0.1);
    try std.testing.expectApproxEqAbs(rect.h, frame.globalRect().h, 0.1);
    h.click(button);
    try std.testing.expectEqual(@as(usize, 1), capture.new_host);
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
    try std.testing.expectApproxEqAbs(@as(f32, 208), list.globalRect().w, 0.1);
    for (workspace.group_headers.items) |group| try std.testing.expectApproxEqAbs(@as(f32, 208), group.globalRect().w, 0.1);
    for (workspace.host_rows.items) |row| {
        try std.testing.expectApproxEqAbs(@as(f32, 202), row.node.globalRect().w, 0.1);
        try std.testing.expectApproxEqAbs(@as(f32, 32), row.node.globalRect().h, 0.1);
        try std.testing.expect(row.name_node.globalRect().w > 80);
    }
    chrome.root.setDisplay(.none);
    try workspace.rebuildSidebar();
    h.frames();
    chrome.root.setDisplay(.flex);
    h.frames();
    for (workspace.group_headers.items) |group| try std.testing.expectApproxEqAbs(@as(f32, 208), group.globalRect().w, 0.1);
    for (workspace.host_rows.items) |row| {
        try std.testing.expectApproxEqAbs(@as(f32, 202), row.node.globalRect().w, 0.1);
        try std.testing.expect(row.name_node.globalRect().w > 80);
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
    try std.testing.expectApproxEqAbs(@as(f32, 48), rail.root.globalRect().w, 0.1);
    const original_parent = chrome.root.parent;
    const search_id = chrome.search.node.id;
    var icon_id: [80]u8 = undefined;
    const saved_owner = workspace.registry.hosts[0].owner();
    const first_icon = find(rail.root, try std.fmt.bufPrint(&icon_id, "sidebar.rail.host.{d}", .{@backingInt(saved_owner.id)})).?;
    const icon_node_id = first_icon.id;
    try rail.refresh();
    try std.testing.expectEqual(icon_node_id, first_icon.id);
    h.click(first_icon);
    for (0..4) |_| h.frames();
    try std.testing.expectEqual(@as(usize, 0), capture.collapsed);
    try std.testing.expect(workspace.selected_host == null);
    try std.testing.expect(!rail.ownsSidebar());
    const selected_icon = firstIcon(first_icon).?;
    try std.testing.expectEqual(T.current().fg_3, selected_icon.getIcon().?.tint);
    var live_tab: W.SessionTab = undefined;
    live_tab.host_id = workspace.hostId(0).?;
    live_tab.failed = false;
    live_tab.terminal = null;
    live_tab.file_ready = true;
    var live_tabs = [_]*W.SessionTab{&live_tab};
    const original_tabs = workspace.tabs;
    workspace.tabs.items = &live_tabs;
    workspace.tabs.capacity = live_tabs.len;
    try rail.refresh();
    h.frames();
    try std.testing.expectEqual(T.current().ok, selected_icon.getIcon().?.tint);
    // The same selected rail node must republish its base style when the live
    // theme changes; remapping the old hard-coded purple is insufficient.
    const previous_theme = T.currentName();
    defer T.select(previous_theme);
    // This fixture advances frame clocks without wall time; avoid sampling an
    // in-flight button background transition as the committed theme surface.
    h.cx.reduced_motion = true;
    rail.setCollapsed(false);
    rail.setCollapsed(true);
    h.cx.handleMouseMove(700, 400);
    h.cx.setFocus(null);
    h.frames();
    const publication = try h.cx.bindState(@import("ui/shell_styles.zig").ThemePublication, .{});
    const selected_colors = [_]ui.Color{ ui.Color.hex(0x4f46e5), ui.Color.hex(0x1345f6), ui.Color.hex(0x6164ec) };
    for ([_]T.Name{ .light, .sauber, .dark }, selected_colors) |name, expected| {
        // Match AppNav.refreshAppearance: publish registry tokens while the
        // startup preset name remains unchanged.
        T.selectTokens(@import("config/theme_registry.zig").builtinTokens(@tagName(name)));
        publication.publish(h.cx, T.widgetTheme(T.currentName()));
        try std.testing.expectEqual(previous_theme, T.currentName());
        try rail.refresh();
        h.frames();
        try std.testing.expectEqual(icon_node_id, first_icon.id);
        try std.testing.expectEqual(@as(?bool, true), rail.items.items[0].selected);
        try std.testing.expectEqual(expected, rail.items.items[0].base.peek().background.?);
        try std.testing.expectEqual(expected, first_icon.getBackground());
        try std.testing.expectEqual(T.current().ok, selected_icon.getIcon().?.tint);
        const host_rect = first_icon.globalRect();
        h.cx.handleMouseMove(host_rect.x + host_rect.w / 2, host_rect.y + host_rect.h / 2);
        h.frames();
        try std.testing.expectEqual(T.current().hover, first_icon.getBackground());
        try std.testing.expectEqual(T.current().ok, selected_icon.getIcon().?.tint);
        h.cx.handleMouseMove(700, 400);
        h.frames();
        try std.testing.expectEqual(expected, first_icon.getBackground());
    }
    live_tab.failed = true;
    try rail.refresh();
    h.frames();
    try std.testing.expectEqual(T.current().fg_3, selected_icon.getIcon().?.tint);
    workspace.tabs = original_tabs;
    // The hot-theme check deliberately dismissed the popup above. Reopen the
    // same captured asset before continuing the original details assertions.
    h.click(first_icon);
    const detail = find(h.root, "sidebar.rail.detail").?;
    try std.testing.expectApproxEqAbs(@as(f32, 320), detail.globalRect().w, 0.1);
    try std.testing.expect(detail.globalRect().h < 154);
    const action_row = detail.children.items[detail.children.items.len - 1].globalRect();
    try std.testing.expectApproxEqAbs(@as(f32, 14), detail.globalRect().y + detail.globalRect().h - action_row.y - action_row.h, 0.1);
    h.cx.handleMouseMove(710, 410);
    try rail.refresh();
    h.frames();
    try std.testing.expect(!rail.items.items[0].popup.open.?.peek());
    h.click(first_icon);
    workspace.selected_host = 1; // Later UI focus cannot replace the captured asset.
    try rail.refresh();
    h.click(find(detail, "sidebar.rail.detail.edit").?);
    try std.testing.expectEqual(saved_owner, capture.rail_owner.?);
    try std.testing.expectEqual(Collapsed.HostAction.edit, capture.rail_action.?);
    try std.testing.expectEqual(original_parent, chrome.root.parent);
    rail.setCollapsed(false);
    chrome.root.setDisplay(.flex);
    h.frames();
    try std.testing.expectEqual(search_id, chrome.search.node.id);
    // The default group deliberately remains collapsed above; validate the
    // visible PRODUCTION row instead of that hidden group's zero-width row.
    for (workspace.host_rows.items) |row| if (row.host_index == 0) {
        try std.testing.expectApproxEqAbs(@as(f32, 202), row.node.globalRect().w, 0.1);
        try std.testing.expect(row.name_node.globalRect().w > 80);
    };
}

test "main workspace sidebar uses inset group cards search icon and framed footer in three themes" {
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
        const row = try V.HostRow.mount(h.cx, h.scope, .{ .name = "Captured target", .detail = "audit@127.0.0.1:1", .route = "本机 → Captured target", .hops = 0, .online = false }, .{ .context = &capture, .select = Capture.select, .connect = Capture.connect, .menu = Capture.menu });
        try group.members.appendChild(h.cx.allocator, row.node);
        h.frames();
        try std.testing.expectApproxEqAbs(@as(f32, 46), view.search_box.globalRect().y, 0.1);
        try std.testing.expectApproxEqAbs(@as(f32, 204), view.search_box.globalRect().w, 0.1);
        try std.testing.expectApproxEqAbs(@as(f32, 14), view.search_box.children.items[0].globalRect().w, 0.1);
        try std.testing.expectEqual(T.current().fg_2, view.search.state.placeholder_color.?);
        try std.testing.expectApproxEqAbs(@as(f32, 8), group.root.globalRect().x, 0.1);
        try std.testing.expectApproxEqAbs(@as(f32, 85), group.root.globalRect().y, 0.1);
        try std.testing.expectApproxEqAbs(@as(f32, 208), group.root.globalRect().w, 0.1);
        try std.testing.expectEqual(T.current().surface_2, group.root.getBackground());
        try std.testing.expectApproxEqAbs(@as(f32, 11), row.node.globalRect().x, 0.1);
        try std.testing.expectApproxEqAbs(@as(f32, 202), row.node.globalRect().w, 0.1);
        try std.testing.expectApproxEqAbs(@as(f32, 32), row.node.globalRect().h, 0.1);
        const width = row.name.globalRect().w;
        row.setMenuOpen(true);
        h.frames();
        try std.testing.expect(row.actions.style.display == .flex);
        try std.testing.expect(row.route.style.display == .none);
        try std.testing.expectApproxEqAbs(width, row.name.globalRect().w, 0.1);
        const footer = find(view.root, "sidebar.footer.new").?;
        const frame = find(footer.parent.?, "sidebar.footer.frame").?;
        try std.testing.expectApproxEqAbs(@as(f32, 208), frame.globalRect().w, 0.1);
        try std.testing.expectApproxEqAbs(@as(f32, 34), frame.globalRect().h, 0.1);
        try std.testing.expectApproxEqAbs(footer.globalRect().x, frame.globalRect().x, 0.1);
        try std.testing.expectApproxEqAbs(footer.globalRect().y, frame.globalRect().y, 0.1);
        try std.testing.expectEqual(T.current().well, footer.getBackground());
        try std.testing.expectApproxEqAbs(@as(f32, 752), footer.globalRect().y, 0.1);
        try std.testing.expectApproxEqAbs(@as(f32, 34), footer.globalRect().h, 0.1);
        try std.testing.expectApproxEqAbs(@as(f32, 8), view.root.globalRect().h - footer.globalRect().y - footer.globalRect().h, 0.1);
    }
}

test "sidebar production mount uses compiled footer vectors with no SVG texture loader" {
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
    const frame = find(footer.parent.?, "sidebar.footer.frame").?;
    const icon = frame.getIcon().?;
    try std.testing.expectEqual(@as(u16, 60001), icon.icon_id);
    try std.testing.expect(icon.rep.shapes.len > 0);
    // A Figma clipPath rectangle must not become an opaque overlay on the
    // actual Button label when compiled by zenit's SVG subset.
    for (icon.rep.shapes) |shape| {
        try std.testing.expect(!shape.fill);
        try std.testing.expect(shape.stroke_width > 0);
    }
    try std.testing.expectApproxEqAbs(@as(f32, 208), icon.rep.view_width, 0.1);
    try std.testing.expectApproxEqAbs(@as(f32, 34), icon.rep.view_height, 0.1);
    try std.testing.expectApproxEqAbs(@as(f32, 208), frame.globalRect().w, 0.1);
    try std.testing.expectApproxEqAbs(@as(f32, 34), frame.globalRect().h, 0.1);
    try std.testing.expect(h.cx.svg_textures.loader == null);
}

test "sidebar icons share Tab selection and track live online changes in three themes" {
    const Icon = @import("ui/session_icon.zig");
    const previous = T.currentName();
    defer T.select(previous);
    for ([_]T.Name{ .dark, .light, .sauber }) |name| {
        T.select(name);
        const h = try H.init();
        defer h.deinit();
        var capture: Capture = .{};
        for ([_]Icon.Kind{ .local, .terminal, .file }) |kind| {
            const row = try V.HostRow.mount(h.cx, h.scope, .{ .kind = kind, .name = "same target", .detail = "audit@127.0.0.1:1", .route = "本机 → same target", .hops = 0, .online = false }, .{ .context = &capture, .select = Capture.select, .connect = Capture.connect, .menu = Capture.menu });
            try h.root.appendChild(h.cx.allocator, row.node);
            row.node.setStyleInline(h.cx.allocator, .{ .width = .{ .px = 202 } });
            h.frames();
            const tab_icon = Icon.forTab(kind == .local, false, kind != .file);
            try std.testing.expectEqual(tab_icon.icon_id.?, row.dot.getIcon().?.icon_id);
            try std.testing.expectEqual(T.current().fg_3, row.dot.getIcon().?.tint);
            row.setSelected(true);
            h.frames();
            try std.testing.expectEqual(T.current().fg_3, row.dot.getIcon().?.tint);
            row.setOnline(true);
            h.frames();
            try std.testing.expectEqual(T.current().ok, row.dot.getIcon().?.tint);
            row.setOnline(false);
            h.frames();
            try std.testing.expectEqual(T.current().fg_3, row.dot.getIcon().?.tint);
            try std.testing.expectApproxEqAbs(@as(f32, 14), row.dot.globalRect().w, 0.1);
            try std.testing.expectApproxEqAbs(@as(f32, 14), row.dot.globalRect().h, 0.1);
        }
    }
}

test "sidebar selected rail follows all theme prototype solid surfaces" {
    defer T.select(.dark);
    const names = [_]@import("ui/app_theme.zig").Name{ .dark, .light, .sauber };
    const selected = [_]ui.Color{ ui.Color.hex(0x6164ec), ui.Color.hex(0x4f46e5), ui.Color.hex(0x1345f6) };
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
    try std.testing.expectEqual(T.current().accent, V.styles.railHost(true).background.?);
    custom.accent = 0xabcdefFF;
    T.selectTokens(custom);
    try std.testing.expectEqual(ui.Color.hex(0xabcdef), V.styles.railHost(true).background.?);
    T.selectTokens(@import("config/theme_registry.zig").builtinTokens("dark"));
    const old_material = T.materialVisible();
    defer _ = T.setMaterialVisible(old_material);
    _ = T.setMaterialVisible(true);
    try std.testing.expectEqual(ui.Color.hex(0x6164ec), V.styles.railHost(true).background.?);
}
