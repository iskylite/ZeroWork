const ui = @import("ui");
const binding = @import("../settings_content_view.zig");
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
        try section.select(.{ .section = "ai", .key = "permission_mode" }, "默认权限模式", "确认后执行：写操作逐次确认。自动执行：在允许范围内自动运行，组内写操作仍需确认。", &[_]ui.widgets.SelectOption{ .{ .value = "confirm", .label = "确认后执行" }, .{ .value = "auto", .label = "自动执行" } }, null);
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
    if (binding.matches(query, "其他行为 默认 Provider 错误 提示 error_hint default_provider")) {
        const section = try page.section("其他行为", "默认服务提供方与错误提示", ui.icons.settings, 27, "settings.ai.behavior", null);
        const options = try bound.scope.allocator.alloc(ui.widgets.SelectOption, bound.controller.model.value.ai.provider_count);
        defer bound.scope.allocator.free(options);
        var count: usize = 0;
        for (bound.controller.model.value.ai.providers[0..bound.controller.model.value.ai.provider_count]) |provider| {
            const name = if (provider.name.len != 0) provider.name else @tagName(provider.kind);
            const text = try controls.owned(bound.scope, name);
            options[count] = .{ .value = text, .label = text, .disabled = !provider.enabled or provider.endpoint.len == 0 or provider.model_count == 0 };
            count += 1;
        }
        if (count != 0) try section.select(.{ .section = "ai", .key = "default_provider" }, "默认服务提供方", "新对话默认使用的模型服务。", options[0..count], null);
        try section.toggle(.{ .section = "ai", .key = "error_hint" }, "错误轻提示", "命令失败时显示助手入口。", null);
    }
    return page.finish();
}
