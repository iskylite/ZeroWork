const std = @import("std");
const ui = @import("ui");
const theme = @import("app_theme.zig");

// Approved Mist SVG geometry in macOS points; the legacy status host has no layout slot.
pub const outer: f32 = 12;
pub const gap: f32 = 24;
pub const title_height: f32 = 36;
pub const status_height: f32 = @import("v3_geometry.zig").status_height;
pub const sidebar_width: f32 = @import("sidebar_model.zig").default_width;
pub const sidebar_collapsed: f32 = 0;
pub const card_radius: f32 = 16;
// Native traffic lights are hosted above the sidebar, outside the tool row.
pub const title_controls_inset: f32 = 79;
pub const title_content_inset: f32 = 10;

pub fn titlePaddingForChrome(chrome: anytype) ui.Padding {
    _ = chrome;
    return .{};
}

/// Apply after theme publication: boxStyled replays its windowed default.
/// Compare the retained node itself so a theme replay cannot mask the change.
pub fn syncTitleChrome(allocator: std.mem.Allocator, node: *ui.Node, chrome: anytype) bool {
    const padding = titlePaddingForChrome(chrome);
    if (std.meta.eql(node.style.padding, padding)) return false;
    node.setStyleInline(allocator, .{ .padding = padding });
    return true;
}

/// With the sidebar hidden, reserve only the native traffic-light footprint.
pub fn syncWorkspaceChrome(allocator: std.mem.Allocator, node: *ui.Node, chrome: anytype, collapsed: bool) bool {
    const controls_visible = if (chrome.controls_geometry_known) chrome.native_controls_count != 0 else !chrome.fullscreen;
    const padding: ui.Padding = .{ .left = if (collapsed and controls_visible) 96 else 0 };
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
    return .{ .width = .fill(), .height = .{ .px = title_height }, .margin = .{ .bottom = 12 }, .flex_shrink = 0, .direction = .row, .align_items = .center, .background = ui.Color.TRANSPARENT };
}
pub fn floating(_: *const ui.ThemeTokens) ui.BoxStyle {
    return .{ .height = .{ .px = 44 }, .direction = .row, .align_items = .center, .padding = ui.Padding.all(6), .gap = 8, .flex_shrink = 0, .background = theme.current().overlay, .border = .{ .radius = 14 }, .shadow = .{ .blur = 14, .offset_y = 3, .color = theme.baseColors().shadow.withAlpha(18) } };
}
/// Compact top-level chrome; content-page toolbars retain floating().
pub fn titleFloating(_: *const ui.ThemeTokens) ui.BoxStyle {
    const c = theme.current();
    return .{ .height = .{ .px = title_height }, .direction = .row, .align_items = .center, .padding = ui.Padding.all(4), .gap = 4, .flex_shrink = 0, .background = c.overlay, .border = .{ .radius = 18 }, .shadow = .{ .blur = 8, .offset_y = 3, .color = theme.baseColors().shadow.withAlpha(20) } };
}
pub fn tabCapsule(t: *const ui.ThemeTokens) ui.BoxStyle {
    var style = titleFloating(t);
    style.gap = 4;
    style.padding = ui.Padding.all(4);
    return style;
}
pub fn body(_: *const ui.ThemeTokens) ui.BoxStyle {
    return .{ .width = .fill(), .height = .fill(), .flex = 1, .min_height = 0, .direction = .row, .gap = gap };
}
pub fn sidebar(_: *const ui.ThemeTokens) ui.BoxStyle {
    const c = theme.current();
    return .{ .shadow = cardShadow(), .inset_shadow = cardHighlight(), .width = .{ .px = sidebar_width }, .height = .fill(), .flex_shrink = 0, .direction = .column, .background = c.surface_1, .border = .{ .width = 0, .color = c.border, .radius = card_radius }, .overflow = .hidden };
}
pub fn pane(_: *const ui.ThemeTokens) ui.BoxStyle {
    return .{ .width = .fill(), .height = .fill(), .min_width = 0, .min_height = 0, .direction = .column, .background = ui.Color.TRANSPARENT, .overflow = .hidden };
}
pub fn status(_: *const ui.ThemeTokens) ui.BoxStyle {
    const c = theme.current();
    return .{ .shadow = cardShadow(), .inset_shadow = cardHighlight(), .width = .fill(), .height = .{ .px = status_height }, .flex_shrink = 0, .direction = .row, .align_items = .center, .gap = 8, .padding = .{ .left = 10, .right = 10 }, .background = c.surface_1, .border = .{ .width = 0, .color = c.border, .radius = card_radius } };
}
pub fn settingsBackdrop(_: *const ui.ThemeTokens) ui.BoxStyle {
    return .{
        .position = .absolute,
        .inset = .{ .top = .{ .px = 0 }, .right = .{ .px = 0 }, .bottom = .{ .px = 0 }, .left = .{ .px = 0 } },
        .width = .fill(),
        .height = .fill(),
        .z_index = 400,
        .hit_behavior = .@"opaque",
        .hit_roles = .{ .pointer = true, .scroll = true },
        .direction = .column,
        .align_items = .center,
        .justify = .center,
        .background = theme.modal_barrier,
    };
}

test "light settings surfaces stay light across transparency and retained theme changes" {
    const previous = theme.currentName();
    const parameters = theme.materialParameters();
    defer {
        theme.select(previous);
        _ = theme.setMaterialParameters(parameters.transparency, parameters.blur);
    }
    theme.select(.dark);
    const cx = try ui.Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    const publication = try cx.bindState(ThemePublication, .{});
    publication.publish(cx, theme.widgetTheme(.dark));
    const backdrop = try ui.boxStyled(cx, settingsBackdrop, .{});
    cx.root = backdrop;
    const id = backdrop.id;
    for ([_]theme.Name{ .light, .sauber, .dark }) |name| {
        for ([_]f32{ 0, 50, 75, 100 }) |transparency| {
            theme.select(name);
            _ = theme.setMaterialParameters(transparency, 0);
            publication.publish(cx, theme.widgetTheme(name));
            try std.testing.expectEqual(id, backdrop.id);
            try std.testing.expectEqual(ui.Color.TRANSPARENT, backdrop.getBackground());
            if (name != .dark) {
                const card = theme.settingsCard();
                try std.testing.expect(card.r > 210 and card.g > 210 and card.b > 210);
                try std.testing.expectEqual(theme.current().surface_2.a, card.a);
            }
        }
    }
}

pub fn settingsPanel(_: *const ui.ThemeTokens) ui.BoxStyle {
    const c = theme.current();
    return .{ .width = .{ .px = @import("v3_geometry.zig").settings_width }, .height = .{ .px = @import("v3_geometry.zig").settings_height }, .direction = .column, .gap = 0, .padding = .{}, .background = c.overlay, .border = .{ .width = 0, .color = c.border, .radius = 14 }, .shadow = .{ .blur = 32, .offset_y = 24, .color = c.shadow }, .hit_behavior = .@"opaque", .hit_roles = .{ .pointer = true, .scroll = true } };
}
pub fn settingsBody(_: *const ui.ThemeTokens) ui.BoxStyle {
    return .{ .width = .fill(), .height = .fill(), .min_height = 0, .direction = .row, .gap = 10, .padding = .{ .left = 14, .right = 14, .bottom = 12 } };
}
pub fn settingsNavigation(_: *const ui.ThemeTokens) ui.BoxStyle {
    return .{ .width = .{ .px = @import("v3_geometry.zig").settings_sidebar }, .height = .fill(), .flex_shrink = 0, .direction = .column, .padding = .{ .top = 4 }, .gap = 6, .background = ui.Color.TRANSPARENT, .border = .{ .width = 0, .radius = 0 } };
}
pub fn settingsContent(_: *const ui.ThemeTokens) ui.BoxStyle {
    return .{ .width = .fill(), .height = .fill(), .min_width = 0, .min_height = 0, .direction = .column };
}
pub fn toolbarButton(allocator: std.mem.Allocator, node: *ui.Node) void {
    const c = theme.current();
    node.setStyleInline(allocator, .{ .width = .{ .px = @import("v3_geometry.zig").icon_action }, .height = .{ .px = @import("v3_geometry.zig").icon_action }, .corner_radius = 12, .padding = ui.Padding.ZERO, .flex_shrink = 0, .border = .{ .width = 0, .color = c.border, .radius = 12 } });
}

// Compact native workspace tool hit target.
pub fn titleToolbarButton(allocator: std.mem.Allocator, node: *ui.Node) void {
    toolbarButton(allocator, node);
    node.setStyleInline(allocator, .{ .width = .{ .px = 28 }, .height = .{ .px = 28 }, .corner_radius = 14, .border = .{ .width = 0, .radius = 14 } });
}

pub fn emptyGuide(_: *const ui.ThemeTokens) ui.BoxStyle {
    return .{ .width = .{ .px = 520 }, .max_width = 520, .height = .{ .fit = .{} }, .flex_shrink = 0, .direction = .column, .align_items = .center, .padding = .ZERO, .gap = 13 };
}
pub fn emptyActions(_: *const ui.ThemeTokens) ui.BoxStyle {
    return .{ .height = .{ .px = 38 }, .margin = .{ .top = 5 }, .flex_shrink = 0, .direction = .row, .gap = 8, .align_items = .center };
}

pub fn collapsedSidebar(_: *const ui.ThemeTokens) ui.BoxStyle {
    const c = theme.current();
    return .{ .shadow = cardShadow(), .inset_shadow = cardHighlight(), .width = .{ .px = sidebar_collapsed }, .height = .fill(), .flex_shrink = 0, .direction = .column, .align_items = .center, .gap = 4, .padding = .{ .top = 8, .bottom = 8 }, .background = c.surface_1, .border = .{ .width = 0, .color = c.border, .radius = card_radius } };
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
    const content = try ui.boxStyled(cx, pane, .{});
    try shell.appendChild(cx.allocator, content);
    const content_id = content.id;
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
        try std.testing.expectEqual(ui.Color.TRANSPARENT, titlebar.getBackground());
        try std.testing.expectEqual(c.surface_1, side.getBackground());
        try std.testing.expectEqual(ui.Color.TRANSPARENT, content.getBackground());
        try std.testing.expectEqual(@as(u8, 0), content.getBackground().a);
        try std.testing.expectEqual(content_id, content.id);
        try std.testing.expectEqual(@as(f32, 0), content.style.border.radius);
        try std.testing.expect(titlebar.style.shadow() == null);
        try std.testing.expectEqual(c.shadow, side.style.shadow().?.color);
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
    for (nodes, 0..) |node, index| try std.testing.expectEqual(if (index == 0 or index == 4) @as(u8, 0) else if (index == 3) theme.current().overlay.a else theme.current().surface_1.a, node.getBackground().a);
    try std.testing.expectEqual(@as(u8, 0), shell.getBackground().a);
}

pub fn emptyTitle(_: *const ui.ThemeTokens) ui.TextStyle {
    return .{ .font_size = 17, .font_weight = 700, .line_height = 24.0 / 17.0, .color = theme.current().fg_1 };
}
pub fn emptyDescription(_: *const ui.ThemeTokens) ui.TextStyle {
    return .{ .font_size = 11, .line_height = 1.65, .color = theme.current().fg_2 };
}
pub fn emptyIcon(_: *const ui.ThemeTokens) ui.BoxStyle {
    return .{ .width = .{ .px = 88 }, .height = .{ .px = 88 }, .margin = .{ .bottom = 3 }, .flex_shrink = 0, .align_items = .center, .justify = .center };
}
pub fn emptyButton(primary: bool) ui.BoxStyle {
    const c = theme.current();
    var style: ui.BoxStyle = .{ .width = .{ .px = 156 }, .height = .{ .px = 38 }, .padding = .{ .left = 14, .right = 14 }, .gap = 7, .font_size = 12, .font_weight = 500, .background = if (primary) c.action_accent else theme.states().action, .text_color = if (primary) theme.actionForeground(c.action_accent) else c.fg_1, .border = .{ .radius = 8 }, .shadow = .{ .color = ui.Color.TRANSPARENT, .blur = 0, .offset_y = 0 }, .inset_shadow = .{ .color = ui.Color.TRANSPARENT, .blur = 0, .offset_y = 0 }, .flex_shrink = 0 };
    if (primary) {
        const family = theme.currentName();
        style.gradient = .{ .from = c.action_accent, .to = c.action_accent_2, .direction = .diagonal };
        style.shadow = .{ .blur = 10, .offset_y = 3, .color = c.action_accent.withAlpha(if (family == .dark) 89 else 82) };
        style.inset_shadow = .{ .offset_y = 1, .blur = 0, .color = ui.Color.WHITE.withAlpha(46) };
    }
    return style;
}

pub fn cardHighlight() @typeInfo(@FieldType(ui.BoxStyle, "inset_shadow")).optional.child {
    // Keep the outer shell shadow, without a hard one-pixel highlight rim.
    return .{ .offset_y = 0, .blur = 0, .color = ui.Color.TRANSPARENT };
}
pub fn cardShadow() @typeInfo(@FieldType(ui.BoxStyle, "shadow")).optional.child {
    return .{ .blur = 4.4, .offset_y = 2, .color = theme.current().shadow };
}
