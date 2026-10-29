//! Metadata-only workspace discovery. Only the trusted UI callback may issue a
//! grant; model arguments, tool results and user-looking strings have no route
//! into this controller. No terminal, connection or lifecycle service is held.
const std = @import("std");
const identity = @import("../host/identity.zig");
const host = @import("host_tools.zig");

pub const lifetime_ms: i64 = 15 * 60 * 1000;
pub const Scope = enum { workspace_open_metadata };
pub const Group = struct { id: u64, membership_revision: u64, members: []const identity.SessionHandle };

/// A frozen selection of open workspace identities and group member versions.
/// Titles, terminal text, credentials, saved-connection payloads and service
/// handles are deliberately absent. A rename/state update keeps the grant;
/// opening, closing, reconnecting or changing group members invalidates it.
pub const Selection = struct {
    scope: Scope = .workspace_open_metadata,
    membership_digest: [32]u8,
    session_count: usize,
    group_count: usize,

    pub fn eql(self: Selection, other: Selection) bool {
        return self.scope == other.scope and self.session_count == other.session_count and self.group_count == other.group_count and std.mem.eql(u8, &self.membership_digest, &other.membership_digest);
    }
    pub fn revision(self: Selection) u64 {
        const value = std.mem.readInt(u64, self.membership_digest[0..8], .little);
        return if (value == 0) 1 else value;
    }
};

/// Canonical identities, not UI order, determine the frozen selection. This is
/// also the value to bind into metadata pagination's source revision/signature.
pub fn captureSelection(a: std.mem.Allocator, sessions: []const identity.SessionHandle, groups: []const Group) !Selection {
    const ordered_sessions = try a.dupe(identity.SessionHandle, sessions);
    defer a.free(ordered_sessions);
    std.mem.sort(identity.SessionHandle, ordered_sessions, {}, sessionLess);
    const ordered_groups = try a.dupe(Group, groups);
    defer a.free(ordered_groups);
    std.mem.sort(Group, ordered_groups, {}, groupLess);
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update("ZeroWork inventory metadata selection v1");
    hashU64(&hash, sessions.len);
    for (ordered_sessions, 0..) |item, index| {
        try validSession(item);
        if (index > 0 and ordered_sessions[index - 1].session_id == item.session_id) return error.InvalidInventorySelection;
        hashSession(&hash, item);
    }
    hashU64(&hash, groups.len);
    for (ordered_groups, 0..) |group, index| {
        if (group.id == 0 or group.membership_revision == 0 or (index > 0 and ordered_groups[index - 1].id == group.id)) return error.InvalidInventorySelection;
        hashU64(&hash, group.id);
        hashU64(&hash, group.membership_revision);
        const members = try a.dupe(identity.SessionHandle, group.members);
        defer a.free(members);
        std.mem.sort(identity.SessionHandle, members, {}, sessionLess);
        hashU64(&hash, members.len);
        for (members, 0..) |member, member_index| {
            try validSession(member);
            if (member_index > 0 and members[member_index - 1].session_id == member.session_id) return error.InvalidInventorySelection;
            hashSession(&hash, member);
        }
    }
    var digest: [32]u8 = undefined;
    hash.final(&digest);
    return .{ .membership_digest = digest, .session_count = sessions.len, .group_count = groups.len };
}
fn validSession(item: identity.SessionHandle) !void {
    if (@backingInt(item.session_id) == 0 or item.generation == 0) return error.InvalidInventorySelection;
}
fn sessionLess(_: void, lhs: identity.SessionHandle, rhs: identity.SessionHandle) bool {
    return if (lhs.session_id == rhs.session_id) lhs.generation < rhs.generation else @backingInt(lhs.session_id) < @backingInt(rhs.session_id);
}
fn groupLess(_: void, lhs: Group, rhs: Group) bool {
    return lhs.id < rhs.id;
}
fn hashU64(hash: *std.crypto.hash.sha2.Sha256, value: u64) void {
    var bytes: [8]u8 = undefined;
    std.mem.writeInt(u64, &bytes, value, .little);
    hash.update(&bytes);
}
fn hashSession(hash: *std.crypto.hash.sha2.Sha256, value: identity.SessionHandle) void {
    hashU64(hash, @backingInt(value.session_id));
    hashU64(hash, value.generation);
}

pub const Ticket = struct {
    context: host.Context,
    selection: Selection,
    sequence: u64,
    captured_at: i64,
    expires_at: i64,

    pub fn eql(self: Ticket, other: Ticket) bool {
        return self.context.eql(other.context) and self.selection.eql(other.selection) and self.sequence == other.sequence and self.captured_at == other.captured_at and self.expires_at == other.expires_at;
    }
};
/// The lifetime of authority is separate from the selection frozen for one
/// query. On-demand grants never contain a wall-clock preauthorization window.
pub const Duration = enum { legacy, invocation, conversation };
pub const InvocationIdentity = struct {
    context: host.Context,
    operation_id: u64,
    turn_id: u64,
    tool_hash: [32]u8,
    call_hash: [32]u8,
    canonical_arguments_hash: [32]u8,

    pub fn capture(value: host.Invocation) InvocationIdentity {
        var tool_hash: [32]u8 = undefined;
        var call_hash: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(value.tool_id, &tool_hash, .{});
        std.crypto.hash.sha2.Sha256.hash(value.call_id, &call_hash, .{});
        return .{ .context = value.context, .operation_id = value.operation_id, .turn_id = value.turn_id, .tool_hash = tool_hash, .call_hash = call_hash, .canonical_arguments_hash = value.canonical_arguments_hash };
    }
    pub fn eql(self: InvocationIdentity, other: InvocationIdentity) bool {
        return self.context.eql(other.context) and self.operation_id == other.operation_id and self.turn_id == other.turn_id and std.mem.eql(u8, &self.tool_hash, &other.tool_hash) and std.mem.eql(u8, &self.call_hash, &other.call_hash) and std.mem.eql(u8, &self.canonical_arguments_hash, &other.canonical_arguments_hash);
    }
};
pub const Grant = struct {
    context: host.Context,
    selection: Selection,
    sequence: u64,
    issued_at: i64,
    expires_at: i64,
    evidence: enum { explicit_ui_action } = .explicit_ui_action,
    duration: Duration = .legacy,
    invocation: ?InvocationIdentity = null,

    pub fn valid(self: Grant, context: host.Context, selection: Selection, now: i64) bool {
        return self.context.eql(context) and self.selection.eql(selection) and (self.duration != .legacy or (now >= self.issued_at and now < self.expires_at));
    }
    pub fn validForInvocation(self: Grant, value: host.Invocation, selection: Selection, now: i64) bool {
        if (!self.valid(value.context, selection, now)) return false;
        if (self.duration != .legacy) {
            const actual = @import("canonical_arguments.zig").digest(std.heap.page_allocator, value.arguments) catch return false;
            if (!std.mem.eql(u8, &actual, &value.canonical_arguments_hash)) return false;
        }
        if (self.duration != .invocation) return true;
        const expected = self.invocation orelse return false;
        return expected.eql(InvocationIdentity.capture(value));
    }
};
pub const Action = enum { allow_workspace_metadata, revoke_workspace_metadata };

/// One instance per conversation. Retain it across safe round boundaries, but
/// never persist grants or copy them into a newly generated TaskId.
pub const Controller = struct {
    pending: ?Ticket = null,
    granted: ?Grant = null,
    next_sequence: u64 = 1,

    pub fn capture(self: *Controller, context: host.Context, selection: Selection, now: i64) !Ticket {
        try context.validate();
        if (now < 0 or std.mem.allEqual(u8, &selection.membership_digest, 0)) return error.InvalidInventorySelection;
        if (self.pending) |pending| if (pending.context.eql(context) and pending.selection.eql(selection) and now >= pending.captured_at and now < pending.expires_at) return pending;
        if (self.next_sequence == 0) return error.InventorySequenceExhausted;
        const sequence = self.next_sequence;
        const expires_at = std.math.add(i64, now, lifetime_ms) catch return error.InvalidInventorySelection;
        self.next_sequence = if (sequence == std.math.maxInt(u64)) 0 else sequence + 1;
        const ticket: Ticket = .{ .context = context, .selection = selection, .sequence = sequence, .captured_at = now, .expires_at = expires_at };
        self.pending = ticket;
        return ticket;
    }
    fn checkTicket(self: *const Controller, ticket: Ticket, context: host.Context, selection: Selection, now: i64) !void {
        try context.validate();
        const pending = self.pending orelse return error.StaleInventoryDecision;
        if (!pending.eql(ticket) or !ticket.context.eql(context) or !ticket.selection.eql(selection)) return error.ScopeChanged;
        if (now < ticket.captured_at or now >= ticket.expires_at) return error.InventoryGrantExpired;
    }
    /// Call only from a real native user event, with fresh host context and
    /// selection. Publish returned context.grant_revision at the same safe
    /// boundary. Tool schemas do not expose this API or any grant flag.
    pub fn allowFromUi(self: *Controller, ticket: Ticket, context: host.Context, selection: Selection, now: i64) !Grant {
        try self.checkTicket(ticket, context, selection, now);
        var authorized = context;
        authorized.grant_revision = try identity.advance(context.grant_revision);
        const expires_at = std.math.add(i64, now, lifetime_ms) catch return error.InvalidInventorySelection;
        const grant: Grant = .{ .context = authorized, .selection = selection, .sequence = ticket.sequence, .issued_at = now, .expires_at = expires_at };
        self.granted = grant;
        self.pending = null;
        return grant;
    }
    pub fn revokeFromUi(self: *Controller, ticket: Ticket, context: host.Context, selection: Selection, now: i64) !u64 {
        try self.checkTicket(ticket, context, selection, now);
        const revision = try identity.advance(context.grant_revision);
        self.clear();
        return revision;
    }
    pub fn metadataGrant(self: *const Controller, context: host.Context, selection: Selection, now: i64) ?Grant {
        const grant = self.granted orelse return null;
        return if (grant.valid(context, selection, now)) grant else null;
    }
    /// Invalidate on a new task, binding/selection change, policy revision or
    /// expiry. Live validation is still mandatory immediately before queries.
    pub fn invalidate(self: *Controller, context: host.Context, selection: Selection, now: i64) void {
        if (self.granted) |grant| {
            if (!grant.valid(context, selection, now)) self.granted = null;
        }
        if (self.pending) |pending| {
            if (!pending.context.eql(context) or !pending.selection.eql(selection) or now < pending.captured_at or now >= pending.expires_at) self.pending = null;
        }
    }
    pub fn clear(self: *Controller) void {
        self.pending = null;
        self.granted = null;
    }
};

fn testContext() host.Context {
    return .{ .conversation_id = .{ .bytes = @splat(1) }, .task_id = .{ .bytes = @splat(2) }, .binding = .{ .session = 4 }, .binding_revision = 1, .grant_revision = 1 };
}
fn testSelection() !Selection {
    return captureSelection(std.testing.allocator, &.{.{ .session_id = @fromBackingInt(4), .generation = 2 }}, &.{});
}
test "inventory grant defaults closed and requires a captured current UI action" {
    var controller: Controller = .{};
    const context = testContext();
    const selection = try testSelection();
    try std.testing.expect(controller.metadataGrant(context, selection, 100) == null);
    const ticket = try controller.capture(context, selection, 100);
    try std.testing.expect(controller.metadataGrant(context, selection, 100) == null);
    var forged = ticket;
    forged.sequence += 1;
    try std.testing.expectError(error.ScopeChanged, controller.allowFromUi(forged, context, selection, 101));
    const grant = try controller.allowFromUi(ticket, context, selection, 101);
    try std.testing.expectEqual(@as(u64, 2), grant.context.grant_revision);
    try std.testing.expect(controller.metadataGrant(context, selection, 101) == null);
    try std.testing.expect(controller.metadataGrant(grant.context, selection, 101) != null);
    try std.testing.expectError(error.StaleInventoryDecision, controller.allowFromUi(ticket, context, selection, 101));
    // No target set, source ref, service or lifecycle permission exists here.
    try std.testing.expect(!@hasField(Grant, "session_targets"));
    try std.testing.expect(!@hasField(Grant, "selected_sources"));
}
test "inventory grant fences task binding expiry policy and explicit revocation" {
    var controller: Controller = .{};
    const context = testContext();
    const selection = try testSelection();
    const ticket = try controller.capture(context, selection, 100);
    const grant = try controller.allowFromUi(ticket, context, selection, 101);
    var changed = grant.context;
    changed.task_id.bytes[0] += 1;
    try std.testing.expect(controller.metadataGrant(changed, selection, 102) == null);
    changed = grant.context;
    changed.binding_revision += 1;
    try std.testing.expect(controller.metadataGrant(changed, selection, 102) == null);
    changed = grant.context;
    changed.grant_revision += 1;
    try std.testing.expect(controller.metadataGrant(changed, selection, 102) == null);
    changed = grant.context;
    changed.conversation_id.bytes[0] += 1;
    try std.testing.expect(controller.metadataGrant(changed, selection, 102) == null);
    try std.testing.expect(controller.metadataGrant(grant.context, selection, grant.expires_at) == null);
    const revoke_ticket = try controller.capture(grant.context, selection, 102);
    try std.testing.expectEqual(@as(u64, 3), try controller.revokeFromUi(revoke_ticket, grant.context, selection, 103));
    try std.testing.expect(controller.metadataGrant(grant.context, selection, 104) == null);
}
test "inventory selection binds all groups member revisions handles and generations" {
    const a = std.testing.allocator;
    const handles = [_]identity.SessionHandle{ .{ .session_id = @fromBackingInt(4), .generation = 2 }, .{ .session_id = @fromBackingInt(8), .generation = 3 } };
    const groups = [_]Group{.{ .id = 7, .membership_revision = 2, .members = &handles }};
    const first = try captureSelection(a, &handles, &groups);
    const reordered = [_]identity.SessionHandle{ handles[1], handles[0] };
    try std.testing.expect(first.eql(try captureSelection(a, &reordered, &.{.{ .id = 7, .membership_revision = 2, .members = &reordered }})));
    const changed = try captureSelection(a, &handles, &.{.{ .id = 7, .membership_revision = 3, .members = &handles }});
    try std.testing.expect(!first.eql(changed));
    var controller: Controller = .{};
    const ticket = try controller.capture(testContext(), first, 100);
    try std.testing.expectError(error.ScopeChanged, controller.allowFromUi(ticket, testContext(), changed, 101));
    const grant = try controller.allowFromUi(ticket, testContext(), first, 101);
    try std.testing.expect(controller.metadataGrant(grant.context, changed, 102) == null);
    var reconnected = handles;
    reconnected[1].generation += 1;
    try std.testing.expect(!first.eql(try captureSelection(a, &reconnected, &groups)));
    try std.testing.expect(!first.eql(try captureSelection(a, handles[0..1], &groups)));
    controller.invalidate(grant.context, changed, 103);
    try std.testing.expect(controller.metadataGrant(grant.context, first, 104) == null);
}
test "inventory capture expiry and invalid identities fail without issuing authority" {
    var controller: Controller = .{};
    const selection = try testSelection();
    const context = testContext();
    const ticket = try controller.capture(context, selection, 1);
    try std.testing.expectError(error.InventoryGrantExpired, controller.allowFromUi(ticket, context, selection, ticket.expires_at));
    try std.testing.expectError(error.InvalidInventorySelection, captureSelection(std.testing.allocator, &.{.{ .session_id = @fromBackingInt(0) }}, &.{}));
    try std.testing.expectError(error.InvalidInventorySelection, captureSelection(std.testing.allocator, &.{ .{ .session_id = @fromBackingInt(1) }, .{ .session_id = @fromBackingInt(1) } }, &.{}));
    controller.clear();
    try std.testing.expectError(error.StaleInventoryDecision, controller.allowFromUi(ticket, context, selection, 2));
}
