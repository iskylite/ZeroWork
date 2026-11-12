const std = @import("std");
const ui = @import("ui");
const notes = @import("plugins/notes/plugin.zig");
const workspace_mod = @import("ui/workspace.zig");
const app_mod = @import("ui/application_host.zig");
const session = @import("host/session_host.zig");
const config = @import("config/config.zig");
const contract = @import("host/plugin_ui_contract.zig");
const floating = @import("plugins/notes/floating.zig");
const notes_view = @import("plugins/notes/view.zig");

test "notes floating quick creation reuses the same renderer in the tab and gates failed close" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "hosts.toml", .data = "" });
    const path = try tmp.dir.realPathFileAlloc(io, "hosts.toml", a);
    defer a.free(path);
    var plugin: notes.Plugin = .{ .allocator = a, .io = io, .data = tmp.dir };
    defer plugin.deinit();
    const domain = try app_mod.Domain.initWithContributions(a, false, &.{plugin.manifest()}, &.{plugin.renderer()});
    defer domain.deinit();
    const cx = try ui.Cx.init(a, io);
    defer cx.deinit();
    const scope = try ui.Scope.init(a, null, cx.owner);
    defer scope.dispose();
    cx.setViewport(1440, 900);
    try cx.setTestFrameStep(16);
    cx.root = try ui.box(cx, .{ .width = .fill(), .height = .fill(), .direction = .column }, .{});
    var slots: [4]*ui.Node = undefined;
    for (&slots) |*slot| {
        slot.* = try ui.box(cx, .{ .width = .fill(), .height = .fill() }, .{});
        try cx.root.?.appendChild(a, slot.*);
    }
    const prefs: config.Config = .{};
    const workspace = try workspace_mod.Workspace.init(a, cx, scope, io, &prefs, path, slots[0], slots[1], slots[2], slots[3]);
    const app = try app_mod.ApplicationHost.initInDomain(domain, workspace, null);
    defer app.deinit();
    app.install();
    const connection = try workspace.createPluginSession(.{ .session_id = @fromBackingInt(9) }, .{ .protocol_id = "test.connection", .name = "连接", .payload_version = 1, .payload = "{}" }, .{ .kind = "test.connection", .mount = mountConnection });
    const panel = try floating.View.mount(workspace, scope, cx.root.?);
    cx.layout();

    try panel.toggle(app);
    _ = try panel.tick(app);
    const owner = app.detached_quick_content.?.handle;
    _ = try app.safeTick();
    try std.testing.expect(try panel.tick(app));
    cx.layout();
    const available = workspace.terminal_area.globalRect();
    const visible = panel.root.globalRect();
    try std.testing.expectApproxEqAbs(@as(f32, 960), visible.w, 0.01);
    try std.testing.expectApproxEqAbs(available.x + available.w, visible.x + visible.w, 0.01);
    try std.testing.expectApproxEqAbs(available.h, visible.h, 0.01);
    try std.testing.expectEqual(@as(usize, 1), workspace.tabs.items.len);
    try std.testing.expectEqual(connection, workspace.tabs.items[workspace.active_tab.?].id);
    try std.testing.expectEqual(session.Lifecycle.ready, app.sessions.queryState(owner).?.lifecycle);
    const original = panel.detached.?.instance;
    const connection_tab = workspace.tabs.items[workspace.active_tab.?];
    cx.window_active = false;
    try std.testing.expect(notes_view.focus(original));
    panel.setWindowVisible(app, false);
    try std.testing.expect(!notes_view.focus(original));
    try std.testing.expectEqual(contract.ContentPresentation.active, connection_tab.plugin_presentation);
    try std.testing.expect(panel.focusOwner(app, owner));
    panel.setWindowVisible(app, true);
    try std.testing.expect(notes_view.focus(original));
    cx.window_active = true;
    const store = try plugin.openStore();
    const library_id = try store.createLibrary("测试");
    const key = try store.createNote(library_id, null, "新文档");
    const documents = try plugin.documentSessions();
    try std.testing.expect(notes_view.openNote(original, key));
    for (0..6) |_| {
        cx.advanceFrameClock();
        cx.layout();
        _ = cx.render();
    }
    try std.testing.expectEqual(owner, documents.ownerFor(key).?);
    const lease = (try documents.open(key, owner)).lease;
    const other_owner = connection_tab.content_owner.session;
    try std.testing.expect(!owner.eql(other_owner));
    try std.testing.expectEqual(owner, (try documents.open(key, other_owner)).occupied);
    try std.testing.expectEqualStrings("notes.editor.active", cx.focus_manager.getFocused().?.meta.ownership.meta.test_id.?);
    const editor = cx.focus_manager.getFocused().?;
    cx.handleTextInput("保存失败时保留这行");
    try std.testing.expectEqualStrings("保存失败时保留这行", (try documents.snapshot(lease)).body_md);
    try panel.toggle(app);
    try std.testing.expect(try panel.tick(app));
    try std.testing.expectEqual(.none, panel.root.style.display);
    panel.setWindowVisible(app, false);
    panel.setWindowVisible(app, true);
    try std.testing.expect(!notes_view.focus(original));
    try std.testing.expect(!panel.focusOwner(app, try owner.nextGeneration()));
    try std.testing.expect(panel.focusOwner(app, owner));
    try std.testing.expect(try panel.tick(app));
    try std.testing.expectEqual(original.context, panel.detached.?.instance.context);
    try panel.openTab(app);
    try std.testing.expect(try panel.tick(app));

    try app.openSingletonQuickContent(notes.id, notes.payload);
    try std.testing.expectEqual(@as(usize, 2), workspace.tabs.items.len);
    const tab = workspace.tabs.items[1];
    try std.testing.expect(tab.content_owner.session.eql(owner));
    try std.testing.expectEqual(original.context, tab.plugin_renderer.?.context);
    try std.testing.expectEqual(lease, (try documents.open(key, owner)).lease);
    const transferred = try documents.snapshot(lease);
    try std.testing.expect(transferred.dirty);
    try std.testing.expectEqualStrings("保存失败时保留这行", transferred.body_md);
    try std.testing.expectEqual(session.Lifecycle.attached, app.sessions.queryState(owner).?.lifecycle);
    try std.testing.expectEqualStrings("我的笔记", tab.titleSlice());
    try std.testing.expect(tab.terminal == null and tab.runtime == null and tab.host_snapshot == null);
    try std.testing.expectEqualStrings("notes.workspace", notes_view.rootNode(tab.plugin_renderer.?).?.meta.ownership.meta.test_id.?);

    const session_count = app.sessions.sessions.items.len;
    try workspace.newSessionFromTab(1);
    _ = try app.safeTick();
    try std.testing.expectEqual(session_count, app.sessions.sessions.items.len);
    try std.testing.expectEqual(@as(usize, 2), workspace.tabs.items.len);
    var roster = @import("ui/group_model.zig").Roster.init(a);
    defer roster.deinit();
    try std.testing.expectError(error.UnsupportedService, workspace.splitGroup(&roster, false));
    try std.testing.expectEqual(@as(usize, 0), roster.groups.items.len);

    panel.setWindowVisible(app, false);
    try std.testing.expectEqual(contract.ContentPresentation.occluded, tab.plugin_presentation);
    workspace.activateTabId(connection_tab.tab_id);
    try std.testing.expectEqual(contract.ContentPresentation.hidden, tab.plugin_presentation);
    panel.setWindowVisible(app, true);
    try std.testing.expectEqual(contract.ContentPresentation.hidden, tab.plugin_presentation);

    try panel.toggle(app);
    try std.testing.expect(try panel.tick(app));
    try std.testing.expectEqual(notes_view.rootNode(original).?, tab.plugin_floating_root.?);
    try std.testing.expectEqual(@as(usize, 2), workspace.tabs.items.len);
    try std.testing.expectEqual(original.context, panel.focused().?.context);
    try std.testing.expectEqual(editor, cx.focus_manager.getFocused().?);
    try std.testing.expectEqual(lease, (try documents.open(key, owner)).lease);
    try std.testing.expectEqual(owner, (try documents.open(key, other_owner)).occupied);
    try std.testing.expectEqual(contract.ContentPresentation.active, tab.plugin_presentation);
    panel.setWindowVisible(app, false);
    try std.testing.expectEqual(contract.ContentPresentation.occluded, tab.plugin_presentation);
    panel.setWindowVisible(app, true);
    try std.testing.expectEqual(contract.ContentPresentation.active, tab.plugin_presentation);
    panel.hide();
    try std.testing.expectEqual(contract.ContentPresentation.hidden, tab.plugin_presentation);

    panel.setWindowVisible(app, false);
    try std.testing.expect(panel.focusOwner(app, owner));
    panel.setWindowVisible(app, true);
    try std.testing.expectEqual(contract.ContentPresentation.active, tab.plugin_presentation);
    try std.testing.expectEqual(original.context, tab.plugin_renderer.?.context);

    var broken = io.vtable.*;
    broken.dirRename = failReplace;
    store.io.vtable = &broken;
    defer store.io = io;

    var auxiliary_cancelled = false;
    app.window_auxiliary = .{
        .context = &auxiliary_cancelled,
        .cancel = struct {
            fn cancel(raw: *anyopaque) void {
                const value: *bool = @ptrCast(@alignCast(raw));
                value.* = true;
            }
        }.cancel,
        .released = struct {
            fn released(_: *anyopaque) bool {
                return true;
            }
        }.released,
    };
    try std.testing.expectError(error.AccessDenied, app.requestWindowClose());
    try std.testing.expect(!auxiliary_cancelled and !app.windowClosePending());
    app.window_auxiliary = null;

    workspace.forceCloseTab(1);
    try std.testing.expect(workspace.tabs.items[1] == tab and !tab.closing);
    try std.testing.expectEqual(session.Lifecycle.attached, app.sessions.queryState(owner).?.lifecycle);
    const failed = try documents.snapshot(lease);
    try std.testing.expect(failed.dirty);
    try std.testing.expectEqual(@as(?anyerror, error.AccessDenied), failed.save_error);
    try std.testing.expectEqualStrings("保存失败时保留这行", failed.body_md);

    store.io = io;
    workspace.forceCloseTab(1);
    for (0..6) |_| {
        _ = try app.safeTick();
        cx.advanceFrameClock();
        cx.layout();
        _ = cx.render();
    }
    try std.testing.expectEqual(@as(usize, 1), workspace.tabs.items.len);
    try std.testing.expectEqual(connection, workspace.tabs.items[0].id);
    const saved = try store.loadNote(a, key, .active);
    defer saved.deinit();
    try std.testing.expectEqualStrings("保存失败时保留这行", saved.value.body_md);
    try std.testing.expect(documents.ownerFor(key) == null);
    try std.testing.expectError(error.StaleLease, documents.snapshot(lease));
    const replacement = (try documents.open(key, other_owner)).lease;
    defer documents.release(replacement) catch {};
    try std.testing.expect(replacement.epoch != lease.epoch);
    try std.testing.expectEqualStrings("保存失败时保留这行", (try documents.snapshot(replacement)).body_md);
}

fn mountConnection(_: ?*anyopaque, request: contract.ContentMount) !contract.RendererInstance {
    const Connection = struct {
        fn update(_: *anyopaque, _: contract.ContentUpdate) !void {}
        fn focus(_: *anyopaque, _: bool) void {}
        fn presentation(_: *anyopaque, _: contract.ContentPresentation) void {}
        fn unmount(_: *anyopaque) void {}
    };
    return .{ .context = request.slot, .vtable = &.{ .update = Connection.update, .focus_changed = Connection.focus, .unmount = Connection.unmount, .presentation_changed = Connection.presentation } };
}

fn failReplace(_: ?*anyopaque, _: std.Io.Dir, _: []const u8, _: std.Io.Dir, _: []const u8) std.Io.Dir.RenameError!void {
    return error.AccessDenied;
}
