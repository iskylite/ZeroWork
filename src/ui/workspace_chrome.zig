//! Retained native chrome for the approved Mist workspace SVG.
//! Reparents existing controls; session, transfer and AI controllers stay owners.
const std = @import("std");
const ui = @import("ui");
const S = @import("shell_styles.zig");
const Workspace = @import("workspace.zig").Workspace;
const tab_layout = @import("tab_strip_layout.zig");
pub const View = struct {
    cx: *ui.Cx,
    workspace: *Workspace,
    bar: *ui.Node,
    tabs: *ui.Node,
    tools: *ui.Node,
    groups: [3]*ui.Node,
    more: *ui.Node,
    expanded: bool = false,
    compact: bool = false,
    opened_frame: f64 = -1,
    owned: [16]?*ui.Signal(bool) = @splat(null),
    owned_count: usize = 0,
    panels: [8]?*ui.Node = @splat(null),
    panel_count: usize = 0,
    identities: [2]?*ui.Node = .{ null, null },
    pub fn ownPanel(self: *View, node: *ui.Node) void {
        if (self.panel_count == self.panels.len) return;
        self.panels[self.panel_count] = node;
        self.panel_count += 1;
    }
    pub fn identitiesAtTabs(self: *View, remote: *ui.Node, local: *ui.Node) !void {
        self.identities = .{ remote, local };
        for (self.identities) |node| {
            try move(self.cx, self.bar, node.?);
            node.?.setStyleInline(self.cx.allocator, .{ .position = .absolute, .width = .{ .px = 28 }, .height = .{ .px = 28 }, .padding = .{}, .corner_radius = 14, .z_index = 5 });
        }
    }
    pub fn mount(cx: *ui.Cx, scope: *ui.Scope, workspace: *Workspace, bar: *ui.Node, tabs: *ui.Node, tools: *ui.Node, groups: [3]*ui.Node) !*View {
        const self = try scope.createState(View, .{ .cx = cx, .workspace = workspace, .bar = bar, .tabs = tabs, .tools = tools, .groups = groups, .more = undefined });
        const capsule = try ui.boxStyled(cx, S.titleFloating, .{});
        capsule.setStyleInline(cx.allocator, .{ .width = .{ .px = 36 }, .justify = .center });
        capsule.meta.ownership.meta.test_id = "toolbar.compact";
        const button = try ui.widgets.Button(.{ .variant = .ghost, .icon_only = true, .icon_asset = ui.icons.ellipsis, .icon_size = @as(f32, 16), .a11y_label = "展开全部工具", .on_click = cx.on(View, self, expand) }).mount(scope, cx);
        S.titleToolbarButton(cx.allocator, button);
        button.meta.ownership.meta.test_id = "toolbar.expand";
        try capsule.appendChild(cx.allocator, button);
        try bar.appendChild(cx.allocator, capsule);
        capsule.setDisplay(.none);
        self.more = capsule;
        try cx.addAfterLayoutHook(self, afterLayout);
        try scope.onCleanup(View, self, cleanup);
        return self;
    }
    pub fn installFeedback(self: *View, scope: *ui.Scope) !void {
        const Feedback = @import("icon_button_feedback.zig").Binding;
        for (self.groups) |group| for (group.children.items) |button| try Feedback.attach(self.cx, scope, button);
        for (self.tabs.children.items) |button| if (button.behavior.interaction.a11y) |props| {
            if (props.role == .button) try Feedback.attach(self.cx, scope, button);
        };
        for (self.more.children.items) |button| try Feedback.attach(self.cx, scope, button);
        for (self.identities) |maybe| if (maybe) |button| try Feedback.attach(self.cx, scope, button);
    }

    pub fn own(self: *View, open: *ui.Signal(bool)) void {
        if (self.owned_count == self.owned.len) return;
        self.owned[self.owned_count] = open;
        self.owned_count += 1;
    }
    fn expand(self: *View) void {
        if (self.expanded) return;
        self.expanded = true;
        self.opened_frame = self.cx.frame_time_ms;
        self.cx.requestRedraw();
        self.cx.scheduleRedrawAfterNs(16 * std.time.ns_per_ms);
    }
    fn afterLayout(raw: *anyopaque, _: u8, _: bool) ui.AfterLayoutResult {
        const self: *View = @ptrCast(@alignCast(raw));
        if (self.workspace.active_tab) |index| {
            if (index < self.workspace.tabs.items.len) {
                const local = self.workspace.isLocalSession(self.workspace.tabs.items[index].id);
                const active_id = self.workspace.model.active;
                var active_rect: ?ui.ComputedRect = null;
                for (self.workspace.tab_nodes.items) |tab| if (tab.tab_id == active_id) {
                    active_rect = tab.node.globalRect();
                };
                for (self.identities, 0..) |maybe, kind| if (maybe) |node| {
                    const capsule = self.tabs.globalRect();
                    const icon_visible = if (active_rect) |r| r.x + 12 >= capsule.x and r.x + 40 <= capsule.x + capsule.w else false;
                    node.setDisplay(if (icon_visible and (kind == 1) == local) .flex else .none);
                    if (active_rect) |r| {
                        const parent = self.bar.globalRect();
                        const left = r.x + 12 - parent.x;
                        const top = r.y - parent.y;
                        const ext = node.style.ensureExtPanic(self.cx.allocator);
                        if (ext.inset.left != .px or ext.inset.top != .px or @abs(ext.inset.left.px - left) > 0.5 or @abs(ext.inset.top.px - top) > 0.5) {
                            node.setStyleInline(self.cx.allocator, .{ .inset = .{ .left = .{ .px = left }, .top = .{ .px = top } } });
                        }
                    }
                };
            }
        } else {
            for (self.identities) |maybe| {
                if (maybe) |node| node.setDisplay(.none);
            }
        }
        const width = self.bar.globalRect().w;
        if (width <= 0) return .done;
        var tools_width: f32 = 16;
        var widths_changed = false;
        for (self.groups) |group| {
            var visible: usize = 0;
            for (group.children.items) |child| if (child.style.display != .none) {
                visible += 1;
            };
            const w = 8 + @as(f32, @floatFromInt(visible)) * 32 - (if (visible > 0) @as(f32, 4) else 0);
            tools_width += w;
            if (group.style.width != .px or group.style.width.px != w) {
                group.setStyle(self.cx.allocator, .width, .{ .px = w });
                widths_changed = true;
            }
        }
        var natural_tabs: f32 = 0;
        for (self.workspace.strip_advances.items, 0..) |advance, i| {
            natural_tabs += std.math.clamp(advance + 76, tab_layout.minimum, tab_layout.maximum);
            if (i > 0) natural_tabs += tab_layout.gap;
        }
        const compact = width < 850 or natural_tabs > @max(0, width - tools_width - 16 - 40);
        var changed = widths_changed or self.compact != compact;
        // An empty zero-width strip must not leave a gap before the sole +.
        const tab_gap: f32 = if (self.workspace.model.tabs.items.len == 0) 0 else 4;
        if (self.tabs.style.gap != tab_gap) {
            self.tabs.setStyle(self.cx.allocator, .gap, tab_gap);
            changed = true;
        }
        self.compact = compact;
        if (!compact) self.expanded = false;
        const more_rect = self.more.globalRect();
        const over_more = compact and self.more.style.display != .none and contains(more_rect, self.cx.mouse_x, self.cx.mouse_y);
        if (over_more and !self.expanded) {
            self.expand();
            changed = true;
        }
        if (compact and self.expanded and self.cx.frame_time_ms > self.opened_frame + 80) {
            const r = self.tools.globalRect();
            // Include the gaps between groups and the retained ellipsis anchor.
            const region: ui.ComputedRect = .{ .x = r.x, .y = r.y, .w = more_rect.x + more_rect.w - r.x, .h = r.h };
            const inside = contains(region, self.cx.mouse_x, self.cx.mouse_y);
            var popup = false;
            for (self.owned[0..self.owned_count]) |open| if (open.?.peek()) {
                popup = true;
            };
            for (self.panels[0..self.panel_count]) |panel| {
                const node = panel.?;
                const rect = node.globalRect();
                var shown = node.isDisplayedInTree();
                var ancestor: ?*ui.Node = node;
                while (ancestor) |current| : (ancestor = current.parent) {
                    if (current.getOpacity() <= 0.001) {
                        shown = false;
                        break;
                    }
                }
                if (shown and rect.w > 0 and rect.h > 0) popup = true;
            }
            if (!inside and !popup) {
                self.expanded = false;
                changed = true;
            }
        }
        const tool_display: @TypeOf(self.tools.style.display) = if (!compact or self.expanded) .flex else .none;
        const more_display: @TypeOf(self.tools.style.display) = if (compact) .flex else .none;
        if (self.tools.style.display != tool_display) {
            self.tools.setDisplay(tool_display);
            changed = true;
        }
        if (self.more.style.display != more_display) {
            self.more.setDisplay(more_display);
            changed = true;
        }
        const position: @TypeOf(self.tools.style.position) = if (compact) .absolute else .relative;
        if (self.tools.style.position != position) {
            self.tools.setStyleInline(self.cx.allocator, .{ .position = position, .inset = if (compact) .{ .right = .{ .px = 44 }, .top = .{ .px = 0 } } else .{}, .z_index = 20 });
            changed = true;
        }
        const progress: f32 = if (!compact or !self.expanded or ui.a11y.preferences.reduceMotion()) 1 else @floatCast(std.math.clamp((self.cx.frame_time_ms - self.opened_frame) / 220, 0, 1));
        const eased = 1 - std.math.pow(f32, 1 - progress, 3);
        const translate = 12 * (1 - eased);
        if (self.tools.getOpacity() != eased or self.tools.style.translate_x != translate) {
            self.tools.setStyleInline(self.cx.allocator, .{ .opacity = eased, .translate_x = translate });
            self.tools.markRenderDirty();
        }
        if (progress < 1) {
            self.cx.requestRedraw();
            self.cx.scheduleRedrawAfterNs(16 * std.time.ns_per_ms);
        }
        // Reserve the expanded groups and ellipsis so their transparent gaps
        // never expose (or forward clicks to) an overlapping tab capsule.
        const reserved = if (compact) (if (self.expanded) tools_width + 44 else @as(f32, 36)) else tools_width;
        const budget = @max(96, width - reserved - 16 - 40);
        if (self.workspace.tab_budget == null or @abs(self.workspace.tab_budget.? - budget) > 0.5) {
            self.workspace.tab_budget = budget;
            self.workspace.reveal_active = true;
            self.workspace.tab_rebuild_pending = true;
            changed = true;
        }
        return if (changed) .needs_layout else .done;
    }
    fn cleanup(self: *View) void {
        self.cx.removeAfterLayoutHook(self);
    }
};
fn contains(rect: ui.ComputedRect, x: f32, y: f32) bool {
    return rect.w > 0 and rect.h > 0 and x >= rect.x and x <= rect.x + rect.w and y >= rect.y and y <= rect.y + rect.h;
}
pub fn move(cx: *ui.Cx, parent: *ui.Node, child: *ui.Node) !void {
    if (child.parent) |old| old.removeChild(child);
    try parent.appendChild(cx.allocator, child);
}
pub fn iconOnly(cx: *ui.Cx, button: *ui.Node, icon: *ui.Node, label: ?*ui.Node) void {
    S.titleToolbarButton(cx.allocator, button);
    button.setStyleInline(cx.allocator, .{ .gap = 0, .justify = .center, .align_items = .center });
    icon.setStyleInline(cx.allocator, .{ .position = .absolute, .inset = .{ .left = .{ .px = 6 }, .top = .{ .px = 6 } }, .width = .{ .px = 16 }, .height = .{ .px = 16 } });
    if (label) |node| node.setDisplay(.none);
}
pub fn retainLegacy(cx: *ui.Cx, bar: *ui.Node) void {
    bar.setStyleInline(cx.allocator, .{ .position = .absolute, .width = .{ .px = 0 }, .height = .{ .px = 0 }, .min_height = 0, .padding = .{}, .overflow = .hidden, .shadow = .{ .color = ui.Color.TRANSPARENT } });
}
