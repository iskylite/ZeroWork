//! One shell for main and child conversations; consumers append authorized
//! actions to the same header instead of maintaining a second layout.
const ui = @import("ui");
const S = @import("ai_assistant_styles.zig");
const theme = @import("app_theme.zig");
pub const View = struct { grip: *ui.Node, bar: *ui.Node, owner: *ui.Node, owner_pill: *ui.Node };
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
    try bar.appendChild(cx.allocator, try ui.spacer(cx));
    try panel.appendChild(cx.allocator, bar);
    return .{ .grip = grip, .bar = bar, .owner = label, .owner_pill = pill };
}
