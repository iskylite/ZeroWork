//! Test-only snapshot of the original default values for numeric parity.
//! Never imported by the UI, token parser, emitter or generated provider.
const values = @import("zenit_style_values");
const Color = values.Color;
const Shadow = values.Shadow;

// Layer 1, Base Color Palettes (raw color steps, theme-invariant)

/// Olive palette (brand primary).
pub const olive = struct {
    pub const _50 = Color.hex(0xF5F7F4);
    pub const _100 = Color.hex(0xE8EDE6);
    pub const _200 = Color.hex(0xD1DBCD);
    pub const _300 = Color.hex(0xA8BDA0);
    pub const _400 = Color.hex(0x7A9A70);
    pub const _500 = Color.hex(0x4D6545);
    pub const _600 = Color.hex(0x4A6741);
    pub const _700 = Color.hex(0x3D5636);
    pub const _800 = Color.hex(0x374F31);
    pub const _900 = Color.hex(0x2A3D25);
};

/// Neutral grayscale.
pub const neutral = struct {
    pub const _50 = Color.hex(0xFAFAFA);
    pub const _100 = Color.hex(0xF5F5F5);
    pub const _200 = Color.hex(0xEFEFEF);
    pub const _300 = Color.hex(0xE5E5E5);
    pub const _400 = Color.hex(0xD4D4D4);
    pub const _500 = Color.hex(0x9B9B9B);
    pub const _600 = Color.hex(0x787878);
    pub const _700 = Color.hex(0x6B6B6B);
    pub const _750 = Color.hex(0x2A2A2A);
    pub const _800 = Color.hex(0x1A1A1A);
    pub const _900 = Color.hex(0x0F0F0F);
};

/// Sage palette.
pub const sage = struct {
    pub const _50 = Color.hex(0xF2F5F5);
    pub const _100 = Color.hex(0xE8EDED);
    pub const _200 = Color.hex(0xCEDADA);
    pub const _300 = Color.hex(0x9FB5B5);
    pub const _400 = Color.hex(0x7A9494);
    pub const _500 = Color.hex(0x5A7272);
    pub const _600 = Color.hex(0x4D6262);
    pub const _700 = Color.hex(0x3F5050);
};

/// Earth palette.
pub const earth = struct {
    pub const _50 = Color.hex(0xFAF8F4);
    pub const _100 = Color.hex(0xF4EFEA);
    pub const _200 = Color.hex(0xE8DFD4);
    pub const _300 = Color.hex(0xCCBA9E);
    pub const _400 = Color.hex(0xA89070);
    pub const _500 = Color.hex(0x7D6A4A);
    pub const _600 = Color.hex(0x6B5A3F);
    pub const _700 = Color.hex(0x564832);
};

/// Rose palette.
pub const rose = struct {
    pub const _50 = Color.hex(0xFAF5F5);
    pub const _100 = Color.hex(0xF6F0F0);
    pub const _200 = Color.hex(0xEBDCDC);
    pub const _300 = Color.hex(0xD4B5B5);
    pub const _400 = Color.hex(0xB08080);
    pub const _500 = Color.hex(0x844F4E);
    pub const _600 = Color.hex(0x6F4241);
    pub const _700 = Color.hex(0x5A3635);
};

/// Slate palette.
pub const slate = struct {
    pub const _50 = Color.hex(0xF5F7FA);
    pub const _100 = Color.hex(0xEDF2F6);
    pub const _200 = Color.hex(0xD8E2EB);
    pub const _300 = Color.hex(0xA8BCCE);
    pub const _400 = Color.hex(0x7090AE);
    pub const _500 = Color.hex(0x374B70);
    pub const _600 = Color.hex(0x2E3F5E);
    pub const _700 = Color.hex(0x24324B);
};

// Layer 2 & 3, Semantic + Component Color Tokens (theme-dependent)

/// Light/dark judgment (parallels CSS color-scheme / Panda's _dark condition
/// root state).
///
/// Usage boundary: theme differences should swap the token layer wholesale (light/dark
/// are two complete token sets; style functions get correct values naturally).
/// scheme is an escape hatch: when a style must branch by lightness and doesn't
/// warrant a token, use `if (t.scheme == .dark)` in the style function. Don't add a
/// dark condition in ConditionalStyle: two dark sources conflict.
pub const ColorScheme = enum { light, dark };

/// Complete theme token set.
pub const ThemeTokens = struct {
    name: []const u8 = "unnamed",
    /// Light/dark judgment. Always use this for theme check, never sniff name
    /// substring (historical lesson: high_contrast pure black missed .dark due to
    /// name, misread as light).
    scheme: ColorScheme = .light,
    color: ColorTokens,
    space: SpaceScale = .{},
    radius: RadiusScale = .{},
    font_size: FontSizeScale = .{},
    border_width: BorderWidthScale = .{},
    size: SizeTokens = .{},
    control: ControlScale = .{},
    duration: DurationTokens = .{},
    shadow: ShadowTokens = .{},
};

/// Semantic + component color tokens.
///
/// Zones:
///   [Semantic / Background]: hierarchy & purpose backgrounds
///   [Semantic / Foreground]: text, icon colors
///   [Semantic / Brand]: brand color, interaction accent
///   [Semantic / Status]: success/warning/error/info
///   [Semantic / Border]: border, focus ring
///   [Component]: component-specific tokens.
pub const ColorTokens = struct {
    // ── Semantic / Background ──────────────────────────────────────────────
    /// Page/window base background (deepest).
    bg_base: Color,
    /// Main content area background.
    bg_primary: Color,
    /// Secondary panel/sidebar background.
    bg_secondary: Color,
    /// Tertiary background: cards, code blocks, insets.
    bg_tertiary: Color,
    /// Overlay bg on hover.
    bg_hover: Color,
    /// Overlay bg on pressed / active.
    bg_active: Color,
    /// Inset accent bg (input interiors, headers, etc).
    bg_inset: Color,

    // ── Semantic / Foreground ─────────────────────────────────────────────
    /// Primary text.
    fg_primary: Color,
    /// Secondary text (descriptions, hints).
    fg_secondary: Color,
    /// Tertiary text (placeholders, tips).
    fg_tertiary: Color,
    /// Disabled text / icon.
    fg_disabled: Color,
    /// Inverted text (white on dark bg).
    fg_inverse: Color,

    // ── Semantic / Brand ──────────────────────────────────────────────────
    /// Brand primary (buttons, links, selected).
    accent: Color,
    /// Brand primary hover.
    accent_hover: Color,
    /// Brand light bg (selected rows, tag bg, etc).
    accent_subtle: Color,
    /// Brand lightest bg (marks, highlights).
    accent_muted: Color,

    // ── Semantic / Status ─────────────────────────────────────────────────
    /// Success.
    success: Color,
    /// Success light bg.
    success_subtle: Color,
    /// Warning.
    warning: Color,
    /// Warning light bg.
    warning_subtle: Color,
    /// Error / danger.
    danger: Color,
    /// Error hover.
    danger_hover: Color,
    /// Error light bg.
    danger_subtle: Color,
    /// Info.
    info: Color,
    /// Info light bg.
    info_subtle: Color,
    /// Foreground on status color (text in badge/tag).
    status_fg: Color,

    // ── Semantic / Border ─────────────────────────────────────────────────
    /// Default border.
    border: Color,
    /// Emphasis border (dividers, table borders).
    border_strong: Color,
    /// Focus border.
    border_focus: Color,
    /// Focus ring (outline).
    focus_ring: Color,

    // ── Component / Selection ─────────────────────────────────────────────
    /// Text selection background.
    selection_bg: Color,

    // ── Component / Button ────────────────────────────────────────────────
    /// Primary button background (= accent).
    button_primary_bg: Color,
    /// Primary button text.
    button_primary_fg: Color,
    /// Secondary button background.
    button_secondary_bg: Color,
    /// Secondary button text.
    button_secondary_fg: Color,

    // ── Component / Input ─────────────────────────────────────────────────
    /// Input background.
    input_bg: Color,
    /// Input border.
    input_border: Color,

    // ── Component / Toggle (Checkbox / Switch) ────────────────────────────
    /// Checkbox unchecked background.
    checkbox_bg: Color,
    /// Checkbox unchecked border.
    checkbox_border: Color,
    /// Checkbox disabled background.
    checkbox_disabled_bg: Color,
    /// Checkbox disabled border.
    checkbox_disabled_border: Color,
    /// Checkbox checked+disabled background.
    checkbox_disabled_checked_bg: Color,
    /// Switch thumb color.
    switch_thumb: Color,
    /// Switch off track.
    switch_track_off: Color,
    /// Switch on track (= accent).
    switch_track_on: Color,

    // ── Component / List / Table ──────────────────────────────────────────
    /// List row hover background.
    list_hover_bg: Color,
    /// List row selected background.
    list_selection_bg: Color,
    /// List row selected hover background.
    list_selection_hover_bg: Color,
    /// Table header background.
    table_header_bg: Color,

    // ── Component / Misc ──────────────────────────────────────────────────
    /// Divider.
    separator: Color,
    /// Scrollbar thumb.
    scrollbar_thumb: Color,
    /// Tooltip background.
    tooltip_bg: Color,
    /// Tooltip text.
    tooltip_fg: Color,
    /// Modal overlay.
    overlay: Color,
};

/// Spacing scale (4px base).
pub const SpaceScale = struct {
    _0: f32 = 0,
    _0_5: f32 = 2,
    _1: f32 = 4,
    _1_5: f32 = 6,
    _2: f32 = 8,
    _3: f32 = 12,
    _4: f32 = 16,
    _6: f32 = 24,
    _8: f32 = 32,
    _10: f32 = 40,
    _12: f32 = 48,
};

/// Corner radius scale.
pub const RadiusScale = struct {
    none: f32 = 0,
    sm: f32 = 3,
    md: f32 = 4,
    lg: f32 = 6,
    xl: f32 = 8,
    full: f32 = 9999,
};

/// Font size scale.
pub const FontSizeScale = struct {
    xxs: f32 = 9,
    xs: f32 = 11,
    sm: f32 = 12,
    md: f32 = 13,
    lg: f32 = 14,
    xl: f32 = 16,
    xxl: f32 = 20,
    xxxl: f32 = 24,
};

/// Border width scale.
pub const BorderWidthScale = struct {
    none: f32 = 0,
    thin: f32 = 1,
    medium: f32 = 1.5,
    thick: f32 = 2,
};

/// Unified control sizes for Button / Input / Select / ComboBox / DatePicker /
/// DateRangePicker / Tabs / Chip.
/// 4 tiers: XS / SM / MD / LG (default md).
///
/// Pure key enum. Actual metrics via theme: `tokens.control.get(size)` ->
/// `ControlMetrics`.
pub const ControlSize = enum {
    xs,
    sm,
    md,
    lg,
};

/// Complete metrics for a single control tier (one per ControlSize).
///
/// HEIGHT CONTRACT: control frame height is not a token but naturally sized:
///
///     frame_height = padding_y * 2 + line_height_px     line_height_px = font_size * line_height
///
/// ControlShell gives layout the "line box" (content/icon slot min height = line_height)
/// and padding_y; no control hardcodes frame height. Changing font_size /
/// line_height / padding_y scales all controls.
///
/// icon size must be <= line_height (centers in line box, doesn't stretch).
/// icon-only control: padding_y on all sides, icon slot is a line_height square,
/// so it is the same height as a text control and square.
pub const ControlMetrics = struct {
    /// Font size.
    font_size: f32,
    /// Line height multiplier (relative to font_size). line_height_px = font_size * line_height.
    line_height: f32,
    /// Corner radius.
    radius: f32,
    /// Vertical padding (frame_height = padding_y * 2 + line_height).
    padding_y: f32,
    /// Horizontal padding.
    padding_h: f32,
    /// Left padding with icon (top/bottom/right still padding_y / padding_h).
    padding_leading_icon: f32,
    /// Icon size (must be <= line_height).
    icon_size: f32,
    /// Gap between icon and text
    gap: f32,

    /// Line height (px) = font_size x line_height
    pub fn lineHeightPx(self: ControlMetrics) f32 {
        return self.font_size * self.line_height;
    }

    /// Outer frame height derived from measurement (padding_y x 2 + line_height).
    /// Read-only for measurement/assertion/positioning; do not write back to style.height.
    pub fn derivedHeight(self: ControlMetrics) f32 {
        return self.padding_y * 2 + self.lineHeightPx();
    }
};

/// Control scale ratio (on ThemeTokens.control; theme can replace uniformly).
///
/// Derivation (line_height fixed at 1.25, binary-exact; both height and frame are precise):
///   xs: 12 x 1.25 = 15   + 2.5 x 2  = 20
///   sm: 12 x 1.25 = 15   + 4.5 x 2  = 24
///   md: 14 x 1.25 = 17.5 + 7.25 x 2 = 32
///   lg: 16 x 1.25 = 20   + 10 x 2   = 40
/// icon_size (12/14/16/20) all <= line_height (15/15/17.5/20).
pub const ControlScale = struct {
    xs: ControlMetrics = .{
        .font_size = 12,
        .line_height = 1.25,
        .radius = 4,
        .padding_y = 2.5,
        .padding_h = 6,
        .padding_leading_icon = 4,
        .icon_size = 12,
        .gap = 4,
    },
    sm: ControlMetrics = .{
        .font_size = 12,
        .line_height = 1.25,
        .radius = 6,
        .padding_y = 4.5,
        .padding_h = 8,
        .padding_leading_icon = 6,
        .icon_size = 14,
        .gap = 4,
    },
    md: ControlMetrics = .{
        .font_size = 14,
        .line_height = 1.25,
        .radius = 8,
        .padding_y = 7.25,
        .padding_h = 12,
        .padding_leading_icon = 10,
        .icon_size = 16,
        .gap = 6,
    },
    lg: ControlMetrics = .{
        .font_size = 16,
        .line_height = 1.25,
        .radius = 10,
        .padding_y = 10,
        .padding_h = 16,
        .padding_leading_icon = 14,
        .icon_size = 20,
        .gap = 8,
    },

    pub fn get(self: *const ControlScale, s: ControlSize) ControlMetrics {
        return switch (s) {
            .xs => self.xs,
            .sm => self.sm,
            .md => self.md,
            .lg => self.lg,
        };
    }
};

/// Component size token
pub const SizeTokens = struct {
    checkbox: f32 = 18,
    switch_width: f32 = 40,
    switch_height: f32 = 22,
    badge_sm: f32 = 16,
    badge_md: f32 = 20,
    dot: f32 = 8,
    close_button: f32 = 24,
};

/// Animation duration token (seconds)
pub const DurationTokens = struct {
    fast: f32 = 0.1,
    normal: f32 = 0.15,
    slow: f32 = 0.25,
};

/// Shadow preset token
pub const ShadowTokens = struct {
    sm: Shadow = .{ .color = Color.rgba(0, 0, 0, 40), .blur = 4, .offset_x = 0, .offset_y = 2 },
    md: Shadow = .{ .color = Color.rgba(0, 0, 0, 80), .blur = 8, .offset_x = 0, .offset_y = 4 },
    lg: Shadow = .{ .color = Color.rgba(0, 0, 0, 100), .blur = 24, .offset_x = 0, .offset_y = 8 },
};

// Light theme

/// Light preset, based on VSCode theme 'Mac Classic' (mac-classic-light-color-theme.json)
pub const light = ThemeTokens{
    .name = "light",
    .scheme = .light,
    .color = .{
        // Background from Mac Classic light
        .bg_base = Color.hex(0xF5F5F5), // activityBar/statusBar/tabs background
        .bg_primary = Color.hex(0xFFFFFF), // editor.background
        .bg_secondary = Color.hex(0xF7F7F7), // sideBar.background / panel.background
        .bg_tertiary = Color.hex(0xEEEEEE), // button background / slightly darker panel
        .bg_hover = Color.hex(0xF0F0F0), // list.hoverBackground
        .bg_active = Color.hex(0xE0E0E0), // button.hoverBackground
        .bg_inset = Color.hex(0xF8F8F8), // editor.lineHighlightBackground

        // Foreground
        .fg_primary = Color.hex(0x1C1612), // editor.foreground
        .fg_secondary = Color.hex(0x555555), // activityBar.foreground / statusBar.foreground
        .fg_tertiary = Color.hex(0x888888), // tab.inactiveForeground
        .fg_disabled = Color.hex(0xBBBBBB), // input.placeholderForeground
        .fg_inverse = Color.hex(0xFFFFFF), // statusBar.debuggingForeground

        // Brand: Mac Classic uses dark brown-black #1C1612 as accent; paired with focusBorder
        // #6699CC
        .accent = Color.hex(0x1C1612), // activityBar.activeBorder / tab.activeBorderTop
        .accent_hover = Color.hex(0x2A2320), // badge.background
        .accent_subtle = Color.hex(0xE4EDFA), // list.activeSelectionBackground
        .accent_muted = Color.hex(0xF0F0F0), // list.hoverBackground

        // Status
        .success = Color.hex(0x2E8B37), // terminal.ansiGreen / gitDecoration.untracked
        .success_subtle = Color.hex(0xE4F2E6), // Derived: success light background
        .warning = Color.hex(0xAA7700), // terminal.ansiYellow
        .warning_subtle = Color.hex(0xF7EEDB), // Derived
        .danger = Color.hex(0xDD0000), // terminal.ansiRed / gitDecoration.deleted
        .danger_hover = Color.hex(0xB30000), // Derived: slightly darker
        .danger_subtle = Color.hex(0xFBE4E4), // Derived
        .info = Color.hex(0x1144AA), // list.highlightForeground / gitDecoration.modified
        .info_subtle = Color.hex(0xE4EDFA), // list.activeSelectionBackground
        .status_fg = Color.hex(0xFFFFFF),

        // Border
        .border = Color.hex(0xE0E0E0), // input.border / dropdown.border
        .border_strong = Color.hex(0xCCCCCC), // editorLineNumber.foreground
        .border_focus = Color.hex(0x6699CC), // focusBorder
        .focus_ring = Color.hex(0x6699CC), // focusBorder

        // Selection
        .selection_bg = Color.hex(0xB5D5FF), // editor.selectionBackground

        // Button
        .button_primary_bg = Color.hex(0x1C1612), // Mac Classic accent color
        .button_primary_fg = Color.hex(0xFFFFFF),
        .button_secondary_bg = Color.hex(0xEEEEEE), // button.background
        .button_secondary_fg = Color.hex(0x1C1612), // button.foreground

        // Input
        .input_bg = Color.hex(0xFFFFFF), // input.background
        .input_border = Color.hex(0xE0E0E0), // input.border

        // Toggle
        .checkbox_bg = Color.hex(0xFFFFFF),
        .checkbox_border = Color.hex(0xCCCCCC),
        .checkbox_disabled_bg = Color.hex(0xF5F5F5),
        .checkbox_disabled_border = Color.hex(0xE0E0E0),
        .checkbox_disabled_checked_bg = Color.hex(0xE0E0E0),
        .switch_thumb = Color.hex(0xFFFFFF),
        .switch_track_off = Color.hex(0xE0E0E0),
        .switch_track_on = Color.hex(0x1C1612),

        // List / Table
        .list_hover_bg = Color.hex(0xF0F0F0), // list.hoverBackground
        .list_selection_bg = Color.hex(0xE4EDFA), // list.activeSelectionBackground
        .list_selection_hover_bg = Color.hex(0xD8E4F4), // Derived: selection one level darker
        .table_header_bg = Color.hex(0xF5F5F5),

        // Misc
        .separator = Color.hex(0xEBEBEB), // panel.border
        .scrollbar_thumb = Color.rgba(0, 0, 0, 38), // scrollbarSlider.background #00000015 → alpha 21/255 ≈ 0x26; 0x15 = 21 decimal
        .tooltip_bg = Color.hex(0x1C1612),
        .tooltip_fg = Color.hex(0xFFFFFF),
        .overlay = Color.rgba(0, 0, 0, 80),
    },
    .shadow = .{
        .sm = .{ .color = Color.rgba(0, 0, 0, 16), .blur = 4, .offset_x = 0, .offset_y = 2 },
        .md = .{ .color = Color.rgba(0, 0, 0, 24), .blur = 8, .offset_x = 0, .offset_y = 4 },
        .lg = .{ .color = Color.rgba(0, 0, 0, 40), .blur = 24, .offset_x = 0, .offset_y = 8 },
    },
};

// Dark theme

/// Dark preset, based on VSCode theme 'Mac Classic Dark' (mac-classic-dark-color-theme.json)
pub const dark = ThemeTokens{
    .name = "dark",
    .scheme = .dark,
    .color = .{
        // Background
        .bg_base = Color.hex(0x0D1119), // activityBar/statusBar/tabs background
        .bg_primary = Color.hex(0x141820), // editor.background / tab.activeBackground
        .bg_secondary = Color.hex(0x12161E), // sideBar / panel.background
        .bg_tertiary = Color.hex(0x1E2230), // editorWidget.background
        .bg_hover = Color.hex(0x1A1E2A), // list.hoverBackground
        .bg_active = Color.hex(0x2A3450), // list.focusBackground
        .bg_inset = Color.hex(0x1C2028), // editor.lineHighlightBackground

        // Foreground
        .fg_primary = Color.hex(0xD7CCC4), // editor.foreground
        .fg_secondary = Color.hex(0xB8AEA6), // activityBar.foreground / statusBar.foreground
        .fg_tertiary = Color.hex(0x958B84), // tab.inactiveForeground
        .fg_disabled = Color.hex(0x7E746D), // input.placeholderForeground
        .fg_inverse = Color.hex(0x141820), // Inverse color

        // Brand: Mac Classic Dark uses warm beige #C7BBB3 as accent; paired with cool blue #6699CC
        .accent = Color.hex(0xC7BBB3), // activityBar.activeBorder / panelTitle.activeBorder
        .accent_hover = Color.hex(0xE8E0DA), // tab.activeBorderTop
        .accent_subtle = Color.hex(0x2A3450), // list.activeSelectionBackground
        .accent_muted = Color.hex(0x1A1E2A), // list.hoverBackground

        // Status
        .success = Color.hex(0x8CB87C), // terminal.ansiGreen / gitDecoration.untracked
        .success_subtle = Color.hex(0x1E2820), // Derived
        .warning = Color.hex(0xD4A843), // terminal.ansiYellow
        .warning_subtle = Color.hex(0x2A2418), // Derived
        .danger = Color.hex(0xC14545), // From terminal.ansiRed #FF6B6B darkened; ensures status_fg (white) contrast >= 4.5
        .danger_hover = Color.hex(0xFF6B6B), // Original ansiRed as hover bright color
        .danger_subtle = Color.hex(0x2E1C1C), // Derived
        .info = Color.hex(0x6B9BFF), // list.highlightForeground / gitDecoration.modified
        .info_subtle = Color.hex(0x1A2030), // Derived
        .status_fg = Color.hex(0xFFFFFF), // Badge/tag inverse text (maintains >= 4.5 contrast with red/blue/green)

        // Border
        .border = Color.hex(0x263048), // input.border / dropdown.border
        .border_strong = Color.hex(0x2A3248), // editorWidget.border
        .border_focus = Color.hex(0x6699CC), // focusBorder
        .focus_ring = Color.hex(0x6699CC), // focusBorder

        // Selection
        .selection_bg = Color.hex(0x3A4D70), // editor.selectionBackground

        // Button
        .button_primary_bg = Color.hex(0xC7BBB3), // accent
        .button_primary_fg = Color.hex(0x141820), // Inverse color
        .button_secondary_bg = Color.hex(0x1E2638), // button.background
        .button_secondary_fg = Color.hex(0xD7CCC4), // button.foreground

        // Input
        .input_bg = Color.hex(0x141820), // input.background
        .input_border = Color.hex(0x263048), // input.border

        // Toggle
        .checkbox_bg = Color.hex(0x141820),
        .checkbox_border = Color.hex(0x263048),
        .checkbox_disabled_bg = Color.hex(0x12161E),
        .checkbox_disabled_border = Color.hex(0x1E2230),
        .checkbox_disabled_checked_bg = Color.hex(0x1E2230),
        .switch_thumb = Color.hex(0xE8E0DA),
        .switch_track_off = Color.hex(0x263048),
        .switch_track_on = Color.hex(0xC7BBB3),

        // List / Table
        .list_hover_bg = Color.hex(0x1A1E2A), // list.hoverBackground
        .list_selection_bg = Color.hex(0x2A3450), // list.activeSelectionBackground
        .list_selection_hover_bg = Color.hex(0x344060), // Derived
        .table_header_bg = Color.hex(0x12161E),

        // Misc
        .separator = Color.hex(0x1E2230), // panel.border
        .scrollbar_thumb = Color.rgba(255, 255, 255, 33), // scrollbarSlider.background #FFFFFF15
        .tooltip_bg = Color.hex(0x1E2230), // editorWidget.background
        .tooltip_fg = Color.hex(0xD7CCC4),
        .overlay = Color.rgba(0, 0, 0, 160),
    },
};

/// v0.9-E (2026-05-13): High-contrast theme, WCAG AAA contrast (>=7:1).
/// Pure black background/white foreground; accent colors pure yellow #FFFF00 / cyan #00FFFF.
/// For users with visual disabilities + high-contrast system settings.
pub const high_contrast = ThemeTokens{
    .name = "high_contrast",
    // Pure black background -> dark. Previously devtools/theme_schema sniffed substring 'dark',
    // misclassifying high_contrast as light; scheme field ends this.
    .scheme = .dark,
    .color = .{
        // Background: pure black
        .bg_base = Color.hex(0x000000),
        .bg_primary = Color.hex(0x000000),
        .bg_secondary = Color.hex(0x000000),
        .bg_tertiary = Color.hex(0x1A1A1A),
        .bg_hover = Color.hex(0x404040),
        .bg_active = Color.hex(0x0000FF),
        .bg_inset = Color.hex(0x000000),

        // Foreground: pure white text (21:1 contrast)
        .fg_primary = Color.hex(0xFFFFFF),
        .fg_secondary = Color.hex(0xFFFFFF),
        .fg_tertiary = Color.hex(0xC0C0C0), // 12:1
        .fg_disabled = Color.hex(0x808080), // 4.6:1 (disabled allows AA, not AAA)
        .fg_inverse = Color.hex(0x000000),

        // Brand: pure yellow accent (19.6:1 contrast vs black)
        .accent = Color.hex(0xFFFF00),
        .accent_hover = Color.hex(0xFFFFC0),
        .accent_subtle = Color.hex(0x404000),
        .accent_muted = Color.hex(0x202000),

        // Status: high-saturation pure colors
        .success = Color.hex(0x00FF00), // 15.3:1
        .success_subtle = Color.hex(0x003300),
        .warning = Color.hex(0xFFFF00), // 19.6:1
        .warning_subtle = Color.hex(0x333300),
        .danger = Color.hex(0xFF6060), // 8:1
        .danger_hover = Color.hex(0xFF8080),
        .danger_subtle = Color.hex(0x330000),
        .info = Color.hex(0x00FFFF), // 16.7:1
        .info_subtle = Color.hex(0x003333),
        .status_fg = Color.hex(0x000000),

        // Border: pure white (clearly visible)
        .border = Color.hex(0xFFFFFF),
        .border_strong = Color.hex(0xFFFFFF),
        .border_focus = Color.hex(0xFFFF00),
        .focus_ring = Color.hex(0xFFFF00),

        // Selection
        .selection_bg = Color.hex(0xFFFF00),

        // Button
        .button_primary_bg = Color.hex(0xFFFFFF),
        .button_primary_fg = Color.hex(0x000000),
        .button_secondary_bg = Color.hex(0x000000),
        .button_secondary_fg = Color.hex(0xFFFFFF),

        // Input
        .input_bg = Color.hex(0x000000),
        .input_border = Color.hex(0xFFFFFF),

        // Toggle
        .checkbox_bg = Color.hex(0x000000),
        .checkbox_border = Color.hex(0xFFFFFF),
        .checkbox_disabled_bg = Color.hex(0x000000),
        .checkbox_disabled_border = Color.hex(0x808080),
        .checkbox_disabled_checked_bg = Color.hex(0x404040),
        .switch_thumb = Color.hex(0xFFFFFF),
        .switch_track_off = Color.hex(0x404040),
        .switch_track_on = Color.hex(0xFFFF00),

        // List / Table
        .list_hover_bg = Color.hex(0x404040),
        .list_selection_bg = Color.hex(0xFFFF00),
        .list_selection_hover_bg = Color.hex(0xFFFFC0),
        .table_header_bg = Color.hex(0x000000),

        // Misc
        .separator = Color.hex(0xFFFFFF),
        .scrollbar_thumb = Color.rgba(255, 255, 255, 200),
        .tooltip_bg = Color.hex(0xFFFFFF),
        .tooltip_fg = Color.hex(0x000000),
        .overlay = Color.rgba(0, 0, 0, 220),
    },
};

// Tests

const std = @import("std");

fn channelToLinear(c: u8) f64 {
    const v = @as(f64, @floatFromInt(c)) / 255.0;
    if (v <= 0.04045) return v / 12.92;
    return std.math.pow(f64, (v + 0.055) / 1.055, 2.4);
}

fn relativeLuminance(c: Color) f64 {
    const r = channelToLinear(c.r);
    const g = channelToLinear(c.g);
    const b = channelToLinear(c.b);
    return 0.2126 * r + 0.7152 * g + 0.0722 * b;
}

fn contrastRatio(a: Color, b: Color) f64 {
    const la = relativeLuminance(a);
    const lb = relativeLuminance(b);
    const hi = if (la > lb) la else lb;
    const lo = if (la > lb) lb else la;
    return (hi + 0.05) / (lo + 0.05);
}

test "ThemeTokens: dark preset has valid colors" {
    const t = &dark;
    try std.testing.expect(t.color.accent.a == 255);
    try std.testing.expect(t.color.bg_primary.a == 255);
    try std.testing.expect(t.color.overlay.a == 160);
}

test "ThemeTokens: light preset has valid colors" {
    const t = &light;
    try std.testing.expect(t.color.accent.a == 255);
    try std.testing.expect(t.color.bg_primary.a == 255);
}

test "ThemeTokens: space scale values" {
    const s = SpaceScale{};
    try std.testing.expectEqual(@as(f32, 0), s._0);
    try std.testing.expectEqual(@as(f32, 4), s._1);
    try std.testing.expectEqual(@as(f32, 8), s._2);
    try std.testing.expectEqual(@as(f32, 16), s._4);
}

test "ThemeTokens: radius scale values" {
    const r = RadiusScale{};
    try std.testing.expectEqual(@as(f32, 0), r.none);
    try std.testing.expectEqual(@as(f32, 4), r.md);
    try std.testing.expectEqual(@as(f32, 9999), r.full);
}

test "ThemeTokens: switching theme is pointer swap" {
    var current: *const ThemeTokens = &dark;
    try std.testing.expectEqualStrings("dark", current.name);
    current = &light;
    try std.testing.expectEqualStrings("light", current.name);
}

test "ThemeTokens: critical contrast pairs stay readable" {
    // Primary button: fg on bg
    try std.testing.expect(contrastRatio(dark.color.button_primary_fg, dark.color.button_primary_bg) >= 4.5);
    try std.testing.expect(contrastRatio(light.color.button_primary_fg, light.color.button_primary_bg) >= 4.5);
    // Danger fg on danger bg
    try std.testing.expect(contrastRatio(dark.color.status_fg, dark.color.danger) >= 4.5);
    try std.testing.expect(contrastRatio(light.color.status_fg, light.color.danger) >= 4.5);
    // Border distinguishable from bg_primary (decorative border, contrast >= 1.2)
    try std.testing.expect(contrastRatio(dark.color.border, dark.color.bg_primary) >= 1.2);
    try std.testing.expect(contrastRatio(light.color.border, light.color.bg_primary) >= 1.2);
}
