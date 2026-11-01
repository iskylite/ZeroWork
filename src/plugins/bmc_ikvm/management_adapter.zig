//! Single worker owns Engine. Typed callers enqueue owned requests; they never
//! execute journal persistence or network IO. Locks cover mailbox/cache copies.
const std = @import("std");
pub const svc = @import("services.zig");
pub const power = @import("protocol/power.zig");
const journal = @import("management_journal.zig");
const model = @import("model.zig");
const redfish = @import("protocol/redfish.zig");
const typed = @import("../../host/plugin_services.zig");
const actions = @import("../../host/resource_actions.zig");

pub const Adapter = struct {
    const Pending = union(enum) { power: svc.Owned(svc.PowerExecutionRequest), boot: svc.Owned(svc.BootExecutionPatch) };
    const Record = struct { key: svc.OperationKey, nonce: [16]u8, request_sha256: [32]u8, result: svc.Owned(svc.Result), cancel_requested: bool = false };
    const InFlight = struct { sequence: u64, operation: svc.OperationKey };
    allocator: std.mem.Allocator,
    owner: svc.identity.SessionHandle,
    endpoint: model.Endpoint,
    facade: ?actions.Facade,
    lease: ?actions.Lease = null,
    engine: power.Engine,
    cached_power: svc.OwnedPowerSnapshot,
    cached_boot: svc.OwnedBootSnapshot,
    pending: ?Pending = null,
    /// Owned by the worker until the matching HTTP transaction has drained.
    /// Cancelling Engine observation does not retire bytes on the HTTP stream.
    in_flight: ?InFlight = null,
    records: [64]?Record = @splat(null),
    mutex: std.atomic.Value(bool) = .init(false),
    authenticated: bool = false,
    closed: bool = false,
    now_ms: u64 = 0,

    /// Call at the final address; endpoint text and journal outlive Adapter.
    pub fn init(self: *Adapter, a: std.mem.Allocator, owner: svc.identity.SessionHandle, endpoint: model.Endpoint, ledger: *journal.Journal, facade: ?actions.Facade) !void {
        if (facade) |value| if (!value.owner.eql(owner)) return error.StaleBinding;
        var cached_power = try svc.OwnedPowerSnapshot.init(a, .{});
        errdefer cached_power.deinit();
        var cached_boot = try svc.OwnedBootSnapshot.init(a, .{});
        errdefer cached_boot.deinit();
        const origin = try redfish.Origin.init(a, endpoint);
        defer a.free(origin.authority);
        // Engine borrows origin, so retain a dedicated owned authority.
        const owned_origin: redfish.Origin = .{ .authority = try a.dupe(u8, origin.authority) };
        errdefer a.free(owned_origin.authority);
        self.* = .{ .allocator = a, .owner = owner, .endpoint = endpoint, .facade = facade, .engine = try power.Engine.init(a, owner, owned_origin, ledger, if (facade != null) .{ .context = self, .acquire = acquire, .revalidate = revalidate, .release = release } else null), .cached_power = cached_power, .cached_boot = cached_boot };
    }
    pub fn deinit(self: *Adapter) void {
        self.close();
        const authority = self.engine.origin.authority;
        self.engine.deinit();
        self.allocator.free(authority);
        self.cached_power.deinit();
        self.cached_boot.deinit();
        for (&self.records) |*slot| if (slot.*) |*record| record.result.deinit();
        self.* = undefined;
    }
    pub fn close(self: *Adapter) void {
        self.lock();
        if (self.closed) {
            self.unlock();
            return;
        }
        self.closed = true;
        self.authenticated = false;
        self.unlock();
        self.tick(self.now_ms) catch {};
        if (self.engine.active) |active| _ = self.engine.cancel(active.execution.operation);
        self.publishResults() catch {};
    }
    pub fn setSnapshots(self: *Adapter, p: svc.PowerSnapshot, b: svc.BootSnapshot, authenticated: bool) !void {
        var pc = try svc.OwnedPowerSnapshot.init(self.allocator, p);
        errdefer pc.deinit();
        var bc = try svc.OwnedBootSnapshot.init(self.allocator, b);
        errdefer bc.deinit();
        try self.engine.setSnapshots(pc.value, bc.value);
        self.swapSnapshots(pc, bc, authenticated);
    }
    fn swapSnapshots(self: *Adapter, pc: svc.OwnedPowerSnapshot, bc: svc.OwnedBootSnapshot, authenticated: bool) void {
        self.lock();
        const oldp = self.cached_power;
        const oldb = self.cached_boot;
        self.cached_power = pc;
        self.cached_boot = bc;
        self.authenticated = authenticated and !self.closed;
        self.unlock();
        var mutable_p = oldp;
        mutable_p.deinit();
        var mutable_b = oldb;
        mutable_b.deinit();
    }
    pub fn tick(self: *Adapter, now_ms: u64) !void {
        self.now_ms = now_ms;
        self.engine.setNow(now_ms);
        self.lock();
        const closed = self.closed;
        var cancellations: [64]?svc.OperationKey = @splat(null);
        for (&self.records, 0..) |*slot, i| if (slot.*) |*record| if (record.cancel_requested) {
            cancellations[i] = record.key;
            record.cancel_requested = false;
        };
        var pending_cancelled = false;
        if (self.pending) |value| {
            const key = pendingKey(value);
            for (cancellations) |cancel_key| if (cancel_key) |cancel_value| if (cancel_value.eql(key)) {
                pending_cancelled = true;
                break;
            };
        }
        // A new Engine operation can free the old operation arena. Preserve it
        // and the HTTP slot until its matching response or transport failure.
        const take_pending = self.in_flight == null or closed or pending_cancelled;
        const pending = if (take_pending) self.pending else null;
        if (take_pending) self.pending = null;
        self.unlock();
        for (cancellations) |key| if (key) |value| {
            _ = self.engine.cancel(value);
        };
        try self.publishResults();
        if (pending) |value| {
            var request = value;
            defer switch (request) {
                .power => |*v| v.deinit(),
                .boot => |*v| v.deinit(),
            };
            const key = pendingKey(request);
            if (closed or pending_cancelled) {
                try self.store(.{ .operation = key, .phase = .cancelled_unsent, .reason = .cancelled });
            } else {
                const accepted: ?svc.OperationKey = switch (request) {
                    .power => |v| self.engine.requestPower(v.value, now_ms),
                    .boot => |v| self.engine.applyBoot(v.value, now_ms),
                } catch |err| blk: {
                    try self.store(.{ .operation = key, .phase = .failed, .reason = power.rejection(err) });
                    break :blk null;
                };
                _ = accepted;
            }
        }
        try self.publishResults();
    }
    fn pendingKey(value: Pending) svc.OperationKey {
        return switch (value) {
            .power => |v| v.value.execution.operation,
            .boot => |v| v.value.execution.operation,
        };
    }
    pub fn next(self: *Adapter, now_ms: u64) !?power.Outbound {
        try self.tick(now_ms);
        self.lock();
        const cap = self.cached_power.value.capability;
        const authenticated = self.authenticated;
        const closed = self.closed;
        self.unlock();
        if (closed) return null;
        const gate: power.Gate = .{ .owner = self.owner, .binding_generation = cap.binding_generation, .capability_revision = cap.revision, .grant_revision = cap.grant_revision, .authenticated = authenticated, .write_granted = cap.write_granted };
        if (self.in_flight) |flight| {
            const active = self.engine.active orelse return error.InvalidManagementTransaction;
            if (!active.execution.operation.eql(flight.operation) or (!active.waiting and !active.result.terminal())) return error.InvalidManagementTransaction;
            // Engine still owns its timeout clock while HTTP drains. A waiting
            // transaction cannot produce a second outbound work item.
            if (try self.engine.next(now_ms, gate) != null) return error.InvalidManagementTransaction;
            try self.publishResults();
            return null;
        }
        const outbound = try self.engine.next(now_ms, gate);
        if (outbound) |work| self.in_flight = .{ .sequence = work.sequence, .operation = work.operation };
        try self.publishResults();
        return outbound;
    }
    pub fn complete(self: *Adapter, completion: power.Completion, now_ms: u64) !void {
        const flight = self.in_flight orelse return error.StaleCompletion;
        if (completion.sequence != flight.sequence) return error.StaleCompletion;
        const active = self.engine.active orelse return error.StaleOperation;
        if (!active.execution.operation.eql(flight.operation)) return error.StaleOperation;
        if (active.result.terminal()) {
            // This exact HTTP response belongs to an observation already
            // cancelled/timed out. Drain it without changing its unknown result
            // or granting permission to replay the original mutation.
            self.in_flight = null;
            return;
        }
        try self.engine.complete(completion, now_ms);
        self.in_flight = null;
        var pc = try svc.OwnedPowerSnapshot.init(self.allocator, self.engine.power.value);
        errdefer pc.deinit();
        const bc = try svc.OwnedBootSnapshot.init(self.allocator, self.engine.boot_snapshot.value);
        self.lock();
        const authenticated = self.authenticated;
        self.unlock();
        self.swapSnapshots(pc, bc, authenticated);
        try self.publishResults();
    }
    fn publishResults(self: *Adapter) !void {
        if (self.engine.active) |active| try self.store(try self.engine.result(active.execution.operation));
    }
    fn store(self: *Adapter, result: svc.Result) !void {
        var copy = try svc.Owned(svc.Result).init(self.allocator, result);
        errdefer copy.deinit();
        self.lock();
        defer self.unlock();
        for (&self.records) |*slot| if (slot.*) |*record| if (record.key.eql(result.operation)) {
            var old = record.result;
            record.result = copy;
            old.deinit();
            return;
        };
        return error.StaleOperation;
    }
    pub fn powerBinding(self: *Adapter) typed.Binding {
        return typed.Binding.init(svc.PowerService, svc.power_key, self, &power_vtable, self.owner, 1);
    }
    pub fn bootBinding(self: *Adapter) typed.Binding {
        return typed.Binding.init(svc.BootService, svc.boot_key, self, &boot_vtable, self.owner, 1);
    }
    fn validate(self: *Adapter, call: svc.Call) !void {
        if (!self.owner.eql(call.owner) or call.binding_generation != self.cached_power.value.capability.binding_generation) return error.StaleBinding;
    }
    fn enqueue(self: *Adapter, pending: Pending) svc.RequestResult {
        self.lock();
        defer self.unlock();
        const execution = switch (pending) {
            .power => |v| v.value.execution,
            .boot => |v| v.value.execution,
        };
        var owned = pending;
        var transferred = false;
        defer if (!transferred) switch (owned) {
            .power => |*v| v.deinit(),
            .boot => |*v| v.deinit(),
        };
        self.validate(execution.call) catch return .{ .rejected = .stale_binding };
        if (execution.operation.owner != .session or !execution.operation.owner.session.eql(self.owner) or execution.operation.operation_id == 0 or std.mem.allEqual(u8, &execution.nonce, 0) or !std.mem.eql(u8, execution.system_uri, self.cached_power.value.system_uri)) return .{ .rejected = .stale_binding };
        const cap = self.cached_power.value.capability;
        if (self.closed or !self.authenticated) return .{ .rejected = .unavailable };
        if (!cap.write_granted) return .{ .rejected = .permission_denied };
        if (!cap.system_mapping_verified) return .{ .rejected = .mapping_unverified };
        if (execution.capability_revision != cap.revision or execution.grant_revision != cap.grant_revision) return .{ .rejected = .stale_capability };
        const encoded = switch (pending) {
            .power => |v| std.json.Stringify.valueAlloc(self.allocator, v.value, .{}),
            .boot => |v| std.json.Stringify.valueAlloc(self.allocator, v.value, .{}),
        } catch return .{ .rejected = .unavailable };
        defer self.allocator.free(encoded);
        // This schema serialization includes typed parameters, complete nonce,
        // operation, revisions, baseline and exact verified System target. Salt
        // it with canonical authority + discovered identity + operation kind.
        var hash = std.crypto.hash.sha2.Sha256.init(.{});
        hash.update(if (pending == .power) "power\x00" else "boot\x00");
        hash.update(self.engine.origin.authority);
        hash.update("\x00");
        hash.update(self.cached_power.value.system_identity);
        hash.update("\x00");
        hash.update(encoded);
        const fingerprint = hash.finalResult();
        for (self.records) |slot| if (slot) |record| if (record.key.eql(execution.operation) or std.mem.eql(u8, &record.nonce, &execution.nonce)) {
            if (!record.key.eql(execution.operation) or !std.mem.eql(u8, &record.nonce, &execution.nonce) or !std.mem.eql(u8, &record.request_sha256, &fingerprint)) return .{ .rejected = .conflict };
            return .{ .accepted = execution.operation };
        };
        if (self.pending != null) return .{ .rejected = .busy };
        for (&self.records) |*slot| if (slot.* == null) {
            const result = svc.Owned(svc.Result).init(self.allocator, .{ .operation = execution.operation, .phase = .queued }) catch return .{ .rejected = .unavailable };
            slot.* = .{ .key = execution.operation, .nonce = execution.nonce, .request_sha256 = fingerprint, .result = result };
            self.pending = pending;
            transferred = true;
            return .{ .accepted = execution.operation };
        };
        return .{ .rejected = .busy };
    }
    fn from(raw: *anyopaque) *Adapter {
        return @ptrCast(@alignCast(raw));
    }
    fn snapshotPower(raw: *anyopaque, call: svc.Call, a: std.mem.Allocator) !svc.OwnedPowerSnapshot {
        const self = from(raw);
        self.lock();
        defer self.unlock();
        try self.validate(call);
        return svc.OwnedPowerSnapshot.init(a, self.cached_power.value);
    }
    fn snapshotBoot(raw: *anyopaque, call: svc.Call, a: std.mem.Allocator) !svc.OwnedBootSnapshot {
        const self = from(raw);
        self.lock();
        defer self.unlock();
        try self.validate(call);
        return svc.OwnedBootSnapshot.init(a, self.cached_boot.value);
    }
    fn requestPower(raw: *anyopaque, request: svc.PowerExecutionRequest) svc.RequestResult {
        const self = from(raw);
        return self.enqueue(.{ .power = svc.Owned(svc.PowerExecutionRequest).init(self.allocator, request) catch return .{ .rejected = .unavailable } });
    }
    fn applyBoot(raw: *anyopaque, request: svc.BootExecutionPatch) svc.RequestResult {
        const self = from(raw);
        return self.enqueue(.{ .boot = svc.Owned(svc.BootExecutionPatch).init(self.allocator, request) catch return .{ .rejected = .unavailable } });
    }
    fn readResult(raw: *anyopaque, call: svc.Call, key: svc.OperationKey, a: std.mem.Allocator) !svc.Owned(svc.Result) {
        const self = from(raw);
        self.lock();
        defer self.unlock();
        try self.validate(call);
        for (self.records) |slot| if (slot) |record| if (record.key.eql(key)) return svc.Owned(svc.Result).init(a, record.result.value);
        return error.StaleOperation;
    }
    fn cancel(raw: *anyopaque, call: svc.Call, key: svc.OperationKey) svc.CancelResult {
        const self = from(raw);
        self.lock();
        defer self.unlock();
        self.validate(call) catch return .stale_operation;
        for (&self.records) |*slot| if (slot.*) |*record| if (record.key.eql(key)) {
            if (record.result.value.terminal()) return .already_terminal;
            record.cancel_requested = true;
            // Only a request still in this mailbox is proven unsent. Once the
            // worker takes it, dispatch may be concurrently entering its journal.
            if (self.pending) |pending| {
                const queued_key = switch (pending) {
                    .power => |v| v.value.execution.operation,
                    .boot => |v| v.value.execution.operation,
                };
                if (queued_key.eql(key)) return .cancelled_unsent;
            }
            return .observation_stopped_remote_may_continue;
        };
        return .stale_operation;
    }
    const power_vtable: svc.PowerService = .{ .snapshot = snapshotPower, .request = requestPower, .cancel = cancel, .result = readResult };
    const boot_vtable: svc.BootService = .{ .snapshot = snapshotBoot, .apply = applyBoot, .cancel = cancel, .result = readResult };
    fn acquire(raw: *anyopaque, key: []const u8, execution: svc.Execution) !u64 {
        const self = from(raw);
        const snapshot = self.engine.power.value;
        const separator = std.mem.indexOfScalar(u8, key, '|') orelse return error.UnverifiedSystem;
        if (!std.mem.eql(u8, key[0..separator], self.engine.origin.authority) or !std.mem.eql(u8, key[separator + 1 ..], snapshot.system_identity) or !std.mem.eql(u8, execution.system_uri, snapshot.system_uri)) return error.UnverifiedSystem;
        if (self.lease != null) return error.ResourceBusy;
        const acquired = try (self.facade orelse return error.ArbiterUnavailable).tryAcquire(.{ .authority = .{ .host = self.endpoint.host, .port = self.endpoint.https_port }, .system_uri = snapshot.system_uri, .system_id = snapshot.system_identity, .verified_mapping = snapshot.capability.system_mapping_verified, .capability_revision = snapshot.capability.revision }, execution.operation, execution.capability_revision);
        self.lease = switch (acquired) {
            .lease => |lease| lease,
            .busy => return error.ResourceBusy,
        };
        return self.lease.?.id;
    }
    fn revalidate(raw: *anyopaque, id: u64, execution: svc.Execution) bool {
        const self = from(raw);
        const lease = self.lease orelse return false;
        if (lease.id != id) return false;
        lease.revalidate(execution.operation, self.engine.power.value.capability.revision) catch return false;
        return true;
    }
    fn release(raw: *anyopaque, id: u64) void {
        const self = from(raw);
        if (self.lease) |lease| if (lease.id == id) {
            lease.release();
            self.lease = null;
        };
    }
    fn lock(self: *Adapter) void {
        while (self.mutex.swap(true, .acquire)) std.atomic.spinLoopHint();
    }
    fn unlock(self: *Adapter) void {
        self.mutex.store(false, .release);
    }
};
