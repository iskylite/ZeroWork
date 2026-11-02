//! Structured public TLS material in the shared authentication presenter.
//! This view proposes a choice index only; it never validates or trusts TLS.
const std = @import("std");
const ui = @import("ui");
const challenge = @import("../host/challenge_host.zig");
pub const S = @import("certificate_trust_styles.zig");
const A = S.shared;
pub const Callbacks = struct {
    context: *anyopaque,
    choose: *const fn (*anyopaque, usize) void,
    cancel: *const fn (*anyopaque) void,
};
const Action = struct {
    view: *View,
    index: usize,
    fn click(self: *Action) void {
        self.view.callbacks.choose(self.view.callbacks.context, self.index);
    }
};
pub const View = struct {
    cx: *ui.Cx,
    callbacks: Callbacks,
    root: *ui.Node = undefined,
    title: *ui.Node = undefined,
    title_icon: *ui.Node = undefined,
    name: *ui.Node = undefined,
    endpoint: *ui.Node = undefined,
    notice: *ui.Node = undefined,
    notice_title: *ui.Node = undefined,
    detail: *ui.Node = undefined,
    failures: *ui.Node = undefined,
    leaf: *ui.Node = undefined,
    chain: *ui.Node = undefined,
    subject: *ui.Node = undefined,
    issuer: *ui.Node = undefined,
    valid_from: *ui.Node = undefined,
    valid_until: *ui.Node = undefined,
    scope_change: *ui.Node = undefined,
    problem: *ui.Node = undefined,
    scroll: ui.widgets.ScrollAreaResult = undefined,
    action_nodes: [3]*ui.Node = undefined,
    actions: [3]Action = undefined,

    pub fn mount(cx: *ui.Cx, scope: *ui.Scope, callbacks: Callbacks) !*View {
        const self = try cx.bindState(View, .{ .cx = cx, .callbacks = callbacks });
        self.root = try ui.box(cx, S.root(), .{});
        self.root.meta.ownership.meta.test_id = "plugin.challenge.certificate";
        self.root.setDisplay(.none);
        const header = try ui.box(cx, A.header(), .{});
        self.title_icon = try ui.iconTint(cx, ui.icons.shield_question, A.theme.current().warn_ink, A.icon(18));
        try header.appendChild(cx.allocator, self.title_icon);
        self.title = try label(cx, header, "信任 BMC 证书", S.text(13, 700, false), "plugin.challenge.certificate.title");
        self.title.setStyleInline(cx.allocator, .{ .height = .{ .px = 20 }, .flex = 1, .min_width = 0 });
        const close = try ui.widgets.Button(.{ .variant = .ghost, .icon_only = true, .a11y_label = "拒绝证书并取消连接", .on_click = cx.on(View, self, cancel) }).mount(scope, cx);
        close.setStyleInline(cx.allocator, A.close());
        close.meta.ownership.meta.test_id = "plugin.challenge.certificate.close";
        try close.appendChild(cx.allocator, try ui.iconTint(cx, ui.icons.x, A.theme.current().fg_2, A.icon(16)));
        try header.appendChild(cx.allocator, close);
        try self.root.appendChild(cx.allocator, header);
        const body = try ui.box(cx, A.body(), .{});
        try self.root.appendChild(cx.allocator, body);
        self.scroll = try ui.widgets.ScrollArea(.{ .direction = .vertical, .rubber_band_y = false }).mount(scope, cx);
        self.scroll.container.setStyleInline(cx.allocator, A.scroll());
        self.scroll.container.meta.ownership.meta.test_id = "plugin.challenge.certificate.scroll";
        self.scroll.content.setStyleInline(cx.allocator, A.stack());
        try body.appendChild(cx.allocator, self.scroll.container);
        const stack = self.scroll.content;
        const identity = try ui.box(cx, A.identity(), .{});
        identity.setStyleInline(cx.allocator, .{ .height = .{ .fit = .{} }, .min_height = 44 });
        try identity.appendChild(cx.allocator, try ui.iconTint(cx, ui.icons.server, A.theme.current().fg_2, A.icon(18)));
        const identity_text = try ui.box(cx, A.identityText(), .{});
        self.name = try label(cx, identity_text, "", S.text(14, 500, false), "plugin.challenge.certificate.source");
        self.endpoint = try label(cx, identity_text, "", S.text(10.5, 400, true), "plugin.challenge.certificate.endpoint");
        try identity.appendChild(cx.allocator, identity_text);
        try stack.appendChild(cx.allocator, identity);
        self.notice = try ui.box(cx, S.notice(false), .{});
        self.notice_title = try label(cx, self.notice, "无法验证此证书", S.text(12, 500, false), "plugin.challenge.certificate.status");
        self.detail = try label(cx, self.notice, "", S.text(11, 400, false), "plugin.challenge.certificate.detail");
        self.failures = try label(cx, self.notice, "", S.text(11, 400, false), "plugin.challenge.certificate.failures");
        try stack.appendChild(cx.allocator, self.notice);
        self.leaf = try fingerprint(cx, stack, "证书 SHA-256", "plugin.challenge.certificate.leaf");
        self.chain = try fingerprint(cx, stack, "证书链 SHA-256", "plugin.challenge.certificate.chain");
        const metadata = try ui.box(cx, S.metadata(), .{});
        metadata.meta.ownership.meta.test_id = "plugin.challenge.certificate.metadata";
        self.subject = try field(cx, metadata, "Subject", false, "plugin.challenge.certificate.subject");
        self.issuer = try field(cx, metadata, "Issuer", false, "plugin.challenge.certificate.issuer");
        self.valid_from = try field(cx, metadata, "生效时间", true, "plugin.challenge.certificate.valid_from");
        self.valid_until = try field(cx, metadata, "到期时间", true, "plugin.challenge.certificate.valid_until");
        self.scope_change = try field(cx, metadata, "信任记录", false, "plugin.challenge.certificate.scope_change");
        try stack.appendChild(cx.allocator, metadata);
        _ = try label(cx, stack, "仅本次信任不会保存记录。保存并继续会记住此目标的证书、证书链和上述验证例外；证书或例外变化时会重新确认。", S.text(11, 400, false), "plugin.challenge.certificate.scope_note");
        self.problem = try label(cx, stack, "", S.text(11, 400, false), "plugin.challenge.certificate.error");
        self.problem.setTextColor(A.theme.current().danger_ink);
        self.problem.setDisplay(.none);
        const footer = try ui.box(cx, A.footer(), .{});
        footer.meta.ownership.meta.test_id = "plugin.challenge.certificate.actions";
        const labels = [_][]const u8{ "拒绝连接", "仅本次信任", "保存并继续" };
        const ids = [_][]const u8{ "plugin.challenge.certificate.reject", "plugin.challenge.certificate.once", "plugin.challenge.certificate.save" };
        const widths = [_]f32{ 104, 132, 146 };
        for (&self.actions, 0..) |*action, index| {
            action.* = .{ .view = self, .index = index };
            const variant: ui.widgets.button.ButtonVariant = if (index == 2) .primary else .secondary;
            const button = try ui.widgets.Button(.{ .label = labels[index], .variant = variant, .a11y_label = labels[index], .on_click = cx.on(Action, action, Action.click) }).mount(scope, cx);
            button.setStyleInline(cx.allocator, A.button(widths[index], index == 2, false));
            button.meta.ownership.meta.test_id = ids[index];
            styleActionText(button, index == 2);
            self.action_nodes[index] = button;
            try footer.appendChild(cx.allocator, button);
            if (index == 0) try footer.appendChild(cx.allocator, try ui.spacer(cx));
        }
        try body.appendChild(cx.allocator, footer);
        return self;
    }

    pub fn show(self: *View, payload: challenge.Payload) !void {
        const certificate = payload.certificate_trust orelse return error.MissingCertificatePresentation;
        try self.title.setTextContent(self.cx.allocator, payload.title);
        try self.name.setTextContent(self.cx.allocator, if (payload.source_name.len != 0) payload.source_name else "TLS 证书");
        try self.endpoint.setTextContent(self.cx.allocator, certificate.authority);
        const color = if (certificate.scope_changed) A.theme.current().danger_ink else A.theme.current().warn_ink;
        self.notice.setStyleInline(self.cx.allocator, S.notice(certificate.scope_changed));
        self.notice_title.setTextColor(color);
        try self.notice_title.setTextContent(self.cx.allocator, if (certificate.scope_changed) "证书或验证例外已变化" else "无法验证此证书");
        const icon = if (certificate.scope_changed) ui.icons.shield_alert else ui.icons.shield_question;
        if (icon.icon_id) |id| if (icon.pickRep(18)) |rep| self.title_icon.setIcon(.{ .icon_id = id, .rep = rep, .tint = color });
        try self.detail.setTextContent(self.cx.allocator, payload.detail);
        try self.failures.setTextContent(self.cx.allocator, certificate.failures);
        const leaf_hex = std.fmt.bytesToHex(certificate.leaf_fingerprint, .lower);
        const chain_hex = std.fmt.bytesToHex(certificate.chain_fingerprint, .lower);
        try self.leaf.setTextContent(self.cx.allocator, &leaf_hex);
        try self.chain.setTextContent(self.cx.allocator, &chain_hex);
        try self.subject.setTextContent(self.cx.allocator, if (certificate.subject.len != 0) certificate.subject else "未提供");
        try self.issuer.setTextContent(self.cx.allocator, if (certificate.issuer.len != 0) certificate.issuer else "未提供");
        try self.valid_from.setTextContent(self.cx.allocator, certificate.valid_from);
        try self.valid_until.setTextContent(self.cx.allocator, certificate.valid_until);
        try self.scope_change.setTextContent(self.cx.allocator, if (certificate.scope_changed) "已变化，请重新核对" else "未发现证书或例外变化");
        self.problem.setDisplay(.none);
        ui.widgets.setScrollY(self.scroll.state, self.scroll.content, 0);
    }
    fn cancel(self: *View) void {
        self.callbacks.cancel(self.callbacks.context);
    }
    pub fn fail(self: *View, message: []const u8) void {
        self.problem.setTextContent(self.cx.allocator, message) catch {};
        self.problem.setDisplay(if (message.len != 0) .flex else .none);
    }
};
fn label(cx: *ui.Cx, parent: *ui.Node, content: []const u8, style: ui.TextStyle, id: ?[]const u8) !*ui.Node {
    const node = try ui.text(cx, content, style);
    node.setStyleInline(cx.allocator, .{ .width = .fill(), .height = .{ .fit = .{} }, .min_height = style.font_size * style.line_height, .min_width = 0, .flex_shrink = 0 });
    node.meta.ownership.meta.test_id = id;
    try parent.appendChild(cx.allocator, node);
    return node;
}
fn fingerprint(cx: *ui.Cx, parent: *ui.Node, name: []const u8, id: []const u8) !*ui.Node {
    const well = try ui.box(cx, A.well(), .{});
    _ = try label(cx, well, name, S.text(11, 500, false), null);
    const value = try label(cx, well, "", S.value(true), id);
    try parent.appendChild(cx.allocator, well);
    return value;
}
fn field(cx: *ui.Cx, parent: *ui.Node, name: []const u8, mono: bool, id: []const u8) !*ui.Node {
    const row = try ui.box(cx, S.metadataRow(), .{});
    const name_node = try label(cx, row, name, S.text(11, 400, false), null);
    name_node.setStyleInline(cx.allocator, S.metadataLabel());
    const value = try label(cx, row, "", S.value(mono), id);
    value.setStyleInline(cx.allocator, .{ .flex = 1 });
    try parent.appendChild(cx.allocator, row);
    return value;
}
fn styleActionText(node: *ui.Node, primary: bool) void {
    if (node.getText()) |old| {
        var text = old;
        text.font_size = 12;
        text.font_weight = 500;
        text.line_height = 1.5;
        text.color = A.actionColor(primary, false);
        text.wrap = .none;
        text.text_align = .center;
        node.setText(text);
    }
    for (node.children.items) |child| styleActionText(child, primary);
}
