//! Real Popover/VirtualList/Button, Cx events and disk transactions, no window.
const std = @import("std");
const ui = @import("ui");
const V = @import("ui/asset_action_view.zig");
const hosts = @import("config/hosts.zig");
const store = @import("config/store.zig");
const S = @import("ui/asset_action_styles.zig");
const theme = S.theme;
const a = std.testing.allocator;
const io = std.testing.io;
fn findButton(node: *ui.Node, label: []const u8) ?*ui.Node {
    if (node.behavior.interaction.a11y) |info| if (info.role == .button and info.label != null and std.mem.eql(u8, info.label.?, label)) return node;
    for (node.children.items) |child| if (findButton(child, label)) |found| return found;
    return null;
}
fn countButtons(node: *ui.Node) usize {
    var count: usize = if (node.behavior.interaction.a11y) |info| if (info.role == .button) 1 else 0 else 0;
    for (node.children.items) |child| count += countButtons(child);
    return count;
}
const Fixture = struct {
    tmp: std.testing.TmpDir,
    live: hosts.Registry,
    cx: *ui.Cx,
    scope: *ui.Scope,
    view: *V.View,
    submitted: usize = 0,
    closed: usize = 0,
    group_visits: usize = 0,
    session_visits: usize = 0,
    last_group: ?hosts.identity.AssetGroupId = null,
    last_owner: ?hosts.identity.AssetOwner = null,
    fail_write: bool = false,
    bad_receipt: bool = false,

    fn init(self: *Fixture) !void {
        self.* = .{ .tmp = std.testing.tmpDir(.{}), .live = undefined, .cx = try ui.Cx.init(a, io), .scope = undefined, .view = undefined };
        self.live = try hosts.Registry.parse(a,
            \\[[hosts]]
            \\name="DB-Master"; host="10.200.4.18"; user="admin"; group="PRODUCTION"
            \\auth={password="not displayed"}
        );
        _ = try self.live.addGroup("DATABASES", "blue");
        _ = try self.live.addGroup("STAGING", "green");
        try store.saveHosts(io, self.tmp.dir, "hosts.toml", self.live);
        self.live.deinit();
        self.live = try store.loadHosts(io, self.tmp.dir, a, "hosts.toml");
        self.cx.setViewport(1440, 900);
        self.cx.setTheme(theme.widgetTheme(theme.currentName()));
        self.cx.root = try ui.box(self.cx, .{ .width = .fill(), .height = .fill(), .direction = .column }, .{});
        self.scope = try ui.Scope.init(a, null, self.cx.owner);
        self.view = try V.View.mount(self.cx, self.scope, .{ .context = self, .submit = submit, .close = close, .view_group = viewGroup, .view_sessions = viewSessions });
    }
    fn deinit(self: *Fixture) void {
        self.scope.dispose();
        self.cx.deinit();
        self.live.deinit();
        self.tmp.cleanup();
    }
    fn show(self: *Fixture, mode: V.Mode) !void {
        var groups: [3]V.Group = undefined;
        for (self.live.groups, &groups) |group, *target| target.* = .{ .reference = .{ .id = group.group_id, .revision = group.revision }, .name = group.name, .host_count = group.ordered_connection_ids.len };
        const host = self.live.hosts[0];
        const group = self.live.groups[self.live.groupIndex(host.asset_group_id.?).?];
        try self.view.show(.{ .mode = mode, .owner = host.owner(), .name = host.name, .endpoint = "admin@10.200.4.18:22", .source_group = .{ .id = group.group_id, .revision = group.revision }, .source_group_name = group.name, .groups = &groups, .open_sessions = 1 });
        self.frame();
    }
    fn frame(self: *Fixture) void {
        for (0..3) |_| {
            self.cx.advanceFrameClock();
            _ = self.cx.render();
        }
    }
    fn click(self: *Fixture, node: *ui.Node) void {
        self.frame();
        const rect = node.globalRect();
        self.cx.handleMouseDown(rect.x + rect.w / 2, rect.y + rect.h / 2, .{});
        self.cx.handleMouseUp(rect.x + rect.w / 2, rect.y + rect.h / 2);
        self.frame();
    }
    fn submit(raw: *anyopaque, request: V.actions.Request) !V.actions.Result {
        const self: *Fixture = @ptrCast(@alignCast(raw));
        self.submitted += 1;
        if (self.bad_receipt) return .{ .kind = .delete, .source_owner = .{ .id = @fromBackingInt(900), .revision = 1 }, .owner = null, .previous_index = 0, .index = null, .commit = .{ .previous_revision = 1, .revision = 2, .source_hash = @splat(0) } };
        if (self.fail_write) try self.tmp.dir.writeFile(io, .{ .sub_path = "blocked", .data = "not a directory" });
        return V.actions.apply(a, io, self.tmp.dir, if (self.fail_write) "blocked/hosts.toml" else "hosts.toml", &self.live, request);
    }
    fn close(raw: *anyopaque) void {
        const self: *Fixture = @ptrCast(@alignCast(raw));
        self.closed += 1;
    }
    fn viewGroup(raw: *anyopaque, group: ?hosts.identity.AssetGroupId) void {
        const self: *Fixture = @ptrCast(@alignCast(raw));
        self.group_visits += 1;
        self.last_group = group;
    }
    fn viewSessions(raw: *anyopaque, owner: hosts.identity.AssetOwner) void {
        const self: *Fixture = @ptrCast(@alignCast(raw));
        self.session_visits += 1;
        self.last_owner = owner;
    }
    fn read(self: *Fixture) ![]u8 {
        return self.tmp.dir.readFileAlloc(io, "hosts.toml", a, .limited(store.max_config_bytes));
    }
    fn expectGeometry(self: *Fixture, step: V.Step) !void {
        self.frame();
        const rect = self.view.dialog.globalRect();
        try std.testing.expectEqual(S.width, rect.w);
        try std.testing.expectEqual(S.height(step), rect.h);
        try std.testing.expectApproxEqAbs(rect.y + rect.h - 12, self.view.footer.globalRect().y + 30, 0.01);
        try std.testing.expectEqual(@as(f32, 30), self.view.footer.globalRect().h);
        try std.testing.expectApproxEqAbs(rect.x + 12, self.view.name.globalRect().x - 32, 0.01);
    }
};

test "asset action view selected destination commits once and dismisses after a verified receipt" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    const owner = f.live.hosts[0].owner();
    const destination = f.live.groups[1].group_id;
    try f.show(.move);
    try f.expectGeometry(.move_select);
    try std.testing.expectEqual(@as(usize, 3), f.view.group_count.peek());
    try std.testing.expectEqual(@as(f32, 98), f.view.groups.globalRect().h);
    try std.testing.expectEqual(@as(usize, 0), f.submitted);
    f.click(f.view.primary);
    try std.testing.expectEqual(@as(usize, 1), f.submitted);
    try std.testing.expectEqual(V.Step.move_success, f.view.step);
    try std.testing.expect(!f.view.isVisible());
    try std.testing.expectEqual(destination, f.live.hosts[0].asset_group_id.?);
    try std.testing.expectEqual(owner.id, f.live.hosts[0].connection_id);
    try std.testing.expectEqual(owner.revision + 1, f.live.hosts[0].revision);
    try std.testing.expect(f.view.receipt != null);
    f.view.primaryAction();
    try std.testing.expectEqual(@as(usize, 1), f.submitted);
}

test "asset action view failed file write retains confirmation original owner target and retry" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    const owner = f.live.hosts[0].owner();
    const before = try f.read();
    defer a.free(before);
    try f.show(.move);
    f.click(findButton(f.view.groups, "STAGING").?);
    try std.testing.expectEqual(@as(?usize, 1), f.view.selected.peek());
    try std.testing.expectEqual(@as(usize, 0), f.submitted);
    f.fail_write = true;
    f.click(f.view.primary);
    try std.testing.expectEqual(V.Step.move_select, f.view.step);
    try std.testing.expect(f.view.failure.? == error.NotDir);
    try std.testing.expect(f.view.receipt == null);
    try std.testing.expectEqual(@as(?usize, 1), f.view.selected.peek());
    try std.testing.expectEqualStrings("目标分组  STAGING", f.view.to.getText().?.content);
    try std.testing.expectEqualStrings("NotDir", f.view.error_detail.getText().?.content);
    try std.testing.expect(!f.view.primary_disabled.peek());
    try std.testing.expectEqual(owner, f.live.hosts[0].owner());
    const unchanged = try f.read();
    defer a.free(unchanged);
    try std.testing.expectEqualStrings(before, unchanged);
    f.fail_write = false;
    f.click(f.view.primary);
    try std.testing.expectEqual(V.Step.move_success, f.view.step);
    try std.testing.expectEqualStrings("STAGING", f.view.target_name.getText().?.content);
    try std.testing.expectEqual(@as(usize, 2), f.submitted);
}

test "asset action view delete defaults focus to keep and dismisses only after a matching receipt" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    const owner = f.live.hosts[0].owner();
    var frozen = try @import("ui/session_lifecycle.zig").Snapshot(hosts.HostConfig).init(a, f.live.hosts[0]);
    defer frozen.deinit();
    try f.show(.delete);
    try f.expectGeometry(.delete_confirm);
    try std.testing.expectEqualStrings("保留主机", f.view.secondary_label.getText().?.content);
    try std.testing.expect(f.cx.focus_manager.getFocused() == f.view.secondary);
    f.bad_receipt = true;
    f.click(f.view.primary);
    try std.testing.expectEqual(V.Step.delete_confirm, f.view.step);
    try std.testing.expect(f.view.failure.? == error.CommitReceiptMismatch);
    try std.testing.expectEqual(owner, f.live.hosts[0].owner());
    try std.testing.expect(f.view.primary_disabled.peek());
    f.view.hide();
    try f.show(.delete);
    f.bad_receipt = false;
    f.click(f.view.primary);
    try std.testing.expectEqual(V.Step.delete_success, f.view.step);
    try std.testing.expect(!f.view.isVisible());
    try std.testing.expectEqual(@as(usize, 0), f.live.hosts.len);
    try std.testing.expectEqualStrings("DB-Master", f.view.name.getText().?.content);
    try std.testing.expectEqualStrings("DB-Master", frozen.value.name);
    try std.testing.expectEqualStrings("not displayed", frozen.value.password.?);
    try std.testing.expectEqual(@as(usize, 0), f.session_visits);
    try std.testing.expect(f.view.receipt != null);
    try std.testing.expect(!f.view.isVisible());
}

test "asset action view Escape and keep cancel without writing or retargeting" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    const before = try f.read();
    defer a.free(before);
    try f.show(.delete);
    f.cx.handleKeyDown(.escape, .{});
    f.frame();
    try std.testing.expect(!f.view.isVisible());
    try std.testing.expectEqual(@as(usize, 1), f.closed);
    try f.show(.move);
    f.click(f.view.secondary);
    try std.testing.expectEqual(@as(usize, 2), f.closed);
    try std.testing.expectEqual(@as(usize, 0), f.submitted);
    const after = try f.read();
    defer a.free(after);
    try std.testing.expectEqualStrings(before, after);
}

test "asset action view stale source and group revisions stay in confirmation and retain disk" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    try f.show(.move);
    var transaction = try store.HostsTransaction.init(a, &f.live);
    defer transaction.deinit();
    const destination = f.live.groups[1];
    _ = try transaction.candidate.?.updateGroup(destination.group_id, destination.revision, "RENAMED", "blue", false);
    try transaction.commit(io, f.tmp.dir, "hosts.toml", &f.live);
    const changed = try f.read();
    defer a.free(changed);
    f.click(f.view.primary);
    try std.testing.expect(f.view.failure.? == error.RevisionConflict);
    try std.testing.expectEqual(V.Step.move_select, f.view.step);
    try std.testing.expectEqualStrings("目标分组  DATABASES", f.view.to.getText().?.content);
    const retained = try f.read();
    defer a.free(retained);
    try std.testing.expectEqualStrings(changed, retained);
}

test "asset action view three themes and global material preserve selection and actual button text paint" {
    const previous = theme.currentName();
    const previous_material = theme.materialVisible();
    defer {
        theme.select(previous);
        _ = theme.setMaterialVisible(previous_material);
    }
    for ([_]theme.Name{ .dark, .light, .sauber }) |name| {
        theme.select(name);
        _ = theme.setMaterialVisible(true);
        var f: Fixture = undefined;
        try f.init();
        defer f.deinit();
        try f.show(.move);
        f.view.choose(1);
        try f.view.retheme();
        f.frame();
        try std.testing.expectEqual(theme.current().overlay, f.view.dialog.getBackground());
        try std.testing.expectEqual(theme.popupAction(), f.view.pair.getBackground());
        try std.testing.expectEqual(@as(?usize, 1), f.view.selected.peek());
        try std.testing.expectEqualStrings("目标分组  STAGING", f.view.to.getText().?.content);
        var found = false;
        for (f.cx.render()) |item| switch (item) {
            .text_run => |run| if (std.mem.eql(u8, run.content, "移动主机")) {
                try std.testing.expectEqual(ui.Color.WHITE, run.color);
                found = true;
            },
            else => {},
        };
        try std.testing.expect(found);
    }
}

test "asset action view danger button preserves geometry and red hover pressed semantics" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    try f.show(.delete);
    try f.cx.setTestFrameStep(100);
    const rect = f.view.primary.globalRect();
    f.cx.handleMouseMove(rect.x + 10, rect.y + 10);
    f.frame();
    try std.testing.expectEqual(@as(f32, 150), f.view.primary.globalRect().w);
    var color = f.view.primary.getBackground();
    try std.testing.expect(color.r > color.g and color.r > color.b);
    f.cx.handleMouseDown(rect.x + 10, rect.y + 10, .{});
    f.frame();
    try std.testing.expectEqual(@as(f32, 150), f.view.primary.globalRect().w);
    color = f.view.primary.getBackground();
    try std.testing.expect(color.r > color.g and color.r > color.b);
    f.cx.handleMouseMove(0, 0);
    f.cx.handleMouseUp(0, 0);
    f.frame();
    try std.testing.expectEqual(@as(usize, 0), f.submitted);
}

test "asset action view large group list virtualizes and keeps copied names after source release" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    var arena = std.heap.ArenaAllocator.init(a);
    const groups = try arena.allocator().alloc(V.Group, 500);
    for (groups, 0..) |*group, index| group.* = .{ .reference = .{ .id = @fromBackingInt(1000 + index), .revision = 2 }, .name = try std.fmt.allocPrint(arena.allocator(), "GROUP-{d:0>4}", .{index}) };
    try f.view.show(.{ .mode = .move, .owner = f.live.hosts[0].owner(), .name = "DB-Master", .endpoint = "admin@10.200.4.18:22", .groups = groups });
    arena.deinit();
    f.frame();
    try std.testing.expectEqual(@as(usize, 500), f.view.group_count.peek());
    try std.testing.expect(countButtons(f.view.groups) < 20);
    try std.testing.expect(findButton(f.view.groups, "GROUP-0000") != null);
    const rect = f.view.groups.globalRect();
    f.cx.handleScroll(.{ .x = rect.x + 20, .y = rect.y + 20, .dx = 0, .dy = -100000 });
    f.frame();
    try std.testing.expect(countButtons(f.view.groups) < 20);
    const final = findButton(f.view.groups, "GROUP-0499").?;
    f.click(final);
    try std.testing.expectEqual(@as(?usize, 499), f.view.selected.peek());
    try std.testing.expectEqualStrings("目标分组  GROUP-0499", f.view.to.getText().?.content);
    try std.testing.expectEqual(@as(usize, 0), f.submitted);
    f.view.close();
    try std.testing.expectEqual(@as(usize, 0), f.submitted);
}
