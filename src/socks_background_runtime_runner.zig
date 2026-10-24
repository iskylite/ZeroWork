//! Headless acceptance of the real no-shell original SSH adapter/runtime.
//! The controller uses SessionHost authority and production SourceFactory,
//! Route, forwarding facade and SOCKS owner loops against owned loopback peers.
const std = @import("std");
const background = @import("host/socks_background_runtime.zig");
const socks = @import("host/socks_route_host.zig");
const sessions = @import("host/session_host.zig");
const plugins = @import("host/plugin_registry.zig");
const clock = @import("platform/realtime.zig");

const Adapter = struct {
    host: ?*background.Host = null,
    creates: usize = 0,
    fn interface(self: *Adapter) sessions.Adapter {
        return .{ .context = self, .registration = .{ .plugin_id = .ssh, .workspace_kind = .terminal, .services = plugins.builtin_descriptors[1].services }, .vtable = &.{ .create = create, .cancel = cancel, .close = close, .release_stale = stale } };
    }
    fn create(raw: *anyopaque, request: sessions.CreateRequest) !void {
        const self: *Adapter = @ptrCast(@alignCast(raw));
        if (request.spec.purpose() != .socks_background) return error.InvalidSessionPurpose;
        try self.host.?.queue(request);
        self.creates += 1;
    }
    fn cancel(raw: *anyopaque, key: sessions.OperationKey) sessions.CloseReceipt {
        const self: *Adapter = @ptrCast(@alignCast(raw));
        return self.host.?.cancel(key);
    }
    fn close(raw: *anyopaque, owner: sessions.SessionHandle, key: sessions.OperationKey) !sessions.CloseReceipt {
        const self: *Adapter = @ptrCast(@alignCast(raw));
        return self.host.?.closeStep(owner, key, .close_protocol);
    }
    fn stale(raw: *anyopaque, owner: sessions.SessionHandle, key: sessions.OperationKey) void {
        const self: *Adapter = @ptrCast(@alignCast(raw));
        self.host.?.releaseStale(owner, key);
    }
    fn releaseForward(raw: *anyopaque, owner: sessions.SessionHandle, key: sessions.OperationKey) !sessions.CloseReceipt {
        const self: *Adapter = @ptrCast(@alignCast(raw));
        return self.host.?.closeStep(owner, key, .release_forwards);
    }
    fn forward(raw: *anyopaque, binding: sessions.ServiceHandle, exit_index: ?usize) !*@import("proto/ssh/forward_service.zig").Service {
        const self: *Adapter = @ptrCast(@alignCast(raw));
        return self.host.?.forwardService(binding, exit_index);
    }
};
fn pause() void {
    var empty: [1]std.c.pollfd = undefined;
    _ = std.c.poll(&empty, 0, 2);
}
fn exists(io: std.Io, path: []const u8) bool {
    std.Io.Dir.cwd().access(io, path, .{}) catch return false;
    return true;
}

pub fn main(init: std.process.Init) !void {
    var args = init.minimal.args.iterate();
    _ = args.next();
    const mode = args.next() orelse return error.MissingMode;
    const controls = args.next() orelse return error.MissingControls;
    const fingerprint = args.next() orelse return error.MissingFingerprint;
    const target_port = try std.fmt.parseInt(u16, args.next() orelse return error.MissingTargetPort, 10);
    var ports: [9]u16 = undefined;
    var count: usize = 0;
    while (args.next()) |port| {
        if (count == 8) return error.TooManyHops;
        ports[count] = try std.fmt.parseInt(u16, port, 10);
        count += 1;
    }
    ports[count] = target_port;
    const selected: ?usize = if (std.mem.eql(u8, mode, "exit-first")) 0 else null;
    const cancel_reconnect = std.mem.eql(u8, mode, "reconnect-cancel-auth");
    const replacement_oom = std.mem.eql(u8, mode, "reconnect-oom");
    const reconnect = std.mem.eql(u8, mode, "reconnect") or replacement_oom or cancel_reconnect;
    const cancel_auth = std.mem.eql(u8, mode, "cancel-auth");
    const reject_key = std.mem.eql(u8, mode, "reject-key");
    var arena = std.heap.ArenaAllocator.init(init.gpa);
    defer arena.deinit();
    const a = arena.allocator();
    var failing = std.testing.FailingAllocator.init(init.gpa, .{});
    const hops = try a.alloc(sessions.RouteHop, count);
    for (hops, 0..) |*hop, index| hop.* = .{ .owner = .{ .id = @fromBackingInt(41 + index), .revision = 8 + index }, .display_name = "same-name", .endpoint = .{ .host = "127.0.0.1", .port = ports[index], .user = try std.fmt.allocPrint(a, "hop-user-{d}", .{index}) }, .auth = .password_prompt, .strict_host_key_checking = true };
    const spec: sessions.SessionCreateSpec = .{ .saved = .{ .connection_id = @fromBackingInt(77), .config_revision = 6, .protocol = .ssh, .immutable_config = .{ .endpoint = .{ .host = "127.0.0.1", .port = target_port, .user = "target-user" }, .auth = .password_prompt, .strict_host_key_checking = false, .startup_commands = &.{"MUST_NOT_EXECUTE"} }, .route_snapshot = hops } };
    var adapter: Adapter = .{};
    var domain = try sessions.SessionHost.init(init.gpa, &.{adapter.interface()});
    defer domain.deinit();
    const host = try background.Host.init(init.gpa, &domain, try std.fs.path.join(a, &.{ controls, "known_hosts" }), .{ .presentation_config_revision = 19, .timeout_ms = 2500, .automatic_reconnect = cancel_reconnect, .reconnect_backoff = .{ 0, 0, 0, 0, 0 } });
    adapter.host = host;
    defer host.deinit() catch unreachable;
    var proxy = try socks.Host.init(init.gpa, &domain, .{ .library = &host.library, .known_hosts_path = host.known_hosts_path, .shared_provider = .{ .context = &adapter, .get = Adapter.forward } });
    defer proxy.deinit() catch unreachable;
    const original = try domain.createBackground(spec, .{ .window_id = @fromBackingInt(1), .workspace_id = @fromBackingInt(1) });
    var current = original;
    for (hops) |*hop| {
        hop.endpoint.port = 1;
        hop.auth = .{ .password = "INVALID-MUTATED" };
        hop.owner.?.revision += 100;
    }
    var auth_count: usize = 0;
    var key_count: usize = 0;
    var rejected_stale: usize = 0;
    var last_request: u64 = 0;
    var first_request: ?background.auth.RequestIdentity = null;
    var started = false;
    var ready = false;
    var resumed = false;
    var paused = false;
    var retried = false;
    var stopping = false;
    var cancelled_reconnect = false;
    var cancelled_at: ?i128 = null;
    var local_port: u16 = 0;
    var close_key: ?sessions.OperationKey = null;
    const stop_path = try std.fs.path.join(a, &.{ controls, "stop" });
    const retry_path = try std.fs.path.join(a, &.{ controls, "retry" });
    const deadline = clock.monotonicNs() + 30 * std.time.ns_per_s;
    while (clock.monotonicNs() < deadline) {
        _ = try host.safeTick();
        _ = try proxy.safeTick();
        if (cancel_reconnect) {
            const active = try host.snapshots(init.gpa);
            defer init.gpa.free(active);
            if (active.len != 0) current = .{ .handle = active[0].owner, .operation = active[0].key };
        }
        if (host.pendingAuthentication()) |request| if (request.state == .input and request.identity.request_id != last_request) {
            const index = request.identity.hop_index;
            const target = index == count;
            if (index > count or !request.identity.key.eql(current.operation) or request.identity.request_id <= last_request or request.port != ports[index] or request.source_owner == null or @backingInt(request.source_owner.?.id) != (if (target) @as(u64, 77) else 41 + index) or request.source_owner.?.revision != (if (target) @as(u64, 6) else 8 + index) or request.presentation_config_revision != 19) return error.ForeignChallenge;
            const frozen = host.authenticationHostFor(request.identity) orelse return error.MissingFrozenHost;
            if (frozen.port != ports[index]) return error.MutatedFrozenSource;
            var stale = request.identity;
            stale.key.operation_id += 1000;
            if (host.submitAuthentication(stale, .trust_once)) |_| return error.AcceptedForeignChallenge else |err| if (err != error.StaleAuthentication) return err;
            rejected_stale += 1;
            if (first_request == null) first_request = request.identity;
            last_request = request.identity.request_id;
            switch (request.kind) {
                .host_key_unknown => {
                    const key = host.authenticationHostKey(request.identity) orelse return error.MissingHostKey;
                    if (!std.mem.eql(u8, key.fingerprintSlice(), fingerprint)) return error.ForeignHostKey;
                    key_count += 1;
                    if (cancel_reconnect and ready and !cancelled_reconnect and index == 0) {
                        if (!host.cancelAuthentication(request.identity)) return error.CancelRejected;
                        // Match Connection.Host: cancel challenge, then create.
                        if (!try domain.cancel(request.identity.key)) return error.DomainCancelRejected;
                        cancelled_reconnect = true;
                    } else if (reject_key and target) {
                        if (!host.cancelAuthentication(request.identity)) return error.CancelRejected;
                        stopping = true;
                        close_key = try domain.requestClose(current.handle, .{ .release_forwards = .{ .context = &adapter, .run = Adapter.releaseForward } });
                    } else try host.submitAuthentication(request.identity, .trust_once);
                },
                .password => {
                    auth_count += 1;
                    if (cancel_auth and target) {
                        if (!host.cancelAuthentication(request.identity)) return error.CancelRejected;
                        stopping = true;
                        close_key = try domain.requestClose(current.handle, .{ .release_forwards = .{ .context = &adapter, .run = Adapter.releaseForward } });
                    } else try host.submitAuthentication(request.identity, .{ .answers = &.{if (target) "target-secret" else try std.fmt.allocPrint(a, "hop-secret-{d}", .{index})} });
                },
                else => return error.UnexpectedChallenge,
            }
        };
        const state = domain.queryState(current.handle) orelse return error.MissingOriginalOwner;
        if (state.attachment != null or state.purpose != .socks_background or domain.queryService(current.handle, .terminal) != .unsupported or domain.queryService(current.handle, .exec) != .unsupported) return error.FabricatedTerminal;
        if (state.lifecycle == .ready and !started) {
            _ = try proxy.start(current.handle, .{ .listener = .{ .requested_port = 0 }, .exit_index = selected });
            started = true;
        }
        if (proxy.snapshot(current.handle)) |value| {
            if (value.phase == .ready and !ready) {
                if (cancel_auth or reject_key or value.local_port == 0) return error.UnexpectedReady;
                ready = true;
                local_port = value.local_port;
                if (host.submitAuthentication(first_request.?, .trust_once)) |_| return error.AcceptedExpiredChallenge else |err| if (err != error.StaleAuthentication) return err;
                try std.Io.Dir.cwd().writeFile(init.io, .{ .sub_path = try std.fs.path.join(a, &.{ controls, "ready.json" }), .data = try std.fmt.allocPrint(a, "{{\"local_port\":{d},\"owner\":{d},\"generation\":{d},\"hop_count\":{d}}}\n", .{ value.local_port, @backingInt(current.handle.session_id), current.handle.generation, count + 1 }) });
            }
            if (reconnect and ready and retried and !resumed and value.phase == .ready) {
                if (value.local_port != local_port or current.handle.generation != original.handle.generation + (if (replacement_oom or cancel_reconnect) @as(u64, 2) else 1)) return error.ReconnectChangedPortOrOwner;
                resumed = true;
                try std.Io.Dir.cwd().writeFile(init.io, .{ .sub_path = try std.fs.path.join(a, &.{ controls, "resumed.json" }), .data = try std.fmt.allocPrint(a, "{{\"local_port\":{d},\"generation\":{d}}}\n", .{ value.local_port, current.handle.generation }) });
            }
        }
        if (reconnect and !cancel_reconnect and ready and !paused and state.lifecycle == .failed and state.create_cleanup == .released) {
            const value = proxy.snapshot(original.handle) orelse return error.MissingPausedListener;
            if (value.local_port != local_port or value.phase != .paused) return error.PortNotRetained;
            if (domain.queryService(original.handle, .forward) == .available) return error.StaleServiceLive;
            paused = true;
            try std.Io.Dir.cwd().writeFile(init.io, .{ .sub_path = try std.fs.path.join(a, &.{ controls, "paused.json" }), .data = "{\"actual_parent_released\":true,\"old_binding_revoked\":true}\n" });
        }
        if (cancel_reconnect and cancelled_reconnect and !retried and state.lifecycle == .failed and state.create_cleanup == .released) {
            paused = true;
            const cancelled = try host.snapshots(init.gpa);
            defer init.gpa.free(cancelled);
            if (cancelled.len != 1 or cancelled[0].failure == null or cancelled[0].failure.? != error.Cancelled) return error.CancelFailureLost;
            const retained = proxy.snapshot(original.handle) orelse return error.MissingPausedListener;
            if (retained.local_port != local_port or retained.phase != .paused) return error.PortNotRetained;
            if (cancelled_at == null) cancelled_at = clock.monotonicNs();
            // Zero backoff would immediately start another automatic attempt.
            // A cancelled challenge must stay failed until explicit retry.
            if (clock.monotonicNs() - cancelled_at.? > 100 * std.time.ns_per_ms) {
                if (adapter.creates != 2) return error.CancelAutomaticallyRetried;
                current = try host.retry(current.handle);
                retried = true;
            }
        }
        if (!cancel_reconnect and paused and !retried and exists(init.io, retry_path)) {
            if (replacement_oom) {
                host.entries.items[0].runtime.allocator = failing.allocator();
                failing.fail_index = failing.alloc_index;
            }
            current = try host.retry(original.handle);
            if (current.handle.session_id != original.handle.session_id or current.handle.generation != original.handle.generation + 1 or current.operation.attempt_id == original.operation.attempt_id) return error.ForeignRetry;
            if (replacement_oom) {
                _ = try host.safeTick();
                const rejected = domain.queryState(current.handle).?;
                const retained = try host.snapshots(init.gpa);
                defer init.gpa.free(retained);
                if (!failing.has_induced_failure or rejected.lifecycle != .failed or rejected.create_cleanup != .released or retained.len != 1 or !retained[0].owner.eql(current.handle) or retained[0].listeners != 1 or retained[0].failure == null or retained[0].failure.? != error.OutOfMemory) return error.OomLostRetainedOwner;
                failing.fail_index = std.math.maxInt(usize);
                current = try host.retry(current.handle);
                if (current.handle.session_id != original.handle.session_id or current.handle.generation != original.handle.generation + 2) return error.OomRetryChangedOwner;
            }
            retried = true;
        }
        if (ready and !stopping and exists(init.io, stop_path)) {
            stopping = true;
            _ = host.requestStop(current.handle);
            close_key = try domain.requestClose(current.handle, .{ .release_forwards = .{ .context = &adapter, .run = Adapter.releaseForward } });
        }
        if (stopping and domain.queryState(current.handle).?.lifecycle == .closed) break;
        pause();
    }
    _ = try host.safeTick();
    _ = try proxy.safeTick();
    const final = domain.queryState(current.handle).?;
    if (!stopping or close_key == null or final.lifecycle != .closed or host.shutdownStep() != .released) return error.CleanupNotReleased;
    if (reconnect and (!paused or !retried or !resumed or adapter.creates != (if (replacement_oom or cancel_reconnect) @as(usize, 3) else 2))) return error.ReconnectNotExercised;
    const expected = (count + 1) * (if (reconnect) @as(usize, 2) else 1) + @intFromBool(cancel_reconnect);
    if (key_count != expected or auth_count != expected - @intFromBool(reject_key) - @intFromBool(cancel_reconnect)) return error.MissingHopAuthentication;
    const values = try host.snapshots(init.gpa);
    defer init.gpa.free(values);
    if (values.len != 0) return error.ClosedBackgroundStillActive;
    var close_completed: usize = 0;
    var close_released: usize = 0;
    var create_completed: usize = 0;
    while (domain.journal.take()) |received| {
        var event = received;
        defer event.deinit();
        if (event.value.key.eql(close_key.?)) switch (event.value.kind) {
            .completed => close_completed += 1,
            .cleanup_released => close_released += 1,
            else => {},
        };
        if (event.value.key.eql(current.operation) and event.value.kind == .completed) create_completed += 1;
    }
    if (close_completed != 1 or close_released != 1 or (ready and create_completed != 1)) return error.OriginalJournalOwnershipFailed;
    const report = try std.fmt.allocPrint(a, "{{\"ready\":{},\"no_tab\":true,\"no_terminal_services\":true,\"original_owner\":true,\"cleanup_released\":true,\"original_journal_cleanup\":true,\"local_port\":{d},\"host_key_prompts\":{d},\"password_prompts\":{d},\"foreign_requests_rejected\":{d},\"reconnect\":{},\"replacement_oom_preserved\":{},\"port_retained\":{},\"generation\":{d},\"create_count\":{d}}}\n", .{ ready, local_port, key_count, auth_count, rejected_stale, reconnect, replacement_oom and failing.has_induced_failure, paused and resumed, current.handle.generation, adapter.creates });
    try std.Io.Dir.cwd().writeFile(init.io, .{ .sub_path = try std.fs.path.join(a, &.{ controls, "runner-report.json" }), .data = report });
    std.debug.print("PASS background {s} no_shell=true no_tab=true cleanup=released\n", .{mode});
}
