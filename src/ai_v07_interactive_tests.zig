//! V0.7 批次B/C 验收：交互式降阻与预算可配置化契约。
//! 覆盖 §2.2.3 interactive_batch_fallback 提示词开关、§2.3 三预算配置
//! 解析/范围/越限错误、Root 上限按新值生效且 16 护栏不可突破、
//! Slots 动态容量公平性、occupied_policy schema 校验。
const std = @import("std");
const a = std.testing.allocator;
const cfg = @import("config/config.zig");
const budget = @import("ai/task_budget.zig");
const id = @import("host/identity.zig");
const host_execution = @import("ai/host_execution.zig");
const plugin_tools = @import("ai/plugin_tools.zig");

test "v0.7 interactive_batch_fallback 配置解析、默认开与严格关闭" {
    // 默认开启。
    const defaults = try cfg.Config.parse("[ai]\n");
    try std.testing.expect(defaults.ai.interactive_batch_fallback);
    // 显式关闭并往返持久化。
    const off = try cfg.Config.parse("[ai]\ninteractive_batch_fallback = false\n");
    try std.testing.expect(!off.ai.interactive_batch_fallback);
    var buffer: [4096]u8 = undefined;
    const encoded = try off.format(&buffer);
    const reloaded = try cfg.Config.parse(encoded);
    try std.testing.expect(!reloaded.ai.interactive_batch_fallback);
}

test "v0.7 三预算配置解析、范围校验与越限错误" {
    // 默认值保持 V0.4 行为。
    const defaults = try cfg.Config.parse("[ai]\n");
    try std.testing.expectEqual(@as(u8, 4), defaults.ai.child_max_active);
    try std.testing.expectEqual(@as(u8, 2), defaults.ai.child_request_concurrency);
    try std.testing.expectEqual(@as(u8, 4), defaults.ai.model_slots);
    // 配置值与往返。
    const configured = try cfg.Config.parse("[ai]\nchild_max_active = 8\nchild_request_concurrency = 4\nmodel_slots = 6\n");
    try std.testing.expectEqual(@as(u8, 8), configured.ai.child_max_active);
    try std.testing.expectEqual(@as(u8, 4), configured.ai.child_request_concurrency);
    try std.testing.expectEqual(@as(u8, 6), configured.ai.model_slots);
    var buffer: [4096]u8 = undefined;
    const reloaded = try cfg.Config.parse(try configured.format(&buffer));
    try std.testing.expectEqual(@as(u8, 8), reloaded.ai.child_max_active);
    // 越限错误定位：child_max_active 超过 16 护栏不可配置突破。
    try std.testing.expectError(error.OutOfRange, cfg.Config.parse("[ai]\nchild_max_active = 17\n"));
    try std.testing.expectError(error.OutOfRange, cfg.Config.parse("[ai]\nchild_max_active = 0\n"));
    try std.testing.expectError(error.OutOfRange, cfg.Config.parse("[ai]\nchild_request_concurrency = 9\n"));
    try std.testing.expectError(error.OutOfRange, cfg.Config.parse("[ai]\nmodel_slots = 1\n"));
    try std.testing.expectError(error.OutOfRange, cfg.Config.parse("[ai]\nmodel_slots = 9\n"));
}

fn delegated(parent: id.TaskId, task: id.TaskId) budget.Fact {
    return .{ .root = parent, .task = task, .parent = parent, .conversation = id.ConversationId.generate(), .agent = id.AgentId.generate(), .generation = 1, .request_key = "k" };
}

test "v0.7 Root 上限按新值生效且 16 护栏不可突破" {
    var root = budget.Root.init(a);
    defer root.deinit();
    const parent = id.TaskId.generate();
    try root.add(.{ .root = parent, .task = parent, .conversation = id.ConversationId.generate(), .agent = id.AgentId.generate(), .generation = 1, .request_key = "root" });
    root.child_limit = 2;
    try root.add(delegated(parent, id.TaskId.generate()));
    try root.add(delegated(parent, id.TaskId.generate()));
    // 第 3 个超出配置上限 2。
    try std.testing.expectError(error.ChildTaskLimit, root.add(delegated(parent, id.TaskId.generate())));
    // 终态一个后活跃计数下降，可再创建直到再次达到上限。
    try root.state(root.facts[1].task, .succeeded, "done");
    try root.add(delegated(parent, id.TaskId.generate()));
    try std.testing.expectError(error.ChildTaskLimit, root.add(delegated(parent, id.TaskId.generate())));
}

test "v0.7 Slots 动态容量与 per-root 并发配置" {
    var slots: budget.Slots = .{};
    // 默认 4 槽、2/根。
    const first = id.TaskId.generate();
    const other = id.TaskId.generate();
    const third = id.TaskId.generate();
    const p1 = try slots.enqueue(first);
    try std.testing.expect(slots.tryAcquire(p1));
    const p2 = try slots.enqueue(first);
    try std.testing.expect(slots.tryAcquire(p2));
    const p3 = try slots.enqueue(first);
    try std.testing.expect(!slots.tryAcquire(p3));
    // 配置 8 槽、3/根：第三个槽对本根可用。
    slots.configure(8, 3);
    try std.testing.expect(slots.tryAcquire(p3));
    const q1 = try slots.enqueue(other);
    const q2 = try slots.enqueue(other);
    const q3 = try slots.enqueue(other);
    try std.testing.expect(slots.tryAcquire(q1));
    try std.testing.expect(slots.tryAcquire(q2));
    try std.testing.expect(slots.tryAcquire(q3));
    // 8 槽已用 6：third 根的两个请求仍可进入（7、8 号槽），第 3 个被容量拒绝。
    const r1 = try slots.enqueue(third);
    const r2 = try slots.enqueue(third);
    const r3 = try slots.enqueue(third);
    try std.testing.expect(slots.tryAcquire(r1));
    try std.testing.expect(slots.tryAcquire(r2));
    try std.testing.expect(!slots.tryAcquire(r3));
    // 释放后容量恢复。
    slots.release(p3);
    try std.testing.expect(slots.tryAcquire(r3));
    slots.release(p1);
    slots.release(p2);
    slots.release(q1);
    slots.release(q2);
    slots.release(q3);
    slots.release(r1);
    slots.release(r2);
    slots.release(r3);
    for (slots.queue) |entry| try std.testing.expect(entry == null);
}

test "v0.7 run_in_terminal 工具描述与 occupied_policy schema 契约" {
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    for (host_execution.contributions) |contribution| {
        if (!std.mem.eql(u8, contribution.definition.id, "host.run_in_terminal")) continue;
        try plugin_tools.validateDefinition(contribution.definition);
        const schema = try std.json.parseFromSlice(std.json.Value, arena.allocator(), contribution.definition.schema, .{});
        defer schema.deinit();
        const policy = schema.value.object.get("properties").?.object.get("occupied_policy").?;
        try std.testing.expectEqual(@as(usize, 3), policy.object.get("enum").?.array.items.len);
        // 描述提到自动恢复与手动兜底并存（attach_shell 保留为兜底）。
        try std.testing.expect(std.mem.indexOf(u8, contribution.definition.description, "occupied_policy") != null);
        try std.testing.expect(std.mem.indexOf(u8, contribution.definition.description, "automatically") != null);
        try std.testing.expect(std.mem.indexOf(u8, contribution.definition.description, "host.attach_shell") != null);
    }
}
