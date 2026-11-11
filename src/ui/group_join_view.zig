//! A protocol-neutral entry point: native session tabs do not need a terminal
//! command editor to join a workspace group.
const std = @import("std");
const ui = @import("ui");
const theme = @import("app_theme.zig");
const roster_mod = @import("group_model.zig");
pub const Hooks = struct {
    context: *anyopaque,
    join: *const fn (*anyopaque, []const u8) anyerror!void,
    leave: *const fn (*anyopaque) anyerror!void,
    overlay_owner: *const fn (*anyopaque) ?*ui.Node,
};
pub const View = struct {
    hooks: Hooks,
    scope: *ui.Scope,
    overlay: *ui.Node,
    cx: *ui.Cx,
    open: *ui.Signal(bool),
    name: *ui.Signal([]const u8),
    error_label: *ui.Node,
    input: *ui.Node = undefined,
    focus_pending: bool = true,
    pub fn mount(cx: *ui.Cx, scope: *ui.Scope, parent: *ui.Node, roster: *roster_mod.Roster, hooks: Hooks) !*View {
        const open = try scope.createSignal(bool, false);
        const self = try scope.createState(View, .{ .hooks = hooks, .scope = scope, .overlay = undefined, .cx = cx, .open = open, .name = try scope.createText("", .{}), .error_label = undefined });
        const popup = try ui.widgets.Popover(.{ .open = open, .trigger = .manual, .anchor = .{ .virtual = .{ .ctx = self, .getRect = anchorRect } }, .position = .bottom_start, .offset = .{ .static = 6 }, .width = @as(f32, 380), .max_height = @as(f32, 460), .viewport_padding = 8, .constrain_width_to_viewport = true, .shift_main_axis = true, .flip = true, .size_policy = .fit_content, .close_on_escape = true, .close_on_outside_click = true, .consume_outside_click = false, .a11y_role = .dialog }).mount(scope, cx);
        self.overlay = popup.wrapper;
        try parent.appendChild(cx.allocator, popup.wrapper);
        popup.chrome.meta.ownership.meta.test_id = "groups.join.dialog";
        popup.chrome.behavior.interaction.a11y = .{ .role = .dialog, .label = "加入会话组" };
        try theme.bindMaterial(cx, scope, popup.chrome, "overlay");
        const body = try ui.box(cx, .{ .width = .fill(), .direction = .column, .gap = 10, .padding = ui.Padding.all(16) }, .{});
        try popup.content.appendChild(cx.allocator, body);
        try body.appendChild(cx.allocator, try ui.text(cx, "加入会话组", .{ .font_size = 14, .font_weight = 600, .color = theme.current().fg_1 }));
        const input = try ui.widgets.Input(.{ .value = self.name, .placeholder = "输入新组名或现有组名", .on_submit = cx.on(View, self, submitted) }).mountResult(scope, cx);
        theme.styleInput(input);
        self.input = input.input_container;
        input.input_container.meta.ownership.meta.test_id = "groups.join.name";
        try body.appendChild(cx.allocator, input.node);
        const area = try ui.widgets.ScrollArea(.{}).mount(scope, cx);
        area.container.setStyleInline(cx.allocator, .{ .width = .fill(), .height = .{ .px = @min(180, @as(f32, @floatFromInt(roster.groups.items.len)) * 34) }, .flex_shrink = 0 });
        area.content.setStyleInline(cx.allocator, .{ .width = .fill(), .direction = .column, .gap = 2 });
        for (roster.groups.items) |group| {
            const row = try scope.createState(Row, .{ .view = self, .name = (try scope.createText(group.name, .{})).peek() });
            const button = try ui.widgets.Button(.{ .label = row.name, .variant = .ghost, .disabled = false, .on_click = cx.on(Row, row, Row.choose) }).mount(scope, cx);
            button.meta.ownership.meta.test_id = "groups.join.existing";
            try area.content.appendChild(cx.allocator, button);
        }
        try body.appendChild(cx.allocator, area.container);
        self.error_label = try ui.text(cx, "", .{ .font_size = 11, .color = theme.current().danger_ink, .wrap = .word });
        self.error_label.setStyleInline(cx.allocator, .{ .width = .fill(), .height = .{ .fit = .{} } });
        try body.appendChild(cx.allocator, self.error_label);
        const actions = try ui.hstack(cx, .{ .width = .fill(), .gap = 8 }, .{});
        const leave_button = try ui.widgets.Button(.{ .label = "移出所有组", .variant = .secondary, .size = .sm, .on_click = cx.on(View, self, leave) }).mount(scope, cx);
        leave_button.meta.ownership.meta.test_id = "groups.join.leave";
        try actions.appendChild(cx.allocator, leave_button);
        try actions.appendChild(cx.allocator, try ui.spacer(cx));
        try actions.appendChild(cx.allocator, try ui.widgets.Button(.{ .label = "取消", .variant = .secondary, .size = .sm, .on_click = cx.on(View, self, cancel) }).mount(scope, cx));
        const accept = try ui.widgets.Button(.{ .label = "加入 / 创建", .size = .sm, .on_click = cx.on(View, self, submit) }).mount(scope, cx);
        accept.meta.ownership.meta.test_id = "groups.join.accept";
        try actions.appendChild(cx.allocator, accept);
        try body.appendChild(cx.allocator, actions);
        try scope.onCleanup(View, self, cleanup);
        try cx.addAfterLayoutHook(self, afterLayout);
        open.set(true);
        cx.requestRedraw();
        return self;
    }
    fn anchorRect(raw: *anyopaque) ui.widgets.popover.AnchorRect {
        const self: *View = @ptrCast(@alignCast(raw));
        const node = self.hooks.overlay_owner(self.hooks.context) orelse return .{ .x = 0, .y = 0, .w = 0, .h = 0 };
        const rect = node.globalRect();
        return .{ .x = rect.x, .y = rect.y, .w = rect.w, .h = rect.h };
    }
    fn afterLayout(raw: *anyopaque, _: u8, _: bool) ui.AfterLayoutResult {
        const self: *View = @ptrCast(@alignCast(raw));
        if (!self.open.peek()) return .done;
        const anchor = self.hooks.overlay_owner(self.hooks.context);
        if (anchor == null or !anchor.?.isDisplayedInTree()) {
            self.open.set(false);
            return .needs_layout;
        }
        if (self.focus_pending and self.input.isDisplayedInTree()) {
            self.focus_pending = false;
            self.cx.setFocus(self.input);
        }
        return .done;
    }
    fn cleanup(self: *View) void {
        self.cx.removeAfterLayoutHook(self);
    }
    fn showError(self: *View, err: anyerror) void {
        self.error_label.setTextContent(self.cx.allocator, switch (err) {
            error.EmptyName => "请输入会话组名称",
            error.GroupClosing => "目标组正在关闭，请稍后重试",
            error.StaleSession => "会话已变化，请重新打开菜单",
            else => @errorName(err),
        }) catch {};
    }
    fn submitted(self: *View, _: []const u8) void {
        self.submit();
    }
    fn submit(self: *View) void {
        const name = @import("tab_rename.zig").normalize(self.name.peek()) catch |err| {
            self.showError(err);
            return;
        };
        self.hooks.join(self.hooks.context, name) catch |err| {
            self.showError(err);
            return;
        };
        self.open.set(false);
    }
    fn leave(self: *View) void {
        self.hooks.leave(self.hooks.context) catch |err| {
            self.showError(err);
            return;
        };
        self.open.set(false);
    }
    fn cancel(self: *View) void {
        self.open.set(false);
    }
    const Row = struct {
        view: *View,
        name: []const u8,
        fn choose(self: *Row) void {
            self.view.hooks.join(self.view.hooks.context, self.name) catch |err| {
                self.view.showError(err);
                return;
            };
            self.view.open.set(false);
        }
    };
};
