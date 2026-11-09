//! Shared visual state for automatically closing notification cards.
//! The owning presenter keeps the timer and its interaction policy.
const std = @import("std");
const ui = @import("ui");
const S = @import("notification_styles.zig");
const theme = @import("app_theme.zig");

pub const View = struct {
    root: *ui.Node,
    icon: *ui.Node,
    label: *ui.Node,

    pub fn mount(cx: *ui.Cx, parent: *ui.Node, test_id: []const u8) !View {
        const root = try ui.boxStyled(cx, S.countdown, .{});
        const icon = try ui.iconTint(cx, ui.icons.clock, theme.current().fg_2, S.closeIcon());
        try root.appendChild(cx.allocator, icon);
        const label = try ui.textStyled(cx, S.countdownText, "");
        label.meta.ownership.meta.test_id = test_id;
        label.setStyleInline(cx.allocator, .{ .height = .{ .px = 18 }, .flex_shrink = 0 });
        try root.appendChild(cx.allocator, label);
        try parent.appendChild(cx.allocator, root);
        return .{ .root = root, .icon = icon, .label = label };
    }

    pub fn update(self: View, cx: *ui.Cx, remaining_ms: u64, paused: bool) !void {
        self.root.setDisplay(if (paused) .none else .flex);
        if (paused) return;
        var buffer: [64]u8 = undefined;
        const text = try std.fmt.bufPrint(&buffer, "{d} 秒后关闭", .{remaining_ms / 1000 + @intFromBool(remaining_ms % 1000 != 0)});
        if (!std.mem.eql(u8, self.label.getText().?.content, text)) try self.label.setTextContent(cx.allocator, text);
        self.retheme();
    }

    pub fn retheme(self: View) void {
        if (!ui.Color.eql(self.label.getText().?.color, theme.current().fg_2)) self.label.setTextColor(theme.current().fg_2);
        if (self.icon.getIcon()) |icon| if (!ui.Color.eql(icon.tint, theme.current().fg_2)) {
            _ = self.icon.setTint(theme.current().fg_2);
        };
    }
};
