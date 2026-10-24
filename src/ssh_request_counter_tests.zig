const std = @import("std");
const auth = @import("proto/ssh/auth_challenge.zig");
const host_key = @import("ui/host_key_confirmation.zig");
const ssh = @import("proto/ssh/session.zig");
const operation = @import("host/operation.zig");

const key: operation.OperationKey = .{ .owner = .app, .operation_id = 91, .attempt_id = 1 };
fn password(operation_key: operation.OperationKey) auth.AuthChallenge {
    return .{ .key = operation_key, .hop_index = 0, .kind = .password, .endpoint_identity = .{ .host = "fixture", .user = "operator" }, .prompts = &.{.{ .text = "Password:" }}, .presentation_config_revision = 1 };
}

const HostOffer = struct {
    bridge: *host_key.Bridge,
    decision: ssh.HostKeyDecision = .reject_unknown,
    fn run(self: *@This()) void {
        self.decision = host_key.Bridge.observer(self.bridge, "fixture", 22, .{ .algorithm = "ssh-ed25519", .fingerprint = "SHA256:fixture", .operation_key = key, .hop_index = 0 });
    }
};

test "request counter gives host trust password retry and next host distinct same-key identities" {
    var counter: auth.RequestCounter = .{};
    var host = host_key.Bridge.init();
    host.request_counter = &counter;
    var input: auth.InteractiveBridge = .{ .request_counter = &counter };
    var offered: HostOffer = .{ .bridge = &host };
    const thread = try std.Thread.spawn(.{}, HostOffer.run, .{&offered});
    var joined = false;
    defer if (!joined) {
        host.cancel();
        thread.join();
    };
    while (!host.pending()) std.Thread.yield() catch {};
    const host_request = host.snapshot().?;
    const trust_id: auth.RequestIdentity = .{ .key = key, .hop_index = 0, .request_id = host_request.generation };
    try std.testing.expectEqual(@as(u64, 1), trust_id.request_id);
    try std.testing.expect(host.decideScoped(trust_id, .trust_once));
    thread.join();
    joined = true;
    try std.testing.expectEqual(ssh.HostKeyDecision.trust_once, offered.decision);

    const password_id = try input.offerChallenge(password(key));
    try std.testing.expectEqual(@as(u64, 2), password_id.request_id);
    try std.testing.expect(!trust_id.eql(password_id));
    try std.testing.expectEqual(auth.Kind.password, input.snapshot().?.kind);
    try std.testing.expectEqual(auth.State.input, input.snapshot().?.state);
    try std.testing.expectError(error.StaleChallenge, input.submit(trust_id, .{ .answers = &.{"old"} }));
    try input.submit(password_id, .{ .answers = &.{"fixture"} });
    var response = try input.waitResponse(password_id, 100);
    defer response.deinit();
    const retry = try input.reject(password_id, error.AuthenticationFailed);
    try std.testing.expectEqual(@as(u64, 3), retry.request_id);
    try input.submit(retry, .{ .answers = &.{"fixture-retry"} });
    var next = try input.waitResponse(retry, 100);
    defer next.deinit();
    try input.complete(retry);

    var offered_again: HostOffer = .{ .bridge = &host };
    const next_thread = try std.Thread.spawn(.{}, HostOffer.run, .{&offered_again});
    var next_joined = false;
    defer if (!next_joined) {
        host.cancel();
        next_thread.join();
    };
    while (!host.pending()) std.Thread.yield() catch {};
    const next_host = host.snapshot().?;
    try std.testing.expectEqual(@as(u64, 4), next_host.generation);
    try std.testing.expect(!host.decideScoped(trust_id, .trust_once));
    try std.testing.expect(host.decideScoped(.{ .key = key, .hop_index = 0, .request_id = next_host.generation }, .trust_once));
    next_thread.join();
    next_joined = true;
}

test "request counter survives bridge attempt resets and rejects old responses" {
    var counter: auth.RequestCounter = .{};
    var input: auth.InteractiveBridge = .{ .request_counter = &counter };
    const old = try input.offerChallenge(password(key));
    input.cancel();
    input.resetForAttempt();
    try std.testing.expectEqual(@as(?*auth.RequestCounter, &counter), input.request_counter);
    try std.testing.expectEqual(old.request_id, input.generation);
    var next_key = key;
    next_key.operation_id += 1;
    next_key.attempt_id = 2;
    const current = try input.offerChallenge(password(next_key));
    try std.testing.expectEqual(@as(u64, 2), current.request_id);
    try std.testing.expectError(error.StaleChallenge, input.submit(old, .{ .answers = &.{"late"} }));
    var host = host_key.Bridge.init();
    host.request_counter = &counter;
    host.cancel();
    host.reset();
    try std.testing.expectEqual(@as(?*auth.RequestCounter, &counter), host.request_counter);
    try std.testing.expectEqual(@as(u64, 3), try host.request_counter.?.next());
    input.cancel();
}

test "request counter atomic allocations are unique across simultaneous bridges" {
    const Allocator = struct {
        counter: *auth.RequestCounter,
        values: [64]u64 = undefined,
        fn run(self: *@This()) void {
            for (&self.values) |*value| value.* = self.counter.next() catch unreachable;
        }
    };
    var counter: auth.RequestCounter = .{};
    var first: Allocator = .{ .counter = &counter };
    var second: Allocator = .{ .counter = &counter };
    const first_thread = try std.Thread.spawn(.{}, Allocator.run, .{&first});
    const second_thread = try std.Thread.spawn(.{}, Allocator.run, .{&second});
    first_thread.join();
    second_thread.join();
    var seen: [128]bool = @splat(false);
    for ([_][]const u64{ &first.values, &second.values }) |values| for (values) |value| {
        try std.testing.expect(value != 0 and value <= seen.len);
        try std.testing.expect(!seen[value - 1]);
        seen[value - 1] = true;
    };
    for (seen) |value| try std.testing.expect(value);
    try std.testing.expectEqual(@as(u64, 129), try counter.next());
}

test "request counter exhaustion never wraps or publishes a duplicate identity" {
    var counter: auth.RequestCounter = .{};
    counter.value.store(std.math.maxInt(u64) - 1, .release);
    var input: auth.InteractiveBridge = .{ .request_counter = &counter };
    const last = try input.offerChallenge(password(key));
    try std.testing.expectEqual(std.math.maxInt(u64), last.request_id);
    try std.testing.expectError(error.RequestExhausted, counter.next());
    var another: auth.InteractiveBridge = .{ .request_counter = &counter };
    try std.testing.expectError(error.RequestExhausted, another.offerChallenge(password(key)));
    try std.testing.expect(another.snapshot() == null);
    var host = host_key.Bridge.init();
    host.request_counter = &counter;
    try std.testing.expectEqual(ssh.HostKeyDecision.reject_unknown, host_key.Bridge.observer(&host, "fixture", 22, .{ .algorithm = "ssh-ed25519", .fingerprint = "SHA256:fixture" }));
    try std.testing.expect(!host.pending());
    try std.testing.expectEqual(@as(u64, 0), host.generation.load(.acquire));
    try std.testing.expectEqual(std.math.maxInt(u64), counter.value.load(.acquire));
    input.cancel();
}

test {
    _ = @import("ssh_auth_challenge_tests.zig");
    _ = host_key;
}
