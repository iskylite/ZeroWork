//! command_encoder/local_sort.zig: local-sort geometry/bounds pure functions
//!
//! Same family as paint_fingerprint.zig: pure function clusters with no dependence on encoder
//! instance state.
//!
//! Purpose: local-sort reorders adjacent same-pipeline commands into one batch submit without
//! changing the visual result, reducing pipeline switches. Reorder legality is decided by bounds
//! here: **two commands with non-overlapping bounds may swap**.
//!
//! Warning: bounds must **err large**. Too small makes an actually-overlapping pair look
//! reorderable and directly produces wrong paint order (later drawn under earlier). Text commands
//! have no shaped ink bounds on the wire, so they fence sorting until that contract is available.

const std = @import("std");

pub const PipelineKind = enum(u8) {
    sdf,
    image,
    icon,
    text,
    fence,
};

pub fn localSortPipelineKind(it: anytype) PipelineKind {
    return switch (it.kind) {
        .rect, .shadow, .gradient => .sdf,
        // .path: arc use sdf, fill_path/stroke_path use path renderer (fence and sdf isolate)
        .path => if (it.arc_outer_radius > 0) .sdf else .fence,
        .image => if (it.icon_rep_ptr != null) .icon else .image,
        // Font choice, fallback, bearings and shaping can exceed any em estimate.
        .text => .fence,
        .control, .none => .fence,
    };
}

pub fn localSortBoundsForCommand(it: anytype) ?[4]f32 {
    return switch (it.kind) {
        .rect, .gradient => normalizedRectBounds(it.geom.x, it.geom.y, it.geom.w, it.geom.h),
        .shadow => blk: {
            const first = localSortShadowBounds(it.geom.x, it.geom.y, it.geom.w, it.geom.h, it.shadow_blur, it.shadow_offset_x, it.shadow_offset_y, it.shadow_spread);
            if (it.shadow2_color.a <= 0) break :blk first;
            const second = localSortShadowBounds(it.geom.x, it.geom.y, it.geom.w, it.geom.h, it.shadow2_blur, it.shadow2_offset_x, it.shadow2_offset_y, 0);
            const left = @min(first[0], second[0]);
            const top = @min(first[1], second[1]);
            break :blk .{ left, top, @max(first[0] + first[2], second[0] + second[2]) - left, @max(first[1] + first[3], second[1] + second[3]) - top };
        },
        .image => localSortImageLikeBounds(it.geom.x, it.geom.y, it.geom.w, it.geom.h, it.rotate),
        .text => null,
        .path => if (it.arc_outer_radius > 0)
            localSortArcBounds(it.geom.x, it.geom.y, it.arc_outer_radius)
        else
            null,
        .control, .none => null,
    };
}

pub fn normalizedRectBounds(x: f32, y: f32, w: f32, h: f32) [4]f32 {
    const clamped_w = @max(w, 0);
    const clamped_h = @max(h, 0);
    return .{ x, y, clamped_w, clamped_h };
}

pub fn localSortImageLikeBounds(x: f32, y: f32, w: f32, h: f32, rotate: f32) [4]f32 {
    if (@abs(rotate) <= 0.0001) return normalizedRectBounds(x, y, w, h);
    const cx = x + w * 0.5;
    const cy = y + h * 0.5;
    const radius = 0.5 * std.math.sqrt(w * w + h * h);
    return .{
        cx - radius,
        cy - radius,
        radius * 2,
        radius * 2,
    };
}

/// Cover the complete SDF vertex quad, including blur tails and positive spread.
/// Match sdf_primitives.metal's expansion; alpha bounds can never exceed this quad.
pub fn localSortShadowBounds(x: f32, y: f32, w: f32, h: f32, blur: f32, offset_x: f32, offset_y: f32, spread: f32) [4]f32 {
    const pad = @max(blur, 0) * 2 + @abs(offset_x) + @abs(offset_y) + @max(spread, 0);
    return .{ x - pad, y - pad, @max(w + pad * 2, 0), @max(h + pad * 2, 0) };
}

pub fn localSortArcBounds(cx: f32, cy: f32, outer_radius: f32) [4]f32 {
    const radius = @max(outer_radius, 0);
    return .{
        cx - radius,
        cy - radius,
        radius * 2,
        radius * 2,
    };
}

pub fn rectsOverlap(a: [4]f32, b: [4]f32) bool {
    if (a[2] <= 0 or a[3] <= 0 or b[2] <= 0 or b[3] <= 0) return false;
    return a[0] < b[0] + b[2] and
        a[0] + a[2] > b[0] and
        a[1] < b[1] + b[3] and
        a[1] + a[3] > b[1];
}
