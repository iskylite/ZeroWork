//! Original-owner adapter seam over Runtime and the application's one Mux.
//! This host never polls transfer progress, creates operation IDs, opens a
//! terminal, or performs native connection/teardown on the controller thread.
const std = @import("std");
const sessions = @import("session_host.zig");
const files = @import("file_binding_host.zig");
const adapter = @import("sftp_adapter.zig");
const identity = @import("identity.zig");
const operations = @import("operation.zig");
pub const runtime = @import("file_transfer_runtime.zig");
pub const routing = @import("../transfer/engine_mux.zig");
pub const RetainJob = runtime.RetainJob;
pub const RetainedJob = runtime.RetainedJob;
pub const OwnedRetainedBatch = runtime.OwnedRetainedBatch;
pub const RetainedDraft = runtime.RetainedDraft;
pub const OwnedCheckpoint = @import("../transfer/sftp_engine.zig").OwnedCheckpoint;
const transfer = @import("../transfer/manager.zig");
pub const FaultSnapshot = struct {
    owner: identity.SessionHandle,
    binding: sessions.ServiceHandle,
    create_key: operations.OperationKey,
    key: operations.OperationKey,
    failure: operations.Failure,
    cleanup: sessions.CloseReceipt,
};
const Entry = struct {
    owner: identity.SessionHandle,
    create_key: operations.OperationKey,
    open_key: operations.OperationKey,
    binding: sessions.ServiceHandle,
    backend: *runtime.Runtime,
    auxiliary: bool = false,
    registered: bool = false,
    closing: bool = false,
    failure: ?operations.Failure = null,
    receipt: sessions.CloseReceipt = .awaiting,
    retain_close: ?operations.OperationKey = null,
    retain_started: bool = false,
    retain_owner: ?identity.RetainedTransferOwnerId = null,
    published_receipt: ?sessions.CloseReceipt = null,
    faulted: bool = false,
    fault_retained: bool = false,
};

pub const Host = struct {
    allocator: std.mem.Allocator,
    domain: *sessions.SessionHost,
    mux: *routing.Mux,
    factory: files.Factory,
    entries: std.ArrayList(*Entry) = .empty,
    shutting_down: bool = false,

    /// Factory should be SourceFactory.interface() in production. Its prepare
    /// synchronously owns the frozen Source before Runtime receives Connector.
    /// All three dependencies must outlive this host's actual release.
    pub fn init(allocator: std.mem.Allocator, domain: *sessions.SessionHost, mux: *routing.Mux, factory: files.Factory) !Host {
        var self: Host = .{ .allocator = allocator, .domain = domain, .mux = mux, .factory = factory };
        try self.entries.ensureTotalCapacity(allocator, 8);
        return self;
    }
    /// Move Host into stable storage before retaining this context in Adapter.
    pub fn hooks(self: *Host) adapter.TransferHooks {
        return .{ .context = self, .start = start, .poll = poll, .close = close };
    }

    /// Must run before SftpAdapter.safeTick: after domain.ready, this registers
    /// the exact live binding before the adapter can enter presenting. Pending
    /// Manager events remain in Mux; only Manager may poll them.
    pub fn safeTick(self: *Host) !bool {
        var at: usize = 0;
        while (at < self.entries.items.len) {
            const entry = self.entries.items[at];
            if (entry.backend.transportFailure()) |reason| {
                entry.faulted = true;
                if (entry.failure == null) {
                    entry.failure = failure(@errorName(reason), .awaiting);
                    entry.failure.?.domain = .transport;
                    entry.failure.?.retryable = true;
                }
                // This revokes new consumers immediately, including before a
                // fallible journal publication. It does not cancel paused IO.
                try self.publishReleaseReceipt(entry, if (entry.backend.closeReceipt() == .unknown) .unknown else .awaiting);
            }
            const valid = self.current(entry);
            if (self.shutting_down) {
                self.markClosing(entry);
                entry.backend.requestRetainedCancel() catch {
                    entry.receipt = .unknown;
                };
            } else if (!valid and entry.retain_close == null and !entry.faulted) self.markClosing(entry);
            if (entry.faulted and !entry.retain_started and entry.backend.backend.faultJobCount() == 0) self.markClosing(entry);
            if (valid and !entry.closing and !entry.registered and entry.backend.state() == .ready and self.domain.bindingIsLive(entry.binding)) {
                self.mux.register(entry.binding, entry.backend.engine()) catch |err| {
                    if (err == error.OutOfMemory) return err;
                    entry.failure = failure(@errorName(err), .awaiting);
                    self.markClosing(entry);
                };
                if (!entry.closing) {
                    // register succeeded; preserve ownership even if an
                    // inconsistent Mux unexpectedly rejects its guard.
                    entry.registered = true;
                    self.mux.setCleanupGuard(entry.binding, entry.backend.cleanupGuard()) catch |err| {
                        entry.failure = failure(@errorName(err), .unknown);
                        self.markClosing(entry);
                    };
                }
            }
            if (entry.closing and self.collect(entry)) {
                _ = self.entries.orderedRemove(at);
                self.allocator.destroy(entry);
                continue;
            }
            at += 1;
        }
        return self.entries.items.len != 0;
    }

    /// Nonblocking. Actual draining, Mux detach, and done-thread deinit happen
    /// on safeTick. A shared Manager remains responsible for consuming events.
    pub fn shutdownStep(self: *Host) sessions.CloseReceipt {
        self.shutting_down = true;
        var result: sessions.CloseReceipt = .released;
        for (self.entries.items) |entry| {
            self.markClosing(entry);
            entry.backend.requestRetainedCancel() catch {
                entry.receipt = .unknown;
            };
            result = combine(result, self.waitReceipt(entry));
        }
        return result;
    }
    pub fn deinit(self: *Host) error{Busy}!void {
        if (self.entries.items.len != 0) return error.Busy;
        self.entries.deinit(self.allocator);
        self.* = undefined;
    }

    /// First line of the original pause-transfers hook: gate automatic stale
    /// binding cancellation while Manager obtains real paused/released events.
    pub fn prepareRetain(self: *Host, owner: identity.SessionHandle, close_key: operations.OperationKey) !void {
        try self.validateRetainClose(owner, close_key);
        if (self.shutting_down) return error.TransferHostClosing;
        for (self.entries.items) |entry| if (entry.binding.resource_owner == .session and entry.owner.eql(owner)) {
            if (entry.retain_close) |original| {
                if (!original.eql(close_key)) return error.StaleCloseOperation;
                continue;
            }
            if (entry.closing) return error.TransferHostClosing;
            entry.retain_close = close_key;
        };
    }

    /// Released means the original worker exported the complete batch and
    /// actually released its native connector. hooks.close still waits for
    /// takeRetained, the old Mux routes, and Runtime destruction.
    pub fn retainPaused(self: *Host, owner: identity.SessionHandle, close_key: operations.OperationKey, retained_owner: identity.RetainedTransferOwnerId, jobs: []const RetainJob) !sessions.CloseReceipt {
        try self.validateRetainClose(owner, close_key);
        if (self.shutting_down) return error.TransferHostClosing;
        if (self.domain.retainedTransferSource(retained_owner, owner) == null) return error.UnknownRetainedTransfer;
        const entry = self.findOriginal(owner) orelse {
            if (jobs.len != 0) return error.UnknownTransferBackend;
            return .released;
        };
        if (entry.retain_close == null or !entry.retain_close.?.eql(close_key)) return error.RetainNotPrepared;
        if (!entry.retain_started) {
            try entry.backend.requestRetain(owner, close_key, retained_owner, jobs);
            entry.retain_started = true;
            entry.retain_owner = retained_owner;
            entry.closing = true;
        } else if (entry.retain_owner != retained_owner) return error.RetainAlreadyRequested else if (entry.backend.retained != null) try entry.backend.requestRetain(owner, close_key, retained_owner, jobs);
        const receipt = convert(entry.backend.closeReceipt());
        if (receipt == .released and !entry.backend.done.load(.acquire)) return .awaiting;
        return receipt;
    }

    pub fn takeRetained(self: *Host, owner: identity.SessionHandle, close_key: operations.OperationKey) !?OwnedRetainedBatch {
        try self.validateRetainClose(owner, close_key);
        const entry = self.findOriginal(owner) orelse return null;
        if (!entry.retain_started or entry.retain_close == null or !entry.retain_close.?.eql(close_key)) return error.RetainNotPrepared;
        return entry.backend.takeRetained();
    }

    /// The caller may use a normal create key to discover the actual failed
    /// open key. A similarly named owner or another generation cannot match.
    pub fn fault(self: *Host, binding: sessions.ServiceHandle, create_key: operations.OperationKey) ?FaultSnapshot {
        const entry = self.find(binding) orelse return null;
        if (!entry.create_key.eql(create_key) or entry.backend.transportFailure() == null) return null;
        var actual = failure("TransferTransportClosed", convert(entry.backend.closeReceipt()));
        actual.domain = .transport;
        actual.retryable = true;
        return .{ .owner = entry.owner, .binding = entry.binding, .create_key = entry.create_key, .key = entry.open_key, .failure = actual, .cleanup = if (entry.receipt == .unknown) .unknown else convert(entry.backend.closeReceipt()) };
    }

    /// Accept the original Manager/Mux identities after paused/released, and
    /// after SessionHost has authorized this exact fault source. No IO here.
    pub fn retainFault(self: *Host, binding: sessions.ServiceHandle, key: operations.OperationKey, retained_owner: identity.RetainedTransferOwnerId, jobs: []const RetainJob) !sessions.CloseReceipt {
        if (self.shutting_down) return error.TransferHostClosing;
        const entry = self.find(binding) orelse return error.StaleTransferFault;
        if (!entry.open_key.eql(key) or entry.backend.transportFailure() == null or !self.domain.faultTransferSourceIsCurrent(retained_owner, entry.owner, binding, key)) return error.StaleTransferFault;
        if (!entry.retain_started) {
            try entry.backend.requestFaultRetain(key, retained_owner, jobs);
            entry.retain_started = true;
            entry.fault_retained = true;
            entry.retain_owner = retained_owner;
            entry.closing = true;
        } else {
            if (!entry.fault_retained or entry.retain_owner != retained_owner) return error.RetainAlreadyRequested;
            if (entry.backend.retained != null) try entry.backend.requestFaultRetain(key, retained_owner, jobs);
        }
        const receipt = convert(entry.backend.closeReceipt());
        return if (receipt == .released and !entry.backend.done.load(.acquire)) .awaiting else receipt;
    }

    pub fn takeFaultRetained(self: *Host, binding: sessions.ServiceHandle, key: operations.OperationKey) !?OwnedRetainedBatch {
        const entry = self.find(binding) orelse return error.StaleTransferFault;
        if (!entry.open_key.eql(key) or !entry.fault_retained or entry.retain_owner == null or !self.domain.faultTransferSourceIsCurrent(entry.retain_owner.?, entry.owner, binding, key)) return error.StaleTransferFault;
        return entry.backend.takeRetained();
    }

    /// Caller reserves Manager/Mux capacity first, then adopts the returned
    /// native ID without opening another job. IO revalidation is asynchronous.
    pub fn importPaused(self: *Host, binding: sessions.ServiceHandle, key: operations.OperationKey, checkpoint: *OwnedCheckpoint, spec: transfer.JobSpec) !transfer.EngineJobId {
        const entry = try self.readyRetainedEntry(binding, key);
        return entry.backend.importPaused(checkpoint, spec);
    }

    pub fn startRetainedDraft(self: *Host, binding: sessions.ServiceHandle, key: operations.OperationKey, draft: RetainedDraft) !transfer.EngineJobId {
        const entry = try self.readyRetainedEntry(binding, key);
        return entry.backend.startRetainedDraft(draft);
    }

    fn readyRetainedEntry(self: *Host, binding: sessions.ServiceHandle, key: operations.OperationKey) !*Entry {
        if (self.shutting_down) return error.TransferHostClosing;
        const entry = self.find(binding) orelse return error.UnknownTransferBackend;
        if (entry.closing or !entry.registered or !entry.open_key.eql(key) or !self.current(entry) or !self.domain.bindingIsLive(binding)) return error.TransferNotReady;
        if (binding.resource_owner != .retained_transfer) return error.InvalidTransferOwner;
        return entry;
    }

    fn validateRetainClose(self: *Host, owner: identity.SessionHandle, key: operations.OperationKey) !void {
        if (key.operation_id == 0 or key.owner != .session or !key.owner.session.eql(owner)) return error.StaleCloseOperation;
        const state = self.domain.queryState(owner) orelse return error.StaleSession;
        if ((state.lifecycle != .closing and state.lifecycle != .cleanup_unknown) or state.close_operation == null or !state.close_operation.?.eql(key)) return error.StaleCloseOperation;
    }

    fn findOriginal(self: *Host, owner: identity.SessionHandle) ?*Entry {
        for (self.entries.items) |entry| if (entry.binding.resource_owner == .session and entry.owner.eql(owner)) return entry;
        return null;
    }

    fn start(raw: *anyopaque, request: adapter.TransferStart) !void {
        const self: *Host = @ptrCast(@alignCast(raw));
        if (self.shutting_down) return error.TransferHostClosing;
        const source = request.source;
        const auxiliary = source.retained_owner == null and source.create_key.eql(source.open_key) and self.domain.auxiliaryTransferOperationIsCurrent(source.owner, source.open_key);
        try validateIdentity(request.binding, source.owner, source.create_key, auxiliary);
        if (source.retained_owner) |id| {
            if (request.binding.resource_owner != .retained_transfer or request.binding.resource_owner.retained_transfer != id or !source.create_key.eql(source.open_key) or !source.ownsOperation(source.open_key) or !self.domain.retainedTransferOperationIsCurrent(id, source.owner, source.open_key)) return error.StaleCreateOperation;
        } else if (auxiliary) {
            if (request.binding.resource_owner != .session or !source.ownsOperation(source.open_key)) return error.OwnerMismatch;
        } else {
            if (request.binding.resource_owner != .session) return error.OwnerMismatch;
            const state = self.domain.queryState(source.owner) orelse return error.StaleSession;
            if (!state.create_operation.eql(source.create_key)) return error.StaleCreateOperation;
            if (!source.ownsOperation(source.open_key) or source.open_key.eql(source.create_key) or source.open_key.attempt_id != source.create_key.attempt_id) return error.InvalidTransferOperation;
        }
        if (!self.domain.bindingIsPreparing(request.binding, source.create_key)) return error.TransferBindingNotPreparing;
        var open = false;
        for (self.domain.journal.records.items) |record| if (record.key.eql(source.open_key)) {
            if (record.terminal) return error.TransferOperationTerminal;
            open = true;
            break;
        };
        if (!open) return error.UnknownOperation;
        const saved = (if (source.retained_owner) |id| self.domain.retainedTransferSource(id, source.owner) else self.savedSpec(source.owner)) orelse return error.StaleSession;
        if (!sameSpec(saved, source.spec)) return error.TransferSourceChanged;
        try source.spec.validate();
        if (source.spec == .local) return error.UnsupportedProtocol;
        if (self.find(request.binding)) |entry| {
            if (!entry.owner.eql(source.owner) or !entry.create_key.eql(source.create_key) or !entry.open_key.eql(source.open_key)) return error.TransferBindingBusy;
            if (entry.closing) return error.TransferHostClosing;
            return;
        }
        for (self.entries.items) |entry| if (entry.binding.binding_id == request.binding.binding_id or (entry.owner.eql(source.owner) and entry.create_key.eql(source.create_key))) return error.TransferBindingBusy;
        // Complete every controller allocation before accepting a worker.
        try self.entries.ensureUnusedCapacity(self.allocator, 1);
        const entry = try self.allocator.create(Entry);
        errdefer self.allocator.destroy(entry);
        const connector = try self.factory.prepare(self.factory.context, source);
        var transferred = false;
        errdefer if (!transferred) self.factory.discard(self.factory.context, connector);
        if (!connector.key.eql(source.open_key)) return error.FactoryOperationMismatch;
        const backend = if (auxiliary) try runtime.Runtime.startAuxiliary(self.allocator, request.binding, connector) else try runtime.Runtime.start(self.allocator, request.binding, connector);
        transferred = true;
        entry.* = .{ .owner = source.owner, .create_key = source.create_key, .open_key = source.open_key, .binding = request.binding, .backend = backend, .auxiliary = auxiliary };
        self.entries.appendAssumeCapacity(entry);
    }

    fn poll(raw: *anyopaque, binding: sessions.ServiceHandle, create_key: operations.OperationKey) adapter.TransferStatus {
        const self: *Host = @ptrCast(@alignCast(raw));
        const entry = self.find(binding) orelse return .{ .failed = failure("transfer_backend_not_started", .released) };
        if (!entry.create_key.eql(create_key)) return .{ .failed = failure("stale_transfer_create_operation", .unknown) };
        if (!self.current(entry)) return .{ .failed = failure("stale_transfer_binding", self.waitReceipt(entry)) };
        if (entry.failure) |value| {
            var result = value;
            result.cleanup = cleanup(self.waitReceipt(entry));
            return .{ .failed = result };
        }
        if (entry.closing) return .{ .failed = failure("transfer_backend_closing", self.waitReceipt(entry)) };
        if (entry.backend.failureReason()) |reason| return .{ .failed = failure(@errorName(reason), convert(entry.backend.closeReceipt())) };
        return switch (entry.backend.state()) {
            .connecting => .pending,
            .ready => .{ .ready = entry.binding },
            .failed => .{ .failed = failure("transfer_connection_failed", convert(entry.backend.closeReceipt())) },
            .closing => .{ .failed = failure("transfer_backend_closing", self.waitReceipt(entry)) },
            .cleanup_unknown => .{ .failed = failure("transfer_cleanup_unknown", .unknown) },
            .closed => .{ .failed = failure("transfer_backend_closed", self.waitReceipt(entry)) },
        };
    }

    fn close(raw: *anyopaque, request: adapter.TransferClose) sessions.CloseReceipt {
        const self: *Host = @ptrCast(@alignCast(raw));
        const original = self.find(request.binding);
        const auxiliary = if (original) |entry| entry.auxiliary else self.domain.auxiliaryTransferOwns(request.binding, request.create_key);
        validateIdentity(request.binding, request.owner, request.create_key, auxiliary) catch return .unknown;
        if (!sameCommandOwner(request.operation.owner, request.create_key.owner)) return .unknown;
        if (original) |entry| {
            if (!entry.owner.eql(request.owner) or !entry.create_key.eql(request.create_key)) return .unknown;
            if (!self.validClose(request, auxiliary)) return .unknown;
            self.markClosing(entry);
            return self.waitReceipt(entry);
        }
        // A rejected prepare/start retained no backend. Do not close a similar
        // physical ID or a different generation which this request does not own.
        for (self.entries.items) |entry| if (entry.binding.binding_id == request.binding.binding_id) return .unknown;
        return if (self.validClose(request, auxiliary)) .released else .unknown;
    }

    fn validClose(self: *Host, request: adapter.TransferClose, auxiliary: bool) bool {
        if (request.operation.eql(request.create_key)) return true;
        if (request.binding.resource_owner == .retained_transfer) return false;
        const state = self.domain.queryState(request.owner) orelse return false;
        return (auxiliary or state.create_operation.eql(request.create_key)) and state.close_operation != null and state.close_operation.?.eql(request.operation);
    }
    fn current(self: *Host, entry: *const Entry) bool {
        if (entry.binding.resource_owner == .retained_transfer) return self.domain.retainedTransferOperationIsCurrent(entry.binding.resource_owner.retained_transfer, entry.owner, entry.open_key) and (self.domain.bindingIsPreparing(entry.binding, entry.create_key) or self.domain.bindingIsLive(entry.binding));
        if (entry.auxiliary) return self.domain.auxiliaryTransferOperationIsCurrent(entry.owner, entry.open_key) and (self.domain.bindingIsPreparing(entry.binding, entry.create_key) or self.domain.bindingIsLive(entry.binding));
        const state = self.domain.queryState(entry.owner) orelse return false;
        return state.create_operation.eql(entry.create_key) and (self.domain.bindingIsPreparing(entry.binding, entry.create_key) or self.domain.bindingIsLive(entry.binding));
    }
    fn find(self: *Host, binding: sessions.ServiceHandle) ?*Entry {
        for (self.entries.items) |entry| if (entry.binding.eql(binding)) return entry;
        return null;
    }
    fn savedSpec(self: *Host, owner: identity.SessionHandle) ?sessions.SessionCreateSpec {
        return self.domain.engineSpec(owner);
    }
    fn markClosing(self: *Host, entry: *Entry) void {
        if (!entry.closing) {
            self.publishReleaseReceipt(entry, .awaiting) catch {
                entry.receipt = .unknown;
            };
        }
        entry.closing = true;
        entry.backend.requestClose();
    }
    fn waitReceipt(_: *Host, entry: *const Entry) sessions.CloseReceipt {
        if (entry.receipt == .unknown or entry.backend.closeReceipt() == .unknown) return .unknown;
        // Even native released waits for Runtime.done, all original Mux jobs'
        // terminal events, successful Mux detach, then Runtime.deinit.
        return .awaiting;
    }
    fn collect(self: *Host, entry: *Entry) bool {
        const actual = entry.backend.closeReceipt();
        if (actual != .released) {
            entry.receipt = convert(actual);
            self.publishReleaseReceipt(entry, entry.receipt) catch {
                entry.receipt = .unknown;
            };
            return false;
        }
        if (entry.registered) {
            self.mux.detach(entry.binding) catch |err| switch (err) {
                error.JobsActive, error.CleanupPending => {
                    entry.receipt = .awaiting;
                    return false;
                },
                error.CleanupUnknown, error.EngineProtocolFault, error.CleanupGuardMissing, error.UnknownBinding => {
                    entry.receipt = .unknown;
                    return false;
                },
            };
            entry.registered = false;
        }
        if (!entry.backend.canDestroy()) {
            entry.receipt = .awaiting;
            return false;
        }
        self.publishReleaseReceipt(entry, .released) catch {
            entry.receipt = .awaiting;
            return false;
        };
        entry.backend.deinit() catch unreachable;
        return true;
    }

    fn publishReleaseReceipt(self: *Host, entry: *Entry, receipt: sessions.CloseReceipt) !void {
        if (!entry.auxiliary and entry.binding.resource_owner != .retained_transfer) return;
        if (entry.published_receipt) |previous| if (previous == receipt or (previous == .unknown and receipt == .awaiting)) return;
        const accepted = if (entry.auxiliary) try self.domain.auxiliaryTransferReleased(entry.binding, entry.open_key, receipt) else try self.domain.retainedTransferReleased(entry.binding, entry.open_key, receipt);
        if (!accepted) return error.StaleTransferRelease;
        entry.published_receipt = receipt;
    }
};

fn validateIdentity(binding: sessions.ServiceHandle, owner: identity.SessionHandle, create_key: operations.OperationKey, auxiliary: bool) !void {
    if (binding.kind != .transfer or binding.binding_id == 0 or binding.binding_generation == 0) return error.InvalidTransferBinding;
    if (@backingInt(owner.session_id) == 0 or owner.generation == 0) return error.OwnerMismatch;
    switch (binding.resource_owner) {
        .session => |actual| {
            if (!actual.eql(owner) or (!auxiliary and binding.binding_generation != owner.generation) or create_key.owner != .session or !create_key.owner.session.eql(owner)) return error.OwnerMismatch;
            if (auxiliary and (binding.origin_session == null or create_key.attempt_id == null or create_key.attempt_id.? == 0)) return error.OwnerMismatch;
        },
        .retained_transfer => |id| {
            if (@backingInt(id) == 0 or binding.origin_session == null or create_key.owner != .transfer_owner or create_key.owner.transfer_owner.id != id or !create_key.owner.transfer_owner.original_handle.eql(owner) or create_key.attempt_id != binding.binding_generation) return error.OwnerMismatch;
        },
    }
    if (binding.origin_session) |origin| if (!origin.eql(owner)) return error.OwnerMismatch;
    if (create_key.operation_id == 0) return error.StaleCreateOperation;
}
fn sameCommandOwner(a: identity.CommandOwner, b: identity.CommandOwner) bool {
    return a.eql(b);
}
fn convert(value: files.readonly.ReleaseReceipt) sessions.CloseReceipt {
    return switch (value) {
        .released => .released,
        .awaiting => .awaiting,
        .unknown => .unknown,
    };
}
fn cleanup(value: sessions.CloseReceipt) operations.Cleanup {
    return switch (value) {
        .released => .released,
        .awaiting => .releasing,
        .unknown => .unknown,
    };
}
fn combine(a: sessions.CloseReceipt, b: sessions.CloseReceipt) sessions.CloseReceipt {
    if (a == .unknown or b == .unknown) return .unknown;
    if (a == .awaiting or b == .awaiting) return .awaiting;
    return .released;
}
fn failure(code: []const u8, receipt: sessions.CloseReceipt) operations.Failure {
    return .{ .domain = .transport, .code = code, .stage = "sftp_transfer", .cleanup = cleanup(receipt), .safe_message = "文件传输连接未就绪" };
}
fn sameSpec(a: sessions.SessionCreateSpec, b: sessions.SessionCreateSpec) bool {
    if (std.meta.activeTag(a) != std.meta.activeTag(b)) return false;
    return switch (a) {
        .local, .plugin => false,
        .saved => |left| blk: {
            const right = b.saved;
            break :blk left.connection_id == right.connection_id and left.config_revision == right.config_revision and left.protocol == right.protocol and left.credential_ref == right.credential_ref and std.mem.eql(u8, left.private_options, right.private_options) and sameConfig(left.immutable_config, right.immutable_config) and sameRoute(left.route_snapshot, right.route_snapshot);
        },
        .temporary_ssh => |left| blk: {
            const right = b.temporary_ssh;
            break :blk sameEndpoint(left.structured_endpoint, right.structured_endpoint) and sameAuth(left.auth_options, right.auth_options) and left.strict_host_key_checking == right.strict_host_key_checking and sameRoute(left.route_snapshot, right.route_snapshot);
        },
    };
}
fn sameEndpoint(a: sessions.Endpoint, b: sessions.Endpoint) bool {
    return a.port == b.port and std.mem.eql(u8, a.host, b.host) and std.mem.eql(u8, a.user, b.user);
}
fn sameAuth(a: sessions.AuthOptions, b: sessions.AuthOptions) bool {
    if (std.meta.activeTag(a) != std.meta.activeTag(b)) return false;
    return switch (a) {
        .agent, .password_prompt, .keyboard_interactive => true,
        .password => |left| std.mem.eql(u8, left, b.password),
        .private_key => |left| std.mem.eql(u8, left.path, b.private_key.path) and sameOptional(left.passphrase, b.private_key.passphrase),
    };
}
fn sameConfig(a: sessions.RemoteConfig, b: sessions.RemoteConfig) bool {
    if (!sameEndpoint(a.endpoint, b.endpoint) or !sameAuth(a.auth, b.auth) or a.strict_host_key_checking != b.strict_host_key_checking or !std.mem.eql(u8, a.terminal_type, b.terminal_type) or a.keepalive_sec != b.keepalive_sec or a.compression != b.compression or a.auto_shell_integration != b.auto_shell_integration or a.startup_commands.len != b.startup_commands.len) return false;
    for (a.startup_commands, b.startup_commands) |left, right| if (!std.mem.eql(u8, left, right)) return false;
    return true;
}
fn sameOptional(a: ?[]const u8, b: ?[]const u8) bool {
    return if (a) |left| if (b) |right| std.mem.eql(u8, left, right) else false else b == null;
}
fn sameRoute(a: []const sessions.RouteHop, b: []const sessions.RouteHop) bool {
    if (a.len != b.len) return false;
    for (a, b) |left, right| if (!std.meta.eql(left.owner, right.owner) or !std.mem.eql(u8, left.display_name, right.display_name) or left.protocol != right.protocol or !sameEndpoint(left.endpoint, right.endpoint) or !sameAuth(left.auth, right.auth) or left.strict_host_key_checking != right.strict_host_key_checking) return false;
    return true;
}
