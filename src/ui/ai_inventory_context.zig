//! Main-thread identity capture for the metadata grant. The selection builder
//! holds no terminal service, credentials, execution target or selected source.
const std = @import("std");
const grants = @import("../ai/inventory_grants.zig");
const identity = @import("../host/identity.zig");
const Workspace = @import("workspace.zig").Workspace;
const Roster = @import("group_model.zig").Roster;

/// Recompute immediately before a grant decision and every inventory query.
/// Include failed/closed tab identities: observing recovery metadata must not
/// depend on their terminal or lifecycle capabilities being available.
pub fn capture(a: std.mem.Allocator, workspace: *const Workspace, roster: ?*const Roster) !grants.Selection {
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const scratch = arena.allocator();
    var sessions: std.ArrayList(identity.SessionHandle) = .empty;
    for (workspace.tabs.items) |tab| {
        if (tab.content_owner == .session) try sessions.append(scratch, tab.content_owner.session);
    }
    var groups: std.ArrayList(grants.Group) = .empty;
    if (roster) |value| {
        for (value.groups.items) |group| {
            var members: std.ArrayList(identity.SessionHandle) = .empty;
            for (group.members.items) |member| {
                if (!member.active) continue;
                for (workspace.tabs.items) |tab| {
                    if (tab.id == member.pane_id and tab.content_owner == .session) {
                        try members.append(scratch, tab.content_owner.session);
                        break;
                    }
                }
            }
            try groups.append(scratch, .{ .id = group.id, .membership_revision = group.membership_revision, .members = members.items });
        }
    }
    return grants.captureSelection(scratch, sessions.items, groups.items);
}

/// Additional rows expose metadata only. Preserve current-binding rows via
/// the original projection, and use this only for rows added by discovery.
/// A listed ref must still pass the original separate target/source validator.
pub fn metadataOnly(item: @import("../ai/host_queries.zig").Session) @import("../ai/host_queries.zig").Session {
    return @import("../ai/host_queries.zig").metadataOnly(item);
}

test "inventory extra metadata projection never carries content or source authority" {
    const item = metadataOnly(.{ .handle = .{ .session_id = @fromBackingInt(9), .generation = 4 }, .title = "fixture", .protocol = "ssh", .state = "failed", .ready = false, .current_member = true, .read_terminal = true, .batch_execution = true, .trusted_pty_execution = true, .saved_source = .{ .id = @fromBackingInt(8), .revision = 2 }, .recording_id = @splat(3), .recording_generation = 7, .has_control_lease = true, .input_ready = true });
    try std.testing.expectEqualStrings("failed", item.state);
    try std.testing.expect(!item.current_member and !item.read_terminal and !item.batch_execution and !item.trusted_pty_execution and !item.has_control_lease);
    try std.testing.expect(item.saved_source == null and item.recording_id == null and item.input_ready == null);
}
