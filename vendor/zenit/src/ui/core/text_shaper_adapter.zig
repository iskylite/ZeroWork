//! TextShaper -> GlyphRun adapter (start of the GlyphRun pipeline)
//!
//! `src/text/types.zig.ShapedGlyph` is low-level per-glyph shaping output, including a cluster
//! field (utf-8 byte offset). Zenit IR `GlyphRun` (src/ui/core/glyph_run.zig) is the high-level
//! aggregate: glyph sequence + cluster_map (byte_offset -> glyph index range) + FontMetrics +
//! total_advance.
//!
//! This adapter only translates format and calls no platform APIs, so ui_core needs no native
//! bridge link (except where the cx.shapeText entry actually calls TextShaper.shape()).

const std = @import("std");
const text_module = @import("text");
const ShapedGlyph = text_module.ShapedGlyph;

const glyph_run_mod = @import("glyph_run.zig");
const GlyphRun = glyph_run_mod.GlyphRun;
const GlyphPosition = glyph_run_mod.GlyphPosition;
const Cluster = glyph_run_mod.Cluster;
const FontMetrics = glyph_run_mod.FontMetrics;
const Direction = glyph_run_mod.Direction;

/// Translate TextShaper.shape() output + font metrics into GlyphRun.
///
/// Memory: glyphs/clusters slices are allocated with the caller-provided allocator; the caller
/// manages lifecycle (typically ShapingCache stores both slices in its arena for later reads).
///
/// Cluster aggregation: a run of ShapedGlyph where **adjacent glyphs share a cluster byte_offset**
/// forms one cluster (complex script: 1 cluster = N glyphs).
pub fn fromShapedGlyphs(
    allocator: std.mem.Allocator,
    shaped: []const ShapedGlyph,
    metrics: FontMetrics,
    direction: Direction,
) !GlyphRun {
    if (shaped.len == 0) {
        return GlyphRun{
            .glyphs = &.{},
            .clusters = &.{},
            .metrics = metrics,
            .direction = direction,
            .total_advance = 0,
        };
    }

    // 1) glyphs slice: 1:1 translation direct, accumulate total_advance
    const glyphs = try allocator.alloc(GlyphPosition, shaped.len);
    errdefer allocator.free(glyphs);
    var total: f32 = 0;
    for (shaped, 0..) |g, i| {
        glyphs[i] = .{
            .glyph_id = g.glyph_index,
            .x_advance = g.x_advance,
            .y_advance = g.y_advance,
            .x_offset = g.x_offset,
            .y_offset = g.y_offset,
        };
        total += g.x_advance;
    }

    // 2) cluster map: segment by byte_offset. First pass count clusters.
    var cluster_count: usize = 1;
    var prev_cluster = shaped[0].cluster;
    for (shaped[1..]) |g| {
        if (g.cluster != prev_cluster) {
            cluster_count += 1;
            prev_cluster = g.cluster;
        }
    }

    const clusters = try allocator.alloc(Cluster, cluster_count);
    errdefer allocator.free(clusters);

    // 3) Second pass fill cluster ranges
    var ci: usize = 0;
    var run_start: u32 = 0;
    prev_cluster = shaped[0].cluster;
    for (shaped[1..], 1..) |g, i| {
        if (g.cluster != prev_cluster) {
            clusters[ci] = .{
                .byte_offset = prev_cluster,
                .glyph_start = run_start,
                .glyph_end = @intCast(i),
            };
            ci += 1;
            run_start = @intCast(i);
            prev_cluster = g.cluster;
        }
    }
    // Finalize last cluster
    clusters[ci] = .{
        .byte_offset = prev_cluster,
        .glyph_start = run_start,
        .glyph_end = @intCast(shaped.len),
    };

    return GlyphRun{
        .glyphs = glyphs,
        .clusters = clusters,
        .metrics = metrics,
        .direction = direction,
        .total_advance = total,
    };
}

// ============================================================================
// Tests
// ============================================================================

const testing = std.testing;

test "fromShapedGlyphs: empty input → empty run" {
    const run = try fromShapedGlyphs(
        testing.allocator,
        &.{},
        .{ .ascent = 12, .descent = 4, .line_gap = 2, .font_size = 14 },
        .ltr,
    );
    try testing.expectEqual(@as(usize, 0), run.glyphs.len);
    try testing.expectEqual(@as(usize, 0), run.clusters.len);
    try testing.expectEqual(@as(f32, 0), run.total_advance);
}

test "fromShapedGlyphs: simple ASCII (1 cluster per glyph)" {
    const shaped = [_]ShapedGlyph{
        .{ .glyph_index = 1, .cluster = 0, .x_advance = 10, .y_advance = 0, .x_offset = 0, .y_offset = 0 },
        .{ .glyph_index = 2, .cluster = 1, .x_advance = 11, .y_advance = 0, .x_offset = 0, .y_offset = 0 },
        .{ .glyph_index = 3, .cluster = 2, .x_advance = 12, .y_advance = 0, .x_offset = 0, .y_offset = 0 },
    };
    const run = try fromShapedGlyphs(
        testing.allocator,
        &shaped,
        .{ .ascent = 12, .descent = 4, .line_gap = 2, .font_size = 14 },
        .ltr,
    );
    defer testing.allocator.free(run.glyphs);
    defer testing.allocator.free(run.clusters);

    try testing.expectEqual(@as(usize, 3), run.glyphs.len);
    try testing.expectEqual(@as(usize, 3), run.clusters.len);
    try testing.expectEqual(@as(f32, 33), run.total_advance);

    // One glyph per cluster
    try testing.expectEqual(@as(u32, 0), run.clusters[0].byte_offset);
    try testing.expectEqual(@as(u32, 0), run.clusters[0].glyph_start);
    try testing.expectEqual(@as(u32, 1), run.clusters[0].glyph_end);
    try testing.expectEqual(@as(u32, 2), run.clusters[2].byte_offset);
    try testing.expectEqual(@as(u32, 2), run.clusters[2].glyph_start);
    try testing.expectEqual(@as(u32, 3), run.clusters[2].glyph_end);
}

test "fromShapedGlyphs: complex cluster (1 cluster = 2 glyphs)" {
    // Simulate emoji ZWJ sequence: 2 glyphs share cluster=0
    const shaped = [_]ShapedGlyph{
        .{ .glyph_index = 100, .cluster = 0, .x_advance = 16, .y_advance = 0, .x_offset = 0, .y_offset = 0 },
        .{ .glyph_index = 200, .cluster = 0, .x_advance = 0, .y_advance = 0, .x_offset = 0, .y_offset = 0 },
        .{ .glyph_index = 5, .cluster = 8, .x_advance = 10, .y_advance = 0, .x_offset = 0, .y_offset = 0 },
    };
    const run = try fromShapedGlyphs(
        testing.allocator,
        &shaped,
        .{ .ascent = 12, .descent = 4, .line_gap = 2, .font_size = 14 },
        .ltr,
    );
    defer testing.allocator.free(run.glyphs);
    defer testing.allocator.free(run.clusters);

    try testing.expectEqual(@as(usize, 3), run.glyphs.len);
    try testing.expectEqual(@as(usize, 2), run.clusters.len);
    try testing.expectEqual(@as(f32, 26), run.total_advance);

    // cluster 0: 2 glyphs (100 + 200)
    try testing.expectEqual(@as(u32, 0), run.clusters[0].byte_offset);
    try testing.expectEqual(@as(u32, 0), run.clusters[0].glyph_start);
    try testing.expectEqual(@as(u32, 2), run.clusters[0].glyph_end);

    // cluster 1: 1 glyph (after byte 8)
    try testing.expectEqual(@as(u32, 8), run.clusters[1].byte_offset);
    try testing.expectEqual(@as(u32, 2), run.clusters[1].glyph_start);
    try testing.expectEqual(@as(u32, 3), run.clusters[1].glyph_end);
}
