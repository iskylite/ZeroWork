//! Headless original-pane reconnect driver; connects only to a local fixture.
const std = @import("std");
const ui = @import("ui");
const workspace_mod = @import("ui/workspace.zig");
const ApplicationHost = @import("ui/application_host.zig").ApplicationHost;
const Config = @import("config/config.zig").Config;
const realtime = @import("platform/realtime.zig");
const session_host = @import("host/session_host.zig");
const auth = @import("proto/ssh/auth_challenge.zig");

pub fn main(init: std.process.Init) !void {
    var args = init.minimal.args.iterate();
    _ = args.next();
    const port = try std.fmt.parseInt(u16, args.next() orelse return error.MissingPort, 10);
    const mode = args.next() orelse return error.MissingMode;
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
    const automatic = std.mem.eql(u8, mode, "automatic");
    config.ssh.auto_reconnect = automatic or std.mem.eql(u8, mode, "manual-race");
    config.ssh.reconnect_max = if (automatic) 1 else 0;
    if (std.mem.eql(u8, mode, "manual-race")) config.ssh.reconnect_max = 2;
    const workspace = try workspace_mod.Workspace.init(allocator, cx, scope, init.io, &config, "fixture-missing-hosts.toml", sidebar, strip, area, empty);
    const app = try ApplicationHost.init(allocator, workspace);
    try scope.onCleanup(ApplicationHost, app, ApplicationHost.deinit);
    app.install();
    cx.setViewport(1100, 720);
    const accepted = try app.create(.{ .connection_id = @fromBackingInt(77), .revision = 6, .name = "loopback-original-pane", .host = "127.0.0.1", .port = port, .user = "operator", .auth_mode = .password, .password = "fixture-password" }, 1, 0, "");
    const id = app.legacyForHandle(accepted.handle) orelse return error.MissingMapping;
    defer closeAndDrain(app, id) catch |err| std.debug.print("CLOSE_FAILURE {s}\n", .{@errorName(err)});
    const tab = workspace.sessionTab(id) orelse return error.MissingTab;
    const original_tab_id = tab.tab_id;
    const original_root = tab.root;
    const first_failed = std.mem.eql(u8, mode, "initial-failure");
    var first_ready = false;
    var drop_sent = false;
    var buffered = false;
    var retried = false;
    var original_worker: ?*@import("vt/ssh_worker.zig").SshWorker = null;
    var original_vt: @FieldType(@import("vt/ghostty_adapter.zig").Adapter, "terminal") = null;
    var original_binding: ?session_host.ServiceHandle = null;
    var first_challenge: ?auth.RequestIdentity = null;
    var trust_count: usize = 0;
    const deadline = realtime.monotonicNs() + 8 * std.time.ns_per_s;
    var final_key = accepted.operation;
    var cancelled_reconnect: ?@import("host/operation.zig").OperationKey = null;
    var shown_generation: u64 = 0;
    var shown_state: ?session_host.Lifecycle = null;
    while (realtime.monotonicNs() < deadline) {
        _ = try app.safeTick();
        if (workspace.pendingAuthentication()) |challenge| {
            if (challenge.kind != .host_key_unknown or challenge.port != port) return error.UnexpectedChallenge;
            if (first_challenge == null) first_challenge = challenge.identity;
            if (std.mem.eql(u8, mode, "cancel-reconnect") and !challenge.identity.key.eql(accepted.operation)) {
                cancelled_reconnect = challenge.identity.key;
                _ = try app.requestCloseLegacy(id);
            } else {
                try workspace.submitAuthentication(challenge.identity, .trust_once);
                trust_count += 1;
            }
        }
        const handle = app.ownerForLegacy(id) orelse return error.LostMapping;
        const state = app.sessions.queryState(handle) orelse return error.LostHostSession;
        if (cancelled_reconnect) |cancelled_key| {
            if (state.lifecycle == .closed and workspace.sessionTab(id) == null) {
                std.debug.print("RECONNECT_CANCEL_OK generation={d} attempt={d} trust={d} released=true\n", .{ cancelled_key.owner.session.generation, cancelled_key.attempt_id.?, trust_count });
                return;
            }
            pause();
            continue;
        }
        if (shown_generation != handle.generation or shown_state != state.lifecycle) {
            std.debug.print("STATE gen={d} phase={s}\n", .{ handle.generation, @tagName(state.lifecycle) });
            shown_generation = handle.generation;
            shown_state = state.lifecycle;
        }
        if (workspace.tabs.items.len != 1 or workspace.tabs.items[0] != tab or tab.tab_id != original_tab_id or tab.root != original_root) return error.PaneReplaced;
        if (!first_ready and state.lifecycle == .attached and handle.generation == accepted.handle.generation) {
            if (first_failed) return error.FirstAttemptShouldFail;
            first_ready = true;
            const facade = tab.runtime orelse return error.MissingRuntime;
            const runtime = nativeRuntime(facade);
            original_worker = runtime.worker;
            original_vt = runtime.worker.vt.terminal;
            original_binding = app.sessions.queryService(handle, .terminal).available;
        }
        if (first_ready and !drop_sent and state.lifecycle == .attached and handle.generation == accepted.handle.generation) {
            const worker = nativeRuntime(tab.runtime.?).worker;
            worker.pushInput("DROP\n") catch |err| {
                if (err == error.DisconnectedApplicationInput) {
                    pause();
                    continue;
                }
                return err;
            };
            drop_sent = true;
        }
        if (!first_failed and !buffered and state.lifecycle == .failed and state.create_cleanup == .released) {
            const worker = nativeRuntime(tab.runtime.?).worker;
            try worker.pushInputFrom("CACHED_中\n", .ordinary);
            worker.pushInput("APP_MUST_NOT_REPLAY\n") catch |err| {
                if (err != error.DisconnectedApplicationInput) return err;
            };
            if (worker.inputSnapshot().queued != "CACHED_中\n".len) return error.WrongInputCache;
            buffered = true;
        }
        if (!retried and !automatic and state.lifecycle == .failed and state.create_cleanup == .released) {
            if (first_failed and tab.runtime != null) return error.InitialFailureInstalledRuntime;
            if (!first_failed and !first_ready) return error.DroppedBeforeAttach;
            try app.requestSshReconnect(id);
            // A second delivery cannot allocate another operation.
            app.requestSshReconnect(id) catch |err| {
                if (err != error.ReconnectAlreadyRequested) return err;
            };
            retried = true;
        }
        if (state.lifecycle == .attached and handle.generation == accepted.handle.generation + 1) {
            final_key = state.create_operation;
            if (handle.session_id != accepted.handle.session_id or final_key.operation_id == accepted.operation.operation_id or final_key.attempt_id.? != accepted.operation.attempt_id.? + 1) return error.AttemptIdentityReused;
            if (original_binding) |binding| if (app.sessions.bindingIsLive(binding)) return error.OldBindingStillLive;
            const facade = tab.runtime orelse return error.MissingRuntime;
            const runtime = nativeRuntime(facade);
            if (!first_failed) {
                if (runtime.worker != original_worker.? or runtime.worker.vt.terminal != original_vt) return error.VtReplaced;
            }
            const prior = runtime.resourceSnapshot().?;
            if (prior.key == null or !prior.key.?.eql(final_key)) return error.LedgerStillOldAttempt;
            const previous = runtime.resource_ledger.?.previousReleased() orelse return error.MissingPreviousReceipt;
            if (!previous.key.?.eql(accepted.operation) or !previous.released()) return error.OldResourcesNotReleased;
            if (first_challenge) |old| {
                var rejected = false;
                workspace.submitAuthentication(old, .trust_once) catch |err| {
                    if (err != error.StaleAuthentication) return err;
                    rejected = true;
                };
                if (!rejected) return error.StaleChallengeAccepted;
            }
            const text = try runtime.worker.searchText(allocator);
            defer allocator.free(text);
            if (std.mem.indexOf(u8, text, "second-ready") == null) {
                pause();
                continue;
            }
            if (!first_failed) {
                const old_output = std.mem.indexOf(u8, text, "first-ready");
                if (std.mem.eql(u8, mode, "manual-clear")) {
                    if (old_output != null) return error.RemoteClearIgnored;
                } else {
                    if (old_output == null) return error.OriginalOutputLost;
                    try runtime.worker.vt.scroll(.top);
                    const top = try runtime.worker.vt.searchText(allocator);
                    defer allocator.free(top);
                    if (std.mem.indexOf(u8, top, "first-ready") == null) return error.HistoryUnavailable;
                    try runtime.worker.vt.scroll(.bottom);
                }
            }
            if (!first_failed and runtime.worker.inputSnapshot().handed_off != "CACHED_中\n".len) {
                pause();
                continue;
            }
            break;
        }
        pause();
    }
    if (final_key.eql(accepted.operation)) return error.ReconnectTimeout;
    if (trust_count != 2) return error.AttemptTrustReused;
    // A delayed timer from before a manual claim must remain inert.
    if (std.mem.eql(u8, mode, "manual-race")) {
        const until = realtime.monotonicNs() + 1200 * std.time.ns_per_ms;
        while (realtime.monotonicNs() < until) {
            _ = try app.safeTick();
            pause();
        }
        if (!app.ownerForLegacy(id).?.eql(final_key.owner.session) or workspace.tabs.items.len != 1) return error.LateTimerReconnected;
    }
    std.debug.print("RECONNECT_OK mode={s} session={d} tab={d} generation={d} attempt={d} trust={d} same_vt={}\n", .{ mode, @backingInt(final_key.owner.session.session_id), @backingInt(original_tab_id), final_key.owner.session.generation, final_key.attempt_id.?, trust_count, !first_failed });
}
fn pause() void {
    var fds: [1]std.c.pollfd = undefined;
    _ = std.c.poll(&fds, 0, 2);
}

fn closeAndDrain(app: *ApplicationHost, id: workspace_mod.SessionId) !void {
    std.debug.print("CLOSE_START\n", .{});
    const key = try app.requestCloseLegacy(id);
    std.debug.print("CLOSE_ACCEPTED\n", .{});
    const deadline = realtime.monotonicNs() + 3 * std.time.ns_per_s;
    while (realtime.monotonicNs() < deadline) {
        _ = try app.safeTick();
        if (app.sessions.queryState(key.owner.session)) |state| {
            if (state.lifecycle == .closed and app.workspace.sessionTab(id) == null) {
                std.debug.print("CLOSE_RELEASED\n", .{});
                return;
            }
        }
        pause();
    }
    return error.CloseDidNotRelease;
}

// Acceptance runner inspects native identity to prove reconnect retains the VT.
fn nativeRuntime(facade: *@import("host/runtime_service.zig").Runtime) *@import("ui/session_runtime.zig").SessionRuntime {
    return @ptrCast(@alignCast(facade.context));
}
