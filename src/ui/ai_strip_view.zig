const ui = @import("ui");
const S = @import("ai_strip_styles.zig");
pub const State = S.State;
pub const View = struct {
    cx: *ui.Cx,
    root: *ui.Node,
    dots: [3]*ui.Node,
    open: ui.Handler(void),
    hovered: *ui.Signal(bool),
    pub fn mount(cx: *ui.Cx, scope: *ui.Scope, open: ui.Handler(void)) !*View {
        const root = try ui.widgets.Button(.{ .variant = .ghost, .a11y_label = "打开 AI 助手", .base_style = S.trigger(), .hover_style = @as(ui.BoxStyle, .{ .background = ui.Color.TRANSPARENT }), .on_click = open }).mount(scope, cx);
        root.meta.ownership.meta.test_id = "ai.strip";
        for (root.children.items) |child| child.setDisplay(.none);
        root.setStyleInline(cx.allocator, S.trigger());
        const self = try scope.createState(View, .{ .cx = cx, .root = root, .dots = undefined, .open = open, .hovered = undefined });
        const lip = try ui.boxStyled(cx, S.lip, .{});
        lip.meta.ownership.meta.test_id = "ai.strip.lip";
        try root.appendChild(cx.allocator, lip);
        for (&self.dots, 0..) |*dot, index| {
            dot.* = try ui.boxStyled(cx, S.dot, .{});
            dot.*.meta.ownership.meta.test_id = switch (index) {
                0 => "ai.strip.dot.0",
                1 => "ai.strip.dot.1",
                else => "ai.strip.dot.2",
            };
            try lip.appendChild(cx.allocator, dot.*);
        }
        const hovered = try ui.hooks.useHover(scope, root);
        self.hovered = hovered;
        root.setDisplay(.none);
        return self;
    }
    pub fn update(self: *View, pane: ?ui.ComputedRect, visible: bool, state: State, phase: usize) void {
        self.root.setDisplay(if (visible and pane != null) .flex else .none);
        const rect = pane orelse return;
        self.root.style.align_items = .center;
        self.root.style.justify = .center;
        self.root.style.gap = 0;
        const parent = (self.root.parent orelse return).globalRect();
        const x = rect.x + (rect.w - 88) / 2 - parent.x;
        const y = rect.y + rect.h - 9 - parent.y;
        const ext = self.root.style.ensureExtPanic(self.cx.allocator);
        if (ext.inset.left != .px or ext.inset.top != .px or @abs(ext.inset.left.px - x) > 0.5 or @abs(ext.inset.top.px - y) > 0.5) {
            ext.inset = .{ .left = .{ .px = x }, .top = .{ .px = y } };
            self.root.markLayoutDirty();
            self.root.markRenderDirty();
        }
        for (self.dots, 0..) |dot, index| dot.setStyleInline(self.cx.allocator, .{ .background = S.color(state, index, phase) });
        if (visible and (state == .working or state == .approval)) self.cx.scheduleRedrawAfterNs(200 * 1_000_000);
    }
};
