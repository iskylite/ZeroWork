//! BMC-local presentation for Select's stable portaled chrome. The Select
//! remains the owner of values, keyboard navigation and overlay dismissal.
const ui = @import("ui");
const S = @import("styles.zig");

pub fn mount(cx: *ui.Cx, select: ui.widgets.SelectResult) !void {
    const scroll = try ui.widgets.ScrollArea(.{ .height = @as(f32, 1), .direction = .vertical, .rubber_band_y = false }).mount(select.scope, cx);
    scroll.container.setStyleInline(cx.allocator, .{ .width = .fill(), .flex_shrink = 0 });
    select.chrome.setStyleInline(cx.allocator, S.selectDropdown());
    select.panel.setStyleInline(cx.allocator, .{ .gap = 0 });
    cx.detachChild(select.chrome, select.panel);
    try scroll.content.appendChild(cx.allocator, select.panel);
    try select.chrome.appendChild(cx.allocator, scroll.container);
    const self = try select.scope.createState(Surface, .{ .cx = cx, .select = select, .scroll = scroll });
    try cx.addAfterLayoutHook(self, Surface.afterLayout);
    errdefer cx.removeAfterLayoutHook(self);
    try select.scope.onCleanup(Surface, self, Surface.cleanup);
}

const Surface = struct {
    cx: *ui.Cx,
    select: ui.widgets.SelectResult,
    scroll: ui.widgets.scroll_area.ScrollAreaResult,
    highlighted: ?usize = null,

    fn cleanup(self: *Surface) void {
        self.cx.removeAfterLayoutHook(self);
    }
    fn afterLayout(raw: *anyopaque, _: u8, _: bool) ui.AfterLayoutResult {
        const self: *Surface = @ptrCast(@alignCast(raw));
        const state = ui.widgets.select.stateOf(self.select);
        const rows = state.option_nodes;
        var changed = false;
        // Options are rebuilt by Select when a fresh device snapshot arrives.
        // Style those live rows rather than retaining their previous pointers.
        for (rows) |row| {
            const height = switch (row.style.height) {
                .px => |value| value,
                else => -1,
            };
            if (height != 32) {
                row.setStyleInline(self.cx.allocator, S.selectOption());
                changed = true;
            }
        }
        const anchor = self.select.trigger.globalRect();
        // Popover flips to the roomier side; reserve its 4px anchor offset,
        // 8px viewport margin and the shared menu's two 5px insets.
        const room = @max(anchor.y - 12, self.cx.viewport.height - anchor.y - anchor.h - 12);
        const height = @max(1, @min(@as(f32, @floatFromInt(rows.len)) * 32, @min(270, room - 10)));
        const current = switch (self.scroll.container.style.height) {
            .px => |value| value,
            else => -1,
        };
        if (@abs(current - height) > 0.1) {
            self.scroll.container.setStyleInline(self.cx.allocator, .{ .height = .{ .px = height } });
            changed = true;
        }
        const glass = S.theme.overlayGlass();
        if (self.select.chrome.style.backdrop_blur() != glass.backdrop_blur) {
            self.select.chrome.setStyleInline(self.cx.allocator, .{ .glass = glass });
        }
        if (!state.shown_open or state.highlighted_index == null) {
            self.highlighted = null;
        } else if (state.highlighted_index != self.highlighted) {
            const index = state.highlighted_index.?;
            // Select owns keyboard navigation; follow only a new highlight so
            // wheel scrolling remains independent. Wait for resized geometry.
            if (changed or @abs(self.scroll.state.viewport_height - self.scroll.container.globalRect().h) > 0.1) {
                self.cx.requestRedraw();
            } else if (index < rows.len) {
                ui.widgets.scroll_area.scrollIntoView(self.scroll.state, self.scroll.content, rows[index], .nearest);
                self.highlighted = index;
            }
        }
        return if (changed) .needs_layout else .done;
    }
};
