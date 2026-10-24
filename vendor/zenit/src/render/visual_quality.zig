//! Decorative quality only. Essential text, images, clipping and compositing
//! are never disabled. Resolve once per renderer; do not identify GPU vendors.
const std = @import("std");
/// Glass degrades liquid → frosted → translucent:
///   full    Liquid Glass (lens, refraction, rim light, native Gaussian banks)
///   frosted backdrop blur (Kawase over the glass region) under a translucent
///           material; member shapes kept, no lens/rim
///   basic   translucent material without blur (also the fallback when the
///           blur pipeline is unavailable); reduced motion
/// Fully opaque material is reserved for the Reduce Transparency setting.
pub const Quality = enum { auto, full, frosted, basic };
pub fn resolve(requested: Quality, software: bool) Quality {
    return if (requested == .auto) (if (software) .frosted else .full) else requested;
}
/// Alpha of the glass material veil drawn by the frosted / basic tiers.
/// Tinted (prominent) glass stays nearly solid so its label remains legible;
/// without blur the veil carries legibility alone and is denser.
pub fn materialAlpha(quality: Quality, tinted: bool, reduce_transparency: bool) f32 {
    if (reduce_transparency) return 1;
    return switch (quality) {
        .frosted => if (tinted) 0.85 else 0.62,
        else => if (tinted) 0.94 else 0.9,
    };
}
pub fn parse(value: []const u8) !Quality {
    inline for (.{ "auto", "full", "frosted", "basic" }) |name| {
        if (std.mem.eql(u8, value, name)) return @field(Quality, name);
    }
    return error.InvalidVisualQuality;
}
/// Glass tint RGB carries the material's light/dark theme even at low alpha.
/// An opaque surface preserves legibility when backdrop filtering is absent.
pub fn opaqueTint(tint: [4]f32) [4]f32 {
    return .{ tint[0], tint[1], tint[2], 1 };
}
test "visual quality selects conservative software defaults and explicit overrides" {
    try std.testing.expectEqual(Quality.frosted, resolve(.auto, true));
    try std.testing.expectEqual(Quality.full, resolve(.auto, false));
    try std.testing.expectEqual(Quality.full, resolve(.full, true));
    try std.testing.expectEqual(Quality.basic, resolve(.basic, false));
    try std.testing.expectError(error.InvalidVisualQuality, parse("typo"));
    try std.testing.expectEqual(Quality.basic, try parse("basic"));
    try std.testing.expectEqual(Quality.frosted, try parse("frosted"));
    try std.testing.expect(materialAlpha(.frosted, false, false) < materialAlpha(.basic, false, false));
    try std.testing.expectEqual(@as(f32, 1), materialAlpha(.frosted, false, true));
    try std.testing.expectEqual([4]f32{ 0.1, 0.2, 0.3, 1 }, opaqueTint(.{ 0.1, 0.2, 0.3, 0 }));
}
