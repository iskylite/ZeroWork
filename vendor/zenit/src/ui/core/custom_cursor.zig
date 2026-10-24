//! Custom bitmap cursor storage, extracted from `Cx`.
//!
//! Depends only on `allocator` and SVG rasterization. System dispatch needs
//! `system_sdk` / `window_id` and stays in Cx.updateCursorShape, so the interface cut is:
//!
//! **the store rasterizes a desc to a bitmap and content-address caches it; dispatch
//! stays in Cx.**
//!
//! Premultiply alpha, the content-addressing key, same-key idempotence and
//! rasterize/insert failure cleanup are testable without a SystemSdk mock.

const std = @import("std");
const types = @import("types.zig");

const CursorShape = types.CursorShape;

/// host-submitted custom cursor description (input).
pub const CustomCursorDesc = struct {
    svg_data: []const u8,
    size_pt: f32,
    scale: f32 = 2.0,
    hot_x: f32 = 0,
    hot_y: f32 = 0,

    /// content-addressing key: same SVG + same params => same bitmap. native side also caches
    /// cursor objects by this key.
    pub fn contentKey(self: CustomCursorDesc) u64 {
        var h = std.hash.Wyhash.init(0);
        h.update(self.svg_data);
        const params = [_]f32{ self.size_pt, self.scale, self.hot_x, self.hot_y };
        h.update(std.mem.asBytes(&params));
        return h.final();
    }
};

/// rasterized custom cursor bitmap (premultiplied RGBA). hot is pixel coordinate (top-left origin).
pub const CustomCursorEntry = struct {
    width: u32,
    height: u32,
    scale: f32,
    hot_x: f32,
    hot_y: f32,
    pixels: []u8,
};

/// svg.rasterize outputs straight-alpha RGBA; bitmap cursor uses CGBitmapContext
/// kCGImageAlphaPremultipliedLast, premultiply in-place before copy.
pub fn premultiplyRgbaInPlace(pixels: []u8) void {
    var i: usize = 0;
    while (i + 4 <= pixels.len) : (i += 4) {
        const a: u16 = pixels[i + 3];
        pixels[i + 0] = @intCast((@as(u16, pixels[i + 0]) * a + 127) / 255);
        pixels[i + 1] = @intCast((@as(u16, pixels[i + 1]) * a + 127) / 255);
        pixels[i + 2] = @intCast((@as(u16, pixels[i + 2]) * a + 127) / 255);
    }
}

pub const CustomCursorStore = struct {
    entries: std.AutoHashMapUnmanaged(u64, CustomCursorEntry) = .{},
    /// currently selected custom cursor (not necessarily dispatched to system yet).
    active: ?u64 = null,
    /// key dispatched to system. idempotency check is 'shape identical **and** key identical',
    /// changing bitmap content while shape in `.custom` must re-dispatch.
    submitted: ?u64 = null,
    /// fallback shape for `.custom` when backend doesn't support bitmap cursors (or bitmap
    /// unregistered). default crosshair: custom cursors typically used for precision drawing tools.
    fallback: CursorShape = .crosshair,

    pub fn deinit(self: *CustomCursorStore, allocator: std.mem.Allocator) void {
        var it = self.entries.iterator();
        while (it.next()) |entry| allocator.free(entry.value_ptr.pixels);
        self.entries.deinit(allocator);
    }

    /// rasterization output (same shape as `svg.rasterize` return, but module doesn't import svg:
    /// rasterize function injected by caller, store thus independent of SVG pipeline for unit
    /// testing).
    pub const Raster = struct { width: u32, height: u32, pixels: []u8 };
    pub const RasterizeFn = *const fn (
        allocator: std.mem.Allocator,
        svg_data: []const u8,
        target_width: u32,
    ) anyerror!Raster;

    /// rasterize and register custom cursor, then set it active.
    ///
    /// on failure (rasterize/insert fail) silently keep current: cursor is visual only, if no
    /// bitmap use current, shouldn't crash host. duplicate submit of same key is no-op.
    pub fn set(
        self: *CustomCursorStore,
        allocator: std.mem.Allocator,
        desc: CustomCursorDesc,
        rasterize: RasterizeFn,
    ) void {
        const key = desc.contentKey();
        if (self.active == key) return;
        if (!self.entries.contains(key)) {
            const w_px: u32 = @intFromFloat(@max(1.0, @round(desc.size_pt * desc.scale)));
            const img = rasterize(allocator, desc.svg_data, w_px) catch return;
            premultiplyRgbaInPlace(img.pixels);
            self.entries.put(allocator, key, .{
                .width = img.width,
                .height = img.height,
                .scale = desc.scale,
                .hot_x = desc.hot_x * desc.scale,
                .hot_y = desc.hot_y * desc.scale,
                .pixels = img.pixels,
            }) catch {
                allocator.free(img.pixels);
                return;
            };
        }
        self.active = key;
    }

    pub fn activeKey(self: *const CustomCursorStore) ?u64 {
        return self.active;
    }

    /// get bitmap for active; return null if no active or bitmap unregistered (caller should fall
    /// back to `fallback`).
    pub fn activeEntry(self: *const CustomCursorStore) ?CustomCursorEntry {
        const key = self.active orelse return null;
        return self.entries.get(key);
    }
};

// -- tests --

const tiny_svg = "<svg viewBox=\"0 0 8 8\"><path d=\"M0 0 L8 0 L8 8 Z\" fill=\"#ff0000\"/></svg>";

/// mock rasterizer: outputs fully opaque w×w RGBA. injecting it makes these tests completely
/// independent of real SVG pipeline, that's the benefit of making rasterize a parameter.
fn fakeRasterize(allocator: std.mem.Allocator, svg_data: []const u8, target_width: u32) anyerror!CustomCursorStore.Raster {
    if (std.mem.eql(u8, svg_data, "FAIL")) return error.RasterizeFailed;
    const w = @max(target_width, 1);
    const px = try allocator.alloc(u8, w * w * 4);
    @memset(px, 255);
    return .{ .width = w, .height = w, .pixels = px };
}

test "premultiplyRgbaInPlace: alpha 全不透明时像素不变" {
    var px = [_]u8{ 200, 100, 50, 255 };
    premultiplyRgbaInPlace(&px);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 200, 100, 50, 255 }, &px);
}

test "premultiplyRgbaInPlace: alpha 全透明时 RGB 归零" {
    var px = [_]u8{ 200, 100, 50, 0 };
    premultiplyRgbaInPlace(&px);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0, 0, 0, 0 }, &px);
}

test "premultiplyRgbaInPlace: 半透明按 round 而非截断" {
    // 200 * 128 / 255 = 100.4; add 127 then divide = 100 (rounding)
    var px = [_]u8{ 200, 200, 200, 128 };
    premultiplyRgbaInPlace(&px);
    try std.testing.expectEqual(@as(u8, 100), px[0]);
    try std.testing.expectEqual(@as(u8, 128), px[3]);
}

test "premultiplyRgbaInPlace: 尾部不足 4 字节不越界" {
    var px = [_]u8{ 10, 20, 30 }; // only 3 bytes
    premultiplyRgbaInPlace(&px);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 10, 20, 30 }, &px);
}

test "contentKey: 同内容同参数得同键，任一参数变则换键" {
    const base = CustomCursorDesc{ .svg_data = tiny_svg, .size_pt = 16 };
    try std.testing.expectEqual(base.contentKey(), base.contentKey());

    var other = base;
    other.size_pt = 24;
    try std.testing.expect(base.contentKey() != other.contentKey());

    other = base;
    other.scale = 1.0;
    try std.testing.expect(base.contentKey() != other.contentKey());

    other = base;
    other.hot_x = 3;
    try std.testing.expect(base.contentKey() != other.contentKey());

    other = base;
    other.svg_data = "<svg viewBox=\"0 0 8 8\"></svg>";
    try std.testing.expect(base.contentKey() != other.contentKey());
}

test "store: 登记后 active 指向该位图，重复提交是 no-op" {
    const alloc = std.testing.allocator;
    var store = CustomCursorStore{};
    defer store.deinit(alloc);

    const desc = CustomCursorDesc{ .svg_data = tiny_svg, .size_pt = 16 };
    store.set(alloc, desc, fakeRasterize);
    try std.testing.expectEqual(@as(?u64, desc.contentKey()), store.activeKey());
    try std.testing.expectEqual(@as(u32, 1), store.entries.count());

    // same desc again: should not rasterize twice
    store.set(alloc, desc, fakeRasterize);
    try std.testing.expectEqual(@as(u32, 1), store.entries.count());
}

test "store: 换参数产出第二个条目，两者共存" {
    const alloc = std.testing.allocator;
    var store = CustomCursorStore{};
    defer store.deinit(alloc);

    store.set(alloc, .{ .svg_data = tiny_svg, .size_pt = 16 }, fakeRasterize);
    store.set(alloc, .{ .svg_data = tiny_svg, .size_pt = 32 }, fakeRasterize);
    try std.testing.expectEqual(@as(u32, 2), store.entries.count());
}

test "store: 光栅化失败时保持原状而不是崩" {
    const alloc = std.testing.allocator;
    var store = CustomCursorStore{};
    defer store.deinit(alloc);

    store.set(alloc, .{ .svg_data = "FAIL", .size_pt = 16 }, fakeRasterize);
    // failure path: don't register, don't set active
    try std.testing.expectEqual(@as(u32, 0), store.entries.count());
    try std.testing.expectEqual(@as(?u64, null), store.activeKey());
}

test "store: activeEntry 在无 active 时返回 null" {
    const alloc = std.testing.allocator;
    var store = CustomCursorStore{};
    defer store.deinit(alloc);
    try std.testing.expectEqual(@as(?CustomCursorEntry, null), store.activeEntry());

    store.set(alloc, .{ .svg_data = tiny_svg, .size_pt = 16 }, fakeRasterize);
    const e = store.activeEntry();
    try std.testing.expect(e != null);
    try std.testing.expect(e.?.pixels.len > 0);
}

test "store: hot 点按 scale 换算成像素坐标" {
    const alloc = std.testing.allocator;
    var store = CustomCursorStore{};
    defer store.deinit(alloc);

    store.set(alloc, .{ .svg_data = tiny_svg, .size_pt = 16, .scale = 2.0, .hot_x = 3, .hot_y = 4 }, fakeRasterize);
    const e = store.activeEntry().?;
    try std.testing.expectEqual(@as(f32, 6), e.hot_x);
    try std.testing.expectEqual(@as(f32, 8), e.hot_y);
}
