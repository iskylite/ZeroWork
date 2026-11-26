//! V0.8 附着式 AI 助手右侧固定槽位。The slot only owns layout: the assistant
//! card keeps its own AgentRuntime, ConversationId and worker while docked.
const std = @import("std");
const ui = @import("ui");
const theme = @import("app_theme.zig");

pub const min_width: f32 = 360;
pub const default_width: f32 = 468;
pub const gap: f32 = 12;

pub const Hooks = struct {
    context: *anyopaque,
    resize: *const fn (*anyopaque, f32) void,
    persist: *const fn (*anyopaque, f32) void,
};

pub const View = struct {
    cx: *ui.Cx,
    scope: *ui.Scope,
    hooks: Hooks,
    root: *ui.Node,
    card_slot: *ui.Node,
    grip: *ui.Node,
    width: f32 = default_width,
    drag_start: f32 = default_width,
    dragging: bool = false,

    pub fn mount(cx: *ui.Cx, scope: *ui.Scope, parent: *ui.Node, hooks: Hooks, initial: f32) !*View {
        const root = try ui.box(cx, .{ .height = .fill(), .flex_shrink = 0, .direction = .row, .align_items = .stretch, .gap = 0, .min_width = 0 }, .{});
        root.meta.ownership.meta.test_id = "workspace.ai_dock";
        root.setDisplay(.none);
        const grip = try ui.box(cx, .{ .width = .{ .px = gap }, .height = .fill(), .flex_shrink = 0, .cursor = .ew_resize, .hit_behavior = .@"opaque" }, .{});
        grip.meta.ownership.meta.test_id = "workspace.ai_dock.grip";
        try root.appendChild(cx.allocator, grip);
        const card_slot = try ui.box(cx, .{ .height = .fill(), .min_width = 0, .direction = .column, .flex_shrink = 0 }, .{});
        card_slot.meta.ownership.meta.test_id = "workspace.ai_dock.slot";
        try root.appendChild(cx.allocator, card_slot);
        const self = try scope.createState(View, .{ .cx = cx, .scope = scope, .hooks = hooks, .root = root, .card_slot = card_slot, .grip = grip, .width = @max(min_width, initial) });
        _ = try ui.interaction.drag.Binding.attach(scope, cx, grip, .{ .axis = .horizontal, .activation_distance = 1, .active_cursor = .ew_resize }, View.drag, self);
        try parent.appendChild(cx.allocator, root);
        return self;
    }

    pub fn setOpen(self: *View, open: bool) void {
        self.root.setDisplay(if (open) .flex else .none);
        self.applyWidth(self.width);
    }

    pub fn setWidth(self: *View, value: f32) void {
        self.width = value;
        self.applyWidth(value);
    }

    fn applyWidth(self: *View, value: f32) void {
        const max = @max(min_width, self.cx.viewport.width * 0.5);
        self.width = std.math.clamp(value, min_width, max);
        const width: ui.Sizing = .{ .px = self.width };
        if (!std.meta.eql(self.card_slot.style.width, width))
            self.card_slot.setStyleInline(self.cx.allocator, .{ .width = width });
    }

    pub fn attach(self: *View, card: *ui.Node) !void {
        try self.card_slot.appendChild(self.cx.allocator, card);
        self.applyWidth(self.width);
        card.setStyleInline(self.cx.allocator, .{
            .position = .relative,
            .inset = .{ .left = .{ .px = 0 }, .top = .{ .px = 0 } },
            .width = .fill(),
            .height = .fill(),
            .min_width = 0,
            .flex_shrink = 0,
            .direction = .column,
            .background = theme.current().surface_1,
            .glass = theme.overlayGlass(),
            .border = .{ .width = 0, .color = ui.Color.TRANSPARENT, .radius = 16 },
            .shadow = .{ .color = ui.Color.TRANSPARENT },
            .shadows = ui.ShadowList.of(&.{}),
            .overflow = .hidden,
        });
        card.setDisplay(.flex);
        card.setHitTestVisible(true);
        card.setOpacityRaw(1);
    }

    fn drag(event: ui.interaction.drag.Event, raw: *anyopaque) void {
        const self: *View = @ptrCast(@alignCast(raw));
        switch (event.phase) {
            .start => {
                self.dragging = true;
                self.drag_start = self.width;
            },
            .move => {
                self.applyWidth(self.drag_start - event.delta.x);
                self.hooks.resize(self.hooks.context, self.width);
                self.cx.requestRedraw();
            },
            .end => {
                self.dragging = false;
                self.hooks.persist(self.hooks.context, self.width);
            },
            .cancel => {
                self.dragging = false;
                self.applyWidth(self.drag_start);
                self.hooks.resize(self.hooks.context, self.width);
            },
        }
    }
};
