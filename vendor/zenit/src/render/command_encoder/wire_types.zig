//! Conversion from UI display-list wire values to renderer enums.

const sdf = @import("../sdf_renderer.zig");

pub fn gradientDirection(direction: u8) sdf.GradientDir {
    return switch (direction) {
        0 => .horizontal,
        1 => .vertical,
        2 => .diagonal,
        3 => .radial,
        4 => .conic,
        else => .vertical,
    };
}

/// text_run.raster_policy wire value (corresponds to ui-side text_blob.TextRasterPolicy).
pub const TextRasterMode = enum(u8) {
    /// Static text: nearest + subpixel variant + CPU/shader dual-side pixel snapping (idempotent
    /// combination)
    static_crisp = 0,
    /// Direct draw during animation: CPU and shader both maintain continuous float coords.
    /// Rounding either side makes adjacent glyphs cross int boundary between frames,
    /// causing kerning/baseline jitter (jitter root cause).
    direct_animated = 1,
    /// Text rasterized into retained surface: coords are stable owner-local, snapping is safe.
    surface_cached = 2,
};

pub const TextRasterControls = struct {
    /// linear sampling + disable subpixel variant + stable font selection + CPU no snap
    force_linear: bool,
    /// Whether vertex shader rounds glyph position to physical pixels
    shader_snap: bool,
};

/// unique policy -> draw control derivation. exhaustive switch: new modes must
/// decide explicitly, forbid collapse to bool `policy != 0`.
pub fn textRasterControls(policy_byte: u8) TextRasterControls {
    const mode: TextRasterMode = switch (policy_byte) {
        0 => .static_crisp,
        1 => .direct_animated,
        2 => .surface_cached,
        // Unknown wire value takes the most conservative static path (no blur, no motion)
        else => .static_crisp,
    };
    return switch (mode) {
        .static_crisp => .{ .force_linear = false, .shader_snap = true },
        .direct_animated => .{ .force_linear = true, .shader_snap = false },
        // Cached layer contents retain filtering for fractional layer composition.
        .surface_cached => .{ .force_linear = true, .shader_snap = true },
    };
}

pub fn gradientExtendMode(mode: u8) sdf.GradientExtendMode {
    return switch (mode) {
        0 => .pad,
        1 => .repeat,
        2 => .reflect,
        else => .pad,
    };
}
