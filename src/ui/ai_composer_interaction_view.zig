//! A stable native composer slot; ordinary editor, attachments and actions stay
//! mounted and are hidden while a request is expanded. The caller owns
//! authorization and supplies exact broker identities.
const std = @import("std");
const ui = @import("ui");
const question = @import("../ai/user_interaction.zig");
const routing = @import("../ai/execution_routing.zig");
const S = @import("ai_composer_interaction_styles.zig");
pub const Ticket = union(enum) {
    tool: struct { sequence: u64, hash: [32]u8 },
    host: struct { sequence: u64, hash: [32]u8 },
    question: question.Ticket,
    pub fn eql(a: Ticket, b: Ticket) bool {
        if (std.meta.activeTag(a) != std.meta.activeTag(b)) return false;
        return switch (a) {
            .tool => |v| v.sequence == b.tool.sequence and std.mem.eql(u8, &v.hash, &b.tool.hash),
            .host => |v| v.sequence == b.host.sequence and std.mem.eql(u8, &v.hash, &b.host.hash),
            .question => |v| v.eql(b.question),
        };
    }
};
pub const Option = struct { id: []const u8, label: []const u8, description: []const u8 = "" };
pub const Snapshot = struct {
    ticket: Ticket,
    title: []const u8,
    target: []const u8 = "",
    detail: []const u8 = "",
    impact: []const u8 = "",
    options: []const Option = &.{},
    allow_custom: bool = true,
    route: ?routing.Route = null,
    route_selectable: bool = false,
    route_reason: []const u8 = "",
};
pub const Action = union(enum) { approve, reject, answer: struct { option_id: ?[]const u8, text: []const u8 }, route: routing.Route };
pub const Callbacks = struct { context: *anyopaque, act: *const fn (*anyopaque, Ticket, Action) anyerror!void };
const Owned = struct {
    arena: std.heap.ArenaAllocator,
    value: Snapshot,
    fn init(a: std.mem.Allocator, source: Snapshot) !Owned {
        var arena = std.heap.ArenaAllocator.init(a);
        errdefer arena.deinit();
        const allocator = arena.allocator();
        var value = source;
        inline for (.{ "title", "target", "detail", "impact", "route_reason" }) |field| @field(value, field) = try allocator.dupe(u8, @field(source, field));
        const options = try allocator.dupe(Option, source.options);
        for (options) |*option| {
            option.id = try allocator.dupe(u8, option.id);
            option.label = try allocator.dupe(u8, option.label);
            option.description = try allocator.dupe(u8, option.description);
        }
        value.options = options;
        return .{ .arena = arena, .value = value };
    }
};
const radio_values = [_][]const u8{ "0", "1", "2", "3", "4", "5", "custom" };
const radio_options = blk: {
    var options: [7]ui.widgets.checkbox.RadioOption = undefined;
    for (0..7) |index| options[index] = .{ .value = radio_values[index], .label = "", .test_id = std.fmt.comptimePrint("ai.interaction.option.{d}", .{index}) };
    break :blk options;
};
pub const View = struct {
    cx: *ui.Cx,
    scope: *ui.Scope,
    callbacks: Callbacks,
    panel: *ui.Node = undefined,
    content: *ui.Node = undefined,
    actions: *ui.Node = undefined,
    pending: *ui.Node = undefined,
    heading_icon: *ui.Node = undefined,
    title: *ui.Node = undefined,
    target: *ui.Node = undefined,
    command_row: *ui.Node = undefined,
    command: *ui.Node = undefined,
    impact_row: *ui.Node = undefined,
    impact: *ui.Node = undefined,
    option_group: *ui.Node = undefined,
    option_rows: [7]*ui.Node = undefined,
    option_labels: [6]*ui.Node = undefined,
    option_descriptions: [6]*ui.Node = undefined,
    custom_label: *ui.Node = undefined,
    custom: ui.widgets.input.InputResult = undefined,
    selected: *ui.Signal(?[]const u8),
    custom_text: *ui.Signal([]const u8),
    accept: *ui.Node = undefined,
    reject: *ui.Node = undefined,
    submit_button: *ui.Node = undefined,
    disabled: *ui.Signal(bool),
    pending_label: *ui.Node = undefined,
    route_row: *ui.Node = undefined,
    route_reason: *ui.Node = undefined,
    route_buttons: [3]*ui.Node = undefined,
    error_label: *ui.Node = undefined,
    source: ?Owned = null,
    postponed: bool = false,
    visible: bool = true,
    submitted: bool = false,
    colors: ?S.theme.Colors = null,
    input_focus: ?ui.Handler(void) = null,
    pub fn mount(cx: *ui.Cx, scope: *ui.Scope, callbacks: Callbacks) !*View {
        const self = try scope.createState(View, .{ .cx = cx, .scope = scope, .callbacks = callbacks, .selected = try scope.createSignal(?[]const u8, null), .custom_text = try scope.createText("", .{ .capacity = 4096 }), .disabled = try scope.createSignal(bool, false) });
        try scope.onCleanup(View, self, release);
        const scroll = try ui.widgets.ScrollArea(.{ .direction = .vertical }).mount(scope, cx);
        @import("ai_card_scroll.zig").containVertical(scroll);
        self.panel = scroll.container;
        self.panel.meta.ownership.meta.test_id = "ai.interaction.panel";
        self.panel.setStyleInline(cx.allocator, S.panel(false, false));
        self.content = scroll.content;
        self.content.setStyleInline(cx.allocator, S.content());
        const heading = try ui.box(cx, S.heading(), .{});
        self.heading_icon = try ui.iconTint(cx, ui.icons.shield, S.theme.current().accent, S.icon(18));
        try heading.appendChild(cx.allocator, self.heading_icon);
        self.title = try self.label(heading, "", S.text(13, 20, 600, false));
        self.title.meta.ownership.meta.test_id = "ai.interaction.title";
        try self.content.appendChild(cx.allocator, heading);
        self.target = try self.label(self.content, "", S.text(11, 16, 400, true));
        self.target.setStyleInline(cx.allocator, .{ .margin = .{ .left = 24, .top = -8 } });
        self.target.meta.ownership.meta.test_id = "ai.interaction.target";
        self.command_row = try ui.box(cx, .{ .width = .fill(), .direction = .row, .align_items = .center, .gap = 6, .flex_shrink = 0 }, .{});
        self.command = try self.label(self.command_row, "", @import("ai_tool_approval_styles.zig").command(cx.tokens));
        self.command.setStyleInline(cx.allocator, .{ .padding = .{ .top = 8, .bottom = 8, .left = 10, .right = 10 }, .background = S.theme.current().surface_2, .border = .{ .radius = 7 } });
        self.command.meta.ownership.meta.test_id = "ai.interaction.command";
        const copy = try self.button(self.command_row, "", "复制命令或详情", "copy", "ai.interaction.copy", false, copyDetail);
        copy.setStyleInline(cx.allocator, .{ .width = .{ .px = 24 }, .height = .{ .px = 24 }, .padding = .{} });
        try self.content.appendChild(cx.allocator, self.command_row);
        self.impact_row = try ui.box(cx, S.impactRow(), .{});
        self.impact_row.meta.ownership.meta.test_id = "ai.interaction.impact.note";
        const impact_icon = try ui.iconTint(cx, ui.icons.get("info").?, S.theme.current().fg_3, S.icon(12));
        impact_icon.setStyleInline(cx.allocator, .{ .margin = .{ .top = 3 } });
        try self.impact_row.appendChild(cx.allocator, impact_icon);
        self.impact = try self.label(self.impact_row, "", S.text(11, 18, 400, true));
        try self.content.appendChild(cx.allocator, self.impact_row);
        self.impact.meta.ownership.meta.test_id = "ai.interaction.impact";
        self.route_row = try ui.box(cx, .{ .width = .fill(), .direction = .row, .gap = 6, .flex_shrink = 0 }, .{});
        inline for (.{ .{ "批处理", chooseBatch }, .{ "当前终端", chooseCurrent }, .{ "新工作终端", chooseNew } }, 0..) |item, index| self.route_buttons[index] = try self.button(self.route_row, item[0], item[0], "terminal", std.fmt.comptimePrint("ai.interaction.route.{d}", .{index}), false, item[1]);
        try self.content.appendChild(cx.allocator, self.route_row);
        self.route_reason = try self.label(self.content, "", S.text(11, 16, 400, true));
        self.option_group = try ui.widgets.RadioGroup(.{ .options = &radio_options, .value = self.selected, .disabled = self.disabled, .on_change = cx.on(View, self, selectionChanged) }).mount(scope, cx);
        self.option_group.setStyleInline(cx.allocator, .{ .width = .fill(), .direction = .column, .gap = 4, .flex_shrink = 0 });
        for (self.option_group.children.items, 0..) |row, index| {
            self.option_rows[index] = row;
            row.setStyleInline(cx.allocator, S.option(false));
            if (row.children.items.len > 0) {
                const circle = row.children.items[0];
                circle.setStyleInline(cx.allocator, .{ .width = .{ .px = 12 }, .height = .{ .px = 12 }, .flex_shrink = 0, .background = ui.Color.TRANSPARENT, .border = .{ .width = 1, .color = S.theme.current().fg_3, .radius = 6 } });
                if (circle.children.items.len > 0) circle.children.items[0].setStyleInline(cx.allocator, .{ .width = .{ .px = 6 }, .height = .{ .px = 6 } });
            }
            if (row.children.items.len > 1) row.children.items[1].setDisplay(.none);
            if (index < 6) {
                const option_copy = try ui.box(cx, .{ .width = .fill(), .flex = 1, .min_width = 0, .direction = .column, .gap = 1, .height = .{ .fit = .{} } }, .{});
                self.option_labels[index] = try self.label(option_copy, "", S.text(12, 16, 500, false));
                self.option_descriptions[index] = try self.label(option_copy, "", S.text(11, 16, 400, true));
                try row.appendChild(cx.allocator, option_copy);
            } else {
                self.custom_label = try self.label(row, "其他", S.text(12, 16, 500, false));
                self.custom_label.meta.ownership.meta.test_id = "ai.interaction.other";
                self.custom = try ui.widgets.Input(.{ .value = self.custom_text, .placeholder = "输入你的答案…", .embedded = true, .growable = true, .disabled = self.disabled, .on_change = cx.on(View, self, customChanged) }).mountResult(scope, cx);
                self.custom.node.setStyleInline(cx.allocator, .{ .width = .fill(), .flex = 1, .min_width = 0, .height = .{ .px = 28 }, .background = S.theme.current().surface_2, .border = .{ .radius = 7 } });
                self.custom.input_container.setStyleInline(cx.allocator, .{ .height = .{ .px = 28 } });
                self.custom.state.font_size = 11;
                self.custom.input_container.meta.ownership.meta.test_id = "ai.interaction.answer";
                self.input_focus = self.custom.input_container.behavior.events.on_focus;
                self.custom.input_container.behavior.events.on_focus = cx.on(View, self, customFocused);
                try row.appendChild(cx.allocator, self.custom.node);
            }
        }
        try self.content.appendChild(cx.allocator, self.option_group);
        self.error_label = try self.label(self.content, "", S.text(11, 16, 400, true));
        self.error_label.meta.ownership.meta.test_id = "ai.interaction.error";
        self.actions = try ui.box(cx, S.actions(), .{});
        self.actions.meta.ownership.meta.test_id = "ai.interaction.actions";
        try self.actions.appendChild(cx.allocator, try ui.spacer(cx));
        _ = try self.button(self.actions, "稍后处理", "稍后处理", "corner-down-left", "ai.interaction.postpone", false, postpone);
        self.reject = try self.button(self.actions, "拒绝", "拒绝执行", "x", "ai.interaction.reject", false, deny);
        self.accept = try self.button(self.actions, "允许执行", "允许执行", "check", "ai.interaction.approve", false, approve);
        self.submit_button = try self.button(self.actions, "提交答案", "提交答案", "check", "ai.interaction.submit", false, submit);
        self.pending = try ui.widgets.Button(.{ .variant = .secondary, .a11y_label = "继续处理待办请求", .base_style = S.pending(), .on_click = cx.on(View, self, reopen) }).mount(scope, cx);
        for (self.pending.children.items) |child| child.setDisplay(.none);
        self.pending.meta.ownership.meta.test_id = "ai.interaction.pending";
        self.pending.setStyleInline(cx.allocator, .{ .position = .absolute, .inset = .{ .right = .{ .px = 14 }, .bottom = .{ .percent = 100 } }, .margin = .{ .bottom = 8 }, .height = .{ .px = 26 }, .width = .{ .fit = .{} }, .max_width = 332, .direction = .row, .align_items = .center, .gap = 6, .padding = .{ .left = 8, .right = 8 }, .background = S.theme.current().surface_2, .border = .{ .radius = 8 }, .z_index = 2, .shadows = ui.ShadowList.of(&.{.{ .color = ui.Color.rgba(0, 0, 0, 64), .blur = 12, .offset_y = 4 }}) });
        try self.pending.appendChild(cx.allocator, try ui.iconTint(cx, ui.icons.clock, S.theme.current().accent, S.icon(13)));
        self.pending_label = try self.label(self.pending, "", S.text(11, 16, 400, false));
        self.pending_label.setStyleInline(cx.allocator, .{ .width = .{ .fit = .{} }, .flex = 0 });
        try self.pending.appendChild(cx.allocator, try ui.iconTint(cx, ui.icons.chevron_right, S.theme.current().fg_2, S.icon(12)));
        self.show();
        return self;
    }
    fn label(self: *View, parent: *ui.Node, value: []const u8, style: ui.TextStyle) !*ui.Node {
        const node = try ui.text(self.cx, "", style);
        try node.setTextContent(self.cx.allocator, value);
        node.setStyleInline(self.cx.allocator, .{ .width = .fill(), .height = .{ .fit = .{} }, .min_width = 0, .flex = 1, .flex_shrink = 0 });
        try parent.appendChild(self.cx.allocator, node);
        return node;
    }
    fn button(self: *View, parent: *ui.Node, text: []const u8, a11y: []const u8, icon_name: []const u8, id: []const u8, primary: bool, comptime callback: fn (*View) void) !*ui.Node {
        const button_node = try ui.widgets.Button(.{ .variant = .secondary, .a11y_label = a11y, .base_style = S.action(primary), .disabled = self.disabled, .on_click = self.cx.on(View, self, callback) }).mount(self.scope, self.cx);
        for (button_node.children.items) |child| child.setDisplay(.none);
        button_node.setStyleInline(self.cx.allocator, .{ .direction = .row, .align_items = .center, .gap = 4, .opacity = 1 });
        button_node.meta.ownership.meta.test_id = id;
        const ink = if (primary) S.theme.actionForeground(S.theme.current().action_accent) else S.theme.current().fg_1;
        try button_node.appendChild(self.cx.allocator, try ui.iconTint(self.cx, ui.icons.get(icon_name) orelse ui.icons.check, ink, S.icon(12)));
        if (text.len != 0) {
            const node = try self.label(button_node, text, S.text(10, 14, 400, false));
            node.setStyleInline(self.cx.allocator, .{ .width = .{ .fit = .{} }, .flex = 0 });
            node.setTextColor(ink);
        }
        try parent.appendChild(self.cx.allocator, button_node);
        return button_node;
    }
    pub fn update(self: *View, snapshot: ?Snapshot) !bool {
        const changed = if (snapshot) |value| if (self.source) |old| !value.ticket.eql(old.value.ticket) else true else self.source != null;
        if (changed) {
            self.cancelPress();
            self.releaseFocus();
            const next = if (snapshot) |value| try Owned.init(self.cx.allocator, value) else null;
            if (self.source) |*old| old.arena.deinit();
            self.source = next;
            self.postponed = false;
            self.submitted = false;
            self.disabled.set(false);
            self.selected.set(null);
            self.custom_text.set("");
            self.error_label.setDisplay(.none);
            if (self.source) |owned| {
                const value = owned.value;
                const is_question = value.ticket == .question;
                try self.title.setTextContent(self.cx.allocator, value.title);
                try self.target.setTextContent(self.cx.allocator, value.target);
                self.target.setDisplay(if (value.target.len == 0) .none else .flex);
                try self.command.setTextContent(self.cx.allocator, value.detail);
                self.command_row.setDisplay(if (is_question or value.detail.len == 0) .none else .flex);
                try self.impact.setTextContent(self.cx.allocator, value.impact);
                self.impact_row.setDisplay(if (value.impact.len == 0) .none else .flex);
                self.option_group.setDisplay(if (is_question) .flex else .none);
                for (0..6) |index| {
                    self.option_rows[index].setDisplay(if (is_question and index < value.options.len) .flex else .none);
                    if (index < value.options.len) {
                        try self.option_labels[index].setTextContent(self.cx.allocator, value.options[index].label);
                        try self.option_descriptions[index].setTextContent(self.cx.allocator, value.options[index].description);
                        self.option_descriptions[index].setDisplay(if (value.options[index].description.len == 0) .none else .flex);
                    }
                }
                self.option_rows[6].setDisplay(if (is_question and value.allow_custom) .flex else .none);
                if (is_question and value.options.len == 0) self.selected.set("custom");
                try self.pending_label.setTextContent(self.cx.allocator, if (is_question) "有 1 个问题待回答" else "有 1 项操作待确认");
                const asset = if (is_question) ui.icons.get("message-circle").? else ui.icons.shield;
                if (asset.icon_id) |id| if (asset.pickRep(18)) |rep| self.heading_icon.setIcon(.{ .icon_id = id, .rep = rep, .tint = S.theme.current().accent });
                self.panel.setStyleInline(self.cx.allocator, S.panel(is_question, value.route_selectable));
            }
        }
        if (snapshot) |value| {
            self.route_row.setDisplay(if (value.route_selectable) .flex else .none);
            self.route_reason.setDisplay(if (value.route_reason.len > 0 and value.route_selectable) .flex else .none);
            if (value.route_selectable) {
                try self.route_reason.setTextContent(self.cx.allocator, value.route_reason);
                for (self.route_buttons, 0..) |button_node, index| button_node.setBackground(if (value.route != null and @backingInt(value.route.?) == index) S.theme.popupSelection() else S.theme.popupAction());
            }
        }
        self.paint();
        self.show();
        return changed;
    }
    pub fn setVisible(self: *View, visible: bool) void {
        if (self.visible and !visible) {
            self.cancelPress();
            self.releaseFocus();
        }
        self.visible = visible;
        self.show();
    }
    pub fn expanded(self: *const View) bool {
        return self.visible and self.source != null and !self.postponed;
    }
    pub fn pendingVisible(self: *const View) bool {
        return self.visible and self.source != null and self.postponed;
    }
    pub fn expandedSizing(self: *const View) ui.Sizing {
        // Use the wrapped content measured by layout, capped independently of
        // the composer. An explicit result lets its parent re-anchor the dock.
        return .{ .px = @min(S.max_body_height, self.content.globalRect().h) + 44 };
    }
    fn show(self: *View) void {
        self.panel.setDisplay(if (self.expanded()) .flex else .none);
        self.actions.setDisplay(if (self.expanded()) .flex else .none);
        self.pending.setDisplay(if (self.pendingVisible()) .flex else .none);
        const is_question = if (self.source) |source| source.value.ticket == .question else false;
        self.accept.setDisplay(if (is_question) .none else .flex);
        self.reject.setDisplay(if (is_question) .none else .flex);
        self.submit_button.setDisplay(if (is_question) .flex else .none);
        const selected = self.selected.peek();
        const custom_selected = selected != null and std.mem.eql(u8, selected.?, "custom");
        self.custom_label.setDisplay(if (custom_selected) .none else .flex);
        self.custom.node.setDisplay(if (custom_selected) .flex else .none);
        for (self.option_rows, 0..) |row, index| {
            row.setBackground(if (selected != null and std.mem.eql(u8, selected.?, radio_values[index])) S.theme.popupSelection() else ui.Color.TRANSPARENT);
            if (row.behavior.interaction.a11y) |*attrs| attrs.label = if (index == 6) "其他方式" else self.option_labels[index].getText().?.content;
        }
    }
    fn selectionChanged(self: *View, _: []const u8) void {
        self.error_label.setDisplay(.none);
        self.show();
        const selected = self.selected.peek() orelse return;
        if (std.mem.eql(u8, selected, "custom") and self.cx.focus_manager.current_focus != self.custom.input_container) self.cx.setFocus(self.custom.input_container);
    }
    fn customFocused(self: *View) void {
        if (self.input_focus) |handler| handler.invoke();
        self.customChanged(self.custom_text.peek());
    }
    fn customChanged(self: *View, _: []const u8) void {
        self.selected.set("custom");
        self.selectionChanged("");
    }
    fn postpone(self: *View) void {
        if (self.submitted) return;
        self.releaseFocus();
        self.postponed = true;
        self.show();
        self.cx.requestRedraw();
    }
    fn reopen(self: *View) void {
        self.postponed = false;
        self.show();
        self.cx.requestRedraw();
    }
    fn approve(self: *View) void {
        self.emit(.approve);
    }
    fn deny(self: *View) void {
        self.emit(.reject);
    }
    fn chooseBatch(self: *View) void {
        self.emit(.{ .route = .batch });
    }
    fn chooseCurrent(self: *View) void {
        self.emit(.{ .route = .current_terminal });
    }
    fn chooseNew(self: *View) void {
        self.emit(.{ .route = .new_terminal });
    }
    fn submit(self: *View) void {
        const value = if (self.source) |owned| owned.value else return;
        const selection = self.selected.peek() orelse {
            self.fail("请选择一项，或输入答案");
            return;
        };
        if (std.mem.eql(u8, selection, "custom")) {
            if (std.mem.trim(u8, self.custom_text.peek(), " \t\r\n").len == 0) {
                self.fail("请输入答案");
                return;
            }
            if (self.custom_text.peek().len > 4096) {
                self.fail("答案不能超过 4096 字节");
                return;
            }
            if (self.custom.state.ime_preedit_len != 0) return;
            self.emit(.{ .answer = .{ .option_id = null, .text = self.custom_text.peek() } });
        } else {
            const index = std.fmt.parseInt(usize, selection, 10) catch return;
            if (index >= value.options.len) return;
            self.emit(.{ .answer = .{ .option_id = value.options[index].id, .text = "" } });
        }
    }
    fn emit(self: *View, action: Action) void {
        if (self.submitted) return;
        const source = self.source orelse return;
        self.callbacks.act(self.callbacks.context, source.value.ticket, action) catch |err| {
            self.fail(@errorName(err));
            return;
        };
        if (action != .route) {
            self.submitted = true;
            self.disabled.set(true);
        }
        self.cx.requestRedraw();
    }
    fn fail(self: *View, message: []const u8) void {
        self.error_label.setTextContent(self.cx.allocator, message) catch {};
        self.error_label.setDisplay(.flex);
        self.cx.requestRedraw();
    }
    fn copyDetail(self: *View) void {
        const source = self.source orelse return;
        _ = ui.platform_services.clipboardSetText(self.cx.system_sdk, source.value.detail);
    }
    fn cancelPress(self: *View) void {
        if (self.cx.pressed_node) |pressed| if (pressed.isDescendantOf(self.panel) or pressed.isDescendantOf(self.actions) or pressed == self.pending) self.cx.cancelPointerInteractions(.explicit);
    }
    fn releaseFocus(self: *View) void {
        if (self.cx.focus_manager.current_focus) |focused| if (focused.isDescendantOf(self.panel) or focused.isDescendantOf(self.actions) or focused == self.pending) self.cx.clearFocus();
    }
    fn paint(self: *View) void {
        const colors = S.theme.current();
        if (self.colors) |old| {
            if (std.meta.eql(old, colors)) return;
            repaint(self.panel, old);
            repaint(self.actions, old);
            repaint(self.pending, old);
        }
        self.colors = colors;
        self.command.setBackground(colors.surface_2);
        self.impact.setTextColor(colors.fg_2);
        self.error_label.setTextColor(colors.danger_ink);
        self.pending.setBackground(colors.surface_2);
        self.custom.node.setBackground(colors.surface_2);
    }
    fn release(self: *View) void {
        if (self.source) |*owned| owned.arena.deinit();
    }
};

fn remap(value: ui.Color, old: S.theme.Colors) ui.Color {
    if (S.theme.remapUiSurface(value, old)) |surface| return surface;
    inline for (@typeInfo(S.theme.Colors).@"struct".field_names) |field| if (ui.Color.eql(value, @field(old, field))) return @field(S.theme.current(), field);
    return value;
}
fn repaint(node: *ui.Node, old: S.theme.Colors) void {
    node.setBackground(remap(node.getBackground(), old));
    if (node.getText()) |value| node.setTextColor(S.theme.remapUiInk(value.color, old));
    if (node.getIcon()) |value| _ = node.setTint(S.theme.remapUiInk(value.tint, old));
    for (node.children.items) |child| repaint(child, old);
}
