const ui = @import("ui");
const S = @import("ai_empty_styles.zig");
pub const Actions = struct {
    context: *anyopaque,
    summarize: *const fn (*anyopaque) void,
    logs: *const fn (*anyopaque) void,
    settings: *const fn (*anyopaque) void,
    ollama: *const fn (*anyopaque) void,
    history: ?*const fn (*anyopaque) void = null,
};
const Click = struct {
    context: *anyopaque,
    run: *const fn (*anyopaque) void,
    fn click(self: *Click) void {
        self.run(self.context);
    }
};
pub fn mount(cx: *ui.Cx, scope: *ui.Scope, configured: bool, actions: Actions) !*ui.Node {
    if (!configured) return mountSetup(cx, scope, actions);
    const root = try ui.boxStyled(cx, S.root, .{});
    root.meta.ownership.meta.test_id = if (configured) "ai.empty.configured" else "ai.empty.unconfigured";
    const status = try ui.boxStyled(cx, S.statusRow, .{});
    status.setDisplay(if (configured) .none else .flex);
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
        const button = try ui.widgets.Button(.{ .label = label, .block = configured, .variant = @as(ui.widgets.button.ButtonVariant, if (!configured and i == 0) .primary else .secondary), .base_style = S.action(configured, !configured and i == 0), .on_click = cx.on(Click, click, Click.click) }).mount(scope, cx);
        button.meta.ownership.meta.test_id = id;
        if (configured) {
            // Shared V3 starter: icon, left-aligned label and the fill-draft arrow.
            for (button.children.items) |child| child.setDisplay(.none);
            button.setStyleInline(cx.allocator, .{ .width = .fill(), .no_cross_stretch = false, .justify = .start, .gap = 6 });
            try button.appendChild(cx.allocator, try ui.iconTint(cx, ui.icons.get(if (i == 0) "terminal" else "file-text").?, S.ink(), .{ .width = .{ .px = 14 }, .height = .{ .px = 14 }, .flex_shrink = 0 }));
            const label_node = try ui.text(cx, label, S.label());
            label_node.setStyleInline(cx.allocator, .{ .width = .fill(), .min_width = 0 });
            try button.appendChild(cx.allocator, label_node);
            try button.appendChild(cx.allocator, try ui.text(cx, "↖", S.label()));
            const hint = try ui.widgets.Tooltip(.{ .text = if (i == 0) "填入问题，发送后分析所选文字或最近输出。" else "选择日志文件，预览后附加到问题。" }).mount(scope, cx);
            hint.wrapper.setStyleInline(cx.allocator, .{ .width = .fill(), .flex = 1, .min_width = 0 });
            hint.trigger.setStyleInline(cx.allocator, .{ .width = .fill(), .height = .{ .px = 30 }, .min_width = 0 });
            try hint.trigger.appendChild(cx.allocator, button);
            try row.appendChild(cx.allocator, hint.wrapper);
        } else try row.appendChild(cx.allocator, button);
    }
    if (configured) if (actions.history) |run| {
        const click = try scope.createState(Click, .{ .context = actions.context, .run = run });
        const recent = try ui.widgets.Button(.{ .variant = .ghost, .block = true, .a11y_label = "最近记录 · 全部连接的 AI 会话", .base_style = S.recent(), .on_click = cx.on(Click, click, Click.click) }).mount(scope, cx);
        recent.meta.ownership.meta.test_id = "ai.empty.recent";
        for (recent.children.items) |child| child.setDisplay(.none);
        recent.setStyleInline(cx.allocator, .{ .justify = .start, .gap = 8 });
        try recent.appendChild(cx.allocator, try ui.iconTint(cx, ui.icons.get("circle-check").?, S.success(), .{ .width = .{ .px = 14 }, .height = .{ .px = 14 }, .flex_shrink = 0 }));
        try recent.appendChild(cx.allocator, try ui.text(cx, "›", S.label()));
        var strong = S.label();
        strong.font_weight = 600;
        try recent.appendChild(cx.allocator, try ui.text(cx, "最近记录", strong));
        var muted = S.label();
        muted.color = S.muted();
        try recent.appendChild(cx.allocator, try ui.text(cx, "全部连接的 AI 会话", muted));
        try root.appendChild(cx.allocator, recent);
    };
    return root;
}

const SetupLayout = struct {
    cx: *ui.Cx,
    root: *ui.Node,
    fn release(self: *SetupLayout) void {
        self.cx.removeAfterLayoutHook(self);
    }
    fn frame(raw: *anyopaque, _: u8, _: bool) ui.AfterLayoutResult {
        const self: *SetupLayout = @ptrCast(@alignCast(raw));
        var ancestor = self.root.parent;
        while (ancestor) |node| : (ancestor = node.parent) {
            if (node.tag != .scroll) continue;
            const available = node.globalRect().h;
            const natural = self.root.globalRect().h - self.root.style.padding.top - self.root.style.padding.bottom;
            const inset = @max(0, (available - natural) / 2);
            if (@abs(self.root.style.padding.top - inset) < 0.1) return .done;
            self.root.setStyleInline(self.cx.allocator, .{ .padding = .{ .top = inset, .bottom = inset } });
            return .needs_layout;
        }
        return .done;
    }
};
fn mountSetup(cx: *ui.Cx, scope: *ui.Scope, actions: Actions) !*ui.Node {
    const root = try ui.box(cx, S.setup(), .{});
    root.meta.ownership.meta.test_id = "ai.empty.unconfigured";
    try root.appendChild(cx.allocator, try ui.iconTint(cx, ui.icons.sparkles, S.accentInk(), .{ .width = .{ .px = 30 }, .height = .{ .px = 30 }, .flex_shrink = 0 }));
    const title = try ui.text(cx, "配置模型，开始对话", S.setupTitle());
    title.meta.ownership.meta.test_id = "ai.empty.title";
    try root.appendChild(cx.allocator, title);
    try root.appendChild(cx.allocator, try ui.text(cx, "添加并启用一个模型服务提供方。", S.setupDescription()));
    const handlers = [_]*const fn (*anyopaque) void{ actions.settings, actions.ollama };
    const labels = [_][]const u8{ "配置 AI 服务", "配置本地模型" };
    const ids = [_][]const u8{ "ai.empty.settings", "ai.empty.ollama" };
    for (handlers, labels, ids, 0..) |run, label, id, i| {
        const click = try scope.createState(Click, .{ .context = actions.context, .run = run });
        const button = try ui.widgets.Button(.{ .label = label, .variant = @as(ui.widgets.button.ButtonVariant, if (i == 0) .primary else .ghost), .base_style = S.setupAction(i == 0), .on_click = cx.on(Click, click, Click.click) }).mount(scope, cx);
        button.meta.ownership.meta.test_id = id;
        try root.appendChild(cx.allocator, button);
    }
    const layout = try scope.createState(SetupLayout, .{ .cx = cx, .root = root });
    try cx.addAfterLayoutHook(layout, SetupLayout.frame);
    try scope.onCleanup(SetupLayout, layout, SetupLayout.release);
    return root;
}
