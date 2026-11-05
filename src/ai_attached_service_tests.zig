const std = @import("std");
const attached = @import("ai/attached_service.zig");
const runtime = @import("ai/session_runtime.zig");
const provider = @import("ai/provider.zig");
const identity = @import("host/identity.zig");
const legacy = @import("ai/assistant_store.zig");
const tools = @import("ai/plugin_tools.zig");
const host = @import("ai/host_tools.zig");
const a = std.testing.allocator;
const Fixture = struct {
    controller_thread: std.Thread.Id,
    runner: ?*runtime.Runner = null,
    bridge: @import("ui/ai_tools.zig").Bridge,
    table: ?tools.RequestTable = null,
    definitions: []provider.ToolDefinition = &.{},
    released: bool = true,
    disposed: bool = false,
    completed: usize = 0,
    controller_calls: usize = 0,
    query: bool = false,
    capture_count: usize = 0,
    fail_answer_once: bool = false,
    fail_capture: bool = false,
    expect_answer_only: bool = false,
    shared: ?*attached.Host = null,
    final_draft: ?[]const u8 = null,
    fail_projection_once: bool = false,
    calls: std.atomic.Value(usize) = .init(0),
    release: std.atomic.Value(bool) = .init(false),
    fn init() Fixture {
        return .{ .controller_thread = std.Thread.getCurrentId(), .bridge = @import("ui/ai_tools.zig").Bridge.init(a) };
    }
    fn deinit(self: *Fixture) void {
        if (self.table) |*table| table.deinit();
        self.bridge.deinit();
    }
    fn backend(self: *Fixture) runtime.Backend {
        return .{ .context = self, .capture = capture, .prepare = prepare, .completed = complete, .local_released = localReleased };
    }
    fn capture(raw: *anyopaque, context: runtime.Context) !void {
        const self: *Fixture = @ptrCast(@alignCast(raw));
        try std.testing.expectEqual(self.controller_thread, std.Thread.getCurrentId());
        self.capture_count += 1;
        if (self.fail_capture) return error.ContextUnavailable;
        if (self.query) {
            if (self.table) |*table| table.deinit();
            self.table = try tools.RequestTable.initWithHost(a, .{ .owner = context.owner, .members = .{} }, &.{}, &.{}, context.authority(), &.{.{ .authority = .conversation_context, .definition = .{ .id = "host.get_current_context", .schema = "{\"type\":\"object\",\"properties\":{},\"additionalProperties\":false}" } }});
            self.definitions = try tools.providerDefinitions(&self.table.?, self.table.?.arena.allocator());
        }
    }
    fn prepare(raw: *anyopaque, _: std.mem.Allocator, _: std.Io, context: runtime.Context) !runtime.Prepared {
        const self: *Fixture = @ptrCast(@alignCast(raw));
        try std.testing.expect(self.controller_thread != std.Thread.getCurrentId());
        return .{ .provider = .{ .ctx = self, .chat = chat, .models = models }, .request = .{ .model = "test", .system = "", .messages = &.{}, .tools = self.definitions, .tool_table = if (self.table) |*table| table else null }, .scope = .{ .owner = context.owner, .members = .{} }, .host = if (self.query) .{ .context = self, .execute = unsupported, .execute_host = invoke } else null };
    }
    fn unsupported(_: *anyopaque, _: @import("ai/tool_loop.zig").Invocation, _: std.mem.Allocator, _: ?*provider.CancelToken) !@import("ai/tool_loop.zig").Outcome {
        return error.UnexpectedLegacyDispatch;
    }
    fn invoke(raw: *anyopaque, invocation: host.Invocation, _: std.mem.Allocator, cancel: ?*provider.CancelToken) !host.Result {
        const self: *Fixture = @ptrCast(@alignCast(raw));
        const Exchange = struct {
            fixture: *Fixture,
            invocation: host.Invocation,
            fn run(ptr: *anyopaque) !void {
                const value: *@This() = @ptrCast(@alignCast(ptr));
                try std.testing.expectEqual(value.fixture.controller_thread, std.Thread.getCurrentId());
                const context = value.fixture.runner.?.context.?;
                try std.testing.expect(value.invocation.context.conversation_id.eql(context.fence.conversation));
                try std.testing.expect(value.invocation.context.task_id.eql(context.task));
                value.fixture.controller_calls += 1;
            }
        };
        var exchange: Exchange = .{ .fixture = self, .invocation = invocation };
        try self.bridge.callController(&exchange, Exchange.run, cancel);
        return .{ .status = .succeeded, .receipt = .{ .conversation_id = invocation.context.conversation_id, .task_id = invocation.context.task_id, .operation_id = invocation.operation_id, .binding_revision = invocation.context.binding_revision } };
    }
    fn models(_: *anyopaque, allocator: std.mem.Allocator) ![]provider.ModelInfo {
        return allocator.alloc(provider.ModelInfo, 0);
    }
    fn chat(raw: *anyopaque, request: provider.ChatRequest, sink: *const fn (*anyopaque, provider.Delta) void, sink_context: *anyopaque) !provider.ChatStats {
        const self: *Fixture = @ptrCast(@alignCast(raw));
        const call = self.calls.fetchAdd(1, .acq_rel);
        while (!self.release.load(.acquire)) {
            if (request.cancel) |cancel| if (cancel.isCancelled()) return error.Cancelled;
            std.Thread.yield() catch {};
        }
        if (self.fail_answer_once and call == 1) {
            self.fail_answer_once = false;
            return error.ProviderFailure;
        }
        if (self.expect_answer_only) try std.testing.expectEqual(@as(usize, 0), request.tools.len);
        if (self.query and call == 0) sink(sink_context, .{ .tool_plan = .{ .index = 0, .call_id = "owned-query", .name = self.definitions[0].name(), .arguments = "{}" } }) else sink(sink_context, .{ .text = "completed" });
        sink(sink_context, .done);
        return .{};
    }
    fn complete(raw: *anyopaque, runner: *runtime.Runner) !void {
        const self: *Fixture = @ptrCast(@alignCast(raw));
        try std.testing.expectEqual(self.controller_thread, std.Thread.getCurrentId());
        try std.testing.expect(runner.thread == null and runner.saved and !runner.agent.busy);
        if (self.fail_projection_once) {
            self.fail_projection_once = false;
            return error.ProjectionBusy;
        }
        self.completed += 1;
    }
    fn localReleased(raw: *anyopaque, _: runtime.Context) bool {
        return @as(*Fixture, @ptrCast(@alignCast(raw))).released;
    }
    fn pump(raw: *anyopaque) !void {
        @as(*Fixture, @ptrCast(@alignCast(raw))).bridge.pump(undefined);
    }
    fn flush(raw: *anyopaque) !void {
        const self: *Fixture = @ptrCast(@alignCast(raw));
        const text = self.final_draft orelse return;
        const ticket = try self.shared.?.service.store.fence(self.runner.?.agent.current.?);
        const record = self.shared.?.service.store.find(ticket.conversation).?;
        _ = try self.shared.?.service.store.setDraft(ticket, record.draft_revision, text);
        self.final_draft = null;
    }
    fn disposable(raw: *anyopaque) bool {
        return @as(*Fixture, @ptrCast(@alignCast(raw))).released;
    }
    fn destroy(raw: *anyopaque) void {
        @as(*Fixture, @ptrCast(@alignCast(raw))).disposed = true;
    }
    fn attach(self: *Fixture, shared: *attached.Host, owner: @import("ai/tool_scope.zig").Owner, window: identity.WindowId) !*runtime.Runner {
        const runner = try shared.service.attach(owner, self.backend());
        self.runner = runner;
        self.shared = shared;
        try shared.register(.{ .agent = runner.agent.id, .window = window, .context = self, .pump = pump, .released = disposable, .destroy = destroy, .flush = flush });
        return runner;
    }
};
fn awaitStarted(fixture: *Fixture) !void {
    const start = std.Io.Clock.Timestamp.now(std.testing.io, .awake);
    while (fixture.calls.load(.acquire) == 0) {
        if (start.durationTo(std.Io.Clock.Timestamp.now(std.testing.io, .awake)).raw.toMilliseconds() > 3000) return error.WorkerTimeout;
        std.Thread.yield() catch {};
    }
}
fn awaitIdle(shared: *attached.Host, runner: *runtime.Runner) !void {
    const start = std.Io.Clock.Timestamp.now(std.testing.io, .awake);
    while (runner.thread != null or runner.agent.busy or runner.pending_commit or runner.pending_notify) {
        try shared.pump();
        if (start.durationTo(std.Io.Clock.Timestamp.now(std.testing.io, .awake)).raw.toMilliseconds() > 3000) return error.WorkerTimeout;
        std.Thread.yield() catch {};
    }
}
test "AiHost integration one process domain shares the service and group identity source" {
    const Domain = @import("ui/application_host.zig").Domain;
    const domain = try Domain.init(a, false);
    defer domain.deinit();
    try std.testing.expectEqual(try domain.aiService(), try domain.aiService());
    const Roster = @import("ui/group_model.zig").Roster;
    var first = Roster.init(a);
    defer first.deinit();
    var second = Roster.init(a);
    defer second.deinit();
    first.shared_identity = &domain.group_identity;
    second.shared_identity = &domain.group_identity;
    const id = (try first.createOrGet("same label", 0)).id;
    try std.testing.expect((try second.createOrGet("same label", 0)).id != id);
}
test "AiHost integration real workers share one writer and closing one window leaves another running" {
    var shared = attached.Host.init(a);
    var first = Fixture.init();
    defer first.deinit();
    var second = Fixture.init();
    defer second.deinit();
    defer shared.deinit() catch unreachable;
    const w1: identity.WindowId = @fromBackingInt(@intCast(1));
    const w2: identity.WindowId = @fromBackingInt(@intCast(2));
    const one = try first.attach(&shared, .{ .session = 1 }, w1);
    const two = try second.attach(&shared, .{ .session = 2 }, w2);
    const same = try shared.service.attach(.{ .session = 1 }, second.backend());
    try std.testing.expectEqual(one, same);
    try std.testing.expectEqual(@as(*anyopaque, &first), same.backend.context);
    try std.testing.expectError(error.AgentBridgeConflict, shared.register(.{ .agent = one.agent.id, .window = w2, .context = &second, .pump = Fixture.pump, .released = Fixture.disposable, .destroy = Fixture.destroy }));
    const t1 = try shared.service.store.create(one.agent.id);
    const t2 = try shared.service.store.create(two.agent.id);
    _ = try shared.service.submit(t1, identity.SubmissionId.generate(), .{ .content = "one" }, null);
    _ = try shared.service.submit(t2, identity.SubmissionId.generate(), .{ .content = "two" }, null);
    try awaitStarted(&first);
    try awaitStarted(&second);
    _ = try shared.closeWindow(w1);
    try awaitIdle(&shared, one);
    try shared.releaseWindow(w1);
    try std.testing.expect(first.disposed and !second.disposed and !two.cancel.isCancelled() and two.agent.busy);
    second.release.store(true, .release);
    try awaitIdle(&shared, two);
    try std.testing.expectEqual(@as(usize, 1), second.completed);
}
test "AiHost integration controller bridge runs off worker and closes the real call result batch" {
    var shared = attached.Host.init(a);
    var fixture = Fixture.init();
    defer fixture.deinit();
    defer shared.deinit() catch unreachable;
    fixture.query = true;
    fixture.release.store(true, .release);
    const runner = try fixture.attach(&shared, .{ .session = 4 }, @fromBackingInt(@intCast(1)));
    const ticket = try shared.service.store.create(runner.agent.id);
    _ = try shared.service.submit(ticket, identity.SubmissionId.generate(), .{ .content = "query host" }, null);
    try awaitIdle(&shared, runner);
    try std.testing.expectEqual(@as(usize, 1), fixture.controller_calls);
    try std.testing.expectEqual(@as(usize, 1), fixture.completed);
    const history = shared.service.store.find(ticket.conversation).?.history;
    try std.testing.expectEqualStrings("owned-query", history.messages[1].tool_calls[0].id);
    try std.testing.expectEqualStrings("owned-query", history.messages[2].tool_call_id.?);
    try std.testing.expectEqualStrings("completed", history.messages[3].content);
}
test "AiHost integration window close keeps binding until all its hidden owners release resources" {
    var shared = attached.Host.init(a);
    var first = Fixture.init();
    defer first.deinit();
    var second = Fixture.init();
    defer second.deinit();
    defer shared.deinit() catch unreachable;
    const window: identity.WindowId = @fromBackingInt(@intCast(7));
    const one = try first.attach(&shared, .{ .session = 1 }, window);
    const two = try second.attach(&shared, .{ .group = 1 }, window);
    second.query = true;
    second.released = false;
    const t1 = try shared.service.store.create(one.agent.id);
    const t2 = try shared.service.store.create(two.agent.id);
    _ = try shared.service.submit(t1, identity.SubmissionId.generate(), .{ .content = "visible" }, null);
    _ = try shared.service.submit(t2, identity.SubmissionId.generate(), .{ .content = "hidden" }, null);
    try awaitStarted(&first);
    try awaitStarted(&second);
    try std.testing.expect(!try shared.closeWindow(window));
    try awaitIdle(&shared, one);
    try awaitIdle(&shared, two);
    try std.testing.expect(shared.service.store.find(t2.conversation).?.binding != null and !shared.windowReady(window));
    second.released = true;
    try std.testing.expect(try shared.closeWindow(window));
    try shared.releaseWindow(window);
    try std.testing.expect(first.disposed and second.disposed);
}
test "AiHost integration migration preserves identity history draft and invalidates old binding tickets" {
    var shared = attached.Host.init(a);
    defer shared.deinit() catch unreachable;
    var old = legacy.Store.init(a);
    defer old.deinit();
    const state = try old.create(.{ .group = 42 });
    state.initial_owner = .{ .session = 7 };
    const id = state.conversation_id;
    state.wire_history = try @import("ai/wire_history.zig").History.copy(a, &.{ .{ .content = "old input" }, .{ .role = .assistant, .content = "actual answer" } }, "");
    state.draft = try a.dupe(u8, "keep this draft");
    state.phase = .done;
    state.current_turn.id = 19;
    const released: @import("ai/session_lifecycle.zig").Released = .{ .worker_joined = true, .dispatch_closed = true, .local_released = true, .transcript_saved = true };
    try shared.migrate(state, released);
    try shared.migrate(state, released);
    const record = shared.service.store.find(id).?;
    try std.testing.expectEqual(@as(usize, 1), shared.service.store.records.items.len);
    try std.testing.expect(record.id.eql(id) and state.binding_revision == record.revision and record.revision > 1);
    try std.testing.expectEqualStrings("actual answer", record.history.messages[1].content);
    try std.testing.expectEqualStrings("keep this draft", record.draft.?);
    try std.testing.expect(record.initial_origin.?.eql(.{ .session = 7 }) and record.binding.?.owner.eql(.{ .group = 42 }));
    state.phase = .running;
    try std.testing.expectError(error.LegacyWorkerStillRunning, shared.migrate(state, released));
    state.phase = .done;
    const operation = identity.HostOperationId.generate();
    const ticket = try shared.service.store.fence(id);
    _ = try shared.service.store.beginEnd(ticket, operation);
    try shared.service.store.commitEnd(ticket, operation, .{ .worker_joined = true, .dispatch_closed = true, .local_released = true, .transcript_saved = true });
}
test "AiHost integration ended legacy selection cannot reanimate a binding" {
    var store = legacy.Store.init(a);
    defer store.deinit();
    const state = try store.create(.{ .session = 3 });
    state.ended = true;
    state.selected = false;
    try std.testing.expect(!store.select(state.id));
    try std.testing.expect(state.ended and !state.selected);
}

test "AiHost integration pending completion cannot be overwritten by a new input or End" {
    var shared = attached.Host.init(a);
    var fixture = Fixture.init();
    defer fixture.deinit();
    defer shared.deinit() catch unreachable;
    fixture.fail_projection_once = true;
    fixture.release.store(true, .release);
    const runner = try fixture.attach(&shared, .{ .session = 1 }, @fromBackingInt(@intCast(1)));
    const ticket = try shared.service.store.create(runner.agent.id);
    _ = try shared.service.submit(ticket, identity.SubmissionId.generate(), .{ .content = "one" }, null);
    const start = std.Io.Clock.Timestamp.now(std.testing.io, .awake);
    while (runner.state.load(.acquire) == .running) {
        if (start.durationTo(std.Io.Clock.Timestamp.now(std.testing.io, .awake)).raw.toMilliseconds() > 3000) return error.WorkerTimeout;
        std.Thread.yield() catch {};
    }
    try std.testing.expectError(error.ProjectionBusy, shared.pump());
    try std.testing.expect(runner.pending_notify);
    const turn = runner.context.?.turn;
    _ = try shared.service.submit(ticket, identity.SubmissionId.generate(), .{ .content = "must wait" }, null);
    try std.testing.expect(runner.context.?.turn == turn and runner.thread == null);
    try shared.service.endConversation(ticket, identity.HostOperationId.generate());
    try std.testing.expect(shared.service.store.find(ticket.conversation).?.binding != null);
    try shared.pump();
    try std.testing.expect(!runner.pending_notify and runner.agent.current == null and fixture.completed == 1);
}

test "AiHost integration one failed End persistence still cancels every owner in its window" {
    const Failing = struct {
        id: identity.ConversationId,
        fn write(raw: *anyopaque, event: @import("ai/session_lifecycle.zig").Event) !void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            if (event.kind == .end_requested and event.conversation.eql(self.id)) return error.StorageUnavailable;
        }
    };
    var shared = attached.Host.init(a);
    var first = Fixture.init();
    defer first.deinit();
    var second = Fixture.init();
    defer second.deinit();
    defer shared.deinit() catch unreachable;
    const window: identity.WindowId = @fromBackingInt(@intCast(1));
    const one = try first.attach(&shared, .{ .session = 1 }, window);
    const two = try second.attach(&shared, .{ .session = 2 }, window);
    const ticket = try shared.service.store.create(one.agent.id);
    const other = try shared.service.store.create(two.agent.id);
    _ = try shared.service.submit(ticket, identity.SubmissionId.generate(), .{ .content = "one" }, null);
    _ = try shared.service.submit(other, identity.SubmissionId.generate(), .{ .content = "two" }, null);
    try awaitStarted(&first);
    try awaitStarted(&second);
    var failing: Failing = .{ .id = ticket.conversation };
    shared.service.store.persist = .{ .context = &failing, .write = Failing.write };
    try std.testing.expectError(error.StorageUnavailable, shared.closeWindow(window));
    try std.testing.expect(one.cancel.isCancelled() and two.cancel.isCancelled());
    shared.service.store.persist = null;
    const start = std.Io.Clock.Timestamp.now(std.testing.io, .awake);
    while (!(try shared.closeWindow(window))) {
        if (start.durationTo(std.Io.Clock.Timestamp.now(std.testing.io, .awake)).raw.toMilliseconds() > 3000) return error.WorkerTimeout;
        std.Thread.yield() catch {};
    }
    try std.testing.expect(one.agent.current == null and two.agent.current == null);
}

test "AiHost integration durable orphan recovery retains canonical history and archives old input" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer a.free(path);
    var first = attached.Host.init(a);
    try first.ensurePersistence(path);
    const agent = try first.service.store.attach(.{ .session = 7 });
    const ticket = try first.service.store.create(agent.id);
    try first.service.store.checkpoint(ticket, 9, &.{ .{ .content = "saved input" }, .{ .role = .assistant, .content = "saved answer" } }, true);
    _ = try first.service.store.setDraft(ticket, 1, "unsent draft");
    const receipt = try first.service.store.find(ticket.conversation).?.inbox.admit(ticket, identity.SubmissionId.generate(), .{ .content = "never auto-run" }, .queue);
    const frozen = try tmp.dir.readFileAlloc(std.testing.io, "ai-sessions.jsonl", a, .limited(1024 * 1024));
    defer a.free(frozen);
    try first.deinit();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "ai-sessions.jsonl", .data = frozen });
    var recovered = attached.Host.init(a);
    defer recovered.deinit() catch unreachable;
    try recovered.ensurePersistence(path);
    const record = recovered.service.store.find(ticket.conversation).?;
    try std.testing.expect(record.binding == null and record.closed_revision != null and !record.needs_recovery);
    try std.testing.expectEqualStrings("saved answer", record.history.messages[1].content);
    try std.testing.expectEqualStrings("unsent draft", record.draft.?);
    try std.testing.expect(record.inbox.receipt(receipt.id).?.archived and recovered.service.runners.items.len == 0);
    const presentation = recovered.presentations.findConversation(ticket.conversation).?;
    try std.testing.expect(presentation.historical_environment and presentation.ended and !presentation.selected);
}

test "AiHost integration answer recovery preserves Task and never repeats the real controller tool" {
    var fixture = Fixture.init();
    defer fixture.deinit();
    fixture.query = true;
    fixture.fail_answer_once = true;
    fixture.release.store(true, .release);
    var shared = attached.Host.init(a);
    defer shared.deinit() catch unreachable;
    const runner = try fixture.attach(&shared, .{ .session = 1 }, @fromBackingInt(@intCast(1)));
    const ticket = try shared.service.store.create(runner.agent.id);
    _ = try shared.service.submit(ticket, identity.SubmissionId.generate(), .{ .content = "query once" }, null);
    try awaitIdle(&shared, runner);
    try std.testing.expectEqual(error.ProviderFailure, runner.failure.?);
    const original = runner.context.?;
    try std.testing.expectEqual(@as(usize, 1), fixture.controller_calls);
    fixture.expect_answer_only = true;
    try shared.service.resumeAnswer(ticket);
    try awaitIdle(&shared, runner);
    try std.testing.expect(runner.failure == null);
    try std.testing.expect(runner.context.?.task.eql(original.task));
    try std.testing.expectEqual(original.turn, runner.context.?.turn);
    try std.testing.expectEqual(@as(usize, 1), fixture.controller_calls);
    try std.testing.expectEqualStrings("completed", shared.service.store.find(ticket.conversation).?.history.messages[3].content);
}

test "AiHost integration final draft is flushed before an idle window can unbind" {
    var fixture = Fixture.init();
    defer fixture.deinit();
    var shared = attached.Host.init(a);
    defer shared.deinit() catch unreachable;
    const window: identity.WindowId = @fromBackingInt(@intCast(1));
    const runner = try fixture.attach(&shared, .{ .session = 1 }, window);
    const ticket = try shared.service.store.create(runner.agent.id);
    fixture.final_draft = "typed just before close";
    try std.testing.expect(try shared.closeWindow(window));
    const record = shared.service.store.find(ticket.conversation).?;
    try std.testing.expect(record.binding == null and record.closed_revision != null);
    try std.testing.expectEqualStrings("typed just before close", record.draft.?);
    try shared.service.store.remove(ticket.conversation);
    try shared.pump();
    try std.testing.expect(runner.record == null and runner.context == null and runner.manager.input == null);
}

test "AiHost integration pinned earlier fork excludes later history and queued authority" {
    var fixture = Fixture.init();
    defer fixture.deinit();
    var shared = attached.Host.init(a);
    defer shared.deinit() catch unreachable;
    const runner = try fixture.attach(&shared, .{ .session = 1 }, @fromBackingInt(@intCast(1)));
    const ticket = try shared.service.store.create(runner.agent.id);
    const first = [_]provider.Message{ .{ .content = "first" }, .{ .role = .assistant, .content = "first result" } };
    try shared.service.store.checkpoint(ticket, 1, &first, true);
    const record = shared.service.store.find(ticket.conversation).?;
    const pinned_revision = record.content_revision;
    try shared.service.store.checkpoint(ticket, 2, &.{ first[0], first[1], .{ .content = "later" }, .{ .role = .assistant, .content = "later result" } }, true);
    _ = try record.inbox.admit(ticket, identity.SubmissionId.generate(), .{ .content = "unexecuted" }, .queue);
    try shared.service.endConversation(ticket, identity.HostOperationId.generate());
    try std.testing.expectError(error.CheckpointChanged, shared.service.store.forkCheckpointAndUse(record.id, pinned_revision, 1, &first, runner.agent.id));
    const forked = try shared.service.store.forkCheckpointAndUse(record.id, record.content_revision, 1, &first, runner.agent.id);
    const copy = shared.service.store.find(forked.conversation).?;
    try std.testing.expect(!copy.id.eql(record.id) and record.binding == null);
    try std.testing.expectEqual(@as(usize, 2), copy.history.messages.len);
    try std.testing.expectEqual(@as(usize, 0), copy.inbox.entries.items.len);
    try std.testing.expectEqual(@as(u64, 1), copy.fork_turn.?);
}

test "AiHost integration accepted input survives controller capture failure and can still End" {
    var fixture = Fixture.init();
    defer fixture.deinit();
    fixture.fail_capture = true;
    var shared = attached.Host.init(a);
    defer shared.deinit() catch unreachable;
    const runner = try fixture.attach(&shared, .{ .session = 1 }, @fromBackingInt(@intCast(1)));
    const ticket = try shared.service.store.create(runner.agent.id);
    const id = identity.SubmissionId.generate();
    const receipt = try shared.service.submit(ticket, id, .{ .content = "must retain this accepted input" }, null);
    try std.testing.expect(receipt.id.eql(id) and receipt.pause == .failure);
    try std.testing.expect(runner.pending_notify and runner.thread == null and runner.saved);
    try shared.pump();
    try std.testing.expectEqual(@as(usize, 1), fixture.completed);
    try std.testing.expectEqual(@as(usize, 0), fixture.calls.load(.acquire));
    try std.testing.expectEqualStrings("must retain this accepted input", shared.service.store.find(ticket.conversation).?.inbox.entries.items[0].payload.messages[0].content);
    try shared.service.endConversation(ticket, identity.HostOperationId.generate());
    try std.testing.expect(shared.service.store.find(ticket.conversation).?.binding == null);
}
