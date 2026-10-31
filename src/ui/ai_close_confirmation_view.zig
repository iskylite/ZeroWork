//! Non-modal close confirmation anchored to the assistant's ×.
//! Baseline: docs/UI_V3/ai-close-confirmation.html. The host validates the
//! captured conversation ticket and applies stop/close at its safe boundary.
const std = @import("std");
const ui = @import("ui");
const identity = @import("../host/identity.zig");
const S = @import("ai_close_confirmation_styles.zig");
const theme = @import("app_theme.zig");
pub const Ticket = struct {
    sequence: u64,
    conversation_id: identity.ConversationId,
    pub fn eql(self: Ticket, other: Ticket) bool {
        return self.sequence == other.sequence and self.conversation_id.eql(other.conversation_id);
    }
};
pub const Snapshot = struct { ticket: Ticket, running: bool, enabled: bool = true };
pub const Callbacks = struct {
    context: *anyopaque,
    on_confirm: *const fn (*anyopaque, Ticket) anyerror!void,
    on_cancel: *const fn (*anyopaque, Ticket) void,
};
pub const View = struct {
    cx: *ui.Cx,
    root: *ui.Node = undefined,
    panel: *ui.Node = undefined,
    title: *ui.Node = undefined,
    detail: *ui.Node = undefined,
    confirm: *ui.Node = undefined,
    cancel: *ui.Node = undefined,
    anchor: *ui.Node,
    open: *ui.Signal(bool),
    disabled: *ui.Signal(bool),
    confirm_label: *ui.Signal([]const u8),
    snapshot: ?Snapshot = null,
    resolved_ticket: ?Ticket = null,
    focus_pending: bool = false,
    callbacks: Callbacks,

    pub fn mount(cx: *ui.Cx, scope: *ui.Scope, anchor: *ui.Node, callbacks: Callbacks) !*View {
        const self = try scope.createState(View, .{ .cx = cx, .anchor = anchor, .callbacks = callbacks, .open = try scope.createSignal(bool, false), .disabled = try scope.createSignal(bool, true), .confirm_label = try scope.createSignal([]const u8, "关闭窗口") });
        const popup = try ui.widgets.Popover(.{ .open = self.open, .trigger = .manual, .anchor = .{ .node = anchor }, .position = .bottom_end, .offset = .{ .static = 8 }, .width = S.width, .max_width = S.width, .constrain_width_to_viewport = true, .viewport_padding = 8, .flip = true, .shift_main_axis = true, .size_policy = .fit_content, .close_on_outside_click = true, .consume_outside_click = true, .close_on_escape = true, .on_open_change = cx.on(View, self, openChanged), .enter_transition = .none, .exit_transition = .none, .a11y_role = .dialog }).mount(scope, cx);
        // Caller mounts this zero-layout owner; Popover independently portals its content.
        self.root = popup.wrapper;
        self.root.setDisplay(.none);
        self.panel = popup.chrome;
        self.panel.meta.ownership.meta.test_id = "ai.close.confirmation";
        self.panel.behavior.interaction.a11y = .{ .role = .dialog, .label = "关闭助手确认" };
        self.panel.setStyleInline(cx.allocator, S.chrome(cx.tokens));
        self.panel.meta.per_frame.hooks.on_theme = chromeTheme;
        const body = try ui.boxStyled(cx, S.panel, .{});
        try popup.content.appendChild(cx.allocator, body);
        self.title = try ui.textStyled(cx, S.title, "关闭助手？");
        self.title.setStyleInline(cx.allocator, .{ .width = .fill(), .min_width = 0, .flex_shrink = 0 });
        self.title.meta.ownership.meta.test_id = "ai.close.confirmation.title";
        try body.appendChild(cx.allocator, self.title);
        self.detail = try ui.textStyled(cx, S.detail, "对话和历史会保留");
        self.detail.setStyleInline(cx.allocator, .{ .width = .fill(), .min_width = 0, .flex_shrink = 0 });
        self.detail.meta.ownership.meta.test_id = "ai.close.confirmation.detail";
        try body.appendChild(cx.allocator, self.detail);
        const actions = try ui.boxStyled(cx, S.actions, .{});
        try body.appendChild(cx.allocator, actions);
        self.cancel = try ui.widgets.Button(.{ .variant = .secondary, .label = "取消", .base_style = S.button(false), .hover_style = .{ .background = theme.popupSelection() }, .on_click = cx.on(View, self, cancelRequest) }).mount(popup.scope, cx);
        self.cancel.meta.ownership.meta.test_id = "ai.close.confirmation.cancel";
        try actions.appendChild(cx.allocator, self.cancel);
        self.confirm = try ui.widgets.Button(.{ .variant = .primary, .label = self.confirm_label, .disabled = self.disabled, .base_style = S.button(true), .on_click = cx.on(View, self, confirmRequest) }).mount(popup.scope, cx);
        self.confirm.meta.ownership.meta.test_id = "ai.close.confirmation.confirm";
        try actions.appendChild(cx.allocator, self.confirm);
        try popup.scope.onCleanup(View, self, cleanup);
        try cx.addAfterLayoutHook(self, afterLayout);
        return self;
    }
    fn chromeTheme(node: *ui.Node, tokens: *const ui.ThemeTokens, allocator: std.mem.Allocator) void {
        node.setStyleInline(allocator, S.chrome(tokens));
    }
    pub fn update(self: *View, next: ?Snapshot) !void {
        const snapshot = next orelse {
            self.dismiss();
            self.resolved_ticket = null;
            return;
        };
        if (self.resolved_ticket) |ticket| if (ticket.eql(snapshot.ticket)) return;
        const changed = if (self.snapshot) |old| !old.ticket.eql(snapshot.ticket) or old.running != snapshot.running or old.enabled != snapshot.enabled else true;
        // The host republishes this snapshot from its frame poll. An unchanged
        // open request must not rewrite text, disturb a press, or schedule work.
        if (!changed and self.open.peek()) return;
        if (changed) self.cancelPress();
        const newly_opened = !self.open.peek();
        self.snapshot = snapshot;
        self.resolved_ticket = null;
        self.disabled.set(!snapshot.enabled);
        try self.title.setTextContent(self.cx.allocator, if (snapshot.running) "停止本轮并关闭？" else "关闭助手？");
        self.confirm_label.set(if (snapshot.running) "停止并关闭" else "关闭窗口");
        self.open.set(true);
        if (newly_opened or changed) self.focus_pending = true;
        self.cx.requestRedraw();
    }
    /// Host-driven dismissal never emits a user cancellation or destroys nodes.
    pub fn dismiss(self: *View) void {
        if (self.snapshot == null and !self.open.peek() and self.disabled.peek() and !self.focus_pending) return;
        self.cancelPress();
        self.snapshot = null;
        self.disabled.set(true);
        self.focus_pending = false;
        self.open.set(false);
        if (self.cx.focus_manager.current_focus) |focused| if (focused == self.panel or focused.isDescendantOf(self.panel)) self.cx.setFocus(self.anchor);
        self.cx.requestRedraw();
    }
    fn cancelPress(self: *View) void {
        if (self.cx.pressed_node) |pressed| if (pressed == self.panel or pressed.isDescendantOf(self.panel)) self.cx.cancelPointerInteractions(.explicit);
    }
    fn confirmRequest(self: *View) void {
        const snapshot = self.snapshot orelse return;
        if (!snapshot.enabled or self.disabled.peek()) return;
        self.resolved_ticket = snapshot.ticket;
        self.dismiss();
        self.callbacks.on_confirm(self.callbacks.context, snapshot.ticket) catch |err| std.log.warn("AI close confirmation rejected: {s}", .{@errorName(err)});
    }
    fn cancelRequest(self: *View) void {
        const snapshot = self.snapshot orelse return;
        self.resolved_ticket = snapshot.ticket;
        self.dismiss();
        self.callbacks.on_cancel(self.callbacks.context, snapshot.ticket);
    }
    fn openChanged(self: *View, value: bool) void {
        if (!value) self.cancelRequest();
    }
    fn afterLayout(raw: *anyopaque, _: u8, _: bool) ui.AfterLayoutResult {
        const self: *View = @ptrCast(@alignCast(raw));
        if (!self.focus_pending or !self.open.peek() or self.panel.globalRect().w <= 0) return .done;
        self.focus_pending = false;
        self.cx.setFocus(self.cancel);
        return .done;
    }
    fn cleanup(self: *View) void {
        self.cx.removeAfterLayoutHook(self);
        if (self.cx.focus_manager.current_focus) |focused| if (focused == self.panel or focused.isDescendantOf(self.panel)) self.cx.clearFocus();
    }
};
