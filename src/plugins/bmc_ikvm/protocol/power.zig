//! One per-session management engine, shared by power and Boot. The controller
//! pulls bounded HTTP work and feeds completions; no networking or automatic
//! retry of writes exists here. All methods run on the controller's IO owner.
const std = @import("std");
pub const svc = @import("../services.zig");
const redfish = @import("redfish.zig");
const auth = @import("auth.zig");
const boot = @import("boot.zig");
const ledger = @import("../management_journal.zig");
pub const Method = enum { get, post, patch };
pub const Purpose = enum { refresh, write, task, verify, query, conflict_refresh, pending_verify };
pub const Outbound = struct { sequence: u64, operation: svc.OperationKey, purpose: Purpose, method: Method, uri: []const u8, body: []const u8 = "", if_match: ?[]const u8 = null, authkey: ?[]const u8 = null };
pub const Completion = struct { sequence: u64, status: u16 = 0, body: []const u8 = "", etag: ?[]const u8 = null, location: ?[]const u8 = null, retry_after_ms: ?u64 = null, transport_error: bool = false };
/// The application-wide resource arbiter is injected by the composition layer.
/// Missing arbitration fails closed for writes. acquire/revalidate use the same
/// canonical authority + verified System identity for every application Tab.
pub const Arbiter = struct {
    context: *anyopaque,
    acquire: *const fn (*anyopaque, []const u8, svc.Execution) anyerror!u64,
    revalidate: *const fn (*anyopaque, u64, svc.Execution) bool,
    release: *const fn (*anyopaque, u64) void,
};
pub const Gate = struct { owner: svc.identity.SessionHandle, binding_generation: u64, capability_revision: u64, grant_revision: u64, authenticated: bool, write_granted: bool, read_granted: bool = true };
const Active = struct {
    arena: std.heap.ArenaAllocator,
    execution: svc.Execution,
    index: usize,
    kind: ledger.Parameters,
    baseline: ledger.Baseline,
    expected_boot: ?svc.BootState = null,
    write_uri: []const u8,
    body: []const u8,
    result: svc.Result,
    authkey: ?auth.Secret = null,
    arbiter_lease: ?u64 = null,
    stage: Purpose = .write,
    refresh_done: bool = false,
    precondition_collected_ms: u64 = 0,
    task_completed: bool = false,
    query_only: bool = false,
    pending_uri: ?[]const u8 = null,
    waiting: bool = false,
    next_poll_ms: u64 = 0,
    deadline_ms: u64,
    polls: u8 = 0,
};
pub const Engine = struct {
    allocator: std.mem.Allocator,
    owner: svc.identity.SessionHandle,
    origin: redfish.Origin,
    journal: *ledger.Journal,
    arbiter: ?Arbiter,
    power: svc.OwnedPowerSnapshot,
    boot_snapshot: svc.OwnedBootSnapshot,
    active: ?Active = null,
    sequence: u64 = 0,
    now_ms: u64 = 0,
    pub fn init(a: std.mem.Allocator, owner: svc.identity.SessionHandle, origin: redfish.Origin, journal: *ledger.Journal, arbiter: ?Arbiter) !Engine {
        var power_snapshot = try svc.OwnedPowerSnapshot.init(a, .{});
        errdefer power_snapshot.deinit();
        return .{ .allocator = a, .owner = owner, .origin = origin, .journal = journal, .arbiter = arbiter, .power = power_snapshot, .boot_snapshot = try svc.OwnedBootSnapshot.init(a, .{}) };
    }
    pub fn deinit(self: *Engine) void {
        if (self.active) |*active| {
            self.release(active);
            active.arena.deinit();
        }
        self.power.deinit();
        self.boot_snapshot.deinit();
        self.* = undefined;
    }
    pub fn setSnapshots(self: *Engine, power_snapshot: svc.PowerSnapshot, boot_snapshot: svc.BootSnapshot) !void {
        var power_copy = try svc.OwnedPowerSnapshot.init(self.allocator, power_snapshot);
        errdefer power_copy.deinit();
        const boot_copy = try svc.OwnedBootSnapshot.init(self.allocator, boot_snapshot);
        self.power.deinit();
        self.boot_snapshot.deinit();
        self.power = power_copy;
        self.boot_snapshot = boot_copy;
    }
    pub fn powerSnapshot(self: *Engine, call: svc.Call, a: std.mem.Allocator) !svc.OwnedPowerSnapshot {
        try self.validateCall(call);
        return svc.OwnedPowerSnapshot.init(a, self.power.value);
    }
    pub fn bootSnapshot(self: *Engine, call: svc.Call, a: std.mem.Allocator) !svc.OwnedBootSnapshot {
        try self.validateCall(call);
        return svc.OwnedBootSnapshot.init(a, self.boot_snapshot.value);
    }
    fn validateCall(self: *const Engine, call: svc.Call) !void {
        if (!self.owner.eql(call.owner) or call.binding_generation != self.power.value.capability.binding_generation) return error.StaleBinding;
    }
    fn validateExecution(self: *const Engine, execution: svc.Execution, capability: svc.Capability, uri: []const u8) !void {
        try self.validateCall(execution.call);
        const owner = switch (execution.operation.owner) {
            .session => |owner| owner,
            else => return error.StaleBinding,
        };
        if (!owner.eql(self.owner) or !std.mem.eql(u8, execution.system_uri, uri) or execution.operation.operation_id == 0 or std.mem.allEqual(u8, &execution.nonce, 0)) return error.StaleBinding;
        if (!capability.system_mapping_verified) return error.MappingUnverified;
        if (!capability.write_granted) return error.PermissionDenied;
        if (capability.revision != execution.capability_revision or capability.grant_revision != execution.grant_revision) return error.StaleCapability;
        if (capability.secondary_auth == .unknown or !capability.secondary_auth_evidence.permitsWrite()) return error.SecondaryAuthUnknown;
        if (self.arbiter == null) return error.ArbiterUnavailable;
    }
    pub fn requestPower(self: *Engine, request: svc.PowerExecutionRequest, now_ms: u64) !svc.OperationKey {
        if (try self.duplicate(request.execution, .{ .power = request.action })) |key| return key;
        const snapshot = self.power.value;
        try self.validateExecution(request.execution, snapshot.capability, snapshot.system_uri);
        if (!snapshot.state.evidence.permitsWrite() or snapshot.state.value == null or !snapshot.reset_types.evidence.permitsWrite() or !svc.contains(snapshot.reset_types.value orelse return error.UnsupportedAction, request.action.redfish()) or snapshot.reset_target == null) return error.UnsupportedAction;
        if (request.action == .on and snapshot.state.value.? != .off) return error.ActionNotApplicable;
        if (request.action != .on and snapshot.state.value.? != .on) return error.ActionNotApplicable;
        var arena: std.heap.ArenaAllocator = .init(self.allocator);
        errdefer arena.deinit();
        const body = try std.json.Stringify.valueAlloc(arena.allocator(), .{ .ResetType = request.action.redfish() }, .{});
        return self.begin(&arena, request.execution, .{ .power = request.action }, .{ .power = snapshot.state.value, .etag = snapshot.etag }, snapshot.system_identity, snapshot.reset_target.?, body, null, @min(snapshot.state.evidence.collected_ms, snapshot.reset_types.evidence.collected_ms), now_ms);
    }
    pub fn applyBoot(self: *Engine, patch: svc.BootExecutionPatch, now_ms: u64) !svc.OperationKey {
        if (try self.duplicate(patch.execution, .{ .boot = boot.normalized(patch) })) |key| return key;
        const snapshot = self.boot_snapshot.value;
        try self.validateExecution(patch.execution, snapshot.capability, snapshot.system_uri);
        if (snapshot.write_uri == null) return error.BootWriteTargetUnverified;
        var arena: std.heap.ArenaAllocator = .init(self.allocator);
        errdefer arena.deinit();
        const prepared = try boot.prepare(arena.allocator(), snapshot, patch);
        const collected = @min(snapshot.enabled_evidence.collected_ms, snapshot.target_evidence.collected_ms);
        return self.begin(&arena, patch.execution, .{ .boot = prepared.parameters }, .{ .boot = snapshot.state, .etag = snapshot.etag }, snapshot.system_identity, snapshot.write_uri.?, prepared.body, prepared.expected, collected, now_ms);
    }
    fn duplicate(self: *Engine, execution: svc.Execution, parameters: ledger.Parameters) !?svc.OperationKey {
        try self.validateCall(execution.call);
        const request_owner = switch (execution.operation.owner) {
            .session => |value| value,
            else => return error.StaleBinding,
        };
        if (!request_owner.eql(self.owner)) return error.StaleBinding;
        var index = self.journal.find(execution.operation);
        if (index == null) for (self.journal.entries, 0..) |entry, i| if (std.mem.eql(u8, &entry.nonce, &execution.nonce)) {
            index = i;
            break;
        };
        const existing = self.journal.entries[index orelse return null];
        var arena: std.heap.ArenaAllocator = .init(self.allocator);
        defer arena.deinit();
        const target = try redfish.canonicalTarget(arena.allocator(), self.origin, execution.system_uri);
        _ = try self.journal.reserve(execution, target, existing.system_identity, parameters, existing.baseline);
        return execution.operation;
    }
    fn begin(self: *Engine, arena: *std.heap.ArenaAllocator, execution_value: svc.Execution, parameters: ledger.Parameters, baseline_value: ledger.Baseline, system_identity: []const u8, write_uri_value: []const u8, body: []const u8, expected: ?svc.BootState, collected_ms: u64, now_ms: u64) !svc.OperationKey {
        const a = arena.allocator();
        var execution = execution_value;
        execution.system_uri = try a.dupe(u8, execution.system_uri);
        const target = try redfish.canonicalTarget(a, self.origin, execution.system_uri);
        const reservation = try self.journal.reserve(execution, target, system_identity, parameters, baseline_value);
        if (reservation.existing) {
            arena.deinit();
            return execution.operation;
        }
        if (self.active) |*old| {
            if (!old.result.terminal()) {
                try self.journal.setResult(reservation.index, .{ .operation = execution.operation, .phase = .failed, .reason = .busy });
                return error.ManagementBusy;
            }
            self.release(old);
            old.arena.deinit();
            self.active = null;
        }
        const entry = self.journal.entries[reservation.index];
        const baseline = try copyBaseline(a, entry.baseline);
        const owned_parameters = try copyParameters(a, entry.parameters);
        const uri = try redfish.resourceUri(a, self.origin, write_uri_value);
        const resource_key = try std.fmt.allocPrint(a, "{s}|{s}", .{ self.origin.authority, system_identity });
        const arbiter = self.arbiter.?;
        const lease = arbiter.acquire(arbiter.context, resource_key, execution) catch |err| {
            try self.journal.setResult(reservation.index, .{ .operation = execution.operation, .phase = .failed, .reason = .busy });
            return err;
        };
        errdefer arbiter.release(arbiter.context, lease);
        const cap = self.power.value.capability;
        const refresh = now_ms < collected_ms or now_ms - collected_ms > 5000 or (parameters == .boot and baseline.etag == null);
        var result_state: svc.Result = .{ .operation = execution.operation, .phase = if (cap.secondary_auth == .required) .awaiting_auth else if (refresh) .refreshing else .queued };
        try self.journal.setResult(reservation.index, result_state);
        result_state.dispatched = false;
        const expected_copy = if (expected) |state| try copyBoot(a, state) else null;
        self.active = .{ .arena = arena.*, .execution = execution, .index = reservation.index, .kind = owned_parameters, .baseline = baseline, .expected_boot = expected_copy, .write_uri = uri, .body = body, .result = result_state, .arbiter_lease = lease, .stage = if (refresh) .refresh else .write, .precondition_collected_ms = collected_ms, .deadline_ms = now_ms +| 60_000 };
        return execution.operation;
    }
    pub fn supplySecondary(self: *Engine, proof: *auth.SecondaryProof) !void {
        const active = if (self.active) |*value| value else return error.StaleOperation;
        if (active.result.phase != .awaiting_auth or !proof.owner.eql(self.owner) or !proof.operation.eql(active.execution.operation) or !std.mem.eql(u8, &proof.nonce, &active.execution.nonce) or proof.capability_revision != active.execution.capability_revision or proof.grant_revision != active.execution.grant_revision) return error.StaleOperation;
        const secret = try auth.Secret.init(self.allocator, proof.authkey.bytes);
        errdefer {
            var mutable = secret;
            mutable.deinit();
        }
        var result_state = active.result;
        result_state.phase = if (active.stage == .refresh) .refreshing else .queued;
        try self.journal.setResult(active.index, result_state);
        if (active.authkey) |*old| old.deinit();
        active.authkey = secret;
        active.result = result_state;
        active.deadline_ms = self.now_ms +| 60_000;
        proof.deinit();
    }
    pub fn next(self: *Engine, now_ms: u64, gate: Gate) !?Outbound {
        self.now_ms = now_ms;
        const active = if (self.active) |*value| value else return null;
        if (active.result.phase == .awaiting_auth or active.result.terminal()) return null;
        if (now_ms >= active.deadline_ms or active.polls >= 24) {
            try self.finish(active, if (active.result.dispatched) .outcome_unknown else .failed, .timeout, null);
            return null;
        }
        if (active.waiting or now_ms < active.next_poll_ms) return null;
        if (!gate.owner.eql(self.owner) or gate.binding_generation != active.execution.call.binding_generation or gate.capability_revision != active.execution.capability_revision or gate.grant_revision != active.execution.grant_revision or !gate.authenticated or (if (active.query_only) !gate.read_granted else !gate.write_granted)) {
            try self.finish(active, if (active.result.dispatched) .outcome_unknown else .failed, if (!gate.authenticated) .authentication_failed else .stale_capability, null);
            return null;
        }
        if (active.stage == .write and (now_ms < active.precondition_collected_ms or now_ms - active.precondition_collected_ms > 5000)) {
            active.stage = .refresh;
            active.result.phase = .refreshing;
        }
        const stage = active.stage;
        var outbound: Outbound = .{ .sequence = self.sequence + 1, .operation = active.execution.operation, .purpose = stage, .method = .get, .uri = active.execution.system_uri };
        if (stage == .write) {
            if (active.query_only or active.result.dispatched) return error.OperationAlreadyDispatched;
            const arbiter = self.arbiter orelse return error.ArbiterUnavailable;
            if (active.arbiter_lease == null or !arbiter.revalidate(arbiter.context, active.arbiter_lease.?, active.execution)) {
                try self.finish(active, .failed, .permission_denied, null);
                return null;
            }
            if (self.power.value.capability.secondary_auth == .required and active.authkey == null) return error.SecondaryAuthRequired;
            // This is the sole write dispatch boundary. Failure returns no work.
            try self.journal.beginDispatch(active.index);
            active.result.dispatched = true;
            active.result.phase = .sending;
            outbound.method = if (active.kind == .power) .post else .patch;
            outbound.uri = active.write_uri;
            outbound.body = active.body;
            outbound.if_match = active.baseline.etag;
            outbound.authkey = if (active.authkey) |secret| secret.bytes else null;
        } else if (stage == .task) outbound.uri = active.result.task_uri orelse return error.MissingTaskMonitor else if (stage == .pending_verify) outbound.uri = active.pending_uri orelse return error.MissingSettingsResource;
        self.sequence += 1;
        outbound.sequence = self.sequence;
        active.waiting = true;
        active.polls += 1;
        return outbound;
    }
    pub fn complete(self: *Engine, response: Completion, now_ms: u64) !void {
        self.now_ms = now_ms;
        const active = if (self.active) |*value| value else return error.StaleOperation;
        if (!active.waiting or response.sequence != self.sequence or active.result.terminal()) return error.StaleCompletion;
        active.waiting = false;
        const stage = active.stage;
        if (stage == .write) if (active.authkey) |*secret| {
            secret.deinit();
            active.authkey = null;
        };
        if (response.transport_error or response.status == 0) {
            try self.finish(active, if (active.result.dispatched) .outcome_unknown else .failed, .transport_lost, null);
            return;
        }
        const uri = if (stage == .task) active.result.task_uri.? else if (stage == .pending_verify) active.pending_uri.? else if (stage == .write) active.write_uri else active.execution.system_uri;
        var doc = redfish.Document.parse(self.allocator, uri, response.status, response.body, response.etag, now_ms) catch {
            try self.finish(active, if (active.result.dispatched) .outcome_unknown else .failed, .remote_error, response.status);
            return;
        };
        defer doc.deinit();
        if (response.status == 401 or response.status == 403) {
            self.power.value.capability.write_granted = false;
            self.boot_snapshot.value.capability.write_granted = false;
            try self.finish(active, .failed, if (response.status == 401) .authentication_failed else .permission_denied, response.status);
            return;
        }
        if (stage == .write) {
            if (response.status == 409 or response.status == 412) {
                active.stage = .conflict_refresh;
                active.result.phase = .refreshing;
                active.result.reason = .conflict;
                active.result.http_status = response.status;
                active.next_poll_ms = now_ms;
                try self.journal.setResult(active.index, active.result);
                return;
            }
            if (!doc.accepted()) {
                try self.finish(active, .failed, .remote_error, response.status);
                return;
            }
            if (response.status == 202) {
                const location = response.location orelse redfish.text(doc.value, "TaskMonitor") orelse redfish.text(doc.value, "@odata.id") orelse {
                    try self.finish(active, .outcome_unknown, .remote_error, response.status);
                    return;
                };
                const task = redfish.resourceUri(active.arena.allocator(), self.origin, location) catch {
                    try self.finish(active, .outcome_unknown, .remote_error, response.status);
                    return;
                };
                active.result.task_uri = task;
                active.stage = .task;
                active.result.phase = .tracking_task;
            } else if (response.status == 200 or response.status == 204) {
                active.stage = .verify;
                active.result.phase = .verifying;
            } else {
                try self.finish(active, .outcome_unknown, .remote_error, response.status);
                return;
            }
            active.result.http_status = response.status;
        } else if (stage == .task) {
            if (response.status == 204 and doc.accepted()) {
                active.task_completed = true;
                active.stage = .verify;
                active.result.phase = .verifying;
            } else if (response.status == 202 and doc.accepted() and redfish.text(doc.value, "TaskState") == null) {
                active.result.phase = .tracking_task;
            } else switch (redfish.parseTask(doc).state) {
                .completed => {
                    active.task_completed = true;
                    active.stage = .verify;
                    active.result.phase = .verifying;
                },
                .running => {},
                .failed => {
                    try self.finish(active, if (doc.accepted()) .failed else .outcome_unknown, .remote_error, response.status);
                    return;
                },
                .unknown => {
                    try self.finish(active, .outcome_unknown, .remote_error, response.status);
                    return;
                },
            }
        } else {
            if (!doc.accepted()) {
                try self.finish(active, if (active.result.dispatched) .outcome_unknown else .failed, .remote_error, response.status);
                return;
            }
            const parsed = try redfish.parseSystem(active.arena.allocator(), self.origin, doc);
            if (stage == .pending_verify) {
                active.result.pending_boot = try copyBoot(active.arena.allocator(), parsed.boot.state);
                const changed = active.kind.boot;
                try self.finish(active, .outcome_unknown, if (boot.matches(active.expected_boot orelse expectedFrom(active.baseline.boot.?, changed), parsed.boot.state, changed)) .pending else .verification_mismatch, response.status);
                return;
            }
            if (!std.mem.eql(u8, parsed.power.system_identity, self.power.value.system_identity)) {
                try self.finish(active, if (active.result.dispatched) .outcome_unknown else .failed, .conflict, response.status);
                return;
            }
            var observed = parsed;
            observed.power.capability = self.power.value.capability;
            observed.boot.capability = self.boot_snapshot.value.capability;
            try self.setSnapshots(observed.power, observed.boot);
            if (stage == .conflict_refresh) {
                active.result.current_power = parsed.power.state.value;
                active.result.current_boot = try copyBoot(active.arena.allocator(), parsed.boot.state);
                try self.finish(active, .failed, .conflict, active.result.http_status);
                return;
            }
            if (stage == .refresh) {
                const same = switch (active.kind) {
                    .power => parsed.power.state.value == active.baseline.power,
                    .boot => svc.sameBoot(parsed.boot.state, active.baseline.boot.?),
                };
                if (!same or !svc.optionalEqual(active.baseline.etag, response.etag)) {
                    try self.finish(active, .failed, .stale_baseline, response.status);
                    return;
                }
                // Fresh reads cannot introduce new allowable values. They must
                // independently continue to permit every requested field.
                if (!try self.refreshAllows(active, parsed)) {
                    try self.finish(active, .failed, .stale_capability, response.status);
                    return;
                }
                active.refresh_done = true;
                active.precondition_collected_ms = now_ms;
                active.stage = .write;
                active.result.phase = .queued;
            } else {
                active.result.current_power = parsed.power.state.value;
                active.result.current_boot = try copyBoot(active.arena.allocator(), parsed.boot.state);
                const verified = switch (active.kind) {
                    .power => |action| if (action.isRestart()) active.task_completed and parsed.power.state.value == .on else parsed.power.state.value == (if (action == .on) svc.PowerState.on else svc.PowerState.off),
                    .boot => |changed| boot.matches(active.expected_boot orelse expectedFrom(active.baseline.boot.?, changed), parsed.boot.state, changed),
                };
                if (verified) {
                    try self.finish(active, .succeeded, null, response.status);
                    return;
                }
                if (active.kind == .power and active.kind.power.isRestart() and parsed.power.state.value == .on and !active.task_completed) {
                    try self.finish(active, .outcome_unknown, .accepted_unverified, response.status);
                    return;
                }
                if (active.kind == .boot) {
                    if (parsed.boot.settings_uri) |settings_uri| {
                        active.pending_uri = try active.arena.allocator().dupe(u8, settings_uri);
                        active.stage = .pending_verify;
                        active.result.phase = .verifying;
                    } else {
                        try self.finish(active, .outcome_unknown, .verification_mismatch, response.status);
                        return;
                    }
                }
            }
        }
        const delay = @max(response.retry_after_ms orelse 1000, 250);
        active.next_poll_ms = now_ms +| delay;
        active.result.retry_after_ms = delay;
        try self.journal.setResult(active.index, active.result);
    }
    fn refreshAllows(self: *Engine, active: *Active, parsed: redfish.ParsedSystem) !bool {
        _ = self;
        return switch (active.kind) {
            .power => |action| parsed.power.state.evidence.permitsWrite() and parsed.power.reset_types.evidence.permitsWrite() and svc.contains(parsed.power.reset_types.value orelse return false, action.redfish()) and parsed.power.reset_target != null and std.mem.eql(u8, parsed.power.reset_target.?, active.write_uri),
            .boot => |changed| blk: {
                var snapshot = parsed.boot;
                snapshot.etag = active.baseline.etag;
                _ = boot.prepare(active.arena.allocator(), snapshot, .{ .execution = active.execution, .baseline = active.baseline.boot.?, .enabled = changed.enabled, .target = changed.target, .mode = changed.mode, .etag = active.baseline.etag }) catch break :blk false;
                break :blk true;
            },
        };
    }
    pub fn cancel(self: *Engine, key: svc.OperationKey) svc.CancelResult {
        const active = if (self.active) |*value| value else return if (self.journal.find(key) != null) .already_terminal else .stale_operation;
        if (!active.execution.operation.eql(key)) return if (self.journal.find(key) != null) .already_terminal else .stale_operation;
        if (active.result.terminal()) return .already_terminal;
        const sent = active.result.dispatched;
        self.finish(active, if (sent) .outcome_unknown else .cancelled_unsent, .cancelled, null) catch {
            active.result.phase = if (sent) .outcome_unknown else .cancelled_unsent;
            active.result.reason = .journal_failed;
            self.release(active);
        };
        active.waiting = false;
        return if (sent) .observation_stopped_remote_may_continue else .cancelled_unsent;
    }
    pub fn result(self: *const Engine, key: svc.OperationKey) !svc.Result {
        if (self.active) |active| if (active.execution.operation.eql(key)) return active.result;
        return self.journal.entries[self.journal.find(key) orelse return error.StaleOperation].result();
    }
    /// Explicit query of a recovered/unknown result. This creates GET work only.
    pub fn query(self: *Engine, key: svc.OperationKey, now_ms: u64) !void {
        if (self.active) |*old| {
            if (!old.result.terminal()) return error.ManagementBusy;
            self.release(old);
            old.arena.deinit();
            self.active = null;
        }
        const index = self.journal.find(key) orelse return error.StaleOperation;
        const entry = self.journal.entries[index];
        if (!entry.dispatch_started or entry.phase != .outcome_unknown) return error.OperationNotUnknown;
        const owner = switch (key.owner) {
            .session => |owner| owner,
            else => return error.StaleBinding,
        };
        if (!owner.eql(self.owner)) return error.StaleBinding;
        var arena: std.heap.ArenaAllocator = .init(self.allocator);
        errdefer arena.deinit();
        const path = try redfish.resourceUri(arena.allocator(), self.origin, entry.canonical_target);
        const cap = self.power.value.capability;
        var state = entry.result();
        state.phase = .verifying;
        // A task completion replaces the journal arena; the query owns every
        // borrowed result string before its first completion can persist.
        if (state.task_uri) |uri| state.task_uri = try arena.allocator().dupe(u8, uri);
        if (state.current_boot) |value| state.current_boot = try copyBoot(arena.allocator(), value);
        if (state.pending_boot) |value| state.pending_boot = try copyBoot(arena.allocator(), value);
        const owned_parameters = try copyParameters(arena.allocator(), entry.parameters);
        const baseline = try copyBaseline(arena.allocator(), entry.baseline);
        self.active = .{ .arena = arena, .execution = .{ .call = .{ .owner = self.owner, .binding_generation = cap.binding_generation }, .operation = key, .nonce = entry.nonce, .system_uri = path, .capability_revision = cap.revision, .grant_revision = cap.grant_revision }, .index = index, .kind = owned_parameters, .baseline = baseline, .write_uri = path, .body = "", .result = state, .stage = if (state.task_uri != null) .task else .query, .query_only = true, .deadline_ms = now_ms +| 60_000 };
    }
    fn finish(self: *Engine, active: *Active, phase: svc.Phase, reason: ?svc.Reason, status: ?u16) !void {
        var result_value = active.result;
        result_value.phase = phase;
        result_value.reason = reason;
        if (status) |value| result_value.http_status = value;
        self.journal.setResult(active.index, result_value) catch |err| {
            active.result.phase = if (active.result.dispatched) .outcome_unknown else .failed;
            active.result.reason = .journal_failed;
            self.release(active);
            return err;
        };
        active.result = result_value;
        active.waiting = false;
        self.release(active);
    }
    fn release(self: *Engine, active: *Active) void {
        if (active.authkey) |*secret| {
            secret.deinit();
            active.authkey = null;
        }
        if (active.arbiter_lease) |lease| {
            if (self.arbiter) |arbiter| arbiter.release(arbiter.context, lease);
            active.arbiter_lease = null;
        }
    }
    pub fn setNow(self: *Engine, now_ms: u64) void {
        self.now_ms = now_ms;
    }
    pub fn powerBinding(self: *Engine, revision: u64) @import("../../../host/plugin_services.zig").Binding {
        return @import("../../../host/plugin_services.zig").Binding.init(svc.PowerService, svc.power_key, self, &power_vtable, self.owner, revision);
    }
    pub fn bootBinding(self: *Engine, revision: u64) @import("../../../host/plugin_services.zig").Binding {
        return @import("../../../host/plugin_services.zig").Binding.init(svc.BootService, svc.boot_key, self, &boot_vtable, self.owner, revision);
    }
};
fn engine(raw: *anyopaque) *Engine {
    return @ptrCast(@alignCast(raw));
}
fn powerSnapshot(raw: *anyopaque, call: svc.Call, allocator: std.mem.Allocator) !svc.OwnedPowerSnapshot {
    return engine(raw).powerSnapshot(call, allocator);
}
fn bootSnapshot(raw: *anyopaque, call: svc.Call, allocator: std.mem.Allocator) !svc.OwnedBootSnapshot {
    return engine(raw).bootSnapshot(call, allocator);
}
fn requestPower(raw: *anyopaque, request: svc.PowerExecutionRequest) svc.RequestResult {
    const value = engine(raw);
    return .{ .accepted = value.requestPower(request, value.now_ms) catch |err| return .{ .rejected = rejection(err) } };
}
fn applyBoot(raw: *anyopaque, patch: svc.BootExecutionPatch) svc.RequestResult {
    const value = engine(raw);
    return .{ .accepted = value.applyBoot(patch, value.now_ms) catch |err| return .{ .rejected = rejection(err) } };
}
fn cancelOperation(raw: *anyopaque, call: svc.Call, key: svc.OperationKey) svc.CancelResult {
    const value = engine(raw);
    value.validateCall(call) catch return .stale_operation;
    return value.cancel(key);
}
fn operationResult(raw: *anyopaque, call: svc.Call, key: svc.OperationKey, allocator: std.mem.Allocator) !svc.Owned(svc.Result) {
    const value = engine(raw);
    try value.validateCall(call);
    const owner = switch (key.owner) {
        .session => |owner| owner,
        else => return error.StaleOperation,
    };
    if (!owner.eql(call.owner)) return error.StaleOperation;
    return svc.Owned(svc.Result).init(allocator, try value.result(key));
}
pub fn rejection(err: anyerror) svc.Reason {
    return switch (err) {
        error.StaleBinding => .stale_binding,
        error.StaleCapability => .stale_capability,
        error.PermissionDenied => .permission_denied,
        error.MappingUnverified => .mapping_unverified,
        error.SecondaryAuthUnknown => .secondary_auth_unknown,
        error.SecondaryAuthRequired => .secondary_auth_required,
        error.StaleBaseline => .stale_baseline,
        error.OperationConflict => .conflict,
        error.ManagementBusy, error.ResourceBusy => .busy,
        error.UnsupportedAction, error.UnsupportedBootValue, error.BootWriteTargetUnverified => .unsupported,
        error.ArbiterUnavailable => .unavailable,
        error.InjectedJournalFailure, error.JournalDirectorySyncFailed => .journal_failed,
        else => .invalid_request,
    };
}
const power_vtable: svc.PowerService = .{ .snapshot = powerSnapshot, .request = requestPower, .cancel = cancelOperation, .result = operationResult };
const boot_vtable: svc.BootService = .{ .snapshot = bootSnapshot, .apply = applyBoot, .cancel = cancelOperation, .result = operationResult };
fn copyBoot(a: std.mem.Allocator, state: svc.BootState) !svc.BootState {
    return .{ .enabled = if (state.enabled) |value| try a.dupe(u8, value) else null, .target = if (state.target) |value| try a.dupe(u8, value) else null, .mode = if (state.mode) |value| try a.dupe(u8, value) else null };
}
fn expectedFrom(baseline: svc.BootState, changed: svc.BootState) svc.BootState {
    return .{ .enabled = changed.enabled orelse baseline.enabled, .target = changed.target orelse baseline.target, .mode = changed.mode orelse baseline.mode };
}
fn copyParameters(a: std.mem.Allocator, parameters: ledger.Parameters) !ledger.Parameters {
    return switch (parameters) {
        .power => parameters,
        .boot => |state| .{ .boot = try copyBoot(a, state) },
    };
}
fn copyBaseline(a: std.mem.Allocator, baseline: ledger.Baseline) !ledger.Baseline {
    return .{ .power = baseline.power, .boot = if (baseline.boot) |state| try copyBoot(a, state) else null, .etag = if (baseline.etag) |tag| try a.dupe(u8, tag) else null };
}
