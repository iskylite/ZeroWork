//! One retained notes presentation within the connection content slot.
const std = @import("std");
const ui = @import("ui");
const contract = @import("../../host/plugin_ui_contract.zig");
const SessionHandle = @import("../../host/identity.zig").SessionHandle;
const Workspace = @import("../../ui/workspace.zig").Workspace;
const SessionTab = @import("../../ui/workspace.zig").SessionTab;
const ApplicationHost = @import("../../ui/application_host.zig").ApplicationHost;
const Surface = @import("../../ui/floating_surface.zig").Surface;
const input = @import("../../ui/floating_input.zig");
const theme = @import("../../ui/app_theme.zig");
const plugin = @import("plugin.zig");
const notes_view = @import("view.zig");
const S = @import("styles.zig");

pub fn panelWidth(window_width: f32, available_width: f32) f32 {
    return @max(0, @min(window_width * (2.0 / 3.0), available_width));
}

pub const View = struct {
    cx: *ui.Cx,
    workspace: *Workspace,
    parent: *ui.Node,
    clip: *ui.Node,
    root: *ui.Node,
    title: *ui.Node,
    title_icon: *ui.Node,
    divider: *ui.Node,
    content: *ui.Node,
    header_slots: notes_view.FloatingHeader,
    surface: *Surface = undefined,
    detached: ?Workspace.MountedPlugin = null,
    detached_visible: bool = false,
    floated_tab: ?@FieldType(SessionTab, "id") = null,
    want_visible: bool = false,
    want_tab: bool = false,
    focus_on_reveal: ?SessionHandle = null,
    pending_source: ?@import("queries.zig").SourceRef = null,
    frame: struct { x: f32 = 0, y: f32 = 0, w: f32 = 0, h: f32 = 0 } = .{},
    theme_version: u32,

    pub fn mount(workspace: *Workspace, scope: *ui.Scope, parent: *ui.Node) !*View {
        const cx = workspace.cx;
        const colors = theme.current();
        const clip = try ui.box(cx, .{
            .position = .absolute,
            .display = .none,
            .inset = .{ .left = .{ .px = 0 }, .top = .{ .px = 0 } },
            .width = .{ .px = 0 },
            .height = .{ .px = 0 },
            .hit_behavior = .children_only,
            .overflow = .hidden,
        }, .{});
        const root = try ui.box(cx, .{
            .position = .absolute,
            .display = .none,
            .inset = .{ .right = .{ .px = 0 }, .top = .{ .px = 0 } },
            .width = .{ .px = 0 },
            .height = .fill(),
            .direction = .column,
            .hit_behavior = .@"opaque",
            .overflow = .hidden,
        }, .{});
        root.setStyleInline(cx.allocator, S.floatingSurface());
        root.meta.ownership.meta.test_id = "notes.floating";
        const header = try ui.box(cx, .{
            .width = .fill(),
            .height = .{ .px = S.floating_header_height },
            .flex_shrink = 0,
            .direction = .row,
            .align_items = .center,
            .gap = S.floating_header_gap,
            .padding = .{ .left = S.floating_header_padding, .right = 8 },
        }, .{});
        header.meta.ownership.meta.test_id = "notes.floating.header";
        try root.appendChild(cx.allocator, header);
        const title_icon = try ui.iconTint(cx, ui.icons.notebook, colors.accent, .{ .width = .{ .px = S.floating_header_icon_size }, .height = .{ .px = S.floating_header_icon_size }, .flex_shrink = 0 });
        try header.appendChild(cx.allocator, title_icon);
        const title = try ui.text(cx, "笔记", .{ .font_size = 14, .font_weight = 600, .color = colors.fg_1 });
        title.meta.ownership.meta.test_id = "notes.floating.title";
        title.setStyleInline(cx.allocator, .{ .flex_shrink = 0 });
        try header.appendChild(cx.allocator, title);
        const document_tools = try ui.box(cx, .{ .width = .fill(), .min_width = 0, .height = .fill() }, .{});
        try document_tools.children.ensureUnusedCapacity(cx.allocator, 1);
        try header.appendChild(cx.allocator, document_tools);
        const directory_tools = try ui.box(cx, .{ .direction = .row, .gap = 8, .align_items = .center, .flex_shrink = 0 }, .{});
        try directory_tools.children.ensureUnusedCapacity(cx.allocator, 2);
        try header.appendChild(cx.allocator, directory_tools);
        const divider = try ui.box(cx, .{
            .position = .absolute,
            .inset = .{ .left = .{ .px = 16 }, .right = .{ .px = 16 }, .bottom = .{ .px = 0 } },
            .height = .{ .px = 1 },
            .background = S.floatingDivider(),
        }, .{});
        try header.appendChild(cx.allocator, divider);
        const content = try ui.box(cx, .{ .width = .fill(), .height = .fill(), .min_height = 0 }, .{});
        try root.appendChild(cx.allocator, content);
        const self = try scope.createState(View, .{
            .cx = cx,
            .workspace = workspace,
            .parent = parent,
            .clip = clip,
            .root = root,
            .title = title,
            .title_icon = title_icon,
            .divider = divider,
            .content = content,
            .header_slots = .{ .document = document_tools, .directory = directory_tools },
            .theme_version = cx.theme_version,
        });
        const open = try ui.widgets.Button(.{ .a11y_label = "在页签中打开", .variant = .ghost, .icon_only = true, .icon_asset = ui.icons.external_link, .icon_size = @as(f32, 16), .base_style = S.tool(), .on_click = cx.on(View, self, requestTab) }).mount(scope, cx);
        open.meta.ownership.meta.test_id = "notes.floating.open-tab";
        const open_hint = try ui.widgets.Tooltip(.{ .text = "在页签中打开" }).mount(scope, cx);
        try open_hint.trigger.appendChild(cx.allocator, open);
        try header.appendChild(cx.allocator, open_hint.wrapper);
        const close = try ui.widgets.Button(.{ .a11y_label = "收起笔记", .variant = .ghost, .icon_only = true, .icon_asset = ui.icons.x, .icon_size = @as(f32, 16), .base_style = S.tool(), .on_click = cx.on(View, self, requestHide) }).mount(scope, cx);
        close.meta.ownership.meta.test_id = "notes.floating.close";
        try header.appendChild(cx.allocator, close);
        input.protect(cx, root);
        try clip.appendChild(cx.allocator, root);
        self.surface = try Surface.mount(cx, scope, clip);
        try parent.appendChild(cx.allocator, clip);
        workspace.notes_float_surface = root;
        return self;
    }

    pub fn tab(self: *View) ?*SessionTab {
        for (self.workspace.tabs.items) |candidate| {
            if (!candidate.closing and std.mem.eql(u8, candidate.plugin_protocol_id, plugin.id)) return candidate;
        }
        return null;
    }

    fn isActive(self: *View, candidate: *SessionTab) bool {
        const index = self.workspace.active_tab orelse return false;
        return self.workspace.tabs.items[index] == candidate;
    }

    pub fn openTab(self: *View, host: *ApplicationHost) !void {
        if (host.detached_quick_content != null) {
            self.requestTab();
            return;
        }
        try host.openSingletonQuickContent(plugin.id, plugin.payload);
        if (self.tab()) |existing| {
            if (existing.plugin_floating_root == null) _ = notes_view.focus(existing.plugin_renderer.?);
        }
    }

    pub fn toggle(self: *View, host: *ApplicationHost) !void {
        if (self.tab()) |existing| if (self.isActive(existing)) {
            _ = notes_view.focus(existing.plugin_renderer.?);
            return;
        };
        if (self.want_visible) {
            self.requestHide();
            return;
        }
        if (self.workspace.active_tab == null and self.workspace.active_group_view == null) return self.openTab(host);
        self.want_visible = true;
        self.cx.requestRedraw();
    }

    pub fn openSource(self: *View, host: *ApplicationHost, source: @import("queries.zig").SourceRef) !void {
        self.pending_source = source;
        if (self.workspace.active_tab != null or self.workspace.active_group_view != null) {
            const active_notes = if (self.tab()) |candidate| self.isActive(candidate) else false;
            if (!active_notes) self.want_visible = true;
        } else try self.openTab(host);
        self.cx.requestRedraw();
    }

    pub fn focusOwner(self: *View, host: *ApplicationHost, owner: SessionHandle) bool {
        if (self.detached) |mounted| {
            if (host.detached_quick_content) |detached| if (detached.handle.eql(owner)) {
                self.want_visible = true;
                if (!self.workspace.notes_window_visible) {
                    self.focus_on_reveal = owner;
                    return true;
                }
                if (self.detached_visible) {
                    self.surface.activate();
                    _ = notes_view.focus(mounted.instance);
                }
                self.cx.requestRedraw();
                return true;
            };
        }
        const candidate = self.tab() orelse return false;
        if (!candidate.content_owner.session.eql(owner)) return false;
        const renderer = candidate.plugin_renderer orelse return false;
        if (!self.workspace.notes_window_visible) {
            self.focus_on_reveal = owner;
            return true;
        }
        if (candidate.plugin_floating_root != null) {
            self.surface.activate();
        } else {
            self.workspace.activateTabId(candidate.tab_id);
        }
        return notes_view.focus(renderer);
    }

    fn requestTab(self: *View) void {
        self.want_tab = true;
        self.cx.requestRedraw();
    }

    fn requestHide(self: *View) void {
        self.want_visible = false;
        self.cx.requestRedraw();
    }

    pub fn focused(self: *View) ?contract.RendererInstance {
        if (!self.workspace.notes_window_visible or self.clip.style.display == .none) return null;
        const node = self.cx.focus_manager.getFocused() orelse return null;
        if (!input.containsPress(self.cx, self.root, node)) return null;
        if (self.detached) |mounted| return mounted.instance;
        const id = self.floated_tab orelse return null;
        const candidate = self.workspace.sessionTab(id) orelse return null;
        return candidate.plugin_renderer;
    }

    pub fn escape(self: *View) bool {
        if (self.focused() == null) return false;
        self.requestHide();
        return true;
    }

    pub fn prepareQuit(self: *View, host: *ApplicationHost) !void {
        if (self.detached) |mounted| {
            if (mounted.instance.vtable.prepare_close) |prepare| prepare(mounted.instance.context) catch |err| {
                self.want_visible = true;
                self.cx.requestRedraw();
                return err;
            };
        }
        try host.closeDetachedQuickContent();
        if (self.detached) |mounted| mounted.destroy(self.cx);
        self.detached = null;
        self.detached_visible = false;
        self.hide();
    }

    pub fn failRequest(self: *View, host: *ApplicationHost) void {
        self.want_tab = false;
        if (self.detached == null) {
            host.closeDetachedQuickContent() catch {};
            self.hide();
        }
    }

    pub fn tick(self: *View, host: *ApplicationHost) !bool {
        if (!self.workspace.notes_window_visible) return false;
        defer self.deliverSource();
        if (self.floated_tab) |id| {
            const candidate = self.workspace.sessionTab(id);
            if (candidate == null or candidate.?.closing) {
                self.hide();
                return true;
            }
        }
        if (self.want_tab) {
            if (self.detached) |mounted| {
                try host.promoteDetachedQuickContent(mounted);
                notes_view.setFloatingHeader(mounted.instance, null);
                self.detached = null;
                self.detached_visible = false;
                self.want_tab = false;
                self.hide();
                _ = notes_view.focus(mounted.instance);
                return true;
            }
            if (host.detached_quick_content == null) {
                self.want_tab = false;
                self.hide();
                try self.openTab(host);
                return true;
            }
        }
        if (self.tab()) |existing| if (self.isActive(existing)) {
            if (self.floated_tab != null) {
                self.hide();
                _ = notes_view.focus(existing.plugin_renderer.?);
                return true;
            }
        };
        if (!self.want_visible and !self.want_tab) {
            const was_visible = self.clip.style.display != .none;
            if (was_visible) self.hide();
            return was_visible;
        }
        var changed = self.syncFrame();
        if (self.tab()) |existing| {
            if (self.floated_tab == null) {
                const instance = existing.plugin_renderer orelse return error.ContentUnavailable;
                const content = notes_view.rootNode(instance) orelse return error.ContentUnavailable;
                self.setDisplay(true);
                try self.workspace.floatPluginContent(existing, content, self.content);
                notes_view.setFloatingHeader(instance, self.header_slots);
                self.floated_tab = existing.id;
                self.surface.activate();
                self.cx.dispatcher.cancelScrollGesture();
                _ = notes_view.focus(instance);
                changed = true;
            }
        } else {
            self.floated_tab = null;
            if (self.detached == null) {
                if (host.detached_quick_content == null) {
                    host.openDetachedQuickContent(plugin.id, plugin.payload) catch |err| switch (err) {
                        error.ContentOpening => return false,
                        else => return err,
                    };
                    self.cx.requestRedraw();
                }
                const mounted = (try host.mountDetachedQuickContent()) orelse return false;
                errdefer mounted.destroy(self.cx);
                try self.content.appendChild(self.cx.allocator, mounted.root);
                notes_view.setFloatingHeader(mounted.instance, self.header_slots);
                self.detached = mounted;
            }
            if (!self.detached_visible and self.want_visible) {
                self.setDisplay(true);
                self.setDetachedVisibility(true);
                self.surface.activate();
                self.cx.dispatcher.cancelScrollGesture();
                _ = notes_view.focus(self.detached.?.instance);
                changed = true;
            }
            if (self.want_tab) self.cx.requestRedraw();
        }
        return changed;
    }

    fn syncFrame(self: *View) bool {
        var changed = false;
        const slot = self.workspace.terminal_area.globalRect();
        const parent = self.parent.globalRect();
        const width = panelWidth(self.cx.viewport.width, slot.w);
        const frame: @TypeOf(self.frame) = .{ .x = slot.x - parent.x, .y = slot.y - parent.y, .w = slot.w, .h = slot.h };
        if (!std.meta.eql(frame, self.frame)) {
            self.frame = frame;
            self.clip.setStyleInline(self.cx.allocator, .{
                .inset = .{ .left = .{ .px = frame.x }, .top = .{ .px = frame.y } },
                .width = .{ .px = frame.w },
                .height = .{ .px = frame.h },
            });
            changed = true;
        }
        if (!std.meta.eql(self.root.style.width, ui.Sizing{ .px = width })) {
            self.root.setStyle(self.cx.allocator, .width, .{ .px = width });
            changed = true;
        }
        if (self.theme_version != self.cx.theme_version) {
            self.theme_version = self.cx.theme_version;
            const colors = theme.current();
            self.root.setStyleInline(self.cx.allocator, S.floatingSurface());
            self.title.setTextColor(colors.fg_1);
            _ = self.title_icon.setTint(colors.accent);
            self.divider.setStyle(self.cx.allocator, .background, S.floatingDivider());
        }
        return changed;
    }

    fn deliverSource(self: *View) void {
        const source = self.pending_source orelse return;
        const instance: ?contract.RendererInstance = if (self.detached_visible)
            self.detached.?.instance
        else if (self.floated_tab) |id|
            if (self.workspace.sessionTab(id)) |candidate| candidate.plugin_renderer else null
        else if (self.tab()) |candidate|
            if (self.isActive(candidate)) candidate.plugin_renderer else null
        else
            null;
        if (instance) |renderer| {
            if (notes_view.openSource(renderer, source)) self.pending_source = null;
        }
    }

    pub fn hide(self: *View) void {
        const restore = self.focused() != null;
        self.want_visible = false;
        self.focus_on_reveal = null;
        self.setDisplay(false);
        if (self.floated_tab) |id| {
            if (self.workspace.sessionTab(id)) |candidate| {
                if (candidate.plugin_renderer) |instance| notes_view.setFloatingHeader(instance, null);
                self.workspace.dockPluginContent(candidate);
            }
            self.floated_tab = null;
        }
        self.setDetachedVisibility(false);
        if (restore) if (self.workspace.active_tab) |index| {
            const active = self.workspace.tabs.items[index];
            self.cx.setFocus(if (active.terminal) |terminal| terminal.root else active.root);
        };
    }

    fn setDisplay(self: *View, visible: bool) void {
        const display: @TypeOf(self.root.style.display) = if (visible) .flex else .none;
        self.clip.setDisplay(display);
        self.root.setDisplay(display);
    }

    fn setDetachedVisibility(self: *View, visible: bool) void {
        if (self.detached_visible == visible) return;
        self.detached_visible = visible;
        self.syncDetachedPresentation();
    }

    pub fn setWindowVisible(self: *View, host: *ApplicationHost, visible: bool) void {
        if (!self.workspace.setNotesWindowVisible(visible)) return;
        if (self.detached_visible) self.syncDetachedPresentation();
        if (!visible) return;
        if (self.focus_on_reveal) |owner| {
            self.focus_on_reveal = null;
            _ = self.focusOwner(host, owner);
        }
        if (self.want_visible or self.want_tab or self.pending_source != null) self.cx.requestRedraw();
    }

    pub fn advanceBackgroundWork(self: *View) void {
        const now_ns = std.Io.Clock.awake.now(self.cx.io).toNanoseconds();
        if (self.detached) |mounted| notes_view.advanceBackgroundWork(mounted.instance, now_ns);
        if (self.tab()) |candidate| {
            if (candidate.plugin_renderer) |renderer| notes_view.advanceBackgroundWork(renderer, now_ns);
        }
    }

    fn syncDetachedPresentation(self: *View) void {
        if (self.detached) |mounted| {
            const state: contract.ContentPresentation = if (!self.detached_visible) .hidden else if (!self.workspace.notes_window_visible) .occluded else .active;
            if (mounted.instance.vtable.presentation_changed) |notify| notify(mounted.instance.context, state);
        }
    }
};

test "notes floating width follows the entire window and clamps to the connection slot" {
    try std.testing.expectApproxEqAbs(@as(f32, 960), panelWidth(1440, 1154), 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 573.333), panelWidth(860, 592), 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 500), panelWidth(860, 500), 0.001);
}
