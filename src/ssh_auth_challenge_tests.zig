const std = @import("std");
const auth = @import("proto/ssh/auth_challenge.zig");
const policy = @import("proto/ssh/connection_policy.zig");
const realtime = @import("platform/realtime.zig");

fn challenge(kind: auth.Kind) auth.AuthChallenge {
    return .{
        .key = .{ .owner = .{ .session = .{ .session_id = @fromBackingInt(7), .generation = 2 } }, .operation_id = 11, .attempt_id = 3 },
        .hop_index = 1,
        .kind = kind,
        .endpoint_identity = .{ .host = "bastion.example", .user = "operator", .port = 2222 },
        .prompts = if (kind == .host_key_unknown or kind == .host_key_changed) &.{} else &.{.{ .text = "Verification code:", .echo = false }},
        .presentation = .protected_form,
        .presentation_config_revision = 12,
    };
}

test "auth challenge freezes each kind and protected form identity independently of source memory" {
    for (std.enums.values(auth.Kind)) |kind| {
        var bridge: auth.InteractiveBridge = .{};
        var request = challenge(kind);
        var host = "bastion.example".*;
        var user = "operator".*;
        var text = "Verification code:".*;
        var prompts = [_]auth.Prompt{.{ .text = &text, .echo = true }};
        request.endpoint_identity.host = &host;
        request.endpoint_identity.user = &user;
        if (request.prompts.len != 0) request.prompts = &prompts;
        const id = try bridge.offerChallenge(request);
        @memset(&host, 'x');
        @memset(&user, 'x');
        @memset(&text, 'x');
        prompts[0].echo = false;
        request.presentation = .otp_modal;
        request.presentation_config_revision = 99;
        const snapshot = bridge.snapshot().?;
        try std.testing.expect(snapshot.identity.eql(id));
        try std.testing.expectEqual(kind, snapshot.kind);
        try std.testing.expectEqualStrings("bastion.example", snapshot.endpoint().host);
        try std.testing.expectEqualStrings("operator", snapshot.endpoint().user);
        try std.testing.expectEqual(@as(u16, 2222), snapshot.endpoint().port);
        try std.testing.expectEqual(auth.Presentation.protected_form, snapshot.presentation);
        try std.testing.expectEqual(@as(u64, 12), snapshot.presentation_config_revision);
        if (snapshot.prompt_count != 0) {
            try std.testing.expectEqualStrings("Verification code:", snapshot.promptAt(0).text);
            try std.testing.expect(snapshot.promptAt(0).echo);
        }
        bridge.cancel();
        // A retained UI snapshot is a value, unaffected by bridge mutation.
        try std.testing.expectEqual(auth.State.input, snapshot.state);
        try std.testing.expectEqualStrings("bastion.example", snapshot.endpoint().host);
    }
}

test "auth challenge rejects wrong owner generation attempt operation hop and request" {
    var bridge: auth.InteractiveBridge = .{};
    const id = try bridge.offerChallenge(challenge(.password));
    var stale = [_]auth.RequestIdentity{ id, id, id, id, id, id };
    stale[0].key.owner.session.session_id = @fromBackingInt(8);
    stale[1].key.owner.session.generation += 1;
    stale[2].key.attempt_id = 4;
    stale[3].key.operation_id += 1;
    stale[4].hop_index += 1;
    stale[5].request_id += 1;
    for (stale) |wrong| {
        try std.testing.expectError(error.StaleChallenge, bridge.submit(wrong, .{ .answers = &.{"secret"} }));
        try std.testing.expect(!bridge.cancelRequest(wrong));
        try std.testing.expectError(error.StaleChallenge, bridge.complete(wrong));
    }
    try std.testing.expectError(error.ChallengeScopeRequired, bridge.answer(id.request_id, "secret"));
    try std.testing.expectError(error.ChallengeScopeRequired, bridge.offer("OTP:"));
    try std.testing.expectEqual(auth.State.input, bridge.snapshot().?.state);
    try std.testing.expect(bridge.cancelRequest(id));
    try std.testing.expect(!bridge.cancelRequest(id));
    try std.testing.expectError(error.Cancelled, bridge.submit(id, .{ .answers = &.{"late"} }));
    try std.testing.expectError(error.Cancelled, bridge.offerChallenge(challenge(.password)));
}

test "auth challenge consumes ordered general prompts once and retries without replay" {
    var bridge: auth.InteractiveBridge = .{};
    var request = challenge(.keyboard_interactive);
    request.prompts = &.{ .{ .text = "Account:", .echo = true }, .{ .text = "Recovery phrase:", .echo = false } };
    const id = try bridge.offerChallenge(request);
    try std.testing.expectError(error.InvalidChallengeResponse, bridge.submit(id, .{ .answers = &.{"only-one"} }));
    try bridge.submit(id, .{ .answers = &.{ "operator", "arbitrary-length response" } });
    try std.testing.expectError(error.StaleChallenge, bridge.submit(id, .{ .answers = &.{ "duplicate", "duplicate" } }));
    try std.testing.expectError(error.InvalidTransition, bridge.complete(id));
    try std.testing.expectError(error.ChallengeBusy, bridge.offerChallenge(request));
    var response = try bridge.waitResponse(id, 100);
    defer response.deinit();
    try std.testing.expectEqualStrings("operator", response.answerAt(0));
    try std.testing.expectEqualStrings("arbitrary-length response", response.answerAt(1));
    try std.testing.expectEqual(@as(usize, 0), bridge.response.count);
    try std.testing.expectEqual(@as(usize, 0), std.mem.count(u8, &bridge.response.bytes, "operator"));
    try std.testing.expectError(error.ResponseConsumed, bridge.waitResponse(id, 100));
    const retry = try bridge.reject(id, error.AuthenticationFailed);
    try std.testing.expect(retry.request_id > id.request_id);
    try std.testing.expectEqual(auth.State.failed, bridge.snapshot().?.state);
    try std.testing.expectEqual(error.AuthenticationFailed, bridge.snapshot().?.failure.?);
    try std.testing.expectEqualStrings("Recovery phrase:", bridge.snapshot().?.promptAt(1).text);
    try std.testing.expectError(error.StaleChallenge, bridge.complete(id));
    try std.testing.expectError(error.StaleChallenge, bridge.submit(id, .{ .answers = &.{ "old", "old" } }));
    try bridge.submit(retry, .{ .answers = &.{ "operator", "new phrase" } });
    var next = try bridge.waitResponse(retry, 100);
    defer next.deinit();
    try std.testing.expectEqualStrings("new phrase", next.answerAt(1));
    try bridge.complete(retry);
    request.hop_index += 1;
    const new_hop = try bridge.offerChallenge(request);
    try std.testing.expect(new_hop.request_id > retry.request_id);
    try std.testing.expectError(error.StaleChallenge, bridge.submit(retry, .{ .answers = &.{ "old", "old" } }));
    bridge.cancel();
}

test "auth challenge rejects invalid metadata and exhausted identities without replacing current state" {
    var bridge: auth.InteractiveBridge = .{};
    var request = challenge(.password);
    request.key.attempt_id = null;
    try std.testing.expectError(error.InvalidChallengeIdentity, bridge.offerChallenge(request));
    request = challenge(.password);
    request.key.owner.session.generation = 0;
    try std.testing.expectError(error.InvalidChallengeIdentity, bridge.offerChallenge(request));
    request = challenge(.password);
    request.endpoint_identity.host = "bad\x00host";
    try std.testing.expectError(error.InvalidChallengeEndpoint, bridge.offerChallenge(request));
    request = challenge(.keyboard_interactive);
    const oversized: [auth.InteractiveBridge.max_prompt + 1]u8 = @splat('x');
    request.prompts = &.{.{ .text = &oversized }};
    try std.testing.expectError(error.InvalidChallengePrompt, bridge.offerChallenge(request));
    const too_many: [auth.max_prompts + 1]auth.Prompt = @splat(.{ .text = "Prompt" });
    request.prompts = &too_many;
    try std.testing.expectError(error.InvalidChallengePrompt, bridge.offerChallenge(request));
    try std.testing.expect(bridge.snapshot() == null);
    try std.testing.expectEqual(@as(u64, 0), bridge.generation);
    request = challenge(.password);
    bridge.generation = std.math.maxInt(u64) - 1;
    const last = try bridge.offerChallenge(request);
    try std.testing.expectEqual(std.math.maxInt(u64), last.request_id);
    try bridge.submit(last, .{ .answers = &.{"secret"} });
    var response = try bridge.waitResponse(last, 100);
    defer response.deinit();
    try bridge.complete(last);
    request.key.attempt_id = 4;
    try std.testing.expectError(error.ChallengeOwnerMismatch, bridge.offerChallenge(request));
    request = challenge(.password);
    try std.testing.expectError(error.RequestExhausted, bridge.offerChallenge(request));
    try std.testing.expect(bridge.snapshot().?.identity.eql(last));
    try std.testing.expectEqual(auth.State.completed, bridge.snapshot().?.state);
}

test "auth bridge compatibility wait is single use and cancellation preserves handed out bytes" {
    var bridge: auth.InteractiveBridge = .{};
    const id = try bridge.offer("Password:");
    try bridge.answer(id, "secret");
    try std.testing.expectError(error.ChallengeBusy, bridge.offer("OTP:"));
    const borrowed = try bridge.wait(id, 100);
    try std.testing.expectError(error.ResponseConsumed, bridge.wait(id, 100));
    bridge.cancel();
    try std.testing.expectEqualStrings("secret", borrowed);
    try std.testing.expectError(error.Cancelled, bridge.offer("OTP:"));
}

test "auth challenge host key decisions do not cross unknown and changed kinds" {
    var unknown: auth.InteractiveBridge = .{};
    const first = try unknown.offerChallenge(challenge(.host_key_unknown));
    try std.testing.expectError(error.InvalidChallengeResponse, unknown.submit(first, .{ .replace_host_key = "yes" }));
    try unknown.submit(first, .trust_once);
    var once = try unknown.waitResponse(first, 100);
    defer once.deinit();
    try std.testing.expectEqual(.trust_once, once.decision);
    try unknown.complete(first);
    const save_id = try unknown.offerChallenge(challenge(.host_key_unknown));
    try unknown.submit(save_id, .trust_save);
    var save = try unknown.waitResponse(save_id, 100);
    defer save.deinit();
    try std.testing.expectEqual(.trust_save, save.decision);
    unknown.cancel();

    var changed: auth.InteractiveBridge = .{};
    const id = try changed.offerChallenge(challenge(.host_key_changed));
    try std.testing.expectError(error.InvalidChallengeResponse, changed.submit(id, .trust_once));
    try std.testing.expectError(error.InvalidChallengeResponse, changed.submit(id, .trust_save));
    for ([_][]const u8{ "YES", " yes", "yes ", "" }) |invalid| try std.testing.expectError(error.InvalidChallengeResponse, changed.submit(id, .{ .replace_host_key = invalid }));
    try changed.submit(id, .{ .replace_host_key = "yes" });
    var replace = try changed.waitResponse(id, 100);
    defer replace.deinit();
    try std.testing.expectEqual(.replace_host_key, replace.decision);
    try changed.complete(id);
}

test "auth challenge expiry and timeout invalidate secret and delayed results" {
    var bridge: auth.InteractiveBridge = .{};
    var request = challenge(.keyboard_interactive);
    request.expires_at_ns = realtime.monotonicNs() - 1;
    try std.testing.expectError(error.ChallengeExpired, bridge.offerChallenge(request));
    request.expires_at_ns = realtime.monotonicNs() + 20 * std.time.ns_per_ms;
    const expired = try bridge.offerChallenge(request);
    try std.testing.expectError(error.ChallengeExpired, bridge.waitResponse(expired, 100));
    try std.testing.expectEqual(auth.State.expired, bridge.snapshot().?.state);
    try std.testing.expectError(error.ChallengeExpired, bridge.submit(expired, .{ .answers = &.{"123456"} }));
    try std.testing.expectError(error.ChallengeExpired, bridge.complete(expired));

    request.expires_at_ns = realtime.monotonicNs() + 20 * std.time.ns_per_ms;
    const submitted = try bridge.offerChallenge(request);
    try bridge.submit(submitted, .{ .answers = &.{"expires-unread"} });
    while (bridge.snapshot().?.state != .expired) {
        var poll_fd: [1]std.c.pollfd = undefined;
        _ = std.c.poll(&poll_fd, 0, 1);
    }
    try std.testing.expectEqual(@as(usize, 0), bridge.response.count);
    try std.testing.expectEqual(@as(usize, 0), std.mem.count(u8, &bridge.response.bytes, "expires-unread"));
    try std.testing.expectError(error.ChallengeExpired, bridge.waitResponse(submitted, 100));
    request.expires_at_ns = null;
    const timed_out = try bridge.offerChallenge(request);
    try std.testing.expectError(error.ChallengeTimeout, bridge.waitResponse(timed_out, 0));
    try std.testing.expectEqual(auth.State.expired, bridge.snapshot().?.state);
    try std.testing.expectError(error.ChallengeExpired, bridge.submit(timed_out, .{ .answers = &.{"123456"} }));
    const cancelled = try bridge.offerChallenge(request);
    try bridge.submit(cancelled, .{ .answers = &.{"cancel-me"} });
    try std.testing.expect(bridge.cancelRequest(cancelled));
    try std.testing.expectEqual(@as(usize, 0), bridge.response.count);
    try std.testing.expectEqual(@as(usize, 0), std.mem.count(u8, &bridge.response.bytes, "cancel-me"));
    try std.testing.expectError(error.Cancelled, bridge.waitResponse(cancelled, 100));
    try std.testing.expectError(error.Cancelled, bridge.complete(cancelled));
}

test "auth challenge real bridge worker wakes on reply and cancellation" {
    const Worker = struct {
        bridge: *auth.InteractiveBridge,
        id: auth.RequestIdentity,
        value: ?auth.Response = null,
        failure: ?anyerror = null,
        fn run(self: *@This()) void {
            self.value = self.bridge.waitResponse(self.id, 60_000) catch |err| {
                self.failure = err;
                return;
            };
        }
    };
    for ([_]bool{ false, true }) |cancel| {
        var bridge: auth.InteractiveBridge = .{};
        const id = try bridge.offerChallenge(challenge(.password));
        var worker: Worker = .{ .bridge = &bridge, .id = id };
        const thread = try std.Thread.spawn(.{}, Worker.run, .{&worker});
        if (cancel) bridge.cancel() else try bridge.submit(id, .{ .answers = &.{"secret"} });
        thread.join();
        if (cancel) {
            try std.testing.expectEqual(error.Cancelled, worker.failure.?);
            try std.testing.expect(worker.value == null);
        } else {
            defer worker.value.?.deinit();
            try std.testing.expectEqualStrings("secret", worker.value.?.answerAt(0));
            try bridge.complete(id);
        }
    }
}

test "auth challenge concurrent duplicate submission accepts exactly one response" {
    const Submitter = struct {
        bridge: *auth.InteractiveBridge,
        id: auth.RequestIdentity,
        start: *std.atomic.Value(bool),
        value: []const u8,
        failure: ?anyerror = null,
        fn run(self: *@This()) void {
            while (!self.start.load(.acquire)) std.atomic.spinLoopHint();
            self.bridge.submit(self.id, .{ .answers = &.{self.value} }) catch |err| {
                self.failure = err;
            };
        }
    };
    var bridge: auth.InteractiveBridge = .{};
    const id = try bridge.offerChallenge(challenge(.password));
    var start: std.atomic.Value(bool) = .init(false);
    var first: Submitter = .{ .bridge = &bridge, .id = id, .start = &start, .value = "first" };
    var second: Submitter = .{ .bridge = &bridge, .id = id, .start = &start, .value = "second" };
    const thread_a = try std.Thread.spawn(.{}, Submitter.run, .{&first});
    const thread_b = try std.Thread.spawn(.{}, Submitter.run, .{&second});
    start.store(true, .release);
    thread_a.join();
    thread_b.join();
    try std.testing.expect((first.failure == null) != (second.failure == null));
    const failure: anyerror = if (first.failure) |err| err else second.failure.?;
    try std.testing.expectEqual(error.StaleChallenge, failure);
    var response = try bridge.waitResponse(id, 100);
    defer response.deinit();
    try std.testing.expectEqualStrings(if (first.failure == null) "first" else "second", response.answerAt(0));
    try bridge.complete(id);
}

test "auth machine freezes remaining methods and rejects duplicate or out of order outcomes" {
    var machine: policy.AuthMachine = .{};
    try std.testing.expectEqual(policy.AuthMethod.agent, machine.next().?);
    try std.testing.expect(machine.next() == null);
    try std.testing.expectError(error.InvalidTransition, machine.result(.password, .success));
    var remaining = [_]policy.AuthMethod{ .password, .keyboard_interactive };
    try machine.resultWithRemaining(.agent, .partial, &remaining);
    @memset(&remaining, .private_key);
    try std.testing.expectEqual(policy.AuthState.partial, machine.state);
    try std.testing.expect(machine.completed.contains(.agent));
    try std.testing.expectError(error.InvalidTransition, machine.result(.agent, .success));
    try std.testing.expectEqual(policy.AuthMethod.password, machine.next().?);
    try machine.resultWithRemaining(.password, .partial, &.{.keyboard_interactive});
    try std.testing.expect(machine.completed.contains(.agent) and machine.completed.contains(.password));
    try std.testing.expectEqual(policy.AuthMethod.keyboard_interactive, machine.next().?);
    try machine.result(.keyboard_interactive, .success);
    try std.testing.expectEqual(policy.AuthState.authenticated, machine.state);
    try std.testing.expect(machine.next() == null);
    try std.testing.expectError(error.InvalidTransition, machine.result(.keyboard_interactive, .success));

    var failed: policy.AuthMachine = .{};
    _ = failed.next();
    try failed.result(.agent, .failure);
    try std.testing.expectEqual(policy.AuthState.pending, failed.state);
    _ = failed.next();
    try failed.resultWithRemaining(.private_key, .partial, &.{});
    try std.testing.expect(failed.next() == null);
    try std.testing.expectEqual(policy.AuthState.rejected, failed.state);

    var rejected_method: policy.AuthMachine = .{};
    _ = rejected_method.next();
    try rejected_method.resultWithRemaining(.agent, .failure, &.{ .agent, .password });
    try std.testing.expectEqual(policy.AuthMethod.password, rejected_method.next().?);
}
