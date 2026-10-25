const std = @import("std");
const ui = @import("ui");
const binding = @import("../settings_content_view.zig");
const config = @import("../config.zig");
const controls = @import("settings_controls.zig");

pub fn mountContent(cx: *ui.Cx, bound: *binding.Binding) !*ui.Node {
    const page = try controls.Page.create(cx, bound, "settings.transfer");
    const query = bound.controller.search_query;
    if (binding.matches(query, "连接隔离 独立传输连接 共享通道限速 dedicated_connection shared_pacing_kbps")) {
        const section = try page.section("连接隔离", "独立传输与共享通道限速", ui.icons.network, 16, "settings.transfer.connection", connectionSummary);
        try section.toggle(.{ .section = "transfer", .key = "dedicated_connection" }, "独立传输连接", "使用独立连接传输文件，减少对终端的影响。", null);
        try section.input(.{ .section = "transfer", .key = "shared_pacing_kbps" }, "共享通道限速（KB/s）", "0 表示不限速；用于新任务的共享通道。", null);
    }
    if (binding.matches(query, "SFTP 引擎 滑动窗口 块大小 断点续传 MD5 完成校验 最大并发任务 window_chunks chunk_kb resume verify_md5 max_tasks")) {
        const section = try page.section("SFTP 引擎", "窗口、分块与并发", ui.icons.server, 17, "settings.transfer.engine", engineSummary);
        try section.input(.{ .section = "transfer", .key = "window_chunks" }, "窗口分块数（块）", "", null);
        try section.input(.{ .section = "transfer", .key = "chunk_kb" }, "分块大小（KiB）", "", null);
        try section.input(.{ .section = "transfer", .key = "max_tasks" }, "最大并发任务（个）", "", null);
        try section.toggle(.{ .section = "transfer", .key = "resume" }, "断点续传", "", null);
        try section.toggle(.{ .section = "transfer", .key = "verify_md5" }, "MD5 完成校验", "", null);
    }
    if (binding.matches(query, "默认行为 默认下载目录 同名 重命名 冲突 每次询问 download_dir conflict_policy")) {
        const section = try page.section("默认行为", "下载目录与同名文件处理", ui.icons.folder, 18, "settings.transfer.defaults", null);
        try section.directory(.{ .section = "transfer", .key = "download_dir" }, "默认下载目录");
        try section.select(.{ .section = "transfer", .key = "conflict_policy" }, "同名文件处理", "覆盖、跳过或保留两者由每次冲突确认决定。", &[_]ui.widgets.SelectOption{.{ .value = "ask", .label = "每次询问" }}, null);
    }
    return page.finish();
}
fn connectionSummary(value: config.Config, buffer: []u8) ![]const u8 {
    const connection = if (value.transfer.dedicated_connection) "独立传输连接" else "共享终端连接";
    if (value.transfer.shared_pacing_kbps == 0) return std.fmt.bufPrint(buffer, "{s} · 共享通道不限速", .{connection});
    return std.fmt.bufPrint(buffer, "{s} · 共享通道 {d} KB/s", .{ connection, value.transfer.shared_pacing_kbps });
}
fn engineSummary(value: config.Config, buffer: []u8) ![]const u8 {
    return std.fmt.bufPrint(buffer, "{d} × {d} KiB · {d} 并发", .{ value.transfer.window_chunks, value.transfer.chunk_kb, value.transfer.max_tasks });
}
