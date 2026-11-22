const std = @import("std");

pub const Page = struct { name: []const u8, config_section: []const u8, description: []const u8 };
pub const ConfigKey = struct { page: []const u8, section: []const u8, key: []const u8 };
pub const keys = [_]ConfigKey{
    .{ .page = "外观主题", .section = "ui", .key = "icon_background" },
    .{ .page = "外观主题", .section = "ui", .key = "theme" },
    .{ .page = "终端配置", .section = "ui", .key = "font_family" },
    .{ .page = "终端配置", .section = "ui", .key = "font_size" },
    .{ .page = "终端配置", .section = "ui", .key = "font_weight" },
    .{ .page = "终端配置", .section = "ui", .key = "line_height" },
    .{ .page = "终端配置", .section = "ui", .key = "cursor_style" },
    .{ .page = "终端配置", .section = "ui", .key = "sidebar_collapsed" },
    .{ .page = "终端配置", .section = "ui", .key = "input_line_highlight" },
    .{ .page = "终端配置", .section = "ui", .key = "timestamp_gutter" },
    .{ .page = "SSH 与网络", .section = "ssh", .key = "keepalive_sec" },
    .{ .page = "SSH 与网络", .section = "ssh", .key = "reconnect_max" },
    .{ .page = "SSH 与网络", .section = "ssh", .key = "reconnect_backoff" },
    .{ .page = "文件传输", .section = "transfer", .key = "dedicated_connection" },
    .{ .page = "文件传输", .section = "transfer", .key = "window_chunks" },
    .{ .page = "文件传输", .section = "transfer", .key = "chunk_kb" },
    .{ .page = "文件传输", .section = "transfer", .key = "download_dir" },
    .{ .page = "文件传输", .section = "transfer", .key = "verify_md5" },
    .{ .page = "文件传输", .section = "transfer", .key = "shared_pacing_kbps" },
    .{ .page = "AI 助手行为", .section = "ai", .key = "default_provider" },
    .{ .page = "AI 助手行为", .section = "ai", .key = "permission_mode" },
    .{ .page = "AI 上下文", .section = "ai", .key = "redact_ip" },
    .{ .page = "AI 助手行为", .section = "ai", .key = "error_hint" },
    .{ .page = "数据与日志", .section = "log", .key = "ring_mb" },
    .{ .page = "数据与日志", .section = "log", .key = "checkpoint_sec" },
    .{ .page = "SSH 与网络", .section = "ssh", .key = "connect_timeout_sec" },
    .{ .page = "SSH 与网络", .section = "ssh", .key = "term" },
    .{ .page = "SSH 与网络", .section = "ssh", .key = "compression" },
    .{ .page = "SSH 与网络", .section = "ssh", .key = "auto_shell_integration" },
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
    .{ .page = "终端配置", .section = "completion", .key = "enabled" },
    .{ .page = "外观主题", .section = "ui.materials", .key = "blur_px" },
    .{ .page = "外观主题", .section = "ui.materials.background", .key = "enabled" },
    .{ .page = "外观主题", .section = "ui.materials.background", .key = "path" },
    .{ .page = "外观主题", .section = "ui.materials.background", .key = "source" },
    .{ .page = "外观主题", .section = "ui.materials.background", .key = "order" },
    .{ .page = "外观主题", .section = "ui.materials.background", .key = "interval_minutes" },
    .{ .page = "外观主题", .section = "ui.materials.background", .key = "fit" },
    .{ .page = "外观主题", .section = "ui.materials.background", .key = "alignment_x" },
    .{ .page = "外观主题", .section = "ui.materials.background", .key = "alignment_y" },
    .{ .page = "外观主题", .section = "ui.materials.background", .key = "transparency" },
    .{ .page = "终端配置", .section = "ui", .key = "scrollback_limit" },
    .{ .page = "AI 助手行为", .section = "ai", .key = "execution_mode" },
    .{ .page = "AI 助手行为", .section = "ai", .key = "session_retention" },
    .{ .page = "终端配置", .section = "ui", .key = "command_info" },
    .{ .page = "关于与更新", .section = "updates", .key = "auto_check" },
    .{ .page = "AI 助手行为", .section = "ai", .key = "step_display" },
    .{ .page = "AI 助手行为", .section = "ai", .key = "follow_up_mode" },
    .{ .page = "AI 子 Agent", .section = "ai", .key = "child_context_mode" },
    .{ .page = "AI 子 Agent", .section = "ai", .key = "child_reuse_policy" },
    .{ .page = "AI 助手行为", .section = "ai", .key = "interactive_batch_fallback" },
    .{ .page = "AI 子 Agent", .section = "ai", .key = "child_max_active" },
    .{ .page = "AI 子 Agent", .section = "ai", .key = "child_request_concurrency" },
    .{ .page = "AI 子 Agent", .section = "ai", .key = "model_slots" },
    .{ .page = "AI 子 Agent", .section = "ai", .key = "swarm_mode_default" },
    .{ .page = "AI 子 Agent", .section = "ai", .key = "swarm_stall_minutes" },
    .{ .page = "AI 子 Agent", .section = "ai", .key = "swarm_stall_parent_minutes" },
    .{ .page = "AI 子 Agent", .section = "ai", .key = "boost_max_rounds" },
};
pub const sections = [_][]const u8{ "ui", "ui.materials", "ui.materials.background", "completion", "transfer", "ssh", "ai", "log", "notify", "updates" };

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
    .{ .name = "外观主题", .config_section = "ui", .description = "应用图标、主题与背景设置；保存后全局生效" },
    .{ .name = "终端配置", .config_section = "ui", .description = "字体、光标与终端显示；保存后全局生效" },
    .{ .name = "快捷键", .config_section = "ui", .description = "逐项录制应用快捷键；Tab 与 Control 保留给远端" },
    .{ .name = "SSH 与网络", .config_section = "ssh", .description = "连接、重连与认证默认值；保存后用于后续连接" },
    .{ .name = "文件传输", .config_section = "transfer", .description = "连接隔离、传输引擎与下载默认值；运行任务保留原设置" },
    .{ .name = "AI 模型服务", .config_section = "ai", .description = "配置模型服务连接与可用模型；保存后用于新对话" },
    .{ .name = "AI 助手行为", .config_section = "ai", .description = "权限、运行方式与对话默认行为" },
    .{ .name = "AI 子 Agent", .config_section = "ai", .description = "子 Agent 配置、预算上限与多智能体编排" },
    .{ .name = "AI 上下文", .config_section = "ai", .description = "敏感信息、附件限制、本地技能与 MCP 服务" },
    .{ .name = "协议插件", .config_section = "plugins", .description = "查看内置协议服务" },
    .{ .name = "通知", .config_section = "notify", .description = "事件通知、标签提醒与勿扰时段" },
    .{ .name = "数据与日志", .config_section = "log", .description = "本地配置、会话记录、日志导出与清理" },
    .{ .name = "关于与更新", .config_section = "updates", .description = "应用版本、自动检查与安全安装更新" },
};

pub const transfer_index = indexOf("文件传输");
pub const ai_models_index = indexOf("AI 模型服务");
pub const ai_behavior_index = indexOf("AI 助手行为");

fn indexOf(comptime name: []const u8) usize {
    for (pages, 0..) |page, index| {
        if (std.mem.eql(u8, page.name, name)) return index;
    }
    @compileError("Unknown settings page: " ++ name);
}

test "settings page map covers thirteen documented pages" {
    try std.testing.expectEqual(@as(usize, 13), pages.len);
    try std.testing.expectEqualStrings("ai", pages[5].config_section);
    try std.testing.expectEqualStrings("log", pages[11].config_section);
    for (pages) |page| if (!std.mem.eql(u8, page.config_section, "plugins")) try std.testing.expect(sectionExists(page.config_section));
    var buffer: [2048]u8 = undefined;
    const text = try formatPages(&buffer);
    try std.testing.expect(std.mem.indexOf(u8, text, "AI 模型服务 [ai]") != null);
    try std.testing.expectEqual(@as(usize, 74), keys.len);
    try std.testing.expect(keyExists("ai", "child_context_mode"));
    try std.testing.expect(keyExists("ai", "child_reuse_policy"));
    try std.testing.expect(keyExists("ai", "step_display"));
    try std.testing.expect(keyExists("ai", "follow_up_mode"));
    try std.testing.expectEqualStrings("line_height", keys[5].key);
    try std.testing.expectEqualStrings("permission_mode", keys[20].key);
    try std.testing.expectEqualStrings("error_hint", keys[22].key);
    try std.testing.expectEqualStrings("checkpoint_sec", keys[24].key);
    try std.testing.expect(keyExists("ai", "error_hint"));
    try std.testing.expect(!keyExists("ai", "not_a_setting"));
}
