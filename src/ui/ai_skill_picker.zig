const std = @import("std");
const ui = @import("ui");
const S = @import("ai_composer_controls_styles.zig");
const Skill = @import("../config/ai_extensions.zig").Skill;

const command = "/skill";
pub const Shortcut = enum {
    skill,
    model,
    session,
    permission,
    execution,
    auto,
    swarm,
    boost,
    fn name(self: Shortcut) []const u8 {
        return switch (self) {
            .skill => "/skill",
            .model => "/model",
            .session => "/session",
            .permission => "/permission",
            .execution => "/execution",
            .auto => "/auto",
            .swarm => "/swarm",
            .boost => "/boost",
        };
    }
    fn hint(self: Shortcut) []const u8 {
        return switch (self) {
            .skill => "选择技能",
            .model => "模型与推理强度",
            .session => "关联会话或组",
            .permission => "工具执行权限",
            .execution => "命令执行方式",
            .auto => "自动编排智能体",
            .swarm => "协作智能体编排",
            .boost => "强化智能体编排",
        };
    }
    fn glyph(self: Shortcut) ui.SvgAsset {
        return switch (self) {
            .skill => ui.icons.sparkles,
            .model => ui.icons.bot,
            .session => ui.icons.link,
            .permission => ui.icons.shield,
            .execution => ui.icons.terminal,
            .auto => ui.icons.wand_sparkles,
            .swarm => ui.icons.users,
            .boost => ui.icons.zap,
        };
    }
    fn testId(self: Shortcut) []const u8 {
        return switch (self) {
            .skill => "ai.skill_picker.command",
            .model => "ai.command.model",
            .session => "ai.command.session",
            .permission => "ai.command.permission",
            .execution => "ai.command.execution",
            .auto => "ai.command.auto",
            .swarm => "ai.command.swarm",
            .boost => "ai.command.boost",
        };
    }
};
const Menu = union(enum) { commands: []const u8, skills: []const u8 };
pub const Actions = struct {
    context: *anyopaque,
    available: *const fn (*anyopaque, u64, Shortcut) bool,
    open: *const fn (*anyopaque, u64, Shortcut) void,
};
const row_height = S.completion_row_height;
const row_gap = S.completion_row_gap;
const padding = S.completion_padding;
const max_rows = 6;

fn menu(line: []const u8) ?Menu {
    if (line.len == 0) return null;
    if (std.mem.eql(u8, line, command)) return .{ .skills = "" };
    if (std.mem.startsWith(u8, line, command ++ " ")) return .{ .skills = std.mem.trim(u8, line[command.len + 1 ..], " \t\r") };
    if (line[0] == '/') for (std.enums.values(Shortcut)) |choice| {
        if (std.mem.startsWith(u8, choice.name(), line)) return .{ .commands = line };
    };
    return null;
}

pub fn isIncomplete(text: []const u8) bool {
    if (menu(text)) |level| return level == .commands or (level == .skills and level.skills.len == 0);
    return false;
}

pub const View = struct {
    cx: *ui.Cx,
    composer: *ui.Node,
    input: ui.widgets.input.TextareaResult,
    on_change: ui.Handler([]const u8),
    popup: ui.widgets.popover.PopoverResult,
    scroll: ui.widgets.ScrollAreaResult,
    row_scope: ?*ui.Scope = null,
    rows: std.ArrayList(*Row) = .empty,
    active: ?u64 = null,
    editor_revision: u64 = 0,
    dismissed: ?u64 = null,
    selected: usize = 0,
    actions: ?Actions = null,
    conversation: ?u64 = null,
    reveal_selection: bool = false,

    pub fn mount(cx: *ui.Cx, scope: *ui.Scope, composer: *ui.Node, input: ui.widgets.input.TextareaResult, on_change: ui.Handler([]const u8)) !*View {
        const popup = try ui.widgets.Popover(S.completionPopover(composer)).mount(scope, cx);
        popup.wrapper.setStyleInline(cx.allocator, S.wrapper());
        popup.chrome.meta.ownership.meta.test_id = "ai.skill_picker";
        popup.chrome.setStyleInline(cx.allocator, S.completionPanel(cx.viewport));
        const scroll = try ui.widgets.ScrollArea(.{ .direction = .vertical, .background = ui.Color.TRANSPARENT, .rubber_band_y = false }).mount(popup.scope, cx);
        scroll.container.setStyleInline(cx.allocator, S.models());
        scroll.content.setStyleInline(cx.allocator, .{ .width = .fill(), .direction = .column, .gap = row_gap });
        try popup.content.appendChild(cx.allocator, scroll.container);
        const self = try scope.createState(View, .{ .cx = cx, .composer = composer, .input = input, .on_change = on_change, .popup = popup, .scroll = scroll });
        try cx.addAfterLayoutHook(self, afterLayout);
        try scope.onCleanup(View, self, cleanup);
        return self;
    }

    fn cleanup(self: *View) void {
        self.cx.removeAfterLayoutHook(self);
        self.rows.deinit(self.cx.allocator);
    }

    fn afterLayout(raw: *anyopaque, _: u8, _: bool) ui.AfterLayoutResult {
        const self: *View = @ptrCast(@alignCast(raw));
        if (!self.popup.open.?.peek()) return .done;
        const count: f32 = @floatFromInt(@min(@max(self.rows.items.len, 1), max_rows));
        const height = padding * 2 + row_height * count + row_gap * (count - 1);
        return if (S.layoutCompletion(self.cx, self.popup.chrome, self.composer, height)) .needs_layout else .done;
    }

    pub fn refresh(self: *View, conversation: ?u64, revision: u64, skills: []const Skill, allowed_ids: ?[]const []const u8) !void {
        self.conversation = conversation;
        const focused = self.cx.focus_manager.getFocused();
        const has_focus = if (focused) |node| node == self.input.input or node.isDescendantOf(self.popup.chrome) else false;
        const text = self.input.state.getText();
        const line = std.mem.sliceTo(text, '\n');
        const level = if (conversation != null and has_focus and !self.input.state.disabled and !self.input.state.imeIsComposing() and self.input.state.cursor.offset <= line.len) menu(line) else null;
        if (level == null) {
            self.popup.open.?.set(false);
            self.active = null;
            self.dismissed = null;
            return;
        }
        var hash = std.hash.Wyhash.init(0);
        hash.update(line);
        std.hash.autoHash(&hash, .{ conversation, revision, S.theme.current() });
        if (level.? == .commands) for (std.enums.values(Shortcut)) |choice| std.hash.autoHash(&hash, self.available(choice));
        if (allowed_ids) |ids| for (ids) |id| hash.update(id);
        const key = hash.final();
        if (self.active == key) {
            self.editor_revision = self.input.state.doc.revision;
            // Outside-click dismissal is owned by the native popover.
            if (!self.popup.open.?.peek()) self.dismissed = key;
            if (self.reveal_selection and self.scroll.state.viewport_height > 0 and self.rows.items.len > 0) {
                ui.widgets.scrollRectIntoView(self.scroll.state, self.scroll.content, @as(f32, @floatFromInt(self.selected)) * (row_height + row_gap), row_height, .nearest);
                self.reveal_selection = false;
            }
            return;
        }
        if (self.dismissed == key) return;
        self.dismissed = null;
        self.active = null;
        self.clearRows();
        const row_scope = try self.popup.scope.childScope();
        self.row_scope = row_scope;
        switch (level.?) {
            .commands => |prefix| {
                for (std.enums.values(Shortcut)) |choice| {
                    if (self.available(choice) and std.mem.startsWith(u8, choice.name(), prefix)) try self.addRow(row_scope, choice.name(), choice);
                }
                if (self.rows.items.len == 0) try self.emptyHint(if (std.mem.eql(u8, prefix, "/session")) "请在独立 AI 会话中关联终端" else "当前会话暂不可使用此命令");
            },
            .skills => |query| {
                for (skills) |skill| {
                    if (!skill.enabled) continue;
                    if (allowed_ids) |ids| {
                        for (ids) |id| {
                            if (std.mem.eql(u8, id, skill.id)) break;
                        } else continue;
                    }
                    if (query.len == 0 or std.ascii.findIgnoreCase(skill.name, query) != null) try self.addRow(row_scope, skill.name, null);
                }
                if (self.rows.items.len == 0) try self.emptyHint(if (query.len == 0) "没有可用技能" else "没有匹配的技能");
            },
        }
        self.selected = 0;
        self.reveal_selection = true;
        S.paintCompletionPanel(self.cx, self.popup.chrome);
        self.active = key;
        self.editor_revision = self.input.state.doc.revision;
        self.popup.open.?.set(true);
        self.cx.requestRedraw();
    }

    fn emptyHint(self: *View, hint: []const u8) !void {
        const label = try ui.text(self.cx, hint, S.completionHint());
        label.setStyleInline(self.cx.allocator, .{ .height = .{ .px = row_height }, .width = .fill(), .padding = .{ .left = 8, .top = 6 } });
        try self.scroll.content.appendChild(self.cx.allocator, label);
    }

    fn clearRows(self: *View) void {
        // Rebuild only at the controller's layout safe point.
        while (self.scroll.content.children.items.len != 0) {
            const child = self.scroll.content.children.items[0];
            self.cx.detachChild(self.scroll.content, child);
            self.cx.destroyDetached(child);
        }
        if (self.row_scope) |scope| scope.dispose();
        self.row_scope = null;
        self.rows.clearRetainingCapacity();
    }

    const Row = struct {
        view: *View,
        name: *ui.Signal([]const u8),
        style: *ui.Signal(ui.BoxStyle),
        button: *ui.Node = undefined,
        shortcut: ?Shortcut,
        fn click(self: *Row) void {
            self.view.choose(self) catch |err| std.log.warn("AI skill selection: {s}", .{@errorName(err)});
        }
    };

    fn addRow(self: *View, scope: *ui.Scope, name: []const u8, shortcut: ?Shortcut) !void {
        try self.rows.ensureUnusedCapacity(self.cx.allocator, 1);
        const selected = self.rows.items.len == 0;
        const row = try scope.createState(Row, .{
            .view = self,
            .name = try scope.createText(name, .{}),
            .style = try scope.createSignal(ui.BoxStyle, S.completionRow(selected)),
            .shortcut = shortcut,
        });
        const button = try ui.widgets.Button(.{
            .variant = .ghost,
            .a11y_label = row.name,
            .base_style = row.style,
            .hover_style = S.hoverOptional(),
            .on_click = self.cx.on(Row, row, Row.click),
        }).mount(scope, self.cx);
        for (button.children.items) |child| child.setDisplay(.none);
        button.setStyleInline(self.cx.allocator, .{ .justify = .start });
        errdefer self.cx.destroyDetached(button);
        button.meta.ownership.meta.test_id = if (shortcut) |item| item.testId() else "ai.skill_picker.skill";
        if (button.behavior.interaction.a11y) |*attrs| attrs.selected = selected;
        try button.appendChild(self.cx.allocator, try ui.iconTint(self.cx, if (shortcut) |item| item.glyph() else ui.icons.sparkles, S.theme.current().fg_2, S.icon(14)));
        const label = try ui.text(self.cx, "", S.completionLabel());
        try label.setTextContent(self.cx.allocator, name);
        label.setStyleInline(self.cx.allocator, S.flexibleLabel(17));
        label.setHitTestVisible(false);
        try button.appendChild(self.cx.allocator, label);
        if (shortcut) |item| {
            const hint = try ui.text(self.cx, item.hint(), S.completionHint());
            hint.setHitTestVisible(false);
            try button.appendChild(self.cx.allocator, hint);
            try button.appendChild(self.cx.allocator, try ui.iconTint(self.cx, ui.icons.chevron_right, S.theme.current().fg_2, S.icon(12)));
        }
        try self.scroll.content.appendChild(self.cx.allocator, button);
        row.button = button;
        self.rows.appendAssumeCapacity(row);
    }

    fn activeLine(self: *View) ?[]const u8 {
        const editor = self.input.state;
        if (!self.popup.open.?.peek() or editor.disabled or editor.imeIsComposing() or self.editor_revision != editor.doc.revision) return null;
        const line = std.mem.sliceTo(editor.getText(), '\n');
        return if (editor.cursor.offset <= line.len) line else null;
    }

    fn available(self: *View, item: Shortcut) bool {
        if (item == .skill) return true;
        const actions = self.actions orelse return false;
        return actions.available(actions.context, self.conversation orelse return false, item);
    }

    fn choose(self: *View, row: *const Row) !void {
        const editor = self.input.state;
        const line = self.activeLine() orelse return;
        const level = menu(line) orelse return;
        const chosen = row.shortcut;
        if ((level == .commands) != (chosen != null)) return;
        if (chosen) |item| {
            if (!self.available(item) or !std.mem.startsWith(u8, item.name(), line)) return;
            if (item == .skill) {
                try editor.replaceRangeChecked(0, line.len, command);
            } else {
                // Local UI shortcuts are never sent as prompts. Keep the rest
                // of a multiline draft and only open the actual captured UI.
                try editor.replaceRangeChecked(0, @min(editor.getText().len, line.len + 1), "");
                self.popup.open.?.set(false);
            }
        } else {
            const replacement = try std.fmt.allocPrint(self.cx.allocator, command ++ " {s}\n", .{row.name.peek()});
            defer self.cx.allocator.free(replacement);
            try editor.replaceRangeChecked(0, @min(editor.getText().len, line.len + 1), replacement);
            self.popup.open.?.set(false);
        }
        const conversation = self.conversation;
        const edited = editor.getText();
        self.input.value.?.set(edited);
        self.on_change.call(edited);
        self.cx.setFocus(self.input.input);
        if (chosen) |item| if (item != .skill) if (self.actions) |actions| if (conversation) |owner| {
            if (actions.available(actions.context, owner, item)) actions.open(actions.context, owner, item);
        };
        self.cx.requestRedraw();
    }

    pub fn handleKey(self: *View, key: ui.events.KeyEvent) bool {
        if (self.activeLine() == null or key.modifiers.super or key.modifiers.ctrl or key.modifiers.alt or key.modifiers.shift) return false;
        switch (key.key) {
            .escape => self.popup.open.?.set(false),
            .@"return", .tab => {
                if (self.rows.items.len != 0) self.rows.items[self.selected].click();
            },
            .up, .down => {
                if (self.rows.items.len == 0) return true;
                const previous = self.selected;
                self.selected = if (key.key == .up) previous -| 1 else @min(previous + 1, self.rows.items.len - 1);
                for ([_]usize{ previous, self.selected }) |index| {
                    const row = self.rows.items[index];
                    row.style.set(S.completionRow(index == self.selected));
                    if (row.button.behavior.interaction.a11y) |*attrs| attrs.selected = index == self.selected;
                }
                self.reveal_selection = true;
            },
            else => return false,
        }
        self.cx.requestRedraw();
        return true;
    }
};
