//! Virtual history rows inside the conversation's existing ScrollArea. The live
//! turn and approval surfaces stay outside the recycled history rows.
const std = @import("std");
const ui = @import("ui");
const Lists = ui.widgets.virtual_list;
const Provider = @typeInfo(@TypeOf(@as(ui.A11yProps, undefined).collection)).optional.child;
pub const Heights = std.AutoHashMapUnmanaged(usize, f32);
pub const View = struct {
    cx: *ui.Cx,
    scope: *ui.Scope,
    outer: ui.widgets.ScrollAreaResult,
    root: *ui.Node = undefined,
    state: *Lists.VirtualListState = undefined,
    context: *anyopaque,
    render: *const fn (*anyopaque, usize, *ui.Scope, *ui.Cx) anyerror!*ui.Node,
    keys: []const usize,
    heights: *Heights,
    ax_vtable: Provider.VTable = undefined,
    pub fn mount(cx: *ui.Cx, scope: *ui.Scope, outer: ui.widgets.ScrollAreaResult, keys: []const usize, heights: *Heights, context: *anyopaque, render: @FieldType(View, "render")) !*View {
        const self = try scope.createState(View, .{ .cx = cx, .scope = scope, .outer = outer, .keys = keys, .heights = heights, .context = context, .render = render });
        const list = try ui.widgets.VirtualList(.{ .item_count = keys.len, .measure_items = true, .estimate_item_height = 240, .overscan = 2, .translate_content = false }).mountWithContext(scope, cx, self, null, renderItem);
        self.root = list.container;
        self.state = list.state;
        // The outer conversation is the sole scroll/clip owner. Retain the
        // widget's scope/pool/measurement ledger, disable its nested scrollbar.
        self.root.behavior.events.on_event = null;
        self.root.meta.per_frame.hooks.before_render.main = null;
        self.root.setStyleInline(cx.allocator, .{ .width = .fill(), .height = .{ .px = self.state.totalContentHeight() }, .flex_shrink = 0, .overflow = .visible, .overflow_hidden = false });
        self.root.meta.ownership.meta.test_id = "ai.history.virtual";
        for (self.root.children.items) |node| if (node != self.state.content_node) {
            node.setDisplay(.none);
            node.setHitTestVisible(false);
        };
        self.state.container_node = outer.container;
        self.state.content_node.meta.ownership.meta.test_id = "ai.history.rows";
        self.state.content_node.behavior.events.event_context = self;
        self.state.content_node.meta.per_frame.hooks.before_render.main = tick;
        if (self.state.content_node.behavior.interaction.a11y) |*attrs| if (attrs.collection) |*provider| {
            self.ax_vtable = provider.vtable.*;
            self.ax_vtable.apply_scroll = applyAccessibleScroll;
            provider.vtable = &self.ax_vtable;
        };
        if (self.state.measured) |m| {
            for (keys, 0..) |key, i| if (heights.get(key)) |height| {
                _ = m.applyMeasurement(i, height, 0, .idle);
            };
            _ = m.consumeAdjustment();
        }
        return self;
    }
    fn renderItem(node: *ui.Node, index: usize, cx: *ui.Cx, raw: ?*anyopaque) void {
        const self: *View = @ptrCast(@alignCast(raw.?));
        ui.view.renderInto(self.scope, cx, node, renderRow, self, .{index}, "AI history row") catch {
            _ = Lists.markPoolNodeRenderIncomplete(node);
        };
    }
    fn renderRow(self: *View, index: usize, scope: *ui.Scope, cx: *ui.Cx) !*ui.Node {
        return self.render(self.context, index, scope, cx);
    }
    fn tick(node: *ui.Node) void {
        const self: *View = @ptrCast(@alignCast(node.behavior.events.event_context.?));
        const viewport = self.outer.container.globalRect();
        if (viewport.h <= 0) return;
        const relative = @max(0, viewport.y - self.root.globalRect().y);
        const total_before = self.state.totalContentHeight();
        const before = std.math.clamp(relative, 0, @max(0, total_before - viewport.h));
        self.state.scroll_state.viewport_height = viewport.h;
        self.state.scroll_state.scroll_y = before;
        self.state.scroll_state.bonus_y = 0;
        self.state.updateVisibleItems();
        const total = self.state.totalContentHeight();
        const adjustment = if (relative >= total_before) total - total_before else self.state.scroll_state.scroll_y - before;
        if (@abs(adjustment) > 0.1) {
            self.outer.state.content_height = @max(0, self.outer.state.content_height + total - total_before);
            ui.widgets.setScrollY(self.outer.state, self.outer.content, @max(0, self.outer.state.scroll_y + adjustment));
        }
        if (self.root.style.height != .px or @abs(self.root.style.height.px - total) > 0.1)
            self.root.setStyleInline(self.cx.allocator, .{ .height = .{ .px = total } });
        for (self.state.pool_bindings, self.state.pool_nodes) |binding, row| {
            const i = binding orelse continue;
            const height = row.globalRect().h;
            if (i < self.keys.len and height > 0) self.heights.put(self.cx.allocator, self.keys[i], height) catch {};
        }
    }
    fn applyAccessibleScroll(raw: *anyopaque, offset: f32) void {
        const state: *Lists.VirtualListState = @ptrCast(@alignCast(raw));
        const self: *View = @ptrCast(@alignCast(state.content_node.behavior.events.event_context.?));
        const base = self.root.globalRect().y + self.outer.state.scroll_y - self.outer.container.globalRect().y;
        ui.widgets.setScrollY(self.outer.state, self.outer.content, @max(0, base + offset));
        self.cx.requestRedraw();
    }
};
