const std = @import("std");
const tools = @import("ai/host_transfer.zig");
const runtime = @import("ai/host_transfer_runtime.zig");
const host = @import("ai/host_tools.zig");
const identity = @import("host/identity.zig");
const transfer = @import("transfer/manager.zig");
const a = std.testing.allocator;
fn context() host.Context {
    return .{ .conversation_id = .{ .bytes = @splat(1) }, .task_id = .{ .bytes = @splat(2) }, .binding = .{ .session = 7 }, .binding_revision = 3, .grant_revision = 4 };
}
const owner: identity.SessionHandle = .{ .session_id = @fromBackingInt(@intCast(7)), .generation = 9 };
const upload = "{\"session_ref\":\"s1:01010101010101010101010101010101:7:9\",\"local_path\":\"/tmp/大文件 with spaces.bin\",\"remote_directory\":\"/remote/目标\",\"request_key\":\"binary-1\"}";
const download = "{\"session_ref\":\"s1:01010101010101010101010101010101:7:9\",\"remote_path\":\"/remote/binary.bin\",\"request_key\":\"download-1\"}";
fn invocation(name: []const u8, args: std.json.Value, wire: []const u8) !host.Invocation {
    var hash: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(wire, &hash, .{});
    return .{ .context = context(), .authority = if (tools.mutates(tools.kind(name).?)) .lifecycle else .conversation_context, .operation_id = 8, .turn_id = 9, .call_id = "transfer-call", .tool_id = name, .arguments = args, .arguments_json = wire, .arguments_hash = hash, .canonical_arguments_hash = try @import("ai/canonical_arguments.zig").digest(a, args) };
}
fn json(wire: []const u8) !std.json.Parsed(std.json.Value) {
    return std.json.parseFromSlice(std.json.Value, a, wire, .{});
}
const Fake = struct {
    submissions: usize = 0,
    cancellations: usize = 0,
    denied: bool = false,
    default_directory: []const u8 = "/Users/test/Downloads",
    captured_target: []const u8 = "",
    progress: transfer.Progress = .{ .job = 41, .done_bytes = 0, .total_bytes = 1024 * 1024 * 1024, .speed_bps = 0, .state = .queued, .attempt = 0, .retry_at_ms = null, .failure = null },
    fn backend(self: *@This()) tools.Backend {
        return .{ .context = self, .validate = validate, .submit = submit, .progress = get, .cancel = cancel, .downloadDirectory = directory };
    }
    fn validate(raw: *anyopaque, ctx: host.Context, target: identity.SessionHandle, live: bool) !void {
        _ = live;
        const self: *@This() = @ptrCast(@alignCast(raw));
        if (self.denied or !ctx.eql(context()) or !target.eql(owner)) return error.TargetNotAuthorized;
    }
    fn submit(raw: *anyopaque, request: tools.Request) !transfer.JobId {
        const self: *@This() = @ptrCast(@alignCast(raw));
        self.submissions += 1;
        self.captured_target = request.destination;
        return self.progress.job;
    }
    fn get(raw: *anyopaque, job: transfer.JobId) ?transfer.Progress {
        const self: *@This() = @ptrCast(@alignCast(raw));
        return if (job == self.progress.job) self.progress else null;
    }
    fn cancel(raw: *anyopaque, job: transfer.JobId) !void {
        const self: *@This() = @ptrCast(@alignCast(raw));
        if (job != self.progress.job) return error.TransferUnavailable;
        self.cancellations += 1;
        self.progress.state = .cancelling;
    }
    fn directory(raw: *anyopaque, allocator: std.mem.Allocator) ![]u8 {
        const self: *@This() = @ptrCast(@alignCast(raw));
        return allocator.dupe(u8, self.default_directory);
    }
};
test "AI transfer strict schemas and absolute paths reject escalation and stale references" {
    var table = try @import("ai/plugin_tools.zig").RequestTable.initWithHost(a, .{ .owner = context().binding, .members = .{} }, &.{}, &.{}, context(), &tools.contributions);
    defer table.deinit();
    try std.testing.expectEqual(@as(usize, 5), table.entries.len);
    const parsed = try json(upload);
    defer parsed.deinit();
    const call = try invocation("host.upload_file", parsed.value, upload);
    const request = try tools.parse(call);
    try std.testing.expectEqual(owner, request.owner.?);
    try std.testing.expectEqualStrings("/tmp/大文件 with spaces.bin", request.source);
    const bad = [_][]const u8{
        "{\"session_ref\":\"s1:01010101010101010101010101010101:7:9\",\"local_path\":\"relative.bin\",\"remote_directory\":\"/tmp\",\"request_key\":\"x\"}",
        "{\"session_ref\":\"s1:02020202020202020202020202020202:7:9\",\"local_path\":\"/tmp/x\",\"remote_directory\":\"/tmp\",\"request_key\":\"x\"}",
        "{\"session_ref\":\"s1:01010101010101010101010101010101:7:9\",\"local_path\":\"/tmp/x\",\"remote_directory\":\"/tmp\",\"request_key\":\"x\",\"approval_sequence\":1}",
        "{\"session_ref\":\"s1:01010101010101010101010101010101:7:9\",\"local_path\":\"/tmp/\\nfile\",\"remote_directory\":\"/tmp\",\"request_key\":\"x\"}",
    };
    for (bad) |wire| {
        const args = try json(wire);
        defer args.deinit();
        const result = tools.parse(try invocation("host.upload_file", args.value, wire));
        if (result) |_| return error.ExpectedRejection else |_| {}
    }
}
test "AI transfer binary queue submission is approved once and original destination is frozen" {
    var fake: Fake = .{};
    var registry = tools.Registry.init(a);
    defer registry.deinit();
    const parsed = try json(download);
    defer parsed.deinit();
    var call = try invocation("host.download_file", parsed.value, download);
    var prepared = try registry.prepare(call, fake.backend(), a);
    defer prepared.deinit(a);
    const op: identity.HostOperationId = .{ .bytes = @splat(3) };
    try std.testing.expectError(error.HostApprovalRequired, registry.submit(call, op, prepared, fake.backend(), a));
    fake.default_directory = "/changed-after-approval";
    call.approval_sequence = 1;
    var result = try registry.submit(call, op, prepared, fake.backend(), a);
    defer result.deinit(a);
    try result.validate(call.context, call.operation_id);
    try std.testing.expectEqualStrings("/Users/test/Downloads", fake.captured_target);
    try std.testing.expect(result.blocks[0].structured.len < 2048);
    const value = try json(result.blocks[0].structured);
    defer value.deinit();
    try std.testing.expect(!value.value.object.get("completed").?.bool);
    try std.testing.expectEqualStrings("queued", value.value.object.get("state").?.string);
    var repeat = try registry.submit(call, op, prepared, fake.backend(), a);
    defer repeat.deinit(a);
    try std.testing.expectEqual(@as(usize, 1), fake.submissions);
    call.canonical_arguments_hash[0] ^= 1;
    try std.testing.expectError(error.IdempotencyConflict, registry.submit(call, op, prepared, fake.backend(), a));
}
test "AI transfer progress requires actual cleanup and cancellation never replaces original job" {
    var fake: Fake = .{};
    var registry = tools.Registry.init(a);
    defer registry.deinit();
    const parsed = try json(upload);
    defer parsed.deinit();
    var call = try invocation("host.upload_file", parsed.value, upload);
    var prepared = try registry.prepare(call, fake.backend(), a);
    defer prepared.deinit(a);
    call.approval_sequence = 1;
    const op: identity.HostOperationId = .{ .bytes = @splat(4) };
    var accepted = try registry.submit(call, op, prepared, fake.backend(), a);
    defer accepted.deinit(a);
    const reference = try tools.reference(a, context(), op);
    defer a.free(reference);
    const wire = try std.json.Stringify.valueAlloc(a, .{ .transfer_ref = reference, .wait_ms = 0 }, .{});
    defer a.free(wire);
    const args = try json(wire);
    defer args.deinit();
    var query = try invocation("host.wait_transfer", args.value, wire);
    fake.progress.state = .succeeded;
    fake.progress.done_bytes = fake.progress.total_bytes;
    try std.testing.expect(!tools.waitSettled(fake.progress));
    var pending = try registry.query(query, fake.backend(), a, true);
    defer pending.deinit(a);
    const pending_value = try json(pending.blocks[0].structured);
    defer pending_value.deinit();
    try std.testing.expect(!pending_value.value.object.get("completed").?.bool);
    try std.testing.expect(pending_value.value.object.get("wait_timed_out").?.bool);
    try std.testing.expect(!pending.receipt.side_effect_started);
    fake.progress.job_cleanup = .released;
    try std.testing.expect(tools.waitSettled(fake.progress));
    var completed = try registry.query(query, fake.backend(), a, false);
    defer completed.deinit(a);
    const completed_value = try json(completed.blocks[0].structured);
    defer completed_value.deinit();
    try std.testing.expect(completed_value.value.object.get("completed").?.bool);
    fake.progress.state = .failed;
    for ([_]transfer.Failure{ .source_not_found, .destination_directory_not_found }) |failure| {
        fake.progress.failure = failure;
        var failed = try registry.query(query, fake.backend(), a, false);
        defer failed.deinit(a);
        const value = try json(failed.blocks[0].structured);
        defer value.deinit();
        try std.testing.expectEqualStrings(@tagName(failure), value.value.object.get("failure").?.string);
        try std.testing.expect(!value.value.object.get("completed").?.bool);
    }
    fake.denied = true;
    try std.testing.expectError(error.TargetNotAuthorized, registry.query(query, fake.backend(), a, false));
    fake.denied = false;
    query.context.conversation_id.bytes[0] ^= 1;
    try std.testing.expectError(error.StaleReference, registry.query(query, fake.backend(), a, false));
    query.context = context();
    const cancel_wire = try std.json.Stringify.valueAlloc(a, .{ .transfer_ref = reference }, .{});
    defer a.free(cancel_wire);
    const cancel_args = try json(cancel_wire);
    defer cancel_args.deinit();
    var cancellation = try invocation("host.cancel_transfer", cancel_args.value, cancel_wire);
    try std.testing.expectError(error.HostApprovalRequired, registry.cancel(cancellation, fake.backend(), a));
    cancellation.approval_sequence = 2;
    var cancelled = try registry.cancel(cancellation, fake.backend(), a);
    defer cancelled.deinit(a);
    try std.testing.expectEqual(@as(usize, 1), fake.submissions);
    try std.testing.expectEqual(@as(usize, 1), fake.cancellations);
    fake.progress.conflict_waiting = true;
    try std.testing.expect(tools.waitSettled(fake.progress));
}
test "AI transfer durable request key survives lost reply and restart without redispatch" {
    const ProcessJournal = @import("ai/lifecycle_runtime.zig").ProcessJournal;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const parsed = try json(upload);
    defer parsed.deinit();
    var call = try invocation("host.upload_file", parsed.value, upload);
    const journal = try ProcessJournal.acquire(.{ .data_root = "/test/ai-transfer", .dir = tmp.dir, .io = std.testing.io });
    var operation = try runtime.begin(journal, call, a);
    const original = operation.handle.operation_ref;
    try operation.dispatched(); // Simulate interruption after dispatch, before receipt.
    operation.deinit(a);
    journal.release();
    const reopened = try ProcessJournal.acquire(.{ .data_root = "/test/ai-transfer", .dir = tmp.dir, .io = std.testing.io });
    defer reopened.release();
    call.call_id = "new-call";
    call.turn_id += 1;
    var repeat = try runtime.begin(reopened, call, a);
    defer repeat.deinit(a);
    try std.testing.expect(repeat.handle.reused and repeat.handle.operation_ref.eql(original));
    try std.testing.expectError(error.OperationAlreadyStarted, repeat.dispatched());
    var result = try repeat.failureResult(call, null, a);
    defer result.deinit(a);
    try std.testing.expectEqual(@import("ai/plugin_tools.zig").Status.outcome_unknown, result.status);
    try std.testing.expect(result.receipt.remote_effect_unknown);
    const changed_wire = "{\"session_ref\":\"s1:01010101010101010101010101010101:7:9\",\"local_path\":\"/different.bin\",\"remote_directory\":\"/remote/目标\",\"request_key\":\"binary-1\"}";
    const changed_args = try json(changed_wire);
    defer changed_args.deinit();
    try std.testing.expectError(error.IdempotencyConflict, runtime.begin(reopened, try invocation("host.upload_file", changed_args.value, changed_wire), a));
    call.canonical_arguments_hash[0] ^= 1;
    try std.testing.expectError(error.InvalidArguments, runtime.begin(reopened, call, a));
}

test "AI transfer approval follows automatic and confirm modes and freezes destination evidence" {
    const Approval = @import("ai/host_approval.zig");
    var broker: Approval.Broker = .{};
    try broker.configure(context(), 17);
    var fake: Fake = .{};
    var registry = tools.Registry.init(a);
    defer registry.deinit();
    const args = try json(download);
    defer args.deinit();
    const call = try invocation("host.download_file", args.value, download);
    var prepared = try registry.prepare(call, fake.backend(), a);
    defer prepared.deinit(a);
    const permit = try broker.beginSubject(call, prepared.subject(), 17, a);
    defer broker.finish(permit);
    try std.testing.expect(!try broker.poll(permit));
    broker.updatePermissionPolicy(.{ .mode = .auto });
    try std.testing.expect(try broker.poll(permit));
    try std.testing.expectEqual(@import("ai/fetch_url.zig").Decision.allow, broker.authorizeSubject(permit, call, prepared.subject(), 17));
    var changed = prepared;
    changed.detail = @constCast("different destination");
    try std.testing.expect(broker.authorizeSubject(permit, call, changed.subject(), 17) != .allow);
    broker.updatePermissionPolicy(.{ .mode = .confirm });
    try std.testing.expect(!try broker.poll(permit));
    try broker.decide(permit.sequence, permit.arguments_hash, false);
    try std.testing.expectError(error.ToolApprovalRejected, broker.poll(permit));
    try std.testing.expectEqual(@as(usize, 0), fake.submissions);
}

// Called from ai_tools' own test so its private controller pump remains private.
pub fn exerciseWorker(bridge: *@import("ui/ai_tools.zig").Bridge, pump: *const fn (*@import("ui/ai_tools.zig").Bridge) void) !void {
    const controller = @import("ui/ai_transfer_controller.zig");
    const Bridge = @import("ui/ai_tools.zig").Bridge;
    const Worker = struct {
        access: controller.Access,
        bridge: *Bridge,
        call: host.Invocation,
        token: @import("ai/provider.zig").CancelToken = .{},
        done: std.atomic.Value(bool) = .init(false),
        result: ?host.Result = null,
        failure: ?anyerror = null,
        fn run(self: *@This()) void {
            self.result = controller.execute(self.access, self.bridge, self.call, a, &self.token) catch |err| blk: {
                self.failure = err;
                break :blk null;
            };
            self.done.store(true, .release);
        }
        fn await(self: *@This(), pump_fn: *const fn (*Bridge) void) !host.Result {
            const thread = try std.Thread.spawn(.{}, run, .{self});
            defer {
                if (!self.done.load(.acquire)) self.token.cancel();
                thread.join();
            }
            const clock: @import("ai/retry.zig").Clock = .{};
            const deadline = clock.now() + 4 * std.time.ns_per_s;
            while (!self.done.load(.acquire) and clock.now() < deadline) {
                pump_fn(self.bridge);
                clock.sleep(std.time.ns_per_ms);
            }
            if (!self.done.load(.acquire)) return error.TransferWorkerTimeout;
            if (self.failure) |err| return err;
            return self.result orelse error.MissingResult;
        }
        fn validate(_: *anyopaque, ctx: host.Context) !void {
            if (!ctx.eql(context())) return error.ScopeChanged;
        }
    };
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const journal = try @import("ai/lifecycle_runtime.zig").ProcessJournal.acquire(.{ .data_root = "/test/transfer-worker", .dir = tmp.dir, .io = std.testing.io });
    defer journal.release();
    var registry = tools.Registry.init(a);
    defer registry.deinit();
    var fake: Fake = .{};
    var broker: @import("ai/host_approval.zig").Broker = .{};
    try broker.configure(context(), 17);
    broker.updatePermissionPolicy(.{ .mode = .auto });
    bridge.route_broker = &broker;
    bridge.policy_revision = 17;
    defer bridge.route_broker = null;
    const args = try json(upload);
    defer args.deinit();
    var call = try invocation("host.upload_file", args.value, upload);
    for (0..2) |attempt| {
        if (attempt == 1) broker.updatePermissionPolicy(.{ .mode = .confirm });
        var worker: Worker = .{ .access = .{ .registry = &registry, .backend = fake.backend(), .approvals = &broker, .journal = journal, .policy_revision = 17, .validate_context = Worker.validate }, .bridge = bridge, .call = call };
        var result = try worker.await(pump);
        defer result.deinit(a);
        try std.testing.expectEqual(@import("ai/plugin_tools.zig").Status.succeeded, result.status);
        try std.testing.expectEqual(@as(usize, 1), fake.submissions);
        call.operation_id += 1;
        call.call_id = "repeat-provider-call";
    }
    const reference = try tools.reference(a, context(), registry.entries.items[0].operation);
    defer a.free(reference);
    broker.updatePermissionPolicy(.{ .mode = .auto });
    for ([_][]const u8{ "host.wait_transfer", "host.get_transfer", "host.cancel_transfer" }) |name| {
        const wire = if (std.mem.eql(u8, name, "host.wait_transfer")) try std.json.Stringify.valueAlloc(a, .{ .transfer_ref = reference, .wait_ms = 10 }, .{}) else try std.json.Stringify.valueAlloc(a, .{ .transfer_ref = reference }, .{});
        defer a.free(wire);
        const query_args = try json(wire);
        defer query_args.deinit();
        var worker: Worker = .{ .access = .{ .registry = &registry, .backend = fake.backend(), .approvals = &broker, .journal = journal, .policy_revision = 17, .validate_context = Worker.validate }, .bridge = bridge, .call = try invocation(name, query_args.value, wire) };
        var result = try worker.await(pump);
        defer result.deinit(a);
        const value = try json(result.blocks[0].structured);
        defer value.deinit();
        try std.testing.expectEqualStrings(reference, value.value.object.get("transfer_ref").?.string);
        if (std.mem.eql(u8, name, "host.wait_transfer")) try std.testing.expect(value.value.object.get("wait_timed_out").?.bool);
    }
    try std.testing.expectEqual(@as(usize, 1), fake.submissions);
    try std.testing.expectEqual(@as(usize, 1), fake.cancellations);
}

test "AI transfer lost result allocation retains original queue entry and owned paths" {
    var fake: Fake = .{};
    var registry = tools.Registry.init(a);
    defer registry.deinit();
    const parsed = try json(upload);
    defer parsed.deinit();
    var call = try invocation("host.upload_file", parsed.value, upload);
    call.approval_sequence = 1;
    var prepared = try registry.prepare(call, fake.backend(), a);
    defer prepared.deinit(a);
    const op: identity.HostOperationId = .{ .bytes = @splat(6) };
    var failing: std.testing.FailingAllocator = .init(a, .{ .fail_index = 0 });
    try std.testing.expectError(error.OutOfMemory, registry.submit(call, op, prepared, fake.backend(), failing.allocator()));
    try std.testing.expectEqual(@as(usize, 1), fake.submissions);
    try std.testing.expectEqualStrings("/tmp/大文件 with spaces.bin", registry.entries.items[0].source);
    var repeat = try registry.submit(call, op, prepared, fake.backend(), a);
    defer repeat.deinit(a);
    try std.testing.expectEqual(@as(usize, 1), fake.submissions);
}
