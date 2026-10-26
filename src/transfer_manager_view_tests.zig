const std = @import("std");

const WindowLegacy = struct {
    owner: Id.SessionHandle = handle(101, 9),
    actions: usize = 0,
    window: ?V.WindowAction = null,
    fn ownerCall(raw: *anyopaque, _: u64) ?Id.SessionHandle {
        const self: *@This() = @ptrCast(@alignCast(raw));
        return self.owner;
    }
    fn action(raw: *anyopaque, _: u64, _: V.Action) void {
        const self: *@This() = @ptrCast(@alignCast(raw));
        self.actions += 1;
    }
    fn windowCall(raw: *anyopaque, action_: V.WindowAction) !void {
        const self: *@This() = @ptrCast(@alignCast(raw));
        self.window = action_;
    }
};
test "transfer projection window adapter preserves full owner generation late native hook and minimum bounds" {
    const h = try H.init(828, 412);
    defer h.deinit();
    var c: WindowLegacy = .{};
    var manager = try backend.Manager.init(std.testing.allocator, .{ .ctx = &c, .open = Engine.open, .cancel = Engine.cancel, .poll = Engine.poll }, 1, .{});
    defer manager.deinit();
    _ = try manager.enqueue(.{ .session_id = 101, .direction = .upload, .sources = &.{"/tmp/a"}, .remote_dir = "/srv", .local_dir = "/tmp" });
    manager.tick(0);
    const p = try V.mountWindow(h.cx, h.scope, &manager, .{ .context = &c, .action = WindowLegacy.action, .owner = WindowLegacy.ownerCall });
    try h.root.appendChild(h.cx.allocator, p.root);
    p.setWindowHook(&c, WindowLegacy.windowCall);
    try p.refresh(1, .{ .window_chunks = 16, .chunk_kb = 64 });
    p.show();
    h.frames();
    try std.testing.expectEqual(c.owner, p.source.?.value.rows[0].target.owner.?);
    try std.testing.expectApproxEqAbs(@as(f32, 828), p.root.globalRect().w, 0.1);
    try std.testing.expectApproxEqAbs(@as(f32, 412), p.root.globalRect().h, 0.1);
    h.cx.setViewport(1040, 720);
    p.retheme();
    h.frames();
    try std.testing.expectApproxEqAbs(@as(f32, 1040), p.root.globalRect().w, 0.1);
    try std.testing.expectApproxEqAbs(@as(f32, 720), p.root.globalRect().h, 0.1);
    h.cx.setViewport(620, 330);
    h.frames();
    try std.testing.expectApproxEqAbs(@as(f32, 620), p.root.globalRect().w, 0.1);
    try std.testing.expectApproxEqAbs(@as(f32, 330), p.root.globalRect().h, 0.1);
    click(h, id(p.root, "transfer.window.zoom").?);
    try std.testing.expectEqual(V.WindowAction.zoom, c.window.?);
    const frozen = p.source.?.value.rows[0].target;
    c.owner = handle(101, 10);
    try std.testing.expectError(error.StaleOwner, p.perform(frozen, .pause));
    try std.testing.expectEqual(@as(usize, 0), c.actions);
}
test "transfer projection global popover stays in current Cx hides without native control or job mutation" {
    const saved_theme = theme.currentName();
    const material = theme.materialVisible();
    defer {
        theme.select(saved_theme);
        _ = theme.setMaterialVisible(material);
    }
    const h = try H.init(1440, 900);
    defer h.deinit();
    const anchor = try ui.widgets.Button(.{ .icon_only = true, .icon_asset = ui.icons.arrow_down_up, .a11y_label = "传输任务", .base_style = .{ .width = .{ .px = 24 }, .height = .{ .px = 24 }, .padding = .{} } }).mount(h.scope, h.cx);
    anchor.setStyleInline(h.cx.allocator, .{ .position = .absolute, .inset = .{ .top = .{ .px = 12 }, .right = .{ .px = 14 } } });
    try h.root.appendChild(h.cx.allocator, anchor);
    var capture: WindowLegacy = .{};
    var manager = try backend.Manager.init(std.testing.allocator, .{ .ctx = &capture, .open = Engine.open, .cancel = Engine.cancel, .poll = Engine.poll }, 1, .{});
    defer manager.deinit();
    const job = try manager.enqueue(.{ .session_id = 101, .direction = .download, .sources = &.{"/srv/release.tar.gz"}, .remote_dir = "/srv", .local_dir = "/tmp" });
    manager.tick(0);
    const before = manager.progress(job).?;
    const p = try V.mountGlobalPopover(h.cx, h.scope, &manager, .{ .context = &capture, .action = WindowLegacy.action, .owner = WindowLegacy.ownerCall });
    try h.root.appendChild(h.cx.allocator, p.root);
    p.setAnchor(anchor);
    // A legacy native hook must never be reached by the in-window close.
    p.setWindowHook(&capture, WindowLegacy.windowCall);
    try p.refresh(1, .{ .window_chunks = 16, .chunk_kb = 64 });
    p.show();
    h.frames();
    const bounds = p.root.globalRect();
    const trigger = anchor.globalRect();
    try std.testing.expectEqual(V.Presentation.global_popover, p.options.presentation);
    try std.testing.expectEqual(h.cx, p.cx);
    try std.testing.expectEqual(h.root, p.root.parent.?);
    try std.testing.expectApproxEqAbs(@as(f32, 360), bounds.w, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 158), bounds.h, 0.01);
    try std.testing.expectApproxEqAbs(trigger.y + trigger.h + 8, bounds.y, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 12), 1440 - bounds.x - bounds.w, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 85), p.list.container.globalRect().y - bounds.y, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 60), p.list.container.globalRect().h, 0.01);
    try std.testing.expect(p.foot.style.display == .none);
    try std.testing.expect(text(p.head, "全局传输管理器") != null);
    try std.testing.expect(text(p.head, "本会话传输") == null);
    try std.testing.expect(p.scope_row.style.display == .none);
    try std.testing.expect(p.counts_row.style.display == .none);
    try std.testing.expectEqual(@as(usize, 1), p.counts.active);
    try std.testing.expectEqual(capture.owner, p.source.?.value.rows[0].target.owner.?);
    try std.testing.expect(id(p.root, "transfer.window.minimize") == null);
    try std.testing.expect(id(p.root, "transfer.window.zoom") == null);
    try std.testing.expect(id(p.root, "transfer.open.all") != null);
    h.cx.setViewport(860, 480);
    theme.select(.light);
    _ = theme.setMaterialVisible(true);
    h.cx.setTheme(theme.widgetTheme(.light));
    p.retheme();
    h.frames();
    const compact = p.root.globalRect();
    const compact_trigger = anchor.globalRect();
    try std.testing.expect(compact.x >= 8);
    try std.testing.expect(compact.x + compact.w <= 852);
    try std.testing.expect(compact.y >= compact_trigger.y + compact_trigger.h + 8);
    try std.testing.expect(compact.y + compact.h <= 472);
    try std.testing.expect(p.list.container.globalRect().h > 0);
    try std.testing.expect(p.foot.globalRect().y + p.foot.globalRect().h <= 472);
    try std.testing.expectEqual(theme.current().overlay, p.root.getBackground());
    click(h, id(p.root, "transfer.window.close").?);
    h.frames();
    try std.testing.expect(p.root.style.display == .none);
    try std.testing.expect(capture.window == null);
    try std.testing.expectEqual(@as(usize, 0), capture.actions);
    try std.testing.expectEqual(anchor, h.cx.focused_node.?);
    try std.testing.expectEqual(before.state, manager.progress(job).?.state);
    try std.testing.expectEqual(before.attempt, manager.progress(job).?.attempt);
    try std.testing.expectEqual(@as(usize, 1), manager.count());
    p.show();
    try p.refresh(2, .{ .window_chunks = 16, .chunk_kb = 64 });
    h.frames();
    try std.testing.expect(p.root.style.display != .none);
    try std.testing.expectEqual(h.root, p.root.parent.?);
    try std.testing.expectEqual(job, p.source.?.value.rows[0].target.job);
    try std.testing.expectEqual(backend.State.running, manager.progress(job).?.state);
}
test "transfer projection theme publication repaints mounted headings and scoped buttons" {
    const saved = theme.currentName();
    const material = theme.materialVisible();
    defer {
        theme.select(saved);
        _ = theme.setMaterialVisible(material);
    }
    theme.select(.dark);
    _ = theme.setMaterialVisible(false);
    const h = try H.init(1000, 700);
    defer h.deinit();
    var c: Capture = .{};
    const p = try h.panel(&c, .window);
    try p.update(.{ .revision = 1, .rows = &.{row(1, 101, .running)}, .choices = &.{ .{ .label = "全部会话", .scope = .all }, .{ .label = "原会话", .scope = .{ .session = handle(101, 1) } } } });
    p.show();
    h.frames();
    click(h, scopeButton(p.scope_row, "原会话").?);
    h.frames();
    try std.testing.expectEqual(@as(usize, 1), p.visible.items.len);
    try std.testing.expectEqual(theme.current().action_accent, scopeButton(p.scope_row, "原会话").?.getBackground());
    theme.select(.light);
    _ = theme.setMaterialVisible(true);
    h.cx.setTheme(theme.widgetTheme(.light));
    p.retheme();
    h.frames();
    try std.testing.expectEqual(theme.current().overlay, p.root.getBackground());
    try std.testing.expectEqual(theme.current().fg_1, text(p.head, "传输任务").?.getText().?.color);
}
const ui = @import("ui");
const V = @import("ui/transfer_manager_view.zig");
const backend = @import("transfer/manager.zig");
const theme = @import("ui/app_theme.zig");
const Id = @import("host/identity.zig");
const Capture = struct {
    target: ?V.Target = null,
    action: ?V.TaskAction = null,
    window: ?V.WindowAction = null,
    calls: usize = 0,
    panel: ?*V.Panel = null,
    next: ?V.Snapshot = null,
    fn actionCall(raw: *anyopaque, target: V.Target, action: V.TaskAction) !void {
        const self: *@This() = @ptrCast(@alignCast(raw));
        self.target = target;
        self.action = action;
        self.calls += 1;
        if (self.next) |next| try self.panel.?.update(next);
    }
    fn windowCall(raw: *anyopaque, action: V.WindowAction) !void {
        const self: *@This() = @ptrCast(@alignCast(raw));
        self.window = action;
    }
};
const H = struct {
    cx: *ui.Cx,
    scope: *ui.Scope,
    root: *ui.Node,
    fn init(w: f32, h: f32) !H {
        const cx = try ui.Cx.init(std.testing.allocator, std.testing.io);
        errdefer cx.deinit();
        cx.setViewport(w, h);
        cx.setTheme(theme.widgetTheme(theme.currentName()));
        const root = try ui.box(cx, .{ .width = .fill(), .height = .fill() }, .{});
        cx.root = root;
        return .{ .cx = cx, .root = root, .scope = try ui.Scope.init(std.testing.allocator, null, cx.owner) };
    }
    fn deinit(self: H) void {
        self.scope.dispose();
        self.cx.deinit();
    }
    fn frames(self: H) void {
        for (0..4) |_| {
            self.cx.frame_count += 1;
            self.cx.frame_time_ms += 16;
            _ = self.cx.render();
        }
    }
    fn panel(self: H, c: *Capture, presentation: V.Presentation) !*V.Panel {
        const p = try V.mountProjection(self.cx, self.scope, .{ .presentation = presentation }, .{ .context = c, .action = Capture.actionCall, .window = Capture.windowCall });
        c.panel = p;
        try self.root.appendChild(self.cx.allocator, p.root);
        return p;
    }
};
fn handle(session: u64, generation: u64) Id.SessionHandle {
    return .{ .session_id = @fromBackingInt(session), .generation = generation };
}
fn row(job: u64, owner: u64, phase: V.Phase) V.Task {
    return .{ .target = .{ .job = job, .attempt = 1, .owner = handle(owner, 1) }, .direction = .upload, .name = "release.tar.gz", .owner_label = "生产 #101", .local_path = "/tmp/release.tar.gz", .remote_path = "/srv/releases/release.tar.gz", .route = "直连", .phase = phase, .total_bytes = 100, .done_bytes = 40, .options = "断点续传 开 · MD5 关", .events = "已连接\n收到 40 B ACK" };
}
fn id(node: *ui.Node, value: []const u8) ?*ui.Node {
    if (node.meta.ownership.meta.test_id) |actual| if (std.mem.eql(u8, actual, value)) return node;
    for (node.children.items) |child| if (id(child, value)) |found| return found;
    return null;
}
fn text(node: *ui.Node, value: []const u8) ?*ui.Node {
    if (node.getText()) |actual| if (std.mem.eql(u8, actual.content, value)) return node;
    for (node.children.items) |child| if (text(child, value)) |found| return found;
    return null;
}
fn textCount(node: *ui.Node) usize {
    var total: usize = if (node.getText() != null) 1 else 0;
    for (node.children.items) |child| total += textCount(child);
    return total;
}
fn count(node: *ui.Node, value: []const u8) usize {
    var result: usize = if (node.meta.ownership.meta.test_id) |actual| if (std.mem.eql(u8, actual, value)) 1 else 0 else 0;
    for (node.children.items) |child| result += count(child, value);
    return result;
}
fn click(h: H, node: *ui.Node) void {
    const r = node.globalRect();
    h.cx.handleMouseDownEx(r.x + r.w / 2, r.y + r.h / 2, .left, .{});
    h.cx.handleMouseUpEx(r.x + r.w / 2, r.y + r.h / 2, .left, .{});
}
test "transfer projection exact window and session geometry uses actual widgets" {
    var c: Capture = .{};
    const h = try H.init(1000, 700);
    defer h.deinit();
    const p = try h.panel(&c, .window);
    try p.update(.{ .revision = 1, .rows = &.{row(1, 101, .running)} });
    p.show();
    h.frames();
    try std.testing.expectApproxEqAbs(@as(f32, 840), p.root.globalRect().w, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 578), p.root.globalRect().h, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 128), p.list.container.globalRect().y - p.root.globalRect().y, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 396), p.list.container.globalRect().h, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 530), p.foot.globalRect().y - p.root.globalRect().y, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 52), id(p.root, "transfer.task").?.globalRect().h, 0.01);
    try std.testing.expectEqual(@as(@TypeOf(p.notice.parent.?.style.display), .none), p.notice.parent.?.style.display);
    try p.update(.{ .revision = 2, .rows = &.{row(1, 101, .running)}, .notice = "原会话已关闭，等待重新绑定" });
    h.frames();
    try std.testing.expectEqual(@as(@TypeOf(p.notice.parent.?.style.display), .flex), p.notice.parent.?.style.display);
    try std.testing.expectEqualStrings("原会话已关闭，等待重新绑定", p.notice.getText().?.content);
    try std.testing.expectApproxEqAbs(@as(f32, 164), p.list.container.globalRect().y - p.root.globalRect().y, 0.01);
    try p.update(.{ .revision = 3, .rows = &.{row(1, 101, .running)} });
    h.frames();
    try std.testing.expectEqual(@as(@TypeOf(p.notice.parent.?.style.display), .none), p.notice.parent.?.style.display);
    try std.testing.expectApproxEqAbs(@as(f32, 128), p.list.container.globalRect().y - p.root.globalRect().y, 0.01);
    click(h, id(p.root, "transfer.window.minimize").?);
    try std.testing.expectEqual(V.WindowAction.minimize, c.window.?);
    click(h, id(p.root, "transfer.window.close").?);
    try std.testing.expectEqual(V.WindowAction.close, c.window.?);
    try std.testing.expectEqual(@as(usize, 0), c.calls);
    const pop = try h.panel(&c, .session_popover);
    try pop.update(.{ .revision = 1, .rows = &.{row(1, 101, .running)} });
    pop.show();
    h.frames();
    try std.testing.expectApproxEqAbs(@as(f32, 344), pop.root.globalRect().w, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 168), pop.root.globalRect().h, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 60), pop.list.container.globalRect().h, 0.01);
    try std.testing.expect(id(pop.root, "transfer.window.minimize") == null);
}
test "transfer projection scope generation counts filter and copied strings remain independent" {
    const h = try H.init(1000, 700);
    defer h.deinit();
    var c: Capture = .{};
    const p = try h.panel(&c, .window);
    var rows = [_]V.Task{ row(1, 101, .running), row(2, 101, .verifying), row(3, 103, .queued), row(4, 201, .failed), row(5, 101, .cancelled) };
    rows[0].speed_bps = 2 * 1048576;
    rows[1].speed_bps = 99999999;
    const temporary = try std.testing.allocator.dupe(u8, "唯一文件.tar");
    rows[0].name = temporary;
    try p.update(.{ .revision = 1, .rows = &rows, .scope = .{ .session = handle(101, 1) }, .scope_label = "原会话 #101" });
    std.testing.allocator.free(temporary);
    rows[0].name = "不再借用原字符串";
    p.show();
    h.frames();
    try std.testing.expectEqual(@as(usize, 3), p.visible.items.len);
    try std.testing.expectEqual(@as(usize, 2), p.counts.active);
    try std.testing.expectEqual(@as(u64, 2 * 1048576), p.counts.speed_bps);
    try std.testing.expect(text(p.root, "唯一文件.tar") != null);
    p.search.set("不存在");
    p.setFilter(.failed);
    try p.flush();
    h.frames();
    try std.testing.expectEqual(@as(usize, 0), p.visible.items.len);
    try std.testing.expectEqual(@as(usize, 2), p.counts.active);
    try std.testing.expect(text(p.root, "没有符合筛选的任务") != null);
    p.search.set("");
    p.setFilter(.all);
    try p.flush();
    var members = [_]Id.SessionHandle{ handle(101, 2), handle(103, 1) };
    try p.update(.{ .revision = 2, .rows = &rows, .scope = .{ .sessions = .{ .members = &members, .revision = 7 } }, .scope_label = "组任务" });
    members[1] = handle(201, 1);
    try std.testing.expectEqual(@as(usize, 1), p.visible.items.len);
    try std.testing.expectEqual(@as(usize, 2), p.visible.items[0]);
}
test "transfer projection real pointer action freezes job attempt owner and defers replacement" {
    const h = try H.init(1000, 700);
    defer h.deinit();
    var c: Capture = .{};
    const p = try h.panel(&c, .window);
    const first = row(1, 101, .running);
    try p.update(.{ .revision = 1, .rows = &.{first} });
    p.show();
    h.frames();
    c.next = .{ .revision = 2, .rows = &.{row(2, 103, .running)} };
    click(h, id(p.root, "transfer.task.primary").?);
    try std.testing.expectEqual(first.target, c.target.?);
    try std.testing.expectEqual(V.TaskAction.pause, c.action.?);
    try std.testing.expect(p.pending_source != null);
    h.frames();
    try std.testing.expectEqual(@as(u64, 2), p.revision);
    try std.testing.expectError(error.StaleTask, p.perform(first.target, .cancel));
    var stale = row(2, 103, .running).target;
    stale.attempt = 9;
    try std.testing.expectError(error.StaleTask, p.perform(stale, .pause));
    try std.testing.expectEqual(@as(usize, 1), c.calls);
}
test "transfer projection details events are readonly and terminal actions never revive cancelled job" {
    const h = try H.init(1000, 700);
    defer h.deinit();
    var c: Capture = .{};
    const p = try h.panel(&c, .window);
    const cancelled = row(1, 101, .cancelled);
    try p.update(.{ .revision = 1, .rows = &.{cancelled} });
    p.show();
    h.frames();
    try std.testing.expect(!V.allows(.cancelled, .retry) and !V.allows(.cancelled, .resume_transfer));
    try std.testing.expect(!V.allows(.verifying, .retry) and !V.allows(.verifying, .reveal));
    click(h, id(p.root, "transfer.task.expand").?);
    h.frames();
    try std.testing.expectApproxEqAbs(@as(f32, 207), p.virtual.totalContentHeight(), 0.1);
    try std.testing.expect(text(p.root, "本地  /tmp/release.tar.gz") != null);
    click(h, id(p.root, "transfer.task.events").?);
    h.frames();
    try std.testing.expectEqual(@as(usize, 0), c.calls);
    try std.testing.expectEqualStrings(cancelled.events, p.event_view.?.snapshot);
    try std.testing.expect(text(h.root, "已连接") != null);
    try std.testing.expect(text(h.root, "收到 40 B ACK") != null);
    try std.testing.expectApproxEqAbs(@as(f32, 520), p.event_view.?.dialog.globalRect().w, 0.1);
    // Figma 321:878950 uses 20px event rows, 8px gaps, and 58px chrome.
    const events = p.event_view.?;
    const viewport = id(h.root, "transfer.events.viewport").?;
    try std.testing.expectApproxEqAbs(@as(f32, 106), events.dialog.globalRect().h, 0.1);
    try std.testing.expectApproxEqAbs(@as(f32, 48), viewport.globalRect().h, 0.1);
    try std.testing.expectApproxEqAbs(@as(f32, 46), viewport.globalRect().y - events.dialog.globalRect().y, 0.1);
    const reference_events = "14:20:01 入队 · job1042 · session101\n14:20:02 SSH传输连接就绪\n14:20:02 开始上传 /srv/releases/release.tar.gz\n14:20:08 已传81.9MiB / 128MiB · 64%";
    try events.show(1042, reference_events);
    h.frames();
    try std.testing.expectEqualStrings(reference_events, events.snapshot);
    try std.testing.expectApproxEqAbs(@as(f32, 162), events.dialog.globalRect().h, 0.1);
    try std.testing.expectApproxEqAbs(@as(f32, 104), viewport.globalRect().h, 0.1);
    try std.testing.expectApproxEqAbs(@as(f32, 496), viewport.globalRect().w, 0.1);
    try std.testing.expectEqual(@as(usize, 4), events.entries.children.items.len);
    for (events.entries.children.items, 0..) |entry, i| {
        try std.testing.expectApproxEqAbs(@as(f32, 20), entry.globalRect().h, 0.1);
        try std.testing.expectApproxEqAbs(@as(f32, @floatFromInt(i * 28)), entry.globalRect().y - events.entries.globalRect().y, 0.1);
    }
    const many_events = "入队\n连接\n开始\n进度1\n进度2\n进度3\n进度4\n进度5\n进度6\n进度7\n进度8\n进度9\n完成";
    try events.show(cancelled.target.job, many_events);
    h.frames();
    try std.testing.expectEqualStrings(many_events, events.snapshot);
    try std.testing.expectEqual(@as(usize, 13), events.entries.children.items.len);
    try std.testing.expect(text(events.entries, "完成") != null);
    try std.testing.expectApproxEqAbs(@as(f32, 242), events.dialog.globalRect().h, 0.1);
    try std.testing.expectApproxEqAbs(@as(f32, 184), viewport.globalRect().h, 0.1);
    try std.testing.expect(events.entries.globalRect().h > viewport.globalRect().h);
    try events.show(cancelled.target.job, "");
    h.frames();
    try std.testing.expectEqualStrings("", events.snapshot);
    try std.testing.expect(text(h.root, "暂无任务事件") != null);
    try std.testing.expectApproxEqAbs(@as(f32, 78), events.dialog.globalRect().h, 0.1);
    try std.testing.expectApproxEqAbs(@as(f32, 20), viewport.globalRect().h, 0.1);
    try std.testing.expectEqual(@as(usize, 0), c.calls);
    click(h, id(h.root, "transfer.events.dismiss").?);
    h.frames();
    try std.testing.expect(!p.event_view.?.open.peek());
    click(h, id(p.root, "transfer.task.primary").?);
    try std.testing.expectEqual(V.TaskAction.new_draft, c.action.?);
}
test "transfer projection unknown owner disabled scope selection removed and many rows virtualized" {
    const h = try H.init(1000, 700);
    defer h.deinit();
    var c: Capture = .{};
    const p = try h.panel(&c, .window);
    var rows: [500]V.Task = undefined;
    for (&rows, 0..) |*r, i| r.* = row(@intCast(i + 1), 101, .running);
    rows[0].target.owner = null;
    try p.update(.{ .revision = 1, .rows = &rows });
    p.show();
    h.frames();
    try std.testing.expect(count(p.root, "transfer.task") < 20);
    click(h, id(p.root, "transfer.task.primary").?);
    try std.testing.expectEqual(@as(usize, 0), c.calls);
    try std.testing.expectError(error.UnknownOwner, p.perform(rows[0].target, .pause));
    try p.selection.append(h.cx.allocator, rows[1].target);
    try p.update(.{ .revision = 2, .rows = &rows, .scope = .{ .session = handle(201, 1) } });
    try std.testing.expectEqual(@as(usize, 0), p.selection.items.len);
    try std.testing.expectEqual(@as(usize, 0), p.visible.items.len);
}
test "transfer projection actual palettes material remain applied and short popover stays reachable" {
    const original = theme.currentName();
    const material = theme.materialVisible();
    defer {
        theme.select(original);
        _ = theme.setMaterialVisible(material);
    }
    for ([_]theme.Name{ .dark, .light, .sauber }) |name| {
        theme.select(name);
        _ = theme.setMaterialVisible(true);
        const h = try H.init(430, 220);
        defer h.deinit();
        var c: Capture = .{};
        const p = try h.panel(&c, .session_popover);
        try p.update(.{ .revision = 1, .rows = &.{row(1, 101, .running)} });
        p.show();
        h.frames();
        const rect = p.root.globalRect();
        try std.testing.expect(rect.x >= 7.9 and rect.y >= 7.9 and rect.x + rect.w <= 422.1 and rect.y + rect.h <= 212.1);
        try std.testing.expectEqual(theme.current().overlay, p.root.getBackground());
        try std.testing.expect(p.foot.globalRect().y + p.foot.globalRect().h <= rect.y + rect.h);
    }
}
const Engine = struct {
    fn open(_: *anyopaque, _: backend.JobSpec) !u64 {
        return 9;
    }
    fn cancel(_: *anyopaque, _: u64) void {}
    fn poll(_: *anyopaque) ?backend.EngineProgress {
        return null;
    }
};
const Legacy = struct {
    calls: usize = 0,
    event: ?backend.EngineProgress = null,
    fn action(raw: *anyopaque, _: u64, _: V.Action) void {
        const self: *@This() = @ptrCast(@alignCast(raw));
        self.calls += 1;
    }
};
test "transfer projection legacy real Manager rejects changed attempt and retains compatibility" {
    const h = try H.init(1000, 700);
    defer h.deinit();
    var c: Legacy = .{};
    const RetryEngine = struct {
        fn poll(raw: *anyopaque) ?backend.EngineProgress {
            const context: *Legacy = @ptrCast(@alignCast(raw));
            const event = context.event;
            context.event = null;
            return event;
        }
    };
    var manager = try backend.Manager.init(std.testing.allocator, .{ .ctx = &c, .open = Engine.open, .cancel = Engine.cancel, .poll = RetryEngine.poll }, 1, .{});
    defer manager.deinit();
    const job = try manager.enqueue(.{ .session_id = 101, .direction = .upload, .sources = &.{"/tmp/a"}, .remote_dir = "/srv", .local_dir = "/tmp" });
    manager.tick(0);
    const p = try V.mount(h.cx, h.scope, &manager, .{ .context = &c, .action = Legacy.action });
    try h.root.appendChild(h.cx.allocator, p.root);
    try p.refresh(1, .{ .window_chunks = 16, .chunk_kb = 64 });
    p.show();
    h.frames();
    const target = p.source.?.value.rows[0].target;
    try p.perform(target, .pause);
    try std.testing.expectEqual(@as(usize, 1), c.calls);
    c.event = .{ .job = 9, .done_bytes = 0, .total_bytes = 1, .state = .failed, .failure = .io, .job_cleanup = .released };
    manager.tick(2);
    try manager.retry(job);
    manager.tick(3);
    try std.testing.expectError(error.StaleAttempt, p.perform(target, .pause));
    p.hide();
    try std.testing.expectEqual(backend.State.running, manager.progress(job).?.state);
}

test "transfer projection native paused artifact cannot be resumed or replaced from its enabled-looking action" {
    const h = try H.init(1000, 700);
    defer h.deinit();
    var c: Legacy = .{};
    const PausedEngine = struct {
        fn pause(_: *anyopaque, _: u64) !void {}
        fn poll(raw: *anyopaque) ?backend.EngineProgress {
            const context: *Legacy = @ptrCast(@alignCast(raw));
            const event = context.event;
            context.event = null;
            return event;
        }
    };
    var manager = try backend.Manager.init(std.testing.allocator, .{ .ctx = &c, .open = Engine.open, .pause = PausedEngine.pause, .cancel = Engine.cancel, .poll = PausedEngine.poll }, 1, .{});
    defer manager.deinit();
    const job = try manager.enqueue(.{ .session_id = 101, .direction = .download, .sources = &.{"/srv/a"}, .remote_dir = "/srv", .local_dir = "/tmp" });
    manager.tick(0);
    try manager.pause(job);
    c.event = .{ .job = 9, .done_bytes = 0, .total_bytes = 1, .state = .paused, .job_cleanup = .released };
    manager.tick(1);
    const panel = try V.mount(h.cx, h.scope, &manager, .{ .context = &c, .action = Legacy.action });
    try h.root.appendChild(h.cx.allocator, panel.root);
    try panel.refresh(2, .{ .window_chunks = 16, .chunk_kb = 64 });
    panel.show();
    h.frames();
    const target = panel.source.?.value.rows[0].target;
    try std.testing.expect(text(panel.root, "数据已保留") != null);
    try std.testing.expectError(error.ActionUnavailable, panel.perform(target, .resume_transfer));
    click(h, id(panel.root, "transfer.task.primary").?);
    h.frames();
    try std.testing.expectEqual(@as(usize, 0), c.calls);
    try std.testing.expectEqual(backend.State.paused, manager.progress(job).?.state);
    try std.testing.expectEqual(@as(u8, 1), manager.progress(job).?.attempt);
}

test "transfer projection resumes only the original native paused task when its backend advertises capability" {
    const h = try H.init(1000, 700);
    defer h.deinit();
    const ResumeEngine = struct {
        manager: ?*backend.Manager = null,
        event: ?backend.EngineProgress = null,
        resumes: usize = 0,
        capable: bool = true,
        fn open(_: *anyopaque, _: backend.JobSpec) !u64 {
            return 9;
        }
        fn pause(_: *anyopaque, _: u64) !void {}
        fn cancel(_: *anyopaque, _: u64) void {}
        fn canResume(raw: *anyopaque, original: u64) bool {
            const self: *@This() = @ptrCast(@alignCast(raw));
            return self.capable and original == 9;
        }
        fn resumeJob(raw: *anyopaque, original: u64) !u64 {
            const self: *@This() = @ptrCast(@alignCast(raw));
            try std.testing.expectEqual(@as(u64, 9), original);
            self.resumes += 1;
            return 10;
        }
        fn poll(raw: *anyopaque) ?backend.EngineProgress {
            const self: *@This() = @ptrCast(@alignCast(raw));
            const event = self.event;
            self.event = null;
            return event;
        }
        fn action(raw: *anyopaque, job: u64, value: V.Action) void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            if (value == .resume_transfer) self.manager.?.resumeJob(job) catch unreachable;
        }
    };
    var c: ResumeEngine = .{};
    var manager = try backend.Manager.init(std.testing.allocator, .{ .ctx = &c, .open = ResumeEngine.open, .pause = ResumeEngine.pause, .cancel = ResumeEngine.cancel, .resume_job = ResumeEngine.resumeJob, .can_resume = ResumeEngine.canResume, .poll = ResumeEngine.poll }, 1, .{});
    defer manager.deinit();
    c.manager = &manager;
    const job = try manager.enqueue(.{ .session_id = 101, .direction = .download, .sources = &.{"/srv/original"}, .remote_dir = "/srv", .local_dir = "/tmp" });
    manager.tick(0);
    try manager.pause(job);
    c.event = .{ .job = 9, .done_bytes = 1, .total_bytes = 4, .state = .paused, .job_cleanup = .released };
    manager.tick(1);
    const panel = try V.mount(h.cx, h.scope, &manager, .{ .context = &c, .action = ResumeEngine.action });
    try h.root.appendChild(h.cx.allocator, panel.root);
    try panel.refresh(2, .{ .window_chunks = 16, .chunk_kb = 64 });
    panel.show();
    h.frames();
    try std.testing.expect(text(panel.root, "等待继续") != null);
    // Capability is a real projection fact even when phase/progress stay paused.
    c.capable = false;
    try panel.refresh(250, .{ .window_chunks = 16, .chunk_kb = 64 });
    h.frames();
    try std.testing.expect(text(panel.root, "数据已保留") != null);
    click(h, id(panel.root, "transfer.task.primary").?);
    h.frames();
    try std.testing.expectEqual(backend.State.paused, manager.progress(job).?.state);
    try std.testing.expectEqual(@as(usize, 0), c.resumes);
    c.capable = true;
    try panel.refresh(500, .{ .window_chunks = 16, .chunk_kb = 64 });
    h.frames();
    try std.testing.expect(text(panel.root, "等待继续") != null);
    click(h, id(panel.root, "transfer.task.primary").?);
    h.frames();
    try std.testing.expectEqual(backend.State.queued, manager.progress(job).?.state);
    try std.testing.expectEqual(@as(usize, 0), c.resumes);
    manager.tick(3);
    try std.testing.expectEqual(@as(usize, 1), c.resumes);
    try std.testing.expectEqual(@as(usize, 1), manager.count());
    try std.testing.expectEqual(backend.State.running, manager.progress(job).?.state);
    try std.testing.expectEqual(@as(u8, 2), manager.progress(job).?.attempt);
    c.event = .{ .job = 10, .done_bytes = 1, .total_bytes = 4, .state = .paused, .failure = .conflict, .job_cleanup = .released };
    manager.tick(4);
    try panel.refresh(5, .{ .window_chunks = 16, .chunk_kb = 64 });
    h.frames();
    try std.testing.expect(text(panel.root, "文件冲突或内容已变化") != null);
    try std.testing.expectEqual(backend.State.paused, manager.progress(job).?.state);
    try std.testing.expectEqual(@as(usize, 1), manager.count());
}

test "transfer projection unchanged Manager refresh keeps task nodes focus and user state" {
    const h = try H.init(1440, 900);
    defer h.deinit();
    var c: Legacy = .{};
    const Completed = struct {
        fn poll(raw: *anyopaque) ?backend.EngineProgress {
            const context: *Legacy = @ptrCast(@alignCast(raw));
            const event = context.event;
            context.event = null;
            return event;
        }
    };
    var manager = try backend.Manager.init(std.testing.allocator, .{ .ctx = &c, .open = Engine.open, .cancel = Engine.cancel, .poll = Completed.poll }, 1, .{});
    defer manager.deinit();
    _ = try manager.enqueue(.{ .session_id = 101, .direction = .download, .sources = &.{"/srv/release.tar.gz"}, .remote_dir = "/srv", .local_dir = "/tmp" });
    manager.tick(0);
    c.event = .{ .job = 9, .done_bytes = 579, .total_bytes = 579, .state = .succeeded, .job_cleanup = .released };
    manager.tick(1);
    const p = try V.mountWindow(h.cx, h.scope, &manager, .{ .context = &c, .action = Legacy.action });
    try h.root.appendChild(h.cx.allocator, p.root);
    try p.refresh(2, .{ .window_chunks = 16, .chunk_kb = 64 });
    p.show();
    h.frames();
    click(h, id(p.root, "transfer.task.expand").?);
    h.frames();
    click(h, id(p.root, "transfer.task.select").?);
    h.frames();
    try std.testing.expectEqual(@as(usize, 1), p.selection.items.len);
    const expanded = p.expanded.?;
    const task_id = id(p.root, "transfer.task").?.id;
    const era = p.virtual.a11y_generation;
    const focus_node = id(p.root, "transfer.task.more").?;
    const focus_id = focus_node.id;
    h.cx.setFocus(focus_node);
    for (0..8) |i| {
        try p.refresh(250 * (i + 1), .{ .window_chunks = 16, .chunk_kb = 64 });
        h.frames();
        try std.testing.expectEqual(era, p.virtual.a11y_generation);
        try std.testing.expectEqual(task_id, id(p.root, "transfer.task").?.id);
        try std.testing.expectEqual(focus_id, h.cx.focused_node.?.id);
        try std.testing.expectEqual(expanded, p.expanded.?);
        try std.testing.expectEqual(@as(usize, 1), p.selection.items.len);
    }
    // An unchanged backend must not swallow local dirty filter/search state.
    p.setFilter(.active);
    try p.refresh(2250, .{ .window_chunks = 16, .chunk_kb = 64 });
    h.frames();
    try std.testing.expectEqual(@as(usize, 0), p.visible.items.len);
    p.setFilter(.all);
    try p.refresh(2500, .{ .window_chunks = 16, .chunk_kb = 64 });
    h.frames();
    try std.testing.expectEqual(@as(usize, 1), p.visible.items.len);
    click(h, id(p.root, "transfer.search.toggle").?);
    h.frames();
    click(h, p.search_node);
    h.cx.handleTextInput("no-matching-task");
    try p.refresh(2750, .{ .window_chunks = 16, .chunk_kb = 64 });
    h.frames();
    try std.testing.expectEqual(@as(usize, 0), p.visible.items.len);
    h.cx.handleKeyDown(.a, .{ .super = true });
    h.cx.handleTextInput("release");
    try p.refresh(3000, .{ .window_chunks = 16, .chunk_kb = 64 });
    h.frames();
    try std.testing.expectEqual(@as(usize, 1), p.visible.items.len);
}

test "transfer projection changed after layout binds rows in the submitted frame and keeps scroll" {
    const h = try H.init(1440, 900);
    defer h.deinit();
    var c: Capture = .{};
    const p = try h.panel(&c, .global_popover);
    var rows: [80]V.Task = undefined;
    for (&rows, 0..) |*task, i| task.* = row(i + 1, 101, .running);
    try p.update(.{ .revision = 1, .rows = &rows });
    p.show();
    h.frames();
    ui.widgets.scroll_area.setScrollY(p.list.state, p.list.content, 520);
    h.frames();
    const before_scroll = p.list.state.scroll_y;
    try std.testing.expect(before_scroll > 400);
    const Change = struct {
        panel: *V.Panel,
        rows: *[80]V.Task,
        mounted_row: usize,
        fired: bool = false,
        rows_after_refresh: usize = 0,
        scroll_after_refresh: f32 = 0,
        fn run(raw: *anyopaque, _: u8, _: bool) ui.AfterLayoutResult {
            const self: *@This() = @ptrCast(@alignCast(raw));
            if (self.fired) return .done;
            self.fired = true;
            self.rows[self.mounted_row].done_bytes = 41;
            self.rows[self.mounted_row].name = "updated-progress.tar.gz";
            self.panel.update(.{ .revision = 2, .rows = self.rows }) catch unreachable;
            self.rows_after_refresh = count(self.panel.root, "transfer.task");
            self.scroll_after_refresh = self.panel.list.state.scroll_y;
            return .needs_layout;
        }
    };
    // Choose a row bound by the actual virtual list after scrolling. Its
    // position changes with card pitch and viewport; index 74 was incidental.
    const mounted_row = for (p.virtual.pool_bindings) |binding| {
        if (binding) |visible_index| break p.visible.items[visible_index];
    } else return error.NoMountedTransferRow;
    var change: Change = .{ .panel = p, .rows = &rows, .mounted_row = mounted_row };
    try h.cx.addAfterLayoutHook(&change, Change.run);
    defer h.cx.removeAfterLayoutHook(&change);
    h.cx.requestRedraw();
    h.frames();
    try std.testing.expect(change.fired);
    try std.testing.expect(change.rows_after_refresh > 0);
    try std.testing.expectApproxEqAbs(before_scroll, change.scroll_after_refresh, 0.01);
    try std.testing.expectApproxEqAbs(before_scroll, p.list.state.scroll_y, 0.01);
    try std.testing.expect(text(p.root, "updated-progress.tar.gz") != null);
}

test "transfer projection confirmed bytes stay verifying until checksum and publication receipts" {
    const Verify = struct {
        event: ?backend.EngineProgress = null,
        fn poll(raw: *anyopaque) ?backend.EngineProgress {
            const self: *@This() = @ptrCast(@alignCast(raw));
            const event = self.event;
            self.event = null;
            return event;
        }
        fn action(_: *anyopaque, _: u64, _: V.Action) void {}
    };
    const h = try H.init(840, 578);
    defer h.deinit();
    var verify: Verify = .{};
    var manager = try backend.Manager.init(std.testing.allocator, .{ .ctx = &verify, .open = Engine.open, .cancel = Engine.cancel, .poll = Verify.poll }, 1, .{});
    defer manager.deinit();
    _ = try manager.enqueue(.{ .session_id = 101, .direction = .download, .sources = &.{"/srv/verified.bin"}, .remote_dir = "/srv", .local_dir = "/tmp", .md5_check = true });
    manager.tick(0);
    const panel = try V.mount(h.cx, h.scope, &manager, .{ .context = &verify, .action = Verify.action });
    try h.root.appendChild(h.cx.allocator, panel.root);
    for ([_]backend.Verification{ .{ .state = .pending }, .{ .state = .reading }, .{ .state = .repairing, .repair_count = 1 }, .{ .state = .passed } }) |stage| {
        verify.event = .{ .job = 9, .done_bytes = 40000, .total_bytes = 40000, .state = .running, .verification = stage };
        manager.tick(1);
        try panel.refresh(1, .{ .window_chunks = 16, .chunk_kb = 64 });
        h.frames();
        try std.testing.expectEqual(V.Phase.verifying, panel.source.?.value.rows[0].phase);
        try std.testing.expect(id(panel.root, "transfer.task.primary") == null);
    }
    verify.event = .{ .job = 9, .done_bytes = 40000, .total_bytes = 40000, .state = .succeeded, .job_cleanup = .released, .verification = .{ .state = .passed } };
    manager.tick(2);
    try panel.refresh(2, .{ .window_chunks = 16, .chunk_kb = 64 });
    h.frames();
    try std.testing.expectEqual(V.Phase.succeeded, panel.source.?.value.rows[0].phase);
}

// Deterministic read-only peer: the production engine owns local temporary
// files, fingerprints, MD5 and pause/resume. Gates only hold real IO boundaries.
const Md5PhasePeer = struct {
    const Sftp = @import("transfer/sftp_engine.zig");
    const Ssh = @import("proto/ssh/session.zig");
    const OpenRead = @FieldType(@FieldType(Sftp.SftpEngine, "remote_files"), "open_read");
    const Purpose = @typeInfo(@typeInfo(OpenRead).pointer.child).@"fn".param_types[3].?;
    const file_size = 65536 + 733;
    caller: std.Thread.Id,
    offset: usize = 0,
    file_index: usize = 0,
    purpose: Purpose = .fingerprint,
    active: bool = false,
    transfer_wait: [2]std.atomic.Value(bool) = .{ .init(false), .init(false) },
    transfer_release: [2]std.atomic.Value(bool) = .{ .init(false), .init(false) },
    checksum_wait: [2]std.atomic.Value(bool) = .{ .init(false), .init(false) },
    checksum_release: [2]std.atomic.Value(bool) = .{ .init(false), .init(false) },
    fn of(raw: ?*anyopaque) *Md5PhasePeer {
        const self: *@This() = @ptrCast(@alignCast(raw.?));
        std.debug.assert(self.caller != std.Thread.getCurrentId());
        return self;
    }
    fn wait(flag: *std.atomic.Value(bool)) !void {
        const clock = @import("platform/realtime.zig");
        const deadline = clock.monotonicNs() + 10 * std.time.ns_per_s;
        while (!flag.load(.acquire)) {
            if (clock.monotonicNs() >= deadline) return error.Md5PhaseGateTimeout;
            var unused: [1]std.c.pollfd = undefined;
            _ = std.c.poll(&unused, 0, 1);
        }
    }
    fn attributes() Ssh.SftpAttributes {
        return .{ .kind = .file, .size = file_size, .modified_at = 1_700_000_000 };
    }
    fn size(raw: ?*anyopaque, _: *Ssh.Session, _: [:0]const u8) !u64 {
        _ = of(raw);
        return file_size;
    }
    fn stat(raw: ?*anyopaque, _: *Ssh.Session, _: [:0]const u8) !Ssh.SftpAttributes {
        _ = of(raw);
        return attributes();
    }
    fn openRead(raw: ?*anyopaque, _: *Ssh.Session, path: [:0]const u8, purpose: Purpose) !Ssh.SftpHandle {
        const self = of(raw);
        std.debug.assert(!self.active);
        const name = std.fs.path.basename(path);
        std.debug.assert(std.mem.eql(u8, name, "a") or std.mem.eql(u8, name, "b"));
        self.file_index = if (name[0] == 'a') 0 else 1;
        self.offset = 0;
        self.purpose = purpose;
        self.active = true;
        return .{ .handle = @ptrCast(self) };
    }
    fn statHandle(raw: ?*anyopaque, _: *Ssh.Session, _: *Ssh.SftpHandle) !Ssh.SftpAttributes {
        std.debug.assert(of(raw).active);
        return attributes();
    }
    fn read(raw: ?*anyopaque, _: *Ssh.SftpHandle, buffer: []u8) !usize {
        const self = of(raw);
        const index = self.file_index;
        if (self.purpose == .transfer and self.offset > 0 and !self.transfer_release[index].load(.acquire)) {
            self.transfer_wait[index].store(true, .release);
            try wait(&self.transfer_release[index]);
        }
        if (self.purpose == .checksum and !self.checksum_release[index].load(.acquire)) {
            self.checksum_wait[index].store(true, .release);
            try wait(&self.checksum_release[index]);
        }
        const length = @min(@min(buffer.len, 4093), file_size - self.offset);
        for (buffer[0..length], self.offset..) |*byte, offset| byte.* = @intCast(33 + offset % 89);
        self.offset += length;
        return length;
    }
    fn close(raw: ?*anyopaque, _: *Ssh.SftpHandle) Ssh.SftpCloseResult {
        const self = of(raw);
        std.debug.assert(self.active);
        self.active = false;
        return .{ .consumed = true, .receipt = .released };
    }
    fn release(raw: ?*anyopaque, _: *Ssh.Session) Ssh.ReleaseReceipt {
        _ = of(raw);
        return .released;
    }
    fn unblock(self: *Md5PhasePeer) void {
        for (0..2) |index| {
            self.transfer_release[index].store(true, .release);
            self.checksum_release[index].store(true, .release);
        }
    }
};

test "transfer projection MD5 phase comes from the real engine and remains pausable between verified sources" {
    const Sftp = @import("transfer/sftp_engine.zig");
    const Ssh = @import("proto/ssh/session.zig");
    const Actions = struct {
        manager: *backend.Manager,
        calls: usize = 0,
        fn owner(_: *anyopaque, _: u64) ?Id.SessionHandle {
            return handle(101, 9);
        }
        fn action(raw: *anyopaque, job: u64, action_: V.Action) void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            std.debug.assert(action_ == .pause);
            self.manager.pause(job) catch unreachable;
            self.calls += 1;
        }
    };
    const h = try H.init(840, 578);
    defer h.deinit();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const directory = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(directory);
    var peer: Md5PhasePeer = .{ .caller = std.Thread.getCurrentId() };
    const engine = try Sftp.SftpEngine.init(std.testing.allocator);
    defer {
        peer.unblock();
        engine.deinit();
    }
    var session: Ssh.Session = .{};
    engine.attachSession(&session);
    engine.remote_metadata = .{ .context = &peer, .size = Md5PhasePeer.size, .stat = Md5PhasePeer.stat };
    engine.remote_files = .{ .context = &peer, .open_read = Md5PhasePeer.openRead, .stat_handle = Md5PhasePeer.statHandle, .read = Md5PhasePeer.read, .close = Md5PhasePeer.close, .release = Md5PhasePeer.release };
    var manager = try backend.Manager.init(std.testing.allocator, engine.engine(), 1, .{ .max_attempts = 1 });
    defer manager.deinit();
    const job = try manager.enqueue(.{ .session_id = 101, .direction = .download, .sources = &.{ "a", "b" }, .remote_dir = "/readonly", .local_dir = directory, .md5_check = true });
    manager.tick(0);
    var actions: Actions = .{ .manager = &manager };
    const panel = try V.mount(h.cx, h.scope, &manager, .{ .context = &actions, .action = Actions.action, .owner = Actions.owner });
    try h.root.appendChild(h.cx.allocator, panel.root);
    panel.show();
    try Md5PhasePeer.wait(&peer.transfer_wait[0]);
    manager.tick(1);
    try panel.refresh(1, .{ .window_chunks = 16, .chunk_kb = 64 });
    h.frames();
    try std.testing.expect(manager.progress(job).?.done_bytes > 0);
    try std.testing.expect(manager.progress(job).?.verification == null);
    try std.testing.expectEqual(V.Phase.running, panel.source.?.value.rows[0].phase);
    const primary = id(panel.root, "transfer.task.primary").?;
    try std.testing.expectEqualStrings("暂停", primary.behavior.interaction.a11y.?.label.?);
    const bounds = primary.globalRect();
    h.cx.handleMouseDown(bounds.x + bounds.w / 2, bounds.y + bounds.h / 2, .{});
    h.cx.handleMouseUp(bounds.x + bounds.w / 2, bounds.y + bounds.h / 2);
    try std.testing.expectEqual(@as(usize, 1), actions.calls);
    peer.transfer_release[0].store(true, .release);
    try Md5PhasePeer.wait(&engine.owner_done);
    manager.tick(2);
    try std.testing.expectEqual(backend.State.paused, manager.progress(job).?.state);
    try std.testing.expect(manager.progress(job).?.verification == null);
    try manager.resumeJob(job);
    manager.tick(3);
    try Md5PhasePeer.wait(&peer.checksum_wait[0]);
    manager.tick(4);
    try panel.refresh(4, .{ .window_chunks = 16, .chunk_kb = 64 });
    h.frames();
    try std.testing.expectEqual(V.Phase.verifying, panel.source.?.value.rows[0].phase);
    try std.testing.expectEqual(.reading, manager.progress(job).?.verification.?.state);
    try std.testing.expect(id(panel.root, "transfer.task.primary") == null);
    peer.checksum_release[0].store(true, .release);
    try Md5PhasePeer.wait(&peer.transfer_wait[1]);
    manager.tick(5);
    try panel.refresh(5, .{ .window_chunks = 16, .chunk_kb = 64 });
    h.frames();
    try std.testing.expect(manager.progress(job).?.done_bytes > Md5PhasePeer.file_size);
    try std.testing.expect(manager.progress(job).?.verification == null);
    try std.testing.expectEqual(V.Phase.running, panel.source.?.value.rows[0].phase);
    try std.testing.expectEqualStrings("暂停", id(panel.root, "transfer.task.primary").?.behavior.interaction.a11y.?.label.?);
    peer.transfer_release[1].store(true, .release);
    try Md5PhasePeer.wait(&peer.checksum_wait[1]);
    manager.tick(6);
    try panel.refresh(6, .{ .window_chunks = 16, .chunk_kb = 64 });
    h.frames();
    try std.testing.expectEqual(V.Phase.verifying, panel.source.?.value.rows[0].phase);
    try std.testing.expect(id(panel.root, "transfer.task.primary") == null);
    peer.checksum_release[1].store(true, .release);
    try Md5PhasePeer.wait(&engine.owner_done);
    manager.tick(7);
    try std.testing.expectEqual(backend.State.succeeded, manager.progress(job).?.state);
    try std.testing.expectEqual(.passed, manager.progress(job).?.verification.?.state);
    try std.testing.expectEqual(@as(u8, 2), manager.progress(job).?.attempt);
}

test "transfer projection conflict waits with a decision action and skips stay distinct from bytes" {
    const ConflictCapture = struct {
        event: ?backend.EngineProgress = null,
        action_seen: ?V.Action = null,
        job_seen: ?u64 = null,
        fn poll(raw: *anyopaque) ?backend.EngineProgress {
            const self: *@This() = @ptrCast(@alignCast(raw));
            const event = self.event;
            self.event = null;
            return event;
        }
        fn action(raw: *anyopaque, job: u64, value: V.Action) void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.job_seen = job;
            self.action_seen = value;
        }
    };
    const h = try H.init(840, 578);
    defer h.deinit();
    var capture: ConflictCapture = .{};
    var manager = try backend.Manager.init(std.testing.allocator, .{ .ctx = &capture, .open = Engine.open, .cancel = Engine.cancel, .poll = ConflictCapture.poll }, 1, .{});
    defer manager.deinit();
    const job = try manager.enqueue(.{ .session_id = 101, .direction = .download, .sources = &.{"/srv/conflict.bin"}, .remote_dir = "/srv", .local_dir = "/tmp" });
    manager.tick(0);
    const panel = try V.mount(h.cx, h.scope, &manager, .{ .context = &capture, .action = ConflictCapture.action });
    try h.root.appendChild(h.cx.allocator, panel.root);
    capture.event = .{ .job = 9, .done_bytes = 0, .total_bytes = 10, .state = .running, .conflict_waiting = true, .speed_bps = 99 };
    manager.tick(1);
    try panel.refresh(1, .{ .window_chunks = 16, .chunk_kb = 64 });
    panel.show();
    h.frames();
    const pending = panel.source.?.value.rows[0];
    try std.testing.expectEqual(V.Phase.conflict, pending.phase);
    try std.testing.expectEqual(@as(u64, 0), pending.speed_bps);
    try std.testing.expectEqual(@as(usize, 1), panel.counts.waiting);
    try panel.perform(pending.target, .resolve_conflict);
    try std.testing.expectEqual(V.Action.resolve_conflict, capture.action_seen.?);
    try std.testing.expectEqual(job, capture.job_seen.?);
    capture.event = .{ .job = 9, .done_bytes = 0, .total_bytes = 10, .state = .succeeded, .skipped_bytes = 10, .skipped_files = 1, .job_cleanup = .released };
    manager.tick(2);
    try panel.refresh(2, .{ .window_chunks = 16, .chunk_kb = 64 });
    h.frames();
    try std.testing.expectEqual(V.Phase.skipped, panel.source.?.value.rows[0].phase);
    try std.testing.expectEqual(@as(u64, 0), panel.source.?.value.rows[0].done_bytes);
    try std.testing.expectEqualStrings("已跳过 1 项", panel.source.?.value.rows[0].status_detail);
}

test "transfer projection Manager receipts reach the frozen event modal without mutating or retargeting jobs" {
    const h = try H.init(926, 594);
    defer h.deinit();
    var capture: WindowLegacy = .{};
    var manager = try backend.Manager.init(std.testing.allocator, .{ .ctx = &capture, .open = Engine.open, .cancel = Engine.cancel, .poll = Engine.poll }, 1, .{});
    defer manager.deinit();
    const job = try manager.enqueue(.{ .session_id = 101, .direction = .upload, .sources = &.{"/tmp/receipt.txt"}, .remote_dir = "/srv", .local_dir = "/tmp" });
    manager.tick(0);
    const p = try V.mountWindow(h.cx, h.scope, &manager, .{ .context = &capture, .action = WindowLegacy.action, .owner = WindowLegacy.ownerCall });
    try h.root.appendChild(h.cx.allocator, p.root);
    try p.refresh(0, .{ .window_chunks = 16, .chunk_kb = 64 });
    p.show();
    h.frames();
    try std.testing.expect(std.mem.indexOf(u8, p.source.?.value.rows[0].events, "入队") != null);
    try std.testing.expect(std.mem.indexOf(u8, p.source.?.value.rows[0].events, "传输中") != null);
    click(h, id(p.root, "transfer.task.expand").?);
    h.frames();
    click(h, id(p.root, "transfer.task.events").?);
    h.frames();
    const frozen = try std.testing.allocator.dupe(u8, p.event_view.?.snapshot);
    defer std.testing.allocator.free(frozen);
    const original = manager.progress(job).?;
    try p.refresh(100, .{ .window_chunks = 16, .chunk_kb = 64 });
    h.frames();
    try std.testing.expectEqualStrings(frozen, p.event_view.?.snapshot);
    try std.testing.expectEqualDeep(original, manager.progress(job).?);
    click(h, id(h.root, "transfer.events.dismiss").?);
    h.frames();
    try std.testing.expectEqual(@as(usize, 0), capture.actions);
    try std.testing.expectEqualDeep(original, manager.progress(job).?);
    click(h, id(p.root, "transfer.window.close").?);
    h.frames();
    try std.testing.expect(p.root.style.display == .none);
}

test "transfer projection global portal Manager receipts reach the frozen event modal without mutating or retargeting jobs" {
    const saved_theme = theme.currentName();
    defer theme.select(saved_theme);
    const h = try H.init(926, 594);
    defer h.deinit();
    var capture: WindowLegacy = .{};
    var manager = try backend.Manager.init(std.testing.allocator, .{ .ctx = &capture, .open = Engine.open, .cancel = Engine.cancel, .poll = Engine.poll }, 1, .{});
    defer manager.deinit();
    const job = try manager.enqueue(.{ .session_id = 101, .direction = .upload, .sources = &.{"/tmp/receipt.txt"}, .remote_dir = "/srv", .local_dir = "/tmp" });
    manager.tick(0);
    _ = try h.cx.ensurePopoverPortalRoot();
    const shell = try ui.box(h.cx, .{ .width = .fill(), .height = .fill() }, .{});
    try h.root.appendChild(h.cx.allocator, shell);
    const p = try V.mountGlobalPopover(h.cx, h.scope, &manager, .{ .context = &capture, .action = WindowLegacy.action, .owner = WindowLegacy.ownerCall });
    try shell.appendChild(h.cx.allocator, p.root);
    try p.refresh(0, .{ .window_chunks = 16, .chunk_kb = 64 });
    p.show();
    h.frames();
    try std.testing.expect(std.mem.indexOf(u8, p.source.?.value.rows[0].events, "入队") != null);
    try std.testing.expect(std.mem.indexOf(u8, p.source.?.value.rows[0].events, "传输中") != null);
    click(h, id(p.root, "transfer.task.expand").?);
    h.frames();
    click(h, id(p.root, "transfer.task.events").?);
    h.frames();
    const frozen = try std.testing.allocator.dupe(u8, p.event_view.?.snapshot);
    defer std.testing.allocator.free(frozen);
    const original = manager.progress(job).?;
    theme.select(.light);
    h.cx.setTheme(theme.widgetTheme(.light));
    p.retheme();
    h.frames();
    try std.testing.expectEqual(theme.current().overlay, p.event_view.?.dialog.getBackground());
    try std.testing.expectEqual(theme.current().fg_1, p.event_view.?.title.getText().?.color);
    try p.refresh(100, .{ .window_chunks = 16, .chunk_kb = 64 });
    h.frames();
    try std.testing.expectEqualStrings(frozen, p.event_view.?.snapshot);
    try std.testing.expectEqualDeep(original, manager.progress(job).?);
    click(h, id(h.root, "transfer.events.dismiss").?);
    h.frames();
    try std.testing.expectEqual(@as(usize, 0), capture.actions);
    try std.testing.expectEqualDeep(original, manager.progress(job).?);
    click(h, id(p.root, "transfer.window.close").?);
    h.frames();
    try std.testing.expect(p.root.style.display == .none);
}

fn scopeButton(node: *ui.Node, label_text: []const u8) ?*ui.Node {
    if (node.meta.ownership.meta.test_id) |test_id| if (std.mem.eql(u8, test_id, "transfer.scope") and text(node, label_text) != null) return node;
    for (node.children.items) |child| if (scopeButton(child, label_text)) |found| return found;
    return null;
}

test "transfer projection Manager scopes filter original owners and survive live refresh" {
    const h = try H.init(926, 594);
    defer h.deinit();
    var capture: WindowLegacy = .{};
    var manager = try backend.Manager.init(std.testing.allocator, .{ .ctx = &capture, .open = Engine.open, .cancel = Engine.cancel, .poll = Engine.poll }, 1, .{});
    defer manager.deinit();
    for ([_]u64{ 101, 202 }) |owner| _ = try manager.enqueue(.{ .session_id = owner, .direction = .upload, .sources = &.{"/tmp/same.txt"}, .remote_dir = "/srv", .local_dir = "/tmp" });
    manager.tick(0);
    const p = try V.mountWindow(h.cx, h.scope, &manager, .{ .context = &capture, .action = WindowLegacy.action });
    try h.root.appendChild(h.cx.allocator, p.root);
    try p.refresh(0, .{ .window_chunks = 16, .chunk_kb = 64 });
    p.show();
    h.frames();
    try std.testing.expectEqual(@as(usize, 3), p.source.?.value.choices.len);
    click(h, scopeButton(p.scope_row, "会话 #101").?);
    h.frames();
    try std.testing.expectEqual(@as(usize, 1), p.visible.items.len);
    try p.refresh(500, .{ .window_chunks = 16, .chunk_kb = 64 });
    h.frames();
    try std.testing.expect(p.selected_scope == .session);
    try std.testing.expectEqual(@as(u64, 101), @backingInt(p.selected_scope.session.session_id));
    try std.testing.expectEqual(@as(usize, 1), p.visible.items.len);
    click(h, id(p.root, "transfer.open.all").?);
    h.frames();
    try std.testing.expectEqual(@as(usize, 2), p.visible.items.len);
    try std.testing.expectEqual(@as(usize, 0), capture.actions);
}

test "transfer projection V3 three filters use real phases preserve jobs and content size" {
    const h = try H.init(1440, 900);
    defer h.deinit();
    var capture: Capture = .{};
    const p = try h.panel(&capture, .global_popover);
    const rows = [_]V.Task{ row(1, 101, .queued), row(2, 101, .running), row(3, 101, .verifying), row(4, 101, .paused), row(5, 101, .succeeded), row(6, 101, .cancelled), row(7, 101, .failed) };
    try p.update(.{ .revision = 1, .rows = &rows });
    p.show();
    h.frames();
    try std.testing.expectEqual(@as(usize, 7), p.visible.items.len);
    try std.testing.expect(text(p.v3_filters.?, "全部 7") != null);
    try std.testing.expect(text(p.v3_filters.?, "进行中 3") != null);
    try std.testing.expect(text(p.v3_filters.?, "已完成 1") != null);
    try std.testing.expectApproxEqAbs(@as(f32, 322), p.list.container.globalRect().h, 0.1);
    click(h, id(p.root, "transfer.filter.active").?);
    h.frames();
    try std.testing.expectEqual(@as(usize, 3), p.visible.items.len);
    try std.testing.expectApproxEqAbs(@as(f32, 3 * 60 + 2 * 6), p.list.container.globalRect().h, 0.1);
    click(h, id(p.root, "transfer.filter.completed").?);
    h.frames();
    try std.testing.expectEqual(@as(usize, 1), p.visible.items.len);
    try std.testing.expectEqual(@as(u64, 5), p.source.?.value.rows[p.visible.items[0]].target.job);
    try std.testing.expectApproxEqAbs(@as(f32, 40), id(p.root, "transfer.task").?.globalRect().h, 0.1);
    const task_id = id(p.root, "transfer.task").?.id;
    try p.update(.{ .revision = 2, .rows = &rows });
    h.frames();
    try std.testing.expectEqual(task_id, id(p.root, "transfer.task").?.id);
    try std.testing.expectEqual(@as(usize, 0), capture.calls);
    click(h, id(p.root, "transfer.window.close").?);
    h.frames();
    try std.testing.expect(p.root.style.display == .none);
}

test "transfer projection V3 session footer dispatches only explicit original host callbacks" {
    const h = try H.init(1440, 900);
    defer h.deinit();
    const Footer = struct {
        sftp: usize = 0,
        manager: usize = 0,
        actions: usize = 0,
        fn action(raw: *anyopaque, _: u64, _: V.Action) void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.actions += 1;
        }
        fn openSftp(raw: *anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.sftp += 1;
        }
        fn openManager(raw: *anyopaque, captured: V.Scope) void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            std.debug.assert(captured == .all);
            self.manager += 1;
        }
    };
    var footer: Footer = .{};
    var manager = try backend.Manager.init(std.testing.allocator, .{ .ctx = &footer, .open = Engine.open, .cancel = Engine.cancel, .poll = Engine.poll }, 1, .{});
    defer manager.deinit();
    const p = try V.mount(h.cx, h.scope, &manager, .{ .context = &footer, .action = Footer.action, .open_sftp = Footer.openSftp, .open_manager = Footer.openManager });
    try h.root.appendChild(h.cx.allocator, p.root);
    try p.refresh(1, .{ .window_chunks = 16, .chunk_kb = 64 });
    p.show();
    h.frames();
    try std.testing.expect(text(p.foot, "打开 SFTP") != null);
    try std.testing.expect(text(p.foot, "全局传输管理") != null);
    click(h, id(p.root, "transfer.open.sftp").?);
    h.frames();
    click(h, id(p.root, "transfer.open.all").?);
    h.frames();
    try std.testing.expectEqual(@as(usize, 1), footer.sftp);
    try std.testing.expectEqual(@as(usize, 1), footer.manager);
    try std.testing.expectEqual(@as(usize, 0), footer.actions);
    try std.testing.expectEqual(@as(usize, 0), manager.count());
}

test "transfer projection V3 measured empty manager matches browser content geometry" {
    const h = try H.init(860, 480);
    defer h.deinit();
    var capture: Capture = .{};
    const p = try h.panel(&capture, .global_popover);
    try p.update(.{ .revision = 1, .rows = &.{} });
    p.show();
    h.frames();
    const panel = p.root.globalRect();
    const empty = p.empty.parent.?.parent.?.globalRect();
    const icon = id(p.root, "transfer.empty.icon").?.globalRect();
    try std.testing.expectApproxEqAbs(@as(f32, 320), panel.w, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 151), panel.h, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 294), p.head.globalRect().w, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 26), p.head.globalRect().h, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 237), p.heading_title.globalRect().w, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 294), empty.w, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 53), empty.h, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 85), empty.y - panel.y, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 24), icon.w, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 24), icon.h, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 14.5), icon.y - empty.y, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 8), p.empty.globalRect().y - empty.y, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 29), p.empty_description.?.globalRect().y - empty.y, 0.01);
    try std.testing.expect(text(p.root, "没有传输任务") != null);
    try std.testing.expect(text(p.root, "从文件工作区或 @up / @dl 开始。") != null);
    click(h, id(p.root, "transfer.window.close").?);
    h.frames();
    try std.testing.expect(p.root.style.display == .none);
}

test "transfer projection V3 measured collapsed card follows the frozen job DOM" {
    const h = try H.init(860, 480);
    defer h.deinit();
    var capture: Capture = .{};
    const p = try h.panel(&capture, .global_popover);
    try p.update(.{ .revision = 1, .rows = &.{row(1, 101, .succeeded)} });
    p.show();
    h.frames();
    const card = id(p.root, "transfer.task").?.globalRect();
    const head = id(p.root, "transfer.task.head").?.globalRect();
    const name = id(p.root, "transfer.task.name").?.globalRect();
    const track = id(p.root, "transfer.task.progress").?.globalRect();
    const meta = id(p.root, "transfer.task.meta").?.globalRect();
    const action = id(p.root, "transfer.task.primary").?.globalRect();
    try std.testing.expect(p.expanded == null);
    try std.testing.expectApproxEqAbs(@as(f32, 158), p.root.globalRect().h, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 334), card.w, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 60), card.h, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 314), head.w, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 24), head.h, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 16), name.h, 0.01);
    try std.testing.expect(name.w >= 100);
    try std.testing.expectApproxEqAbs(@as(f32, 2), track.h, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 58), track.y - card.y, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 14), meta.h, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 36), meta.y - card.y, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 34), action.w, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 24), action.h, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 8), action.y - card.y, 0.01);
    try std.testing.expect(text(p.root, "查看") != null);
    try std.testing.expectEqual(@as(usize, 1), textCount(id(p.root, "transfer.filter.all").?));
    try std.testing.expectEqual(@as(usize, 1), textCount(id(p.root, "transfer.task.primary").?));
    try std.testing.expectApproxEqAbs(@as(f32, 16), text(p.root, "全部 1").?.globalRect().h, 0.01);
    click(h, id(p.root, "transfer.task.expand").?);
    h.frames();
    try std.testing.expect(p.expanded != null);
    try std.testing.expect(id(p.root, "transfer.task.events") != null);
}

test "transfer projection V3 reveal capability changes rebind the completed action" {
    const h = try H.init(860, 480);
    defer h.deinit();
    var capture: Capture = .{};
    const p = try h.panel(&capture, .global_popover);
    var completed = row(1, 101, .succeeded);
    completed.can_reveal = false;
    try p.update(.{ .revision = 1, .rows = &.{completed} });
    p.show();
    h.frames();
    try std.testing.expectError(error.ActionUnavailable, p.perform(completed.target, .reveal));
    click(h, id(p.root, "transfer.task.primary").?);
    h.frames();
    try std.testing.expectEqual(@as(usize, 0), capture.calls);
    completed.can_reveal = true;
    try p.update(.{ .revision = 2, .rows = &.{completed} });
    h.frames();
    click(h, id(p.root, "transfer.task.primary").?);
    h.frames();
    try std.testing.expectEqual(@as(usize, 1), capture.calls);
    try std.testing.expectEqual(V.TaskAction.reveal, capture.action.?);
    try std.testing.expectEqual(completed.target, capture.target.?);
    completed.can_reveal = false;
    try p.update(.{ .revision = 3, .rows = &.{completed} });
    h.frames();
    click(h, id(p.root, "transfer.task.primary").?);
    h.frames();
    try std.testing.expectEqual(@as(usize, 1), capture.calls);
}

test "transfer projection V3 all native phases keep the measured card and truthful supported controls" {
    const h = try H.init(860, 480);
    defer h.deinit();
    var capture: Capture = .{};
    for ([_]V.Presentation{ .global_popover, .session_popover, .session_tray }) |presentation| {
        const p = try h.panel(&capture, presentation);
        p.show();
        for ([_]V.Phase{ .queued, .running, .retry_wait, .pausing, .paused, .conflict, .verifying, .succeeded, .skipped, .failed, .checksum_failed, .cancelling, .cancelled, .cleanup_unknown }, 0..) |phase, i| {
            var task = row(1, 101, phase);
            if (phase == .failed or phase == .checksum_failed) task.status_detail = "目标文件没有通过校验";
            try p.update(.{ .revision = i + 1, .rows = &.{task} });
            h.frames();
            try std.testing.expect(p.expanded == null);
            try std.testing.expectApproxEqAbs(@as(f32, 40), id(p.root, "transfer.task").?.globalRect().h, 0.01);
            try std.testing.expectApproxEqAbs(@as(f32, 24), id(p.root, "transfer.task.head").?.globalRect().h, 0.01);
            try std.testing.expect(id(p.root, "transfer.task.meta").?.globalRect().w > 0);
            const filename = id(p.root, "transfer.task.name").?.globalRect();
            const location = id(p.root, "transfer.task.location").?.globalRect();
            const rate = id(p.root, "transfer.task.rate").?.globalRect();
            const status = id(p.root, "transfer.task.status").?.globalRect();
            try std.testing.expect(filename.w > 0);
            try std.testing.expect(location.w > 0);
            try std.testing.expectApproxEqAbs(filename.y + filename.h / 2, location.y + location.h / 2, 0.5);
            const rate_text = id(p.root, "transfer.task.rate").?.getText().?.content;
            const full_rate_width = ui.Cx.measureTextWidthCallback(h.cx, rate_text.ptr, rate_text.len, 10, 400, false);
            try std.testing.expect(rate.w >= full_rate_width - 0.5);
            try std.testing.expect(filename.x + filename.w <= status.x + 0.5);
            try std.testing.expect(location.x + location.w <= rate.x + 0.5);
            const card_bounds = id(p.root, "transfer.task").?.globalRect();
            if (presentation == .session_tray) {
                const viewport = p.list.container.globalRect();
                const progress = id(p.root, "transfer.task.progress").?.globalRect();
                try std.testing.expect(viewport.h >= 40);
                try std.testing.expect(card_bounds.y >= viewport.y - 0.5);
                try std.testing.expect(card_bounds.y + card_bounds.h <= viewport.y + viewport.h + 0.5);
                try std.testing.expect(progress.y + progress.h <= viewport.y + viewport.h + 0.5);
            }
            inline for (.{ "transfer.task.primary", "transfer.task.cancel" }) |action_id| {
                if (id(p.root, action_id)) |action_node| {
                    const action_bounds = action_node.globalRect();
                    try std.testing.expect(action_bounds.w > 0 and action_bounds.h == 24);
                    try std.testing.expect(action_bounds.x >= card_bounds.x and action_bounds.x + action_bounds.w <= card_bounds.x + card_bounds.w + 0.5);
                }
            }
            if (phase == .failed or phase == .checksum_failed) {
                try std.testing.expect(text(p.root, "目标文件没有通过校验") != null);
                try std.testing.expectApproxEqAbs(@as(f32, 14), id(p.root, "transfer.task.error").?.globalRect().h, 0.01);
            }
            if (phase == .cancelled or phase == .checksum_failed or phase == .cleanup_unknown) try std.testing.expect(id(p.root, "transfer.task.primary") == null);
        }
        p.hide();
    }
    try std.testing.expectEqual(@as(usize, 0), capture.calls);
}

test "transfer projection presents only mounted viewport rows matching current filter and search" {
    const h = try H.init(1440, 900);
    defer h.deinit();
    var c: Capture = .{};
    const p = try h.panel(&c, .global_popover);
    var rows: [80]V.Task = undefined;
    for (&rows, 0..) |*task, i| task.* = row(i + 1, 101, .running);
    try p.update(.{ .revision = 1, .rows = &rows });
    p.show();
    h.frames();
    try std.testing.expect(p.presents(80));
    try std.testing.expect(!p.presents(1));
    p.setFilter(.failed);
    try std.testing.expect(!p.presents(80));
    p.setFilter(.all);
    p.search.set("unmatched-file-name");
    try std.testing.expect(!p.presents(80));
    p.search.set("");
    h.frames();
    ui.widgets.scroll_area.setScrollY(p.list.state, p.list.content, 520);
    h.frames();
    try std.testing.expect(!p.presents(80));
}

test "transfer projection direction filter keeps each file card owner scoped" {
    const h = try H.init(860, 480);
    defer h.deinit();
    var capture: Capture = .{};
    const p = try h.panel(&capture, .session_tray);
    var upload = row(1, 101, .running);
    upload.direction = .upload;
    var download = row(2, 101, .running);
    download.direction = .download;
    var other = row(3, 202, .running);
    other.direction = .upload;
    p.selected_scope = .{ .session = upload.target.owner.? };
    p.setDirectionFilter(.upload);
    try p.update(.{ .revision = 1, .scope = .{ .session = upload.target.owner.? }, .rows = &.{ upload, download, other } });
    p.show();
    h.frames();
    try std.testing.expectEqual(@as(usize, 1), p.visible.items.len);
    try std.testing.expectEqual(@as(u64, 1), p.source.?.value.rows[p.visible.items[0]].target.job);
    p.setDirectionFilter(.download);
    h.frames();
    try std.testing.expectEqual(@as(usize, 1), p.visible.items.len);
    try std.testing.expectEqual(@as(u64, 2), p.source.?.value.rows[p.visible.items[0]].target.job);
}

test "transfer direction trays hide empty cards without layout and restore with tasks" {
    const h = try H.init(860, 480);
    defer h.deinit();
    var capture: Capture = .{};
    const p = try h.panel(&capture, .session_tray);
    p.setDirectionFilter(.upload);
    try p.update(.{ .revision = 1, .rows = &.{} });
    p.show();
    h.frames();
    try std.testing.expectEqual(@as(@TypeOf(p.root.style.display), .none), p.root.style.display);
    var task = row(1, 101, .running);
    task.direction = .upload;
    try p.update(.{ .revision = 2, .rows = &.{task} });
    h.frames();
    try std.testing.expectEqual(@as(@TypeOf(p.root.style.display), .flex), p.root.style.display);
    try std.testing.expect(text(p.root, "上传传输") != null);
    try std.testing.expectEqual(@as(f32, 0), p.root.style.border.width);
    try p.update(.{ .revision = 3, .rows = &.{} });
    h.frames();
    p.show();
    try std.testing.expectEqual(@as(@TypeOf(p.root.style.display), .none), p.root.style.display);
    p.setDirectionFilter(.download);
    task.direction = .download;
    try p.update(.{ .revision = 4, .rows = &.{task} });
    h.frames();
    try std.testing.expect(text(p.root, "下载传输") != null);
    try std.testing.expectEqual(@as(@TypeOf(p.root.style.display), .flex), p.root.style.display);
}
