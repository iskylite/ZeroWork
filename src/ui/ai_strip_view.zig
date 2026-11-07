const ui = @import("ui");
const S = @import("ai_strip_styles.zig");
pub const State = S.State;
pub const View = struct {
    cx: *ui.Cx,
    root: *ui.Node,
    dots: [3]*ui.Node,
    lip: *ui.Node,
    open: ui.Handler(void),
    hovered: *ui.Signal(bool),
    pub fn mount(cx: *ui.Cx, scope: *ui.Scope, open: ui.Handler(void)) !*View {
        const root = try ui.widgets.Button(.{ .variant = .ghost, .a11y_label = "打开 AI 助手", .base_style = S.trigger(), .hover_style = @as(ui.BoxStyle, .{ .background = ui.Color.TRANSPARENT }), .on_click = open }).mount(scope, cx);
        root.meta.ownership.meta.test_id = "ai.strip";
        for (root.children.items) |child| child.setDisplay(.none);
        root.setStyleInline(cx.allocator, S.trigger());
        const self = try scope.createState(View, .{ .cx = cx, .root = root, .dots = undefined, .lip = undefined, .open = open, .hovered = undefined });
        const lip = try ui.boxStyled(cx, S.lip, .{});
        self.lip = lip;
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
    pub fn update(self: *View, pane: ?ui.ComputedRect, visible: bool, state: State, phase: usize, expanded: bool) void {
        self.root.setDisplay(if (visible and pane != null) .flex else .none);
        const rect = pane orelse return;
        const parent = (self.root.parent orelse return).globalRect();
        const x = rect.x + (rect.w - S.width) / 2 - parent.x;
        const y = rect.y + rect.h + 11 - parent.y;
        const ext = self.root.style.ensureExtPanic(self.cx.allocator);
        if (ext.inset.left != .px or ext.inset.top != .px or @abs(ext.inset.left.px - x) > 0.5 or @abs(ext.inset.top.px - y) > 0.5) {
            ext.inset = .{ .left = .{ .px = x }, .top = .{ .px = y } };
            self.root.markLayoutDirty();
            self.root.markRenderDirty();
        }
        if (S.activeLip(expanded or self.hovered.get()).background) |paint| if (!ui.Color.eql(self.lip.getBackground(), paint)) self.lip.setBackground(paint);
        if (self.root.behavior.interaction.a11y) |*attrs| attrs.label = if (state == .unknown) "打开 AI 助手，执行结果仍待核实" else "打开 AI 助手";
        for (self.dots, 0..) |dot, index| {
            const paint = S.color(state, index, phase);
            if (!ui.Color.eql(dot.getBackground(), paint)) dot.setBackground(paint);
        }
        if (visible and (state == .working or state == .approval)) self.cx.scheduleRedrawAfterNs(200 * 1_000_000);
    }
};
