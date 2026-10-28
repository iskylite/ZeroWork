//! Global theme selection over the SettingsHost's one live registry. A click
//! requests a transaction; only update() acknowledges the committed current ID.
const std = @import("std");
const ui = @import("ui");
const themes = @import("../config/theme_registry.zig");
const S = @import("status_theme_styles.zig");

pub const ThemeId = []const u8;
pub const Hooks = struct {
    context: *anyopaque,
    select: *const fn (*anyopaque, ThemeId) anyerror!void,
    manage: *const fn (*anyopaque) void,
    busy: *const fn (*anyopaque) bool,
};
const Feedback = enum { applied, pending, failure };

pub const View = struct {
    cx: *ui.Cx,
    scope: *ui.Scope,
    registry: *themes.Registry,
    hooks: Hooks,
    root: *ui.Node = undefined,
    chrome: *ui.Node = undefined,
    content: *ui.Node = undefined,
    header: *ui.Node = undefined,
    body: *ui.Node = undefined,
    title: *ui.Node = undefined,
    header_icon: *ui.Node = undefined,
    fade: *ui.Node = undefined,
    close_icon: *ui.Node = undefined,
    scope_row: *ui.Node = undefined,
    scope_label: *ui.Node = undefined,
    scope_icon: *ui.Node = undefined,
    scope_tag: *ui.Node = undefined,
    manage_button: *ui.Node = undefined,
    manage_icon: *ui.Node = undefined,
    manage_label: *ui.Node = undefined,
    feedback_row: *ui.Node = undefined,
    feedback_label: *ui.Node = undefined,
    feedback_icon: *ui.Node = undefined,
    feedback_failure: *ui.Node = undefined,
    feedback_spinner: *ui.Node = undefined,
    scroll_hint: *ui.Node = undefined,
    scroll: ui.widgets.ScrollAreaResult = undefined,
    open: *ui.Signal(bool),
    disabled: *ui.Signal(bool),
    row_scope: ?*ui.Scope = null,
    rows: std.ArrayList(*Row) = .empty,
    row_generation: u64 = 0,
    rendered_registry_revision: u64 = 0,
    registry_revision: u64 = 0,
    config_revision: u64 = 0,
    current: []const u8 = "",
    requested: ?[]u8 = null,
    feedback: Feedback = .applied,
    anchor_id: ?u32 = null,
    anchor_rect: ui.widgets.popover.AnchorRect = .{ .x = 0, .y = 0, .w = 0, .h = 0 },
    status_top: f32 = 0,
    anchor_inset: f32 = 0,
    list_height: f32 = -1,
    dirty: bool = true,
    focus_current: bool = false,
    paint_revision: u32 = 0,

    pub fn mount(cx: *ui.Cx, scope: *ui.Scope, registry: *themes.Registry, hooks: Hooks) !*View {
        const self = try cx.allocator.create(View);
        var adopted = false;
        errdefer if (!adopted) cx.allocator.destroy(self);
        const open = try scope.createSignal(bool, false);
        const disabled = try scope.createSignal(bool, false);
        self.* = .{ .cx = cx, .scope = scope, .registry = registry, .hooks = hooks, .open = open, .disabled = disabled };
        try scope.onCleanup(View, self, cleanup);
        adopted = true;
        const popup = try ui.widgets.Popover(.{ .open = open, .trigger = .manual, .close_on_outside_click = false, .anchor = .{ .virtual = .{ .ctx = self, .getRect = anchor } }, .position = .top, .width = S.width, .max_width = S.width, .offset = .{ .static = 6 }, .viewport_padding = 8, .constrain_width_to_viewport = true, .flip = false, .shift_main_axis = false, .size_policy = .fit_content, .on_open_change = cx.on(View, self, openChanged) }).mount(scope, cx);
        self.scope = popup.scope;
        self.root = popup.wrapper;
        self.chrome = popup.chrome;
        self.content = popup.content;
        self.root.setStyleInline(cx.allocator, .{ .position = .absolute, .width = .{ .px = 0 }, .height = .{ .px = 0 } });
        self.chrome.setStyleInline(cx.allocator, S.panel());
        self.chrome.meta.ownership.meta.test_id = "status.theme";
        self.content.setStyleInline(cx.allocator, S.content());
        self.fade = try ui.box(cx, S.fade(), .{});
        self.fade.setDisplay(.none);
        try self.chrome.appendChild(cx.allocator, self.fade);
        self.header = try ui.box(cx, S.header(), .{});
        self.header_icon = try ui.iconTint(cx, ui.icons.palette, S.theme.current().accent, S.icon(18));
        try self.header.appendChild(cx.allocator, self.header_icon);
        self.title = try ui.text(cx, "全局主题", S.title());
        self.title.setStyleInline(cx.allocator, .{ .width = .{ .px = 72 }, .height = .{ .px = 20 }, .flex_shrink = 0 });
        try self.header.appendChild(cx.allocator, self.title);
        try self.header.appendChild(cx.allocator, try ui.spacer(cx));
        const close = try ui.widgets.Button(.{ .variant = .ghost, .a11y_label = "关闭全局主题", .base_style = S.close(), .hover_style = S.hover(), .on_click = cx.on(View, self, hide) }).mount(popup.scope, cx);
        close.setStyleInline(cx.allocator, S.close());
        self.close_icon = try ui.iconTint(cx, ui.icons.x, S.theme.current().fg_2, S.icon(14));
        try close.appendChild(cx.allocator, self.close_icon);
        close.meta.ownership.meta.test_id = "status.theme.close";
        try self.header.appendChild(cx.allocator, close);
        try self.content.appendChild(cx.allocator, self.header);
        self.body = try ui.box(cx, S.body(), .{});
        try self.content.appendChild(cx.allocator, self.body);
        self.scope_row = try ui.box(cx, S.passiveRow(), .{});
        self.scope_icon = try ui.iconTint(cx, ui.icons.globe, S.theme.current().fg_2, S.icon(14));
        try self.scope_row.appendChild(cx.allocator, self.scope_icon);
        self.scope_label = try ui.text(cx, "应用与全部终端", S.label());
        self.scope_label.setStyleInline(cx.allocator, S.labelBox());
        try self.scope_row.appendChild(cx.allocator, self.scope_label);
        self.scope_tag = try ui.text(cx, "全局生效", S.tag());
        self.scope_tag.setStyleInline(cx.allocator, .{ .width = .{ .px = 100 }, .height = .{ .px = 16 }, .flex_shrink = 0 });
        try self.scope_row.appendChild(cx.allocator, self.scope_tag);
        try self.body.appendChild(cx.allocator, self.scope_row);
        self.scroll = try ui.widgets.ScrollArea(.{ .direction = .vertical, .height = 90, .rubber_band_y = false }).mount(popup.scope, cx);
        self.scroll.container.setStyleInline(cx.allocator, .{ .width = .fill(), .height = .{ .px = 90 }, .min_height = 0, .flex_shrink = 0 });
        self.scroll.container.meta.ownership.meta.test_id = "status.theme.list";
        self.scroll.content.setStyleInline(cx.allocator, S.body());
        try self.body.appendChild(cx.allocator, self.scroll.container);
        self.manage_button = try ui.widgets.Button(.{ .variant = .ghost, .a11y_label = "管理主题…", .base_style = S.row(), .hover_style = S.hover(), .disabled = disabled, .on_click = cx.on(View, self, manage) }).mount(popup.scope, cx);
        self.manage_button.setStyleInline(cx.allocator, S.row());
        self.manage_button.meta.ownership.meta.test_id = "status.theme.manage";
        const manage_content = try self.rowContent(self.manage_button, ui.icons.get("settings-2").?, "管理主题…");
        self.manage_icon = manage_content.icon;
        self.manage_label = manage_content.label;
        try self.body.appendChild(cx.allocator, self.manage_button);
        self.feedback_row = try ui.box(cx, S.passiveRow(), .{});
        self.feedback_icon = try ui.iconTint(cx, ui.icons.get("circle-check").?, S.theme.current().ok, S.icon(14));
        try self.feedback_row.appendChild(cx.allocator, self.feedback_icon);
        self.feedback_failure = try ui.iconTint(cx, ui.icons.circle_alert, S.theme.current().danger, S.icon(14));
        self.feedback_failure.setDisplay(.none);
        try self.feedback_row.appendChild(cx.allocator, self.feedback_failure);
        self.feedback_spinner = try ui.widgets.Spinner(.{ .size = 14, .stroke_width = 2, .color = S.theme.current().fg_2 }).mount(popup.scope, cx);
        self.feedback_spinner.setDisplay(.none);
        try self.feedback_row.appendChild(cx.allocator, self.feedback_spinner);
        self.feedback_label = try ui.text(cx, "当前全局主题", S.label());
        self.feedback_label.setStyleInline(cx.allocator, S.labelBox());
        self.feedback_label.meta.ownership.meta.test_id = "status.theme.feedback";
        try self.feedback_row.appendChild(cx.allocator, self.feedback_label);
        try self.body.appendChild(cx.allocator, self.feedback_row);
        self.scroll_hint = try ui.iconTint(cx, ui.icons.chevron_down, S.theme.current().fg_3, S.icon(12));
        self.scroll_hint.setStyleInline(cx.allocator, S.scrollHint(174));
        try self.chrome.appendChild(cx.allocator, self.scroll_hint);
        return self;
    }

    pub fn update(self: *View, current: ThemeId, registry_revision: u64, config_revision: u64) !void {
        if (registry_revision == 0 or config_revision == 0) return error.InvalidRevision;
        if (registry_revision != self.registry.revision) return error.StaleRegistryRevision;
        if (config_revision < self.config_revision) return error.StaleConfigRevision;
        const record = self.registry.get(current) orelse return error.UnknownTheme;
        if (record.staged_for != null) return error.ThemeNotPrepared;
        const changed = !std.mem.eql(u8, self.current, record.id);
        if (!changed and registry_revision == self.registry_revision and config_revision == self.config_revision) return;
        const owned = try self.cx.allocator.dupe(u8, record.id);
        if (self.current.len != 0) self.cx.allocator.free(self.current);
        self.current = owned;
        if (changed or (self.requested != null and std.mem.eql(u8, self.requested.?, record.id))) {
            self.clearRequested();
            self.feedback = .applied;
        }
        self.registry_revision = registry_revision;
        self.config_revision = config_revision;
        self.dirty = true;
        self.cx.requestRedraw();
    }

    pub fn show(self: *View, trigger: *ui.Node, status_top: f32) !void {
        if (self.current.len == 0) return error.MissingThemeProjection;
        if (!std.math.isFinite(status_top) or status_top < 0) return error.InvalidAnchor;
        if (self.isOpen() and self.anchor_id == trigger.id) {
            self.hide();
            return;
        }
        const rect = trigger.globalRect();
        self.anchor_id = trigger.id;
        self.status_top = status_top;
        self.anchor_inset = rect.y - status_top;
        self.anchor_rect = .{ .x = rect.x, .y = status_top, .w = rect.w, .h = 0 };
        self.focus_current = true;
        self.open.set(true);
        try self.flush();
    }
    pub fn isOpen(self: *const View) bool {
        return self.open.peek();
    }
    pub fn hide(self: *View) void {
        self.open.set(false);
        self.restoreFocus();
    }

    /// Rebuild only at the application's safe hook, after a click unwinds.
    pub fn flush(self: *View) !void {
        if (self.paint_revision != self.cx.theme_version) self.dirty = true;
        if (!self.isOpen()) return;
        if (self.anchor_id) |id| if (find(self.cx.root orelse return, id)) |trigger| {
            if (trigger.style.display == .none) {
                self.hide();
                return;
            }
            const rect = trigger.globalRect();
            self.status_top = rect.y - self.anchor_inset;
            self.anchor_rect = .{ .x = rect.x, .y = self.status_top, .w = rect.w, .h = 0 };
        } else {
            self.hide();
            return;
        };
        const busy = self.hooks.busy(self.hooks.context) or self.requested != null;
        if (self.disabled.peek() != busy) self.disabled.set(busy);
        if (self.rendered_registry_revision != self.registry.revision) self.dirty = true;
        if (self.dirty) {
            if (self.row_generation == std.math.maxInt(u64)) return error.RevisionExhausted;
            self.row_generation += 1;
            // Detach while native Button handlers are still alive: detaching
            // the focused row emits its blur event before freeing the scope.
            while (self.scroll.content.children.items.len > 0) {
                const node = self.scroll.content.children.items[0];
                self.cx.detachChild(self.scroll.content, node);
                self.cx.destroyDetached(node);
            }
            if (self.row_scope) |old| old.dispose();
            self.row_scope = null;
            self.rows.clearRetainingCapacity();
            const rows_scope = try self.scope.childScope();
            self.row_scope = rows_scope;
            for (self.registry.records.items) |*record| {
                if (record.staged_for != null) continue;
                try self.appendRow(rows_scope, record, std.mem.eql(u8, record.id, self.current));
            }
            // Popover owns the measured width and placement after opening.
            // Retheming must not restore .fill and restart native remeasurement.
            const panel_style = S.panel();
            self.chrome.setStyleInline(self.cx.allocator, .{ .background = panel_style.background, .shadow = panel_style.shadow });
            self.fade.setStyleInline(self.cx.allocator, S.fade());
            self.title.setTextColor(S.theme.current().fg_1);
            _ = self.header_icon.setTint(S.theme.current().accent);
            _ = self.close_icon.setTint(S.theme.current().fg_2);
            self.scope_label.setTextColor(S.theme.current().fg_1);
            self.scope_tag.setTextColor(S.theme.current().accent_ink);
            _ = self.scope_icon.setTint(S.theme.current().fg_2);
            self.manage_button.setStyleInline(self.cx.allocator, S.row());
            _ = self.manage_icon.setTint(S.theme.current().fg_2);
            self.manage_label.setTextColor(S.theme.current().fg_1);
            _ = self.scroll_hint.setTint(S.theme.current().fg_3);
            self.rendered_registry_revision = self.registry.revision;
            self.paint_revision = self.cx.theme_version;
            self.dirty = false;
        }
        const count = @min(S.visible_rows, self.rows.items.len);
        const desired = if (count == 0) 0 else @as(f32, @floatFromInt(count)) * S.row_height + @as(f32, @floatFromInt(count - 1)) * S.row_gap;
        const available = @max(0, @min(self.status_top, self.cx.viewport.height - 8) - 6 - 8 - S.fixed_height);
        const list_height = @min(340, @min(desired, available));
        if (self.list_height != list_height) {
            self.list_height = list_height;
            self.scroll.container.setStyle(self.cx.allocator, .height, .{ .px = list_height });
        }
        const total_height = if (self.rows.items.len == 0) 0 else @as(f32, @floatFromInt(self.rows.items.len)) * S.row_height + @as(f32, @floatFromInt(self.rows.items.len - 1)) * S.row_gap;
        if (self.focus_current) {
            self.focus_current = false;
            for (self.rows.items, 0..) |row, index| {
                if (!std.mem.eql(u8, row.id, self.current)) continue;
                // Fixed row geometry lets opening locate the selection before
                // the first layout, without moving it in the registry order.
                self.scroll.state.content_height = total_height;
                self.scroll.state.viewport_height = list_height;
                const y = @as(f32, @floatFromInt(index)) * (S.row_height + S.row_gap);
                ui.widgets.scroll_area.setScrollY(self.scroll.state, self.scroll.content, y - (list_height - S.row_height) / 2);
                self.cx.setFocus(row.button);
                break;
            }
        }
        const width = @min(S.width, @max(0, self.cx.viewport.width - 16));
        const center = self.anchor_rect.x + self.anchor_rect.w / 2;
        const left = std.math.clamp(center - width / 2, 8, @max(8, self.cx.viewport.width - width - 8));
        self.scroll_hint.setStyleInline(self.cx.allocator, S.scrollHint(std.math.clamp(center - left - 6, 14, @max(14, width - 26))));
        self.scroll_hint.setDisplay(if (total_height > list_height) .flex else .none);
        self.scope_row.setDisplay(.none);
        self.feedback_row.setDisplay(if (self.feedback == .applied and !busy) .none else .flex);
        switch (self.feedback) {
            .applied => try self.feedbackText(if (busy) "外观更新处理中…" else "已应用至应用与全部终端", false),
            .pending => try self.feedbackText("正在应用至应用与全部终端…", false),
            .failure => try self.feedbackText(self.feedback_label.getText().?.content, true),
        }
    }

    pub fn reportError(self: *View, message: []const u8) !void {
        self.clearRequested();
        self.feedback = .failure;
        try self.feedbackText(message, true);
        self.cx.requestRedraw();
    }

    fn appendRow(self: *View, scope: *ui.Scope, record: *const themes.Record, current: bool) !void {
        const row = try self.cx.allocator.create(Row);
        var adopted = false;
        errdefer if (!adopted) self.cx.allocator.destroy(row);
        const id = try self.cx.allocator.dupe(u8, record.id);
        errdefer if (!adopted) self.cx.allocator.free(id);
        const name = try self.cx.allocator.dupe(u8, record.theme.name);
        errdefer if (!adopted) self.cx.allocator.free(name);
        const test_id = try std.fmt.allocPrint(self.cx.allocator, "status.theme.item.{s}", .{record.id});
        errdefer if (!adopted) self.cx.allocator.free(test_id);
        row.* = .{ .view = self, .id = id, .name = name, .test_id = test_id, .generation = self.row_generation, .registry_revision = self.registry.revision };
        try scope.onCleanup(Row, row, Row.cleanup);
        adopted = true;
        const button = try ui.widgets.Button(.{ .variant = .ghost, .a11y_label = row.name, .disabled = self.disabled, .base_style = S.row(), .hover_style = S.hover(), .on_click = self.cx.on(Row, row, Row.choose) }).mount(scope, self.cx);
        button.setStyleInline(self.cx.allocator, S.row());
        button.meta.ownership.meta.test_id = row.test_id;
        row.button = button;
        const text = if (current) try std.fmt.allocPrint(self.cx.allocator, "{s} · 当前", .{record.theme.name}) else try self.cx.allocator.dupe(u8, record.theme.name);
        defer self.cx.allocator.free(text);
        _ = try self.rowContent(button, ui.icons.palette, text);
        if (current) button.setBackground(S.theme.popupSelection());
        try self.scroll.content.appendChild(self.cx.allocator, button);
        try self.rows.append(self.cx.allocator, row);
    }
    const Content = struct { icon: *ui.Node, label: *ui.Node };
    fn rowContent(self: *View, button: *ui.Node, icon: ui.SvgAsset, text: []const u8) !Content {
        const content = try ui.box(self.cx, S.rowContent(), .{});
        try button.appendChild(self.cx.allocator, content);
        const icon_node = try ui.iconTint(self.cx, icon, S.theme.current().fg_2, S.icon(14));
        try content.appendChild(self.cx.allocator, icon_node);
        const label = try ui.text(self.cx, text, S.label());
        label.setStyleInline(self.cx.allocator, S.labelBox());
        try content.appendChild(self.cx.allocator, label);
        return .{ .label = label, .icon = icon_node };
    }
    fn feedbackText(self: *View, text: []const u8, failure: bool) !void {
        if (!std.mem.eql(u8, self.feedback_label.getText().?.content, text)) try self.feedback_label.setTextContent(self.cx.allocator, text);
        const color = if (failure) S.theme.current().danger_ink else S.theme.current().fg_1;
        if (!ui.Color.eql(self.feedback_label.getText().?.color, color)) self.feedback_label.setTextColor(color);
        tint(self.feedback_icon, S.theme.current().ok);
        tint(self.feedback_failure, S.theme.current().danger);
        const pending = !failure and (self.feedback == .pending or self.disabled.peek());
        self.feedback_icon.setDisplay(if (!failure and !pending) .flex else .none);
        self.feedback_failure.setDisplay(if (failure) .flex else .none);
        self.feedback_spinner.setDisplay(if (pending) .flex else .none);
    }
    fn select(self: *View, row: *Row) void {
        if (!self.isOpen() or self.requested != null or self.hooks.busy(self.hooks.context)) return;
        if (row.generation != self.row_generation) return;
        if (row.registry_revision != self.registry.revision) {
            self.dirty = true;
            self.reportError("主题库已更新，请重新选择") catch {};
            return;
        }
        const record = self.registry.get(row.id) orelse return;
        if (record.staged_for != null or std.mem.eql(u8, self.current, record.id)) return;
        self.requested = self.cx.allocator.dupe(u8, row.id) catch {
            self.reportError("内存不足，主题未更改") catch {};
            return;
        };
        self.feedback = .pending;
        // Do not touch row after this callback: the host may acknowledge the
        // new configuration synchronously, but row teardown stays in flush.
        self.hooks.select(self.hooks.context, row.id) catch |err| {
            var buffer: [192]u8 = undefined;
            const text = std.fmt.bufPrint(&buffer, "主题更新失败：{s}", .{@errorName(err)}) catch "主题更新失败";
            self.reportError(text) catch {};
        };
        self.cx.requestRedraw();
    }
    fn manage(self: *View) void {
        if (!self.isOpen() or self.hooks.busy(self.hooks.context) or self.requested != null) return;
        self.hide();
        self.hooks.manage(self.hooks.context);
    }
    fn clearRequested(self: *View) void {
        if (self.requested) |id| self.cx.allocator.free(id);
        self.requested = null;
    }
    fn openChanged(self: *View, value: bool) void {
        if (!value) self.restoreFocus();
    }
    fn anchor(raw: *anyopaque) ui.widgets.popover.AnchorRect {
        const self: *View = @ptrCast(@alignCast(raw));
        return self.anchor_rect;
    }
    fn restoreFocus(self: *View) void {
        const id = self.anchor_id orelse return;
        if (find(self.cx.root orelse return, id)) |node| self.cx.setFocus(node);
    }
    fn cleanup(self: *View) void {
        // Child scopes (including row_scope) have already been disposed.
        if (self.current.len != 0) self.cx.allocator.free(self.current);
        self.clearRequested();
        self.rows.deinit(self.cx.allocator);
        self.cx.allocator.destroy(self);
    }
};

const Row = struct {
    view: *View,
    id: []u8,
    name: []u8,
    test_id: []u8,
    generation: u64,
    registry_revision: u64,
    button: *ui.Node = undefined,
    fn choose(self: *Row) void {
        self.view.select(self);
    }
    fn cleanup(self: *Row) void {
        const allocator = self.view.cx.allocator;
        allocator.free(self.id);
        allocator.free(self.name);
        allocator.free(self.test_id);
        allocator.destroy(self);
    }
};
fn find(node: *ui.Node, id: u32) ?*ui.Node {
    if (node.id == id) return node;
    for (node.children.items) |child| if (find(child, id)) |found| return found;
    return null;
}
fn tint(node: *ui.Node, color: ui.Color) void {
    const current = if (node.getIcon()) |icon| icon.tint else if (node.getImage()) |image| image.tint else return;
    if (!ui.Color.eql(current, color)) _ = node.setTint(color);
}

const TestHooks = struct {
    calls: usize = 0,
    managed: usize = 0,
    busy_state: bool = false,
    fail: bool = false,
    selected: [96]u8 = undefined,
    selected_len: usize = 0,
    fn select(raw: *anyopaque, id: ThemeId) !void {
        const self: *@This() = @ptrCast(@alignCast(raw));
        self.calls += 1;
        self.selected_len = id.len;
        @memcpy(self.selected[0..id.len], id);
        if (self.fail) return error.ReadOnlyFileSystem;
    }
    fn manage(raw: *anyopaque) void {
        const self: *@This() = @ptrCast(@alignCast(raw));
        self.managed += 1;
    }
    fn busy(raw: *anyopaque) bool {
        const self: *@This() = @ptrCast(@alignCast(raw));
        return self.busy_state;
    }
    fn hooks(self: *@This()) Hooks {
        return .{ .context = self, .select = select, .manage = manage, .busy = busy };
    }
};
fn testFrame(cx: *ui.Cx) void {
    cx.setTestFrameStep(16) catch unreachable;
    // First measure, then position, then let the public overlay animation
    // controller enter. No opacity override or direct callback invocation.
    for (0..20) |_| {
        cx.advanceFrameClock();
        cx.layout();
        _ = cx.render();
    }
}
fn click(cx: *ui.Cx, node: *ui.Node) void {
    const rect = node.globalRect();
    cx.handleMouseDown(rect.x + rect.w / 2, rect.y + rect.h / 2, .{});
    cx.handleMouseUp(rect.x + rect.w / 2, rect.y + rect.h / 2);
}

test "global theme popover renders the real registry in a bounded scroll area" {
    const allocator = std.testing.allocator;
    var registry = try themes.Registry.init(allocator);
    defer registry.deinit();
    const cx = try ui.Cx.init(allocator, std.testing.io);
    defer cx.deinit();
    cx.setViewport(1440, 900);
    cx.root = try ui.box(cx, .{ .width = .fill(), .height = .fill() }, .{});
    const scope = try ui.Scope.init(allocator, null, cx.owner);
    defer scope.dispose();
    const trigger = try ui.widgets.Button(.{ .label = "主题" }).mount(scope, cx);
    trigger.setStyleInline(allocator, .{ .position = .absolute, .inset = .{ .left = .{ .px = 1120 }, .top = .{ .px = 863 } }, .width = .{ .px = 28 }, .height = .{ .px = 26 } });
    try cx.root.?.appendChild(allocator, trigger);
    var recorder: TestHooks = .{};
    const view = try View.mount(cx, scope, &registry, recorder.hooks());
    try cx.root.?.appendChild(allocator, view.root);
    try view.update("dark", registry.revision, 1);
    cx.layout();
    _ = cx.render(); // Establish this Cx's clock before Popover starts entering.
    try view.show(trigger, 860);
    testFrame(cx);
    try std.testing.expectEqual(registry.records.items.len, view.rows.items.len);
    try std.testing.expectEqualStrings("dark", view.rows.items[0].id);
    const panel = view.chrome.globalRect();
    try std.testing.expectApproxEqAbs(@as(f32, 344), panel.w, 0.1);
    try std.testing.expect(panel.y >= 8 and panel.y + panel.h <= 854.1);
    const head = view.header.globalRect();
    try std.testing.expectApproxEqAbs(panel.x + 14, head.x, 0.1);
    try std.testing.expectApproxEqAbs(panel.y + 14, head.y, 0.1);
    try std.testing.expectApproxEqAbs(@as(f32, 316), head.w, 0.1);
    try std.testing.expectApproxEqAbs(@as(f32, 30), head.h, 0.1);
    try std.testing.expect(view.scope_row.style.display == .none);
    try std.testing.expect(view.feedback_row.style.display == .none);
    try std.testing.expect(view.scroll.container.globalRect().h <= 340);
    try std.testing.expect(view.manage_button.globalRect().y >= view.scroll.container.globalRect().y + view.scroll.container.globalRect().h);
    for (view.rows.items) |row| try std.testing.expect(registry.get(row.id) != null);
    // A late selection keeps registry order and is focused/visible on every open.
    const last_id = registry.records.items[registry.records.items.len - 1].id;
    try view.update(last_id, registry.revision, 2);
    try view.flush();
    testFrame(cx);
    for (registry.records.items, view.rows.items) |record, row| try std.testing.expectEqualStrings(record.id, row.id);
    view.hide();
    try view.show(trigger, 860);
    testFrame(cx);
    const selected = view.rows.items[view.rows.items.len - 1].button;
    try std.testing.expect(cx.isFocused(selected));
    const viewport = view.scroll.container.globalRect();
    const selected_rect = selected.globalRect();
    try std.testing.expect(selected_rect.y >= viewport.y - 0.1);
    try std.testing.expect(selected_rect.y + selected_rect.h <= viewport.y + viewport.h + 0.1);
    ui.widgets.scroll_area.setScrollY(view.scroll.state, view.scroll.content, 0);
    try view.flush();
    try std.testing.expectEqual(@as(f32, 0), view.scroll.state.scroll_y);
    view.hide();
    try view.show(trigger, 860);
    testFrame(cx);
    try std.testing.expect(view.scroll.state.scroll_y > 0);
    try std.testing.expect(cx.isFocused(selected));
    // A compact window shrinks the list viewport; it retains every record.
    cx.setViewport(480, 270);
    trigger.setStyleInline(allocator, .{ .inset = .{ .left = .{ .px = 430 }, .top = .{ .px = 233 } } });
    cx.layout();
    try view.flush();
    testFrame(cx);
    const compact = view.chrome.globalRect();
    try std.testing.expect(compact.x >= 8 and compact.x + compact.w <= 472.1);
    try std.testing.expect(compact.y >= 8);
    try std.testing.expectApproxEqAbs(@as(f32, 224), compact.y + compact.h, 0.1);
    try std.testing.expect(view.scroll.container.globalRect().h < 340);
    try std.testing.expectEqual(registry.records.items.len, view.rows.items.len);
}

test "global theme selection waits for committed update and keeps save errors in place" {
    const allocator = std.testing.allocator;
    var registry = try themes.Registry.init(allocator);
    defer registry.deinit();
    const cx = try ui.Cx.init(allocator, std.testing.io);
    defer cx.deinit();
    cx.setViewport(1440, 900);
    cx.root = try ui.box(cx, .{ .width = .fill(), .height = .fill() }, .{});
    const scope = try ui.Scope.init(allocator, null, cx.owner);
    defer scope.dispose();
    const trigger = try ui.widgets.Button(.{ .label = "主题" }).mount(scope, cx);
    trigger.setStyleInline(allocator, .{ .position = .absolute, .inset = .{ .left = .{ .px = 1120 }, .top = .{ .px = 863 } }, .width = .{ .px = 28 }, .height = .{ .px = 26 } });
    try cx.root.?.appendChild(allocator, trigger);
    var recorder: TestHooks = .{ .fail = true };
    const view = try View.mount(cx, scope, &registry, recorder.hooks());
    try cx.root.?.appendChild(allocator, view.root);
    try view.update("dark", registry.revision, 1);
    cx.layout();
    _ = cx.render();
    try view.show(trigger, 860);
    testFrame(cx);
    click(cx, view.rows.items[1].button);
    try view.flush();
    try std.testing.expectEqual(@as(usize, 1), recorder.calls);
    try std.testing.expectEqualStrings("light", recorder.selected[0..recorder.selected_len]);
    try std.testing.expectEqualStrings("dark", view.current);
    try std.testing.expect(view.feedback == .failure and view.isOpen());
    try std.testing.expect(std.mem.indexOf(u8, view.feedback_label.getText().?.content, "ReadOnlyFileSystem") != null);
    recorder.busy_state = true;
    try view.flush();
    click(cx, view.rows.items[1].button);
    try std.testing.expectEqual(@as(usize, 1), recorder.calls);
    recorder.busy_state = false;
    recorder.fail = false;
    try view.flush();
    click(cx, view.rows.items[1].button);
    try std.testing.expectEqual(@as(usize, 2), recorder.calls);
    try std.testing.expectEqualStrings("dark", view.current);
    try std.testing.expect(view.requested != null);
    click(cx, view.rows.items[2].button);
    try std.testing.expectEqual(@as(usize, 2), recorder.calls);
    try view.update("light", registry.revision, 2);
    try view.flush();
    testFrame(cx);
    try std.testing.expectEqualStrings("light", view.current);
    try std.testing.expectEqualStrings("dark", view.rows.items[0].id);
    try std.testing.expectEqualStrings("light", view.rows.items[1].id);
    try std.testing.expect(view.requested == null and view.feedback == .applied);
    try std.testing.expectError(error.StaleConfigRevision, view.update("dark", registry.revision, 1));
    const stale = view.rows.items[1];
    registry.revision += 1;
    stale.choose();
    try std.testing.expectEqual(@as(usize, 2), recorder.calls);
    try view.update("light", registry.revision, 2);
    try view.flush();
    testFrame(cx);
    click(cx, view.manage_button);
    try std.testing.expectEqual(@as(usize, 1), recorder.managed);
    try std.testing.expect(!view.isOpen());
}

test "global theme keyboard selection retains app scope and escape returns the original trigger" {
    const allocator = std.testing.allocator;
    var registry = try themes.Registry.init(allocator);
    defer registry.deinit();
    const cx = try ui.Cx.init(allocator, std.testing.io);
    defer cx.deinit();
    cx.setViewport(480, 480);
    cx.root = try ui.box(cx, .{ .width = .fill(), .height = .fill() }, .{});
    const scope = try ui.Scope.init(allocator, null, cx.owner);
    defer scope.dispose();
    const trigger = try ui.widgets.Button(.{ .a11y_label = "全局主题" }).mount(scope, cx);
    trigger.setStyleInline(allocator, .{ .position = .absolute, .inset = .{ .left = .{ .px = 430 }, .top = .{ .px = 443 } }, .width = .{ .px = 28 }, .height = .{ .px = 26 } });
    try cx.root.?.appendChild(allocator, trigger);
    var recorder: TestHooks = .{};
    const view = try View.mount(cx, scope, &registry, recorder.hooks());
    try cx.root.?.appendChild(allocator, view.root);
    try view.update("dark", registry.revision, 1);
    cx.layout();
    _ = cx.render();
    try view.show(trigger, 440);
    testFrame(cx);
    const r = view.chrome.globalRect();
    try std.testing.expect(r.x >= 8 and r.x + r.w <= 472.1);
    try std.testing.expectApproxEqAbs(@as(f32, 310), view.scroll_hint.style.inset().left.px, 0.1);
    cx.setFocus(view.rows.items[1].button);
    cx.handleKeyDown(.@"return", .{});
    try std.testing.expectEqual(@as(usize, 1), recorder.calls);
    try std.testing.expectEqualStrings("light", recorder.selected[0..recorder.selected_len]);
    try std.testing.expectEqualStrings("dark", view.current);
    // No selected tab or terminal owner participates in this commit acknowledgement.
    try view.update("light", registry.revision, 2);
    try view.flush();
    testFrame(cx);
    try std.testing.expectEqualStrings("light", view.current);
    cx.handleKeyDown(.escape, .{});
    try std.testing.expect(!view.isOpen());
    try std.testing.expect(cx.isFocused(trigger));
    try std.testing.expectEqual(@as(usize, 0), recorder.managed);
}
