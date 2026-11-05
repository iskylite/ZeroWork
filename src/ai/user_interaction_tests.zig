const std = @import("std");
const Q = @import("user_interaction.zig");
const host = @import("host_tools.zig");
const a = std.testing.allocator;
const context: host.Context = .{ .conversation_id = .{ .bytes = @splat(1) }, .task_id = .{ .bytes = @splat(2) }, .binding = .{ .session = 101 }, .binding_revision = 1, .grant_revision = 1 };
const json = "{\"question\":\"如何处理？\",\"options\":[{\"id\":\"reload\",\"label\":\"平滑重载\"},{\"id\":\"restart\",\"label\":\"重启\"}]}";
fn invocation(value: std.json.Value, wire: []const u8) !host.Invocation {
    var hash: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(wire, &hash, .{});
    return .{ .context = context, .authority = .conversation_context, .operation_id = 3, .turn_id = 4, .call_id = "question", .tool_id = Q.contribution.definition.id, .arguments = value, .arguments_json = wire, .arguments_hash = hash, .canonical_arguments_hash = try @import("canonical_arguments.zig").digest(a, value) };
}
test "user interaction requires exact ticket, explicit answer and consumes once" {
    var broker: Q.Broker = .{};
    broker.configure(context);
    defer broker.stop();
    const parsed = try std.json.parseFromSlice(std.json.Value, a, json, .{});
    defer parsed.deinit();
    const request = try invocation(parsed.value, json);
    const ticket = try broker.begin(request, a);
    for (0..3) |_| {
        try std.testing.expect(broker.snapshot() != null);
        try std.testing.expect((try broker.poll(ticket)) == null);
    }
    try std.testing.expectError(error.UserQuestionBusy, broker.begin(request, a));
    try std.testing.expectError(error.InvalidUserAnswer, broker.answer(ticket, null, " \n "));
    try std.testing.expectError(error.InvalidUserAnswer, broker.answer(ticket, "foreign-option", ""));
    var stale = ticket;
    stale.sequence += 1;
    try std.testing.expectError(error.StaleUserQuestion, broker.answer(stale, "reload", ""));
    try broker.answer(ticket, "reload", "ignored custom data");
    try std.testing.expect(broker.snapshot() == null);
    try std.testing.expectError(error.StaleUserQuestion, broker.answer(ticket, "restart", ""));
    const answer = try broker.wait(ticket, null);
    try std.testing.expectEqualStrings("reload", answer.option_id.?.text());
    try std.testing.expectEqualStrings("平滑重载", answer.text.text());
    try std.testing.expectError(error.CancelledBeforeDispatch, broker.poll(ticket));
    var result = try Q.result(request, answer, a);
    defer result.deinit(a);
    try result.validate(context, request.operation_id);
}
test "user interaction cancel and scope replacement never manufacture an answer" {
    var broker: Q.Broker = .{};
    broker.configure(context);
    const parsed = try std.json.parseFromSlice(std.json.Value, a, json, .{});
    defer parsed.deinit();
    const request = try invocation(parsed.value, json);
    const old = try broker.begin(request, a);
    var next = context;
    next.binding_revision += 1;
    broker.configure(next);
    try std.testing.expectError(error.StaleUserQuestion, broker.answer(old, "reload", ""));
    try std.testing.expectError(error.ScopeChanged, broker.begin(request, a));
    broker.configure(context);
    const current = try broker.begin(request, a);
    try std.testing.expect(current.sequence > old.sequence);
    var cancel: @import("provider.zig").CancelToken = .{};
    cancel.cancel();
    try std.testing.expectError(error.CancelledBeforeDispatch, broker.wait(current, &cancel));
    try std.testing.expect(broker.snapshot() == null);
    _ = try broker.begin(request, a);
    broker.stop();
    try std.testing.expect(broker.snapshot() == null);
    try std.testing.expectError(error.ScopeChanged, broker.begin(request, a));
}
test "user interaction validates bounded unique options and custom answers" {
    var broker: Q.Broker = .{};
    broker.configure(context);
    defer broker.stop();
    const invalid = "{\"question\":\"选择\",\"options\":[{\"id\":\"a\",\"label\":\"A\"},{\"id\":\"a\",\"label\":\"B\"}]}";
    const parsed = try std.json.parseFromSlice(std.json.Value, a, invalid, .{});
    defer parsed.deinit();
    try std.testing.expectError(error.InvalidUserQuestion, broker.begin(try invocation(parsed.value, invalid), a));
    const freeform = "{\"question\":\"说明你的约束\"}";
    const valid = try std.json.parseFromSlice(std.json.Value, a, freeform, .{});
    defer valid.deinit();
    const ticket = try broker.begin(try invocation(valid.value, freeform), a);
    try broker.answer(ticket, null, "  保留现有连接  ");
    const answer = try broker.wait(ticket, null);
    try std.testing.expectEqualStrings("保留现有连接", answer.text.text());
    try std.testing.expect(answer.option_id == null);
    var tampered = try invocation(valid.value, freeform);
    tampered.arguments_hash = @splat(0);
    try std.testing.expectError(error.InvalidUserQuestion, broker.begin(tampered, a));
}
