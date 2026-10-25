//! Confirmation shown before a SOCKS listener is bound to 0.0.0.0.
//!
//! This is a stateful production view, rather than a design annotation: the
//! red warning is only mounted when the caller has explicitly requested a
//! LAN-facing bind.  Enter is deliberately ignored; the destructive action
//! is available through the visible confirmation button only.
const std = @import("std");
const ui = @import("ui");
const theme = @import("app_theme.zig");

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
    frame: *ui.Node = undefined,
    open: *ui.Signal(bool) = undefined,
    portaled: bool = false,
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

        self.open = try scope.createSignal(bool, false);
        const modal = try ui.widgets.Modal(.{ .open = self.open, .width = 430, .max_height = 450, .background = theme.current().overlay, .close_on_overlay = false, .enter_transition = .none, .exit_transition = .none, .on_open_change = cx.on(View, self, modalChanged) }).mount(scope, cx);
        self.root = modal.overlay;
        self.root.setDisplay(.none);
        self.card = modal.dialog;
        self.frame = modal.body;
        self.portaled = modal.portaled;
        self.root.meta.ownership.meta.test_id = "forward.exposure";
        self.card.meta.ownership.meta.test_id = "forward.exposure.card";
        self.card.setStyleInline(cx.allocator, .{ .width = .{ .px = 430 }, .direction = .column, .background = theme.current().overlay, .border = .{ .radius = 14 } });
        self.frame.setStyleInline(cx.allocator, .{ .width = .fill(), .height = .fill(), .min_height = 0, .direction = .column, .gap = 0 });
        self.frame.setStyleInline(cx.allocator, .{ .padding = ui.Padding.all(20) });
        self.card.behavior.interaction.focusable = true;
        self.card.behavior.events.on_key_down = onKeyDown;
        self.card.behavior.events.key_context = @ptrCast(self);

        const heading = try ui.text(cx, "确认开放局域网访问", .{
            .font_size = 15,
            .font_weight = 700,
            .color = theme.current().danger_ink,
            .wrap = .word,
        });
        self.body = try ui.widgets.ScrollArea(.{ .direction = .vertical }).mount(scope, cx);
        self.body.container.style.width = .fill();
        self.body.container.style.height = .{ .fit = .{} };
        self.body.content.style.width = .fill();
        self.body.content.style.flex_shrink = 0;
        try self.frame.appendChild(cx.allocator, self.body.container);
        try self.body.content.appendChild(cx.allocator, heading);
        const intro = try ui.text(cx, "转发将绑定到 0.0.0.0。局域网内的其他设备可以访问此监听端口。", .{
            .font_size = 12,
            .color = theme.current().fg_2,
            .wrap = .word,
            .line_height = 1.45,
        });
        intro.style.margin = .{ .top = 8, .bottom = 0, .left = 0, .right = 0 };
        try self.body.content.appendChild(cx.allocator, intro);

        self.bind_text = try ui.text(cx, "绑定地址：0.0.0.0", .{ .font_size = 11.5, .color = theme.current().fg_1, .use_monospace_font = true });
        try self.body.content.appendChild(cx.allocator, self.bind_text);

        const foot = try ui.box(cx, .{
            .width = .fill(),
            .direction = .row,
            .justify = .end,
            .gap = 9,
            .margin = .{ .top = 16, .bottom = 0, .left = 0, .right = 0 },
            .flex_shrink = 0,
        }, .{});
        _ = try button(self, foot, "取消", false);
        self.confirm_button = try button(self, foot, "确认开放", true);
        try self.frame.appendChild(cx.allocator, foot);
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
        self.open.set(true);
        self.focus_pending = true;
        self.root.setDisplay(.flex);
        self.cx.requestRedraw();
    }

    fn modalChanged(self: *View, value: bool) void {
        if (!value and self.visible) self.cancelNow();
    }
    pub fn hide(self: *View) void {
        self.visible = false;
        self.open.set(false);
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
        const bounds: ui.ComputedRect = .{ .x = 0, .y = 0, .w = self.cx.viewport.width, .h = self.cx.viewport.height };
        const width = @max(@as(f32, 1), @min(@as(f32, 430), bounds.w - 32));
        const natural = self.body.content.globalRect().h;
        const body_h = @max(@as(f32, 1), @min(natural, bounds.h - 122));
        var changed = false;
        if (self.frame.style.padding.left != 20) {
            self.frame.setStyleInline(self.cx.allocator, .{ .padding = ui.Padding.all(20) });
            changed = true;
        }
        const total = body_h + 90;
        if (self.card.style.height != .px or @abs(self.card.style.height.px - total) > 0.5) {
            self.card.setStyleInline(self.cx.allocator, .{ .height = .{ .px = total } });
            changed = true;
        }
        if (self.card.style.width != .px or @abs(self.card.style.width.px - width) > 0.5) {
            self.card.setStyleInline(self.cx.allocator, .{ .width = .{ .px = width } });
            changed = true;
        }
        if (self.body.container.style.height != .px or @abs(self.body.container.style.height.px - body_h) > 0.5) {
            self.body.container.setStyleInline(self.cx.allocator, .{ .height = .{ .px = body_h } });
            changed = true;
        }
        if (changed) {
            self.card.markLayoutDirty();
            self.cx.requestRedraw();
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

fn button(self: *View, parent: *ui.Node, label: []const u8, comptime danger: bool) !*ui.Node {
    const node = try ui.widgets.Button(.{ .label = label, .variant = @as(ui.widgets.ButtonVariant, if (danger) .danger else .secondary), .base_style = .{ .width = .{ .px = 112 }, .height = .{ .px = 34 }, .background = if (danger) theme.current().danger_ink else theme.current().well, .text_color = if (danger) ui.Color.WHITE else theme.current().fg_1, .font_size = 12, .corner_radius = 8, .border_width = 0 }, .on_click = self.cx.on(View, self, if (danger) View.onConfirmClick else View.onCancelClick), .on_event = if (danger) pointerOnly else null }).mount(self.scope, self.cx);
    node.meta.ownership.meta.test_id = if (danger) "forward.exposure.confirm" else "forward.exposure.cancel";
    try parent.appendChild(self.cx.allocator, node);
    return node;
}
fn pointerOnly(event: ui.events.Event, _: ?*anyopaque) ui.events.EventResult {
    switch (event) {
        .key_down => |key| if (key.key == .@"return" or key.key == .space) return .stop,
        .key_up => |key| if (key.key == .@"return" or key.key == .space) return .stop,
        else => {},
    }
    return .ignored;
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
