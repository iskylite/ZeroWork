//! Shared picker for adding or replacing a saved SSH route hop.
const std = @import("std");
const ui = @import("ui");
const S = @import("../../ui/wizard_styles.zig");

pub const RoutePicker = struct {
    pub const Target = union(enum) { insert: usize, replace: usize };
    pub const Actions = struct {
        context: *anyopaque,
        options: *const fn (*anyopaque, Target) []const ui.widgets.SelectOption,
        available: *const fn (*anyopaque, Target, []const u8) bool,
        choose: *const fn (*anyopaque, Target, []const u8) void,
        anchor_gap: ?*const fn (*anyopaque, Target) f32 = null,
        anchor_changed: ?*const fn (*anyopaque, Target, bool) void = null,
    };

    const Option = struct {
        picker: *RoutePicker,
        value: []const u8,
        fn choose(self: *Option) void {
            self.picker.choose(self.value);
        }
    };

    cx: *ui.Cx,
    actions: Actions,
    popup: ui.widgets.popover.PopoverResult = undefined,
    input: ui.widgets.input.InputResult = undefined,
    query: *ui.Signal([]const u8) = undefined,
    list: ui.widgets.ScrollAreaResult = undefined,
    row_scope: ?*ui.Scope = null,
    source: ?*ui.Node = null,
    target: Target = .{ .insert = 0 },
    dirty: bool = false,
    focus_pending: bool = false,

    pub fn mount(cx: *ui.Cx, scope: *ui.Scope, parent: *ui.Node, actions: Actions) !*RoutePicker {
        const self = try scope.createState(RoutePicker, .{ .cx = cx, .actions = actions });
        self.popup = try ui.widgets.Popover(.{
            .trigger = .manual,
            .position = .bottom,
            .width = 216,
            .max_height = 202,
            .offset = .{ .static = 10 },
            .anchor = .{ .virtual = .{ .ctx = self, .getRect = anchor } },
            .on_open_change = cx.on(RoutePicker, self, openChanged),
            .constrain_width_to_viewport = true,
            .shift_main_axis = true,
            .close_on_escape = true,
            .size_policy = .fit_content,
            .a11y_role = .dialog,
        }).mount(scope, cx);
        const popup = self.popup;
        popup.wrapper.setStyleInline(cx.allocator, .{ .position = .absolute, .width = .{ .px = 0 }, .height = .{ .px = 0 } });
        try parent.appendChild(cx.allocator, popup.wrapper);
        popup.content.meta.ownership.meta.test_id = "wizard.route.picker";
        popup.content.setStyleInline(cx.allocator, .{ .padding = ui.Padding.all(8), .direction = .column, .gap = 6 });
        self.query = try popup.scope.createText("", .{});
        self.input = try ui.widgets.Input(.{
            .value = self.query,
            .placeholder = "搜索 SSH 主机",
            .size = .sm,
            .leading_icon_asset = ui.icons.search,
            .on_change = cx.on(RoutePicker, self, queryChanged),
            .on_submit = cx.on(RoutePicker, self, submit),
        }).mountResult(popup.scope, cx);
        self.input.input_container.meta.ownership.meta.test_id = "wizard.route.search";
        try popup.content.appendChild(cx.allocator, self.input.node);
        self.list = try ui.widgets.ScrollArea(.{ .direction = .vertical, .rubber_band_y = false }).mount(popup.scope, cx);
        self.list.content.setStyleInline(cx.allocator, .{ .width = .fill(), .height = .{ .fit = .{} }, .direction = .column, .gap = 2 });
        try popup.content.appendChild(cx.allocator, self.list.container);
        self.paint();
        return self;
    }

    fn anchor(raw: *anyopaque) ui.widgets.popover.AnchorRect {
        const self: *RoutePicker = @ptrCast(@alignCast(raw));
        const rect = (self.source orelse return .{ .x = 0, .y = 0, .w = 0, .h = 0 }).globalRect();
        const gap = if (self.actions.anchor_gap) |get| get(self.actions.context, self.target) else 0;
        return .{ .x = rect.x, .y = rect.y, .w = rect.w, .h = rect.h + gap };
    }

    pub fn show(self: *RoutePicker, source: *ui.Node, target: Target) void {
        self.source = source;
        self.target = target;
        self.query.set("");
        self.dirty = true;
        self.focus_pending = true;
        self.popup.show.invoke();
        self.paintAnchor(true);
        self.cx.requestRedraw();
    }

    fn paintAnchor(self: *RoutePicker, active: bool) void {
        if (self.actions.anchor_changed) |changed| changed(self.actions.context, self.target, active);
    }

    pub fn close(self: *RoutePicker) void {
        if (self.popup.open.?.peek()) self.popup.close.invoke();
    }

    fn openChanged(self: *RoutePicker, open: bool) void {
        if (open) return;
        self.paintAnchor(false);
        self.focus_pending = false;
        if (self.source) |source| self.cx.setFocus(source);
    }

    pub fn paint(self: *RoutePicker) void {
        self.popup.chrome.setBackground(S.theme.popupAction());
        self.input.input_container.setBackground(S.theme.popupInset());
        self.input.state.tokens = self.cx.tokens;
        self.input.state.dirty = true;
        if (self.popup.open.?.peek()) self.paintAnchor(true);
        self.dirty = true;
    }

    fn queryChanged(self: *RoutePicker, _: []const u8) void {
        self.dirty = true;
        self.cx.requestRedraw();
    }

    fn options(self: *RoutePicker) []const ui.widgets.SelectOption {
        return self.actions.options(self.actions.context, self.target);
    }

    fn available(self: *RoutePicker, option: ui.widgets.SelectOption) bool {
        return !option.disabled and self.actions.available(self.actions.context, self.target, option.value);
    }

    fn matches(self: *RoutePicker, option: ui.widgets.SelectOption) bool {
        const query = std.mem.trim(u8, self.query.peek(), " \t\r\n");
        return self.available(option) and std.ascii.findIgnoreCase(option.label, query) != null;
    }

    fn submit(self: *RoutePicker, _: []const u8) void {
        for (self.options()) |option| if (self.matches(option)) {
            self.choose(option.value);
            return;
        };
    }

    fn choose(self: *RoutePicker, value: []const u8) void {
        if (!self.popup.open.?.peek()) return;
        for (self.options()) |option| if (std.mem.eql(u8, option.value, value) and self.available(option)) {
            self.actions.choose(self.actions.context, self.target, option.value);
            return;
        };
    }

    pub fn update(self: *RoutePicker) bool {
        if (!self.popup.open.?.peek()) return false;
        if (self.dirty) {
            self.dirty = false;
            self.rebuild() catch return false;
            return true;
        }
        if (self.focus_pending) {
            self.focus_pending = false;
            self.cx.setFocus(self.input.input_container);
        }
        return false;
    }

    fn rebuild(self: *RoutePicker) !void {
        const cx = self.cx;
        const a = cx.allocator;
        const list = self.list.content;
        for (list.children.items) |node| cx.invalidateReferencesTo(node);
        if (self.row_scope) |scope| scope.dispose();
        self.row_scope = null;
        while (list.children.items.len != 0) {
            const node = list.children.items[list.children.items.len - 1];
            cx.detachChild(list, node);
            cx.destroyDetached(node);
        }
        const scope = try self.popup.scope.childScope();
        self.row_scope = scope;
        var count: usize = 0;
        for (self.options()) |option| {
            if (!self.matches(option)) continue;
            const ctx = try scope.createState(Option, .{ .picker = self, .value = option.value });
            var style = S.row(30);
            style.padding = .{ .left = 8 };
            style.background = if (count == 0) S.theme.popupSelection() else ui.Color.TRANSPARENT;
            style.border = .{ .radius = 6 };
            style.justify = .start;
            const row = try ui.widgets.Button(.{ .variant = .ghost, .a11y_label = option.label, .base_style = style, .on_click = cx.on(Option, ctx, Option.choose) }).mount(scope, cx);
            for (row.children.items) |child| child.setDisplay(.none);
            row.setStyleInline(a, style);
            row.meta.ownership.meta.test_id = "wizard.route.option";
            try row.appendChild(a, try ui.iconTint(cx, ui.icons.server, S.theme.current().fg_2, S.icon(14)));
            const name = try ui.text(cx, option.label, S.text(12, 600, false));
            name.setStyleInline(a, .{ .width = .fill(), .min_width = 0, .flex = 1 });
            try row.appendChild(a, name);
            try list.appendChild(a, row);
            count += 1;
        }
        if (count == 0) {
            const empty = try ui.text(cx, "没有可选的 SSH 主机", S.text(12, 400, false));
            empty.setStyleInline(a, S.row(30));
            try list.appendChild(a, empty);
        }
        const visible: usize = @min(@max(count, 1), 4);
        self.list.container.setStyleInline(a, .{ .width = .fill(), .height = .{ .px = @floatFromInt(visible * 32 - 2) }, .flex_shrink = 0 });
        ui.widgets.setScrollY(self.list.state, list, 0);
    }
};
