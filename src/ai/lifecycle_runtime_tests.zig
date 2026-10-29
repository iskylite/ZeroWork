const std = @import("std");
const backend = @import("lifecycle_runtime.zig");
const tools = @import("host_lifecycle.zig");
const host = @import("host_tools.zig");
const identity = @import("../host/identity.zig");
const journal = @import("lifecycle_journal.zig");
const a = std.testing.allocator;
const io = std.testing.io;
fn context() host.Context {
    return .{ .conversation_id = identity.ConversationId.generate(), .task_id = identity.TaskId.generate(), .binding = .{ .session = 101 }, .binding_revision = 1, .grant_revision = 1 };
}
fn synchronous(_: *anyopaque, raw: *anyopaque, invoke: *const fn (*anyopaque) anyerror!void, _: ?*@import("provider.zig").CancelToken) !void {
    try invoke(raw);
}
const Fixture = struct {
    owner: *backend.ProcessJournal,
    ctx: host.Context,
    prepare_count: usize = 0,
    publish_count: usize = 0,
    released_count: usize = 0,
    open_count: usize = 0,
    dispatch_count: usize = 0,
    close_count: usize = 0,
    ack_count: usize = 0,
    fail_after_publish: bool = false,
    fail_before_dispatch: bool = false,
    approval_required: bool = false,
    close_authorized: bool = true,
    last_operation: ?identity.HostOperationId = null,
    snapshot: ?tools.lifecycle.Snapshot = null,
    fn invoke(raw: *anyopaque, call: *backend.Call) !void {
        const self: *@This() = @ptrCast(@alignCast(raw));
        switch (call.action) {
            .authorize => |request| {
                if (!self.close_authorized and request.kind == .close_session) return error.CloseApprovalRequired;
                call.result = .{ .authorized = .{ .source = request.source, .saved_source = request.saved_source, .session = request.session, .group = request.group, .retention = request.retention orelse .auto_idle, .approval_required = self.approval_required, .explicit_user_close = self.close_authorized } };
            },
            .prepare_group => |request| {
                self.prepare_count += 1;
                self.last_operation = request.operation;
                if (self.fail_before_dispatch) try self.owner.dir.?.writeFile(io, .{ .sub_path = self.owner.path, .data = "disk changed before dispatch" });
                call.result = .{ .group_plan = .{ .id = 77, .token = self, .binding_revision = 2, .notice_revision = 2 } };
            },
            .commit_group => {
                self.publish_count += 1;
                try std.testing.expectEqual(journal.Stage.dispatch_started, self.owner.store.?.records.items[0].stage);
                try std.testing.expectEqual(@as(?u64, 77), self.owner.store.?.records.items[0].created_group);
                if (self.fail_after_publish) try self.owner.dir.?.writeFile(io, .{ .sub_path = self.owner.path, .data = "disk changed during publication" });
            },
            .release_group => self.released_count += 1,
            .queue_open => |request| {
                self.open_count += 1;
                self.snapshot = .{ .operation_ref = request.operation_ref, .context = request.context, .group = request.group, .source = request.source, .saved_source = request.saved_source, .session = .{ .session_id = @fromBackingInt(102), .generation = 3 }, .state = .prepared, .retention = request.retention, .revision = 2 };
                call.result = .{ .session = self.snapshot.? };
            },
            .authorize_open => |request| {
                self.dispatch_count += 1;
                const fact = self.owner.store.?.records.items[0];
                try std.testing.expectEqual(journal.Stage.dispatch_started, fact.stage);
                try std.testing.expect(fact.created_session.?.eql(request.session));
                try std.testing.expectEqual(journal.Ownership.created_task, fact.ownership);
                try std.testing.expectEqual(@as(u64, 2), request.revision);
                call.result = .{ .session = self.snapshot.? };
            },
            .query_open, .resolve_owned => call.result = .{ .session = self.snapshot.? },
            .queue_close => |request| {
                self.close_count += 1;
                self.last_operation = request.operation;
                call.result = .{ .close = .{ .operation_ref = request.operation, .session = request.session, .state = .awaiting_result } };
            },
            .acknowledge_close => self.ack_count += 1,
            .set_retention => |request| {
                self.snapshot.?.retention = request.retention;
                self.snapshot.?.ownership_revision += 1;
                self.snapshot.?.revision += 1;
                call.result = .{ .session = self.snapshot.? };
            },
            .cancel_open => {},
            else => return error.UnsupportedFixtureAction,
        }
    }
    fn runtime(self: *@This()) backend.Runtime {
        return .{ .journal_owner = self.owner, .controller = .{ .context = self, .invoke = invoke } };
    }
    fn scheduler(self: *@This()) backend.Scheduler {
        return .{ .context = self, .call = synchronous };
    }
};
fn execute(fixture: *Fixture, tool: []const u8, args: []const u8) !host.Result {
    const parsed = try std.json.parseFromSlice(std.json.Value, a, args, .{});
    defer parsed.deinit();
    var raw_hash: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(args, &raw_hash, .{});
    var runtime = fixture.runtime();
    return runtime.execute(fixture.scheduler(), .{ .context = fixture.ctx, .authority = .lifecycle, .operation_id = 1, .turn_id = 1, .call_id = "real-call", .tool_id = tool, .arguments = parsed.value, .arguments_json = args, .arguments_hash = raw_hash, .canonical_arguments_hash = try @import("canonical_arguments.zig").digest(a, parsed.value) }, a, null);
}
fn createArgs(ctx: host.Context, name: []const u8) ![]const u8 {
    return std.fmt.allocPrint(a, "{{\"initial_session_ref\":\"s1:{s}:101:1\",\"name\":\"{s}\",\"request_key\":\"create-1\"}}", .{ std.fmt.bytesToHex(ctx.conversation_id.bytes, .lower), name });
}

test "lifecycle runtime shares one process IO owner across window registrations" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const first = try backend.ProcessJournal.acquire(.{ .data_root = "/test/shared-lifecycle", .dir = tmp.dir, .io = io });
    defer first.release();
    const second = try backend.ProcessJournal.acquire(.{ .data_root = "/test/shared-lifecycle", .dir = tmp.dir, .io = io });
    defer second.release();
    try std.testing.expect(first == second);
    try std.testing.expect(first.store == null); // UI acquire performs no IO.
    const ctx = context();
    const request: journal.Request = .{ .context = ctx, .tool_id = "host.create_group", .request_key = "one", .canonical_hash = @splat(1), .turn_id = 1, .call_id = "call" };
    const started = try first.begin(request);
    const repeated = try second.begin(request);
    try std.testing.expect(repeated.reused and repeated.operation_ref.eql(started.operation_ref));
}

test "lifecycle runtime publishes group only after durable intent and never republishes a repeated key" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const owner = try backend.ProcessJournal.acquire(.{ .data_root = "/test/group-lifecycle", .dir = tmp.dir, .io = io });
    defer owner.release();
    var fixture: Fixture = .{ .owner = owner, .ctx = context() };
    const args = try createArgs(fixture.ctx, "排障");
    defer a.free(args);
    var first = try execute(&fixture, "host.create_group", args);
    defer first.deinit(a);
    try first.validate(fixture.ctx, 1);
    try std.testing.expectEqual(@as(usize, 1), fixture.publish_count);
    try std.testing.expectEqual(journal.Stage.committed, owner.store.?.records.items[0].stage);
    // Scope refresh changes binding but cannot create another resource for key.
    fixture.ctx.binding = .{ .group = 77 };
    fixture.ctx.binding_revision = 2;
    var repeated = try execute(&fixture, "host.create_group", args);
    defer repeated.deinit(a);
    try std.testing.expectEqual(@as(usize, 1), fixture.prepare_count);
    try std.testing.expectEqual(@as(usize, 1), fixture.released_count);
    try std.testing.expectEqual(@import("plugin_tools.zig").Status.succeeded, repeated.status);
    const changed = try createArgs(fixture.ctx, "另一个组");
    defer a.free(changed);
    var conflict = try execute(&fixture, "host.create_group", changed);
    defer conflict.deinit(a);
    try std.testing.expect(std.mem.indexOf(u8, conflict.blocks[0].structured, "IdempotencyConflict") != null);
    try std.testing.expectEqual(@as(usize, 1), fixture.publish_count);
}

test "lifecycle runtime publication without durable confirmation stays unknown and cannot replay" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const owner = try backend.ProcessJournal.acquire(.{ .data_root = "/test/group-unknown", .dir = tmp.dir, .io = io });
    defer owner.release();
    var fixture: Fixture = .{ .owner = owner, .ctx = context(), .fail_after_publish = true };
    const args = try createArgs(fixture.ctx, "故障");
    defer a.free(args);
    var first = try execute(&fixture, "host.create_group", args);
    defer first.deinit(a);
    try std.testing.expectEqual(@import("plugin_tools.zig").Status.outcome_unknown, first.status);
    try std.testing.expect(first.receipt.side_effect_started and first.receipt.remote_effect_unknown);
    var repeated = try execute(&fixture, "host.create_group", args);
    defer repeated.deinit(a);
    try std.testing.expectEqual(@import("plugin_tools.zig").Status.outcome_unknown, repeated.status);
    try std.testing.expectEqual(@as(usize, 1), fixture.publish_count);
    try std.testing.expectEqual(@as(usize, 1), fixture.released_count);
}

test "lifecycle runtime owned-session dispatch is fenced by the durable exact handle" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const owner = try backend.ProcessJournal.acquire(.{ .data_root = "/test/open-lifecycle", .dir = tmp.dir, .io = io });
    defer owner.release();
    var ctx = context();
    ctx.binding = .{ .group = 77 };
    var fixture: Fixture = .{ .owner = owner, .ctx = ctx };
    const args = try std.fmt.allocPrint(a, "{{\"group_ref\":\"g1:{s}:77\",\"source_ref\":\"s1:{s}:101:1\",\"connection_policy\":\"new_only\",\"request_key\":\"open-1\"}}", .{ std.fmt.bytesToHex(ctx.conversation_id.bytes, .lower), std.fmt.bytesToHex(ctx.conversation_id.bytes, .lower) });
    defer a.free(args);
    var opened = try execute(&fixture, "host.open_session", args);
    defer opened.deinit(a);
    try opened.validate(ctx, 1);
    try std.testing.expectEqual(@import("plugin_tools.zig").Status.succeeded, opened.status);
    try std.testing.expect(std.mem.indexOf(u8, opened.blocks[0].structured, "opening") != null);
    var repeated = try execute(&fixture, "host.open_session", args);
    defer repeated.deinit(a);
    try std.testing.expectEqual(@as(usize, 1), fixture.open_count);
    try std.testing.expectEqual(@as(usize, 1), fixture.dispatch_count);
}

test "lifecycle runtime close waits for accepted-result acknowledgement and rejects ungranted borrowed close" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const owner = try backend.ProcessJournal.acquire(.{ .data_root = "/test/close-lifecycle", .dir = tmp.dir, .io = io });
    defer owner.release();
    var fixture: Fixture = .{ .owner = owner, .ctx = context(), .close_authorized = false };
    const args = try std.fmt.allocPrint(a, "{{\"session_ref\":\"s1:{s}:101:1\",\"request_key\":\"close-1\"}}", .{std.fmt.bytesToHex(fixture.ctx.conversation_id.bytes, .lower)});
    defer a.free(args);
    var denied = try execute(&fixture, "host.close_session", args);
    defer denied.deinit(a);
    try std.testing.expectEqual(@as(usize, 0), fixture.close_count);
    fixture.close_authorized = true;
    const allowed_args = try std.fmt.allocPrint(a, "{{\"session_ref\":\"s1:{s}:101:1\",\"request_key\":\"close-2\"}}", .{std.fmt.bytesToHex(fixture.ctx.conversation_id.bytes, .lower)});
    defer a.free(allowed_args);
    var accepted = try execute(&fixture, "host.close_session", allowed_args);
    defer accepted.deinit(a);
    try std.testing.expectEqual(@as(usize, 1), fixture.close_count);
    try std.testing.expectEqual(@as(usize, 0), fixture.ack_count);
    var runtime = fixture.runtime();
    try runtime.acknowledgeResult(fixture.scheduler(), fixture.ctx, fixture.last_operation.?);
    try std.testing.expectEqual(@as(usize, 1), fixture.ack_count);
}

test "lifecycle runtime journal failure before dispatch publishes nothing and releases preparation" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const owner = try backend.ProcessJournal.acquire(.{ .data_root = "/test/group-before-dispatch", .dir = tmp.dir, .io = io });
    defer owner.release();
    var fixture: Fixture = .{ .owner = owner, .ctx = context(), .fail_before_dispatch = true };
    const args = try createArgs(fixture.ctx, "失败");
    defer a.free(args);
    var result = try execute(&fixture, "host.create_group", args);
    defer result.deinit(a);
    try std.testing.expectEqual(@import("plugin_tools.zig").Status.failed, result.status);
    try std.testing.expect(!result.receipt.side_effect_started and !result.receipt.remote_effect_unknown);
    try std.testing.expectEqual(@as(usize, 0), fixture.publish_count);
    try std.testing.expectEqual(@as(usize, 1), fixture.released_count);
}

test "lifecycle runtime requires the precise lifecycle approval before preparing any resource" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const owner = try backend.ProcessJournal.acquire(.{ .data_root = "/test/group-approval", .dir = tmp.dir, .io = io });
    defer owner.release();
    var fixture: Fixture = .{ .owner = owner, .ctx = context(), .approval_required = true };
    const args = try createArgs(fixture.ctx, "审批");
    defer a.free(args);
    var result = try execute(&fixture, "host.create_group", args);
    defer result.deinit(a);
    try std.testing.expectEqual(@as(usize, 0), fixture.prepare_count);
    try std.testing.expect(std.mem.indexOf(u8, result.blocks[0].structured, "ApprovalRequired") != null);
    try std.testing.expect(!result.receipt.side_effect_started);
}

test "lifecycle runtime persists notice watermark only after matching task acknowledgement" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const owner = try backend.ProcessJournal.acquire(.{ .data_root = "/test/group-notice", .dir = tmp.dir, .io = io });
    defer owner.release();
    var fixture: Fixture = .{ .owner = owner, .ctx = context() };
    const args = try createArgs(fixture.ctx, "通知");
    defer a.free(args);
    var result = try execute(&fixture, "host.create_group", args);
    defer result.deinit(a);
    var runtime = fixture.runtime();
    var other = fixture.ctx;
    other.task_id = identity.TaskId.generate();
    try runtime.acknowledgeNotice(other, 2);
    try std.testing.expectEqual(@as(u64, 0), owner.store.?.records.items[0].wire_notice_revision);
    try runtime.acknowledgeNotice(fixture.ctx, 1);
    try std.testing.expectEqual(@as(u64, 0), owner.store.?.records.items[0].wire_notice_revision);
    try runtime.acknowledgeNotice(fixture.ctx, 2);
    try std.testing.expectEqual(@as(u64, 2), owner.store.?.records.items[0].wire_notice_revision);
    const revision = owner.store.?.records.items[0].revision;
    try runtime.acknowledgeNotice(fixture.ctx, 2);
    try std.testing.expectEqual(revision, owner.store.?.records.items[0].revision);
}

test "lifecycle runtime concurrent windows reserve a shared request key once" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const owner = try backend.ProcessJournal.acquire(.{ .data_root = "/test/concurrent-lifecycle", .dir = tmp.dir, .io = io });
    defer owner.release();
    const Worker = struct {
        owner: *backend.ProcessJournal,
        request: journal.Request,
        handle: ?journal.Handle = null,
        failure: ?anyerror = null,
        fn run(self: *@This()) void {
            self.handle = self.owner.begin(self.request) catch |err| blk: {
                self.failure = err;
                break :blk null;
            };
        }
    };
    const request: journal.Request = .{ .context = context(), .tool_id = "host.create_group", .request_key = "shared", .canonical_hash = @splat(5), .turn_id = 1, .call_id = "call" };
    var one: Worker = .{ .owner = owner, .request = request };
    var two: Worker = .{ .owner = owner, .request = request };
    const first = try std.Thread.spawn(.{}, Worker.run, .{&one});
    const second = try std.Thread.spawn(.{}, Worker.run, .{&two});
    first.join();
    second.join();
    try std.testing.expect(one.failure == null and two.failure == null);
    try std.testing.expect(one.handle.?.operation_ref.eql(two.handle.?.operation_ref));
    try std.testing.expect(one.handle.?.reused != two.handle.?.reused);
    try std.testing.expectEqual(@as(usize, 1), owner.store.?.records.items.len);
}

test "lifecycle runtime accepts saved connection sources without inventing a session handle" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const owner = try backend.ProcessJournal.acquire(.{ .data_root = "/test/saved-source-lifecycle", .dir = tmp.dir, .io = io });
    defer owner.release();
    var ctx = context();
    ctx.binding = .{ .group = 77 };
    var fixture: Fixture = .{ .owner = owner, .ctx = ctx };
    const args = try std.fmt.allocPrint(a, "{{\"group_ref\":\"g1:{s}:77\",\"source_ref\":\"c1:{s}:9:4\",\"connection_policy\":\"new_only\",\"request_key\":\"saved-1\"}}", .{ std.fmt.bytesToHex(ctx.conversation_id.bytes, .lower), std.fmt.bytesToHex(ctx.conversation_id.bytes, .lower) });
    defer a.free(args);
    var opened = try execute(&fixture, "host.open_session", args);
    defer opened.deinit(a);
    try std.testing.expectEqual(@import("plugin_tools.zig").Status.succeeded, opened.status);
    try std.testing.expect(fixture.snapshot.?.source == null);
    try std.testing.expectEqual(@as(u64, 9), @backingInt(fixture.snapshot.?.saved_source.?.id));
    try std.testing.expectEqual(@as(u64, 4), fixture.snapshot.?.saved_source.?.revision);
    try std.testing.expect(std.mem.indexOf(u8, opened.blocks[0].structured, "c1:") != null);
    const retention_args = try std.fmt.allocPrint(a, "{{\"session_ref\":\"s1:{s}:102:3\",\"retention\":\"keep\",\"request_key\":\"keep-1\"}}", .{std.fmt.bytesToHex(ctx.conversation_id.bytes, .lower)});
    defer a.free(retention_args);
    var retained = try execute(&fixture, "host.set_session_retention", retention_args);
    defer retained.deinit(a);
    try std.testing.expectEqual(@import("plugin_tools.zig").Status.succeeded, retained.status);
    try std.testing.expectEqual(tools.lifecycle.Retention.keep, fixture.snapshot.?.retention);
    const op_ref = try tools.operationRef(a, ctx, fixture.snapshot.?.operation_ref);
    defer a.free(op_ref);
    const wait_args = try std.fmt.allocPrint(a, "{{\"operation_ref\":\"{s}\",\"wait_ms\":0}}", .{op_ref});
    defer a.free(wait_args);
    var waiting = try execute(&fixture, "host.wait_session_ready", wait_args);
    defer waiting.deinit(a);
    try std.testing.expect(std.mem.indexOf(u8, waiting.blocks[0].structured, "\"timed_out\":true") != null);
    try std.testing.expect(!waiting.receipt.side_effect_started);
    try std.testing.expectEqual(@as(usize, 1), fixture.open_count);
    try std.testing.expectEqual(@as(usize, 1), fixture.dispatch_count);
}
