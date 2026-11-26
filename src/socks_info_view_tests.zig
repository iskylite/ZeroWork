const std = @import("std");
const ui = @import("ui");
const view_mod = @import("ui/socks_info_view.zig");

const Sink = struct { actions: usize = 0, last: ?view_mod.Action = null };
fn action(raw: *anyopaque, a: view_mod.Action) void {
    const s: *Sink = @ptrCast(@alignCast(raw));
    s.actions += 1;
    s.last = a;
}

test "socks card mounts hidden, copies live values and dispatches actions" {
    var cx = try ui.Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    cx.setViewport(1280, 720);
    const scope = try ui.Scope.init(std.testing.allocator, null, cx.owner);
    defer scope.dispose();
    const root = try ui.box(cx, .{ .width = .fill(), .height = .fill() }, .{});
    cx.root = root;
    var sink = Sink{};
    const view = try view_mod.mount(cx, scope, .{ .context = @ptrCast(&sink), .action = action });
    if (!view.portaled) try root.appendChild(cx.allocator, view.wrapper);
    try std.testing.expect(view.root.style.display == .none);
    try view.update(.{ .state = .running, .port = 1081, .bind = "127.0.0.1", .host = "db", .exit = "db", .session_id = 201, .route = "via jump", .connections = 2, .uploaded = 1024 });
    try std.testing.expectEqualStrings("#db", view.owner.getText().?.content);
    view.show(.{ .x = 1180, .y = 670, .w = 80, .h = 20 });
    cx.layout();
    _ = view.updateGeometry();
    try std.testing.expect(view.root.style.display == .flex);
    const stable_height = view.root.style.height.px;
    try view.update(.{ .state = .running, .port = 1081, .test_result = "SOCKS CONNECT 成功 - 15 ms", .logs = "日志\n日志\n日志\n日志\n日志\n日志\n日志\n日志\n日志\n日志\n日志\n日志\n日志\n日志\n日志\n日志\n日志\n日志\n日志\n日志\n日志\n日志\n日志\n日志\n日志\n日志\n日志\n日志\n日志\n日志\n日志\n日志\n日志\n日志\n日志\n日志\n日志\n日志\n日志\n日志\n日志\n日志\n日志\n日志\n日志\n日志\n日志\n日志\n日志\n日志\n日志\n日志\n日志\n日志\n日志\n日志\n日志\n日志\n日志\n日志\n日志\n日志\n日志\n日志\n日志\n日志\n日志\n日志\n日志\n日志\n日志\n日志\n日志\n日志\n日志\n日志\n日志\n日志\n日志\n日志\n" });
    cx.layout();
    _ = view.updateGeometry();
    // A visible result can resize the overview; the separate log text does
    // not reserve space in this card.
    try std.testing.expect(view.root.style.height.px != stable_height);
    view.dispatch(.logs);
    cx.layout();
    _ = view.updateGeometry();
    try std.testing.expectEqual(@as(f32, 560), view.logs_root.style.width.px);
    try std.testing.expectEqual(@as(f32, 420), view.logs_root.style.height.px);
    try std.testing.expect(view.root.style.display == .none);
    for (0..4) |_| cx.layout();
    try std.testing.expect(view.logs_body.content.globalRect().h > view.logs_body.container.globalRect().h);
    view.dispatch(.logs_back);
    view.dispatch(.test_proxy);
    try std.testing.expectEqual(@as(usize, 1), sink.actions);
    try std.testing.expectEqual(view_mod.Action.test_proxy, sink.last.?);
    view.dispatch(.stop);
    try std.testing.expectEqual(view_mod.Action.stop, sink.last.?);
    try view.update(.{ .state = .connecting, .logs = "正在申请监听" });
    const actions_before = sink.actions;
    try std.testing.expectEqualStrings("取消启动", view.control_text.getText().?.content);
    try std.testing.expect(!view.control_disabled.get());
    view.dispatch(.start);
    try std.testing.expectEqual(actions_before + 1, sink.actions);
    try std.testing.expectEqual(view_mod.Action.stop, sink.last.?);
    try view.update(.{ .state = .stopping, .logs = "正在申请监听" });
    try std.testing.expectEqualStrings("停止中", view.status.getText().?.content);
    try std.testing.expect(view.control_disabled.get());
    view.dispatch(.start);
    try std.testing.expectEqual(actions_before + 1, sink.actions);
    view.dispatch(.logs);
    try std.testing.expect(view.logs_text.style.display == .flex);
    try std.testing.expectEqualStrings("正在申请监听", view.logs_text.getText().?.content);
    try view.update(.{ .state = .failed, .error_text = "AddressInUse" });
    try std.testing.expectEqualStrings("重试", view.control_text.getText().?.content);
    view.dispatch(.start);
    try std.testing.expectEqual(view_mod.Action.start, sink.last.?);
}

test "socks card hugs content and removes cleared result space" {
    const cx = try ui.Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    cx.setViewport(1280, 720);
    try cx.setTestFrameStep(100);
    const scope = try ui.Scope.init(std.testing.allocator, null, cx.owner);
    defer scope.dispose();
    cx.root = try ui.box(cx, .{ .width = .fill(), .height = .fill() }, .{});
    var sink = Sink{};
    const view = try view_mod.mount(cx, scope, .{ .context = &sink, .action = action });
    if (!view.portaled) try cx.root.?.appendChild(cx.allocator, view.wrapper);
    const configured: view_mod.Data = .{ .configured = true, .host = "db", .port = 1081 };
    try view.update(configured);
    view.show(.{ .x = 1160, .y = 680, .w = 80, .h = 20 });
    settle(cx);
    const compact = view.root.globalRect();
    try std.testing.expect(view.message.style.display == .none);
    try std.testing.expect(view.footer.parent == view.rule);
    // SVG: 30 px actions, 12 px bottom inset, and the resting gap between
    // the log button and the three actions is 12 px (not a second footer).
    try expectRuleActions(view);
    try std.testing.expect(compact.h < 400);

    var with_result = configured;
    with_result.test_result = "SOCKS CONNECT 成功 - 15 ms";
    try view.update(with_result);
    settle(cx);
    const expanded = view.root.globalRect();
    try std.testing.expect(expanded.h > compact.h);
    try std.testing.expectApproxEqAbs(compact.y + compact.h, expanded.y + expanded.h, 0.5);

    try view.update(configured);
    settle(cx);
    try std.testing.expectApproxEqAbs(compact.h, view.root.globalRect().h, 0.5);
    try std.testing.expect(view.message.style.display == .none);
    try view.update(.{});
    settle(cx);
    try std.testing.expect(view.root.globalRect().h < compact.h);
    try std.testing.expect(view.footer.parent == view.empty);
    try std.testing.expect(view.config_button.isDisplayedInTree());
    try std.testing.expect(!view.control_button.isDisplayedInTree() and !view.test_button.isDisplayedInTree());
}

fn expectRuleActions(view: *view_mod.View) !void {
    const footer = view.footer.globalRect();
    const rule = view.rule.globalRect();
    const details = view.details_row.globalRect();
    try std.testing.expect(view.footer.parent == view.rule);
    try std.testing.expectApproxEqAbs(@as(f32, 12), rule.y + rule.h - footer.y - footer.h, 0.5);
    try std.testing.expectApproxEqAbs(@as(f32, 12), footer.x - rule.x, 0.5);
    try std.testing.expectApproxEqAbs(@as(f32, 30), footer.h, 0.5);
    try std.testing.expectApproxEqAbs(@as(f32, 9), footer.y - details.y - details.h, 0.5);
}

fn settle(cx: *ui.Cx) void {
    for (0..12) |_| {
        cx.advanceFrameClock();
        cx.layout();
        _ = cx.render();
    }
}

test "socks card follows the live trigger through resize without leaving the window" {
    var cx = try ui.Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    cx.setViewport(1600, 600);
    const scope = try ui.Scope.init(std.testing.allocator, null, cx.owner);
    defer scope.dispose();
    const root = try ui.box(cx, .{ .width = .fill(), .height = .fill() }, .{});
    cx.root = root;
    var sink = Sink{};
    const view = try view_mod.mount(cx, scope, .{ .context = @ptrCast(&sink), .action = action });
    if (!view.portaled) try root.appendChild(cx.allocator, view.wrapper);
    const chip = try ui.box(cx, .{ .position = .absolute, .inset = .{ .right = .{ .px = 220 }, .bottom = .{ .px = 12 } }, .width = .{ .px = 96 }, .height = .{ .px = 24 } }, .{});
    try root.appendChild(cx.allocator, chip);
    try view.update(.{ .state = .running, .host = "db" });
    view.showNode(chip);
    try cx.setTestFrameStep(100);
    for (0..10) |_| {
        cx.advanceFrameClock();
        cx.layout();
        _ = cx.render();
    }
    const first = view.root.globalRect();
    try std.testing.expectApproxEqAbs(@as(f32, 380), first.w, 0.01);
    try std.testing.expect(first.h >= 288 and first.h < 500);
    try expectRuleActions(view);
    try std.testing.expectEqual(ui.A11yRole.button, view.test_button.behavior.interaction.a11y.?.role);
    const first_anchor = chip.globalRect();
    try std.testing.expect(view.pointer.style.display == .none);
    try std.testing.expect(first.y + first.h <= 592.5);
    // Move the trigger; after-layout must recompute the popup position and
    // pointer offset from the node, rather than retaining the old snapshot.
    chip.style.ensureExtPanic(cx.allocator).inset.right = .{ .px = 40 };
    chip.markLayoutDirty();
    for (0..10) |_| {
        cx.advanceFrameClock();
        cx.layout();
        _ = cx.render();
    }
    const second_anchor = chip.globalRect();
    const second = view.root.globalRect();
    try std.testing.expect(second_anchor.x > first_anchor.x + 100);
    // The card is intentionally lower-right anchored; its pointer is the
    // element that tracks a horizontally moving status chip.
    try std.testing.expect(second.x != first.x);
    try std.testing.expect(second.x >= 7.5 and second.x + second.w <= 1592.5);
}

test "socks card long endpoint and failure scroll without detaching controls from their rule" {
    const cx = try ui.Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    cx.setViewport(860, 480);
    const scope = try ui.Scope.init(std.testing.allocator, null, cx.owner);
    defer scope.dispose();
    cx.root = try ui.box(cx, .{ .width = .fill(), .height = .fill() }, .{});
    var sink = Sink{};
    const view = try view_mod.mount(cx, scope, .{ .context = &sink, .action = action });
    if (!view.portaled) try cx.root.?.appendChild(cx.allocator, view.wrapper);
    try view.update(.{
        .mode = .local,
        .port = 1081,
        .state = .failed,
        .target_host = "very-long-target-host-for-production-forwarding-diagnostics.example.internal.with-additional-routing-segments.example.internal",
        .target_port = 443,
        .error_text = "连接失败，请检查目标主机配置和当前链路。\n第一条诊断记录：此处保留完整错误原因。\n第二条诊断记录：此处保留下一步操作建议。\n第三条诊断记录：请重新连接后显式重试。",
    });
    view.show(.{ .x = 720, .y = 440, .w = 80, .h = 20 });
    try cx.setTestFrameStep(100);
    for (0..12) |_| {
        cx.advanceFrameClock();
        cx.layout();
        _ = cx.render();
        _ = view.updateGeometry();
    }
    try std.testing.expect(view.address.globalRect().h > 32);
    try std.testing.expect(view.message.globalRect().h >= 64);
    const card = view.root.globalRect();
    try expectRuleActions(view);
    try std.testing.expect(view.body.content.globalRect().h > view.body.container.globalRect().h);
    try std.testing.expect(card.y >= 7.5 and card.y + card.h <= 472.5);
}

test "socks diagnostics keep recent measured steps and disclose truncation" {
    const Journal = @import("proto/ssh/forward_diagnostics.zig").Journal;
    const clock = @import("platform/realtime.zig");
    var journal: Journal = .{};
    for (0..26) |_| journal.add("TCP 通道建立", clock.monotonicNs() - 2 * std.time.ns_per_ms, null);
    journal.add("监听失败", null, error.AddressInUse);
    try std.testing.expectEqual(@as(usize, 24), journal.count);
    try std.testing.expectEqual(@as(usize, 3), journal.dropped);
    try std.testing.expect(journal.records[0].elapsed_us.? >= 2000);
    var buffer: [4096]u8 = undefined;
    const logs = journal.format(&buffer);
    try std.testing.expect(journal.records[0].timestamp_ms > 1_500_000_000_000);
    try std.testing.expect(std.mem.indexOf(u8, logs, " - TCP 通道建立 - ") != null);
    try std.testing.expect(std.mem.indexOf(u8, logs, " - 监听失败: AddressInUse\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, logs, "ms") != null);
    try std.testing.expect(std.mem.indexOf(u8, logs, "AddressInUse") != null);
    try std.testing.expect(std.mem.indexOf(u8, logs, "已省略 3 条") != null);
}

test "socks card top toolbar retains forwarding body and anchors below button" {
    const cx = try ui.Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    cx.setViewport(1440, 900);
    try cx.setTestFrameStep(100);
    const scope = try ui.Scope.init(std.testing.allocator, null, cx.owner);
    defer scope.dispose();
    cx.root = try ui.box(cx, .{ .width = .fill(), .height = .fill() }, .{});
    var sink: Sink = .{};
    const view = try view_mod.mount(cx, scope, .{ .context = &sink, .action = action });
    try cx.root.?.appendChild(cx.allocator, view.wrapper);
    try view.update(.{ .configured = true, .host = "DB-A", .port = 1081, .route = "via jump", .connections = 2, .uploaded = 1024 });
    for ([_]ui.Size{ .{ .width = 1440, .height = 900 }, .{ .width = 860, .height = 480 } }) |size| {
        cx.setViewport(size.width, size.height);
        view.show(.{ .x = size.width - 240, .y = 16, .w = 28, .h = 28 });
        settle(cx);
        const r = view.root.globalRect();
        const body = view.body.container.globalRect();
        const address = view.address.globalRect();
        try std.testing.expectApproxEqAbs(@as(f32, 50), r.y, 0.5);
        try std.testing.expect(r.x >= 8 and r.x + r.w <= size.width - 7.9 and r.y + r.h <= size.height - 7.9);
        try std.testing.expect(body.h > 100);
        try std.testing.expect(address.y >= body.y and address.y + address.h <= body.y + body.h + 0.1);
        try expectRuleActions(view);
        try std.testing.expectEqualStrings("127.0.0.1:1081", view.address.getText().?.content);
        view.hide();
        settle(cx);
    }
}

test "socks card single mascot panel stays beside rail and real hover shows active TCP count only" {
    const cx = try ui.Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    try cx.setTestFrameStep(100);
    cx.setViewport(1440, 900);
    const scope = try ui.Scope.init(std.testing.allocator, null, cx.owner);
    defer scope.dispose();
    cx.root = try ui.box(cx, .{ .width = .fill(), .height = .fill() }, .{});
    var sink: Sink = .{};
    const view = try view_mod.mountAnchored(cx, scope, .{ .context = &sink, .action = action }, true);
    if (!view.portaled) try cx.root.?.appendChild(cx.allocator, view.wrapper);
    var live: view_mod.Data = .{ .state = .running, .host = "work-session", .exit = "actual-exit", .port = 1080, .connections = 2, .downloaded = 0, .uploaded = 17 };
    try view.update(live);
    view.show(.{ .x = 1376, .y = 757, .w = 28, .h = 28 });
    settle(cx);
    try std.testing.expect(view.root.globalRect().x + view.root.globalRect().w <= 1371);
    try std.testing.expectEqualStrings("#work-session", view.owner.getText().?.content);
    try std.testing.expectEqualStrings("出口 actual-exit", view.exit.getText().?.content);
    try std.testing.expectEqualStrings("下载 0 B  ·  上传 17 B", view.statistics.getText().?.content);
    try std.testing.expectEqualStrings("正在监听", view.status.getText().?.content);
    try std.testing.expectEqualStrings("#2", view.connections_text.getText().?.content);
    try std.testing.expectEqualStrings("TCP · 不支持 UDP", view.protocol.getText().?.content);
    const number = view.connections_tip.trigger.globalRect();
    try std.testing.expect(number.w > 0 and number.h > 0);
    cx.handleMouseMove(number.x + number.w / 2, number.y + number.h / 2);
    settle(cx);
    try std.testing.expect(view.connections_tip.open.?.peek());
    try std.testing.expectEqualStrings("2 个活跃 TCP 连接", view.connections_tip.content.behavior.interaction.a11y.?.label.?);
    live.connections = 0;
    try view.update(live);
    settle(cx);
    try std.testing.expect(view.connections_tip.open.?.peek());
    try std.testing.expectEqualStrings("#0", view.connections_text.getText().?.content);
    try std.testing.expectEqualStrings("0 个活跃 TCP 连接", view.connections_tip.content.behavior.interaction.a11y.?.label.?);
    live.connections = null;
    try view.update(live);
    settle(cx);
    try std.testing.expect(!view.connections_tip.open.?.peek() and !view.connections_tip.wrapper.isDisplayedInTree());
    try view.update(.{ .state = .running, .read_only = true, .configured = true, .host = "web", .port = 18080, .connections = 1 });
    try std.testing.expect(!view.footer.isDisplayedInTree());
    view.dispatch(.stop);
    view.dispatch(.config);
    try std.testing.expectEqual(@as(usize, 0), sink.actions);
    view.dispatch(.copy_export);
    try std.testing.expectEqual(view_mod.Action.copy_export, sink.last.?);
    view.withoutCurrent();
    try std.testing.expect(!view.current_content.isDisplayedInTree());
    try std.testing.expectEqualStrings("", view.owner.getText().?.content);
    view.dispatch(.copy_export);
    view.dispatch(.logs);
    try std.testing.expectEqual(@as(usize, 1), sink.actions);
    try std.testing.expect(!view.logs_open.peek());
    try view.update(.{ .state = .connecting, .configured = true, .port = 0, .connections = 5 });
    try std.testing.expectEqualStrings("自动分配端口", view.address.getText().?.content);
    try std.testing.expect(!view.connections_tip.wrapper.isDisplayedInTree());
    view.dispatch(.copy_export);
    try std.testing.expectEqual(@as(usize, 1), sink.actions);
}

test "socks card workspace host keeps background-only rows independent and rejects stale session generation" {
    const ws = @import("ui/workspace.zig");
    const app = @import("ui/application_host.zig");
    const Host = @import("ui/socks_application_host.zig").Host;
    const L = @import("ui/socks_background_view.zig");
    const R = @import("host/plugin_ui_contract.zig");
    const id = @import("host/identity.zig");
    const a = std.testing.allocator;
    const cx = try ui.Cx.init(a, std.testing.io);
    defer cx.deinit();
    try cx.setTestFrameStep(75);
    cx.setViewport(1440, 900);
    const scope = try ui.Scope.init(a, null, cx.owner);
    defer scope.dispose();
    const root = try ui.box(cx, .{ .width = .fill(), .height = .fill() }, .{});
    cx.root = root;
    const chip = try ui.box(cx, .{ .position = .absolute, .inset = .{ .right = .{ .px = 55 }, .bottom = .{ .px = 109 } }, .width = .{ .px = 28 }, .height = .{ .px = 28 } }, .{});
    try root.appendChild(a, chip);
    // Read-only renderer with an actual forwarded endpoint receipt in one
    // generation. No network, native window, OS clipboard or secret storage.
    var forward: R.ForwardingStatus = .{ .state = .{ .listening = 18080 }, .exit = "jumphost", .connections = 9 };
    const renderer: R.RendererInstance = .{ .context = &forward, .vtable = &.{
        .update = struct {
            fn call(_: *anyopaque, _: R.ContentUpdate) anyerror!void {}
        }.call,
        .focus_changed = struct {
            fn call(_: *anyopaque, _: bool) void {}
        }.call,
        .unmount = struct {
            fn call(_: *anyopaque) void {}
        }.call,
        .forwarding_status = struct {
            fn call(raw: *anyopaque) R.ForwardingStatus {
                const receipt: *R.ForwardingStatus = @ptrCast(@alignCast(raw));
                return receipt.*;
            }
        }.call,
    } };
    const owner: id.SessionHandle = .{ .session_id = @fromBackingInt(20), .generation = 7 };
    var tab: ws.SessionTab = .{ .id = 4, .tab_id = @fromBackingInt(3), .content_owner = .{ .session = owner }, .host_id = 1, .host_index = 0, .host_snapshot = null, .root = chip, .plugin_renderer = renderer };
    tab.setTitle("web-tab");
    // Minimal captured identity fixtures for these read-only host projections.
    var workspace: ws.Workspace = undefined;
    workspace.active_group_view = null;
    workspace.active_tab = null;
    workspace.tabs = .empty;
    defer workspace.tabs.deinit(a);
    try workspace.tabs.append(a, &tab);
    var application: app.ApplicationHost = undefined;
    application.mappings = .empty;
    defer application.mappings.deinit(a);
    try application.mappings.append(a, .{ .handle = owner, .create_operation = undefined, .legacy_id = tab.id, .legacy_generation = 1, .tab_id = tab.tab_id, .owner = tab.content_owner, .source = null });
    var registry = L.M.Model.init(a, undefined);
    defer registry.deinit();
    const bg: id.SessionHandle = .{ .session_id = @fromBackingInt(22), .generation = 3 };
    try registry.rows.append(a, .{ .owner = bg, .source = .{ .id = @fromBackingInt(8) }, .name = "background-only", .phase = .listening, .local_port = 18081, .bind127 = true, .stats = .{ .connections_active = 3, .bytes_up = 123 }, .failure = null });
    var backend: L.M.Routes.Host = undefined;
    var host: Host = .{ .allocator = a, .cx = cx, .workspace = &workspace, .application = &application, .backend = &backend, .chip = chip, .background_model = &registry };
    const info = try view_mod.mountAnchored(cx, scope, .{ .context = &host, .action = Host.infoAction }, true);
    host.info = info;
    if (!info.portaled) try root.appendChild(a, info.wrapper);
    const capture = struct {
        fn run(_: *anyopaque, _: id.SessionHandle, _: L.Action) void {}
    };
    const list = try L.View.mount(cx, scope, .{ .context = &host, .action = capture.run });
    try root.appendChild(a, list.remote_entry);
    try root.appendChild(a, list.local_entry);
    if (!list.popover.portaled) try root.appendChild(a, list.popover.wrapper);
    try list.attachInline(info.body.content);
    try list.update(registry.rows.items);
    host.showInfo();
    settle(cx);
    try std.testing.expect(info.root.isDisplayedInTree() and !info.current_content.isDisplayedInTree());
    try std.testing.expect(list.inline_section.?.root.isDisplayedInTree() and !list.popover.open_read.get());
    try std.testing.expect(!list.remote_entry.isDisplayedInTree() and !list.local_entry.isDisplayedInTree());
    try std.testing.expect(host.info_owner == null and host.backgroundIsListening());
    workspace.active_tab = 0;
    host.showInfo();
    settle(cx);
    try std.testing.expect(host.info_owner.?.eql(owner));
    try std.testing.expect(info.read_only and info.current_content.isDisplayedInTree() and !info.footer.isDisplayedInTree());
    try std.testing.expectEqualStrings("#web-tab", info.owner.getText().?.content);
    try std.testing.expectEqualStrings("#9", info.connections_text.getText().?.content);
    try std.testing.expect(list.inline_section.?.root.globalRect().y >= info.rule.globalRect().y + info.rule.globalRect().h);
    try std.testing.expectEqualStrings("1 条", list.inline_section.?.count.getText().?.content);
    // Reusing a tab slot or rotating a generation must not hand its old
    // actions to the replacement, nor treat the app-owned row as the tab.
    application.mappings.items[0].handle = try owner.nextGeneration();
    try std.testing.expect(host.currentForwarding() == null);
    host.showInfo();
    settle(cx);
    try std.testing.expect(info.root.isDisplayedInTree() and !info.current_content.isDisplayedInTree() and host.info_owner == null);
    try std.testing.expect(list.inline_section.?.root.isDisplayedInTree());
    registry.rows.clearRetainingCapacity();
    try list.update(registry.rows.items);
    info.hide();
    host.showInfo();
    try std.testing.expect(!info.open.peek());
}
