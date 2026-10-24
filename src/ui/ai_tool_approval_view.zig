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
    root: *ui.Node,
    card: *ui.Node,
    body: *ui.Node,
    footer: *ui.Node,
    group_footer: *ui.Node,
    target_copy: *ui.Node,
    target_owned: ?[]u8 = null,
    tail: *ui.Node,
    group_mode: bool = false,
    card_height: f32 = 152,
    identity: *ui.Node,
    title: *ui.Node,
    command_copy: *ui.Node,
    command: *ui.Node,
    feedback: *ui.Node,
    callbacks: Callbacks,
    sequence: ?u64 = null,
    arguments_hash: [32]u8 = @splat(0),
    command_owned: ?[]u8 = null,
    expanded: bool = true,
    decision_pending: *ui.Signal(bool),
    accept_style: *ui.Signal(S.ButtonStyle),
    reject_style: *ui.Signal(S.ButtonStyle),

    pub fn mount(cx: *ui.Cx, scope: *ui.Scope, callbacks: Callbacks) !*View {
        const self = try scope.createState(View, .{ .cx = cx, .root = undefined, .card = undefined, .body = undefined, .footer = undefined, .group_footer = undefined, .target_copy = undefined, .tail = undefined, .identity = undefined, .title = undefined, .command_copy = undefined, .command = undefined, .feedback = undefined, .callbacks = callbacks, .decision_pending = try scope.createSignal(bool, false), .accept_style = try scope.createSignal(S.ButtonStyle, S.iconButton(true)), .reject_style = try scope.createSignal(S.ButtonStyle, S.iconButton(false)) });
        try scope.onCleanup(View, self, cleanup);
        self.root = try ui.boxStyled(cx, S.wrapper, .{});
        self.root.meta.ownership.meta.test_id = "ai.approval";
        self.root.setDisplay(.none);
        self.card = try ui.boxStyled(cx, S.panel, .{});
        try self.root.appendChild(cx.allocator, self.card);
        const header = try ui.boxStyled(cx, S.header, .{});
        try self.card.appendChild(cx.allocator, header);
        const disclosure = try ui.widgets.Button(.{ .variant = .ghost, .icon_only = true, .icon_asset = ui.icons.hand, .icon_size = @as(f32, 14), .a11y_label = "查看待批准调用详情", .base_style = S.disclosureButton(), .on_click = cx.on(View, self, toggle) }).mount(scope, cx);
        disclosure.meta.ownership.meta.test_id = "ai.approval.disclosure";
        try header.appendChild(cx.allocator, disclosure);
        self.title = try ui.textStyled(cx, S.title, "工具调用");
        self.title.meta.ownership.meta.test_id = "ai.approval.title";
        try header.appendChild(cx.allocator, self.title);
        const state = try ui.textStyled(cx, S.secondary, "待批准");
        try header.appendChild(cx.allocator, state);
        try header.appendChild(cx.allocator, try ui.spacer(cx));
        self.target_copy = try ui.widgets.Button(.{ .variant = .ghost, .icon_only = true, .icon_asset = ui.icons.copy, .icon_size = @as(f32, 14), .a11y_label = "复制全部目标信息", .base_style = S.disclosureButton(), .on_click = cx.on(View, self, copyTargets) }).mount(scope, cx);
        self.target_copy.meta.ownership.meta.test_id = "ai.approval.copy_targets";
        self.target_copy.setDisplay(.none);
        try header.appendChild(cx.allocator, self.target_copy);
        const scroll = try ui.widgets.ScrollArea(.{ .direction = .vertical }).mount(scope, cx);
        self.body = scroll.container;
        self.body.setStyleInline(cx.allocator, S.body(cx.tokens));
        self.body.meta.ownership.meta.test_id = "ai.approval.details";
        scroll.content.setStyleInline(cx.allocator, S.content(cx.tokens));
        try self.card.appendChild(cx.allocator, self.body);
        self.identity = try ui.textStyled(cx, S.secondary, "");
        self.identity.meta.ownership.meta.test_id = "ai.approval.target";
        try scroll.content.appendChild(cx.allocator, self.identity);
        const command_row = try ui.boxStyled(cx, S.commandRow, .{});
        try scroll.content.appendChild(cx.allocator, command_row);
        const command_scroll = try ui.widgets.ScrollArea(.{ .direction = .vertical, .height = 27 }).mount(scope, cx);
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
        self.feedback = try ui.textStyled(cx, S.impact, "影响 · 尚未核实");
        self.feedback.meta.ownership.meta.test_id = "ai.approval.impact";
        try scroll.content.appendChild(cx.allocator, self.feedback);
        const footer = try ui.boxStyled(cx, S.footer, .{});
        self.footer = footer;
        try self.card.appendChild(cx.allocator, footer);
        try footer.appendChild(cx.allocator, try ui.spacer(cx));
        const reject = try ui.widgets.Button(.{ .variant = .secondary, .label = "拒绝", .icon_asset = ui.icons.x, .icon_size = @as(f32, 16), .a11y_label = "拒绝此调用", .base_style = self.reject_style, .disabled = self.decision_pending, .on_click = cx.on(View, self, rejectCall) }).mount(scope, cx);
        reject.meta.ownership.meta.test_id = "ai.approval.reject";
        try footer.appendChild(cx.allocator, reject);
        const accept = try ui.widgets.Button(.{ .variant = .primary, .label = "批准执行", .icon_asset = ui.icons.check, .icon_size = @as(f32, 16), .a11y_label = "批准此调用", .base_style = self.accept_style, .disabled = self.decision_pending, .on_click = cx.on(View, self, acceptCall) }).mount(scope, cx);
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
            try self.title.setTextContent(self.cx.allocator, if (terminal) "执行命令" else "工具调用");
            if (self.command_copy.behavior.interaction.a11y) |*attrs| attrs.label = if (terminal) "复制完整命令" else "复制调用参数";
            const target = if (source.group) try self.cx.allocator.dupe(u8, source.target) else if (source.cwd != null or terminal) try std.fmt.allocPrint(self.cx.allocator, "{s} · #{d} · 目录 {s}", .{ source.target, @backingInt(source.owner.session_id), source.cwd orelse "未知" }) else try std.fmt.allocPrint(self.cx.allocator, "{s} · #{d}", .{ source.target, @backingInt(source.owner.session_id) });
            defer self.cx.allocator.free(target);
            try self.identity.setTextContent(self.cx.allocator, target);
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
        self.body.setDisplay(.flex);
        const parent_height = if (self.root.parent) |parent| parent.globalRect().h else 0;
        const desired: f32 = if (source.group and parent_height >= 420) 216 else 152;
        self.card_height = desired;
        self.target_copy.setDisplay(if (source.group) .flex else .none);
        const compact_group = source.group and desired == 152;
        self.footer.setDisplay(if (compact_group) .none else .flex);
        if (source.group) self.footer.setStyleInline(self.cx.allocator, S.groupIconFooter(self.cx.tokens)) else self.footer.setStyleInline(self.cx.allocator, S.footer(self.cx.tokens));
        self.group_footer.setDisplay(if (compact_group) .flex else .none);
        self.tail.setDisplay(if (source.group) .none else .flex);
        self.root.setStyleInline(self.cx.allocator, .{ .padding = .{ .left = if (compact_group) 14 else 20, .right = if (compact_group) 14 else 20 } });
        self.body.setStyleInline(self.cx.allocator, .{ .height = .{ .px = if (source.group) desired - 66 else 73 } });
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
        const copied = ui.platform_services.clipboardSetText(self.cx.system_sdk, command);
        self.feedback.setTextContent(self.cx.allocator, if (copied) "已复制" else "复制失败") catch {};
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
