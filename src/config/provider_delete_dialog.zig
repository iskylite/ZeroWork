//! One active native confirmation for a captured Provider/model identity.
const std = @import("std");
const ui = @import("ui");
const S = @import("settings_styles.zig");
const controls = @import("settings_parts/settings_controls.zig");
pub const Target = struct { provider: usize, model: ?usize = null, provider_name: []const u8, model_id: []const u8 = "" };
pub const Hooks = struct { context: *anyopaque, accept: *const fn (*anyopaque, *Dialog) bool };
pub const Dialog = struct {
    cx: *ui.Cx,
    scope: *ui.Scope,
    target: Target,
    hooks: Hooks,
    modal: ui.widgets.ModalResult,
    open: *ui.Signal(bool),
    content: *ui.Node,
    problem: *ui.Node,
    done: bool = false,
    pub fn mount(cx: *ui.Cx, parent: *ui.Scope, target: Target, hooks: Hooks) !*Dialog {
        const scope = try parent.childScope();
        errdefer scope.dispose();
        const self = try scope.allocator.create(Dialog);
        self.* = .{ .cx = cx, .scope = scope, .target = .{ .provider = target.provider, .model = target.model, .provider_name = try controls.owned(scope, target.provider_name), .model_id = try controls.owned(scope, target.model_id) }, .hooks = hooks, .open = try scope.createSignal(bool, true), .modal = undefined, .content = undefined, .problem = undefined };
        try scope.onCleanup(Dialog, self, release);
        self.modal = try ui.widgets.Modal(.{ .open = ui.split(self.open, cx.on(Dialog, self, opened)), .width = @as(f32, 390), .max_height = @as(f32, 640), .background = S.theme.current().overlay, .close_on_overlay = true, .enter_transition = .none, .exit_transition = .none }).mount(scope, cx);
        self.modal.overlay.meta.ownership.meta.test_id = "settings.ai.delete.overlay";
        self.modal.dialog.meta.ownership.meta.test_id = "settings.ai.delete.dialog";
        self.modal.dialog.setStyleInline(cx.allocator, .{ .width = .{ .px = 390 }, .height = .{ .px = 206 }, .direction = .column, .padding = .{}, .gap = 0, .background = S.theme.current().overlay, .border = .{ .radius = 14 }, .overflow_hidden = true });
        self.modal.body.setStyleInline(cx.allocator, .{ .width = .fill(), .height = .fill(), .min_height = 0, .flex = 1, .direction = .column, .gap = 0, .padding = .{} });
        const header = try ui.box(cx, .{ .width = .fill(), .height = .{ .px = 60 }, .padding = .{ .left = 20, .right = 20, .top = 16, .bottom = 10 }, .direction = .row, .align_items = .center, .flex_shrink = 0 }, .{});
        try header.appendChild(cx.allocator, try ui.textStyled(cx, S.title, if (target.model == null) "删除服务提供方？" else "删除模型？"));
        try self.modal.body.appendChild(cx.allocator, header);
        const scroll = try ui.widgets.ScrollArea(.{ .direction = .vertical, .rubber_band_y = false }).mount(scope, cx);
        scroll.container.setStyleInline(cx.allocator, .{ .width = .fill(), .height = .fill(), .min_height = 0, .flex = 1 });
        scroll.container.meta.ownership.meta.test_id = "settings.ai.delete.viewport";
        scroll.content.setStyleInline(cx.allocator, .{ .width = .fill(), .direction = .column, .padding = .{ .left = 20, .right = 20, .top = 8, .bottom = 18 }, .gap = 8, .flex_shrink = 0 });
        self.content = scroll.content;
        const message = if (target.model == null) try std.fmt.allocPrint(scope.allocator, "将删除“{s}”及其模型配置。", .{target.provider_name}) else try std.fmt.allocPrint(scope.allocator, "将从“{s}”移除“{s}”的模型配置。", .{ target.provider_name, target.model_id });
        defer scope.allocator.free(message);
        const label = try ui.text(cx, try controls.owned(scope, message), .{ .font_size = 12, .line_height = 20.0 / 12.0, .color = S.theme.current().fg_2, .wrap = .word });
        label.setStyleInline(cx.allocator, .{ .width = .fill(), .min_width = 0, .flex_shrink = 0 });
        try scroll.content.appendChild(cx.allocator, label);
        self.problem = try ui.textStyled(cx, S.errorNote, "");
        self.problem.setDisplay(.none);
        try scroll.content.appendChild(cx.allocator, self.problem);
        try self.modal.body.appendChild(cx.allocator, scroll.container);
        const footer = try ui.box(cx, .{ .width = .fill(), .height = .{ .px = 60 }, .padding = .{ .left = 20, .right = 20, .top = 12, .bottom = 16 }, .direction = .row, .gap = 8, .justify = .end, .align_items = .center, .flex_shrink = 0 }, .{});
        footer.meta.ownership.meta.test_id = "settings.ai.delete.footer";
        const cancel_button = try ui.widgets.Button(.{ .label = "取消", .variant = .secondary, .base_style = S.actionControl(false), .hover_style = S.buttonHover(), .on_click = cx.on(Dialog, self, cancel) }).mount(scope, cx);
        cancel_button.meta.ownership.meta.test_id = "settings.ai.delete.cancel";
        try footer.appendChild(cx.allocator, cancel_button);
        var danger = S.actionControl(true);
        danger.background = S.theme.current().danger;
        danger.text_color = ui.Color.WHITE;
        const confirm = try ui.widgets.Button(.{ .label = "删除", .variant = .secondary, .base_style = danger, .on_click = cx.on(Dialog, self, accept) }).mount(scope, cx);
        confirm.meta.ownership.meta.test_id = "settings.ai.delete.confirm";
        try footer.appendChild(cx.allocator, confirm);
        try self.modal.body.appendChild(cx.allocator, footer);
        return self;
    }
    fn release(self: *Dialog) void {
        self.scope.allocator.destroy(self);
    }
    pub fn destroy(self: *Dialog) void {
        const cx = self.cx;
        const scope = self.scope;
        const overlay = self.modal.overlay;
        cx.invalidateReferencesTo(overlay);
        if (overlay.parent) |parent| cx.detachChild(parent, overlay);
        scope.dispose();
        cx.destroyDetached(overlay);
    }
    pub fn resize(self: *Dialog) void {
        const width = @min(390, @max(1, self.cx.viewport.width - 32));
        const content_height = self.content.globalRect().h;
        const height = @min(@max(1, self.cx.viewport.height - 32), @max(166, 120 + content_height));
        if (self.modal.dialog.style.width != .px or self.modal.dialog.style.width.px != width or self.modal.dialog.style.height != .px or @abs(self.modal.dialog.style.height.px - height) > 0.1) self.modal.dialog.setStyleInline(self.cx.allocator, .{ .width = .{ .px = width }, .height = .{ .px = height } });
    }
    pub fn fail(self: *Dialog, text: []const u8) void {
        self.problem.setTextContent(self.cx.allocator, text) catch {};
        self.problem.setDisplay(.flex);
        self.cx.requestRedraw();
    }
    pub fn cancel(self: *Dialog) void {
        self.done = true;
        self.open.set(false);
        self.cx.requestRedraw();
    }
    fn opened(self: *Dialog, open: bool) void {
        if (!open) self.cancel();
    }
    fn accept(self: *Dialog) void {
        if (self.hooks.accept(self.hooks.context, self)) self.cancel();
    }
};
