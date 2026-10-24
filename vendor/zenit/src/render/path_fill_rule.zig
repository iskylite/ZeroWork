//! Fill-rule aware planning for multi-contour path fills.
//!
//! Ear clipping triangulates one simple polygon. A path with several contours
//! (a ring, the letter O, an icon with a cut-out) is a set of nested contours
//! whose filled regions depend on the fill rule. `plan` assigns every contour a
//! role from the nesting tree; `bridgeHoles` joins an outer contour and its
//! holes into one weakly simple polygon (earcut's hole elimination) that the
//! ear clipper can triangulate.
//!
//! Assumes contours do not cross one another (nesting is decided by one vertex);
//! a self-intersecting single contour keeps the previous per-contour behaviour.

const std = @import("std");

pub const Point = @import("path_tessellator.zig").TPoint;

pub const FillRule = enum { evenodd, nonzero };

pub const Role = enum {
    /// Same fill on both sides: not a boundary (or degenerate).
    skip,
    /// Encloses a filled region bounded outside by an unfilled one.
    outer,
    /// Encloses an unfilled region inside a filled one; `owner` is its outer.
    hole,
};

pub const Plan = struct {
    roles: []Role,
    owner: []u32,

    pub fn deinit(self: Plan, allocator: std.mem.Allocator) void {
        allocator.free(self.roles);
        allocator.free(self.owner);
    }
};

/// Twice the signed area (positive for the orientation `ensureCCW` produces).
pub fn signedArea2(ring: []const Point) f32 {
    var area2: f32 = 0;
    for (ring, 0..) |p, i| {
        const q = ring[(i + 1) % ring.len];
        area2 += p.x * q.y - q.x * p.y;
    }
    return area2;
}

fn pointInRing(p: Point, ring: []const Point) bool {
    var inside = false;
    var j = ring.len - 1;
    for (ring, 0..) |a, i| {
        const b = ring[j];
        if ((a.y > p.y) != (b.y > p.y)) {
            const x = (b.x - a.x) * (p.y - a.y) / (b.y - a.y) + a.x;
            if (p.x < x) inside = !inside;
        }
        j = i;
    }
    return inside;
}

/// Roles of `rings` under `rule`. The region inside a contour has winding
/// number parent + orientation (nonzero) or depth parity (evenodd); a contour
/// is a boundary only where that fill differs from its parent's.
pub fn plan(allocator: std.mem.Allocator, rings: []const []const Point, rule: FillRule) !Plan {
    const n = rings.len;
    const roles = try allocator.alloc(Role, n);
    errdefer allocator.free(roles);
    const owner = try allocator.alloc(u32, n);
    errdefer allocator.free(owner);
    const area = try allocator.alloc(f32, n);
    defer allocator.free(area);
    const parent = try allocator.alloc(?u32, n);
    defer allocator.free(parent);
    const winding = try allocator.alloc(i32, n);
    defer allocator.free(winding);
    const order = try allocator.alloc(u32, n);
    defer allocator.free(order);

    for (rings, 0..) |ring, i| {
        area[i] = if (ring.len >= 3) signedArea2(ring) else 0;
        if (!std.math.isFinite(area[i])) area[i] = 0;
        order[i] = @intCast(i);
        roles[i] = .skip;
        owner[i] = @intCast(i);
    }
    // Larger contours first: a parent is always decided before its children.
    std.mem.sort(u32, order, area, struct {
        fn larger(a: []f32, lhs: u32, rhs: u32) bool {
            return @abs(a[lhs]) > @abs(a[rhs]) or (@abs(a[lhs]) == @abs(a[rhs]) and lhs < rhs);
        }
    }.larger);

    for (order, 0..) |i, rank| {
        parent[i] = null;
        winding[i] = 0;
        if (area[i] == 0) continue;
        // Innermost earlier (larger) contour containing this one.
        var best: ?u32 = null;
        for (order[0..rank]) |j| {
            if (area[j] == 0 or @abs(area[j]) <= @abs(area[i])) continue;
            if (!pointInRing(rings[i][0], rings[j])) continue;
            if (best == null or @abs(area[j]) < @abs(area[best.?])) best = j;
        }
        parent[i] = best;
        const parent_winding: i32 = if (best) |p| winding[p] else 0;
        winding[i] = switch (rule) {
            .nonzero => parent_winding + @as(i32, if (area[i] > 0) 1 else -1),
            .evenodd => parent_winding + 1,
        };
        const filled = filledFor(rule, winding[i]);
        const parent_filled = filledFor(rule, parent_winding);
        if (filled == parent_filled) continue;
        if (filled) {
            roles[i] = .outer;
            continue;
        }
        // Unfilled inside a filled region: a hole of the nearest outer above.
        var up = best;
        while (up) |u| : (up = parent[u]) {
            if (roles[u] == .outer) {
                roles[i] = .hole;
                owner[i] = u;
                break;
            }
        }
    }
    return .{ .roles = roles, .owner = owner };
}

fn filledFor(rule: FillRule, winding: i32) bool {
    return switch (rule) {
        .nonzero => winding != 0,
        .evenodd => @mod(winding, 2) == 1,
    };
}

/// Appends to `out` the polygon formed by `outer` (positive area) with every
/// hole (negative area) joined through a zero-width bridge, as earcut does:
/// holes in decreasing max-x order, each bridged from its rightmost vertex to
/// the nearest visible vertex of the ring to its right. A hole with no visible
/// ring vertex is left out (returned count says how many were joined).
pub fn bridgeHoles(allocator: std.mem.Allocator, out: *std.ArrayList(Point), outer: []const Point, holes: []const []const Point) !usize {
    try out.appendSlice(allocator, outer);
    const order = try allocator.alloc(usize, holes.len);
    defer allocator.free(order);
    for (order, 0..) |*o, i| o.* = i;
    std.mem.sort(usize, order, holes, struct {
        fn rightmost(h: []const []const Point, lhs: usize, rhs: usize) bool {
            return maxX(h[lhs]) > maxX(h[rhs]);
        }
    }.rightmost);
    var joined: usize = 0;
    for (order) |h| {
        const hole = holes[h];
        if (hole.len < 3) continue;
        var m: usize = 0;
        for (hole, 0..) |p, i| {
            if (p.x > hole[m].x or (p.x == hole[m].x and p.y < hole[m].y)) m = i;
        }
        const bridge = findBridge(out.items, hole[m]) orelse continue;
        // ring[..bridge], hole from m around back to m, ring[bridge..]
        const insert = try allocator.alloc(Point, hole.len + 2);
        defer allocator.free(insert);
        for (0..hole.len + 1) |k| insert[k] = hole[(m + k) % hole.len];
        insert[hole.len + 1] = out.items[bridge];
        try out.insertSlice(allocator, bridge + 1, insert);
        joined += 1;
    }
    return joined;
}

fn maxX(ring: []const Point) f32 {
    var x = -std.math.inf(f32);
    for (ring) |p| x = @max(x, p.x);
    return x;
}

/// Index of the ring vertex the hole vertex `m` (the hole's rightmost) joins:
/// cast a ray from `m` to +x and take the nearest ring edge it crosses; the
/// bridge goes to that edge's right end `p`, unless ring vertices lie inside
/// the triangle (m, hit, p) — then to the one closest in angle to the ray (the
/// first thing the ray's sweep towards `p` meets), so the bridge crosses no
/// ring edge.
fn findBridge(ring: []const Point, m: Point) ?usize {
    var hit_x = std.math.inf(f32);
    var p_index: ?usize = null;
    for (ring, 0..) |a, i| {
        const j = (i + 1) % ring.len;
        const b = ring[j];
        // Half-open in y so a ray through a vertex counts one edge.
        if ((a.y <= m.y) == (b.y <= m.y)) continue;
        const x = a.x + (m.y - a.y) * (b.x - a.x) / (b.y - a.y);
        if (!std.math.isFinite(x) or x < m.x or x >= hit_x) continue;
        hit_x = x;
        p_index = if (a.x >= b.x) i else j;
    }
    // A ring vertex exactly on the ray at or right of m is visible directly.
    var on_ray: ?usize = null;
    for (ring, 0..) |v, i| {
        if (v.y == m.y and v.x >= m.x and v.x <= hit_x and (on_ray == null or v.x < ring[on_ray.?].x)) on_ray = i;
    }
    if (on_ray) |i| return i;
    const pi = p_index orelse return null;
    const p = ring[pi];
    const hit = Point{ .x = hit_x, .y = m.y };
    var best = pi;
    var best_tan = std.math.inf(f32);
    for (ring, 0..) |v, i| {
        if (i == pi or v.x < m.x) continue;
        if (!inTriangle(v, m, hit, p)) continue;
        const tan = @abs(v.y - m.y) / (v.x - m.x);
        if (tan < best_tan or (tan == best_tan and v.x > ring[best].x)) {
            best = i;
            best_tan = tan;
        }
    }
    return best;
}

fn inTriangle(p: Point, a: Point, b: Point, c: Point) bool {
    const d1 = (p.x - b.x) * (a.y - b.y) - (a.x - b.x) * (p.y - b.y);
    const d2 = (p.x - c.x) * (b.y - c.y) - (b.x - c.x) * (p.y - c.y);
    const d3 = (p.x - a.x) * (c.y - a.y) - (c.x - a.x) * (p.y - a.y);
    const neg = d1 < 0 or d2 < 0 or d3 < 0;
    const pos = d1 > 0 or d2 > 0 or d3 > 0;
    return !(neg and pos);
}

test {
    _ = @import("path_fill_rule_test.zig");
}
