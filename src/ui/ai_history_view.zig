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
    fingerprints: []const u64 = &.{},
    heights: *Heights,
    ax_vtable: Provider.VTable = undefined,
    pub fn mount(cx: *ui.Cx, scope: *ui.Scope, outer: ui.widgets.ScrollAreaResult, keys: []const usize, heights: *Heights, context: *anyopaque, render: @FieldType(View, "render")) !*View {
        const owned_keys = try cx.allocator.dupe(usize, keys);
        const self = scope.createState(View, .{ .cx = cx, .scope = scope, .outer = outer, .keys = owned_keys, .heights = heights, .context = context, .render = render }) catch |err| {
            cx.allocator.free(owned_keys);
            return err;
        };
        scope.onCleanup(View, self, cleanup) catch |err| {
            cx.allocator.free(owned_keys);
            return err;
        };
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
        self.root.setStyleInline(cx.allocator, .{ .height = .{ .px = self.state.totalContentHeight() } });
        return self;
    }
    fn cleanup(self: *View) void {
        self.cx.allocator.free(self.keys);
        self.cx.allocator.free(self.fingerprints);
    }
    /// Preserve the list, measurements and bound prefix when history is appended
    /// or truncated. Only rows whose rendered input changed are refreshed.
    pub fn update(self: *View, keys: []const usize, fingerprints: []const u64) !void {
        std.debug.assert(keys.len == fingerprints.len);
        const next_keys = try self.cx.allocator.dupe(usize, keys);
        errdefer self.cx.allocator.free(next_keys);
        const next_fingerprints = try self.cx.allocator.dupe(u64, fingerprints);
        const old_keys = self.keys;
        const old_fingerprints = self.fingerprints;
        defer self.cx.allocator.free(old_keys);
        defer self.cx.allocator.free(old_fingerprints);
        self.keys = next_keys;
        self.fingerprints = next_fingerprints;
        const common = @min(old_keys.len, keys.len);
        const stable_prefix = std.mem.eql(usize, old_keys[0..common], keys[0..common]);
        if (!stable_prefix) {
            Lists.updateItemCount(self.state, keys.len);
            Lists.invalidateAllMeasurements(self.state);
            for (keys) |key| _ = self.heights.remove(key);
        } else {
            if (keys.len != old_keys.len) {
                // updateItemCount intentionally clears the whole pool. For an
                // unchanged prefix, grow/shrink its public ledger directly and
                // let updateVisibleItems recycle only rows outside the range.
                self.state.item_count = keys.len;
                self.state.a11y_generation +%= 1;
                if (self.state.measured) |ledger| ledger.setCount(keys.len);
                self.state.initialized = false;
            }
            for (keys[0..common], 0..) |key, index| {
                if (index < old_fingerprints.len and old_fingerprints[index] == fingerprints[index]) continue;
                _ = self.heights.remove(key);
                Lists.invalidateMeasurement(self.state, index);
                Lists.refreshRange(self.state, index, index + 1);
            }
        }
        self.root.setStyleInline(self.cx.allocator, .{ .height = .{ .px = self.state.totalContentHeight() } });
        self.state.content_node.markLayoutDirty();
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
        // Measured slots are pinned to px. Their fit-content child can change
        // when a disclosure opens/closes without changing the row's data key.
        // Release only those slots, then let layout run before collecting them.
        var remeasure = false;
        for (self.state.pool_bindings, self.state.pool_nodes) |binding, row| {
            const i = binding orelse continue;
            if (row.style.height != .px or row.children.items.len != 1) continue;
            const intrinsic = row.children.items[0].globalRect().h;
            if (intrinsic > 0 and @abs(intrinsic - row.globalRect().h) > 0.1) {
                Lists.invalidateMeasurement(self.state, i);
                if (i < self.keys.len) _ = self.heights.remove(self.keys[i]);
                remeasure = true;
            }
        }
        if (remeasure) {
            self.cx.requestRedraw();
            return;
        }
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
