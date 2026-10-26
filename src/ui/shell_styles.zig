const std = @import("std");
const ui = @import("ui");
const theme = @import("app_theme.zig");

pub const outer: f32 = 8;
pub const gap: f32 = 6;
pub const title_height: f32 = 46;
pub const status_height: f32 = 32;
pub const sidebar_width: f32 = 300;
pub const sidebar_collapsed: f32 = 0;
pub const card_radius: f32 = 11;
// The windowed inset clears the native traffic lights; a header without
// native controls uses the same inset at both ends.
pub const title_controls_inset: f32 = 79;
pub const title_content_inset: f32 = 10;

pub fn titlePaddingForChrome(chrome: anytype) ui.Padding {
    const controls_visible = if (chrome.controls_geometry_known)
        chrome.native_controls_count != 0
    else
        !chrome.fullscreen;
    return .{ .left = if (controls_visible) title_controls_inset else title_content_inset, .right = title_content_inset };
}

/// Apply after theme publication: boxStyled replays its windowed default.
/// Compare the retained node itself so a theme replay cannot mask the change.
pub fn syncTitleChrome(allocator: std.mem.Allocator, node: *ui.Node, chrome: anytype) bool {
    const padding = titlePaddingForChrome(chrome);
    if (std.meta.eql(node.style.padding, padding)) return false;
    node.setStyleInline(allocator, .{ .padding = padding });
    return true;
}

/// Registry tokens reuse one address. Publish a different, window-owned
/// snapshot so Cx and native widgets observe each actual palette change.
/// Allocate this through cx.bindState to keep both addresses valid for Cx.
pub const ThemePublication = struct {
    snapshots: [2]ui.ThemeTokens = undefined,
    slot: u1 = 0,

    pub fn publish(self: *ThemePublication, cx: *ui.Cx, prepared: *const ui.ThemeTokens) void {
        self.slot ^= 1;
        self.snapshots[self.slot] = prepared.*;
        cx.setTheme(&self.snapshots[self.slot]);
    }
};

pub fn root(_: *const ui.ThemeTokens) ui.BoxStyle {
    // Retained portal wrappers can have zero height while still participating
    // in flex gap. Space the three chrome sections themselves instead.
    return .{ .width = .fill(), .height = .fill(), .direction = .column, .padding = ui.Padding.all(outer), .gap = 0, .background = theme.current().app };
}
pub fn title(_: *const ui.ThemeTokens) ui.BoxStyle {
    const c = theme.current();
    return .{ .shadow = cardShadow(), .inset_shadow = .{ .offset_y = 0, .blur = 0, .color = ui.Color.TRANSPARENT }, .width = .fill(), .height = .{ .px = title_height }, .margin = .{ .bottom = gap }, .flex_shrink = 0, .direction = .row, .align_items = .center, .gap = 4, .padding = .{ .left = title_controls_inset, .right = title_content_inset }, .background = c.surface_1, .border = .{ .width = 0, .color = c.border, .radius = card_radius } };
}
pub fn body(_: *const ui.ThemeTokens) ui.BoxStyle {
    return .{ .width = .fill(), .height = .fill(), .flex = 1, .min_height = 0, .direction = .row, .gap = gap, .margin = .{ .bottom = gap } };
}
pub fn sidebar(_: *const ui.ThemeTokens) ui.BoxStyle {
    const c = theme.current();
    return .{ .shadow = cardShadow(), .inset_shadow = .{ .offset_y = 0, .blur = 0, .color = ui.Color.TRANSPARENT }, .width = .{ .px = sidebar_width }, .height = .fill(), .flex_shrink = 0, .direction = .column, .background = c.surface_1, .border = .{ .width = 0, .color = c.border, .radius = card_radius }, .overflow = .hidden };
}
pub fn pane(_: *const ui.ThemeTokens) ui.BoxStyle {
    const c = theme.current();
    return .{ .shadow = cardShadow(), .inset_shadow = .{ .offset_y = 0, .blur = 0, .color = ui.Color.TRANSPARENT }, .width = .fill(), .height = .fill(), .min_width = 0, .min_height = 0, .direction = .column, .background = c.terminal, .border = .{ .width = 0, .color = c.border, .radius = card_radius }, .overflow = .hidden };
}
pub fn status(_: *const ui.ThemeTokens) ui.BoxStyle {
    const c = theme.current();
    return .{ .shadow = cardShadow(), .inset_shadow = .{ .offset_y = 0, .blur = 0, .color = ui.Color.TRANSPARENT }, .width = .fill(), .height = .{ .px = status_height }, .flex_shrink = 0, .direction = .row, .align_items = .center, .gap = 8, .padding = .{ .left = 10, .right = 10 }, .background = c.surface_1, .border = .{ .width = 0, .color = c.border, .radius = card_radius } };
}
pub fn settingsPanel(_: *const ui.ThemeTokens) ui.BoxStyle {
    const c = theme.current();
    return .{ .width = .{ .px = @import("v3_geometry.zig").settings_width }, .height = .{ .px = @import("v3_geometry.zig").settings_height }, .direction = .column, .gap = 0, .padding = .{}, .background = c.overlay, .border = .{ .width = 0, .color = c.border, .radius = 14 }, .shadow = .{ .blur = 32, .offset_y = 24, .color = c.shadow } };
}
pub fn settingsBody(_: *const ui.ThemeTokens) ui.BoxStyle {
    return .{ .width = .fill(), .height = .fill(), .min_height = 0, .direction = .row, .gap = 10, .padding = .{ .left = 14, .right = 14, .bottom = 12 } };
}
pub fn settingsNavigation(_: *const ui.ThemeTokens) ui.BoxStyle {
    const c = theme.current();
    return .{ .width = .{ .px = @import("v3_geometry.zig").settings_sidebar }, .height = .fill(), .flex_shrink = 0, .direction = .column, .padding = .{ .top = 4 }, .gap = 6, .background = ui.Color.TRANSPARENT, .border = .{ .width = 0, .side_widths = .{ 0, 1, 0, 0 }, .color = c.fg_1.withAlpha(31), .radius = 0 } };
}
pub fn settingsContent(_: *const ui.ThemeTokens) ui.BoxStyle {
    return .{ .width = .fill(), .height = .fill(), .min_width = 0, .min_height = 0, .direction = .column };
}
pub fn toolbarButton(allocator: std.mem.Allocator, node: *ui.Node) void {
    const c = theme.current();
    node.setStyleInline(allocator, .{ .width = .{ .px = @import("v3_geometry.zig").icon_action }, .height = .{ .px = @import("v3_geometry.zig").icon_action }, .padding = ui.Padding.ZERO, .flex_shrink = 0, .background = ui.Color.TRANSPARENT, .border = .{ .width = 0, .color = c.border, .radius = 7 } });
}

// Actual workspace HTML .title-actions .icon-btn is 30 × 30.
pub fn titleToolbarButton(allocator: std.mem.Allocator, node: *ui.Node) void {
    toolbarButton(allocator, node);
    node.setStyleInline(allocator, .{ .width = .{ .px = 30 }, .height = .{ .px = 30 } });
}

pub fn emptyGuide(_: *const ui.ThemeTokens) ui.BoxStyle {
    return .{ .width = .{ .px = 520 }, .max_width = 520, .height = .{ .fit = .{} }, .flex_shrink = 0, .direction = .column, .align_items = .center, .padding = .ZERO, .gap = 13 };
}
pub fn emptyActions(_: *const ui.ThemeTokens) ui.BoxStyle {
    return .{ .height = .{ .px = 38 }, .margin = .{ .top = 5 }, .flex_shrink = 0, .direction = .row, .gap = 8, .align_items = .center };
}

pub fn collapsedSidebar(_: *const ui.ThemeTokens) ui.BoxStyle {
    const c = theme.current();
    return .{ .shadow = cardShadow(), .inset_shadow = .{ .offset_y = 0, .blur = 0, .color = ui.Color.TRANSPARENT }, .width = .{ .px = sidebar_collapsed }, .height = .fill(), .flex_shrink = 0, .direction = .column, .align_items = .center, .gap = 4, .padding = .{ .top = 8, .bottom = 8 }, .background = c.surface_1, .border = .{ .width = 0, .color = c.border, .radius = card_radius } };
}

pub fn collapsedAction() ui.BoxStyle {
    const c = theme.current();
    return .{ .width = .{ .px = 34 }, .height = .{ .px = 34 }, .flex_shrink = 0, .align_items = .center, .justify = .center, .padding = ui.Padding.ZERO, .background = ui.Color.TRANSPARENT, .border = .{ .width = 0, .color = c.border, .radius = 9 } };
}

test "shell publishes reused registry tokens and repaints retained chrome" {
    const previous = theme.currentName();
    defer theme.select(previous);
    var registry = try @import("../config/theme_registry.zig").Registry.init(std.testing.allocator);
    defer registry.deinit();
    const cx = try ui.Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    const publication = try cx.bindState(ThemePublication, .{});
    theme.selectTokens(registry.get("dark").?.ui_tokens);
    const prepared = theme.widgetTheme(theme.currentName());
    publication.publish(cx, prepared);
    const shell = try ui.boxStyled(cx, root, .{});
    cx.root = shell;
    const titlebar = try ui.boxStyled(cx, title, .{});
    try shell.appendChild(cx.allocator, titlebar);
    const side = try ui.boxStyled(cx, sidebar, .{});
    try shell.appendChild(cx.allocator, side);
    const title_id = titlebar.id;
    const side_id = side.id;
    var previous_publication = cx.tokens;
    for ([_][]const u8{ "light", "sauber", "dark" }) |id| {
        theme.selectTokens(registry.get(id).?.ui_tokens);
        // The prepared registry address never changes, so passing it straight
        // to Cx.setTheme would skip the second and following updates.
        try std.testing.expectEqual(prepared, theme.widgetTheme(theme.currentName()));
        publication.publish(cx, prepared);
        try std.testing.expect(cx.tokens != previous_publication);
        previous_publication = cx.tokens;
        const c = theme.current();
        try std.testing.expectEqual(c.app, shell.getBackground());
        try std.testing.expectEqual(c.surface_1, titlebar.getBackground());
        try std.testing.expectEqual(c.surface_1, side.getBackground());
        try std.testing.expectEqual(@as(u8, 0), titlebar.style.shadow().?.color.a);
        try std.testing.expectEqual(@as(u8, 0), side.style.shadow().?.color.a);
        try std.testing.expectEqual(c.fg_1, cx.tokens.tokens.color.fg_primary);
        try std.testing.expectEqual(title_id, titlebar.id);
        try std.testing.expectEqual(side_id, side.id);
        try std.testing.expectEqual(title_height, titlebar.style.height.px);
        try std.testing.expectEqual(sidebar_width, side.style.width.px);
    }
}

test "global material publication repaints retained shell after an image becomes ready" {
    const saved_parameters = theme.materialParameters();
    defer _ = theme.setMaterialParameters(saved_parameters.transparency, saved_parameters.blur);
    _ = theme.setMaterialParameters(75, 24);
    const previous = theme.currentName();
    const was_visible = theme.materialVisible();
    defer {
        theme.select(previous);
        _ = theme.setMaterialVisible(was_visible);
    }
    _ = theme.setMaterialVisible(false);
    theme.select(.dark);
    const cx = try ui.Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    const publication = try cx.bindState(ThemePublication, .{});
    publication.publish(cx, theme.widgetTheme(.dark));
    const shell = try ui.boxStyled(cx, root, .{});
    cx.root = shell;
    const recipes = .{ title, sidebar, status, settingsPanel, settingsNavigation };
    var nodes: [recipes.len]*ui.Node = undefined;
    var ids: [recipes.len]u32 = undefined;
    inline for (recipes, 0..) |recipe, index| {
        nodes[index] = try ui.boxStyled(cx, recipe, .{});
        ids[index] = nodes[index].id;
        try shell.appendChild(cx.allocator, nodes[index]);
    }
    const revision = cx.theme_version;
    _ = theme.setMaterialVisible(true);
    publication.publish(cx, theme.widgetTheme(.dark));
    try std.testing.expect(cx.theme_version > revision);
    try std.testing.expectEqual(@as(u8, 0), shell.getBackground().a);
    inline for (recipes, 0..) |recipe, index| {
        const node = nodes[index];
        try std.testing.expectEqual(ids[index], node.id);
        try std.testing.expectEqual(recipe(cx.tokens).background, node.getBackground());
        try std.testing.expect(node.getBackground().a < 255);
    }
    try std.testing.expectEqual(title_height, nodes[0].style.height.px);
    try std.testing.expectEqual(sidebar_width, nodes[1].style.width.px);
    try std.testing.expectEqual(status_height, nodes[2].style.height.px);
    try std.testing.expectEqual(@import("v3_geometry.zig").settings_width, nodes[3].style.width.px);
    try std.testing.expectEqual(@import("v3_geometry.zig").settings_sidebar, nodes[4].style.width.px);
    _ = theme.setMaterialVisible(false);
    publication.publish(cx, theme.widgetTheme(.dark));
    for (nodes, 0..) |node, index| try std.testing.expectEqual(if (index == 4) @as(u8, 0) else if (index == 3) theme.current().overlay.a else theme.current().surface_1.a, node.getBackground().a);
    try std.testing.expectEqual(@as(u8, 0), shell.getBackground().a);
}

pub fn emptyTitle(_: *const ui.ThemeTokens) ui.TextStyle {
    return .{ .font_size = 17, .font_weight = 700, .line_height = 24.0 / 17.0, .color = theme.current().fg_1 };
}
pub fn emptyDescription(_: *const ui.ThemeTokens) ui.TextStyle {
    return .{ .font_size = 11, .line_height = 1.65, .color = theme.current().fg_2 };
}
pub fn emptyIcon(_: *const ui.ThemeTokens) ui.BoxStyle {
    return .{ .width = .{ .px = 56 }, .height = .{ .px = 56 }, .margin = .{ .bottom = 3 }, .flex_shrink = 0, .align_items = .center, .justify = .center, .background = theme.current().selection, .border = .{ .radius = 14 } };
}
pub fn emptyButton(primary: bool) ui.BoxStyle {
    const c = theme.current();
    var style: ui.BoxStyle = .{ .width = .{ .px = 156 }, .height = .{ .px = 38 }, .padding = .{ .left = 14, .right = 14 }, .gap = 7, .font_size = 12, .font_weight = 500, .background = if (primary) c.action_accent else c.hover, .text_color = if (primary) theme.actionForeground(c.action_accent) else c.fg_1, .border = .{ .radius = 8 }, .shadow = .{ .color = ui.Color.TRANSPARENT, .blur = 0, .offset_y = 0 }, .inset_shadow = .{ .color = ui.Color.TRANSPARENT, .blur = 0, .offset_y = 0 }, .flex_shrink = 0 };
    if (primary) {
        const family = theme.currentName();
        style.gradient = .{ .from = c.action_accent, .to = c.action_accent_2, .direction = .diagonal };
        style.shadow = .{ .blur = 10, .offset_y = 3, .color = c.action_accent.withAlpha(if (family == .dark) 89 else 82) };
        style.inset_shadow = .{ .offset_y = 1, .blur = 0, .color = ui.Color.WHITE.withAlpha(46) };
    }
    return style;
}

fn cardShadow() @typeInfo(@FieldType(ui.BoxStyle, "shadow")).optional.child {
    // V3 shell sections have no individual elevation. The native window owns
    // the exterior shadow; explicit zero clears any retained old shadow.
    return .{ .blur = 0, .offset_y = 0, .color = ui.Color.TRANSPARENT };
}
