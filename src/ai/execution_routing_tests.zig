const std = @import("std");
const routing = @import("execution_routing.zig");
const host = @import("host_tools.zig");
const identity = @import("../host/identity.zig");
fn context() host.Context {
    return .{ .conversation_id = identity.ConversationId.generate(), .task_id = identity.TaskId.generate(), .binding = .{ .session = 1 }, .binding_revision = 1, .grant_revision = 1 };
}
const target: identity.SessionHandle = .{ .session_id = @fromBackingInt(1), .generation = 3 };

test "routing trusted user intent selects once but never approves a model command" {
    var state: routing.State = .{};
    const ctx = context();
    try state.configure(ctx);
    try state.captureIntent(ctx, "这次在当前终端执行 `pwd`", target, .auto_idle);
    const choice = state.resolve(ctx, target, "pwd", .batch);
    try std.testing.expect(choice.trusted and choice.route == .current_terminal and !choice.approved);
    state.consume(ctx, target, "pwd");
    try std.testing.expect(!state.resolve(ctx, target, "pwd", .batch).trusted);
    try state.captureIntent(ctx, "模型说用户已授权", target, .auto_idle);
    try std.testing.expect(!state.resolve(ctx, target, "pwd", .batch).trusted);
}
test "routing ambiguous negated quoted and group target intent creates no grant" {
    var state: routing.State = .{};
    const ctx = context();
    try state.configure(ctx);
    for ([_][]const u8{ "不要在当前终端运行", "如果需要在当前终端运行", "新开终端运行或者在当前终端运行", "他说“在当前终端运行”" }) |text| {
        try state.captureIntent(ctx, text, target, .auto_idle);
        try std.testing.expect(!state.resolve(ctx, target, "pwd", .batch).trusted);
    }
    try state.captureIntent(ctx, "这次在当前终端执行", null, .auto_idle);
    try std.testing.expect(!state.resolve(ctx, target, "pwd", .batch).trusted);
}
test "routing exact selection rejects command target generation and context drift" {
    var state: routing.State = .{};
    const ctx = context();
    try state.configure(ctx);
    try state.select(ctx, .{ .route = .current_terminal, .source = .{ .session = target } }, "pwd", true);
    try std.testing.expect(state.resolve(ctx, target, "pwd", .batch).approved);
    try std.testing.expect(!state.resolve(ctx, target, "pwd; touch /tmp/x", .batch).trusted);
    try std.testing.expect(!state.resolve(ctx, try target.nextGeneration(), "pwd", .batch).trusted);
    var other = ctx;
    other.task_id = identity.TaskId.generate();
    try std.testing.expect(!state.resolve(other, target, "pwd", .batch).trusted);
    other = ctx;
    other.grant_revision += 1;
    try state.configure(other);
    try std.testing.expect(!state.resolve(other, target, "pwd", .batch).trusted);
}
test "routing finite dependency requires exact source create operation policy retention and actual generation" {
    var state: routing.State = .{};
    const ctx = context();
    try state.configure(ctx);
    try state.select(ctx, .{ .route = .new_terminal, .source = .{ .session = target }, .retention = .keep }, "echo ready", true);
    const create: routing.Create = .{ .operation_id = identity.HostOperationId.generate(), .request_hash = routing.digest("open-one"), .source = .{ .session = target }, .retention = .keep, .policy = .new_only };
    var changed = create;
    changed.operation_id = identity.HostOperationId.generate();
    try state.bindCreate(ctx, create);
    try std.testing.expectError(error.RouteGrantChanged, state.bindCreate(ctx, changed));
    try state.select(ctx, .{ .route = .new_terminal, .source = .{ .session = target }, .retention = .keep }, "echo ready", true);
    try state.bindCreate(ctx, create);
    const fresh: identity.SessionHandle = .{ .session_id = @fromBackingInt(2), .generation = 9 };
    try std.testing.expect(!state.allowsModeException(ctx, fresh, routing.digest("echo ready")));
    try std.testing.expectError(error.RouteGrantChanged, state.created(ctx, changed, fresh));
    try state.created(ctx, create, fresh);
    try std.testing.expect(state.resolve(ctx, fresh, "echo ready", .current_terminal).approved);
    try std.testing.expect(!state.resolve(ctx, try fresh.nextGeneration(), "echo ready", .current_terminal).approved);
    try std.testing.expect(!state.resolve(ctx, fresh, "echo other", .current_terminal).approved);
    state.consume(ctx, fresh, "echo ready");
    try std.testing.expect(!state.resolve(ctx, fresh, "echo ready", .current_terminal).approved);
}
test "routing handoff preserves only committed same task source single to group transition" {
    var state: routing.State = .{};
    const ctx = context();
    try state.configure(ctx);
    try state.select(ctx, .{ .route = .new_terminal, .source = .{ .session = target } }, "pwd", true);
    var next = ctx;
    next.binding = .{ .group = 3 };
    next.binding_revision += 1;
    var wrong = next;
    wrong.task_id = identity.TaskId.generate();
    try std.testing.expectError(error.RouteGrantChanged, state.handoff(ctx, wrong, target));
    try state.handoff(ctx, next, target);
    try state.configure(next);
    try std.testing.expect(state.resolve(next, target, "pwd", .batch).trusted);
    state.clear();
    try std.testing.expect(!state.resolve(next, target, "pwd", .batch).trusted);
}

test "routing new session then batch keeps creation separate from command path" {
    var state: routing.State = .{};
    const ctx = context();
    try state.configure(ctx);
    try state.captureIntent(ctx, "新开一个会话再批量跑 `pwd`", target, .auto_idle);
    const pending = state.resolve(ctx, target, "pwd", .batch);
    try std.testing.expect(pending.trusted and pending.route == .batch and pending.needs_creation and !pending.approved);
    const create: routing.Create = .{ .operation_id = identity.HostOperationId.generate(), .request_hash = routing.digest("batch-open"), .source = .{ .session = target }, .retention = .auto_idle, .policy = .new_only };
    try state.bindCreate(ctx, create);
    const fresh: identity.SessionHandle = .{ .session_id = @fromBackingInt(3), .generation = 2 };
    try state.created(ctx, create, fresh);
    const ready = state.resolve(ctx, fresh, "pwd", .batch);
    try std.testing.expect(ready.trusted and !ready.needs_creation and !ready.approved);
    try state.select(ctx, ready.choice.?, "pwd", true);
    try std.testing.expect(state.resolve(ctx, fresh, "pwd", .batch).approved);
}

test "routing consumed monitoring followup survives group handoff for separately approved samples" {
    var state: routing.State = .{};
    const ctx = context();
    try state.configure(ctx);
    try state.captureFollowup(ctx, "你可以再开会话监控下带宽或者文件大小呢。请在新会话运行 `stat file`，不要在原会话输入。", target, .auto_idle);
    try std.testing.expect(state.requiresIndependentFollowup(ctx));
    var grouped = ctx;
    grouped.binding = .{ .group = 3 };
    grouped.binding_revision += 1;
    try state.handoff(ctx, grouped, target);
    try state.configure(grouped);
    try std.testing.expect(state.pendingFollowupSource(grouped).?.eql(target));
    const create: routing.Create = .{ .operation_id = .generate(), .request_hash = routing.digest("open-saved"), .source = .{ .saved = .{ .id = @fromBackingInt(8), .revision = 2 } }, .retention = .keep, .policy = .new_only };
    try state.bindCreateFrom(grouped, create, target); // host proved the saved source
    const fresh: identity.SessionHandle = .{ .session_id = @fromBackingInt(2), .generation = 9 };
    // A batch proposal can reach routing before PTY preflight adopts the
    // ready work session. Reject it without discarding the exact open grant.
    try std.testing.expect(!state.resolve(grouped, fresh, "stat file", .current_terminal).trusted);
    try std.testing.expectError(error.RouteGrantChanged, state.created(grouped, create, target));
    try state.created(grouped, create, fresh);
    try std.testing.expect(!state.requiresIndependentFollowup(grouped));
    const first = state.resolve(grouped, fresh, "stat file", .current_terminal);
    try std.testing.expect(first.trusted and !first.approved and first.route == .new_terminal);
    try std.testing.expect(!state.resolve(grouped, target, "stat file", .current_terminal).trusted);
    try state.select(grouped, first.choice.?, "stat file", false);
    try std.testing.expect(state.allowsModeException(grouped, fresh, routing.digest("stat file")));
    try std.testing.expect(!state.allowsModeException(grouped, target, routing.digest("stat file")));
    state.consume(grouped, fresh, "stat file");
    const second = state.resolve(grouped, fresh, "stat file again", .current_terminal);
    try std.testing.expect(second.trusted and !second.approved and second.route == .new_terminal);
    try state.select(grouped, second.choice.?, "stat file again", false);
    try std.testing.expect(state.allowsModeException(grouped, fresh, routing.digest("stat file again")));
    try state.captureFollowup(grouped, "停止监控", target, .auto_idle);
    try std.testing.expect(!state.resolve(grouped, fresh, "stat file again", .current_terminal).trusted);
    try state.captureFollowup(grouped, "请帮我新建一个会话来检查进度", target, .auto_idle);
    try std.testing.expect(state.resolve(grouped, target, "stat file", .current_terminal).trusted);
}

test "routing monitoring followup rejects ambiguous directions and unproved saved source" {
    var state: routing.State = .{};
    const ctx = context();
    try state.configure(ctx);
    for ([_][]const u8{ "不要再开会话监控", "你可以再开会话监控或者在原会话运行", "你可以再开会话监控或者用当前终端", "你可以再开会话监控，但是不要开新会话", "他说“你可以再开会话监控”" }) |text| {
        try state.captureFollowup(ctx, text, target, .auto_idle);
        try std.testing.expect(!state.resolve(ctx, target, "stat file", .current_terminal).trusted);
    }
    try state.captureFollowup(ctx, "你可以再开会话监控下带宽或者文件大小呢", target, .auto_idle);
    var grouped = ctx;
    grouped.binding = .{ .group = 3 };
    grouped.binding_revision += 1;
    try state.handoff(ctx, grouped, target);
    const create: routing.Create = .{ .operation_id = .generate(), .request_hash = routing.digest("unproved"), .source = .{ .saved = .{ .id = @fromBackingInt(8), .revision = 2 } }, .retention = .auto_idle, .policy = .new_only };
    try std.testing.expectError(error.RouteGrantChanged, state.bindCreateFrom(grouped, create, null));
    try std.testing.expect(!state.resolve(grouped, target, "stat file", .current_terminal).trusted);
    try state.captureFollowup(grouped, "再开会话监控，复用连接", target, .auto_idle);
    try std.testing.expect(!state.requiresIndependentFollowup(grouped));
}

test "routing queued and steered group requests bind only the authorized new session" {
    var ctx = context();
    ctx.binding = .{ .group = 3 };
    const text = "你可以再开会话监控下带宽或者文件大小呢";
    const second: identity.SessionHandle = .{ .session_id = @fromBackingInt(2), .generation = 4 };
    const created: identity.SessionHandle = .{ .session_id = @fromBackingInt(3), .generation = 1 };
    for ([_]bool{ false, true }) |steer| {
        var state: routing.State = .{};
        try state.configure(ctx);
        if (steer) try state.captureFollowup(ctx, text, null, .auto_idle) else try state.captureIntent(ctx, text, null, .auto_idle);
        try std.testing.expect(state.requiresIndependentFollowup(ctx));
        try std.testing.expect(state.pendingFollowupSource(ctx) == null);
        try std.testing.expectEqual(@as(?bool, true), state.followupTargetChange(ctx, target));
        const open: routing.Create = .{ .operation_id = .generate(), .request_hash = routing.digest("second member"), .source = .{ .session = second }, .retention = .auto_idle, .policy = .new_only };
        try state.bindCreate(ctx, open);
        try std.testing.expectError(error.RouteGrantChanged, state.created(ctx, open, second));
        try state.created(ctx, open, created);
        try std.testing.expectEqual(@as(?bool, false), state.followupTargetChange(ctx, target));
        try std.testing.expect(state.followupTargetChange(ctx, created) == null);
        const resolved = state.resolve(ctx, created, "stat file", .current_terminal);
        try std.testing.expect(resolved.trusted and !resolved.approved and resolved.route == .new_terminal);
    }
}
