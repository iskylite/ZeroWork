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

/// Maximum background transparency by role, not opacity and not tree opacity.
/// Lower layers reveal more of the shared window backdrop; overlays stay readable.
/// Current visual contract and native captures: docs/UI_V3/LAYER_MATERIALS.md.
/// Each role keeps its readable minimum opacity at the slider limit.
pub const material_ratio = struct {
    pub const surface_1: f32 = 0.95;
    pub const surface_2: f32 = 0.90;
    pub const well: f32 = 0.80;
    pub const overlay: f32 = 0.16;
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
/// Final T=0 background values (transparency P; alpha8 is opacity):
/// role        P before quantization    alpha8   actual opacity
/// surface_1   44.67778560%              141      55.294118%
/// surface_2   30.56901120%              177      69.411765%
/// well        21.16316160%              201      78.823529%
/// overlay     4.00000000%               245      96.078431%
/// hover       23.51462400%              195      76.470588%
/// tab_on      16.46023680%              213      83.529412%
pub const material_transparency_base = struct {
    pub const surface_1: f32 = 0.446777856;
    pub const surface_2: f32 = 0.305690112;
    pub const well: f32 = 0.211631616;
    pub const overlay: f32 = 0.04;
    pub const hover: f32 = 0.235146240;
    pub const tab_on: f32 = 0.164602368;
};

/// Final transparency increment across the full slider range, capped per role.
pub const material_transparency_span = struct {
    pub const surface_1: f32 = 0.670166784;
    pub const surface_2: f32 = 0.752467968;
    pub const well: f32 = 0.728953344;
    pub const overlay: f32 = 0.12;
    pub const hover: f32 = 0.646652160;
    pub const tab_on: f32 = 0.599622912;
};
pub fn materialAlpha(comptime role: []const u8) u8 {
    const base = @field(material_transparency_base, role);
    const span = @field(material_transparency_span, role);
    const transparency = @min(@field(material_ratio, role), base + span * material_transparency / 100);
    // Apply background alpha only; text, icons and subtree opacity stay intact.
    return @intFromFloat(@round(255 * (1 - transparency)));
}

/// Floating surface level, independent of widget kind and numeric z-index.
/// L1 preserves the existing material; L2 transmits 1–4%; L3+ is opaque.
pub fn layerAlpha(level: usize) u8 {
    return switch (level) {
        0, 1 => materialAlpha("overlay"),
        2 => @intFromFloat(@round(255 * (1 - (0.01 + 0.03 * material_transparency / 100)))),
        else => 255,
    };
}
pub fn layerBackground(level: usize) ui.Color {
    return baseColors().overlay.withAlpha(layerAlpha(level));
}
/// Keep retained surface paint in sync with the same publication as widget tokens.
/// Only overlay surfaces filter the backdrop; foreground opacity is untouched.
pub fn bindMaterial(cx: *ui.Cx, scope: *ui.Scope, node: *ui.Node, comptime role: []const u8) !void {
    try scope.createEffect(.{ .cx = cx, .node = node, .publication = try cx.themeSignal(scope) }, struct {
        fn paint(ctx: anytype) void {
            _ = ctx.publication.get();
            ctx.node.setBackground(@field(current(), role));
            if (comptime std.mem.eql(u8, role, "overlay")) ctx.node.setStyleInline(ctx.cx.allocator, overlayPaint());
        }
    }.paint);
}

/// Blur already-painted window content behind overlays, never their foreground.
/// Even when the configured background blur is zero, use 12 logical px to suppress
/// lower-layer text ghosting. This samples app content, not the desktop.
/// Quiet, opaque content surface inside an overlay; independent of wallpaper alpha.
fn insetColor(c: Colors) ui.Color {
    const overlay = c.overlay.withAlpha(255);
    const well = c.well.withAlpha(255);
    const blended = ui.Color.lerp(overlay, well, 0.3);
    return if (contrast(overlay, blended) >= 1.1) blended else well;
}
pub fn popupInset() ui.Color {
    return insetColor(current());
}
fn actionColor(c: Colors) ui.Color {
    return ui.Color.lerp(c.overlay.withAlpha(255), c.fg_2.withAlpha(255), 0.12);
}
pub fn popupAction() ui.Color {
    return actionColor(current());
}
pub fn popupBorder() ui.Color {
    return ui.Color.TRANSPARENT;
}
fn selectionColor(c: Colors) ui.Color {
    const dark = @as(u32, c.app.r) * 299 + @as(u32, c.app.g) * 587 + @as(u32, c.app.b) * 114 < 128000;
    return ui.Color.lerp(c.overlay.withAlpha(255), c.accent, if (dark) 0.16 else 0.10);
}
pub fn popupSelection() ui.Color {
    return selectionColor(current());
}
/// Secondary metadata must remain readable on the UI selection surface.
pub fn selectionSecondary() ui.Color {
    const c = current();
    if (contrast(c.fg_2, popupSelection()) >= 4.5) return c.fg_2;
    const ink = ui.Color.lerp(c.fg_2, c.fg_1, 0.25);
    return if (contrast(ink, popupSelection()) >= 4.5) ink else c.fg_1;
}
/// Repaint retained UI-derived fills without treating terminal selection as UI chrome.
pub fn remapUiSurface(color: ui.Color, previous: Colors) ?ui.Color {
    if (ui.Color.eql(color, insetColor(previous))) return popupInset();
    if (ui.Color.eql(color, actionColor(previous))) return popupAction();
    if (ui.Color.eql(color, selectionColor(previous))) return popupSelection();
    return null;
}
/// Separate floating surfaces with material and shadow, without perimeter lines.
pub fn overlayPaint() ui.BoxStyle {
    return .{ .glass = overlayGlass(), .outline = .{ .width = 0, .color = ui.Color.TRANSPARENT } };
}
/// App-owned field paint survives widget focus/disabled recipes and theme publication.
/// The Input keeps its editing, focus, accessibility and composition handlers.
pub fn styleInput(input: ui.widgets.input.InputResult) void {
    input.input_container.addBeforeRender(paintInputChrome);
}
fn paintInputChrome(node: *ui.Node) void {
    const state: *ui.widgets.input.TextInputState = @ptrCast(@alignCast(node.behavior.events.event_context orelse return));
    if (state.cx_ref) |cx| if (state.tokens != cx.tokens) {
        state.tokens = cx.tokens;
        state.dirty = true;
    };
    const c = current();
    const background = if (state.disabled) popupAction() else if (state.has_error) c.danger.withAlpha(24) else if (state.focused) popupSelection() else popupInset();
    if (!ui.Color.eql(node.getBackground(), background)) node.setBackground(background);
    node.setBorderColor(ui.Color.TRANSPARENT);
    const outline = node.style.outline();
    if (outline != null and outline.?.width != 0) node.setStyleInline(state.allocator, .{ .outline = .{ .width = 0, .color = ui.Color.TRANSPARENT } });
}
pub fn overlayGlass() ui.GlassParams {
    return .{ .backdrop_blur = @max(12, material_blur), .capture_current_target = false, .glass_intensity = 0, .specular_opacity = 0, .refraction_level = 0, .warp_gain = 0 };
}

test "global material parameters derive role ratios with readable overlay at endpoints" {
    const saved = materialParameters();
    defer _ = setMaterialParameters(saved.transparency, saved.blur);
    for ([_]f32{ 0, 25, 75, 100 }, [_]u8{ 245, 237, 222, 214 }) |percent, overlay_alpha| {
        _ = setMaterialParameters(percent, percent * 0.5);
        try std.testing.expectEqual(overlay_alpha, current().overlay.a);
        try std.testing.expect(current().overlay.a >= 214);
        try std.testing.expect(current().surface_1.a < current().surface_2.a);
        try std.testing.expect(current().surface_2.a < current().well.a);
        try std.testing.expect(current().well.a < current().overlay.a);
        try std.testing.expectEqual(@max(12, percent * 0.5), overlayGlass().backdrop_blur);
        try std.testing.expectEqual(current().overlay, widgetTheme(currentName()).tokens.color.tooltip_bg);
    }
    _ = setMaterialParameters(75, 0);
    try std.testing.expectEqual(@as(f32, 12), overlayGlass().backdrop_blur);
    try std.testing.expectEqual(@as(u8, 222), current().overlay.a);
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
/// An unchecked control stays neutral, including on pale single-hue palettes.
pub fn switchTrackOff() ui.Color {
    const c = baseColors();
    return ui.Color.lerp(c.surface_2, c.fg_3, 0.35);
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
    return tokenColors(@import("../config/theme_registry.zig").builtinTokens(@tagName(name)));
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
    // Action focus/press uses a neutral surface; selection stays with tabs and choices.
    t.bg_active = c.hover;
    t.bg_inset = c.well;
    t.fg_primary = c.fg_1;
    t.fg_secondary = c.fg_2;
    t.fg_tertiary = c.fg_2;
    t.fg_disabled = c.fg_3;
    // Zenit uses accent for checked checkbox/radio/switch fills. V3 uses --primary.
    t.accent = c.action_accent;
    t.accent_hover = c.action_accent;
    t.accent_muted = selectionColor(c);
    t.accent_subtle = selectionColor(c);
    t.border = ui.Color.TRANSPARENT;
    t.border_strong = ui.Color.TRANSPARENT;
    t.border_focus = ui.Color.TRANSPARENT;
    // Focus uses selection fill and caret, without a border or focus ring.
    t.focus_ring = ui.Color.TRANSPARENT;
    t.fg_inverse = actionForeground(c.action_accent);
    t.success = c.ok_ink;
    t.success_subtle = c.ok.withAlpha(24);
    t.warning_subtle = c.warn.withAlpha(24);
    t.danger_subtle = c.danger.withAlpha(24);
    t.danger_hover = c.action_danger;
    t.info = c.accent_ink;
    t.info_subtle = selectionColor(c);
    t.warning = c.warn_ink;
    // Widget danger is text/icon ink. Filled app actions use action_danger explicitly.
    t.danger = c.danger_ink;
    t.selection_bg = selectionColor(c);
    t.button_primary_bg = c.action_accent;
    t.button_primary_fg = actionForeground(c.action_accent);
    t.button_secondary_bg = actionColor(c);
    t.button_secondary_fg = if (dark) c.fg_2 else c.fg_1;
    t.input_bg = insetColor(c);
    t.input_border = ui.Color.TRANSPARENT;
    t.checkbox_bg = ui.Color.lerp(c.overlay.withAlpha(255), c.fg_2.withAlpha(255), 0.4);
    t.checkbox_border = ui.Color.TRANSPARENT;
    t.checkbox_disabled_bg = c.surface_2;
    t.checkbox_disabled_border = ui.Color.TRANSPARENT;
    t.checkbox_disabled_checked_bg = c.well_border;
    t.switch_track_on = c.action_accent;
    t.switch_thumb = ui.Color.WHITE;
    t.switch_track_off = ui.Color.lerp(c.surface_2.withAlpha(255), c.fg_3, 0.35);
    t.list_hover_bg = c.hover;
    t.list_selection_bg = selectionColor(c);
    t.list_selection_hover_bg = selectionColor(c);
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
        try std.testing.expectEqual(popupInset(), widget.input_bg);
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
        try std.testing.expectEqual(tokenColor(record.danger_ink), widget.danger);
        try std.testing.expect(contrast(widget.button_primary_bg, widget.button_primary_fg) >= 4.49);
        try std.testing.expectEqual(ui.Color.TRANSPARENT, widget.focus_ring);
        try std.testing.expectEqual(c.fg_3, widget.fg_disabled);
        try std.testing.expectEqual(c.surface_2, widget.checkbox_disabled_bg);
        try std.testing.expectEqual(popupInset(), widget.input_bg);
        try std.testing.expectEqual(popupSelection(), widget.list_selection_bg);
        try std.testing.expectEqual(c.hover, widget.bg_active);
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

test "layer hierarchy keeps fields and actions readable without perimeter outlines" {
    const previous = currentName();
    const parameters = materialParameters();
    defer {
        select(previous);
        _ = setMaterialParameters(parameters.transparency, parameters.blur);
    }
    var registry = try @import("../config/theme_registry.zig").Registry.init(std.testing.allocator);
    defer registry.deinit();
    for (registry.records.items) |record| {
        selectTokens(record.ui_tokens);
        for ([_]f32{ 0, 50, 100 }) |transparency| {
            _ = setMaterialParameters(transparency, 0);
            const c = current();
            const tokens = widgetTheme(currentName()).tokens.color;
            try std.testing.expectEqual(@as(u8, 255), tokens.input_bg.a);
            try std.testing.expectEqual(@as(u8, 255), tokens.button_secondary_bg.a);
            try std.testing.expectEqual(@as(u8, 255), tokens.checkbox_bg.a);
            try std.testing.expectEqual(ui.Color.TRANSPARENT, tokens.border_focus);
            try std.testing.expectEqual(ui.Color.TRANSPARENT, tokens.input_border);
            inline for (@typeInfo(@TypeOf(record.ui_tokens)).@"struct".field_names) |role|
                try std.testing.expect(@field(record.ui_tokens, role) != 0);
            for ([_]ui.Color{ tokens.input_bg, tokens.button_secondary_bg, popupSelection() }) |surface| {
                try std.testing.expect(contrast(surface, c.fg_1) >= 4.5);
                try std.testing.expect(contrast(surface, c.fg_2) >= 4.5);
            }
            for ([_]ui.Color{ c.accent_ink, c.ok_ink, c.warn_ink, c.danger_ink }) |ink|
                try std.testing.expect(contrast(c.overlay.withAlpha(255), ink) >= 4.5);
            try std.testing.expect(contrast(c.action_accent, tokens.button_primary_fg) >= 4.5);
            try std.testing.expect(contrast(c.action_accent_2, tokens.button_primary_fg) >= 4.5);
            try std.testing.expect(contrast(c.action_danger, actionForeground(c.action_danger)) >= 4.5);
            try std.testing.expectEqual(c.danger_ink, tokens.danger);
            try std.testing.expectEqual(popupSelection(), tokens.list_selection_bg);
            try std.testing.expectEqual(popupSelection(), tokens.selection_bg);
            try std.testing.expect(!ui.Color.eql(tokens.input_bg, tokens.checkbox_bg));
            try std.testing.expect(contrast(tokens.input_bg, c.fg_1) >= 4.5);
            try std.testing.expect(contrast(tokens.input_bg, c.overlay.withAlpha(255)) >= 1.1);
            try std.testing.expect(contrast(popupSelection(), c.fg_1) >= 4.5);
            try std.testing.expect(contrast(popupSelection(), c.accent_ink) >= 4.5);
            try std.testing.expectEqual(@as(f32, 0), @import("notification_history_styles.zig").panel().border.?.width);
            try std.testing.expectEqual(@as(f32, 0), @import("notification_styles.zig").card(widgetTheme(currentName())).border.?.width);
            try std.testing.expect(contrast(tokens.button_secondary_bg, tokens.button_secondary_fg) >= 4.5);
            try std.testing.expectEqual(@as(f32, 0), overlayPaint().outline.?.width);
            try std.testing.expectEqual(@as(f32, 12), overlayPaint().glass.?.backdrop_blur);
        }
    }
}
