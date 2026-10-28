//! Headless original-pane reconnect driver; connects only to a local fixture.
const std = @import("std");
const ui = @import("ui");
const workspace_mod = @import("ui/workspace.zig");
const ApplicationHost = @import("ui/application_host.zig").ApplicationHost;
const Config = @import("config/config.zig").Config;
const realtime = @import("platform/realtime.zig");
const session_host = @import("host/session_host.zig");

pub fn main(init: std.process.Init) !void {
    var args = init.minimal.args.iterate();
    _ = args.next();
    const port = try std.fmt.parseInt(u16, args.next() orelse return error.MissingPort, 10);

    const hop_value = if (args.next()) |value| try std.fmt.parseInt(u16, value, 10) else 0;
    const jump_port: ?u16 = if (hop_value == 0) null else hop_value;
    const scenario = args.next() orelse "baseline";
    const fixture = args.next();
    const allocator = std.heap.c_allocator;
    const cx = try ui.Cx.init(allocator, init.io);
    defer cx.deinit();
    const scope = try ui.Scope.init(allocator, null, cx.owner);
    defer scope.dispose();
    const root = try ui.box(cx, .{ .width = .fill(), .height = .fill(), .direction = .column }, .{});
    cx.root = root;
    const strip = try ui.box(cx, .{ .width = .fill(), .height = .{ .px = 46 } }, .{});
    try root.appendChild(allocator, strip);
    const area = try ui.box(cx, .{ .width = .fill(), .height = .fill() }, .{});
    try root.appendChild(allocator, area);
    const empty = try ui.box(cx, .{}, .{});
    try area.appendChild(allocator, empty);
    const sidebar = try ui.box(cx, .{ .display = .none }, .{});
    try root.appendChild(allocator, sidebar);
    var config: Config = .{};
    config.ssh.connect_timeout_sec = 2;
    config.ssh.reconnect_backoff = .{ 1, 1, 1, 1, 1 };
    config.ssh.auto_reconnect = false;
    const workspace = try workspace_mod.Workspace.init(allocator, cx, scope, init.io, &config, "fixture-missing-hosts.toml", sidebar, strip, area, empty);
    const app = try ApplicationHost.init(allocator, workspace);
    try scope.onCleanup(ApplicationHost, app, ApplicationHost.deinit);
    app.install();
    cx.setViewport(1100, 720);

    const HopId = @import("host/identity.zig").ConnectionId;
    var route: [1]HopId = undefined;
    if (jump_port) |value| {
        const hop = try workspace.registry.add(.{ .name = "shared-jump", .host = "127.0.0.1", .port = value, .user = "operator", .auth_mode = .password, .password = "fixture-password" });
        route[0] = hop.id;
    }
    const accepted = try app.create(.{ .route = if (jump_port != null) &route else &.{}, .connection_id = @fromBackingInt(77), .revision = 6, .name = "shared-loopback", .host = "127.0.0.1", .port = port, .user = "records-fixture", .auth_mode = .password, .password = "records-secret" }, 1, 0, "");
    const source = app.legacyForHandle(accepted.handle).?;
    defer cleanup(app);
    try attached(app, source, 1);
    try send(app, source, "export SOURCE_ONLY=source; printf 'SOURCE_MARKER\n'\n");
    try contains(app, source, "SOURCE_MARKER");
    const pending_scene = std.mem.startsWith(u8, scenario, "cancel-") or std.mem.startsWith(u8, scenario, "timeout-");
    if (pending_scene) {
        try send(app, source, "printf 'ZW_ARM_REUSE_HOLD_%s\n' READY\n");
        try contains(app, source, "ZW_ARM_REUSE_HOLD_READY");
    }
    try workspace.reuseSessionFromTab(workspace.tabIndex(source).?);
    const child = workspace.tabs.items[1].id;
    if (pending_scene) {
        try pendingShellScenario(app, source, child, scenario, init.io, fixture orelse return error.MissingFixture);
        return;
    }
    try attached(app, child, 1);
    try send(app, child, "test -z \"$SOURCE_ONLY\" && printf 'INDEPENDENT_%s\n' CONTEXT\n");
    try contains(app, child, "INDEPENDENT_CONTEXT");
    if (std.mem.eql(u8, scenario, "jump-forwards")) {
        if (jump_port == null) return error.MissingJump;
        try jumpForwardScenario(app, source, child, port);
        return;
    }
    if (std.mem.eql(u8, scenario, "eof-loss")) {
        try send(app, child, "exit\n");
        try ended(app, source);
        try ended(app, child);
        try app.requestSshReconnect(source);
        try app.requestSshReconnect(child);
        try attached(app, source, 2);
        try attached(app, child, 2);
        try probe(app, source);
        try probe(app, child);
        try closeOne(app, child);
        try closeOne(app, source);
        std.debug.print("EOF_LOSS_OK both_recovered=true all_closed=true\n", .{});
        return;
    }
    if (!std.mem.eql(u8, scenario, "baseline")) {
        try lifecycleScenario(app, source, child, scenario);
        return;
    }
    if (jump_port != null) {
        _ = try app.requestCloseLegacy(source);
        const deadline = realtime.monotonicNs() + 5 * std.time.ns_per_s;
        while (workspace.sessionTab(source) != null and realtime.monotonicNs() < deadline) try tick(app);
        if (workspace.sessionTab(source) != null) return error.SourceCloseTimeout;
        try restart(app, child);
        try send(app, child, "printf 'JUMP_CHILD_%s\n' SURVIVES\n");
        try contains(app, child, "JUMP_CHILD_SURVIVES");
        _ = try app.requestCloseLegacy(child);
        while (workspace.tabs.items.len != 0 and realtime.monotonicNs() < deadline) try tick(app);
        if (workspace.tabs.items.len != 0) return error.ChildCloseTimeout;
        std.debug.print("SHARED_JUMP_OK original_closed=true child_io=true final_closed=true\n", .{});
        return;
    }
    // Reused tabs keep the live transport, including consecutive reconnects.
    try restart(app, child);
    try restart(app, child);
    try restart(app, source);
    try send(app, child, "printf 'CHILD_SURVIVES_SOURCE_%s\n' RECONNECT\n");
    try contains(app, child, "CHILD_SURVIVES_SOURCE_RECONNECT");
    try send(app, source, "printf 'SOURCE_SURVIVES_CHILD_%s\n' RECONNECT\n");
    try contains(app, source, "SOURCE_SURVIVES_CHILD_RECONNECT");
    try workspace.reuseSessionFromTab(workspace.tabIndex(source).?);
    const sibling = workspace.tabs.items[workspace.tabs.items.len - 1].id;
    try attached(app, sibling, 1);
    const lease = try workspace.sessionTab(source).?.runtime.?.reuseConnection();
    const group: *@import("vt/shared_ssh_connection.zig").Connection = @ptrCast(@alignCast(lease.context));
    group.lock();
    @import("generated_ssh_session").zw_libssh2_session_abort_io(group.native.handle.?, group.native.socket_fd);
    group.unlock();
    lease.release();
    try ended(app, source);
    try ended(app, sibling);
    try app.requestSshReconnect(source);
    try attached(app, source, 3);
    try app.requestSshReconnect(sibling);
    try attached(app, sibling, 2);
    for ([_]u64{ source, child, sibling }) |id| {
        _ = try app.requestCloseLegacy(id);
    }
    const deadline = realtime.monotonicNs() + 5 * std.time.ns_per_s;
    while (workspace.tabs.items.len != 0 and realtime.monotonicNs() < deadline) {
        try tick(app);
    }
    if (workspace.tabs.items.len != 0) return error.CloseNotReleased;
    std.debug.print("SHARED_CONNECTION_OK independent_context=true source_reconnect=true child_reconnect=true transport_loss=true closed=true\n", .{});
}
fn tick(app: *ApplicationHost) !void {
    _ = try app.safeTick();
    // Stand in for the native window's frame consumer in this headless run.
    for (app.workspace.tabs.items) |tab| if (tab.runtime) |runtime| if (!runtime.torn_down) {
        _ = runtime.textSlot().acknowledge(0);
    };
    if (app.workspace.pendingAuthentication()) |challenge| try app.workspace.submitAuthentication(challenge.identity, .trust_once);
    var delay: std.c.timespec = .{ .sec = 0, .nsec = 2 * std.time.ns_per_ms };
    _ = std.c.nanosleep(&delay, null);
}
fn attached(app: *ApplicationHost, id: u64, generation: u64) !void {
    const deadline = realtime.monotonicNs() + 8 * std.time.ns_per_s;
    while (realtime.monotonicNs() < deadline) {
        try tick(app);
        const owner = app.ownerForLegacy(id) orelse return error.MissingOwner;
        const state = app.sessions.queryState(owner).?;
        if (state.lifecycle == .attached and owner.generation == generation) return;
    }
    if (app.workspace.sessionTab(id)) |tab| if (tab.runtime) |runtime| {
        std.debug.print("ATTACH_TIMEOUT id={d} expected={d} actual={d} control={any} state={any}\n", .{ id, generation, app.ownerForLegacy(id).?.generation, runtime.reconnectSnapshot(), app.sessions.queryState(app.ownerForLegacy(id).?).?.lifecycle });
    };
    return error.AttachTimeout;
}
fn ended(app: *ApplicationHost, id: u64) !void {
    const deadline = realtime.monotonicNs() + 8 * std.time.ns_per_s;
    while (realtime.monotonicNs() < deadline) {
        try tick(app);
        const state = app.sessions.queryState(app.ownerForLegacy(id).?).?;
        if ((state.lifecycle == .ended or state.lifecycle == .failed) and state.create_cleanup == .released) return;
    }
    return error.EndTimeout;
}
fn restart(app: *ApplicationHost, id: u64) !void {
    const generation = app.ownerForLegacy(id).?.generation;
    const runtime: *@import("ui/session_runtime.zig").SessionRuntime = @ptrCast(@alignCast(app.workspace.sessionTab(id).?.runtime.?.context));
    const terminal = runtime.worker.vt.terminal;
    const group = runtime.worker.shared_connection;
    const reuse = runtime.worker.prefer_shared_reconnect and group != null;
    const allocator = std.heap.c_allocator;
    const command = try std.fmt.allocPrint(allocator, "printf 'RECONNECT_HISTORY_{d}_%s\n' {d}\n", .{ id, generation });
    defer allocator.free(command);
    const marker = try std.fmt.allocPrint(allocator, "RECONNECT_HISTORY_{d}_{d}", .{ id, generation });
    defer allocator.free(marker);
    try send(app, id, command);
    try contains(app, id, marker);
    try send(app, id, "exit\n");
    try ended(app, id);
    try app.requestSshReconnect(id);
    try attached(app, id, generation + 1);
    if (runtime.worker.vt.terminal != terminal) return error.TerminalReplaced;
    if (reuse and runtime.worker.shared_connection != group) return error.LiveTransportNotReused;
    if (!reuse and runtime.worker.shared_connection != null) return error.IndependentModeChanged;
    try contains(app, id, marker);
}
fn send(app: *ApplicationHost, id: u64, bytes: []const u8) !void {
    const deadline = realtime.monotonicNs() + 3 * std.time.ns_per_s;
    while (realtime.monotonicNs() < deadline) {
        app.workspace.sessionTab(id).?.runtime.?.pushInputFrom(bytes, .application) catch |err| {
            if (err == error.DisconnectedApplicationInput) {
                try tick(app);
                continue;
            }
            return err;
        };
        return;
    }
    return error.InputTimeout;
}
fn contains(app: *ApplicationHost, id: u64, needle: []const u8) !void {
    const deadline = realtime.monotonicNs() + 3 * std.time.ns_per_s;
    while (realtime.monotonicNs() < deadline) {
        try tick(app);
        const text = try app.workspace.sessionTab(id).?.runtime.?.searchText(std.heap.c_allocator);
        defer std.heap.c_allocator.free(text);
        if (std.mem.indexOf(u8, text, needle) != null) return;
    }
    return error.OutputTimeout;
}

fn cleanup(app: *ApplicationHost) void {
    for (app.workspace.tabs.items) |tab| {
        _ = app.requestCloseLegacy(tab.id) catch continue;
    }
    const deadline = realtime.monotonicNs() + 5 * std.time.ns_per_s;
    while (app.workspace.tabs.items.len != 0 and realtime.monotonicNs() < deadline) tick(app) catch break;
}

fn lifecycleScenario(app: *ApplicationHost, source: u64, child: u64, scenario: []const u8) !void {
    const workspace = app.workspace;
    var ids = [4]u64{ source, child, 0, 0 };
    for (ids[2..]) |*id| {
        try workspace.reuseSessionFromTab(workspace.tabIndex(source).?);
        id.* = workspace.tabs.items[workspace.tabs.items.len - 1].id;
        try attached(app, id.*, 1);
    }
    if (std.mem.eql(u8, scenario, "simultaneous-live") or std.mem.eql(u8, scenario, "close-during-reconnect")) {
        const group = native(app, child).worker.shared_connection;
        for (ids[1..3]) |id| try send(app, id, "exit\n");
        for (ids[1..3]) |id| try ended(app, id);
        // Both operations are accepted before either can be driven by safeTick.
        for (ids[1..3]) |id| try app.requestSshReconnect(id);
        if (std.mem.eql(u8, scenario, "close-during-reconnect")) {
            // Close the original owner and one retrying borrower before driving
            // either reconnect to attached. The other retry must remain usable.
            _ = try app.requestCloseLegacy(source);
            _ = try app.requestCloseLegacy(child);
            try attached(app, ids[2], 2);
            if (native(app, ids[2]).worker.shared_connection != group) return error.ConcurrentReconnectChangedTransport;
            try probe(app, ids[2]);
            try probe(app, ids[3]);
            const deadline = realtime.monotonicNs() + 8 * std.time.ns_per_s;
            while ((workspace.sessionTab(source) != null or workspace.sessionTab(child) != null) and realtime.monotonicNs() < deadline) try tick(app);
            if (workspace.sessionTab(source) != null or workspace.sessionTab(child) != null) return error.CloseNotReleased;
            try closeOne(app, ids[2]);
            try probe(app, ids[3]);
            try closeOne(app, ids[3]);
            std.debug.print("LIFECYCLE_OK scenario={s} all_closed=true\n", .{scenario});
            return;
        }
        for (ids[1..3]) |id| {
            try attached(app, id, 2);
            if (native(app, id).worker.shared_connection != group) return error.ConcurrentReconnectChangedTransport;
            try probe(app, id);
        }
        try probe(app, source);
        try probe(app, ids[3]);
    } else if (std.mem.eql(u8, scenario, "simultaneous-broken")) {
        const lease = try workspace.sessionTab(source).?.runtime.?.reuseConnection();
        const group: *@import("vt/shared_ssh_connection.zig").Connection = @ptrCast(@alignCast(lease.context));
        group.lock();
        @import("generated_ssh_session").zw_libssh2_session_abort_io(group.native.handle.?, group.native.socket_fd);
        group.unlock();
        lease.release();
        for (ids) |id| try ended(app, id);
        for (ids) |id| try app.requestSshReconnect(id);
        for (ids) |id| {
            try attached(app, id, 2);
            if (native(app, id).worker.shared_connection != null) return error.BrokenTransportNotReplaced;
            try probe(app, id);
        }
    }
    const order: [4]usize = if (std.mem.eql(u8, scenario, "child-first")) .{ 1, 2, 3, 0 } else if (std.mem.eql(u8, scenario, "interleaved")) .{ 2, 0, 3, 1 } else .{ 0, 1, 2, 3 };
    for (order) |index| {
        try closeOne(app, ids[index]);
        // Every remaining native channel must still perform a round-trip.
        for (ids) |id| if (workspace.sessionTab(id) != null) try probe(app, id);
    }
    if (workspace.tabs.items.len != 0) return error.CloseNotReleased;
    std.debug.print("LIFECYCLE_OK scenario={s} all_closed=true\n", .{scenario});
}
fn native(app: *ApplicationHost, id: u64) *@import("ui/session_runtime.zig").SessionRuntime {
    return @ptrCast(@alignCast(app.workspace.sessionTab(id).?.runtime.?.context));
}
var probe_sequence: u64 = 0;
fn probe(app: *ApplicationHost, id: u64) !void {
    probe_sequence += 1;
    const allocator = std.heap.c_allocator;
    const command = try std.fmt.allocPrint(allocator, "printf 'LIFECYCLE_{d}_%s\n' {d}\n", .{ id, probe_sequence });
    defer allocator.free(command);
    const marker = try std.fmt.allocPrint(allocator, "LIFECYCLE_{d}_{d}", .{ id, probe_sequence });
    defer allocator.free(marker);
    try send(app, id, command);
    try contains(app, id, marker);
}
fn closeOne(app: *ApplicationHost, id: u64) !void {
    _ = try app.requestCloseLegacy(id);
    const deadline = realtime.monotonicNs() + 8 * std.time.ns_per_s;
    while (app.workspace.sessionTab(id) != null and realtime.monotonicNs() < deadline) try tick(app);
    if (app.workspace.sessionTab(id) != null) return error.CloseNotReleased;
}

fn pendingShellScenario(app: *ApplicationHost, source: u64, child: u64, scenario: []const u8, io: std.Io, fixture: []const u8) !void {
    const source_runtime = native(app, source);
    const group = source_runtime.worker.shared_connection orelse return error.MissingSharedGroup;
    const child_owner = app.ownerForLegacy(child).?;
    const child_key = app.sessions.queryState(child_owner).?.create_operation;
    const deadline = realtime.monotonicNs() + 5 * std.time.ns_per_s;
    const held = try std.fs.path.join(std.heap.c_allocator, &.{ fixture, "held-request.json" });
    defer std.heap.c_allocator.free(held);
    while (true) {
        std.Io.Dir.cwd().access(io, held, .{}) catch {
            if (realtime.monotonicNs() >= deadline) return error.PeerDidNotHoldRequest;
            try tick(app);
            continue;
        };
        break;
    }
    const cancel = std.mem.startsWith(u8, scenario, "cancel-");
    const started = realtime.monotonicNs();
    if (cancel) _ = try app.sessions.cancel(child_key);
    while (realtime.monotonicNs() < deadline) {
        try tick(app);
        const state = app.sessions.queryState(child_owner).?;
        if (state.lifecycle == .failed and state.create_cleanup == .released) break;
    }
    const state = app.sessions.queryState(child_owner).?;
    if (state.create_cleanup != .released or state.lifecycle != .failed) return error.CancelDidNotRelease;
    if (cancel and realtime.monotonicNs() - started > 500 * std.time.ns_per_ms) return error.CancelWaitedForNetworkTimeout;
    if (!group.isReusable()) return error.CancelBrokeOriginalTransport;
    try probe(app, source);
    try closeOne(app, child);
    if (std.mem.endsWith(u8, scenario, "open")) {
        const release_path = try std.fs.path.join(std.heap.c_allocator, &.{ fixture, "release-held" });
        defer std.heap.c_allocator.free(release_path);
        try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = release_path, .data = "" });
    }
    {
        try app.workspace.reuseSessionFromTab(app.workspace.tabIndex(source).?);
        const next = app.workspace.tabs.items[app.workspace.tabs.items.len - 1].id;
        try attached(app, next, 1);
        try probe(app, next);
        try closeOne(app, next);
    }
    try probe(app, source);
    try closeOne(app, source);
    std.debug.print("PENDING_SHELL_OK scenario={s} original_io=true final_closed=true\n", .{scenario});
}

const ForwardService = @import("proto/ssh/forward_service.zig").Service;
fn startForward(app: *ApplicationHost, id: u64) !*ForwardService {
    const owner = app.ownerForLegacy(id).?;
    const binding = app.sessions.queryService(owner, .forward).available;
    const origin = app.sessions.queryState(owner).?.create_operation;
    const key = try app.sessions.journal.begin(.{ .session = owner }, origin.attempt_id);
    const service = try app.sshForwardService(binding, 0);
    try service.start(origin, binding, key, .{ .requested_port = 0 });
    const deadline = realtime.monotonicNs() + 3 * std.time.ns_per_s;
    while (realtime.monotonicNs() < deadline) {
        try tick(app);
        const value = service.snapshot();
        if (value.phase == .running) {
            _ = try app.sessions.journal.publish(key, .completed, "loopback forward running", null);
            return service;
        }
        if (value.phase == .failed) return value.failure orelse error.ForwardStartFailed;
    }
    return error.ForwardStartTimeout;
}
fn socketTransfer(fd: c_int, bytes: []u8, write: bool) !void {
    const deadline = realtime.monotonicNs() + 3 * std.time.ns_per_s;
    var offset: usize = 0;
    while (offset < bytes.len and realtime.monotonicNs() < deadline) {
        var polls = [_]std.c.pollfd{.{ .fd = fd, .events = if (write) std.posix.POLL.OUT else std.posix.POLL.IN, .revents = 0 }};
        if (std.c.poll(&polls, 1, 20) <= 0) continue;
        const count = if (write) std.c.write(fd, bytes.ptr + offset, bytes.len - offset) else std.c.read(fd, bytes.ptr + offset, bytes.len - offset);
        if (count == 0) return error.ProxyClosed;
        if (count < 0) {
            switch (std.c.errno(count)) {
                .AGAIN, .INTR => continue,
                else => return error.ProxySocketFailed,
            }
        }
        offset += @intCast(count);
    }
    if (offset != bytes.len) return error.ProxyIOTimeout;
}
fn proxyProbe(port: u16, target: u16) !void {
    const c = @import("generated_ssh_session");
    const fd = c.zw_ssh_socket_connect("127.0.0.1", port, 1000);
    if (fd < 0) return error.ProxyNotListening;
    defer c.zw_ssh_socket_close(fd);
    var greeting = [_]u8{ 5, 1, 0 };
    try socketTransfer(fd, &greeting, true);
    var method: [2]u8 = undefined;
    try socketTransfer(fd, &method, false);
    if (!std.mem.eql(u8, &method, &.{ 5, 0 })) return error.ProxyGreetingFailed;
    var request = [_]u8{ 5, 1, 0, 1, 127, 0, 0, 1, @truncate(target >> 8), @truncate(target) };
    try socketTransfer(fd, &request, true);
    var reply: [10]u8 = undefined;
    try socketTransfer(fd, &reply, false);
    if (reply[0] != 5 or reply[1] != 0) return error.ProxyConnectFailed;
    var banner: [4]u8 = undefined;
    try socketTransfer(fd, &banner, false);
    if (!std.mem.eql(u8, &banner, "SSH-")) return error.WrongProxyExit;
}
fn jumpForwardScenario(app: *ApplicationHost, source: u64, child: u64, target: u16) !void {
    try app.workspace.reuseSessionFromTab(app.workspace.tabIndex(source).?);
    const sibling = app.workspace.tabs.items[app.workspace.tabs.items.len - 1].id;
    try attached(app, sibling, 1);
    const primary = try startForward(app, source);
    const first = try startForward(app, child);
    const second = try startForward(app, sibling);
    const primary_port = primary.snapshot().port;
    const first_port = first.snapshot().port;
    const second_port = second.snapshot().port;
    if (first == second or first_port == second_port or primary_port == first_port or primary_port == second_port) return error.ForwardAuthorityShared;
    try proxyProbe(primary_port, target);
    try proxyProbe(first_port, target);
    try proxyProbe(second_port, target);
    try restart(app, child);
    if (try startForward(app, child) != first or first.snapshot().port != first_port) return error.ReconnectLostForwardPort;
    try proxyProbe(first_port, target);
    try closeOne(app, source);
    const source_close_deadline = realtime.monotonicNs() + std.time.ns_per_s;
    while (true) {
        const fd = @import("generated_ssh_session").zw_ssh_socket_connect("127.0.0.1", primary_port, 100);
        if (fd < 0) break;
        @import("generated_ssh_session").zw_ssh_socket_close(fd);
        if (realtime.monotonicNs() >= source_close_deadline) return error.SourceProxySurvivedClose;
        try tick(app);
    }
    try proxyProbe(first_port, target);
    try proxyProbe(second_port, target);
    const binding = app.sessions.queryService(app.ownerForLegacy(child).?, .forward).available;
    _ = first.requestStop(binding);
    const deadline = realtime.monotonicNs() + 3 * std.time.ns_per_s;
    while (first.snapshot().cleanup != .released and realtime.monotonicNs() < deadline) try tick(app);
    if (first.snapshot().cleanup != .released or second.snapshot().phase != .running) return error.ForwardStopNotIsolated;
    const c = @import("generated_ssh_session");
    const stopped_fd = c.zw_ssh_socket_connect("127.0.0.1", first_port, 100);
    if (stopped_fd >= 0) {
        c.zw_ssh_socket_close(stopped_fd);
        return error.StoppedProxyStillListening;
    }
    try proxyProbe(second_port, target);
    try probe(app, child);
    try probe(app, sibling);
    // The upstream IO thread may exit before a tab's detach request. Parent
    // loss must still acknowledge every facade before the Worker is freed.
    const group = native(app, child).worker.shared_connection.?;
    group.lock();
    c.zw_libssh2_session_abort_io(group.native.handle.?, group.native.socket_fd);
    group.unlock();
    try ended(app, child);
    try ended(app, sibling);
    try closeOne(app, child);
    try closeOne(app, sibling);
    std.debug.print("JUMP_FORWARDS_OK independent_ports=true socks_roundtrips=7 reconnect_preserves_port=true source_closed=true stop_isolated=true transport_loss_released=true\n", .{});
}
