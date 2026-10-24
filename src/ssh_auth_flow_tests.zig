const std = @import("std");
const flow = @import("proto/ssh/auth_flow.zig");
const challenge = @import("proto/ssh/auth_challenge.zig");
const policy = @import("proto/ssh/connection_policy.zig");

fn config(bridge: ?*challenge.InteractiveBridge) flow.Config {
    return .{
        .endpoint = .{ .host = "second-hop.example", .port = 2222, .user = "operator" },
        .auth = .password_prompt,
        .source_owner = .{ .id = @fromBackingInt(42), .revision = 7 },
        .operation_key = .{ .owner = .{ .session = .{ .session_id = @fromBackingInt(8), .generation = 2 } }, .operation_id = 9, .attempt_id = 3 },
        .hop_index = 1,
        .interaction = if (bridge) |value| .{ .bridge = value, .presentation = .protected_form, .presentation_config_revision = 13, .timeout_ms = 2000 } else null,
    };
}

const Driver = struct {
    bridge: *challenge.InteractiveBridge,
    kinds: []const challenge.Kind,
    failure: ?anyerror = null,
    saw_retry: bool = false,
    fn run(self: *Driver) void {
        self.answerAll() catch |err| {
            self.failure = err;
            self.bridge.cancel();
        };
    }
    fn answerAll(self: *Driver) !void {
        var previous: u64 = 0;
        for (self.kinds) |kind| {
            var attempts: usize = 0;
            while (true) {
                if (self.bridge.snapshot()) |snapshot| {
                    if (snapshot.identity.request_id > previous and (snapshot.state == .input or snapshot.state == .failed)) {
                        try std.testing.expectEqual(kind, snapshot.kind);
                        try std.testing.expectEqualStrings("second-hop.example", snapshot.endpoint().host);
                        try std.testing.expectEqual(@as(usize, 1), snapshot.identity.hop_index);
                        try std.testing.expectEqual(@as(u64, 7), snapshot.source_owner.?.revision);
                        try std.testing.expectEqual(@as(u64, 13), snapshot.presentation_config_revision);
                        try std.testing.expectEqual(@as(u64, 3), snapshot.identity.key.attempt_id.?);
                        if (snapshot.state == .failed) self.saw_retry = true;
                        if (kind == .keyboard_interactive) {
                            try std.testing.expectEqual(@as(usize, 2), snapshot.prompt_count);
                            try std.testing.expect(snapshot.promptAt(0).echo);
                            try std.testing.expect(!snapshot.promptAt(1).echo);
                            try self.bridge.submit(snapshot.identity, .{ .answers = &.{ "operator", "arbitrary recovery response" } });
                        } else try self.bridge.submit(snapshot.identity, .{ .answers = &.{"fresh secret"} });
                        try std.testing.expectError(error.StaleChallenge, self.bridge.submit(snapshot.identity, .{ .answers = &.{"duplicate"} }));
                        previous = snapshot.identity.request_id;
                        break;
                    }
                }
                attempts += 1;
                if (attempts > 2500) return error.TestTimeout;
                var fd: [1]std.c.pollfd = undefined;
                _ = std.c.poll(&fd, 0, 1);
            }
        }
    }
};

const prompts = [_]challenge.Prompt{ .{ .text = "Account:", .echo = true }, .{ .text = "Recovery phrase:", .echo = false } };

test "auth flow carries actual partial into ordered multi prompt continuation" {
    var bridge: challenge.InteractiveBridge = .{};
    var driver: Driver = .{ .bridge = &bridge, .kinds = &.{ .password, .keyboard_interactive } };
    const thread = try std.Thread.spawn(.{}, Driver.run, .{&driver});
    var joined = false;
    defer if (!joined) thread.join();
    defer bridge.cancel();
    const Backend = struct {
        calls: usize = 0,
        pub fn query(_: *@This()) !flow.Advertised {
            return .{ .methods = try flow.parseMethods("password,keyboard-interactive") };
        }
        pub fn attempt(self: *@This(), auth: flow.Auth, conversation: *flow.Conversation) !flow.Attempt {
            self.calls += 1;
            if (self.calls == 1) {
                try std.testing.expectEqualStrings("fresh secret", auth.password);
                return .{ .outcome = .partial, .remaining = try flow.parseMethods("keyboard-interactive") };
            }
            try std.testing.expect(auth == .keyboard_interactive);
            var reply = try conversation.request(.keyboard_interactive, &prompts);
            defer reply.deinit();
            try std.testing.expectEqualStrings("operator", reply.answerAt(0));
            try std.testing.expectEqualStrings("arbitrary recovery response", reply.answerAt(1));
            return .{ .outcome = .success };
        }
    };
    var backend: Backend = .{};
    const result = try flow.authenticate(config(&bridge), &backend);
    thread.join();
    joined = true;
    if (driver.failure) |err| return err;
    try std.testing.expect(result.accepted_methods.contains(.password));
    try std.testing.expect(result.accepted_methods.contains(.keyboard_interactive));
    try std.testing.expectEqual(@as(usize, 2), backend.calls);
    try std.testing.expectEqual(challenge.State.completed, bridge.snapshot().?.state);
}

test "auth flow changed method list without partial never records the rejected method" {
    const Backend = struct {
        pub fn query(_: *@This()) !flow.Advertised {
            return .{ .methods = try flow.parseMethods("publickey,keyboard-interactive") };
        }
        pub fn attempt(_: *@This(), auth: flow.Auth, _: *flow.Conversation) !flow.Attempt {
            return if (auth == .agent) .{ .outcome = .failure, .remaining = try flow.parseMethods("keyboard-interactive") } else .{ .outcome = .success };
        }
    };
    var backend: Backend = .{};
    var options = config(null);
    options.auth = .agent;
    options.legacy_keyboard = .{ .ctx = &backend, .callback = struct {
        fn unused(_: *anyopaque, _: []const u8, _: []u8) ?[]const u8 {
            return null;
        }
    }.unused };
    const result = try flow.authenticate(options, &backend);
    try std.testing.expect(!result.accepted_methods.contains(.agent));
    try std.testing.expectEqual(@as(usize, 1), result.accepted_methods.count());
    try std.testing.expect(result.accepted_methods.contains(.keyboard_interactive));
}

test "auth flow rejected password requires fresh scoped submission before retry" {
    var bridge: challenge.InteractiveBridge = .{};
    var driver: Driver = .{ .bridge = &bridge, .kinds = &.{ .password, .password } };
    const thread = try std.Thread.spawn(.{}, Driver.run, .{&driver});
    var joined = false;
    defer if (!joined) thread.join();
    defer bridge.cancel();
    const Backend = struct {
        calls: usize = 0,
        pub fn query(_: *@This()) !flow.Advertised {
            return .{ .methods = try flow.parseMethods("password") };
        }
        pub fn attempt(self: *@This(), auth: flow.Auth, _: *flow.Conversation) !flow.Attempt {
            try std.testing.expectEqualStrings("fresh secret", auth.password);
            self.calls += 1;
            return if (self.calls == 1) .{ .outcome = .failure, .remaining = try flow.parseMethods("password") } else .{ .outcome = .success };
        }
    };
    var backend: Backend = .{};
    _ = try flow.authenticate(config(&bridge), &backend);
    thread.join();
    joined = true;
    if (driver.failure) |err| return err;
    try std.testing.expectEqual(@as(usize, 2), backend.calls);
    try std.testing.expect(driver.saw_retry);
}

test "auth flow cancellation interrupts a typed wait without waiting for deadline" {
    var bridge: challenge.InteractiveBridge = .{};
    var cancel: std.atomic.Value(bool) = .init(false);
    const Canceller = struct {
        fn run(b: *challenge.InteractiveBridge, flag: *std.atomic.Value(bool)) void {
            while (b.snapshot() == null) std.Thread.yield() catch {};
            flag.store(true, .release);
        }
    };
    const thread = try std.Thread.spawn(.{}, Canceller.run, .{ &bridge, &cancel });
    defer thread.join();
    const Backend = struct {
        pub fn query(_: *@This()) !flow.Advertised {
            return .{ .methods = try flow.parseMethods("password") };
        }
        pub fn attempt(_: *@This(), _: flow.Auth, _: *flow.Conversation) !flow.Attempt {
            return error.ShouldNotAuthenticate;
        }
    };
    var backend: Backend = .{};
    var options = config(&bridge);
    options.cancel_token = &cancel;
    options.interaction.?.timeout_ms = 60_000;
    try std.testing.expectError(error.Cancelled, flow.authenticate(options, &backend));
    try std.testing.expectEqual(challenge.State.cancelled, bridge.snapshot().?.state);
    try std.testing.expectEqual(@as(usize, 0), bridge.response.count);
}

test "auth flow parses bounded server methods and retains publickey alternatives" {
    const methods = try flow.parseMethods("publickey,password,keyboard-interactive,external@example");
    try std.testing.expectEqual(@as(usize, 4), methods.count());
    try std.testing.expectError(error.InvalidAuthenticationMethods, flow.parseMethods("password,,publickey"));
    try std.testing.expectError(error.InvalidAuthenticationMethods, flow.parseMethods("password\x00publickey"));
}

test "auth flow takes an already submitted retry without completing an unconsumed response" {
    var bridge: challenge.InteractiveBridge = .{};
    defer bridge.cancel();
    const options = config(&bridge);
    const request = try bridge.offerChallenge(.{
        .key = options.operation_key.?,
        .source_owner = options.source_owner,
        .hop_index = options.hop_index,
        .kind = .password,
        .endpoint_identity = options.endpoint,
        .prompts = &.{.{ .text = "Password:" }},
        .presentation_config_revision = 13,
    });
    try bridge.submit(request, .{ .answers = &.{"first"} });
    var first = try bridge.waitResponse(request, 100);
    first.deinit();
    const retry = try bridge.reject(request, error.AuthenticationFailed);
    try bridge.submit(retry, .{ .answers = &.{"fresh retry"} });
    var conversation: flow.Conversation = .{ .config = options, .last = retry, .retry_pending = true };
    var response = try conversation.request(.password, &.{.{ .text = "Password:" }});
    defer response.deinit();
    try std.testing.expectEqualStrings("fresh retry", response.answerAt(0));
    try std.testing.expect(bridge.snapshot().?.identity.eql(retry));
    try bridge.complete(retry);
}
