//! Cached background patches. Work follows visible shape intersections, not
//! surface height; stable patches are regular retained Zenit paint nodes.
const std = @import("std");
const ui = @import("ui");
const theme = @import("app_theme.zig");
pub const Rect = ui.ComputedRect;
pub fn intersection(a: Rect, b: Rect) Rect {
    const x = @max(a.x, b.x);
    const y = @max(a.y, b.y);
    return Rect.init(x, y, @max(0, @min(a.x + a.w, b.x + b.w) - x), @max(0, @min(a.y + a.h, b.y + b.h) - y));
}
pub fn overlaps(a: Rect, b: Rect) bool {
    return a.x < b.x + b.w and a.x + a.w > b.x and a.y < b.y + b.h and a.y + a.h > b.y;
}
pub const Snapshot = struct { rect: Rect, clip: Rect, visible: Rect };
/// Reads the physical clip chain once, including scrolled ancestors. Useful
/// for visual timers too: offscreen content must not keep requesting frames.
pub fn snapshot(cx: *ui.Cx, node: *ui.Node) ?Snapshot {
    const bounds = node.globalRect();
    var clip = Rect.init(0, 0, cx.viewport.width, cx.viewport.height);
    var cursor: ?*ui.Node = node;
    var world = bounds;
    while (cursor) |current| {
        if (current.style.display == .none) return null;
        if (current != node and (current.style.overflow != .visible or current.style.overflow_hidden)) clip = intersection(clip, world);
        const local = current.rectFromWorldOrFallback();
        world.x -= local.x + current.style.translate_x + current.frame_state.frame_local.runtime.sticky.x;
        world.y -= local.y + current.style.translate_y + current.frame_state.frame_local.runtime.sticky.y;
        cursor = current.parent;
        if (cursor) |parent| {
            const r = parent.rectFromWorldOrFallback();
            world.w = r.w;
            world.h = r.h;
        }
    }
    const region = intersection(bounds, clip);
    return if (region.w > 0 and region.h > 0) .{ .rect = bounds, .clip = clip, .visible = region } else null;
}
pub const Shape = struct {
    rect: Rect,
    clip: Rect,
    radius: f32,
    level: usize,
    pub fn visible(self: Shape) Rect {
        return intersection(self.rect, self.clip);
    }
    pub fn span(self: Shape, y: f32) ?[2]f32 {
        const r = self.rect;
        if (y < r.y or y >= r.y + r.h or y < self.clip.y or y >= self.clip.y + self.clip.h or r.w <= 0 or r.h <= 0) return null;
        const radius = @min(self.radius, @min(r.w, r.h) / 2);
        const edge = @min(y - r.y, r.y + r.h - y);
        const inset = if (edge < radius) radius - @sqrt(@max(0, radius * radius - (radius - edge) * (radius - edge))) else 0;
        const left = @max(r.x + inset, self.clip.x);
        const right = @min(r.x + r.w - inset, self.clip.x + self.clip.w);
        return if (right > left) .{ left, right } else null;
    }
    pub fn contains(self: Shape, r: Rect) bool {
        for ([_]f32{ r.y + 0.001, r.y + r.h - 0.001 }) |y| {
            const s = self.span(y) orelse return false;
            if (r.x < s[0] - 0.01 or r.x + r.w > s[1] + 0.01) return false;
        }
        return true;
    }
    fn coverage(self: Shape, x: f32, y: f32, blur: f32) f32 {
        if (blur == 0) {
            const s = self.span(y) orelse return 0;
            return if (x >= s[0] and x < s[1]) 1 else 0;
        }
        const r = self.rect;
        const radius = @min(self.radius, @min(r.w, r.h) / 2);
        const qx = @abs(x - r.x - r.w / 2) - r.w / 2 + radius;
        const qy = @abs(y - r.y - r.h / 2) - r.h / 2 + radius;
        const rounded = @sqrt(@max(qx, 0) * @max(qx, 0) + @max(qy, 0) * @max(qy, 0)) + @min(@max(qx, qy), 0) - radius;
        const clip_distance = @max(@max(self.clip.x - x, x - self.clip.x - self.clip.w), @max(self.clip.y - y, y - self.clip.y - self.clip.h));
        const z = @max(rounded, clip_distance) / (blur * @sqrt(@as(f32, 2)));
        const t = 1 / (1 + 0.3275911 * @abs(z));
        const erf = 1 - (((((1.061405429 * t - 1.453152027) * t) + 1.421413741) * t - 0.284496736) * t + 0.254829592) * t * @exp(-z * z);
        return 0.5 * (1 - (if (z < 0) -erf else erf));
    }
};
pub const Patch = struct { x: f32, y: f32, w: f32, h: f32, first: u8, last: u8 };
pub const Paint = struct {
    rect: Rect,
    region: Rect,
    level: usize,
    alpha: u8,
    blur: f32,
    shapes: []const Shape,
    fn alphaAt(self: Paint, x: f32, y: f32) u8 {
        var transmission: f32 = 1;
        for (1..5) |level| {
            var covered: f32 = 0;
            for (self.shapes) |shape| if (shape.level >= level) {
                covered = @max(covered, shape.coverage(x, y, self.blur));
            };
            transmission -= 0.2 * covered;
        }
        const own = 1 - @as(f32, @floatFromInt(self.alpha)) / 255;
        const extra = if (own == 0) 0 else @max(0, 1 - theme.layerTransmission(self.level) / (@max(0.2, transmission) * own));
        return @intFromFloat(@round(255 * extra));
    }
    /// Local geometry key: a common translation does not invalidate patches.
    pub fn key(self: Paint, radius: f32) u64 {
        var hash = std.hash.Wyhash.init(0);
        std.hash.autoHash(&hash, .{ self.level, self.alpha, self.shapes.len });
        for ([_]f32{ self.rect.w, self.rect.h, self.region.x - self.rect.x, self.region.y - self.rect.y, self.region.w, self.region.h, self.blur, radius }) |value| hashFloat(&hash, value);
        for (self.shapes) |shape| {
            std.hash.autoHash(&hash, @min(shape.level, 4));
            for ([_]f32{ shape.rect.x - self.rect.x, shape.rect.y - self.rect.y, shape.rect.w, shape.rect.h, shape.clip.x - self.rect.x, shape.clip.y - self.rect.y, shape.clip.w, shape.clip.h, shape.radius }) |value| hashFloat(&hash, value);
        }
        return hash.final();
    }
};
fn hashFloat(hash: *std.hash.Wyhash, value: f32) void {
    const quantized: i64 = @intFromFloat(@round(value * 64));
    std.hash.autoHash(hash, quantized);
}
const Builder = struct {
    allocator: std.mem.Allocator,
    out: *std.ArrayList(Patch),
    previous: std.ArrayList(usize) = .empty,
    current: std.ArrayList(usize) = .empty,
    fn append(self: *Builder, patch: Patch) !void {
        if (patch.first == 0 and patch.last == 0) return;
        for (self.previous.items) |index| {
            const old = &self.out.items[index];
            if (@abs(old.x - patch.x) < 0.001 and @abs(old.w - patch.w) < 0.001 and old.first == patch.first and old.last == patch.last and @abs(old.y + old.h - patch.y) < 0.001) {
                old.h += patch.h;
                try self.current.append(self.allocator, index);
                return;
            }
        }
        try self.out.append(self.allocator, patch);
        try self.current.append(self.allocator, self.out.items.len - 1);
    }
    fn segment(self: *Builder, paint: Paint, x: f32, y: f32, w: f32, h: f32, depth: u8) !void {
        const first = paint.alphaAt(paint.rect.x + x + 0.001, paint.rect.y + y + h / 2);
        const last = paint.alphaAt(paint.rect.x + x + w - 0.001, paint.rect.y + y + h / 2);
        if (paint.blur > 0 and depth < 6 and w > 2) {
            const middle = paint.alphaAt(paint.rect.x + x + w / 2, paint.rect.y + y + h / 2);
            const linear = @divTrunc(@as(i32, first) + @as(i32, last), 2);
            if (@abs(@as(i32, middle) - linear) > 1) {
                try self.segment(paint, x, y, w / 2, h, depth + 1);
                try self.segment(paint, x + w / 2, y, w / 2, h, depth + 1);
                return;
            }
        }
        try self.append(.{ .x = x, .y = y, .w = w, .h = h, .first = first, .last = last });
    }
};
/// Exact flat bands can cover arbitrarily tall surfaces in one patch. Only
/// rounded/blurred boundary bands need fine samples, then equal bands merge.
pub fn build(allocator: std.mem.Allocator, paint: Paint, out: *std.ArrayList(Patch)) !void {
    out.clearRetainingCapacity();
    var builder: Builder = .{ .allocator = allocator, .out = out };
    defer builder.previous.deinit(allocator);
    defer builder.current.deinit(allocator);
    var cuts: std.ArrayList(f32) = .empty;
    defer cuts.deinit(allocator);
    const bottom = paint.region.y + paint.region.h;
    var world_y = paint.region.y;
    while (world_y < bottom - 0.001) {
        var end = bottom;
        var fine = false;
        for (paint.shapes) |shape| {
            const r = shape.rect;
            const pad = 3 * paint.blur;
            const radius = @min(shape.radius, @min(r.w, r.h) / 2);
            for ([_]f32{ r.y - pad, r.y + radius + pad, r.y + r.h - radius - pad, r.y + r.h + pad, shape.clip.y - pad, shape.clip.y + pad, shape.clip.y + shape.clip.h - pad, shape.clip.y + shape.clip.h + pad }) |edge| if (edge > world_y + 0.001) {
                end = @min(end, edge);
            };
            fine = fine or (world_y >= r.y - pad and world_y < r.y + radius + pad) or (world_y >= r.y + r.h - radius - pad and world_y < r.y + r.h + pad) or (paint.blur > 0 and ((@abs(world_y - shape.clip.y) < pad) or (@abs(world_y - shape.clip.y - shape.clip.h) < pad)));
        }
        if (fine) end = @min(end, world_y + @as(f32, if (paint.blur > 0) 2 else 0.5));
        const height = @max(0.001, end - world_y);
        const sample_y = world_y + height / 2;
        cuts.clearRetainingCapacity();
        try cuts.append(allocator, paint.region.x - paint.rect.x);
        try cuts.append(allocator, paint.region.x + paint.region.w - paint.rect.x);
        for (paint.shapes) |shape| {
            const visible = shape.visible();
            if (sample_y < visible.y - 3 * paint.blur or sample_y > visible.y + visible.h + 3 * paint.blur or visible.h <= 0) continue;
            const span = shape.span(std.math.clamp(sample_y, visible.y + 0.001, visible.y + visible.h - 0.001)) orelse continue;
            for (span) |edge| for ([_]f32{ -3, -2, -1, -0.5, 0, 0.5, 1, 2, 3 }) |offset| {
                const x = edge + offset * paint.blur;
                if (x > paint.region.x and x < paint.region.x + paint.region.w) try cuts.append(allocator, x - paint.rect.x);
                if (paint.blur == 0) break;
            };
        }
        std.mem.sort(f32, cuts.items, {}, std.sort.asc(f32));
        builder.current.clearRetainingCapacity();
        for (0..cuts.items.len - 1) |i| {
            const width = cuts.items[i + 1] - cuts.items[i];
            if (width > 0.001) try builder.segment(paint, cuts.items[i], world_y - paint.rect.y, width, height, 0);
        }
        std.mem.swap(std.ArrayList(usize), &builder.previous, &builder.current);
        world_y = end;
    }
}
