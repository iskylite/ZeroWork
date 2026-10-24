/// Path tessellator: CPU-side path flattening.
///
/// Flattens PathGeometry (Bezier path command stream) into line contour lists. Each contour is a
/// group of f32 vertices (x,y interleaved), a closed or open subpath.
///
/// Supports:
///   move_to / line_to / quad_to (quadratic Bezier) / close / cubic_to (adaptive subdivision)
///
/// Memory: flatten writes into tessellator-owned reusable buffers (vertex_pool / contours_buf)
/// and returns a borrowed slice; caller does not free; invalidated by the next flatten call.
/// Call deinit when destroying the tessellator.
///
/// Zig 0.15: std.ArrayList has no allocator field; append/deinit etc. take an explicit allocator.
const std = @import("std");
const Allocator = std.mem.Allocator;

/// 2D point (layout compatible with types.zig Point, avoid cross-module dependency)
pub const TPoint = struct { x: f32, y: f32 };

/// single contour: planar vertex sequence, format [x0,y0, x1,y1, ...]
pub const Contour = struct {
    vertices: []f32, // length must be even, guaranteed by tessellator
    closed: bool = false,

    pub fn pointCount(self: Contour) usize {
        return self.vertices.len / 2;
    }

    pub fn point(self: Contour, idx: usize) TPoint {
        return .{ .x = self.vertices[idx * 2], .y = self.vertices[idx * 2 + 1] };
    }
};

/// quadratic Bezier flatness threshold (pixels)
const FLATNESS_THRESHOLD: f32 = 0.5;
/// A pathological but finite curve/tolerance must not grow the recursion tree
/// without bound. 2^12 segments is already beyond useful UI-path precision.
const MAX_CURVE_SUBDIVISION_DEPTH: u8 = 12;

pub const PathTessellator = struct {
    allocator: Allocator,
    /// reusable pool for all contour vertices stored contiguously; slices returned by flatten
    /// borrow from here
    vertex_pool: std.ArrayList(f32) = .empty,
    /// record each contour's (start, len, closed); pool may reallocate during vertex writes, so
    /// record spans first and materialize slices at end
    spans: std.ArrayList(Span) = .empty,
    contours_buf: std.ArrayList(Contour) = .empty,

    const Span = struct { start: usize, len: usize, closed: bool };

    pub fn init(allocator: Allocator) PathTessellator {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *PathTessellator) void {
        self.vertex_pool.deinit(self.allocator);
        self.spans.deinit(self.allocator);
        self.contours_buf.deinit(self.allocator);
    }

    /// Flatten path commands to contour list. scale_factor: current render scale (Retina = 2.0),
    /// for adaptive threshold. Returns borrowed slice: invalidated on next flatten or deinit;
    /// caller does not free.
    pub fn flatten(
        self: *PathTessellator,
        /// PathCommand type passed at comptime to avoid circular dependency
        comptime PathCommand: type,
        commands: []const PathCommand,
        scale_factor: f32,
    ) ![]const Contour {
        const alloc = self.allocator;
        const tol = FLATNESS_THRESHOLD / @max(scale_factor, 0.001);

        self.vertex_pool.clearRetainingCapacity();
        self.spans.clearRetainingCapacity();
        self.contours_buf.clearRetainingCapacity();

        const pool = &self.vertex_pool;
        // current contour start index in pool
        var cur_start: usize = 0;

        var cur_x: f32 = 0;
        var cur_y: f32 = 0;
        // current subpath start point (last move_to). SVG semantics: after close, current point
        // returns to subpath start; subsequent L/C/Q without M implicitly start new subpath from
        // here.
        var sub_x: f32 = 0;
        var sub_y: f32 = 0;
        // after close and before next M: next draw command must prepend start vertex
        var reopen_at_start = false;

        for (commands) |cmd| {
            switch (cmd) {
                .move_to => {},
                .close => {},
                .line_to, .quad_to, .cubic_to => if (reopen_at_start) {
                    reopen_at_start = false;
                    try pool.append(alloc, sub_x);
                    try pool.append(alloc, sub_y);
                },
            }
            switch (cmd) {
                .move_to => |p| {
                    reopen_at_start = false;
                    try self.finishContour(cur_start, false);
                    cur_start = pool.items.len;
                    if (!std.math.isFinite(p.x) or !std.math.isFinite(p.y)) {
                        cur_x = 0;
                        cur_y = 0;
                        sub_x = 0;
                        sub_y = 0;
                        continue;
                    }
                    // new contour start point
                    try pool.append(alloc, p.x);
                    try pool.append(alloc, p.y);
                    cur_x = p.x;
                    cur_y = p.y;
                    sub_x = p.x;
                    sub_y = p.y;
                },
                .line_to => |p| {
                    if (!std.math.isFinite(p.x) or !std.math.isFinite(p.y)) continue;
                    try pool.append(alloc, p.x);
                    try pool.append(alloc, p.y);
                    cur_x = p.x;
                    cur_y = p.y;
                },
                .quad_to => |q| {
                    // adaptive quadratic Bezier subdivision
                    try flattenQuad(
                        alloc,
                        pool,
                        cur_x,
                        cur_y,
                        q.ctrl.x,
                        q.ctrl.y,
                        q.end.x,
                        q.end.y,
                        tol,
                        0,
                    );
                    if (std.math.isFinite(q.end.x) and std.math.isFinite(q.end.y)) {
                        cur_x = q.end.x;
                        cur_y = q.end.y;
                    }
                },
                .cubic_to => |c| {
                    // adaptive cubic Bezier subdivision (de Casteljau)
                    try flattenCubic(
                        alloc,
                        pool,
                        cur_x,
                        cur_y,
                        c.ctrl1.x,
                        c.ctrl1.y,
                        c.ctrl2.x,
                        c.ctrl2.y,
                        c.end.x,
                        c.end.y,
                        tol,
                        0,
                    );
                    if (std.math.isFinite(c.end.x) and std.math.isFinite(c.end.y)) {
                        cur_x = c.end.x;
                        cur_y = c.end.y;
                    }
                },
                .close => {
                    try self.finishContour(cur_start, true);
                    cur_start = pool.items.len;
                    // return to subpath start, not origin: if previously (0,0), direct L/C after Z
                    // draws spike from origin
                    cur_x = sub_x;
                    cur_y = sub_y;
                    reopen_at_start = true;
                },
            }
        }

        // save last unclosed contour
        try self.finishContour(cur_start, false);

        // materialize: pool stops growing here, slices stable until next flatten
        try self.contours_buf.ensureTotalCapacity(alloc, self.spans.items.len);
        for (self.spans.items) |span| {
            self.contours_buf.appendAssumeCapacity(.{
                .vertices = self.vertex_pool.items[span.start .. span.start + span.len],
                .closed = span.closed,
            });
        }
        return self.contours_buf.items;
    }

    /// end current contour: if >= 2 points, record span; otherwise roll back pool and discard
    fn finishContour(self: *PathTessellator, cur_start: usize, closed: bool) !void {
        const len = self.vertex_pool.items.len - cur_start;
        if (len >= 4) {
            try self.spans.append(self.allocator, .{ .start = cur_start, .len = len, .closed = closed });
        } else {
            self.vertex_pool.shrinkRetainingCapacity(cur_start);
        }
    }
};

/// adaptive quadratic Bezier subdivision (de Casteljau). p0=(x0,y0) p1=(cx,cy) p2=(ex,ey). Output
/// points appended to `out` (excludes start, includes end).
fn flattenQuad(
    alloc: Allocator,
    out: *std.ArrayList(f32),
    x0: f32,
    y0: f32,
    cx: f32,
    cy: f32,
    ex: f32,
    ey: f32,
    tol: f32,
    depth: u8,
) !void {
    if (!std.math.isFinite(x0) or !std.math.isFinite(y0) or
        !std.math.isFinite(cx) or !std.math.isFinite(cy) or
        !std.math.isFinite(ex) or !std.math.isFinite(ey) or
        !std.math.isFinite(tol) or tol <= 0 or depth >= MAX_CURVE_SUBDIVISION_DEPTH)
    {
        return appendFiniteEndpoint(alloc, out, ex, ey);
    }

    // curve midpoint
    const mx = (x0 + 2.0 * cx + ex) * 0.25;
    const my = (y0 + 2.0 * cy + ey) * 0.25;
    // chord midpoint
    const lx = (x0 + ex) * 0.5;
    const ly = (y0 + ey) * 0.5;

    const dx = mx - lx;
    const dy = my - ly;
    const dist2 = dx * dx + dy * dy;

    if (!std.math.isFinite(dist2) or dist2 <= tol * tol) {
        // flat enough, output end point directly
        try out.append(alloc, ex);
        try out.append(alloc, ey);
        return;
    }

    // Subdivide: left half + right half
    const m01x = (x0 + cx) * 0.5;
    const m01y = (y0 + cy) * 0.5;
    const m12x = (cx + ex) * 0.5;
    const m12y = (cy + ey) * 0.5;
    const mmx = (m01x + m12x) * 0.5;
    const mmy = (m01y + m12y) * 0.5;

    try flattenQuad(alloc, out, x0, y0, m01x, m01y, mmx, mmy, tol, depth + 1);
    try flattenQuad(alloc, out, mmx, mmy, m12x, m12y, ex, ey, tol, depth + 1);
}

/// Adaptive cubic Bezier subdivision (de Casteljau)
///
/// p0=(x0,y0)  p1=(c1x,c1y)  p2=(c2x,c2y)  p3=(ex,ey)
/// Flatness: max distance from control points to chord < tol
/// Output points appended to `out` (excludes start, includes end).
fn flattenCubic(
    alloc: Allocator,
    out: *std.ArrayList(f32),
    x0: f32,
    y0: f32,
    c1x: f32,
    c1y: f32,
    c2x: f32,
    c2y: f32,
    ex: f32,
    ey: f32,
    tol: f32,
    depth: u8,
) !void {
    if (!std.math.isFinite(x0) or !std.math.isFinite(y0) or
        !std.math.isFinite(c1x) or !std.math.isFinite(c1y) or
        !std.math.isFinite(c2x) or !std.math.isFinite(c2y) or
        !std.math.isFinite(ex) or !std.math.isFinite(ey) or
        !std.math.isFinite(tol) or tol <= 0 or depth >= MAX_CURVE_SUBDIVISION_DEPTH)
    {
        return appendFiniteEndpoint(alloc, out, ex, ey);
    }

    // Use sum of both control point distances to chord as flatness metric (more conservative than
    // max, but simple/fast)
    // Chord vector
    const chord_dx = ex - x0;
    const chord_dy = ey - y0;
    const chord_len2 = chord_dx * chord_dx + chord_dy * chord_dy;

    var flat = false;
    if (!std.math.isFinite(chord_len2) or chord_len2 < 1e-10) {
        // Degenerates to point, output directly
        flat = true;
    } else {
        // Perpendicular distance from control point to chord (using cross product)
        const inv_chord = 1.0 / @sqrt(chord_len2);
        const d1 = @abs((c1x - x0) * chord_dy * inv_chord - (c1y - y0) * chord_dx * inv_chord);
        const d2 = @abs((c2x - x0) * chord_dy * inv_chord - (c2y - y0) * chord_dx * inv_chord);
        flat = (d1 + d2) <= tol;
    }

    if (flat) {
        try out.append(alloc, ex);
        try out.append(alloc, ey);
        return;
    }

    // de Casteljau subdivide at t=0.5
    const m01x = (x0 + c1x) * 0.5;
    const m01y = (y0 + c1y) * 0.5;
    const m12x = (c1x + c2x) * 0.5;
    const m12y = (c1y + c2y) * 0.5;
    const m23x = (c2x + ex) * 0.5;
    const m23y = (c2y + ey) * 0.5;

    const mm012x = (m01x + m12x) * 0.5;
    const mm012y = (m01y + m12y) * 0.5;
    const mm123x = (m12x + m23x) * 0.5;
    const mm123y = (m12y + m23y) * 0.5;

    const midx = (mm012x + mm123x) * 0.5;
    const midy = (mm012y + mm123y) * 0.5;

    try flattenCubic(alloc, out, x0, y0, m01x, m01y, mm012x, mm012y, midx, midy, tol, depth + 1);
    try flattenCubic(alloc, out, midx, midy, mm123x, mm123y, m23x, m23y, ex, ey, tol, depth + 1);
}

fn appendFiniteEndpoint(alloc: Allocator, out: *std.ArrayList(f32), x: f32, y: f32) !void {
    if (!std.math.isFinite(x) or !std.math.isFinite(y)) return;
    try out.append(alloc, x);
    try out.append(alloc, y);
}

// ============================================================================
// Unit tests
// ============================================================================

const TestPoint = struct { x: f32, y: f32 };
const TestPathCommand = union(enum) {
    move_to: TestPoint,
    line_to: TestPoint,
    quad_to: struct { ctrl: TestPoint, end: TestPoint },
    cubic_to: struct { ctrl1: TestPoint, ctrl2: TestPoint, end: TestPoint },
    close: void,
};

test "close 后无 move_to 的 line_to 从子路径起点续画（不从原点拉尖刺）" {
    const alloc = std.testing.allocator;
    var tess = PathTessellator.init(alloc);
    defer tess.deinit();

    // M50,50 L60,50 L60,60 Z L70,70, SVG semantics: second segment starts at (50,50)
    const cmds = [_]TestPathCommand{
        .{ .move_to = .{ .x = 50, .y = 50 } },
        .{ .line_to = .{ .x = 60, .y = 50 } },
        .{ .line_to = .{ .x = 60, .y = 60 } },
        .close,
        .{ .line_to = .{ .x = 70, .y = 70 } },
        .{ .quad_to = .{ .ctrl = .{ .x = 80, .y = 60 }, .end = .{ .x = 90, .y = 70 } } },
    };
    const contours = try tess.flatten(TestPathCommand, &cmds, 1.0);
    try std.testing.expectEqual(@as(usize, 2), contours.len);
    try std.testing.expect(contours[0].closed);
    const second = contours[1];
    try std.testing.expect(!second.closed);
    // Start is subpath start (50,50)
    try std.testing.expectEqual(@as(f32, 50), second.vertices[0]);
    try std.testing.expectEqual(@as(f32, 50), second.vertices[1]);
    // No vertex near origin (old bug: curve start took (0,0))
    var k: usize = 0;
    while (k < second.vertices.len) : (k += 2) {
        try std.testing.expect(second.vertices[k] >= 50 and second.vertices[k + 1] >= 50);
    }
}

test "flatten straight lines forms one contour with 4 points" {
    const alloc = std.testing.allocator;
    var tess = PathTessellator.init(alloc);
    defer tess.deinit();

    const cmds = [_]TestPathCommand{
        .{ .move_to = .{ .x = 0, .y = 0 } },
        .{ .line_to = .{ .x = 10, .y = 0 } },
        .{ .line_to = .{ .x = 10, .y = 10 } },
        .{ .line_to = .{ .x = 0, .y = 10 } },
        .close,
    };

    const contours = try tess.flatten(TestPathCommand, &cmds, 1.0);

    try std.testing.expectEqual(@as(usize, 1), contours.len);
    try std.testing.expectEqual(@as(usize, 4), contours[0].pointCount());
    try std.testing.expect(contours[0].closed);
}

test "flatten quad bezier subdivides to multiple points" {
    const alloc = std.testing.allocator;
    var tess = PathTessellator.init(alloc);
    defer tess.deinit();

    // 90-degree arc approximation: from (0,0) via control (50,0) to (50,50)
    const cmds = [_]TestPathCommand{
        .{ .move_to = .{ .x = 0, .y = 0 } },
        .{ .quad_to = .{ .ctrl = .{ .x = 50, .y = 0 }, .end = .{ .x = 50, .y = 50 } } },
        .close,
    };

    const contours = try tess.flatten(TestPathCommand, &cmds, 1.0);

    try std.testing.expectEqual(@as(usize, 1), contours.len);
    // 50px span, post-subdivision point count should > 2 (start + multiple subdivisions)
    try std.testing.expect(contours[0].pointCount() > 2);
    try std.testing.expect(contours[0].closed);
}

test "two subpaths from two move_to" {
    const alloc = std.testing.allocator;
    var tess = PathTessellator.init(alloc);
    defer tess.deinit();

    const cmds = [_]TestPathCommand{
        .{ .move_to = .{ .x = 0, .y = 0 } },
        .{ .line_to = .{ .x = 10, .y = 0 } },
        .{ .line_to = .{ .x = 10, .y = 10 } },
        .close,
        .{ .move_to = .{ .x = 20, .y = 20 } },
        .{ .line_to = .{ .x = 30, .y = 20 } },
        .{ .line_to = .{ .x = 30, .y = 30 } },
        .close,
    };

    const contours = try tess.flatten(TestPathCommand, &cmds, 1.0);

    try std.testing.expectEqual(@as(usize, 2), contours.len);
    try std.testing.expect(contours[0].closed);
    try std.testing.expect(contours[1].closed);
}

test "flatten cubic bezier produces more points than endpoints only" {
    const alloc = std.testing.allocator;
    var tess = PathTessellator.init(alloc);
    defer tess.deinit();

    // S-curve cubic Bezier: from (0,0) via (0,100),(100,0) to (100,100)
    const cmds = [_]TestPathCommand{
        .{ .move_to = .{ .x = 0, .y = 0 } },
        .{ .cubic_to = .{
            .ctrl1 = .{ .x = 0, .y = 100 },
            .ctrl2 = .{ .x = 100, .y = 0 },
            .end = .{ .x = 100, .y = 100 },
        } },
        .close,
    };

    const contours = try tess.flatten(TestPathCommand, &cmds, 1.0);

    try std.testing.expectEqual(@as(usize, 1), contours.len);
    // 100px S-curve should subdivide to multiple points
    try std.testing.expect(contours[0].pointCount() > 3);
    try std.testing.expect(contours[0].closed);
}

test "open polyline contour preserves non-closed state" {
    const alloc = std.testing.allocator;
    var tess = PathTessellator.init(alloc);
    defer tess.deinit();

    const cmds = [_]TestPathCommand{
        .{ .move_to = .{ .x = 0, .y = 0 } },
        .{ .line_to = .{ .x = 10, .y = 5 } },
        .{ .line_to = .{ .x = 20, .y = 0 } },
    };

    const contours = try tess.flatten(TestPathCommand, &cmds, 1.0);

    try std.testing.expectEqual(@as(usize, 1), contours.len);
    try std.testing.expectEqual(@as(usize, 3), contours[0].pointCount());
    try std.testing.expect(!contours[0].closed);
}

test "repeated flatten reuses buffers and stays correct" {
    const alloc = std.testing.allocator;
    var tess = PathTessellator.init(alloc);
    defer tess.deinit();

    const square = [_]TestPathCommand{
        .{ .move_to = .{ .x = 0, .y = 0 } },
        .{ .line_to = .{ .x = 10, .y = 0 } },
        .{ .line_to = .{ .x = 10, .y = 10 } },
        .{ .line_to = .{ .x = 0, .y = 10 } },
        .close,
    };
    const tri = [_]TestPathCommand{
        .{ .move_to = .{ .x = 5, .y = 5 } },
        .{ .line_to = .{ .x = 15, .y = 5 } },
        .{ .line_to = .{ .x = 10, .y = 15 } },
        .close,
    };

    // Second flatten invalidates previous result, must itself still work
    for (0..3) |_| {
        const a = try tess.flatten(TestPathCommand, &square, 1.0);
        try std.testing.expectEqual(@as(usize, 1), a.len);
        try std.testing.expectEqual(@as(usize, 4), a[0].pointCount());
        const b = try tess.flatten(TestPathCommand, &tri, 1.0);
        try std.testing.expectEqual(@as(usize, 1), b.len);
        try std.testing.expectEqual(@as(usize, 3), b[0].pointCount());
        try std.testing.expectEqual(@as(f32, 5), b[0].point(0).x);
    }
}

test "degenerate contour before move_to is discarded and pool rewinds" {
    const alloc = std.testing.allocator;
    var tess = PathTessellator.init(alloc);
    defer tess.deinit();

    const cmds = [_]TestPathCommand{
        .{ .move_to = .{ .x = 99, .y = 99 } }, // Single-point contour, should discard
        .{ .move_to = .{ .x = 0, .y = 0 } },
        .{ .line_to = .{ .x = 10, .y = 0 } },
        .{ .line_to = .{ .x = 10, .y = 10 } },
        .close,
    };

    const contours = try tess.flatten(TestPathCommand, &cmds, 1.0);
    try std.testing.expectEqual(@as(usize, 1), contours.len);
    try std.testing.expectEqual(@as(usize, 3), contours[0].pointCount());
    try std.testing.expectEqual(@as(f32, 0), contours[0].point(0).x);
}

test "non-finite and overflowing curves terminate with finite output" {
    const alloc = std.testing.allocator;
    var tess = PathTessellator.init(alloc);
    defer tess.deinit();

    const cmds = [_]TestPathCommand{
        .{ .move_to = .{ .x = 0, .y = 0 } },
        .{ .quad_to = .{
            .ctrl = .{ .x = std.math.nan(f32), .y = 10 },
            .end = .{ .x = 10, .y = 10 },
        } },
        .{ .cubic_to = .{
            .ctrl1 = .{ .x = 3.0e38, .y = 3.0e38 },
            .ctrl2 = .{ .x = -3.0e38, .y = -3.0e38 },
            .end = .{ .x = 20, .y = 20 },
        } },
        .{ .line_to = .{ .x = 30, .y = 0 } },
        .close,
    };

    const contours = try tess.flatten(TestPathCommand, &cmds, 1.0);
    try std.testing.expectEqual(@as(usize, 1), contours.len);
    try std.testing.expect(contours[0].pointCount() <= 3 + (@as(usize, 1) << MAX_CURVE_SUBDIVISION_DEPTH));
    for (contours[0].vertices) |value| try std.testing.expect(std.math.isFinite(value));
}
