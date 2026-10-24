//! Stateless native widget rendering of the frozen group-close ledger.
const std = @import("std");
const ui = @import("ui");
const controller = @import("group_close_controller.zig");
const styles = @import("group_close_styles.zig");
const theme = @import("app_theme.zig");
pub const Props = struct {
    group_name: []const u8,
    plan: *const controller.Plan,
    partial: bool,
    cancel: ui.Handler(void),
    approve: ui.Handler(void),
};
pub fn render(cx: *ui.Cx, scope: *ui.Scope, dialog: *ui.Node, body: *ui.Node, props: Props) !*ui.Node {
    dialog.setStyleInline(cx.allocator, styles.dialog(props.partial));
    body.setStyleInline(cx.allocator, styles.body());
    try label(cx, body, if (props.plan.phase == .closing) "正在关闭组内会话" else if (props.partial) "部分成员尚未关闭" else "关闭组内全部会话？", styles.slot(12, 20), styles.title());
    var buf: [512]u8 = undefined;
    const counts = props.plan.counts();
    const summary = if (props.partial) try std.fmt.bufPrint(&buf, "{s} · 已关闭 {d} · 未关闭 {d} · 待核实 {d}", .{ props.group_name, counts.closed, counts.unclosed, counts.unknown }) else try std.fmt.bufPrint(&buf, "{s} · {d} 个会话", .{ props.group_name, props.plan.approvalCount() });
    try label(cx, body, summary, styles.slot(40, 18), styles.text(false));
    const scroll = try ui.widgets.ScrollArea(.{ .direction = .vertical, .rubber_band_y = false }).mount(scope, cx);
    scroll.container.setStyleInline(cx.allocator, styles.scroll(props.partial));
    scroll.container.meta.ownership.meta.test_id = "groups.close.members";
    scroll.content.setStyleInline(cx.allocator, styles.scrollContent());
    const list = try ui.box(cx, styles.list(), .{});
    for (props.plan.members.items) |*member| {
        var line = std.Io.Writer.Allocating.init(cx.allocator);
        defer line.deinit();
        try line.writer.print("{s}  #{d} · {s}", .{ member.label(), member.id, if (props.partial or !member.eligible or member.state == .closed) stateText(member.state) else "确认关闭" });
        if (!props.partial and member.eligible and member.state == .queued) {
            const impact = member.impact;
            if (impact.detail_len != 0) {
                try line.writer.writeByte('\n');
                try line.writer.writeAll(impact.detailText());
            }
            if (member.risk & 8 != 0) try line.writer.writeAll("\n运行命令将结束");
            if (impact.transfer != 0 or member.risk & 1 != 0) try line.writer.writeAll(" · 传输暂停并保留");
            if (impact.ai != 0 or member.risk & 2 != 0) try line.writer.writeAll(" · 停止 AI");
            if (impact.socks != 0 or member.risk & 4 != 0) try line.writer.writeAll(" · 释放 SOCKS");
            if (impact.unknown != 0 or member.risk & 16 != 0) try line.writer.writeAll(" · 存在待核实资源");
        }
        if (member.remote_effect_unknown) try line.writer.writeAll(" · 远端后果待核实");
        var text_style = styles.text(true);
        if (props.partial) text_style.color = if (member.state == .closed) theme.current().ok else theme.current().warn;
        const row = try ui.text(cx, line.writer.buffered(), text_style);
        row.setStyleInline(cx.allocator, .{ .width = .fill(), .flex_shrink = 0 });
        try list.appendChild(cx.allocator, row);
    }
    try scroll.content.appendChild(cx.allocator, list);
    if (props.partial) {
        try label(cx, scroll.content, "已关闭成员保留结果；只重试尚未关闭的原成员。", .{ .width = .fill(), .flex_shrink = 0 }, styles.note());
    } else {
        try label(cx, scroll.content, "将关闭全部成员，包括它们的独立页签。", styles.notice(), styles.text(true));
        try label(cx, scroll.content, "停止命令、AI 与 SOCKS；传输暂停并保留。", styles.notice(), styles.note());
        try label(cx, scroll.content, "取消不会断开；已关闭的成员不能自动恢复。", .{ .width = .fill(), .flex_shrink = 0 }, styles.note());
    }
    try body.appendChild(cx.allocator, scroll.container);
    const actions = try ui.box(cx, styles.actions(props.partial), .{});
    const cancel = try ui.widgets.Button(.{ .label = if (props.plan.phase == .closing) "停止后续关闭" else if (props.partial) "收起结果" else "取消", .variant = .secondary, .on_click = props.cancel }).mount(scope, cx);
    cancel.setStyleInline(cx.allocator, styles.button(props.partial, false));
    cancel.meta.ownership.meta.test_id = "groups.close.cancel";
    try actions.appendChild(cx.allocator, cancel);
    const approve_label = if (props.partial) "重试未关闭项" else try std.fmt.bufPrint(&buf, "关闭全部 {d} 个会话", .{props.plan.approvalCount()});
    const approve = try ui.widgets.Button(.{ .label = approve_label, .disabled = props.plan.phase == .closing or props.plan.phase == .complete, .variant = @as(ui.widgets.ButtonVariant, if (props.partial) .primary else .danger), .on_click = props.approve }).mount(scope, cx);
    approve.setStyleInline(cx.allocator, styles.button(props.partial, true));
    approve.meta.ownership.meta.test_id = "groups.close.accept";
    try actions.appendChild(cx.allocator, approve);
    try body.appendChild(cx.allocator, actions);
    try @import("compact_overlay_layout.zig").mount(cx, scope, dialog, scroll.container, scroll.content, if (props.partial) 116 else 114, if (props.partial) 132 else 180, actions, 70);
    return cancel;
}
fn label(cx: *ui.Cx, parent: *ui.Node, value: []const u8, box: ui.BoxStyle, text: ui.TextStyle) !void {
    const node = try ui.text(cx, value, text);
    node.setStyleInline(cx.allocator, box);
    try parent.appendChild(cx.allocator, node);
}
pub fn stateText(state: controller.MemberState) []const u8 {
    return switch (state) {
        .queued => "等待关闭",
        .await_confirm => "等待成员确认",
        .closing => "正在关闭",
        .closed => "已关闭",
        .cancelled => "已取消 · 仍存活",
        .failed => "关闭失败 · 可重试",
        .cleanup_unknown => "资源释放待核实",
    };
}
