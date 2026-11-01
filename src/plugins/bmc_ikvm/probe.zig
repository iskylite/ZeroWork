//! Non-UI, read-only BMC ProbeFactory. The provider owns frozen configuration
//! and independent worker resources; the editor/ProbeHost retains its actual
//! restricted-context capabilities and cancellation storage until release.
const std = @import("std");
const builtin = @import("builtin");
const contract = @import("../../host/probe_contract.zig");
const operation = @import("../../host/operation.zig");
const identity = @import("../../host/identity.zig");
const tls_trust = @import("../../host/tls_trust.zig");
const native = @import("native_driver.zig");
const model = @import("model.zig");
const route = @import("route.zig");
const profile = @import("protocol/profile.zig");
const auth = @import("protocol/auth.zig");
const svc = @import("services.zig");
const progress = @import("connection_progress.zig");

pub const Callbacks = struct {
    context: *anyopaque,
    trust_reply: ?*const fn (*anyopaque, tls_trust.Challenge, *const std.atomic.Value(bool)) anyerror!tls_trust.TrustChoice = null,
    password_reply: ?*const fn (*anyopaque, identity.SessionHandle, operation.OperationKey, *const std.atomic.Value(bool), std.mem.Allocator) anyerror!auth.Secret = null,
};
pub const Options = struct {
    /// null identifies the actual anonymous device on its trusted worker
    /// channel. Explicit selection remains for existing verified callers.
    /// Neither mode tries multiple login schemas or unknown firmware.
    selected: ?profile.Profile = null,
    callbacks: ?Callbacks = null,
};

fn AtomicEnum(comptime E: type) type {
    return struct {
        value: std.atomic.Value(u8),
        fn init(value: E) @This() {
            return .{ .value = .init(@backingInt(value)) };
        }
        fn load(self: *const @This(), comptime order: std.builtin.AtomicOrder) E {
            return @fromBackingInt(@intCast(self.value.load(order)));
        }
        fn store(self: *@This(), value: E, comptime order: std.builtin.AtomicOrder) void {
            self.value.store(@backingInt(value), order);
        }
        fn swap(self: *@This(), value: E, comptime order: std.builtin.AtomicOrder) E {
            return @fromBackingInt(@intCast(self.value.swap(@backingInt(value), order)));
        }
    };
}

const Entry = struct {
    allocator: std.mem.Allocator,
    key: operation.OperationKey,
    external_cancel: *const std.atomic.Value(bool),
    cancel_source: std.atomic.Value(bool) = .init(false),
    cleanup_retry: std.atomic.Value(bool) = .init(false),
    plan: route.Plan,
    backend: *native.NativeDriver,
    connection_progress: progress.Tracker = .{},
    receipt: AtomicEnum(contract.CloseReceipt) = .init(.awaiting),
    web_logout: AtomicEnum(native.RemoteRelease) = .init(.not_created),
    outcome_ready: std.atomic.Value(bool) = .init(false),
    // Published once before outcome_ready; all messages are static strings.
    outcome: contract.Outcome = .failed,
    message: []const u8 = "",
    version: std.atomic.Value(u64) = .init(1),
    last_polled: u64 = 0,
    last_progress_stage: ?progress.Stage = null,
    last_progress_second: u64 = std.math.maxInt(u64),
    done: std.atomic.Value(bool) = .init(false),

    fn cancelled(self: *const Entry) bool {
        return self.cancel_source.load(.acquire) or self.external_cancel.load(.acquire);
    }
    fn run(self: *Entry) void {
        self.connection_progress.setStage(.route);
        self.backend.beginProbe() catch |err| {
            self.connection_progress.fail(err);
            self.outcome = if (err == error.Cancelled or self.cancelled()) .cancelled else .failed;
            self.message = if (self.outcome == .cancelled) "测试已取消" else @errorName(err);
            self.finish();
            return;
        };
        self.outcome = if (self.cancelled()) .cancelled else .succeeded;
        self.message = if (self.outcome == .cancelled) "测试已取消" else "BMC 只读连接测试成功";
        self.finish();
    }
    fn finish(self: *Entry) void {
        self.connection_progress.setStage(.cleanup);
        self.outcome_ready.store(true, .release);
        _ = self.version.fetchAdd(1, .release);
        while (true) {
            const cleaned: contract.CloseReceipt = switch (self.backend.cleanupProbe()) {
                .released => .released,
                .unknown => .unknown,
                .not_started, .awaiting => .awaiting,
            };
            self.web_logout.store(self.backend.diagnostics.web_logout, .release);
            if (cleaned == .released) {
                self.backend.deinit() catch {
                    self.publishReceipt(.unknown);
                    self.awaitRetry();
                    continue;
                };
                self.connection_progress.finish(self.outcome == .cancelled or self.cancelled());
                self.publishReceipt(.released);
                // Last access by the detached worker. The configuration owner
                // may now retire the entry without joining any native IO.
                self.done.store(true, .release);
                return;
            }
            self.publishReceipt(cleaned);
            self.awaitRetry();
        }
    }
    fn publishReceipt(self: *Entry, receipt: contract.CloseReceipt) void {
        if (self.receipt.swap(receipt, .acq_rel) != receipt) _ = self.version.fetchAdd(1, .release);
    }
    fn awaitRetry(self: *Entry) void {
        // Unknown local cleanup pins its real owner and worker. A later poll,
        // cancel or deinit retries on this same native IO owner.
        while (!self.cleanup_retry.swap(false, .acq_rel)) {
            var fds: [1]std.c.pollfd = undefined;
            _ = std.c.poll(&fds, 0, 10);
        }
    }
};

pub const Provider = struct {
    pub const capacity = 16;
    allocator: std.mem.Allocator,
    selected: ?svc.Owned(profile.Profile),
    callbacks: ?Callbacks,
    owner_thread: std.Thread.Id,
    entries: [capacity]?*Entry = @splat(null),
    // Only poll on the configuration owner writes this borrowed result buffer.
    // It survives retirement of an Entry; ProbeHost copies before next poll.
    message_buffer: [768]u8 = undefined,
    // Deterministic coverage of the native thread-spawn failure cleanup path.
    test_fail_spawn: if (builtin.is_test) bool else void = if (builtin.is_test) false else {},

    /// Heap-stable provider. It must outlive every factory value, ProbeHost and
    /// borrowed callback/facade backing store used by its outstanding requests.
    /// Profile strings are owned; callbacks/facades retain their usual explicit
    /// host lifetime. No IO occurs during init or begin preparation.
    pub fn init(a: std.mem.Allocator, options: Options) !*Provider {
        const self = try a.create(Provider);
        errdefer a.destroy(self);
        self.* = .{ .allocator = a, .selected = if (options.selected) |selected| try svc.Owned(profile.Profile).init(a, selected) else null, .callbacks = options.callbacks, .owner_thread = std.Thread.getCurrentId() };
        return self;
    }
    pub fn factory(self: *Provider) contract.ProbeFactory {
        return .{ .context = self, .begin = begin, .poll = poll, .cancel = cancel };
    }
    /// Nonblocking. Live/unknown owners stay allocated; drain ProbeHost.poll
    /// and retry deinit. Unregister consumers before the successful final call.
    pub fn deinit(self: *Provider) !void {
        try self.requireThread();
        var pending = false;
        for (self.entries) |slot| if (slot) |entry| {
            if (!entry.done.load(.acquire)) {
                entry.cancel_source.store(true, .release);
                entry.cleanup_retry.store(true, .release);
                pending = true;
            }
        };
        // A retryable deinit leaves completed-but-undelivered receipts intact
        // too, so the host can continue draining every original operation.
        if (pending) return error.ProbeCleanupPending;
        for (&self.entries) |*slot| if (slot.* != null) self.retire(slot);
        if (self.selected) |*selected| selected.deinit();
        const a = self.allocator;
        a.destroy(self);
    }
    fn cast(raw: *anyopaque) *Provider {
        return @ptrCast(@alignCast(raw));
    }
    fn requireThread(self: *Provider) !void {
        if (std.Thread.getCurrentId() != self.owner_thread) return error.ProbeWrongConfigurationThread;
    }
    fn begin(raw: *anyopaque, request: contract.ProbeRequest) !void {
        const self = cast(raw);
        try self.requireThread();
        try request.restricted_context.requireOwner(request.handle, request.operation);
        try tls_trust.requireOperation(request.handle, request.operation);
        if (!request.token.handle.eql(request.handle) or !request.token.operation.eql(request.operation) or !request.token.parent_editor_operation.eql(request.parent_editor_operation) or request.token.draft_revision != request.draft_revision or request.draft_revision == 0) return error.StaleProbeRequest;
        if (request.restricted_context.cancelled()) return error.Cancelled;
        try request.envelope.validate();
        if (!std.mem.eql(u8, request.envelope.protocol_id, model.protocol_id)) return error.UnsupportedProtocol;
        if (request.envelope.payload_version != model.payload_version) return error.UnsupportedPayloadVersion;
        for (self.entries) |slot| if (slot) |entry| {
            if (entry.key.eql(request.operation)) return error.DuplicateProbeOperation;
        };
        const slot = for (&self.entries) |*candidate| {
            if (candidate.* == null) break candidate;
        } else return error.ProbeCapacity;
        var parsed = try model.parse(self.allocator, request.envelope.payload);
        defer parsed.deinit();
        const payload = parsed.value();
        var ids: [8]identity.ConnectionId = undefined;
        const hops = switch (payload.access) {
            .direct => &.{},
            .ssh_route => |access| access.hops,
        };
        for (hops, 0..) |hop, index| ids[index] = @fromBackingInt(hop.asset_id);
        const entry = try self.allocator.create(Entry);
        errdefer self.allocator.destroy(entry);
        entry.* = .{ .allocator = self.allocator, .key = request.operation, .external_cancel = request.restricted_context.cancel, .plan = try route.Plan.init(self.allocator, request.handle, request.restricted_context.connection_configs, ids[0..hops.len], .{ .host = payload.endpoint.host, .port = payload.endpoint.https_port }), .backend = undefined };
        entry.connection_progress = progress.Tracker.init(@intCast(hops.len));
        errdefer entry.plan.deinit();
        const callbacks: ?native.Callbacks = if (self.callbacks) |value| .{ .context = value.context, .trust_reply = value.trust_reply, .password_reply = value.password_reply } else null;
        entry.backend = try native.NativeDriver.prepareProbe(self.allocator, request.restricted_context, payload, &entry.plan, &entry.cancel_source, .{ .selected = if (self.selected) |selected| selected.value else null, .callbacks = callbacks, .progress = &entry.connection_progress });
        const fail_spawn = if (builtin.is_test) self.test_fail_spawn else false;
        const thread = (if (fail_spawn) @as(anyerror!std.Thread, error.ThreadQuotaExceeded) else std.Thread.spawn(.{}, Entry.run, .{entry})) catch |err| {
            // prepareProbe has not started a native transport. This path must
            // wipe copied auth and release the cleanup reservation before a
            // throwing begin promises that no resources were acquired.
            entry.backend.discardPrepared() catch unreachable;
            return err;
        };
        slot.* = entry;
        thread.detach();
    }
    fn poll(raw: *anyopaque, key: operation.OperationKey) !?contract.ProbeUpdate {
        const self = cast(raw);
        try self.requireThread();
        const slot = self.find(key) orelse return error.StaleProbeOperation;
        const entry = slot.*.?;
        if (entry.done.load(.acquire)) {
            const result: contract.ProbeUpdate = .{ .result = .{ .outcome = if (entry.cancelled()) .cancelled else entry.outcome, .safe_message = try self.resultMessage(entry, true), .cleanup = .released } };
            self.retire(slot);
            return result;
        }
        entry.cleanup_retry.store(true, .release);
        const version = entry.version.load(.acquire);
        const connection = entry.connection_progress.snapshot();
        const second = connection.elapsed_ms / 1000;
        if (version == entry.last_polled and connection.stage == entry.last_progress_stage and second == entry.last_progress_second) return null;
        entry.last_polled = version;
        entry.last_progress_stage = connection.stage;
        entry.last_progress_second = second;
        if (entry.outcome_ready.load(.acquire)) return .{ .result = .{ .outcome = if (entry.cancelled()) .cancelled else entry.outcome, .safe_message = try self.resultMessage(entry, false), .cleanup = if (entry.receipt.load(.acquire) == .unknown) .unknown else .awaiting } };
        return .{ .progress = .{ .stage = probeStage(connection.stage), .safe_message = try formatProgress(connection, &self.message_buffer) } };
    }
    fn resultMessage(self: *Provider, entry: *Entry, finished: bool) ![]const u8 {
        const connection = entry.connection_progress.snapshot();
        const logout = if (entry.web_logout.load(.acquire) == .unknown) "；WEB 会话注销未确认" else "";
        if (!entry.cancelled()) if (connection.failure_code) |code| return std.fmt.bufPrint(&self.message_buffer, "{s}失败 · {s} · 总计 {d} 秒{s}{s}", .{ progress.stageLabel(connection.failure_stage orelse .failed), code, connection.elapsed_ms / 1000, logout, if (finished) "" else " · 正在释放连接资源" });
        return std.fmt.bufPrint(&self.message_buffer, "{s} · 总计 {d} 秒{s}", .{ finalMessage(entry), connection.elapsed_ms / 1000, if (finished) "" else " · 正在释放连接资源" });
    }
    fn cancel(raw: *anyopaque, key: operation.OperationKey) contract.CloseReceipt {
        const self = cast(raw);
        self.requireThread() catch return .unknown;
        const slot = self.find(key) orelse return .unknown;
        const entry = slot.*.?;
        entry.cancel_source.store(true, .release);
        entry.cleanup_retry.store(true, .release);
        if (entry.done.load(.acquire)) {
            self.retire(slot);
            return .released;
        }
        return if (entry.receipt.load(.acquire) == .unknown) .unknown else .awaiting;
    }
    fn find(self: *Provider, key: operation.OperationKey) ?*?*Entry {
        for (&self.entries) |*slot| if (slot.*) |entry| {
            if (entry.key.eql(key)) return slot;
        };
        return null;
    }
    fn retire(self: *Provider, slot: *?*Entry) void {
        const entry = slot.*.?;
        std.debug.assert(entry.done.load(.acquire));
        entry.plan.deinit();
        self.allocator.destroy(entry);
        slot.* = null;
    }
};

/// Finer native phases remain visible in safe_message while the public host
/// contract keeps its stable coarse Stage enum.
pub fn probeStage(stage: progress.Stage) contract.Stage {
    return switch (stage) {
        .idle => .accepted,
        .route => .transport,
        .tls_handshake, .waiting_certificate, .video_tls_handshake, .waiting_video_certificate => .trust,
        .waiting_credentials, .web_login => .authentication,
        .public_identity, .public_script, .firmware_confirmation, .redfish_discovery, .oem_session, .websocket_upgrade, .rfb_negotiation, .awaiting_first_frame, .streaming => .discovery,
        .cleanup, .cancelled, .failed => .cleanup,
        .released => .finished,
    };
}
pub fn formatProgress(connection: progress.Snapshot, buffer: []u8) ![]const u8 {
    if (connection.stage == .route and connection.route_hops != 0) return std.fmt.bufPrint(buffer, "建立 {d} 跳 SSH 链 · 阶段 {d} 秒 · 总计 {d} 秒", .{ connection.route_hops, connection.stage_elapsed_ms / 1000, connection.elapsed_ms / 1000 });
    return std.fmt.bufPrint(buffer, "{s} · 阶段 {d} 秒 · 总计 {d} 秒", .{ progress.stageLabel(connection.stage), connection.stage_elapsed_ms / 1000, connection.elapsed_ms / 1000 });
}

fn finalMessage(entry: *const Entry) []const u8 {
    if (entry.cancelled()) return if (entry.web_logout.load(.acquire) == .unknown) "测试已取消；WEB 会话注销未确认" else "测试已取消";
    if (entry.web_logout.load(.acquire) == .unknown) return switch (entry.outcome) {
        .succeeded => "BMC 只读连接测试成功；WEB 会话注销未确认",
        .failed => "BMC 只读连接测试失败；WEB 会话注销未确认",
        .cancelled => "测试已取消；WEB 会话注销未确认",
    };
    return entry.message;
}
