//! Real Route/Listener acceptance for SocksRouteHost. The original SessionHost
//! identity/binding comes from its public lifecycle API; its terminal adapter
//! is an authority-only fixture, not a claim of GUI/terminal attachment testing.
//! Every SOCKS connect, auth, relay, byte and close uses production libssh2.
const std = @import("std");
const host_mod = @import("host/socks_route_host.zig");
const sessions = @import("host/session_host.zig");
const plugins = @import("host/plugin_registry.zig");
const ssh = @import("proto/ssh/session.zig");
const clock = @import("platform/realtime.zig");
const Authority = struct {
    closes: usize = 0,
    fn interface(self: *Authority) sessions.Adapter {
        return .{ .context = self, .registration = .{ .plugin_id = .ssh, .workspace_kind = .terminal, .services = plugins.builtin_descriptors[1].services }, .vtable = &.{ .create = create, .cancel = cancel, .close = close, .release_stale = stale } };
    }
    fn create(_: *anyopaque, _: sessions.CreateRequest) !void {}
    fn cancel(_: *anyopaque, _: sessions.OperationKey) sessions.CloseReceipt {
        return .released;
    }
    fn close(raw: *anyopaque, _: sessions.SessionHandle, _: sessions.OperationKey) !sessions.CloseReceipt {
        const self: *Authority = @ptrCast(@alignCast(raw));
        self.closes += 1;
        return .released;
    }
    fn stale(_: *anyopaque, _: sessions.SessionHandle, _: sessions.OperationKey) void {}
};
fn releaseForward(raw: *anyopaque, owner: sessions.SessionHandle, _: sessions.OperationKey) !sessions.CloseReceipt {
    const host: *host_mod.Host = @ptrCast(@alignCast(raw));
    return host.requestStop(owner);
}
fn pause() void {
    var empty: [1]std.c.pollfd = undefined;
    _ = std.c.poll(&empty, 0, 2);
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
    const exit: ?usize = if (std.mem.eql(u8, mode, "exit-first")) 0 else if (std.mem.eql(u8, mode, "exit-second")) 1 else null;
    const expected_count = if (exit) |index| index + 1 else count + 1;
    const cancel_auth = std.mem.eql(u8, mode, "cancel-auth");
    const reject_key = std.mem.eql(u8, mode, "reject-key");
    const owner_close = std.mem.eql(u8, mode, "owner-close");
    if (!std.fs.path.isAbsolute(controls)) return error.OwnedDirectoryRequired;
    var arena = std.heap.ArenaAllocator.init(init.gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const hops = try a.alloc(sessions.RouteHop, count);
    for (hops, 0..) |*hop, index| hop.* = .{
        .owner = .{ .id = @fromBackingInt(41 + index), .revision = 8 + index },
        .display_name = try std.fmt.allocPrint(a, "frozen-hop-{d}", .{index}),
        .endpoint = .{ .host = "127.0.0.1", .port = ports[index], .user = try std.fmt.allocPrint(a, "hop-user-{d}", .{index}) },
        .auth = .password_prompt,
    };
    const spec: sessions.SessionCreateSpec = .{ .saved = .{
        .connection_id = @fromBackingInt(77),
        .config_revision = 6,
        .protocol = .ssh,
        .immutable_config = .{ .endpoint = .{ .host = "127.0.0.1", .port = target_port, .user = "target-user" }, .auth = .password_prompt, .strict_host_key_checking = false, .startup_commands = &.{"MUST_NOT_EXECUTE"} },
        .route_snapshot = hops,
    } };
    var library = try ssh.Library.init();
    defer library.deinit();
    var authority: Authority = .{};
    var domain = try sessions.SessionHost.init(init.gpa, &.{authority.interface()});
    defer domain.deinit();
    const attachment: sessions.AttachmentTarget = .{ .window_id = @fromBackingInt(1), .workspace_id = @fromBackingInt(1) };
    const original = try domain.create(spec, attachment);
    if (!try domain.ready(original.handle, original.operation, plugins.builtin_descriptors[1].services)) return error.ReadyRejected;
    if (!try domain.attached(original.handle, .{ .target = attachment, .tab_id = @fromBackingInt(1) })) return error.AttachRejected;
    var host = try host_mod.Host.init(init.gpa, &domain, .{ .library = &library, .known_hosts_path = try std.fs.path.join(a, &.{ controls, "known_hosts" }), .presentation_config_revision = 19, .timeout_ms = 3000 });
    defer host.deinit() catch unreachable;
    const key = try host.start(original.handle, .{ .listener = .{ .requested_port = 0 }, .exit_index = exit });
    if (key.eql(original.operation) or key.owner != .session or !key.owner.session.eql(original.handle) or key.attempt_id != original.operation.attempt_id) return error.ForeignOperation;
    // Frozen owner state is independent of the caller's mutable route array.
    for (hops) |*hop| {
        hop.endpoint.port = 1;
        hop.auth = .{ .password = "INVALID-MUTATED" };
        hop.owner.?.revision += 100;
    }
    const frozen_route = try host.sourceRoute(original.handle);
    if (frozen_route.len != count) return error.ForeignOriginalRoute;
    for (frozen_route, 0..) |hop, index| if (hop.endpoint.port != ports[index] or hop.owner.?.revision != 8 + index) return error.MutatedOriginalRoute;
    var last_id: u64 = 0;
    var key_prompts: usize = 0;
    var password_prompts: usize = 0;
    var rejected_stale: usize = 0;
    var first_request: ?host_mod.auth.RequestIdentity = null;
    var ready = false;
    var stopping = false;
    var stop_started: i128 = 0;
    var close_key: ?sessions.OperationKey = null;
    const ready_path = try std.fs.path.join(a, &.{ controls, "ready.json" });
    const stop_path = try std.fs.path.join(a, &.{ controls, "stop" });
    const deadline = clock.monotonicNs() + 18 * std.time.ns_per_s;
    while (clock.monotonicNs() < deadline) {
        _ = try host.safeTick();
        if (host.pendingAuthentication()) |request| if (request.state == .input and request.identity.request_id != last_id) {
            const index = request.identity.hop_index;
            const target = exit == null and index == count;
            if (!request.identity.key.eql(key) or index >= expected_count or request.identity.request_id <= last_id or request.port != ports[index] or request.source_owner == null or @backingInt(request.source_owner.?.id) != (if (target) @as(u64, 77) else 41 + index) or request.source_owner.?.revision != (if (target) @as(u64, 6) else 8 + index) or request.presentation_config_revision != 19) return error.ForeignChallenge;
            const expected_user = if (target) "target-user" else try std.fmt.allocPrint(a, "hop-user-{d}", .{index});
            if (!std.mem.eql(u8, request.endpoint().user, expected_user)) return error.ForeignEndpoint;
            const projected = host.authenticationHostFor(request.identity) orelse return error.MissingHostMetadata;
            if (projected.port != ports[index] or !std.mem.eql(u8, projected.user, expected_user) or projected.password != null) return error.ForeignMetadata;
            var stale = request.identity;
            stale.key.operation_id += 1000;
            if (host.submitAuthentication(stale, .trust_once)) |_| return error.AcceptedForeignChallenge else |err| if (err != error.StaleAuthentication) return err;
            rejected_stale += 1;
            if (first_request == null) first_request = request.identity;
            last_id = request.identity.request_id;
            switch (request.kind) {
                .host_key_unknown => {
                    const info = host.authenticationHostKey(request.identity) orelse return error.MissingHostKey;
                    if (!std.mem.eql(u8, info.fingerprintSlice(), fingerprint)) return error.ForeignHostKey;
                    key_prompts += 1;
                    if (reject_key and index + 1 == expected_count) {
                        if (!host.cancelAuthentication(request.identity)) return error.CancelRejected;
                        stopping = true;
                        stop_started = clock.monotonicNs();
                    } else try host.submitAuthentication(request.identity, .trust_once);
                },
                .password => {
                    password_prompts += 1;
                    if (cancel_auth and index + 1 == expected_count) {
                        if (!host.cancelAuthentication(request.identity)) return error.CancelRejected;
                        stopping = true;
                        stop_started = clock.monotonicNs();
                    } else try host.submitAuthentication(request.identity, .{ .answers = &.{if (target) "target-secret" else try std.fmt.allocPrint(a, "hop-secret-{d}", .{index})} });
                },
                else => return error.UnexpectedChallenge,
            }
        };
        const snapshot = host.snapshot(original.handle).?;
        if (snapshot.phase == .ready and !ready) {
            if (cancel_auth or reject_key or snapshot.local_port == 0) return error.UnexpectedReady;
            const actual_exit = host.exitHost(original.handle) orelse return error.MissingExitMetadata;
            if (actual_exit.port != ports[expected_count - 1] or snapshot.exit_index != exit or !snapshot.bind127 or snapshot.requested_port != 0 or snapshot.max_connections != 64) return error.ForeignExitMetadata;
            if (exit) |selected| if (!std.mem.eql(u8, actual_exit.name, try std.fmt.allocPrint(a, "frozen-hop-{d}", .{selected}))) return error.ForeignExitName;
            ready = true;
            if (host.submitAuthentication(first_request.?, .trust_once)) |_| return error.AcceptedExpiredChallenge else |err| if (err != error.StaleAuthentication) return err;
            const json = try std.fmt.allocPrint(a, "{{\"local_port\":{d},\"key\":{d},\"owner\":{d},\"hop_count\":{d}}}\n", .{ snapshot.local_port, key.operation_id, @backingInt(original.handle.session_id), expected_count });
            try std.Io.Dir.cwd().writeFile(init.io, .{ .sub_path = ready_path, .data = json });
        }
        if (ready and !stopping) {
            if (std.Io.Dir.cwd().access(init.io, stop_path, .{})) |_| {
                stopping = true;
                stop_started = clock.monotonicNs();
                if (owner_close) {
                    close_key = try domain.requestClose(original.handle, .{ .release_forwards = .{ .context = &host, .run = releaseForward } });
                    if (authority.closes != 0) return error.ProtocolClosedBeforeForwardRelease;
                } else _ = host.requestStop(original.handle);
            } else |err| if (err != error.FileNotFound) return err;
        }
        if (snapshot.cleanup == .released) break;
        if (snapshot.phase == .cleanup_unknown) return error.CleanupUnknown;
        pause();
    }
    _ = try host.safeTick();
    const final = host.snapshot(original.handle).?;
    if (final.cleanup != .released or final.stats.connections_active != 0 or !stopping) return error.CleanupNotReleased;
    if (key_prompts != expected_count or password_prompts != (if (reject_key) expected_count - 1 else expected_count)) return error.MissingOriginalHopChallenge;
    if (owner_close) {
        if (!try domain.closeReceipt(original.handle, close_key.?, .release_forwards, .released) or authority.closes != 1 or domain.queryState(original.handle).?.lifecycle != .closed) return error.CloseOrderingFailed;
    } else if (domain.queryState(original.handle).?.lifecycle != .attached) return error.OriginalTerminalWasChanged;
    const diagnostics = host.connectionProgress(original.handle).?;
    var completed: usize = 0;
    var cancelled: usize = 0;
    var released: usize = 0;
    while (domain.journal.take()) |received| {
        var event = received;
        defer event.deinit();
        if (!event.value.key.eql(key)) continue;
        switch (event.value.kind) {
            .completed => completed += 1,
            .cancelled => cancelled += 1,
            .cleanup_released => released += 1,
            else => {},
        }
    }
    if (released != 1 or (ready and completed != 1) or (!ready and cancelled != 1)) return error.JournalOwnershipFailed;
    if (host.shutdownStep() != .released) return error.ShutdownNotReleased;
    _ = try host.retryCleanup(original.handle);
    const report = try std.fmt.allocPrint(a, "{{\"ready\":{},\"cleanup_released\":true,\"stop_ms\":{d},\"local_port\":{d},\"bytes_up\":{d},\"bytes_down\":{d},\"active\":{d},\"host_key_prompts\":{d},\"password_prompts\":{d},\"foreign_requests_rejected\":{d},\"original_owner\":true,\"original_terminal_untouched\":{},\"close_ordering\":{},\"real_progress_events\":{d},\"original_journal_cleanup\":true}}\n", .{ ready, @divTrunc(clock.monotonicNs() - stop_started, std.time.ns_per_ms), final.local_port, final.stats.bytes_up, final.stats.bytes_down, final.stats.connections_active, key_prompts, password_prompts, rejected_stale, !owner_close, owner_close, diagnostics.count });
    try std.Io.Dir.cwd().writeFile(init.io, .{ .sub_path = try std.fs.path.join(a, &.{ controls, "runner-report.json" }), .data = report });
    std.debug.print("PASS {s} actual_route=true typed_auth=true cleanup=released\n", .{mode});
}
