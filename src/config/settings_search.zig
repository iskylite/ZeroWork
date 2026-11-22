//! Search terms are product labels and schema keys, independent of UI nodes.
const std = @import("std");

pub const page_terms = [_][]const u8{
    "应用图标 透明背景 黑底 白底 Dock icon_background 主题 theme 主题库 背景 图片 目录 轮播 顺序 随机 间隔 source order interval_minutes 材质 模糊 透明度 fit 对齐 blur_px background path alignment_x alignment_y transparency",
    "字体 字号 行高 光标 font cursor font_family font_size font_weight line_height cursor_style 时间戳 侧栏 高亮 补全 sidebar_collapsed input_line_highlight timestamp_gutter 命令信息 command_info 最大显示行数 回滚 scrollback_limit completion enabled",
    "快捷键 页签 分栏 新建 关闭 序号 直达 上一个 下一个 最近使用 聚焦上一个分栏 聚焦下一个分栏 previous_pane next_pane split tab 终端 应用 复制 粘贴 搜索 补全 采纳 快速连接 立即重连 侧栏 AI 上传 广播 terminal",
    "SSH 网络 连接 保活 KeepAlive 超时 终端 TERM 压缩 keepalive_sec connect_timeout_sec compression 自动 会话 初始化 命令 状态 shell integration auto_shell_integration 断线 自动重连 最大次数 退避 输入缓存 auto_reconnect reconnect_max reconnect_backoff buffer_input SOCKS5 默认值 本地端口 绑定地址 socks_port socks_bind 双因素 认证 验证码 OTP TOTP 自动填充 otp_modal totp_autofill",
    "文件传输 连接隔离 独立传输连接 共享通道限速 dedicated_connection shared_pacing_kbps SFTP 引擎 滑动窗口 块大小 断点续传 MD5 完成校验 最大并发任务 window_chunks chunk_kb resume verify_md5 max_tasks 默认行为 默认下载目录 同名 重命名 冲突 每次询问 download_dir conflict_policy",
    "AI 模型服务 Provider 模型 API Key 地址 endpoint anthropic OpenAI 兼容 Ollama 服务提供方",
    "AI 助手行为 权限 确认 执行 自动执行 完全控制 permission_mode 运行方式 批处理 交互式 自行判断 每次询问 空闲后关闭 保留任务会话 execution_mode session_retention 其他行为 默认服务提供方 默认错误提示 error_hint default_provider 步骤默认显示 步骤 聚合 折叠 展开 step_display 对话 跟进行为 排队 引导 follow_up_mode queue steer 交互式批处理回退 interactive_batch_fallback",
    "AI 子 Agent 子 Agent 默认上下文 独立 继承 复用策略 每次新建 优先复用 模型决定 预算 并发 上限 child_context_mode child_reuse_policy child_max_active child_request_concurrency model_slots 多智能体 编排 模式 停滞 催父 轮次 swarm swarm_mode_default swarm_stall_minutes swarm_stall_parent_minutes boost_max_rounds 角色模板 推理强度",
    "AI 上下文 上下文 隐藏连接身份 来源 脱敏 隐私 IP 主机 用户 redact_ip 附件 图片 本地 文本 文件 引用 attachment 本地技能 技能 SKILL MCP 服务 工具 导入 stdio HTTP 环境变量 请求头",
    "协议 插件 Local zsh SSH SFTP 已内置 权限 版本",
    "通知 事件提醒 传输完成 断线 重连 AI 助手 回合 结束 终端 Bell 声音 transfer_done reconnect ai_ready bell 注意标记 勿扰 非活跃 后台 标签 图标 跳动 圆点 时段 tab_dot quiet_hours",
    "数据 日志 位置 凭据 本地 配置目录 明文 600 config_dir 会话记录 缓冲 上限 快照 间隔 保留 天数 导出格式 ring_mb checkpoint_sec retention_days export_format 导出 清理 清空 删除 会话 诊断 export clear",
    "关于 更新 版本 自动 检查 偏好 正式版 通道 GitHub release update version auto_check channel",
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
    for ([_]usize{ 0, 1, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 2 }) |index| if (matches(query, page_terms[index])) return index;
    return null;
}
