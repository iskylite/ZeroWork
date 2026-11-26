//! Seam between the bundled AI plugin page and the main-window assistant host.
//! A plugin cannot import the executable root, so the page publishes its center
//! slot and inspector pages here; main.zig attaches the assistant surface and
//! the existing child-workspace views into them.
const ui = @import("ui");
const identity = @import("../host/identity.zig");
const workspace_shell = @import("ai_workspace_shell.zig");

pub const inspector_pages = 4;
pub const visible_conversation_limit = 40;
pub const WorkspacePreview = @import("../host/workspace_preview.zig");
pub const WorkspaceText = @import("../host/workspace_text_reference.zig");
pub const WorkspaceTicket = @import("ai_workspace_view.zig").Ticket;
/// Borrowed only during a live controller projection. Consumers must not
/// retain the records: an owner switch can dispose the presentation store.
pub const DiffAccess = struct {
    authority: @import("../ai/host_tools.zig").Context,
    turn_id: u64,
    records: []const *@import("../ai/tool_results.zig").Record,
};
pub const ConversationAction = union(enum) { new_chat, history, preview: u64, pin: struct { id: u64, value: bool }, delete: u64, choose_workspace: WorkspaceTicket, reference_workspace_file: WorkspaceText.Selection };
pub const ConversationActions = struct {
    context: *anyopaque,
    invoke: *const fn (*anyopaque, identity.SessionHandle, ConversationAction) void,
    can_open_global_history: bool = false,
};

/// A historical inspector selection is valid only while the presentation that
/// opened it is still shown. In particular a same-tab binding handoff and a
/// same-owner conversation switch both remove that temporary choice.
pub fn retainedInspectorParent(historical: ?identity.ConversationId, owner_changed: bool, before: ?u64, after: u64) ?identity.ConversationId {
    return if (!owner_changed and before == after) historical else null;
}
/// Intrusive registration lives as long as the mounted plugin page. Slots
/// are keyed by the full session generation and removed by pointer on unmount.
pub const Slot = struct {
    owner: identity.SessionHandle,
    center: *ui.Node,
    pages: [inspector_pages]?*ui.Node = @splat(null),
    context: *anyopaque,
    set_badge: *const fn (*anyopaque, []const u8) void,
    set_host: *const fn (*anyopaque, usize, ?*ui.Node) anyerror!void,
    set_conversations: ?*const fn (*anyopaque, []const u8, []const workspace_shell.Conversation, bool) anyerror!void = null,
    set_workspace: ?*const fn (*anyopaque, ?WorkspaceTicket, ?WorkspacePreview.Source, ?DiffAccess) anyerror!void = null,
    actions: ?ConversationActions = null,
    shown: [visible_conversation_limit]u64 = undefined,
    shown_count: usize = 0,
    projected: [visible_conversation_limit]u64 = undefined,
    projected_count: usize = 0,
    next: ?*Slot = null,
};

var first: ?*Slot = null;

fn lookup(owner: identity.SessionHandle) ?*Slot {
    var cursor = first;
    while (cursor) |slot| : (cursor = slot.next) {
        if (slot.owner.eql(owner)) return slot;
    }
    return null;
}

pub fn setBadge(owner: identity.SessionHandle, value: []const u8) void {
    if (lookup(owner)) |slot| slot.set_badge(slot.context, value);
}

pub fn setHost(owner: identity.SessionHandle, index: usize, node: ?*ui.Node) !void {
    const slot = lookup(owner) orelse return error.InspectorHostUnavailable;
    if (index >= inspector_pages) return error.InspectorHostUnavailable;
    try slot.set_host(slot.context, index, node);
}

/// Store only IDs actually presented inside this mounted AI surface. Historical
/// numerical session/group owners are not proof of membership after relaunch.
pub fn observeConversation(owner: identity.SessionHandle, id: u64) []const u64 {
    const slot = lookup(owner) orelse return &.{};
    if (id == 0) return slot.shown[0..slot.shown_count];
    const used = slot.shown[0..slot.shown_count];
    for (used, 0..) |previous, i| {
        if (previous != id) continue;
        if (i != 0) {
            @memmove(used[1..][0..i], used[0..i]);
            used[0] = id;
        }
        return used;
    }
    if (slot.shown_count < slot.shown.len) slot.shown_count += 1;
    const retained = slot.shown_count - 1;
    @memmove(slot.shown[1..][0..retained], slot.shown[0..retained]);
    slot.shown[0] = id;
    return slot.shown[0..slot.shown_count];
}

pub fn setConversations(owner: identity.SessionHandle, title: []const u8, rows: []const workspace_shell.Conversation, actions: ConversationActions) !void {
    const slot = lookup(owner) orelse return;
    if (slot.set_conversations) |set| try set(slot.context, title, rows, actions.can_open_global_history);
    slot.actions = actions;
    slot.projected_count = 0;
    for (rows[0..@min(rows.len, slot.projected.len)]) |row| {
        const id = @import("std").fmt.parseInt(u64, row.id, 10) catch continue;
        slot.projected[slot.projected_count] = id;
        slot.projected_count += 1;
    }
}

pub fn setWorkspace(owner: identity.SessionHandle, ticket: ?WorkspaceTicket, source: ?WorkspacePreview.Source) void {
    setWorkspaceWithDiff(owner, ticket, source, null);
}
pub fn setWorkspaceWithDiff(owner: identity.SessionHandle, ticket: ?WorkspaceTicket, source: ?WorkspacePreview.Source, diff: ?DiffAccess) void {
    const slot = lookup(owner) orelse return;
    if (slot.set_workspace) |set| set(slot.context, ticket, source, diff) catch {};
}

pub fn dispatch(slot: *Slot, action: ConversationAction) void {
    // A retired view cannot address a replacement, even for the same handle.
    if (lookup(slot.owner) != slot) return;
    const requested: ?u64 = switch (action) {
        .preview => |id| id,
        .pin => |pin| pin.id,
        .delete => |id| id,
        else => null,
    };
    if (requested) |id| {
        for (slot.projected[0..slot.projected_count]) |visible| {
            if (visible == id) break;
        } else return;
    }
    if (slot.actions) |actions| {
        if (action == .history and !actions.can_open_global_history) return;
        actions.invoke(actions.context, slot.owner, action);
    }
}

pub fn register(slot: *Slot) void {
    if (lookup(slot.owner)) |prior| unregister(prior);
    slot.next = first;
    first = slot;
}

pub fn unregister(slot: *Slot) void {
    var link = &first;
    while (link.*) |current| : (link = &current.next) {
        if (current != slot) continue;
        link.* = slot.next;
        slot.next = null;
        return;
    }
}

pub fn find(owner: identity.SessionHandle) ?*ui.Node {
    return if (lookup(owner)) |slot| slot.center else null;
}

pub fn findPages(owner: identity.SessionHandle) ?[inspector_pages]?*ui.Node {
    return if (lookup(owner)) |slot| slot.pages else null;
}

test "standalone renderer registrations are independent and unmount by exact token" {
    const std = @import("std");
    const Probe = struct {
        badge_calls: usize = 0,
        fn setBadge(raw: *anyopaque, _: []const u8) void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.badge_calls += 1;
        }
        fn setHost(_: *anyopaque, _: usize, _: ?*ui.Node) !void {}
    };
    var node: ui.Node = undefined; // Only its address is published, never read.
    var probes: [12]Probe = @splat(.{});
    var entries: [probes.len]Slot = undefined;
    for (&entries, &probes, 1..) |*slot, *probe, id| {
        slot.* = .{ .owner = .{ .session_id = @fromBackingInt(id), .generation = 1 }, .center = &node, .context = probe, .set_badge = Probe.setBadge, .set_host = Probe.setHost };
        register(slot);
    }
    defer for (&entries) |*slot| unregister(slot);
    setBadge(entries[11].owner, "第十二个 AI");
    try std.testing.expectEqual(@as(usize, 1), probes[11].badge_calls);
    try std.testing.expectEqual(@as(usize, 0), probes[0].badge_calls);
    var replacement = entries[11];
    replacement.context = &probes[0];
    register(&replacement);
    defer unregister(&replacement);
    unregister(&entries[11]); // the old renderer cannot remove its replacement
    setBadge(replacement.owner, "重新挂载");
    try std.testing.expectEqual(@as(usize, 1), probes[0].badge_calls);
    try std.testing.expectEqual(@as(usize, 1), probes[11].badge_calls);
}

test "conversation rail accepts only visible-owner IDs from the still-mounted renderer" {
    const std = @import("std");
    const Probe = struct {
        new_count: usize = 0,
        history_count: usize = 0,
        preview: u64 = 0,
        owner: ?identity.SessionHandle = null,
        fn setBadge(_: *anyopaque, _: []const u8) void {}
        fn setHost(_: *anyopaque, _: usize, _: ?*ui.Node) !void {}
        fn invoke(raw: *anyopaque, owner: identity.SessionHandle, action: ConversationAction) void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.owner = owner;
            switch (action) {
                .new_chat => self.new_count += 1,
                .history => self.history_count += 1,
                .preview => |id| self.preview = id,
                .pin, .delete, .choose_workspace, .reference_workspace_file => {},
            }
        }
    };
    var node: ui.Node = undefined;
    var probe: Probe = .{};
    const owner: identity.SessionHandle = .{ .session_id = @fromBackingInt(40) };
    const newer = try owner.nextGeneration();
    var a: Slot = .{ .owner = owner, .center = &node, .context = &probe, .set_badge = Probe.setBadge, .set_host = Probe.setHost };
    var b: Slot = .{ .owner = newer, .center = &node, .context = &probe, .set_badge = Probe.setBadge, .set_host = Probe.setHost };
    register(&a);
    defer unregister(&a);
    register(&b);
    defer unregister(&b);
    const hooks: ConversationActions = .{ .context = &probe, .invoke = Probe.invoke };
    try setConversations(owner, "", &.{}, hooks);
    try setConversations(newer, "", &.{}, hooks);
    dispatch(&b, .history);
    try std.testing.expectEqual(@as(usize, 0), probe.history_count);
    var standalone_hooks = hooks;
    standalone_hooks.can_open_global_history = true;
    try setConversations(owner, "", &.{}, standalone_hooks);
    dispatch(&a, .history);
    try std.testing.expectEqual(@as(usize, 1), probe.history_count);
    try std.testing.expectEqualSlices(u64, &.{11}, observeConversation(owner, 11));
    try std.testing.expectEqualSlices(u64, &.{22}, observeConversation(newer, 22));
    try setConversations(owner, "", &.{.{ .id = "11", .title = "" }}, standalone_hooks);
    try setConversations(newer, "", &.{.{ .id = "22", .title = "" }}, hooks);
    dispatch(&a, .{ .preview = 22 });
    try std.testing.expectEqual(@as(u64, 0), probe.preview);
    dispatch(&a, .{ .preview = 11 });
    try std.testing.expectEqual(@as(u64, 11), probe.preview);
    try std.testing.expect(probe.owner.?.eql(owner));
    dispatch(&b, .new_chat);
    try std.testing.expectEqual(@as(usize, 1), probe.new_count);
    try std.testing.expect(probe.owner.?.eql(newer));
    for (100..100 + visible_conversation_limit + 1) |id| _ = observeConversation(newer, id);
    const recent = observeConversation(newer, 103);
    try std.testing.expectEqual(@as(usize, visible_conversation_limit), recent.len);
    try std.testing.expectEqual(@as(u64, 103), recent[0]);
    try setConversations(newer, "", &.{.{ .id = "103", .title = "" }}, hooks);
    dispatch(&b, .{ .preview = 22 });
    try std.testing.expectEqual(@as(u64, 11), probe.preview);
    var replacement: Slot = .{ .owner = owner, .center = &node, .context = &probe, .set_badge = Probe.setBadge, .set_host = Probe.setHost };
    register(&replacement);
    defer unregister(&replacement);
    try setConversations(owner, "", &.{}, hooks);
    dispatch(&a, .new_chat);
    try std.testing.expectEqual(@as(usize, 1), probe.new_count);
    dispatch(&replacement, .new_chat);
    try std.testing.expectEqual(@as(usize, 2), probe.new_count);
}

test "conversation rail drops historical inspector parent on owner or conversation change" {
    const std = @import("std");
    const chosen: identity.ConversationId = .{ .bytes = @splat(19) };
    try std.testing.expect(retainedInspectorParent(chosen, false, 90, 90).?.eql(chosen));
    try std.testing.expect(retainedInspectorParent(chosen, true, 90, 90) == null);
    try std.testing.expect(retainedInspectorParent(chosen, false, 90, 91) == null);
    try std.testing.expect(retainedInspectorParent(chosen, true, null, 91) == null);
}
