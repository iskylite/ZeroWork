//! Confirmation shown before a SOCKS listener is bound to 0.0.0.0.
//!
//! This is a stateful production view, rather than a design annotation: the
//! red warning is only mounted when the caller has explicitly requested a
//! LAN-facing bind.  Enter is deliberately ignored; the destructive action
//! is available through the visible confirmation button only.
const std = @import("std");
const ui = @import("ui");
const mock = @import("mockups/common.zig");

pub const Hooks = struct {
    context: *anyopaque,
    confirm: *const fn (*anyopaque, []const u8) void,
    cancel: *const fn (*anyopaque) void,
};

pub const View = struct {
    cx: *ui.Cx,
    scope: *ui.Scope,
    hooks: Hooks,
    root: *ui.Node,
    card: *ui.Node,
    body: ui.widgets.ScrollAreaResult,
    bind_text: *ui.Node,
    confirm_button: *ui.Node,
    visible: bool = false,
    pending_bind: std.ArrayList(u8) = .empty,
    focus_pending: bool = false,

    pub fn mount(cx: *ui.Cx, scope: *ui.Scope, hooks: Hooks) !*View {
        const self = try cx.allocator.create(View);
        self.* = .{
            .cx = cx,
            .scope = scope,
            .hooks = hooks,
            .root = undefined,
            .card = undefined,
            .body = undefined,
            .bind_text = undefined,
            .confirm_button = undefined,
        };
        try scope.onCleanup(View, self, cleanup);

        self.root = try ui.box(cx, .{
            .position = .absolute,
            .inset = .{ .top = .{ .px = 0 }, .right = .{ .px = 0 }, .bottom = .{ .px = 0 }, .left = .{ .px = 0 } },
            .width = .fill(),
            .height = .fill(),
            .display = .none,
            .z_index = 360,
            .align_items = .center,
            .justify = .center,
            .background = ui.Color.rgba(15, 23, 42, 112),
        }, .{});
        self.card = try ui.box(cx, .{
            .width = .{ .px = 430 },
            .direction = .column,
            .padding = ui.Padding.all(20),
            .background = ui.Color.WHITE,
            .border = .{ .width = 0, .color = mock.tok.alpha(mock.tok.red, 64), .radius = 12 },
            .shadow = .{ .blur = 30, .offset_y = 12, .color = ui.Color.rgba(15, 23, 42, 64) },
            .flex_shrink = 0,
        }, .{});
        self.card.behavior.interaction.focusable = true;
        self.card.behavior.events.on_key_down = onKeyDown;
        self.card.behavior.events.key_context = @ptrCast(self);
        try self.root.appendChild(cx.allocator, self.card);

        const heading = try ui.text(cx, "确认开放局域网访问", .{
            .font_size = 15,
            .font_weight = 700,
            .color = mock.tok.red,
            .wrap = .word,
        });
        self.body = try ui.widgets.ScrollArea(.{ .direction = .vertical }).mount(scope, cx);
        self.body.container.style.width = .fill();
        self.body.container.style.height = .{ .fit = .{} };
        self.body.content.style.width = .fill();
        self.body.content.style.flex_shrink = 0;
        try self.card.appendChild(cx.allocator, self.body.container);
        try self.body.content.appendChild(cx.allocator, heading);
        const intro = try ui.text(cx, "SOCKS5 将绑定到 0.0.0.0。局域网内的其他设备可以访问此代理。", .{
            .font_size = 12,
            .color = mock.tok.fg2,
            .wrap = .word,
            .line_height = 1.45,
        });
        intro.style.margin = .{ .top = 8, .bottom = 0, .left = 0, .right = 0 };
        try self.body.content.appendChild(cx.allocator, intro);

        self.bind_text = try ui.text(cx, "绑定地址：0.0.0.0", .{ .font_size = 11.5, .color = mock.tok.fg, .use_monospace_font = true });
        try self.body.content.appendChild(cx.allocator, self.bind_text);

        const foot = try ui.box(cx, .{
            .width = .fill(),
            .direction = .row,
            .justify = .end,
            .gap = 9,
            .margin = .{ .top = 16, .bottom = 0, .left = 0, .right = 0 },
            .flex_shrink = 0,
        }, .{});
        const cancel = try button(self, foot, "取消", false);
        cancel.behavior.events.on_click = cx.on(View, self, onCancelClick);
        self.confirm_button = try button(self, foot, "确认开放", true);
        self.confirm_button.behavior.events.on_click = cx.on(View, self, onConfirmClick);
        try self.body.content.appendChild(cx.allocator, foot);
        try cx.addAfterLayoutHook(self, afterLayout);
        return self;
    }

    /// Copies the requested bind address. Caller may release its draft after return.
    pub fn show(self: *View, bind: []const u8) !void {
        self.pending_bind.clearRetainingCapacity();
        try self.pending_bind.appendSlice(self.cx.allocator, bind);
        var buf: [96]u8 = undefined;
        const label = try std.fmt.bufPrint(&buf, "绑定地址：{s}", .{bind});
        try self.bind_text.setTextContent(self.cx.allocator, label);
        self.visible = true;
        self.focus_pending = true;
        self.root.setDisplay(.flex);
        self.cx.requestRedraw();
    }

    pub fn hide(self: *View) void {
        self.visible = false;
        self.root.setDisplay(.none);
        self.cx.requestRedraw();
    }

    fn confirmNow(self: *View) void {
        if (!self.visible or self.pending_bind.items.len == 0) return;
        self.hide();
        self.hooks.confirm(self.hooks.context, self.pending_bind.items);
    }

    fn cancelNow(self: *View) void {
        if (!self.visible) return;
        self.hide();
        self.hooks.cancel(self.hooks.context);
    }

    fn onConfirmClick(self: *View) void {
        self.confirmNow();
    }
    fn onCancelClick(self: *View) void {
        self.cancelNow();
    }

    fn afterLayout(raw: *anyopaque, _: u8, _: bool) ui.AfterLayoutResult {
        const self: *View = @ptrCast(@alignCast(raw));
        return if (self.updateGeometry()) .needs_layout else .done;
    }

    pub fn updateGeometry(self: *View) bool {
        if (!self.visible) return false;
        const bounds = if (self.root.parent) |p| p.globalRect() else ui.ComputedRect{ .x = 0, .y = 0, .w = self.cx.viewport.width, .h = self.cx.viewport.height };
        const width = @max(@as(f32, 1), @min(@as(f32, 430), bounds.w - 32));
        const natural = self.body.content.globalRect().h;
        const body_h = @max(@as(f32, 1), @min(natural, bounds.h - 74));
        var changed = false;
        if (self.card.style.width != .px or @abs(self.card.style.width.px - width) > 0.5) {
            self.card.style.width = .{ .px = width };
            changed = true;
        }
        if (self.body.container.style.height != .px or @abs(self.body.container.style.height.px - body_h) > 0.5) {
            self.body.container.style.height = .{ .px = body_h };
            changed = true;
        }
        if (changed) {
            self.card.markLayoutDirty();
            return true;
        }
        if (self.focus_pending) {
            self.cx.setFocus(self.card);
            self.focus_pending = false;
        }
        return false;
    }

    fn cleanup(self: *View) void {
        self.cx.removeAfterLayoutHook(self);
        self.pending_bind.deinit(self.cx.allocator);
        self.cx.allocator.destroy(self);
    }
};

fn button(self: *View, parent: *ui.Node, label: []const u8, danger: bool) !*ui.Node {
    const n = try ui.box(self.cx, .{
        .height = .{ .px = 34 },
        .padding = .{ .left = 18, .right = 18 },
        .direction = .row,
        .align_items = .center,
        .justify = .center,
        .background = if (danger) mock.tok.red else mock.tok.btn_sec_bg,
        .border = .{ .width = if (danger) 0 else 1, .color = if (danger) mock.tok.red else mock.tok.setbd, .radius = 8 },
        .flex_shrink = 0,
    }, .{});
    try n.appendChild(self.cx.allocator, try ui.text(self.cx, label, .{ .font_size = 12, .font_weight = if (danger) 600 else 400, .color = if (danger) ui.Color.WHITE else mock.tok.fg2 }));
    try parent.appendChild(self.cx.allocator, n);
    return n;
}

fn onKeyDown(key: ui.events.KeyCode, _: ui.events.Modifiers, raw: ?*anyopaque) ui.events.EventResult {
    const self: *View = @ptrCast(@alignCast(raw orelse return .ignored));
    if (key == .escape) {
        self.cancelNow();
        return .stop;
    }
    // Enter intentionally does not confirm: only an explicit click opens LAN access.
    return if (key == .@"return") .stop else .ignored;
}

pub fn mount(cx: *ui.Cx, scope: *ui.Scope, hooks: Hooks) !*View {
    return View.mount(cx, scope, hooks);
}
