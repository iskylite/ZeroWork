//! Bounded facts and request mailboxes for one frozen connection attempt.
//! Native handles never cross this boundary; each transport's IO owner drives
//! its own channel-open sample and publishes a copy of the result here.
const std = @import("std");
const operation = @import("../../host/operation.zig");
const identity = @import("../../host/identity.zig");
const auth = @import("auth_flow.zig");
pub const OperationKey = operation.OperationKey;
pub const max_hops = 9;
pub const Source = enum { session, @"test" };
pub const Status = enum { not_attempted, negotiating, online, releasing, released };
pub const Cleanup = enum { released, releasing, unknown };
pub const Reason = enum { rejected, native_failure, timed_out, cancelled, session_closed };

pub fn Text(comptime capacity: usize) type {
    return struct {
        bytes: [capacity]u8 = @splat(0),
        len: usize = 0,
        pub fn init(value: []const u8) !@This() {
            if (value.len > capacity) return error.DetailsTextTooLong;
            var result: @This() = .{};
            @memcpy(result.bytes[0..value.len], value);
            result.len = value.len;
            return result;
        }
        pub fn slice(self: *const @This()) []const u8 {
            return self.bytes[0..self.len];
        }
    };
}
pub const Endpoint = struct {
    host: Text(1024) = .{},
    user: Text(256) = .{},
    name: Text(512) = .{},
    port: u16 = 22,
    asset_owner: ?identity.AssetOwner = null,
};
pub const Metadata = struct {
    /// Negotiated signature algorithm, separate from the trust key's wire type.
    host_key_algorithm: Text(64) = .{},
    fingerprint: Text(128) = .{},
    cipher_c2s: Text(64) = .{},
    cipher_s2c: Text(64) = .{},
    accepted_auth_methods: auth.Methods = .init(.{}),
};
pub const Sample = struct {
    request_id: u64,
    probe_kind: enum { ssh_channel_open } = .ssh_channel_open,
    started_ns: ?i128 = null,
    completed_ns: ?i128 = null,
    duration_ms: ?u64 = null,
    status: enum { pending, ready, unavailable, stale } = .pending,
    reason: ?Reason = null,
    cleanup: Cleanup = .released,
};
pub const Hop = struct {
    endpoint: Endpoint = .{},
    configured: bool = false,
    status: Status = .not_attempted,
    metadata: Metadata = .{},
    rtt_sample: ?Sample = null,
};
pub const ConnectionDetailsSnapshot = struct {
    key: OperationKey,
    revision: u64,
    source: Source,
    hops: [max_hops]Hop,
    hop_count: usize,
    target_rtt_sample: ?Sample,
    sampled_at: ?i128,
};
pub const Request = struct {
    id: u64,
    timeout_ms: u32,
    cancelled: bool = false,
};
const Slot = struct {
    request: ?Request = null,
    taken: bool = false,
};

pub const Store = struct {
    mutex: std.atomic.Value(bool) = .init(false),
    key: ?OperationKey = null,
    revision: u64 = 0,
    source: Source = .session,
    hop_count: usize = 0,
    hops: [max_hops]Hop = @splat(.{}),
    slots: [max_hops]Slot = @splat(.{}),
    next_request: u64 = 1,

    fn tryLock(self: *Store) bool {
        return !self.mutex.swap(true, .acquire);
    }
    fn lock(self: *Store) void {
        while (!self.tryLock()) std.atomic.spinLoopHint();
    }
    fn unlock(self: *Store) void {
        self.mutex.store(false, .release);
    }
    fn matches(self: *const Store, key: OperationKey, hop: usize) bool {
        return self.key != null and self.key.?.eql(key) and hop < self.hop_count;
    }
    fn changed(self: *Store) void {
        self.revision +|= 1;
    }
    pub fn begin(self: *Store, key: OperationKey, hop_count: usize, source: Source) !void {
        if (key.operation_id == 0 or key.attempt_id == null or key.attempt_id == 0 or hop_count == 0 or hop_count > max_hops) return error.InvalidDetailsOwner;
        if ((source == .session and key.owner != .session) or (source == .@"test" and key.owner != .app)) return error.InvalidDetailsOwner;
        self.lock();
        defer self.unlock();
        if (self.key) |previous| {
            if (previous.eql(key)) {
                if (self.hop_count != hop_count or self.source != source) return error.InvalidDetailsOwner;
                return;
            }
            for (self.hops[0..self.hop_count], self.slots[0..self.hop_count]) |hop, slot| {
                if (hop.status != .not_attempted and hop.status != .released) return error.CleanupNotReleased;
                if (slot.request != null) return error.CleanupNotReleased;
            }
            if (previous.owner != .session or key.owner != .session or previous.owner.session.session_id != key.owner.session.session_id or
                key.owner.session.generation != try identity.advance(previous.owner.session.generation) or
                key.attempt_id != try identity.advance(previous.attempt_id.?) or previous.operation_id == key.operation_id) return error.InvalidDetailsOwner;
        }
        self.key = key;
        self.hop_count = hop_count;
        self.source = source;
        self.hops = @splat(.{});
        self.slots = @splat(.{});
        self.changed();
    }
    pub fn configure(self: *Store, key: OperationKey, hop: usize, endpoint: Endpoint) !void {
        self.lock();
        defer self.unlock();
        if (!self.matches(key, hop)) return error.StaleOperation;
        const current = &self.hops[hop];
        if (current.configured) {
            if (!std.meta.eql(current.endpoint, endpoint)) return error.InvalidDetailsOwner;
            return;
        }
        current.endpoint = endpoint;
        current.configured = true;
        self.changed();
    }
    pub fn status(self: *Store, key: OperationKey, hop: usize, value: Status) void {
        self.lock();
        defer self.unlock();
        if (!self.matches(key, hop)) return;
        const current = &self.hops[hop];
        if (current.status == value) return;
        current.status = value;
        if (value == .released) {
            if (current.rtt_sample) |*sample| {
                if (sample.status == .ready) sample.status = .stale;
                if (sample.status == .pending) {
                    sample.status = .unavailable;
                    sample.reason = .session_closed;
                }
                sample.cleanup = .released;
            }
            self.slots[hop] = .{};
        }
        self.changed();
    }
    pub fn negotiated(self: *Store, key: OperationKey, hop: usize, metadata: Metadata) void {
        self.lock();
        defer self.unlock();
        if (!self.matches(key, hop)) return;
        self.hops[hop].metadata = metadata;
        self.hops[hop].status = .online;
        self.changed();
    }

    /// Controller calls never wait for a native operation or another thread.
    /// null selects the whole frozen chain; admission is atomic across hops.
    pub fn request(self: *Store, key: OperationKey, selected: ?usize, timeout_ms: u32) !u64 {
        if (timeout_ms == 0) return error.InvalidTimeout;
        if (!self.tryLock()) return error.WorkerBusy;
        defer self.unlock();
        if (self.key == null or !self.key.?.eql(key)) return error.StaleOperation;
        if (selected) |hop| if (hop >= self.hop_count) return error.InvalidHop;
        const first = selected orelse 0;
        const end = if (selected) |hop| hop + 1 else self.hop_count;
        for (first..end) |hop| {
            if (self.hops[hop].status != .online) return error.TransportNotOnline;
            if (self.slots[hop].request != null) return error.SampleBusy;
        }
        if (self.next_request == std.math.maxInt(u64) or self.revision == std.math.maxInt(u64)) return error.SequenceExhausted;
        const id = self.next_request;
        self.next_request += 1;
        for (first..end) |hop| {
            self.slots[hop] = .{ .request = .{ .id = id, .timeout_ms = timeout_ms } };
            self.hops[hop].rtt_sample = .{ .request_id = id };
        }
        self.changed();
        return id;
    }
    pub fn cancel(self: *Store, key: OperationKey, request_id: u64) !void {
        if (!self.tryLock()) return error.WorkerBusy;
        defer self.unlock();
        if (self.key == null or !self.key.?.eql(key)) return error.StaleOperation;
        var found = false;
        for (self.slots[0..self.hop_count]) |*slot| if (slot.request) |*pending| {
            if (pending.id == request_id) {
                pending.cancelled = true;
                found = true;
            }
        };
        if (!found) return error.StaleSample;
    }
    pub fn take(self: *Store, key: OperationKey, hop: usize) ?Request {
        if (!self.tryLock()) return null;
        defer self.unlock();
        if (!self.matches(key, hop)) return null;
        const slot = &self.slots[hop];
        if (slot.taken) return null;
        const value = slot.request orelse return null;
        slot.taken = true;
        return value;
    }
    pub fn cancelled(self: *Store, key: OperationKey, hop: usize, request_id: u64) bool {
        if (!self.tryLock()) return false;
        defer self.unlock();
        if (!self.matches(key, hop)) return true;
        const value = self.slots[hop].request orelse return true;
        return value.id != request_id or value.cancelled;
    }
    pub fn publish(self: *Store, key: OperationKey, hop: usize, sample: Sample, finished: bool) void {
        self.lock();
        defer self.unlock();
        if (!self.matches(key, hop)) return;
        const request_value = self.slots[hop].request orelse return;
        if (request_value.id != sample.request_id) return;
        self.hops[hop].rtt_sample = sample;
        if (finished) self.slots[hop] = .{};
        self.changed();
    }
    pub fn snapshot(self: *Store, key: OperationKey) !ConnectionDetailsSnapshot {
        if (!self.tryLock()) return error.WorkerBusy;
        defer self.unlock();
        if (self.key == null or !self.key.?.eql(key)) return error.StaleOperation;
        var sampled_at: ?i128 = null;
        for (self.hops[0..self.hop_count]) |hop| if (hop.rtt_sample) |sample| if (sample.completed_ns) |end| {
            sampled_at = @max(sampled_at orelse end, end);
        };
        const target = &self.hops[self.hop_count - 1];
        return .{ .key = key, .revision = self.revision, .source = self.source, .hops = self.hops, .hop_count = self.hop_count, .sampled_at = sampled_at, .target_rtt_sample = if (target.status == .online and target.rtt_sample != null and target.rtt_sample.?.status == .ready and target.rtt_sample.?.cleanup == .released) target.rtt_sample else null };
    }
};

test "details copy endpoint metadata and reject stale samples and generations" {
    const key: OperationKey = .{ .owner = .{ .session = .{ .session_id = @fromBackingInt(7) } }, .operation_id = 2, .attempt_id = 1 };
    var store: Store = .{};
    try store.begin(key, 1, .session);
    try store.configure(key, 0, .{ .host = try Text(1024).init("host"), .user = try Text(256).init("operator"), .asset_owner = .{ .id = @fromBackingInt(8), .revision = 3 } });
    store.negotiated(key, 0, .{ .cipher_c2s = try Text(64).init("aes128-ctr") });
    const id = try store.request(key, null, 100);
    try std.testing.expectError(error.SampleBusy, store.request(key, 0, 100));
    try std.testing.expectEqual(id, store.take(key, 0).?.id);
    try std.testing.expect(store.take(key, 0) == null);
    try store.cancel(key, id);
    try std.testing.expect(store.cancelled(key, 0, id));
    store.publish(key, 0, .{ .request_id = id, .started_ns = 100, .completed_ns = 5_000_100, .duration_ms = 5, .status = .ready }, true);
    var snapshot = try store.snapshot(key);
    try std.testing.expectEqualStrings("host", snapshot.hops[0].endpoint.host.slice());
    try std.testing.expectEqual(@as(?u64, 5), snapshot.target_rtt_sample.?.duration_ms);
    store.status(key, 0, .released);
    var next = key;
    next.owner.session.generation += 1;
    next.operation_id += 1;
    next.attempt_id = 2;
    try store.begin(next, 1, .session);
    store.publish(key, 0, .{ .request_id = id, .duration_ms = 999, .status = .ready }, true);
    try std.testing.expectError(error.StaleOperation, store.snapshot(key));
    snapshot = try store.snapshot(next);
    try std.testing.expect(snapshot.target_rtt_sample == null);
    try std.testing.expectEqual(@as(usize, 0), snapshot.hops[0].metadata.cipher_c2s.len);
}

test "released test metadata retains provenance but cannot advertise live RTT" {
    const key: OperationKey = .{ .owner = .app, .operation_id = 4, .attempt_id = 1 };
    var store: Store = .{};
    try store.begin(key, 1, .@"test");
    store.negotiated(key, 0, .{ .fingerprint = try Text(128).init("SHA256:real") });
    const id = try store.request(key, null, 100);
    store.publish(key, 0, .{ .request_id = id, .started_ns = 10, .completed_ns = 1_000_010, .duration_ms = 1, .status = .ready }, true);
    store.status(key, 0, .released);
    const snapshot = try store.snapshot(key);
    try std.testing.expectEqual(Source.@"test", snapshot.source);
    try std.testing.expectEqualStrings("SHA256:real", snapshot.hops[0].metadata.fingerprint.slice());
    try std.testing.expectEqual(.stale, snapshot.hops[0].rtt_sample.?.status);
    try std.testing.expect(snapshot.target_rtt_sample == null);
    try std.testing.expectError(error.TransportNotOnline, store.request(key, 0, 100));
}
