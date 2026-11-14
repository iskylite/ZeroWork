//! Fixed approval actions live outside the scrolling conversation/history.
const std = @import("std");
const ui = @import("ui");
const tools = @import("ai_local_tools.zig");
const S = @import("ai_tool_approval_styles.zig");
const theme = @import("app_theme.zig");
pub const Callbacks = struct {
    context: *anyopaque,
    decide: *const fn (*anyopaque, u64, [32]u8, bool) anyerror!void,
};
pub const View = struct {
    cx: *ui.Cx,
    target_copy_feedback: *@import("copy_button.zig").Button = undefined,
    command_copy_feedback: *@import("copy_button.zig").Button = undefined,
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
    tool_detail: *ui.Node = undefined,
    header_identity: *ui.Node,
    title: *ui.Node,
    command_copy: *ui.Node,
    command_copy_label: *ui.Signal([]const u8) = undefined,
    command: *ui.Node,
    command_row: *ui.Node = undefined,
    command_viewport: *ui.Node = undefined,
    feedback: *ui.Node,
    callbacks: Callbacks,
    sequence: ?u64 = null,
    arguments_hash: [32]u8 = @splat(0),
    command_owned: ?[]u8 = null,
    expanded: bool = true,
    state_label: *ui.Node = undefined,
    accept_text: *ui.Signal([]const u8) = undefined,
    decision_pending: *ui.Signal(bool),
    accept_style: *ui.Signal(S.ButtonStyle),
    reject_style: *ui.Signal(S.ButtonStyle),

    pub fn mount(cx: *ui.Cx, scope: *ui.Scope, callbacks: Callbacks) !*View {
        const self = try scope.createState(View, .{ .cx = cx, .root = undefined, .card = undefined, .body = undefined, .footer = undefined, .group_footer = undefined, .target_copy = undefined, .tail = undefined, .identity = undefined, .header_identity = undefined, .title = undefined, .command_copy = undefined, .command = undefined, .feedback = undefined, .callbacks = callbacks, .decision_pending = try scope.createSignal(bool, false), .accept_style = try theme.paintSignal(S.ButtonStyle, cx, scope, S.iconButton, .{true}), .reject_style = try theme.paintSignal(S.ButtonStyle, cx, scope, S.iconButton, .{false}) });
        self.accept_text = try scope.createSignal([]const u8, "批准此调用");
        try scope.onCleanup(View, self, cleanup);
        self.root = try ui.boxStyled(cx, S.wrapper, .{});
        self.root.meta.ownership.meta.test_id = "ai.approval";
        self.root.setDisplay(.none);
        self.card = try ui.boxStyled(cx, S.panel, .{});
        self.card.meta.per_frame.hooks.on_theme = panelTheme;
        @import("layer_materials.zig").card(self.card, .action);
        try self.root.appendChild(cx.allocator, self.card);
        const header = try ui.boxStyled(cx, S.header, .{});
        try self.card.appendChild(cx.allocator, header);
        const disclosure = try ui.widgets.Button(.{ .variant = .ghost, .icon_only = true, .icon_asset = ui.icons.terminal, .icon_size = @as(f32, 17), .a11y_label = "查看待批准调用详情", .base_style = try theme.paintSignal(@FieldType(ui.widgets.ControlShellConfig, "style"), cx, scope, S.disclosureButton, .{}), .on_click = cx.on(View, self, toggle) }).mount(scope, cx);
        disclosure.meta.ownership.meta.test_id = "ai.approval.disclosure";
        try header.appendChild(cx.allocator, disclosure);
        self.title = try ui.textStyled(cx, S.title, "工具调用");
        self.title.meta.ownership.meta.test_id = "ai.approval.title";
        self.title.setStyleInline(cx.allocator, .{ .width = .{ .fit = .{} }, .max_width = 220, .min_width = 0, .flex_shrink = 1 });
        try header.appendChild(cx.allocator, self.title);
        self.header_identity = try ui.textStyled(cx, S.headerIdentity, "");
        self.header_identity.meta.ownership.meta.test_id = "ai.approval.target";
        self.header_identity.setStyleInline(cx.allocator, .{ .width = .fill(), .flex = 1, .min_width = 0 });
        try header.appendChild(cx.allocator, self.header_identity);
        const state = try ui.textStyled(cx, stateStyle, "待确认");
        self.state_label = state;
        state.meta.ownership.meta.test_id = "ai.approval.state";
        state.setStyleInline(cx.allocator, .{ .padding = .{ .left = 6, .right = 6, .top = 3, .bottom = 3 }, .background = ui.Color.TRANSPARENT, .corner_radius = 5, .flex_shrink = 0 });
        try header.appendChild(cx.allocator, state);
        self.target_copy_feedback = try @import("copy_button.zig").Button.mount(cx, scope, .{ .variant = .ghost, .icon_only = true, .icon_asset = ui.icons.copy, .icon_size = @as(f32, 14), .a11y_label = "复制全部目标信息", .base_style = try theme.paintSignal(@FieldType(ui.widgets.ControlShellConfig, "style"), cx, scope, S.disclosureButton, .{}), .on_click = cx.on(View, self, copyTargets) });
        self.target_copy = self.target_copy_feedback.node;
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
        self.tool_detail = try ui.textStyled(cx, S.secondary, "");
        self.tool_detail.meta.ownership.meta.test_id = "ai.approval.tool";
        self.tool_detail.setStyleInline(cx.allocator, .{ .width = .fill(), .height = .{ .px = 20.625 }, .flex_shrink = 0 });
        self.tool_detail.setDisplay(.none);
        try scroll.content.appendChild(cx.allocator, self.tool_detail);
        const command_row = try ui.boxStyled(cx, S.commandRow, .{});
        self.command_row = command_row;
        command_row.meta.per_frame.hooks.on_theme = commandRowTheme;
        try scroll.content.appendChild(cx.allocator, command_row);
        const command_scroll = try ui.widgets.ScrollArea(.{ .direction = .vertical, .height = 27 }).mount(scope, cx);
        @import("ai_card_scroll.zig").containVertical(command_scroll);
        command_scroll.container.setStyleInline(cx.allocator, S.commandViewport(cx.tokens));
        @import("layer_materials.zig").card(command_scroll.container, .control);
        command_scroll.container.meta.per_frame.hooks.on_theme = commandViewportTheme;
        command_scroll.container.meta.ownership.meta.test_id = "ai.approval.command_scroll";
        self.command_viewport = command_scroll.container;
        command_scroll.content.setStyleInline(cx.allocator, S.commandContent(cx.tokens));
        command_scroll.content.meta.per_frame.hooks.on_theme = commandContentTheme;
        try command_row.appendChild(cx.allocator, command_scroll.container);
        self.command = try ui.textStyled(cx, S.command, "");
        self.command.setStyleInline(cx.allocator, .{ .width = .fill(), .min_width = 0, .flex_shrink = 0 });
        self.command.meta.ownership.meta.test_id = "ai.approval.command";
        try command_scroll.content.appendChild(cx.allocator, self.command);
        self.command_copy_label = try scope.createText("复制完整命令", .{});
        self.command_copy_feedback = try @import("copy_button.zig").Button.mount(cx, scope, .{ .variant = .ghost, .icon_only = true, .icon_asset = ui.icons.copy, .icon_size = @as(f32, 16), .a11y_label = self.command_copy_label, .base_style = try theme.paintSignal(@FieldType(ui.widgets.ControlShellConfig, "style"), cx, scope, S.disclosureButton, .{}), .on_click = cx.on(View, self, copyCommand) });
        const copy = self.command_copy_feedback.node;
        self.command_copy = copy;
        copy.meta.ownership.meta.test_id = "ai.approval.copy";
        try command_row.appendChild(cx.allocator, copy);
        const impact = try ui.boxStyled(cx, S.impactNotice, .{});
        impact.meta.ownership.meta.test_id = "ai.approval.impact_notice";
        try impact.appendChild(cx.allocator, try theme.icon(cx, ui.icons.get("triangle-alert").?, "warn_ink", .{ .width = .{ .px = 12 }, .height = .{ .px = 12 }, .flex_shrink = 0 }));
        self.feedback = try ui.textStyled(cx, S.impact, "");
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
        try @import("app_theme.zig").stylePrimary(cx, scope, accept, self.decision_pending);
        accept.meta.ownership.meta.test_id = "ai.approval.accept";
        try footer.appendChild(cx.allocator, accept);
        self.group_footer = try ui.boxStyled(cx, S.groupFooter, .{});
        self.group_footer.setDisplay(.none);
        try self.card.appendChild(cx.allocator, self.group_footer);
        try self.group_footer.appendChild(cx.allocator, try ui.spacer(cx));
        const group_reject = try ui.widgets.Button(.{ .label = "拒绝", .variant = .secondary, .a11y_label = "拒绝此组调用", .base_style = try theme.paintSignal(@FieldType(ui.widgets.ControlShellConfig, "style"), cx, scope, S.groupButton, .{false}), .disabled = self.decision_pending, .on_click = cx.on(View, self, rejectCall) }).mount(scope, cx);
        group_reject.meta.ownership.meta.test_id = "ai.approval.group.reject";
        try self.group_footer.appendChild(cx.allocator, group_reject);
        const group_accept = try ui.widgets.Button(.{ .label = "批准执行", .variant = .primary, .a11y_label = "批准此组调用全部目标", .base_style = try theme.paintSignal(@FieldType(ui.widgets.ControlShellConfig, "style"), cx, scope, S.groupButton, .{true}), .disabled = self.decision_pending, .on_click = cx.on(View, self, acceptCall) }).mount(scope, cx);
        try @import("app_theme.zig").stylePrimary(cx, scope, group_accept, self.decision_pending);
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
            const action_title = try @import("ai_tool_titles.zig").action(self.cx.allocator, source.tool_id orelse "run_command", source.command);
            defer self.cx.allocator.free(action_title);
            try self.title.setTextContent(self.cx.allocator, action_title);
            if (source.tool_id) |name| {
                const tool_detail = try @import("ai_tool_titles.zig").detail(self.cx.allocator, name);
                defer self.cx.allocator.free(tool_detail);
                try self.tool_detail.setTextContent(self.cx.allocator, tool_detail);
            }
            self.tool_detail.setDisplay(if (source.tool_id != null) .flex else .none);
            self.command_copy_label.set(if (terminal) "复制完整命令" else "复制调用参数");
            const target = if (source.group) try self.cx.allocator.dupe(u8, source.target) else if (source.cwd != null or terminal) try std.fmt.allocPrint(self.cx.allocator, "{s} · #{d} · 目录 {s}", .{ source.target, @backingInt(source.owner.session_id), source.cwd orelse "未知" }) else try std.fmt.allocPrint(self.cx.allocator, "{s} · #{d}", .{ source.target, @backingInt(source.owner.session_id) });
            defer self.cx.allocator.free(target);
            try self.identity.setTextContent(self.cx.allocator, target);
            const header_target = if (!source.group and std.mem.eql(u8, source.target, "bmc_ikvm")) try std.fmt.allocPrint(self.cx.allocator, "会话 #{d}", .{@backingInt(source.owner.session_id)}) else try self.cx.allocator.dupe(u8, if (source.group) "全部目标" else source.target);
            defer self.cx.allocator.free(header_target);
            try self.header_identity.setTextContent(self.cx.allocator, header_target);
            const file_change = if (source.tool_id) |name| std.mem.eql(u8, name, "file.write_text") or std.mem.eql(u8, name, "file.edit_text") else false;
            const display = if (file_change) try @import("../ai/terminal_file_tools.zig").approvalText(self.cx.allocator, source.tool_id.?, source.command) else null;
            defer if (display) |text| self.cx.allocator.free(text);
            try self.command.setTextContent(self.cx.allocator, display orelse command);
            try self.feedback.setTextContent(self.cx.allocator, if (source.group) "每个所列目标各执行一次。" else "");
            self.feedback.parent.?.setDisplay(if (source.group) .flex else .none);
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
        self.accept_text.set("批准此调用");
        try self.state_label.setTextContent(self.cx.allocator, "待确认");
        self.body.setDisplay(.flex);
        const tool_height: f32 = if (source.tool_id != null) 20.625 else 0;
        const file_extra: f32 = if (source.tool_id) |name| if (std.mem.startsWith(u8, name, "file.")) 93 else 0 else 0;
        self.command_row.setStyleInline(self.cx.allocator, .{ .height = .{ .px = 37 + file_extra } });
        self.command_viewport.setStyleInline(self.cx.allocator, .{ .height = .{ .px = 37 + file_extra } });
        const base_height: f32 = if (source.group) 207.625 else if (self.feedback.parent.?.style.display == .flex) 167.625 else 137.625;
        const desired = base_height + tool_height + file_extra;
        self.card_height = desired;
        self.target_copy.setDisplay(.flex);
        self.footer.setDisplay(.flex);
        self.footer.setStyleInline(self.cx.allocator, S.footer(self.cx.tokens));
        self.group_footer.setDisplay(.none);
        self.tail.setDisplay(.none);
        self.root.setStyleInline(self.cx.allocator, .{ .padding = .{ .left = 14, .right = 14, .top = 9 } });
        self.identity.setDisplay(.flex);
        self.identity.setStyleInline(self.cx.allocator, .{ .height = .{ .fit = .{} } });
        self.body.setStyleInline(self.cx.allocator, .{ .height = .{ .px = desired - 77 } });
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
        self.callbacks.decide(self.callbacks.context, sequence, self.arguments_hash, approved) catch |err| {
            self.feedback.setTextContent(self.cx.allocator, @errorName(err)) catch {};
            if (self.feedback.parent.?.style.display == .none) {
                self.feedback.parent.?.setDisplay(.flex);
                self.card_height += 30;
                self.body.setStyleInline(self.cx.allocator, .{ .height = .{ .px = self.card_height - 77 } });
                self.card.setStyleInline(self.cx.allocator, .{ .height = .{ .px = self.card_height } });
            }
            self.cx.requestRedraw();
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
        self.command_copy_feedback.copy(command);
    }
    fn copyTargets(self: *View) void {
        const targets = self.target_owned orelse return;
        self.target_copy_feedback.copy(targets);
    }
    fn cleanup(self: *View) void {
        if (self.target_owned) |owned| self.cx.allocator.free(owned);
        if (self.command_owned) |owned| self.cx.allocator.free(owned);
    }
};

fn stateStyle(_: *const ui.ThemeTokens) ui.TextStyle {
    return .{ .font_size = 10, .line_height = 1.65, .color = theme.current().fg_2 };
}

fn commandViewportTheme(node: *ui.Node, tokens: *const ui.ThemeTokens, allocator: std.mem.Allocator) void {
    var style = S.commandViewport(tokens);
    style.height = null; // update() owns the ordinary/file-specific viewport height.
    node.setStyleInline(allocator, style);
}

fn commandContentTheme(node: *ui.Node, tokens: *const ui.ThemeTokens, allocator: std.mem.Allocator) void {
    node.setStyleInline(allocator, S.commandContent(tokens));
}

fn commandRowTheme(node: *ui.Node, tokens: *const ui.ThemeTokens, allocator: std.mem.Allocator) void {
    var style = S.commandRow(tokens);
    style.height = null;
    node.setStyleInline(allocator, style);
}

fn panelTheme(node: *ui.Node, tokens: *const ui.ThemeTokens, allocator: std.mem.Allocator) void {
    var style = S.panel(tokens);
    style.height = null; // Approval kind and file detail size belong to update().
    node.setStyleInline(allocator, style);
}
