//! Thread-safe host-key confirmation bridge.
//!
//! The SSH worker invokes `observer` after the real handshake has produced a
//! fingerprint.  The callback publishes an owned, bounded snapshot and waits
//! for the UI to decide.  No decision (including a closed modal) is treated as
//! acceptance: the callback returns `reject_unknown` on cancel/timeout.
const std = @import("std");
const ssh = @import("../proto/ssh/session.zig");
const RequestCounter = @import("../proto/ssh/auth_challenge.zig").RequestCounter;

pub const State = enum(u8) { idle, pending, trust_once, trust_save, trust_changed_yes, reject };

pub const Request = struct {
    generation: u64 = 0,
    operation_key: ?@import("../host/operation.zig").OperationKey = null,
    hop_index: usize = 0,
    source_owner: ?@import("../host/identity.zig").AssetOwner = null,
    store_path: [4096]u8 = undefined,
    store_path_len: usize = 0,
    old_algorithm: [64]u8 = undefined,
    old_algorithm_len: usize = 0,
    old_fingerprint: [192]u8 = undefined,
    old_fingerprint_len: usize = 0,
    host: [1024]u8 = undefined,
    host_len: usize = 0,
    port: u16 = 0,
    algorithm: [64]u8 = undefined,
    algorithm_len: usize = 0,
    fingerprint: [192]u8 = undefined,
    fingerprint_len: usize = 0,
    status: ssh.HostKeyStatus = .unknown,

    pub fn hostSlice(self: *const Request) []const u8 {
        return self.host[0..self.host_len];
    }
    pub fn algorithmSlice(self: *const Request) []const u8 {
        return self.algorithm[0..self.algorithm_len];
    }
    pub fn fingerprintSlice(self: *const Request) []const u8 {
        return self.fingerprint[0..self.fingerprint_len];
    }
};

pub const Bridge = struct {
    state: std.atomic.Value(u8) = .init(@backingInt(State.idle)),
    generation: std.atomic.Value(u64) = .init(0),
    request_counter: ?*RequestCounter = null,
    request: Request = .{},
    request_lock: SpinLock = .{},
    cancelled: std.atomic.Value(bool) = .init(false),

    const SpinLock = struct {
        held: std.atomic.Value(bool) = .init(false),
        fn lock(self: *SpinLock) void {
            while (self.held.swap(true, .acquire)) std.atomic.spinLoopHint();
        }
        fn unlock(self: *SpinLock) void {
            self.held.store(false, .release);
        }
    };

    pub fn init() Bridge {
        return .{};
    }

    /// Callback suitable for `ssh.HostKeyObserver.callback`.
    pub fn observer(raw: *anyopaque, host: []const u8, port: u16, info: ssh.HostKeyInfo) ssh.HostKeyDecision {
        const self: *Bridge = @ptrCast(@alignCast(raw));
        return self.offer(host, port, info);
    }

    fn offer(self: *Bridge, host: []const u8, port: u16, info: ssh.HostKeyInfo) ssh.HostKeyDecision {
        if (self.cancelled.load(.acquire)) return .reject_unknown;
        // Identity and fingerprints must be complete; never ask the user to
        // approve a truncated endpoint, fingerprint, or trust-store path.
        if (host.len > 1024 or info.algorithm.len > 64 or info.fingerprint.len > 192 or (info.store_path orelse @as([]const u8, "")).len > 4096) return .reject_unknown;
        self.request_lock.lock();
        const generation = if (self.request_counter) |counter| counter.next() catch {
            self.request_lock.unlock();
            return .reject_unknown;
        } else blk: {
            const current = self.generation.load(.acquire);
            if (current == std.math.maxInt(u64)) {
                self.request_lock.unlock();
                return .reject_unknown;
            }
            break :blk current + 1;
        };
        self.generation.store(generation, .release);
        self.request = .{ .generation = generation, .port = port, .status = info.status, .operation_key = info.operation_key, .hop_index = info.hop_index, .source_owner = info.source_owner };
        self.request.store_path_len = copyBounded(&self.request.store_path, info.store_path orelse @as([]const u8, ""));
        if (info.verification) |checked| if (checked.old_key) |old| {
            const old_fingerprint = old.fingerprint();
            self.request.old_algorithm_len = copyBounded(&self.request.old_algorithm, @tagName(old.algorithm));
            self.request.old_fingerprint_len = copyBounded(&self.request.old_fingerprint, old_fingerprint.slice());
        };
        self.request.host_len = copyBounded(&self.request.host, host);
        self.request.algorithm_len = copyBounded(&self.request.algorithm, info.algorithm);
        self.request.fingerprint_len = copyBounded(&self.request.fingerprint, info.fingerprint);
        self.state.store(@backingInt(State.pending), .release);
        self.request_lock.unlock();
        // Release the lock before waiting; UI reads only after acquire and
        // decides through the atomic state.  Cancellation is polled in short
        // intervals so closing the app never strands a worker thread.
        // (The lock is intentionally scoped above only for publication.)
        while (true) {
            const current = @as(State, @fromBackingInt(@intCast(self.state.load(.acquire))));
            switch (current) {
                .trust_once => return .trust_once,
                .trust_save => return .trust_save,
                .trust_changed_yes => return .trust_changed_yes,
                .reject, .idle => return .reject_unknown,
                .pending => {},
            }
            if (self.cancelled.load(.acquire)) {
                self.state.store(@backingInt(State.reject), .release);
                return .reject_unknown;
            }
            // A prompt may remain open for minutes. Do not busy-spin a CPU
            // core while the UI waits for a user decision.
            var wait_fd: [1]std.c.pollfd = undefined;
            _ = std.c.poll(&wait_fd, 0, 10);
        }
    }

    fn copyBounded(dst: []u8, src: []const u8) usize {
        const n = @min(dst.len, src.len);
        @memcpy(dst[0..n], src[0..n]);
        return n;
    }

    pub fn pending(self: *const Bridge) bool {
        return @as(State, @fromBackingInt(@intCast(self.state.load(.acquire)))) == .pending;
    }

    pub fn snapshot(self: *Bridge) ?Request {
        if (!self.pending()) return null;
        self.request_lock.lock();
        defer self.request_lock.unlock();
        if (!self.pending()) return null;
        return self.request;
    }

    /// Display-only metadata survives trust acceptance for the following auth
    /// challenge. Decisions must still use the pending, scoped request.
    pub fn lastSnapshot(self: *Bridge) ?Request {
        self.request_lock.lock();
        defer self.request_lock.unlock();
        if (self.request.generation == 0) return null;
        return self.request;
    }

    pub fn decide(self: *Bridge, generation: u64, decision: ssh.HostKeyDecision) bool {
        // Changed fingerprints require the dedicated literal-yes path below;
        // keeping this generic method unable to produce that state prevents a
        // first-connect button or stale caller from silently accepting a MITM.
        if (decision == .trust_changed_yes) return false;
        self.request_lock.lock();
        defer self.request_lock.unlock();
        if (self.request.operation_key != null or self.request.generation != generation or !self.pending()) return false;
        // A changed key can only leave the pending state via
        // decideChangedYes("yes"). Generic trust buttons are rejected.
        if (self.request.status == .changed and decision != .reject_unknown) return false;
        self.state.store(@backingInt(switch (decision) {
            .trust_once => State.trust_once,
            .trust_save => State.trust_save,
            .trust_changed_yes => State.trust_changed_yes,
            .reject_unknown => State.reject,
        }), .release);
        return true;
    }

    /// Explicit changed-key acknowledgement. The UI must pass the literal
    /// ASCII word `yes`; any other spelling, whitespace, or casing rejects.
    pub fn decideChangedYes(self: *Bridge, generation: u64, confirmation: []const u8) bool {
        if (!std.mem.eql(u8, confirmation, "yes")) return false;
        self.request_lock.lock();
        defer self.request_lock.unlock();
        if (self.request.operation_key != null or self.request.generation != generation or !self.pending() or self.request.status != .changed) return false;
        self.state.store(@backingInt(State.trust_changed_yes), .release);
        return true;
    }

    /// New runtime requests require the complete operation/hop/request tuple.
    pub fn decideScoped(self: *Bridge, identity: @import("../proto/ssh/auth_challenge.zig").RequestIdentity, reply: @import("../proto/ssh/auth_challenge.zig").Reply) bool {
        self.request_lock.lock();
        defer self.request_lock.unlock();
        const key = self.request.operation_key orelse return false;
        if (!self.pending() or !key.eql(identity.key) or self.request.hop_index != identity.hop_index or self.request.generation != identity.request_id) return false;
        const next: State = switch (reply) {
            .answers => return false,
            .trust_once => if (self.request.status == .unknown) .trust_once else return false,
            .trust_save => if (self.request.status == .unknown) .trust_save else return false,
            .replace_host_key => |word| if (self.request.status == .changed and std.mem.eql(u8, word, "yes")) .trust_changed_yes else return false,
        };
        self.state.store(@backingInt(next), .release);
        return true;
    }

    /// Called when the modal is dismissed, the session is closed, or the
    /// workspace is torn down. It always wakes a waiting observer as reject.
    pub fn cancel(self: *Bridge) void {
        self.cancelled.store(true, .release);
        self.state.store(@backingInt(State.reject), .release);
    }

    pub fn reset(self: *Bridge) void {
        self.cancelled.store(false, .release);
        self.state.store(@backingInt(State.idle), .release);
    }
};

test "host key observer publishes real request and accepts once" {
    var bridge = Bridge.init();
    var thread = try std.Thread.spawn(.{}, struct {
        fn run(b: *Bridge) void {
            const decision = Bridge.observer(@ptrCast(b), "target.example", 2222, .{ .algorithm = "ssh-ed25519", .fingerprint = "SHA256:abc" });
            std.testing.expectEqual(ssh.HostKeyDecision.trust_once, decision) catch unreachable;
        }
    }.run, .{&bridge});
    while (!bridge.pending()) std.Thread.yield() catch {};
    const req = bridge.snapshot().?;
    try std.testing.expectEqualStrings("target.example", req.hostSlice());
    try std.testing.expectEqual(@as(u16, 2222), req.port);
    try std.testing.expect(bridge.decide(req.generation, .trust_once));
    thread.join();
}

test "host key observer cancel rejects and stale generation cannot decide" {
    var bridge = Bridge.init();
    var thread = try std.Thread.spawn(.{}, struct {
        fn run(b: *Bridge) void {
            const decision = Bridge.observer(@ptrCast(b), "target", 22, .{ .algorithm = "rsa", .fingerprint = "SHA256:x" });
            std.testing.expectEqual(ssh.HostKeyDecision.reject_unknown, decision) catch unreachable;
        }
    }.run, .{&bridge});
    while (!bridge.pending()) std.Thread.yield() catch {};
    const req = bridge.snapshot().?;
    try std.testing.expect(!bridge.decide(req.generation - 1, .trust_save));
    bridge.cancel();
    thread.join();
    try std.testing.expect(!bridge.pending());
}

test "host key reconnect requires a fresh generation and rejects stale acceptance" {
    var bridge = Bridge.init();
    const Runner = struct {
        fn run(b: *Bridge, expected: ssh.HostKeyDecision) void {
            const decision = Bridge.observer(@ptrCast(b), "target", 22, .{ .algorithm = "ssh-ed25519", .fingerprint = "SHA256:real-handshake-value" });
            std.testing.expectEqual(expected, decision) catch unreachable;
        }
    };
    var first = try std.Thread.spawn(.{}, Runner.run, .{ &bridge, ssh.HostKeyDecision.trust_once });
    while (!bridge.pending()) std.Thread.yield() catch {};
    const generation = bridge.snapshot().?.generation;
    try std.testing.expect(bridge.decide(generation, .trust_once));
    first.join();
    var second = try std.Thread.spawn(.{}, Runner.run, .{ &bridge, ssh.HostKeyDecision.reject_unknown });
    while (!bridge.pending()) std.Thread.yield() catch {};
    try std.testing.expect(!bridge.decide(generation, .trust_once));
    try std.testing.expect(bridge.decide(bridge.snapshot().?.generation, .reject_unknown));
    second.join();
}

test "changed fingerprint never accepts trust_once and requires literal yes" {
    var bridge = Bridge.init();
    var thread = try std.Thread.spawn(.{}, struct {
        fn run(b: *Bridge) void {
            const decision = Bridge.observer(@ptrCast(b), "target", 22, .{
                .algorithm = "ssh-ed25519",
                .fingerprint = "SHA256:new",
                .status = .changed,
            });
            std.testing.expectEqual(ssh.HostKeyDecision.trust_changed_yes, decision) catch unreachable;
        }
    }.run, .{&bridge});
    while (!bridge.pending()) std.Thread.yield() catch {};
    const req = bridge.snapshot().?;
    try std.testing.expectEqual(ssh.HostKeyStatus.changed, req.status);
    try std.testing.expect(!bridge.decide(req.generation, .trust_once));
    try std.testing.expect(!bridge.decideChangedYes(req.generation, "YES"));
    try std.testing.expect(!bridge.decideChangedYes(req.generation, " yes"));
    try std.testing.expect(bridge.decideChangedYes(req.generation, "yes"));
    thread.join();
}

test "host key decision binds operation hop and request without legacy bypass" {
    var bridge = Bridge.init();
    const key: @import("../host/operation.zig").OperationKey = .{ .owner = .app, .operation_id = 39, .attempt_id = 2 };
    var observed: ssh.HostKeyDecision = .reject_unknown;
    var joined = false;
    const thread = try std.Thread.spawn(.{}, struct {
        fn run(b: *Bridge, operation: @import("../host/operation.zig").OperationKey, result: *ssh.HostKeyDecision) void {
            result.* = Bridge.observer(b, "hop.test", 2222, .{
                .algorithm = "ssh-ed25519",
                .fingerprint = "SHA256:received",
                .operation_key = operation,
                .hop_index = 1,
                .store_path = "/isolated/known_hosts",
            });
        }
    }.run, .{ &bridge, key, &observed });
    defer {
        if (!joined) {
            bridge.cancel();
            thread.join();
        }
    }
    while (!bridge.pending()) std.Thread.yield() catch {};
    const request = bridge.snapshot().?;
    try std.testing.expectEqualStrings("/isolated/known_hosts", request.store_path[0..request.store_path_len]);
    try std.testing.expect(!bridge.decide(request.generation, .trust_once));
    var reply: @import("../proto/ssh/auth_challenge.zig").RequestIdentity = .{ .key = key, .hop_index = 0, .request_id = request.generation };
    try std.testing.expect(!bridge.decideScoped(reply, .trust_once));
    reply.hop_index = 1;
    reply.key.operation_id += 1;
    try std.testing.expect(!bridge.decideScoped(reply, .trust_once));
    reply.key = key;
    try std.testing.expect(bridge.decideScoped(reply, .trust_once));
    thread.join();
    joined = true;
    try std.testing.expectEqual(ssh.HostKeyDecision.trust_once, observed);
    try std.testing.expect(bridge.snapshot() == null);
    try std.testing.expectEqual(request.generation, bridge.lastSnapshot().?.generation);
    try std.testing.expect(!bridge.decideScoped(reply, .trust_once));
}
