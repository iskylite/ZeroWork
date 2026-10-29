//! Controlled loopback acceptance for the production AppHost and SSH mailbox.
//! No native window, provider, user configuration or credential store is used.
const std = @import("std");
pub const application_test_mode = true;
const ui = @import("ui");
const workspace_mod = @import("ui/workspace.zig");
const Application = @import("ui/application_host.zig");
const Config = @import("config/config.zig").Config;
const identity = @import("host/identity.zig");
const realtime = @import("platform/realtime.zig");
const a = std.heap.c_allocator;
pub fn main(init: std.process.Init) !void {
    var args = init.minimal.args.iterate();
    _ = args.next();
    const port = try std.fmt.parseInt(u16, args.next() orelse return error.MissingPort, 10);
    const mode = args.next() orelse return error.MissingMode;
    if (port < 1024) return error.NonFixtureTarget;
    const raw_dir = std.c.getenv("ZEROWORK_DATA_DIR") orelse return error.MissingIsolatedDirectory;
    if (!std.mem.startsWith(u8, std.mem.span(raw_dir), "/tmp/zw-disconnect-")) return error.NonFixtureDirectory;
    const cx = try ui.Cx.init(a, init.io);
    defer cx.deinit();
    const scope = try ui.Scope.init(a, null, cx.owner);
    defer scope.dispose();
    cx.root = try ui.box(cx, .{ .width = .fill(), .height = .fill(), .direction = .column }, .{});
    var nodes: [4]*ui.Node = undefined;
    for (&nodes) |*node| {
        node.* = try ui.box(cx, .{ .width = .fill(), .height = .{ .px = 100 } }, .{});
        try cx.root.?.appendChild(a, node.*);
    }
    cx.setViewport(1100, 720);
    var config: Config = .{};
    config.ssh.connect_timeout_sec = 3;
    config.ssh.auto_reconnect = true;
    config.ssh.reconnect_backoff = .{ 1, 1, 1, 1, 1 };
    config.ssh.buffer_input = true;
    const workspace = try workspace_mod.Workspace.init(a, cx, scope, init.io, &config, "fixture-missing-hosts.toml", nodes[0], nodes[1], nodes[2], nodes[3]);
    const app = try Application.ApplicationHost.init(a, workspace);
    try scope.onCleanup(Application.ApplicationHost, app, Application.ApplicationHost.deinit);
    app.install();
    const first = try app.create(.{ .name = "disconnect-fixture", .host = "127.0.0.1", .port = port, .user = "bootstrap-fixture", .auth_mode = .password, .password = "fixture-only" }, 1, 0, "");
    const source = app.legacyForHandle(first.handle).?;
    defer closeAll(app) catch {};
    try attached(app, source, 1);
    var target = source;
    if (std.mem.eql(u8, mode, "shared")) {
        try workspace.reuseSessionFromTab(workspace.tabIndex(source).?);
        target = workspace.tabs.items[1].id;
        try attached(app, target, 1);
    }
    const handle = app.ownerForLegacy(target).?;
    const tab = workspace.sessionTab(target).?;
    const original_tab = tab.tab_id;
    const original_root = tab.root;
    const runtime = tab.runtime.?;
    const native: *@import("ui/session_runtime.zig").SessionRuntime = @ptrCast(@alignCast(runtime.context));
    const worker = native.worker;
    const vt = worker.vt.terminal;
    try send(app, target, "printf 'DISCONNECT_%s\\n' PRESERVED\n");
    try contains(app, target, "DISCONNECT_PRESERVED");
    const old_service = try runtime.terminalService();
    const old_exec = try app.sshExecService(handle);
    const context: @import("ai/host_tools.zig").Context = .{ .conversation_id = .generate(), .task_id = .generate(), .binding = .{ .session = @backingInt(handle.session_id) }, .binding_revision = 1, .grant_revision = 1 };
    const operation = identity.HostOperationId.generate();
    const blocked = try old_exec.exec("uname", .{ .call_id = 986, .capture_cap = 1024, .key = app.sessions.queryState(handle).?.create_operation });
    if (app.preflightSessionDisconnect(handle)) |_| return error.ActiveExecWasDisconnected else |err| {
        if (err != error.ActiveExecutionConflict and err != error.WorkerBusy) return err;
    }
    const exec_deadline = realtime.monotonicNs() + 2 * std.time.ns_per_s;
    while (old_exec.poll(blocked) == null and realtime.monotonicNs() < exec_deadline) try tick(app);
    if (old_exec.poll(blocked) == null) return error.FixtureExecTimeout;
    const close_deadline = realtime.monotonicNs() + 2 * std.time.ns_per_s;
    while (realtime.monotonicNs() < close_deadline) {
        const cleanup = old_exec.closeCall(blocked) catch |err| {
            if (err != error.WorkerBusy) return err;
            try tick(app);
            continue;
        };
        if (cleanup == .released) break;
        try tick(app);
    }
    const Risk = struct {
        fn active(_: ?*anyopaque, _: workspace_mod.SessionId) workspace_mod.CloseRisk {
            return .{ .transfer = true, .socks = true };
        }
    };
    const previous_close = workspace.close_bridge;
    workspace.close_bridge = .{ .risk = Risk.active };
    const risk_result = app.preflightSessionDisconnect(handle);
    workspace.close_bridge = previous_close;
    if (risk_result) |_| return error.ActiveTransferForwardWasDisconnected else |err| if (err != error.ActiveReference) return err;
    const before = try preflight(app, handle);
    if (app.requestSessionDisconnect(operation, context, handle, before.create_operation, before.binding, before.impact_revision +% 1)) |_| return error.StaleImpactAccepted else |err| if (err != error.ScopeChanged) return err;
    if (app.disconnects.entries.items.len != 0) return error.RejectedPreflightDispatched;
    std.debug.print("DISCONNECT_PREFLIGHT active_exec=blocked transfer_forward=blocked stale_impact=blocked\n", .{});
    const accepted = try app.requestSessionDisconnect(operation, context, handle, before.create_operation, before.binding, before.impact_revision);
    if (accepted.state != .pending or accepted.local_released) return error.FalseSynchronousRelease;
    if (old_exec.exec("printf NEVER_AFTER_DISCONNECT", .{ .call_id = 987, .capture_cap = 1024, .key = before.create_operation })) |_| return error.OldExecAccepted else |err| {
        if (err != error.BridgeClosed and err != error.SessionNotActive and err != error.StaleSession) return err;
        std.debug.print("OLD_EXEC_REJECTED {s}\n", .{@errorName(err)});
    }
    if (worker.input.pending() != 0) return error.OldInputRetained;
    const released = try disconnected(app, operation, context);
    if (!released.local_released or released.remote_effect_unknown) return error.MissingRealRelease;
    const repeated = try app.requestSessionDisconnect(operation, context, handle, before.create_operation, before.binding, before.impact_revision);
    if (repeated.state != .disconnected or app.disconnects.entries.items.len != 1) return error.DisconnectRedispatched;
    if (app.sessions.bindingIsLive(old_service.binding)) return error.OldBindingRevived;
    if (workspace.sessionTab(target) != tab or tab.tab_id != original_tab or tab.root != original_root or native.worker != worker or worker.vt.terminal != vt or runtime.torn_down) return error.DisconnectDestroyedPane;
    const retained = try worker.searchText(a);
    defer a.free(retained);
    if (std.mem.indexOf(u8, retained, "DISCONNECT_PRESERVED") == null) return error.DisconnectLostOutput;
    const idle_until = realtime.monotonicNs() + 1500 * std.time.ns_per_ms;
    while (realtime.monotonicNs() < idle_until) try tick(app);
    if (!app.ownerForLegacy(target).?.eql(handle) or app.sessions.queryState(handle).?.lifecycle != .failed or !native.thread.explicit_disconnect_active.load(.acquire)) return error.AutomaticReconnectOccurred;
    if (worker.pushInputFrom("printf NEVER_BUFFERED_AFTER_DISCONNECT\n", .ordinary)) |_| return error.OldInputAccepted else |err| {
        if (err != error.DisconnectedApplicationInput and err != error.SessionNotWritable and err != error.TerminalClosed and err != error.SessionClosed and err != error.DisconnectedInputDisabled) return err;
        std.debug.print("OLD_INPUT_REJECTED {s}\n", .{@errorName(err)});
    }
    if (worker.input.pending() != 0) return error.DisconnectedInputQueued;
    if (std.mem.eql(u8, mode, "shared")) {
        if (app.sessions.queryState(first.handle).?.lifecycle != .attached) return error.SiblingDisconnected;
        try send(app, source, "printf 'SIBLING_%s\\n' STILL_ALIVE\n");
        try contains(app, source, "SIBLING_STILL_ALIVE");
    }
    try app.requestSshReconnect(target);
    try attached(app, target, handle.generation + 1);
    const next = app.ownerForLegacy(target).?;
    if (next.eql(handle) or app.sessions.bindingIsLive(old_service.binding)) return error.OldGenerationRevived;
    if (workspace.sessionTab(target) != tab or native.worker != worker or worker.vt.terminal != vt) return error.ReconnectReplacedPane;
    try send(app, target, "printf 'EXPLICIT_%s\\n' NEW_GENERATION\n");
    try contains(app, target, "EXPLICIT_NEW_GENERATION");
    std.debug.print("DISCONNECT_OK mode={s} original_generation={d} new_generation={d} same_tab=true same_vt=true actual_release=true automatic_reconnect=false operations={d}\n", .{ mode, handle.generation, next.generation, app.disconnects.entries.items.len });
}
fn tick(app: *Application.ApplicationHost) !void {
    _ = try app.safeTick();
    // This headless process stands in for the native frame consumer.
    for (app.workspace.tabs.items) |tab| if (tab.runtime) |runtime| if (!runtime.torn_down) {
        _ = runtime.textSlot().acknowledge(0);
    };
    if (app.workspace.pendingAuthentication()) |challenge| {
        if (challenge.kind != .host_key_unknown) return error.UnexpectedFixtureAuthentication;
        try app.workspace.submitAuthentication(challenge.identity, .trust_once);
    }
    app.workspace.cx.advanceFrameClock();
    app.workspace.cx.layout();
    _ = app.workspace.cx.render();
    var duration: std.c.timespec = .{ .sec = 0, .nsec = 5 * std.time.ns_per_ms };
    _ = std.c.nanosleep(&duration, null);
}
fn attached(app: *Application.ApplicationHost, id: workspace_mod.SessionId, generation: u64) !void {
    const deadline = realtime.monotonicNs() + 8 * std.time.ns_per_s;
    while (realtime.monotonicNs() < deadline) {
        try tick(app);
        const handle = app.ownerForLegacy(id) orelse continue;
        if (handle.generation == generation and app.sessions.queryState(handle).?.lifecycle == .attached) return;
    }
    return error.FixtureAttachTimeout;
}
fn preflight(app: *Application.ApplicationHost, handle: identity.SessionHandle) !Application.DisconnectPreflight {
    const deadline = realtime.monotonicNs() + 3 * std.time.ns_per_s;
    while (realtime.monotonicNs() < deadline) {
        if (app.preflightSessionDisconnect(handle)) |value| return value else |err| if (err != error.WorkerBusy and err != error.ActiveExecutionConflict and err != error.ActiveReference) return err;
        try tick(app);
    }
    return error.FixturePreflightTimeout;
}
fn disconnected(app: *Application.ApplicationHost, operation: identity.HostOperationId, context: @import("ai/host_tools.zig").Context) !Application.DisconnectSnapshot {
    const deadline = realtime.monotonicNs() + 6 * std.time.ns_per_s;
    while (realtime.monotonicNs() < deadline) {
        try tick(app);
        const value = try app.querySessionDisconnect(operation, context);
        if (value.state == .outcome_unknown) return error.FixtureDisconnectUnknown;
        if (value.state == .disconnected) return value;
    }
    return error.FixtureDisconnectTimeout;
}
fn send(app: *Application.ApplicationHost, id: workspace_mod.SessionId, bytes: []const u8) !void {
    const deadline = realtime.monotonicNs() + 2 * std.time.ns_per_s;
    while (realtime.monotonicNs() < deadline) {
        const runtime = app.workspace.sessionTab(id).?.runtime.?;
        runtime.pushInputFrom(bytes, .application) catch |err| {
            if (err != error.DisconnectedApplicationInput and err != error.SessionNotWritable) return err;
            try tick(app);
            continue;
        };
        return;
    }
    return error.FixtureInputTimeout;
}
fn contains(app: *Application.ApplicationHost, id: workspace_mod.SessionId, text: []const u8) !void {
    const deadline = realtime.monotonicNs() + 3 * std.time.ns_per_s;
    while (realtime.monotonicNs() < deadline) {
        try tick(app);
        const bytes = try app.workspace.sessionTab(id).?.runtime.?.searchText(a);
        defer a.free(bytes);
        if (std.mem.indexOf(u8, bytes, text) != null) return;
    }
    return error.FixtureOutputTimeout;
}
fn closeAll(app: *Application.ApplicationHost) !void {
    for (app.mappings.items) |mapping| _ = try app.requestCloseLegacy(mapping.legacy_id);
    const deadline = realtime.monotonicNs() + 5 * std.time.ns_per_s;
    while (realtime.monotonicNs() < deadline) {
        try tick(app);
        var done = true;
        for (app.mappings.items) |mapping| if (app.sessions.queryState(mapping.handle).?.lifecycle != .closed) {
            done = false;
            break;
        };
        if (done) return;
    }
    return error.FixtureCloseTimeout;
}
