//! Search terms are product labels and schema keys, independent of UI nodes.
const std = @import("std");

pub const page_terms = [_][]const u8{
    "外观 主题 theme 主题库 背景 图片 材质 模糊 透明度 fit 对齐 字体 字号 行高 光标 font cursor 时间戳 侧栏 高亮 补全 font_family font_size font_weight line_height cursor_style sidebar_collapsed input_line_highlight timestamp_gutter enabled blur_px background path alignment_x alignment_y transparency",
    "快捷键 页签 分栏 新建 关闭 序号 直达 上一个 下一个 最近使用 split tab 终端 应用 复制 粘贴 搜索 补全 采纳 快速连接 立即重连 侧栏 AI 上传 广播 terminal",
    "SSH 网络 连接 保活 KeepAlive 超时 终端 TERM 压缩 keepalive_sec connect_timeout_sec compression 断线 自动重连 最大次数 退避 输入缓存 auto_reconnect reconnect_max reconnect_backoff buffer_input SOCKS5 默认值 本地端口 绑定地址 socks_port socks_bind 双因素 认证 验证码 OTP TOTP 自动填充 otp_modal totp_autofill",
    "文件传输 连接隔离 独立传输连接 共享通道限速 dedicated_connection shared_pacing_kbps SFTP 引擎 滑动窗口 块大小 断点续传 MD5 完成校验 最大并发任务 window_chunks chunk_kb resume verify_md5 max_tasks 默认行为 默认下载目录 同名 重命名 冲突 每次询问 download_dir conflict_policy",
    "AI 辅助 Provider 模型 API Key 地址 endpoint anthropic OpenAI 兼容 Ollama 权限 确认 执行 自动执行 完全控制 permission_mode 上下文 隐藏连接身份 来源 脱敏 隐私 IP 主机 用户 redact_ip 附件 图片 本地 文本 文件 引用 attachment 其他行为 默认错误提示 error_hint default_provider",
    "协议 插件 Local zsh SSH SFTP 已内置 权限 版本",
    "通知 事件提醒 传输完成 断线 重连 AI 助手 回合 结束 终端 Bell 声音 transfer_done reconnect ai_ready bell 注意标记 勿扰 非活跃 标签 圆点 时段 tab_dot quiet_hours",
    "数据 日志 位置 凭据 本地 配置目录 明文 600 config_dir 会话记录 缓冲 上限 快照 间隔 保留 天数 导出格式 ring_mb checkpoint_sec retention_days export_format 导出 清理 清空 删除 会话 诊断 export clear",
};

pub fn matches(query: []const u8, text: []const u8) bool {
    const needle = std.mem.trim(u8, query, " \t\r\n");
    if (needle.len == 0) return true;
    if (needle.len > text.len) return false;
    for (0..text.len - needle.len + 1) |start| if (std.ascii.eqlIgnoreCase(needle, text[start..][0..needle.len])) return true;
    return false;
}
pub fn pageMatches(query: []const u8, page: usize) bool {
    return page < page_terms.len and matches(query, page_terms[page]);
}
pub fn firstPage(query: []const u8) ?usize {
    // Scalar settings take precedence over shortcut rows mentioning the same
    // action, e.g. “重连” opens the four SSH fields before its key binding.
    for ([_]usize{ 0, 2, 3, 4, 5, 6, 7, 1 }) |index| if (matches(query, page_terms[index])) return index;
    return null;
}
