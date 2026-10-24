//! Product color semantics read from the Vanta prototype. Selection is global
//! and main-thread owned; views and terminals share these named slots.
const std = @import("std");
const ui = @import("ui");

pub const Name = enum { dark, light, sauber };
pub const Colors = struct {
    app: ui.Color,
    surface_1: ui.Color,
    surface_2: ui.Color,
    well: ui.Color,
    well_border: ui.Color,
    terminal: ui.Color,
    overlay: ui.Color,
    hover: ui.Color,
    tab_on: ui.Color,
    fg_1: ui.Color,
    fg_2: ui.Color,
    fg_3: ui.Color,
    accent: ui.Color,
    accent_ink: ui.Color,
    ok: ui.Color,
    ok_ink: ui.Color,
    warn: ui.Color,
    warn_ink: ui.Color,
    danger: ui.Color,
    danger_ink: ui.Color,
    selection: ui.Color,
    border: ui.Color,
    shadow: ui.Color,
};

var selected: Name = .sauber;
var applied_colors: ?Colors = null;
var applied_widgets: ui.ThemeTokens = undefined;
var material_visible: bool = false;

/// Global material role alphas. The window compositor owns image opacity and
/// blur once; these tints preserve control/elevation boundaries over that same
/// image. Foreground, primary actions, borders and selection remain unchanged.
/// 2026-10-18 user feedback extends materials to all application components.
pub const material_alpha = struct {
    pub const surface_1: u8 = 24;
    pub const surface_2: u8 = 32;
    pub const well: u8 = 48;
    pub const overlay: u8 = 208;
    pub const hover: u8 = 80;
    pub const tab_on: u8 = 96;
};

/// Set from the host's actual visible image/preview, never just a saved path.
/// A change requires the same theme publication/repaint as palette selection.
pub fn setMaterialVisible(visible: bool) bool {
    if (material_visible == visible) return false;
    material_visible = visible;
    refreshWidgets();
    return true;
}
pub fn materialVisible() bool {
    return material_visible;
}

/// Publish exactly the registry's prepared roles, including imported themes.
/// Storage is process-owned; no borrowed draft strings reach widget tokens.
pub fn selectTokens(tokens: @import("../config/theme_registry.zig").UiTokens) void {
    var next: Colors = undefined;
    inline for (@typeInfo(Colors).@"struct".field_names) |field| {
        const rgba = @field(tokens, field);
        @field(next, field) = ui.Color.rgba(@intCast(rgba >> 24), @intCast((rgba >> 16) & 255), @intCast((rgba >> 8) & 255), @intCast(rgba & 255));
    }
    applied_colors = next;
    refreshWidgets();
}

pub fn fromName(name: []const u8) Name {
    if (std.ascii.eqlIgnoreCase(name, "sauber")) return .sauber;
    if (std.ascii.eqlIgnoreCase(name, "light") or std.ascii.eqlIgnoreCase(name, "vanta-light")) return .light;
    return .dark;
}
pub fn select(name: Name) void {
    selected = name;
    applied_colors = null;
    if (material_visible) refreshWidgets();
}
pub fn currentName() Name {
    return selected;
}
pub fn current() Colors {
    var value = baseColors();
    if (!material_visible) return value;
    value.app.a = 0;
    value.terminal.a = 0;
    inline for (.{ "surface_1", "surface_2", "well", "overlay", "hover", "tab_on" }) |field| {
        const color = &@field(value, field);
        color.a = @min(color.a, @field(material_alpha, field));
    }
    return value;
}
/// Unmodified palette for image clear/veil composition and theme previews.
/// Using current().app there would apply UI translucency to the image itself.
pub fn baseColors() Colors {
    return applied_colors orelse colors(selected);
}
fn refreshWidgets() void {
    const base = baseColors();
    const dark = @as(u32, base.app.r) * 299 + @as(u32, base.app.g) * 587 + @as(u32, base.app.b) * 114 < 128000;
    applied_widgets = widgetTokensFrom(current(), dark);
    applied_widgets.name = if (applied_colors != null) "global" else @tagName(selected);
}
pub fn colors(name: Name) Colors {
    return switch (name) {
        .dark => .{
            .app = hex(0x060608),
            .surface_1 = hex(0x131316),
            .surface_2 = hex(0x1b1b1f),
            .well = hex(0x0c0c0f),
            .well_border = hex(0x26262c),
            .terminal = hex(0x0a0a0d),
            .overlay = hex(0x18181c),
            .hover = hex(0x202026),
            .tab_on = hex(0x1e1e23),
            .fg_1 = hex(0xf4f4f5),
            .fg_2 = hex(0xa1a1aa),
            .fg_3 = hex(0x5b5b64),
            .accent = hex(0x6366f1),
            .accent_ink = hex(0x8c8ef5),
            .ok = hex(0x22c55e),
            .ok_ink = hex(0x22c55e),
            .warn = hex(0xf59e0b),
            .warn_ink = hex(0xf59e0b),
            .danger = hex(0xef4444),
            .danger_ink = hex(0xf36e6e),
            .selection = ui.Color.rgba(0x63, 0x66, 0xf1, 36),
            .border = hex(0x26262c),
            .shadow = ui.Color.rgba(0, 0, 0, 92),
        },
        .light => .{
            .app = hex(0xe6e6ea),
            .surface_1 = hex(0xfbfbfc),
            .surface_2 = hex(0xf4f4f7),
            .well = hex(0xececf0),
            .well_border = hex(0xd9d9e0),
            .terminal = hex(0xfbfbfc),
            .overlay = hex(0xffffff),
            .hover = hex(0xececf1),
            .tab_on = hex(0xffffff),
            .fg_1 = hex(0x18181b),
            .fg_2 = hex(0x52525b),
            .fg_3 = hex(0xa1a1aa),
            .accent = hex(0x4f46e5),
            .accent_ink = hex(0x4f46e5),
            .ok = hex(0x16a34a),
            .ok_ink = hex(0x107435),
            .warn = hex(0xd97706),
            .warn_ink = hex(0x985304),
            .danger = hex(0xdc2626),
            .danger_ink = hex(0xc32222),
            .selection = ui.Color.rgba(0x4f, 0x46, 0xe5, 23),
            .border = hex(0xd9d9e0),
            .shadow = ui.Color.rgba(15, 23, 42, 36),
        },
        .sauber => .{
            .app = hex(0xd9eccf),
            .surface_1 = hex(0xf2fdec),
            .surface_2 = hex(0xecfbe5),
            .well = hex(0xe2f5da),
            .well_border = hex(0xc9e4bd),
            .terminal = hex(0xecffe5),
            .overlay = hex(0xf3ffef),
            .hover = hex(0xdbf0d6),
            .tab_on = hex(0xf8fff4),
            .fg_1 = hex(0x0f172a),
            .fg_2 = hex(0x46604f),
            .fg_3 = hex(0x8aa396),
            .accent = hex(0x1345f6),
            .accent_ink = hex(0x1345f6),
            .ok = hex(0x10b981),
            .ok_ink = hex(0x0a714f),
            .warn = hex(0xd49a0c),
            .warn_ink = hex(0x7f5c07),
            .danger = hex(0xdc4c3f),
            .danger_ink = hex(0xad3c32),
            .selection = ui.Color.rgba(0x13, 0x45, 0xf6, 23),
            .border = hex(0xc9e4bd),
            .shadow = ui.Color.rgba(20, 70, 35, 36),
        },
    };
}

fn hex(value: u24) ui.Color {
    return ui.Color.hex(value);
}

const dark_widgets = widgetTokens(.dark);
const light_widgets = widgetTokens(.light);
const sauber_widgets = widgetTokens(.sauber);
pub fn widgetTheme(name: Name) *const ui.ThemeTokens {
    if (applied_colors != null or material_visible) return &applied_widgets;
    return switch (name) {
        .dark => &dark_widgets,
        .light => &light_widgets,
        .sauber => &sauber_widgets,
    };
}

fn widgetTokens(comptime name: Name) ui.ThemeTokens {
    var value = widgetTokensFrom(colors(name), name == .dark);
    value.name = @tagName(name);
    return value;
}

fn widgetTokensFrom(c: Colors, dark: bool) ui.ThemeTokens {
    var value = if (dark) ui.theme.dark else ui.theme.light;
    const t = &value.tokens.color;
    t.bg_base = c.app;
    t.bg_primary = c.surface_1;
    t.bg_secondary = c.surface_2;
    t.bg_tertiary = c.overlay;
    t.bg_hover = c.hover;
    t.bg_active = c.selection;
    t.bg_inset = c.well;
    t.fg_primary = c.fg_1;
    t.fg_secondary = c.fg_2;
    t.fg_tertiary = c.fg_3;
    t.fg_disabled = c.fg_3;
    t.accent = c.accent;
    t.accent_hover = c.accent;
    t.accent_subtle = c.selection;
    t.border = ui.Color.TRANSPARENT;
    t.border_strong = ui.Color.TRANSPARENT;
    t.border_focus = ui.Color.TRANSPARENT;
    t.focus_ring = ui.Color.TRANSPARENT;
    t.success = c.ok;
    t.warning = c.warn;
    t.danger = c.danger;
    t.selection_bg = c.selection;
    t.button_primary_bg = c.accent;
    t.button_primary_fg = ui.Color.WHITE;
    t.button_secondary_bg = c.surface_2;
    t.button_secondary_fg = c.fg_1;
    t.input_bg = c.well;
    t.input_border = ui.Color.TRANSPARENT;
    t.checkbox_bg = c.well;
    t.checkbox_border = ui.Color.TRANSPARENT;
    t.switch_track_on = c.accent;
    t.switch_track_off = c.well_border;
    t.list_hover_bg = c.hover;
    t.list_selection_bg = c.selection;
    t.separator = ui.Color.TRANSPARENT;
    t.tooltip_bg = c.overlay;
    t.tooltip_fg = c.fg_1;
    return value;
}

test "global material projects every palette without weakening action or foreground colors" {
    const previous = currentName();
    const was_visible = materialVisible();
    defer {
        select(previous);
        _ = setMaterialVisible(was_visible);
    }
    for (std.enums.values(Name)) |name| {
        _ = setMaterialVisible(false);
        select(name);
        const original = current();
        try std.testing.expect(setMaterialVisible(true));
        try std.testing.expect(!setMaterialVisible(true));
        const visible = current();
        try std.testing.expectEqual(@as(u8, 0), visible.app.a);
        try std.testing.expectEqual(@as(u8, 0), visible.terminal.a);
        inline for (.{ "surface_1", "surface_2", "well", "overlay", "hover", "tab_on" }) |field| {
            var expected = @field(original, field);
            expected.a = @field(material_alpha, field);
            try std.testing.expectEqual(expected, @field(visible, field));
        }
        inline for (.{ "fg_1", "fg_2", "fg_3", "accent", "accent_ink", "selection", "border", "well_border" }) |field| {
            try std.testing.expectEqual(@field(original, field), @field(visible, field));
        }
        const widget = widgetTheme(name).tokens.color;
        try std.testing.expectEqual(visible.surface_1, widget.bg_primary);
        try std.testing.expectEqual(visible.well, widget.input_bg);
        try std.testing.expectEqual(visible.overlay, widget.tooltip_bg);
        try std.testing.expectEqual(original.accent, widget.button_primary_bg);
        try std.testing.expectEqual(ui.Color.WHITE, widget.button_primary_fg);
        try std.testing.expectEqual(original, baseColors());
        try std.testing.expect(setMaterialVisible(false));
        try std.testing.expectEqual(original, current());
    }

    var registry = try @import("../config/theme_registry.zig").Registry.init(std.testing.allocator);
    defer registry.deinit();
    var imported = registry.get("nord").?.ui_tokens;
    imported.surface_1 = 0x12345608;
    imported.overlay = 0x234567ff;
    selectTokens(imported);
    const original = current();
    _ = setMaterialVisible(true);
    try std.testing.expectEqual(original, baseColors());
    try std.testing.expectEqual(original.surface_1, current().surface_1);
    try std.testing.expectEqual(ui.Color.rgba(0x23, 0x45, 0x67, material_alpha.overlay), current().overlay);
    try std.testing.expectEqual(original.accent, widgetTheme(currentName()).tokens.color.button_primary_bg);
    _ = setMaterialVisible(false);
    try std.testing.expectEqual(original, current());
}
