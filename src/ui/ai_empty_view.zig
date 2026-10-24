const ui = @import("ui");
const S = @import("ai_empty_styles.zig");
pub const Actions = struct {
    context: *anyopaque,
    summarize: *const fn (*anyopaque) void,
    logs: *const fn (*anyopaque) void,
    settings: *const fn (*anyopaque) void,
    ollama: *const fn (*anyopaque) void,
};
const Click = struct {
    context: *anyopaque,
    run: *const fn (*anyopaque) void,
    fn click(self: *Click) void {
        self.run(self.context);
    }
};
pub fn mount(cx: *ui.Cx, scope: *ui.Scope, configured: bool, actions: Actions) !*ui.Node {
    const root = try ui.boxStyled(cx, S.root, .{});
    root.meta.ownership.meta.test_id = if (configured) "ai.empty.configured" else "ai.empty.unconfigured";
    const status = try ui.boxStyled(cx, S.statusRow, .{});
    try status.appendChild(cx.allocator, try ui.iconTint(cx, ui.icons.get(if (configured) "circle-check" else "triangle-alert").?, S.status(configured).color, S.icon()));
    try status.appendChild(cx.allocator, try ui.text(cx, if (configured) "已配置模型" else "未配置 Provider / 模型", S.status(configured)));
    try root.appendChild(cx.allocator, status);
    const row = try ui.boxStyled(cx, S.row, .{});
    try root.appendChild(cx.allocator, row);
    const labels = if (configured) [_][]const u8{ "概括终端报错", "分析应用日志" } else [_][]const u8{ "打开 AI 设置", "配置本地模型" };
    const handlers = if (configured) [_]*const fn (*anyopaque) void{ actions.summarize, actions.logs } else [_]*const fn (*anyopaque) void{ actions.settings, actions.ollama };
    const ids = if (configured) [_][]const u8{ "ai.empty.summarize", "ai.empty.logs" } else [_][]const u8{ "ai.empty.settings", "ai.empty.ollama" };
    for (labels, handlers, ids, 0..) |label, run, id, i| {
        const click = try scope.createState(Click, .{ .context = actions.context, .run = run });
        const button = try ui.widgets.Button(.{ .label = label, .variant = @as(ui.widgets.button.ButtonVariant, if (!configured and i == 0) .primary else .secondary), .base_style = S.action(configured, !configured and i == 0), .on_click = cx.on(Click, click, Click.click) }).mount(scope, cx);
        button.meta.ownership.meta.test_id = id;
        if (configured) {
            const hint = try ui.widgets.Tooltip(.{ .text = if (i == 0) "填入问题，发送后分析所选文字或最近输出。" else "选择日志文件，预览后附加到问题。" }).mount(scope, cx);
            hint.wrapper.setStyleInline(cx.allocator, .{ .width = .fill(), .flex = 1, .min_width = 0 });
            try hint.trigger.appendChild(cx.allocator, button);
            try row.appendChild(cx.allocator, hint.wrapper);
        } else try row.appendChild(cx.allocator, button);
    }
    return root;
}
