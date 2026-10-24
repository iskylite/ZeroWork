//! SVG texture cache and hit geometry, stateful subsystem split from `Cx`.
//!
//! Manages two tables:
//!  - `hit_shapes`   texture_id -> PathGeometry (texture's precise hit shape)
//!  - `texture_cache` (svg content hash, w, h) -> texture_id (avoid re-rasterize)
//!
//! These two tables plus `loader` form a self-contained ownership closure (geometry
//! needs free; textures need the loader's unload callback), with no coupling to the
//! rest of Cx state.
//!
//! **Ownership contract**:
//!  - Each PathGeometry in `hit_shapes` is owned by this store; clear/replace must
//!    free it
//!  - texture_id in `texture_cache` is owned by `loader`; the store only calls
//!    unload_fn on cache clear
//!  - Swapping loaders requires clearing the cache first; otherwise the new loader
//!    unloads the old loader's ids

const std = @import("std");
const types = @import("types.zig");
const svg_path = @import("svg_path.zig");
const svg_geometry = @import("svg_geometry.zig");

const PathGeometry = types.PathGeometry;

/// Host-provided SVG rasterization backend.
pub const SvgTextureLoader = struct {
    context: ?*anyopaque = null,
    load_fn: *const fn (context: ?*anyopaque, svg_data: []const u8, width: u32, height: u32) anyerror!u32,
    unload_fn: ?*const fn (context: ?*anyopaque, texture_id: u32) void = null,
};

const CacheKey = struct {
    hash: u64,
    width: u32,
    height: u32,
};

pub const SvgTextureStore = struct {
    allocator: std.mem.Allocator,
    hit_shapes: std.AutoHashMap(u32, PathGeometry),
    texture_cache: std.AutoHashMap(CacheKey, u32),
    loader: ?SvgTextureLoader = null,

    pub fn init(allocator: std.mem.Allocator) SvgTextureStore {
        return .{
            .allocator = allocator,
            .hit_shapes = std.AutoHashMap(u32, PathGeometry).init(allocator),
            .texture_cache = std.AutoHashMap(CacheKey, u32).init(allocator),
        };
    }

    pub fn deinit(self: *SvgTextureStore) void {
        self.clearTextureCache();
        self.texture_cache.deinit();
        self.clearHitShapes();
        self.hit_shapes.deinit();
    }

    /// Parse SVG path geometry and register as hit shape for texture. Reregistering
    /// frees old geometry.
    pub fn registerHit(self: *SvgTextureStore, texture_id: u32, svg_data: []const u8) !void {
        var geometry = try svg_path.createSvgDocumentPathGeometry(self.allocator, svg_data, .nonzero);
        errdefer svg_path.freePathGeometry(self.allocator, &geometry);

        const gop = try self.hit_shapes.getOrPut(texture_id);
        if (gop.found_existing) {
            var old = gop.value_ptr.*;
            svg_path.freePathGeometry(self.allocator, &old);
        }
        gop.value_ptr.* = geometry;
    }

    pub fn lookupHit(self: *const SvgTextureStore, texture_id: u32) ?PathGeometry {
        return self.hit_shapes.get(texture_id);
    }

    /// Unlink and free hit geometry for one texture. No-op if entry absent.
    pub fn dropHit(self: *SvgTextureStore, texture_id: u32) void {
        if (self.hit_shapes.fetchRemove(texture_id)) |kv| {
            var geometry = kv.value;
            svg_path.freePathGeometry(self.allocator, &geometry);
        }
    }

    pub fn clearHitShapes(self: *SvgTextureStore) void {
        var it = self.hit_shapes.iterator();
        while (it.next()) |entry| {
            var geometry = entry.value_ptr.*;
            svg_path.freePathGeometry(self.allocator, &geometry);
        }
        self.hit_shapes.clearRetainingCapacity();
    }

    /// Must clear cache before swapping loader: cached texture_ids belong to old
    /// loader; leaving them for new loader causes it to unload an id it never issued.
    pub fn setLoader(self: *SvgTextureStore, loader: ?SvgTextureLoader) void {
        self.clearTextureCache();
        self.loader = loader;
    }

    pub fn clearTextureCache(self: *SvgTextureStore) void {
        if (self.loader) |loader| {
            if (loader.unload_fn) |unload_fn| {
                var it = self.texture_cache.iterator();
                while (it.next()) |entry| unload_fn(loader.context, entry.value_ptr.*);
            }
        }
        self.texture_cache.clearRetainingCapacity();
    }

    /// Get (or rasterize) an SVG texture. On cache hit, also fill in any missing hit
    /// shape.
    pub fn load(self: *SvgTextureStore, svg_data: []const u8, width: u32, height: u32) !u32 {
        if (width == 0 or height == 0) return error.InvalidSvgRasterSize;
        const loader = self.loader orelse return error.SvgTextureLoaderUnavailable;
        const key = CacheKey{
            .hash = svg_geometry.hashSvgTexture(svg_data),
            .width = width,
            .height = height,
        };
        if (self.texture_cache.get(key)) |texture_id| {
            if (self.lookupHit(texture_id) == null) {
                try self.registerHit(texture_id, svg_data);
            }
            return texture_id;
        }

        const texture_id = try loader.load_fn(loader.context, svg_data, width, height);
        errdefer if (loader.unload_fn) |unload_fn| unload_fn(loader.context, texture_id);
        try self.registerHit(texture_id, svg_data);
        // On put failure, hit geometry must also be unlinked: errdefer already returned
        // texture_id to the loader, so a leftover geometry entry is orphaned and points to
        // an unloaded texture. If the loader reuses the id (legal, it is just a u32 handle),
        // the next SVG gets the same id and lookupHit returns the **previous image's
        // geometry**: misaligned hit region, no crash/error.
        errdefer self.dropHit(texture_id);
        try self.texture_cache.put(key, texture_id);
        return texture_id;
    }
};

// ── Tests ──────────────────────────────────────────────────────────

const TestLoader = struct {
    var next_id: u32 = 1;
    var load_calls: u32 = 0;
    var unloaded: [32]u32 = undefined;
    var unload_count: usize = 0;
    var fail_load: bool = false;

    fn reset() void {
        next_id = 1;
        load_calls = 0;
        unload_count = 0;
        fail_load = false;
    }

    fn load(_: ?*anyopaque, _: []const u8, _: u32, _: u32) anyerror!u32 {
        if (fail_load) return error.LoadFailed;
        load_calls += 1;
        const id = next_id;
        next_id += 1;
        return id;
    }

    fn unload(_: ?*anyopaque, texture_id: u32) void {
        if (unload_count < unloaded.len) {
            unloaded[unload_count] = texture_id;
            unload_count += 1;
        }
    }

    fn loader() SvgTextureLoader {
        return .{ .load_fn = load, .unload_fn = unload };
    }
};

const test_svg = "<svg><path d=\"M0 0 L10 10\"/></svg>";

test "没有 loader 时 load 明确报错，而不是静默成功" {
    var store = SvgTextureStore.init(std.testing.allocator);
    defer store.deinit();
    try std.testing.expectError(error.SvgTextureLoaderUnavailable, store.load(test_svg, 16, 16));
}

test "尺寸为 0 时拒绝栅格化" {
    TestLoader.reset();
    var store = SvgTextureStore.init(std.testing.allocator);
    defer store.deinit();
    store.setLoader(TestLoader.loader());
    try std.testing.expectError(error.InvalidSvgRasterSize, store.load(test_svg, 0, 16));
    try std.testing.expectError(error.InvalidSvgRasterSize, store.load(test_svg, 16, 0));
    try std.testing.expectEqual(@as(u32, 0), TestLoader.load_calls);
}

test "同一张图同尺寸只栅格化一次；换尺寸重新栅格化" {
    TestLoader.reset();
    var store = SvgTextureStore.init(std.testing.allocator);
    defer store.deinit();
    store.setLoader(TestLoader.loader());

    const a = try store.load(test_svg, 16, 16);
    const b = try store.load(test_svg, 16, 16);
    try std.testing.expectEqual(a, b);
    try std.testing.expectEqual(@as(u32, 1), TestLoader.load_calls);

    const c = try store.load(test_svg, 32, 32);
    try std.testing.expect(c != a);
    try std.testing.expectEqual(@as(u32, 2), TestLoader.load_calls);
}

test "load 顺带登记命中几何" {
    TestLoader.reset();
    var store = SvgTextureStore.init(std.testing.allocator);
    defer store.deinit();
    store.setLoader(TestLoader.loader());

    const id = try store.load(test_svg, 16, 16);
    const hit = store.lookupHit(id);
    try std.testing.expect(hit != null);
    try std.testing.expect(hit.?.commands.len > 0);
}

test "清缓存时通过 unload_fn 归还贴图" {
    TestLoader.reset();
    var store = SvgTextureStore.init(std.testing.allocator);
    defer store.deinit();
    store.setLoader(TestLoader.loader());

    const id = try store.load(test_svg, 16, 16);
    store.clearTextureCache();
    try std.testing.expectEqual(@as(usize, 1), TestLoader.unload_count);
    try std.testing.expectEqual(id, TestLoader.unloaded[0]);
}

test "换 loader 先清旧缓存，避免新 loader 收到不属于它的 id" {
    TestLoader.reset();
    var store = SvgTextureStore.init(std.testing.allocator);
    defer store.deinit();
    store.setLoader(TestLoader.loader());

    const id = try store.load(test_svg, 16, 16);
    store.setLoader(null); // Swap loader.
    try std.testing.expectEqual(@as(usize, 1), TestLoader.unload_count);
    try std.testing.expectEqual(id, TestLoader.unloaded[0]);
    try std.testing.expectEqual(@as(u32, 0), store.texture_cache.count());
}

test "重复登记同一 texture_id 的命中几何不泄漏" {
    var store = SvgTextureStore.init(std.testing.allocator);
    defer store.deinit();
    // Second registration must free first geometry; leak caught by testing.allocator.
    try store.registerHit(7, test_svg);
    try store.registerHit(7, "<svg><path d=\"M0 0 L20 20 L30 5\"/></svg>");
    try std.testing.expectEqual(@as(u32, 1), store.hit_shapes.count());
}

test "loader 失败时不写缓存也不留命中几何" {
    TestLoader.reset();
    var store = SvgTextureStore.init(std.testing.allocator);
    defer store.deinit();
    store.setLoader(TestLoader.loader());
    TestLoader.fail_load = true;

    try std.testing.expectError(error.LoadFailed, store.load(test_svg, 16, 16));
    try std.testing.expectEqual(@as(u32, 0), store.texture_cache.count());
    try std.testing.expectEqual(@as(u32, 0), store.hit_shapes.count());
}

test "put 失败时不留下指向已卸载贴图的残留命中条目" {
    // GLM cross-review found (2026-09-22, pre-existing not from refactor): load()'s
    // errdefer only returns texture_id to loader; hit geometry left in hit_shapes.
    // Loader reuses id (u32 handle, completely legal) and next SVG gets same id,
    // lookupHit hits previous image's geometry, hit region misaligned, no crash/error.
    TestLoader.reset();

    // Measure hit registration first so the next allocation is cache publication,
    // independent of ArrayList growth policies in the Zig standard library.
    var counting = std.testing.FailingAllocator.init(std.testing.allocator, .{ .resize_fail_index = 0 });
    var probe = SvgTextureStore.init(counting.allocator());
    defer probe.deinit();
    try probe.registerHit(1, test_svg);
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{
        .fail_index = counting.alloc_index,
        .resize_fail_index = 0,
    });
    var store = SvgTextureStore.init(failing.allocator());
    defer store.deinit();
    store.setLoader(TestLoader.loader());

    try std.testing.expectError(error.OutOfMemory, store.load(test_svg, 16, 16));

    // After failure both tables must match: texture returned to loader, geometry
    // must not remain.
    try std.testing.expect(TestLoader.unload_count >= 1);
    try std.testing.expectEqual(@as(u32, 0), store.hit_shapes.count());
    try std.testing.expectEqual(@as(u32, 0), store.texture_cache.count());
}
