//! A host-authored transcript event. Message ownership and lifecycle stay with
//! the caller; this view only presents the actual host notice text.
const ui = @import("ui");
const theme = @import("app_theme.zig");

pub const takeover_text = "你已接管终端；当前命令继续运行，AI 助手会继续本轮，需要输入时会重新申请权限。";

pub fn mount(cx: *ui.Cx, parent: *ui.Node, text: []const u8) !*ui.Node {
    const root = try ui.boxStyled(cx, noticeStyle, .{});
    root.meta.ownership.meta.test_id = "ai.host_notice";
    try parent.appendChild(cx.allocator, root);
    const header = try ui.boxStyled(cx, headerStyle, .{});
    header.meta.ownership.meta.test_id = "ai.host_notice.header";
    try root.appendChild(cx.allocator, header);
    const icon = try ui.iconTint(cx, ui.icons.log_out, theme.current().accent_ink, .{ .width = .{ .px = 16 }, .height = .{ .px = 16 }, .flex_shrink = 0 });
    icon.meta.ownership.meta.test_id = "ai.host_notice.icon";
    try header.appendChild(cx.allocator, icon);
    const title = try ui.textStyled(cx, titleStyle, "外部消息");
    title.setStyleInline(cx.allocator, .{ .width = .{ .fit = .{} }, .height = .{ .px = 20 }, .flex_shrink = 0 });
    title.meta.ownership.meta.test_id = "ai.host_notice.title";
    try header.appendChild(cx.allocator, title);
    try header.appendChild(cx.allocator, try ui.textStyled(cx, sourceStyle, "宿主更新"));
    const body = try ui.textStyled(cx, bodyStyle, text);
    body.setStyleInline(cx.allocator, .{ .width = .fill(), .height = .{ .fit = .{} }, .min_width = 0, .margin = .{ .left = 22 }, .flex_shrink = 0 });
    body.meta.ownership.meta.test_id = "ai.host_notice.body";
    try root.appendChild(cx.allocator, body);
    return root;
}
fn noticeStyle(_: *const ui.ThemeTokens) ui.BoxStyle {
    return .{ .width = .fill(), .height = .{ .fit = .{} }, .min_width = 0, .direction = .column, .gap = 4, .padding = .{ .left = 2, .right = 2, .top = 6, .bottom = 6 }, .flex_shrink = 0 };
}
fn headerStyle(_: *const ui.ThemeTokens) ui.BoxStyle {
    return .{ .width = .fill(), .height = .{ .px = 20 }, .direction = .row, .align_items = .center, .gap = 6, .flex_shrink = 0 };
}
fn titleStyle(_: *const ui.ThemeTokens) ui.TextStyle {
    return .{ .font_size = 13, .font_weight = 700, .line_height = 20.0 / 13.0, .color = theme.current().accent_ink };
}
fn sourceStyle(_: *const ui.ThemeTokens) ui.TextStyle {
    return .{ .font_size = 11, .line_height = 16.0 / 11.0, .color = theme.current().fg_2 };
}
fn bodyStyle(_: *const ui.ThemeTokens) ui.TextStyle {
    return .{ .font_size = 12, .line_height = 18.0 / 12.0, .color = theme.current().fg_2, .wrap = .word };
}
