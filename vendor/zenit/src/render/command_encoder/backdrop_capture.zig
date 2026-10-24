//! command_encoder/backdrop_capture.zig: backdrop sample region resolution.
//!
//! Answers one question: **given a logical-coord glass sample area, landing in a 64px bucket
//! texture + physical pixels + visibility clipped, where exactly to copy from in the source RT,
//! how much, and where to place it in the target texture**.
//!
//! Why independent: `computeBackdropCaptureRegion` is a **static** function on
//! `RenderCommandEncoder` (backdrop_blur.zig:753 always calls it via
//! `@TypeOf(encoder.*).computeBackdropCaptureRegion(...)`, never self). Depends only on
//! offscreen_texture bucket sizing, zero encoder state.
//!
//! Pixel domain conversions (finitePixelCoordinate / physicalPixelExtent /
//! max_safe_pixel_coordinate) are shared with encoder viewport/scissor paths, so they live in
//! pixel_domain.zig; both this module and command_encoder.zig import from there (split
//! modules must not back-import the parent, else the parent's same decl is ambiguous).
//!
//! Interface cut: **logical area -> {texture size, src/copy/dst physical rects}**.
//! Blit / kawase chain / composite is backdrop_blur.zig's job.
//!
//! WARNING - behavior contract:
//!   - texture allocated in 64px buckets (morph/resize animation pool hits);
//!   - src crossing viewport bottom/right must clamp to source texture, else blit reports
//!     InvalidTextureRegion -> caller silently abandons the **whole** glass composite, so a
//!     node scrolled in shows only text/border;
//!   - src_tex_w/h = 0 means unknown, skip right/bottom clamp (test compat only).

const std = @import("std");
const offscreen_texture = @import("../offscreen_texture.zig");
const clip_geometry = @import("clip_geometry.zig");
const pixel_domain = @import("pixel_domain.zig");

const finitePixelCoordinate = pixel_domain.finitePixelCoordinate;
const intersectClipRects = clip_geometry.intersectClipRects;

pub const BackdropCaptureRegion = struct {
    tex_w: u32,
    tex_h: u32,
    src_x: u32,
    src_y: u32,
    copy_w: u32,
    copy_h: u32,
    dst_x: u32,
    dst_y: u32,

    /// Map the world-space node through the actual physical-pixel blit,
    /// including clipping and its destination offset in the padded texture.
    pub fn contentUv(self: BackdropCaptureRegion, node: [4]f32, scale: f32) [4]f32 {
        const tex_w: f32 = @floatFromInt(self.tex_w);
        const tex_h: f32 = @floatFromInt(self.tex_h);
        return .{
            (node[0] * scale - @as(f32, @floatFromInt(self.src_x)) + @as(f32, @floatFromInt(self.dst_x))) / tex_w,
            (node[1] * scale - @as(f32, @floatFromInt(self.src_y)) + @as(f32, @floatFromInt(self.dst_y))) / tex_h,
            node[2] * scale / tex_w,
            node[3] * scale / tex_h,
        };
    }

    pub fn coversFullTexture(self: BackdropCaptureRegion) bool {
        return self.src_x == 0 and
            self.src_y == 0 and
            self.dst_x == 0 and
            self.dst_y == 0 and
            self.copy_w == self.tex_w and
            self.copy_h == self.tex_h;
    }
};

pub fn computeBackdropCaptureRegion(
    sample_x: f32,
    sample_y: f32,
    w: f32,
    h: f32,
    scale: f32,
    clip_rect: ?[4]f32,
    /// Source texture (current RT) physical size. 0 = unknown (skip right/bottom boundary clamp,
    /// test compat only).
    src_tex_w: u32,
    src_tex_h: u32,
) ?BackdropCaptureRegion {
    if (!std.math.isFinite(sample_x) or !std.math.isFinite(sample_y) or
        !std.math.isFinite(w) or !std.math.isFinite(h) or
        !std.math.isFinite(scale) or scale <= 0 or w <= 0 or h <= 0)
    {
        return null;
    }
    if (clip_rect) |clip| {
        for (clip) |value| if (!std.math.isFinite(value)) return null;
    }
    // Texture allocation size lands in a 64px bucket (perf):
    // capture/kawase chain/glass composite sizes all derive from tex_w/tex_h (chain halves per
    // level,
    // composite same size). Glass geometry animation (morph/resize) changes exact size every frame
    // ->
    // pool never hits and every level is re-created each frame.
    // With bucketing, same-bucket frames share a texture. All UV/texel math uses
    // tex_w/tex_h as base; padded right/bottom areas follow the existing 'partial capture' path:
    // coversFullTexture()=false -> transparent clear, valid_uv clamp sample excludes pad from rim.
    const max_capture_dimension: u32 = 1 << 24;
    const exact_size = offscreen_texture.computeOffscreenTextureSize(w, h, scale, max_capture_dimension) orelse return null;
    const tex_w = offscreen_texture.bucketDimension(exact_size.width, max_capture_dimension);
    const tex_h = offscreen_texture.bucketDimension(exact_size.height, max_capture_dimension);

    const base_rect = [4]f32{
        sample_x,
        sample_y,
        @max(w, 0),
        @max(h, 0),
    };
    var visible_rect = base_rect;
    if (clip_rect) |clip| {
        visible_rect = intersectClipRects(visible_rect, clip);
    }
    // Outside current RT left/top boundary no valid backdrop; visible area must be cropped before
    // copy.
    visible_rect = intersectClipRects(visible_rect, .{ 0, 0, std.math.inf(f32), std.math.inf(f32) });
    for (visible_rect) |value| if (!std.math.isFinite(value)) return null;
    if (visible_rect[2] <= 0 or visible_rect[3] <= 0) return null;

    const src_x = finitePixelCoordinate(@floor(visible_rect[0] * scale)) orelse return null;
    const src_y = finitePixelCoordinate(@floor(visible_rect[1] * scale)) orelse return null;
    const src_x_end = finitePixelCoordinate(@ceil((visible_rect[0] + visible_rect[2]) * scale)) orelse return null;
    const src_y_end = finitePixelCoordinate(@ceil((visible_rect[1] + visible_rect[3]) * scale)) orelse return null;
    const dst_x = finitePixelCoordinate(@floor((visible_rect[0] - sample_x) * scale)) orelse return null;
    const dst_y = finitePixelCoordinate(@floor((visible_rect[1] - sample_y) * scale)) orelse return null;

    if (dst_x >= tex_w or dst_y >= tex_h) return null;

    // Right/bottom boundary clamp to source texture: glass crossing viewport bottom/right edge
    // (tile during scroll) if src overflows, blit wrapper reports InvalidTextureRegion -> caller
    // silently abandons **whole glass composite** -> node scrolled in sees only text/border 'plain'
    // (downstream app verified capture). After clamp partial capture + transparent pad fill, glass
    // enters normally.
    const src_x_end_c = if (src_tex_w > 0) @min(src_x_end, src_tex_w) else src_x_end;
    const src_y_end_c = if (src_tex_h > 0) @min(src_y_end, src_tex_h) else src_y_end;
    if (src_x >= src_x_end_c or src_y >= src_y_end_c) return null;
    const raw_copy_w = src_x_end_c - src_x;
    const raw_copy_h = src_y_end_c - src_y;
    const copy_w = @min(raw_copy_w, tex_w - dst_x);
    const copy_h = @min(raw_copy_h, tex_h - dst_y);
    if (copy_w == 0 or copy_h == 0) return null;

    return .{
        .tex_w = tex_w,
        .tex_h = tex_h,
        .src_x = src_x,
        .src_y = src_y,
        .copy_w = copy_w,
        .copy_h = copy_h,
        .dst_x = dst_x,
        .dst_y = dst_y,
    };
}

// -- tests --
// command_encoder_test.zig has 4 end-to-end region tests (clip crop / negative origin pad /
// non-finite reject / src clamp). Here: branches with no other test entry: copy rect inside
// bucket-sized texture invariant, src_tex=0 'unknown' semantic, and the two zero visible-area
// reject paths. Pixel domain primitives have boundary tests in pixel_domain.zig.

test "computeBackdropCaptureRegion: copy 矩形始终完整落在目标纹理内（dst+copy ≤ tex）" {
    // dst_x=20/copy_w, dst_y=12/copy_h negative origin pad scenario. The truncation clamp
    // (copy_w = min(raw, tex_w - dst_x)) is defensive: the visible rect is always within the
    // sample area, so raw + dst <= tex holds. This pins the **result invariant** dst + copy <= tex
    // (blit target overflow = InvalidTextureRegion = whole glass composite abandoned), not that
    // the truncation branch triggers.
    const region = computeBackdropCaptureRegion(-10, -6, 30, 20, 2, null, 0, 0).?;
    try std.testing.expectEqual(@as(u32, 64), region.tex_w);
    try std.testing.expectEqual(@as(u32, 64), region.tex_h);
    try std.testing.expectEqual(@as(u32, 20), region.dst_x);
    try std.testing.expectEqual(@as(u32, 12), region.dst_y);
    // Invariant: copy rect right/bottom edges must not exceed bucket-sized texture.
    try std.testing.expect(region.dst_x + region.copy_w <= region.tex_w);
    try std.testing.expect(region.dst_y + region.copy_h <= region.tex_h);
    // Has pad (dst non-zero origin) => necessarily not full texture coverage.
    try std.testing.expect(!region.coversFullTexture());
}

test "computeBackdropCaptureRegion: src_tex 尺寸未知(0)时跳过 clamp" {
    // src_tex_w/h = 0 is 'unknown' not 'zero-size': right/bottom clamp don't apply.
    const a = computeBackdropCaptureRegion(0, 0, 30, 20, 2, null, 0, 0).?;
    const b = computeBackdropCaptureRegion(0, 0, 30, 20, 2, null, 1_000_000, 1_000_000).?;
    // Large enough source texture clamp is no-op => both match; this is branch observable
    // semantics.
    try std.testing.expectEqual(a.copy_w, b.copy_w);
    try std.testing.expectEqual(a.copy_h, b.copy_h);
}

test "computeBackdropCaptureRegion: 采样区完全在 RT 之上（可视高 ≤ 0）返回 null" {
    // clip cropped visible area to zero -> null (not zero-size region).
    const clipped = computeBackdropCaptureRegion(0, 0, 30, 20, 2, .{ 0, 100, 10, 1 }, 0, 0);
    try std.testing.expect(clipped == null);
}

test "computeBackdropCaptureRegion: 采样区完全在 RT 左侧（可视宽 ≤ 0）返回 null" {
    // Sample window entirely outside current RT -> intersect with (0,0,inf,inf) yields zero area ->
    // null
    // (not zero-size region; caller abandons whole glass capture per this).
    const offscreen = computeBackdropCaptureRegion(-10_000, -6, 30, 20, 2, null, 0, 0);
    try std.testing.expect(offscreen == null);
}
