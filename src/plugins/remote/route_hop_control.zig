//! Common replacement and ordering controls for a route hop.
const std = @import("std");
const ui = @import("ui");
const S = @import("../../ui/wizard_styles.zig");

pub const Action = enum { up, down, remove };
pub const Actions = struct {
    context: *anyopaque,
    replace: *const fn (*anyopaque, usize, *ui.Node) void,
    reorder: *const fn (*anyopaque, usize, Action) void,
};
pub const Mount = struct {
    row: *ui.Node,
    index: usize,
    trigger_id: []const u8,
    menu_id: []const u8,
    locked: *ui.Signal(bool),
    actions: Actions,
    height: f32 = 52,
};

pub const RouteHopControl = struct {
    index: usize,
    actions: Actions,
    trigger: *ui.Node = undefined,
    items: *ui.Signal([]const ui.widgets.MenuItem),
    menu_open: ?*ui.Signal(bool) = null,

    pub fn mount(cx: *ui.Cx, scope: *ui.Scope, props: Mount) !*RouteHopControl {
        const self = try scope.createState(RouteHopControl, .{
            .index = props.index,
            .actions = props.actions,
            .items = try scope.createList(ui.widgets.MenuItem, &.{}),
        });
        const a = cx.allocator;
        const row = props.row;
        var content_style = S.row(props.height);
        content_style.flex = 1;
        content_style.min_width = 0;
        content_style.justify = .start;
        content_style.gap = 9;
        content_style.padding = .{};
        content_style.background = ui.Color.TRANSPARENT;
        content_style.cursor = .pointer;
        const shell = try ui.widgets.control_shell.ControlShell(.{
            .tag = .button,
            .style = content_style,
            .interactive = false,
            .focus_ring = false,
        }, .{}).mount(scope, cx);
        self.trigger = shell.node;
        self.trigger.setStyleInline(a, content_style);
        self.trigger.behavior.interaction.a11y = .{ .role = .button, .label = "选择 SSH 跳板主机" };
        self.trigger.behavior.events.on_click = ui.Cx.handlerFrom(RouteHopControl, self, replace);
        self.trigger.meta.ownership.meta.test_id = props.trigger_id;
        try row.appendChild(a, self.trigger);

        const focus = try ui.hooks.useFocusState(scope, cx, self.trigger);
        try scope.createEffect(.{ .visible = focus.visible, .locked = props.locked, .trigger = self.trigger, .row = row, .theme = try cx.themeSignal(scope) }, struct {
            fn paint(ctx: anytype) void {
                _ = ctx.theme.get();
                const locked = ctx.locked.get();
                ctx.trigger.setCursor(if (locked) .not_allowed else .pointer);
                ctx.trigger.setFocusable(!locked);
                ctx.trigger.behavior.interaction.a11y.?.disabled = locked;
                const keyboard_focus = ctx.visible.get() and !locked;
                const colors = S.theme.states();
                ctx.row.setBackground(if (keyboard_focus) colors.selected_hover else colors.selected);
            }
        }.paint);

        const menu = try ui.widgets.Menu(.{ .items = self.items, .width = 154, .position = .bottom_end, .on_select = cx.on(RouteHopControl, self, select) }).mount(scope, cx);
        self.menu_open = menu.open;
        var style = S.button(26, 26, false);
        style.background = ui.Color.TRANSPARENT;
        const button = try ui.widgets.Button(.{ .variant = .ghost, .icon_only = true, .icon_asset = ui.icons.ellipsis, .icon_size = @as(f32, 15), .a11y_label = "跳板操作", .disabled = props.locked, .base_style = style }).mount(scope, cx);
        button.meta.ownership.meta.test_id = props.menu_id;
        menu.wrapper.setStyleInline(a, .{ .width = .{ .px = 26 }, .height = .{ .px = 26 }, .flex_shrink = 0 });
        try menu.trigger.appendChild(a, button);
        try row.appendChild(a, menu.wrapper);
        return self;
    }

    pub fn refresh(self: *RouteHopControl, count: usize) void {
        self.items.set(&.{
            .{ .id = "replace", .label = "更换主机" },
            .{ .id = "previous", .label = "前移", .disabled = self.index == 0 },
            .{ .id = "next", .label = "后移", .disabled = self.index + 1 >= count },
            .{ .id = "remove", .label = "移除跳板", .danger = true },
        });
    }

    fn replace(self: *RouteHopControl) void {
        self.actions.replace(self.actions.context, self.index, self.trigger);
    }

    fn select(self: *RouteHopControl, command: []const u8) void {
        if (std.mem.eql(u8, command, "replace")) return self.replace();
        const action: Action = if (std.mem.eql(u8, command, "previous")) .up else if (std.mem.eql(u8, command, "next")) .down else if (std.mem.eql(u8, command, "remove")) .remove else return;
        self.actions.reorder(self.actions.context, self.index, action);
    }
};
