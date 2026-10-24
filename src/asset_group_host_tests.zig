const std = @import("std");
const ui = @import("ui");
const Group = @import("ui/asset_group_host.zig");
const A = Group.actions;
const hosts = @import("config/hosts.zig");
const store = @import("config/store.zig");
const Workspace = @import("ui/workspace.zig").Workspace;
const Config = @import("config/config.zig").Config;
const a = std.testing.allocator;

test "asset group host mounts against a real Workspace publishes the sidebar bridge and cleans it up" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "hosts.toml", .data = "" });
    const path = try tmp.dir.realPathFileAlloc(std.testing.io, "hosts.toml", a);
    defer a.free(path);
    const cx = try ui.Cx.init(a, std.testing.io);
    defer cx.deinit();
    cx.setViewport(1440, 900);
    cx.root = try ui.box(cx, .{ .width = .fill(), .height = .fill() }, .{});
    const scope = try ui.Scope.init(a, null, cx.owner);
    defer scope.dispose();
    var containers: [4]*ui.Node = undefined;
    for (&containers) |*container| {
        container.* = try ui.box(cx, .{ .width = .{ .px = 300 }, .height = .{ .px = 200 } }, .{});
        try cx.root.?.appendChild(a, container.*);
    }
    const settings: Config = .{};
    const workspace = try Workspace.init(a, cx, scope, std.testing.io, &settings, path, containers[0], containers[1], containers[2], containers[3]);
    const HostCallback = struct {
        calls: usize = 0,
        reference: ?Group.GroupRef = null,
        fn open(raw: *anyopaque, reference: ?Group.GroupRef) !void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.calls += 1;
            self.reference = reference;
        }
    };
    var callback: HostCallback = .{};
    const host_scope = try scope.childScope();
    const host = try Group.Host.mount(cx, host_scope, workspace, .{ .context = &callback, .open = HostCallback.open });
    try std.testing.expect(workspace.sidebar_bridge.context == @as(?*anyopaque, @ptrCast(host)));
    workspace.sidebar_bridge.new_group.?(workspace.sidebar_bridge.context);
    host.view.value.set("真实宿主分组");
    cx.layout();
    _ = cx.render();
    cx.setFocus(host.view.primary);
    cx.handleKeyDown(.@"return", .{});
    try cx.setTestFrameStep(16);
    for (0..20) |_| {
        cx.advanceFrameClock();
        cx.layout();
        _ = cx.render();
    }
    try std.testing.expectEqual(@as(usize, 1), workspace.registry.groups.len);
    try std.testing.expectEqualStrings("真实宿主分组", workspace.registry.groups[0].name);
    try std.testing.expect(workspace.group_headers.items.len != 0);
    var saved = try store.loadHosts(std.testing.io, tmp.dir, a, "hosts.toml");
    defer saved.deinit();
    try std.testing.expectEqualStrings("真实宿主分组", saved.groups[0].name);
    host.view.hide();
    const reference: Group.GroupRef = .{ .id = workspace.registry.groups[0].group_id, .revision = workspace.registry.groups[0].revision };
    workspace.sidebar_bridge.new_host.?(workspace.sidebar_bridge.context, reference);
    try std.testing.expectEqual(@as(usize, 1), callback.calls);
    try std.testing.expectEqual(reference, callback.reference.?);
    host_scope.dispose();
    try std.testing.expect(workspace.sidebar_bridge.context == null);
    try std.testing.expect(workspace.sidebar_bridge.new_group == null);
}

const Fixture = struct {
    tmp: @TypeOf(std.testing.tmpDir(.{})),
    registry: hosts.Registry,
    cx: *ui.Cx,
    scope: *ui.Scope,
    view: *Group.View,
    wizard_open: *ui.Signal(bool) = undefined,
    wizard: ui.widgets.ModalResult = undefined,
    calls: usize = 0,
    created_hosts: usize = 0,
    last_group: ?Group.GroupRef = null,
    path: []const u8 = "hosts.toml",
    fn init(self: *Fixture) !void {
        self.* = .{ .tmp = std.testing.tmpDir(.{}), .registry = .{ .arena = .init(a), .hosts = &.{} }, .cx = try ui.Cx.init(a, std.testing.io), .scope = undefined, .view = undefined };
        self.cx.setViewport(1440, 900);
        self.cx.root = try ui.box(self.cx, .{ .width = .fill(), .height = .fill() }, .{});
        self.scope = try ui.Scope.init(a, null, self.cx.owner);
        self.wizard_open = try self.scope.createSignal(bool, false);
        self.wizard = try ui.widgets.Modal(.{ .open = self.wizard_open, .title = "新建主机" }).mount(self.scope, self.cx);
        if (!self.wizard.portaled) try self.cx.root.?.appendChild(a, self.wizard.overlay);
        try self.wizard.body.appendChild(a, try ui.widgets.Button(.{ .label = "保存" }).mount(self.scope, self.cx));
        self.view = try Group.View.mount(self.cx, self.scope, .{ .context = self, .submit = submit, .new_host = newHost });
    }
    fn deinit(self: *Fixture) void {
        self.scope.dispose();
        self.cx.deinit();
        self.registry.deinit();
        self.tmp.cleanup();
    }
    fn settle(self: *Fixture) void {
        self.cx.setTestFrameStep(16) catch unreachable;
        for (0..20) |_| {
            self.cx.advanceFrameClock();
            self.cx.layout();
            _ = self.cx.render();
        }
    }
    fn enter(self: *Fixture, node: *ui.Node) void {
        self.cx.setFocus(node);
        self.cx.handleKeyDown(.@"return", .{});
        self.settle();
    }
    fn click(self: *Fixture, node: *ui.Node) void {
        const rect = node.globalRect();
        self.cx.handleMouseDown(rect.x + rect.w / 2, rect.y + rect.h / 2, .{});
        self.cx.handleMouseUp(rect.x + rect.w / 2, rect.y + rect.h / 2);
        self.settle();
    }
    fn submit(raw: *anyopaque, request: A.Request) !A.Result {
        const self: *Fixture = @ptrCast(@alignCast(raw));
        self.calls += 1;
        return A.apply(a, std.testing.io, self.tmp.dir, self.path, &self.registry, request);
    }
    fn newHost(raw: *anyopaque, reference: ?Group.GroupRef) !void {
        const self: *Fixture = @ptrCast(@alignCast(raw));
        if (reference) |value| _ = try A.group(&self.registry, value);
        self.created_hosts += 1;
        self.last_group = reference;
        self.wizard_open.set(true);
    }
    fn create(self: *Fixture, name: []const u8) !Group.GroupRef {
        const result = try submit(self, .{ .create = .{ .name = name } });
        return result.group.?;
    }
    fn snapshot(self: *Fixture, reference: Group.GroupRef) !Group.GroupSnapshot {
        const value = try A.group(&self.registry, reference);
        var count: usize = 0;
        for (self.registry.hosts) |host| if (host.asset_group_id == reference.id) {
            count += 1;
        };
        return .{ .reference = reference, .name = value.name, .color = value.color, .collapsed = value.collapsed, .host_count = count };
    }
};

test "asset group host create follows exact Figma geometry and acknowledges an actual disk commit" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    try f.view.show(.create, null);
    f.settle();
    const r = f.view.dialog.globalRect();
    try std.testing.expectEqual(@as(f32, 320), r.w);
    try std.testing.expectEqual(@as(f32, 135), r.h);
    try std.testing.expect(f.view.summary.style.display == .none);
    try std.testing.expect(f.view.helper.style.display == .none);
    try std.testing.expect(f.view.notice.style.display == .none);
    try std.testing.expectApproxEqAbs(r.y + 53, f.view.input.input_container.globalRect().y, 0.1);
    try std.testing.expectEqual(@as(f32, 296), f.view.input.input_container.globalRect().w);
    try std.testing.expectEqual(@as(f32, 32), f.view.input.input_container.globalRect().h);
    try std.testing.expectApproxEqAbs(r.y + 93, f.view.primary.globalRect().y, 0.1);
    try std.testing.expectEqual(@as(usize, 0), f.registry.groups.len);
    f.view.value.set(" 数据库 ");
    f.enter(f.view.primary);
    try std.testing.expectEqual(Group.Mode.created, f.view.mode);
    try std.testing.expectEqual(@as(f32, 130), f.view.dialog.globalRect().h);
    try std.testing.expectEqual(@as(usize, 1), f.registry.groups.len);
    try std.testing.expectEqualStrings("数据库", f.registry.groups[0].name);
    var loaded = try store.loadHosts(std.testing.io, f.tmp.dir, a, "hosts.toml");
    defer loaded.deinit();
    try std.testing.expectEqualStrings("数据库", loaded.groups[0].name);
    try std.testing.expectEqual(@as(usize, 0), f.created_hosts);
    f.click(f.view.secondary);
    try std.testing.expectEqual(@as(usize, 1), f.created_hosts);
    try std.testing.expectEqual(f.registry.groups[0].group_id, f.last_group.?.id);
    try std.testing.expect(!f.view.isVisible());
    try std.testing.expect(f.wizard_open.peek());
    try std.testing.expect(f.cx.focus_manager.activeScope() == f.wizard.overlay);
    const focus = f.cx.focus_manager.current_focus orelse return error.NoWizardFocus;
    try std.testing.expect(focus.isDescendantOf(f.wizard.dialog));
}

test "asset group host retains invalid and failed drafts without fake success or host creation" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    try f.view.show(.create, null);
    f.settle();
    f.view.value.set("  ");
    f.enter(f.view.primary);
    try std.testing.expectEqual(Group.Mode.create, f.view.mode);
    try std.testing.expectEqual(@as(usize, 0), f.registry.groups.len);
    try std.testing.expectEqualStrings("请输入分组名称。", f.view.helper.getText().?.content);
    try std.testing.expect(f.view.helper.style.display == .flex);
    try std.testing.expect(f.view.notice.style.display == .none);
    f.view.value.set("保留草稿");
    f.path = "missing/../broken.toml/hosts.toml";
    try f.tmp.dir.writeFile(std.testing.io, .{ .sub_path = "broken.toml", .data = "blocked" });
    f.enter(f.view.primary);
    try std.testing.expect(f.view.failure != null);
    try std.testing.expectEqual(Group.Mode.create, f.view.mode);
    try std.testing.expectEqualStrings("保留草稿", f.view.value.peek());
    try std.testing.expectEqual(@as(usize, 0), f.registry.groups.len);
    try std.testing.expectEqual(@as(usize, 0), f.created_hosts);
    f.cx.handleKeyDown(.escape, .{});
    f.settle();
    try std.testing.expect(!f.view.isVisible());
}

test "asset group host rename color and collapse commit captured identities while stale revisions fail" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    const first = try f.create("A");
    const second = try f.create("B");
    try f.view.show(.rename, try f.snapshot(first));
    f.settle();
    const stale = try Fixture.submit(&f, .{ .color = .{ .group = first, .color = "#123456" } });
    f.view.value.set("错误目标");
    f.enter(f.view.primary);
    try std.testing.expectEqual(error.RevisionConflict, f.view.failure.?);
    try std.testing.expectEqualStrings("A", f.registry.groups[0].name);
    try std.testing.expectEqualStrings("B", f.registry.groups[1].name);
    try f.view.show(.rename, try f.snapshot(stale.group.?));
    f.view.value.set("原组改名");
    f.settle();
    f.click(f.view.primary);
    try std.testing.expect(!f.view.isVisible());
    const renamed = f.view.receipt.?.group.?;
    const colored = try Fixture.submit(&f, .{ .color = .{ .group = renamed, .color = "#abcdef" } });
    const collapsed = try Fixture.submit(&f, .{ .toggle_collapsed = colored.group.? });
    const final = try A.group(&f.registry, collapsed.group.?);
    try std.testing.expectEqualStrings("原组改名", final.name);
    try std.testing.expectEqualStrings("#abcdef", final.color);
    try std.testing.expect(final.collapsed);
    try std.testing.expectEqualStrings("B", (try A.group(&f.registry, second)).name);
    try std.testing.expectError(error.InvalidGroupColor, Fixture.submit(&f, .{ .color = .{ .group = collapsed.group.?, .color = "red" } }));
    try std.testing.expectError(error.DuplicateGroupName, Fixture.submit(&f, .{ .rename = .{ .group = collapsed.group.?, .name = "B" } }));
}

test "asset group host empty deletion waits for an explicit confirm and rejects populated groups" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    const empty = try f.create("待删空组");
    try f.view.show(.delete_empty, try f.snapshot(empty));
    f.settle();
    try std.testing.expect(f.cx.isFocused(f.view.secondary));
    try std.testing.expectEqual(@as(usize, 1), f.registry.groups.len);
    const calls = f.calls;
    f.cx.handleKeyDown(.escape, .{});
    f.settle();
    try std.testing.expectEqual(calls, f.calls);
    try f.view.show(.delete_empty, try f.snapshot(empty));
    f.settle();
    f.click(f.view.primary);
    try std.testing.expectEqual(@as(usize, 0), f.registry.groups.len);
    try std.testing.expect(f.view.receipt.?.kind == .delete_empty);
    try std.testing.expect(f.view.receipt.?.group == null);
    const populated = try f.create("非空组");
    var transaction = try store.HostsTransaction.init(a, &f.registry);
    defer transaction.deinit();
    _ = try transaction.candidate.?.add(.{ .name = "DB", .host = "db.example", .user = "ops", .asset_group_id = populated.id });
    try transaction.commit(std.testing.io, f.tmp.dir, "hosts.toml", &f.registry);
    const current: Group.GroupRef = .{ .id = populated.id, .revision = f.registry.groups[0].revision };
    try std.testing.expectError(error.GroupNotEmpty, Fixture.submit(&f, .{ .delete_empty = current }));
    try f.view.show(.delete_empty, try f.snapshot(current));
    f.settle();
    f.click(f.view.primary);
    try std.testing.expectEqual(error.GroupNotEmpty, f.view.failure.?);
    try std.testing.expectEqual(@as(usize, 1), f.registry.groups.len);
    try std.testing.expectEqual(@as(usize, 1), f.registry.hosts.len);
}

test "asset group host external disk edits and IME composition cannot publish a stale group" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    const reference = try f.create("原始组");
    try f.view.show(.rename, try f.snapshot(reference));
    f.settle();
    f.view.value.set("新名称");
    const input_event = f.view.input.input_container.behavior.events.on_event.?;
    _ = input_event(.{ .ime_preedit = .{ .text = "xin", .cursor_utf8_offset = 3 } }, f.view.input.input_container.behavior.events.event_context);
    f.view.submit();
    f.settle();
    try std.testing.expect(!f.view.pending);
    try std.testing.expectEqualStrings("原始组", f.registry.groups[0].name);
    _ = input_event(.{ .ime_preedit = .{ .text = "", .cursor_utf8_offset = 0 } }, f.view.input.input_container.behavior.events.event_context);
    try f.tmp.dir.writeFile(std.testing.io, .{ .sub_path = "hosts.toml", .data = "# External edit\n" });
    f.enter(f.view.primary);
    try std.testing.expectEqual(error.FileConflict, f.view.failure.?);
    try std.testing.expectEqualStrings("原始组", f.registry.groups[0].name);
    try std.testing.expectEqual(Group.Mode.rename, f.view.mode);
    f.cx.setViewport(480, 400);
    f.settle();
    try std.testing.expect(f.view.dialog.globalRect().h <= 384);
    try std.testing.expect(f.view.primary.globalRect().y + f.view.primary.globalRect().h <= 400);
}

test "asset group host created receipt cannot add a host to a changed group" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    try f.view.show(.create, null);
    f.view.value.set("原分组");
    f.settle();
    f.enter(f.view.primary);
    const reference = f.view.receipt.?.group.?;
    _ = try Fixture.submit(&f, .{ .rename = .{ .group = reference, .name = "已改名分组" } });
    f.click(f.view.secondary);
    try std.testing.expectEqual(@as(usize, 0), f.created_hosts);
    try std.testing.expectEqual(error.RevisionConflict, f.view.failure.?);
    try std.testing.expect(f.view.isVisible());
    try std.testing.expect(!f.wizard_open.peek());
    try std.testing.expectEqualStrings("原分组", f.view.source.?.value.name);
    try std.testing.expectEqualStrings("已改名分组", f.registry.groups[0].name);
}
