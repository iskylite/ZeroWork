const std = @import("std");
const ui = @import("ui");
const binding = @import("../settings_content_view.zig");
const config = @import("../config.zig");
const controls = @import("settings_controls.zig");

pub fn mountContent(cx: *ui.Cx, bound: *binding.Binding) !*ui.Node {
    const page = try controls.Page.create(cx, bound, "settings.notifications");
    const query = bound.controller.search_query;
    if (binding.matches(query, "事件提醒 通知 传输完成 断线 重连 AI 回答 就绪 终端 Bell 声音 transfer_done reconnect ai_ready bell")) {
        const section = try page.section("事件提醒", "后台事件与终端声音", ui.icons.bell, 48, "settings.notifications.events", null);
        try section.toggle(.{ .section = "notify", .key = "transfer_done" }, "传输完成", "", null);
        try section.toggle(.{ .section = "notify", .key = "reconnect" }, "断线与重连", "", null);
        try section.toggle(.{ .section = "notify", .key = "ai_ready" }, "AI 回答就绪", "", null);
        try section.toggle(.{ .section = "notify", .key = "bell" }, "终端 Bell 声音", "", null);
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
