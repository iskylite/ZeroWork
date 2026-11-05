//! One leading slot: activity at rest, disclosure on hover/focus or while open.
const std = @import("std");
const ui = @import("ui");
const theme = @import("app_theme.zig");

pub fn activityIcon(tool_name: ?[]const u8) ui.SvgAsset {
    const name = tool_name orelse return ui.icons.get("brain").?;
    var decoded: [128]u8 = undefined;
    const logical = @import("../ai/plugin_tools.zig").decodeName(&decoded, name) catch name;
    if (std.mem.eql(u8, logical, "host.run_builtin")) return ui.icons.terminal;
    if (std.mem.eql(u8, logical, "host.request_user_input")) return ui.icons.get("message-circle").?;
    if (std.mem.startsWith(u8, logical, "bmc_ikvm.")) return ui.icons.get("monitor").?;
    if (std.mem.indexOf(u8, logical, "search") != null) return ui.icons.search;
    if (std.mem.endsWith(u8, logical, "run_command")) return ui.icons.get("code").?;
    if (std.mem.indexOf(u8, logical, "terminal") != null or std.mem.indexOf(u8, logical, "execution") != null or std.mem.endsWith(u8, logical, "attach_shell")) return ui.icons.terminal;
    if (std.mem.endsWith(u8, logical, "fetch_url")) return ui.icons.get("globe").?;
    if (std.mem.indexOf(u8, logical, "group") != null) return ui.icons.get("layers").?;
    if (std.mem.indexOf(u8, logical, "session") != null or (std.mem.startsWith(u8, logical, "host.") and (std.mem.indexOf(u8, logical[5..], "host") != null))) return ui.icons.get("server").?;
    return ui.icons.get("file-text").?;
}

pub const Indicator = struct {
    cx: *ui.Cx,
    header: *ui.Node,
    slot: *ui.Node,
    activity: *ui.Node,
    chevron: *ui.Node,
    expanded: bool,
    hovered: bool = false,
    focused: bool = false,
    disclosed: ?bool = null,

    pub fn mount(cx: *ui.Cx, scope: *ui.Scope, header: *ui.Node, tool_name: ?[]const u8, color: ui.Color, expanded: bool, activity_id: []const u8, chevron_id: []const u8) !*Indicator {
        const slot = try ui.box(cx, .{ .width = .{ .px = 22 }, .height = .{ .px = 22 }, .flex_shrink = 0 }, .{});
        const style: ui.BoxStyle = .{ .position = .absolute, .inset = .{ .left = .{ .px = 4 }, .top = .{ .px = 4 } }, .width = .{ .px = 14 }, .height = .{ .px = 14 }, .flex_shrink = 0 };
        const activity = try ui.iconTint(cx, activityIcon(tool_name), color, .{ .width = .{ .px = 14 }, .height = .{ .px = 14 } });
        activity.setStyleInline(cx.allocator, style);
        activity.meta.ownership.meta.test_id = activity_id;
        const chevron = try ui.iconTint(cx, ui.icons.chevron_right, theme.current().fg_2, .{ .width = .{ .px = 14 }, .height = .{ .px = 14 } });
        chevron.setStyleInline(cx.allocator, style);
        chevron.meta.ownership.meta.test_id = chevron_id;
        try slot.appendChild(cx.allocator, activity);
        try slot.appendChild(cx.allocator, chevron);
        try header.appendChild(cx.allocator, slot);
        const self = try scope.createState(Indicator, .{ .cx = cx, .header = header, .slot = slot, .activity = activity, .chevron = chevron, .expanded = expanded });
        const hovered = try ui.hooks.useHover(scope, header);
        const focused = try ui.hooks.useFocusState(scope, cx, header);
        try scope.createEffect(.{ .hovered = hovered, .focused = focused.visible, .state = self }, struct {
            fn run(ctx: anytype) void {
                ctx.state.hovered = ctx.hovered.get();
                ctx.state.focused = ctx.focused.get();
                ctx.state.refresh();
            }
        }.run);
        try cx.addAfterLayoutHook(self, afterLayout);
        try scope.onCleanup(Indicator, self, cleanup);
        self.setExpanded(expanded);
        return self;
    }

    pub fn setExpanded(self: *Indicator, expanded: bool) void {
        self.expanded = expanded;
        const asset = if (expanded) ui.icons.chevron_down else ui.icons.chevron_right;
        if (asset.icon_id) |id| if (asset.pickRep(14)) |rep| self.chevron.setIcon(.{ .icon_id = id, .rep = rep, .tint = theme.current().fg_2 });
        if (self.header.behavior.interaction.a11y) |*attrs| attrs.expanded = expanded;
        self.refresh();
    }

    fn refresh(self: *Indicator) void {
        const disclose = self.expanded or self.hovered or self.focused;
        if (self.disclosed == disclose) return;
        self.disclosed = disclose;
        self.activity.setOpacityRaw(if (disclose) 0 else 1);
        self.chevron.setOpacityRaw(if (disclose) 1 else 0);
        self.cx.requestRedraw();
    }

    fn afterLayout(raw: *anyopaque, _: u8, _: bool) ui.AfterLayoutResult {
        const self: *Indicator = @ptrCast(@alignCast(raw));
        // Live transcript replacement clears the old hit target. Restore the
        // stationary pointer's state after the new header has real bounds,
        // before painting; use the normal target when another surface owns it.
        const visible = @import("material_geometry.zig").snapshot(self.cx, self.header);
        self.hovered = self.cx.cursor_state.pointer_valid and if (self.cx.hovered_node) |node|
            node == self.header or node.isDescendantOf(self.header)
        else if (visible) |geometry|
            geometry.visible.contains(self.cx.mouse_x, self.cx.mouse_y)
        else
            false;
        self.refresh();
        return .done;
    }

    fn cleanup(self: *Indicator) void {
        self.cx.removeAfterLayoutHook(self);
    }
};
