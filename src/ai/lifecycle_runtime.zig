//! Worker-owned durable lifecycle transactions. Controller calls are bounded
//! prepare/validate/publish/enqueue operations; all journal IO stays here.
const std = @import("std");
const host = @import("host_tools.zig");
const tools = @import("host_lifecycle.zig");
const identity = @import("../host/identity.zig");
const journal = @import("lifecycle_journal.zig");
const provider = @import("provider.zig");
const approvals = @import("host_approval.zig");
const queries = @import("host_queries.zig");
const lifecycle = tools.lifecycle;
pub const bootstrap_product = @import("ssh_bootstrap_product.zig");

/// Configuration is acquired without disk IO. Every window with the same
/// absolute data-root/path receives this same owner, journal and IO mutex.
pub const JournalConfig = struct { data_root: []const u8, path: []const u8 = "ai/lifecycle.json", dir: ?std.Io.Dir = null, io: ?std.Io = null };
var registry_mutex: std.atomic.Mutex = .unlocked;
var owners: [8]?*ProcessJournal = @splat(null);
fn lock(mutex: *std.atomic.Mutex) void {
    while (!mutex.tryLock()) std.atomic.spinLoopHint();
}
pub const ProcessJournal = struct {
    mutex: std.atomic.Mutex = .unlocked,
    scope_key: []u8,
    data_root: []u8,
    path: []u8,
    dir: ?std.Io.Dir,
    io: std.Io,
    threaded: std.Io.Threaded,
    owns_directory: bool = false,
    refs: usize = 1,
    store: ?journal.Journal = null,
    pub fn acquire(config: JournalConfig) !*ProcessJournal {
        if (!std.fs.path.isAbsolute(config.data_root) or config.path.len == 0 or std.fs.path.isAbsolute(config.path) or std.mem.indexOf(u8, config.path, "..") != null) return error.InvalidJournalPath;
        const a = std.heap.page_allocator;
        const scope_key = try std.fs.path.resolveAlloc(a, &.{ config.data_root, config.path });
        defer a.free(scope_key);
        lock(&registry_mutex);
        defer registry_mutex.unlock();
        var empty: ?usize = null;
        for (owners, 0..) |maybe, index| {
            if (maybe) |owner| {
                if (std.mem.eql(u8, owner.scope_key, scope_key)) {
                    owner.refs += 1;
                    return owner;
                }
            } else if (empty == null) empty = index;
        }
        const slot = empty orelse return error.JournalScopeLimit;
        const owner = try a.create(ProcessJournal);
        errdefer a.destroy(owner);
        owner.* = .{ .scope_key = try a.dupe(u8, scope_key), .data_root = undefined, .path = undefined, .dir = config.dir, .io = undefined, .threaded = .init(a, .{}) };
        owner.io = config.io orelse owner.threaded.io();
        errdefer a.free(owner.scope_key);
        errdefer owner.threaded.deinit();
        owner.data_root = try a.dupe(u8, config.data_root);
        errdefer a.free(owner.data_root);
        owner.path = try a.dupe(u8, config.path);
        owners[slot] = owner;
        return owner;
    }
    /// Release only after this window's worker has joined. The final process
    /// owner closes the file lock; no UI callback calls this during a tool.
    pub fn release(self: *ProcessJournal) void {
        lock(&registry_mutex);
        defer registry_mutex.unlock();
        self.refs -= 1;
        if (self.refs != 0) return;
        if (self.store) |*store| store.deinit();
        if (self.owns_directory) self.dir.?.close(self.io);
        self.threaded.deinit();
        for (&owners) |*owner| if (owner.* == self) {
            owner.* = null;
            break;
        };
        const a = std.heap.page_allocator;
        a.free(self.scope_key);
        a.free(self.data_root);
        a.free(self.path);
        a.destroy(self);
    }
    fn openLocked(self: *ProcessJournal) !*journal.Journal {
        if (self.dir == null) {
            self.dir = try std.Io.Dir.cwd().openDir(self.io, self.data_root, .{ .follow_symlinks = false });
            self.owns_directory = true;
        }
        if (self.store == null) self.store = try journal.Journal.open(std.heap.page_allocator, self.io, self.dir.?, self.path);
        return &self.store.?;
    }
    pub fn begin(self: *ProcessJournal, request: journal.Request) !journal.Handle {
        lock(&self.mutex);
        defer self.mutex.unlock();
        return (try self.openLocked()).begin(request);
    }
    pub fn snapshot(self: *ProcessJournal, a: std.mem.Allocator, handle: journal.Handle) !journal.Record {
        lock(&self.mutex);
        defer self.mutex.unlock();
        return (try self.openLocked()).snapshot(a, handle);
    }
    pub fn update(self: *ProcessJournal, handle: journal.Handle, revision: u64, change: journal.Update) !void {
        lock(&self.mutex);
        defer self.mutex.unlock();
        return (try self.openLocked()).update(handle, revision, change);
    }
    /// Persist the provider's acknowledged watermark only at a closed tool-pair
    /// round boundary. Same CID/task is sufficient after a binding handoff.
    pub fn acknowledgeNotice(self: *ProcessJournal, context: host.Context, revision: u64) !void {
        try context.validate();
        lock(&self.mutex);
        defer self.mutex.unlock();
        const store = try self.openLocked();
        for (store.records.items, 0..) |record, index| {
            if (!record.context.conversation_id.eql(context.conversation_id) or !record.context.task_id.eql(context.task_id) or record.notice_revision == 0 or record.notice_revision > revision or record.wire_notice_revision >= record.notice_revision) continue;
            if (record.stage != .committed and record.stage != .succeeded) continue;
            try store.update(.{ .index = index, .operation_ref = record.operation_ref }, record.revision, .{ .stage = .succeeded, .local_released = record.local_released, .remote_effect_unknown = record.remote_effect_unknown, .wire_notice_revision = record.notice_revision });
        }
    }
};

/// Host preflight must resolve generations/membership, exact Task grants,
/// policy/mode/retention and borrowed-resource impact. Approval never replaces
/// those checks. Repeated preflight must produce the same frozen authorization.
pub const Authorized = struct {
    source: ?identity.SessionHandle = null,
    saved_source: ?identity.AssetOwner = null,
    session: ?identity.SessionHandle = null,
    group: ?identity.GroupOwner = null,
    retention: lifecycle.Retention = .auto_idle,
    allow_new_fallback: bool = false,
    explicit_user_close: bool = false,
    approval_required: bool = true,
    policy_revision: u64 = 1,
    membership_revision: ?u64 = null,
    ownership_revision: ?u64 = null,
    impact_revision: ?u64 = null,
    create_operation: ?@import("../host/operation.zig").OperationKey = null,
    disconnect_binding: ?@import("../host/session_host.zig").ServiceHandle = null,
    bootstrap_required: bool = false,
};
pub const GroupPlan = struct { id: u64, token: *anyopaque, binding_revision: u64, notice_revision: u64 };
pub const CloseSnapshot = struct {
    operation_ref: identity.HostOperationId,
    session: identity.SessionHandle,
    state: enum { awaiting_result, closing, cleanup_pending, closed, cancelled_unsent, outcome_unknown },
    revision: u64 = 1,
    local_released: bool = true,
    remote_effect_unknown: bool = false,
    error_code: ?[]const u8 = null,
    recording_id: ?[32]u8 = null,
    recording_generation: u64 = 0,
    recording_unavailable_reason: ?[]const u8 = "RecordingUnavailable",
};
pub const MutationReceipt = struct {
    state: enum { committed, pending, disconnected, ready, outcome_unknown },
    source_revision: u64,
    session: ?identity.SessionHandle = null,
    group: ?identity.GroupOwner = null,
    membership_revision: ?u64 = null,
    ownership_revision: ?u64 = null,
    notice_revision: ?u64 = null,
    local_released: bool = true,
    remote_effect_unknown: bool = false,
    operation_ref: ?identity.HostOperationId = null,
    error_code: ?[]const u8 = null,
    operation_accepted: ?bool = true,
};
pub const Action = union(enum) {
    authorize: tools.Request,
    prepare_group: struct { operation: identity.HostOperationId, request: tools.Request, authorized: Authorized },
    commit_group: GroupPlan,
    release_group: GroupPlan,
    queue_open: lifecycle.OpenRequest,
    query_open: identity.HostOperationId,
    resolve_owned: identity.SessionHandle,
    authorize_open: struct { operation: identity.HostOperationId, revision: u64, session: identity.SessionHandle },
    cancel_open: identity.HostOperationId,
    probe_bootstrap: identity.HostOperationId,
    install_bootstrap: *bootstrap_product.Prepared,
    queue_close: struct { operation: identity.HostOperationId, session: identity.SessionHandle, explicit_user_close: bool },
    query_close: identity.HostOperationId,
    acknowledge_close: identity.HostOperationId,
    set_retention: struct { session: identity.SessionHandle, retention: lifecycle.Retention },
    query_disconnect: identity.HostOperationId,
    mutate: struct { operation: identity.HostOperationId, request: tools.Request, authorized: Authorized },
};
pub const Call = struct {
    context: host.Context,
    action: Action,
    result: union(enum) { none, authorized: Authorized, group_plan: GroupPlan, session: lifecycle.Snapshot, close: CloseSnapshot, mutation: MutationReceipt, bootstrap_probe: ?bootstrap_product.Probed } = .none,
};
pub const Controller = struct { context: *anyopaque, invoke: *const fn (*anyopaque, *Call) anyerror!void };
/// Bridge adapter: call(context, task_context, task_fn, cancel) invokes the
/// supplied task through Bridge.callController outside the Bridge lock.
pub const Scheduler = struct { context: *anyopaque, call: *const fn (*anyopaque, *anyopaque, *const fn (*anyopaque) anyerror!void, ?*provider.CancelToken) anyerror!void };
pub const Runtime = struct {
    journal_owner: *ProcessJournal,
    controller: Controller,
    approval: ?*approvals.Broker = null,

    fn controllerCall(self: *Runtime, scheduler: Scheduler, context: host.Context, action: Action, cancel: ?*provider.CancelToken) !Call {
        const Exchange = struct {
            controller: Controller,
            call: Call,
            fn run(raw: *anyopaque) !void {
                const exchange: *@This() = @ptrCast(@alignCast(raw));
                try exchange.controller.invoke(exchange.controller.context, &exchange.call);
            }
        };
        var exchange: Exchange = .{ .controller = self.controller, .call = .{ .context = context, .action = action } };
        try scheduler.call(scheduler.context, &exchange, Exchange.run, cancel);
        return exchange.call;
    }
    pub fn execute(self: *Runtime, scheduler: Scheduler, invocation: host.Invocation, allocator: std.mem.Allocator, cancel: ?*provider.CancelToken) !host.Result {
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const transient = try self.executeInner(scheduler, invocation, arena.allocator(), cancel);
        const blocks = try allocator.alloc(host.Block, transient.blocks.len);
        var count: usize = 0;
        errdefer {
            for (blocks[0..count]) |block| switch (block) {
                .text, .structured => |body| allocator.free(body),
            };
            allocator.free(blocks);
        }
        for (transient.blocks, blocks) |block, *owned| {
            owned.* = switch (block) {
                .text => |body| .{ .text = try allocator.dupe(u8, body) },
                .structured => |body| .{ .structured = try allocator.dupe(u8, body) },
            };
            count += 1;
        }
        var result = transient;
        result.blocks = blocks;
        return result;
    }
    fn executeInner(self: *Runtime, scheduler: Scheduler, invocation: host.Invocation, allocator: std.mem.Allocator, cancel: ?*provider.CancelToken) !host.Result {
        const request = try tools.parse(invocation);
        try cancelled(cancel);
        const canonical = try @import("canonical_arguments.zig").digest(allocator, invocation.arguments);
        if (!std.mem.eql(u8, &canonical, &invocation.canonical_arguments_hash)) return error.InvalidArguments;
        if (request.kind == .wait_session_ready) return self.wait(scheduler, invocation, request, allocator, cancel);
        const handle = self.journal_owner.begin(.{ .context = invocation.context, .tool_id = invocation.tool_id, .request_key = request.request_key, .canonical_hash = canonical, .turn_id = invocation.turn_id, .call_id = invocation.call_id }) catch |err| return journalError(invocation, allocator, err, false);
        if (handle.reused) {
            var prior = try self.journal_owner.snapshot(allocator, handle);
            defer prior.deinit(allocator);
            if (request.kind == .open_session and (prior.stage == .committed or prior.stage == .succeeded) and prior.created_session != null) {
                const observed = self.controllerCall(scheduler, invocation.context, .{ .query_open = handle.operation_ref }, cancel) catch null;
                if (observed) |value| if (value.result == .session and value.result.session.session != null and value.result.session.session.?.eql(prior.created_session.?)) return sessionResult(allocator, invocation, handle.operation_ref, value.result.session, false, true);
            }
            if (request.kind == .close_session and prior.dispatch_started and prior.created_session != null) {
                const observed = self.controllerCall(scheduler, invocation.context, .{ .query_close = handle.operation_ref }, cancel) catch null;
                if (observed) |value| if (value.result == .close and value.result.close.session.eql(prior.created_session.?)) return closeResult(allocator, invocation, handle.operation_ref, value.result.close, true);
            }
            if (request.kind == .disconnect_session and prior.dispatch_started and prior.created_session != null) {
                // Query the original receipt only. Neither a new request key
                // nor a lost reply is permission to enqueue cleanup again.
                const observed = self.controllerCall(scheduler, invocation.context, .{ .query_disconnect = handle.operation_ref }, cancel) catch null;
                if (observed) |value| if (value.result == .mutation) return disconnectResult(allocator, invocation, handle.operation_ref, prior.created_session.?, value.result.mutation, true);
                if (prior.stage == .succeeded) return disconnectResult(allocator, invocation, handle.operation_ref, prior.created_session.?, .{ .state = .disconnected, .source_revision = prior.revision, .session = prior.created_session, .operation_ref = handle.operation_ref }, true);
                return disconnectResult(allocator, invocation, handle.operation_ref, prior.created_session.?, .{ .state = .outcome_unknown, .source_revision = prior.revision, .session = prior.created_session, .operation_ref = handle.operation_ref, .local_released = false, .remote_effect_unknown = true, .error_code = "DisconnectReceiptUnavailable", .operation_accepted = if (prior.stage == .committed) true else null }, true);
            }
            return recordResult(allocator, invocation, prior, true);
        }
        return self.fresh(scheduler, invocation, request, handle, allocator, cancel) catch |err| {
            var fact = try self.journal_owner.snapshot(allocator, handle);
            defer fact.deinit(allocator);
            const unknown = fact.dispatch_started;
            const stage: journal.Stage = if (unknown) .outcome_unknown else if (err == error.CancelledBeforeDispatch) .cancelled_unsent else if (err == error.ToolApprovalRejected) .rejected else .failed;
            self.journal_owner.update(handle, fact.revision, .{ .stage = stage, .local_released = !unknown, .remote_effect_unknown = unknown }) catch {};
            return failureResult(allocator, invocation, handle.operation_ref, err, unknown);
        };
    }
    fn fresh(self: *Runtime, scheduler: Scheduler, invocation: host.Invocation, request: tools.Request, handle: journal.Handle, a: std.mem.Allocator, cancel: ?*provider.CancelToken) !host.Result {
        const first = try self.controllerCall(scheduler, invocation.context, .{ .authorize = request }, cancel);
        if (first.result != .authorized) return error.InvalidControllerReceipt;
        const authorized = first.result.authorized;
        var permit: ?approvals.Permit = null;
        var impact: [2048]u8 = undefined;
        const subject = lifecycleSubject(invocation, authorized, &impact);
        defer if (permit) |value| self.approval.?.finish(value);
        if (authorized.approval_required) {
            const broker = self.approval orelse return error.ApprovalRequired;
            permit = try broker.requestSubject(invocation, subject, authorized.policy_revision, a, cancel);
        }
        try cancelled(cancel);
        const checked = try self.controllerCall(scheduler, invocation.context, .{ .authorize = request }, cancel);
        if (checked.result != .authorized or !std.meta.eql(authorized, checked.result.authorized)) return error.ScopeChanged;
        if (permit) |value| if (self.approval.?.authorizeSubject(value, invocation, subject, authorized.policy_revision) != .allow) return error.ScopeChanged;
        switch (request.kind) {
            .create_group => return self.createGroup(scheduler, invocation, request, authorized, handle, a, cancel, permit),
            .open_session => return self.open(scheduler, invocation, request, authorized, handle, a, cancel, permit),
            .close_session => return self.close(scheduler, invocation, request, authorized, handle, a, cancel, permit),
            .disconnect_session => {
                try self.journal_owner.update(handle, 1, .{ .stage = .dispatch_started, .created_session = request.session });
                try self.validatePermit(permit, invocation, authorized);
                const applied = try self.controllerCall(scheduler, invocation.context, .{ .mutate = .{ .operation = handle.operation_ref, .request = request, .authorized = authorized } }, cancel);
                if (applied.result != .mutation) return error.InvalidControllerReceipt;
                const receipt = applied.result.mutation;
                try self.journal_owner.update(handle, 2, .{ .stage = if (receipt.state == .disconnected and receipt.local_released and !receipt.remote_effect_unknown) .succeeded else if (receipt.state == .outcome_unknown or receipt.remote_effect_unknown) .outcome_unknown else .committed, .local_released = receipt.local_released, .remote_effect_unknown = receipt.remote_effect_unknown });
                return disconnectResult(a, invocation, handle.operation_ref, request.session.?, receipt, false);
            },
            .set_session_retention => {
                try self.journal_owner.update(handle, 1, .{ .stage = .dispatch_started, .created_session = request.session });
                try self.validatePermit(permit, invocation, authorized);
                const updated = try self.controllerCall(scheduler, invocation.context, .{ .set_retention = .{ .session = request.session.?, .retention = request.retention.? } }, cancel);
                if (updated.result != .session) return error.InvalidControllerReceipt;
                try self.journal_owner.update(handle, 2, .{ .stage = .succeeded });
                return sessionResult(a, invocation, handle.operation_ref, updated.result.session, false, false);
            },
            else => {
                try self.journal_owner.update(handle, 1, .{ .stage = .dispatch_started, .created_session = request.session, .created_group = if (request.group) |group| @backingInt(group.id) else null });
                try self.validatePermit(permit, invocation, authorized);
                const applied = try self.controllerCall(scheduler, invocation.context, .{ .mutate = .{ .operation = handle.operation_ref, .request = request, .authorized = authorized } }, cancel);
                if (applied.result != .mutation) return error.InvalidControllerReceipt;
                const receipt = applied.result.mutation;
                if (!receipt.local_released or receipt.remote_effect_unknown) return error.OutcomeUnknown;
                try self.journal_owner.update(handle, 2, .{ .stage = .succeeded, .notice_revision = receipt.notice_revision });
                return jsonResult(a, invocation, .succeeded, .{ .operation_ref = try tools.operationRef(a, invocation.context, handle.operation_ref), .state = @tagName(receipt.state), .source_revision = receipt.source_revision, .session_ref = if (receipt.session) |session| try queries.sessionRef(a, invocation.context, session) else null, .group_ref = if (receipt.group) |group| try queries.groupRef(a, invocation.context, @backingInt(group.id)) else null, .membership_revision = receipt.membership_revision, .ownership_revision = receipt.ownership_revision, .notice_revision = receipt.notice_revision, .name = request.name }, true, false);
            },
        }
    }
    fn createGroup(self: *Runtime, scheduler: Scheduler, invocation: host.Invocation, request: tools.Request, authorized: Authorized, handle: journal.Handle, a: std.mem.Allocator, cancel: ?*provider.CancelToken, permit: ?approvals.Permit) !host.Result {
        const prepared = try self.controllerCall(scheduler, invocation.context, .{ .prepare_group = .{ .operation = handle.operation_ref, .request = request, .authorized = authorized } }, cancel);
        if (prepared.result != .group_plan) return error.InvalidControllerReceipt;
        const plan = prepared.result.group_plan;
        // Release prepared allocations even when cancellation or journal IO fails.
        defer _ = self.controllerCall(scheduler, invocation.context, .{ .release_group = plan }, null) catch {};
        if (plan.id == 0 or plan.binding_revision <= invocation.context.binding_revision or plan.notice_revision == 0) return error.InvalidControllerReceipt;
        try cancelled(cancel);
        try self.journal_owner.update(handle, 1, .{ .stage = .dispatch_started, .created_group = plan.id });
        try self.validatePermit(permit, invocation, authorized);
        _ = try self.controllerCall(scheduler, invocation.context, .{ .commit_group = plan }, cancel);
        // If this sync fails, the durable dispatch_started receipt fences retries
        // even though the UI already published. Never rebuild from the name.
        try self.journal_owner.update(handle, 2, .{ .stage = .committed, .created_group = plan.id, .committed_binding = .{ .group = plan.id }, .committed_binding_revision = plan.binding_revision, .notice_revision = plan.notice_revision });
        var record = try self.journal_owner.snapshot(a, handle);
        defer record.deinit(a);
        return recordResult(a, invocation, record, false);
    }
    fn open(self: *Runtime, scheduler: Scheduler, invocation: host.Invocation, request: tools.Request, authorized: Authorized, handle: journal.Handle, a: std.mem.Allocator, cancel: ?*provider.CancelToken, permit: ?approvals.Permit) !host.Result {
        if (authorized.group == null or authorized.group.?.id != request.group.?.id or ((authorized.source == null) == (authorized.saved_source == null)) or !std.meta.eql(authorized.source, request.source) or !std.meta.eql(authorized.saved_source, request.saved_source)) return error.InvalidControllerReceipt;
        const queued = try self.controllerCall(scheduler, invocation.context, .{ .queue_open = .{ .operation_ref = handle.operation_ref, .context = invocation.context, .group = authorized.group.?, .membership_revision = authorized.membership_revision, .source = authorized.source, .saved_source = authorized.saved_source, .connection_policy = request.connection_policy.?, .retention = authorized.retention, .allow_new_fallback = authorized.allow_new_fallback } }, cancel);
        if (queued.result != .session) return error.InvalidControllerReceipt;
        var snapshot = queued.result.session;
        errdefer _ = self.controllerCall(scheduler, invocation.context, .{ .cancel_open = handle.operation_ref }, null) catch {};
        const deadline = now() + 5000;
        while (snapshot.state == .queued) {
            try cancelled(cancel);
            if (now() >= deadline) return error.OperationBusy;
            @import("retry.zig").wait(5, cancel) catch return error.CancelledBeforeDispatch;
            const queried = try self.controllerCall(scheduler, invocation.context, .{ .query_open = handle.operation_ref }, cancel);
            if (queried.result != .session) return error.InvalidControllerReceipt;
            snapshot = queried.result.session;
        }
        if (snapshot.state != .prepared or snapshot.session == null) return error.SessionPrepareFailed;
        try self.validatePermit(permit, invocation, authorized);
        if (authorized.bootstrap_required) try self.prepareBootstrap(scheduler, invocation, handle.operation_ref, snapshot.session.?, authorized, a, cancel, permit);
        try cancelled(cancel);
        try self.journal_owner.update(handle, 1, .{ .stage = .dispatch_started, .created_session = snapshot.session, .ownership = .created_task });
        if (!authorized.bootstrap_required) try self.validatePermit(permit, invocation, authorized);
        const dispatched = try self.controllerCall(scheduler, invocation.context, .{ .authorize_open = .{ .operation = handle.operation_ref, .revision = snapshot.revision, .session = snapshot.session.? } }, cancel);
        if (dispatched.result != .session or dispatched.result.session.session == null or !dispatched.result.session.session.?.eql(snapshot.session.?)) return error.InvalidControllerReceipt;
        snapshot = dispatched.result.session;
        try self.journal_owner.update(handle, 2, .{ .stage = .committed, .created_session = snapshot.session, .ownership = .created_task });
        return sessionResult(a, invocation, handle.operation_ref, snapshot, false, false);
    }
    fn prepareBootstrap(self: *Runtime, scheduler: Scheduler, invocation: host.Invocation, operation: identity.HostOperationId, owner: identity.SessionHandle, authorized: Authorized, a: std.mem.Allocator, cancel: ?*provider.CancelToken, opening_permit: ?approvals.Permit) !void {
        const source = authorized.source orelse return error.BootstrapRequiresSharedSource;
        const deadline = now() + 10_000;
        var probed: bootstrap_product.Probed = undefined;
        while (true) {
            try cancelled(cancel);
            if (now() >= deadline) return error.BootstrapProbeTimedOut;
            const response = try self.controllerCall(scheduler, invocation.context, .{ .probe_bootstrap = operation }, cancel);
            if (response.result != .bootstrap_probe) return error.InvalidControllerReceipt;
            if (response.result.bootstrap_probe) |value| {
                probed = value;
                break;
            }
            @import("retry.zig").wait(10, cancel) catch return error.CancelledBeforeDispatch;
        }
        const prepared = try bootstrap_product.Prepared.create(std.heap.c_allocator, self.journal_owner.io, invocation.context, operation, source, owner, probed);
        defer prepared.release();
        const subject = try prepared.subject(a);
        const broker = self.approval orelse return error.BootstrapDeploymentAuthorizationRequired;
        // Creation approval and route choice are insufficient for deployment.
        // Complete the first card before presenting this concrete manifest.
        if (opening_permit) |value| broker.finish(value);
        const permit = try broker.requestSubject(invocation, subject, authorized.policy_revision, a, cancel);
        defer broker.finish(permit);
        try cancelled(cancel);
        try prepared.approve(broker, permit, invocation, authorized.policy_revision, now(), a);
        _ = try self.controllerCall(scheduler, invocation.context, .{ .install_bootstrap = prepared }, cancel);
    }
    fn close(self: *Runtime, scheduler: Scheduler, invocation: host.Invocation, request: tools.Request, authorized: Authorized, handle: journal.Handle, a: std.mem.Allocator, cancel: ?*provider.CancelToken, permit: ?approvals.Permit) !host.Result {
        try self.journal_owner.update(handle, 1, .{ .stage = .dispatch_started, .created_session = request.session });
        try self.validatePermit(permit, invocation, authorized);
        const accepted = try self.controllerCall(scheduler, invocation.context, .{ .queue_close = .{ .operation = handle.operation_ref, .session = request.session.?, .explicit_user_close = authorized.explicit_user_close } }, cancel);
        if (accepted.result != .close) return error.InvalidControllerReceipt;
        const snapshot = accepted.result.close;
        if (!snapshot.session.eql(request.session.?) or !snapshot.operation_ref.eql(handle.operation_ref)) return error.InvalidControllerReceipt;
        try self.journal_owner.update(handle, 2, .{ .stage = .committed });
        // Ack happens only through acknowledgeResult() after Loop accepted and
        // copied this immutable tool result. This handler never closes/joins.
        return closeResult(a, invocation, handle.operation_ref, snapshot, false);
    }
    fn validatePermit(self: *Runtime, permit: ?approvals.Permit, invocation: host.Invocation, authorized: Authorized) !void {
        if (permit) |value| {
            var impact: [2048]u8 = undefined;
            const subject = lifecycleSubject(invocation, authorized, &impact);
            if (self.approval.?.authorizeSubject(value, invocation, subject, authorized.policy_revision) != .allow) return error.ScopeChanged;
        } else if (authorized.approval_required) return error.ApprovalRequired;
    }
    pub fn acknowledgeNotice(self: *Runtime, context: host.Context, revision: u64) !void {
        try self.journal_owner.acknowledgeNotice(context, revision);
    }
    /// The result consumer invokes this after accepting the close tool result.
    /// It is deliberately separate from execute() to avoid closing a source
    /// while its own worker/result callback is still active.
    pub fn acknowledgeResult(self: *Runtime, scheduler: Scheduler, context: host.Context, operation: identity.HostOperationId) !void {
        _ = try self.controllerCall(scheduler, context, .{ .acknowledge_close = operation }, null);
    }
    fn wait(self: *Runtime, scheduler: Scheduler, invocation: host.Invocation, request: tools.Request, a: std.mem.Allocator, cancel: ?*provider.CancelToken) !host.Result {
        var queried = try self.controllerCall(scheduler, invocation.context, if (request.operation) |op| .{ .query_open = op } else .{ .resolve_owned = request.session.? }, cancel);
        if (queried.result != .session) return error.InvalidControllerReceipt;
        var snapshot = queried.result.session;
        const initial_revision = request.after_revision orelse snapshot.revision;
        const deadline = now() + request.wait_ms;
        while ((snapshot.state == .queued or snapshot.state == .prepared or snapshot.state == .opening) and snapshot.revision <= initial_revision and now() < deadline) {
            @import("retry.zig").wait(@min(@as(u32, 10), request.wait_ms), cancel) catch return error.CancelledBeforeDispatch;
            queried = try self.controllerCall(scheduler, invocation.context, .{ .query_open = snapshot.operation_ref }, cancel);
            if (queried.result != .session) return error.InvalidControllerReceipt;
            snapshot = queried.result.session;
        }
        return sessionResult(a, invocation, snapshot.operation_ref, snapshot, now() >= deadline and (snapshot.state == .queued or snapshot.state == .prepared or snapshot.state == .opening) and snapshot.revision <= initial_revision, false);
    }
};
fn lifecycleSubject(invocation: host.Invocation, authorized: Authorized, buffer: *[2048]u8) approvals.Subject {
    const kind = tools.kind(invocation.tool_id).?;
    const retention = @import("../config/config.zig").sessionRetentionLabel(authorized.retention);
    const impact = switch (kind) {
        .open_session => blk: {
            const policy = invocation.arguments.object.get("connection_policy").?.string;
            const connection = if (std.mem.eql(u8, policy, "prefer_reuse")) "先复用来源连接；不可复用时明确允许建立新连接" else if (std.mem.eql(u8, policy, "reuse_only")) "仅复用来源连接并新开 shell；不可复用则停止，不新建连接" else "始终新建独立工作终端，不复用原连接";
            break :blk std.fmt.bufPrint(buffer, "{s}。不执行用户命令。{s}冻结保留方式：{s}。", .{ connection, if (authorized.bootstrap_required) "将先只读探测平台/zsh，再另行审批本次临时 helper 的精确目录与资源 hash。" else "默认启用终端集成；SSH 如需命令事件，仅在原 shell 内初始化文本钩子，不上传运行文件。", retention }) catch "创建独立工作会话；不执行用户命令。";
        },
        .create_group => "创建真实终端组，原会话加入；同一 AI 对话、历史和草稿迁移到该组。",
        .close_session => "明确关闭本次精确会话及其进程/连接；真实关闭会在工具结果受理后再次核查影响。",
        .set_session_retention => std.fmt.bufPrint(buffer, "将本任务创建的精确会话保留方式改为：{s}；旧的自动关闭计划同时撤销。", .{retention}) catch "修改本任务工作会话的保留方式。",
        .add_group_member => "仅添加本次精确成员关系；不会连接、执行命令或取得其他会话内容权限。",
        .remove_group_member => "仅移除本次精确成员关系，不关闭该会话；组身份与当前 AI 对话保留。",
        .rename_group => "修改当前组的显示名称；组身份、成员及执行授权保持原来的边界。",
        .reconnect_session => "明确建立新的连接代次；旧会话引用和旧执行不会复活，不重放命令。",
        .disconnect_session => "断开本次精确会话的连接并保留历史，不自动重连。",
        .wait_session_ready => "只读等待本任务已创建会话的状态，不创建或重连。",
    };
    return .{ .kind = .lifecycle, .target = invocation.tool_id, .detail = invocation.arguments_json, .impact = impact };
}
fn now() i64 {
    return @intCast(@divTrunc(@import("../platform/realtime.zig").monotonicNs(), std.time.ns_per_ms));
}
fn cancelled(cancel: ?*provider.CancelToken) !void {
    if (cancel) |token| if (token.isCancelled()) return error.CancelledBeforeDispatch;
}
fn jsonResult(a: std.mem.Allocator, invocation: host.Invocation, status: @import("plugin_tools.zig").Status, body: anytype, started: bool, unknown: bool) !host.Result {
    const encoded = try std.json.Stringify.valueAlloc(a, body, .{});
    errdefer a.free(encoded);
    if (encoded.len > 64 * 1024) return error.ResultLimit;
    const blocks = try a.alloc(host.Block, 1);
    blocks[0] = .{ .structured = encoded };
    return .{ .status = status, .blocks = blocks, .receipt = .{ .conversation_id = invocation.context.conversation_id, .task_id = invocation.context.task_id, .operation_id = invocation.operation_id, .binding_revision = invocation.context.binding_revision, .side_effect_started = started, .local_released = !unknown, .remote_effect_unknown = unknown } };
}
fn closeResult(a: std.mem.Allocator, invocation: host.Invocation, operation: identity.HostOperationId, snapshot: CloseSnapshot, reused: bool) !host.Result {
    if (!snapshot.operation_ref.eql(operation)) return error.InvalidControllerReceipt;
    const recording_ref = if (snapshot.recording_id) |id| blk: {
        _ = identity.RecordingId.parse(&id) catch return error.InvalidControllerReceipt;
        if (snapshot.recording_generation == 0) return error.InvalidControllerReceipt;
        break :blk try @import("host_terminal_queries.zig").recordingRef(a, invocation.context, id, snapshot.recording_generation);
    } else null;
    const unknown = snapshot.state == .outcome_unknown or snapshot.remote_effect_unknown;
    return jsonResult(a, invocation, if (unknown) .outcome_unknown else .succeeded, .{
        .operation_ref = try tools.operationRef(a, invocation.context, operation),
        .session_ref = try queries.sessionRef(a, invocation.context, snapshot.session),
        .state = if (snapshot.state == .awaiting_result) "closing" else @tagName(snapshot.state),
        .recording_ref = recording_ref,
        .recording_unavailable_reason = snapshot.recording_unavailable_reason,
        .idempotent_reuse = reused,
        .result_acknowledgement_required = snapshot.state == .awaiting_result,
        .source_revision = snapshot.revision,
        .local_released = snapshot.local_released,
        .remote_effect_unknown = snapshot.remote_effect_unknown,
        .error_code = snapshot.error_code,
    }, true, unknown);
}
fn disconnectResult(a: std.mem.Allocator, invocation: host.Invocation, operation: identity.HostOperationId, session: identity.SessionHandle, receipt: MutationReceipt, reused: bool) !host.Result {
    if (receipt.operation_ref == null or !receipt.operation_ref.?.eql(operation) or receipt.session == null or !receipt.session.?.eql(session)) return error.InvalidControllerReceipt;
    if (receipt.state != .pending and receipt.state != .disconnected and receipt.state != .outcome_unknown) return error.InvalidControllerReceipt;
    if (receipt.state == .disconnected and (!receipt.local_released or receipt.remote_effect_unknown)) return error.InvalidControllerReceipt;
    const unknown = receipt.state == .outcome_unknown or receipt.remote_effect_unknown;
    // A succeeded pending result acknowledges enqueue only. The structured
    // protocol receipt below separately reports the runtime's actual ownership.
    return jsonResult(a, invocation, if (unknown) .outcome_unknown else .succeeded, .{
        .operation_ref = try tools.operationRef(a, invocation.context, operation),
        .session_ref = try queries.sessionRef(a, invocation.context, session),
        .state = @tagName(receipt.state),
        .operation_accepted = receipt.operation_accepted,
        .session_preserved = if (receipt.operation_accepted == true) @as(?bool, true) else null,
        .records_preserved = if (receipt.operation_accepted == true) @as(?bool, true) else null,
        .automatic_reconnect = if (receipt.operation_accepted == true) @as(?bool, false) else null,
        .affected_execution_state = if (receipt.operation_accepted == true) "authorization_revoked" else "unknown",
        .source_revision = receipt.source_revision,
        .local_released = receipt.local_released,
        .remote_effect_unknown = receipt.remote_effect_unknown,
        .error_code = receipt.error_code,
        .idempotent_reuse = reused,
    }, true, unknown);
}
fn recordResult(a: std.mem.Allocator, invocation: host.Invocation, record: journal.Record, reused: bool) !host.Result {
    const unknown = record.stage == .dispatch_started or record.stage == .running or record.stage == .outcome_unknown or !record.local_released or record.remote_effect_unknown;
    const status: @import("plugin_tools.zig").Status = if (unknown) .outcome_unknown else switch (record.stage) {
        .committed, .succeeded => .succeeded,
        .rejected => .rejected,
        .cancelled_unsent => .cancelled_unsent,
        else => .failed,
    };
    return jsonResult(a, invocation, status, .{ .operation_ref = try tools.operationRef(a, invocation.context, record.operation_ref), .state = if (unknown) "outcome_unknown" else @tagName(record.stage), .idempotent_reuse = reused, .result_acknowledgement_required = std.mem.eql(u8, invocation.tool_id, "host.close_session") and record.stage == .committed, .code = if (record.stage == .prepared) @as(?[]const u8, "OperationBusy") else if (unknown) @as(?[]const u8, "OutcomeUnknown") else null, .group_ref = if (record.created_group) |group| try queries.groupRef(a, invocation.context, group) else null, .session_ref = if (record.created_session) |session| try queries.sessionRef(a, invocation.context, session) else null, .initial_member = if (record.context.binding == .session) record.context.binding.session else @as(?u64, null), .handoff_revision = record.committed_binding_revision, .same_conversation_id = record.context.conversation_id, .source_revision = record.revision, .notice_revision = record.notice_revision, .side_effect_started = record.dispatch_started, .local_released = record.local_released and !unknown, .remote_effect_unknown = unknown, .recovery_hint = if (unknown) "Inspect the original operation; do not replay or create another resource to recover this reply." else if (record.stage == .prepared) "Original operation is in progress; do not dispatch another copy." else "Use the original receipt." }, record.dispatch_started, unknown);
}
fn sessionResult(a: std.mem.Allocator, invocation: host.Invocation, operation: identity.HostOperationId, snapshot: lifecycle.Snapshot, timed_out: bool, reused: bool) !host.Result {
    if (!snapshot.context.conversation_id.eql(invocation.context.conversation_id) or !snapshot.context.task_id.eql(invocation.context.task_id)) return error.InvalidControllerReceipt;
    if ((std.mem.eql(u8, invocation.tool_id, "host.open_session") or std.mem.eql(u8, invocation.tool_id, "host.wait_session_ready")) and !snapshot.operation_ref.eql(operation)) return error.InvalidControllerReceipt;
    return jsonResult(a, invocation, .succeeded, .{ .operation_ref = try tools.operationRef(a, invocation.context, operation), .session_ref = if (snapshot.session) |session| try queries.sessionRef(a, invocation.context, session) else null, .group_ref = try queries.groupRef(a, invocation.context, @backingInt(snapshot.group.id)), .state = if (snapshot.state == .prepared) "opening" else @tagName(snapshot.state), .source_ref = if (snapshot.source) |source| try queries.sessionRef(a, invocation.context, source) else if (snapshot.saved_source) |source| try tools.connectionRef(a, invocation.context, source) else @as(?[]const u8, null), .ownership = @tagName(snapshot.ownership), .ownership_revision = snapshot.ownership_revision, .retention = @tagName(snapshot.retention), .membership_committed = snapshot.membership_committed, .source_revision = snapshot.revision, .error_code = snapshot.error_code, .timed_out = timed_out, .idempotent_reuse = reused, .local_released = snapshot.local_released, .remote_effect_unknown = snapshot.remote_effect_unknown, .observed_at = @import("../platform/realtime.zig").milliseconds(undefined), .truncated = false, .next_cursor = @as(?[]const u8, null) }, !std.mem.eql(u8, invocation.tool_id, "host.wait_session_ready"), false);
}
fn failureResult(a: std.mem.Allocator, invocation: host.Invocation, operation: identity.HostOperationId, err: anyerror, started: bool) !host.Result {
    return jsonResult(a, invocation, if (started) .outcome_unknown else if (err == error.CancelledBeforeDispatch) .cancelled_unsent else if (err == error.ToolApprovalRejected) .rejected else .failed, .{ .code = @errorName(err), .stage = if (started) "outcome_unknown" else "preflight", .retryable = false, .operation_ref = try tools.operationRef(a, invocation.context, operation), .side_effect_started = started, .local_released = !started, .remote_effect_unknown = started, .recovery_hint = if (started) "Inspect the original operation; never redispatch an unknown effect." else "No effect was dispatched; inspect and correct the rejected request." }, started, started);
}
fn journalError(invocation: host.Invocation, a: std.mem.Allocator, err: anyerror, started: bool) !host.Result {
    return jsonResult(a, invocation, .failed, .{ .code = if (err == error.IdempotencyConflict) "IdempotencyConflict" else "JournalUnavailable", .stage = "journal_begin", .retryable = false, .detail = @errorName(err), .side_effect_started = started, .local_released = true, .remote_effect_unknown = false, .recovery_hint = "Repair durable lifecycle storage before requesting another effect." }, started, false);
}

test {
    _ = @import("lifecycle_runtime_tests.zig");
}
