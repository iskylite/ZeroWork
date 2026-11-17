//! V0.7 批次A验收：子任务通道降阻契约。
//! 覆盖 §2.1 seq 编号（唯一、复用保留、销毁不回收、@seq/label/agent_id 三向解析）、
//! §3.2 内容派生幂等、§3.3 游标默认与自动投递、§3.4 面板就绪行、
//! §3.5 预算错误载荷、journal 兼容读取（旧 fact 补号迁移）。
const std = @import("std");
const a = std.testing.allocator;
const id = @import("host/identity.zig");
const budget = @import("ai/task_budget.zig");
const lifecycle = @import("ai/session_lifecycle.zig");
const Runtime = @import("ai/session_runtime.zig");
const gateway = @import("ai/child_gateway.zig");
const Journal = @import("ai/session_journal.zig").Journal;
const scope = @import("ai/tool_scope.zig");
const P = @import("ai/provider.zig");
const Clock = @import("ai/retry.zig").Clock;

fn delegated(parent: id.TaskId, task: id.TaskId, request_key: []const u8, label: []const u8) budget.Fact {
    return .{
        .root = parent,
        .task = task,
        .parent = parent,
        .conversation = id.ConversationId.generate(),
        .agent = id.AgentId.generate(),
        .generation = 1,
        .request_key = request_key,
        .label = label,
    };
}

test "v0.7 seq 分配唯一、销毁不回收、rollover 保留原编号" {
    var root = budget.Root.init(a);
    defer root.deinit();
    const parent = id.TaskId.generate();
    const parent_fact: budget.Fact = .{ .root = parent, .task = parent, .conversation = id.ConversationId.generate(), .agent = id.AgentId.generate(), .generation = 1 };
    try root.add(parent_fact);
    const first = delegated(parent, id.TaskId.generate(), "one", "巡检");
    try root.add(first);
    const second = delegated(parent, id.TaskId.generate(), "two", "修复");
    try root.add(second);
    try std.testing.expectEqual(@as(u32, 1), root.facts[1].seq);
    try std.testing.expectEqual(@as(u32, 2), root.facts[2].seq);
    // 终态销毁后新任务继续编号，不回收。
    try root.state(first.task, .succeeded, "done");
    const third = delegated(parent, id.TaskId.generate(), "three", "验证");
    try root.add(third);
    try std.testing.expectEqual(@as(u32, 3), root.facts[3].seq);
    // rollover（复用成员的下一任务）保留原编号 2（同 agent、同 conversation）。
    var rolled = second;
    rolled.task = id.TaskId.generate();
    rolled.request_key = "two-next";
    rolled.label = "修复";
    try root.rollover(second.task, .succeeded, rolled);
    try std.testing.expectEqual(@as(u32, 3), root.facts[3].seq);
    try std.testing.expectEqual(@as(u32, 2), root.facts[4].seq);
}

test "v0.7 @seq、裸 label、agent_id 三向引用解析" {
    var root = budget.Root.init(a);
    defer root.deinit();
    const parent = id.TaskId.generate();
    const parent_fact: budget.Fact = .{ .root = parent, .task = parent, .conversation = id.ConversationId.generate(), .agent = id.AgentId.generate(), .generation = 1 };
    try root.add(parent_fact);
    const one = delegated(parent, id.TaskId.generate(), "one", "巡检");
    try root.add(one);
    const two = delegated(parent, id.TaskId.generate(), "two", "修复");
    try root.add(two);
    // @seq 命中。
    const by_seq = try root.factForSeq(parent, 2);
    try std.testing.expect(by_seq.agent.eql(two.agent));
    // 裸 label 唯一命中。
    const by_label = try root.factsForLabel(parent, "巡检");
    try std.testing.expect(by_label.fact.agent.eql(one.agent));
    // 多个同名 label 拒绝（不按名字猜）。
    const duplicate = delegated(parent, id.TaskId.generate(), "dup", "巡检");
    try root.add(duplicate);
    try std.testing.expectError(error.LabelAmbiguous, root.factsForLabel(parent, "巡检"));
    // 未分配的 seq 与未知 label 报 TaskNotFound。
    try std.testing.expectError(error.TaskNotFound, root.factForSeq(parent, 9));
    try std.testing.expectError(error.TaskNotFound, root.factsForLabel(parent, "不存在"));
}

const Fake = struct {
    calls: std.atomic.Value(usize) = .init(0),
    release: std.atomic.Value(bool) = .init(false),
    fn backend(self: *Fake) Runtime.Backend {
        return .{ .context = self, .prepare = prepare };
    }
    fn prepare(raw: *anyopaque, _: std.mem.Allocator, _: std.Io, context: Runtime.Context) !Runtime.Prepared {
        const self: *Fake = @ptrCast(@alignCast(raw));
        _ = self;
        return .{ .provider = .{ .ctx = raw, .chat = chat, .models = models }, .request = .{ .model = "fixture", .system = "", .messages = &.{}, .timeout_ms = 600000 }, .scope = .{ .owner = context.owner, .members = .{}, .inventory = &.{} } };
    }
    fn chat(raw: *anyopaque, request: P.ChatRequest, sink: *const fn (*anyopaque, P.Delta) void, output: *anyopaque) !P.ChatStats {
        const self: *Fake = @ptrCast(@alignCast(raw));
        _ = self.calls.fetchAdd(1, .acq_rel);
        while (!self.release.load(.acquire)) {
            if (request.cancel) |cancel| if (cancel.isCancelled()) return error.Cancelled;
            (Clock{}).sleep(std.time.ns_per_ms);
        }
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
    fn install(raw: *anyopaque, record: *lifecycle.Record, root: *budget.Root, task: budget.Fact, _: id.SubmissionId, _: []const u8) !*Runtime.Runner {
        const self: *@This() = @ptrCast(@alignCast(raw));
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

test "v0.7 create 省略 request_key/name 内容派生幂等命中" {
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
    // 无 request_key、无 name：宿主按 canonical(text+targets+父任务) 派生。
    const minimal = "{\"action\":\"create\",\"text\":\"检查日志材料\",\"session_refs\":[]}";
    var response = try invoke(env, minimal);
    defer response.deinit(a);
    try started(&child);
    var body = try std.json.parseFromSlice(std.json.Value, a, response.blocks[0].structured, .{});
    defer body.deinit();
    const task = body.value.object.get("task").?;
    try std.testing.expectEqual(@as(u32, 1), task.object.get("seq").?.integer);
    try std.testing.expect(task.object.get("label") != null);
    // 相同参数重试命中幂等去重（reused_receipt），不再创建第二个子任务。
    var repeated = try invoke(env, minimal);
    defer repeated.deinit(a);
    try std.testing.expect(std.mem.indexOf(u8, repeated.blocks[0].structured, "\"reused_receipt\":true") != null);
    try std.testing.expectEqual(@as(usize, 2), service.store.records.items.len);
    // 显式新键 + 不同内容创建第二个子任务（显式键语义不变）。
    var second_child = try invoke(env, "{\"action\":\"create\",\"request_key\":\"k1\",\"text\":\"另一个任务\",\"session_refs\":[]}");
    defer second_child.deinit(a);
    try std.testing.expectEqual(@as(usize, 3), service.store.records.items.len);
    // 同一显式键 + 不同内容报 ChildRequestConflict。
    try std.testing.expectError(error.ChildRequestConflict, invoke(env, "{\"action\":\"create\",\"request_key\":\"k1\",\"text\":\"内容不同\",\"session_refs\":[]}"));
    // 让 worker 完成并收尾，避免测试进程挂起。
    child.release.store(true, .release);
    const start = (Clock{}).now();
    while (parent.task_root.?.childrenRunning(parent.context.?.task)) {
        try service.poll();
        if ((Clock{}).now() - start > 3 * std.time.ns_per_s) return error.TestWorkerTimeout;
        (Clock{}).sleep(std.time.ns_per_ms);
    }
}

test "v0.7 面板就绪行：seq+label+agent_id+状态标签+用量" {
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
    var response = try invoke(env, "{\"action\":\"create\",\"name\":\"巡检华东\",\"text\":\"并行巡检\",\"session_refs\":[],\"reusable\":true}");
    defer response.deinit(a);
    try started(&child);
    child.release.store(true, .release);
    const start = (Clock{}).now();
    while (parent.task_root.?.childrenRunning(parent.context.?.task)) {
        try service.poll();
        if ((Clock{}).now() - start > 3 * std.time.ns_per_s) return error.TestWorkerTimeout;
        (Clock{}).sleep(std.time.ns_per_ms);
    }
    // list 返回 G3 面板就绪行结构。
    var listed = try invoke(env, "{\"action\":\"list\"}");
    defer listed.deinit(a);
    var body = try std.json.parseFromSlice(std.json.Value, a, listed.blocks[0].structured, .{});
    defer body.deinit();
    const children = body.value.object.get("children").?.array;
    try std.testing.expect(children.items.len == 1);
    const row = children.items[0].object;
    try std.testing.expectEqual(@as(i64, 1), row.get("seq").?.integer);
    try std.testing.expectEqualStrings("巡检华东", row.get("label").?.string);
    try std.testing.expect(row.get("agent_id") != null);
    try std.testing.expectEqualStrings("reuse_ready", row.get("status").?.string);
    const usage = row.get("usage").?.object;
    try std.testing.expect(usage.get("requests") != null and usage.get("tokens") != null);
    const flags = row.get("flags").?.object;
    try std.testing.expect(flags.get("reusable") != null and flags.get("purpose") != null);
}

test "v0.7 wait_events 省略 after_sequence 从已投递水位开始" {
    var root = budget.Root.init(a);
    defer root.deinit();
    const parent = id.TaskId.generate();
    const parent_fact: budget.Fact = .{ .root = parent, .task = parent, .conversation = id.ConversationId.generate(), .agent = id.AgentId.generate(), .generation = 1 };
    try root.add(parent_fact);
    const one = delegated(parent, id.TaskId.generate(), "one", "");
    try root.add(one);
    const two = delegated(parent, id.TaskId.generate(), "two", "");
    try root.add(two);
    // 初始水位 0：默认游标返回全部事件。
    try std.testing.expectEqual(@as(u64, 0), root.delivered_watermark);
    root.advanceDeliveredWatermark(root.facts[1].event_sequence);
    try std.testing.expectEqual(root.facts[1].event_sequence, root.delivered_watermark);
    // advance 只前进不后退。
    root.advanceDeliveredWatermark(1);
    try std.testing.expectEqual(root.facts[1].event_sequence, root.delivered_watermark);
}

test "v0.7 旧 journal 无 seq 的 delegated fact 重放按持久化顺序补号" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var journal = try Journal.open(a, std.testing.io, tmp.dir, "sessions.jsonl");
    defer journal.deinit();
    var store = lifecycle.Store.init(a);
    defer store.deinit();
    try journal.bind(&store);
    const live: scope.Scope = .{ .owner = .{ .session = 11 }, .members = .{}, .inventory = &.{11} };
    const parent_agent = try store.attach(live.owner);
    const ticket = try store.create(parent_agent.id);
    const record = try store.registerChild(ticket, .{ .request_key = "legacy", .name = "旧子任务" }, null);
    // 先持久化父任务 fact，再写一条无 seq/label 的 V0.4 形态 delegated fact。
    const parent_task = id.TaskId.generate();
    const parent_fact: budget.Fact = .{ .root = parent_task, .task = parent_task, .conversation = ticket.conversation, .agent = parent_agent.id, .generation = 1, .request_key = "legacy-parent", .sequence = 4 };
    try lifecycle.Store.persistTask(&store, parent_fact);
    const legacy: budget.Fact = .{ .root = parent_task, .task = id.TaskId.generate(), .parent = parent_task, .conversation = record.id, .agent = record.child.?.info.agent, .generation = 1, .request_key = "legacy", .sequence = 5 };
    try lifecycle.Store.persistTask(&store, legacy);
    // 重放后 seq 被迁移补号，validate 通过。
    var replayed = lifecycle.Store.init(a);
    defer replayed.deinit();
    try journal.bind(&replayed);
    const facts = replayed.task_facts.items;
    try std.testing.expect(facts.len == 2);
    try std.testing.expectEqual(@as(u32, 0), facts[0].fact.seq); // root fact carries no seq
    try std.testing.expectEqual(@as(u32, 1), facts[1].fact.seq); // delegated fact repaired to #1
    // 同一 task 的后续状态更新保持首次补的编号。
    var updated = legacy;
    updated.status = .succeeded;
    updated.sequence = 6;
    try lifecycle.Store.persistTask(&store, updated);
    var replayed_two = lifecycle.Store.init(a);
    defer replayed_two.deinit();
    try journal.bind(&replayed_two);
    try std.testing.expectEqual(@as(usize, 2), replayed_two.task_facts.items.len);
    try std.testing.expectEqual(@as(u32, 1), replayed_two.task_facts.items[1].fact.seq);
    try std.testing.expectEqual(budget.Status.succeeded, replayed_two.task_facts.items[1].fact.status);
}

test "v0.7 resumeAnswer 不再因未收齐子任务硬阻塞并返回未收齐清单" {
    var root = budget.Root.init(a);
    defer root.deinit();
    const parent = id.TaskId.generate();
    const parent_fact: budget.Fact = .{ .root = parent, .task = parent, .conversation = id.ConversationId.generate(), .agent = id.AgentId.generate(), .generation = 1 };
    try root.add(parent_fact);
    const running_child = delegated(parent, id.TaskId.generate(), "still", "等待审批");
    try root.add(running_child);
    // V0.4：子任务未收齐时 resumeAnswer 直接 ChildSettlementRequired。
    // V0.7 §3.3：继续执行，调用方用 outstandingChildren 披露。
    try root.state(parent, .failed, "answer recovery");
    try root.resumeAnswer(parent);
    const outstanding = try root.outstandingChildren(a, parent);
    defer a.free(outstanding);
    try std.testing.expect(outstanding.len == 1);
    try std.testing.expectEqualStrings("等待审批", outstanding[0].label);
    try std.testing.expectEqual(@as(u32, 1), outstanding[0].seq);
}

test "v0.7 Boost verification waits for settlement and survives journal replay" {
    var service = Runtime.Service.init(a);
    defer service.deinit();
    var root = budget.Root.init(a);
    defer root.deinit();
    const parent = try service.store.attach(.{ .session = 11 });
    const fence = try service.store.create(parent.id);
    const root_id = id.TaskId.generate();
    try root.add(.{ .root = root_id, .task = root_id, .conversation = fence.conversation, .agent = parent.id, .generation = 1 });
    try root.configureBoost(root_id, 5);
    const initial = try root.factForTask(root_id);
    const child = try service.store.registerChild(fence, .{ .name = "实现", .request_key = "implement" }, null);
    const child_task = id.TaskId.generate();
    try root.add(.{
        .root = root_id, .task = child_task, .parent = root_id, .conversation = child.id,
        .agent = child.child.?.info.agent, .generation = 1, .request_key = "implement",
        .boost_round = .{ .number = 1, .phase = .implementation },
    });
    const checks = [_]budget.VerificationItem{
        .{ .requirement = "检查输入", .passed = true, .detail = "用例通过" },
        .{ .requirement = "检查空值", .passed = false, .detail = "缺少回执" },
    };
    try std.testing.expectError(error.BoostChildrenPending, root.verifyBoost(root_id, &checks));
    try root.state(child_task, .succeeded, "实现已交付");
    try root.verifyBoost(root_id, &checks);
    try root.verifyBoost(root_id, &checks);
    try std.testing.expectError(error.BoostAlreadyVerified, root.verifyBoost(root_id, checks[0..1]));
    for ([_]budget.Fact{ initial, try root.factForTask(child_task), try root.factForTask(root_id) }) |fact| {
        try service.store.replay(.{ .kind = .task_fact, .conversation = fact.conversation, .revision = fact.sequence, .task_fact = fact });
    }
    const replayed = try @import("ai/child_projection.zig").boostView(a, &service, fence.conversation);
    defer a.free(replayed.rows);
    try std.testing.expectEqual(@as(usize, 1), replayed.rows.len);
    try std.testing.expectEqual(@as(u8, 1), replayed.rows[0].round.number);
    try std.testing.expect(replayed.parent.?.verification.?[0].passed);
    try std.testing.expect(!replayed.parent.?.verification.?[1].passed);
}
