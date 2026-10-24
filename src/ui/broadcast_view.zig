const ui = @import("ui");
const S = @import("broadcast_styles.zig");
pub const View = struct {
    cx: *ui.Cx,
    root: *ui.Node,
    open: *ui.Signal(bool),
    content: *ui.Node,
    control: *ui.Node,
    control_text: *ui.Node,
    disabled: *ui.Signal(bool),
    group_id: u32 = 0,
    running: bool = false,
    hooks: struct { context: *anyopaque, resolve: *const fn (*anyopaque, u32, bool) void },
    pub fn mount(cx: *ui.Cx, scope: *ui.Scope, hooks: @FieldType(View, "hooks")) !*View {
        const self = try cx.allocator.create(View);
        self.* = .{ .cx = cx, .root = undefined, .open = try scope.createSignal(bool, false), .content = undefined, .control = undefined, .control_text = undefined, .disabled = try scope.createSignal(bool, false), .hooks = hooks };
        const popup = try ui.widgets.Popover(.{ .trigger = .manual, .position = .top_end, .open = self.open, .width = @as(f32, 360), .max_height = @as(f32, 248), .constrain_width_to_viewport = true, .viewport_padding = 8, .on_open_change = cx.on(View, self, changed), .anchor = .{ .virtual = .{ .ctx = self, .getRect = anchorRect } } }).mount(scope, cx);
        self.root = popup.content;
        self.root.setStyleInline(cx.allocator, S.panel());
        const content_scope = popup.scope;
        try cx.root.?.appendChild(cx.allocator, popup.wrapper);
        self.root.meta.ownership.meta.test_id = "group.broadcast.card";
        self.root.behavior.events.on_key_down = onKey;
        self.root.behavior.events.key_context = self;
        const head = try ui.box(cx, S.header(), .{});
        try head.appendChild(cx.allocator, try ui.text(cx, "广播输入", S.text(true)));
        try head.appendChild(cx.allocator, try ui.spacer(cx));
        try head.appendChild(cx.allocator, try ui.widgets.Button(.{ .icon_only = true, .icon_asset = ui.icons.x, .variant = .ghost, .a11y_label = "收起广播信息", .on_click = cx.on(View, self, hide) }).mount(content_scope, cx));
        try self.root.appendChild(cx.allocator, head);
        const scroll = try ui.widgets.ScrollArea(.{ .direction = .vertical }).mount(content_scope, cx);
        scroll.container.setStyleInline(cx.allocator, .{ .width = .fill(), .height = .fill() });
        self.content = try ui.text(cx, "", S.text(false));
        try scroll.content.appendChild(cx.allocator, self.content);
        try self.root.appendChild(cx.allocator, scroll.container);
        const footer = try ui.box(cx, S.row(), .{});
        try footer.appendChild(cx.allocator, try ui.widgets.Button(.{ .label = "取消", .variant = .secondary, .on_click = cx.on(View, self, hide) }).mount(content_scope, cx));
        try footer.appendChild(cx.allocator, try ui.spacer(cx));
        self.control = try ui.widgets.Button(.{ .variant = .primary, .disabled = self.disabled, .on_click = cx.on(View, self, accept) }).mount(content_scope, cx);
        self.control_text = try ui.text(cx, "开启广播", S.primaryButtonText());
        try self.control.appendChild(cx.allocator, self.control_text);
        self.control.meta.ownership.meta.test_id = "group.broadcast.accept";
        try footer.appendChild(cx.allocator, self.control);
        try self.root.appendChild(cx.allocator, footer);
        try @import("compact_overlay_layout.zig").mount(cx, content_scope, self.root, scroll.container, scroll.content, 94, 154, null, 0);
        try scope.onCleanup(View, self, cleanup);
        return self;
    }
    pub fn show(self: *View, group: u32, running: bool, text: []const u8, can_enable: bool) !void {
        self.group_id = group;
        self.running = running;
        try self.content.setTextContent(self.cx.allocator, text);
        try self.control_text.setTextContent(self.cx.allocator, if (running) "停止广播" else "开启广播");
        self.disabled.set(!running and !can_enable);
        const was_hidden = !self.open.get();
        self.root.setStyleInline(self.cx.allocator, S.panel());
        const bounds = self.cx.root.?.globalRect();
        self.root.setStyle(self.cx.allocator, .width, .{ .px = @min(@as(f32, 360), @max(@as(f32, 100), bounds.w - 16)) });
        self.root.setDisplay(.flex);
        self.open.set(true);
        if (was_hidden) self.cx.setFocus(self.control);
        self.cx.requestRedraw();
    }
    pub fn dismiss(self: *View) void {
        self.open.set(false);
        self.root.setDisplay(.none);
        self.cx.requestRedraw();
    }
    pub fn hide(self: *View) void {
        self.open.set(false);
        self.root.setDisplay(.none);
        if (!self.running) self.hooks.resolve(self.hooks.context, self.group_id, false);
        self.cx.requestRedraw();
    }
    fn anchorRect(raw: *anyopaque) ui.widgets.popover.AnchorRect {
        const self: *View = @ptrCast(@alignCast(raw));
        return .{ .x = @max(@as(f32, 8), self.cx.viewport.width - 32), .y = @max(@as(f32, 8), self.cx.viewport.height - 38), .w = 0, .h = 0 };
    }
    fn changed(self: *View, value: bool) void {
        if (!value) self.hide();
    }
    fn onKey(key: ui.events.KeyCode, _: ui.events.Modifiers, raw: ?*anyopaque) ui.events.EventResult {
        const self: *View = @ptrCast(@alignCast(raw orelse return .ignored));
        if (key == .escape) {
            self.hide();
            return .stop;
        }
        return .ignored;
    }
    fn accept(self: *View) void {
        self.hooks.resolve(self.hooks.context, self.group_id, true);
    }
    fn cleanup(self: *View) void {
        self.cx.allocator.destroy(self);
    }
};
