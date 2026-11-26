//! V0.8 附着式 AI 助手右侧固定槽位。The slot only owns layout: the assistant
//! card keeps its own AgentRuntime, ConversationId and worker while docked.
const std = @import("std");
const ui = @import("ui");
const theme = @import("app_theme.zig");

pub const min_width: f32 = 360;
pub const default_width: f32 = 468;
pub const gap: f32 = 12;
/// Even at the window minimum, reserve room for the terminal and the dock's
/// real controls rather than letting an oversized left rail clip them.
pub const min_row_width: f32 = 592;
const max_preference_width: f32 = 2400;

pub const Hooks = struct {
    context: *anyopaque,
    persist: *const fn (*anyopaque, f32) void,
};

const WidthRange = struct { min: f32, max: f32 };

fn widthRange(row_width: f32, window_width: f32) WidthRange {
    // Ask the current row (after the host rail has taken its space), not the
    // window, how much room can be shared by the terminal and the assistant.
    const terminal_room = @min(260, row_width * 0.4);
    const max = @max(0, @min(@max(min_width, window_width * 0.5), row_width - gap - terminal_room));
    return .{ .min = @min(min_width, max), .max = max };
}

pub const View = struct {
    cx: *ui.Cx,
    hooks: Hooks,
    parent: *ui.Node,
    root: *ui.Node,
    card_slot: *ui.Node,
    grip: *ui.Node,
    preferred_width: f32 = default_width,
    effective_width: f32 = default_width,
    drag_start: f32 = default_width,
    drag_restore: f32 = default_width,
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
        const self = try scope.createState(View, .{ .cx = cx, .hooks = hooks, .parent = parent, .root = root, .card_slot = card_slot, .grip = grip });
        _ = try ui.interaction.drag.Binding.attach(scope, cx, grip, .{ .axis = .horizontal, .activation_distance = 1, .active_cursor = .ew_resize }, View.drag, self);
        try parent.appendChild(cx.allocator, root);
        self.setWidth(initial);
        try cx.addAfterLayoutHook(self, View.afterLayout);
        errdefer cx.removeAfterLayoutHook(self);
        try scope.onCleanup(View, self, View.cleanup);
        return self;
    }

    pub fn setOpen(self: *View, open: bool) void {
        self.root.setDisplay(if (open) .flex else .none);
        if (open) _ = self.applyWidth();
    }

    pub fn setWidth(self: *View, value: f32) void {
        self.preferred_width = if (std.math.isFinite(value)) std.math.clamp(value, min_width, max_preference_width) else default_width;
        _ = self.applyWidth();
    }

    fn limits(self: *const View) WidthRange {
        const parent_width = self.parent.globalRect().w;
        const window_width = self.cx.viewport.width;
        return widthRange(if (parent_width > 0) parent_width else window_width, window_width);
    }

    fn applyWidth(self: *View) bool {
        const range = self.limits();
        self.effective_width = std.math.clamp(self.preferred_width, range.min, range.max);
        self.grip.setHitTestVisible(range.max - range.min > 0.5);
        const width: ui.Sizing = .{ .px = self.effective_width };
        const root_width: ui.Sizing = .{ .px = self.effective_width + gap };
        var changed = false;
        if (!std.meta.eql(self.root.style.width, root_width)) {
            self.root.setStyleInline(self.cx.allocator, .{ .width = root_width });
            changed = true;
        }
        if (!std.meta.eql(self.card_slot.style.width, width)) {
            self.card_slot.setStyleInline(self.cx.allocator, .{ .width = width });
            changed = true;
        }
        return changed;
    }

    fn afterLayout(raw: *anyopaque, _: u8, _: bool) ui.AfterLayoutResult {
        const self: *View = @ptrCast(@alignCast(raw));
        return if (self.root.style.display != .none and self.applyWidth()) .needs_layout else .done;
    }

    fn cleanup(self: *View) void {
        self.cx.removeAfterLayoutHook(self);
    }

    pub fn attach(self: *View, card: *ui.Node) !void {
        try self.card_slot.appendChild(self.cx.allocator, card);
        _ = self.applyWidth();
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
                self.drag_start = self.effective_width;
                self.drag_restore = self.preferred_width;
            },
            .move => {
                const range = self.limits();
                if (range.max - range.min <= 0.5) return;
                self.setWidth(std.math.clamp(self.drag_start - event.delta.x, range.min, range.max));
                self.cx.requestRedraw();
            },
            .end => {
                self.dragging = false;
                if (@abs(self.preferred_width - self.drag_restore) > 0.5)
                    self.hooks.persist(self.hooks.context, self.preferred_width);
            },
            .cancel => {
                self.dragging = false;
                self.setWidth(self.drag_restore);
            },
        }
    }
};

test "dock budget respects the actual row and retains terminal room" {
    const small = widthRange(592, 860);
    try std.testing.expectApproxEqAbs(@as(f32, 343.2), small.max, 0.01);
    try std.testing.expectEqual(small.min, small.max);
    const wide = widthRange(1154, 1440);
    try std.testing.expect(wide.min <= default_width and wide.max >= default_width);
    try std.testing.expect(wide.max + gap < 1154);
}
