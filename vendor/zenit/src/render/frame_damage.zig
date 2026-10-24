//! Conservative damage for a flat frame. No textures or borrowed paint data are
//! retained here. Commit only after the matching pixels have been submitted.
const std = @import("std");
const paint = @import("command_encoder/paint_fingerprint.zig");
const Item = @import("command_encoder/retained_plan.zig").DamageItem;
pub const PixelRect = [4]u32;
pub const FrameDamage = struct {
    previous: std.ArrayList(Item) = .empty,
    current: std.ArrayList(Item) = .empty,
    valid: bool = false,
    pending_valid: bool = false,
    key: u64 = 0,
    pending_key: u64 = 0,

    pub fn deinit(self: *FrameDamage, a: std.mem.Allocator) void {
        self.previous.deinit(a);
        self.current.deinit(a);
    }
    pub fn invalidate(self: *FrameDamage) void {
        self.valid = false;
        self.pending_valid = false;
    }
    pub fn commit(self: *FrameDamage) void {
        std.mem.swap(std.ArrayList(Item), &self.previous, &self.current);
        self.valid = self.pending_valid;
        self.key = self.pending_key;
    }
    /// Last balanced clip boundary before an offscreen/control effect. The
    /// candidate still needs prepare() validation before its pixels are reused.
    pub fn flatPrefixEnd(commands: anytype) usize {
        var depth: usize = 0;
        var end: usize = 0;
        for (commands, 0..) |it, i| {
            if (it.kind == .control) switch (it.control_kind) {
                .push_clip => depth += 1,
                .pop_clip => {
                    if (depth == 0) return 0;
                    depth -= 1;
                },
                else => return end,
            };
            if (depth == 0) end = i + 1;
        }
        return 0; // Entire flat frames already use frame damage.
    }
    /// null means full redraw; zero extent means copy-only. Unknown effects,
    /// mutable textures, transformed groups and dynamic noise always redraw.
    pub fn prepare(self: *FrameDamage, a: std.mem.Allocator, commands: anytype, width: u32, height: u32, scale: f32, context_key: u64) !?PixelRect {
        self.pending_valid = false;
        self.current.clearRetainingCapacity();
        if (width == 0 or height == 0 or !std.math.isFinite(scale) or scale <= 0) return null;
        var kh = std.hash.Wyhash.init(context_key);
        kh.update(std.mem.asBytes(&width));
        kh.update(std.mem.asBytes(&height));
        kh.update(std.mem.asBytes(&scale));
        self.pending_key = kh.final();
        var clips: [32][4]f32 = undefined;
        var clip_hashes: [32]u64 = undefined;
        var depth: usize = 0;
        for (commands) |it| {
            if (it.use_draw_transform or it.blend_mode != 0 or it.noise_intensity > 0) return null;
            const geom = [4]f32{ it.geom.x, it.geom.y, it.geom.w, it.geom.h };
            for (geom) |v| if (!std.math.isFinite(v)) return null;
            if (it.kind == .control) {
                switch (it.control_kind) {
                    .push_clip => {
                        if (depth == clips.len or it.clip_shape_kind > 2 or geom[2] < 0 or geom[3] < 0) return null;
                        const pad = 2 / scale;
                        var bounds = [4]f32{ geom[0] - pad, geom[1] - pad, geom[2] + 2 * pad, geom[3] + 2 * pad };
                        var h = std.hash.Wyhash.init(if (depth == 0) 0 else clip_hashes[depth - 1]);
                        paint.hashPaintItemInto(&h, it);
                        if (depth > 0) bounds = intersection(bounds, clips[depth - 1]);
                        clips[depth] = bounds;
                        clip_hashes[depth] = h.final();
                        depth += 1;
                    },
                    .pop_clip => {
                        if (depth == 0) return null;
                        depth -= 1;
                    },
                    else => return null,
                }
                continue;
            }
            switch (it.kind) {
                .rect, .shadow, .gradient => {},
                .text => {
                    if (it.text_font_family != 0 or it.text_spans != null or std.mem.indexOfAny(u8, it.text_content, "\r\n") != null) return null;
                },
                // Icon representations are immutable; external image textures
                // can change without changing a paint item and cannot be reused.
                .image => if (it.icon_rep_ptr == null) return null,
                else => return null,
            }
            var bounds = paint.damageItemBounds(it);
            for (bounds) |v| if (!std.math.isFinite(v)) return null;
            if (bounds[2] < 0 or bounds[3] < 0) return null;
            if (depth > 0) bounds = intersection(bounds, clips[depth - 1]);
            var h = std.hash.Wyhash.init(if (depth == 0) 0 else clip_hashes[depth - 1]);
            paint.hashPaintItemInto(&h, it);
            try self.current.append(a, .{ .digest = h.final(), .bounds = bounds });
        }
        if (depth != 0) return null;
        self.pending_valid = true;
        if (!self.valid or self.key != self.pending_key) return null;
        return diff(self.previous.items, self.current.items, width, height, scale);
    }
};
fn intersection(a: [4]f32, b: [4]f32) [4]f32 {
    const x = @max(a[0], b[0]);
    const y = @max(a[1], b[1]);
    return .{ x, y, @max(0, @min(a[0] + a[2], b[0] + b[2]) - x), @max(0, @min(a[1] + a[3], b[1] + b[3]) - y) };
}
fn diff(previous: []const Item, current: []const Item, width: u32, height: u32, scale: f32) ?PixelRect {
    var lo: [2]f32 = @splat(std.math.inf(f32));
    var hi: [2]f32 = @splat(-std.math.inf(f32));
    const count = @max(previous.len, current.len);
    for (0..count) |i| {
        if (i < previous.len and i < current.len and previous[i].digest == current[i].digest and std.mem.eql(f32, &previous[i].bounds, &current[i].bounds)) continue;
        for ([_]?Item{ if (i < previous.len) previous[i] else null, if (i < current.len) current[i] else null }) |entry| {
            const item = entry orelse continue;
            if (item.bounds[2] <= 0 or item.bounds[3] <= 0) continue;
            for (0..2) |axis| {
                lo[axis] = @min(lo[axis], item.bounds[axis]);
                hi[axis] = @max(hi[axis], item.bounds[axis] + item.bounds[axis + 2]);
            }
        }
    }
    if (!std.math.isFinite(lo[0])) return .{ 0, 0, 0, 0 };
    var rect: PixelRect = undefined;
    for ([_]u32{ width, height }, 0..) |extent, axis| {
        const maximum: f32 = @floatFromInt(extent);
        rect[axis] = @intFromFloat(@floor(std.math.clamp(lo[axis] * scale - 1, 0, maximum)));
        const end: u32 = @intFromFloat(@ceil(std.math.clamp(hi[axis] * scale + 1, 0, maximum)));
        rect[axis + 2] = end -| rect[axis];
    }
    // Large changes are cheaper to clear/repaint directly than copy and clip.
    if (@as(u64, rect[2]) * rect[3] * 5 > @as(u64, width) * height * 3) return null;
    return rect;
}
test "frame damage includes old and new positions, removal and context invalidation" {
    const old = [_]Item{.{ .digest = 1, .bounds = .{ 20, 30, 40, 10 } }};
    const moved = [_]Item{.{ .digest = 1, .bounds = .{ 25, 35, 40, 10 } }};
    try std.testing.expectEqual(PixelRect{ 0, 0, 0, 0 }, diff(&old, &old, 200, 100, 1).?);
    try std.testing.expectEqual(PixelRect{ 19, 29, 47, 17 }, diff(&old, &moved, 200, 100, 1).?);
    try std.testing.expectEqual(PixelRect{ 19, 29, 42, 12 }, diff(&old, &.{}, 200, 100, 1).?);
    var plan: FrameDamage = .{};
    plan.pending_valid = true;
    plan.pending_key = 5;
    plan.commit();
    try std.testing.expect(plan.valid and plan.key == 5);
    plan.invalidate();
    try std.testing.expect(!plan.valid and !plan.pending_valid);
}
