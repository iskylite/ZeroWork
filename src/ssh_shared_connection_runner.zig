//! Headless original-pane reconnect driver; connects only to a local fixture.
const std = @import("std");
pub const application_test_mode = true;
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
    const requested_directory = std.c.getenv("ZEROWORK_DATA_DIR") orelse return error.MissingIsolatedDataDirectory;
    var data_paths = try @import("config/paths.zig").Paths.forApplication(allocator);
    defer data_paths.deinit();
    if (!data_paths.is_override or !std.mem.eql(u8, data_paths.directory, std.mem.span(requested_directory))) return error.DataDirectoryNotIsolated;
    std.debug.print("ISOLATED_DATA_DIR_VERIFIED\n", .{});
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
    {
        const service = try app.workspace.sessionTab(source).?.runtime.?.terminalService();
        const capability = try service.executionSnapshot();
        if (capability.interactive_execution or capability.state != .unavailable) return error.FalseSshExecutionCapability;
        const queued_before = native(app, source).worker.input.pending();
        service.executionRequest(.{ .execution_id = .generate(), .task_id = .generate(), .expected_input_epoch = 0, .ownership_revision = 1, .command = "printf NEVER_INJECTED", .command_hash = @import("host/terminal_execution.zig").digest("printf NEVER_INJECTED") }) catch |err| {
            if (err != error.IntegrationUnavailable) return err;
            if (native(app, source).worker.input.pending() != queued_before) return error.UnsupportedPtyInjectedInput;
            std.debug.print("TRUSTED_PTY_UNAVAILABLE_NO_INPUT\n", .{});
        };
    }
    if (std.mem.eql(u8, scenario, "owned-session") or std.mem.eql(u8, scenario, "owned-saved")) {
        try ownedSessionScenario(app, source, std.mem.eql(u8, scenario, "owned-saved"));
        return;
    }
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
    if (std.mem.eql(u8, scenario, "details")) {
        const original = try onlineDetails(app, source);
        try sameTransportDetails(original, try onlineDetails(app, child));
        try sampleDetails(app, child);
        try restart(app, child);
        try sameTransportDetails(original, try onlineDetails(app, child));
        try sampleDetails(app, child);
        try closeOne(app, source);
        // Details and new samples belong to the surviving tab, even after
        // the tab that authenticated the transport has been destroyed.
        try sameTransportDetails(original, try onlineDetails(app, child));
        try sampleDetails(app, child);
        try workspace.reuseSessionFromTab(workspace.tabIndex(child).?);
        const sibling = workspace.tabs.items[workspace.tabs.items.len - 1].id;
        try attached(app, sibling, 1);
        try sameTransportDetails(original, try onlineDetails(app, sibling));
        try sampleDetails(app, sibling);
        try probe(app, child);
        try probe(app, sibling);
        try closeOne(app, sibling);
        try closeOne(app, child);
        std.debug.print("SHARED_DETAILS_OK online=true metadata=true generations=true rtt_all_hops=true source_closed=true\n", .{});
        return;
    }
    if (std.mem.eql(u8, scenario, "reconnect-fallback")) {
        try reconnectFallback(app, source, child, init.io, fixture orelse return error.MissingFixture);
        return;
    }
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

fn ownedTick(app: *ApplicationHost) !void {
    try tick(app);
    app.workspace.cx.advanceFrameClock();
    app.workspace.cx.layout();
    _ = app.workspace.cx.render();
}

fn ownedSessionScenario(app: *ApplicationHost, source: u64, with_saved_source: bool) !void {
    const identity = @import("host/identity.zig");
    const lifecycle = @import("host/lifecycle_supervisor.zig");
    const workspace = app.workspace;
    var roster = @import("ui/group_model.zig").Roster.init(std.heap.c_allocator);
    defer roster.deinit();
    defer {
        for (workspace.tabs.items) |tab| _ = app.requestCloseLegacy(tab.id) catch {};
        const end = realtime.monotonicNs() + 8 * std.time.ns_per_s;
        while (workspace.tabs.items.len > 0 and realtime.monotonicNs() < end) ownedTick(app) catch break;
        workspace.group_roster = null;
    }
    var prepared = try roster.prepareNew("owned-loopback", 0xff00ffff, source);
    defer prepared.deinit();
    const group_id = try prepared.commit();
    try workspace.openGroup(&roster, group_id);
    const source_owner = app.ownerForLegacy(source).?;
    var request: lifecycle.OpenRequest = .{ .operation_ref = identity.HostOperationId.generate(), .context = .{ .conversation_id = identity.ConversationId.generate(), .task_id = identity.TaskId.generate(), .binding = .{ .group = group_id }, .binding_revision = 2, .grant_revision = 1 }, .group = .{ .id = @fromBackingInt(group_id) }, .source = source_owner, .connection_policy = .reuse_only, .retention = .auto_idle };
    _ = try app.queueOwnedSession(request);
    try ownedTick(app);
    var opened = try app.queryOwnedSession(request.operation_ref, request.context);
    if (opened.state != .prepared or workspace.tabs.items.len != 1 or app.findHandle(opened.session.?) != null or roster.findById(group_id).?.members.items.len != 1) return error.ReservationAcquiredNativeResource;
    // Test acknowledgement stands in for the journal owner's durable permit.
    _ = try app.authorizeOwnedSessionDispatch(request.operation_ref, request.context, opened.revision, opened.session.?);
    const deadline = realtime.monotonicNs() + 8 * std.time.ns_per_s;
    while (opened.state != .ready and realtime.monotonicNs() < deadline) {
        try ownedTick(app);
        opened = try app.queryOwnedSession(request.operation_ref, request.context);
        if (opened.state == .failed or opened.state == .cleanup_pending) return error.OwnedCreateFailed;
    }
    if (opened.state != .ready or !opened.membership_committed) return error.OwnedReadyTimeout;
    const child = app.legacyForHandle(opened.session.?).?;
    if (native(app, source).worker.shared_connection != native(app, child).worker.shared_connection) return error.CreatedAnotherTransport;
    try send(app, child, "test -z \"$SOURCE_ONLY\" && printf 'OWNED_INDEPENDENT_%s\n' CONTEXT\n");
    try contains(app, child, "OWNED_INDEPENDENT_CONTEXT");
    _ = try app.queueOwnedSession(request);
    try ownedTick(app);
    if (workspace.tabs.items.len != 2 or roster.findById(group_id).?.members.items.len != 2) return error.DuplicateOwnedMember;
    request.operation_ref = identity.HostOperationId.generate();
    _ = try app.queueOwnedSession(request);
    try ownedTick(app);
    const cancelled = try app.queryOwnedSession(request.operation_ref, request.context);
    _ = try app.cancelOwnedSession(request.operation_ref, request.context);
    for (0..3) |_| try ownedTick(app);
    if ((try app.queryOwnedSession(request.operation_ref, request.context)).state != .cancelled or app.findHandle(cancelled.session.?) != null) return error.PreparedCancelTouchedFactory;
    const close_operation = identity.HostOperationId.generate();
    _ = try app.queueSessionClose(close_operation, request.context, opened.session.?, true);
    try ownedTick(app);
    if (app.sessions.queryState(opened.session.?).?.close_operation != null) return error.CloseRanBeforeResultAcknowledgement;
    try app.acknowledgeSessionCloseResult(close_operation);
    while ((try app.querySessionClose(close_operation, request.context)).state != .closed and realtime.monotonicNs() < deadline) try ownedTick(app);
    if (workspace.sessionTab(child) != null or roster.findById(group_id).?.members.items.len != 1) return error.OwnedCloseLeftGhost;
    if (app.sessions.queryState(source_owner).?.lifecycle != .attached) return error.BorrowedSourceClosed;
    try probe(app, source);
    if (with_saved_source) {
        var saved = workspace.sessionTab(source).?.host_snapshot.?.value;
        saved.connection_id = @fromBackingInt(9901);
        saved.revision = 1;
        saved.name = "owned-saved-source";
        const index = try workspace.appendHost(saved);
        request.operation_ref = identity.HostOperationId.generate();
        request.source = null;
        request.saved_source = .{ .id = workspace.registry.hosts[index].connection_id, .revision = workspace.registry.hosts[index].revision };
        request.connection_policy = .reuse_only;
        if (app.queueOwnedSession(request)) |_| return error.SavedReuseOpenedConnection else |err| if (err != error.ReuseUnavailable) return err;
        request.connection_policy = .prefer_reuse;
        if (app.queueOwnedSession(request)) |_| return error.SavedFallbackBypassedAuthorization else |err| if (err != error.FallbackAuthorizationRequired) return err;
        request.connection_policy = .new_only;
        _ = try app.queueOwnedSession(request);
        try ownedTick(app);
        var saved_snapshot = try app.queryOwnedSession(request.operation_ref, request.context);
        if (saved_snapshot.state != .prepared or saved_snapshot.source != null or saved_snapshot.saved_source == null) return error.SavedSourceBecameFakeSession;
        _ = try app.authorizeOwnedSessionDispatch(request.operation_ref, request.context, saved_snapshot.revision, saved_snapshot.session.?);
        const saved_deadline = realtime.monotonicNs() + 8 * std.time.ns_per_s;
        while (saved_snapshot.state != .ready and realtime.monotonicNs() < saved_deadline) {
            try ownedTick(app);
            saved_snapshot = try app.queryOwnedSession(request.operation_ref, request.context);
            if (saved_snapshot.state == .failed or saved_snapshot.state == .cleanup_pending) return error.SavedOwnedCreateFailed;
        }
        if (saved_snapshot.state != .ready) return error.SavedOwnedReadyTimeout;
        const saved_child = app.legacyForHandle(saved_snapshot.session.?).?;
        if (native(app, source).worker.shared_connection == native(app, saved_child).worker.shared_connection) return error.SavedNewOnlyReusedTransport;
        try send(app, saved_child, "test -z \"$SOURCE_ONLY\" && printf 'SAVED_OWNED_%s\n' INDEPENDENT\n");
        try contains(app, saved_child, "SAVED_OWNED_INDEPENDENT");
        try probe(app, source);
        std.debug.print("OWNED_SAVED_SOURCE_OK real_asset_identity=true no_fake_session=true reuse_only_zero_connect=true fallback_authorized=true independent_transport=true\n", .{});
    }
    std.debug.print("OWNED_SESSION_OK reserved_zero_native=true reuse_one_transport=true unique_ready_member=true independent_shell=true cancellation_zero_native=true close_after_result=true borrowed_source_survives=true\n", .{});
}
const Details = @import("proto/ssh/connection_details.zig");
fn onlineDetails(app: *ApplicationHost, id: u64) !Details.ConnectionDetailsSnapshot {
    const owner = app.ownerForLegacy(id) orelse return error.MissingOwner;
    const deadline = realtime.monotonicNs() + 3 * std.time.ns_per_s;
    while (true) {
        const snapshot = app.sshConnectionDetails(owner) catch |err| {
            if (err != error.WorkerBusy or realtime.monotonicNs() >= deadline) return err;
            try tick(app);
            continue;
        };
        if (!snapshot.key.owner.session.eql(owner)) return error.WrongDetailsOwner;
        for (snapshot.hops[0..snapshot.hop_count]) |hop| {
            if (!hop.configured or hop.status != .online) return error.DetailsNotOnline;
            if (hop.metadata.cipher_c2s.len == 0 or hop.metadata.cipher_s2c.len == 0 or hop.metadata.fingerprint.len == 0 or hop.metadata.host_key_algorithm.len == 0) return error.MissingNegotiatedMetadata;
        }
        return snapshot;
    }
}
fn sameTransportDetails(expected: Details.ConnectionDetailsSnapshot, actual: Details.ConnectionDetailsSnapshot) !void {
    if (expected.hop_count != actual.hop_count) return error.WrongDetailsRoute;
    for (expected.hops[0..expected.hop_count], actual.hops[0..actual.hop_count]) |before, after| {
        if (!std.meta.eql(before.endpoint, after.endpoint) or !std.meta.eql(before.metadata, after.metadata)) return error.TransportDetailsChanged;
    }
}
fn sampleDetails(app: *ApplicationHost, id: u64) !void {
    const owner = app.ownerForLegacy(id) orelse return error.MissingOwner;
    const deadline = realtime.monotonicNs() + 5 * std.time.ns_per_s;
    const request = while (true) {
        const request = app.requestSshRtt(owner, null) catch |err| {
            if ((err != error.SampleBusy and err != error.WorkerBusy) or realtime.monotonicNs() >= deadline) return err;
            try tick(app);
            continue;
        };
        break request;
    };
    while (realtime.monotonicNs() < deadline) {
        try tick(app);
        const snapshot = app.sshConnectionDetails(owner) catch |err| {
            if (err == error.WorkerBusy) continue;
            return err;
        };
        var ready = true;
        for (snapshot.hops[0..snapshot.hop_count]) |hop| {
            const sample = hop.rtt_sample orelse return error.MissingRttSample;
            if (sample.request_id != request) return error.WrongRttOwner;
            if (sample.status == .unavailable) return error.RttUnavailable;
            ready = ready and sample.status == .ready and sample.cleanup == .released;
        }
        if (ready) return;
    }
    return error.RttTimeout;
}
fn reconnectFallback(app: *ApplicationHost, source: u64, child: u64, io: std.Io, fixture: []const u8) !void {
    try sampleDetails(app, source);
    try sampleDetails(app, child);
    try send(app, child, "exit\n");
    try ended(app, child);
    try send(app, source, "printf 'ZW_ARM_REUSE_HOLD_%s\n' READY\n");
    try contains(app, source, "ZW_ARM_REUSE_HOLD_READY");
    try app.requestSshReconnect(child);
    const held = try std.fs.path.join(std.heap.c_allocator, &.{ fixture, "held-request.json" });
    defer std.heap.c_allocator.free(held);
    const deadline = realtime.monotonicNs() + 4 * std.time.ns_per_s;
    while (true) {
        std.Io.Dir.cwd().access(io, held, .{}) catch {
            if (realtime.monotonicNs() >= deadline) return error.PeerDidNotHoldRequest;
            try tick(app);
            continue;
        };
        break;
    }
    const drop = try std.fs.path.join(std.heap.c_allocator, &.{ fixture, "drop-first" });
    defer std.heap.c_allocator.free(drop);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = drop, .data = "drop" });
    try attached(app, child, 2);
    if (native(app, child).worker.shared_connection != null) return error.SharedOwnerRetainedAfterFallback;
    _ = try onlineDetails(app, child);
    try sampleDetails(app, child);
    try probe(app, child);
    try closeOne(app, child);
    try closeOne(app, source);
    std.debug.print("RECONNECT_FALLBACK_OK independent=true online=true rtt=true terminal_io=true closed=true\n", .{});
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
