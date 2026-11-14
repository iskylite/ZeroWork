const std = @import("std");
const ui = @import("ui");
const S = @import("ai_composer_controls_styles.zig");
const Skill = @import("../config/ai_extensions.zig").Skill;

const command = "/skill";
const Menu = union(enum) { commands, skills: []const u8 };
const row_height: f32 = 32;
const row_gap: f32 = 4;
const padding: f32 = 6;
const panel_width: f32 = 320;
const max_rows = 6;
const max_height = padding * 2 + row_height * max_rows + row_gap * (max_rows - 1);

fn menu(line: []const u8) ?Menu {
    if (line.len == 0) return null;
    if (std.mem.eql(u8, line, command)) return .{ .skills = "" };
    if (std.mem.startsWith(u8, line, command ++ " ")) return .{ .skills = std.mem.trim(u8, line[command.len + 1 ..], " \t\r") };
    if (std.mem.startsWith(u8, command, line)) return .commands;
    return null;
}

pub fn isIncomplete(text: []const u8) bool {
    return std.mem.eql(u8, text, "/") or std.mem.eql(u8, text, command);
}

pub const View = struct {
    cx: *ui.Cx,
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
    reveal_selection: bool = false,

    pub fn mount(cx: *ui.Cx, scope: *ui.Scope, input: ui.widgets.input.TextareaResult, on_change: ui.Handler([]const u8)) !*View {
        const popup = try ui.widgets.Popover(.{
            .trigger = .manual,
            .anchor = .{ .node = input.wrapper },
            .position = .top_start,
            .offset = .{ .static = 6 },
            .width = panel_width,
            .max_height = max_height,
            .constrain_width_to_viewport = true,
            .shift_main_axis = true,
            .close_on_escape = false,
        }).mount(scope, cx);
        popup.wrapper.setStyleInline(cx.allocator, S.wrapper());
        popup.chrome.meta.ownership.meta.test_id = "ai.skill_picker";
        const scroll = try ui.widgets.ScrollArea(.{ .direction = .vertical, .background = ui.Color.TRANSPARENT, .rubber_band_y = false }).mount(popup.scope, cx);
        scroll.container.setStyleInline(cx.allocator, S.models());
        scroll.content.setStyleInline(cx.allocator, .{ .width = .fill(), .direction = .column, .gap = row_gap });
        try popup.content.appendChild(cx.allocator, scroll.container);
        const self = try scope.createState(View, .{ .cx = cx, .input = input, .on_change = on_change, .popup = popup, .scroll = scroll });
        try scope.onCleanup(View, self, cleanup);
        return self;
    }

    fn cleanup(self: *View) void {
        self.rows.deinit(self.cx.allocator);
    }

    pub fn refresh(self: *View, conversation: ?u64, revision: u64, skills: []const Skill, allowed_ids: ?[]const []const u8) !void {
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
            .commands => try self.addRow(row_scope, command, true),
            .skills => |query| {
                for (skills) |skill| {
                    if (!skill.enabled) continue;
                    if (allowed_ids) |ids| {
                        for (ids) |id| {
                            if (std.mem.eql(u8, id, skill.id)) break;
                        } else continue;
                    }
                    if (query.len == 0 or std.ascii.findIgnoreCase(skill.name, query) != null) try self.addRow(row_scope, skill.name, false);
                }
                if (self.rows.items.len == 0) {
                    const label = try ui.text(self.cx, if (query.len == 0) "没有可用技能" else "没有匹配的技能", S.text(13, 400, 20, true));
                    label.setStyleInline(self.cx.allocator, .{ .height = .{ .px = row_height }, .width = .fill(), .padding = .{ .left = 8, .top = 6 } });
                    try self.scroll.content.appendChild(self.cx.allocator, label);
                }
            },
        }
        self.selected = 0;
        self.reveal_selection = true;
        const count: f32 = @floatFromInt(@min(@max(self.rows.items.len, 1), max_rows));
        const height = padding * 2 + row_height * count + row_gap * (count - 1);
        var style = S.panel(.attachment, self.cx.viewport);
        style.width = .{ .px = @min(panel_width, @max(0, self.cx.viewport.width - 16)) };
        style.height = .{ .px = height };
        style.min_height = 0;
        style.padding = ui.Padding.all(padding);
        self.popup.chrome.setStyleInline(self.cx.allocator, style);
        self.active = key;
        self.editor_revision = self.input.state.doc.revision;
        self.popup.open.?.set(true);
        self.cx.requestRedraw();
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
        is_command: bool,
        fn click(self: *Row) void {
            self.view.choose(self) catch |err| std.log.warn("AI skill selection: {s}", .{@errorName(err)});
        }
    };

    fn rowStyle(selected: bool) ui.BoxStyle {
        var style = S.option(row_height, selected);
        style.padding = .{ .left = 8, .right = 8 };
        style.gap = 8;
        if (!selected) style.background = ui.Color.TRANSPARENT;
        return style;
    }

    fn addRow(self: *View, scope: *ui.Scope, name: []const u8, is_command: bool) !void {
        try self.rows.ensureUnusedCapacity(self.cx.allocator, 1);
        const selected = self.rows.items.len == 0;
        const row = try scope.createState(Row, .{
            .view = self,
            .name = try scope.createText(name, .{}),
            .style = try scope.createSignal(ui.BoxStyle, rowStyle(selected)),
            .is_command = is_command,
        });
        const button = try ui.widgets.Button(.{
            .variant = .ghost,
            .a11y_label = row.name,
            .base_style = row.style,
            .hover_style = S.hoverOptional(),
            .on_click = self.cx.on(Row, row, Row.click),
        }).mount(scope, self.cx);
        for (button.children.items) |child| child.setDisplay(.none);
        errdefer self.cx.destroyDetached(button);
        button.meta.ownership.meta.test_id = if (is_command) "ai.skill_picker.command" else "ai.skill_picker.skill";
        if (button.behavior.interaction.a11y) |*attrs| attrs.selected = selected;
        try button.appendChild(self.cx.allocator, try ui.iconTint(self.cx, ui.icons.sparkles, S.theme.current().accent, S.icon(16)));
        const label = try ui.text(self.cx, "", S.text(13, 400, 20, false));
        try label.setTextContent(self.cx.allocator, name);
        label.setStyleInline(self.cx.allocator, S.flexibleLabel(20));
        try button.appendChild(self.cx.allocator, label);
        if (is_command) try button.appendChild(self.cx.allocator, try ui.iconTint(self.cx, ui.icons.get("chevron-right").?, S.theme.current().fg_2, S.icon(16)));
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

    fn choose(self: *View, row: *const Row) !void {
        const editor = self.input.state;
        const line = self.activeLine() orelse return;
        const level = menu(line) orelse return;
        if ((level == .commands) != row.is_command) return;
        if (row.is_command) {
            try editor.replaceRangeChecked(0, line.len, command);
        } else {
            const replacement = try std.fmt.allocPrint(self.cx.allocator, command ++ " {s}\n", .{row.name.peek()});
            defer self.cx.allocator.free(replacement);
            try editor.replaceRangeChecked(0, @min(editor.getText().len, line.len + 1), replacement);
            self.popup.open.?.set(false);
        }
        const edited = editor.getText();
        self.input.value.?.set(edited);
        self.on_change.call(edited);
        self.cx.setFocus(self.input.input);
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
                    row.style.set(rowStyle(index == self.selected));
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
