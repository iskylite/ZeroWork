const ui = @import("ui");
const S = @import("ai_empty_styles.zig");
pub const Recent = struct { id: u64, title: []const u8 };
pub const Actions = struct {
    logo_texture: ?u32 = null,
    recent: []const Recent = &.{},
    select: ?*const fn (*anyopaque, u64) void = null,
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
    const logo = try ui.image(cx, actions.logo_texture orelse 0, .{ .width = .{ .px = 88 }, .height = .{ .px = 88 }, .flex_shrink = 0 });
    logo.meta.ownership.meta.test_id = "ai.empty.logo";
    try root.appendChild(cx.allocator, logo);
    const title = try ui.textStyled(cx, S.welcomeTitle, "有什么可以帮你？");
    title.meta.ownership.meta.test_id = "ai.empty.title";
    try root.appendChild(cx.allocator, title);
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
            // Shared V3 starter: icon, left-aligned label and the source help icon.
            for (button.children.items) |child| child.setDisplay(.none);
            button.setStyleInline(cx.allocator, .{ .width = .fill(), .no_cross_stretch = false, .justify = .start, .gap = 6 });
            try button.appendChild(cx.allocator, try ui.iconTint(cx, ui.icons.get(if (i == 0) "terminal" else "file-text").?, S.ink(), .{ .width = .{ .px = 14 }, .height = .{ .px = 14 }, .flex_shrink = 0 }));
            var starter_text = S.label();
            starter_text.font_size = 11.5;
            starter_text.font_weight = 500;
            starter_text.line_height = 16.0 / 11.5;
            const label_node = try ui.text(cx, label, starter_text);
            label_node.setStyleInline(cx.allocator, .{ .width = .fill(), .min_width = 0, .margin = .{ .right = 12 } });
            try button.appendChild(cx.allocator, label_node);
            try button.appendChild(cx.allocator, try ui.iconTint(cx, ui.icons.get("arrow-up-right").?, S.muted(), .{ .width = .{ .px = 12 }, .height = .{ .px = 12 }, .flex_shrink = 0 }));
            const hint = try ui.widgets.Tooltip(.{ .text = if (i == 0) "填入问题，发送后分析所选文字或最近输出。" else "选择日志文件，附加到问题。" }).mount(scope, cx);
            hint.wrapper.setStyleInline(cx.allocator, .{ .width = .fill(), .flex = 1, .min_width = 0 });
            hint.trigger.setStyleInline(cx.allocator, .{ .width = .fill(), .height = .{ .px = 30 }, .min_width = 0 });
            try hint.trigger.appendChild(cx.allocator, button);
            try row.appendChild(cx.allocator, hint.wrapper);
        } else try row.appendChild(cx.allocator, button);
    }
    if (actions.recent.len > 0 and actions.select != null) {
        const recent = try ui.boxStyled(cx, S.recentGroup, .{});
        recent.meta.ownership.meta.test_id = "ai.empty.recent";
        try recent.appendChild(cx.allocator, try ui.text(cx, "最近会话", .{ .font_size = 10.5, .line_height = 16.0 / 10.5, .color = S.muted() }));
        for (actions.recent[0..@min(2, actions.recent.len)]) |entry| {
            const click = try scope.createState(RecentClick, .{ .context = actions.context, .select = actions.select.?, .id = entry.id });
            const button = try ui.widgets.Button(.{ .label = entry.title, .variant = .ghost, .block = true, .base_style = S.recent(), .on_click = cx.on(RecentClick, click, RecentClick.run) }).mount(scope, cx);
            button.meta.ownership.meta.test_id = "ai.empty.recent.link";
            for (button.children.items) |child| child.setDisplay(.none);
            try button.appendChild(cx.allocator, try ui.iconTint(cx, ui.icons.get("message-circle").?, S.muted(), S.icon()));
            const text = try ui.text(cx, entry.title, S.label());
            text.setStyleInline(cx.allocator, .{ .width = .fill(), .height = .{ .px = 16 }, .min_width = 0, .overflow_hidden = true });
            try button.appendChild(cx.allocator, text);
            try button.appendChild(cx.allocator, try ui.iconTint(cx, ui.icons.get("arrow-up-right").?, S.muted(), S.icon()));
            try recent.appendChild(cx.allocator, button);
        }
        try root.appendChild(cx.allocator, recent);
    }
    const layout = try scope.createState(SetupLayout, .{ .cx = cx, .root = root, .logo = logo });
    try cx.addAfterLayoutHook(layout, SetupLayout.frame);
    try scope.onCleanup(SetupLayout, layout, SetupLayout.release);
    return root;
}
const RecentClick = struct {
    context: *anyopaque,
    select: *const fn (*anyopaque, u64) void,
    id: u64,
    fn run(self: *RecentClick) void {
        self.select(self.context, self.id);
    }
};

const SetupLayout = struct {
    cx: *ui.Cx,
    root: *ui.Node,
    logo: ?*ui.Node = null,
    fn release(self: *SetupLayout) void {
        self.cx.removeAfterLayoutHook(self);
    }
    fn frame(raw: *anyopaque, _: u8, _: bool) ui.AfterLayoutResult {
        const self: *SetupLayout = @ptrCast(@alignCast(raw));
        var ancestor = self.root.parent;
        while (ancestor) |node| : (ancestor = node.parent) {
            if (node.tag != .scroll) continue;
            const available = node.globalRect().h;
            if (self.logo) |logo| {
                const size: f32 = if (available < 260) 56 else 88;
                const gap: f32 = if (available < 260) 8 else 12;
                if (@abs(logo.globalRect().h - size) > 0.1 or self.root.style.gap != gap) {
                    logo.setStyleInline(self.cx.allocator, .{ .width = .{ .px = size }, .height = .{ .px = size } });
                    self.root.setStyleInline(self.cx.allocator, .{ .gap = gap });
                    return .needs_layout;
                }
            }
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
    const logo = try ui.image(cx, actions.logo_texture orelse 0, .{ .width = .{ .px = 88 }, .height = .{ .px = 88 }, .flex_shrink = 0 });
    logo.meta.ownership.meta.test_id = "ai.empty.logo";
    try root.appendChild(cx.allocator, logo);
    const title = try ui.text(cx, "配置模型，开始对话", S.setupTitle());
    title.meta.ownership.meta.test_id = "ai.empty.title";
    try root.appendChild(cx.allocator, title);
    try root.appendChild(cx.allocator, try ui.text(cx, "添加并启用一个模型服务提供方。", S.setupDescription()));
    const click = try scope.createState(Click, .{ .context = actions.context, .run = actions.settings });
    const button = try ui.widgets.Button(.{ .label = "配置 AI 服务", .variant = .primary, .base_style = S.setupAction(true), .on_click = cx.on(Click, click, Click.click) }).mount(scope, cx);
    button.meta.ownership.meta.test_id = "ai.empty.settings";
    try root.appendChild(cx.allocator, button);
    const layout = try scope.createState(SetupLayout, .{ .cx = cx, .root = root, .logo = logo });
    try cx.addAfterLayoutHook(layout, SetupLayout.frame);
    try scope.onCleanup(SetupLayout, layout, SetupLayout.release);
    return root;
}
