const std = @import("std");

/// Reconnect state machine. The worker thread mutates the state; the UI thread
/// reads it through currentState() (input routing, status display). Only the
/// worker thread writes, so read-modify-write cycles are safe without CAS —
/// the atomic only guarantees that cross-thread readers see a whole enum.
pub const State = enum(u8) { connected, suspected, reconnecting, dead, closed };
pub const Machine = struct {
    state: std.atomic.Value(State) = .init(.connected),
    attempts: u8 = 0,
    max_attempts: u8,
    backoff: []const u8,
    failed_hop: ?usize = null,

    pub fn init(max_attempts: u8, backoff: []const u8) !Machine {
        if (max_attempts == 0 or max_attempts > backoff.len) return error.InvalidPolicy;
        return .{ .max_attempts = max_attempts, .backoff = backoff };
    }

    pub fn currentState(self: *const Machine) State {
        return self.state.load(.acquire);
    }

    fn setState(self: *Machine, next: State) void {
        self.state.store(next, .release);
    }

    pub fn suspect(self: *Machine, failed_hop: ?usize) void {
        const state = self.currentState();
        if (state == .closed or state == .dead) return;
        self.setState(.suspected);
        self.failed_hop = failed_hop;
    }
    pub fn nextDelay(self: *Machine) !u8 {
        const state = self.currentState();
        if (state != .suspected and state != .reconnecting) return error.InvalidTransition;
        if (self.attempts >= self.max_attempts) {
            self.setState(.dead);
            return error.RetryExhausted;
        }
        const delay = self.backoff[self.attempts];
        self.attempts += 1;
        self.setState(.reconnecting);
        return delay;
    }
    pub fn authorized(self: *Machine) void {
        self.setState(.reconnecting);
    }
    pub fn connected(self: *Machine) void {
        self.setState(.connected);
        self.attempts = 0;
        self.failed_hop = null;
    }
    pub fn failed(self: *Machine) void {
        const state = self.currentState();
        if (state != .reconnecting and state != .suspected) return;
        if (self.attempts >= self.max_attempts) self.setState(.dead) else self.setState(.suspected);
    }
    pub fn close(self: *Machine) void {
        self.setState(.closed);
    }
};

test "reconnect state follows configured backoff and reaches dead" {
    const backoff = [_]u8{ 1, 2, 4 };
    var machine = try Machine.init(3, &backoff);
    machine.suspect(1);
    try std.testing.expectEqual(@as(u8, 1), try machine.nextDelay());
    machine.failed();
    try std.testing.expectEqual(@as(u8, 2), try machine.nextDelay());
    machine.failed();
    _ = try machine.nextDelay();
    machine.failed();
    try std.testing.expectEqual(State.dead, machine.currentState());
}

test "reconnect state is readable across threads" {
    const backoff = [_]u8{1};
    var machine = Machine.init(1, &backoff) catch unreachable;
    machine.suspect(null);
    const reader = struct {
        fn read(subject: *Machine, observed: *State) void {
            observed.* = subject.currentState();
        }
    };
    var observed: State = .connected;
    const thread = try std.Thread.spawn(.{}, reader.read, .{ &machine, &observed });
    thread.join();
    try std.testing.expectEqual(State.suspected, observed);
}

const OperationKey = @import("../host/operation.zig").OperationKey;
const ReleaseReceipt = @import("../proto/ssh/session.zig").ReleaseReceipt;

/// One host-issued grant crosses into the existing IO owner. No native call,
/// ID allocation or network wait runs while this short mailbox lock is held.
pub const Control = struct {
    pub const Phase = enum { active, releasing, waiting, connecting, ready, ended, closed };
    pub const Snapshot = struct {
        key: ?OperationKey,
        phase: Phase = .active,
        cleanup: ReleaseReceipt = .awaiting,
        failure: ?anyerror = null,
        /// Present only when the peer sent an actual shell exit-status.
        exit_code: ?i32 = null,
        /// Retained for this exact operation after a later transport fault.
        was_attached: bool = false,
        notification_incident: ?u64 = null,
    };
    pub const Grant = struct { previous: OperationKey, next: OperationKey };
    mutex: std.atomic.Value(bool) = .init(false),
    value: Snapshot,
    grant: ?Grant = null,

    pub fn init(key: ?OperationKey) Control {
        return .{ .value = .{ .key = key } };
    }
    fn lock(self: *Control) void {
        while (self.mutex.swap(true, .acquire)) std.atomic.spinLoopHint();
    }
    fn unlock(self: *Control) void {
        self.mutex.store(false, .release);
    }
    pub fn snapshot(self: *Control) Snapshot {
        self.lock();
        defer self.unlock();
        return self.value;
    }
    pub fn lost(self: *Control, key: ?OperationKey, receipt: ReleaseReceipt, failure: anyerror) void {
        self.lostWithIncident(key, receipt, failure, null);
    }
    pub fn lostWithIncident(self: *Control, key: ?OperationKey, receipt: ReleaseReceipt, failure: anyerror, incident: ?u64) void {
        self.lock();
        defer self.unlock();
        if (self.value.phase == .closed or self.value.phase == .ended or !std.meta.eql(key, self.value.key)) return;
        self.value.phase = if (receipt == .awaiting) .releasing else .waiting;
        self.value.cleanup = receipt;
        self.value.failure = failure;
        self.value.notification_incident = incident;
    }
    pub fn ended(self: *Control, key: ?OperationKey, receipt: ReleaseReceipt, exit_code: ?i32) void {
        self.lock();
        defer self.unlock();
        if (self.value.phase == .closed or !std.meta.eql(key, self.value.key)) return;
        self.value.phase = .ended;
        self.value.cleanup = receipt;
        self.value.failure = null;
        self.value.exit_code = exit_code;
        self.grant = null;
    }
    pub fn request(self: *Control, previous: OperationKey, next: OperationKey) !void {
        self.lock();
        defer self.unlock();
        if (self.value.key == null or !self.value.key.?.eql(previous)) return error.StaleOperation;
        if ((self.value.phase != .waiting and self.value.phase != .ended) or self.grant != null) return error.ReconnectAlreadyRequested;
        if (self.value.cleanup != .released) return error.CleanupNotReleased;
        if (previous.owner != .session or next.owner != .session or
            previous.owner.session.session_id != next.owner.session.session_id or
            previous.owner.session.generation == std.math.maxInt(u64) or next.owner.session.generation != previous.owner.session.generation + 1 or
            previous.attempt_id == null or previous.attempt_id.? == std.math.maxInt(u64) or next.attempt_id != previous.attempt_id.? + 1 or
            next.operation_id == previous.operation_id) return error.InvalidOperation;
        self.grant = .{ .previous = previous, .next = next };
        self.value.phase = .connecting;
    }
    /// IO-owner only. Taking the grant consumes it before any network IO.
    pub fn take(self: *Control) ?Grant {
        self.lock();
        defer self.unlock();
        const grant = self.grant orelse return null;
        self.grant = null;
        self.value = .{ .key = grant.next, .phase = .connecting };
        return grant;
    }
    pub fn ready(self: *Control, key: OperationKey) void {
        self.lock();
        defer self.unlock();
        if (self.value.phase != .connecting or self.value.key == null or !self.value.key.?.eql(key)) return;
        self.value.phase = .ready;
    }
    pub fn attached(self: *Control, key: OperationKey) bool {
        self.lock();
        defer self.unlock();
        if (self.value.key == null or !self.value.key.?.eql(key)) return false;
        if (self.value.phase == .active) {
            self.value.was_attached = true;
            return true;
        }
        if (self.value.phase != .ready) return false;
        self.value.phase = .active;
        self.value.was_attached = true;
        return true;
    }
    pub fn close(self: *Control) void {
        self.lock();
        defer self.unlock();
        self.value.phase = .closed;
        self.grant = null;
    }
};

/// Controller-owned countdown. Manual and timer deliveries claim this same
/// ticket; delayed timer deliveries cannot create a second attempt.
pub const Ticket = struct {
    key: OperationKey,
    deadline_ns: ?i128,
    claimed: bool = false,
    invalidated: bool = false,
    pub fn claim(self: *Ticket, key: OperationKey, now_ns: i128, manual: bool) bool {
        if (self.claimed or self.invalidated or !self.key.eql(key)) return false;
        if (!manual and (self.deadline_ns == null or now_ns < self.deadline_ns.?)) return false;
        self.claimed = true;
        self.deadline_ns = null;
        return true;
    }
    pub fn invalidate(self: *Ticket) void {
        self.invalidated = true;
        self.deadline_ns = null;
    }
};

test "notification reconnect retains actual attachment across fault and resets it for a new operation" {
    const first: OperationKey = .{ .owner = .{ .session = .{ .session_id = @fromBackingInt(7) } }, .operation_id = 1, .attempt_id = 1 };
    var next = first;
    next.owner.session.generation = 2;
    next.operation_id = 2;
    next.attempt_id = 2;
    var control = Control.init(first);
    try std.testing.expect(!control.snapshot().was_attached);
    try std.testing.expect(control.attached(first));
    control.lost(first, .released, error.ConnectionClosed);
    try std.testing.expect(control.snapshot().was_attached);
    try control.request(first, next);
    _ = control.take().?;
    try std.testing.expect(!control.snapshot().was_attached);
    control.lost(next, .released, error.ConnectionClosed);
    try std.testing.expect(!control.snapshot().was_attached);
}

test "manual and late timer share one reconnect ticket including sleep gaps" {
    const key: OperationKey = .{ .owner = .{ .session = .{ .session_id = @fromBackingInt(7) } }, .operation_id = 1, .attempt_id = 1 };
    var ticket: Ticket = .{ .key = key, .deadline_ns = 100 };
    try std.testing.expect(!ticket.claim(key, 99, false));
    try std.testing.expect(ticket.claim(key, 99, true));
    try std.testing.expect(!ticket.claim(key, 10_000, false));
    try std.testing.expect(!ticket.claim(key, 10_000, true));
    var no_auto: Ticket = .{ .key = key, .deadline_ns = null };
    try std.testing.expect(!no_auto.claim(key, 10_000, false));
    no_auto.invalidate();
    try std.testing.expect(!no_auto.claim(key, 10_000, true));
}

test "host reconnect grant is released-only single-use and rejects old readiness" {
    const first: OperationKey = .{ .owner = .{ .session = .{ .session_id = @fromBackingInt(7) } }, .operation_id = 1, .attempt_id = 1 };
    var next = first;
    next.owner.session.generation = 2;
    next.operation_id = 2;
    next.attempt_id = 2;
    var control = Control.init(first);
    control.lost(first, .unknown, error.ConnectionClosed);
    try std.testing.expectError(error.CleanupNotReleased, control.request(first, next));
    control.lost(first, .released, error.ConnectionClosed);
    try control.request(first, next);
    try std.testing.expectError(error.ReconnectAlreadyRequested, control.request(first, next));
    try std.testing.expect(control.take().?.next.eql(next));
    try std.testing.expect(control.take() == null);
    control.ready(first);
    try std.testing.expectEqual(Control.Phase.connecting, control.snapshot().phase);
    control.ready(next);
    try std.testing.expect(!control.attached(first));
    try std.testing.expect(control.attached(next));
    control.close();
    control.lost(next, .released, error.ConnectionClosed);
    try std.testing.expectEqual(Control.Phase.closed, control.snapshot().phase);
}

test "normal shell end has no failure or automatic grant and keeps actual exit presence" {
    const first: OperationKey = .{ .owner = .{ .session = .{ .session_id = @fromBackingInt(7) } }, .operation_id = 1, .attempt_id = 1 };
    var next = first;
    next.owner.session.generation += 1;
    next.operation_id += 1;
    next.attempt_id = 2;
    var control = Control.init(first);
    control.ended(first, .awaiting, null);
    try std.testing.expectEqual(Control.Phase.ended, control.snapshot().phase);
    try std.testing.expect(control.snapshot().failure == null);
    try std.testing.expect(control.snapshot().exit_code == null);
    try std.testing.expect(control.take() == null);
    try std.testing.expectError(error.CleanupNotReleased, control.request(first, next));
    control.ended(first, .released, 7);
    control.lost(first, .released, error.ConnectionClosed);
    try std.testing.expectEqual(Control.Phase.ended, control.snapshot().phase);
    try std.testing.expectEqual(@as(?i32, 7), control.snapshot().exit_code);
    try std.testing.expect(control.take() == null);
    try control.request(first, next);
    try std.testing.expect(control.take().?.next.eql(next));
    try std.testing.expect(control.snapshot().exit_code == null);
    control.ended(first, .released, 0);
    try std.testing.expectEqual(Control.Phase.connecting, control.snapshot().phase);
}
