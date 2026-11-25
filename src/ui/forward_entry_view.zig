//! V0.8 统一「端口转发」入口。One mascot slot now owns both owners: the current
//! session forward and the app-level background forwards. Rows only delegate
//! to those existing panels, so their actions and semantics stay unchanged.
const std = @import("std");
const ui = @import("ui");
const T = @import("app_theme.zig");

pub const Row = struct {
    detail: []const u8 = "",
    active: bool = false,
    enabled: bool = false,
};

const Entry = struct {
    view: *View,
    session: bool,
    button: *ui.Node = undefined,
    dot: *ui.Node = undefined,
    detail: *ui.Node = undefined,

    fn activate(self: *Entry) void {
        self.view.hide();
        if (self.session) self.view.hooks.open_session(self.view.hooks.context) else self.view.hooks.open_background(self.view.hooks.context);
    }
};

pub const Hooks = struct {
    context: *anyopaque,
    open_session: *const fn (*anyopaque) void,
    open_background: *const fn (*anyopaque) void,
};

pub const View = struct {
    cx: *ui.Cx,
    hooks: Hooks,
    popover: ui.widgets.popover.PopoverResult = undefined,
    session_entry: Entry = undefined,
    background_entry: Entry = undefined,
    anchor: ui.ComputedRect = .{ .x = 0, .y = 0, .w = 0, .h = 0 },

    pub fn mount(cx: *ui.Cx, scope: *ui.Scope, hooks: Hooks) !*View {
        const self = try scope.createState(View, .{ .cx = cx, .hooks = hooks });
        self.popover = try ui.widgets.Popover(.{ .group = @import("floating_surface.zig").workspace_popup, .trigger = .manual, .position = .top_end, .offset = .{ .static = 8 }, .width = @as(f32, 320), .max_width = @as(f32, 320), .constrain_width_to_viewport = true, .close_on_escape = true, .close_on_outside_click = true, .anchor = .{ .virtual = .{ .ctx = self, .getRect = anchorRect } } }).mount(scope, cx);
        self.popover.trigger.setDisplay(.none);
        self.popover.content.meta.ownership.meta.test_id = "workspace.mascot.forward.menu";
        self.popover.content.setStyleInline(cx.allocator, .{
            .width = .fill(),
            .direction = .column,
            .gap = 2,
            .padding = ui.Padding.all(8),
            .background = T.current().overlay,
            .glass = T.overlayGlass(),
            .border = .{ .width = 0, .color = ui.Color.TRANSPARENT, .radius = 11 },
            .shadow = .{ .offset_y = 12, .blur = 24, .color = T.current().shadow },
        });
        const header = try ui.box(cx, .{ .width = .fill(), .height = .{ .px = 26 }, .direction = .row, .align_items = .center, .gap = 8, .padding = .{ .left = 6, .right = 6 }, .flex_shrink = 0 }, .{});
        try header.appendChild(cx.allocator, try T.icon(cx, ui.icons.get("plug-zap").?, "accent", .{ .width = .{ .px = 15 }, .height = .{ .px = 15 }, .flex_shrink = 0 }));
        try header.appendChild(cx.allocator, try ui.text(cx, "端口转发", .{ .font_size = 12.5, .font_weight = 600, .color = T.current().fg_1 }));
        try self.popover.content.appendChild(cx.allocator, header);
        self.session_entry = try self.row(scope, "当前会话转发", "workspace.mascot.forward.session", true);
        self.background_entry = try self.row(scope, "后台保持转发", "workspace.mascot.forward.background", false);
        try scope.createEffect(.{ .view = self, .theme = try cx.themeSignal(scope) }, struct {
            fn run(ctx: anytype) void {
                _ = ctx.theme.get();
                const view = ctx.view;
                view.popover.content.setStyleInline(view.cx.allocator, .{ .background = T.current().overlay, .glass = T.overlayGlass(), .shadow = .{ .offset_y = 12, .blur = 24, .color = T.current().shadow } });
            }
        }.run);
        return self;
    }

    fn row(self: *View, scope: *ui.Scope, title: []const u8, test_id: []const u8, session: bool) !Entry {
        const cx = self.cx;
        const state = try scope.createState(Entry, .{ .view = self, .session = session });
        const button = try ui.widgets.Button(.{ .variant = .ghost, .a11y_label = title, .on_click = cx.on(Entry, state, Entry.activate) }).mount(scope, cx);
        button.meta.ownership.meta.test_id = test_id;
        button.setStyleInline(cx.allocator, .{ .width = .fill(), .height = .{ .px = 46 }, .direction = .row, .align_items = .center, .gap = 10, .padding = .{ .left = 10, .right = 10 }, .background = ui.Color.TRANSPARENT, .border = .{ .width = 0, .color = ui.Color.TRANSPARENT, .radius = 8 } });
        const dot = try ui.box(cx, .{ .width = .{ .px = 7 }, .height = .{ .px = 7 }, .background = T.current().fg_3, .border = .{ .width = 0, .color = T.current().fg_3, .radius = 4 }, .flex_shrink = 0 }, .{});
        try button.appendChild(cx.allocator, dot);
        const labels = try ui.box(cx, .{ .width = .fill(), .direction = .column, .gap = 1, .min_width = 0 }, .{});
        try labels.appendChild(cx.allocator, try ui.text(cx, title, .{ .font_size = 12, .font_weight = 500, .color = T.current().fg_1 }));
        const detail = try ui.text(cx, "", .{ .font_size = 10.5, .color = T.current().fg_2, .text_overflow = .ellipsis });
        try labels.appendChild(cx.allocator, detail);
        try button.appendChild(cx.allocator, labels);
        try button.appendChild(cx.allocator, try T.icon(cx, ui.icons.get("chevron-right").?, "fg_3", .{ .width = .{ .px = 13 }, .height = .{ .px = 13 }, .flex_shrink = 0 }));
        try self.popover.content.appendChild(cx.allocator, button);
        state.button = button;
        state.dot = dot;
        state.detail = detail;
        return state.*;
    }

    pub fn show(self: *View, anchor: ui.ComputedRect) void {
        self.anchor = anchor;
        self.popover.show.invoke();
        self.cx.requestRedraw();
    }

    pub fn hide(self: *View) void {
        self.popover.close.invoke();
    }

    pub fn update(self: *View, session: Row, background: Row) !void {
        try apply(self.cx, &self.session_entry, session);
        try apply(self.cx, &self.background_entry, background);
    }

    fn apply(cx: *ui.Cx, entry: *Entry, value: Row) !void {
        entry.button.setDisplay(if (value.enabled) .flex else .none);
        if (!value.enabled) return;
        try entry.detail.setTextContent(cx.allocator, value.detail);
        entry.dot.setBackground(if (value.active) T.current().ok else T.current().fg_3);
    }

    fn anchorRect(raw: *anyopaque) ui.widgets.popover.AnchorRect {
        const self: *View = @ptrCast(@alignCast(raw));
        return .{ .x = self.anchor.x, .y = self.anchor.y, .w = self.anchor.w, .h = self.anchor.h };
    }
};
