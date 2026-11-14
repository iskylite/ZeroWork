const std = @import("std");
const life = @import("ai/session_lifecycle.zig");
const id = @import("host/identity.zig");
const Journal = @import("ai/session_journal.zig").Journal;
const scope = @import("ai/tool_scope.zig");
const a = std.testing.allocator;
const live: scope.Scope = .{ .owner = .{ .group = 7 }, .members = .{}, .inventory = &.{ 11, 12 } };
const handles = [_]id.SessionHandle{ .{ .session_id = @fromBackingInt(11), .generation = 3 }, .{ .session_id = @fromBackingInt(12), .generation = 5 } };
fn end(store: *life.Store, ticket: life.input.Fence) !void {
    const op = id.HostOperationId.generate();
    _ = try store.beginEnd(ticket, op);
    try store.commitEnd(ticket, op, .{ .worker_joined = true, .dispatch_closed = true, .local_released = true, .transcript_saved = true });
}

test "v0.4 child identity ownership, explicit scope and ordinary main indexes stay separate" {
    var store = life.Store.init(a);
    defer store.deinit();
    const parent = try store.attach(live.owner);
    const ticket = try store.create(parent.id);
    const child = try store.registerChild(ticket, .{ .name = "检查日志", .request_key = "log-check", .reusable = true }, null);
    const info = child.child.?.info;
    try std.testing.expect(child.parent == null and child.binding == null and child.history.messages.len == 0);
    try std.testing.expect(info.created_by_agent.eql(parent.id) and info.owning_parent_conversation.eql(ticket.conversation));
    try std.testing.expectEqual(parent, try store.attach(live.owner));
    try std.testing.expectEqual(child, try store.registerChild(ticket, .{ .name = "检查日志", .request_key = "log-check", .reusable = true }, null));
    try std.testing.expectError(error.ChildRequestConflict, store.registerChild(ticket, .{ .name = "另一任务", .request_key = "log-check" }, null));
    const bound = try store.bindChild(ticket, info.agent, child.revision, live, &.{handles[0]});
    try store.validateExecutionTarget(bound, handles[0], live, &handles);
    try std.testing.expectError(error.TargetOutsideAssistant, store.validateExecutionTarget(bound, handles[1], live, &handles));
    try std.testing.expectError(error.TargetOutsideAssistant, store.validateExecutionTarget(bound, .{ .session_id = handles[0].session_id, .generation = 4 }, live, &.{.{ .session_id = handles[0].session_id, .generation = 4 }}));
    try std.testing.expectError(error.ChildCannotDelegate, store.registerChild(bound, .{ .name = "grandchild", .request_key = "forbidden" }, null));
    try std.testing.expectError(error.ChildRequiresParent, store.create(info.agent));
    const other = try store.attach(.{ .session = 99 });
    const other_ticket = try store.create(other.id);
    try std.testing.expectError(error.ChildNotFound, store.childFor(other_ticket, info.agent));
    try std.testing.expectError(error.ChildRequiresParent, store.resumeConversation(child.id, other.id, child.revision));
    try std.testing.expectError(error.ChildRequiresParent, store.fork(child.id, child.content_revision));
    _ = try store.environmentChanged(parent.id);
    try std.testing.expectError(error.ParentBindingChanged, store.validateExecution(bound));
    // Evidence can still be saved after parent authority changes.
    try store.checkpoint(bound, 1, &.{.{ .content = "old fact" }}, true);
    try end(&store, bound);
}

test "v0.4 child inheritance freezes an owned legal prefix and never uses an old checkpoint" {
    var store = life.Store.init(a);
    defer store.deinit();
    const parent = try store.attach(live.owner);
    const ticket = try store.create(parent.id);
    try store.checkpoint(ticket, 1, &.{.{ .content = "outdated checkpoint" }}, true);
    var latest = [_]@import("ai/provider.zig").Message{.{ .content = "current consumed input" }};
    const source: life.child.Source = .{ .conversation = ticket.conversation, .content_revision = 3, .turn = 2, .message_count = latest.len };
    const child = try store.registerChild(ticket, .{ .name = "继承检查", .request_key = "inherit", .context_mode = .inherit }, .{ .source = source, .messages = &latest });
    latest[0].content = "parent changed later";
    try std.testing.expectError(error.ChildRequestConflict, store.registerChild(ticket, .{ .name = "继承检查", .request_key = "inherit", .context_mode = .inherit }, .{ .source = source, .messages = &latest }));
    try std.testing.expectEqualStrings("current consumed input", child.history.messages[0].content);
    try std.testing.expect(child.history.usage == null and child.presentation == null and child.parent == null);
    try std.testing.expectError(error.MissingInheritanceSnapshot, store.registerChild(ticket, .{ .name = "missing", .request_key = "missing", .context_mode = .inherit }, null));
    const dangling = [_]@import("ai/provider.zig").Message{.{ .role = .assistant, .content = "", .tool_calls = &.{.{ .id = "self-create", .name = "host__agent_utasks", .arguments = "{}" }} }};
    try std.testing.expectError(error.InvalidToolMessage, store.registerChild(ticket, .{ .name = "unsafe", .request_key = "unsafe", .context_mode = .inherit }, .{ .source = source, .messages = &dangling }));
    try std.testing.expectEqual(@as(usize, 1), store.childCount(ticket.conversation));
}

test "v0.4 child schema 2 mixes with old lines and reuses data after parent gets a new AgentId" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var journal = try Journal.open(a, std.testing.io, tmp.dir, "sessions.jsonl");
    defer journal.deinit();
    var store = life.Store.init(a);
    defer store.deinit();
    try journal.bind(&store);
    const parent = try store.attach(live.owner);
    const ticket = try store.create(parent.id);
    const child = try store.registerChild(ticket, .{ .name = "可复用", .request_key = "reuse", .reusable = true }, null);
    const child_id = child.id;
    const agent_id = child.child.?.info.agent;
    _ = try store.bindChild(ticket, agent_id, child.revision, live, &.{handles[1]});
    try std.testing.expect(std.mem.indexOf(u8, journal.bytes.items, "\"schema\":1") != null and std.mem.indexOf(u8, journal.bytes.items, "\"schema\":2") != null);
    var replayed = life.Store.init(a);
    defer replayed.deinit();
    try journal.bind(&replayed);
    try std.testing.expect(replayed.find(child_id).?.needs_recovery and replayed.agent(agent_id).?.closing);
    try std.testing.expectError(error.ChildSettlementRequired, replayed.recoverOrphan(ticket.conversation, .{ .worker_joined = true, .dispatch_closed = true, .local_released = true, .transcript_saved = true }));
    try replayed.recoverOrphan(child_id, .{ .worker_joined = true, .dispatch_closed = true, .local_released = true, .transcript_saved = true });
    try replayed.recoverOrphan(ticket.conversation, .{ .worker_joined = true, .dispatch_closed = true, .local_released = true, .transcript_saved = true });
    const new_parent = try replayed.attach(live.owner);
    try std.testing.expect(!new_parent.id.eql(parent.id));
    const restored = try replayed.resumeConversation(ticket.conversation, new_parent.id, replayed.find(ticket.conversation).?.revision);
    const saved_child = replayed.find(child_id).?;
    const rebound = try replayed.bindChild(restored, agent_id, saved_child.revision, live, &.{handles[0]});
    try std.testing.expect(saved_child.child.?.info.created_by_agent.eql(parent.id));
    try std.testing.expect(replayed.agent(agent_id).?.parent_binding.?.agent.eql(new_parent.id));
    try replayed.validateExecutionTarget(rebound, handles[0], live, &handles);
    try std.testing.expectEqual(new_parent, try replayed.attach(live.owner));
    try end(&replayed, rebound);
}

test "v0.4 child persistence failure and allocation failure publish no orphan identity" {
    const Failure = struct {
        fn write(_: *anyopaque, event: life.Event) !void {
            if (event.kind == .child_create or event.kind == .child_bind or event.kind == .remove_family) return error.StorageUnavailable;
        }
    };
    var store = life.Store.init(a);
    defer store.deinit();
    const parent = try store.attach(live.owner);
    const ticket = try store.create(parent.id);
    var sentinel: u8 = 0;
    store.persist = .{ .context = &sentinel, .write = Failure.write };
    try std.testing.expectError(error.StorageUnavailable, store.registerChild(ticket, .{ .name = "must rollback", .request_key = "rollback" }, null));
    try std.testing.expectEqual(@as(usize, 1), store.records.items.len);
    try std.testing.expectEqual(@as(usize, 1), store.agents.items.len);
    store.persist = null;
    const child = try store.registerChild(ticket, .{ .name = "child", .request_key = "child" }, null);
    store.persist = .{ .context = &sentinel, .write = Failure.write };
    try std.testing.expectError(error.StorageUnavailable, store.bindChild(ticket, child.child.?.info.agent, child.revision, live, &.{handles[0]}));
    try std.testing.expect(child.binding == null and store.agent(child.child.?.info.agent).?.targets.len == 0);
    store.persist = null;
    try end(&store, ticket);
    store.persist = .{ .context = &sentinel, .write = Failure.write };
    try std.testing.expectError(error.StorageUnavailable, store.removeFamily(ticket.conversation, store.find(ticket.conversation).?.revision, 1));
    try std.testing.expectEqual(@as(usize, 2), store.records.items.len);
    store.persist = null;
    try store.removeFamily(ticket.conversation, store.find(ticket.conversation).?.revision, 1);
    try std.testing.expectEqual(@as(usize, 0), store.records.items.len);
    const Check = struct {
        fn run(alloc: std.mem.Allocator) !void {
            var local = life.Store.init(alloc);
            defer local.deinit();
            const p = try local.attach(live.owner);
            const f = try local.create(p.id);
            const c = try local.registerChild(f, .{ .name = "owned strings", .request_key = "allocation", .model = .{ .provider_id = "provider", .model_id = "model" } }, null);
            _ = try local.bindChild(f, c.child.?.info.agent, c.revision, live, &.{handles[0]});
        }
    };
    try std.testing.checkAllAllocationFailures(a, Check.run, .{});
}

test "v0.4 child presentations never deselect the parent and family deletion is explicit" {
    var store = life.Store.init(a);
    defer store.deinit();
    const parent = try store.attach(live.owner);
    const ticket = try store.create(parent.id);
    const child = try store.registerChild(ticket, .{ .name = "child", .request_key = "child" }, null);
    var presentation = @import("ai/assistant_store.zig").Store.init(a);
    defer presentation.deinit();
    const main = try presentation.create(live.owner);
    const main_id = main.id;
    main.conversation_id = ticket.conversation;
    const view = try presentation.createChildPresentation(child, live.owner);
    try std.testing.expect(!view.selected and !view.listed and !presentation.select(view.id));
    try std.testing.expectEqual(main_id, presentation.active(live.owner).?.id);
    const bound = try store.bindChild(ticket, child.child.?.info.agent, child.revision, live, &.{handles[0]});
    const op = id.HostOperationId.generate();
    _ = try store.beginEnd(ticket, op);
    try std.testing.expectError(error.ChildSettlementRequired, store.commitEnd(ticket, op, .{ .worker_joined = true, .dispatch_closed = true, .local_released = true, .transcript_saved = true }));
    try end(&store, bound);
    try store.commitEnd(ticket, op, .{ .worker_joined = true, .dispatch_closed = true, .local_released = true, .transcript_saved = true });
    try std.testing.expectError(error.ChildRecordsPresent, store.remove(ticket.conversation));
    try std.testing.expectError(error.ChildRequiresParent, store.remove(child.id));
    const child_id = child.id;
    try store.removeFamily(ticket.conversation, store.find(ticket.conversation).?.revision, 1);
    try std.testing.expect(store.find(child_id) == null);
}

const Runtime = @import("ai/session_runtime.zig");
const WorkerFixture = struct {
    calls: std.atomic.Value(usize) = .init(0),
    release: std.atomic.Value(bool) = .init(false),
    saw_child: std.atomic.Value(bool) = .init(false),
    release_pending: usize = 0,
    hold_projection: bool = false,
    fn backend(self: *WorkerFixture) Runtime.Backend {
        return .{ .context = self, .prepare = prepare, .release_worker = releaseWorker };
    }
    fn releaseWorker(raw: *anyopaque) !void {
        const self: *WorkerFixture = @ptrCast(@alignCast(raw));
        if (self.release_pending == 0) return;
        self.release_pending -= 1;
        return error.ResourceCleanupPending;
    }
    fn prepare(raw: *anyopaque, _: std.mem.Allocator, _: std.Io, context: Runtime.Context) !Runtime.Prepared {
        const self: *WorkerFixture = @ptrCast(@alignCast(raw));
        try context.authority().validate();
        self.saw_child.store(context.child_origin != null, .release);
        return .{ .provider = .{ .ctx = raw, .chat = chat, .models = models }, .request = .{ .model = "mock", .system = "", .messages = &.{} }, .scope = .{ .owner = context.owner, .members = .{} } };
    }
    fn chat(raw: *anyopaque, request: @import("ai/provider.zig").ChatRequest, sink: *const fn (*anyopaque, @import("ai/provider.zig").Delta) void, output: *anyopaque) !@import("ai/provider.zig").ChatStats {
        const self: *WorkerFixture = @ptrCast(@alignCast(raw));
        _ = self.calls.fetchAdd(1, .acq_rel);
        if (self.saw_child.load(.acquire)) try std.testing.expect(std.mem.indexOf(u8, request.system, "不能再派生") != null);
        while (!self.release.load(.acquire)) {
            if (!self.hold_projection) if (request.cancel) |cancel| if (cancel.isCancelled()) return error.Cancelled;
            std.Thread.yield() catch {};
        }
        sink(output, .{ .text = "child completed" });
        sink(output, .done);
        return .{};
    }
    fn models(_: *anyopaque, alloc: std.mem.Allocator) ![]@import("ai/provider.zig").ModelInfo {
        return alloc.alloc(@import("ai/provider.zig").ModelInfo, 0);
    }
    fn started(self: *WorkerFixture) !void {
        const start = std.Io.Clock.Timestamp.now(std.testing.io, .awake);
        while (self.calls.load(.acquire) == 0) {
            if (start.durationTo(std.Io.Clock.Timestamp.now(std.testing.io, .awake)).raw.toMilliseconds() > 3000) return error.WorkerTimeout;
            std.Thread.yield() catch {};
        }
    }
};
fn awaitIdle(service: *Runtime.Service, runner: *Runtime.Runner) !void {
    const start = std.Io.Clock.Timestamp.now(std.testing.io, .awake);
    while (runner.thread != null or runner.agent.busy or runner.pending_commit or runner.pending_notify) {
        try service.poll();
        if (start.durationTo(std.Io.Clock.Timestamp.now(std.testing.io, .awake)).raw.toMilliseconds() > 3000) return error.WorkerTimeout;
        std.Thread.yield() catch {};
    }
}

test "v0.4 child real independent Workers preserve main owner and parent End drains every child" {
    var parent_provider: WorkerFixture = .{};
    var child_provider: WorkerFixture = .{};
    var other_provider: WorkerFixture = .{};
    var service = Runtime.Service.init(a);
    defer service.deinit();
    const parent = try service.attach(live.owner, parent_provider.backend());
    const parent_fence = try service.store.create(parent.agent.id);
    _ = try service.submit(parent_fence, .generate(), .{ .content = "root task" }, null);
    try parent_provider.started();
    const child = try service.store.registerChild(parent_fence, .{ .name = "independent", .request_key = "work", .reusable = true }, null);
    const runner = try service.useChild(parent_fence, child.child.?.info.agent, child.revision, live, &.{handles[0]}, child_provider.backend(), parent.context.?.task);
    const child_fence = try service.store.fence(child.id);
    try std.testing.expect(runner.worker == null and child_provider.calls.load(.acquire) == 0);
    _ = try service.submit(child_fence, .generate(), .{ .content = "delegated task" }, null);
    try child_provider.started();
    try std.testing.expect(runner != parent and runner.worker != parent.worker and runner.context.?.root_task.eql(parent.context.?.task));
    try std.testing.expect(child_provider.saw_child.load(.acquire));
    try std.testing.expectEqual(parent, try service.attach(live.owner, child_provider.backend()));
    const authority = runner.context.?.authority();
    _ = try service.validateAuthority(authority);
    var forged = authority;
    forged.child_origin = null;
    try std.testing.expectError(error.ScopeChanged, service.validateAuthority(forged));
    const other = try service.attach(.{ .session = 99 }, other_provider.backend());
    const other_fence = try service.store.create(other.agent.id);
    _ = try service.submit(other_fence, .generate(), .{ .content = "unrelated task" }, null);
    try other_provider.started();
    try service.endConversation(parent_fence, .generate());
    const start = std.Io.Clock.Timestamp.now(std.testing.io, .awake);
    while (parent.agent.current != null) {
        try service.poll();
        if (start.durationTo(std.Io.Clock.Timestamp.now(std.testing.io, .awake)).raw.toMilliseconds() > 3000) return error.WorkerTimeout;
        std.Thread.yield() catch {};
    }
    try std.testing.expect(parent.worker == null and runner.worker == null and runner.agent.current == null);
    try std.testing.expect(other.agent.busy and !other.worker.?.cancel.isCancelled());
    try std.testing.expectError(error.ScopeChanged, service.validateAuthority(authority));
    try std.testing.expectEqual(@as(usize, 1), child_provider.calls.load(.acquire));
    try service.stop(other_fence);
    try awaitIdle(&service, other);
    const restored = try service.resumeConversation(parent_fence.conversation, parent.agent.id, service.store.find(parent_fence.conversation).?.revision);
    child_provider.release.store(true, .release);
    const reused = try service.useChild(restored, runner.agent.id, child.revision, live, &.{handles[1]}, child_provider.backend(), null);
    try std.testing.expectEqual(runner, reused);
    try std.testing.expect(reused.worker == null);
    _ = try service.submit(try service.store.fence(child.id), .generate(), .{ .content = "new explicit task" }, null);
    try awaitIdle(&service, reused);
    try std.testing.expectEqual(@as(u64, 2), reused.worker_generation);
    try std.testing.expect(!reused.context.?.task.eql(authority.task_id) and reused.context.?.parent_task == null);
    try std.testing.expectError(error.ScopeChanged, service.validateAuthority(authority));
    try service.endConversation(restored, .generate());
    try service.poll();
}

test "v0.4 child Stop follows only its root while End also closes user directed work" {
    var root_provider: WorkerFixture = .{};
    var delegated_provider: WorkerFixture = .{};
    var user_provider: WorkerFixture = .{};
    var service = Runtime.Service.init(a);
    defer service.deinit();
    const root = try service.attach(live.owner, root_provider.backend());
    const ticket = try service.store.create(root.agent.id);
    _ = try service.submit(ticket, .generate(), .{ .content = "parent" }, null);
    try root_provider.started();
    const delegated_record = try service.store.registerChild(ticket, .{ .name = "delegated", .request_key = "delegated" }, null);
    const user_record = try service.store.registerChild(ticket, .{ .name = "user", .request_key = "user" }, null);
    const delegated = try service.useChild(ticket, delegated_record.child.?.info.agent, delegated_record.revision, live, &.{handles[0]}, delegated_provider.backend(), root.context.?.task);
    const user = try service.useChild(ticket, user_record.child.?.info.agent, user_record.revision, live, &.{handles[1]}, user_provider.backend(), null);
    _ = try service.submit(try service.store.fence(delegated_record.id), .generate(), .{ .content = "delegated" }, null);
    _ = try service.submit(try service.store.fence(user_record.id), .generate(), .{ .content = "user" }, null);
    try delegated_provider.started();
    try user_provider.started();
    try service.stop(ticket);
    try awaitIdle(&service, root);
    try awaitIdle(&service, delegated);
    try std.testing.expect(user.agent.busy and !user.worker.?.cancel.isCancelled());
    try service.endConversation(ticket, .generate());
    try awaitIdle(&service, user);
    try service.poll();
    try std.testing.expect(root.agent.current == null and delegated.agent.current == null and user.agent.current == null);
}

test "v0.4 child journal refuses unknown versions and schema 1 child data" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const conversation = id.ConversationId.generate();
    const parent = id.ConversationId.generate();
    const agent = id.AgentId.generate();
    const text = try std.json.Stringify.valueAlloc(a, .{ .schema = 9, .event = .{ .kind = "child_create", .conversation = conversation, .revision = 1, .child_info = .{ .agent = agent, .owning_parent_conversation = parent, .created_by_agent = agent, .request_key = "key", .name = "child", .context_mode = "independent", .reusable = false } } }, .{});
    defer a.free(text);
    const line = try std.fmt.allocPrint(a, "{s}\n", .{text});
    defer a.free(line);
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "bad.jsonl", .data = line });
    var journal = try Journal.open(a, std.testing.io, tmp.dir, "bad.jsonl");
    defer journal.deinit();
    var store = life.Store.init(a);
    defer store.deinit();
    try std.testing.expectError(error.InvalidSessionJournal, journal.bind(&store));
    try std.testing.expect(store.records.items.len == 0 and store.agents.items.len == 0);
    for (journal.bytes.items, 0..) |byte, i| {
        if (byte == '9') {
            journal.bytes.items[i] = '1';
            break;
        }
    }
    try std.testing.expectError(error.InvalidSessionJournal, journal.bind(&store));
    try std.testing.expect(store.records.items.len == 0 and store.agents.items.len == 0);
}

test "v0.4 child current Loop snapshot contains first input and excludes its whole open create batch" {
    const Loop = @import("ai/tool_loop.zig");
    const P = @import("ai/provider.zig");
    const Fake = struct {
        loop: *Loop.Loop,
        snapshot: @import("ai/wire_history.zig").History = .{},
        fn execute(raw: *anyopaque, invocation: Loop.Invocation, alloc: std.mem.Allocator, _: ?*P.CancelToken) !Loop.Outcome {
            const self: *@This() = @ptrCast(@alignCast(raw));
            if (std.mem.eql(u8, invocation.key.call_id, "create-child")) {
                self.snapshot = try self.loop.snapshotForChild(alloc, invocation.key.call_id, self.loop.scope, &handles);
                try std.testing.expectEqual(@as(usize, 4), self.snapshot.messages.len);
                try std.testing.expectEqualStrings("FIRST TURN consumed input", self.snapshot.messages[0].content);
                try std.testing.expectEqualStrings("closed result", self.snapshot.messages[2].content);
                var subset = self.loop.scope;
                subset.inventory = &.{11};
                try std.testing.expectError(error.InheritanceScopeProjectionRequired, self.loop.snapshotForChild(alloc, invocation.key.call_id, subset, &.{handles[0]}));
                // Offloaded evidence retains its original owner even though it
                // is no longer a provider image input. Reject before copying.
                self.loop.messages.items[0].offloaded_images = &.{.{ .reference = .{}, .owner = handles[1] }};
                defer self.loop.messages.items[0].offloaded_images = &.{};
                try std.testing.expectError(error.InheritanceScopeProjectionRequired, self.loop.snapshotForChild(alloc, invocation.key.call_id, self.loop.scope, &.{handles[0]}));
            }
            return Loop.Outcome.copy(alloc, &.{.{ .session_id = 11, .status = .succeeded, .stdout = "batch result" }});
        }
    };
    var loop = Loop.Loop.init(a, live, 1, .{ .context_window = 200000 });
    var loop_live = true;
    defer if (loop_live) loop.deinit();
    const initial = [_]P.Message{
        .{ .content = "FIRST TURN consumed input" },
        .{ .role = .assistant, .content = "", .tool_calls = &.{.{ .id = "old-call", .name = "read_terminal", .arguments = "{\"session_ids\":[11]}" }} },
        .{ .role = .tool, .content = "closed result", .tool_call_id = "old-call" },
        .{ .content = "latest consumed steer" },
    };
    try loop.start(.{ .model = "fixture", .system = "rules", .messages = &initial, .tools = &.{.{ .tool = .read_terminal, .session_ids = &.{ 11, 12 } }} });
    var fake: Fake = .{ .loop = &loop };
    defer fake.snapshot.deinit();
    try loop.complete("current batch prose", &.{ .{ .id = "same-batch-preflight", .name = "read_terminal", .arguments = "{\"session_ids\":[11]}" }, .{ .id = "create-child", .name = "read_terminal", .arguments = "{\"session_ids\":[11]}" } }, .{ .context = &fake, .execute = Fake.execute }, .{}, 1, null);
    try std.testing.expectError(error.InvalidInheritanceSnapshot, loop.snapshotForChild(a, "create-child", live, &handles));
    loop.deinit();
    loop_live = false;
    try std.testing.expectEqualStrings("latest consumed steer", fake.snapshot.messages[3].content);
    try @import("ai/provider_http.zig").validateToolMessages(.{ .model = "child", .system = "rules", .messages = fake.snapshot.messages });
}

test "v0.4 child execution journal uses explicit schema and retains origin without live references" {
    const execution_journal = @import("ai/lifecycle_journal.zig");
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const parent: life.input.Fence = .{ .agent = .generate(), .conversation = .generate(), .binding = 2, .environment = 1 };
    const request: execution_journal.Request = .{ .context = .{ .conversation_id = .generate(), .task_id = .generate(), .binding = .{ .session = 11 }, .binding_revision = 2, .grant_revision = 1, .child_origin = .{ .agent = .generate(), .parent = parent, .worker_generation = 1, .scope_revision = 2 } }, .tool_id = "host.run_in_terminal", .request_key = "once", .canonical_hash = @splat(4), .turn_id = 1, .call_id = "child-call" };
    var first = try execution_journal.Journal.open(a, std.testing.io, tmp.dir, "executions.json");
    const token = try first.begin(request);
    first.deinit();
    const text = try tmp.dir.readFileAlloc(std.testing.io, "executions.json", a, .unlimited);
    defer a.free(text);
    try std.testing.expect(std.mem.indexOf(u8, text, "\"schema_version\":2") != null);
    var second = try execution_journal.Journal.open(a, std.testing.io, tmp.dir, "executions.json");
    defer second.deinit();
    var fact = try second.snapshot(a, token);
    defer fact.deinit(a);
    try std.testing.expect(fact.context.eql(request.context));
    try std.testing.expectEqual(execution_journal.Stage.cancelled_unsent, fact.stage);
}

test "v0.4 child journal preserves old null fields and family delete replays atomically" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var journal = try Journal.open(a, std.testing.io, tmp.dir, "sessions.jsonl");
    defer journal.deinit();
    var store = life.Store.init(a);
    defer store.deinit();
    try journal.bind(&store);
    const parent = try store.attach(live.owner);
    const ticket = try store.create(parent.id);
    const first_line = std.mem.sliceTo(journal.bytes.items, '\n');
    const parsed = try std.json.parseFromSlice(std.json.Value, a, first_line, .{});
    defer parsed.deinit();
    const event = parsed.value.object.get("event").?.object;
    try std.testing.expect(event.get("draft").? == .null);
    try std.testing.expect(event.get("parent").? == .null);
    try std.testing.expect(event.get("child_info") == null and event.get("parent_binding") == null and event.get("targets") == null);
    const child = try store.registerChild(ticket, .{ .name = "family", .request_key = "family" }, null);
    const child_id = child.id;
    const child_agent_id = child.child.?.info.agent;
    try end(&store, ticket);
    try store.removeFamily(ticket.conversation, store.find(ticket.conversation).?.revision, 1);
    var recovered = life.Store.init(a);
    defer recovered.deinit();
    try journal.bind(&recovered);
    try std.testing.expect(recovered.find(ticket.conversation) == null and recovered.find(child_id) == null);
    try std.testing.expect(recovered.agent(child_agent_id).?.closing);
}

test "v0.4 child capability tables require exact per-tool targets and omit empty or lifecycle definitions" {
    const Tools = @import("ai/plugin_tools.zig");
    const Host = @import("ai/host_tools.zig");
    const context: Host.Context = .{ .conversation_id = .generate(), .task_id = .generate(), .binding = live.owner, .binding_revision = 2, .grant_revision = 1, .child_origin = .{ .agent = .generate(), .parent = .{ .agent = .generate(), .conversation = .generate(), .binding = 2, .environment = 1 }, .worker_generation = 1, .scope_revision = 2 } };
    var contribution: Host.Contribution = .{ .authority = .execution_control, .definition = .{ .id = "host.run_in_terminal", .schema = "{\"type\":\"object\",\"properties\":{\"session_ref\":{\"type\":\"string\"}},\"required\":[\"session_ref\"],\"additionalProperties\":false}" } };
    try std.testing.expectError(error.ChildCapabilityTargetsRequired, Tools.RequestTable.initWithHost(a, live, &.{}, &.{}, context, &.{contribution}));
    contribution.session_targets = &.{};
    var empty = try Tools.RequestTable.initWithHost(a, live, &.{}, &.{}, context, &.{contribution});
    defer empty.deinit();
    try std.testing.expectEqual(@as(usize, 0), empty.entries.len);
    var cloned_empty = try Tools.cloneTable(&empty, a);
    defer cloned_empty.deinit();
    try std.testing.expectEqual(@as(usize, 0), cloned_empty.entries.len);
    contribution.session_targets = &.{handles[0]};
    var table = try Tools.RequestTable.initWithHost(a, live, &.{}, &.{}, context, &.{ contribution, .{ .authority = .lifecycle, .definition = .{ .id = "host.create_group", .schema = "{\"type\":\"object\",\"properties\":{},\"additionalProperties\":false}" } } });
    defer table.deinit();
    try std.testing.expectEqual(@as(usize, 1), table.entries.len);
    const reference = try @import("ai/host_queries.zig").sessionRef(a, context, handles[0]);
    defer a.free(reference);
    try std.testing.expect(std.mem.indexOf(u8, table.entries[0].definition.schema, reference) != null);
    try std.testing.expect(table.lookup("host__create_ugroup") == null);
}

test "v0.4 child empty assignment stays explicitly empty for material-only work" {
    var store = life.Store.init(a);
    defer store.deinit();
    const parent = try store.attach(live.owner);
    const ticket = try store.create(parent.id);
    const child = try store.registerChild(ticket, .{ .name = "分析材料", .request_key = "material" }, null);
    const bound = try store.bindChild(ticket, child.child.?.info.agent, child.revision, live, &.{});
    _ = try store.validateExecution(bound);
    try std.testing.expectEqual(@as(usize, 0), store.agent(bound.agent).?.targets.len);
    try std.testing.expectError(error.TargetOutsideAssistant, store.validateExecutionTarget(bound, handles[0], live, &handles));
    try end(&store, bound);
}

test "v0.4 child defaults save merge preserve active policy and explicit creation overrides" {
    const child = @import("ai/child_agent.zig");
    const cfg = @import("config/config.zig");
    const settings = @import("config/settings_values.zig");
    const runtime = @import("config/runtime_config.zig");
    const Controller = @import("config/settings_controller.zig").Controller;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var target = try runtime.RuntimeConfig.loadOrDefault(std.testing.io, tmp.dir, a, "config.toml");
    defer target.deinit();
    var controller = try Controller.init(a, target.value);
    defer controller.deinit();
    try controller.editKey("ai", "child_context_mode", .{ .text = "inherit" });
    try controller.editKey("ai", "child_reuse_policy", .{ .text = "prefer_reuse" });
    const policy = target.value.agentPolicyRevision();
    try controller.save(std.testing.io, tmp.dir, &target);
    try std.testing.expectEqual(policy, target.value.agentPolicyRevision());
    try std.testing.expectEqual(cfg.ChildContextMode.inherit, target.value.ai.child_context_mode);
    var loaded = try runtime.RuntimeConfig.loadOrDefault(std.testing.io, tmp.dir, a, "config.toml");
    defer loaded.deinit();
    try std.testing.expectEqual(cfg.ChildReusePolicy.prefer_reuse, loaded.value.ai.child_reuse_policy);
    const defaults: child.Defaults = .{ .context_mode = .inherit, .reuse_policy = .prefer_reuse };
    try std.testing.expectEqual(child.ContextMode.inherit, child.resolve(defaults, null, null).context_mode);
    try std.testing.expect(child.resolve(defaults, null, null).reusable);
    try std.testing.expectEqual(child.ContextMode.independent, child.resolve(defaults, .independent, false).context_mode);
    try std.testing.expect(!child.resolve(defaults, .independent, false).reusable);
    try std.testing.expect(!child.resolve(.{ .reuse_policy = .model }, null, null).reusable);
    try std.testing.expect(child.resolve(.{}, null, true).reusable);
    var invalid: cfg.Config = .{};
    try std.testing.expectError(error.InvalidValue, settings.writeConfig(&invalid, "ai", "child_reuse_policy", .{ .text = "automatic" }));
    try controller.editKey("ai", "child_context_mode", .{ .text = "independent" });
    try controller.discardLatest(&target);
    try std.testing.expectEqual(cfg.ChildContextMode.inherit, controller.model.value.ai.child_context_mode);
}

test "v0.4 handoff intent drains real child worker, fences dispatch and preserves parent task budget" {
    var root_provider: WorkerFixture = .{};
    var child_provider: WorkerFixture = .{};
    var service = Runtime.Service.init(a);
    defer service.deinit();
    const parent_scope: scope.Scope = .{ .owner = .{ .session = 11 }, .members = .{}, .inventory = &.{11} };
    const parent = try service.attach(parent_scope.owner, root_provider.backend());
    const ticket = try service.store.create(parent.agent.id);
    _ = try service.submit(ticket, .generate(), .{ .content = "keep parent task" }, null);
    try root_provider.started();
    const task = parent.context.?.task;
    const root = parent.task_root.?;
    const record = try service.store.registerChild(ticket, .{ .name = "drain", .request_key = "drain" }, null);
    const child = try service.useChild(ticket, record.child.?.info.agent, record.revision, parent_scope, &.{handles[0]}, child_provider.backend(), task);
    const child_ticket = try service.store.fence(record.id);
    _ = try service.submit(child_ticket, .generate(), .{ .content = "child" }, null);
    try child_provider.started();
    const operation = id.HostOperationId.generate();
    try std.testing.expect(!try service.quiesceChildren(ticket, operation));
    try std.testing.expectError(error.TransitionPending, service.store.validateExecution(ticket));
    try std.testing.expectError(error.TransitionPending, service.store.registerChild(ticket, .{ .name = "blocked", .request_key = "blocked" }, null));
    try std.testing.expectError(error.TransitionPending, service.quiesceChildren(ticket, .generate()));
    try awaitIdle(&service, child);
    try std.testing.expect(try service.quiesceChildren(ticket, operation));
    try std.testing.expect(child.worker == null and record.binding == null and !record.task_pending);
    try std.testing.expect(parent.thread != null and !parent.worker.?.cancel.isCancelled());
    try std.testing.expect(parent.context.?.task.eql(task) and parent.task_root.? == root);
    service.store.releaseTransition(ticket, .generate());
    try std.testing.expectError(error.TransitionPending, service.store.validateExecution(ticket));
    const next = try service.handoff(ticket, .{ .group = 88 });
    service.store.releaseTransition(ticket, operation);
    _ = try service.store.validateExecution(next);
    try std.testing.expect(parent.context.?.task.eql(task) and parent.task_root.? == root);
    try service.stop(next);
    try awaitIdle(&service, parent);
}

test "v0.4 child editable settings preserve provenance, reject expansion and replay unbound drafts" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var journal = try Journal.open(a, std.testing.io, tmp.dir, "children.jsonl");
    defer journal.deinit();
    var store = life.Store.init(a);
    defer store.deinit();
    try journal.bind(&store);
    const parent = try store.attach(live.owner);
    const ticket = try store.create(parent.id);
    const record = try store.registerChild(ticket, .{ .name = "initial", .request_key = "editable", .skill_ids = &.{"skill-a"}, .mcp_ids = &.{"mcp-a"} }, null);
    var prefs = life.child.Settings.fromInfo(record.child.?.info);
    prefs.name = "edited";
    prefs.model = .{ .provider_id = "provider", .model_id = "next-model" };
    prefs.targets = &.{handles[0]};
    try store.updateChildSettings(ticket, record.child.?.info.agent, 1, prefs, live);
    try std.testing.expectEqualStrings("initial", record.child.?.info.name);
    try std.testing.expectEqualStrings("edited", life.Store.childPreferences(record).name);
    try std.testing.expectError(error.StaleChildSettings, store.updateChildSettings(ticket, record.child.?.info.agent, 1, prefs, live));
    prefs.skill_ids = &.{"not-selected-by-parent"};
    try std.testing.expectError(error.ChildCapabilityExpansion, store.updateChildSettings(ticket, record.child.?.info.agent, 2, prefs, live));
    try std.testing.expectEqual(@as(u64, 2), record.child_settings_revision);
    _ = try store.setChildDraft(record.id, record.draft_revision, "own unbound draft");
    try std.testing.expect(record.binding == null and store.agents.items.len == 2);
    var replay = life.Store.init(a);
    defer replay.deinit();
    try journal.bind(&replay);
    const recovered = replay.find(record.id).?;
    try std.testing.expectEqualStrings("own unbound draft", recovered.draft.?);
    try std.testing.expectEqualStrings("edited", life.Store.childPreferences(recovered).name);
    try std.testing.expectEqualStrings("next-model", life.Store.childPreferences(recovered).model.?.model_id);
    try std.testing.expect(life.Store.childPreferences(recovered).targets[0].eql(handles[0]));
    try std.testing.expect(recovered.binding == null and !recovered.needs_recovery);
}

test "v0.4 child attachment drafts are keyed by conversation even under the same parent owner" {
    const Presentations = @import("ai/assistant_store.zig").Store;
    var store = life.Store.init(a);
    defer store.deinit();
    var presentations = Presentations.init(a);
    defer presentations.deinit();
    const parent = try store.attach(live.owner);
    const fence = try store.create(parent.id);
    const one = try store.registerChild(fence, .{ .name = "one", .request_key = "one" }, null);
    const two = try store.registerChild(fence, .{ .name = "two", .request_key = "two" }, null);
    const first_id = (try presentations.createChildPresentation(one, live.owner)).id;
    const second_id = (try presentations.createChildPresentation(two, live.owner)).id;
    const parent_state = try presentations.get(live.owner);
    const first_text = try presentations.attachmentDraftForState(first_id);
    const second_text = try presentations.attachmentDraftForState(second_id);
    const parent_text = try presentations.attachmentDraft(live.owner);
    try std.testing.expect(first_text != second_text and first_text != parent_text);
    try std.testing.expect(first_text.conversation_id.?.eql(one.id) and second_text.conversation_id.?.eql(two.id));
    const first_images = try presentations.imageDraftForState(first_id);
    const second_images = try presentations.imageDraftForState(second_id);
    try std.testing.expect(first_images != second_images);
    try std.testing.expect(parent_state.id != first_id and parent_state.id != second_id);
}

test "v0.4 child projection counts real workers, excludes human waits and retains unresolved attention" {
    const projection = @import("ai/child_projection.zig");
    var parent_provider: WorkerFixture = .{ .hold_projection = true };
    var child_provider: WorkerFixture = .{ .hold_projection = true };
    var service = Runtime.Service.init(a);
    defer service.deinit();
    defer {
        parent_provider.release.store(true, .release);
        child_provider.release.store(true, .release);
    }
    const parent = try service.attach(live.owner, parent_provider.backend());
    const fence = try service.store.create(parent.agent.id);
    _ = try service.submit(fence, .generate(), .{ .content = "parent" }, null);
    try parent_provider.started();
    const record = try service.store.registerChild(fence, .{ .name = "one", .request_key = "one" }, null);
    const child = try service.useChild(fence, record.child.?.info.agent, record.revision, live, &.{}, child_provider.backend(), parent.context.?.task);
    _ = try service.submit(try service.store.fence(record.id), .generate(), .{ .content = "child" }, null);
    try child_provider.started();
    const task = child.context.?.task;
    try std.testing.expect(projection.entry(&service, record).running);
    try child.task_root.?.userWait(task, true);
    const waiting = projection.entry(&service, record);
    try std.testing.expect(!waiting.running and waiting.group == .attention);
    try child.task_root.?.userWait(task, false);
    child_provider.release.store(true, .release);
    try awaitIdle(&service, child);
    try std.testing.expect(!projection.entry(&service, record).running);
    var unknown = child.task_root.?.facts[1];
    unknown.task = .generate();
    unknown.status = .outcome_unknown;
    unknown.request_key = "old-unknown";
    try child.task_root.?.add(unknown);
    var verification = unknown;
    verification.task = .generate();
    verification.status = .succeeded;
    verification.request_key = "verified-new-task";
    try child.task_root.?.add(verification);
    const pending = projection.entry(&service, record);
    try std.testing.expect(pending.group == .attention and !pending.running);
    try std.testing.expectEqualStrings("待核验", pending.status);
}

test "v0.4 child direct user queue creates fresh roots and releases each worker without reviving parent" {
    var parent_provider: WorkerFixture = .{};
    var child_provider: WorkerFixture = .{ .release_pending = 1 };
    var service = Runtime.Service.init(a);
    defer service.deinit();
    const parent = try service.attach(live.owner, parent_provider.backend());
    const parent_ticket = try service.store.create(parent.agent.id);
    _ = try service.submit(parent_ticket, .generate(), .{ .content = "parent" }, null);
    try parent_provider.started();
    const parent_task = parent.context.?.task;
    const record = try service.store.registerChild(parent_ticket, .{ .name = "direct", .request_key = "direct", .reusable = false }, null);
    const runner = try service.useChild(parent_ticket, record.child.?.info.agent, record.revision, live, &.{}, child_provider.backend(), null);
    runner.end_when_idle = true;
    const ticket = try service.store.fence(record.id);
    _ = try service.submit(ticket, .generate(), .{ .content = "one" }, null);
    try child_provider.started();
    const first_task = runner.context.?.task;
    const receipt = try service.submit(ticket, .generate(), .{ .content = "two" }, .queue);
    try std.testing.expectEqual(life.input.Route.queue, receipt.route);
    child_provider.release.store(true, .release);
    const start = std.Io.Clock.Timestamp.now(std.testing.io, .awake);
    while (record.binding != null) {
        try service.poll();
        if (start.durationTo(std.Io.Clock.Timestamp.now(std.testing.io, .awake)).raw.toMilliseconds() > 3000) return error.WorkerTimeout;
        std.Thread.yield() catch {};
    }
    try std.testing.expectEqual(@as(usize, 2), child_provider.calls.load(.acquire));
    try std.testing.expectEqual(@as(u64, 2), runner.worker_generation);
    try std.testing.expect(runner.worker == null and record.binding == null and !record.task_pending);
    try std.testing.expectEqual(@as(usize, 3), service.task_roots.items.len);
    const first = service.task_roots.items[1].facts[0];
    const second = service.task_roots.items[2].facts[0];
    try std.testing.expect(first.task.eql(first_task) and !first.root.eql(second.root));
    try std.testing.expect(first.parent == null and second.parent == null and first.status == .succeeded and second.status == .succeeded);
    try std.testing.expect(parent.context.?.task.eql(parent_task) and !parent.worker.?.cancel.isCancelled());
}

test "v0.4 child delegated queue rolls to next task under the original shared budget" {
    var parent_provider: WorkerFixture = .{};
    var child_provider: WorkerFixture = .{};
    var service = Runtime.Service.init(a);
    defer service.deinit();
    const parent = try service.attach(live.owner, parent_provider.backend());
    const parent_ticket = try service.store.create(parent.agent.id);
    _ = try service.submit(parent_ticket, .generate(), .{ .content = "parent" }, null);
    try parent_provider.started();
    const record = try service.store.registerChild(parent_ticket, .{ .name = "queue", .request_key = "queue" }, null);
    const runner = try service.useChild(parent_ticket, record.child.?.info.agent, record.revision, live, &.{}, child_provider.backend(), parent.context.?.task);
    runner.auto_end = true;
    runner.end_when_idle = true;
    const ticket = try service.store.fence(record.id);
    _ = try service.submit(ticket, .generate(), .{ .content = "one" }, null);
    try child_provider.started();
    _ = try service.submit(ticket, .generate(), .{ .content = "two" }, .queue);
    const root = parent.task_root.?;
    child_provider.release.store(true, .release);
    try awaitIdle(&service, runner);
    try std.testing.expectEqual(@as(usize, 3), root.count);
    try std.testing.expectEqual(@as(u32, 3), root.counters.requests);
    try std.testing.expect(root.facts[1].status == .succeeded and root.facts[2].status == .succeeded);
    try std.testing.expect(root.facts[1].parent.?.eql(parent.context.?.task) and root.facts[2].parent.?.eql(parent.context.?.task));
    try std.testing.expect(root.facts[1].root.eql(root.facts[2].root));
    try std.testing.expectEqual(@as(u64, 2), runner.worker_generation);
    try std.testing.expect(record.binding == null and runner.worker == null);
}
