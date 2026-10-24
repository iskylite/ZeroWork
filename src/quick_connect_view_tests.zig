const std = @import("std");
const ui = @import("ui");
const V = @import("ui/quick_connect_view.zig");
const identity = @import("host/identity.zig");
const parser = @import("ui/quick_connect.zig");
const T = V.styles.theme;
const owner_a: identity.AssetOwner = .{ .id = @fromBackingInt(81), .revision = 7 };
const owner_b: identity.AssetOwner = .{ .id = @fromBackingInt(92), .revision = 3 };
const assets = [_]V.SavedAsset{
    .{ .owner = owner_a, .name = "DB-Master", .host = "10.200.4.18", .user = "admin", .group = "Production", .hops = 2 },
    .{ .owner = owner_b, .name = "K8s-Node01", .host = "10.200.4.25", .user = "ubuntu", .hops = 1 },
    .{ .owner = .{ .id = @fromBackingInt(105), .revision = 2 }, .name = "Files", .host = "10.200.4.30", .user = "deploy", .protocol = .sftp },
};
const Probe = struct {
    saved_count: usize = 0,
    temporary_count: usize = 0,
    profile_count: usize = 0,
    closed_count: usize = 0,
    fail_saved: bool = false,
    owner: ?identity.AssetOwner = null,
    target_port: u16 = 0,
    target_host: [256]u8 = @splat(0),
    target_host_len: usize = 0,
    target_user: [128]u8 = @splat(0),
    target_user_len: usize = 0,
    profile_query: [256]u8 = @splat(0),
    profile_query_len: usize = 0,
    profile_has_target: bool = false,
    fn saved(raw: *anyopaque, owner: identity.AssetOwner) !void {
        const self: *Probe = @ptrCast(@alignCast(raw));
        self.saved_count += 1;
        self.owner = owner;
        if (self.fail_saved) return error.StaleAsset;
    }
    fn temporary(raw: *anyopaque, target: parser.ParsedTarget) !void {
        const self: *Probe = @ptrCast(@alignCast(raw));
        self.temporary_count += 1;
        self.target_port = target.port;
        self.target_host_len = target.host.len;
        @memcpy(self.target_host[0..target.host.len], target.host);
        const user = target.user orelse "";
        self.target_user_len = user.len;
        @memcpy(self.target_user[0..user.len], user);
    }
    fn profile(raw: *anyopaque, target: ?parser.ParsedTarget, query: []const u8) !void {
        const self: *Probe = @ptrCast(@alignCast(raw));
        self.profile_count += 1;
        self.profile_has_target = target != null;
        self.profile_query_len = query.len;
        @memcpy(self.profile_query[0..query.len], query);
    }
    fn closed(raw: *anyopaque) void {
        const self: *Probe = @ptrCast(@alignCast(raw));
        self.closed_count += 1;
    }
};
const H = struct {
    cx: *ui.Cx,
    scope: *ui.Scope,
    view: *V.View,
    anchor: *ui.Node,
    fn init(probe: *Probe) !H {
        const cx = try ui.Cx.init(std.testing.allocator, std.testing.io);
        errdefer cx.deinit();
        cx.setViewport(1440, 900);
        cx.bindFrameClock();
        cx.root = try ui.box(cx, .{ .width = .fill(), .height = .fill() }, .{});
        cx.svg_textures.setLoader(.{ .load_fn = struct {
            fn load(_: ?*anyopaque, _: []const u8, _: u32, _: u32) !u32 {
                return 9001;
            }
        }.load });
        const scope = try ui.Scope.init(std.testing.allocator, null, cx.owner);
        const anchor = try ui.widgets.Button(.{ .label = "连接" }).mount(scope, cx);
        try cx.root.?.appendChild(cx.allocator, anchor);
        const view = try V.View.mount(cx, scope, .{ .context = probe, .saved = Probe.saved, .temporary = Probe.temporary, .new_profile = Probe.profile, .closed = Probe.closed });
        try cx.root.?.appendChild(cx.allocator, view.root);
        const result: H = .{ .cx = cx, .scope = scope, .view = view, .anchor = anchor };
        result.frames();
        cx.setFocus(anchor);
        try view.update(1, &assets);
        try view.show();
        result.frames();
        return result;
    }
    fn deinit(self: H) void {
        self.scope.dispose();
        self.cx.deinit();
    }
    fn frames(self: H) void {
        for (0..12) |_| {
            self.cx.frame_count += 1;
            self.cx.frame_time_ms += 16;
            self.cx.bindFrameClock();
            _ = self.cx.render();
        }
    }
    fn key(self: H, code: ui.events.KeyCode) void {
        self.cx.handleKeyDown(code, .{});
        self.frames();
    }
    fn click(self: H, node: *ui.Node) void {
        const r = node.globalRect();
        self.cx.handleMouseDown(r.x + r.w / 2, r.y + r.h / 2, .{});
        self.cx.handleMouseUp(r.x + r.w / 2, r.y + r.h / 2);
        self.frames();
    }
    fn query(self: H, value: []const u8) void {
        self.view.setQuery(value);
        self.frames();
    }
};
fn near(expected: f32, actual: f32) !void {
    try std.testing.expectApproxEqAbs(expected, actual, 0.1);
}
fn part(node: *ui.Node, parent: *ui.Node, x: f32, y: f32, width: f32, height: f32) !void {
    const a = node.globalRect();
    const b = parent.globalRect();
    try near(x, a.x - b.x);
    try near(y, a.y - b.y);
    try near(width, a.w);
    try near(height, a.h);
}
fn find(node: *ui.Node, id: []const u8) ?*ui.Node {
    if (node.meta.ownership.meta.test_id) |value| if (std.mem.eql(u8, value, id)) return node;
    for (node.children.items) |child| if (find(child, id)) |result| return result;
    return null;
}
test "quick connect native saved prototype geometry and keyboard submit use captured owner" {
    var probe: Probe = .{};
    const h = try H.init(&probe);
    defer h.deinit();
    const view = h.view;
    try near(520, view.chrome.globalRect().w);
    try near(306, view.chrome.globalRect().h);
    try part(view.input.node, view.chrome, 16, 56, 488, 40);
    try part(view.input.input_container, view.chrome, 16, 56, 488, 40);
    try std.testing.expect(view.clear.style.display == .none);
    try part(view.scroll.container, view.chrome, 16, 124, 488, 96);
    try part(view.secondary, view.chrome, 16, 256, 144, 34);
    try part(view.primary, view.chrome, 360, 256, 144, 34);
    const row = view.scroll.content.children.items[0];
    try near(28, row.globalRect().h);
    const pieces = row.children.items[row.children.items.len - 1].children.items;
    try part(pieces[0], row, 8, 7, 14, 14);
    try near(108, pieces[1].globalRect().w);
    try part(pieces[2], row, 142, 7, 230, 14);
    try part(pieces[3], row, 378, 2, 46, 24);
    try std.testing.expect(pieces[2].getText().?.use_monospace_font);
    h.key(.down);
    try std.testing.expectEqual(owner_b, view.selected.?);
    h.key(.@"return");
    h.key(.@"return");
    try std.testing.expectEqual(@as(usize, 1), probe.saved_count);
    try std.testing.expectEqual(owner_b, probe.owner.?);
    try std.testing.expect(!view.isOpen());
    try std.testing.expectEqual(@as(usize, 1), probe.closed_count);
}
test "quick connect native invalid raw port remains editable and corrected fields submit structured IPv6" {
    var probe: Probe = .{};
    const h = try H.init(&probe);
    defer h.deinit();
    const view = h.view;
    h.query("ssh root@[2001:db8::1]:70000");
    try std.testing.expectEqual(V.Mode.invalid, view.mode);
    try std.testing.expectEqualStrings("70000", view.port_value.peek());
    try std.testing.expect(view.disabled.peek());
    try near(366, view.chrome.globalRect().h);
    try part(view.notice, view.chrome, 16, 102, 488, 62);
    try part(view.host_input.node, view.chrome, 16, 190, 330, 32);
    try part(view.port_input.node, view.chrome, 358, 190, 146, 32);
    try part(view.user_input.node, view.chrome, 16, 248, 488, 32);
    h.key(.@"return");
    try std.testing.expectEqual(@as(usize, 0), probe.temporary_count);
    try std.testing.expect(view.isOpen());
    h.cx.setFocus(view.port_input.input_container);
    h.cx.handleKeyDown(.a, .{ .super = true });
    h.cx.handleTextInput("2222");
    h.frames();
    try std.testing.expectEqual(V.Mode.temporary, view.mode);
    try std.testing.expectEqualStrings("root@[2001:db8::1]:2222", view.query.peek());
    h.key(.@"return");
    try std.testing.expectEqual(@as(usize, 1), probe.temporary_count);
    try std.testing.expectEqual(@as(u16, 2222), probe.target_port);
    try std.testing.expectEqualStrings("2001:db8::1", probe.target_host[0..probe.target_host_len]);
    try std.testing.expectEqualStrings("root", probe.target_user[0..probe.target_user_len]);
    try std.testing.expectEqual(@as(usize, 0), probe.profile_count);
}
test "quick connect native no match preserves query explicit profile and clear search" {
    var probe: Probe = .{};
    const h = try H.init(&probe);
    defer h.deinit();
    const view = h.view;
    h.query("no-such-host");
    // Figma 235:410394: compact empty state, inline clear and one action.
    try near(255, view.chrome.globalRect().h);
    try part(view.input.input_container, view.chrome, 16, 56, 488, 40);
    try part(view.clear, view.chrome, 464, 64, 24, 24);
    try std.testing.expect(view.secondary.style.display == .none);
    try part(view.primary, view.chrome, 360, 203, 144, 34);
    h.key(.@"return");
    try std.testing.expectEqual(@as(usize, 0), probe.profile_count);
    try std.testing.expectEqualStrings("no-such-host", view.query.peek());
    h.click(find(view.chrome, "quick.clear").?);
    try std.testing.expectEqualStrings("", view.query.peek());
    try std.testing.expectEqual(@as(usize, 3), view.matches.items.len);
    try std.testing.expect(view.clear.style.display == .none);
    try part(view.input.input_container, view.chrome, 16, 56, 488, 40);
    try std.testing.expectEqual(view.input.input_container, h.cx.focused_node.?);
    h.query("another-missing-host");
    h.click(view.primary);
    try std.testing.expectEqual(@as(usize, 1), probe.profile_count);
    try std.testing.expect(!probe.profile_has_target);
    try std.testing.expectEqualStrings("another-missing-host", probe.profile_query[0..probe.profile_query_len]);
    try std.testing.expectEqual(@as(usize, 0), probe.saved_count);
    try std.testing.expectEqual(@as(usize, 0), probe.temporary_count);
}
test "quick connect native failed callback keeps input owner and retry until receipt" {
    var probe: Probe = .{ .fail_saved = true };
    const h = try H.init(&probe);
    defer h.deinit();
    const view = h.view;
    h.query("Production");
    h.key(.@"return");
    try std.testing.expect(view.isOpen());
    try std.testing.expectEqual(error.StaleAsset, view.last_problem.?);
    try std.testing.expectEqual(owner_a, view.selected.?);
    try std.testing.expectEqualStrings("Production", view.query.peek());
    try std.testing.expectEqual(@as(usize, 0), probe.closed_count);
    probe.fail_saved = false;
    h.click(view.primary);
    try std.testing.expect(!view.isOpen());
    try std.testing.expectEqual(@as(usize, 2), probe.saved_count);
    try std.testing.expectEqual(@as(usize, 1), probe.closed_count);
}
test "quick connect native composition enter belongs to input escape restores previous focus" {
    var probe: Probe = .{};
    const h = try H.init(&probe);
    defer h.deinit();
    const view = h.view;
    const events = view.input.input_container.behavior.events;
    _ = events.on_event.?(.{ .ime_preedit = .{ .text = "zhong", .cursor_utf8_offset = 5 } }, events.event_context);
    h.key(.@"return");
    try std.testing.expect(view.input.state.imeIsComposing());
    try std.testing.expectEqual(@as(usize, 0), probe.saved_count);
    _ = events.on_event.?(.{ .ime_commit = .{ .text = "中" } }, events.event_context);
    h.frames();
    try std.testing.expectEqualStrings("中", view.query.peek());
    h.key(.escape);
    try std.testing.expect(!view.isOpen());
    try std.testing.expectEqual(h.anchor, h.cx.focused_node.?);
    try std.testing.expectEqual(@as(usize, 1), probe.closed_count);
}
test "quick connect native snapshots copy labels and reject stale row while registry changes" {
    var probe: Probe = .{};
    const h = try H.init(&probe);
    defer h.deinit();
    const view = h.view;
    var name = [_]u8{ 'F', 'i', 'r', 's', 't' };
    var source: V.SavedAsset = .{ .owner = owner_a, .name = &name, .host = "host.example", .user = "ops" };
    try view.update(2, &.{source});
    @memset(&name, 'X');
    h.frames();
    h.query("First");
    try std.testing.expectEqual(@as(usize, 1), view.matches.items.len);
    const old_rect = view.scroll.content.children.items[0].globalRect();
    source.owner.revision += 1;
    source.name = "First";
    try view.update(3, &.{source});
    h.cx.handleMouseDown(old_rect.x + 30, old_rect.y + 14, .{});
    h.cx.handleMouseUp(old_rect.x + 30, old_rect.y + 14);
    try std.testing.expectEqual(@as(usize, 0), probe.saved_count);
    h.frames();
    h.key(.@"return");
    try std.testing.expectEqual(source.owner, probe.owner.?);
    try std.testing.expectEqual(@as(usize, 1), probe.saved_count);
}
test "quick connect native theme material changes preserve active draft and selection" {
    const previous = T.currentName();
    const previous_material = T.materialVisible();
    defer {
        T.select(previous);
        _ = T.setMaterialVisible(previous_material);
    }
    var probe: Probe = .{};
    const h = try H.init(&probe);
    defer h.deinit();
    const view = h.view;
    const publication = try h.cx.bindState(@import("ui/shell_styles.zig").ThemePublication, .{});
    h.query("DB");
    const chrome_id = view.chrome.id;
    inline for (.{ T.Name.dark, T.Name.light, T.Name.sauber }) |name| {
        T.select(name);
        _ = T.setMaterialVisible(true);
        publication.publish(h.cx, T.widgetTheme(name));
        h.frames();
        try std.testing.expectEqual(chrome_id, view.chrome.id);
        try std.testing.expectEqualStrings("DB", view.query.peek());
        try std.testing.expectEqual(owner_a, view.selected.?);
        try std.testing.expectEqual(T.current().overlay, view.chrome.getBackground());
        try std.testing.expectEqual(T.current().well, view.input.input_container.getBackground());
        try std.testing.expect(view.chrome.getBackground().a < 255);
    }
    try std.testing.expectEqual(@as(usize, 0), probe.saved_count);
}
