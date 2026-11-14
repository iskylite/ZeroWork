//! A host-authored transcript event. Message ownership and lifecycle stay with
//! the caller; this view only presents the actual host notice text.
const ui = @import("ui");
const theme = @import("app_theme.zig");

pub const takeover_text = "你已接管终端；当前命令继续运行，AI 助手会继续本轮，需要输入时会重新申请权限。";

pub fn mountResumedHistory(cx: *ui.Cx, parent: *ui.Node) !void {
    const card = try ui.boxStyled(cx, resumedHistoryCard, .{});
    card.meta.ownership.meta.test_id = "ai.history.resumed";
    const tile = try ui.boxStyled(cx, resumedHistoryIconTile, .{});
    const icon = try theme.icon(cx, ui.icons.get("history").?, "accent_ink", .{ .width = .{ .px = 24 }, .height = .{ .px = 24 }, .flex_shrink = 0 });
    icon.meta.ownership.meta.test_id = "ai.history.resumed.icon";
    try tile.appendChild(cx.allocator, icon);
    try card.appendChild(cx.allocator, tile);
    const copy = try ui.box(cx, .{ .width = .fill(), .height = .{ .fit = .{} }, .min_width = 0, .direction = .column, .gap = 2 }, .{});
    const title = try ui.textStyled(cx, resumedHistoryTitle, "以上是旧会话记录");
    title.setStyleInline(cx.allocator, .{ .width = .fill(), .min_width = 0 });
    try copy.appendChild(cx.allocator, title);
    const detail = try ui.textStyled(cx, bodyStyle, "后续操作以当前连接为准。");
    detail.setStyleInline(cx.allocator, .{ .width = .fill(), .min_width = 0 });
    try copy.appendChild(cx.allocator, detail);
    try card.appendChild(cx.allocator, copy);
    try parent.appendChild(cx.allocator, card);
}

fn resumedHistoryCard(_: *const ui.ThemeTokens) ui.BoxStyle {
    const surface = theme.popupInset();
    const accent = theme.current().accent_ink;
    return .{
        .width = .fill(),
        .height = .{ .fit = .{} },
        .min_width = 0,
        .direction = .row,
        .align_items = .center,
        .gap = 12,
        .margin = .{ .top = 4, .bottom = 4 },
        .padding = ui.Padding.all(12),
        .background = ui.Color.lerp(surface, accent, 0.08),
        .border = .{ .width = 1, .radius = 10, .color = ui.Color.lerp(surface, accent, 0.32) },
        .flex_shrink = 0,
    };
}

fn resumedHistoryIconTile(_: *const ui.ThemeTokens) ui.BoxStyle {
    return .{
        .width = .{ .px = 40 },
        .height = .{ .px = 40 },
        .align_items = .center,
        .justify = .center,
        .background = ui.Color.lerp(theme.popupInset(), theme.current().accent_ink, 0.21),
        .border = .{ .radius = 9 },
        .flex_shrink = 0,
    };
}

fn resumedHistoryTitle(_: *const ui.ThemeTokens) ui.TextStyle {
    return .{ .font_size = 14, .font_weight = 650, .line_height = 20.0 / 14.0, .color = theme.current().fg_1, .wrap = .word };
}

pub fn mount(cx: *ui.Cx, parent: *ui.Node, text: []const u8) !*ui.Node {
    const root = try ui.boxStyled(cx, noticeStyle, .{});
    root.meta.ownership.meta.test_id = "ai.host_notice";
    try parent.appendChild(cx.allocator, root);
    const header = try ui.boxStyled(cx, headerStyle, .{});
    header.meta.ownership.meta.test_id = "ai.host_notice.header";
    try root.appendChild(cx.allocator, header);
    const icon = try theme.icon(cx, ui.icons.log_out, "accent_ink", .{ .width = .{ .px = 16 }, .height = .{ .px = 16 }, .flex_shrink = 0 });
    icon.meta.ownership.meta.test_id = "ai.host_notice.icon";
    try header.appendChild(cx.allocator, icon);
    const title = try ui.textStyled(cx, titleStyle, "外部消息");
    title.setStyleInline(cx.allocator, .{ .width = .{ .fit = .{} }, .height = .{ .px = 20 }, .flex_shrink = 0 });
    title.meta.ownership.meta.test_id = "ai.host_notice.title";
    try header.appendChild(cx.allocator, title);
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
fn bodyStyle(_: *const ui.ThemeTokens) ui.TextStyle {
    return .{ .font_size = 12, .line_height = 18.0 / 12.0, .color = theme.current().fg_2, .wrap = .word };
}
