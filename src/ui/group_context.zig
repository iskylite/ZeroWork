const std = @import("std");
const Group = @import("group_model.zig").Group;
const Anchor = @import("overlay_anchor.zig").Anchor;

pub const Context = struct {
    group: Group,
    pinned: bool = false,
    anchor: Anchor = .pane_top_center,

    pub fn effectiveAnchor(self: Context) Anchor {
        return if (self.pinned) .status_chip else self.anchor;
    }
};

test "pinned group uses status chip anchor priority" {
    const group: Group = .{ .id = 1, .name = "Production" };
    try std.testing.expectEqual(Anchor.pane_center, (Context{ .group = group, .anchor = .pane_center }).effectiveAnchor());
    try std.testing.expectEqual(Anchor.status_chip, (Context{ .group = group, .pinned = true, .anchor = .pane_center }).effectiveAnchor());
}
