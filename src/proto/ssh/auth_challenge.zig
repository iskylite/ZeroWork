//! Thread-safe challenge bridge used by the SSH worker and UI.
const std = @import("std");
const realtime = @import("../../platform/realtime.zig");
const OperationKey = @import("../../host/operation.zig").OperationKey;
const AssetOwner = @import("../../host/identity.zig").AssetOwner;

pub const Kind = enum { password, private_key_passphrase, keyboard_interactive, host_key_unknown, host_key_changed };
pub const Presentation = enum { otp_modal, protected_form };
pub const State = enum { input, submitting, failed, expired, completed, cancelled };
pub const EndpointIdentity = struct { host: []const u8, port: u16 = 22, user: []const u8 };
pub const PromptKind = @import("auth_prompt.zig").Kind;
pub const Prompt = struct { text: []const u8, echo: bool = false, kind: PromptKind = .generic };
/// One original connection/probe Job owns this for its entire lifetime. Every
/// host-key/auth kind and retry shares the same nonzero request-ID sequence.
pub const RequestCounter = struct {
    value: std.atomic.Value(u64) = .init(0),

    pub fn next(self: *RequestCounter) error{RequestExhausted}!u64 {
        var previous = self.value.load(.acquire);
        while (true) {
            if (previous == std.math.maxInt(u64)) return error.RequestExhausted;
            if (self.value.cmpxchgWeak(previous, previous + 1, .acq_rel, .acquire)) |current| {
                previous = current;
            } else return previous + 1;
        }
    }
};
pub const RequestIdentity = struct {
    key: OperationKey,
    hop_index: usize,
    request_id: u64,

    pub fn eql(self: RequestIdentity, other: RequestIdentity) bool {
        return self.key.eql(other.key) and self.hop_index == other.hop_index and self.request_id == other.request_id;
    }
};

/// Borrowed only during publication. The bridge freezes every value, including
/// the setting revision that chose the keyboard-interactive presentation.
pub const AuthChallenge = struct {
    key: OperationKey,
    source_owner: ?AssetOwner = null,
    hop_index: usize,
    kind: Kind,
    endpoint_identity: EndpointIdentity,
    prompts: []const Prompt,
    expires_at_ns: ?i128 = null,
    presentation: Presentation = .protected_form,
    presentation_config_revision: u64,
};

pub const max_prompts = 16;
const Range = struct { start: usize = 0, len: usize = 0 };
const PromptRange = struct { range: Range = .{}, echo: bool = false, kind: PromptKind = .generic };

/// A value copy with no pointers into the worker or bridge and no response
/// secrets. UI may retain it while switching tabs or saving global settings.
pub const Snapshot = struct {
    identity: RequestIdentity,
    source_owner: ?AssetOwner = null,
    kind: Kind,
    presentation: Presentation,
    presentation_config_revision: u64,
    expires_at_ns: ?i128,
    state: State = .input,
    failure: ?anyerror = null,
    host: [1024]u8 = @splat(0),
    host_len: usize = 0,
    user: [256]u8 = @splat(0),
    user_len: usize = 0,
    port: u16,
    text: [InteractiveBridge.max_prompt]u8 = @splat(0),
    prompt_ranges: [max_prompts]PromptRange = @splat(.{}),
    prompt_count: usize = 0,

    pub fn endpoint(self: *const Snapshot) EndpointIdentity {
        return .{ .host = self.host[0..self.host_len], .port = self.port, .user = self.user[0..self.user_len] };
    }
    pub fn promptAt(self: *const Snapshot, index: usize) Prompt {
        std.debug.assert(index < self.prompt_count);
        const item = self.prompt_ranges[index];
        return .{ .text = self.text[item.range.start..][0..item.range.len], .echo = item.echo, .kind = item.kind };
    }
};

pub const Reply = union(enum) {
    answers: []const []const u8,
    trust_once,
    trust_save,
    /// This is a decision only. The host-key owner must still validate its
    /// frozen public key/store revision and wait for the persistence receipt.
    replace_host_key: []const u8,
};

/// Worker-owned value; call deinit after handing each prompt to the backend.
/// It never borrows the bridge's secret buffer.
pub const Response = struct {
    decision: enum { answers, trust_once, trust_save, replace_host_key } = .answers,
    bytes: [max_prompts * InteractiveBridge.max_answer]u8 = @splat(0),
    ranges: [max_prompts]Range = @splat(.{}),
    count: usize = 0,

    pub fn answerAt(self: *const Response, index: usize) []const u8 {
        std.debug.assert(index < self.count);
        const range = self.ranges[index];
        return self.bytes[range.start..][0..range.len];
    }
    pub fn deinit(self: *Response) void {
        std.crypto.secureZero(u8, &self.bytes);
        self.decision = .answers;
        self.ranges = @splat(.{});
        self.count = 0;
    }
};

const SpinMutex = struct {
    state: std.atomic.Value(bool) = .init(false),
    fn lock(self: *SpinMutex) void {
        while (self.state.swap(true, .acquire)) std.atomic.spinLoopHint();
    }
    fn unlock(self: *SpinMutex) void {
        self.state.store(false, .release);
    }
};

pub const InteractiveBridge = struct {
    mutex: SpinMutex = .{},
    request_counter: ?*RequestCounter = null,
    generation: u64 = 0,
    prompt_buf: [4096]u8 = undefined,
    prompt_len: usize = 0,
    answer_buf: [256]u8 = undefined,
    answer_len: usize = 0,
    pending: bool = false,
    answered: bool = false,
    cancelled: bool = false,
    mode: enum { unused, legacy, scoped } = .unused,
    current: ?Snapshot = null,
    response: Response = .{},
    response_taken: bool = false,
    pub const max_prompt = 4096;
    pub const max_answer = 256;

    pub fn offer(self: *InteractiveBridge, text: []const u8) !u64 {
        if (text.len == 0 or text.len > max_prompt) return error.InvalidChallengePrompt;
        self.mutex.lock();
        defer self.mutex.unlock();
        // A ConnectJob owns one bridge. Cancellation ends that job permanently,
        // including a worker that reaches offer only after shutdown cancelled it.
        if (self.cancelled) return error.Cancelled;
        if (self.mode == .scoped) return error.ChallengeScopeRequired;
        if (self.pending or (self.answered and !self.response_taken)) return error.ChallengeBusy;
        const request_id = try self.nextRequestId();
        self.mode = .legacy;
        @memcpy(self.prompt_buf[0..text.len], text);
        self.prompt_len = text.len;
        self.clearResponse();
        self.pending = true;
        self.answered = false;
        self.generation = request_id;
        return self.generation;
    }
    pub fn wait(self: *InteractiveBridge, generation: u64, timeout_ms: u64) ![]const u8 {
        const deadline = realtime.monotonicNs() + @as(i128, @intCast(timeout_ms)) * std.time.ns_per_ms;
        while (true) {
            self.mutex.lock();
            if (self.mode == .scoped) {
                self.mutex.unlock();
                return error.ChallengeScopeRequired;
            }
            if (self.cancelled or generation != self.generation) {
                self.mutex.unlock();
                return error.Cancelled;
            }
            // The compatibility result is borrowed until the sole worker next
            // offers. Cancellation must not mutate bytes the worker is still
            // copying. New callers use waitResponse's owned value.
            if (self.answered and !self.response_taken) {
                const result = self.answer_buf[0..self.answer_len];
                self.response_taken = true;
                self.mutex.unlock();
                return result;
            }
            if (self.response_taken) {
                self.mutex.unlock();
                return error.ResponseConsumed;
            }
            if (realtime.monotonicNs() >= deadline) {
                self.pending = false;
                self.mutex.unlock();
                return error.ChallengeTimeout;
            }
            self.mutex.unlock();
            std.Thread.yield() catch {};
        }
    }
    pub fn answer(self: *InteractiveBridge, generation: u64, value: []const u8) !void {
        if (value.len == 0 or value.len > max_answer) return error.InvalidChallengeResponse;
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.mode == .scoped) return error.ChallengeScopeRequired;
        if (!self.pending or generation != self.generation or self.cancelled) return error.StaleChallenge;
        @memcpy(self.answer_buf[0..value.len], value);
        self.answer_len = value.len;
        self.answered = true;
        self.pending = false;
    }
    pub fn cancel(self: *InteractiveBridge) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.cancelLocked();
    }
    pub fn pendingNow(self: *InteractiveBridge) bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.expireLocked(realtime.monotonicNs());
        return self.pending;
    }
    pub fn prompt(self: *InteractiveBridge, out: []u8) []const u8 {
        self.mutex.lock();
        defer self.mutex.unlock();
        const n = @min(out.len, self.prompt_len);
        @memcpy(out[0..n], self.prompt_buf[0..n]);
        return out[0..n];
    }

    pub fn offerChallenge(self: *InteractiveBridge, challenge: AuthChallenge) !RequestIdentity {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.cancelled) return error.Cancelled;
        if (self.mode == .legacy) return error.ChallengeScopeRequired;
        const now = realtime.monotonicNs();
        self.expireLocked(now);
        if (self.current) |current| {
            if (!current.identity.key.eql(challenge.key)) return error.ChallengeOwnerMismatch;
            if (challenge.hop_index < current.identity.hop_index) return error.StaleChallenge;
            if (current.state != .completed and current.state != .expired and current.state != .failed) return error.ChallengeBusy;
        }
        // Validate before consuming the shared sequence. The provisional ID is
        // never published; a valid challenge receives its actual Job-wide ID.
        var frozen = try freeze(challenge, .{ .key = challenge.key, .hop_index = challenge.hop_index, .request_id = 1 }, now);
        const identity: RequestIdentity = .{ .key = challenge.key, .hop_index = challenge.hop_index, .request_id = try self.nextRequestId() };
        frozen.identity = identity;
        self.clearResponse();
        self.current = frozen;
        self.generation = identity.request_id;
        self.mode = .scoped;
        self.pending = true;
        self.answered = false;
        return identity;
    }

    pub fn snapshot(self: *InteractiveBridge) ?Snapshot {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.expireLocked(realtime.monotonicNs());
        return self.current;
    }

    /// Exactly one submission is accepted while input/failed. No echo or OTP
    /// shape is inferred: each response belongs to its ordered server prompt.
    pub fn submit(self: *InteractiveBridge, identity: RequestIdentity, reply: Reply) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        const current = try self.currentFor(identity);
        if (current.state != .input and current.state != .failed) return error.StaleChallenge;
        var response: Response = .{};
        defer response.deinit();
        switch (reply) {
            .answers => |answers| {
                if (current.kind == .host_key_unknown or current.kind == .host_key_changed or answers.len != current.prompt_count) return error.InvalidChallengeResponse;
                var offset: usize = 0;
                for (answers, 0..) |value, index| {
                    if (value.len == 0 or value.len > max_answer or std.mem.indexOfScalar(u8, value, 0) != null) return error.InvalidChallengeResponse;
                    @memcpy(response.bytes[offset..][0..value.len], value);
                    response.ranges[index] = .{ .start = offset, .len = value.len };
                    offset += value.len;
                }
                response.count = answers.len;
            },
            .trust_once, .trust_save => {
                if (current.kind != .host_key_unknown) return error.InvalidChallengeResponse;
                response.decision = if (reply == .trust_once) .trust_once else .trust_save;
            },
            .replace_host_key => |confirmation| {
                if (current.kind != .host_key_changed or !std.mem.eql(u8, confirmation, "yes")) return error.InvalidChallengeResponse;
                response.decision = .replace_host_key;
            },
        }
        self.response = response;
        current.state = .submitting;
        current.failure = null;
        self.response_taken = false;
        self.pending = false;
        self.answered = true;
    }

    /// One worker consumes a submission once; in-flight state persists until
    /// complete/reject, so a late callback cannot answer a newer request.
    pub fn waitResponse(self: *InteractiveBridge, identity: RequestIdentity, timeout_ms: u64) !Response {
        return self.waitResponseCancellable(identity, timeout_ms, null);
    }

    pub fn waitResponseCancellable(self: *InteractiveBridge, identity: RequestIdentity, timeout_ms: u64, token: ?*const std.atomic.Value(bool)) !Response {
        const deadline = realtime.monotonicNs() + @as(i128, @intCast(timeout_ms)) * std.time.ns_per_ms;
        while (true) {
            if (token) |cancelled| if (cancelled.load(.acquire)) {
                self.cancel();
                return error.Cancelled;
            };
            self.mutex.lock();
            const current = self.currentFor(identity) catch |err| {
                self.mutex.unlock();
                return err;
            };
            if (current.state == .submitting) {
                if (self.response_taken) {
                    self.mutex.unlock();
                    return error.ResponseConsumed;
                }
                const result = self.response;
                self.response.deinit();
                self.response_taken = true;
                self.mutex.unlock();
                return result;
            }
            if (current.state == .completed) {
                self.mutex.unlock();
                return error.ResponseConsumed;
            }
            if (realtime.monotonicNs() >= deadline) {
                self.expireCurrent();
                self.mutex.unlock();
                return error.ChallengeTimeout;
            }
            self.mutex.unlock();
            var poll_fd: [1]std.c.pollfd = undefined;
            _ = std.c.poll(&poll_fd, 0, 1);
        }
    }

    pub fn complete(self: *InteractiveBridge, identity: RequestIdentity) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        const current = try self.currentFor(identity);
        if (current.state != .submitting or !self.response_taken) return error.InvalidTransition;
        current.state = .completed;
        self.clearResponse();
    }

    /// Backend refusal retains endpoint/prompts/presentation and permits fresh
    /// input. A new request id prevents a duplicate callback for the previous
    /// submission from completing this new input round.
    pub fn reject(self: *InteractiveBridge, identity: RequestIdentity, failure: anyerror) !RequestIdentity {
        self.mutex.lock();
        defer self.mutex.unlock();
        const current = try self.currentFor(identity);
        if (current.state != .submitting or !self.response_taken) return error.InvalidTransition;
        self.generation = try self.nextRequestId();
        current.identity.request_id = self.generation;
        current.state = .failed;
        current.failure = failure;
        self.clearResponse();
        self.pending = true;
        return current.identity;
    }

    pub fn cancelRequest(self: *InteractiveBridge, identity: RequestIdentity) bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        const current = self.current orelse return false;
        if (!current.identity.eql(identity) or self.cancelled) return false;
        self.cancelLocked();
        return true;
    }

    /// Old IO worker must already be parked/joined. Keep the original Job's
    /// counter and consumed IDs while clearing the previous attempt's secrets.
    pub fn resetForAttempt(self: *InteractiveBridge) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.clearResponse();
        self.current = null;
        self.pending = false;
        self.cancelled = false;
        self.mode = .unused;
        self.prompt_len = 0;
    }

    fn nextRequestId(self: *InteractiveBridge) error{RequestExhausted}!u64 {
        if (self.request_counter) |counter| return counter.next();
        if (self.generation == std.math.maxInt(u64)) return error.RequestExhausted;
        return self.generation + 1;
    }

    fn currentFor(self: *InteractiveBridge, identity: RequestIdentity) !*Snapshot {
        if (self.cancelled) return error.Cancelled;
        if (self.current) |*current| {
            if (!current.identity.eql(identity)) return error.StaleChallenge;
            self.expireLocked(realtime.monotonicNs());
            if (current.state == .expired) return error.ChallengeExpired;
            return current;
        }
        return error.StaleChallenge;
    }
    fn clearResponse(self: *InteractiveBridge) void {
        std.crypto.secureZero(u8, &self.answer_buf);
        self.answer_len = 0;
        self.response.deinit();
        self.response_taken = false;
        self.answered = false;
    }
    fn cancelLocked(self: *InteractiveBridge) void {
        self.cancelled = true;
        self.pending = false;
        // Legacy wait returns a borrowed slice. If already handed to its sole
        // worker, retain those bytes until the joined job destroys the bridge;
        // clearing them here would race the caller's compatibility copy.
        if (self.mode == .legacy and self.response_taken) {
            self.response.deinit();
            self.answered = false;
        } else self.clearResponse();
        if (self.current) |*current| current.state = .cancelled;
    }
    fn expireCurrent(self: *InteractiveBridge) void {
        self.pending = false;
        self.clearResponse();
        if (self.current) |*current| current.state = .expired;
    }
    fn expireLocked(self: *InteractiveBridge, now: i128) void {
        if (self.current) |current| {
            if (current.state == .completed or current.state == .cancelled or current.state == .expired) return;
            if (current.expires_at_ns) |expires| if (now >= expires) self.expireCurrent();
        }
    }
};

fn freeze(challenge: AuthChallenge, identity: RequestIdentity, now: i128) !Snapshot {
    if (challenge.key.operation_id == 0 or challenge.key.attempt_id == null or challenge.key.attempt_id == 0 or challenge.presentation_config_revision == 0) return error.InvalidChallengeIdentity;
    const valid_owner = switch (challenge.key.owner) {
        .app => true,
        .session => |owner| @backingInt(owner.session_id) != 0 and owner.generation != 0,
        .asset => |owner| @backingInt(owner.id) != 0 and owner.revision != 0,
        .group => |owner| @backingInt(owner.id) != 0 and owner.revision != 0,
        .history => |owner| @backingInt(owner) != 0,
        .transfer_owner => |owner| @backingInt(owner.id) != 0 and @backingInt(owner.original_handle.session_id) != 0 and owner.original_handle.generation != 0,
    };
    if (!valid_owner) return error.InvalidChallengeIdentity;
    if (challenge.expires_at_ns) |expiry| if (expiry <= now) return error.ChallengeExpired;
    if (challenge.source_owner) |owner| if (@backingInt(owner.id) == 0 or owner.revision == 0) return error.InvalidChallengeIdentity;
    var snapshot: Snapshot = .{ .identity = identity, .source_owner = challenge.source_owner, .kind = challenge.kind, .presentation = challenge.presentation, .presentation_config_revision = challenge.presentation_config_revision, .expires_at_ns = challenge.expires_at_ns, .port = challenge.endpoint_identity.port };
    const endpoint = challenge.endpoint_identity;
    if (endpoint.host.len == 0 or endpoint.host.len > snapshot.host.len or endpoint.user.len == 0 or endpoint.user.len > snapshot.user.len or endpoint.port == 0 or !validText(endpoint.host) or !validText(endpoint.user)) return error.InvalidChallengeEndpoint;
    @memcpy(snapshot.host[0..endpoint.host.len], endpoint.host);
    @memcpy(snapshot.user[0..endpoint.user.len], endpoint.user);
    snapshot.host_len = endpoint.host.len;
    snapshot.user_len = endpoint.user.len;
    switch (challenge.kind) {
        .host_key_unknown, .host_key_changed => if (challenge.prompts.len != 0) return error.InvalidChallengePrompt,
        .password, .private_key_passphrase => if (challenge.prompts.len != 1) return error.InvalidChallengePrompt,
        .keyboard_interactive => if (challenge.prompts.len == 0 or challenge.prompts.len > max_prompts) return error.InvalidChallengePrompt,
    }
    var offset: usize = 0;
    for (challenge.prompts, 0..) |prompt_item, index| {
        if (prompt_item.text.len == 0 or prompt_item.text.len > snapshot.text.len - offset or !validText(prompt_item.text)) return error.InvalidChallengePrompt;
        @memcpy(snapshot.text[offset..][0..prompt_item.text.len], prompt_item.text);
        snapshot.prompt_ranges[index] = .{ .range = .{ .start = offset, .len = prompt_item.text.len }, .echo = prompt_item.echo, .kind = prompt_item.kind };
        offset += prompt_item.text.len;
    }
    snapshot.prompt_count = challenge.prompts.len;
    return snapshot;
}

fn validText(value: []const u8) bool {
    return std.unicode.utf8ValidateSlice(value) and std.mem.indexOfScalar(u8, value, 0) == null;
}

test "interactive bridge answer completes wait" {
    var bridge = InteractiveBridge{};
    const generation = try bridge.offer("Password:");
    try bridge.answer(generation, "secret");
    try std.testing.expectEqualStrings("secret", try bridge.wait(generation, 100));
    const next = try bridge.offer("OTP:");
    try bridge.answer(next, "123456");
    try std.testing.expectEqualStrings("123456", try bridge.wait(next, 100));
}
test "interactive bridge rejects stale and cancellation" {
    var bridge = InteractiveBridge{};
    const generation = try bridge.offer("OTP:");
    try std.testing.expectError(error.StaleChallenge, bridge.answer(generation + 1, "1"));
    bridge.cancel();
    try std.testing.expectError(error.Cancelled, bridge.wait(generation, 100));
}

test "cancelled challenge cannot be reopened before its worker waits" {
    var bridge = InteractiveBridge{};
    const generation = try bridge.offer("OTP:");
    bridge.cancel();
    try std.testing.expectError(error.Cancelled, bridge.offer("Password:"));
    try std.testing.expectEqual(generation, bridge.generation);
    try std.testing.expect(!bridge.pendingNow());
    try std.testing.expectError(error.Cancelled, bridge.wait(generation, 60_000));
    try std.testing.expectError(error.StaleChallenge, bridge.answer(generation, "late"));
}

test "shutdown cancellation wins before a delayed worker offers its first challenge" {
    const Worker = struct {
        bridge: *InteractiveBridge,
        proceed: std.atomic.Value(bool) = .init(false),
        failure: ?anyerror = null,
        generation: ?u64 = null,

        fn run(self: *@This()) void {
            while (!self.proceed.load(.acquire)) std.atomic.spinLoopHint();
            self.generation = self.bridge.offer("OTP:") catch |err| {
                self.failure = err;
                return;
            };
        }
    };
    var bridge = InteractiveBridge{};
    var worker: Worker = .{ .bridge = &bridge };
    const thread = try std.Thread.spawn(.{}, Worker.run, .{&worker});
    bridge.cancel();
    worker.proceed.store(true, .release);
    thread.join();
    try std.testing.expectEqual(error.Cancelled, worker.failure.?);
    try std.testing.expect(worker.generation == null);
    try std.testing.expectEqual(@as(u64, 0), bridge.generation);
    try std.testing.expect(!bridge.pendingNow());
    try std.testing.expectError(error.Cancelled, bridge.wait(0, 60_000));
}
