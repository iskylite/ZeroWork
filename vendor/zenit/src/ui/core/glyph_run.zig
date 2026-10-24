//! GlyphRun + cluster map: cluster-aware text layout data structure.
//!
//! The old ASCII-first measure API returns a single f32 advance and loses:
//! - char -> glyph cluster map (complex script: 1 cluster = N codepoints / N
//!   glyphs)
//! - per-glyph advance + offset
//! - direction (RTL: glyph order != logical order)
//! - baseline metrics (ascent/descent/line_gap) for mixed font size alignment
//!
//! GlyphRun is a normalized IR of TextShaper.shape() output; it preserves cluster_map
//! so cursor xToCluster is monotone and shaping is consistent.
//!
//! Design refs:
//! - HarfBuzz hb_buffer / hb_glyph_info_t / hb_glyph_position_t
//! - CoreText CTRun / CTRunGetGlyphCount + CTRunGetStringIndices
//! - Skia SkShaper RunIterator
//!
//! Pitfalls:
//! - **Don't** let GlyphRun own []Glyph (only reference the ShapingCache slice)
//! - **Don't** use codepoint index as cursor position (use cluster index)
//! - **Don't** ignore direction: for an RTL run glyph_x is visual position, cluster
//!   order is logical

const std = @import("std");
const testing = std.testing;

pub const Direction = enum(u8) { ltr, rtl };

/// One glyph's position + advance (HarfBuzz style).
pub const GlyphPosition = struct {
    /// Glyph id (font-specific).
    glyph_id: u32,
    /// X advance (how far right to next glyph position).
    x_advance: f32,
    /// Y advance (for vertical writing; 0 for horizontal).
    y_advance: f32 = 0,
    /// X offset (glyph offset from baseline start; not advance).
    x_offset: f32 = 0,
    /// y offset
    y_offset: f32 = 0,
};

/// Cluster map entry: lookup glyph index range by codepoint index.
pub const Cluster = struct {
    /// Start byte offset of cluster in original utf-8 byte stream.
    byte_offset: u32,
    /// Start index in glyphs array for this cluster.
    glyph_start: u32,
    /// End index in glyphs array for this cluster (exclusive).
    glyph_end: u32,
};

/// Font metrics (pixel space).
pub const FontMetrics = struct {
    /// Height above baseline (positive).
    ascent: f32,
    /// Height below baseline (positive).
    descent: f32,
    /// Line gap (extra space from baseline to next baseline).
    line_gap: f32,
    /// Font size (used to recalculate metrics).
    font_size: f32,

    /// Line height = ascent + descent + line_gap for this metrics.
    pub fn lineHeight(self: FontMetrics) f32 {
        return self.ascent + self.descent + self.line_gap;
    }
};

/// Complete shaping result: text with consistent (font, direction, script).
pub const GlyphRun = struct {
    /// Glyph sequence (visual order: LTR is logical order; RTL is reversed visual
    /// order).
    glyphs: []const GlyphPosition,
    /// Cluster map (sorted by byte_offset, regardless of direction).
    clusters: []const Cluster,
    /// Font metrics.
    metrics: FontMetrics,
    /// Text direction.
    direction: Direction = .ltr,
    /// Total X advance (sum of all glyph advances).
    total_advance: f32 = 0,

    /// Given original byte position, find corresponding cluster index. Return that
    /// cluster's glyph_start. RTL caller should reverse-calculate visual x.
    pub fn clusterAt(self: GlyphRun, byte: u32) ?u32 {
        // Clusters sorted by byte_offset; binary search.
        var lo: usize = 0;
        var hi: usize = self.clusters.len;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            const c = self.clusters[mid];
            if (c.byte_offset <= byte) {
                if (mid + 1 == self.clusters.len or self.clusters[mid + 1].byte_offset > byte) {
                    return @intCast(mid);
                }
                lo = mid + 1;
            } else {
                hi = mid;
            }
        }
        return null;
    }

    /// Given visual x (local space, run start = 0), find corresponding cluster
    /// index. Monotone accumulate advances; for LTR. RTL caller reverses x input.
    pub fn xToCluster(self: GlyphRun, x: f32) u32 {
        if (self.clusters.len == 0) return 0;
        if (x <= 0) return 0;

        var cur_x: f32 = 0;
        for (self.clusters, 0..) |cluster, idx| {
            // Cluster width = sum of advances of its glyphs.
            var cluster_w: f32 = 0;
            var gi = cluster.glyph_start;
            while (gi < cluster.glyph_end) : (gi += 1) {
                if (gi >= self.glyphs.len) break;
                cluster_w += self.glyphs[gi].x_advance;
            }
            // Does x fall in this cluster?
            if (x < cur_x + cluster_w / 2.0) return @intCast(idx);
            cur_x += cluster_w;
        }
        return @intCast(self.clusters.len);
    }
};

// ============================================================================
// Tests
// ============================================================================

test "FontMetrics.lineHeight" {
    const m = FontMetrics{ .ascent = 12, .descent = 4, .line_gap = 2, .font_size = 14 };
    try testing.expectEqual(@as(f32, 18), m.lineHeight());
}

test "GlyphRun.clusterAt: byte offset → cluster idx" {
    const glyphs = [_]GlyphPosition{
        .{ .glyph_id = 1, .x_advance = 10 },
        .{ .glyph_id = 2, .x_advance = 12 },
        .{ .glyph_id = 3, .x_advance = 11 },
    };
    const clusters = [_]Cluster{
        .{ .byte_offset = 0, .glyph_start = 0, .glyph_end = 1 }, // 'h' at byte 0
        .{ .byte_offset = 1, .glyph_start = 1, .glyph_end = 2 }, // 'i' at byte 1
        .{ .byte_offset = 2, .glyph_start = 2, .glyph_end = 3 }, // '!' at byte 2
    };
    const run = GlyphRun{
        .glyphs = &glyphs,
        .clusters = &clusters,
        .metrics = .{ .ascent = 12, .descent = 4, .line_gap = 2, .font_size = 14 },
    };

    try testing.expectEqual(@as(u32, 0), run.clusterAt(0).?);
    try testing.expectEqual(@as(u32, 1), run.clusterAt(1).?);
    try testing.expectEqual(@as(u32, 2), run.clusterAt(2).?);
}

test "GlyphRun.clusterAt: byte beyond text → last cluster" {
    const clusters = [_]Cluster{
        .{ .byte_offset = 0, .glyph_start = 0, .glyph_end = 1 },
        .{ .byte_offset = 5, .glyph_start = 1, .glyph_end = 2 },
    };
    const run = GlyphRun{
        .glyphs = &.{},
        .clusters = &clusters,
        .metrics = .{ .ascent = 0, .descent = 0, .line_gap = 0, .font_size = 14 },
    };
    try testing.expectEqual(@as(u32, 1), run.clusterAt(100).?);
}

test "GlyphRun.xToCluster: x=0 → cluster 0" {
    const glyphs = [_]GlyphPosition{
        .{ .glyph_id = 1, .x_advance = 10 },
        .{ .glyph_id = 2, .x_advance = 10 },
    };
    const clusters = [_]Cluster{
        .{ .byte_offset = 0, .glyph_start = 0, .glyph_end = 1 },
        .{ .byte_offset = 1, .glyph_start = 1, .glyph_end = 2 },
    };
    const run = GlyphRun{
        .glyphs = &glyphs,
        .clusters = &clusters,
        .metrics = .{ .ascent = 0, .descent = 0, .line_gap = 0, .font_size = 14 },
    };
    try testing.expectEqual(@as(u32, 0), run.xToCluster(0));
}

test "GlyphRun.xToCluster: x at half of cluster 0 → cluster 0" {
    const glyphs = [_]GlyphPosition{
        .{ .glyph_id = 1, .x_advance = 10 },
        .{ .glyph_id = 2, .x_advance = 10 },
    };
    const clusters = [_]Cluster{
        .{ .byte_offset = 0, .glyph_start = 0, .glyph_end = 1 },
        .{ .byte_offset = 1, .glyph_start = 1, .glyph_end = 2 },
    };
    const run = GlyphRun{
        .glyphs = &glyphs,
        .clusters = &clusters,
        .metrics = .{ .ascent = 0, .descent = 0, .line_gap = 0, .font_size = 14 },
    };
    // x=4 in cluster 0 (width 10), midpoint = 5; 4 < 5 -> still cluster 0
    try testing.expectEqual(@as(u32, 0), run.xToCluster(4));
}

test "GlyphRun.xToCluster: x past midpoint of cluster 0 → cluster 1" {
    const glyphs = [_]GlyphPosition{
        .{ .glyph_id = 1, .x_advance = 10 },
        .{ .glyph_id = 2, .x_advance = 10 },
    };
    const clusters = [_]Cluster{
        .{ .byte_offset = 0, .glyph_start = 0, .glyph_end = 1 },
        .{ .byte_offset = 1, .glyph_start = 1, .glyph_end = 2 },
    };
    const run = GlyphRun{
        .glyphs = &glyphs,
        .clusters = &clusters,
        .metrics = .{ .ascent = 0, .descent = 0, .line_gap = 0, .font_size = 14 },
    };
    // x=8 past cluster 0 midpoint (5) -> cluster 1
    try testing.expectEqual(@as(u32, 1), run.xToCluster(8));
}

test "GlyphRun.xToCluster: complex cluster (1 codepoint, 2 glyphs)" {
    // Simulate Arabic combination: 1 cluster = 2 glyphs.
    const glyphs = [_]GlyphPosition{
        .{ .glyph_id = 1, .x_advance = 5 },
        .{ .glyph_id = 2, .x_advance = 5 },
        .{ .glyph_id = 3, .x_advance = 12 },
    };
    const clusters = [_]Cluster{
        .{ .byte_offset = 0, .glyph_start = 0, .glyph_end = 2 }, // First cluster: 2 glyphs, width 10.
        .{ .byte_offset = 2, .glyph_start = 2, .glyph_end = 3 }, // Second cluster: 1 glyph, width 12.
    };
    const run = GlyphRun{
        .glyphs = &glyphs,
        .clusters = &clusters,
        .metrics = .{ .ascent = 0, .descent = 0, .line_gap = 0, .font_size = 14 },
    };
    // x=4 in cluster 0 (midpoint=5) -> 0.
    try testing.expectEqual(@as(u32, 0), run.xToCluster(4));
    // x=8 past cluster 0 midpoint -> 1.
    try testing.expectEqual(@as(u32, 1), run.xToCluster(8));
}

test "GlyphRun.xToCluster: empty clusters → 0" {
    const run = GlyphRun{
        .glyphs = &.{},
        .clusters = &.{},
        .metrics = .{ .ascent = 0, .descent = 0, .line_gap = 0, .font_size = 14 },
    };
    try testing.expectEqual(@as(u32, 0), run.xToCluster(50));
}
