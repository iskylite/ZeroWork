const std = @import("std");
const ui = @import("ui");
const binding = @import("../settings_content_view.zig");
const config = @import("../config.zig");
const controls = @import("settings_controls.zig");

pub fn mountContent(cx: *ui.Cx, bound: *binding.Binding) !*ui.Node {
    const page = try controls.Page.create(cx, bound, "settings.notifications");
    const query = bound.controller.search_query;
    if (binding.matches(query, "事件提醒 通知 传输完成 断线 重连 AI 助手 回合 结束 终端 Bell 声音 transfer_done reconnect ai_ready bell")) {
        const section = try page.section("事件提醒", "后台事件与终端声音", ui.icons.bell, 48, "settings.notifications.events", null);
        try section.toggle(.{ .section = "notify", .key = "transfer_done" }, "后台传输完成", "仅离开应用时提醒；已有保存值继续生效。", null);
        try section.toggle(.{ .section = "notify", .key = "reconnect" }, "持续连接故障", "断线后自动重连停止并影响工作时提醒。", null);
        try section.toggle(.{ .section = "notify", .key = "ai_ready" }, "后台 AI 任务完成", "默认关闭；仅最终答复完成且离开应用时提醒。", null);
        try section.toggle(.{ .section = "notify", .key = "bell" }, "终端 Bell 声音", "", null);
        const permission_panel = try ui.box(cx, .{ .width = .fill(), .direction = .column, .padding = .{ .left = 10, .right = 10, .bottom = 8 }, .margin = .{ .top = 8, .bottom = 8 }, .background = controls.S.theme.current().well, .border = .{ .radius = 8 } }, .{});
        const row = try ui.boxStyled(cx, controls.S.fieldRow, .{});
        row.meta.ownership.meta.test_id = "settings.notifications.permission";
        const labels = try ui.boxStyled(cx, controls.S.fieldLabel, .{});
        try labels.appendChild(cx.allocator, try ui.textStyled(cx, controls.S.label, "系统通知权限"));
        const help = if (bound.hooks.authorization_help) |read| read(bound.hooks.context) else "当前无法使用系统通知。";
        const status = permissionStatus(help);
        const status_row = try ui.box(cx, .{ .direction = .row, .align_items = .center, .gap = 4 }, .{});
        try status_row.appendChild(cx.allocator, try ui.textStyled(cx, controls.S.note, status));
        try status_row.appendChild(cx.allocator, try controls.inlineHint(cx, bound, "settings.notifications.permission.info", help, ui.icons.info, controls.S.theme.current().fg_2));
        labels.setStyleInline(cx.allocator, .{ .direction = .row, .align_items = .center, .gap = 8 });
        try labels.appendChild(cx.allocator, status_row);
        try row.appendChild(cx.allocator, labels);
        const tip = try ui.widgets.Tooltip(.{ .text = "当前版本尚未提供测试通知", .open_delay_ms = 450 }).mount(bound.scope, cx);
        const button = try ui.widgets.Button(.{ .label = "测试通知", .disabled = true, .a11y_label = "当前版本尚未提供测试通知", .variant = .secondary, .base_style = controls.S.actionControl(false) }).mount(bound.scope, cx);
        button.meta.ownership.meta.test_id = "settings.notifications.test";
        try tip.trigger.appendChild(cx.allocator, button);
        try row.appendChild(cx.allocator, tip.wrapper);
        try permission_panel.appendChild(cx.allocator, row);
        try section.body.appendChild(cx.allocator, permission_panel);
    }
    if (binding.matches(query, "注意标记 勿扰 非活跃 标签 圆点 时段 tab_dot quiet_hours")) {
        const section = try page.section("注意标记与勿扰", "标签圆点与勿扰时段", ui.icons.moon, 49, "settings.notifications.attention", null);
        try section.toggle(.{ .section = "notify", .key = "tab_dot" }, "非活跃标签圆点", "", null);
        try section.input(.{ .section = "notify", .key = "quiet_hours" }, "勿扰时段", "24 小时制，如 22:00-08:00；留空关闭勿扰，不影响后台任务。", null);
    }
    return page.finish();
}
fn quietSummary(value: config.Config, buffer: []u8) ![]const u8 {
    const time = value.notify.quiet_hours;
    if (time.len != 11) return time;
    return std.fmt.bufPrint(buffer, "{s}–{s}", .{ time[0..5], time[6..11] });
}

fn permissionStatus(help: []const u8) []const u8 {
    if (std.mem.indexOf(u8, help, "均关闭") != null) return "系统显示已关闭";
    if (std.mem.indexOf(u8, help, "已被拒绝") != null) return "已拒绝";
    if (std.mem.indexOf(u8, help, "临时授权") != null) return "临时授权";
    if (std.mem.indexOf(u8, help, "已获授权") != null) return "已允许";
    if (std.mem.indexOf(u8, help, "尚未授权") != null) return "未授权";
    if (std.mem.indexOf(u8, help, "正在查询") != null) return "查询中…";
    return "不可用";
}
