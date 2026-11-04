//! Contextual help for existing controls, shared by the affected panels.
const ui = @import("ui");
const theme = @import("app_theme.zig");

pub const Options = struct {
    id: []const u8,
    layout: ui.BoxStyle = .{ .flex_shrink = 0 },
    width: ?f32 = null,
    visible: ?*ui.Signal(bool) = null,
    enabled: ?*ui.Signal(bool) = null,
    /// Preserve keyboard help when the hover target wraps an actual input.
    focus_target: ?*ui.Node = null,
};

const Visibility = struct {
    cx: *ui.Cx,
    control: ui.hit.NodeHandle,
    open: *ui.Signal(bool),
    enabled: ?*ui.Signal(bool),

    fn check(raw: *anyopaque, _: u8, _: bool) ui.AfterLayoutResult {
        const self: *Visibility = @ptrCast(@alignCast(raw));
        if (!self.open.peek()) return .done;
        if (self.enabled == null or self.enabled.?.peek()) {
            if (self.cx.node_registry.resolve(self.control, null)) |node| {
                if (node.isDisplayedInTree() and node.globalRect().w > 0 and node.globalRect().h > 0) return .done;
            }
        }
        self.open.set(false);
        self.cx.requestRedraw();
        return .needs_layout;
    }

    fn release(self: *Visibility) void {
        self.cx.removeAfterLayoutHook(self);
    }
};

const Hover = struct {
    enabled: *ui.Signal(bool),
    open: *ui.Signal(bool),

    fn show(self: *Hover) void {
        if (self.enabled.peek()) self.open.set(true);
    }
};

pub fn mount(cx: *ui.Cx, scope: *ui.Scope, control: *ui.Node, text: anytype, options: Options) !ui.widgets.TooltipResult {
    const tip = try ui.widgets.Tooltip(.{ .text = text, .open_delay_ms = 450, .position = .bottom_end, .width = options.width, .wrap = .word, .font_size = 11, .background = theme.current().overlay.withAlpha(255), .text_color = theme.current().fg_1 }).mount(scope, cx);
    tip.wrapper.setStyleInline(cx.allocator, options.layout);
    tip.trigger.setStyleInline(cx.allocator, options.layout);
    tip.content.meta.ownership.meta.test_id = options.id;
    tip.content.meta.per_frame.hooks.on_theme = struct {
        fn paint(node: *ui.Node, _: *const ui.ThemeTokens, _: @import("std").mem.Allocator) void {
            node.setBackground(theme.current().overlay.withAlpha(255));
        }
    }.paint;
    theme.bindInk(tip.content.children.items[0], "fg_1");
    try tip.trigger.appendChild(cx.allocator, control);
    if (options.enabled) |enabled| {
        const hover = try scope.createState(Hover, .{ .enabled = enabled, .open = tip.open.? });
        tip.wrapper.behavior.events.on_hover = cx.on(Hover, hover, Hover.show);
    }
    const focus = try ui.hooks.useFocusState(scope, cx, options.focus_target orelse control);
    try scope.createEffect(.{ .focused = focus.visible, .open = tip.open.?, .visible = options.visible, .enabled = options.enabled }, struct {
        fn update(value: anytype) void {
            const focused = value.focused.get();
            const visible = if (value.visible) |signal| signal.get() else true;
            const enabled = if (value.enabled) |signal| signal.get() else true;
            value.open.set(visible and enabled and focused);
        }
    }.update);
    const visibility = try scope.createState(Visibility, .{ .cx = cx, .control = .{ .id = control.id, .generation = try cx.node_registry.trackGeneration(control) }, .open = tip.open.?, .enabled = options.enabled });
    try cx.addAfterLayoutHook(visibility, Visibility.check);
    errdefer cx.removeAfterLayoutHook(visibility);
    try scope.onCleanup(Visibility, visibility, Visibility.release);
    return tip;
}
