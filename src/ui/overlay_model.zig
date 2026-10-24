const std = @import("std");
const identity = @import("../host/identity.zig");
const anchor = @import("overlay_anchor.zig");

pub const Trigger = enum { button, menu, shortcut, command, authentication, confirmation };
pub const FocusTarget = union(enum) {
    control: struct { window_id: identity.WindowId, control_id: u64 },
    content: struct { window_id: identity.WindowId, owner: identity.CommandOwner },
};
pub const DismissPolicy = struct { escape: bool = true, outside: bool = true, owner_change: bool = true };
pub const OverlayRecord = struct {
    id: u64,
    owner: identity.CommandOwner,
    window_id: identity.WindowId,
    trigger: Trigger,
    anchor: anchor.Rect,
    /// The view updates one window-space rect after shift/flip layout. Drawing,
    /// hit testing and IME placement consume this same geometry.
    geometry: anchor.Rect,
    focus_return: FocusTarget,
    dismiss_policy: DismissPolicy = .{},
    modal: bool = false,
};

pub const Dismissed = struct { overlay_id: u64, focus: FocusTarget };
pub const InputResult = union(enum) { unhandled, consumed_by_ime, blocked, dismissed: Dismissed };

/// Pure per-window stack. Popovers do not acquire a modal scrim merely by being
/// registered here; modal presentation is an explicit record property.
pub const OverlayHost = struct {
    allocator: std.mem.Allocator,
    window_id: identity.WindowId,
    records: std.ArrayList(OverlayRecord) = .empty,
    next_id: u64 = 1,
    exhausted: bool = false,

    pub fn init(allocator: std.mem.Allocator, window_id: identity.WindowId) OverlayHost {
        return .{ .allocator = allocator, .window_id = window_id };
    }

    pub fn deinit(self: *OverlayHost) void {
        self.records.deinit(self.allocator);
    }

    pub fn open(self: *OverlayHost, record: OverlayRecord) !u64 {
        if (record.window_id != self.window_id or @backingInt(self.window_id) == 0) return error.WrongWindow;
        if (!validRect(record.anchor) or !validRect(record.geometry)) return error.InvalidGeometry;
        if (self.exhausted or self.next_id == 0) return error.OverlayIdExhausted;
        var next = record;
        next.id = self.next_id;
        try self.records.append(self.allocator, next);
        if (self.next_id == std.math.maxInt(u64)) self.exhausted = true else self.next_id += 1;
        return next.id;
    }

    pub fn top(self: *const OverlayHost) ?OverlayRecord {
        return if (self.records.items.len > 0) self.records.items[self.records.items.len - 1] else null;
    }

    pub fn updateGeometry(self: *OverlayHost, id: u64, geometry: anchor.Rect) !bool {
        if (!validRect(geometry)) return error.InvalidGeometry;
        for (self.records.items) |*record| if (record.id == id) {
            record.geometry = geometry;
            return true;
        };
        return false;
    }

    /// IME consumes the first Escape. A blocked top layer never lets Escape
    /// reach another overlay or the terminal underneath it.
    pub fn escape(self: *OverlayHost, ime_composing: bool, trigger_exists: bool) InputResult {
        if (ime_composing) return .consumed_by_ime;
        const record = self.top() orelse return .unhandled;
        if (!record.dismiss_policy.escape) return .blocked;
        return .{ .dismissed = self.remove(self.records.items.len - 1, trigger_exists) };
    }

    pub fn outside(self: *OverlayHost, x: f32, y: f32, trigger_exists: bool) InputResult {
        const record = self.top() orelse return .unhandled;
        const rect = record.geometry;
        if (x >= rect.x and x < rect.x + rect.width and y >= rect.y and y < rect.y + rect.height) return .unhandled;
        if (!record.dismiss_policy.outside) return .blocked;
        return .{ .dismissed = self.remove(self.records.items.len - 1, trigger_exists) };
    }

    pub fn dismiss(self: *OverlayHost, id: u64, trigger_exists: bool) ?Dismissed {
        for (self.records.items, 0..) |record, index| if (record.id == id) return self.remove(index, trigger_exists);
        return null;
    }

    /// Owner invalidation is exact, including session generation/group revision.
    /// It cannot close an unrelated active tab's authentication or menu layer.
    pub fn invalidateOwner(self: *OverlayHost, owner: identity.CommandOwner) void {
        var index = self.records.items.len;
        while (index > 0) {
            index -= 1;
            if (self.records.items[index].owner.eql(owner)) _ = self.records.orderedRemove(index);
        }
    }

    pub fn ownerChanged(self: *OverlayHost, owner: identity.CommandOwner) void {
        var index = self.records.items.len;
        while (index > 0) {
            index -= 1;
            const record = self.records.items[index];
            if (record.owner != .app and !record.owner.eql(owner) and record.dismiss_policy.owner_change) _ = self.records.orderedRemove(index);
        }
    }

    fn remove(self: *OverlayHost, index: usize, trigger_exists: bool) Dismissed {
        const record = self.records.orderedRemove(index);
        const focus = if (trigger_exists) record.focus_return else FocusTarget{ .content = .{ .window_id = record.window_id, .owner = record.owner } };
        return .{ .overlay_id = record.id, .focus = focus };
    }
};

fn validRect(rect: anchor.Rect) bool {
    return std.math.isFinite(rect.x) and std.math.isFinite(rect.y) and std.math.isFinite(rect.width) and std.math.isFinite(rect.height) and rect.width >= 0 and rect.height >= 0;
}

fn testRecord(owner: identity.CommandOwner) OverlayRecord {
    return .{ .id = 0, .owner = owner, .window_id = @fromBackingInt(1), .trigger = .button, .anchor = .{ .x = 10, .y = 20, .width = 20, .height = 20 }, .geometry = .{ .x = 10, .y = 40, .width = 100, .height = 80 }, .focus_return = .{ .control = .{ .window_id = @fromBackingInt(1), .control_id = 7 } } };
}

test "Escape is consumed by IME then only dismisses the top overlay" {
    var host = OverlayHost.init(std.testing.allocator, @fromBackingInt(1));
    defer host.deinit();
    _ = try host.open(testRecord(.app));
    const top_id = try host.open(testRecord(.{ .session = .{ .session_id = @fromBackingInt(2) } }));
    try std.testing.expectEqual(InputResult.consumed_by_ime, host.escape(true, true));
    try std.testing.expectEqual(@as(usize, 2), host.records.items.len);
    const dismissed = host.escape(false, false).dismissed;
    try std.testing.expectEqual(top_id, dismissed.overlay_id);
    try std.testing.expect(dismissed.focus == .content);
    try std.testing.expectEqual(@as(usize, 1), host.records.items.len);
}

test "overlay geometry and exact owners prevent cross-session dismissal" {
    var host = OverlayHost.init(std.testing.allocator, @fromBackingInt(1));
    defer host.deinit();
    const old_owner: identity.CommandOwner = .{ .session = .{ .session_id = @fromBackingInt(1), .generation = 1 } };
    const current_owner: identity.CommandOwner = .{ .session = .{ .session_id = @fromBackingInt(1), .generation = 2 } };
    _ = try host.open(testRecord(old_owner));
    const current = try host.open(testRecord(current_owner));
    host.invalidateOwner(old_owner);
    try std.testing.expectEqual(current, host.top().?.id);
    try std.testing.expectEqual(InputResult.unhandled, host.outside(20, 50, true));
    var record = testRecord(current_owner);
    record.dismiss_policy.escape = false;
    _ = try host.open(record);
    try std.testing.expectEqual(InputResult.blocked, host.escape(false, true));
    try std.testing.expectEqual(@as(usize, 2), host.records.items.len);
}
