//! Controller-only snapshot of actual Local and SSH terminals. The AI worker
//! receives the resulting owned text and never queries the active tab.
const std = @import("std");
const model = @import("../ai/group_context.zig");
const scope_mod = @import("../ai/tool_scope.zig");
const App = @import("application_host.zig").ApplicationHost;
const Roster = @import("group_model.zig").Roster;
pub fn assemble(allocator: std.mem.Allocator, app: *App, roster: *Roster, scope: scope_mod.Scope, context_window: u32, redact: bool) !@import("../ai/assembler.zig").Assembled {
    if (scope.owner != .group) return error.InvalidGroupOwner;
    const group = roster.findById(std.math.cast(u32, scope.owner.group) orelse return error.UnknownGroup) orelse return error.UnknownGroup;
    var context = model.Context.init(allocator);
    defer context.deinit();
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();
    for (scope.members.slice()) |id| {
        var found = false;
        for (app.workspace.tabs.items) |tab| if (tab.content_owner == .session and @backingInt(tab.content_owner.session.session_id) == id) {
            const member = for (group.members.items) |item| {
                if (item.active and item.pane_id == tab.id) break true;
            } else false;
            if (!member) return error.TargetNotAuthorized;
            found = true;
            const owner = tab.content_owner.session;
            const available = !tab.closing and !tab.failed and !tab.archived;
            var clean = try @import("ai_session_context.zig").assemble(a, app, owner, context_window, redact);
            defer clean.deinit(a);
            try context.add(.{ .id = id, .generation = owner.generation, .name = if (redact) "<redacted>" else tab.titleSlice(), .summary = try a.dupe(u8, clean.text), .transport = .plugin, .available = available });
            if (group.pinned_pane == tab.id) context.anchor_id = id;
            break;
        };
        if (!found) return error.StaleSession;
    }
    return context.assemble(scope.owner.group, group.membership_revision, context_window);
}

fn flatten(allocator: std.mem.Allocator, lines: []const []const u8) ![]u8 {
    var bytes: std.ArrayList(u8) = .empty;
    defer bytes.deinit(allocator);
    for (lines) |line| {
        const keep = @min(line.len, 16384 - bytes.items.len);
        try bytes.appendSlice(allocator, line[0..keep]);
        if (bytes.items.len < 16384) try bytes.append(allocator, '\n');
        if (bytes.items.len == 16384) break;
    }
    return bytes.toOwnedSlice(allocator);
}
