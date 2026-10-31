//! Host approval card. Reuses the existing native approval styles/widgets;
//! reference: docs/UI_V3/ai/host-approval.html. Main-thread UI only.
const std = @import("std");
const ui = @import("ui");
const approval = @import("../ai/host_approval.zig");
const S = @import("ai_tool_approval_styles.zig");
const R = @import("ai_host_approval_route_styles.zig");
const theme = @import("app_theme.zig");
pub const Callbacks = struct {
    context: *anyopaque,
    on_decision: *const fn (*anyopaque, u64, [32]u8, bool) anyerror!void,
    on_renew: ?*const fn (*anyopaque, u64, [32]u8) anyerror!void = null,
    on_route: ?*const fn (*anyopaque, u64, [32]u8, approval.routing.Route) anyerror!void = null,
};
pub const View = struct {
    cx: *ui.Cx,
    root: *ui.Node,
    card: *ui.Node,
    body: *ui.Node,
    title: *ui.Node,
    target: *ui.Node,
    url: *ui.Node,
    summary: *ui.Node,
    network_row: *ui.Node,
    summary_row: *ui.Node,
    feedback: *ui.Node,
    source: *ui.Node,
    route_row: *ui.Node = undefined,
    route_reason: *ui.Node = undefined,
    route_buttons: [3]*ui.Signal(S.ButtonStyle) = undefined,
    route_selected: approval.routing.Route = .batch,
    accept: *ui.Node,
    reject: *ui.Node,
    copy: *ui.Node,
    network_icon: *ui.Node,
    lifecycle_icon: *ui.Node,
    terminal_icon: *ui.Node,
    callbacks: Callbacks,
    sequence: ?u64 = null,
    context: ?@import("../ai/host_tools.zig").Context = null,
    operation_id: u64 = 0,
    arguments_hash: [32]u8 = @splat(0),
    requested_url: ?[]u8 = null,
    expired: bool = false,
    state_label: *ui.Node = undefined,
    accept_text: *ui.Signal([]const u8) = undefined,
    decision_pending: *ui.Signal(bool),
    accept_style: *ui.Signal(S.ButtonStyle),
    reject_style: *ui.Signal(S.ButtonStyle),
    accept_label: *ui.Signal([]const u8) = undefined,
    reject_label: *ui.Signal([]const u8) = undefined,
    copy_label: *ui.Signal([]const u8) = undefined,

    pub fn mount(cx: *ui.Cx, scope: *ui.Scope, callbacks: Callbacks) !*View {
        const self = try scope.createState(View, .{ .cx = cx, .root = undefined, .card = undefined, .body = undefined, .title = undefined, .target = undefined, .url = undefined, .summary = undefined, .network_row = undefined, .summary_row = undefined, .feedback = undefined, .source = undefined, .accept = undefined, .reject = undefined, .copy = undefined, .network_icon = undefined, .lifecycle_icon = undefined, .terminal_icon = undefined, .callbacks = callbacks, .decision_pending = try scope.createSignal(bool, false), .accept_style = try scope.createSignal(S.ButtonStyle, S.iconButton(true)), .reject_style = try scope.createSignal(S.ButtonStyle, S.iconButton(false)) });
        self.accept_text = try scope.createSignal([]const u8, "批准此调用");
        self.accept_label = try scope.createSignal([]const u8, "批准这次本机网络读取");
        self.reject_label = try scope.createSignal([]const u8, "拒绝这次本机网络读取");
        self.copy_label = try scope.createSignal([]const u8, "复制完整请求 URL");
        try scope.onCleanup(View, self, cleanup);
        self.root = try ui.boxStyled(cx, S.wrapper, .{});
        self.root.meta.ownership.meta.test_id = "ai.host_approval";
        self.root.setDisplay(.none);
        self.card = try ui.boxStyled(cx, panelStyle, .{});
        self.card.meta.ownership.meta.test_id = "ai.host_approval.card";
        try self.root.appendChild(cx.allocator, self.card);
        const header = try ui.boxStyled(cx, S.header, .{});
        try self.card.appendChild(cx.allocator, header);
        self.network_icon = try ui.iconTint(cx, ui.icons.get("globe").?, theme.current().fg_2, .{ .width = .{ .px = 17 }, .height = .{ .px = 17 }, .flex_shrink = 0 });
        self.network_icon.meta.ownership.meta.test_id = "ai.host_approval.icon.network";
        self.lifecycle_icon = try ui.iconTint(cx, ui.icons.get("layers").?, theme.current().fg_2, .{ .width = .{ .px = 17 }, .height = .{ .px = 17 }, .flex_shrink = 0 });
        self.lifecycle_icon.meta.ownership.meta.test_id = "ai.host_approval.icon.lifecycle";
        self.terminal_icon = try ui.iconTint(cx, ui.icons.terminal, theme.current().fg_2, .{ .width = .{ .px = 17 }, .height = .{ .px = 17 }, .flex_shrink = 0 });
        self.terminal_icon.meta.ownership.meta.test_id = "ai.host_approval.icon.terminal";
        try header.appendChild(cx.allocator, self.network_icon);
        try header.appendChild(cx.allocator, self.lifecycle_icon);
        try header.appendChild(cx.allocator, self.terminal_icon);
        self.title = try ui.textStyled(cx, S.title, "获取网页");
        self.title.meta.ownership.meta.test_id = "ai.host_approval.title";
        self.title.setStyleInline(cx.allocator, .{ .width = .{ .fit = .{} }, .flex_shrink = 0 });
        try header.appendChild(cx.allocator, self.title);
        self.target = try ui.textStyled(cx, S.headerIdentity, "本机网络");
        self.target.setStyleInline(cx.allocator, .{ .width = .fill(), .flex = 1, .min_width = 0 });
        self.target.meta.ownership.meta.test_id = "ai.host_approval.target";
        try header.appendChild(cx.allocator, self.target);
        const state = try ui.text(cx, "待确认", .{ .font_size = 10, .line_height = 1.65, .color = theme.current().fg_2 });
        self.state_label = state;
        state.meta.ownership.meta.test_id = "ai.host_approval.state";
        state.setStyleInline(cx.allocator, .{ .padding = .{ .left = 6, .right = 6, .top = 3, .bottom = 3 }, .background = ui.Color.TRANSPARENT, .corner_radius = 5, .flex_shrink = 0 });
        try header.appendChild(cx.allocator, state);
        const scroll = try ui.widgets.ScrollArea(.{ .direction = .vertical }).mount(scope, cx);
        @import("ai_card_scroll.zig").containVertical(scroll);
        self.body = scroll.container;
        scroll.container.setStyleInline(cx.allocator, .{ .width = .fill(), .height = .{ .fit = .{ .max = 220 } }, .max_height = 220, .flex_shrink = 0 });
        scroll.container.meta.ownership.meta.test_id = "ai.host_approval.details";
        scroll.content.setStyleInline(cx.allocator, S.content(cx.tokens));
        try self.card.appendChild(cx.allocator, scroll.container);
        const source = try ui.textStyled(cx, S.secondary, "来源 · 本机网络 · HTTP/HTTPS GET");
        self.source = source;
        source.setStyleInline(cx.allocator, .{ .width = .fill(), .height = .{ .px = 20.625 }, .flex_shrink = 0 });
        source.meta.ownership.meta.test_id = "ai.host_approval.source";
        try scroll.content.appendChild(cx.allocator, source);
        self.route_row = try ui.boxStyled(cx, R.row, .{});
        self.route_row.meta.ownership.meta.test_id = "ai.host_approval.routes";
        self.route_row.setDisplay(.none);
        try scroll.content.appendChild(cx.allocator, self.route_row);
        inline for (.{ .{ "批处理", "ai.host_approval.route.batch", chooseBatch }, .{ "当前终端", "ai.host_approval.route.current", chooseCurrent }, .{ "新工作终端", "ai.host_approval.route.new", chooseNew } }, 0..) |item, index| {
            self.route_buttons[index] = try scope.createSignal(S.ButtonStyle, R.button(index == 0));
            const button = try ui.widgets.Button(.{ .variant = .secondary, .label = item[0], .a11y_label = item[0], .base_style = self.route_buttons[index], .disabled = self.decision_pending, .on_click = cx.on(View, self, item[2]) }).mount(scope, cx);
            button.meta.ownership.meta.test_id = item[1];
            try self.route_row.appendChild(cx.allocator, button);
        }
        self.route_reason = try ui.textStyled(cx, R.reason, "");
        self.route_reason.setStyleInline(cx.allocator, .{ .width = .fill(), .height = .{ .fit = .{} }, .margin = .{ .bottom = 6 }, .flex_shrink = 0 });
        self.route_reason.meta.ownership.meta.test_id = "ai.host_approval.route.reason";
        self.route_reason.setDisplay(.none);
        try scroll.content.appendChild(cx.allocator, self.route_reason);
        // URLs are addresses, with a single-line horizontal viewport. The copy
        // action remains at the right edge while the full URL can scroll.
        self.network_row = try ui.box(cx, .{ .width = .fill(), .height = .{ .px = 38 }, .direction = .row, .align_items = .center, .gap = 8, .padding = .{ .left = 10, .right = 8 }, .background = theme.popupInset(), .corner_radius = 7, .flex_shrink = 0, .margin = .{ .bottom = 8 } }, .{});
        self.network_row.meta.ownership.meta.test_id = "ai.host_approval.address_bar";
        try scroll.content.appendChild(cx.allocator, self.network_row);
        const address_scroll = try ui.widgets.ScrollArea(.{ .direction = .horizontal, .rubber_band_x = false }).mount(scope, cx);
        @import("ai_card_scroll.zig").showOverflowScrollbar(address_scroll);
        address_scroll.container.setStyleInline(cx.allocator, .{ .width = .fill(), .height = .{ .px = 38 }, .flex = 1, .min_width = 0, .flex_shrink = 1 });
        address_scroll.container.meta.ownership.meta.test_id = "ai.host_approval.url_viewport";
        address_scroll.content.setStyleInline(cx.allocator, .{ .width = .{ .fit = .{} }, .height = .{ .px = 38 }, .direction = .row, .align_items = .center, .flex_shrink = 0 });
        self.url = try ui.text(cx, "", .{ .font_size = 10.5, .line_height = 17.0 / 10.5, .color = theme.current().fg_1, .use_monospace_font = true, .wrap = .none });
        self.url.setStyleInline(cx.allocator, .{ .width = .{ .fit = .{} }, .height = .{ .px = 17 }, .flex_shrink = 0 });
        self.url.meta.ownership.meta.test_id = "ai.host_approval.url";
        try address_scroll.content.appendChild(cx.allocator, self.url);
        try self.network_row.appendChild(cx.allocator, address_scroll.container);
        const address_copy = try ui.widgets.Button(.{ .variant = .ghost, .icon_only = true, .icon_asset = ui.icons.copy, .icon_size = @as(f32, 14), .a11y_label = "复制完整请求 URL", .base_style = S.disclosureButton(), .on_click = cx.on(View, self, copyUrl) }).mount(scope, cx);
        address_copy.meta.ownership.meta.test_id = "ai.host_approval.copy_url";
        try self.network_row.appendChild(cx.allocator, address_copy);
        const url_row = try ui.boxStyled(cx, summaryRowStyle, .{});
        self.summary_row = url_row;
        url_row.meta.ownership.meta.test_id = "ai.host_approval.summary_row";
        try scroll.content.appendChild(cx.allocator, url_row);
        const url_scroll = try ui.widgets.ScrollArea(.{ .direction = .vertical }).mount(scope, cx);
        @import("ai_card_scroll.zig").containVertical(url_scroll);
        url_scroll.container.setStyleInline(cx.allocator, S.commandViewport(cx.tokens));
        url_scroll.container.setStyleInline(cx.allocator, .{ .height = .{ .fit = .{ .min = 37, .max = 105 } }, .min_height = 37, .max_height = 105, .overflow_hidden = true });
        url_scroll.container.meta.ownership.meta.test_id = "ai.host_approval.summary_viewport";
        url_scroll.content.setStyleInline(cx.allocator, S.commandContent(cx.tokens));
        try url_row.appendChild(cx.allocator, url_scroll.container);
        self.summary = try ui.textStyled(cx, S.command, "");
        self.summary.setStyleInline(cx.allocator, .{ .width = .fill(), .min_width = 0, .flex_shrink = 0 });
        self.summary.meta.ownership.meta.test_id = "ai.host_approval.summary";
        try url_scroll.content.appendChild(cx.allocator, self.summary);
        const copy = try ui.widgets.Button(.{ .variant = .ghost, .icon_only = true, .icon_asset = ui.icons.copy, .icon_size = @as(f32, 14), .a11y_label = self.copy_label, .base_style = S.disclosureButton(), .on_click = cx.on(View, self, copyUrl) }).mount(scope, cx);
        self.copy = copy;
        copy.meta.ownership.meta.test_id = "ai.host_approval.copy";
        try url_row.appendChild(cx.allocator, copy);
        const impact = try ui.boxStyled(cx, S.impactNotice, .{});
        impact.meta.ownership.meta.test_id = "ai.host_approval.impact_notice";
        try impact.appendChild(cx.allocator, try ui.iconTint(cx, ui.icons.get("triangle-alert").?, theme.current().warn_ink, .{ .width = .{ .px = 12 }, .height = .{ .px = 12 }, .flex_shrink = 0 }));
        self.feedback = try ui.textStyled(cx, impactTextStyle, impact_copy);
        self.feedback.setStyleInline(cx.allocator, .{ .width = .fill(), .min_width = 0, .flex = 1, .flex_shrink = 0 });
        self.feedback.meta.ownership.meta.test_id = "ai.host_approval.impact";
        try impact.appendChild(cx.allocator, self.feedback);
        try scroll.content.appendChild(cx.allocator, impact);
        const footer = try ui.boxStyled(cx, footerStyle, .{});
        footer.meta.ownership.meta.test_id = "ai.host_approval.footer";
        try self.card.appendChild(cx.allocator, footer);
        try footer.appendChild(cx.allocator, try ui.spacer(cx));
        const reject = try ui.widgets.Button(.{ .variant = .secondary, .label = "拒绝此调用", .a11y_label = self.reject_label, .base_style = self.reject_style, .disabled = self.decision_pending, .on_click = cx.on(View, self, rejectCall) }).mount(scope, cx);
        self.reject = reject;
        reject.meta.ownership.meta.test_id = "ai.host_approval.reject";
        try footer.appendChild(cx.allocator, reject);
        const accept = try ui.widgets.Button(.{ .variant = .primary, .label = self.accept_text, .a11y_label = self.accept_label, .base_style = self.accept_style, .disabled = self.decision_pending, .on_click = cx.on(View, self, acceptCall) }).mount(scope, cx);
        self.accept = accept;
        accept.meta.ownership.meta.test_id = "ai.host_approval.accept";
        try footer.appendChild(cx.allocator, accept);
        return self;
    }
    pub fn update(self: *View, source: ?approval.Snapshot) !void {
        self.accept_style.set(S.iconButton(true));
        self.reject_style.set(S.iconButton(false));
        const pending = source orelse {
            self.cancelPress();
            self.root.setDisplay(.none);
            self.sequence = null;
            self.context = null;
            if (self.requested_url) |text| self.cx.allocator.free(text);
            self.requested_url = null;
            return;
        };
        if (self.sequence == null or self.sequence.? != pending.sequence or self.context == null or !self.context.?.eql(pending.context) or self.operation_id != pending.operation_id or !std.mem.eql(u8, &self.arguments_hash, &pending.arguments_hash)) {
            self.cancelPress();
            const url = try self.cx.allocator.dupe(u8, pending.detail.text());
            errdefer self.cx.allocator.free(url);
            if (pending.kind == .network_url) try self.url.setTextContent(self.cx.allocator, url) else try self.summary.setTextContent(self.cx.allocator, url);
            const network = pending.kind == .network_url;
            self.network_row.setDisplay(if (network) .flex else .none);
            self.summary_row.setDisplay(if (network) .none else .flex);
            self.source.setDisplay(if (network) .none else .flex);
            if (pending.kind == .network_url) {
                const parsed = try std.Uri.parse(pending.canonical_url.text());
                const target = if (parsed.host) |value| switch (value) {
                    .raw, .percent_encoded => |text| text,
                } else "本机网络";
                try self.target.setTextContent(self.cx.allocator, target);
            } else {
                const target = try @import("ai_tool_header_projection.zig").approvalTarget(self.cx.allocator, pending.tool.text(), pending.target.text(), pending.detail.text());
                defer self.cx.allocator.free(target);
                try self.target.setTextContent(self.cx.allocator, target);
            }
            const interaction = std.mem.eql(u8, pending.tool.text(), "host.send_execution_input");
            const saving_host = std.mem.eql(u8, pending.tool.text(), "host.create_host");
            try self.title.setTextContent(self.cx.allocator, switch (pending.kind) {
                .network_url => "获取网页",
                .lifecycle => if (saving_host) "保存新主机" else "管理会话",
                .terminal_command => if (interaction) "请求交互输入" else "请求执行命令",
            });
            self.network_icon.setDisplay(if (pending.kind == .network_url) .flex else .none);
            self.lifecycle_icon.setDisplay(if (pending.kind == .lifecycle) .flex else .none);
            self.terminal_icon.setDisplay(if (pending.kind == .terminal_command) .flex else .none);
            self.accept_label.set(switch (pending.kind) {
                .network_url => "批准这次本机网络读取",
                .lifecycle => if (saving_host) "批准保存这台主机" else "批准这次会话管理操作",
                .terminal_command => if (interaction) "批准这次受控输入" else "批准这次终端命令",
            });
            self.reject_label.set(switch (pending.kind) {
                .network_url => "拒绝这次本机网络读取",
                .lifecycle => if (saving_host) "拒绝保存这台主机" else "拒绝这次会话管理操作",
                .terminal_command => if (interaction) "拒绝这次受控输入" else "拒绝这次终端命令",
            });
            self.copy_label.set(if (pending.kind == .network_url) "复制完整请求 URL" else "复制完整操作详情");
            try self.source.setTextContent(self.cx.allocator, switch (pending.kind) {
                .network_url => "来源 · 本机网络 · HTTP/HTTPS GET",
                .lifecycle => "来源 · 当前对话 · 宿主管理操作",
                .terminal_command => if (interaction) "来源 · 已授权执行 · 受控交互输入" else "来源 · 当前对话 · 交互式终端命令",
            });
            try self.feedback.setTextContent(self.cx.allocator, if (pending.impact.len != 0) pending.impact.text() else switch (pending.kind) {
                .network_url => impact_copy,
                .lifecycle => "仅批准本调用列明的对象与操作。实际身份、授权和保留影响会在派发前复验。",
                .terminal_command => "仅批准本调用列明的终端与命令。实际运行方式、目标和输入状态会在派发前复验。",
            });
            if (self.requested_url) |old| self.cx.allocator.free(old);
            self.requested_url = url;
            self.sequence = pending.sequence;
            self.context = pending.context;
            self.operation_id = pending.operation_id;
            self.arguments_hash = pending.arguments_hash;
            self.decision_pending.set(false);
        }
        if (self.expired != pending.expired) self.decision_pending.set(false);
        self.expired = pending.expired;
        self.accept_text.set(if (pending.expired) "重新确认" else "批准此调用");
        self.accept_label.set(if (pending.expired) "重新确认此请求" else switch (pending.kind) {
            .network_url => "批准这次本机网络读取",
            .lifecycle => if (std.mem.eql(u8, pending.tool.text(), "host.create_host")) "批准保存这台主机" else "批准这次会话管理操作",
            .terminal_command => if (std.mem.eql(u8, pending.tool.text(), "host.send_execution_input")) "批准这次受控输入" else "批准这次终端命令",
        });
        try self.state_label.setTextContent(self.cx.allocator, if (pending.expired) "已过期 · 流程暂停" else "待确认");
        const has_routes = pending.route != null and pending.route.?.selectable;
        self.route_row.setDisplay(if (has_routes) .flex else .none);
        self.route_reason.setDisplay(if (has_routes) .flex else .none);
        if (pending.route) |route| {
            self.route_selected = route.choice.route;
            try self.route_reason.setTextContent(self.cx.allocator, route.reason.text());
            for (self.route_buttons, 0..) |signal, index| signal.set(R.button(index == @backingInt(route.choice.route)));
        }
        self.root.setDisplay(.flex);
    }
    pub fn height(self: *const View) f32 {
        return if (self.sequence == null) 0 else self.card.globalRect().h;
    }
    fn cancelPress(self: *View) void {
        if (self.cx.pressed_node) |pressed| if (pressed == self.root or pressed.isDescendantOf(self.root)) self.cx.cancelPointerInteractions(.explicit);
    }
    fn decision(self: *View, approved: bool) void {
        const sequence = self.sequence orelse return;
        if (self.decision_pending.peek()) return;
        if (approved and self.expired) {
            const renew = self.callbacks.on_renew orelse return;
            renew(self.callbacks.context, sequence, self.arguments_hash) catch |err| {
                self.feedback.setTextContent(self.cx.allocator, @errorName(err)) catch {};
                return;
            };
            self.cx.requestRedraw();
            return;
        }
        self.callbacks.on_decision(self.callbacks.context, sequence, self.arguments_hash, approved) catch |err| {
            self.feedback.setTextContent(self.cx.allocator, @errorName(err)) catch {};
            return;
        };
        // The containing subtree remains alive until its next controller tick.
        self.decision_pending.set(true);
        self.cx.requestRedraw();
    }
    fn choose(self: *View, route: approval.routing.Route) void {
        const sequence = self.sequence orelse return;
        if (self.decision_pending.peek()) return;
        const callback = self.callbacks.on_route orelse return;
        callback(self.callbacks.context, sequence, self.arguments_hash, route) catch |err| {
            self.feedback.setTextContent(self.cx.allocator, @errorName(err)) catch {};
            return;
        };
        self.route_selected = route;
        for (self.route_buttons, 0..) |signal, index| signal.set(R.button(index == @backingInt(route)));
        self.feedback.setTextContent(self.cx.allocator, if (route == .new_terminal) "以卡片列明的实际会话为来源新建工作终端；创建步骤另行精确确认。只批准这一条命令。" else "只批准上述完整命令、实际目标及所选运行方式；派发前复验权限。") catch {};
        self.cx.requestRedraw();
    }
    fn chooseBatch(self: *View) void {
        self.choose(.batch);
    }
    fn chooseCurrent(self: *View) void {
        self.choose(.current_terminal);
    }
    fn chooseNew(self: *View) void {
        self.choose(.new_terminal);
    }
    fn acceptCall(self: *View) void {
        self.decision(true);
    }
    fn rejectCall(self: *View) void {
        self.decision(false);
    }
    fn copyUrl(self: *View) void {
        const url = self.requested_url orelse return;
        _ = ui.platform_services.clipboardSetText(self.cx.system_sdk, url);
    }
    fn cleanup(self: *View) void {
        if (self.requested_url) |url| self.cx.allocator.free(url);
        self.requested_url = null;
        self.sequence = null;
        self.context = null;
    }
};
pub const impact_copy = "本机将发送完整 URL（含路径和查询参数）。请确认无敏感信息，仅批准本次读取。";

fn impactTextStyle(tokens: *const ui.ThemeTokens) ui.TextStyle {
    var style = S.impact(tokens);
    const colors = theme.current();
    style.color = theme.patchInk(colors.warn_ink, &.{theme.patchPaint(colors.warn.withAlpha(20), theme.popupAction())});
    return style;
}

// Keep host approval sizing in the named styles themselves. Theme replay applies
// these styles again; overriding S.commandRow's fixed 37px after mount allowed
// the taller argument viewport to overlap both its source and impact notice.
fn panelStyle(tokens: *const ui.ThemeTokens) ui.BoxStyle {
    var style = S.panel(tokens);
    style.height = .{ .fit = .{} };
    return style;
}
fn summaryRowStyle(tokens: *const ui.ThemeTokens) ui.BoxStyle {
    var style = S.commandRow(tokens);
    style.height = .{ .fit = .{} };
    style.margin = .{ .bottom = 8 };
    return style;
}
fn footerStyle(tokens: *const ui.ThemeTokens) ui.BoxStyle {
    var style = S.footer(tokens);
    style.margin = .{ .top = 8 };
    return style;
}
