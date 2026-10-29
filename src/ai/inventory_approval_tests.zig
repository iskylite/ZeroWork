const std = @import("std");
const approval = @import("inventory_approval.zig");
const inventory = @import("inventory_grants.zig");
const host = @import("host_tools.zig");
const identity = @import("../host/identity.zig");
fn context() host.Context {
    return .{ .conversation_id = .{ .bytes = @splat(1) }, .task_id = .{ .bytes = @splat(2) }, .binding = .{ .session = 4 }, .binding_revision = 1, .grant_revision = 2 };
}
fn selection() !inventory.Selection {
    return inventory.captureSelection(std.testing.allocator, &.{.{ .session_id = @fromBackingInt(4), .generation = 1 }}, &.{});
}
const Call = struct {
    parsed: std.json.Parsed(std.json.Value),
    invocation: host.Invocation,
    fn init(ctx: host.Context, wire: []const u8) !Call {
        const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, wire, .{});
        errdefer parsed.deinit();
        var raw: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(wire, &raw, .{});
        return .{ .parsed = parsed, .invocation = .{ .context = ctx, .authority = .conversation_context, .operation_id = 1, .turn_id = 1, .call_id = "query", .tool_id = "host.list_sessions", .arguments = parsed.value, .arguments_json = wire, .arguments_hash = raw, .canonical_arguments_hash = try @import("canonical_arguments.zig").digest(std.testing.allocator, parsed.value) } };
    }
    fn deinit(self: *Call) void {
        self.parsed.deinit();
    }
};
test "inventory on-demand owns pending snapshot and rejects stale or forged decisions" {
    var broker: approval.Broker = .{};
    const ctx = context();
    const frozen = try selection();
    try broker.configure(ctx, 1);
    var call = try Call.init(ctx, "{\"scope\":\"workspace\"}");
    defer call.deinit();
    try std.testing.expect(broker.snapshot() == null);
    const ticket = try broker.begin(call.invocation, frozen, 1, std.testing.allocator);
    const snapshot = broker.snapshot().?;
    try std.testing.expect(snapshot.ticket.eql(ticket));
    try std.testing.expect(snapshot.target.text().len > 0 and snapshot.detail.text().len > 0);
    var stale = ticket;
    stale.sequence += 1;
    try std.testing.expectError(error.StaleInventoryDecision, broker.decide(stale, .allow_once));
    try broker.decide(ticket, .deny);
    try std.testing.expectError(error.InventoryApprovalDenied, broker.wait(ticket, null));
    try std.testing.expect(broker.snapshot() == null);
    call.invocation.call_id = "new-model-call";
    call.invocation.operation_id += 1;
    try std.testing.expectError(error.InventoryApprovalDenied, broker.begin(call.invocation, frozen, 1, std.testing.allocator));
    var reordered = try Call.init(ctx, "{ \"scope\" : \"workspace\" }");
    defer reordered.deinit();
    try std.testing.expectError(error.InventoryApprovalDenied, broker.begin(reordered.invocation, frozen, 1, std.testing.allocator));
    var switched = ctx;
    switched.conversation_id.bytes[0] += 1;
    try broker.configure(switched, 1);
    try broker.configure(ctx, 1);
    try std.testing.expectError(error.InventoryApprovalDenied, broker.begin(call.invocation, frozen, 1, std.testing.allocator));
    var next = ctx;
    next.task_id.bytes[0] += 1;
    try broker.configure(next, 1);
    call.invocation.context = next;
    const next_ticket = try broker.begin(call.invocation, frozen, 1, std.testing.allocator);
    broker.stop();
    try std.testing.expectError(error.CancelledBeforeDispatch, broker.poll(next_ticket));
    try std.testing.expectError(error.StaleInventoryDecision, broker.decide(next_ticket, .allow_conversation));
}
test "inventory allow once is exact invocation claimed once and does not expand other authorities" {
    var broker: approval.Broker = .{};
    const ctx = context();
    const frozen = try selection();
    try broker.configure(ctx, 1);
    var call = try Call.init(ctx, "{\"scope\":\"workspace\"}");
    defer call.deinit();
    const ticket = try broker.begin(call.invocation, frozen, 1, std.testing.allocator);
    try broker.decide(ticket, .allow_once);
    try broker.wait(ticket, null);
    var forged_args = try Call.init(ctx, "{\"scope\":\"workspace\",\"limit\":2}");
    defer forged_args.deinit();
    var forged = call.invocation;
    forged.arguments = forged_args.invocation.arguments;
    try std.testing.expect(broker.grantForInvocation(forged, frozen, 1) == null);
    var changed = call.invocation;
    changed.call_id = "different";
    try std.testing.expect(broker.grantForInvocation(changed, frozen, 1) == null);
    var drift = frozen;
    drift.session_count += 1;
    try std.testing.expect(broker.grantForInvocation(call.invocation, drift, 1) == null);
    const grant = broker.grantForInvocation(call.invocation, frozen, 1).?;
    try std.testing.expect(grant.validForInvocation(call.invocation, frozen, 99));
    try std.testing.expect(!grant.validForInvocation(changed, frozen, 99));
    try std.testing.expect(broker.grantForInvocation(call.invocation, frozen, 1) == null);
    try std.testing.expect(!@hasField(inventory.Grant, "session_targets") and !@hasField(inventory.Grant, "selected_sources"));
    broker.finish(ticket);
    try std.testing.expect(broker.grantForInvocation(call.invocation, frozen, 1) == null);
    try std.testing.expectError(error.InventoryAlreadyConsumed, broker.begin(call.invocation, frozen, 1, std.testing.allocator));
    // A new invocation with the same arguments needs its own decision.
    call.invocation.operation_id = 2;
    call.invocation.call_id = "second";
    const second = try broker.begin(call.invocation, frozen, 1, std.testing.allocator);
    try std.testing.expect(broker.snapshot() != null);
    try std.testing.expect(broker.grantForInvocation(call.invocation, frozen, 1) == null);
    try broker.decide(second, .deny);
    try std.testing.expectError(error.InventoryApprovalDenied, broker.wait(second, null));
    call.invocation.operation_id = 3;
    call.invocation.call_id = "third";
    try std.testing.expectError(error.InventoryApprovalDenied, broker.begin(call.invocation, frozen, 1, std.testing.allocator));
}
test "inventory continuous is per conversation spans tasks and new sessions and revokes locally" {
    var broker: approval.Broker = .{};
    const ctx = context();
    const frozen = try selection();
    try broker.configure(ctx, 7);
    var call = try Call.init(ctx, "{\"scope\":\"workspace\"}");
    defer call.deinit();
    const ticket = try broker.begin(call.invocation, frozen, 7, std.testing.allocator);
    try broker.decide(ticket, .allow_conversation);
    try broker.wait(ticket, null);
    broker.finish(ticket);
    broker.stop();
    var next = ctx;
    next.task_id.bytes[0] += 1;
    try broker.configure(next, 7);
    call.invocation.context = next;
    const expanded = try inventory.captureSelection(std.testing.allocator, &.{ .{ .session_id = @fromBackingInt(4), .generation = 1 }, .{ .session_id = @fromBackingInt(8), .generation = 2 } }, &.{});
    try std.testing.expect(broker.grantForInvocation(call.invocation, expanded, 7) != null);
    const automatic = try broker.begin(call.invocation, expanded, 7, std.testing.allocator);
    try std.testing.expect(broker.snapshot() == null);
    try broker.wait(automatic, null);
    broker.finish(automatic);
    var other = next;
    other.conversation_id.bytes[0] += 1;
    try broker.configure(other, 7);
    call.invocation.context = other;
    try std.testing.expect(!broker.continuousAllowed());
    try std.testing.expect(broker.conversationAllowed(next.conversation_id, next.binding, next.binding_revision, 7));
    try std.testing.expect(!broker.conversationAllowed(other.conversation_id, other.binding, other.binding_revision, 7));
    try std.testing.expect(broker.grantForInvocation(call.invocation, expanded, 7) == null);
    const other_ticket = try broker.begin(call.invocation, expanded, 7, std.testing.allocator);
    try broker.decide(other_ticket, .allow_conversation);
    broker.finish(other_ticket);
    broker.revokeConversation(other.conversation_id);
    try std.testing.expect(broker.conversationAllowed(next.conversation_id, next.binding, next.binding_revision, 7));
    try std.testing.expect(!broker.conversationAllowed(other.conversation_id, other.binding, other.binding_revision, 7));
    try broker.configure(next, 7);
    call.invocation.context = next;
    try std.testing.expect(broker.continuousAllowed());
    broker.revoke();
    try std.testing.expect(broker.grantForInvocation(call.invocation, expanded, 7) == null);
    // Revocation does not stop the current provider round.
    const fresh = try broker.begin(call.invocation, expanded, 7, std.testing.allocator);
    try broker.decide(fresh, .allow_conversation);
    broker.finish(fresh);
    try broker.configure(next, 8);
    try std.testing.expect(!broker.continuousAllowed());
    const new_policy = try broker.begin(call.invocation, expanded, 8, std.testing.allocator);
    try broker.decide(new_policy, .allow_conversation);
    broker.finish(new_policy);
    next.binding_revision += 1;
    try broker.configure(next, 8);
    try std.testing.expect(!broker.continuousAllowed());
    call.invocation.context = next;
    const latest = try broker.begin(call.invocation, expanded, 8, std.testing.allocator);
    try broker.decide(latest, .allow_conversation);
    broker.finish(latest);
    try std.testing.expect(!broker.conversationAllowed(next.conversation_id, next.binding, next.binding_revision, 9));
    try std.testing.expect(!broker.conversationAllowed(next.conversation_id, next.binding, next.binding_revision, 8));
    broker.clearConversation(next.conversation_id);
    try std.testing.expect(!broker.continuousAllowed());
}
test "inventory begin rejects default scope guessed refs changed hashes and nonmetadata tools" {
    var broker: approval.Broker = .{};
    const ctx = context();
    const frozen = try selection();
    try broker.configure(ctx, 1);
    var default = try Call.init(ctx, "{}");
    defer default.deinit();
    try std.testing.expectError(error.InvalidInventoryApproval, broker.begin(default.invocation, frozen, 1, std.testing.allocator));
    var call = try Call.init(ctx, "{\"scope\":\"workspace\"}");
    defer call.deinit();
    call.invocation.canonical_arguments_hash[0] += 1;
    try std.testing.expectError(error.InvalidInventoryApproval, broker.begin(call.invocation, frozen, 1, std.testing.allocator));
    call.invocation.canonical_arguments_hash[0] -= 1;
    call.invocation.tool_id = "host.get_session";
    try std.testing.expectError(error.InvalidInventoryApproval, broker.begin(call.invocation, frozen, 1, std.testing.allocator));
    call.invocation.tool_id = "read_terminal";
    try std.testing.expectError(error.InvalidInventoryApproval, broker.begin(call.invocation, frozen, 1, std.testing.allocator));
}
