//! Window-local workspace state. No widgets, transports or borrowed view pointers.
const std = @import("std");
const identity = @import("../host/identity.zig");

pub const TabId = identity.TabId;
pub const Owner = identity.ContentOwner;
pub const Tab = struct {
    id: TabId,
    owner: Owner,
    title: [64]u8 = @splat(0),
    title_len: u8 = 0,
    revision: u64 = 1,
    details: []const u8 = "",

    pub fn name(self: *const Tab) []const u8 {
        return self.title[0..self.title_len];
    }
    fn setName(self: *Tab, raw: []const u8) !void {
        const value = std.mem.trim(u8, raw, " \t\r\n");
        if (value.len == 0) return error.EmptyName;
        if (value.len > self.title.len) return error.NameTooLong;
        if (!std.unicode.utf8ValidateSlice(value)) return error.InvalidName;
        for (value) |byte| if (byte < 0x20 or byte == 0x7f) return error.InvalidName;
        @memcpy(self.title[0..value.len], value);
        self.title_len = @intCast(value.len);
    }
};

pub const Rename = struct { tab: TabId, owner: Owner, revision: u64 };
pub const CloseTarget = struct { tab: TabId, owner: Owner };
pub const Picker = struct {
    query: std.ArrayList(u8) = .empty,
    revision: u64 = 0,
    results: std.ArrayList(TabId) = .empty,
    highlighted: ?TabId = null,
    open: bool = false,
    /// Stable control identity, resolved by the view only when returning focus.
    focus_return: ?u64 = null,

    pub fn deinit(self: *Picker, allocator: std.mem.Allocator) void {
        self.query.deinit(allocator);
        self.results.deinit(allocator);
    }
    pub fn update(self: *Picker, allocator: std.mem.Allocator, workspace: *const Model, query: []const u8) !void {
        if (self.revision == std.math.maxInt(u64)) return error.RevisionExhausted;
        // Prepare first so allocation failure leaves the previous query intact.
        const copy = try allocator.dupe(u8, query);
        defer allocator.free(copy);
        var matches: std.ArrayList(TabId) = .empty;
        errdefer matches.deinit(allocator);
        for (workspace.tabs.items) |*tab| {
            if (matchesTab(tab, query))
                try matches.append(allocator, tab.id);
        }
        try self.query.ensureTotalCapacity(allocator, copy.len);
        self.query.clearRetainingCapacity();
        self.query.appendSliceAssumeCapacity(copy);
        self.results.deinit(allocator);
        self.results = matches;
        self.revision += 1;
        self.highlighted = if (matches.items.len > 0) matches.items[0] else null;
    }
    pub fn show(self: *Picker, allocator: std.mem.Allocator, workspace: *const Model, focus_return: u64) !void {
        try self.update(allocator, workspace, "");
        self.open = true;
        self.focus_return = focus_return;
    }
    pub fn dismiss(self: *Picker) ?u64 {
        self.open = false;
        self.highlighted = null;
        const focus = self.focus_return;
        self.focus_return = null;
        return focus;
    }
    pub fn move(self: *Picker, direction: enum { previous, next }) void {
        if (self.results.items.len == 0) {
            self.highlighted = null;
            return;
        }
        var index: usize = 0;
        for (self.results.items, 0..) |id, i| if (id == self.highlighted) {
            index = i;
            break;
        };
        index = switch (direction) {
            .previous => if (index == 0) self.results.items.len - 1 else index - 1,
            .next => (index + 1) % self.results.items.len,
        };
        self.highlighted = self.results.items[index];
    }
    pub fn activate(self: *const Picker, workspace: *Model, query_revision: u64) !void {
        if (!self.open) return error.PickerClosed;
        if (query_revision != self.revision) return error.StaleQuery;
        const id = self.highlighted orelse return error.NoMatch;
        const index = workspace.indexOf(id) orelse return error.TabClosed;
        if (!matchesTab(&workspace.tabs.items[index], self.query.items)) return error.NoMatch;
        for (self.results.items) |candidate| if (candidate == id) return workspace.activate(id);
        return error.NoMatch;
    }
};

fn matchesTab(tab: *const Tab, query: []const u8) bool {
    return containsName(tab.name(), query) or containsName(tab.details, query);
}

fn containsName(name: []const u8, query: []const u8) bool {
    if (query.len > name.len) return false;
    for (0..name.len - query.len + 1) |start| {
        if (std.ascii.eqlIgnoreCase(name[start..][0..query.len], query)) return true;
    }
    return false;
}

pub const Model = struct {
    allocator: std.mem.Allocator,
    window: identity.WindowId,
    workspace: identity.WorkspaceId,
    tabs: std.ArrayList(Tab) = .empty,
    active: ?TabId = null,
    recent: std.ArrayList(TabId) = .empty,
    recent_cycle: std.ArrayList(TabId) = .empty,
    recent_cursor: ?usize = null,
    order_revision: u64 = 0,
    drag_order: std.ArrayList(TabId) = .empty,
    dragging: bool = false,
    window_close: ?u64 = null,

    pub fn deinit(self: *Model) void {
        for (self.tabs.items) |tab| if (tab.details.len > 0) self.allocator.free(tab.details);
        self.tabs.deinit(self.allocator);
        self.recent.deinit(self.allocator);
        self.recent_cycle.deinit(self.allocator);
        self.drag_order.deinit(self.allocator);
    }
    pub fn indexOf(self: *const Model, id: TabId) ?usize {
        for (self.tabs.items, 0..) |tab, index| if (tab.id == id) return index;
        return null;
    }

    /// A retry keeps the tab but changes the exact attempt owner. Captured
    /// rename/menu/close requests from the old generation remain stale.
    pub fn replaceOwner(self: *Model, id: TabId, expected: Owner, next: Owner) !void {
        const index = self.indexOf(id) orelse return error.UnknownTab;
        const tab = &self.tabs.items[index];
        if (!tab.owner.eql(expected)) return error.StaleOwner;
        if (tab.owner.eql(next)) return;
        if (tab.revision == std.math.maxInt(u64)) return error.RevisionExhausted;
        tab.owner = next;
        tab.revision += 1;
    }
    pub fn append(self: *Model, id: TabId, owner: Owner, name: []const u8) !void {
        if (self.window_close != null) return error.WindowClosing;
        if (@backingInt(id) == 0) return error.InvalidIdentity;
        const valid_owner = switch (owner) {
            .session => |handle| @backingInt(handle.session_id) != 0 and handle.generation != 0,
            .group => |group| @backingInt(group.id) != 0 and group.revision != 0,
            .history => |history| @backingInt(history) != 0,
        };
        if (!valid_owner or @backingInt(self.window) == 0 or @backingInt(self.workspace) == 0) return error.InvalidIdentity;
        if (self.indexOf(id) != null) return error.DuplicateTab;
        if (self.order_revision == std.math.maxInt(u64)) return error.RevisionExhausted;
        var tab: Tab = .{ .id = id, .owner = owner };
        try tab.setName(name);
        try self.recent.ensureUnusedCapacity(self.allocator, 1);
        try self.tabs.append(self.allocator, tab);
        self.order_revision += 1;
        self.recent.appendAssumeCapacity(id);
        try self.activate(id);
    }
    /// Host/type metadata is display/search data, never the tab's primary key.
    pub fn setDetails(self: *Model, id: TabId, details: []const u8) !void {
        const tab = &self.tabs.items[self.indexOf(id) orelse return error.TabClosed];
        const owned = if (details.len > 0) try self.allocator.dupe(u8, details) else "";
        if (tab.details.len > 0) self.allocator.free(tab.details);
        tab.details = owned;
    }
    pub fn activate(self: *Model, id: TabId) !void {
        if (self.indexOf(id) == null) return error.TabClosed;
        self.recent_cursor = null;
        self.recent_cycle.clearRetainingCapacity();
        self.active = id;
        self.touchRecent(id);
    }
    fn touchRecent(self: *Model, id: TabId) void {
        const at = std.mem.indexOfScalar(TabId, self.recent.items, id) orelse return;
        _ = self.recent.orderedRemove(at);
        self.recent.insertAssumeCapacity(0, id);
    }
    /// Ctrl remains held across previews. Freeze MRU order until release so
    /// repeated Tab visits every surviving tab rather than toggling two tabs.
    pub fn cycleRecent(self: *Model, reverse: bool, excluded: []const TabId) !?TabId {
        if (self.recent_cursor == null) {
            try self.recent_cycle.ensureTotalCapacity(self.allocator, self.recent.items.len);
            self.recent_cycle.clearRetainingCapacity();
            for (self.recent.items) |id| {
                if (self.indexOf(id) == null or std.mem.indexOfScalar(TabId, excluded, id) != null) continue;
                self.recent_cycle.appendAssumeCapacity(id);
            }
            if (self.recent_cycle.items.len == 0) return null;
            self.recent_cursor = if (self.active) |id| std.mem.indexOfScalar(TabId, self.recent_cycle.items, id) else null;
        }
        const count = self.recent_cycle.items.len;
        if (count == 0) return null;
        var cursor = self.recent_cursor orelse if (reverse) @as(usize, 0) else count - 1;
        for (0..count) |_| {
            cursor = if (reverse) (if (cursor == 0) count - 1 else cursor - 1) else (if (cursor + 1 == count) 0 else cursor + 1);
            const id = self.recent_cycle.items[cursor];
            if (self.indexOf(id) == null or std.mem.indexOfScalar(TabId, excluded, id) != null) continue;
            self.recent_cursor = cursor;
            self.active = id;
            return id;
        }
        return null;
    }
    pub fn finishRecentSwitch(self: *Model) void {
        if (self.recent_cursor != null) if (self.active) |id| self.touchRecent(id);
        self.recent_cursor = null;
        self.recent_cycle.clearRetainingCapacity();
    }
    pub fn beginRename(self: *const Model, id: TabId) !Rename {
        const tab = self.tabs.items[self.indexOf(id) orelse return error.TabClosed];
        return .{ .tab = id, .owner = tab.owner, .revision = tab.revision };
    }
    /// Own this snapshot until the batch finishes. Later tabs never join the
    /// batch; each item is still revalidated before requesting resource close.
    /// Group membership exclusions are supplied by the V0.1.6 coordinator.
    pub fn freezeCloseTargets(self: *const Model, keep: ?TabId, excluded_groups: []const identity.GroupId) ![]CloseTarget {
        if (keep) |id| if (self.indexOf(id) == null) return error.TabClosed;
        var targets: std.ArrayList(CloseTarget) = .empty;
        errdefer targets.deinit(self.allocator);
        for (self.tabs.items) |tab| {
            if (tab.id == keep) continue;
            if (tab.owner == .group) {
                var excluded = false;
                for (excluded_groups) |group| if (group == tab.owner.group.id) {
                    excluded = true;
                    break;
                };
                if (excluded) continue;
            }
            try targets.append(self.allocator, .{ .tab = tab.id, .owner = tab.owner });
        }
        return targets.toOwnedSlice(self.allocator);
    }
    pub fn isCurrentTarget(self: *const Model, target: CloseTarget) bool {
        const index = self.indexOf(target.tab) orelse return false;
        return self.tabs.items[index].owner.eql(target.owner);
    }
    pub fn beginWindowClose(self: *Model, ticket: @import("../host/window_host.zig").Close) ![]CloseTarget {
        if (ticket.window != self.window or ticket.workspace != self.workspace or ticket.request == 0) return error.WrongWorkspace;
        if (self.window_close != null) return error.WindowClosing;
        const targets = try self.freezeCloseTargets(null, &.{});
        self.window_close = ticket.request;
        return targets;
    }
    pub fn cancelWindowClose(self: *Model, request: u64) !void {
        if (self.window_close != request) return error.StaleClose;
        self.window_close = null;
    }
    pub fn rename(self: *Model, request: Rename, raw: []const u8) !void {
        const tab = &self.tabs.items[self.indexOf(request.tab) orelse return error.TabClosed];
        if (!std.meta.eql(tab.owner, request.owner) or tab.revision != request.revision) return error.StaleRename;
        if (tab.revision == std.math.maxInt(u64)) return error.RevisionExhausted;
        try tab.setName(raw);
        tab.revision += 1;
    }
    /// Called only after the owning controller acknowledges resource cleanup.
    /// Group confirmation/close coordination happens before this method.
    pub fn completeClose(self: *Model, id: TabId, owner: Owner) !void {
        const index = self.indexOf(id) orelse return error.TabClosed;
        if (!std.meta.eql(self.tabs.items[index].owner, owner)) return error.StaleOwner;
        if (self.order_revision == std.math.maxInt(u64)) return error.RevisionExhausted;
        const removed = self.tabs.orderedRemove(index);
        if (std.mem.indexOfScalar(TabId, self.recent.items, id)) |recent_index| _ = self.recent.orderedRemove(recent_index);
        if (removed.details.len > 0) self.allocator.free(removed.details);
        self.order_revision += 1;
        if (self.active == id) {
            self.active = if (self.tabs.items.len == 0) null else self.tabs.items[@min(index, self.tabs.items.len - 1)].id;
            if (self.active) |active| self.touchRecent(active);
        }
    }
    pub fn beginDrag(self: *Model) !void {
        if (self.dragging) return error.DragInProgress;
        try self.drag_order.ensureTotalCapacity(self.allocator, self.tabs.items.len);
        self.drag_order.clearRetainingCapacity();
        for (self.tabs.items) |tab| self.drag_order.appendAssumeCapacity(tab.id);
        self.dragging = true;
    }
    pub fn moveTab(self: *Model, id: TabId, to: usize) !void {
        const from = self.indexOf(id) orelse return error.TabClosed;
        if (to >= self.tabs.items.len) return error.InvalidPosition;
        if (from == to) return;
        if (self.order_revision == std.math.maxInt(u64)) return error.RevisionExhausted;
        const tab = self.tabs.orderedRemove(from);
        self.tabs.insertAssumeCapacity(to, tab);
        self.order_revision += 1;
    }
    pub fn endDrag(self: *Model, cancel: bool) !void {
        if (!self.dragging) return;
        if (cancel) {
            if (self.order_revision == std.math.maxInt(u64)) return error.RevisionExhausted;
            // Restore surviving original tabs; new tabs stay after that snapshot.
            var next: usize = 0;
            for (self.drag_order.items) |id| {
                const at = self.indexOf(id) orelse continue;
                const tab = self.tabs.orderedRemove(at);
                self.tabs.insertAssumeCapacity(next, tab);
                next += 1;
            }
            self.order_revision += 1;
        }
        self.dragging = false;
        self.drag_order.clearRetainingCapacity();
    }
};

fn testModel() Model {
    return .{ .allocator = std.testing.allocator, .window = @fromBackingInt(1), .workspace = @fromBackingInt(1) };
}
fn session(id: u64) Owner {
    return .{ .session = .{ .session_id = @fromBackingInt(id), .generation = 1 } };
}

test "recent tab cycle freezes MRU order until Control release" {
    var model = testModel();
    defer model.deinit();
    const a: TabId = @fromBackingInt(1);
    const b: TabId = @fromBackingInt(2);
    const c: TabId = @fromBackingInt(3);
    try model.append(a, session(1), "same");
    try model.append(b, session(2), "same");
    try model.append(c, session(3), "same");
    try model.activate(a);
    try model.moveTab(c, 0);
    try std.testing.expectEqual(c, (try model.cycleRecent(false, &.{})).?);
    try std.testing.expectEqual(b, (try model.cycleRecent(false, &.{})).?);
    try std.testing.expectEqual(c, (try model.cycleRecent(true, &.{})).?);
    try std.testing.expectEqualSlices(TabId, &.{ a, c, b }, model.recent.items);
    model.finishRecentSwitch();
    try std.testing.expectEqualSlices(TabId, &.{ c, a, b }, model.recent.items);
    try std.testing.expectEqual(a, (try model.cycleRecent(false, &.{})).?);
    model.finishRecentSwitch();
    try std.testing.expectEqual(c, (try model.cycleRecent(false, &.{})).?);
    try std.testing.expectEqual(@as(?TabId, c), model.active);
}

test "recent tab cycle skips closed and pending close identities" {
    var model = testModel();
    defer model.deinit();
    const a: TabId = @fromBackingInt(1);
    const b: TabId = @fromBackingInt(2);
    const c: TabId = @fromBackingInt(3);
    const d: TabId = @fromBackingInt(4);
    for ([_]TabId{ a, b, c, d }) |id| try model.append(id, session(@backingInt(id)), "same");
    try std.testing.expectEqual(c, (try model.cycleRecent(false, &.{})).?);
    try model.completeClose(b, session(2));
    try std.testing.expectEqual(a, (try model.cycleRecent(false, &.{})).?);
    try std.testing.expectEqual(d, (try model.cycleRecent(false, &.{c})).?);
    try model.completeClose(c, session(3));
    model.finishRecentSwitch();
    try std.testing.expectEqualSlices(TabId, &.{ d, a }, model.recent.items);
    try std.testing.expectEqual(a, (try model.cycleRecent(true, &.{})).?);
    try model.completeClose(a, session(1));
    try std.testing.expectEqual(d, (try model.cycleRecent(false, &.{})).?);
    try model.completeClose(d, session(4));
    try std.testing.expect((try model.cycleRecent(false, &.{})) == null);
    model.finishRecentSwitch();
    try std.testing.expect(model.active == null);
}

test "same names keep identity; late rename cannot touch surviving tab" {
    var model = testModel();
    defer model.deinit();
    const a: TabId = @fromBackingInt(1);
    const b: TabId = @fromBackingInt(2);
    try model.append(a, session(7), "same");
    try model.append(b, session(8), "same");
    const draft = try model.beginRename(a);
    try model.completeClose(a, session(7));
    try std.testing.expectError(error.TabClosed, model.rename(draft, "changed"));
    try std.testing.expectEqualStrings("same", model.tabs.items[0].name());
    const edit = try model.beginRename(b);
    try std.testing.expectError(error.InvalidName, model.rename(edit, "\xff"));
    try std.testing.expectError(error.NameTooLong, model.rename(edit, "界界界界界界界界界界界界界界界界界界界界界界"));
    try model.rename(edit, "生产");
    try std.testing.expectError(error.StaleRename, model.rename(edit, "late"));
}

test "retry replaces only the attempt owner and invalidates captured tab requests" {
    var model = testModel();
    defer model.deinit();
    const id: TabId = @fromBackingInt(5);
    const old = session(91);
    const next: Owner = .{ .session = try old.session.nextGeneration() };
    try model.append(id, old, "我的本地会话");
    const rename = try model.beginRename(id);
    const captured = try model.freezeCloseTargets(null, &.{});
    defer model.allocator.free(captured);
    try model.replaceOwner(id, old, next);
    try std.testing.expectEqual(id, model.active.?);
    try std.testing.expectEqualStrings("我的本地会话", model.tabs.items[0].name());
    try std.testing.expect(model.tabs.items[0].owner.eql(next));
    try std.testing.expect(!model.isCurrentTarget(captured[0]));
    try std.testing.expectError(error.StaleRename, model.rename(rename, "迟到的重命名"));
    try std.testing.expectError(error.StaleOwner, model.completeClose(id, old));
    try std.testing.expectError(error.StaleOwner, model.replaceOwner(id, old, next));
    const revision = model.tabs.items[0].revision;
    try model.replaceOwner(id, next, next);
    try std.testing.expectEqual(revision, model.tabs.items[0].revision);
    try model.completeClose(id, next);
    try std.testing.expect(model.active == null);
}

test "picker only commits current query and surviving identity; empty enter keeps active" {
    var model = testModel();
    defer model.deinit();
    var picker: Picker = .{};
    defer picker.deinit(std.testing.allocator);
    try model.append(@fromBackingInt(1), session(7), "Alpha");
    try model.append(@fromBackingInt(2), session(8), "Beta");
    try picker.show(std.testing.allocator, &model, 91);
    try picker.update(std.testing.allocator, &model, "alpha");
    const previous = picker.revision;
    try std.testing.expectEqual(@as(?TabId, @fromBackingInt(2)), model.active);
    try picker.update(std.testing.allocator, &model, "missing");
    try std.testing.expectError(error.StaleQuery, picker.activate(&model, previous));
    try std.testing.expectError(error.NoMatch, picker.activate(&model, picker.revision));
    try std.testing.expectEqual(@as(?TabId, @fromBackingInt(2)), model.active);
    try picker.update(std.testing.allocator, &model, "alpha");
    try model.completeClose(@fromBackingInt(1), session(7));
    try std.testing.expectError(error.TabClosed, picker.activate(&model, picker.revision));
}

test "picker searches host identity and dismiss blocks late activation" {
    var model = testModel();
    defer model.deinit();
    var picker: Picker = .{};
    defer picker.deinit(std.testing.allocator);
    try model.append(@fromBackingInt(1), session(7), "Production");
    try model.setDetails(@fromBackingInt(1), "SSH root@db.example:22");
    try picker.show(std.testing.allocator, &model, 77);
    try picker.update(std.testing.allocator, &model, "DB.EXAMPLE");
    try picker.activate(&model, picker.revision);
    try std.testing.expectEqual(@as(?u64, 77), picker.dismiss());
    try std.testing.expectError(error.PickerClosed, picker.activate(&model, picker.revision));
    try picker.show(std.testing.allocator, &model, 77);
    try picker.update(std.testing.allocator, &model, "Production");
    try model.rename(try model.beginRename(@fromBackingInt(1)), "Renamed");
    try std.testing.expectError(error.NoMatch, picker.activate(&model, picker.revision));
}

test "close acknowledgment keeps background active and chooses right then left" {
    var model = testModel();
    defer model.deinit();
    for (1..5) |id| try model.append(@fromBackingInt(@as(u64, @intCast(id))), session(@intCast(id)), "tab");
    try model.activate(@fromBackingInt(2));
    try std.testing.expectError(error.StaleOwner, model.completeClose(@fromBackingInt(1), session(9)));
    try model.completeClose(@fromBackingInt(1), session(1));
    try std.testing.expectEqual(@as(?TabId, @fromBackingInt(2)), model.active);
    try model.completeClose(@fromBackingInt(2), session(2));
    try std.testing.expectEqual(@as(?TabId, @fromBackingInt(3)), model.active);
    try model.activate(@fromBackingInt(4));
    try model.completeClose(@fromBackingInt(4), session(4));
    try std.testing.expectEqual(@as(?TabId, @fromBackingInt(3)), model.active);
    try model.completeClose(@fromBackingInt(3), session(3));
    try std.testing.expect(model.active == null);
}

test "drag cancel restores surviving snapshot without retargeting owner or active" {
    var model = testModel();
    defer model.deinit();
    for (1..4) |id| try model.append(@fromBackingInt(@as(u64, @intCast(id))), session(@intCast(id)), "tab");
    try model.beginDrag();
    try model.moveTab(@fromBackingInt(3), 0);
    try model.completeClose(@fromBackingInt(2), session(2));
    try model.append(@fromBackingInt(4), session(4), "new");
    try model.endDrag(true);
    try std.testing.expectEqual(@as(TabId, @fromBackingInt(1)), model.tabs.items[0].id);
    try std.testing.expectEqual(@as(TabId, @fromBackingInt(3)), model.tabs.items[1].id);
    try std.testing.expectEqual(@as(TabId, @fromBackingInt(4)), model.tabs.items[2].id);
    try std.testing.expectEqual(@as(?TabId, @fromBackingInt(4)), model.active);
    try std.testing.expect(std.meta.eql(session(3), model.tabs.items[1].owner));
}

test "close batch freezes ordered targets and excludes groups containing retained session" {
    var model = testModel();
    defer model.deinit();
    try model.append(@fromBackingInt(1), session(1), "keep");
    try model.append(@fromBackingInt(2), .{ .group = .{ .id = @fromBackingInt(1) } }, "group sharing keep");
    try model.append(@fromBackingInt(3), session(3), "close");
    const targets = try model.freezeCloseTargets(@fromBackingInt(1), &.{@fromBackingInt(1)});
    defer model.allocator.free(targets);
    try model.append(@fromBackingInt(4), session(4), "arrived later");
    try std.testing.expectEqual(@as(usize, 1), targets.len);
    try std.testing.expectEqual(@as(TabId, @fromBackingInt(3)), targets[0].tab);
    try std.testing.expect(model.isCurrentTarget(targets[0]));
    try model.completeClose(targets[0].tab, targets[0].owner);
    try std.testing.expect(!model.isCurrentTarget(targets[0]));
    try std.testing.expectEqual(@as(usize, 3), model.tabs.items.len);
}

test "window close freezes owners and gates new content until matching cancellation" {
    var model = testModel();
    defer model.deinit();
    try model.append(@fromBackingInt(1), session(1), "existing");
    const targets = try model.beginWindowClose(.{ .window = model.window, .workspace = model.workspace, .request = 7 });
    defer model.allocator.free(targets);
    try std.testing.expectEqual(@as(usize, 1), targets.len);
    try std.testing.expectError(error.WindowClosing, model.append(@fromBackingInt(2), session(2), "new"));
    try std.testing.expectError(error.StaleClose, model.cancelWindowClose(6));
    try model.cancelWindowClose(7);
    try model.append(@fromBackingInt(2), session(2), "new");
}
