const std = @import("std");

pub const Page = struct { name: []const u8, config_section: []const u8, description: []const u8 };
pub const ConfigKey = struct { page: []const u8, section: []const u8, key: []const u8 };
pub const keys = [_]ConfigKey{
    .{ .page = "外观与主题", .section = "ui", .key = "icon_background" },
    .{ .page = "外观与主题", .section = "ui", .key = "theme" },
    .{ .page = "外观与主题", .section = "ui", .key = "font_family" },
    .{ .page = "外观与主题", .section = "ui", .key = "font_size" },
    .{ .page = "外观与主题", .section = "ui", .key = "font_weight" },
    .{ .page = "外观与主题", .section = "ui", .key = "line_height" },
    .{ .page = "外观与主题", .section = "ui", .key = "cursor_style" },
    .{ .page = "外观与主题", .section = "ui", .key = "sidebar_collapsed" },
    .{ .page = "外观与主题", .section = "ui", .key = "input_line_highlight" },
    .{ .page = "外观与主题", .section = "ui", .key = "timestamp_gutter" },
    .{ .page = "SSH 与网络", .section = "ssh", .key = "keepalive_sec" },
    .{ .page = "SSH 与网络", .section = "ssh", .key = "reconnect_max" },
    .{ .page = "SSH 与网络", .section = "ssh", .key = "reconnect_backoff" },
    .{ .page = "文件传输", .section = "transfer", .key = "dedicated_connection" },
    .{ .page = "文件传输", .section = "transfer", .key = "window_chunks" },
    .{ .page = "文件传输", .section = "transfer", .key = "chunk_kb" },
    .{ .page = "文件传输", .section = "transfer", .key = "download_dir" },
    .{ .page = "文件传输", .section = "transfer", .key = "verify_md5" },
    .{ .page = "文件传输", .section = "transfer", .key = "shared_pacing_kbps" },
    .{ .page = "AI 辅助", .section = "ai", .key = "default_provider" },
    .{ .page = "AI 辅助", .section = "ai", .key = "permission_mode" },
    .{ .page = "AI 辅助", .section = "ai", .key = "redact_ip" },
    .{ .page = "AI 辅助", .section = "ai", .key = "error_hint" },
    .{ .page = "数据与日志", .section = "log", .key = "ring_mb" },
    .{ .page = "数据与日志", .section = "log", .key = "checkpoint_sec" },
    .{ .page = "SSH 与网络", .section = "ssh", .key = "connect_timeout_sec" },
    .{ .page = "SSH 与网络", .section = "ssh", .key = "term" },
    .{ .page = "SSH 与网络", .section = "ssh", .key = "compression" },
    .{ .page = "SSH 与网络", .section = "ssh", .key = "auto_reconnect" },
    .{ .page = "SSH 与网络", .section = "ssh", .key = "buffer_input" },
    .{ .page = "SSH 与网络", .section = "ssh", .key = "socks_port" },
    .{ .page = "SSH 与网络", .section = "ssh", .key = "socks_bind" },
    .{ .page = "SSH 与网络", .section = "ssh", .key = "otp_modal" },
    .{ .page = "SSH 与网络", .section = "ssh", .key = "totp_autofill" },
    .{ .page = "文件传输", .section = "transfer", .key = "resume" },
    .{ .page = "文件传输", .section = "transfer", .key = "max_tasks" },
    .{ .page = "文件传输", .section = "transfer", .key = "conflict_policy" },
    .{ .page = "通知", .section = "notify", .key = "transfer_done" },
    .{ .page = "通知", .section = "notify", .key = "reconnect" },
    .{ .page = "通知", .section = "notify", .key = "ai_ready" },
    .{ .page = "通知", .section = "notify", .key = "bell" },
    .{ .page = "通知", .section = "notify", .key = "tab_dot" },
    .{ .page = "通知", .section = "notify", .key = "quiet_hours" },
    .{ .page = "数据与日志", .section = "log", .key = "retention_days" },
    .{ .page = "数据与日志", .section = "log", .key = "export_format" },
    .{ .page = "外观与主题", .section = "completion", .key = "enabled" },
    .{ .page = "外观与主题", .section = "ui.materials", .key = "blur_px" },
    .{ .page = "外观与主题", .section = "ui.materials.background", .key = "enabled" },
    .{ .page = "外观与主题", .section = "ui.materials.background", .key = "path" },
    .{ .page = "外观与主题", .section = "ui.materials.background", .key = "fit" },
    .{ .page = "外观与主题", .section = "ui.materials.background", .key = "alignment_x" },
    .{ .page = "外观与主题", .section = "ui.materials.background", .key = "alignment_y" },
    .{ .page = "外观与主题", .section = "ui.materials.background", .key = "transparency" },
    .{ .page = "外观与主题", .section = "ui", .key = "scrollback_limit" },
    .{ .page = "AI 辅助", .section = "ai", .key = "execution_mode" },
    .{ .page = "AI 辅助", .section = "ai", .key = "session_retention" },
};
pub const sections = [_][]const u8{ "ui", "ui.materials", "ui.materials.background", "completion", "transfer", "ssh", "ai", "log", "notify" };

pub fn keyExists(section: []const u8, key: []const u8) bool {
    for (keys) |entry| if (std.mem.eql(u8, entry.section, section) and std.mem.eql(u8, entry.key, key)) return true;
    return false;
}

pub fn sectionExists(section: []const u8) bool {
    for (sections) |candidate| if (std.mem.eql(u8, candidate, section)) return true;
    return false;
}

pub fn formatPages(buffer: []u8) ![]const u8 {
    var writer = std.Io.Writer.fixed(buffer);
    for (pages, 0..) |page, index| {
        if (index != 0) try writer.writeByte('\n');
        try writer.print("{s} [{s}] — {s}", .{ page.name, page.config_section, page.description });
    }
    return writer.buffered();
}

pub const pages = [_]Page{
    .{ .name = "外观与主题", .config_section = "ui", .description = "主题、背景与显示设置在保存后全局生效" },
    .{ .name = "快捷键", .config_section = "ui", .description = "逐项录制应用快捷键；Tab 与 Control 保留给远端" },
    .{ .name = "SSH 与网络", .config_section = "ssh", .description = "连接、重连与认证默认值；保存后用于后续连接" },
    .{ .name = "文件传输", .config_section = "transfer", .description = "连接隔离、传输引擎与下载默认值；运行任务保留原设置" },
    .{ .name = "AI 辅助", .config_section = "ai", .description = "配置服务提供方、模型与权限；助手始终作用于原会话。" },
    .{ .name = "协议插件", .config_section = "plugins", .description = "查看内置协议服务" },
    .{ .name = "通知", .config_section = "notify", .description = "事件通知、标签提醒与勿扰时段" },
    .{ .name = "数据与日志", .config_section = "log", .description = "本地配置、会话记录、日志导出与清理" },
};

test "settings page map covers eight documented pages" {
    try std.testing.expectEqual(@as(usize, 8), pages.len);
    try std.testing.expectEqualStrings("ai", pages[4].config_section);
    try std.testing.expectEqualStrings("log", pages[7].config_section);
    for (pages) |page| if (!std.mem.eql(u8, page.config_section, "plugins")) try std.testing.expect(sectionExists(page.config_section));
    var buffer: [1024]u8 = undefined;
    const text = try formatPages(&buffer);
    try std.testing.expect(std.mem.indexOf(u8, text, "AI 辅助 [ai]") != null);
    try std.testing.expectEqual(@as(usize, 56), keys.len);
    try std.testing.expectEqualStrings("line_height", keys[5].key);
    try std.testing.expectEqualStrings("permission_mode", keys[20].key);
    try std.testing.expectEqualStrings("error_hint", keys[22].key);
    try std.testing.expectEqualStrings("checkpoint_sec", keys[24].key);
    try std.testing.expect(keyExists("ai", "error_hint"));
    try std.testing.expect(!keyExists("ai", "not_a_setting"));
}
