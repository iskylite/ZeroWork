const std = @import("std");
const ui = @import("ui");
pub const sizing = @import("group_layout.zig");
pub const Layout = sizing.Layout;
pub const Member = @import("group_close_controller.zig").Member;
pub const ClosePhase = @import("group_close_controller.zig").ClosePhase;
pub const ClosePlan = @import("group_close_controller.zig").Plan;
pub const Pane = struct { session: u64, node: *ui.Node };
pub const View = struct {
    id: u32,
    layout: Layout = .side_by_side,
    root: ?*ui.Node = null,
    scope: ?*ui.Scope = null,
    dirty: bool = true,
    panes: std.ArrayList(Pane) = .empty,
    drag_source: ?u64 = null,
    drag_target: ?u64 = null,
    focused: ?u64 = null,
    tree: sizing.Tree = .{},
    saved_layout: ?sizing.Snapshot = null,
    pending_placement: ?struct { source: u64, session: u64, axis: Layout } = null,
    layout_loaded: bool = false,
    resizing: bool = false,
    persist_pending: bool = false,
    drop_marker: ?*ui.Node = null,
    presented_pin: ?u64 = null,
    drop_edge: sizing.Edge = .right,
    state_hash: u64 = 0,
    close: ?ClosePlan = null,
    dialog: ?*ui.Node = null,
    dialog_scope: ?*ui.Scope = null,
    dialog_open: ?*ui.Signal(bool) = null,
    pub fn deinit(self: *View, allocator: std.mem.Allocator) void {
        if (self.close) |*plan| plan.members.deinit(allocator);
        self.panes.deinit(allocator);
        self.tree.deinit(allocator);
        if (self.saved_layout) |snapshot| allocator.free(snapshot.nodes);
    }
};
