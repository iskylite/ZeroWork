const std = @import("std");
const ui = @import("ui");
const binding = @import("../settings_content_view.zig");
const config = @import("../config.zig");
const controls = @import("settings_controls.zig");

pub fn mountContent(cx: *ui.Cx, bound: *binding.Binding) !*ui.Node {
    const page = try controls.Page.create(cx, bound, "settings.data");
    const query = bound.controller.search_query;
    if (binding.matches(query, "位置 凭据 本地 配置目录 缓存 诊断 钥匙串 600 config_dir cache_dir logs_dir")) {
        const section = try page.section("位置与凭据", "本地存储 · macOS 钥匙串", ui.icons.folder, 56, "settings.data.location", null);
        if (bound.hooks.read) |read| {
            if (read(bound.hooks.context, .{ .section = "data", .key = "config_path" })) |value| try section.readonly("配置文件", value.text);
            if (read(bound.hooks.context, .{ .section = "data", .key = "hosts_path" })) |value| try section.readonly("主机配置", value.text);
        }
        try section.readonly("缓存目录", readPath(bound, "cache_dir"));
        try section.readonly("诊断日志目录", readPath(bound, "logs_dir"));
        try section.readonly("密码与 API Key", "存储于 macOS 钥匙串");
        try section.iconAction("凭据访问状态", "检查凭据状态", ui.icons.lock, "settings.data.credential_help", .credential_help);
        try section.readonly("配置文件权限", "仅当前用户可读写 · 600");
    }
    if (binding.matches(query, "会话记录 日志 缓冲 上限 快照 间隔 保留 天数 导出格式 ring_mb checkpoint_sec retention_days export_format")) {
        const section = try page.section("会话记录", "缓冲、快照与保留策略", ui.icons.database, 57, "settings.data.history", null);
        try section.input(.{ .section = "log", .key = "ring_mb" }, "每会话缓冲上限（MiB）", "", null);
        try section.input(.{ .section = "log", .key = "checkpoint_sec" }, "快照间隔（秒）", "", null);
        try section.input(.{ .section = "log", .key = "retention_days" }, "保留天数", "", null);
        try section.select(.{ .section = "log", .key = "export_format" }, "会话导出格式", "", &[_]ui.widgets.SelectOption{ .{ .value = "txt_cast", .label = ".txt + .cast" }, .{ .value = "txt", .label = ".txt" }, .{ .value = "cast", .label = ".cast" } }, null);
    }
    if (binding.matches(query, "导出 清理 清空 清除 全部 应用 数据 删除 会话 诊断 日志 export clear")) {
        const section = try page.section("导出与清理", "导出诊断信息与清理应用数据", ui.icons.file_text, 58, "settings.data.actions", null);
        try section.iconAction("应用诊断日志", "导出日志…", ui.icons.upload, "settings.data.export_logs", .export_logs);
        try section.iconAction("已结束会话记录", "清理记录…", ui.icons.trash_2, "settings.data.clear_logs", .clear_logs);
        try section.iconAction("全部应用数据", "清除全部数据…", ui.icons.triangle_alert, "settings.data.clear_all", .clear_all);
    }
    return page.finish();
}
fn historySummary(value: config.Config, buffer: []u8) ![]const u8 {
    return std.fmt.bufPrint(buffer, "缓冲 {d} MiB · 每 {d} 秒快照 · 保留 {d} 天", .{ value.log.ring_mb, value.log.checkpoint_sec, value.log.retention_days });
}

fn readPath(bound: *binding.Binding, key: []const u8) []const u8 {
    if (bound.hooks.read) |read| if (read(bound.hooks.context, .{ .section = "data", .key = key })) |value| return value.text;
    return "由应用管理";
}
