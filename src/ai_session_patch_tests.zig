const std = @import("std");
const identity = @import("host/identity.zig");
const lifecycle = @import("ai/session_lifecycle.zig");
const input = @import("ai/session_input.zig");
const provider = @import("ai/provider.zig");
const Manager = @import("ai/turn_manager.zig").Manager;
const runtime = @import("ai/session_runtime.zig");

const RuntimeFixture = struct {
    started: std.atomic.Value(bool) = .init(false),
    release: std.atomic.Value(bool) = .init(false),
    calls: std.atomic.Value(usize) = .init(0),
    cleaned: bool = true,
    uses_tools: bool = false,
    fn prepare(raw: *anyopaque, _: std.mem.Allocator, _: std.Io, context: runtime.Context) !runtime.Prepared {
        const self: *@This() = @ptrCast(@alignCast(raw));
        return .{ .provider = .{ .ctx = raw, .chat = chat, .models = models }, .request = .{ .model = "mock", .system = "", .messages = &.{} }, .scope = .{ .owner = context.owner, .members = .{} }, .host = if (self.uses_tools) .{ .context = self, .execute = unexpectedTool } else null };
    }
    fn unexpectedTool(_: *anyopaque, _: @import("ai/tool_loop.zig").Invocation, _: std.mem.Allocator, _: ?*provider.CancelToken) !@import("ai/tool_loop.zig").Outcome {
        return error.UnexpectedTool;
    }
    fn chat(raw: *anyopaque, request: provider.ChatRequest, sink: *const fn (*anyopaque, provider.Delta) void, ctx: *anyopaque) !provider.ChatStats {
        const self: *@This() = @ptrCast(@alignCast(raw));
        _ = self.calls.fetchAdd(1, .monotonic);
        self.started.store(true, .release);
        while (!self.release.load(.acquire)) {
            if (request.cancel) |cancel| if (cancel.isCancelled()) return error.Cancelled;
            std.Thread.yield() catch {};
        }
        sink(ctx, .{ .text = "done" });
        sink(ctx, .done);
        return .{};
    }
    fn models(_: *anyopaque, a: std.mem.Allocator) ![]provider.ModelInfo {
        return a.alloc(provider.ModelInfo, 0);
    }
    fn released(raw: *anyopaque, _: runtime.Context) bool {
        return @as(*@This(), @ptrCast(@alignCast(raw))).cleaned;
    }
    fn backend(self: *@This()) runtime.Backend {
        return .{ .context = self, .prepare = prepare, .local_released = released };
    }
};
fn waitStarted(value: *RuntimeFixture) !void {
    const started = std.Io.Clock.Timestamp.now(std.testing.io, .awake);
    while (!value.started.load(.acquire)) {
        if (started.durationTo(std.Io.Clock.Timestamp.now(std.testing.io, .awake)).raw.toMilliseconds() > 3000) return error.WorkerDidNotStart;
        std.Thread.yield() catch {};
    }
}
fn waitIdle(service: *runtime.Service, runner: *runtime.Runner) !void {
    const started = std.Io.Clock.Timestamp.now(std.testing.io, .awake);
    while (runner.thread != null or runner.agent.busy) {
        try service.poll();
        if (started.durationTo(std.Io.Clock.Timestamp.now(std.testing.io, .awake)).raw.toMilliseconds() > 3000) return error.WorkerDidNotFinish;
        std.Thread.yield() catch {};
    }
}

test "AI session PATCH real workers overlap and stopping one leaves another running" {
    var service = runtime.Service.init(std.testing.allocator);
    defer service.deinit();
    var first: RuntimeFixture = .{};
    var second: RuntimeFixture = .{};
    const a = try service.attach(.{ .session = 1 }, first.backend());
    const b = try service.attach(.{ .group = 1 }, second.backend());
    const ta = try service.store.create(a.agent.id);
    const tb = try service.store.create(b.agent.id);
    _ = try service.submit(ta, identity.SubmissionId.generate(), .{ .content = "A" }, null);
    _ = try service.submit(tb, identity.SubmissionId.generate(), .{ .content = "B" }, null);
    try waitStarted(&first);
    try waitStarted(&second);
    try std.testing.expect(a.agent.busy and b.agent.busy);
    try service.stop(ta);
    try waitIdle(&service, a);
    try std.testing.expect(b.agent.busy and !b.worker.?.cancel.isCancelled());
    second.release.store(true, .release);
    try waitIdle(&service, b);
    try std.testing.expect(service.store.find(ta.conversation).?.binding != null);
    try std.testing.expectEqualStrings("done", service.store.find(tb.conversation).?.history.messages[1].content);
}

test "AI session PATCH queued input starts next turn while steering continues current turn" {
    var service = runtime.Service.init(std.testing.allocator);
    defer service.deinit();
    var fixture: RuntimeFixture = .{};
    const runner = try service.attach(.{ .session = 1 }, fixture.backend());
    const ticket = try service.store.create(runner.agent.id);
    _ = try service.submit(ticket, identity.SubmissionId.generate(), .{ .content = "first" }, null);
    try waitStarted(&fixture);
    const turn = runner.context.?.turn;
    const steer = try service.submit(ticket, identity.SubmissionId.generate(), .{ .content = "steer" }, .steer);
    const queued = try service.submit(ticket, identity.SubmissionId.generate(), .{ .content = "next" }, .queue);
    try std.testing.expectEqual(input.Route.steer, steer.route);
    fixture.release.store(true, .release);
    try waitIdle(&service, runner);
    const inbox = &service.store.find(ticket.conversation).?.inbox;
    try std.testing.expectEqual(turn, inbox.receipt(steer.id).?.turn.?);
    try std.testing.expect(inbox.receipt(queued.id).?.turn.? > turn);
    try std.testing.expectEqual(@as(usize, 3), fixture.calls.load(.acquire));
}

test "AI session PATCH end remains bound until independent cleanup acknowledges release" {
    var service = runtime.Service.init(std.testing.allocator);
    defer service.deinit();
    var fixture: RuntimeFixture = .{ .cleaned = false, .uses_tools = true };
    const runner = try service.attach(.{ .session = 1 }, fixture.backend());
    const ticket = try service.store.create(runner.agent.id);
    _ = try service.submit(ticket, identity.SubmissionId.generate(), .{ .content = "run" }, null);
    try waitStarted(&fixture);
    try service.endConversation(ticket, identity.HostOperationId.generate());
    try waitIdle(&service, runner);
    try std.testing.expect(service.store.find(ticket.conversation).?.binding != null);
    fixture.cleaned = true;
    try service.poll();
    try std.testing.expect(service.store.find(ticket.conversation).?.binding == null);
}

test "AI session PATCH binary binding ends only after release and resumes exclusively" {
    var store = lifecycle.Store.init(std.testing.allocator);
    defer store.deinit();
    const a = try store.attach(.{ .session = 1 });
    try std.testing.expectEqual(a, try store.attach(.{ .session = 1 }));
    const b = try store.attach(.{ .group = 1 });
    const ticket = try store.create(a.id);
    try std.testing.expectError(error.BindingConflict, store.create(a.id));
    try std.testing.expectError(error.BindingConflict, store.resumeConversation(ticket.conversation, b.id, ticket.binding));
    const operation = identity.HostOperationId.generate();
    try std.testing.expect(!try store.beginEnd(ticket, operation));
    try std.testing.expect(store.find(ticket.conversation).?.binding != null);
    try std.testing.expectError(error.ConversationEnding, store.find(ticket.conversation).?.inbox.admit(ticket, identity.SubmissionId.generate(), .{ .content = "late" }, .steer));
    try std.testing.expectError(error.ResourceCleanupPending, store.commitEnd(ticket, operation, .{ .worker_joined = false, .dispatch_closed = true, .local_released = true, .transcript_saved = true }));
    try store.commitEnd(ticket, operation, .{ .worker_joined = true, .dispatch_closed = true, .local_released = true, .transcript_saved = true });
    const record = store.find(ticket.conversation).?;
    try std.testing.expect(record.binding == null and a.current == null);
    const resumed = try store.resumeConversation(record.id, b.id, record.revision);
    try std.testing.expect(resumed.binding > ticket.binding);
    try store.commitEnd(ticket, operation, .{ .worker_joined = true, .dispatch_closed = true, .local_released = true, .transcript_saved = true });
    try std.testing.expect(record.binding.?.agent.eql(b.id));
    try std.testing.expectError(error.BindingChanged, store.validate(ticket));
}

test "AI session PATCH fork copies only committed history and no execution or draft" {
    var store = lifecycle.Store.init(std.testing.allocator);
    defer store.deinit();
    const a = try store.attach(.{ .session = 1 });
    const b = try store.attach(.{ .session = 2 });
    const ticket = try store.create(a.id);
    _ = try store.setDraft(ticket, 1, "do not copy");
    try store.checkpoint(ticket, 1, &.{ .{ .content = "old host" }, .{ .role = .assistant, .content = "historical result" } }, true);
    a.busy = true;
    const source = store.find(ticket.conversation).?;
    const copy = try store.fork(source.id, source.content_revision);
    const forked = store.find(copy).?;
    try std.testing.expect(forked.binding == null and forked.draft == null and forked.inbox.entries.items.len == 0);
    try std.testing.expect(!copy.eql(source.id));
    _ = try store.resumeConversation(copy, b.id, forked.revision);
    try std.testing.expect(source.binding.?.agent.eql(a.id));
    try std.testing.expectEqualStrings("historical result", forked.history.messages[1].content);
    try std.testing.expectError(error.BindingConflict, store.remove(source.id));
}

test "AI session PATCH queue keeps unknown delivery while paused and rejects stale edits" {
    var store = lifecycle.Store.init(std.testing.allocator);
    defer store.deinit();
    const a = try store.attach(.{ .session = 1 });
    const ticket = try store.create(a.id);
    const inbox = &store.find(ticket.conversation).?.inbox;
    const first = try inbox.admit(ticket, identity.SubmissionId.generate(), .{ .content = "one" }, .queue);
    _ = try inbox.admit(ticket, first.id, .{ .content = "one" }, .queue);
    try std.testing.expectEqual(@as(usize, 1), inbox.entries.items.len);
    const second = try inbox.edit(first.id, first.revision, .{ .content = "edited" });
    try std.testing.expectError(error.SubmissionNotReady, inbox.edit(first.id, first.revision, .{ .content = "stale" }));
    const claimed = try inbox.claim(first.id, second.revision, null, 1, .start);
    try inbox.reconcile(first.id, claimed.attempt, .outcome_unknown);
    inbox.pauseAll(.stop);
    try std.testing.expectEqual(input.Delivery.outcome_unknown, inbox.receipt(first.id).?.delivery);
    inbox.finish(1, .stop);
    try std.testing.expectError(error.SubmissionUnconfirmed, inbox.continueQueue(ticket));
    try std.testing.expectError(error.StaleSubmissionAttempt, inbox.reconcile(first.id, claimed.attempt + 1, .accepted));
    const failed = try inbox.admit(ticket, identity.SubmissionId.generate(), .{ .content = "known not delivered" }, .queue);
    try inbox.reconcile(failed.id, failed.attempt, .failed);
    try std.testing.expectEqual(@as(usize, 1), store.budget.count);
    const resent = try inbox.reissue(ticket, failed.id, failed.revision, identity.SubmissionId.generate(), .{ .content = "retry explicitly" }, .queue);
    try std.testing.expect(resent.original.?.eql(failed.id));
}

test "AI session PATCH tool-free steering stays in the same turn and preserves both inputs" {
    const Fixture = struct {
        inbox: *input.Inbox,
        ticket: input.Fence,
        calls: usize = 0,
        fn chat(raw: *anyopaque, request: provider.ChatRequest, sink: *const fn (*anyopaque, provider.Delta) void, ctx: *anyopaque) !provider.ChatStats {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.calls += 1;
            if (self.calls == 1) {
                try std.testing.expectEqualStrings("first", request.messages[request.messages.len - 1].content);
                _ = try self.inbox.admit(self.ticket, identity.SubmissionId.generate(), .{ .content = "correction" }, .steer);
                sink(ctx, .{ .text = "initial response" });
            } else {
                try std.testing.expectEqualStrings("correction", request.messages[request.messages.len - 1].content);
                try std.testing.expectEqualStrings("initial response", request.messages[request.messages.len - 2].content);
                sink(ctx, .{ .text = "corrected" });
            }
            sink(ctx, .done);
            return .{};
        }
        fn models(_: *anyopaque, a: std.mem.Allocator) ![]provider.ModelInfo {
            return a.alloc(provider.ModelInfo, 0);
        }
    };
    var store = lifecycle.Store.init(std.testing.allocator);
    defer store.deinit();
    const a = try store.attach(.{ .session = 1 });
    const ticket = try store.create(a.id);
    const inbox = &store.find(ticket.conversation).?.inbox;
    const initial = try inbox.admit(ticket, identity.SubmissionId.generate(), .{ .content = "first" }, .queue);
    _ = try inbox.claim(initial.id, initial.revision, null, 1, .start);
    var fixture: Fixture = .{ .inbox = inbox, .ticket = ticket };
    var manager = Manager.init(std.testing.allocator);
    defer manager.deinit();
    manager.turn_id = 1;
    manager.input = inbox;
    manager.scope = .{ .owner = a.owner, .members = .{} };
    _ = try manager.run(.{ .ctx = &fixture, .chat = Fixture.chat, .models = Fixture.models }, .{ .model = "mock", .system = "", .messages = &.{} });
    try std.testing.expectEqual(@as(usize, 2), fixture.calls);
    try std.testing.expectEqual(@as(u64, 1), manager.turn_id);
    try std.testing.expectEqualStrings("corrected", manager.round_text.items);
    try std.testing.expectEqual(input.Delivery.consumed, inbox.receipt(initial.id).?.delivery);
}

const Journal = @import("ai/session_journal.zig").Journal;
const all_released: lifecycle.Released = .{ .worker_joined = true, .dispatch_closed = true, .local_released = true, .transcript_saved = true };

test "AI session PATCH journal restores orphan as fenced data and resumes only after release" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var journal = try Journal.open(std.testing.allocator, std.testing.io, tmp.dir, "sessions.jsonl");
    var store = lifecycle.Store.init(std.testing.allocator);
    try journal.bind(&store);
    const agent = try store.attach(.{ .session = 44 });
    const ticket = try store.create(agent.id);
    try store.checkpoint(ticket, 7, &.{ .{ .content = "past" }, .{ .role = .assistant, .content = "saved answer" } }, true);
    _ = try store.setDraft(ticket, 1, "draft survives");
    const pending = try store.find(ticket.conversation).?.inbox.admit(ticket, identity.SubmissionId.generate(), .{ .content = "do not replay" }, .queue);
    store.deinit();
    journal.deinit();
    var reopened = try Journal.open(std.testing.allocator, std.testing.io, tmp.dir, "sessions.jsonl");
    defer reopened.deinit();
    var restored = lifecycle.Store.init(std.testing.allocator);
    defer restored.deinit();
    try reopened.bind(&restored);
    const record = restored.find(ticket.conversation).?;
    try std.testing.expect(record.binding != null and record.needs_recovery and !record.inbox.admission);
    try std.testing.expectError(error.RecoveryRequired, restored.validate(ticket));
    try std.testing.expect(record.inbox.receipt(pending.id).?.archived);
    try std.testing.expectEqualStrings("draft survives", record.draft.?);
    try std.testing.expectError(error.ResourceCleanupPending, restored.recoverOrphan(record.id, .{ .worker_joined = true, .dispatch_closed = true, .local_released = false, .transcript_saved = true }));
    try restored.recoverOrphan(record.id, all_released);
    const target = try restored.attach(.{ .group = 55 });
    const resumed = try restored.resumeConversation(record.id, target.id, record.revision);
    try std.testing.expect(resumed.binding > ticket.binding and record.inbox.next() == null);
    try std.testing.expectEqualStrings("saved answer", record.history.messages[1].content);
    const forked = try restored.fork(record.id, record.content_revision);
    const operation = identity.HostOperationId.generate();
    _ = try restored.beginEnd(resumed, operation);
    try restored.commitEnd(resumed, operation, all_released);
    try restored.remove(record.id);
    try std.testing.expectEqualStrings("saved answer", restored.find(forked).?.history.messages[1].content);
}

test "AI session PATCH failed durable admission and lifecycle publication retain previous state" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var journal = try Journal.open(std.testing.allocator, std.testing.io, tmp.dir, "sessions.jsonl");
    defer journal.deinit();
    var store = lifecycle.Store.init(std.testing.allocator);
    defer store.deinit();
    try journal.bind(&store);
    const agent = try store.attach(.{ .session = 1 });
    const ticket = try store.create(agent.id);
    const record = store.find(ticket.conversation).?;
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "sessions.jsonl", .data = "external change\n" });
    try std.testing.expectError(error.JournalConflict, record.inbox.admit(ticket, identity.SubmissionId.generate(), .{ .content = "preserve composer" }, .queue));
    try std.testing.expectEqual(@as(usize, 0), record.inbox.entries.items.len);
    try std.testing.expectEqual(@as(usize, 0), store.budget.count);
    try std.testing.expectError(error.JournalConflict, store.beginEnd(ticket, identity.HostOperationId.generate()));
    try std.testing.expect(record.binding != null and record.ending.?.failed and !record.inbox.admission);
    try std.testing.expectError(error.StaleLifecycleOperation, store.commitEnd(ticket, record.ending.?.operation, all_released));
}

test "AI session PATCH native factory freezes config without starting network IO" {
    var native = try runtime.Native.init(std.testing.allocator, .{ .kind = .ollama, .endpoint = "http://localhost:11434", .model = "test", .auth = .none });
    defer native.deinit();
    _ = native.backend();
    try std.testing.expectEqualStrings("test", native.config.model);
}

test "AI session PATCH steering between tools keeps completed result and prevents remaining dispatch" {
    const loop_mod = @import("ai/tool_loop.zig");
    const Fixture = struct {
        inbox: *input.Inbox,
        ticket: input.Fence,
        executed: usize = 0,
        fn current(raw: *anyopaque, revision: u64) bool {
            return @as(*input.Inbox, @ptrCast(@alignCast(raw))).planCurrent(revision);
        }
        fn execute(raw: *anyopaque, _: loop_mod.Invocation, allocator: std.mem.Allocator, _: ?*provider.CancelToken) !loop_mod.Outcome {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.executed += 1;
            _ = try self.inbox.admit(self.ticket, identity.SubmissionId.generate(), .{ .content = "change plan" }, .steer);
            const targets = try allocator.alloc(loop_mod.TargetResult, 1);
            targets[0] = .{ .session_id = 1, .status = .succeeded, .transport = .local, .stdout = try allocator.dupe(u8, "first tool actually completed"), .stderr = try allocator.dupe(u8, ""), .exit = 0 };
            return .{ .targets = targets };
        }
    };
    var store = lifecycle.Store.init(std.testing.allocator);
    defer store.deinit();
    const agent = try store.attach(.{ .session = 1 });
    const ticket = try store.create(agent.id);
    const inbox = &store.find(ticket.conversation).?.inbox;
    const first = try inbox.admit(ticket, identity.SubmissionId.generate(), .{ .content = "start" }, .queue);
    _ = try inbox.claim(first.id, first.revision, null, 9, .start);
    var fixture: Fixture = .{ .inbox = inbox, .ticket = ticket };
    var run = loop_mod.Loop.init(std.testing.allocator, .{ .owner = agent.owner, .members = .{ .ids = .{1} ++ @as([15]u64, @splat(0)), .len = 1 } }, 9, .{});
    defer run.deinit();
    try run.start(.{ .model = "test", .system = "", .messages = &.{}, .tools = &.{.{ .tool = .read_terminal, .session_ids = &.{1} }} });
    run.dispatch_gate = .{ .context = inbox, .revision = inbox.inputRevision(), .current = Fixture.current };
    try run.complete("", &.{ .{ .id = "first", .name = "read_terminal", .arguments = "{\"session_ids\":[1]}" }, .{ .id = "second", .name = "read_terminal", .arguments = "{\"session_ids\":[1]}" } }, .{ .context = &fixture, .execute = Fixture.execute }, .{}, 1, null);
    try std.testing.expectEqual(@as(usize, 1), fixture.executed);
    try std.testing.expect(run.records.items[0].dispatched and !run.records.items[1].dispatched and !run.uncertain);
    try std.testing.expect(std.mem.indexOf(u8, run.messages.items[1].content, "first tool actually completed") != null);
    try std.testing.expect(std.mem.indexOf(u8, run.messages.items[2].content, "not_dispatched_due_to_new_input") != null);
    try @import("ai/provider_http.zig").validateToolMessages(try run.nextRequest());
}

test "AI session PATCH saturated inbox still permits stop and explicit same binding queue continuation" {
    var store = lifecycle.Store.init(std.testing.allocator);
    defer store.deinit();
    const agent = try store.attach(.{ .session = 1 });
    const ticket = try store.create(agent.id);
    const record = store.find(ticket.conversation).?;
    for (0..input.Inbox.max_count) |_| _ = try record.inbox.admit(ticket, identity.SubmissionId.generate(), .{ .content = "queued" }, .queue);
    try std.testing.expectError(error.InputQueueFull, record.inbox.admit(ticket, identity.SubmissionId.generate(), .{ .content = "overflow" }, .queue));
    try std.testing.expectError(error.InvalidSubmission, record.inbox.admit(ticket, identity.SubmissionId.generate(), .{ .content = "\xff" }, .queue));
    record.inbox.pauseAll(.stop);
    try std.testing.expect(record.inbox.next() == null);
    try record.inbox.continueQueue(ticket);
    try std.testing.expect(record.inbox.next() != null);
    const op = identity.HostOperationId.generate();
    _ = try store.beginEnd(ticket, op);
    try store.commitEnd(ticket, op, all_released);
    try std.testing.expect(record.binding == null and store.budget.count == 0);
    const resumed = try store.resumeConversation(record.id, agent.id, record.revision);
    try record.inbox.continueQueue(resumed);
    try std.testing.expect(record.inbox.next() == null);
    const old = record.inbox.entries.items[0].receipt;
    try std.testing.expectError(error.BindingChanged, record.inbox.admit(resumed, old.id, .{ .content = "queued" }, .queue));
    const reissued = try record.inbox.reissue(resumed, old.id, old.revision, identity.SubmissionId.generate(), .{ .content = "explicit current-environment input" }, .queue);
    try std.testing.expect(reissued.original.?.eql(old.id) and !reissued.id.eql(old.id));
}

test "AI session PATCH copy-and-use failure publishes neither fork nor target binding" {
    const Failing = struct {
        fn write(_: *anyopaque, _: lifecycle.Event) !void {
            return error.StorageUnavailable;
        }
    };
    var store = lifecycle.Store.init(std.testing.allocator);
    defer store.deinit();
    const source = try store.attach(.{ .session = 1 });
    const target = try store.attach(.{ .session = 2 });
    const ticket = try store.create(source.id);
    try store.checkpoint(ticket, 1, &.{.{ .content = "stable" }}, true);
    var sentinel: u8 = 0;
    store.persist = .{ .context = &sentinel, .write = Failing.write };
    try std.testing.expectError(error.StorageUnavailable, store.forkAndUse(ticket.conversation, store.find(ticket.conversation).?.content_revision, target.id));
    try std.testing.expectEqual(@as(usize, 1), store.records.items.len);
    try std.testing.expect(target.current == null and source.current.?.eql(ticket.conversation));
}

test "AI session PATCH active environment invalidation joins before next turn and rejects old fence" {
    var service = runtime.Service.init(std.testing.allocator);
    defer service.deinit();
    var fixture: RuntimeFixture = .{};
    const runner = try service.attach(.{ .session = 1 }, fixture.backend());
    const ticket = try service.store.create(runner.agent.id);
    _ = try service.submit(ticket, identity.SubmissionId.generate(), .{ .content = "old environment" }, null);
    try waitStarted(&fixture);
    const next = try service.environmentChanged(ticket);
    try std.testing.expect(next.environment > ticket.environment);
    try std.testing.expectError(error.BindingChanged, service.submit(ticket, identity.SubmissionId.generate(), .{ .content = "stale" }, null));
    try waitIdle(&service, runner);
    try std.testing.expect(service.store.find(ticket.conversation).?.binding != null);
    fixture.release.store(true, .release);
    _ = try service.submit(next, identity.SubmissionId.generate(), .{ .content = "current environment" }, null);
    try waitIdle(&service, runner);
}

test "AI session PATCH consumed receipt and canonical input survive crash in one journal record" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var journal = try Journal.open(std.testing.allocator, std.testing.io, tmp.dir, "sessions.jsonl");
    var service = runtime.Service.init(std.testing.allocator);
    try journal.bind(&service.store);
    var fixture: RuntimeFixture = .{};
    const runner = try service.attach(.{ .session = 1 }, fixture.backend());
    const ticket = try service.store.create(runner.agent.id);
    const receipt = try service.submit(ticket, identity.SubmissionId.generate(), .{ .content = "durable user input" }, null);
    try waitStarted(&fixture);
    // Snapshot exactly the durable state while HTTP is active; no terminal checkpoint exists yet.
    const frozen = try tmp.dir.readFileAlloc(std.testing.io, "sessions.jsonl", std.testing.allocator, .limited(1024 * 1024));
    defer std.testing.allocator.free(frozen);
    try service.stop(ticket);
    try waitIdle(&service, runner);
    service.deinit();
    journal.deinit();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "sessions.jsonl", .data = frozen });
    var reopened = try Journal.open(std.testing.allocator, std.testing.io, tmp.dir, "sessions.jsonl");
    defer reopened.deinit();
    var restored = lifecycle.Store.init(std.testing.allocator);
    defer restored.deinit();
    try reopened.bind(&restored);
    const record = restored.find(ticket.conversation).?;
    try std.testing.expectEqual(input.Delivery.consumed, record.inbox.receipt(receipt.id).?.delivery);
    try std.testing.expectEqualStrings("durable user input", record.recovery_history.messages[0].content);
    try restored.recoverOrphan(record.id, all_released);
    try std.testing.expectEqualStrings("durable user input", record.history.messages[0].content);
    try std.testing.expect(record.binding == null);
}

test "AI session PATCH durable queue reorder survives restart and malformed replay is atomic" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var journal = try Journal.open(std.testing.allocator, std.testing.io, tmp.dir, "sessions.jsonl");
    var store = lifecycle.Store.init(std.testing.allocator);
    try journal.bind(&store);
    const agent = try store.attach(.{ .session = 1 });
    const ticket = try store.create(agent.id);
    const inbox = &store.find(ticket.conversation).?.inbox;
    const one = try inbox.admit(ticket, identity.SubmissionId.generate(), .{ .content = "one" }, .queue);
    const two = try inbox.admit(ticket, identity.SubmissionId.generate(), .{ .content = "two" }, .queue);
    try inbox.reorder(inbox.queue_revision, &.{ two.id, one.id });
    store.deinit();
    journal.deinit();
    var reopened = try Journal.open(std.testing.allocator, std.testing.io, tmp.dir, "sessions.jsonl");
    defer reopened.deinit();
    var restored = lifecycle.Store.init(std.testing.allocator);
    defer restored.deinit();
    try reopened.bind(&restored);
    try std.testing.expect(restored.find(ticket.conversation).?.inbox.entries.items[0].receipt.id.eql(two.id));
    try reopened.bytes.appendSlice(std.testing.allocator, "{bad json}\n");
    var invalid = lifecycle.Store.init(std.testing.allocator);
    defer invalid.deinit();
    if (reopened.bind(&invalid)) |_| return error.InvalidJournalWasAccepted else |_| {}
    try std.testing.expect(invalid.records.items.len == 0 and invalid.agents.items.len == 0 and invalid.persist == null);
}

test "AI session PATCH follow up mode defaults steer and persists explicit queue" {
    const config = @import("config/config.zig");
    const defaults = try config.Config.parse("");
    try std.testing.expectEqual(input.Mode.steer, defaults.ai.follow_up_mode);
    const custom = try config.Config.parse("[ai]\nfollow_up_mode = \"queue\"\n");
    var buffer: [65536]u8 = undefined;
    const saved = try custom.format(&buffer);
    const loaded = try config.Config.parse(saved);
    try std.testing.expectEqual(input.Mode.queue, loaded.ai.follow_up_mode);
    try std.testing.expectError(error.InvalidValue, config.Config.parse("[ai]\nfollow_up_mode = \"invalid\"\n"));
}

test "AI session PATCH fork projects historical resources without changing raw records" {
    const Fixture = struct {
        checked: std.atomic.Value(bool) = .init(false),
        fn prepare(raw: *anyopaque, _: std.mem.Allocator, _: std.Io, context: runtime.Context) !runtime.Prepared {
            return .{ .provider = .{ .ctx = raw, .chat = chat, .models = RuntimeFixture.models }, .request = .{ .model = "mock", .system = "", .messages = &.{} }, .scope = .{ .owner = context.owner, .members = .{} } };
        }
        fn chat(raw: *anyopaque, request: provider.ChatRequest, sink: *const fn (*anyopaque, provider.Delta) void, ctx: *anyopaque) !provider.ChatStats {
            const self: *@This() = @ptrCast(@alignCast(raw));
            try std.testing.expect(std.mem.startsWith(u8, request.messages[0].content, "[历史环境，仅作记录]"));
            try std.testing.expect(request.messages[0].image_owner == null and request.messages[0].image_transform == 0);
            try std.testing.expectEqualStrings("current input", request.messages[request.messages.len - 1].content);
            try std.testing.expect(std.mem.indexOf(u8, request.system, "本轮起始绑定版本") != null);
            self.checked.store(true, .release);
            sink(ctx, .{ .text = "new answer" });
            sink(ctx, .done);
            return .{};
        }
    };
    var service = runtime.Service.init(std.testing.allocator);
    defer service.deinit();
    var old: RuntimeFixture = .{};
    var fresh: Fixture = .{};
    const source = try service.attach(.{ .session = 1 }, old.backend());
    const target = try service.attach(.{ .session = 2 }, .{ .context = &fresh, .prepare = Fixture.prepare });
    const initial = try service.store.create(source.agent.id);
    const owner: identity.SessionHandle = .{ .session_id = @fromBackingInt(@intCast(1)), .generation = 17 };
    try service.store.checkpoint(initial, 1, &.{.{ .content = "original remote resource", .image_owner = owner, .image_transform = 99 }}, true);
    const next = try service.forkAndUse(initial.conversation, service.store.find(initial.conversation).?.content_revision, target.agent.id);
    _ = try service.submit(next, identity.SubmissionId.generate(), .{ .content = "current input" }, null);
    try waitIdle(&service, target);
    try std.testing.expect(fresh.checked.load(.acquire));
    try std.testing.expectEqualStrings("original remote resource", service.store.find(next.conversation).?.history.messages[0].content);
    try std.testing.expect(service.store.find(next.conversation).?.history.messages[0].image_owner.?.eql(owner));
}

test "AI session PATCH steering supersedes exact approval and question tickets without approving" {
    const host = @import("ai/host_tools.zig");
    const Q = @import("ai/user_interaction.zig");
    var service = runtime.Service.init(std.testing.allocator);
    defer service.deinit();
    var fixture: RuntimeFixture = .{};
    const runner = try service.attach(.{ .session = 1 }, fixture.backend());
    const ticket = try service.store.create(runner.agent.id);
    _ = try service.submit(ticket, identity.SubmissionId.generate(), .{ .content = "start" }, null);
    try waitStarted(&fixture);
    const json = "{\"question\":\"choose\"}";
    const args = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, json, .{});
    defer args.deinit();
    var call: host.Invocation = .{ .context = runner.context.?.authority(), .authority = .conversation_context, .operation_id = 9, .turn_id = runner.context.?.turn, .call_id = "waiting", .tool_id = Q.contribution.definition.id, .arguments = args.value, .arguments_json = json, .arguments_hash = @splat(1), .canonical_arguments_hash = try @import("ai/canonical_arguments.zig").digest(std.testing.allocator, args.value) };
    std.crypto.hash.sha2.Sha256.hash(json, &call.arguments_hash, .{});
    const question = try runner.worker.?.questions.begin(call, std.testing.allocator);
    call.authority = .execution_control;
    call.tool_id = "host.send_execution_input";
    const permit = try runner.worker.?.approvals.beginSubject(call, .{ .kind = .terminal_command, .target = "execution", .detail = "input" }, ticket.environment, std.testing.allocator);
    _ = try service.submit(ticket, identity.SubmissionId.generate(), .{ .content = "new plan" }, .steer);
    try std.testing.expect(runner.worker.?.questions.snapshot() == null and runner.worker.?.approvals.snapshot() == null);
    try std.testing.expectError(error.ScopeChanged, runner.worker.?.approvals.waitForDecision(permit, null));
    try std.testing.expectError(error.StaleApproval, runner.worker.?.approvals.decide(permit.sequence, permit.arguments_hash, true));
    try std.testing.expectError(error.CancelledBeforeDispatch, runner.worker.?.questions.poll(question));
    try std.testing.expectError(error.StaleUserQuestion, runner.worker.?.questions.answer(question, null, "late answer"));
    try service.stop(ticket);
    try waitIdle(&service, runner);
}

test "AI session PATCH failed history save on one agent does not starve another agent completion" {
    const Failing = struct {
        conversation: identity.ConversationId,
        fn write(raw: *anyopaque, event: lifecycle.Event) !void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            if (event.kind == .checkpoint and event.conversation.eql(self.conversation)) return error.StorageUnavailable;
        }
    };
    var service = runtime.Service.init(std.testing.allocator);
    defer service.deinit();
    var a: RuntimeFixture = .{ .release = .init(true) };
    var b: RuntimeFixture = .{ .release = .init(true) };
    const first = try service.attach(.{ .session = 1 }, a.backend());
    const second = try service.attach(.{ .session = 2 }, b.backend());
    const ta = try service.store.create(first.agent.id);
    const tb = try service.store.create(second.agent.id);
    var failing: Failing = .{ .conversation = ta.conversation };
    service.store.persist = .{ .context = &failing, .write = Failing.write };
    _ = try service.submit(ta, identity.SubmissionId.generate(), .{ .content = "one" }, null);
    _ = try service.submit(tb, identity.SubmissionId.generate(), .{ .content = "two" }, null);
    const started = std.Io.Clock.Timestamp.now(std.testing.io, .awake);
    while (first.state.load(.acquire) == .running or second.state.load(.acquire) == .running) {
        if (started.durationTo(std.Io.Clock.Timestamp.now(std.testing.io, .awake)).raw.toMilliseconds() > 3000) return error.WorkerDidNotFinish;
        std.Thread.yield() catch {};
    }
    try std.testing.expectError(error.StorageUnavailable, service.poll());
    try std.testing.expect(first.pending_commit and first.agent.busy and !second.agent.busy and !second.pending_commit);
    try std.testing.expectEqualStrings("done", service.store.find(tb.conversation).?.history.messages[1].content);
    service.store.persist = null;
    try service.poll();
    try std.testing.expect(!first.agent.busy);
}

test "AI session PATCH destroyed attachment gets fresh agent and idle send-now selects exact queue item" {
    var service = runtime.Service.init(std.testing.allocator);
    defer service.deinit();
    var fixture: RuntimeFixture = .{};
    const old = try service.attach(.{ .session = 1 }, fixture.backend());
    const initial = try service.store.create(old.agent.id);
    try std.testing.expectError(error.BindingConflict, service.retire(old.agent.id));
    try service.endConversation(initial, identity.HostOperationId.generate());
    try service.retire(old.agent.id);
    const fresh = try service.attach(.{ .session = 1 }, fixture.backend());
    try std.testing.expect(!fresh.agent.id.eql(old.agent.id));
    const ticket = try service.store.create(fresh.agent.id);
    const inbox = &service.store.find(ticket.conversation).?.inbox;
    const first = try inbox.admit(ticket, identity.SubmissionId.generate(), .{ .content = "head" }, .queue);
    const second = try inbox.admit(ticket, identity.SubmissionId.generate(), .{ .content = "selected" }, .queue);
    _ = try service.sendNow(ticket, second.id, second.revision);
    try waitStarted(&fixture);
    try std.testing.expectEqual(input.Delivery.consumed, inbox.receipt(second.id).?.delivery);
    try std.testing.expectEqual(input.Delivery.queued, inbox.receipt(first.id).?.delivery);
    try std.testing.expectError(error.ConversationUnbound, service.endConversation(initial, identity.HostOperationId.generate()));
    try std.testing.expect(!fresh.worker.?.cancel.isCancelled());
    try service.stop(ticket);
    try waitIdle(&service, fresh);
    try std.testing.expectEqualStrings("selected", service.store.find(ticket.conversation).?.history.messages[0].content);
}

test "AI session PATCH first input failure publishes no empty conversation and successful retry deduplicates" {
    const Failing = struct {
        fn write(_: *anyopaque, _: lifecycle.Event) !void {
            return error.StorageUnavailable;
        }
    };
    var service = runtime.Service.init(std.testing.allocator);
    defer service.deinit();
    var fixture: RuntimeFixture = .{};
    const runner = try service.attach(.{ .session = 1 }, fixture.backend());
    var sentinel: u8 = 0;
    service.store.persist = .{ .context = &sentinel, .write = Failing.write };
    const id = identity.SubmissionId.generate();
    try std.testing.expectError(error.StorageUnavailable, service.createAndSubmit(runner.agent.id, id, .{ .content = "first" }, null));
    try std.testing.expect(runner.agent.current == null and service.store.records.items.len == 0 and service.store.budget.count == 0);
    service.store.persist = null;
    const accepted = try service.createAndSubmit(runner.agent.id, id, .{ .content = "first" }, null);
    try waitStarted(&fixture);
    service.applySettings(.{ .follow_up_mode = .queue });
    const same = try service.createAndSubmit(runner.agent.id, id, .{ .content = "first" }, null);
    try std.testing.expect(same.id.eql(accepted.id) and same.fence.eql(accepted.fence) and same.mode == .steer and service.store.records.items.len == 1);
    try service.stop(accepted.fence);
    try waitIdle(&service, runner);
}

test "AI session PATCH first binding and pending payload replay as one durable event" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var journal = try Journal.open(std.testing.allocator, std.testing.io, tmp.dir, "sessions.jsonl");
    var store = lifecycle.Store.init(std.testing.allocator);
    try journal.bind(&store);
    const agent = try store.attach(.{ .session = 1 });
    const id = identity.SubmissionId.generate();
    const ticket = try store.createWithInput(agent.id, id, .{ .content = "atomic first input" }, .steer);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, journal.bytes.items, "\n"));
    store.deinit();
    journal.deinit();
    var reopened = try Journal.open(std.testing.allocator, std.testing.io, tmp.dir, "sessions.jsonl");
    defer reopened.deinit();
    var restored = lifecycle.Store.init(std.testing.allocator);
    defer restored.deinit();
    try reopened.bind(&restored);
    const record = restored.find(ticket.conversation).?;
    try std.testing.expect(record.needs_recovery and record.history.messages.len == 0 and record.inbox.receipt(id).?.archived);
    try std.testing.expectEqualStrings("atomic first input", record.inbox.entries.items[0].payload.messages[0].content);
    try std.testing.expectError(error.RecoveryRequired, restored.attach(.{ .session = 1 }));
}

test "AI session PATCH allocation failure during initial ownership and fork leaves no leaked payloads" {
    const Scenario = struct {
        fn run(a: std.mem.Allocator) !void {
            var store = lifecycle.Store.init(a);
            defer store.deinit();
            const source = try store.attach(.{ .session = 1 });
            const target = try store.attach(.{ .session = 2 });
            const ticket = try store.createWithInput(source.id, identity.SubmissionId.generate(), .{ .content = "owned input" }, .queue);
            _ = try store.setDraft(ticket, 1, "draft");
            try store.checkpoint(ticket, 1, &.{ .{ .content = "owned input" }, .{ .role = .assistant, .content = "answer" } }, true);
            _ = try store.forkAndUse(ticket.conversation, store.find(ticket.conversation).?.content_revision, target.id);
        }
    };
    try std.testing.checkAllAllocationFailures(std.testing.allocator, Scenario.run, .{});
}

test "AI session PATCH auto queue waits for previous local tool ownership release" {
    var service = runtime.Service.init(std.testing.allocator);
    defer service.deinit();
    var fixture: RuntimeFixture = .{ .uses_tools = true, .cleaned = false };
    const runner = try service.attach(.{ .session = 1 }, fixture.backend());
    const ticket = try service.store.create(runner.agent.id);
    _ = try service.submit(ticket, identity.SubmissionId.generate(), .{ .content = "first" }, null);
    try waitStarted(&fixture);
    const queued = try service.submit(ticket, identity.SubmissionId.generate(), .{ .content = "next" }, .queue);
    fixture.release.store(true, .release);
    try waitIdle(&service, runner);
    try std.testing.expectEqual(@as(usize, 1), fixture.calls.load(.acquire));
    try std.testing.expectEqual(input.Delivery.queued, service.store.find(ticket.conversation).?.inbox.receipt(queued.id).?.delivery);
    fixture.cleaned = true;
    try service.poll();
    try waitIdle(&service, runner);
    try std.testing.expectEqual(@as(usize, 2), fixture.calls.load(.acquire));
}

test "AI session PATCH journal owns actual image bytes and preserves distinct historical image owners" {
    const images = @import("ai/image_attachments.zig");
    const png = "\x89PNG\r\n\x1a\n\x00\x00\x00\x0dIHDR" ++
        "\x00\x00\x00\x01\x00\x00\x00\x01\x08\x06\x00\x00\x00\x1f\x15\xc4\x89" ++
        "\x00\x00\x00\x0dIDAT\x78\x9c\x63\xf8\xcf\xc0\xf0\x1f\x00\x05\x00\x01\xff\x89\x99\x3d\x1d" ++
        "\x00\x00\x00\x00IEND\xae\x42\x60\x82";
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var journal = try Journal.open(std.testing.allocator, std.testing.io, tmp.dir, "sessions.jsonl");
    var store = lifecycle.Store.init(std.testing.allocator);
    try journal.bind(&store);
    const agent = try store.attach(.{ .session = 1 });
    const first: identity.SessionHandle = .{ .session_id = @fromBackingInt(@intCast(1)), .generation = 7 };
    const other: identity.SessionHandle = .{ .session_id = @fromBackingInt(@intCast(2)), .generation = 9 };
    var original = try images.ContentRef.create(std.testing.allocator, "immutable.png", png, 123, .{});
    const ticket = try store.createWithInput(agent.id, identity.SubmissionId.generate(), .{ .content = "image", .images = &.{original}, .image_owner = first, .image_transform = 99, .offloaded_images = &.{.{ .reference = original, .owner = other }} }, .queue);
    original.release();
    store.deinit();
    journal.deinit();
    var reopened = try Journal.open(std.testing.allocator, std.testing.io, tmp.dir, "sessions.jsonl");
    defer reopened.deinit();
    var restored = lifecycle.Store.init(std.testing.allocator);
    defer restored.deinit();
    try reopened.bind(&restored);
    const message = restored.find(ticket.conversation).?.inbox.entries.items[0].payload.messages[0];
    try std.testing.expectEqualSlices(u8, png, message.images[0].content().?.bytes);
    try std.testing.expect(message.image_owner.?.eql(first) and message.offloaded_images[0].owner.?.eql(other));
    try std.testing.expectEqual(@as(u64, 99), message.image_transform);
    try std.testing.expectEqualSlices(u8, png, message.offloaded_images[0].reference.content().?.bytes);
}
