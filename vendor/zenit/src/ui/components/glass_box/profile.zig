//! Platform glass profiles. Apple ships two Liquid Glass renderings: macOS (AppKit /
//! SwiftUI on the Mac) and iOS (UIKit / SwiftUI on iPhone and iPad). They differ in measured
//! optics (blur, coating, tint response, rim, dispersion) and in adaptive / motion behaviour,
//! so every measured value lives in a profile selected by `GlassIdiom`, the way
//! `UIUserInterfaceIdiom` selects platform behaviour.
//!
//! A profile is a set of resolver functions plus scalar parameter groups: the macOS material is
//! a fitted function with its own functional form (size tables, family interpolation), and a
//! platform measured later need not share that form. Each profile records where its baseline
//! came from (`baseline`).
const std = @import("std");
const builtin = @import("builtin");
const core = @import("../../core.zig");
const theme = core.theme;
const Color = core.Color;
const glass_box = @import("mod.zig");

pub const GlassIdiom = enum(u8) {
    macos = 0,
    ios = 1,

    /// The idiom of the platform the app is built for. Desktop targets without a native
    /// Liquid Glass (Windows, Linux) follow the macOS rendering.
    pub fn host() GlassIdiom {
        return switch (builtin.os.tag) {
            .ios, .tvos, .visionos, .watchos => .ios,
            else => .macos,
        };
    }

    pub fn profile(self: GlassIdiom) *const GlassProfile {
        return switch (self) {
            .macos => &macos,
            .ios => &ios,
        };
    }
};

/// Where a profile's numbers come from.
pub const Baseline = enum {
    /// Fitted to native captures (see docs/GLASS_NATIVE_FIDELITY.md).
    measured,
    /// Some groups fitted to native captures, the rest inherited from another profile; each
    /// field documents which (see `ios`).
    partial,
    /// Not yet captured: values are copied from another profile and must not be cited as native.
    placeholder,
};

/// Regular glass coating in sRGB-encoded space (after the chroma boost):
///   light family: out = veil * a + brightness * in * (1 - a)
///   dark family:  out = offset + gain * in            (a = 1 - gain, veil = offset / a)
/// Each pair is {small, large}, interpolated over the shorter side in `ramp` (logical px).
pub const CoatingModel = struct {
    ramp: [2]f32,
    light_alpha: [2]f32,
    /// Light veil gray (0-255).
    light_veil: [2]f32,
    /// Backdrop gain before the light veil (1 = none).
    light_brightness: f32 = 1.0,
    dark_gain: [2]f32,
    /// Dark output over black (0-255).
    dark_offset: [2]f32,
    /// Chroma gain after the veil, light and dark families.
    light_chroma: [2]f32,
    dark_chroma: [2]f32,
    /// Drop shadow alpha (regular only; clear has none), light and dark families.
    light_shadow: [2]f32 = .{ 0.095, 0.095 },
    dark_shadow: [2]f32 = .{ 0.039, 0.039 },
    /// Compact elements (shorter side <= `compact.max_dim`, the ones that flip family) use
    /// their own coating; null = the ramp's small end for every size. Between max_dim and
    /// ramp[0] the ramp's small end applies (constant below the ramp).
    compact: ?CompactCoating = null,
};

/// Coating of compact elements. Every field is required, so a profile cannot enable the compact
/// coating with an unfilled (zero) coefficient.
pub const CompactCoating = struct {
    max_dim: f32,
    light_alpha: f32,
    light_veil: f32,
    light_brightness: f32,
    dark_gain: f32,
    dark_offset: f32,
    light_chroma: f32,
    dark_chroma: f32,
    light_shadow: f32,
    dark_shadow: f32,
    /// Blur bank lookup size (shorter side, logical px).
    blur_dim: f32,
    /// Measured non-affine coating as a backdrop-luma transfer curve (0-255 output at input
    /// 0, 16, ..., 256); null = the affine coefficients above. With a curve the light backdrop
    /// gain is part of the curve.
    light_curve: ?[17]f32,
    dark_curve: ?[17]f32,
};

/// Which material family to resolve. Adaptive glass (regular, untinted) renders an explicit
/// family, which can differ from the appearance (a compact element over a bright backdrop in
/// dark appearance is light); clear and tinted glass follow the appearance.
pub const MaterialFamily = enum { appearance, light, dark };

/// Material resolver: style + tint + laid-out size + material family -> resolved material.
pub const MaterialFn = *const fn (
    profile: *const GlassProfile,
    tokens: *const theme.ThemeTokens,
    readability: glass_box.GlassBoxReadability,
    emphasis: glass_box.GlassBoxEmphasis,
    style: glass_box.GlassEffectStyle,
    tint: ?Color,
    width: f32,
    height: f32,
    radius: f32,
    live_luminance: ?f32,
    family: MaterialFamily,
) glass_box.ResolvedGlassBoxStyle;

/// Adaptive light/dark family switch of small regular glass (see adaptiveFamilyStep).
pub const FamilyParams = struct {
    /// Elements whose shorter side exceeds this (logical px) never flip.
    flip_max_dim: f32,
    /// Whether tinted (Glass.tint) regular glass flips family too. iOS: yes (a fresh 120 x 60
    /// red-tinted glass over black reads 255,47,47 in the light appearance, the dark-appearance
    /// value); macOS: no (244,40,40 light vs 255,47,47 dark).
    tinted_adapts: bool,
    /// Light appearance: enter the dark family below / leave it above this sRGB backdrop luma.
    enter_dark_luma: f32,
    exit_dark_luma: f32,
    /// Dark appearance: enter the light family above / leave it below this luma.
    dark_appearance_enter_light_luma: f32,
    dark_appearance_exit_light_luma: f32,
    /// Material crossfade: critically damped spring response (s) and onset delay (s).
    to_dark_response_s: f32,
    to_light_response_s: f32,
    to_dark_delay_s: f32,
    to_light_delay_s: f32,
    /// Content ink (vibrancy) crossfade, measured separately from the material.
    ink_to_dark_response_s: f32,
    ink_to_light_response_s: f32,
    ink_to_dark_delay_s: f32,
    ink_to_light_delay_s: f32,
    /// A fresh effect is drawn in the appearance family from its first frame and switches to its
    /// backdrop's family this long after it first appears (native_family_fresh.swift).
    fresh_to_dark_delay_s: f32,
    fresh_to_light_delay_s: f32,
};

/// `glassEffectTransition(.materialize)` durations.
pub const MaterializeParams = struct {
    appear_ms: f64,
    disappear_ms: f64,
};

/// System `.glass` button press: constant sRGB offset of the body on the pressed frame.
pub const PressParams = struct {
    glass_button_light: f32,
    glass_button_dark: f32,
};

/// Window not key: tint dropped, coating flattened (rim and shadow removed).
pub const InactiveParams = struct {
    /// Gray coating replacing Glass.tint, and its chroma gain.
    tint_veil: Color,
    tint_saturation: f32,
    /// Untinted regular, light and dark families.
    plain_veil: Color,
    dark_veil: Color,
};

pub const GlassProfile = struct {
    idiom: GlassIdiom,
    baseline: Baseline,
    /// Default `cornerRadius` of the platform glass view.
    default_corner_radius: f32,
    material: MaterialFn,
    coating: CoatingModel,
    family: FamilyParams,
    materialize: MaterializeParams,
    press: PressParams,
    inactive: InactiveParams,
};

/// macOS 26.4 (AppKit NSGlassEffectView / SwiftUI glassEffect), see
/// docs/GLASS_NATIVE_FIDELITY.md and scripts/glass_native_model.
pub const macos: GlassProfile = .{
    .idiom = .macos,
    .baseline = .measured,
    // NSGlassEffectView().cornerRadius == 8
    .default_corner_radius = 8,
    .material = glass_box.fittedMaterial,
    // Native regular on gray 128: light 213 + 0.137 in at every size; dark capsule 20 + 0.21 in,
    // large panel 14 + 0.30 in (gray, blue and red backdrops). Chroma gain light 0.39 -> 0.73,
    // dark 0.78 -> 0.93.
    .coating = .{
        .ramp = .{ 64, 160 },
        .light_alpha = .{ 0.863, 0.863 },
        .light_veil = .{ 247, 247 },
        .dark_gain = .{ 0.21, 0.30 },
        .dark_offset = .{ 20, 14 },
        .light_chroma = .{ 0.39, 0.73 },
        .dark_chroma = .{ 0.78, 0.93 },
    },
    .family = .{
        // native_family_flip.swift: small regular elements (<= 64 px) flip on their own
        // backdrop; >= 96 px never flip.
        .flip_max_dim = 64,
        .tinted_adapts = false,
        .enter_dark_luma = 48.0 / 255.0,
        .exit_dark_luma = 120.0 / 255.0,
        .dark_appearance_enter_light_luma = 232.0 / 255.0,
        .dark_appearance_exit_light_luma = 164.0 / 255.0,
        // native_family_transition.swift
        .to_dark_response_s = 0.37,
        .to_light_response_s = 0.50,
        .to_dark_delay_s = 0.045,
        .to_light_delay_s = 0.050,
        .ink_to_dark_response_s = 0.51,
        .ink_to_light_response_s = 0.355,
        .ink_to_dark_delay_s = 0.055,
        .ink_to_light_delay_s = 0.025,
        .fresh_to_dark_delay_s = 0.150,
        .fresh_to_light_delay_s = 0.207,
    },
    // native_materialize.swift: smoothstep-shaped, not an alpha fade
    .materialize = .{ .appear_ms = 420, .disappear_ms = 270 },
    // Native .glass button (gray 128 / white / dark 40 agree)
    .press = .{ .glass_button_light = -19.8 / 255.0, .glass_button_dark = 17.7 / 255.0 },
    .inactive = .{
        // native_tint_backdrop.swift inactive: every tint reads the same gray
        .tint_veil = Color.rgba(213, 213, 213, 229),
        .tint_saturation = 0.2 / (1.0 - 0.898),
        // white 249 -> 242, black 210 -> 217
        .plain_veil = Color.rgba(241, 241, 241, 230),
        // native_dark_inactive.swift: out = 41 + 0.125 * in
        .dark_veil = Color.rgba(47, 47, 47, 223),
    },
};

/// iOS 26.5 (UIKit UIGlassEffect / SwiftUI glassEffect; identical within 2 levels), measured on
/// the iOS Simulator (iPhone 17 Pro, 3x): scripts/glass_native_model/baselines/
/// ios-26-5-simulator-iphone-17-pro.
/// Measured: regular coating, chroma gain and drop shadow vs size (`size`, `chroma` sets), the
/// compact blur (`compare` grating), family flip size and thresholds (fresh effect), clear
/// (identical to macOS: 18.7 + 1.041 in), Glass.tint and its alpha (identical mixing law), no
/// edge dispersion on static glass.
/// Inherited from macOS, checked: lens and rim (grating edge RMS 4-6 levels against iOS, vs
/// 11-16 between the two natives); blur bank above the compact size (grating interior 2-3).
/// Inherited, not measured on iOS: family hysteresis exits and crossfade springs, materialize /
/// press timings, inactive state.
pub const ios: GlassProfile = blk: {
    var p = macos;
    p.idiom = .ios;
    p.baseline = .partial;
    // Regular, 2d x d capsules, gray 0..240: affine per size (rmse <= 1.7 levels for d >= 72).
    p.coating = .{
        .ramp = .{ 72, 160 },
        .light_alpha = .{ 0.6945, 0.7153 },
        .light_veil = .{ 250.5, 253.1 },
        .dark_gain = .{ 0.2410, 0.3084 },
        .dark_offset = .{ 28.5, 18.8 },
        // `chroma` set (colour bars, 2d x d, d 52..200): interior chroma within 2 levels.
        .light_chroma = .{ 0.575, 0.90 },
        .dark_chroma = .{ 0.625, 0.64 },
        // Shadow below the glass on uniform gray (`size` set): within 1.1 levels. Unlike macOS
        // the dark-family shadow deepens with size and compact light glass casts a stronger one.
        .light_shadow = .{ 0.102, 0.088 },
        .dark_shadow = .{ 0.055, 0.150 },
        // d <= 60 flips family and uses its own coating: measured transfer curves (dark is a
        // knee 19..106, light 174..250); the affine fields are their best lines (light
        // 146.7 + 0.4546 in, dark 18.0 + 0.4728 in) for paths that need an affine coating.
        .compact = .{
            // The pressed tab bar platter (62 -> 65.2 pt) still reads compact (216 over gray
            // 128, interaction/tabbar_hold_t9.png); 72 is regular (`size` set).
            .max_dim = 68,
            .light_alpha = 146.7 / 255.0,
            .light_veil = 255,
            .light_brightness = 0.4546 / (1.0 - 146.7 / 255.0),
            .dark_gain = 0.4728,
            .dark_offset = 18.0,
            .light_chroma = 0.511,
            .dark_chroma = 0.78,
            .light_shadow = 0.174,
            .dark_shadow = 0.035,
            // Compact glass is blurrier than macOS glass of the same size: a 16 pt grating keeps
            // the native modulation (55 levels) with the bank looked up at 84 pt.
            .blur_dim = 84,
            // `size` set, d 44..60 (identical), gray step 16, same in both appearances. Dark is
            // measured over 0..208 and light over 64..240; the ends beyond (only reached while a
            // family crossfades) continue the end slopes.
            .dark_curve = .{ 19, 23, 28, 34, 42, 57, 70, 82, 89, 93, 96, 98, 103, 106.3, 110.5, 114.6, 118.8 },
            .light_curve = .{ 142, 150, 158, 166, 174, 182, 188, 196, 205, 216.7, 223, 230, 236, 242, 247, 250, 253 },
        },
    };
    // Flip only for the shorter side <= 60 (72 never flips): between 60 and 72, like macOS 64.
    // Fresh effect, light appearance: gray 48 flips dark, 64 stays light; dark appearance: 208
    // stays dark, 224 flips light. Exit (hysteresis) thresholds are inherited from macOS.
    p.family.enter_dark_luma = 56.0 / 255.0;
    // Tinted glass flips family too (`tint` set: light g0 / dark g255 match the other appearance).
    p.family.tinted_adapts = true;
    p.family.dark_appearance_enter_light_luma = 216.0 / 255.0;
    break :blk p;
};

test "GlassIdiom: host idiom and profile lookup" {
    try std.testing.expectEqual(GlassIdiom.macos, GlassIdiom.host());
    try std.testing.expect(GlassIdiom.macos.profile() == &macos);
    try std.testing.expect(GlassIdiom.ios.profile() == &ios);
    try std.testing.expectEqual(GlassIdiom.ios, ios.idiom);
    try std.testing.expectEqual(Baseline.measured, macos.baseline);
    try std.testing.expectEqual(Baseline.partial, ios.baseline);
}
