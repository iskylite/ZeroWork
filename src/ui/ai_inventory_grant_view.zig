//! Native on-demand inventory approval; reference: inventory-grant.html.
//! This passive view emits an exact captured decision. The host owns validation
//! and authorization. It is absent until an actual request is pending.
const ui = @import("ui");
const approval = @import("../ai/inventory_approval.zig");
const S = @import("ai_inventory_grant_styles.zig");
const theme = @import("app_theme.zig");
pub const explanation = "AI需要查看已打开会话和会话组的名称、连接状态与分组。不会读取终端内容或执行命令。";
pub const duration_hint = "仅此一次用于本次调用；持续允许仅当前对话，可随时撤销。";
pub const Snapshot = struct {
    pending: ?approval.Snapshot = null,
    enabled: bool = true,
    unavailable_reason: ?[]const u8 = null,
};
pub const Callbacks = struct {
    context: *anyopaque,
    on_decision: *const fn (*anyopaque, approval.Ticket, approval.Decision) anyerror!void,
};
pub const View = struct {
    cx: *ui.Cx,
    root: *ui.Node,
    target: *ui.Node,
    detail: *ui.Node,
    feedback: *ui.Node,
    deny: *ui.Node,
    allow_once: *ui.Node,
    allow_conversation: *ui.Node,
    disabled: *ui.Signal(bool),
    primary_style: *ui.Signal(S.ButtonStyle),
    ticket: ?approval.Ticket = null,
    decision_pending: bool = false,
    external_feedback: bool = false,
    callbacks: Callbacks,

    pub fn mount(cx: *ui.Cx, scope: *ui.Scope, callbacks: Callbacks) !*View {
        const self = try scope.createState(View, .{ .cx = cx, .root = undefined, .target = undefined, .detail = undefined, .feedback = undefined, .deny = undefined, .allow_once = undefined, .allow_conversation = undefined, .disabled = try scope.createSignal(bool, true), .primary_style = try scope.createSignal(S.ButtonStyle, S.button(false)), .callbacks = callbacks });
        self.root = try ui.boxStyled(cx, S.root, .{});
        self.root.meta.ownership.meta.test_id = "ai.inventory_grant";
        self.root.setDisplay(.none);
        const header = try ui.boxStyled(cx, S.header, .{});
        header.meta.ownership.meta.test_id = "ai.inventory_grant.header";
        try self.root.appendChild(cx.allocator, header);
        const icon = try ui.iconTint(cx, ui.icons.get("layout-grid").?, theme.current().fg_2, .{ .width = .{ .px = 16 }, .height = .{ .px = 16 }, .flex_shrink = 0 });
        icon.meta.ownership.meta.test_id = "ai.inventory_grant.icon";
        try header.appendChild(cx.allocator, icon);
        const title = try ui.textStyled(cx, S.title, "查看其他会话");
        title.setStyleInline(cx.allocator, .{ .width = .{ .fit = .{} }, .flex_shrink = 0 });
        title.meta.ownership.meta.test_id = "ai.inventory_grant.title";
        try header.appendChild(cx.allocator, title);
        self.target = try self.copy("ai.inventory_grant.target", "", true);
        self.detail = try self.copy("ai.inventory_grant.explanation", explanation, false);
        _ = try self.copy("ai.inventory_grant.hint", duration_hint, true);
        self.feedback = try self.copy("ai.inventory_grant.feedback", "", true);
        self.feedback.setDisplay(.none);
        const actions = try ui.boxStyled(cx, S.actions, .{});
        actions.meta.ownership.meta.test_id = "ai.inventory_grant.actions";
        try self.root.appendChild(cx.allocator, actions);
        self.deny = try ui.widgets.Button(.{ .variant = .secondary, .label = "拒绝", .a11y_label = "拒绝本次查看其他会话", .base_style = S.button(false), .disabled = self.disabled, .hover_style = .{ .background = theme.popupSelection() }, .on_click = cx.on(View, self, denyRequest) }).mount(scope, cx);
        self.deny.meta.ownership.meta.test_id = "ai.inventory_grant.deny";
        try actions.appendChild(cx.allocator, self.deny);
        self.allow_once = try ui.widgets.Button(.{ .variant = .primary, .label = "仅此一次", .a11y_label = "仅本次调用允许查看其他会话", .base_style = self.primary_style, .disabled = self.disabled, .on_click = cx.on(View, self, allowOnce) }).mount(scope, cx);
        self.allow_once.meta.ownership.meta.test_id = "ai.inventory_grant.allow_once";
        try actions.appendChild(cx.allocator, self.allow_once);
        self.allow_conversation = try ui.widgets.Button(.{ .variant = .secondary, .label = "持续允许", .a11y_label = "当前对话持续允许查看其他会话，可撤销", .base_style = S.button(false), .disabled = self.disabled, .hover_style = .{ .background = theme.popupSelection() }, .on_click = cx.on(View, self, allowConversation) }).mount(scope, cx);
        self.allow_conversation.meta.ownership.meta.test_id = "ai.inventory_grant.allow_conversation";
        try actions.appendChild(cx.allocator, self.allow_conversation);
        return self;
    }
    fn copy(self: *View, id: []const u8, value: []const u8, secondary: bool) !*ui.Node {
        const node = if (secondary) try ui.textStyled(self.cx, S.secondary, value) else try ui.textStyled(self.cx, S.text, value);
        node.setStyleInline(self.cx.allocator, .{ .width = .fill(), .min_width = 0, .flex_shrink = 0 });
        node.meta.ownership.meta.test_id = id;
        try self.root.appendChild(self.cx.allocator, node);
        return node;
    }
    pub fn update(self: *View, snapshot: Snapshot) !void {
        const pending = snapshot.pending orelse {
            self.cancelPress();
            self.root.setDisplay(.none);
            self.ticket = null;
            self.decision_pending = false;
            self.disabled.set(true);
            return;
        };
        if (self.ticket == null or !self.ticket.?.eql(pending.ticket)) {
            self.cancelPress();
            self.decision_pending = false;
            self.feedback.setDisplay(.none);
        }
        self.ticket = pending.ticket;
        self.root.setDisplay(.flex);
        self.disabled.set(!snapshot.enabled or self.decision_pending);
        self.refreshActionPaint();
        try self.target.setTextContent(self.cx.allocator, pending.target.text());
        try self.detail.setTextContent(self.cx.allocator, pending.detail.text());
        if (snapshot.unavailable_reason) |reason| {
            try self.feedback.setTextContent(self.cx.allocator, reason);
            self.feedback.setDisplay(.flex);
            self.external_feedback = true;
        } else if (self.external_feedback) {
            self.external_feedback = false;
            self.feedback.setDisplay(.none);
        }
    }
    fn refreshActionPaint(self: *View) void {
        self.primary_style.set(S.button(!self.disabled.peek()));
        const paint = S.primaryPaint(!self.disabled.peek());
        self.allow_once.setStyleInline(self.cx.allocator, paint);
        self.allow_once.setStyle(self.cx.allocator, .gradient, paint.gradient);
    }
    fn cancelPress(self: *View) void {
        if (self.cx.pressed_node) |pressed| if (pressed == self.root or pressed.isDescendantOf(self.root)) self.cx.cancelPointerInteractions(.explicit);
    }
    fn denyRequest(self: *View) void {
        self.decide(.deny);
    }
    fn allowOnce(self: *View) void {
        self.decide(.allow_once);
    }
    fn allowConversation(self: *View) void {
        self.decide(.allow_conversation);
    }
    fn decide(self: *View, value: approval.Decision) void {
        const ticket = self.ticket orelse return;
        if (self.disabled.peek()) return;
        self.callbacks.on_decision(self.callbacks.context, ticket, value) catch |err| {
            const reason = switch (err) {
                error.ScopeChanged, error.StaleInventoryDecision, error.InventoryGrantExpired => "请求已失效，请等待新的请求",
                error.OperationBusy, error.InventoryApprovalBusy => "暂时无法处理，请稍后重试",
                else => "暂时无法处理，请重试",
            };
            self.feedback.setTextContent(self.cx.allocator, reason) catch {};
            self.feedback.setDisplay(.flex);
            self.external_feedback = false;
            if (err == error.ScopeChanged or err == error.StaleInventoryDecision or err == error.InventoryGrantExpired) self.disabled.set(true);
            self.refreshActionPaint();
            self.cx.requestRedraw();
            return;
        };
        // The host publishes dismissal on its next safe tick. Never destroy
        // this subtree while the Button dispatcher is still using it.
        self.disabled.set(true);
        self.refreshActionPaint();
        self.decision_pending = true;
        self.cx.requestRedraw();
    }
};
