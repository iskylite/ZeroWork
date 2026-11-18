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

// Pull in the V0.7 §3.7 role-template contract tests through this suite.
comptime {
    _ = @import("config/ai_role_templates.zig");
}

// V0.7 阶段3 批S1/S2/S3/S5 契约测试通过本套件收集。
comptime {
    _ = @import("ai/swarm_mode.zig");
    _ = @import("ai/swarm_board.zig");
    _ = @import("ai/swarm_orchestration.zig");
    _ = @import("ai/swarm_prompts.zig");
}

test "v0.7 board 引擎：postBoard 入流、ask 计数按 seq 键控与终态清零" {
    const budget_mod = @import("ai/task_budget.zig");
    var root = budget_mod.Root.init(a);
    defer root.deinit();
    const parent = id.TaskId.generate();
    try root.add(.{ .root = parent, .task = parent, .conversation = id.ConversationId.generate(), .agent = id.AgentId.generate(), .generation = 1, .request_key = "root" });
    const child = delegated(parent, id.TaskId.generate());
    try root.add(child);
    // add 按值接收 Fact：分配的 seq 存在 root.facts，调用方副本保持 0。
    const child_seq = root.facts[1].seq;
    // seq 无回收（§2.1）：next_seq 推进到 16 后新成员拿 #17，ask 计数不受 ≤16 槽位限制。
    root.next_seq = 16;
    const late = delegated(parent, id.TaskId.generate());
    try root.add(late);
    const late_seq = root.facts[2].seq;
    try std.testing.expectEqual(@as(u32, 17), late_seq);
    // 与 main.dispatchBoardPost 相同的按 seq 键控计数：ask×3 不触发自动回复，第 4 次触发。
    const Ask = struct {
        fn once(board_root: *budget_mod.Root, seq: u32) !?[]const u8 {
            board_root.lock();
            defer board_root.mutex.unlock();
            if (seq == 0) return error.ScopeChanged;
            const entry = try board_root.board_ask_counts.getOrPut(board_root.allocator, seq);
            if (!entry.found_existing) entry.value_ptr.* = 0;
            entry.value_ptr.* += 1;
            return if (entry.value_ptr.* >= 4) "按当前最佳判断继续" else null;
        }
    };
    for (0..3) |_| try std.testing.expect((try Ask.once(&root, child_seq)) == null);
    try std.testing.expectEqualStrings("按当前最佳判断继续", (try Ask.once(&root, child_seq)).?);
    // seq 17 的成员同样计数到第 4 次（此前 seq>16 直接 ScopeChanged 拒绝发帖）。
    for (0..3) |_| try std.testing.expect((try Ask.once(&root, late_seq)) == null);
    try std.testing.expectEqualStrings("按当前最佳判断继续", (try Ask.once(&root, late_seq)).?);
    try std.testing.expectEqual(@as(usize, 2), root.board_ask_counts.count());
    // postBoard 入流；父目标帖与 @all 帖可投递（deliverableText 语义）。
    try root.postBoard(.{ .origin = child.seq, .to = .parent, .category = .ask, .text = "请求确认方案", .ts = 1 });
    try root.postBoard(.{ .origin = child.seq, .to = .all, .category = .note, .text = "广播: " ++ "xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx", .ts = 2 });
    try root.postBoard(.{ .origin = child.seq, .to = .{ .member = 2 }, .category = .answer, .text = "给成员 2 的结果", .ts = 3 });
    try std.testing.expectEqual(@as(usize, 3), root.board_posts.items.len);
    // 终态按 seq 清除对应成员的计数（不再有 ≤16 的槽位界）。
    try root.state(child.task, .succeeded, "done");
    try std.testing.expectEqual(@as(usize, 1), root.board_ask_counts.count());
    try root.state(late.task, .succeeded, "done");
    try std.testing.expectEqual(@as(usize, 0), root.board_ask_counts.count());
}

test "v0.7 depends_on 门控与 challenge 工具契约" {
    const gateway = @import("ai/child_gateway.zig");
    const orchestration = @import("ai/swarm_orchestration.zig");
    const a2 = std.testing.allocator;
    // schema 拒绝非 create 的 depends_on 与未配对的 challenge。
    const bad_reuse = try std.json.parseFromSlice(std.json.Value, a2, "{\"action\":\"reuse\",\"agent_id\":\"01010101010101010101010101010101\",\"text\":\"x\",\"session_refs\":[],\"depends_on\":[]}", .{});
    defer bad_reuse.deinit();
    try std.testing.expectError(error.InvalidArguments, gateway.parse(a2, bad_reuse.value));
    const bad_challenge = try std.json.parseFromSlice(std.json.Value, a2, "{\"action\":\"create\",\"text\":\"x\",\"session_refs\":[],\"purpose\":\"challenge\"}", .{});
    defer bad_challenge.deinit();
    try std.testing.expectError(error.InvalidArguments, gateway.parse(a2, bad_challenge.value));
    const ok_challenge = try std.json.parseFromSlice(std.json.Value, a2, "{\"action\":\"create\",\"text\":\"复审\",\"session_refs\":[],\"purpose\":\"challenge\",\"challenge_target\":\"@1\"}", .{});
    defer ok_challenge.deinit();
    const parsed = try gateway.parse(a2, ok_challenge.value);
    defer parsed.deinit();
    try std.testing.expect(parsed.value.purpose == .challenge);
    try std.testing.expectEqualStrings("@1", parsed.value.challenge_target.?);
    // 依赖引用解析与环检测。
    try std.testing.expectError(error.DependencyCycle, orchestration.containsSelf(&.{1, 2}, 2));
}

test "v0.7 §12.3 swarm 配置键解析、范围与往返 + 停滞升级阈值读配置" {
    const C = @import("config/config.zig");
    const prompts = @import("ai/swarm_prompts.zig");
    // 默认值。
    const defaults = try C.Config.parse("[ai]\n");
    try std.testing.expectEqual(C.SwarmModeDefault.auto, defaults.ai.swarm_mode_default);
    try std.testing.expectEqual(@as(u8, 3), defaults.ai.swarm_stall_minutes);
    try std.testing.expectEqual(@as(u8, 2), defaults.ai.swarm_stall_parent_minutes);
    try std.testing.expectEqual(@as(u8, 5), defaults.ai.boost_max_rounds);
    // 配置值与往返。
    const configured = try C.Config.parse("[ai]\nswarm_mode_default = \"swarm\"\nswarm_stall_minutes = 5\nswarm_stall_parent_minutes = 4\nboost_max_rounds = 8\n");
    try std.testing.expectEqual(C.SwarmModeDefault.swarm, configured.ai.swarm_mode_default);
    try std.testing.expectEqual(@as(u8, 5), configured.ai.swarm_stall_minutes);
    try std.testing.expectEqual(@as(u8, 4), configured.ai.swarm_stall_parent_minutes);
    try std.testing.expectEqual(@as(u8, 8), configured.ai.boost_max_rounds);
    var buffer: [4096]u8 = undefined;
    const reloaded = try C.Config.parse(try configured.format(&buffer));
    try std.testing.expectEqual(C.SwarmModeDefault.swarm, reloaded.ai.swarm_mode_default);
    try std.testing.expectEqual(@as(u8, 8), reloaded.ai.boost_max_rounds);
    // 越限错误定位。
    try std.testing.expectError(error.OutOfRange, C.Config.parse("[ai]\nswarm_stall_minutes = 0\n"));
    try std.testing.expectError(error.OutOfRange, C.Config.parse("[ai]\nswarm_stall_minutes = 31\n"));
    try std.testing.expectError(error.OutOfRange, C.Config.parse("[ai]\nswarm_stall_parent_minutes = 0\n"));
    try std.testing.expectError(error.OutOfRange, C.Config.parse("[ai]\nboost_max_rounds = 9\n"));
    try std.testing.expectError(error.InvalidValue, C.Config.parse("[ai]\nswarm_mode_default = \"turbo\"\n"));
    // 停滞阈值构造自配置（§12.2 读配置语义）。
    const stall: prompts.StallConfig = .{ .idle_minutes = reloaded.ai.swarm_stall_minutes, .parent_minutes = reloaded.ai.swarm_stall_parent_minutes };
    try std.testing.expectEqual(@as(u8, 5), stall.idle_minutes);
    try std.testing.expectEqual(@as(u8, 4), stall.parent_minutes);
}

test "v0.7 §3.7 child_role_templates 配置持久化往返（Stored JSON）" {
    const C = @import("config/config.zig");
    const a2 = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(a2);
    defer arena.deinit();
    const aa = arena.allocator();
    // 两个模板（含槽位 effort）编码进 JSON 串。
    const list = [_]C.ai_role_templates.Stored{
        .{ .name = "攻坚", .efforts = .{ null, .high, null, .medium, .low } },
        .{ .name = "巡检", .models = .{ null, null, null, "group/deepseek-v4.1-flash-1017", null } },
    };
    const encoded = try C.ai_role_templates.Stored.encode(aa, &list);
    const key = try std.fmt.allocPrint(aa, "[ai]\nchild_role_templates = {s}\n", .{try std.json.Stringify.valueAlloc(aa, encoded, .{})});
    const parsed = try C.Config.parseWithAllocator(aa, key);
    try std.testing.expectEqual(@as(usize, 2), parsed.ai.child_role_templates.len);
    try std.testing.expectEqualStrings("攻坚", parsed.ai.child_role_templates[0].name);
    try std.testing.expectEqual(@import("ai/provider.zig").Effort.high, parsed.ai.child_role_templates[0].efforts[1].?);
    try std.testing.expectEqualStrings("group/deepseek-v4.1-flash-1017", parsed.ai.child_role_templates[1].models[3].?);
    // 格式化往返：写出再读回保持。
    var buffer: [4096]u8 = undefined;
    const formatted = try parsed.format(&buffer);
    const reloaded = try C.Config.parseWithAllocator(aa, formatted);
    try std.testing.expectEqual(@as(usize, 2), reloaded.ai.child_role_templates.len);
    try std.testing.expectEqualStrings("巡检", reloaded.ai.child_role_templates[1].name);
    // 重名拒绝（配置层校验重名，由 setRoleTemplates 与 UI 层保证）。
    const dup = [_]C.ai_role_templates.Stored{ .{ .name = "x" }, .{ .name = "x" } };
    const dup_json = try std.json.Stringify.valueAlloc(aa, try C.ai_role_templates.Stored.encode(aa, &dup), .{});
    const dup_source = try std.fmt.allocPrint(aa, "[ai]\nchild_role_templates = {s}\n", .{dup_json});
    const parsed_dup = try C.Config.parseWithAllocator(aa, dup_source);
    // 配置解析不查重名（结构合法）；重名拒绝发生在 controller 写通道。
    try std.testing.expectEqual(@as(usize, 2), parsed_dup.ai.child_role_templates.len);
}

test "v0.7 §3.7 模板管理 controller 写通道（新建/复制/删除/校验）" {
    const controller_mod = @import("config/settings_controller.zig");
    const C = @import("config/config.zig");
    const a2 = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var target = try @import("config/runtime_config.zig").RuntimeConfig.loadOrDefault(std.testing.io, tmp.dir, a2, "config.toml");
    defer target.deinit();
    var controller = try controller_mod.Controller.init(a2, target.value);
    defer controller.deinit();
    // 新建：空列表 → 一个"新模板"。
    try controller.setRoleTemplates(&.{.{ .name = "新模板" }});
    try std.testing.expectEqual(@as(usize, 1), controller.model.value.ai.child_role_templates.len);
    // 复制语义在 UI 层（副本名由按钮处理器生成）；controller 接受任意合法列表。
    try controller.setRoleTemplates(&.{ .{ .name = "攻坚", .efforts = .{ null, .high, null, .medium, .low } }, .{ .name = "新模板" } });
    try std.testing.expectEqual(@as(usize, 2), controller.model.value.ai.child_role_templates.len);
    try std.testing.expectEqual(@import("ai/provider.zig").Effort.high, controller.model.value.ai.child_role_templates[0].efforts[1].?);
    // 删除：写回剩余列表。
    try controller.setRoleTemplates(&.{.{ .name = "新模板" }});
    try std.testing.expectEqualStrings("新模板", controller.model.value.ai.child_role_templates[0].name);
    // 非法列表拒绝（空名）。
    try std.testing.expectError(error.InvalidRoleTemplate, controller.setRoleTemplates(&.{.{ .name = " " }}));
    // 保存持久化到 [ai] child_role_templates 并可读回。
    try controller.save(std.testing.io, tmp.dir, &target);
    const raw = try tmp.dir.readFileAlloc(std.testing.io, "config.toml", a2, .unlimited);
    defer a2.free(raw);
    try std.testing.expect(std.mem.indexOf(u8, raw, "child_role_templates") != null);
    var loaded = try @import("config/runtime_config.zig").RuntimeConfig.loadOrDefault(std.testing.io, tmp.dir, a2, "config.toml");
    defer loaded.deinit();
    try std.testing.expectEqual(@as(usize, 1), loaded.value.ai.child_role_templates.len);
    try std.testing.expectEqualStrings("新模板", loaded.value.ai.child_role_templates[0].name);
    _ = C;
}
