//! Fixed approval actions live outside the scrolling conversation/history.
const std = @import("std");
const ui = @import("ui");
const tools = @import("ai_local_tools.zig");
const S = @import("ai_tool_approval_styles.zig");
const theme = @import("app_theme.zig");
pub const Callbacks = struct {
    context: *anyopaque,
    renew: ?*const fn (*anyopaque, u64, [32]u8) anyerror!void = null,
    decide: *const fn (*anyopaque, u64, [32]u8, bool) anyerror!void,
};
pub const View = struct {
    cx: *ui.Cx,
    root: *ui.Node,
    card: *ui.Node,
    body: *ui.Node,
    footer: *ui.Node,
    group_footer: *ui.Node,
    target_copy: *ui.Node,
    target_owned: ?[]u8 = null,
    tail: *ui.Node,
    group_mode: bool = false,
    card_height: f32 = 167.625,
    identity: *ui.Node,
    header_identity: *ui.Node,
    title: *ui.Node,
    command_copy: *ui.Node,
    command: *ui.Node,
    feedback: *ui.Node,
    callbacks: Callbacks,
    sequence: ?u64 = null,
    arguments_hash: [32]u8 = @splat(0),
    command_owned: ?[]u8 = null,
    expanded: bool = true,
    expired: bool = false,
    state_label: *ui.Node = undefined,
    accept_text: *ui.Signal([]const u8) = undefined,
    decision_pending: *ui.Signal(bool),
    accept_style: *ui.Signal(S.ButtonStyle),
    reject_style: *ui.Signal(S.ButtonStyle),

    pub fn mount(cx: *ui.Cx, scope: *ui.Scope, callbacks: Callbacks) !*View {
        const self = try scope.createState(View, .{ .cx = cx, .root = undefined, .card = undefined, .body = undefined, .footer = undefined, .group_footer = undefined, .target_copy = undefined, .tail = undefined, .identity = undefined, .header_identity = undefined, .title = undefined, .command_copy = undefined, .command = undefined, .feedback = undefined, .callbacks = callbacks, .decision_pending = try scope.createSignal(bool, false), .accept_style = try scope.createSignal(S.ButtonStyle, S.iconButton(true)), .reject_style = try scope.createSignal(S.ButtonStyle, S.iconButton(false)) });
        self.accept_text = try scope.createSignal([]const u8, "批准此调用");
        try scope.onCleanup(View, self, cleanup);
        self.root = try ui.boxStyled(cx, S.wrapper, .{});
        self.root.meta.ownership.meta.test_id = "ai.approval";
        self.root.setDisplay(.none);
        self.card = try ui.boxStyled(cx, S.panel, .{});
        try self.root.appendChild(cx.allocator, self.card);
        const header = try ui.boxStyled(cx, S.header, .{});
        try self.card.appendChild(cx.allocator, header);
        const disclosure = try ui.widgets.Button(.{ .variant = .ghost, .icon_only = true, .icon_asset = ui.icons.terminal, .icon_size = @as(f32, 17), .a11y_label = "查看待批准调用详情", .base_style = S.disclosureButton(), .on_click = cx.on(View, self, toggle) }).mount(scope, cx);
        disclosure.meta.ownership.meta.test_id = "ai.approval.disclosure";
        try header.appendChild(cx.allocator, disclosure);
        self.title = try ui.textStyled(cx, S.title, "工具调用");
        self.title.meta.ownership.meta.test_id = "ai.approval.title";
        self.title.setStyleInline(cx.allocator, .{ .width = .{ .fit = .{} }, .flex_shrink = 0 });
        try header.appendChild(cx.allocator, self.title);
        self.header_identity = try ui.textStyled(cx, S.headerIdentity, "");
        self.header_identity.meta.ownership.meta.test_id = "ai.approval.target";
        self.header_identity.setStyleInline(cx.allocator, .{ .width = .fill(), .flex = 1, .min_width = 0 });
        try header.appendChild(cx.allocator, self.header_identity);
        const state = try ui.text(cx, "待确认", .{ .font_size = 10, .line_height = 1.65, .color = theme.current().fg_2 });
        self.state_label = state;
        state.meta.ownership.meta.test_id = "ai.approval.state";
        state.setStyleInline(cx.allocator, .{ .padding = .{ .left = 6, .right = 6, .top = 3, .bottom = 3 }, .background = ui.Color.TRANSPARENT, .corner_radius = 5, .flex_shrink = 0 });
        try header.appendChild(cx.allocator, state);
        self.target_copy = try ui.widgets.Button(.{ .variant = .ghost, .icon_only = true, .icon_asset = ui.icons.copy, .icon_size = @as(f32, 14), .a11y_label = "复制全部目标信息", .base_style = S.disclosureButton(), .on_click = cx.on(View, self, copyTargets) }).mount(scope, cx);
        self.target_copy.meta.ownership.meta.test_id = "ai.approval.copy_targets";
        self.target_copy.setDisplay(.none);
        try header.appendChild(cx.allocator, self.target_copy);
        const scroll = try ui.widgets.ScrollArea(.{ .direction = .vertical }).mount(scope, cx);
        @import("ai_card_scroll.zig").containVertical(scroll);
        self.body = scroll.container;
        self.body.setStyleInline(cx.allocator, S.body(cx.tokens));
        self.body.meta.ownership.meta.test_id = "ai.approval.details";
        scroll.content.setStyleInline(cx.allocator, S.content(cx.tokens));
        try self.card.appendChild(cx.allocator, self.body);
        self.identity = try ui.textStyled(cx, S.secondary, "");
        self.identity.meta.ownership.meta.test_id = "ai.approval.group_targets";
        self.identity.setStyleInline(cx.allocator, .{ .width = .fill(), .height = .{ .px = 20.625 }, .flex_shrink = 0 });
        try scroll.content.appendChild(cx.allocator, self.identity);
        const command_row = try ui.boxStyled(cx, S.commandRow, .{});
        try scroll.content.appendChild(cx.allocator, command_row);
        const command_scroll = try ui.widgets.ScrollArea(.{ .direction = .vertical, .height = 27 }).mount(scope, cx);
        @import("ai_card_scroll.zig").containVertical(command_scroll);
        command_scroll.container.setStyleInline(cx.allocator, S.commandViewport(cx.tokens));
        command_scroll.container.meta.ownership.meta.test_id = "ai.approval.command_scroll";
        command_scroll.content.setStyleInline(cx.allocator, S.commandContent(cx.tokens));
        try command_row.appendChild(cx.allocator, command_scroll.container);
        self.command = try ui.textStyled(cx, S.command, "");
        self.command.setStyleInline(cx.allocator, .{ .width = .fill(), .min_width = 0, .flex_shrink = 0 });
        self.command.meta.ownership.meta.test_id = "ai.approval.command";
        try command_scroll.content.appendChild(cx.allocator, self.command);
        const copy = try ui.widgets.Button(.{ .variant = .ghost, .icon_only = true, .icon_asset = ui.icons.copy, .icon_size = @as(f32, 16), .a11y_label = "复制完整命令", .base_style = S.disclosureButton(), .on_click = cx.on(View, self, copyCommand) }).mount(scope, cx);
        self.command_copy = copy;
        copy.meta.ownership.meta.test_id = "ai.approval.copy";
        try command_row.appendChild(cx.allocator, copy);
        const impact = try ui.boxStyled(cx, S.impactNotice, .{});
        impact.meta.ownership.meta.test_id = "ai.approval.impact_notice";
        try impact.appendChild(cx.allocator, try ui.iconTint(cx, ui.icons.get("triangle-alert").?, theme.current().warn_ink, .{ .width = .{ .px = 12 }, .height = .{ .px = 12 }, .flex_shrink = 0 }));
        self.feedback = try ui.textStyled(cx, S.impact, "影响 · 尚未核实");
        self.feedback.meta.ownership.meta.test_id = "ai.approval.impact";
        self.feedback.setStyleInline(cx.allocator, .{ .width = .fill(), .min_width = 0, .flex = 1, .flex_shrink = 0 });
        try impact.appendChild(cx.allocator, self.feedback);
        try scroll.content.appendChild(cx.allocator, impact);
        const footer = try ui.boxStyled(cx, S.footer, .{});
        self.footer = footer;
        try self.card.appendChild(cx.allocator, footer);
        try footer.appendChild(cx.allocator, try ui.spacer(cx));
        const reject = try ui.widgets.Button(.{ .variant = .secondary, .label = "拒绝此调用", .a11y_label = "拒绝此调用", .base_style = self.reject_style, .disabled = self.decision_pending, .on_click = cx.on(View, self, rejectCall) }).mount(scope, cx);
        reject.meta.ownership.meta.test_id = "ai.approval.reject";
        try footer.appendChild(cx.allocator, reject);
        const accept = try ui.widgets.Button(.{ .variant = .primary, .label = self.accept_text, .a11y_label = self.accept_text, .base_style = self.accept_style, .disabled = self.decision_pending, .on_click = cx.on(View, self, acceptCall) }).mount(scope, cx);
        accept.meta.ownership.meta.test_id = "ai.approval.accept";
        try footer.appendChild(cx.allocator, accept);
        self.group_footer = try ui.boxStyled(cx, S.groupFooter, .{});
        self.group_footer.setDisplay(.none);
        try self.card.appendChild(cx.allocator, self.group_footer);
        try self.group_footer.appendChild(cx.allocator, try ui.spacer(cx));
        const group_reject = try ui.widgets.Button(.{ .label = "拒绝", .variant = .secondary, .a11y_label = "拒绝此组调用", .base_style = S.groupButton(false), .disabled = self.decision_pending, .on_click = cx.on(View, self, rejectCall) }).mount(scope, cx);
        group_reject.meta.ownership.meta.test_id = "ai.approval.group.reject";
        try self.group_footer.appendChild(cx.allocator, group_reject);
        const group_accept = try ui.widgets.Button(.{ .label = "批准执行", .variant = .primary, .a11y_label = "批准此组调用全部目标", .base_style = S.groupButton(true), .disabled = self.decision_pending, .on_click = cx.on(View, self, acceptCall) }).mount(scope, cx);
        group_accept.meta.ownership.meta.test_id = "ai.approval.group.accept";
        try self.group_footer.appendChild(cx.allocator, group_accept);
        self.tail = try ui.boxStyled(cx, S.tail, .{});
        try self.card.appendChild(cx.allocator, self.tail);
        return self;
    }
    pub fn update(self: *View, approval: ?tools.Approval) !void {
        self.accept_style.set(S.iconButton(true));
        self.reject_style.set(S.iconButton(false));
        const source = approval orelse {
            if (self.sequence != null) self.cancelOldPress();
            self.root.setDisplay(.none);
            self.sequence = null;
            return;
        };
        if (self.sequence != source.sequence) {
            self.cancelOldPress();
            const command = try self.cx.allocator.dupe(u8, source.command);
            errdefer self.cx.allocator.free(command);
            const terminal = source.tool_id == null or std.mem.eql(u8, source.tool_id.?, "run_command");
            try self.title.setTextContent(self.cx.allocator, if (terminal) "请求执行命令" else @import("ai_tool_titles.zig").title(source.tool_id.?) orelse "工具调用");
            if (self.command_copy.behavior.interaction.a11y) |*attrs| attrs.label = if (terminal) "复制完整命令" else "复制调用参数";
            const target = if (source.group) try self.cx.allocator.dupe(u8, source.target) else if (source.cwd != null or terminal) try std.fmt.allocPrint(self.cx.allocator, "{s} · #{d} · 目录 {s}", .{ source.target, @backingInt(source.owner.session_id), source.cwd orelse "未知" }) else try std.fmt.allocPrint(self.cx.allocator, "{s} · #{d}", .{ source.target, @backingInt(source.owner.session_id) });
            defer self.cx.allocator.free(target);
            try self.identity.setTextContent(self.cx.allocator, target);
            try self.header_identity.setTextContent(self.cx.allocator, if (source.group) "全部目标" else source.target);
            try self.command.setTextContent(self.cx.allocator, command);
            try self.feedback.setTextContent(self.cx.allocator, if (source.group) (if (terminal) "影响 · 上述全部目标各执行一次此命令；写入及业务影响尚未核实。" else "影响 · 上述全部目标各执行一次此调用；写入及业务影响尚未核实。") else "影响 · 尚未核实");
            const target_copy = try self.cx.allocator.dupe(u8, target);
            if (self.target_owned) |old| self.cx.allocator.free(old);
            self.target_owned = target_copy;
            if (self.command_owned) |old| self.cx.allocator.free(old);
            self.command_owned = command;
            self.sequence = source.sequence;
            self.arguments_hash = source.arguments_hash;
            self.group_mode = source.group;
            self.expanded = true;
            self.decision_pending.set(false);
        }
        if (self.expired != source.expired) self.decision_pending.set(false);
        self.expired = source.expired;
        self.accept_text.set(if (source.expired) "重新确认" else "批准此调用");
        try self.state_label.setTextContent(self.cx.allocator, if (source.expired) "已过期 · 流程暂停" else "待确认");
        self.body.setDisplay(.flex);
        const desired: f32 = if (source.group) 207.625 else 167.625;
        self.card_height = desired;
        self.target_copy.setDisplay(.flex);
        self.footer.setDisplay(.flex);
        self.footer.setStyleInline(self.cx.allocator, S.footer(self.cx.tokens));
        self.group_footer.setDisplay(.none);
        self.tail.setDisplay(.none);
        self.root.setStyleInline(self.cx.allocator, .{ .padding = .{ .left = 14, .right = 14, .top = 9 } });
        self.identity.setDisplay(.flex);
        self.identity.setStyleInline(self.cx.allocator, .{ .height = .{ .fit = .{} } });
        self.body.setStyleInline(self.cx.allocator, .{ .height = .{ .px = if (source.group) 130.625 else 90.625 } });
        if (self.card.style.height != .px or self.card.style.height.px != desired) self.card.setStyleInline(self.cx.allocator, .{ .height = .{ .px = desired } });
        self.root.setDisplay(.flex);
    }
    pub fn height(self: *const View) f32 {
        return if (self.root.style.display == .none) 0 else self.card_height;
    }
    fn cancelOldPress(self: *View) void {
        if (self.cx.pressed_node) |pressed| {
            if (pressed == self.root or pressed.isDescendantOf(self.root)) self.cx.cancelPointerInteractions(.explicit);
        }
    }
    fn toggle(self: *View) void {
        self.expanded = true; // Target, arguments and impact remain visible while approval is pending.
        self.body.setDisplay(.flex);
        self.cx.requestRedraw();
    }
    fn decision(self: *View, approved: bool) void {
        const sequence = self.sequence orelse return;
        if (self.decision_pending.peek()) return;
        if (approved and self.expired) {
            const renew = self.callbacks.renew orelse return;
            renew(self.callbacks.context, sequence, self.arguments_hash) catch |err| {
                self.feedback.setTextContent(self.cx.allocator, @errorName(err)) catch {};
                return;
            };
            self.cx.requestRedraw();
            return;
        }
        self.callbacks.decide(self.callbacks.context, sequence, self.arguments_hash, approved) catch |err| {
            self.feedback.setTextContent(self.cx.allocator, @errorName(err)) catch {};
            return;
        };
        self.decision_pending.set(true);
    }
    fn acceptCall(self: *View) void {
        self.decision(true);
    }
    fn rejectCall(self: *View) void {
        self.decision(false);
    }
    fn copyCommand(self: *View) void {
        const command = self.command_owned orelse return;
        _ = ui.platform_services.clipboardSetText(self.cx.system_sdk, command);
    }
    fn copyTargets(self: *View) void {
        const targets = self.target_owned orelse return;
        _ = ui.platform_services.clipboardSetText(self.cx.system_sdk, targets);
    }
    fn cleanup(self: *View) void {
        if (self.target_owned) |owned| self.cx.allocator.free(owned);
        if (self.command_owned) |owned| self.cx.allocator.free(owned);
    }
};
