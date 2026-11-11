//! Manual context compaction is transcript activity, separate from model messages.
const std = @import("std");
const ui = @import("ui");
const theme = @import("app_theme.zig");
const S = @import("ai_tool_results_styles.zig");
const Recovery = @import("ai_recovery_styles.zig");
const Activity = @import("../ai/assistant_store.zig").CompactionActivity;

pub fn append(cx: *ui.Cx, scope: *ui.Scope, parent: *ui.Node, activity: Activity, on_cancel: ui.HandlerRef) !void {
    const label: []const u8 = switch (activity.status) {
        .idle => return,
        .running => "正在压缩上下文…",
        .succeeded => "上下文已压缩",
        .failed => "上下文压缩失败",
        .cancelled => "已取消上下文压缩",
    };
    const card = try ui.boxStyled(cx, S.card, .{});
    card.meta.ownership.meta.test_id = "ai.transcript.compaction";
    try parent.appendChild(cx.allocator, card);
    const row = try ui.boxStyled(cx, S.header, .{});
    try card.appendChild(cx.allocator, row);
    const colors = theme.current();
    const icon = switch (activity.status) {
        .idle => unreachable,
        .running => try ui.widgets.Spinner(.{ .size = 14, .stroke_width = 2, .color = colors.accent }).mount(scope, cx),
        .succeeded => try ui.iconTint(cx, ui.icons.check, colors.ok_ink, Recovery.icon()),
        .failed => try ui.iconTint(cx, ui.icons.get("circle-alert").?, colors.danger_ink, Recovery.icon()),
        .cancelled => try ui.iconTint(cx, ui.icons.x, colors.fg_2, Recovery.icon()),
    };
    try row.appendChild(cx.allocator, icon);
    const title = try ui.textStyled(cx, Recovery.title, label);
    title.setStyleInline(cx.allocator, .{ .flex_shrink = 0 });
    try row.appendChild(cx.allocator, title);
    if (activity.status == .running) {
        try row.appendChild(cx.allocator, try ui.spacer(cx));
        const cancel = try ui.widgets.Button(.{ .label = "取消", .a11y_label = "取消压缩", .variant = .ghost, .base_style = Recovery.action(false, false, true), .on_click = on_cancel }).mount(scope, cx);
        cancel.meta.ownership.meta.test_id = "ai.transcript.compaction.cancel";
        try row.appendChild(cx.allocator, cancel);
    } else if (activity.status == .succeeded) {
        var buffer: [128]u8 = undefined;
        const detail = try std.fmt.bufPrint(&buffer, "历史输入约 {d} → {d} tokens", .{ activity.before_tokens, activity.after_tokens });
        try row.appendChild(cx.allocator, try ui.textStyled(cx, Recovery.summary, detail));
    }
}
