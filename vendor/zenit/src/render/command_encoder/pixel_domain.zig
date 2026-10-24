//! command_encoder/pixel_domain.zig: safe conversion from logical to physical pixel domain.
//! Shared by the encoder (viewport/scissor) and backdrop_capture.zig (backdrop sampling region),
//! which both need the same 2^24 clamp; no copies allowed. Zero-dependency module: both **import
//! from here**, and it must not re-import the parent file, else same decl names in the parent
//! become ambiguous references.
//! Why 2^24 limit: f32 precisely represents each integer up to 2^24; beyond, adjacent integers
//! start getting absorbed; @intFromFloat result unpredictable. All amounts becoming texture coords
//! / scissor / viewport sizes must pass through here first.

const std = @import("std");

/// Safe upper limit for physical pixel coords (2^24 = 16_777_216).
pub const max_safe_pixel_coordinate: f32 = 16_777_216;

/// Float coordinates -> u32: negative/zero folded to 0; NaN/Inf/exceeds safe limit returns null.
///
/// Used for src/dst pixel rectangles. Callers receiving null must discard the capture/crop; never
/// truncate out-of-bounds values, as truncation shifts the entire sampling window elsewhere.
pub fn finitePixelCoordinate(value: f32) ?u32 {
    if (!std.math.isFinite(value)) return null;
    if (value <= 0) return 0;
    if (value > max_safe_pixel_coordinate) return null;
    return @intFromFloat(value);
}

/// Physical pixels (logical size x scale): ceil rounding, invalid input zeroed, result clamped to
/// max_safe_pixel_coordinate (for viewport/scissor dimensions).
pub fn physicalPixelExtent(logical: f32, scale: f32) u32 {
    if (!std.math.isFinite(logical) or !std.math.isFinite(scale) or logical <= 0 or scale <= 0) return 0;
    const pixels = @ceil(logical * scale);
    if (!std.math.isFinite(pixels) or pixels <= 0) return 0;
    return @intFromFloat(@min(pixels, max_safe_pixel_coordinate));
}

// Test anchors: while these primitives lived inline in the parent file they had no direct coverage
// (only passed through indirectly by the backdrop region end-to-end tests). If the clamp boundary
// slips: viewport gets out-of-range sizes, the backdrop sampling window shifts as a whole. Both
// are pinned here.

test "finitePixelCoordinate: 负值/零折成 0，超安全上限返回 null" {
    try std.testing.expectEqual(@as(?u32, 0), finitePixelCoordinate(-1.5));
    try std.testing.expectEqual(@as(?u32, 0), finitePixelCoordinate(0));
    try std.testing.expectEqual(@as(?u32, 7), finitePixelCoordinate(7.9));
    // Cannot use max+1 as out-of-bounds sample: f32 has 2-unit spacing above 2^24; 16_777_216 + 1
    // rounds back to 16_777_216 itself (still valid). Use 2^25.
    try std.testing.expectEqual(@as(?u32, null), finitePixelCoordinate(33_554_432));
    try std.testing.expectEqual(@as(?u32, null), finitePixelCoordinate(std.math.nan(f32)));
    try std.testing.expectEqual(@as(?u32, null), finitePixelCoordinate(std.math.inf(f32)));
    // Exactly at limit: f32 can represent precisely within 2^24, still valid.
    const at_limit = finitePixelCoordinate(max_safe_pixel_coordinate);
    try std.testing.expectEqual(@as(?u32, 16_777_216), at_limit);
}

test "physicalPixelExtent: ceil 取整且钳到安全上限，非法输入归零" {
    try std.testing.expectEqual(@as(u32, 1), physicalPixelExtent(0.1, 1));
    try std.testing.expectEqual(@as(u32, 2), physicalPixelExtent(1.0, 2)); // 1.0*2=2
    try std.testing.expectEqual(@as(u32, 0), physicalPixelExtent(-5, 2));
    try std.testing.expectEqual(@as(u32, 0), physicalPixelExtent(10, 0));
    try std.testing.expectEqual(@as(u32, 0), physicalPixelExtent(std.math.nan(f32), 1));
    // Huge logical size -> ceil and clamp to 16_777_216, not overflow/crash.
    try std.testing.expectEqual(@as(u32, 16_777_216), physicalPixelExtent(1e9, 1e9));
}
