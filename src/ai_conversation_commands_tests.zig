//! UI command transactions against the real authority and executor service.
const std = @import("std");
const runtime = @import("ai/session_runtime.zig");
const commands = @import("ai/conversation_commands.zig");
const identity = @import("host/identity.zig");
const a = std.testing.allocator;
const Fixture = struct {
    released: bool = true,
    fn prepare(_: *anyopaque, _: std.mem.Allocator, _: std.Io, _: runtime.Context) !runtime.Prepared {
        return error.UnexpectedModelRequest;
    }
    fn release(raw: *anyopaque, _: runtime.Context) bool {
        return @as(*Fixture, @ptrCast(@alignCast(raw))).released;
    }
    fn backend(self: *Fixture) runtime.Backend {
        return .{ .context = self, .prepare = prepare, .local_released = release };
    }
};
fn completed(service: *runtime.Service, runner: *runtime.Runner) !runtime.input.Fence {
    const ticket = try service.store.create(runner.agent.id);
    try service.store.checkpoint(ticket, 1, &.{ .{ .content = "original question" }, .{ .role = .assistant, .content = "stable answer" } }, true);
    return ticket;
}
test "conversation UI command refuses bound restore and keeps the current target intact" {
    var fixture: Fixture = .{};
    var service = runtime.Service.init(a);
    defer service.deinit();
    const first = try service.attach(.{ .session = 1 }, fixture.backend());
    const second = try service.attach(.{ .session = 2 }, fixture.backend());
    const source = try completed(&service, first);
    const target = try completed(&service, second);
    try std.testing.expectError(error.BindingConflict, commands.Command.prepare(&service, .restore, source.conversation, second.agent.id));
    try std.testing.expect(second.agent.current.?.eql(target.conversation));
}
test "conversation UI command restore race is rejected before stopping the target" {
    var fixture: Fixture = .{};
    var service = runtime.Service.init(a);
    defer service.deinit();
    const first = try service.attach(.{ .session = 1 }, fixture.backend());
    const second = try service.attach(.{ .session = 2 }, fixture.backend());
    const third = try service.attach(.{ .session = 3 }, fixture.backend());
    const source = try completed(&service, first);
    try service.endConversation(source, identity.HostOperationId.generate());
    const target = try completed(&service, second);
    var command = try commands.Command.prepare(&service, .restore, source.conversation, second.agent.id);
    defer command.deinit();
    try std.testing.expect(command.needsConfirmation());
    const record = service.store.find(source.conversation).?;
    _ = try service.resumeConversation(source.conversation, third.agent.id, record.revision);
    try std.testing.expectError(error.BindingChanged, command.advance(&service));
    try std.testing.expect(second.agent.current.?.eql(target.conversation) and service.store.find(target.conversation).?.ending == null);
}
test "conversation UI command pinned copy survives new output and source deletion without queue or draft" {
    var fixture: Fixture = .{};
    var service = runtime.Service.init(a);
    defer service.deinit();
    const first = try service.attach(.{ .session = 1 }, fixture.backend());
    const second = try service.attach(.{ .session = 2 }, fixture.backend());
    const source = try completed(&service, first);
    _ = try service.store.setDraft(source, 1, "not copied");
    _ = try service.store.find(source.conversation).?.inbox.admit(source, identity.SubmissionId.generate(), .{ .content = "never replay" }, .queue);
    var command = try commands.Command.prepare(&service, .copy, source.conversation, second.agent.id);
    defer command.deinit();
    try std.testing.expect(!command.needsConfirmation());
    try service.store.checkpoint(source, 2, &.{.{ .content = "later output must not enter the pinned copy" }}, true);
    try service.endConversation(source, identity.HostOperationId.generate());
    try service.store.remove(source.conversation);
    const result = (try command.advance(&service)).?;
    const copy = service.store.find(result.conversation.?).?;
    try std.testing.expect(copy.binding == null and copy.parent.?.eql(source.conversation));
    try std.testing.expectEqualStrings("stable answer", copy.history.messages[1].content);
    try std.testing.expect(copy.draft == null and copy.inbox.entries.items.len == 0 and second.agent.current == null);
}
test "conversation UI command keeps binary binding while End waits then restores without model execution" {
    var fixture: Fixture = .{};
    var service = runtime.Service.init(a);
    defer service.deinit();
    const first = try service.attach(.{ .session = 1 }, fixture.backend());
    const second = try service.attach(.{ .session = 2 }, fixture.backend());
    const source = try completed(&service, first);
    try service.endConversation(source, identity.HostOperationId.generate());
    const target = try completed(&service, second);
    second.context = .{ .fence = target, .task = identity.TaskId.generate(), .turn = 2, .owner = second.agent.owner };
    second.record = service.store.find(target.conversation);
    second.has_tools = true;
    fixture.released = false;
    var command = try commands.Command.prepare(&service, .restore, source.conversation, second.agent.id);
    defer command.deinit();
    try std.testing.expect((try command.advance(&service)) == null);
    try std.testing.expect(service.store.find(target.conversation).?.binding != null);
    try std.testing.expect(!service.store.find(target.conversation).?.inbox.admission);
    fixture.released = true;
    try service.poll();
    const result = (try command.advance(&service)).?;
    try std.testing.expect(result.used and result.conversation.?.eql(source.conversation));
    try std.testing.expect(second.thread == null and second.context == null);
    try std.testing.expect(service.store.find(target.conversation).?.binding == null);
    try std.testing.expect(service.store.find(source.conversation).?.revision > source.binding);
}
test "conversation UI command cancellation drops the restore step while the accepted End still settles" {
    var fixture: Fixture = .{};
    var service = runtime.Service.init(a);
    defer service.deinit();
    const first = try service.attach(.{ .session = 1 }, fixture.backend());
    const second = try service.attach(.{ .session = 2 }, fixture.backend());
    const source = try completed(&service, first);
    try service.endConversation(source, identity.HostOperationId.generate());
    const target = try completed(&service, second);
    second.context = .{ .fence = target, .task = identity.TaskId.generate(), .turn = 2, .owner = second.agent.owner };
    second.record = service.store.find(target.conversation);
    second.has_tools = true;
    fixture.released = false;
    var command = try commands.Command.prepare(&service, .restore, source.conversation, second.agent.id);
    try std.testing.expect((try command.advance(&service)) == null);
    command.deinit();
    fixture.released = true;
    try service.poll();
    try std.testing.expect(second.agent.current == null and service.store.find(source.conversation).?.binding == null);
}
test "conversation UI command changed target generation cannot redirect the original operation" {
    var fixture: Fixture = .{};
    var service = runtime.Service.init(a);
    defer service.deinit();
    const runner = try service.attach(.{ .session = 1 }, fixture.backend());
    const ticket = try completed(&service, runner);
    var command = try commands.Command.prepare(&service, .new, null, runner.agent.id);
    defer command.deinit();
    _ = try service.store.environmentChanged(runner.agent.id);
    try std.testing.expectError(error.BindingChanged, command.advance(&service));
    try std.testing.expect(runner.agent.current.?.eql(ticket.conversation));
}
test "conversation UI setting transaction validates follow-up values and preserves current choice on invalid input" {
    var config: @import("config/config.zig").Config = .{};
    const values = @import("config/settings_values.zig");
    try values.writeConfig(&config, "ai", "follow_up_mode", .{ .text = "queue" });
    try std.testing.expectEqualStrings("queue", values.read(config, "ai", "follow_up_mode").?.text);
    try std.testing.expectError(error.InvalidValue, values.writeConfig(&config, "ai", "follow_up_mode", .{ .text = "unknown" }));
    try std.testing.expectEqual(@import("config/config.zig").FollowUpMode.queue, config.ai.follow_up_mode);
}

test "conversation UI history writer queues input and delays unbind until publication rights release" {
    var fixture: Fixture = .{};
    var service = runtime.Service.init(a);
    defer service.deinit();
    const runner = try service.attach(.{ .session = 1 }, fixture.backend());
    const ticket = try completed(&service, runner);
    runner.controller_busy = true;
    const receipt = try service.submit(ticket, identity.SubmissionId.generate(), .{ .content = "wait for compaction" }, .steer);
    try std.testing.expect(receipt.delivery == .queued and receipt.route == .queue and runner.thread == null);
    var command = try commands.Command.prepare(&service, .end, ticket.conversation, runner.agent.id);
    defer command.deinit();
    try std.testing.expect((try command.advance(&service)) == null);
    try std.testing.expect(service.store.find(ticket.conversation).?.binding != null);
    runner.controller_busy = false;
    try service.poll();
    _ = (try command.advance(&service)).?;
    try std.testing.expect(runner.agent.current == null);
    try std.testing.expect(service.store.find(ticket.conversation).?.inbox.receipt(receipt.id).?.archived);
}

test "conversation UI turn fork freezes its chosen checkpoint and waits for explicit confirmation" {
    var fixture: Fixture = .{};
    var service = runtime.Service.init(a);
    defer service.deinit();
    const first = try service.attach(.{ .session = 1 }, fixture.backend());
    const source = try completed(&service, first);
    const prefix = [_]@import("ai/provider.zig").Message{ .{ .content = "original question" }, .{ .role = .assistant, .content = "stable answer" } };
    try service.store.checkpoint(source, 2, &.{ .{ .content = "original question" }, .{ .role = .assistant, .content = "stable answer" }, .{ .content = "later question" }, .{ .role = .assistant, .content = "later answer" } }, true);
    var command = try commands.Command.prepare(&service, .copy_use, source.conversation, first.agent.id);
    defer command.deinit();
    try command.selectCheckpoint(&service.store, 1, &prefix);
    try std.testing.expect(command.needsConfirmation());
    try std.testing.expect(service.store.find(source.conversation).?.ending == null);
    try std.testing.expect(first.agent.current.?.eql(source.conversation));
    const result = (try command.advance(&service)).?;
    const copied = service.store.find(result.conversation.?).?;
    try std.testing.expectEqual(@as(u64, 1), copied.fork_turn.?);
    try std.testing.expectEqual(@as(usize, 2), copied.history.messages.len);
    try std.testing.expectEqualStrings("stable answer", copied.history.messages[1].content);
}
