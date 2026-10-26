//! Product color semantics read from the Vanta prototype. Selection is global
//! and main-thread owned; views and terminals share these named slots.
const std = @import("std");
const ui = @import("ui");

pub const Name = enum { dark, light, sauber };
pub const Colors = struct {
    action_accent: ui.Color = ui.Color.TRANSPARENT,
    action_accent_2: ui.Color = ui.Color.TRANSPARENT,
    action_danger: ui.Color = ui.Color.TRANSPARENT,
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

var material_transparency: f32 = 0;
var material_blur: f32 = 0;

/// Ratios of the global transparency, not independent surface opacity values.
/// Overlay transmits at most 10% so text remains readable even with blur off.
pub const material_ratio = struct {
    pub const surface_1: f32 = 0.95;
    pub const surface_2: f32 = 0.90;
    pub const well: f32 = 0.80;
    pub const overlay: f32 = 0.10;
    pub const hover: f32 = 0.75;
    pub const tab_on: f32 = 0.65;
};

pub fn setMaterialParameters(transparency: f32, blur: f32) bool {
    const next_t = if (std.math.isFinite(transparency)) std.math.clamp(transparency, 0, 100) else 0;
    const next_b = if (std.math.isFinite(blur)) std.math.clamp(blur, 0, 96) else 0;
    if (material_transparency == next_t and material_blur == next_b) return false;
    material_transparency = next_t;
    material_blur = next_b;
    refreshWidgets();
    return true;
}
pub fn materialParameters() struct { transparency: f32, blur: f32 } {
    return .{ .transparency = material_transparency, .blur = material_blur };
}
pub fn materialAlpha(comptime role: []const u8) u8 {
    return @intFromFloat(@round(255 * (1 - material_transparency / 100 * @field(material_ratio, role))));
}
pub fn overlayGlass() ui.GlassParams {
    return .{ .backdrop_blur = material_blur, .capture_current_target = false, .glass_intensity = 0, .specular_opacity = 0, .refraction_level = 0, .warp_gain = 0 };
}

test "global material parameters derive role ratios with readable overlay at endpoints" {
    const saved = materialParameters();
    defer _ = setMaterialParameters(saved.transparency, saved.blur);
    for ([_]f32{ 0, 25, 75, 100 }) |percent| {
        _ = setMaterialParameters(percent, percent * 0.5);
        try std.testing.expectEqual(@as(u8, @intFromFloat(@round(255 * (1 - percent / 100 * 0.10)))), current().overlay.a);
        try std.testing.expect(current().overlay.a >= 230);
        try std.testing.expectEqual(percent * 0.5, overlayGlass().backdrop_blur);
        try std.testing.expectEqual(current().overlay, widgetTheme(currentName()).tokens.color.tooltip_bg);
    }
    _ = setMaterialParameters(75, 0);
    try std.testing.expectEqual(@as(f32, 0), overlayGlass().backdrop_blur);
    try std.testing.expectEqual(@as(u8, 236), current().overlay.a);
}

/// Tracks actual image visibility for host/preview bookkeeping only. It never
/// switches containers between opaque and translucent presentation.
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
    applied_colors = tokenColors(tokens);
    refreshWidgets();
}
fn tokenColors(tokens: @import("../config/theme_registry.zig").UiTokens) Colors {
    var next: Colors = undefined;
    inline for (@typeInfo(Colors).@"struct".field_names) |field| {
        const rgba = @field(tokens, field);
        @field(next, field) = ui.Color.rgba(@intCast(rgba >> 24), @intCast((rgba >> 16) & 255), @intCast((rgba >> 8) & 255), @intCast(rgba & 255));
    }
    return completeColors(next);
}

fn completeColors(value: Colors) Colors {
    var c = value;
    if (c.action_accent.a == 0) c.action_accent = c.accent;
    if (c.action_accent_2.a == 0) c.action_accent_2 = c.action_accent;
    if (c.action_danger.a == 0) c.action_danger = c.danger;
    return c;
}

/// Filled actions use a distinct background from links, marks and status inks.
/// Imported palettes may provide a very pale accent; select a readable ink.
pub fn actionForeground(background: ui.Color) ui.Color {
    return if (contrast(background, ui.Color.WHITE) >= contrast(background, hex(0x101014))) ui.Color.WHITE else hex(0x101014);
}
fn luminance(c: ui.Color) f64 {
    var result: f64 = 0;
    inline for (.{ "r", "g", "b" }, .{ 0.2126, 0.7152, 0.0722 }) |field, weight| {
        const channel = @as(f64, @floatFromInt(@field(c, field))) / 255;
        result += weight * (if (channel <= 0.04045) channel / 12.92 else std.math.pow(f64, (channel + 0.055) / 1.055, 2.4));
    }
    return result;
}
fn contrast(a: ui.Color, b: ui.Color) f64 {
    const x = luminance(a);
    const y = luminance(b);
    return (@max(x, y) + 0.05) / (@min(x, y) + 0.05);
}

pub fn fromName(name: []const u8) Name {
    if (std.ascii.eqlIgnoreCase(name, "sauber")) return .sauber;
    if (std.ascii.eqlIgnoreCase(name, "light") or std.ascii.eqlIgnoreCase(name, "vanta-light")) return .light;
    return .dark;
}
pub fn select(name: Name) void {
    selected = name;
    applied_colors = null;
    refreshWidgets();
}
/// Appearance family used by native recipes. The actual selected theme ID
/// remains in RuntimeConfig; a registry palette can change without select().
pub fn currentName() Name {
    if (applied_colors) |value| {
        // Registry presets can revise their role colors. Recognize Sauber from
        // its authoritative registered palette rather than stale fallback RGBs.
        if (std.meta.eql(value, tokenColors(@import("../config/theme_registry.zig").builtinTokens("sauber")))) return .sauber;
        const weighted_luminance = @as(u32, value.app.r) * 299 + @as(u32, value.app.g) * 587 + @as(u32, value.app.b) * 114;
        return if (weighted_luminance < 128000) .dark else .light;
    }
    return selected;
}
pub fn current() Colors {
    return surfaceColors(baseColors());
}
fn surfaceColors(base: Colors) Colors {
    var value = base;
    value.app.a = 0;
    value.terminal.a = 0;
    inline for (.{ "surface_1", "surface_2", "well", "overlay", "hover", "tab_on" }) |field| {
        const color = &@field(value, field);
        color.a = materialAlpha(field);
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
    var c: Colors = switch (name) {
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
    const actions = @import("../config/theme_registry.zig").builtinTokens(@tagName(name));
    c.action_accent = tokenColor(actions.action_accent);
    c.action_accent_2 = tokenColor(actions.action_accent_2);
    c.action_danger = tokenColor(actions.action_danger);
    return completeColors(c);
}
fn tokenColor(rgba: u32) ui.Color {
    return ui.Color.rgba(@intCast(rgba >> 24), @intCast((rgba >> 16) & 255), @intCast((rgba >> 8) & 255), @intCast(rgba & 255));
}

test "registry token publication updates native appearance family without changing palette" {
    const previous = currentName();
    const was_visible = materialVisible();
    defer {
        select(previous);
        _ = setMaterialVisible(was_visible);
    }
    _ = setMaterialVisible(false);
    select(.dark);
    var registry = try @import("../config/theme_registry.zig").Registry.init(std.testing.allocator);
    defer registry.deinit();
    for ([_][]const u8{ "light", "sauber", "nord", "dark", "light" }, [_]Name{ .light, .sauber, .dark, .dark, .light }) |id, family| {
        const tokens = registry.get(id).?.ui_tokens;
        selectTokens(tokens);
        try std.testing.expectEqual(family, currentName());
        try std.testing.expectEqual(ui.Color.rgba(@intCast(tokens.app >> 24), @intCast((tokens.app >> 16) & 255), @intCast((tokens.app >> 8) & 255), @intCast(tokens.app & 255)), baseColors().app);
    }
    var imported = registry.get("light").?.ui_tokens;
    imported.app = 0xffeeccff;
    imported.accent = 0xa23010ff;
    selectTokens(imported);
    try std.testing.expectEqual(Name.light, currentName());
    _ = setMaterialVisible(true);
    try std.testing.expectEqual(Name.light, currentName());
    try std.testing.expectEqual(ui.Color.rgba(0xa2, 0x30, 0x10, 255), baseColors().accent);
}

fn hex(value: u24) ui.Color {
    return ui.Color.hex(value);
}

var named_widgets: [3]ui.ThemeTokens = undefined;
pub fn widgetTheme(name: Name) *const ui.ThemeTokens {
    if (applied_colors != null) return &applied_widgets;
    named_widgets[@backingInt(name)] = widgetTokens(name);
    return &named_widgets[@backingInt(name)];
}

fn widgetTokens(name: Name) ui.ThemeTokens {
    var value = widgetTokensFrom(surfaceColors(colors(name)), name == .dark);
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
    // Zenit uses accent for checked checkbox/radio/switch fills. V3 uses --primary.
    t.accent = c.action_accent;
    t.accent_hover = c.action_accent;
    t.accent_muted = c.selection;
    t.accent_subtle = c.selection;
    t.border = ui.Color.TRANSPARENT;
    t.border_strong = ui.Color.TRANSPARENT;
    t.border_focus = ui.Color.TRANSPARENT;
    // V3 controls use selected surfaces for focus; the HTML adds no outline.
    t.focus_ring = ui.Color.TRANSPARENT;
    t.fg_inverse = actionForeground(c.action_accent);
    t.success = c.ok;
    t.success_subtle = c.ok.withAlpha(24);
    t.warning_subtle = c.warn.withAlpha(24);
    t.danger_subtle = c.danger.withAlpha(24);
    t.danger_hover = c.action_danger;
    t.info = c.accent_ink;
    t.info_subtle = c.selection;
    t.warning = c.warn;
    t.danger = c.action_danger;
    t.selection_bg = c.selection;
    t.button_primary_bg = c.action_accent;
    t.button_primary_fg = actionForeground(c.action_accent);
    t.button_secondary_bg = c.surface_2;
    t.button_secondary_fg = c.fg_1;
    t.input_bg = c.well;
    t.input_border = ui.Color.TRANSPARENT;
    t.checkbox_bg = c.well;
    t.checkbox_border = ui.Color.TRANSPARENT;
    t.checkbox_disabled_bg = c.surface_2;
    t.checkbox_disabled_border = c.well_border;
    t.checkbox_disabled_checked_bg = c.well_border;
    t.switch_track_on = c.action_accent;
    t.switch_thumb = actionForeground(c.action_accent);
    t.switch_track_off = c.well_border;
    t.list_hover_bg = c.hover;
    t.list_selection_bg = c.selection;
    t.list_selection_hover_bg = c.selection;
    t.table_header_bg = c.surface_2;
    t.separator = ui.Color.TRANSPARENT;
    t.tooltip_bg = c.overlay;
    t.tooltip_fg = c.fg_1;
    return value;
}

test "global surface tints do not depend on whether an image is visible" {
    const previous = currentName();
    const was_visible = materialVisible();
    defer {
        select(previous);
        _ = setMaterialVisible(was_visible);
    }
    for (std.enums.values(Name)) |name| {
        select(name);
        const base = baseColors();
        _ = setMaterialVisible(false);
        const no_image = current();
        _ = setMaterialVisible(true);
        try std.testing.expectEqual(no_image, current());
        try std.testing.expectEqual(base, baseColors());
        try std.testing.expectEqual(@as(u8, 0), no_image.app.a);
        try std.testing.expectEqual(@as(u8, 0), no_image.terminal.a);
        inline for (.{ "surface_1", "surface_2", "well", "overlay", "hover", "tab_on" }) |field| {
            var expected = @field(base, field);
            expected.a = materialAlpha(field);
            try std.testing.expectEqual(expected, @field(no_image, field));
        }
        inline for (.{ "fg_1", "fg_2", "fg_3", "accent", "accent_ink", "selection", "border", "well_border" }) |field| {
            try std.testing.expectEqual(@field(base, field), @field(no_image, field));
        }
        const widget = widgetTheme(name).tokens.color;
        try std.testing.expectEqual(no_image.surface_1, widget.bg_primary);
        try std.testing.expectEqual(no_image.well, widget.input_bg);
        try std.testing.expectEqual(no_image.overlay, widget.tooltip_bg);
        try std.testing.expectEqual(base.action_accent, widget.button_primary_bg);
    }
    var registry = try @import("../config/theme_registry.zig").Registry.init(std.testing.allocator);
    defer registry.deinit();
    var imported = registry.get("nord").?.ui_tokens;
    imported.surface_1 = 0x12345608;
    imported.overlay = 0x234567ff;
    selectTokens(imported);
    const imported_base = baseColors();
    _ = setMaterialVisible(false);
    try std.testing.expectEqual(ui.Color.rgba(0x12, 0x34, 0x56, materialAlpha("surface_1")), current().surface_1);
    try std.testing.expectEqual(ui.Color.rgba(0x23, 0x45, 0x67, materialAlpha("overlay")), current().overlay);
    try std.testing.expectEqual(imported_base.action_accent, widgetTheme(currentName()).tokens.color.button_primary_bg);
    _ = setMaterialVisible(true);
    try std.testing.expectEqual(imported_base, baseColors());
}

test "all V3 themes publish independent filled action and readable state roles" {
    const previous = currentName();
    defer select(previous);
    inline for (@import("../config/theme_presets.zig").ids) |id| {
        const record = @import("../config/theme_registry.zig").builtinTokens(id);
        selectTokens(record);
        const c = current();
        const widget = widgetTheme(currentName()).tokens.color;
        try std.testing.expectEqual(tokenColor(record.action_accent), widget.button_primary_bg);
        try std.testing.expectEqual(tokenColor(record.action_accent), widget.accent);
        try std.testing.expectEqual(tokenColor(record.action_danger), widget.danger);
        try std.testing.expect(contrast(widget.button_primary_bg, widget.button_primary_fg) >= 4.49);
        try std.testing.expectEqual(ui.Color.TRANSPARENT, widget.focus_ring);
        try std.testing.expectEqual(c.fg_3, widget.fg_disabled);
        try std.testing.expectEqual(c.surface_2, widget.checkbox_disabled_bg);
        try std.testing.expectEqual(c.well, widget.input_bg);
        try std.testing.expectEqual(c.selection, widget.list_selection_bg);
        if (!std.mem.eql(u8, id, "dark") and !std.mem.eql(u8, id, "light") and !std.mem.eql(u8, id, "sauber"))
            try std.testing.expect(!ui.Color.eql(c.action_accent, c.accent));
    }
}

test "legacy imported palettes derive readable filled action foreground" {
    const previous = currentName();
    defer select(previous);
    var record = @import("../config/theme_registry.zig").builtinTokens("light");
    record.action_accent = 0;
    record.action_accent_2 = 0;
    record.action_danger = 0;
    record.accent = 0xf8e99aff;
    selectTokens(record);
    const widget = widgetTheme(currentName()).tokens.color;
    try std.testing.expectEqual(tokenColor(record.accent), widget.button_primary_bg);
    try std.testing.expect(contrast(widget.button_primary_bg, widget.button_primary_fg) > 10);
}
