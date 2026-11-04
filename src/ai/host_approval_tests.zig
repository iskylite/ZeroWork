const std = @import("std");
const approval = @import("host_approval.zig");
const host = @import("host_tools.zig");
const provider = @import("provider.zig");
const identity = @import("../host/identity.zig");
fn context() host.Context {
    return .{ .conversation_id = identity.ConversationId.generate(), .task_id = identity.TaskId.generate(), .binding = .{ .session = 1 }, .binding_revision = 2, .grant_revision = 3 };
}
fn invocation(ctx: host.Context, args: std.json.Value, json: []const u8) !host.Invocation {
    var hash: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(json, &hash, .{});
    return .{ .context = ctx, .authority = .local_network_read, .operation_id = 42, .turn_id = 7, .call_id = "exact-call", .tool_id = "host.fetch_url", .arguments = args, .arguments_json = json, .arguments_hash = hash, .canonical_arguments_hash = try @import("canonical_arguments.zig").digest(std.testing.allocator, args) };
}
fn time(raw: ?*anyopaque) i64 {
    return @as(*i64, @ptrCast(@alignCast(raw.?))).*;
}

test "host approval binds trusted input evidence independently of visible text" {
    const a = std.testing.allocator;
    var broker: approval.Broker = .{};
    const ctx = context();
    try broker.configure(ctx, 9);
    const json = "{\"text\":\"continue\"}";
    const parsed = try std.json.parseFromSlice(std.json.Value, a, json, .{});
    defer parsed.deinit();
    var call = try invocation(ctx, parsed.value, json);
    call.tool_id = "host.send_execution_input";
    call.authority = .execution_control;
    const subject: approval.Subject = .{ .kind = .terminal_command, .target = "execution 1", .detail = "continue", .impact = "向当前等待输入的程序发送内容", .evidence_hash = @splat(1) };
    const permit = try broker.beginSubject(call, subject, 9, a);
    defer broker.finish(permit);
    const shown = broker.snapshot().?;
    try std.testing.expectEqualStrings(subject.detail, shown.detail.text());
    try std.testing.expectEqualStrings(subject.impact, shown.impact.text());
    try broker.decide(permit.sequence, permit.arguments_hash, true);
    try std.testing.expectEqual(@import("fetch_url.zig").Decision.allow, broker.authorizeSubject(permit, call, subject, 9));
    var changed = subject;
    changed.evidence_hash = @splat(2);
    try std.testing.expectEqual(@import("fetch_url.zig").Decision.scope_changed, broker.authorizeSubject(permit, call, changed, 9));
    changed.evidence_hash = null;
    try std.testing.expectEqual(@import("fetch_url.zig").Decision.scope_changed, broker.authorizeSubject(permit, call, changed, 9));
}

test "execution deadline Stop racing approved or rejected host approval clears the permit" {
    const Race = struct {
        broker: *approval.Broker,
        allow: bool,
        polls: std.atomic.Value(usize) = .init(0),
        fn stopped(raw: *const anyopaque) bool {
            const self: *@This() = @ptrCast(@alignCast(@constCast(raw)));
            const index = self.polls.fetchAdd(1, .acq_rel);
            if (index == 1) {
                const pending = self.broker.snapshot().?;
                self.broker.decide(pending.sequence, pending.arguments_hash, self.allow) catch unreachable;
            }
            return index >= 2;
        }
    };
    for ([_]bool{ true, false }) |allow| {
        var broker: approval.Broker = .{};
        const ctx = context();
        try broker.configure(ctx, 4);
        var args = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, "{\"url\":\"https://example.test/\"}", .{});
        defer args.deinit();
        const call = try invocation(ctx, args.value, "{\"url\":\"https://example.test/\"}");
        var race: Race = .{ .broker = &broker, .allow = allow };
        var cancel: provider.CancelToken = .{ .source = .{ .context = &race, .poll = Race.stopped } };
        try std.testing.expectError(error.CancelledBeforeDispatch, broker.request(call, "https://example.test/", 4, std.testing.allocator, &cancel));
        try std.testing.expect(broker.entry == null);
        try std.testing.expectEqual(@as(usize, 3), race.polls.load(.acquire));
    }
}

test "execution deadline native host approval still honours explicit caller cancellation" {
    const Deadline = struct {
        expires_ms: std.atomic.Value(i64) = .init(0),
        polls: std.atomic.Value(usize) = .init(0),
        fn milliseconds() i64 {
            return @intCast(@divTrunc(@import("../platform/realtime.zig").monotonicNs(), std.time.ns_per_ms));
        }
        fn stopped(raw: *const anyopaque) bool {
            const self: *@This() = @ptrCast(@alignCast(@constCast(raw)));
            if (self.polls.fetchAdd(1, .acq_rel) == 1) self.expires_ms.store(milliseconds() + 70, .release);
            const expires = self.expires_ms.load(.acquire);
            return expires != 0 and milliseconds() >= expires;
        }
    };
    var broker: approval.Broker = .{};
    const ctx = context();
    try broker.configure(ctx, 4);
    var args = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, "{\"url\":\"https://example.test/\"}", .{});
    defer args.deinit();
    const call = try invocation(ctx, args.value, "{\"url\":\"https://example.test/\"}");
    var deadline: Deadline = .{};
    var cancel: provider.CancelToken = .{ .source = .{ .context = &deadline, .poll = Deadline.stopped } };
    const started = Deadline.milliseconds();
    try std.testing.expectError(error.CancelledBeforeDispatch, broker.request(call, "https://example.test/", 4, std.testing.allocator, &cancel));
    try std.testing.expect(deadline.expires_ms.load(.acquire) != 0);
    try std.testing.expect(broker.entry == null);
    std.debug.print("native approval caller cancellation released in {d}ms\n", .{Deadline.milliseconds() - started});
}

test "host approval freezes URL call authority and sequence without expiring" {
    const a = std.testing.allocator;
    const ctx = context();
    const json = "{\"url\":\"https://example.com/docs#part\"}";
    const args = try std.json.parseFromSlice(std.json.Value, a, json, .{});
    defer args.deinit();
    var call = try invocation(ctx, args.value, json);
    var now: i64 = 1000;
    var broker: approval.Broker = .{ .clock_context = &now, .clock = time };
    try broker.configure(ctx, 5);
    const permit = try broker.begin(call, "https://example.com/docs#part", 5, a);
    const pending = broker.snapshot().?;
    try std.testing.expectEqualStrings("https://example.com/docs", pending.canonical_url.text());
    try std.testing.expectEqualStrings("https://example.com/docs#part", pending.requested_url.text());
    try std.testing.expectEqualStrings("exact-call", pending.call.text());
    try std.testing.expect(!try broker.poll(permit));
    var bad_hash = permit.arguments_hash;
    bad_hash[0] ^= 1;
    try std.testing.expectError(error.StaleApproval, broker.decide(permit.sequence, bad_hash, true));
    try broker.decide(permit.sequence, permit.arguments_hash, true);
    try std.testing.expect(try broker.poll(permit));
    try std.testing.expectEqual(@import("fetch_url.zig").Decision.allow, broker.authorize(permit, call, "https://example.com/docs", 5));
    try std.testing.expectEqual(@import("fetch_url.zig").Decision.approval_required, broker.authorize(permit, call, "https://example.com/other", 5));
    call.call_id = "another-call";
    try std.testing.expectEqual(@import("fetch_url.zig").Decision.scope_changed, broker.authorize(permit, call, "https://example.com/docs", 5));
    call.call_id = "exact-call";
    call.arguments_json = "{}";
    try std.testing.expectEqual(@import("fetch_url.zig").Decision.scope_changed, broker.authorize(permit, call, "https://example.com/docs", 5));
    call.arguments_json = json;
    now += 30 * 24 * 60 * 60 * 1000;
    try std.testing.expect(try broker.poll(permit));
    try std.testing.expectEqual(@import("fetch_url.zig").Decision.allow, broker.authorize(permit, call, "https://example.com/docs", 5));
    broker.finish(permit);
    now += 1;
    const next = try broker.begin(call, "https://example.com/docs#part", 5, a);
    try std.testing.expect(next.sequence > permit.sequence);
    try std.testing.expectError(error.StaleApproval, broker.decide(permit.sequence, permit.arguments_hash, true));
    var changed = ctx;
    changed.grant_revision += 1;
    try broker.configure(changed, 5);
    try std.testing.expect(broker.snapshot() == null);
    try std.testing.expectEqual(@import("fetch_url.zig").Decision.scope_changed, broker.authorize(next, call, "https://example.com/docs", 5));
    broker.stop();
}

test "host approval generic subjects freeze exact command and lifecycle details" {
    const a = std.testing.allocator;
    const ctx = context();
    const json = "{\"request_key\":\"one\"}";
    const args = try std.json.parseFromSlice(std.json.Value, a, json, .{});
    defer args.deinit();
    var call = try invocation(ctx, args.value, json);
    call.authority = .lifecycle;
    call.tool_id = "host.open_session";
    var broker: approval.Broker = .{};
    try broker.configure(ctx, 9);
    const subject: approval.Subject = .{ .kind = .lifecycle, .target = "当前组 g_7", .detail = "新建工作会话；来源 s_3；reuse_only", .impact = "只新建该组内工作会话；不执行命令。" };
    const permit = try broker.beginSubject(call, subject, 9, a);
    try std.testing.expectEqual(approval.SubjectKind.lifecycle, broker.snapshot().?.kind);
    try broker.decide(permit.sequence, permit.arguments_hash, true);
    try std.testing.expectEqual(@import("fetch_url.zig").Decision.allow, broker.authorizeSubject(permit, call, subject, 9));
    var changed = subject;
    changed.detail = "new_only";
    try std.testing.expectEqual(@import("fetch_url.zig").Decision.scope_changed, broker.authorizeSubject(permit, call, changed, 9));
    broker.finish(permit);
    call.authority = .execution_control;
    call.tool_id = "host.run_in_terminal";
    const command: approval.Subject = .{ .kind = .terminal_command, .target = "s_3 · 当前终端", .detail = "printf 'https://local.example/'; pwd" };
    const command_permit = try broker.beginSubject(call, command, 9, a);
    try broker.decide(command_permit.sequence, command_permit.arguments_hash, false);
    try std.testing.expectError(error.ToolApprovalRejected, broker.poll(command_permit));
    try std.testing.expectEqual(@import("fetch_url.zig").Decision.denied, broker.authorizeSubject(command_permit, call, command, 9));
    broker.finish(command_permit);
}

test "host approval worker cancellation releases pending storage without holding UI lock" {
    const a = std.testing.allocator;
    const ctx = context();
    const json = "{\"url\":\"https://example.com/\"}";
    const args = try std.json.parseFromSlice(std.json.Value, a, json, .{});
    defer args.deinit();
    var broker: approval.Broker = .{};
    try broker.configure(ctx, 4);
    const Worker = struct {
        broker: *approval.Broker,
        call: host.Invocation,
        cancel: provider.CancelToken = .{},
        failure: ?anyerror = null,
        fn run(self: *@This()) void {
            _ = self.broker.request(self.call, "https://example.com/", 4, std.testing.allocator, &self.cancel) catch |err| {
                self.failure = err;
                return;
            };
        }
    };
    var worker: Worker = .{ .broker = &broker, .call = try invocation(ctx, args.value, json) };
    const thread = try std.Thread.spawn(.{}, Worker.run, .{&worker});
    var observed = false;
    for (0..1000) |_| {
        if (broker.snapshot() != null) {
            observed = true;
            break;
        }
        try @import("retry.zig").wait(1, null);
    }
    try std.testing.expect(broker.mutex.tryLock());
    broker.mutex.unlock();
    worker.cancel.cancel();
    thread.join();
    try std.testing.expect(observed);
    try std.testing.expectEqual(error.CancelledBeforeDispatch, worker.failure.?);
    try std.testing.expect(broker.snapshot() == null);
}

test "routing approval combines selection and permission and cross tool stays zero dispatch" {
    const a = std.testing.allocator;
    const ctx = context();
    const json = "{\"command\":\"pwd\"}";
    const args = try std.json.parseFromSlice(std.json.Value, a, json, .{});
    defer args.deinit();
    var call = try invocation(ctx, args.value, json);
    call.authority = .execution_control;
    call.tool_id = "run_command";
    const target: identity.SessionHandle = .{ .session_id = @fromBackingInt(1), .generation = 4 };
    var broker: approval.Broker = .{};
    try broker.configure(ctx, 9);
    const subject: approval.Subject = .{ .kind = .terminal_command, .target = "session 1 g4", .detail = "pwd", .route = .{ .proposed = .batch, .choice = .{ .route = .batch, .source = .{ .session = target } }, .target = target, .selectable = true } };
    const permit = try broker.beginSubject(call, subject, 9, a);
    try broker.chooseRoute(permit.sequence, permit.arguments_hash, .current_terminal);
    try std.testing.expect(!broker.execution_route.resolve(ctx, target, "pwd", .batch).trusted);
    try broker.decide(permit.sequence, permit.arguments_hash, true);
    try std.testing.expectEqual(approval.routing.Route.current_terminal, (try broker.selectedRoute(permit)).route);
    try std.testing.expectEqual(@import("fetch_url.zig").Decision.scope_changed, broker.authorizeSubject(permit, call, subject, 9));
    broker.finish(permit);
    call.tool_id = "host.run_in_terminal";
    call.call_id = "correct-next-round";
    call.operation_id += 1;
    var correct = subject;
    correct.route.?.proposed = .current_terminal;
    correct.route.?.choice.route = .current_terminal;
    correct.route.?.selectable = false;
    const carried = (try broker.beginGrantedSubject(call, correct, 9, a)).?;
    try std.testing.expectEqual(@import("fetch_url.zig").Decision.allow, broker.authorizeSubject(carried, call, correct, 9));
    broker.finish(carried);
    broker.execution_route.consume(ctx, target, "pwd");
    try std.testing.expect(try broker.beginGrantedSubject(call, correct, 9, a) == null);
}
test "routing rejected pending choice and changed command cannot mint successor permission" {
    const a = std.testing.allocator;
    const ctx = context();
    const json = "{\"command\":\"pwd\"}";
    const args = try std.json.parseFromSlice(std.json.Value, a, json, .{});
    defer args.deinit();
    var call = try invocation(ctx, args.value, json);
    call.authority = .execution_control;
    call.tool_id = "host.run_in_terminal";
    const target: identity.SessionHandle = .{ .session_id = @fromBackingInt(1), .generation = 4 };
    var broker: approval.Broker = .{};
    try broker.configure(ctx, 9);
    const subject: approval.Subject = .{ .kind = .terminal_command, .target = "session 1 g4", .detail = "pwd", .route = .{ .proposed = .current_terminal, .choice = .{ .route = .current_terminal, .source = .{ .session = target } }, .target = target, .selectable = true } };
    const permit = try broker.beginSubject(call, subject, 9, a);
    try broker.chooseRoute(permit.sequence, permit.arguments_hash, .batch);
    try broker.decide(permit.sequence, permit.arguments_hash, false);
    broker.finish(permit);
    try std.testing.expect(!broker.execution_route.resolve(ctx, target, "pwd", .current_terminal).trusted);
    try broker.execution_route.select(ctx, .{ .route = .batch, .source = .{ .session = target } }, "pwd", true);
    var changed = subject;
    changed.detail = "pwd; touch x";
    try std.testing.expect(try broker.beginGrantedSubject(call, changed, 9, a) == null);
}

test "host approval waits indefinitely and accepts one direct decision" {
    const a = std.testing.allocator;
    const ctx = context();
    const json = "{\"url\":\"https://example.com/\"}";
    const args = try std.json.parseFromSlice(std.json.Value, a, json, .{});
    defer args.deinit();
    const Clock = struct {
        value: std.atomic.Value(i64) = .init(1000),
        fn read(raw: ?*anyopaque) i64 {
            return @as(*@This(), @ptrCast(@alignCast(raw.?))).value.load(.acquire);
        }
    };
    var clock: Clock = .{};
    var broker: approval.Broker = .{ .clock_context = &clock, .clock = Clock.read };
    try broker.configure(ctx, 4);
    const Worker = struct {
        broker: *approval.Broker,
        call: host.Invocation,
        finished: std.atomic.Value(bool) = .init(false),
        cancel: provider.CancelToken = .{},
        failure: ?anyerror = null,
        permit: ?approval.Permit = null,
        fn run(self: *@This()) void {
            defer self.finished.store(true, .release);
            self.permit = self.broker.request(self.call, "https://example.com/", 4, std.testing.allocator, &self.cancel) catch |err| {
                self.failure = err;
                return;
            };
        }
    };
    var worker: Worker = .{ .broker = &broker, .call = try invocation(ctx, args.value, json) };
    const thread = try std.Thread.spawn(.{}, Worker.run, .{&worker});
    defer {
        worker.cancel.cancel();
        thread.join();
    }
    var pending: ?approval.Snapshot = null;
    for (0..1000) |_| {
        pending = broker.snapshot();
        if (pending != null) break;
        try @import("retry.zig").wait(1, null);
    }
    const frozen = pending orelse return error.ApprovalNotPublished;
    clock.value.store(30 * 24 * 60 * 60 * 1000, .release);
    try @import("retry.zig").wait(30, null);
    try std.testing.expect(!broker.snapshot().?.expired);
    try std.testing.expect(!worker.finished.load(.acquire));
    try std.testing.expectEqual(frozen.sequence, broker.snapshot().?.sequence);
    try std.testing.expectEqualStrings(frozen.call.text(), broker.snapshot().?.call.text());
    try @import("retry.zig").wait(30, null);
    try std.testing.expect(!worker.finished.load(.acquire));
    try broker.decide(frozen.sequence, frozen.arguments_hash, true);
    for (0..1000) |_| {
        if (worker.finished.load(.acquire)) break;
        try @import("retry.zig").wait(1, null);
    }
    try std.testing.expect(worker.finished.load(.acquire));
    try std.testing.expect(worker.failure == null and worker.permit != null);
    broker.finish(worker.permit.?);
}

test "live permission PTY rejudges the same pending permit and revokes only automatic grants" {
    const a = std.testing.allocator;
    var broker: approval.Broker = .{};
    const ctx = context();
    try broker.configure(ctx, 9);
    const json = "{\"command\":\"df -h\"}";
    const parsed = try std.json.parseFromSlice(std.json.Value, a, json, .{});
    defer parsed.deinit();
    var call = try invocation(ctx, parsed.value, json);
    call.tool_id = "host.run_in_terminal";
    call.authority = .execution_control;
    const target: identity.SessionHandle = .{ .session_id = @fromBackingInt(1) };
    const subject: approval.Subject = .{ .kind = .terminal_command, .target = "session 1", .detail = "df -h", .route = .{ .proposed = .current_terminal, .choice = .{ .route = .current_terminal, .source = .{ .session = target } }, .target = target, .selectable = false } };
    broker.updatePermissionPolicy(.{ .mode = .confirm });
    const permit = try broker.beginSubject(call, subject, 9, a);
    defer broker.finish(permit);
    try std.testing.expect(!try broker.poll(permit));
    broker.updatePermissionPolicy(.{ .mode = .auto });
    try std.testing.expect(try broker.poll(permit));
    try std.testing.expect(broker.snapshot() == null);
    try std.testing.expectEqual(@import("fetch_url.zig").Decision.allow, broker.authorizeSubject(permit, call, subject, 9));
    try std.testing.expect(!broker.execution_route.resolve(ctx, target, "df -h", .current_terminal).approved);
    broker.updatePermissionPolicy(.{ .mode = .confirm });
    try std.testing.expect(!try broker.poll(permit));
    try std.testing.expectEqual(permit.sequence, broker.snapshot().?.sequence);
    try std.testing.expectEqual(@import("fetch_url.zig").Decision.approval_required, broker.authorizeSubject(permit, call, subject, 9));
    try broker.decide(permit.sequence, permit.arguments_hash, true);
    broker.updatePermissionPolicy(.{ .mode = .auto });
    broker.updatePermissionPolicy(.{ .mode = .confirm });
    try std.testing.expect(try broker.poll(permit));
}

test "live permission PTY auto allows all safe commands and retains route rejection and stop checks" {
    const a = std.testing.allocator;
    for ([_][]const u8{ "df -h", "kubectl rollout restart deploy/api", "touch /tmp/fixture", "df -h; echo x", "echo x; shutdown now" }) |command| {
        for ([_]bool{ false, true }) |selectable| {
            var broker: approval.Broker = .{};
            const ctx = context();
            try broker.configure(ctx, 9);
            broker.updatePermissionPolicy(.{ .mode = .auto, .whitelist = &.{"kubectl rollout restart"} });
            const json = try std.json.Stringify.valueAlloc(a, .{ .command = command }, .{});
            defer a.free(json);
            const parsed = try std.json.parseFromSlice(std.json.Value, a, json, .{});
            defer parsed.deinit();
            var call = try invocation(ctx, parsed.value, json);
            call.tool_id = "host.run_in_terminal";
            call.authority = .execution_control;
            const target: identity.SessionHandle = .{ .session_id = @fromBackingInt(1) };
            const subject: approval.Subject = .{ .kind = .terminal_command, .target = "session 1", .detail = command, .route = .{ .proposed = .current_terminal, .choice = .{ .route = .current_terminal, .source = .{ .session = target } }, .target = target, .selectable = selectable } };
            const permit = try broker.beginSubject(call, subject, 9, a);
            defer broker.finish(permit);
            const automatic = !selectable and !std.mem.eql(u8, command, "echo x; shutdown now");
            try std.testing.expectEqual(automatic, try broker.poll(permit));
            if (!automatic) {
                try broker.decide(permit.sequence, permit.arguments_hash, false);
                broker.updatePermissionPolicy(.{ .mode = .auto });
                try std.testing.expectError(error.ToolApprovalRejected, broker.poll(permit));
            }
            broker.stop();
            broker.updatePermissionPolicy(.{ .mode = .auto });
            try std.testing.expectError(error.CancelledBeforeDispatch, broker.poll(permit));
        }
    }
}

test "automatic permission covers host lifecycle network input and group command approvals" {
    const a = std.testing.allocator;
    const cases = [_]struct { tool: []const u8, kind: approval.SubjectKind, authority: provider.ToolAuthority, json: []const u8, detail: []const u8, automatic: bool = true }{
        .{ .tool = "host.run_in_terminal", .kind = .terminal_command, .authority = .execution_control, .json = "{\"command\":\"touch /tmp/auto-fixture\"}", .detail = "touch /tmp/auto-fixture" },
        .{ .tool = "run_command", .kind = .terminal_command, .authority = .execution_control, .json = "{\"command\":\"touch /tmp/auto-fixture\"}", .detail = "touch /tmp/auto-fixture" },
        .{ .tool = "host.send_execution_input", .kind = .terminal_command, .authority = .execution_control, .json = "{\"text\":\"continue\"}", .detail = "continue" },
        .{ .tool = "host.send_execution_input", .kind = .terminal_command, .authority = .execution_control, .json = "{\"host_secret_request\":true}", .detail = "host secret", .automatic = false },
        .{ .tool = "host.create_group", .kind = .lifecycle, .authority = .lifecycle, .json = "{}", .detail = "create group" },
        .{ .tool = "host.open_session", .kind = .lifecycle, .authority = .lifecycle, .json = "{}", .detail = "open session with its exact bootstrap dependencies" },
        .{ .tool = "host.close_session", .kind = .lifecycle, .authority = .lifecycle, .json = "{}", .detail = "close authorized session" },
        .{ .tool = "host.create_host", .kind = .lifecycle, .authority = .lifecycle, .json = "{}", .detail = "save static host configuration" },
        .{ .tool = "host.fetch_url", .kind = .network_url, .authority = .local_network_read, .json = "{\"url\":\"https://example.test/\"}", .detail = "https://example.test/" },
    };
    for (cases) |case| {
        var broker: approval.Broker = .{};
        var ctx = context();
        ctx.binding = .{ .group = 7 };
        try broker.configure(ctx, 9);
        const parsed = try std.json.parseFromSlice(std.json.Value, a, case.json, .{});
        defer parsed.deinit();
        var call = try invocation(ctx, parsed.value, case.json);
        call.tool_id = case.tool;
        call.authority = case.authority;
        const subject: approval.Subject = .{ .kind = case.kind, .target = if (case.kind == .network_url) case.detail else "authorized target", .detail = case.detail };
        const permit = try broker.beginSubject(call, subject, 9, a);
        defer broker.finish(permit);
        try std.testing.expect(!try broker.poll(permit));
        broker.updatePermissionPolicy(.{ .mode = .auto });
        try std.testing.expectEqual(case.automatic, try broker.poll(permit));
        if (!case.automatic) continue;
        try std.testing.expect(try broker.approvalIsAutomatic(permit));
        try std.testing.expectEqual(@import("fetch_url.zig").Decision.allow, broker.authorizeSubject(permit, call, subject, 9));
        broker.updatePermissionPolicy(.{ .mode = .confirm });
        try std.testing.expect(!try broker.poll(permit));
        try std.testing.expectEqual(@import("fetch_url.zig").Decision.approval_required, broker.authorizeSubject(permit, call, subject, 9));
        broker.updatePermissionPolicy(.{ .mode = .auto });
        try std.testing.expect(try broker.poll(permit));
        var changed = call;
        changed.operation_id += 1;
        try std.testing.expectEqual(@import("fetch_url.zig").Decision.scope_changed, broker.authorizeSubject(permit, changed, subject, 9));
        broker.stop();
        try std.testing.expectError(error.CancelledBeforeDispatch, broker.poll(permit));
    }
}

test "automatic permission follows valid URL redirects while retaining transport and scope restrictions" {
    const a = std.testing.allocator;
    var broker: approval.Broker = .{};
    const ctx = context();
    try broker.configure(ctx, 9);
    broker.updatePermissionPolicy(.{ .mode = .auto });
    const json = "{\"url\":\"https://example.test/\"}";
    const parsed = try std.json.parseFromSlice(std.json.Value, a, json, .{});
    defer parsed.deinit();
    const call = try invocation(ctx, parsed.value, json);
    const permit = try broker.request(call, "https://example.test/", 9, a, null);
    defer broker.finish(permit);
    const Decision = @import("fetch_url.zig").Decision;
    try std.testing.expectEqual(Decision.allow, broker.authorize(permit, call, "https://other.example.test/final", 9));
    for ([_][]const u8{ "file:///tmp/private", "http://127.0.0.1/", "http://169.254.169.254/", "https://user:secret@example.test/" }) |url| {
        try std.testing.expectEqual(Decision.denied, broker.authorize(permit, call, url, 9));
    }
    var changed = call;
    changed.context.task_id = identity.TaskId.generate();
    try std.testing.expectEqual(Decision.scope_changed, broker.authorize(permit, changed, "https://other.example.test/final", 9));
    broker.updatePermissionPolicy(.{ .mode = .confirm });
    try std.testing.expectEqual(Decision.approval_required, broker.authorize(permit, call, "https://other.example.test/final", 9));
    try broker.decide(permit.sequence, permit.arguments_hash, true);
    try std.testing.expectEqual(Decision.allow, broker.authorize(permit, call, "https://example.test/", 9));
    try std.testing.expectEqual(Decision.approval_required, broker.authorize(permit, call, "https://other.example.test/final", 9));
    broker.stop();
    try std.testing.expectEqual(Decision.scope_changed, broker.authorize(permit, call, "https://other.example.test/final", 9));
}
