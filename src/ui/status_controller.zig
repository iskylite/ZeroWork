//! Status overlays consume owned snapshots only. They cannot write to a
//! terminal, probe a network, or resolve an action against the active tab.
const std = @import("std");
const identity = @import("../host/identity.zig");
const Snapshot = @import("session_lifecycle.zig").Snapshot;
const geometry = @import("overlay_anchor.zig");

pub const Kind = enum { identity, grid, encoding, rtt, readonly, more, theme };
pub const Projection = struct {
    owner: identity.ContentOwner,
    owner_kind: enum { local, ssh, history },
    source_revision: u64,
    identity_label: []const u8,
    encoding: enum { unknown, utf8 } = .unknown,
    grid: ?struct { cols: u16, rows: u16, revision: u64 } = null,
    read_only: bool = false,
    cwd: ?[]const u8 = null,
    available: bool = true,
    unavailable_reason: ?[]const u8 = null,
    rtt: ?struct { milliseconds: ?u64, reason: ?[]const u8 = null } = null,
    history_available: bool = false,
    export_available: bool = false,
};
pub const Popover = struct {
    kind: Kind,
    owner: identity.ContentOwner,
    source_revision: u64,
    /// Horizontal trigger bounds; y is the status card's top edge (the 26px
    /// trigger is inset 3px and must not shift the specified 6px card gap).
    anchor: geometry.Rect,
    focus_return: u64,
    narrow_more: bool = false,
};
pub const Controller = struct {
    allocator: std.mem.Allocator,
    source: ?Snapshot(Projection) = null,
    popover: ?Popover = null,

    pub fn deinit(self: *Controller) void {
        if (self.source) |*source| source.deinit();
        self.source = null;
        self.popover = null;
    }

    /// A pane switch closes without requesting focus in the old pane. Stale
    /// updates for the currently selected owner do not replace newer data.
    pub fn select(self: *Controller, value: Projection) !bool {
        if (value.source_revision == 0) return error.InvalidRevision;
        if (value.owner_kind == .history and (!value.read_only or value.owner != .history)) return error.InvalidHistory;
        if (value.owner_kind != .history and value.owner != .session) return error.InvalidOwner;
        if (value.owner_kind == .local and value.rtt != null) return error.LocalNetworkCapability;
        if (value.grid) |grid| if (grid.cols == 0 or grid.rows == 0 or grid.revision == 0) return error.InvalidGeometry;
        if (self.source) |old| {
            if (old.value.owner.eql(value.owner) and value.source_revision <= old.value.source_revision) return false;
        }
        const next = try Snapshot(Projection).init(self.allocator, value);
        if (self.popover) |*open| {
            if (!open.owner.eql(value.owner) or !value.available) {
                self.popover = null;
            } else open.source_revision = value.source_revision;
        }
        if (self.source) |*old| old.deinit();
        self.source = next;
        return true;
    }

    pub fn available(self: *const Controller, kind: Kind) bool {
        const value = if (self.source) |source| source.value else return false;
        if (!value.available) return false;
        return switch (kind) {
            .rtt => value.owner_kind == .ssh,
            .readonly => value.owner_kind == .history and value.read_only,
            else => true,
        };
    }

    /// Worker refreshes may update the captured owner, never select a pane.
    pub fn refresh(self: *Controller, value: Projection) !bool {
        const current = if (self.source) |source| source.value else return error.StaleOwner;
        if (!current.owner.eql(value.owner)) return error.StaleOwner;
        return self.select(value);
    }

    /// Returns a stable focus token only for an explicit toggle/close. A caller
    /// must resolve that token in the original pane, never keep a widget pointer.
    pub fn toggle(self: *Controller, kind: Kind, anchor: geometry.Rect, focus_return: u64, narrow: bool) !?u64 {
        if (!self.available(kind)) return error.Unavailable;
        const value = self.source.?.value;
        if (self.popover) |open| if (open.kind == kind and open.owner.eql(value.owner)) return self.close();
        self.popover = .{ .kind = kind, .owner = value.owner, .source_revision = value.source_revision, .anchor = anchor, .focus_return = focus_return, .narrow_more = narrow };
        return null;
    }

    /// Secondary details inherit both owner and focus return from More.
    pub fn detail(self: *Controller, owner: identity.ContentOwner, kind: Kind) !void {
        const open = if (self.popover) |*open| open else return error.NotOpen;
        if (!open.owner.eql(owner)) return error.StaleOwner;
        if (open.kind != .more) return error.NotMore;
        if (kind != .grid and kind != .encoding and kind != .rtt and kind != .theme) return error.InvalidDetail;
        if (!self.available(kind)) return error.Unavailable;
        open.kind = kind;
    }

    pub fn updateAnchor(self: *Controller, owner: identity.ContentOwner, anchor: geometry.Rect) !void {
        const open = if (self.popover) |*open| open else return error.NotOpen;
        if (!open.owner.eql(owner)) return error.StaleOwner;
        open.anchor = anchor;
    }

    pub fn invalidate(self: *Controller, owner: identity.ContentOwner) void {
        if (self.source) |*source| if (source.value.owner.eql(owner)) {
            source.deinit();
            self.source = null;
            self.popover = null;
        };
    }

    pub fn close(self: *Controller) ?u64 {
        const open = self.popover orelse return null;
        self.popover = null;
        return open.focus_return;
    }

    pub fn moreItems(self: *const Controller, output: *[4]Kind, narrow: bool) []const Kind {
        if (self.source == null or !self.source.?.value.available) return output[0..0];
        var count: usize = 0;
        output[count] = .encoding;
        count += 1;
        output[count] = .grid;
        count += 1;
        if (self.available(.rtt)) {
            output[count] = .rtt;
            count += 1;
        }
        if (narrow) {
            output[count] = .theme;
            count += 1;
        }
        return output[0..count];
    }

    /// Shrink only the scrollable body when vertical space is insufficient.
    /// The caller mounts this result in the window portal.
    pub fn placement(self: *const Controller, window: geometry.Size) !geometry.Rect {
        const open = self.popover orelse return error.NotOpen;
        var items: [4]Kind = undefined;
        const desired: f32 = switch (open.kind) {
            .grid, .rtt => 186,
            .encoding => 148,
            .readonly => 184,
            .more => 52 + 32 * @as(f32, @floatFromInt(self.moreItems(&items, open.narrow_more).len)),
            .identity => 156, // Bridge 444:186232, Local identity.
            .theme => 260,
        };
        const height = @min(desired, @max(0, open.anchor.y - 6 - 8));
        const width = @min(@as(f32, 360), @max(0, window.width - 16));
        return .{
            .x = @min(@max(8, open.anchor.x + (open.anchor.width - width) / 2), @max(8, window.width - width - 8)),
            .y = @max(8, open.anchor.y - 6 - height),
            .width = width,
            .height = height,
        };
    }
};

fn localProjection(id: u64, revision: u64) Projection {
    return .{ .owner = .{ .session = .{ .session_id = @fromBackingInt(id) } }, .owner_kind = .local, .source_revision = revision, .identity_label = "本地 · zsh", .encoding = .utf8 };
}
const test_anchor: geometry.Rect = .{ .x = 312, .y = 860, .width = 94, .height = 26 };

test "status details retain owner and close on pane switch without redirecting" {
    var controller: Controller = .{ .allocator = std.testing.allocator };
    defer controller.deinit();
    const first = localProjection(1, 1);
    _ = try controller.select(first);
    _ = try controller.toggle(.more, test_anchor, 41, true);
    var items: [4]Kind = undefined;
    try std.testing.expectEqualSlices(Kind, &.{ .encoding, .grid, .theme }, controller.moreItems(&items, true));
    try std.testing.expectError(error.Unavailable, controller.detail(first.owner, .rtt));
    try controller.detail(first.owner, .grid);
    try std.testing.expectEqual(@as(u64, 41), controller.popover.?.focus_return);
    try std.testing.expect(!try controller.select(first));
    _ = try controller.select(localProjection(2, 1));
    try std.testing.expect(controller.popover == null);
    try std.testing.expect(controller.close() == null);
    try std.testing.expectError(error.NotOpen, controller.detail(first.owner, .grid));
    try std.testing.expectError(error.StaleOwner, controller.refresh(first));
}

test "status owns text and refreshes applied geometry without accepting stale data" {
    var controller: Controller = .{ .allocator = std.testing.allocator };
    defer controller.deinit();
    var cwd = [_]u8{ '/', 'a' };
    var value = localProjection(1, 3);
    value.cwd = &cwd;
    value.grid = .{ .cols = 80, .rows = 24, .revision = 2 };
    _ = try controller.select(value);
    cwd[1] = 'b';
    try std.testing.expectEqualStrings("/a", controller.source.?.value.cwd.?);
    _ = try controller.toggle(.grid, test_anchor, 42, false);
    value.source_revision = 4;
    value.grid = .{ .cols = 100, .rows = 30, .revision = 3 };
    _ = try controller.select(value);
    try std.testing.expectEqual(@as(u16, 100), controller.source.?.value.grid.?.cols);
    try std.testing.expectEqual(@as(u64, 4), controller.popover.?.source_revision);
    value.source_revision = 3;
    try std.testing.expect(!try controller.select(value));
    const placed = try controller.placement(.{ .width = 1440, .height = 900 });
    try std.testing.expectEqual(@as(f32, 668), placed.y);
    try std.testing.expectEqual(@as(f32, 186), placed.height);
    try std.testing.expectEqual(@as(f32, 854), placed.y + placed.height);
    try std.testing.expectEqual(@as(?u64, 42), controller.close());
}

test "status rejects local RTT and writable history and invalidates old focus" {
    var controller: Controller = .{ .allocator = std.testing.allocator };
    defer controller.deinit();
    var value = localProjection(1, 1);
    value.rtt = .{ .milliseconds = 12 };
    try std.testing.expectError(error.LocalNetworkCapability, controller.select(value));
    value.rtt = null;
    _ = try controller.select(value);
    _ = try controller.toggle(.encoding, .{ .x = 800, .y = 170, .width = 26, .height = 26 }, 51, false);
    const placed = try controller.placement(.{ .width = 860, .height = 480 });
    try std.testing.expectEqual(@as(f32, 492), placed.x);
    try std.testing.expectEqual(@as(f32, 16), placed.y);
    try std.testing.expectEqual(@as(f32, 148), placed.height);
    try controller.updateAnchor(value.owner, .{ .x = 800, .y = 154, .width = 26, .height = 26 });
    const constrained = try controller.placement(.{ .width = 860, .height = 480 });
    try std.testing.expectEqual(@as(f32, 8), constrained.y);
    try std.testing.expectEqual(@as(f32, 140), constrained.height);
    try std.testing.expectEqual(@as(f32, 148), constrained.y + constrained.height);
    controller.invalidate(value.owner);
    try std.testing.expect(controller.close() == null);
    value.owner = .{ .history = @fromBackingInt(1) };
    value.owner_kind = .history;
    try std.testing.expectError(error.InvalidHistory, controller.select(value));
    value.read_only = true;
    _ = try controller.select(value);
    try std.testing.expect(controller.available(.readonly));
    try std.testing.expect(!controller.available(.rtt));
}
