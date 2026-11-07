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

pub const StateColors = @import("theme_states.zig").Palette;
const StateCache = struct { colors: Colors, states: StateColors };
var state_cache: [2]?StateCache = .{ null, null };
/// L1 tonal state backgrounds follow their material roles; semantic foregrounds
/// and primary/danger actions retain their original opacity.
pub fn states() StateColors {
    return stateColors(current());
}
fn stateColors(colors_: Colors) StateColors {
    var normalized = colors_;
    inline for (@typeInfo(Colors).@"struct".field_names) |role|
        @field(normalized, role).a = 255;
    for (state_cache) |cached| if (cached) |entry| {
        if (std.meta.eql(entry.colors, normalized)) return @import("theme_states.zig").materialize(entry.states, colors_);
    };
    const result = @import("theme_states.zig").derive(normalized);
    state_cache[1] = state_cache[0];
    state_cache[0] = .{ .colors = normalized, .states = result };
    return @import("theme_states.zig").materialize(result, colors_);
}

/// Maximum background transparency by role, not opacity and not tree opacity.
/// The four shell cards follow the slider exactly; internal/floating roles retain their curves.
/// Current visual contract and native captures: docs/UI_V3/LAYER_MATERIALS.md.
/// Shell opacity is 1-T with no readability floor or image-dependent adjustment.
pub const material_ratio = struct {
    pub const surface_1: f32 = 1.0;
    pub const surface_2: f32 = 0.9;
    pub const well: f32 = 0.84;
    pub const overlay: f32 = 0.5;
    pub const hover: f32 = 0.9;
    pub const tab_on: f32 = 0.82;
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
/// surface_1   0%                       255     100%
/// surface_2   72.00000000%              71       27.843137%
/// well        64.00000000%              92       36.078431%
/// overlay     0%                       255      100%
/// hover       82.00000000%              46       18.039216%
/// tab_on      68.00000000%              82       32.156863%
pub const material_transparency_base = struct {
    pub const surface_1: f32 = 0;
    pub const surface_2: f32 = 0.72;
    pub const well: f32 = 0.64;
    pub const overlay: f32 = 0;
    pub const hover: f32 = 0.82;
    pub const tab_on: f32 = 0.68;
};

/// Final transparency increment across the full slider range, capped per role.
pub const material_transparency_span = struct {
    pub const surface_1: f32 = 1.0;
    pub const surface_2: f32 = 0.18;
    pub const well: f32 = 0.2;
    pub const overlay: f32 = 0.5;
    pub const hover: f32 = 0.08;
    pub const tab_on: f32 = 0.14;
};
const material_roles = .{ "surface_1", "surface_2", "well", "overlay", "hover", "tab_on" };
const MaterialAlphaCache = struct { palette: Colors, transparency: f32, image_visible: bool, alphas: [6]u8 };
var material_alpha_cache: ?MaterialAlphaCache = null;

fn unadjustedMaterialAlpha(comptime role: []const u8) u8 {
    const base = @field(material_transparency_base, role);
    const span = @field(material_transparency_span, role);
    const transparency = @min(@field(material_ratio, role), base + span * material_transparency / 100);
    return @intFromFloat(@round(255 * (1 - transparency)));
}
fn materialAlphas(palette: Colors) [6]u8 {
    if (material_alpha_cache) |cached| {
        if (cached.transparency == material_transparency and cached.image_visible == material_visible and std.meta.eql(cached.palette, palette)) return cached.alphas;
    }
    var alphas: [6]u8 = undefined;
    inline for (material_roles, 0..) |role, index| alphas[index] = unadjustedMaterialAlpha(role);
    material_alpha_cache = .{ .palette = palette, .transparency = material_transparency, .image_visible = material_visible, .alphas = alphas };
    return alphas;
}
pub fn materialAlpha(comptime role: []const u8) u8 {
    inline for (material_roles, 0..) |candidate, index| {
        if (comptime std.mem.eql(u8, role, candidate)) return materialAlphas(baseColors())[index];
    }
    @compileError("unknown material role: " ++ role);
}

/// Final wallpaper transmission, rather than the alpha of each overlapping fill.
/// L0..L4 retain 100/80/60/40/20% of the configured transmission; L4+ caps.
pub fn layerTransmission(level: usize) f32 {
    return @as(f32, @floatFromInt(5 - @min(level, 4))) / 5;
}
pub fn layerFinalAlpha(level: usize) u8 {
    return @intFromFloat(@round(255 * (1 - material_transparency / 100 * layerTransmission(level))));
}
/// Source-over fill over the immediately preceding material level.
pub fn layerAlpha(level: usize) u8 {
    if (level == 0) return layerFinalAlpha(0);
    if (material_transparency == 0) return 255;
    return @intFromFloat(@round(255 * (1 - layerTransmission(level) / layerTransmission(level - 1))));
}
pub fn layerBackground(level: usize) ui.Color {
    return baseColors().overlay.withAlpha(layerAlpha(level));
}
/// Keep settings cards visually distinct over their shared window background
/// while the material policy retains ownership of the actual layer alpha.
pub fn settingsCard() ui.Color {
    const c = current();
    const opacity = @as(f32, @floatFromInt(layerAlpha(2))) / 255;
    // Light cards need only a quiet tonal difference. Compensating their tint
    // for transparency mixes almost half the dark ink into the surface.
    const strength = if (currentName() == .dark) @min(1, 0.12 / opacity) else 0.12;
    return ui.Color.lerp(c.overlay.withAlpha(255), c.fg_2.withAlpha(255), strength).withAlpha(c.surface_2.a);
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

/// Theme-bound native icon; asset, layout and interaction identity stay retained.
pub fn icon(cx: *ui.Cx, asset: ui.SvgAsset, comptime role: []const u8, style: ui.Style) !*ui.Node {
    const node = try ui.iconTint(cx, asset, @field(current(), role), style);
    bindInk(node, role);
    return node;
}
pub fn bindInk(node: *ui.Node, comptime role: []const u8) void {
    node.meta.per_frame.hooks.on_theme = struct {
        fn paint(n: *ui.Node, _: *const ui.ThemeTokens, _: std.mem.Allocator) void {
            const color = @field(current(), role);
            if (n.getText() != null) n.setTextColor(color);
            _ = n.setTint(color);
        }
    }.paint;
}
/// Feed retained widget overrides from the same publication as their recipes.
pub fn paintSignal(comptime Value: type, cx: *ui.Cx, scope: *ui.Scope, comptime paint: anytype, args: anytype) !*ui.Signal(Value) {
    const value = try scope.createSignal(Value, @call(.auto, paint, args));
    try scope.createEffect(.{ .value = value, .args = args, .publication = try cx.themeSignal(scope) }, struct {
        fn apply(ctx: anytype) void {
            _ = ctx.publication.get();
            ctx.value.set(@call(.auto, paint, ctx.args));
        }
    }.apply);
    return value;
}

/// Button forwards geometry/fill overrides but omits gradient and shadows.
/// Keep the V3 primary paint on the native node without replacing its control state.
pub fn stylePrimary(cx: *ui.Cx, scope: *ui.Scope, button: *ui.Node, disabled: ?*ui.Signal(bool)) !void {
    try scope.createEffect(.{ .cx = cx, .node = button, .disabled = disabled, .hovered = try ui.hooks.useHover(scope, button), .pressed = try ui.hooks.usePressed(scope, cx, button), .focused = (try ui.hooks.useFocusState(scope, cx, button)).focused, .publication = try cx.themeSignal(scope) }, struct {
        fn paint(ctx: anytype) void {
            _ = ctx.publication.get();
            const unavailable = if (ctx.disabled) |value| value.get() else if (ctx.node.behavior.interaction.a11y) |attrs| attrs.disabled else false;
            const recipe = @import("shell_styles.zig").emptyButton(true);
            const s = states();
            const pressed = ctx.pressed.get() and ctx.hovered.get();
            const hot = ctx.hovered.get() or ctx.focused.get();
            ctx.node.setStyle(ctx.cx.allocator, .gradient, if (unavailable) null else .{ .from = if (pressed) s.primary_pressed else if (hot) s.primary_hover else s.primary, .to = if (pressed) s.primary_pressed_to else if (hot) s.primary_hover_to else s.primary_to, .direction = .diagonal });
            ctx.node.setStyleInline(ctx.cx.allocator, .{
                .shadow = if (unavailable) .{ .blur = 0, .color = ui.Color.TRANSPARENT } else recipe.shadow,
                .inset_shadow = if (unavailable) .{ .blur = 0, .color = ui.Color.TRANSPARENT } else recipe.inset_shadow,
            });
        }
    }.paint);
}

/// Blur already-painted window content behind overlays, never their foreground.
/// Even when the configured background blur is zero, use 12 logical px to suppress
/// lower-layer text ghosting. This samples app content, not the desktop.
/// Quiet inline field fill, composited over its containing L0 or floating surface.
fn insetColor(c: Colors) ui.Color {
    return stateColors(c).control;
}
pub fn popupInset() ui.Color {
    return insetColor(current());
}
fn actionColor(c: Colors) ui.Color {
    return stateColors(c).action;
}
pub fn popupAction() ui.Color {
    return actionColor(current());
}
pub fn popupBorder() ui.Color {
    return ui.Color.TRANSPARENT;
}
fn selectionColor(c: Colors) ui.Color {
    return stateColors(c).selected;
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
/// Opt-in ink for this execution PATCH's enabled text on explicit final paints.
/// Callers supply only backgrounds that their own new component actually draws;
/// this never publishes a palette, changes current(), or affects widget tokens.
pub fn patchInk(ink: ui.Color, backgrounds: []const ui.Color) ui.Color {
    if (patchInkPasses(ink, backgrounds)) return ink;
    const foreground = baseColors().fg_1;
    for (1..256) |amount| {
        const candidate = ui.Color.lerp(ink, foreground, @as(f32, @floatFromInt(amount)) / 255);
        if (patchInkPasses(candidate, backgrounds)) return candidate;
    }
    return foreground;
}
fn patchInkPasses(ink: ui.Color, backgrounds: []const ui.Color) bool {
    for (backgrounds) |background| if (contrast(ink, background) < 4.5) return false;
    return true;
}
/// Compose a PATCH fill over a known opaque parent using the actual alpha8.
pub fn patchPaint(foreground: ui.Color, background: ui.Color) ui.Color {
    std.debug.assert(background.a == 255);
    var result = foreground;
    inline for (.{ "r", "g", "b" }) |channel| {
        const mixed = @as(u32, @field(foreground, channel)) * foreground.a + @as(u32, @field(background, channel)) * (255 - @as(u32, foreground.a));
        @field(result, channel) = @intCast((mixed + 127) / 255);
    }
    result.a = 255;
    return result;
}
/// Repaint retained UI-derived fills without treating terminal selection as UI chrome.
pub fn remapUiSurface(color: ui.Color, previous: Colors) ?ui.Color {
    const old_bubble = cachedBubblePaint(previous, if (previous.overlay.a == 255) 255 else 64, &previous_bubble_paint_cache);
    if (ui.Color.eql(color, old_bubble.from)) return userBubblePaint().from;
    if (ui.Color.eql(color, old_bubble.to)) return userBubblePaint().to;
    if (ui.Color.eql(color, insetColor(previous))) return popupInset();
    if (ui.Color.eql(color, actionColor(previous))) return popupAction();
    if (ui.Color.eql(color, selectionColor(previous))) return popupSelection();
    const old_states = stateColors(previous);
    const next_states = states();
    inline for (@typeInfo(StateColors).@"struct".field_names) |role|
        if (ui.Color.eql(color, @field(old_states, role))) return @field(next_states, role);
    return null;
}
/// Foregrounds retain readable ink roles when a palette aliases base/ink RGB.
pub fn remapUiInk(color: ui.Color, previous: Colors) ui.Color {
    inline for (.{ "fg_1", "fg_2", "fg_3", "accent_ink", "ok_ink", "warn_ink", "danger_ink" }) |role| {
        if (ui.Color.eql(color, @field(previous, role))) return @field(current(), role);
    }
    inline for (@typeInfo(Colors).@"struct".field_names) |role| {
        if (ui.Color.eql(color, @field(previous, role))) return @field(current(), role);
    }
    return color;
}
/// Shared outer shadow for every floating surface; palette owns its color.
pub fn floatingShadow() ui.Shadow {
    return .{ .offset_y = 8, .blur = 24, .color = current().shadow };
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
/// Settings forms own validation labels but share focus/disabled/error fills.
pub fn paintInputValidation(input: ui.widgets.input.InputResult, invalid: bool) void {
    if (input.state.has_error != invalid) {
        input.state.has_error = invalid;
        input.state.dirty = true;
        input.input_container.markRenderDirty();
    }
    if (input.input_container.behavior.interaction.a11y) |*attrs| attrs.invalid = invalid;
    input.input_container.setBorderWidth(0);
    paintInputChrome(input.input_container);
}
fn inputSelectionBackground(c: Colors) ui.Color {
    const focused_bg = stateColors(c).focus;
    for ([_]ui.Color{ c.action_accent, c.accent_ink, c.fg_1 }) |candidate| {
        const solid = candidate.withAlpha(255);
        if (contrast(solid, focused_bg) >= 1.5) return solid;
    }
    return actionForeground(focused_bg);
}
fn paintInputChrome(node: *ui.Node) void {
    const state: *ui.widgets.input.TextInputState = @ptrCast(@alignCast(node.behavior.events.event_context orelse return));
    if (state.cx_ref) |cx| if (state.tokens != cx.tokens) {
        state.tokens = cx.tokens;
        state.dirty = true;
    };
    const c = current();
    // Focus uses the theme focus fill. Text selection must
    // remain distinct, with readable ink for both built-in and imported themes.
    const selection_bg = inputSelectionBackground(c);
    const selection_fg = actionForeground(selection_bg);
    if (state.selection_bg_override == null or !ui.Color.eql(state.selection_bg_override.?, selection_bg) or
        state.selection_fg_override == null or !ui.Color.eql(state.selection_fg_override.?, selection_fg))
    {
        state.selection_bg_override = selection_bg;
        state.selection_fg_override = selection_fg;
        state.dirty = true;
    }
    const background = if (state.disabled) states().disabled else if (state.has_error) (if (state.focused) states().error_focus else states().tag_danger) else if (state.focused) states().focus else popupInset();
    if (!ui.Color.eql(node.getBackground(), background)) node.setBackground(background);
    node.setBorderColor(ui.Color.TRANSPARENT);
    const outline = node.style.outline();
    if (outline != null and outline.?.width != 0) node.setStyleInline(state.allocator, .{ .outline = .{ .width = 0, .color = ui.Color.TRANSPARENT } });
}

test "input text selection stays visible and follows retained theme changes" {
    const previous = currentName();
    defer select(previous);
    const cx = try ui.Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    const scope = try ui.Scope.init(std.testing.allocator, null, cx.owner);
    defer scope.dispose();
    cx.setViewport(320, 80);
    const input = try ui.widgets.Input(.{ .value = "https://172.20.3.225", .width = 280 }).mountResult(scope, cx);
    styleInput(input);
    cx.root = input.node;
    input.state.focused = true;
    input.state.selection_anchor = 8;
    input.state.cursor_pos = 13;
    var registry = try @import("../config/theme_registry.zig").Registry.init(std.testing.allocator);
    defer registry.deinit();
    for (registry.records.items) |record| {
        errdefer std.debug.print("input selection theme: {s}\n", .{record.id});
        selectTokens(record.ui_tokens);
        cx.setTheme(widgetTheme(currentName()));
        cx.layout();
        _ = cx.render();
        const spans = input.state.text_display_node.?.getText().?.spans;
        try std.testing.expectEqual(@as(usize, 1), spans.len);
        try std.testing.expectEqual(@as(u32, 8), spans[0].start);
        try std.testing.expectEqual(@as(u32, 13), spans[0].end);
        try std.testing.expectEqual(inputSelectionBackground(current()), spans[0].bg_color.?);
        try std.testing.expect(contrast(spans[0].bg_color.?, input.input_container.getBackground()) >= 1.5);
        try std.testing.expect(contrast(spans[0].bg_color.?, spans[0].color.?) >= 4.5);
    }
    // Imported middle-luminance accents need dark ink rather than fixed white.
    var imported = @import("../config/theme_registry.zig").builtinTokens("light");
    imported.action_accent = 0x808080ff;
    selectTokens(imported);
    cx.setTheme(widgetTheme(currentName()));
    cx.layout();
    _ = cx.render();
    const span = input.state.text_display_node.?.getText().?.spans[0];
    try std.testing.expect(contrast(span.bg_color.?, span.color.?) >= 4.5);
    try std.testing.expectEqual(actionForeground(current().action_accent), span.color.?);
    // An imported action color can exactly match the field's focus surface.
    const focused_bg = states().focus;
    imported.action_accent = (@as(u32, focused_bg.r) << 24) | (@as(u32, focused_bg.g) << 16) | (@as(u32, focused_bg.b) << 8) | 255;
    selectTokens(imported);
    cx.setTheme(widgetTheme(currentName()));
    cx.layout();
    _ = cx.render();
    const fallback_span = input.state.text_display_node.?.getText().?.spans[0];
    try std.testing.expect(contrast(fallback_span.bg_color.?, input.input_container.getBackground()) >= 1.5);
    try std.testing.expect(contrast(fallback_span.bg_color.?, fallback_span.color.?) >= 4.5);
}
pub fn overlayGlass() ui.GlassParams {
    return .{ .backdrop_blur = @max(12, material_blur), .capture_current_target = false, .glass_intensity = 0, .specular_opacity = 0, .refraction_level = 0, .warp_gain = 0 };
}

test "global material parameters and actual depth follow the slider at endpoints" {
    const saved = materialParameters();
    defer _ = setMaterialParameters(saved.transparency, saved.blur);
    for ([_]f32{ 0, 25, 75, 100 }, [_]u8{ 255, 223, 159, 128 }) |percent, overlay_alpha| {
        _ = setMaterialParameters(percent, percent * 0.5);
        try std.testing.expectEqual(overlay_alpha, unadjustedMaterialAlpha("overlay"));
        try std.testing.expectEqual(overlay_alpha, current().overlay.a);
        try std.testing.expectEqual(@as(u8, if (percent == 0) 255 else 51), layerAlpha(1));
        try std.testing.expectEqual(@as(u8, @intFromFloat(@round(255 * (1 - percent / 100)))), current().surface_1.a);
        try std.testing.expect(current().surface_2.a < current().well.a);
        try std.testing.expect(current().well.a < current().overlay.a);
        try std.testing.expectEqual(@max(12, percent * 0.5), overlayGlass().backdrop_blur);
        try std.testing.expectEqual(current().overlay, widgetTheme(currentName()).tokens.color.tooltip_bg);
    }
    _ = setMaterialParameters(75, 0);
    try std.testing.expectEqual(@as(f32, 12), overlayGlass().backdrop_blur);
    try std.testing.expectEqual(@as(u8, 159), current().overlay.a);
}

/// A successfully loaded image enables the chrome readability floor. Floating
/// overlays always guard arbitrary app/terminal RGB, including without an image.
/// Foreground inks and the underlying no-image material curves stay unchanged.
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
/// Imported palettes and translucent bubbles can reach middle luminance.
/// Keep readable white actions; pure black covers the middle-luminance gap
/// that near-black leaves below 4.5:1.
pub fn actionForeground(background: ui.Color) ui.Color {
    return if (contrast(background, ui.Color.WHITE) >= 4.5) ui.Color.WHITE else ui.Color.BLACK;
}
/// One derived paint owns both the translucent user-bubble gradient and its ink.
pub const BubblePaint = struct { from: ui.Color, to: ui.Color, foreground: ui.Color };
const BubblePaintCache = struct { palette: Colors, alpha: u8, paint: BubblePaint };
var bubble_paint_cache: ?BubblePaintCache = null;
var previous_bubble_paint_cache: ?BubblePaintCache = null;
const bubble_min_contrast: f64 = 4.85;

pub fn userBubblePaint() BubblePaint {
    return cachedBubblePaint(baseColors(), layerAlpha(2), &bubble_paint_cache);
}
fn cachedBubblePaint(palette: Colors, alpha: u8, cache: *?BubblePaintCache) BubblePaint {
    if (cache.*) |cached| {
        if (cached.alpha == alpha and std.meta.eql(cached.palette, palette)) return cached.paint;
    }
    const paint = deriveBubblePaint(palette, alpha);
    cache.* = .{ .palette = palette, .alpha = alpha, .paint = paint };
    return paint;
}
fn bubbleContrast(ink: ui.Color, from: ui.Color, to: ui.Color, parent: ui.Color) f64 {
    var minimum: f64 = std.math.inf(f64);
    // sRGB interpolation can have an interior luminance minimum. Sample every
    // 8-bit step, using the same quantized alpha as the actual gradient paint.
    for (0..256) |step| {
        const color = ui.Color.lerp(from, to, @as(f32, @floatFromInt(step)) / 255);
        minimum = @min(minimum, contrast(ink, patchPaint(color, parent)));
    }
    return minimum;
}
fn deriveBubblePaint(palette: Colors, alpha: u8) BubblePaint {
    const parent = palette.overlay.withAlpha(255);
    const from = palette.action_accent.withAlpha(alpha);
    const to = palette.action_accent_2.withAlpha(alpha);
    const white = bubbleContrast(ui.Color.WHITE, from, to, parent);
    const black = bubbleContrast(ui.Color.BLACK, from, to, parent);
    const ink = if (white >= black) ui.Color.WHITE else ui.Color.BLACK;
    if (@max(white, black) >= bubble_min_contrast) return .{ .from = from, .to = to, .foreground = ink };
    // Some gradients cross the interval where neither single ink reaches the
    // target. Move both stops toward the same opposite pole, preserving alpha.
    const pole = if (ui.Color.eql(ink, ui.Color.WHITE)) ui.Color.BLACK else ui.Color.WHITE;
    var low: u16 = 1;
    var high: u16 = 255;
    while (low < high) {
        const middle = low + (high - low) / 2;
        const amount = @as(f32, @floatFromInt(middle)) / 255;
        const adjusted_from = ui.Color.lerp(from, pole, amount).withAlpha(alpha);
        const adjusted_to = ui.Color.lerp(to, pole, amount).withAlpha(alpha);
        if (bubbleContrast(ink, adjusted_from, adjusted_to, parent) >= bubble_min_contrast) high = middle else low = middle + 1;
    }
    const amount = @as(f32, @floatFromInt(low)) / 255;
    return .{ .from = ui.Color.lerp(from, pole, amount).withAlpha(alpha), .to = ui.Color.lerp(to, pole, amount).withAlpha(alpha), .foreground = ink };
}
/// An unchecked control stays neutral, including on pale single-hue palettes.
pub fn switchTrackOff() ui.Color {
    return states().choice_off;
}
pub fn choiceBackground(checked: bool, disabled: bool) ui.Color {
    const s = states();
    return if (disabled) (if (checked) s.choice_disabled_on else s.choice_disabled_off) else if (checked) s.choice_on else s.choice_off;
}
pub fn choiceThumb(checked: bool, disabled: bool) ui.Color {
    const s = states();
    return if (disabled) (if (checked) s.choice_disabled_ink else s.choice_disabled_thumb_off) else if (checked) s.choice_ink else s.choice_thumb_off;
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
    const alphas = materialAlphas(base);
    inline for (material_roles, 0..) |field, index| {
        const color = &@field(value, field);
        color.a = alphas[index];
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
    const s = stateColors(c);
    t.bg_base = c.app;
    t.bg_primary = c.surface_1;
    t.bg_secondary = c.surface_2;
    t.bg_tertiary = c.overlay;
    t.bg_hover = s.hover;
    t.bg_active = s.pressed;
    t.bg_focus = s.focus;
    t.bg_inset = c.well;
    t.fg_primary = c.fg_1;
    t.fg_secondary = c.fg_2;
    t.fg_tertiary = s.muted_ink;
    t.fg_disabled = c.fg_3;
    // Zenit uses accent for checked checkbox/radio/switch fills. V3 uses --primary.
    t.accent = c.action_accent;
    t.accent_hover = s.primary_hover;
    t.accent_muted = selectionColor(c);
    t.accent_subtle = selectionColor(c);
    t.border = ui.Color.TRANSPARENT;
    t.border_strong = ui.Color.TRANSPARENT;
    t.border_focus = ui.Color.TRANSPARENT;
    // Focus uses its theme state fill and caret, without a border or focus ring.
    t.focus_ring = ui.Color.TRANSPARENT;
    t.fg_inverse = actionForeground(c.action_accent);
    t.success = c.ok_ink;
    t.success_subtle = s.feedback_ok;
    t.warning_subtle = s.feedback_warn;
    t.danger_subtle = s.feedback_danger;
    t.danger_hover = c.action_danger;
    t.info = c.accent_ink;
    t.info_subtle = s.feedback_info;
    t.warning = c.warn_ink;
    // Widget danger is text/icon ink. Filled app actions use action_danger explicitly.
    t.danger = c.danger_ink;
    t.selection_bg = selectionColor(c);
    t.button_primary_bg = c.action_accent;
    t.button_primary_fg = actionForeground(c.action_accent);
    t.button_primary_hover = s.primary_hover;
    t.button_primary_pressed = s.primary_pressed;
    t.button_danger_bg = s.danger;
    t.button_danger_fg = s.danger_ink;
    t.button_danger_hover = s.danger_hover;
    t.button_danger_pressed = s.danger_pressed;
    t.button_secondary_bg = actionColor(c);
    t.button_secondary_fg = if (dark) c.fg_2 else c.fg_1;
    t.input_bg = insetColor(c);
    t.input_border = ui.Color.TRANSPARENT;
    t.checkbox_bg = s.choice_off;
    t.checkbox_fg = s.choice_ink;
    t.checkbox_disabled_fg = s.choice_disabled_ink;
    t.switch_thumb_on = s.choice_ink;
    t.switch_disabled_thumb_off = s.choice_disabled_thumb_off;
    t.range_track = s.range_track;
    t.range_fill = s.range_fill;
    t.range_hover = s.range_hover;
    t.range_drag = s.range_drag;
    t.range_thumb = s.range_thumb;
    t.range_disabled = s.range_disabled;
    t.range_disabled_thumb = s.range_disabled_thumb;
    t.progress_success = s.progress_ok;
    t.progress_warning = s.progress_warn;
    t.progress_error = s.progress_danger;
    t.checkbox_border = ui.Color.TRANSPARENT;
    t.checkbox_disabled_bg = s.choice_disabled_off;
    t.checkbox_disabled_border = ui.Color.TRANSPARENT;
    t.checkbox_disabled_checked_bg = s.choice_disabled_on;
    t.switch_track_on = s.choice_on;
    t.switch_thumb = s.choice_thumb_off;
    t.switch_track_off = s.choice_off;
    t.list_hover_bg = s.hover;
    t.list_selection_bg = selectionColor(c);
    t.list_selection_hover_bg = s.selected_hover;
    t.table_header_bg = c.surface_2;
    t.separator = ui.Color.TRANSPARENT;
    t.tooltip_bg = c.overlay;
    t.tooltip_fg = c.fg_1;
    return value;
}

test "image readability floor preserves no-image material curves and palette inks" {
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
        const with_image = current();
        try std.testing.expectEqual(base, baseColors());
        try std.testing.expectEqual(@as(u8, 0), no_image.app.a);
        try std.testing.expectEqual(@as(u8, 0), no_image.terminal.a);
        inline for (.{ "surface_1", "surface_2", "well", "overlay", "hover", "tab_on" }) |field| {
            var expected = @field(base, field);
            expected.a = if (comptime std.mem.eql(u8, field, "overlay")) no_image.overlay.a else unadjustedMaterialAlpha(field);
            try std.testing.expectEqual(expected, @field(no_image, field));
            try std.testing.expect(@field(with_image, field).a >= expected.a);
            try std.testing.expectEqual(@field(base, field), @field(with_image, field).withAlpha(255));
        }
        inline for (.{ "fg_1", "fg_2", "fg_3", "accent", "accent_ink", "selection", "border", "well_border" }) |field| {
            try std.testing.expectEqual(@field(base, field), @field(no_image, field));
            try std.testing.expectEqual(@field(base, field), @field(with_image, field));
        }
        const widget = widgetTheme(name).tokens.color;
        try std.testing.expectEqual(with_image.surface_1, widget.bg_primary);
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

test "theme state contract covers every builtin and matches the editable design palette" {
    const previous = currentName();
    defer select(previous);
    const reference = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, "docs/UI_V3/theme-states.json", std.testing.allocator, .limited(256 * 1024));
    defer std.testing.allocator.free(reference);
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, reference, .{});
    defer parsed.deinit();
    const themes = parsed.value.object.get("themes").?.object;
    const contract = @import("theme_states.zig");
    for (@import("../config/theme_presets.zig").ids) |id| {
        errdefer std.debug.print("theme state contract: {s}\n", .{id});
        selectTokens(@import("../config/theme_registry.zig").builtinTokens(id));
        const s = states();
        const c = baseColors();
        const expected = themes.get(id).?.object;
        inline for (@typeInfo(StateColors).@"struct".field_names) |role| {
            const value = expected.get(role).?.string;
            try std.testing.expectEqual(hex(try std.fmt.parseInt(u24, value[1..], 16)), @field(s, role).withAlpha(255));
        }
        inline for (contract.material_roles) |mapping|
            try std.testing.expectEqual(@field(current(), mapping[1]).a, @field(s, mapping[0]).a);
        const pairs = [_][2]ui.Color{ .{ s.hover, s.action }, .{ s.pressed, s.hover }, .{ s.selected_hover, s.selected }, .{ s.disabled, s.control } };
        for (pairs) |pair| try std.testing.expect(contrast(pair[0], pair[1]) >= contract.state_min);
        for ([_][2]ui.Color{ .{ s.focus, s.control }, .{ s.drop_target, s.selected }, .{ s.error_focus, s.tag_danger } }) |pair|
            try std.testing.expect(contrast(pair[0], pair[1]) >= contract.focus_min);
        for ([_]ui.Color{ s.primary, s.primary_to, s.primary_hover, s.primary_hover_to, s.primary_pressed, s.primary_pressed_to }) |background|
            try std.testing.expect(contrast(background, s.primary_ink) >= contract.text_min);
        for ([_]ui.Color{ s.danger, s.danger_hover, s.danger_pressed }) |background|
            try std.testing.expect(contrast(background, s.danger_ink) >= contract.text_min);
        for ([_]ui.Color{ s.control, s.hover, s.pressed, s.focus, s.selected, s.selected_hover, s.drop_target }) |background|
            for ([_]ui.Color{ c.fg_1, c.fg_2, s.muted_ink }) |ink|
                try std.testing.expect(contrast(background, ink) >= contract.text_min);
        for ([_][2]ui.Color{ .{ s.tag_ok, c.ok_ink }, .{ s.tag_warn, c.warn_ink }, .{ s.tag_danger, c.danger_ink }, .{ s.error_focus, c.danger_ink } }) |pair|
            try std.testing.expect(contrast(pair[0], pair[1]) >= contract.text_min);
        for ([_][2]ui.Color{
            .{ s.choice_on, s.choice_ink },                          .{ s.choice_disabled_on, s.choice_disabled_ink },
            .{ s.choice_disabled_off, s.choice_disabled_thumb_off }, .{ s.range_fill, s.range_thumb },
            .{ s.range_disabled, s.range_disabled_thumb },           .{ s.feedback_info, c.accent_ink },
            .{ s.feedback_ok, c.ok_ink },                            .{ s.feedback_warn, c.warn_ink },
            .{ s.feedback_danger, c.danger_ink },                    .{ s.search_match, s.search_match_ink },
            .{ s.search_current, s.search_current_ink },
        }) |pair| try std.testing.expect(contrast(pair[0], pair[1]) >= contract.text_min);
        for ([_]ui.Color{ s.range_fill, s.range_hover, s.range_drag, s.range_disabled, s.progress_ok, s.progress_warn, s.progress_danger }) |fill|
            try std.testing.expect(contrast(fill, s.range_track) >= contract.graphic_min);
        try std.testing.expect(contrast(s.choice_thumb_off, s.choice_off) >= contract.graphic_min);
        try std.testing.expect(contrast(s.choice_on, s.choice_off) >= 1.5);
        try std.testing.expect(contrast(s.choice_disabled_on, s.choice_disabled_off) >= 1.5);
        try std.testing.expect(contrast(s.range_hover, s.range_fill) >= contract.state_min);
        try std.testing.expect(contrast(s.range_drag, s.range_hover) >= contract.state_min);
        for ([_]ui.Color{ s.range_hover, s.range_drag }) |edge|
            try std.testing.expect(contrast(edge, s.range_thumb) >= contract.graphic_min);
        for ([_]ui.Color{ s.feedback_info, s.feedback_ok, s.feedback_warn, s.feedback_danger }) |background|
            for ([_]ui.Color{ c.fg_1, c.fg_2 }) |ink|
                try std.testing.expect(contrast(background, ink) >= contract.text_min);
        try std.testing.expect(contrast(s.search_match, c.terminal) >= 1.5);
        try std.testing.expect(contrast(s.search_current, c.terminal) >= contract.graphic_min);
        try std.testing.expect(contrast(s.search_current, s.search_match) >= contract.graphic_min);
    }
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
        try std.testing.expectEqual(states().choice_disabled_off, widget.checkbox_disabled_bg);
        try std.testing.expectEqual(popupInset(), widget.input_bg);
        try std.testing.expectEqual(popupSelection(), widget.list_selection_bg);
        try std.testing.expectEqual(states().pressed, widget.bg_active);
        if (!std.mem.eql(u8, id, "dark") and !std.mem.eql(u8, id, "light") and !std.mem.eql(u8, id, "sauber") and !std.mem.eql(u8, id, "reference-light"))
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
            try std.testing.expectEqual(c.well.a, tokens.input_bg.a);
            try std.testing.expectEqual(c.surface_2.a, tokens.button_secondary_bg.a);
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

test "all builtin auxiliary inks remain readable across material and interaction surfaces" {
    const previous = applied_colors;
    const parameters = materialParameters();
    defer {
        applied_colors = previous;
        _ = setMaterialParameters(parameters.transparency, parameters.blur);
        refreshWidgets();
    }
    inline for (@import("../config/theme_presets.zig").ids) |id| {
        selectTokens(@import("../config/theme_registry.zig").builtinTokens(id));
        for ([_]f32{ 0, 50, 100 }) |transparency| {
            _ = setMaterialParameters(transparency, 0);
            const c = current();
            const parent = baseColors().app.withAlpha(255);
            const backgrounds = [_]ui.Color{
                parent,
                c.overlay.withAlpha(255),
                patchPaint(c.surface_1, parent),
                patchPaint(c.surface_2, parent),
                patchPaint(c.well, parent),
                patchPaint(c.overlay, parent),
                patchPaint(c.hover, parent),
                patchPaint(c.tab_on, parent),
                popupInset(),
                popupSelection(),
                popupAction(),
            };
            // fg_3 is readable helper text, metadata and placeholders, including
            // focused inputs. Disabled widgets retain their separate interaction
            // state/paint; readability is never obtained by relabelling content.
            for (backgrounds) |background| {
                try std.testing.expect(contrast(c.fg_3, background) >= 4.5);
                try std.testing.expect(contrast(c.fg_2, background) >= 5.4);
                try std.testing.expect(contrast(c.fg_1, background) >= 6.2);
                try std.testing.expect(contrast(c.fg_1, background) > contrast(c.fg_2, background));
                try std.testing.expect(contrast(c.fg_2, background) > contrast(c.fg_3, background));
            }
            try std.testing.expect(!ui.Color.eql(c.fg_3, c.fg_2));
            try std.testing.expect(!ui.Color.eql(c.fg_2, c.fg_1));
        }
    }
}

test "builtin terminal selection preserves readable default ink through RGBA composites" {
    const previous = applied_colors;
    const visible = material_visible;
    const parameters = materialParameters();
    const cache = material_alpha_cache;
    defer {
        applied_colors = previous;
        material_visible = visible;
        _ = setMaterialParameters(parameters.transparency, parameters.blur);
        material_alpha_cache = cache;
        refreshWidgets();
    }
    for (@import("../config/theme_presets.zig").ids) |id| {
        selectTokens(@import("../config/theme_registry.zig").builtinTokens(id));
        const terminal = @import("../config/theme_presets.zig").terminalDefaults(id).?;
        const foreground = tokenColor(terminal.foreground);
        const selection = tokenColor(terminal.selection);
        for ([_]bool{ false, true }) |image| {
            _ = setMaterialVisible(image);
            for ([_]f32{ 0, 50, 100 }) |transparency| {
                // User-controlled shell transparency may expose arbitrary image RGB.
                if (image and transparency > 0) continue;
                _ = setMaterialParameters(transparency, 0);
                const palette = baseColors();
                const c = current();
                for ([_]u8{ 0, 64, 128, 192, 255 }) |gray| {
                    const pixel = ui.Color.rgba(gray, gray, gray, 255);
                    const parent = if (image) patchPaint(palette.app.withAlpha(@intFromFloat(@round((100 - transparency) * 255 / 100))), pixel) else palette.app;
                    const background = patchPaint(c.surface_1, parent);
                    // Selection alpha is part of the palette, including the
                    // translucent product Dark/Light selections.
                    const selected_contrast = contrast(foreground, patchPaint(selection, background));
                    if (selected_contrast < 4.5) std.debug.print("selection contrast: {s}, image={}, T={d}, gray={d}: {d}\n", .{ id, image, transparency, gray, selected_contrast });
                    try std.testing.expect(selected_contrast >= 4.5);
                }
            }
        }
    }
}

test "material depths stay exact across palette transparency and image visibility" {
    const previous = applied_colors;
    const visible = material_visible;
    const parameters = materialParameters();
    const cache = material_alpha_cache;
    defer {
        applied_colors = previous;
        material_visible = visible;
        _ = setMaterialParameters(parameters.transparency, parameters.blur);
        material_alpha_cache = cache;
        refreshWidgets();
    }
    _ = setMaterialVisible(true);
    for (@import("../config/theme_presets.zig").ids) |id| {
        selectTokens(@import("../config/theme_registry.zig").builtinTokens(id));
        for ([_]f32{ 0, 50, 100 }) |transparency| {
            _ = setMaterialParameters(transparency, 0);
            const c = current();
            inline for (material_roles) |role| try std.testing.expectEqual(unadjustedMaterialAlpha(role), @field(c, role).a);
            for (0..5) |level| {
                const expected = 1 - transparency / 100 * layerTransmission(level);
                try std.testing.expectEqual(@as(u8, @intFromFloat(@round(255 * expected))), layerFinalAlpha(level));
                if (level > 0 and transparency > 0) {
                    const under = 1 - transparency / 100 * layerTransmission(level - 1);
                    const own = @as(f32, @floatFromInt(layerAlpha(level))) / 255;
                    try std.testing.expectApproxEqAbs(expected, under + (1 - under) * own, 0.002);
                }
            }
            _ = setMaterialVisible(false);
            inline for (material_roles) |role| try std.testing.expectEqual(unadjustedMaterialAlpha(role), materialAlpha(role));
            _ = setMaterialVisible(true);
            try std.testing.expectEqual(c, current());
        }
    }
    selectTokens(@import("../config/theme_registry.zig").builtinTokens("dark"));
    _ = setMaterialParameters(0, 0);
    const first = current();
    selectTokens(@import("../config/theme_registry.zig").builtinTokens("light"));
    const second = current();
    try std.testing.expect(!std.meta.eql(first, second));
    selectTokens(@import("../config/theme_registry.zig").builtinTokens("dark"));
    try std.testing.expectEqual(first, current());
    _ = setMaterialParameters(50, 0);
    try std.testing.expect(first.surface_1.a != current().surface_1.a);
}

test "execution PATCH opt-in ink covers actual approval impact and history warning paints without publication" {
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
        for ([_]f32{ 0, 25, 50, 75, 100 }) |transparency| {
            _ = setMaterialParameters(transparency, 0);
            const palette = baseColors();
            const unmodified = current();
            const widgets = widgetTheme(currentName()).*;
            const approval_styles = @import("ai_tool_approval_styles.zig");
            const impact = patchPaint(approval_styles.impactNotice(widgetTheme(currentName())).background.?, patchPaint(approval_styles.panel(widgetTheme(currentName())).background.?, unmodified.overlay.withAlpha(255)));
            const impact_ink = patchInk(unmodified.warn_ink, &.{impact});
            try std.testing.expect(contrast(impact_ink, impact) >= 4.5);
            if (contrast(unmodified.warn_ink, impact) >= 4.5) try std.testing.expectEqual(unmodified.warn_ink, impact_ink);
            const veil = palette.app.withAlpha(@intFromFloat(@round((100 - transparency) * 255 / 100)));
            const history_backgrounds = [_]ui.Color{
                patchPaint(unmodified.overlay, palette.app.withAlpha(255)),
                patchPaint(unmodified.overlay, patchPaint(veil, palette.app.withAlpha(255))),
            };
            const history_ink = patchInk(unmodified.warn_ink, &history_backgrounds);
            for (history_backgrounds) |background| try std.testing.expect(contrast(history_ink, background) >= 4.5);
            const action_ink = patchInk(unmodified.accent_ink, &.{popupAction()});
            try std.testing.expect(contrast(action_ink, popupAction()) >= 4.5);
            if (contrast(unmodified.accent_ink, popupAction()) >= 4.5) try std.testing.expectEqual(unmodified.accent_ink, action_ink);
            try std.testing.expectEqual(palette, baseColors());
            try std.testing.expectEqual(unmodified, current());
            try std.testing.expect(std.meta.eql(widgets, widgetTheme(currentName()).*));
        }
    }
}

test "floating material preserves requested alpha and semantic inks without an image" {
    const previous = applied_colors;
    const visible = material_visible;
    const parameters = materialParameters();
    defer {
        applied_colors = previous;
        material_visible = visible;
        _ = setMaterialParameters(parameters.transparency, parameters.blur);
        refreshWidgets();
    }
    _ = setMaterialVisible(false);
    for (@import("../config/theme_presets.zig").ids) |id| {
        selectTokens(@import("../config/theme_registry.zig").builtinTokens(id));
        for ([_]f32{ 0, 50, 100 }) |transparency| {
            _ = setMaterialParameters(transparency, 0);
            const c = current();
            try std.testing.expectEqual(materialAlpha("overlay"), c.overlay.a);
            inline for (.{ "fg_1", "fg_2", "fg_3", "accent_ink", "ok_ink", "warn_ink", "danger_ink" }) |ink|
                try std.testing.expectEqual(@field(baseColors(), ink), @field(c, ink));
            const paint = userBubblePaint();
            try std.testing.expect(bubbleContrast(paint.foreground, paint.from, paint.to, baseColors().overlay.withAlpha(255)) >= bubble_min_contrast);
        }
    }
}

test "filled action foreground remains readable on real translucent bubble midtones" {
    // Retina paint samples from Paper, Sand and Ice at T=0. Near-black #101014
    // falls below 4.5 here even when it wins over white.
    for ([_]ui.Color{ hex(0x738149), hex(0xa17140), hex(0x3e81a7) }) |background| {
        try std.testing.expect(contrast(background, actionForeground(background)) >= 4.5);
    }
}

test "filled action gradient endpoint and Ice inset keep material contrast margin" {
    const registry = @import("../config/theme_registry.zig");
    const sauber = tokenColors(registry.builtinTokens("sauber"));
    // Worst L1 alpha at T=100; both gradient stops must support the same white ink.
    for ([_]ui.Color{ sauber.action_accent, sauber.action_accent_2 }) |stop| {
        const painted = patchPaint(stop.withAlpha(214), sauber.overlay.withAlpha(255));
        try std.testing.expect(contrast(painted, ui.Color.WHITE) >= 4.5);
    }
    const ice = tokenColors(registry.builtinTokens("ice"));
    try std.testing.expect(contrast(insetColor(ice), ice.overlay.withAlpha(255)) >= 1.12);
}

test "user bubble paints cover the full gradient and cache every palette and alpha" {
    const registry = @import("../config/theme_registry.zig");
    inline for (@import("../config/theme_presets.zig").ids) |id| {
        const palette = tokenColors(registry.builtinTokens(id));
        for ([_]u8{ 245, 230, 214, 92, 66, 41 }) |alpha| {
            const paint = deriveBubblePaint(palette, alpha);
            try std.testing.expectEqual(alpha, paint.from.a);
            try std.testing.expectEqual(alpha, paint.to.a);
            try std.testing.expect(bubbleContrast(paint.foreground, paint.from, paint.to, palette.overlay.withAlpha(255)) >= bubble_min_contrast);
        }
    }
    const original = applied_colors;
    const original_cache = bubble_paint_cache;
    const parameters = materialParameters();
    defer {
        applied_colors = original;
        bubble_paint_cache = original_cache;
        _ = setMaterialParameters(parameters.transparency, parameters.blur);
        refreshWidgets();
    }
    const first = tokenColors(registry.builtinTokens("dark"));
    const second = tokenColors(registry.builtinTokens("gruvbox-light"));
    applied_colors = first;
    _ = setMaterialParameters(0, 0);
    const a = userBubblePaint();
    applied_colors = second;
    const b = userBubblePaint();
    try std.testing.expect(!std.meta.eql(a, b));
    _ = setMaterialParameters(100, 0);
    const c = userBubblePaint();
    try std.testing.expectEqual(layerAlpha(2), c.from.a);
    try std.testing.expect(c.from.a < a.from.a);
    try std.testing.expect(!std.meta.eql(b, c));
}

test "common theme controls retain checked disabled and range colors across builtin publications" {
    const old = currentName();
    defer select(old);
    select(.dark);
    const cx = try ui.Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    cx.setViewport(600, 600);
    const scope = try ui.Scope.init(std.testing.allocator, null, cx.owner);
    defer scope.dispose();
    const publication = try cx.bindState(@import("shell_styles.zig").ThemePublication, .{});
    publication.publish(cx, widgetTheme(currentName()));
    cx.root = try ui.box(cx, .{ .width = .fill(), .height = .fill(), .direction = .column }, .{});
    const disabled = try scope.createSignal(bool, false);
    const cb = try ui.widgets.Checkbox(.{ .checked = true, .disabled = disabled }).mount(scope, cx);
    const mixed = try ui.widgets.Checkbox(.{ .indeterminate = true, .disabled = disabled }).mount(scope, cx);
    const radio = try ui.widgets.Radio(.{ .checked = true, .disabled = disabled }).mount(scope, cx);
    const on = try ui.widgets.Switch(.{ .checked = true, .disabled = disabled }).mount(scope, cx);
    const off = try ui.widgets.Switch(.{ .checked = false, .disabled = disabled }).mount(scope, cx);
    const slider = try ui.widgets.Slider(.{ .value = 60, .disabled = disabled }).mount(scope, cx);
    const progress = try ui.widgets.Progress(.{ .value = 60 }).mount(scope, cx);
    const alert = try ui.widgets.Alert(.{ .variant = .warning, .message = "Review" }).mount(scope, cx);
    for ([_]*ui.Node{ cb, mixed, radio, on, off, slider.wrapper, progress, alert }) |node| try cx.root.?.appendChild(cx.allocator, node);
    const slider_area = slider.wrapper.children.items[0];
    const track = slider_area.children.items[0];
    const thumb = slider_area.children.items[1];
    for (@import("../config/theme_presets.zig").ids) |id| {
        errdefer std.debug.print("common theme controls: {s}\n", .{id});
        selectTokens(@import("../config/theme_registry.zig").builtinTokens(id));
        publication.publish(cx, widgetTheme(currentName()));
        const s = states();
        for ([_]bool{ false, true }) |dis| {
            disabled.set(dis);
            for (0..18) |_| {
                cx.frame_count += 1;
                cx.frame_time_ms += 16;
                cx.bindFrameClock();
                _ = cx.render();
            }
            const fill = if (dis) s.choice_disabled_on else s.choice_on;
            const ink = if (dis) s.choice_disabled_ink else s.choice_ink;
            for ([_]*ui.Node{ cb, mixed, radio, on }) |control| {
                try std.testing.expectEqual(fill, control.children.items[0].getBackground());
                try std.testing.expectEqual(@as(f32, 1), control.getOpacity());
            }
            try std.testing.expectEqual(ink, cb.children.items[0].children.items[0].getIcon().?.tint);
            try std.testing.expectEqual(ink, mixed.children.items[0].children.items[1].children.items[0].getIcon().?.tint);
            try std.testing.expectEqual(ink, radio.children.items[0].children.items[0].getBackground());
            try std.testing.expectEqual(ink, on.children.items[0].children.items[0].getBackground());
            try std.testing.expectEqual(if (dis) s.choice_disabled_off else s.choice_off, off.children.items[0].getBackground());
            try std.testing.expectEqual(if (dis) s.choice_disabled_thumb_off else s.choice_thumb_off, off.children.items[0].children.items[0].getBackground());
            try std.testing.expectEqual(s.range_track, track.getBackground());
            try std.testing.expectEqual(if (dis) s.range_disabled else s.range_fill, track.children.items[0].getBackground());
            try std.testing.expectEqual(if (dis) s.range_disabled_thumb else s.range_thumb, thumb.getBackground());
            try std.testing.expectEqual(s.range_track, progress.children.items[0].getBackground());
            try std.testing.expectEqual(s.feedback_warn, alert.getBackground());
            try std.testing.expectEqual(@as(f32, 60), slider.value.?.peek());
        }
    }
}
