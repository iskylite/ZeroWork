//! Process-owned task resources. Window presenters borrow this domain; they
//! never own its Manager, checkpoints, native transfer backends or listeners.
//! There is deliberately no Cx, Node, Scope, Workspace or ApplicationHost here.
const std = @import("std");
const identity = @import("identity.zig");
const sessions = @import("session_host.zig");
const transfer = @import("../transfer/manager.zig");
const routing = @import("../transfer/engine_mux.zig");
const dispatching = @import("../transfer/engine_dispatch.zig");
const sftp = @import("../transfer/sftp_engine.zig");
const retained_store = @import("retained_transfer_store.zig");
const retained_runtime = @import("file_transfer_runtime.zig");
const native_transfers = @import("file_transfer_host.zig");
const authentication = @import("../ui/file_authentication.zig");
const routes = @import("socks_route_host.zig");
const background = @import("../ui/socks_background_model.zig");
const ssh = @import("../proto/ssh/session.zig");
const Config = @import("../config/config.zig").Config;

pub const AuxiliaryConnection = struct {
    owner: @import("identity.zig").SessionHandle,
    binding: @import("session_host.zig").ServiceHandle,
    key: @import("operation.zig").OperationKey,
    closing: bool = false,
    released: bool = false,
};

pub const SharedConnection = struct {
    owner: @import("identity.zig").SessionHandle,
    binding: @import("session_host.zig").ServiceHandle,
    key: @import("operation.zig").OperationKey,
    service: *@import("../proto/ssh/shared_transfer_service.zig").Service,
    released: bool = false,
    fault_retained: bool = false,
};

pub const RetainedConnection = struct {
    owner: @import("identity.zig").TransferOwner,
    binding: @import("session_host.zig").ServiceHandle,
    key: @import("operation.zig").OperationKey,
    closing: bool = false,
    released: bool = false,
};

pub const RetainedClose = struct {
    owner: @import("identity.zig").SessionHandle,
    key: @import("operation.zig").OperationKey,
    retained_id: @import("identity.zig").RetainedTransferOwnerId,
    jobs: []retained_runtime.RetainJob,
    batch: *retained_store.Batch,
    fault_binding: ?@import("session_host.zig").ServiceHandle = null,
    shared_binding: ?@import("session_host.zig").ServiceHandle = null,
    pending: ?retained_runtime.OwnedRetainedBatch = null,
    deferred_cancel: std.ArrayList(transfer.JobId) = .empty,
    complete: bool = false,
};

pub const JobOwner = struct {
    job: transfer.JobId,
    owner: identity.SessionHandle,
    verification_trace_attempt: u8 = 0,
    directory_refresh: @import("transfer_directory_refresh.zig").Completion = .{},
};

pub const Domain = struct {
    allocator: std.mem.Allocator,
    sessions: *sessions.SessionHost,
    mux: routing.Mux,
    dispatch: dispatching.Dispatch,
    manager: transfer.Manager,
    retained_store: retained_store.Store,
    engine: *sftp.SftpEngine,
    library: ssh.Library,
    authentication: *authentication.FileAuthentication,
    transfers: native_transfers.Host,
    socks: routes.Host,
    backgrounds: ?background.Model = null,
    retained_closes: std.ArrayList(*RetainedClose) = .empty,
    retained_connections: std.ArrayList(RetainedConnection) = .empty,
    auxiliary_connections: std.ArrayList(AuxiliaryConnection) = .empty,
    shared_connections: std.ArrayList(SharedConnection) = .empty,
    job_owners: std.ArrayList(JobOwner) = .empty,
    next_transfer_intent: u64 = 1,
    last_tick_ms: ?u64 = null,
    shutting_down: bool = false,

    /// Allocate first: all interfaces capture stable addresses within Domain.
    /// The config is application-owned and must outlive this resource domain.
    pub fn init(allocator: std.mem.Allocator, io: std.Io, session_domain: *sessions.SessionHost, config: *const Config, known_hosts_path: []const u8, provider: ?routes.SharedProvider) !*Domain {
        const self = try allocator.create(Domain);
        errdefer allocator.destroy(self);
        const engine = try sftp.SftpEngine.init(allocator);
        errdefer engine.deinit();
        self.* = .{
            .allocator = allocator,
            .sessions = session_domain,
            .engine = engine,
            .library = try ssh.Library.init(),
            .mux = routing.Mux.init(allocator, .{ .context = session_domain, .is_live = bindingLive }),
            .dispatch = undefined,
            .manager = undefined,
            .retained_store = undefined,
            .authentication = undefined,
            .transfers = undefined,
            .socks = undefined,
        };
        errdefer self.library.deinit();
        self.dispatch = dispatching.Dispatch.init(allocator, engine.engine(), self.mux.engine());
        self.manager = try transfer.Manager.init(allocator, self.dispatch.engine(), config.transfer.max_tasks, .{});
        errdefer self.manager.deinit();
        self.authentication = try authentication.FileAuthentication.init(allocator, session_domain, .{ .library = &self.library, .known_hosts_path = known_hosts_path, .presentation_config_revision = config.config_revision, .saved_config = config });
        errdefer self.authentication.deinit() catch {};
        self.transfers = try native_transfers.Host.init(allocator, session_domain, &self.mux, self.authentication.factory());
        errdefer self.transfers.deinit() catch {};
        self.socks = try routes.Host.init(allocator, session_domain, .{ .library = &self.library, .known_hosts_path = known_hosts_path, .presentation = if (config.ssh.otp_modal) .otp_modal else .protected_form, .presentation_config_revision = config.config_revision, .timeout_ms = @as(u32, config.ssh.connect_timeout_sec) * 1000, .totp_autofill = config.ssh.totp_autofill, .shared_provider = provider });
        self.retained_store = retained_store.Store.init(allocator, io, &self.manager, &self.mux, &self.dispatch, session_domain);
        return self;
    }

    pub fn bindBackgrounds(self: *Domain, hooks: background.Hooks) *background.Model {
        if (self.backgrounds == null) self.backgrounds = background.Model.init(self.allocator, hooks);
        return &self.backgrounds.?;
    }

    pub fn ownerForJob(self: *const Domain, job: transfer.JobId) ?identity.SessionHandle {
        for (self.job_owners.items) |captured| if (captured.job == job) return captured.owner;
        return null;
    }

    pub const JobSnapshot = struct {
        job: transfer.JobId,
        attempt: u8,
        owner: ?identity.SessionHandle,
        session_id: ?u64,
        retained_owner: ?identity.TransferOwner,
        binding: ?sessions.ServiceHandle,
        progress: transfer.Progress,
    };
    /// Value-only process snapshot; caller frees the returned slice. This is
    /// the authoritative source for per-window manager queries and test routes.
    pub fn jobSnapshots(self: *const Domain, allocator: std.mem.Allocator) ![]JobSnapshot {
        const values = try allocator.alloc(JobSnapshot, self.manager.count());
        for (values, 0..) |*value, index| {
            const progress = self.manager.progressAt(index).?;
            value.* = .{ .job = progress.job, .attempt = progress.attempt, .owner = self.ownerForJob(progress.job), .session_id = self.manager.sessionId(progress.job), .retained_owner = self.manager.retainedOwner(progress.job), .binding = self.manager.transferBinding(progress.job), .progress = progress };
        }
        return values;
    }

    /// Each window may request a tick. The Manager remains the sole progress
    /// consumer, and a process timestamp prevents duplicate scheduling passes.
    pub fn tick(self: *Domain, now_ms: u64, concurrency: u16) !bool {
        if (self.last_tick_ms != null and self.last_tick_ms.? == now_ms) return self.manager.count() != 0;
        self.last_tick_ms = now_ms;
        var active = try self.transfers.safeTick();
        active = try self.authentication.collect() or active;
        active = try self.socks.safeTick() or active;
        active = try self.retained_store.poll() or active;
        self.manager.concurrency = concurrency;
        self.manager.tick(now_ms);
        return active;
    }

    /// Only process shutdown calls this. Closing a window must first move its
    /// checkpoints into retained_store and then drop only its presentation.
    pub fn shutdownStep(self: *Domain) sessions.CloseReceipt {
        self.shutting_down = true;
        var result = self.retained_store.shutdownStep();
        result = combine(result, self.transfers.shutdownStep());
        result = combine(result, self.socks.shutdownStep());
        result = combine(result, switch (self.authentication.shutdownStep()) {
            .released => .released,
            .awaiting => .awaiting,
            .unknown => .unknown,
        });
        for (0..self.manager.count()) |index| {
            const progress = self.manager.progressAt(index).?;
            if (progress.state != .succeeded and progress.state != .failed and progress.state != .cancelled and self.manager.retainedOwner(progress.job) == null) self.manager.cancel(progress.job) catch {};
            const current = self.manager.progress(progress.job).?;
            if (current.job_cleanup != .released) result = combine(result, if (current.job_cleanup == .unknown) .unknown else .awaiting);
        }
        return result;
    }

    /// Returns Busy without freeing resource owners when native release is
    /// incomplete. No window cleanup is allowed to call this method.
    pub fn deinit(self: *Domain) error{Busy}!void {
        for (self.retained_closes.items) |record| if (record.pending != null) return error.Busy;
        if (self.transfers.entries.items.len != 0) return error.Busy;
        if (self.mux.registrations.items.len != 0 or self.mux.jobs.items.len != 0) return error.Busy;
        for (self.dispatch.protocol_fault) |fault| if (fault) return error.Busy;
        for (self.retained_store.batches.items) |batch| {
            for (batch.slots) |slot| if (slot.thread != null or slot.receipt_pending) return error.Busy;
            if (batch.payload) |payload| for (payload.jobs) |job| if (job.checkpoint != null) return error.Busy;
        }
        for (self.authentication.contexts.items) |context| if (!context.closed.load(.acquire)) return error.Busy;
        for (self.socks.shared_entries.items) |entry| if (entry.service != null or entry.last.cleanup != .released) return error.Busy;
        if (self.socks.shutdownStep() != .released) return error.Busy;
        for (self.socks.entries.items) |entry| if (!entry.runtime.done.load(.acquire)) return error.Busy;
        for (self.dispatch.jobs.items) |job| if (!job.terminal) return error.Busy;
        try self.retained_store.deinit();
        try self.transfers.deinit();
        try self.socks.deinit();
        self.authentication.deinit() catch return error.Busy;
        self.manager.deinit();
        try self.dispatch.deinit();
        try self.mux.deinit();
        self.engine.deinit();
        self.library.deinit();
        if (self.backgrounds) |*model| model.deinit();
        for (self.retained_closes.items) |record| {
            record.deferred_cancel.deinit(self.allocator);
            self.allocator.free(record.jobs);
            self.allocator.destroy(record);
        }
        self.retained_closes.deinit(self.allocator);
        self.retained_connections.deinit(self.allocator);
        self.auxiliary_connections.deinit(self.allocator);
        self.shared_connections.deinit(self.allocator);
        self.job_owners.deinit(self.allocator);
        self.allocator.destroy(self);
    }

    fn bindingLive(raw: *anyopaque, binding: sessions.ServiceHandle) bool {
        const domain: *sessions.SessionHost = @ptrCast(@alignCast(raw));
        return domain.bindingIsLive(binding);
    }
};
fn combine(a: sessions.CloseReceipt, b: sessions.CloseReceipt) sessions.CloseReceipt {
    if (a == .unknown or b == .unknown) return .unknown;
    if (a == .awaiting or b == .awaiting) return .awaiting;
    return .released;
}
