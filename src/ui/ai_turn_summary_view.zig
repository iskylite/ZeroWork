//! A completed turn keeps its final answer outside this lazy process disclosure.
const std = @import("std");
const ui = @import("ui");
const Turn = @import("../ai/conversation_turn.zig").Turn;
pub const View = struct {
    cx: *ui.Cx,
    scope: *ui.Scope,
    turn: *Turn,
    root: *ui.Node,
    button: *ui.Node = undefined,
    icon: *ui.Node = undefined,
    process: *ui.Node = undefined,
    divider: *ui.Node = undefined,
    context: *anyopaque,
    render: *const fn (*anyopaque, *ui.Node, *ui.Scope) anyerror!void,
    on_toggle: ui.Handler(void),
    rendered: bool = false,
    pub fn mount(cx: *ui.Cx, scope: *ui.Scope, parent: *ui.Node, turn: *Turn, context: *anyopaque, render: @FieldType(View, "render"), on_toggle: ui.Handler(void)) !*View {
        const root = try ui.box(cx, .{ .width = .fill(), .height = .{ .fit = .{} }, .direction = .column, .gap = 8, .min_width = 0, .flex_shrink = 0 }, .{});
        root.meta.ownership.meta.test_id = "ai.turn.process.section";
        const self = try scope.createState(View, .{ .cx = cx, .scope = scope, .turn = turn, .root = root, .context = context, .render = render, .on_toggle = on_toggle });
        const color = @import("app_theme.zig").current().fg_2;
        self.button = try ui.widgets.Button(.{ .variant = .ghost, .a11y_label = "展开或收起本回合过程消息", .base_style = ui.BoxStyle{ .height = .{ .px = 22 }, .align_self = .start, .padding = .{}, .gap = 4, .text_color = color }, .on_click = cx.on(View, self, toggle) }).mount(scope, cx);
        self.button.meta.ownership.meta.test_id = "ai.turn.process.toggle";
        if (self.button.behavior.interaction.a11y) |*attrs| attrs.expanded = turn.process_expanded;
        self.icon = try ui.iconTint(cx, if (turn.process_expanded) ui.icons.chevron_down else ui.icons.chevron_right, color, .{ .width = .{ .px = 12 }, .height = .{ .px = 12 }, .flex_shrink = 0 });
        try self.button.appendChild(cx.allocator, self.icon);
        try self.button.appendChild(cx.allocator, try ui.text(cx, "回合完成", .{ .font_size = 11.5, .line_height = 16.0 / 11.5, .color = color }));
        try root.appendChild(cx.allocator, self.button);
        self.divider = try ui.box(cx, .{ .width = .fill(), .height = .{ .px = 1 }, .flex_shrink = 0, .background = @import("app_theme.zig").current().fg_2.withAlpha(64) }, .{});
        self.divider.meta.ownership.meta.test_id = "ai.turn.divider";
        try root.appendChild(cx.allocator, self.divider);
        self.process = try ui.box(cx, .{ .width = .fill(), .height = .{ .fit = .{} }, .direction = .column, .gap = 8, .flex_shrink = 0, .min_width = 0 }, .{});
        self.process.meta.ownership.meta.test_id = "ai.turn.process";
        try root.appendChild(cx.allocator, self.process);
        if (turn.process_expanded) try self.ensureRendered();
        self.process.setDisplay(if (turn.process_expanded) .flex else .none);
        try parent.appendChild(cx.allocator, root);
        return self;
    }
    fn ensureRendered(self: *View) !void {
        if (self.rendered) return;
        const scope = try self.scope.childScope();
        errdefer {
            scope.dispose();
            while (self.process.children.items.len > 0) {
                const node = self.process.children.items[self.process.children.items.len - 1];
                self.cx.detachChild(self.process, node);
                self.cx.destroyDetached(node);
            }
        }
        try self.render(self.context, self.process, scope);
        self.rendered = true;
    }
    fn toggle(self: *View) void {
        const expanded = !self.turn.process_expanded;
        if (expanded) self.ensureRendered() catch |err| {
            std.log.warn("AI process disclosure: {s}", .{@errorName(err)});
            return;
        };
        self.turn.process_expanded = expanded;
        self.process.setDisplay(if (expanded) .flex else .none);
        if (self.button.behavior.interaction.a11y) |*attrs| attrs.expanded = expanded;
        const asset = if (expanded) ui.icons.chevron_down else ui.icons.chevron_right;
        if (asset.icon_id) |id| if (asset.pickRep(12)) |rep| self.icon.setIcon(.{ .icon_id = id, .rep = rep, .tint = @import("app_theme.zig").current().fg_2 });
        self.on_toggle.invoke();
        self.cx.requestRedraw();
    }
};
