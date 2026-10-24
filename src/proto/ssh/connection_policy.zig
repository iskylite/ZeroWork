const std = @import("std");
const Hop = @import("hop_plan.zig").Hop;
const Plan = @import("hop_plan.zig").Plan;

/// The same OpenSSH store is shared by every hop; it never stores credentials.
pub const HostKeyStore = @import("host_key_store.zig").HostKeyStore;

pub const AuthMethod = enum { agent, private_key, password, keyboard_interactive };
pub const AuthState = enum { pending, partial, authenticated, rejected };

/// Per-hop authentication state. Partial success keeps completed methods and
/// advances to the next method instead of restarting the hop.
pub const AuthMachine = struct {
    state: AuthState = .pending,
    completed: std.EnumSet(AuthMethod) = .init(.{}),
    attempted: std.EnumSet(AuthMethod) = .init(.{}),
    next_index: usize = 0,
    methods: []const AuthMethod = &default_methods,
    in_flight: ?AuthMethod = null,
    remaining: ?std.EnumSet(AuthMethod) = null,
    pub const default_methods = [_]AuthMethod{ .agent, .private_key, .password, .keyboard_interactive };

    pub fn next(self: *AuthMachine) ?AuthMethod {
        if (self.state == .authenticated or self.state == .rejected or self.in_flight != null) return null;
        while (self.next_index < self.methods.len) : (self.next_index += 1) {
            const method = self.methods[self.next_index];
            if (self.remaining) |remaining| if (!remaining.contains(method)) continue;
            if (!self.completed.contains(method) and !self.attempted.contains(method)) {
                self.next_index += 1;
                self.in_flight = method;
                self.attempted.insert(method);
                return method;
            }
        }
        self.state = .rejected;
        return null;
    }
    pub fn result(self: *AuthMachine, method: AuthMethod, outcome: Outcome) !void {
        if (self.state == .authenticated or self.state == .rejected or self.in_flight != method) return error.InvalidTransition;
        switch (outcome) {
            .success => {
                self.completed.insert(method);
                self.state = .authenticated;
            },
            .partial => {
                self.completed.insert(method);
                self.state = .partial;
            },
            .failure => {
                self.state = if (self.next_index >= self.methods.len) .rejected else if (self.completed.count() != 0) .partial else .pending;
            },
        }
        self.in_flight = null;
    }
    /// The backend supplies the server's remaining methods after PARTIAL.
    /// Freeze the set by value; never clear methods already accepted this hop.
    /// This does not query libssh2 or imply live PARTIAL support by itself.
    pub fn resultWithRemaining(self: *AuthMachine, method: AuthMethod, outcome: Outcome, methods: []const AuthMethod) !void {
        try self.result(method, outcome);
        var remaining = std.EnumSet(AuthMethod).init(.{});
        for (methods) |item| remaining.insert(item);
        self.remaining = remaining;
        if (outcome != .success) {
            self.next_index = 0;
            self.state = if (self.completed.count() != 0) .partial else .pending;
        }
    }
    pub const Outcome = enum { success, partial, failure };
};

/// UI-independent keyboard-interactive challenge state.  The live libssh2
/// callback is wired separately; this object prevents a caller from treating
/// an unanswered OTP prompt as authentication success and rejects stale
/// responses from a previous hop or retry.
pub const InteractiveChallenge = struct {
    /// libssh2 keyboard-interactive prompts are untrusted server input. Keep
    /// the bridge bounded even before a live callback is wired, so a malicious
    /// server cannot force an unbounded allocation on the UI side.
    pub const max_prompt_bytes: usize = 4096;
    pub const max_response_bytes: usize = 256;
    allocator: std.mem.Allocator,
    generation: u64 = 0,
    prompt: []u8 = &.{},
    pending: bool = false,
    cancelled: bool = false,

    pub fn init(allocator: std.mem.Allocator) InteractiveChallenge {
        return .{ .allocator = allocator };
    }
    pub fn deinit(self: *InteractiveChallenge) void {
        if (self.prompt.len != 0) self.allocator.free(self.prompt);
        self.* = undefined;
    }
    pub fn offer(self: *InteractiveChallenge, prompt: []const u8) !u64 {
        if (prompt.len == 0 or prompt.len > max_prompt_bytes) return error.InvalidChallengePrompt;
        if (self.prompt.len != 0) self.allocator.free(self.prompt);
        self.prompt = try self.allocator.dupe(u8, prompt);
        self.generation +%= 1;
        self.pending = true;
        self.cancelled = false;
        return self.generation;
    }
    pub fn answer(self: *InteractiveChallenge, generation: u64, value: []const u8) ![]u8 {
        if (!self.pending or self.cancelled or generation != self.generation) return error.StaleChallenge;
        if (value.len == 0 or value.len > max_response_bytes) return error.InvalidChallengeResponse;
        self.pending = false;
        return self.allocator.dupe(u8, value);
    }
    pub fn cancel(self: *InteractiveChallenge) void {
        self.cancelled = true;
        self.pending = false;
    }
};

pub const ProxyJump = struct {
    plan: Plan,
    pub const Edge = struct { from: Hop, to: Hop };
    pub fn init(plan: Plan) !ProxyJump {
        try plan.validate();
        return .{ .plan = plan };
    }
    pub fn edge(self: ProxyJump, index: usize) !Edge {
        if (index >= self.plan.hops.len - 1) return error.NoJump;
        return .{ .from = self.plan.hops[index], .to = self.plan.hops[index + 1] };
    }
    pub fn edgeCount(self: ProxyJump) usize {
        return self.plan.hops.len - 1;
    }
};

test "auth machine preserves partial progress and order" {
    var auth = AuthMachine{};
    try std.testing.expectEqual(AuthMethod.agent, auth.next().?);
    try auth.result(.agent, .partial);
    try std.testing.expectEqual(AuthMethod.private_key, auth.next().?);
    try auth.result(.private_key, .success);
    try std.testing.expectEqual(AuthState.authenticated, auth.state);
    try std.testing.expect(auth.next() == null);
}

test "interactive challenge rejects stale and cancelled answers" {
    var challenge = InteractiveChallenge.init(std.testing.allocator);
    defer challenge.deinit();
    const generation = try challenge.offer("Verification code");
    try std.testing.expectError(error.StaleChallenge, challenge.answer(generation - 1, "123456"));
    const answer = try challenge.answer(generation, "123456");
    defer std.testing.allocator.free(answer);
    try std.testing.expectEqualStrings("123456", answer);
    const next = try challenge.offer("Verification code");
    challenge.cancel();
    try std.testing.expectError(error.StaleChallenge, challenge.answer(next, "123456"));
}

test "interactive challenge bounds untrusted prompt and response" {
    var challenge = InteractiveChallenge.init(std.testing.allocator);
    defer challenge.deinit();
    var oversized_prompt: [InteractiveChallenge.max_prompt_bytes + 1]u8 = undefined;
    @memset(&oversized_prompt, 'x');
    try std.testing.expectError(error.InvalidChallengePrompt, challenge.offer(&oversized_prompt));
    const generation = try challenge.offer("Verification code:");
    var oversized_response: [InteractiveChallenge.max_response_bytes + 1]u8 = undefined;
    @memset(&oversized_response, '1');
    try std.testing.expectError(error.InvalidChallengeResponse, challenge.answer(generation, &oversized_response));
    // A rejected response leaves the challenge pending; only a valid answer
    // transitions it, and no implicit success is possible.
    try std.testing.expect(challenge.pending);
    const answer = try challenge.answer(generation, "123456");
    defer std.testing.allocator.free(answer);
    try std.testing.expect(!challenge.pending);
}

test "proxy jump exposes direct tcpip edges" {
    const hops = [_]Hop{ .{ .host = "a", .user = "u" }, .{ .host = "b", .user = "u" }, .{ .host = "c", .user = "u" } };
    const jump = try ProxyJump.init(.{ .hops = &hops });
    const e = try jump.edge(1);
    try std.testing.expectEqualStrings("b", e.from.host);
    try std.testing.expectEqualStrings("c", e.to.host);
    try std.testing.expectError(error.NoJump, jump.edge(2));
}
