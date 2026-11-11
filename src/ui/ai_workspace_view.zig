//! The assistant header projects the currently displayed conversation's
//! workspace. All directory changes go back through the host's captured ticket.
const std = @import("std");
const ui = @import("ui");
const identity = @import("../host/identity.zig");
const Header = @import("ai_assistant_header.zig");
const S = @import("ai_assistant_styles.zig");
const menu = @import("ai_composer_controls_styles.zig");
const theme = @import("app_theme.zig");

pub const Ticket = struct {
    conversation: identity.ConversationId,
    revision: u64,
    scope_revision: u64 = 0,

    pub fn eql(self: Ticket, other: Ticket) bool {
        return self.conversation.eql(other.conversation) and self.revision == other.revision and self.scope_revision == other.scope_revision;
    }

    pub fn same(first: ?Ticket, second: ?Ticket) bool {
        return if (first) |value| if (second) |other| value.eql(other) else false else second == null;
    }
};

pub const Action = enum { choose, remove };
pub const Callbacks = struct {
    context: *anyopaque,
    action: *const fn (*anyopaque, Ticket, Action) anyerror!void,
};
pub const Snapshot = struct {
    ticket: Ticket,
    directory: ?[]const u8 = null,
    unavailable_reason: ?[]const u8 = null,
    pending: bool = false,
    editable: bool = true,
};

pub const View = struct {
    cx: *ui.Cx,
    callbacks: Callbacks,
    header: Header.View,
    open: *ui.Signal(bool),
    hint_text: *ui.Signal([]const u8),
    hint_open: *ui.Signal(bool) = undefined,
    disabled: *ui.Signal(bool),
    trigger: *ui.Node = undefined,
    name: *ui.Node = undefined,
    folder: *ui.Node = undefined,
    chevron: *ui.Node = undefined,
    slot: *ui.Node = undefined,
    hint_trigger: *ui.Node = undefined,
    chrome: *ui.Node = undefined,
    path: *ui.Node = undefined,
    status: *ui.Node = undefined,
    choose: *ui.Node = undefined,
    remove: *ui.Node = undefined,
    ticket: ?Ticket = null,
    captured: ?Ticket = null,
    unavailable: bool = false,
    pending: bool = false,
    focus_pending: bool = false,
    slot_width: f32 = S.workspace_min_width,

    pub fn mount(cx: *ui.Cx, scope: *ui.Scope, header: Header.View, callbacks: Callbacks) !*View {
        const self = try scope.createState(View, .{
            .cx = cx,
            .callbacks = callbacks,
            .header = header,
            .open = try scope.createSignal(bool, false),
            .hint_text = try scope.createText("", .{}),
            .disabled = try scope.createSignal(bool, true),
        });
        const button_style = try theme.paintSignal(S.ButtonStyle, cx, scope, S.workspaceButton, .{});
        const button_hover = try theme.paintSignal(?S.ButtonStyle, cx, scope, S.workspaceHover, .{});
        self.trigger = try ui.widgets.Button(.{
            .variant = .ghost,
            .a11y_label = "本地工作区",
            .base_style = button_style,
            .hover_style = button_hover,
            .on_click = cx.on(View, self, toggle),
        }).mount(scope, cx);
        self.trigger.meta.ownership.meta.test_id = "ai.workspace";
        for (self.trigger.children.items) |child| child.setDisplay(.none);
        self.trigger.setStyleInline(cx.allocator, .{ .justify = .start, .overflow = .hidden });
        self.folder = try ui.iconTint(cx, ui.icons.folder, theme.current().fg_2, menu.icon(13));
        try self.trigger.appendChild(cx.allocator, self.folder);
        self.name = try ui.textStyled(cx, S.workspaceName, "");
        self.name.meta.ownership.meta.test_id = "ai.workspace.name";
        self.name.setStyleInline(cx.allocator, .{ .width = .fill(), .min_width = 0, .flex_shrink = 1 });
        try self.trigger.appendChild(cx.allocator, self.name);
        self.chevron = try ui.iconTint(cx, ui.icons.chevron_down, theme.current().fg_3, menu.icon(10));
        try self.trigger.appendChild(cx.allocator, self.chevron);

        const hint = try @import("control_hint.zig").mount(cx, scope, self.trigger, self.hint_text, .{
            .id = "ai.workspace.hint",
            .layout = S.workspaceSlot(S.workspace_min_width),
            .width = 300,
            .wrap = .char,
        });
        self.slot = hint.wrapper;
        self.hint_trigger = hint.trigger;
        self.hint_trigger.setStyleInline(cx.allocator, .{ .width = .fill(), .height = .{ .px = 20 }, .min_width = 0, .overflow = .hidden });
        self.hint_open = hint.open.?;
        self.slot.setDisplay(.none);
        try header.bar.insertChildBefore(cx.allocator, self.slot, header.spacer);

        const popup = try ui.widgets.Popover(.{
            .open = self.open,
            .trigger = .manual,
            .anchor = .{ .node = self.trigger },
            .position = .bottom_start,
            .offset = .{ .static = 6 },
            .width = 300,
            .max_height = 300,
            .size_policy = .fit_content,
            .close_on_escape = true,
            .close_on_outside_click = true,
            .constrain_width_to_viewport = true,
            .flip = true,
            .shift_main_axis = true,
            .viewport_padding = 8,
            .on_open_change = cx.on(View, self, openChanged),
        }).mount(scope, cx);
        popup.wrapper.setStyleInline(cx.allocator, menu.wrapper());
        try header.bar.appendChild(cx.allocator, popup.wrapper);
        self.chrome = popup.chrome;
        self.chrome.meta.ownership.meta.test_id = "ai.workspace.menu";
        self.chrome.setStyleInline(cx.allocator, S.workspacePopup(cx.tokens));
        self.chrome.meta.per_frame.hooks.on_theme = paintChrome;
        const body = try ui.box(cx, .{ .width = .fill(), .min_width = 0, .direction = .column, .padding = ui.Padding.all(10), .gap = 6 }, .{});
        try popup.content.appendChild(cx.allocator, body);
        self.path = try detail(cx, body, "ai.workspace.path");
        self.status = try detail(cx, body, "ai.workspace.status");
        self.choose = try self.mountAction(popup.scope, body, "更换目录…", "ai.workspace.change", change);
        self.remove = try self.mountAction(popup.scope, body, "移除工作区", "ai.workspace.remove", clear);
        try scope.createEffect(.{ .view = self, .colors = try cx.themeSignal(scope) }, struct {
            fn repaint(state: anytype) void {
                _ = state.colors.get();
                state.view.paintInk();
                paintChrome(state.view.chrome, state.view.cx.tokens, state.view.cx.allocator);
            }
        }.repaint);
        try cx.addAfterLayoutHook(self, afterLayout);
        errdefer cx.removeAfterLayoutHook(self);
        try scope.onCleanup(View, self, release);
        return self;
    }

    fn release(self: *View) void {
        self.cx.removeAfterLayoutHook(self);
        if (self.cx.focus_manager.current_focus) |node| {
            if (node.isDescendantOf(self.chrome) or node == self.trigger) self.cx.clearFocus();
        }
    }

    fn afterLayout(raw: *anyopaque, _: u8, _: bool) ui.AfterLayoutResult {
        const self: *View = @ptrCast(@alignCast(raw));
        if (!self.slot.isDisplayedInTree()) return .done;
        if (self.focus_pending and self.open.peek() and self.choose.isDisplayedInTree() and self.choose.globalRect().h > 0) {
            self.focus_pending = false;
            self.cx.setFocus(self.choose);
        }
        // Reserve measured widths for the existing header children, including
        // all controls and every gap. Only the new workspace pill shrinks.
        var reserved = 2 * S.header_padding_x;
        for (self.header.bar.children.items) |child| {
            if (child.style.position == .absolute or child.style.display == .none or child == self.slot) continue;
            reserved += S.header_gap;
            if (child != self.header.spacer) reserved += child.globalRect().w;
        }
        const text = self.name.getText().?.content;
        const preferred = S.workspace_chrome_width + self.cx.text.measureTextWidth(text, 11, 400, false);
        const width = std.math.clamp(@min(preferred, self.header.bar.globalRect().w - reserved), S.workspace_min_width, S.workspace_max_width);
        if (@abs(width - self.slot_width) <= 0.25) return .done;
        self.slot_width = width;
        self.slot.setStyleInline(self.cx.allocator, S.workspaceSlot(width));
        return .needs_layout;
    }

    fn detail(cx: *ui.Cx, parent: *ui.Node, id: []const u8) !*ui.Node {
        const node = try ui.textStyled(cx, S.workspaceDetails, "");
        node.meta.ownership.meta.test_id = id;
        node.setStyleInline(cx.allocator, .{ .width = .fill(), .min_width = 0, .flex_shrink = 0, .padding = .{ .left = 4, .right = 4 } });
        try parent.appendChild(cx.allocator, node);
        return node;
    }

    fn mountAction(self: *View, scope: *ui.Scope, parent: *ui.Node, label: []const u8, id: []const u8, comptime action: fn (*View) void) !*ui.Node {
        const button = try ui.widgets.Button(.{
            .variant = .ghost,
            .a11y_label = label,
            .disabled = self.disabled,
            .base_style = menu.attachmentRow(),
            .hover_style = try theme.paintSignal(?ui.BoxStyle, self.cx, scope, menu.hoverOptional, .{}),
            .on_click = self.cx.on(View, self, action),
        }).mount(scope, self.cx);
        button.meta.ownership.meta.test_id = id;
        for (button.children.items) |child| child.setDisplay(.none);
        button.setStyleInline(self.cx.allocator, .{ .justify = .start });
        const text = try ui.text(self.cx, label, menu.text(11.5, 400, 18, false));
        theme.bindInk(text, "fg_1");
        try button.appendChild(self.cx.allocator, text);
        try parent.appendChild(self.cx.allocator, button);
        return button;
    }

    pub fn update(self: *View, next: ?Snapshot) !void {
        const directory = if (next) |value| value.directory else null;
        const pending = if (next) |value| value.pending else false;
        const reason = if (next) |value| value.unavailable_reason else null;
        const ticket = if (next) |value| value.ticket else null;
        const visible = directory != null or pending;
        if (!visible or !Ticket.same(ticket, self.ticket)) self.dismiss();
        self.ticket = ticket;
        self.pending = pending;
        self.unavailable = reason != null;
        self.slot.setDisplay(if (visible) .flex else .none);
        if (!visible) return;

        const editable = next.?.editable;
        self.disabled.set(!editable);
        self.choose.setDisplay(if (editable) .flex else .none);
        self.remove.setDisplay(if (editable and directory != null) .flex else .none);
        self.path.setDisplay(if (directory != null) .flex else .none);
        const name = if (directory) |path| basename(path) else "已移除";
        const status = if (reason) |cause| unavailableMessage(cause) else if (pending)
            if (directory != null) "等待当前任务更新本地工作区" else "本地工作区已移除，等待当前任务更新"
        else
            "";
        const hint_changed = !std.mem.eql(u8, self.path.getText().?.content, directory orelse "") or
            !std.mem.eql(u8, self.status.getText().?.content, status);
        try setText(self.cx, self.name, name);
        try setText(self.cx, self.path, directory orelse "");
        try setText(self.cx, self.status, status);
        self.status.setDisplay(if (status.len != 0) .flex else .none);
        if (self.trigger.behavior.interaction.a11y) |*a11y| a11y.label = self.name.getText().?.content;
        if (hint_changed) {
            if (directory != null and status.len != 0) {
                const hint = try std.fmt.allocPrint(self.cx.allocator, "{s}\n{s}", .{ directory.?, status });
                defer self.cx.allocator.free(hint);
                self.hint_text.set(hint);
            } else self.hint_text.set(directory orelse status);
        }
        self.paintInk();
    }

    pub fn dismiss(self: *View) void {
        self.open.set(false);
        self.hint_open.set(false);
        self.focus_pending = false;
        self.captured = null;
    }

    fn paintChrome(node: *ui.Node, tokens: *const ui.ThemeTokens, a: std.mem.Allocator) void {
        node.setStyleInline(a, S.workspacePopup(tokens));
    }
    fn paintInk(self: *View) void {
        const colors = theme.current();
        _ = self.folder.setTint(if (self.unavailable) colors.warn else if (self.pending) colors.accent else colors.fg_2);
        _ = self.chevron.setTint(colors.fg_3);
        self.name.setTextColor(colors.fg_2);
        self.path.setTextColor(colors.fg_2);
        self.status.setTextColor(if (self.unavailable) colors.warn else colors.fg_2);
    }
    fn openChanged(self: *View, open: bool) void {
        if (open) return;
        self.captured = null;
        self.focus_pending = false;
        if (self.cx.focus_manager.current_focus) |node| {
            if (node.isDescendantOf(self.chrome) and self.trigger.isDisplayedInTree()) self.cx.setFocus(self.trigger);
        }
    }
    fn toggle(self: *View) void {
        if (self.open.peek()) return self.dismiss();
        self.captured = self.ticket orelse return;
        self.hint_open.set(false);
        self.focus_pending = !self.disabled.peek();
        self.open.set(true);
        self.cx.requestRedraw();
    }
    fn change(self: *View) void {
        self.emit(.choose);
    }
    fn clear(self: *View) void {
        self.emit(.remove);
    }
    fn emit(self: *View, action: Action) void {
        const ticket = self.captured orelse return;
        if (!self.open.peek() or self.disabled.peek() or !Ticket.same(ticket, self.ticket)) return;
        if (action == .remove and !self.remove.isDisplayedInTree()) return;
        self.dismiss();
        self.callbacks.action(self.callbacks.context, ticket, action) catch |err| {
            std.log.warn("AI local workspace update failed: {s}", .{@errorName(err)});
        };
        self.cx.requestRedraw();
    }
};

fn setText(cx: *ui.Cx, node: *ui.Node, text: []const u8) !void {
    if (!std.mem.eql(u8, node.getText().?.content, text)) try node.setTextContent(cx.allocator, text);
}
fn unavailableMessage(reason: []const u8) []const u8 {
    const messages = std.StaticStringMap([]const u8).initComptime(.{
        .{ "FileNotFound", "目录不存在或已移动" },
        .{ "NotDir", "原路径已不是目录" },
        .{ "AccessDenied", "没有访问此目录的权限" },
        .{ "PermissionDenied", "没有访问此目录的权限" },
        .{ "DirectoryIdentityChanged", "原目录已被替换，请重新选择" },
    });
    return messages.get(reason) orelse "暂时无法访问此目录";
}

fn basename(path: []const u8) []const u8 {
    const name = std.fs.path.basename(path);
    return if (name.len != 0) name else path;
}
