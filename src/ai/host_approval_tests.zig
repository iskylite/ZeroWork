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

test "host approval freezes URL call authority expiry and sequence without session targets" {
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
    now = pending.expires_at_ms;
    try std.testing.expectError(error.ToolApprovalExpired, broker.poll(permit));
    try std.testing.expectEqual(@import("fetch_url.zig").Decision.approval_required, broker.authorize(permit, call, "https://example.com/docs", 5));
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

test "host approval expiry suspends the worker until explicit renewal and a separate decision" {
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
    clock.value.store(frozen.expires_at_ms + 1000, .release);
    try @import("retry.zig").wait(30, null);
    try std.testing.expect(broker.snapshot().?.expired);
    try std.testing.expect(!worker.finished.load(.acquire));
    try std.testing.expectError(error.StaleApproval, broker.decide(frozen.sequence, frozen.arguments_hash, true));
    try broker.renew(frozen.sequence, frozen.arguments_hash);
    try std.testing.expect(!broker.snapshot().?.expired);
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
