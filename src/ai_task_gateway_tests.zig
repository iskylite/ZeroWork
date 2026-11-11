const std = @import("std");
const a = std.testing.allocator;
const id = @import("host/identity.zig");
const budget = @import("ai/task_budget.zig");
const Runtime = @import("ai/session_runtime.zig");
const gateway = @import("ai/child_gateway.zig");
const P = @import("ai/provider.zig");
const Clock = @import("ai/retry.zig").Clock;
fn fact(root: id.TaskId) budget.Fact {
    return .{ .root = root, .task = root, .agent = .generate(), .conversation = .generate(), .generation = 1 };
}
test "v0.4 task shared counters record unlimited requests and calls across answer recovery" {
    var root = budget.Root.init(a);
    defer root.deinit();
    const parent = fact(.generate());
    try root.add(parent);
    try root.take(parent.task, 80, 160);
    var child = fact(parent.root);
    child.task = .generate();
    child.parent = parent.task;
    try root.add(child);
    try root.take(child.task, 80, 160);
    try root.state(child.task, .succeeded, "child fact");
    try root.state(parent.task, .failed, "answer recovery");
    try root.resumeAnswer(parent.task);
    try root.take(parent.task, 1, 0);
    try std.testing.expectEqual(@as(u64, 161), root.counters.requests);
    try std.testing.expectEqual(@as(u64, 320), root.counters.calls);
}

test "v0.4 task human waits pause only when every machine branch is waiting" {
    var root = budget.Root.init(a);
    defer root.deinit();
    const parent = fact(.generate());
    try root.add(parent);
    var child = fact(parent.root);
    child.task = .generate();
    child.parent = parent.task;
    try root.add(child);
    try root.state(parent.task, .waiting_children, "");
    const before = root.counters.elapsed_ns;
    (Clock{}).sleep(2 * std.time.ns_per_ms);
    try root.check();
    try std.testing.expect(root.counters.elapsed_ns > before);
    try root.state(child.task, .human_wait, "");
    const paused = root.counters.elapsed_ns;
    (Clock{}).sleep(2 * std.time.ns_per_ms);
    try root.check();
    try std.testing.expectEqual(paused, root.counters.elapsed_ns);
    root.counters.timeout_ns = root.counters.elapsed_ns;
    try std.testing.expectError(error.SharedTaskTimeout, root.check());
    try root.state(child.task, .succeeded, "settled");
    try root.resumeAnswer(parent.task);
    try root.check();
}
test "v0.4 task four unfinished children and durable dispatch counters fail closed" {
    var root = budget.Root.init(a);
    defer root.deinit();
    const parent = fact(.generate());
    try root.add(parent);
    for (0..4) |_| {
        var child = fact(parent.root);
        child.task = .generate();
        child.parent = parent.task;
        try root.add(child);
    }
    var fifth = fact(parent.root);
    fifth.task = .generate();
    fifth.parent = parent.task;
    try std.testing.expectError(error.ChildTaskLimit, root.add(fifth));
    const Failure = struct {
        fn write(_: *anyopaque, _: budget.Fact) !void {
            return error.DiskFull;
        }
    };
    var sentinel: u8 = 0;
    root.persist = .{ .context = &sentinel, .write = Failure.write };
    try std.testing.expectError(error.DiskFull, root.take(parent.task, 1, 0));
    try std.testing.expectEqual(@as(u32, 0), root.counters.requests);
    try std.testing.expectError(error.TaskPersistenceFailed, root.take(parent.task, 1, 0));
}
test "v0.4 task model slots enforce four global two per root and fair cancellable admission" {
    var slots: budget.Slots = .{};
    const first = id.TaskId.generate();
    const other = id.TaskId.generate();
    const third = id.TaskId.generate();
    const p1 = try slots.enqueue(first);
    try std.testing.expect(slots.tryAcquire(p1));
    const p2 = try slots.enqueue(first);
    try std.testing.expect(slots.tryAcquire(p2));
    const p3 = try slots.enqueue(first);
    try std.testing.expect(!slots.tryAcquire(p3));
    const q1 = try slots.enqueue(other);
    try std.testing.expect(slots.tryAcquire(q1));
    const q2 = try slots.enqueue(other);
    try std.testing.expect(slots.tryAcquire(q2));
    const r1 = try slots.enqueue(third);
    try std.testing.expect(!slots.tryAcquire(r1));
    slots.release(q2);
    try std.testing.expect(slots.tryAcquire(r1));
    slots.release(p2);
    const q3 = try slots.enqueue(other);
    // Root rotation admits the eligible oldest different root.
    try std.testing.expect(slots.tryAcquire(p3));
    slots.cancel(q3);
    slots.release(p1);
    slots.release(p3);
    slots.release(q1);
    slots.release(r1);
    for (slots.active) |entry| try std.testing.expect(entry == null);
    for (slots.queue) |entry| try std.testing.expect(entry == null);
}
const Fake = struct {
    timeout_ms: u32 = 600000,
    retry_once: bool = false,
    runner: ?*Runtime.Runner = null,
    expect_read_only: bool = false,
    calls: std.atomic.Value(usize) = .init(0),
    release: std.atomic.Value(bool) = .init(false),
    fn backend(self: *Fake) Runtime.Backend {
        return .{ .context = self, .prepare = prepare, .capture = capture };
    }
    fn capture(raw: *anyopaque, _: Runtime.Context) !void {
        const self: *Fake = @ptrCast(@alignCast(raw));
        if (self.retry_once) {
            self.runner.?.worker.?.manager.retry_policy.delays_ms = @splat(1);
        }
    }
    fn prepare(raw: *anyopaque, _: std.mem.Allocator, _: std.Io, context: Runtime.Context) !Runtime.Prepared {
        const self: *Fake = @ptrCast(@alignCast(raw));
        return .{ .provider = .{ .ctx = raw, .chat = chat, .models = models }, .request = .{ .model = "fixture", .system = "", .messages = &.{}, .timeout_ms = self.timeout_ms }, .scope = .{ .owner = context.owner, .members = .{}, .inventory = &.{} } };
    }
    fn chat(raw: *anyopaque, request: P.ChatRequest, sink: *const fn (*anyopaque, P.Delta) void, output: *anyopaque) !P.ChatStats {
        const self: *Fake = @ptrCast(@alignCast(raw));
        if (self.expect_read_only) try std.testing.expect(std.mem.indexOf(u8, request.system, "本任务仅允许只读核验") != null);
        const attempt = self.calls.fetchAdd(1, .acq_rel);
        while (!self.release.load(.acquire)) {
            if (request.cancel) |cancel| if (cancel.isCancelled()) return error.Cancelled;
            (Clock{}).sleep(std.time.ns_per_ms);
        }
        if (self.retry_once and attempt == 0) return error.RateLimited;
        sink(output, .{ .text = "CHILD_EVIDENCE" });
        sink(output, .done);
        return .{ .input_tokens = 7, .output_tokens = 3, .usage_reported = true };
    }
    fn models(_: *anyopaque, alloc: std.mem.Allocator) ![]P.ModelInfo {
        return alloc.alloc(P.ModelInfo, 0);
    }
};
const Factory = struct {
    service: *Runtime.Service,
    fake: *Fake,
    fail: bool = false,
    fn install(raw: *anyopaque, record: *@import("ai/session_lifecycle.zig").Record, root: *budget.Root, task: budget.Fact, _: id.SubmissionId, _: []const u8) !*Runtime.Runner {
        const self: *@This() = @ptrCast(@alignCast(raw));
        if (self.fail) return error.TestStartupFailure;
        return self.service.adoptChild(record, self.fake.backend(), root, task);
    }
};
fn started(fake: *Fake) !void {
    const start = (Clock{}).now();
    while (fake.calls.load(.acquire) == 0) {
        if ((Clock{}).now() - start > 3 * std.time.ns_per_s) return error.TestWorkerTimeout;
        (Clock{}).sleep(std.time.ns_per_ms);
    }
}
fn invoke(env: gateway.Environment, json: []const u8) !@import("ai/host_tools.zig").Result {
    const parsed = try std.json.parseFromSlice(std.json.Value, a, json, .{});
    defer parsed.deinit();
    const request = try gateway.parse(a, parsed.value);
    defer request.deinit();
    var hash: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(json, &hash, .{});
    return gateway.execute(env, .{ .context = env.authority, .authority = .conversation_context, .operation_id = 1, .turn_id = 1, .call_id = "gateway-call", .tool_id = gateway.tool_id, .arguments = parsed.value, .arguments_json = json, .arguments_hash = hash, .canonical_arguments_hash = hash }, request.value, a);
}
const create = "{\"action\":\"create\",\"request_key\":\"one\",\"name\":\"reader\",\"text\":\"only supplied material\",\"session_refs\":[],\"reusable\":true}";
test "v0.4 task gateway atomic launch idempotency report delivery and worker settlement" {
    var main: Fake = .{};
    var child: Fake = .{};
    var service = Runtime.Service.init(a);
    defer service.deinit();
    const parent = try service.attach(.{ .session = 11 }, main.backend());
    const fence = try service.store.create(parent.agent.id);
    _ = try service.submit(fence, .generate(), .{ .content = "parent" }, null);
    try started(&main);
    var factory: Factory = .{ .service = &service, .fake = &child };
    const env: gateway.Environment = .{ .service = &service, .authority = parent.context.?.authority(), .live = .{ .owner = parent.agent.owner, .members = .{}, .inventory = &.{11} }, .handles = &.{.{ .session_id = @fromBackingInt(11), .generation = 2 }}, .factory = .{ .context = &factory, .install = Factory.install } };
    var response = try invoke(env, create);
    defer response.deinit(a);
    try started(&child);
    try std.testing.expectEqual(@as(usize, 2), service.store.records.items.len);
    try std.testing.expectEqual(@as(usize, 2), parent.task_root.?.count);
    var child_env = env;
    child_env.authority = service.runners.items[1].context.?.authority();
    try std.testing.expectError(error.ChildCannotDelegate, invoke(child_env, "{\"action\":\"list\"}"));
    var repeated = try invoke(env, create);
    defer repeated.deinit(a);
    try std.testing.expectEqual(@as(usize, 1), child.calls.load(.acquire));
    try std.testing.expectError(error.ChildRequestConflict, invoke(env, "{\"action\":\"create\",\"request_key\":\"one\",\"name\":\"reader\",\"text\":\"changed\",\"session_refs\":[]}"));
    try std.testing.expectError(error.TargetNotAuthorized, invoke(env, "{\"action\":\"create\",\"request_key\":\"outside\",\"name\":\"reader\",\"text\":\"x\",\"session_refs\":[\"s1:outside:99:1\"]}"));
    child.release.store(true, .release);
    const start = (Clock{}).now();
    while (parent.task_root.?.childrenRunning(parent.context.?.task)) {
        try service.poll();
        if ((Clock{}).now() - start > 3 * std.time.ns_per_s) return error.TestWorkerTimeout;
        (Clock{}).sleep(std.time.ns_per_ms);
    }
    try std.testing.expect(service.runners.items[1].worker == null and service.store.records.items[1].binding == null);
    var events = try invoke(env, "{\"action\":\"wait_events\"}");
    defer events.deinit(a);
    try std.testing.expect(parent.task_root.?.needsChildren(parent.context.?.task));
    try gateway.acknowledge(parent.task_root.?, &events, a);
    const event_body = try std.json.parseFromSlice(std.json.Value, a, events.blocks[0].structured, .{});
    defer event_body.deinit();
    const watermark = event_body.value.object.get("watermark").?.integer;
    const wait_json = try std.fmt.allocPrint(a, "{{\"action\":\"wait_events\",\"after_sequence\":{d}}}", .{watermark});
    defer a.free(wait_json);
    var no_echo = try invoke(env, wait_json);
    defer no_echo.deinit(a);
    const empty = try std.json.parseFromSlice(std.json.Value, a, no_echo.blocks[0].structured, .{});
    defer empty.deinit();
    try std.testing.expectEqual(@as(usize, 0), empty.value.object.get("events").?.array.items.len);

    try std.testing.expect(!parent.task_root.?.needsChildren(parent.context.?.task));
    try std.testing.expectEqual(@as(u64, 7), parent.task_root.?.counters.input_tokens);
    try std.testing.expect(std.mem.indexOf(u8, events.blocks[0].structured, "CHILD_EVIDENCE") != null);
    const old_fact = parent.task_root.?.facts[1];
    const old_child = service.runners.items[1];
    const reuse_json = try std.fmt.allocPrint(a, "{{\"action\":\"reuse\",\"request_key\":\"again\",\"agent_id\":\"{s}\",\"text\":\"new explicit task\",\"session_refs\":[]}}", .{std.fmt.bytesToHex(old_fact.agent.bytes, .lower)});
    defer a.free(reuse_json);
    var reused = try invoke(env, reuse_json);
    defer reused.deinit(a);
    try std.testing.expectEqual(@as(u64, 2), old_child.worker_generation);
    try std.testing.expect(!old_fact.task.eql(old_child.context.?.task));
    try std.testing.expect(old_fact.task.eql(parent.task_root.?.facts[1].task) and parent.task_root.?.facts[1].status == .succeeded);
    while (parent.task_root.?.childrenRunning(parent.context.?.task)) {
        try service.poll();
        (Clock{}).sleep(std.time.ns_per_ms);
    }
    factory.fail = true;
    const failure_json = try std.fmt.allocPrint(a, "{{\"action\":\"reuse\",\"request_key\":\"startup-fail\",\"agent_id\":\"{s}\",\"text\":\"explicit next task\",\"session_refs\":[]}}", .{std.fmt.bytesToHex(old_fact.agent.bytes, .lower)});
    defer a.free(failure_json);
    try std.testing.expectError(error.ChildStartupFailed, invoke(env, failure_json));
    try std.testing.expectEqual(budget.Status.failed, parent.task_root.?.facts[3].status);
    try std.testing.expect(service.store.records.items[1].binding == null and !service.store.records.items[1].task_pending);
}
test "v0.4.3 child receives the current workspace and only explicitly delegated file capability" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDir(io, "project", .default_dir);
    try tmp.dir.createDir(io, "next", .default_dir);
    const project = try tmp.dir.realPathFileAlloc(io, "project", a);
    defer a.free(project);
    const next = try tmp.dir.realPathFileAlloc(io, "next", a);
    defer a.free(next);

    var main: Fake = .{};
    var child: Fake = .{};
    var service = Runtime.Service.init(a);
    defer service.deinit();
    const parent = try service.attach(.{ .session = 11 }, main.backend());
    const fence = try service.store.create(parent.agent.id);
    try std.testing.expect(try service.store.setWorkspace(io, fence, 1, project));
    _ = try service.submit(fence, .generate(), .{ .content = "parent" }, null);
    try started(&main);
    var factory: Factory = .{ .service = &service, .fake = &child };
    const terminal: id.SessionHandle = .{ .session_id = @fromBackingInt(11) };
    var env: gateway.Environment = .{
        .service = &service,
        .authority = parent.context.?.authority(),
        .live = .{ .owner = parent.agent.owner, .members = .{}, .inventory = &.{11} },
        .handles = &.{terminal},
        .local_files = .read,
        .factory = .{ .context = &factory, .install = Factory.install },
    };
    const reference = try @import("ai/host_queries.zig").sessionRef(a, env.authority, terminal);
    defer a.free(reference);
    const assign = try std.fmt.allocPrint(a, "{{\"action\":\"create\",\"request_key\":\"one\",\"name\":\"child\",\"text\":\"inspect the working directory\",\"session_refs\":[\"{s}\"],\"reusable\":true,\"local_files\":\"write\"}}", .{reference});
    defer a.free(assign);
    try std.testing.expectError(error.LocalFileAuthorityNotGranted, invoke(env, assign));
    try std.testing.expectError(error.InvalidArguments, invoke(env, "{\"action\":\"list\",\"local_files\":\"read\"}"));
    try std.testing.expectEqual(@as(usize, 1), service.store.records.items.len);

    env.local_files = .write;
    try std.testing.expectError(error.LocalFileAuthorityNotGranted, invoke(env, assign));
    env.workspace_targets = &.{terminal};
    try std.testing.expectError(error.LocalFileAuthorityNotGranted, invoke(env, "{\"action\":\"create\",\"request_key\":\"material\",\"name\":\"child\",\"text\":\"read files\",\"session_refs\":[],\"local_files\":\"read\"}"));
    var response = try invoke(env, assign);
    defer response.deinit(a);
    try started(&child);
    const receipt = try std.json.parseFromSlice(std.json.Value, a, response.blocks[0].structured, .{});
    defer receipt.deinit();
    const view = receipt.value.object.get("local_workspace").?.object;
    try std.testing.expectEqualStrings(project, view.get("directory").?.string);
    try std.testing.expectEqualStrings("ready", view.get("state").?.string);
    const runner = service.runners.items[1];
    const authority = runner.context.?.authority();
    try std.testing.expectEqual(.write, try service.localFiles(authority, .write, .write));
    try std.testing.expectEqual(.read, try service.localFiles(authority, .write, .read));
    try std.testing.expectEqual(.none, try service.localFiles(authority, .write, .none));
    try std.testing.expectEqual(.none, try service.localFiles(authority, .none, .write));
    const scopes = try parent.task_root.?.childFileTasks(a, env.authority);
    defer a.free(scopes);
    try std.testing.expectEqual(@as(usize, 1), scopes.len);
    try std.testing.expect(scopes[0].matches(authority));
    try std.testing.expectError(error.ChildCannotDelegate, parent.task_root.?.childFileTasks(a, authority));

    try std.testing.expect(try service.store.setWorkspace(io, fence, 2, next));
    child.release.store(true, .release);
    const start = (Clock{}).now();
    while (parent.task_root.?.childrenRunning(parent.context.?.task)) {
        try service.poll();
        if ((Clock{}).now() - start > 3 * std.time.ns_per_s) return error.TestWorkerTimeout;
        (Clock{}).sleep(std.time.ns_per_ms);
    }
    child.release.store(false, .release);
    const reuse = try std.fmt.allocPrint(a, "{{\"action\":\"reuse\",\"request_key\":\"verify\",\"agent_id\":\"{s}\",\"text\":\"verify without writing\",\"session_refs\":[\"{s}\"],\"purpose\":\"verify\",\"local_files\":\"write\"}}", .{ std.fmt.bytesToHex(runner.agent.id.bytes, .lower), reference });
    defer a.free(reuse);
    var reused = try invoke(env, reuse);
    defer reused.deinit(a);
    const reread = try std.json.parseFromSlice(std.json.Value, a, reused.blocks[0].structured, .{});
    defer reread.deinit();
    try std.testing.expectEqualStrings(project, reread.value.object.get("local_workspace").?.object.get("directory").?.string);
    try std.testing.expectEqualStrings("read", reread.value.object.get("task").?.object.get("local_files").?.string);
    const verify_authority = runner.context.?.authority();
    try std.testing.expectEqual(.read, try service.localFiles(verify_authority, .write, .write));
    try std.testing.expectError(error.ScopeChanged, service.localFiles(authority, .write, .write));
    try service.stop(fence);
    try std.testing.expectEqual(.none, try service.localFiles(verify_authority, .write, .write));
}

test "v0.4.3 child task rollover cannot restore file writes after downgrade or an unknown result" {
    var root = budget.Root.init(a);
    defer root.deinit();
    const parent = fact(.generate());
    try root.add(parent);
    var child = fact(parent.root);
    child.task = .generate();
    child.parent = parent.task;
    child.local_files = .write;
    try root.add(child);
    var next = child;
    next.task = .generate();
    next.generation = 2;
    try std.testing.expectError(error.InvalidTaskFact, root.rollover(child.task, .outcome_unknown, next));
    next.local_files = .read;
    try root.rollover(child.task, .outcome_unknown, next);
    var later = next;
    later.task = .generate();
    later.generation = 3;
    later.local_files = .write;
    try std.testing.expectError(error.InvalidTaskFact, root.rollover(next.task, .succeeded, later));
}

test "v0.4 task gateway storage failure rolls back identity binding first input and root reservation" {
    const Failure = struct {
        fn write(_: *anyopaque, event: @import("ai/session_lifecycle.zig").Event) !void {
            if (event.kind == .child_launch) return error.DiskFull;
        }
    };
    var main: Fake = .{};
    var child: Fake = .{};
    var service = Runtime.Service.init(a);
    defer service.deinit();
    const parent = try service.attach(.{ .session = 11 }, main.backend());
    const fence = try service.store.create(parent.agent.id);
    _ = try service.submit(fence, .generate(), .{ .content = "parent" }, null);
    try started(&main);
    var sentinel: u8 = 0;
    service.store.persist = .{ .context = &sentinel, .write = Failure.write };
    var factory: Factory = .{ .service = &service, .fake = &child };
    const env: gateway.Environment = .{ .service = &service, .authority = parent.context.?.authority(), .live = .{ .owner = parent.agent.owner, .members = .{}, .inventory = &.{11} }, .handles = &.{}, .factory = .{ .context = &factory, .install = Factory.install } };
    const before = service.store.budget.count;
    try std.testing.expectError(error.DiskFull, invoke(env, create));
    try std.testing.expectEqual(@as(usize, 1), service.store.records.items.len);
    try std.testing.expectEqual(@as(usize, 1), service.store.agents.items.len);
    try std.testing.expectEqual(@as(usize, 1), parent.task_root.?.count);
    try std.testing.expectEqual(before, service.store.budget.count);
    service.store.persist = null;
    factory.fail = true;
    try std.testing.expectError(error.ChildStartupFailed, invoke(env, create));
    try std.testing.expect(service.store.records.items[1].binding == null);
    try std.testing.expectEqual(budget.Status.failed, parent.task_root.?.facts[1].status);
}

test "v0.4 task atomic child launch replays input and counters but never revives execution" {
    const Life = @import("ai/session_lifecycle.zig");
    const Journal = @import("ai/session_journal.zig").Journal;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var journal = try Journal.open(a, std.testing.io, tmp.dir, "sessions.jsonl");
    defer journal.deinit();
    var store = Life.Store.init(a);
    defer store.deinit();
    try journal.bind(&store);
    const parent = try store.attach(.{ .session = 11 });
    const fence = try store.create(parent.id);
    const task = id.TaskId.generate();
    var parent_fact: budget.Fact = .{ .root = task, .task = task, .conversation = fence.conversation, .agent = parent.id, .generation = 1 };
    try Life.Store.persistTask(&store, parent_fact);
    var child_fact: budget.Fact = .{ .root = task, .task = .generate(), .parent = task, .conversation = .{}, .agent = .{}, .generation = 1, .sequence = 2, .request_key = "atomic", .read_only = true, .local_files = .read, .targets = &.{.{ .session_id = @fromBackingInt(11), .generation = 2 }} };
    const child = try store.launchChild(fence, .{ .request_key = "atomic", .name = "child" }, null, null, .{ .owner = parent.owner, .members = .{}, .inventory = &.{11} }, child_fact.targets.?, .generate(), "must not auto run", &child_fact);
    parent_fact.sequence = 3;
    parent_fact.counters.requests = 2;
    parent_fact.counters.pending_requests = 1;
    parent_fact.counters.calls = 1;
    try Life.Store.persistTask(&store, parent_fact);
    try std.testing.expect(std.mem.indexOf(u8, journal.bytes.items, "\"kind\":\"child_launch\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, journal.bytes.items, "\"kind\":\"child_create\"") == null);
    var restored = Life.Store.init(a);
    defer restored.deinit();
    try journal.bind(&restored);
    const recovered = restored.find(child.id).?;
    try std.testing.expect(recovered.needs_recovery and recovered.inbox.entries.items.len == 1);
    try std.testing.expectEqualStrings("must not auto run", recovered.inbox.entries.items[0].payload.messages[0].content);
    try std.testing.expectEqual(@as(usize, 2), restored.task_facts.items.len);
    try std.testing.expect(restored.task_facts.items[1].fact.read_only);
    try std.testing.expectEqual(.read, restored.task_facts.items[1].fact.local_files);
    try std.testing.expectEqual(@as(u64, 2), restored.task_facts.items[1].fact.targets.?[0].generation);
    try restored.recoverTasks();
    for (restored.task_facts.items) |saved| {
        try std.testing.expectEqual(budget.Status.interrupted, saved.fact.status);
        try std.testing.expectEqual(@as(u32, 2), saved.fact.counters.requests);
        try std.testing.expectEqual(@as(u32, 1), saved.fact.counters.calls);
        try std.testing.expect(!saved.fact.counters.usage_complete);
    }
    var second = Life.Store.init(a);
    defer second.deinit();
    try journal.bind(&second);
    for (second.task_facts.items) |saved| try std.testing.expectEqual(budget.Status.interrupted, saved.fact.status);
    var forged = second.task_facts.items[1].fact;
    forged.sequence = 100;
    forged.read_only = false;
    try std.testing.expectError(error.InvalidSessionJournal, second.replay(.{ .kind = .task_fact, .conversation = forged.conversation, .revision = forged.sequence, .task_fact = forged }));
    forged.read_only = true;
    forged.local_files = .none;
    try std.testing.expectError(error.InvalidSessionJournal, second.replay(.{ .kind = .task_fact, .conversation = forged.conversation, .revision = forged.sequence, .task_fact = forged }));
    forged.local_files = .read;
    forged.targets = &.{.{ .session_id = @fromBackingInt(11), .generation = 3 }};
    try std.testing.expectError(error.InvalidSessionJournal, second.replay(.{ .kind = .task_fact, .conversation = forged.conversation, .revision = forged.sequence, .task_fact = forged }));
    var stale = parent_fact;
    stale.sequence = 99;
    stale.counters.requests = 0;
    try std.testing.expectError(error.InvalidSessionJournal, second.replay(.{ .kind = .task_fact, .conversation = stale.conversation, .revision = stale.sequence, .task_fact = stale }));
    const schema_offset = std.mem.indexOf(u8, journal.bytes.items, "\"schema\":3") orelse return error.MissingTaskSchema;
    journal.bytes.items[schema_offset + "\"schema\":".len] = '2';
    var downgraded = Life.Store.init(a);
    defer downgraded.deinit();
    try std.testing.expectError(error.InvalidSessionJournal, journal.bind(&downgraded));
}
test "v0.4 task atomic launch allocation failures do not publish child or input" {
    const Check = struct {
        fn run(alloc: std.mem.Allocator) !void {
            var store = @import("ai/session_lifecycle.zig").Store.init(alloc);
            defer store.deinit();
            const parent = try store.attach(.{ .session = 11 });
            const fence = try store.create(parent.id);
            const task = id.TaskId.generate();
            var child_fact: budget.Fact = .{ .root = task, .task = .generate(), .parent = task, .conversation = .{}, .agent = .{}, .generation = 1, .request_key = "allocation" };
            _ = store.launchChild(fence, .{ .request_key = "allocation", .name = "child" }, null, null, .{ .owner = parent.owner, .members = .{}, .inventory = &.{11} }, &.{}, .generate(), "owned initial input", &child_fact) catch |err| {
                try std.testing.expectEqual(@as(usize, 1), store.records.items.len);
                try std.testing.expectEqual(@as(usize, 1), store.agents.items.len);
                try std.testing.expectEqual(@as(usize, 0), store.budget.count);
                return err;
            };
        }
    };
    try std.testing.checkAllAllocationFailures(a, Check.run, .{});
}
test "v0.4 task gateway schemas reject irrelevant authority fields and bounded events are real receipts" {
    try @import("ai/plugin_tools.zig").validateDefinition(gateway.contribution.definition);
    for ([_][]const u8{ "{\"action\":\"reuse\",\"agent_id\":\"invalid\",\"model\":{\"provider_id\":\"p\",\"model_id\":\"m\"}}", "{\"action\":\"list\",\"session_refs\":[]}", "{\"action\":\"wait_events\",\"wait_ms\":10001}", "{\"action\":\"stop\",\"parent\":\"forged\"}" }) |json| {
        const value = try std.json.parseFromSlice(std.json.Value, a, json, .{});
        defer value.deinit();
        if (gateway.parse(a, value.value)) |parsed| {
            parsed.deinit();
            return error.UnexpectedGatewayAcceptance;
        } else |_| {}
    }
}

test "v0.4 task waiting for model capacity consumes no request or active time and cancellation needs no slot" {
    var fixtures: [5]Fake = @splat(.{});
    var service = Runtime.Service.init(a);
    defer service.deinit();
    var runners: [5]*Runtime.Runner = undefined;
    for (&fixtures, 0..) |*fixture, i| {
        if (i == 4) {
            fixture.timeout_ms = 100;
            fixture.retry_once = true;
        }
        runners[i] = try service.attach(.{ .session = 11 + i }, fixture.backend());
        fixture.runner = runners[i];
        const fence = try service.store.create(runners[i].agent.id);
        _ = try service.submit(fence, .generate(), .{ .content = "independent root" }, null);
        if (i < 4) try started(fixture);
    }
    const root = runners[4].task_root.?;
    const start = (Clock{}).now();
    while (true) {
        root.lock();
        const waiting = root.facts[0].status == .waiting_model;
        root.mutex.unlock();
        if (waiting) break;
        if ((Clock{}).now() - start > std.time.ns_per_s) return error.TestWorkerTimeout;
        (Clock{}).sleep(std.time.ns_per_ms);
    }
    (Clock{}).sleep(150 * std.time.ns_per_ms);
    try std.testing.expectEqual(@as(usize, 0), fixtures[4].calls.load(.acquire));
    root.lock();
    const used = root.counters.requests;
    root.mutex.unlock();
    try std.testing.expectEqual(@as(u32, 0), used);
    fixtures[4].release.store(true, .release);
    fixtures[3].release.store(true, .release);
    try started(&fixtures[4]);
    while (runners[4].agent.busy or runners[4].thread != null) {
        try service.poll();
        if ((Clock{}).now() - start > 3 * std.time.ns_per_s) return error.TestWorkerTimeout;
        (Clock{}).sleep(std.time.ns_per_ms);
    }
    try std.testing.expect(runners[4].failure == null);
    try std.testing.expectEqual(@as(u32, 2), root.counters.requests);
    try std.testing.expectEqual(@as(u32, 0), root.counters.pending_requests);
}
test "v0.4 task automatic compaction uses the same provider slot budget and usage ledger" {
    const Compact = struct {
        calls: usize = 0,
        fn prepare(raw: *anyopaque, _: std.mem.Allocator, _: std.Io, context: Runtime.Context) !Runtime.Prepared {
            var config = @import("ai/provider_config.zig").defaults(.openai_compat);
            config.context_window = 8192;
            return .{ .provider = .{ .ctx = raw, .chat = chat, .models = Fake.models }, .request = .{ .model = "fixture", .system = "rules", .messages = &.{} }, .scope = .{ .owner = context.owner, .members = .{} }, .limits = .{ .context_window = 8192 }, .compaction = config };
        }
        fn chat(raw: *anyopaque, _: P.ChatRequest, sink: *const fn (*anyopaque, P.Delta) void, output: *anyopaque) !P.ChatStats {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.calls += 1;
            sink(output, .{ .text = "Verified compact factual memory of the earlier supplied material and its constraints." });
            sink(output, .done);
            return .{ .input_tokens = 11, .output_tokens = 5, .usage_reported = true };
        }
    };
    var fixture: Compact = .{};
    var service = Runtime.Service.init(a);
    defer service.deinit();
    const runner = try service.attach(.{ .session = 11 }, .{ .context = &fixture, .prepare = Compact.prepare });
    const fence = try service.store.create(runner.agent.id);
    // Cross the context compaction threshold without a fixed output reservation.
    const long = try a.alloc(u8, 30000);
    defer a.free(long);
    @memset(long, 'm');
    try service.store.checkpoint(fence, 1, &.{ .{ .content = long }, .{ .role = .assistant, .content = "prior complete answer" } }, true);
    _ = try service.submit(fence, .generate(), .{ .content = "continue with current material" }, null);
    const start = (Clock{}).now();
    while (runner.thread != null or runner.agent.busy or runner.pending_notify) {
        try service.poll();
        if ((Clock{}).now() - start > 5 * std.time.ns_per_s) return error.TestWorkerTimeout;
        (Clock{}).sleep(std.time.ns_per_ms);
    }
    if (runner.failure) |err| return err;
    try std.testing.expect(fixture.calls >= 2);
    try std.testing.expectEqual(@as(u32, @intCast(fixture.calls)), runner.task_root.?.counters.requests);
    try std.testing.expectEqual(@as(u64, fixture.calls * 11), runner.task_root.?.counters.input_tokens);
    try std.testing.expect(runner.worker.?.manager.tool_run.?.compaction_provider == null);
}

test "v0.4 task gateway follows the current parent handoff fence without replacing its Task budget" {
    var main: Fake = .{};
    var child: Fake = .{};
    var service = Runtime.Service.init(a);
    defer service.deinit();
    const parent = try service.attach(.{ .session = 11 }, main.backend());
    const original = try service.store.create(parent.agent.id);
    _ = try service.submit(original, .generate(), .{ .content = "parent" }, null);
    try started(&main);
    const task = parent.context.?.task;
    const root = parent.task_root.?;
    const moved = try service.handoff(original, .{ .group = 7 });
    var authority = parent.context.?.authority();
    authority.binding = .{ .group = 7 };
    authority.binding_revision = moved.binding;
    var factory: Factory = .{ .service = &service, .fake = &child };
    const env: gateway.Environment = .{ .service = &service, .authority = authority, .live = .{ .owner = .{ .group = 7 }, .members = .{}, .inventory = &.{11} }, .handles = &.{}, .factory = .{ .context = &factory, .install = Factory.install } };
    var created = try invoke(env, create);
    defer created.deinit(a);
    try std.testing.expect(parent.context.?.task.eql(task) and parent.task_root.? == root);
    try std.testing.expect(service.runners.items[1].agent.parent_binding.?.eql(moved));
    var stale = env;
    stale.authority = parent.context.?.authority();
    try std.testing.expectError(error.ScopeChanged, invoke(stale, "{\"action\":\"list\"}"));
}

test "v0.4 task final fact failure after child unbind blocks parent End and retries without a Worker" {
    const Failure = struct {
        enabled: bool = true,
        fn write(raw: *anyopaque, event: @import("ai/session_lifecycle.zig").Event) !void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            if (self.enabled and event.kind == .task_fact and event.task_fact.?.parent != null and event.task_fact.?.status == .succeeded) return error.DiskFull;
        }
    };
    var main: Fake = .{};
    var child: Fake = .{};
    child.release.store(true, .release);
    var service = Runtime.Service.init(a);
    defer service.deinit();
    const parent = try service.attach(.{ .session = 11 }, main.backend());
    const fence = try service.store.create(parent.agent.id);
    _ = try service.submit(fence, .generate(), .{ .content = "parent" }, null);
    try started(&main);
    var failure: Failure = .{};
    service.store.persist = .{ .context = &failure, .write = Failure.write };
    var factory: Factory = .{ .service = &service, .fake = &child };
    const env: gateway.Environment = .{ .service = &service, .authority = parent.context.?.authority(), .live = .{ .owner = parent.agent.owner, .members = .{}, .inventory = &.{11} }, .handles = &.{}, .factory = .{ .context = &factory, .install = Factory.install } };
    var response = try invoke(env, create);
    defer response.deinit(a);
    const start = (Clock{}).now();
    var blocked = false;
    while (!blocked) {
        service.poll() catch |err| {
            if (err != error.DiskFull) return err;
            blocked = true;
        };
        if ((Clock{}).now() - start > 3 * std.time.ns_per_s) return error.TestWorkerTimeout;
        (Clock{}).sleep(std.time.ns_per_ms);
    }
    const child_record = service.store.records.items[1];
    try std.testing.expect(child_record.binding == null and child_record.task_pending);
    try std.testing.expect(service.runners.items[1].worker == null);
    try service.endConversation(fence, .generate());
    for (0..4) |_| {
        service.poll() catch |err| if (err != error.DiskFull) return err;
        (Clock{}).sleep(std.time.ns_per_ms);
    }
    try std.testing.expect(parent.agent.current != null);
    failure.enabled = false;
    while (parent.agent.current != null) {
        try service.poll();
        if ((Clock{}).now() - start > 3 * std.time.ns_per_s) return error.TestWorkerTimeout;
        (Clock{}).sleep(std.time.ns_per_ms);
    }
    try std.testing.expect(!child_record.task_pending and service.runners.items[1].record == null);
    try std.testing.expectEqual(@as(usize, 1), child.calls.load(.acquire));
}

test "v0.4 task unresolved reuse permits observation and disjoint new work without clearing original evidence" {
    var prior = fact(.generate());
    prior.status = .outcome_unknown;
    const old = id.SessionHandle{ .session_id = @fromBackingInt(11), .generation = 2 };
    const moved = id.SessionHandle{ .session_id = @fromBackingInt(12), .generation = 2 };
    prior.targets = &.{old};
    try std.testing.expectError(error.ChildNeedsVerification, gateway.checkReuse(prior, &.{old}, false));
    try gateway.checkReuse(prior, &.{old}, true);
    try gateway.checkReuse(prior, &.{moved}, false);
    try gateway.checkReuse(prior, &.{}, false);
    try std.testing.expectEqual(budget.Status.outcome_unknown, prior.status);
    const same_reconnected = id.SessionHandle{ .session_id = old.session_id, .generation = 3 };
    try std.testing.expectError(error.ChildNeedsVerification, gateway.checkReuse(prior, &.{same_reconnected}, false));
    prior.targets = null;
    prior.status = .interrupted;
    try std.testing.expectError(error.ChildNeedsVerification, gateway.checkReuse(prior, &.{moved}, false));
    try gateway.checkReuse(prior, &.{moved}, true);
    var owned = try budget.Owned.init(a, prior);
    defer owned.deinit();
    try std.testing.expectEqual(budget.Status.interrupted, owned.fact.status);
    const parsed = try std.json.parseFromSlice(std.json.Value, a, "{\"action\":\"reuse\",\"request_key\":\"inspect\",\"agent_id\":\"01010101010101010101010101010101\",\"text\":\"inspect original outcome\",\"session_refs\":[],\"purpose\":\"verify\"}", .{});
    defer parsed.deinit();
    const request = try gateway.parse(a, parsed.value);
    defer request.deinit();
    try std.testing.expect(request.value.purpose == .verify);
}

test "v0.4 task readonly verification launches a new child task while original unknown evidence remains" {
    var main: Fake = .{};
    var child: Fake = .{ .expect_read_only = true };
    child.release.store(true, .release);
    var service = Runtime.Service.init(a);
    defer service.deinit();
    const parent = try service.attach(.{ .session = 11 }, main.backend());
    const fence = try service.store.create(parent.agent.id);
    _ = try service.submit(fence, .generate(), .{ .content = "verify prior unknown" }, null);
    try started(&main);
    const record = try service.store.registerChild(fence, .{ .name = "uncertain", .request_key = "original", .reusable = true }, null);
    const target: id.SessionHandle = .{ .session_id = @fromBackingInt(11), .generation = 2 };
    const root = parent.task_root.?;
    try root.add(.{ .root = parent.context.?.root_task, .parent = parent.context.?.task, .task = .generate(), .agent = record.child.?.info.agent, .conversation = record.id, .generation = 1, .status = .outcome_unknown, .targets = &.{target}, .request_key = "original", .summary = "original remote effect remains unknown" });
    var factory: Factory = .{ .service = &service, .fake = &child };
    const env: gateway.Environment = .{ .service = &service, .authority = parent.context.?.authority(), .live = .{ .owner = parent.agent.owner, .members = .{}, .inventory = &.{11} }, .handles = &.{target}, .factory = .{ .context = &factory, .install = Factory.install } };
    const reference = try @import("ai/host_queries.zig").sessionRef(a, env.authority, target);
    defer a.free(reference);
    const work = try std.fmt.allocPrint(a, "{{\"action\":\"reuse\",\"request_key\":\"work\",\"agent_id\":\"{s}\",\"text\":\"never replay\",\"session_refs\":[\"{s}\"]}}", .{ std.fmt.bytesToHex(record.child.?.info.agent.bytes, .lower), reference });
    defer a.free(work);
    try std.testing.expectError(error.ChildNeedsVerification, invoke(env, work));
    const verify = try std.fmt.allocPrint(a, "{{\"action\":\"reuse\",\"purpose\":\"verify\",\"request_key\":\"verify\",\"agent_id\":\"{s}\",\"text\":\"only observe current state\",\"session_refs\":[\"{s}\"]}}", .{ std.fmt.bytesToHex(record.child.?.info.agent.bytes, .lower), reference });
    defer a.free(verify);
    var response = try invoke(env, verify);
    defer response.deinit(a);
    try started(&child);
    const start = (Clock{}).now();
    while (root.childrenRunning(parent.context.?.task)) {
        try service.poll();
        if ((Clock{}).now() - start > 3 * std.time.ns_per_s) return error.TestWorkerTimeout;
        (Clock{}).sleep(std.time.ns_per_ms);
    }
    try std.testing.expectEqual(budget.Status.outcome_unknown, root.facts[1].status);
    try std.testing.expectEqualStrings("original remote effect remains unknown", root.facts[1].summary);
    try std.testing.expect(root.facts[2].read_only and root.facts[2].targets.?[0].eql(target));
    try std.testing.expect(!root.facts[1].task.eql(root.facts[2].task));
    try std.testing.expectEqual(budget.Status.succeeded, root.facts[2].status);
    try std.testing.expectError(error.ChildNeedsVerification, invoke(env, work));
}
