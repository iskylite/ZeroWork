const ui = @import("ui");
const binding = @import("../settings_content_view.zig");
const draft = @import("../settings_ai_draft.zig");
const controls = @import("settings_controls.zig");

pub fn matchesProviders(query: []const u8) bool {
    return binding.matches(query, "Provider 模型 API Key 地址 endpoint anthropic OpenAI 兼容 Ollama");
}

pub fn mountContent(cx: *ui.Cx, bound: *binding.Binding) !*ui.Node {
    const page = try controls.Page.create(cx, bound, "settings.ai");
    const query = bound.controller.search_query;
    if (matchesProviders(query)) try page.root.appendChild(cx.allocator, try bound.providers(cx));
    if (binding.matches(query, "权限 确认 执行 自动执行 permission_mode")) {
        const section = try page.section("权限", "执行前的默认确认方式", ui.icons.shield, 24, "settings.ai.permissions", null);
        try section.select(.{ .section = "ai", .key = "permission_mode" }, "默认权限模式", "确认后执行：执行命令前确认。自动执行：授权范围内可自动运行命令和工具，包括组内写操作。", &[_]ui.widgets.SelectOption{ .{ .value = "confirm", .label = "确认后执行" }, .{ .value = "auto", .label = "自动执行" } }, null);
    }
    if (binding.matches(query, "运行方式 执行 批处理 交互式 自行判断 每次询问 execution_mode 保留 任务结束 空闲后关闭 保留任务会话 session_retention")) {
        const section = try page.section("运行方式", "全局默认；对话可以单独调整", ui.icons.terminal, 28, "settings.ai.execution", null);
        try section.select(.{ .section = "ai", .key = "execution_mode" }, "默认运行方式", "交互式由助手按任务选择使用当前终端或新建工作会话。", &[_]ui.widgets.SelectOption{
            .{ .value = "auto", .label = "自行判断" },
            .{ .value = "ask", .label = "每次询问" },
            .{ .value = "isolated_exec", .label = "批处理" },
            .{ .value = "interactive", .label = "交互式" },
        }, null);
        try section.select(.{ .section = "ai", .key = "session_retention" }, "任务会话处理", "空闲后关闭、每次询问或保留任务会话。只作用于随后由 AI 创建的资源；已有终端和已创建资源保留原策略。", &[_]ui.widgets.SelectOption{
            .{ .value = "auto_idle", .label = "空闲后关闭" },
            .{ .value = "ask", .label = "每次询问" },
            .{ .value = "keep", .label = "保留任务会话" },
        }, null);
    }
    if (binding.matches(query, "对话 跟进行为 排队 引导 follow_up_mode queue steer")) {
        const section = try page.section("对话", "AI 工作时如何处理新消息", ui.icons.get("messages-square").?, 29, "settings.ai.conversation", null);
        try section.select(.{ .section = "ai", .key = "follow_up_mode" }, "跟进行为", "引导：补充到当前任务。排队：当前任务完成后依次处理。仅影响新发送的消息；⌘⇧Enter 使用另一种行为。", &[_]ui.widgets.SelectOption{
            .{ .value = "steer", .label = "引导", .test_id = "settings.follow_up_mode.steer" },
            .{ .value = "queue", .label = "排队", .test_id = "settings.follow_up_mode.queue" },
        }, null);
    }
    if (binding.matches(query, "子 Agent 默认上下文 独立 继承 复用策略 每次新建 优先复用 模型决定 child_context_mode child_reuse_policy")) {
        const section = try page.section("子 Agent", "只用于之后创建的子配置；已有子配置保持原选择", ui.icons.get("messages-square").?, 30, "settings.ai.children", null);
        try section.select(.{ .section = "ai", .key = "child_context_mode" }, "默认上下文", "独立上下文从任务材料开始；继承上下文复制创建时已消费的合法历史。显式创建参数优先。", &[_]ui.widgets.SelectOption{
            .{ .value = "independent", .label = "独立上下文", .test_id = "settings.child_context.independent" },
            .{ .value = "inherit", .label = "继承当前上下文", .test_id = "settings.child_context.inherit" },
        }, null);
        try section.select(.{ .section = "ai", .key = "child_reuse_policy" }, "默认复用策略", "每次新建默认不可自动复用；优先复用会提示模型先列出并选择明确候选；模型决定默认保守，仍需显式设置可复用。宿主不会按名称悄悄替换。", &[_]ui.widgets.SelectOption{
            .{ .value = "new", .label = "每次新建", .test_id = "settings.child_reuse.new" },
            .{ .value = "prefer_reuse", .label = "优先复用", .test_id = "settings.child_reuse.prefer_reuse" },
            .{ .value = "model", .label = "模型决定", .test_id = "settings.child_reuse.model" },
        }, null);
    }
    if (binding.matches(query, "上下文 来源 脱敏 隐私 IP 主机 用户 redact_ip")) {
        const section = try page.section("上下文", "连接身份与敏感信息", ui.icons.file_text, 25, "settings.ai.context", null);
        try section.toggle(.{ .section = "ai", .key = "redact_ip" }, "隐藏连接身份", "隐藏 SSH 连接的 IP、主机名和用户名。终端正文与附件仍按原文发送，请检查敏感内容。", null);
    }
    if (binding.matches(query, "附件 图片 本地 文本 文件 引用 attachment")) {
        const section = try page.section("附件", "图片和本地文本的大小限制", ui.icons.paperclip, 26, "settings.ai.attachments", null);
        try section.readonly("图片上限", "最多 4 张 · 单张 10 MB");
        try section.readonly("本地文本上限", "UTF-8 · 64 KiB");
    }
    if (binding.matches(query, "其他行为 默认 Provider 错误 提示 error_hint default_provider 步骤默认显示 步骤 聚合 折叠 展开 step_display")) {
        const section = try page.section("其他行为", "默认服务提供方与错误提示", ui.icons.settings, 27, "settings.ai.behavior", null);
        const options = try bound.scope.allocator.alloc(ui.widgets.SelectOption, bound.controller.model.value.ai.provider_count);
        defer bound.scope.allocator.free(options);
        var count: usize = 0;
        for (bound.controller.model.value.ai.providers[0..bound.controller.model.value.ai.provider_count]) |provider| {
            const text = try controls.owned(bound.scope, draft.providerName(provider));
            options[count] = .{ .value = text, .label = text, .disabled = !provider.enabled or !draft.eligible(provider) };
            count += 1;
        }
        if (count != 0) try section.select(.{ .section = "ai", .key = "default_provider" }, "默认服务提供方", "新对话默认使用的模型服务。", options[0..count], null);
        try section.select(.{ .section = "ai", .key = "step_display" }, "步骤默认显示", "只决定新步骤组的初始状态；已有组和手动收展状态保持不变。", &[_]ui.widgets.SelectOption{ .{ .value = "collapsed", .label = "折叠", .test_id = "settings.step_display.collapsed" }, .{ .value = "expanded", .label = "展开", .test_id = "settings.step_display.expanded" } }, null);
        try section.toggle(.{ .section = "ai", .key = "error_hint" }, "错误轻提示", "命令失败时显示助手入口。", null);
    }
    if (binding.matches(query, "本地技能 技能 SKILL MCP 服务 工具 导入 stdio HTTP 环境变量 请求头")) if (bound.hooks.mount_extensions) |mount| try page.root.appendChild(cx.allocator, try mount(bound.hooks.context, cx, bound.scope));
    return page.finish();
}
