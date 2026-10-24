const std = @import("std");
const ui = @import("ui");
const model_mod = @import("workspace_model.zig");
const identity = @import("../host/identity.zig");
const styles = @import("workspace_tab_styles.zig");
const theme = @import("app_theme.zig");

pub const Hooks = struct {
    context: *anyopaque,
    activate: *const fn (*anyopaque, identity.TabId) void,
    dismiss: *const fn (*anyopaque) void,
    status: *const fn (*anyopaque, identity.TabId) []const u8,
};

pub const View = struct {
    cx: *ui.Cx,
    scope: *ui.Scope,
    model: *model_mod.Model,
    picker: *model_mod.Picker,
    hooks: Hooks,
    wrapper: *ui.Node,
    chrome: *ui.Node = undefined,
    content: *ui.Node,
    rows: *ui.Node,
    scroll: ui.widgets.ScrollAreaResult,
    input: ui.widgets.input.InputResult,
    open: *ui.Signal(bool),
    query: *ui.Signal([]const u8),
    row_scope: ?*ui.Scope = null,
    dirty: bool = false,
    paint_revision: u32 = 0,

    pub fn mount(cx: *ui.Cx, scope: *ui.Scope, anchor: ui.widgets.popover.Anchor, model: *model_mod.Model, picker: *model_mod.Picker, hooks: Hooks) !*View {
        const self = try cx.allocator.create(View);
        const open = try scope.createSignal(bool, false);
        const query = try scope.createText("", .{});
        self.* = .{ .cx = cx, .scope = scope, .model = model, .picker = picker, .hooks = hooks, .wrapper = undefined, .content = undefined, .rows = undefined, .scroll = undefined, .input = undefined, .open = open, .query = query };
        try scope.onCleanup(View, self, cleanup);
        const popover = try ui.widgets.Popover(.{
            .open = open,
            .trigger = .manual,
            .anchor = anchor,
            .position = .bottom_start,
            .width = styles.picker_width,
            .max_width = styles.picker_width,
            .max_height = styles.picker_height,
            .offset = .{ .static = 8 },
            .viewport_padding = styles.picker_padding,
            .constrain_width_to_viewport = true,
            .shift_main_axis = true,
            .close_on_escape = false,
            .on_open_change = cx.on(View, self, openChanged),
        }).mount(scope, cx);
        self.scope = popover.scope;
        self.wrapper = popover.wrapper;
        self.chrome = popover.chrome;
        self.content = popover.content;
        popover.chrome.setStyleInline(cx.allocator, styles.panel());
        popover.chrome.setStyle(cx.allocator, .height, .{ .px = styles.picker_height });
        popover.chrome.meta.ownership.meta.test_id = "tabs.picker";
        popover.chrome.behavior.events.capture_context = self;
        popover.chrome.behavior.events.on_event_capture = onEvent;

        const field = try ui.box(cx, .{ .width = .fill(), .height = .{ .px = 53 }, .direction = .column, .gap = 8, .flex_shrink = 0 }, .{});
        try field.appendChild(cx.allocator, try ui.text(cx, "全部页签", .{ .font_size = 11, .font_weight = 600, .color = theme.current().fg_1, .line_height = 13.0 / 11.0 }));
        self.input = try ui.widgets.Input(.{ .value = query, .placeholder = "搜索名称、主机或类型…", .on_change = cx.on(View, self, queryChanged), .on_submit = cx.on(View, self, submit) }).mountResult(popover.scope, cx);
        self.input.input_container.setStyleInline(cx.allocator, styles.field());
        styles.tuneInput(&self.input);
        self.input.node.meta.ownership.meta.test_id = "tabs.picker.query";
        try field.appendChild(cx.allocator, self.input.node);
        try popover.content.appendChild(cx.allocator, field);

        self.scroll = try ui.widgets.ScrollArea(.{ .height = 159, .direction = .vertical, .rubber_band_y = false }).mount(popover.scope, cx);
        self.rows = self.scroll.content;
        self.rows.style.width = .fill();
        self.rows.style.gap = 8;
        try popover.content.appendChild(cx.allocator, self.scroll.container);
        const hint = try ui.text(cx, "↑↓ 选择   ↵ 切换   Esc 返回", styles.smallText());
        try popover.content.appendChild(cx.allocator, hint);
        return self;
    }

    pub fn show(self: *View, focus_return: u64) !void {
        self.retheme();
        try self.picker.show(self.cx.allocator, self.model, focus_return);
        self.query.set("");
        self.open.set(true);
        self.dirty = true;
        self.cx.setFocus(self.input.input_container);
        self.cx.requestRedraw();
    }

    pub fn hide(self: *View) void {
        self.open.set(false);
        _ = self.picker.dismiss();
        self.hooks.dismiss(self.hooks.context);
    }

    pub fn handleKey(self: *View, key: ui.events.KeyCode) ui.events.EventResult {
        if (!self.open.peek()) return .ignored;
        if (self.input.state.imeIsComposing()) return .ignored;
        switch (key) {
            .escape => self.hide(),
            .up, .down => {
                self.picker.move(if (key == .up) .previous else .next);
                self.dirty = true;
                self.cx.requestRedraw();
            },
            .@"return" => self.activate(),
            else => return .ignored,
        }
        return .stop;
    }

    pub fn flush(self: *View) !void {
        if (self.paint_revision != self.cx.theme_version) {
            self.retheme();
            self.dirty = true;
        }
        if (!self.dirty) return;
        self.dirty = false;
        if (self.row_scope) |old| old.dispose();
        self.row_scope = null;
        while (self.rows.children.items.len > 0) {
            const node = self.rows.children.items[0];
            self.cx.detachChild(self.rows, node);
            self.cx.destroyDetached(node);
        }
        const scope = try self.scope.childScope();
        self.row_scope = scope;
        if (self.picker.results.items.len == 0) {
            const empty = try ui.text(self.cx, "没有匹配的页签", .{ .font_size = 12, .color = theme.current().fg_3 });
            empty.meta.ownership.meta.test_id = "tabs.picker.empty";
            try self.rows.appendChild(self.cx.allocator, empty);
            return;
        }
        for (self.picker.results.items) |id| {
            const model_index = self.model.indexOf(id) orelse continue;
            const tab = &self.model.tabs.items[model_index];
            const highlighted = self.picker.highlighted == id;
            const row = try ui.widgets.Button(.{ .variant = .ghost, .base_style = styles.pickerRow(highlighted), .a11y_label = tab.name() }).mount(scope, self.cx);
            for (row.children.items) |child| child.setDisplay(.none);
            const row_context = try self.cx.allocator.create(RowContext);
            row_context.* = .{ .view = self, .id = id, .revision = self.picker.revision };
            try scope.onCleanup(RowContext, row_context, RowContext.cleanup);
            row.behavior.events.on_click = .{ .callback = RowContext.click, .context = row_context };
            row.meta.ownership.meta.test_id = "tabs.picker.row";
            // Button supplies keyboard/press/focus behavior; native child nodes
            // provide the prototype's two-line row content and right status.
            const labels = try ui.box(self.cx, .{ .width = .fill(), .direction = .column, .gap = 3 }, .{});
            try labels.appendChild(self.cx.allocator, try ui.text(self.cx, tab.name(), .{ .font_size = 12, .font_weight = 500, .color = theme.current().fg_1, .text_overflow = .ellipsis }));
            try labels.appendChild(self.cx.allocator, try ui.text(self.cx, tab.details, .{ .font_size = 10, .color = theme.current().fg_3, .text_overflow = .ellipsis }));
            try row.appendChild(self.cx.allocator, labels);
            try row.appendChild(self.cx.allocator, try ui.text(self.cx, self.hooks.status(self.hooks.context, id), .{ .font_size = 10, .color = if (self.model.active == id) theme.current().accent_ink else theme.current().fg_3 }));
            try self.rows.appendChild(self.cx.allocator, row);
        }
        if (self.picker.highlighted) |id| {
            for (self.picker.results.items, 0..) |candidate, index| if (candidate == id) {
                const top = @as(f32, @floatFromInt(index)) * (styles.picker_row_height + 8);
                const bottom = top + styles.picker_row_height;
                if (top < self.scroll.state.scroll_y) self.scroll.state.scroll_y = top;
                if (bottom > self.scroll.state.scroll_y + 159) self.scroll.state.scroll_y = bottom - 159;
                break;
            };
        }
        self.rows.markLayoutDirty();
    }

    fn retheme(self: *View) void {
        const c = theme.current();
        self.chrome.setBackground(c.overlay);
        self.input.input_container.setBackground(c.well);
        self.input.input_container.setBorderColor(ui.Color.TRANSPARENT);
        self.input.state.tokens = self.cx.tokens;
        self.input.state.dirty = true;
        if (self.input.state.text_display_node) |node| node.setTextColor(c.fg_1);
        self.paint_revision = self.cx.theme_version;
    }

    fn queryChanged(self: *View, query: []const u8) void {
        self.picker.update(self.cx.allocator, self.model, query) catch return;
        self.dirty = true;
        self.cx.requestRedraw();
    }
    fn submit(self: *View, _: []const u8) void {
        self.activate();
    }
    fn activate(self: *View) void {
        self.picker.activate(self.model, self.picker.revision) catch return;
        const id = self.model.active orelse return;
        self.hide();
        self.hooks.activate(self.hooks.context, id);
    }
    fn openChanged(self: *View, open: bool) void {
        if (!open) {
            _ = self.picker.dismiss();
            self.hooks.dismiss(self.hooks.context);
        }
    }
    fn onEvent(event: ui.events.Event, context: ?*anyopaque) ui.events.EventResult {
        const self: *View = @ptrCast(@alignCast(context orelse return .ignored));
        return if (event == .key_down) self.handleKey(event.key_down.key) else .ignored;
    }
    fn cleanup(self: *View) void {
        self.cx.allocator.destroy(self);
    }
};

const RowContext = struct {
    view: *View,
    id: identity.TabId,
    revision: u64,
    fn click(context: *anyopaque) void {
        const self: *RowContext = @ptrCast(@alignCast(context));
        if (!self.view.picker.open or self.revision != self.view.picker.revision) return;
        self.view.picker.highlighted = self.id;
        self.view.activate();
    }
    fn cleanup(self: *RowContext) void {
        self.view.cx.allocator.destroy(self);
    }
};

test "picker uses prototype panel and rows; no-match Enter preserves active tab" {
    var cx = try ui.Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    const scope = try ui.Scope.init(std.testing.allocator, null, cx.owner);
    defer scope.dispose();
    const root = try ui.box(cx, .{ .width = .fill(), .height = .fill() }, .{});
    cx.root = root;
    const anchor = try ui.box(cx, .{ .position = .absolute, .inset = .{ .left = .{ .px = 780 }, .top = .{ .px = 16 } }, .width = .{ .px = 28 }, .height = .{ .px = 28 } }, .{});
    try root.appendChild(cx.allocator, anchor);
    var model: model_mod.Model = .{ .allocator = std.testing.allocator, .window = @fromBackingInt(1), .workspace = @fromBackingInt(1) };
    defer model.deinit();
    const first: identity.TabId = @fromBackingInt(1);
    const second: identity.TabId = @fromBackingInt(2);
    try model.append(first, .{ .session = .{ .session_id = @fromBackingInt(91) } }, "same");
    try model.setDetails(first, "test@one.example · SSH");
    try model.append(second, .{ .session = .{ .session_id = @fromBackingInt(92) } }, "same");
    try model.setDetails(second, "test@two.example · SSH");
    var picker: model_mod.Picker = .{};
    defer picker.deinit(std.testing.allocator);
    const Sink = struct {
        activations: usize = 0,
        fn activate(context: *anyopaque, _: identity.TabId) void {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.activations += 1;
        }
        fn dismiss(_: *anyopaque) void {}
        fn status(_: *anyopaque, _: identity.TabId) []const u8 {
            return "在线";
        }
    };
    var sink: Sink = .{};
    const view = try View.mount(cx, scope, .{ .node = anchor }, &model, &picker, .{ .context = &sink, .activate = Sink.activate, .dismiss = Sink.dismiss, .status = Sink.status });
    try root.appendChild(cx.allocator, view.wrapper);
    cx.setViewport(860, 480);
    try view.show(1);
    try view.flush();
    cx.layout();
    try std.testing.expectApproxEqAbs(styles.picker_width, view.content.globalRect().w, 0.01);
    try std.testing.expectApproxEqAbs(styles.picker_height, view.content.globalRect().h, 0.01);
    try std.testing.expectEqual(@as(usize, 2), view.rows.children.items.len);
    try std.testing.expectApproxEqAbs(@as(f32, 392), view.input.input_container.globalRect().w, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 392), view.rows.children.items[0].globalRect().w, 0.01);
    try std.testing.expectApproxEqAbs(styles.picker_row_height, view.rows.children.items[0].globalRect().h, 0.01);
    view.query.set("absent");
    view.queryChanged("absent");
    try view.flush();
    _ = view.handleKey(.@"return");
    try std.testing.expectEqual(@as(usize, 0), sink.activations);
    try std.testing.expectEqual(second, model.active.?);
    try std.testing.expectEqualStrings("absent", picker.query.items);
    _ = view.handleKey(.escape);
    try std.testing.expect(!picker.open);
    try std.testing.expectEqual(second, model.active.?);
}
