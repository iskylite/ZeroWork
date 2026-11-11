//! One shell for main and child conversations; consumers append authorized
//! actions to the same header instead of maintaining a second layout.
const ui = @import("ui");
const std = @import("std");
const S = @import("ai_assistant_styles.zig");
const theme = @import("app_theme.zig");
pub const View = struct { grip: *ui.Node, bar: *ui.Node, owner: *ui.Node, owner_pill: *ui.Node, spacer: *ui.Node };
pub fn mountCountBadge(cx: *ui.Cx, button: *ui.Node, test_id: []const u8) !*ui.Node {
    button.setStyleInline(cx.allocator, .{ .position = .relative });
    const badge = try ui.textStyled(cx, S.countBadgeText, "");
    badge.setStyleInline(cx.allocator, S.countBadge(cx.tokens));
    badge.meta.ownership.meta.test_id = test_id;
    badge.setDisplay(.none);
    badge.setHitTestVisible(false);
    try button.appendChild(cx.allocator, badge);
    return badge;
}
pub fn updateCountBadge(cx: *ui.Cx, badge: *ui.Node, count: usize) !void {
    var buffer: [32]u8 = undefined;
    const number = try std.fmt.bufPrint(&buffer, "{d}", .{count});
    if (!std.mem.eql(u8, badge.getText().?.content, number)) try badge.setTextContent(cx.allocator, number);
    badge.setDisplay(if (count == 0) .none else .flex);
}
pub fn repaintCountBadge(cx: *ui.Cx, badge: *ui.Node) void {
    badge.setStyleInline(cx.allocator, S.countBadge(cx.tokens));
    badge.setTextColor(theme.current().accent_ink);
}
pub fn mount(cx: *ui.Cx, panel: *ui.Node, owner: []const u8) !View {
    const grip = try ui.boxStyled(cx, S.gripRow, .{});
    try grip.appendChild(cx.allocator, try ui.boxStyled(cx, S.grip, .{}));
    try panel.appendChild(cx.allocator, grip);
    const bar = try ui.boxStyled(cx, S.header, .{});
    try bar.appendChild(cx.allocator, try ui.iconTint(cx, ui.icons.sparkles, theme.current().accent, S.regionIcon()));
    try bar.appendChild(cx.allocator, try ui.textStyled(cx, S.title, "AI 助手"));
    const label = try ui.textStyled(cx, S.ownerText, owner);
    label.setStyleInline(cx.allocator, .{ .max_width = 144, .min_width = 0 });
    const pill = try ui.boxStyled(cx, S.ownerPill, .{});
    pill.meta.ownership.meta.test_id = "ai.owner";
    try pill.appendChild(cx.allocator, label);
    try bar.appendChild(cx.allocator, pill);
    const spacer = try ui.spacer(cx);
    try bar.appendChild(cx.allocator, spacer);
    try panel.appendChild(cx.allocator, bar);
    return .{ .grip = grip, .bar = bar, .owner = label, .owner_pill = pill, .spacer = spacer };
}
