const std = @import("std");
const M = @import("ui/socks_background_model.zig");
const identity = @import("host/identity.zig");
const sessions = @import("host/session_host.zig");
const operations = @import("host/operation.zig");
const owner: identity.SessionHandle = .{ .session_id = @fromBackingInt(501) };
const asset: identity.AssetOwner = .{ .id = @fromBackingInt(81), .revision = 3 };
fn key(handle: identity.SessionHandle) operations.OperationKey {
    return .{ .owner = .{ .session = handle }, .operation_id = handle.generation };
}
fn runtime(handle: identity.SessionHandle) M.Runtime.Snapshot {
    return .{ .owner = handle, .key = key(handle), .source = asset, .phase = .ready, .lifecycle = .ready, .protocol_cleanup = .awaiting, .cleanup = .awaiting, .failure = null, .listeners = 1, .connections_active = 2, .bytes_up = 0, .bytes_down = 0 };
}
fn listening(handle: identity.SessionHandle) M.Routes.Snapshot {
    return .{ .owner = handle, .binding = .{ .resource_owner = .{ .session = handle }, .origin_session = handle, .kind = .forward, .binding_id = 1, .binding_generation = handle.generation }, .key = key(handle), .phase = .ready, .cleanup = .awaiting, .local_port = 1083, .stats = .{ .connections_active = 2 }, .failure = null, .exit_index = null, .requested_port = 1080, .bind127 = true, .max_connections = 64 };
}
const Fixture = struct {
    values: []const M.Runtime.Snapshot = &.{},
    listener_value: ?M.Routes.Snapshot = null,
    creates: usize = 0,
    starts: usize = 0,
    listener_closes: usize = 0,
    owner_closes: usize = 0,
    reconnects: usize = 0,
    last_owner: ?identity.SessionHandle = null,
    last_options: ?M.Routes.StartOptions = null,
    start_error: ?anyerror = null,
    auto_listener: bool = true,
    close_error: ?anyerror = null,
    multiple: bool = false,
    fn hooks(self: *@This()) M.Hooks {
        return .{ .context = self, .create = create, .snapshots = snapshots, .listener = listener, .start = start, .close_listener = closeListener, .close_owner = closeOwner, .reconnect = reconnect };
    }
    fn cast(raw: *anyopaque) *@This() {
        return @ptrCast(@alignCast(raw));
    }
    fn create(raw: *anyopaque, id: u64, source: identity.AssetOwner) !sessions.Accepted {
        const self = cast(raw);
        const second = self.multiple and self.creates == 1;
        try std.testing.expectEqual(@as(u64, if (second) 78 else 77), id);
        try std.testing.expectEqualDeep(if (second) identity.AssetOwner{ .id = @fromBackingInt(82), .revision = 1 } else asset, source);
        self.creates += 1;
        const handle = if (second) identity.SessionHandle{ .session_id = @fromBackingInt(502) } else owner;
        return .{ .handle = handle, .operation = key(handle) };
    }
    fn snapshots(raw: *anyopaque, allocator: std.mem.Allocator) ![]M.Runtime.Snapshot {
        return allocator.dupe(M.Runtime.Snapshot, cast(raw).values);
    }
    fn listener(raw: *anyopaque, _: identity.SessionHandle) ?M.Routes.Snapshot {
        return cast(raw).listener_value;
    }
    fn start(raw: *anyopaque, handle: identity.SessionHandle, options: M.Routes.StartOptions) !operations.OperationKey {
        const self = cast(raw);
        self.starts += 1;
        self.last_owner = handle;
        self.last_options = options;
        if (self.start_error) |err| return err;
        if (self.auto_listener) self.listener_value = listening(handle);
        return key(handle);
    }
    fn closeListener(raw: *anyopaque, handle: identity.SessionHandle) sessions.CloseReceipt {
        const self = cast(raw);
        self.listener_closes += 1;
        self.last_owner = handle;
        return .awaiting;
    }
    fn closeOwner(raw: *anyopaque, handle: identity.SessionHandle) !operations.OperationKey {
        const self = cast(raw);
        self.owner_closes += 1;
        self.last_owner = handle;
        if (self.close_error) |err| return err;
        return key(handle);
    }
    fn reconnect(raw: *anyopaque, handle: identity.SessionHandle) !void {
        const self = cast(raw);
        self.reconnects += 1;
        self.last_owner = handle;
    }
};
fn begin(model: *M.Model) !void {
    _ = try model.startSaved(.{ .host_id = 77, .asset = asset, .name = "原始主机", .options = .{ .listener = .{ .requested_port = 1080 }, .exit_index = 1 } });
}
test "background SOCKS counts only actual registry owners and reports allocated listener port" {
    var fixture: Fixture = .{};
    var model = M.Model.init(std.testing.allocator, fixture.hooks());
    defer model.deinit();
    try begin(&model);
    try std.testing.expect(!try model.refresh());
    try std.testing.expectEqual(@as(usize, 0), model.rows.items.len);
    var value = runtime(owner);
    value.phase = .connecting;
    value.lifecycle = .creating;
    fixture.values = &.{value};
    _ = try model.refresh();
    try std.testing.expectEqual(M.Phase.connecting, model.rows.items[0].phase);
    try std.testing.expectEqual(@as(?u16, null), model.rows.items[0].local_port);
    try std.testing.expectEqual(@as(usize, 0), fixture.starts);
    fixture.values = &.{runtime(owner)};
    fixture.listener_value = null;
    _ = try model.refresh();
    _ = try model.refresh();
    try std.testing.expectEqual(@as(usize, 1), fixture.creates);
    try std.testing.expectEqual(@as(usize, 1), fixture.starts);
    try std.testing.expectEqual(@as(?usize, 1), fixture.last_options.?.exit_index);
    try std.testing.expectEqual(@as(u16, 1080), fixture.last_options.?.listener.requested_port);
    try std.testing.expectEqual(@as(?u16, 1083), model.rows.items[0].local_port);
    try std.testing.expectEqual(@as(u32, 2), model.rows.items[0].connections);
    try std.testing.expectEqual(M.Phase.listening, model.rows.items[0].phase);
}
test "background SOCKS reconnect follows actual generation and rejects stale management callbacks" {
    var fixture: Fixture = .{ .values = &.{runtime(owner)} };
    var model = M.Model.init(std.testing.allocator, fixture.hooks());
    defer model.deinit();
    try begin(&model);
    _ = try model.refresh();
    const replacement = try owner.nextGeneration();
    fixture.values = &.{runtime(replacement)};
    fixture.listener_value = listening(replacement);
    _ = try model.refresh();
    try std.testing.expectEqual(@as(usize, 1), fixture.starts);
    try std.testing.expectError(error.StaleBackgroundOwner, model.stop(owner));
    try std.testing.expectError(error.StaleBackgroundOwner, model.reconnect(owner));
    try model.reconnect(replacement);
    try std.testing.expectEqual(@as(usize, 1), fixture.reconnects);
    fixture.values = &.{runtime(owner)};
    _ = try model.refresh();
    try std.testing.expectEqual(@as(usize, 0), model.rows.items.len);
    try std.testing.expectEqual(@as(usize, 1), fixture.starts);
}
test "background SOCKS stop preserves row while actual close is pending then removes closed owner" {
    var fixture: Fixture = .{ .values = &.{runtime(owner)}, .listener_value = listening(owner) };
    var model = M.Model.init(std.testing.allocator, fixture.hooks());
    defer model.deinit();
    try begin(&model);
    _ = try model.refresh();
    try model.stop(owner);
    _ = try model.refresh();
    _ = try model.refresh();
    try std.testing.expectEqual(@as(usize, 1), fixture.listener_closes);
    try std.testing.expectEqual(@as(usize, 1), fixture.owner_closes);
    try std.testing.expectEqual(@as(usize, 1), model.rows.items.len);
    try std.testing.expectEqual(M.Phase.closing, model.rows.items[0].phase);
    try std.testing.expectError(error.BackgroundClosing, model.reconnect(owner));
    var value = runtime(owner);
    value.lifecycle = .closed;
    value.phase = .closed;
    fixture.values = &.{value};
    _ = try model.refresh();
    try std.testing.expectEqual(@as(usize, 0), model.rows.items.len);
    try std.testing.expect(!model.hasAsset(asset));
}
test "background SOCKS preserves failure and cleanup unknown without guessed green state" {
    var fixture: Fixture = .{ .values = &.{runtime(owner)}, .start_error = error.PortUnavailable };
    var model = M.Model.init(std.testing.allocator, fixture.hooks());
    defer model.deinit();
    try begin(&model);
    _ = try model.refresh();
    _ = try model.refresh();
    try std.testing.expectEqual(@as(usize, 1), fixture.starts);
    try std.testing.expectEqual(M.Phase.failed, model.rows.items[0].phase);
    try std.testing.expectEqual(error.PortUnavailable, model.rows.items[0].failure.?);
    var value = runtime(owner);
    value.phase = .cleanup_unknown;
    value.cleanup = .unknown;
    fixture.values = &.{value};
    _ = try model.refresh();
    try std.testing.expectEqual(M.Phase.cleanup_unknown, model.rows.items[0].phase);
    try std.testing.expectEqual(@as(?u16, null), model.rows.items[0].local_port);
}
test "background SOCKS excludes mismatched registry source and stale listener generation" {
    var value = runtime(owner);
    value.source.revision += 1;
    var fixture: Fixture = .{ .values = &.{value}, .auto_listener = false };
    var model = M.Model.init(std.testing.allocator, fixture.hooks());
    defer model.deinit();
    try begin(&model);
    _ = try model.refresh();
    try std.testing.expectEqual(@as(usize, 0), model.rows.items.len);
    try std.testing.expectEqual(@as(usize, 0), fixture.starts);
    fixture.values = &.{runtime(owner)};
    fixture.listener_value = listening(try owner.nextGeneration());
    _ = try model.refresh();
    try std.testing.expectEqual(M.Phase.starting, model.rows.items[0].phase);
    try std.testing.expectEqual(@as(?u16, null), model.rows.items[0].local_port);
    try std.testing.expectEqual(@as(u32, 0), model.rows.items[0].connections);
    try std.testing.expectEqualStrings("原始主机", model.rows.items[0].name);
}
test "background SOCKS requires exposure approval before creating a native owner" {
    var fixture: Fixture = .{};
    var model = M.Model.init(std.testing.allocator, fixture.hooks());
    defer model.deinit();
    try std.testing.expectError(error.ExposureConfirmationRequired, model.startSaved(.{ .host_id = 77, .asset = asset, .name = "主机", .options = .{ .listener = .{ .bind127 = false } } }));
    try std.testing.expectEqual(@as(usize, 0), fixture.creates);
}

test "background SOCKS stop acceptance never follows a later replacement generation" {
    var fixture: Fixture = .{ .values = &.{runtime(owner)}, .close_error = error.StaleSession };
    var model = M.Model.init(std.testing.allocator, fixture.hooks());
    defer model.deinit();
    try begin(&model);
    _ = try model.refresh();
    try std.testing.expectError(error.StaleSession, model.stop(owner));
    try std.testing.expectEqualDeep(owner, fixture.last_owner.?);
    const replacement = try owner.nextGeneration();
    fixture.values = &.{runtime(replacement)};
    fixture.listener_value = listening(replacement);
    _ = try model.refresh();
    _ = try model.refresh();
    try std.testing.expectEqual(@as(usize, 1), fixture.listener_closes);
    try std.testing.expectEqual(@as(usize, 1), fixture.owner_closes);
    try std.testing.expectEqual(M.Phase.listening, model.rows.items[0].phase);
}

test "background SOCKS aggregate count follows two registered owners and real close removal" {
    var fixture: Fixture = .{ .multiple = true };
    var model = M.Model.init(std.testing.allocator, fixture.hooks());
    defer model.deinit();
    try begin(&model);
    const second_owner: identity.SessionHandle = .{ .session_id = @fromBackingInt(502) };
    const second_asset: identity.AssetOwner = .{ .id = @fromBackingInt(82), .revision = 1 };
    _ = try model.startSaved(.{ .host_id = 78, .asset = second_asset, .name = "第二主机", .options = .{} });
    var second = runtime(second_owner);
    second.source = second_asset;
    fixture.values = &.{ runtime(owner), second };
    _ = try model.refresh();
    try std.testing.expectEqual(@as(usize, 2), model.rows.items.len);
    try std.testing.expectEqualDeep(second_asset, model.rows.items[1].source);
    try std.testing.expectError(error.BackgroundAlreadyActive, model.startSaved(.{ .host_id = 78, .asset = second_asset, .name = "第二主机", .options = .{} }));
    fixture.values = &.{second};
    _ = try model.refresh();
    try std.testing.expectEqual(@as(usize, 1), model.rows.items.len);
    try std.testing.expectEqualDeep(second_owner, model.rows.items[0].owner);
    try std.testing.expect(!model.hasAsset(asset));
    try std.testing.expect(model.hasAsset(second_asset));
}

const ui = @import("ui");
const V = @import("ui/socks_background_view.zig");
test "background SOCKS actual bridge declarations" {
    std.testing.refAllDecls(@import("ui/socks_background_host.zig").Host);
}
const ViewCapture = struct {
    owner: ?identity.SessionHandle = null,
    action: ?V.Action = null,
    count: usize = 0,
    fn run(raw: *anyopaque, handle: identity.SessionHandle, action: V.Action) void {
        const self: *@This() = @ptrCast(@alignCast(raw));
        self.owner = handle;
        self.action = action;
        self.count += 1;
    }
};
fn find(node: *ui.Node, id: []const u8) ?*ui.Node {
    if (node.meta.ownership.meta.test_id) |actual| if (std.mem.eql(u8, actual, id)) return node;
    for (node.children.items) |child| if (find(child, id)) |found| return found;
    return null;
}
fn frames(cx: *ui.Cx) void {
    for (0..12) |_| {
        cx.frame_count += 1;
        cx.frame_time_ms += 16;
        cx.bindFrameClock();
        _ = cx.render();
    }
}
fn click(cx: *ui.Cx, node: *ui.Node) void {
    const rect = node.globalRect();
    cx.handleMouseDownEx(rect.x + rect.w / 2, rect.y + rect.h / 2, .left, .{});
    cx.handleMouseUpEx(rect.x + rect.w / 2, rect.y + rect.h / 2, .left, .{});
}
test "background SOCKS attached list uses real count owner callbacks and theme roles" {
    V.S.theme.select(.dark);
    defer V.S.theme.select(.dark);
    const cx = try ui.Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    cx.setViewport(900, 600);
    cx.bindFrameClock();
    cx.svg_textures.setLoader(.{ .load_fn = struct {
        fn load(_: ?*anyopaque, _: []const u8, _: u32, _: u32) !u32 {
            return 9001;
        }
    }.load });
    cx.setTheme(V.S.theme.widgetTheme(.dark));
    const scope = try ui.Scope.init(std.testing.allocator, null, cx.owner);
    defer scope.dispose();
    const root = try ui.box(cx, .{ .width = .fill(), .height = .fill(), .direction = .column }, .{});
    cx.root = root;
    try root.appendChild(cx.allocator, try ui.spacer(cx));
    const bar = try ui.box(cx, .{ .width = .fill(), .height = .{ .px = 32 }, .direction = .row, .justify = .end }, .{});
    try root.appendChild(cx.allocator, bar);
    var capture: ViewCapture = .{};
    const view = try V.View.mount(cx, scope, .{ .context = &capture, .action = ViewCapture.run });
    try bar.appendChild(cx.allocator, view.remote_entry);
    try bar.appendChild(cx.allocator, view.local_entry);
    try root.appendChild(cx.allocator, view.popover.wrapper);
    view.local_entry.setDisplay(.none);
    try view.update(&.{});
    frames(cx);
    try std.testing.expect(view.remote_entry.style.display == .none);
    const rows: [1]M.Row = .{.{ .owner = owner, .source = asset, .name = "原始主机", .phase = .listening, .local_port = 1083, .connections = 2, .failure = null }};
    try view.update(&rows);
    frames(cx);
    try std.testing.expectEqualStrings("后台转发 ×1", view.count_text.get());
    try std.testing.expectEqual(@as(f32, 26), view.remote_entry.globalRect().h);
    click(cx, view.remote_entry);
    try view.update(&rows);
    frames(cx);
    try std.testing.expect(view.popover.open_read.get());
    const card = view.popover.content.globalRect();
    try std.testing.expectEqual(@as(f32, 360), card.w);
    try std.testing.expect(card.x >= 0 and card.y >= 0 and card.x + card.w <= 900 and card.y + card.h <= 600);
    const row_node = find(view.popover.content, "socks.background.row").?;
    try std.testing.expectEqual(@as(f32, 64), row_node.globalRect().h);
    const status = find(view.popover.content, "socks.background.state").?;
    try std.testing.expectEqualStrings(":1083 · 后台监听 · 2 个连接", status.getText().?.content);
    try std.testing.expect(ui.Color.eql(V.S.theme.current().ok_ink, status.getText().?.color));
    click(cx, find(view.popover.content, "socks.background.stop").?);
    try std.testing.expectEqual(@as(usize, 1), capture.count);
    try std.testing.expectEqualDeep(owner, capture.owner.?);
    try std.testing.expectEqual(V.Action.stop, capture.action.?);
    try std.testing.expect(view.popover.open_read.get());
    for ([_]V.S.theme.Name{ .light, .sauber }) |theme| {
        V.S.theme.select(theme);
        cx.setTheme(V.S.theme.widgetTheme(theme));
        frames(cx);
        try view.update(&rows);
        frames(cx);
        try std.testing.expect(ui.Color.eql(V.S.theme.current().overlay, view.popover.content.getBackground()));
        try std.testing.expect(ui.Color.eql(V.S.theme.current().ok_ink, find(view.popover.content, "socks.background.state").?.getText().?.color));
    }
    const second: M.Row = .{ .owner = .{ .session_id = @fromBackingInt(502) }, .source = .{ .id = @fromBackingInt(82) }, .name = "第二主机", .phase = .connecting, .local_port = null, .connections = 0, .failure = null };
    view.showAt(asset.id, view.remote_entry.globalRect());
    try view.update(&.{ rows[0], second });
    frames(cx);
    try std.testing.expectEqualStrings("后台转发 ×2", view.count_text.get());
    try std.testing.expectEqual(@as(usize, 1), view.list.content.children.items.len);
    try view.update(&rows);
    frames(cx);
    cx.setViewport(320, 120);
    try view.update(&rows);
    frames(cx);
    try std.testing.expect(view.popover.content.globalRect().w <= 304);
    try std.testing.expect(view.popover.content.globalRect().h <= 104);
    try view.update(&.{});
    frames(cx);
    try std.testing.expect(view.remote_entry.style.display == .none);
}
