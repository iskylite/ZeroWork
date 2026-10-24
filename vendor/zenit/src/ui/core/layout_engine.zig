const std = @import("std");
const Allocator = std.mem.Allocator;

const types = @import("types.zig");
const node_mod = @import("node.zig");
const text_layout = @import("text_layout.zig");
// GlyphRun pipeline support
const shaping_cache_mod = @import("shaping_cache.zig");
const text_module = @import("text");
const text_shaper_adapter = @import("text_shaper_adapter.zig");
const glyph_run_mod = @import("glyph_run.zig");

const Node = node_mod.Node;
const Size = types.Size;
const Sizing = types.Sizing;
const AlignItems = types.AlignItems;

/// Bound recursive measure/layout walks before application-provided tree depth
/// can exhaust the native stack. Nodes beyond the limit remain dirty and can
/// be diagnosed through `layout_depth_limit_hits` instead of crashing.
pub const max_layout_recursion_depth: usize = 128;
pub var layout_depth_limit_hits: u64 = 0;

/// Number of frame_allocator allocation failures during layout.
///
/// The >512-children slow paths (shrink_deltas for flex_shrink, placements for grid) degrade on
/// allocation failure instead of crashing, like `layout_depth_limit_hits`. Degrading yields
/// **silently wrong layout** (shrink not applied => overflow; grid not laid out), so this counter
/// makes OOM distinguishable from a layout bug.
pub var layout_alloc_failure_hits: u64 = 0;
var g_layout_recursion_depth: usize = 0;

/// display: none—node and subtree don't participate in layout (no space, gap excluded, no parent
/// expansion).
pub inline fn isDisplayNone(n: *const Node) bool {
    return n.style.display == .none;
}

/// Children that do not take part in flex / grid flow layout: absolute (positioned separately) or
/// display:none.
/// Every layout-engine traversal that skips non-flow children uses this single predicate.
pub inline fn isOutOfFlow(n: *const Node) bool {
    return n.style.position == .absolute or isDisplayNone(n);
}

/// Layout finalization for a display:none subtree: own size is zeroed (position is kept;
/// computeChildrenBBox / hit-test pruning exclude it since w/h = 0) and the layout dirty bits of
/// the whole subtree are cleared. Otherwise the hidden subtree stays dirty every frame and idle
/// frame-gating always sees pending layout work. onMount still fires: the node is still in the
/// tree (unlike unmount), just not displayed.
fn collapseDisplayNone(node: *Node) void {
    const r = node.rectFromWorldOrFallback();
    if (r.w != 0 or r.h != 0) node.setLayoutRect(types.ComputedRect.init(r.x, r.y, 0, 0));
    settleHiddenSubtree(node, 0);
}

/// Recursion (depth limit, not width; wide subtrees won't miss dirty-bit clearing).
fn settleHiddenSubtree(n: *Node, depth: usize) void {
    n.frame_state.state_bits.dirty.core.layout = false;
    n.frame_state.state_bits.dirty.core.subtree_layout = false;
    node_mod.fireMountIfNeeded(n);
    if (depth >= max_layout_recursion_depth) return;
    for (n.children.items) |c| settleHiddenSubtree(c, depth + 1);
}

fn enterLayoutRecursion() bool {
    if (g_layout_recursion_depth >= max_layout_recursion_depth) {
        layout_depth_limit_hits +|= 1;
        return false;
    }
    g_layout_recursion_depth += 1;
    return true;
}

fn leaveLayoutRecursion() void {
    std.debug.assert(g_layout_recursion_depth > 0);
    g_layout_recursion_depth -= 1;
}

fn releaseShapedFallbackFontRefs(glyphs: []const text_module.ShapedGlyph) void {
    for (glyphs) |glyph| {
        if (glyph.fallback_font_ref) |font_ref| {
            text_module.releaseFallbackFontRef(font_ref);
        }
    }
}

// IntrinsicCache: reuses the intrinsic measurement for the same node and the same
// (axis, content_version) across calcIntrinsicSize calls.
// Keyed by a (node.id, axis) -> value hashmap, invalidated by node.caches.versions.content.
//
// Uses a static variable under the single-threaded model (guaranteed by owner.assertThread);
// move next to LayoutTable when Node is split.
const IntrinsicCacheEntry = struct {
    value: f32,
    /// content_version at write time; hit requires current version match
    content_version: u32,
};

var g_intrinsic_cache: std.AutoHashMapUnmanaged(u64, IntrinsicCacheEntry) = .{};
var g_intrinsic_cache_refcount: u32 = 0;
var g_intrinsic_cache_allocator: Allocator = undefined;

/// A destroyed node can never hit this memo again; remove both axis keys.
pub fn forgetIntrinsicCache(world_id: u16, node_id: u32) void {
    if (g_intrinsic_cache_refcount == 0) return;
    _ = g_intrinsic_cache.remove(intrinsicCacheKey(world_id, node_id, false));
    _ = g_intrinsic_cache.remove(intrinsicCacheKey(world_id, node_id, true));
}

pub fn intrinsicCacheMemoryStats() struct { entries: usize, capacity: usize, slot_bytes: usize } {
    return .{ .entries = g_intrinsic_cache.count(), .capacity = g_intrinsic_cache.capacity(), .slot_bytes = g_intrinsic_cache.capacity() * (@sizeOf(u64) + @sizeOf(IntrinsicCacheEntry) + 1) };
}

fn intrinsicCacheKey(world_id: u16, node_id: u32, is_main_row: bool) u64 {
    // The key must include world_id: this table is process-wide, while node.id is a per-Cx counter
    // and ids of two windows fully overlap. Without world_id, a node in window B would hit the
    // intrinsic size of the same-id node in window A (content_version is also a small per-node
    // counter and easily equal), mixing up layouts.
    return (@as(u64, world_id) << 33) | (@as(u64, node_id) << 1) |
        (if (is_main_row) @as(u64, 1) else 0);
}

fn intrinsicCacheLookup(node: *const Node, is_main_row: bool) ?f32 {
    if (g_intrinsic_cache_refcount == 0) return null;
    const key = intrinsicCacheKey(node.world_id, node.id, is_main_row);
    if (g_intrinsic_cache.get(key)) |entry| {
        if (entry.content_version == node.meta.per_frame.caches.versions.content) {
            return entry.value;
        }
    }
    return null;
}

fn intrinsicCacheStore(node: *const Node, is_main_row: bool, value: f32) void {
    if (g_intrinsic_cache_refcount == 0) return;
    const key = intrinsicCacheKey(node.world_id, node.id, is_main_row);
    // Safe degradation: this is a pure memoization cache. A failed write only means re-measuring
    // next time with an identical result (intrinsicCacheStore has no side effects).
    g_intrinsic_cache.put(g_intrinsic_cache_allocator, key, .{
        .value = value,
        .content_version = node.meta.per_frame.caches.versions.content,
    }) catch {};
}

/// Enable intrinsic cache (refcounted, safe for nested multi-Cx). The first Cx.init allocates and
/// sets up; later Cx.init only does refcount++.
///
/// Known edge: the allocator is bound to the **first** Cx. If two Cx use different allocators and
/// the first-init Cx deinits first (refcount 1 -> no release), later puts still use the first
/// allocator; if it is destroyed => UAF. Not triggered when all Cx share one GPA; multiple App
/// each holding its own allocator need per-Cx table migration.
pub fn enableIntrinsicCache(allocator: Allocator) void {
    if (g_intrinsic_cache_refcount == 0) {
        g_intrinsic_cache_allocator = allocator;
        g_intrinsic_cache = .{};
    }
    g_intrinsic_cache_refcount += 1;
}

/// Disable cache (refcount--; last Cx.deinit releases).
pub fn disableIntrinsicCache() void {
    if (g_intrinsic_cache_refcount == 0) return;
    g_intrinsic_cache_refcount -= 1;
    if (g_intrinsic_cache_refcount == 0) {
        g_intrinsic_cache.deinit(g_intrinsic_cache_allocator);
        g_intrinsic_cache = .{};
    }
}

/// Layout context, pass frame allocator to all layout functions.
/// frame_allocator auto-clears at frame end, replaces fixed-size arrays on stack.
pub const LayoutContext = struct {
    frame_allocator: Allocator,
    /// Let layout pass measureIntrinsicTextWidth use GlyphRun pipeline, replaces
    /// direct measureTextWidthWithSpans. null -> downgrade to old path (compat with
    /// existing layoutNode test fixtures).
    shaping_cache: ?*shaping_cache_mod.ShapingCache = null,
    font_system: ?*text_module.FontSystem = null,
    /// Parent flex_shrink pinned this node on one axis (see isShrinkableFit): its own
    /// layoutChildren fit backfill end must not re-fit this axis per child actual size,
    /// else shrink gets propped back to content height, ScrollArea never scrolls.
    /// Only matches == this node, grandchild sees mismatch.
    frozen_node: ?*const Node = null,
    frozen_axis_is_width: bool = false,
};

/// CSS flex item auto-min: overflow != visible (here overflow_hidden) items min
/// size 0, can be squeezed below content; normal fit items min is content itself.
fn isShrinkableFit(child: *const Node, is_row: bool) bool {
    const main_sizing = if (is_row) child.style.width else child.style.height;
    return main_sizing == .fit and child.style.overflow_hidden and child.style.flex_shrink > 0;
}

/// Fast count Unicode chars (not bytes) in UTF-8 string.
/// For text intrinsic estimate.
fn countUtf8Chars(bytes: []const u8) usize {
    var count: usize = 0;
    var i: usize = 0;
    while (i < bytes.len) {
        // UTF-8 continuation bytes start 0b10xxxxxx, count heads only
        if (bytes[i] & 0xC0 != 0x80) count += 1;
        i += 1;
    }
    return count;
}

/// Merge sizing's built-in min/max with node ext.min_X / ext.max_X into the effective (min,max)
/// for this axis.
///
/// Why: `style.height = .fit{.max=N}` and `ext.max_height` are two clamp paths; row layout/grid
/// use `style.max_height()` (=ext), fit intrinsic uses `fit.max`. Middleware (e.g. popover
/// autosize) updating only one leaves the other stale (small popup bursting oversized).
///
///   effective_min = max(sizing_mm.min, ext.min)
///   effective_max = min(sizing_mm.max, ext.max)
///
/// Defaults (fit{}/grow{} min=0,max=inf; ext same) merge unchanged.
pub fn effectiveMinMax(sizing: Sizing, node: *const Node, comptime is_width: bool) struct { min: f32, max: f32 } {
    const ext_min: f32 = if (is_width) node.style.min_width() else node.style.min_height();
    const ext_max: f32 = if (is_width) node.style.max_width() else node.style.max_height();
    return switch (sizing) {
        .grow => |mm| .{ .min = @max(mm.min, ext_min), .max = @min(mm.max, ext_max) },
        .fit => |mm| .{ .min = @max(mm.min, ext_min), .max = @min(mm.max, ext_max) },
        // px / percent -> ext clamp (layout later reclamped by ext, no repeat here)
        else => .{ .min = ext_min, .max = ext_max },
    };
}

/// resolveSize for known child sizing + container available space -> child
/// actual size. **Not** effective_min_max, caller holding child node uses
/// helper above directly.
fn resolveSize(sizing: Sizing, available: f32, intrinsic: f32) f32 {
    return switch (sizing) {
        .px => |v| v,
        .grow => |mm| std.math.clamp(available, mm.min, mm.max),
        .fit => |mm| std.math.clamp(intrinsic, mm.min, mm.max),
        .percent => |p| available * p / 100.0,
    };
}

fn measureIntrinsicTextWidth(t: types.TextProps) f32 {
    // layout pass entry (layoutNode) sets thread-local
    // g_active_shaping_cache / g_active_font_system; this measureIntrinsicTextWidth
    // calc-chain has no ctx param, uses globals instead. layoutNode exit clears back.
    return measureIntrinsicTextWidthCtx(g_active_shaping_cache, g_active_font_system, t);
}

var g_active_shaping_cache: ?*shaping_cache_mod.ShapingCache = null;
var g_active_font_system: ?*text_module.FontSystem = null;

/// GlyphRun pipeline font-resolver hook.
///
/// == Why not just FontSystem.findFont(family='system') ==
/// findFont queries installed system fonts **by name**. An App using `loadFont(path)` (Inter /
/// Lora / JetBrains Mono shipped with the repo) has fonts that exist nowhere in the system
/// library; the by-name query misses and silently falls back to another family, so shaping and
/// renderer use two fonts and the same text gets two widths.
/// `setDefaultFamily('Inter')` does not fix this: it only replaces 'system' with 'Inter' in the
/// system query, which still misses when Inter is not installed.
///
/// So the App hands back **its own FontSelector-picked `*Font`**, running the same picker logic,
/// guaranteeing 'measured and drawn use the same Font object'. The returned Font is owned by the
/// App; the pipeline borrows and never releases it (opposite of findFont, see the owned branch in
/// shapeViaPipeline). `content` must be passed: render-side CJK/Korean fallback is picked by
/// content, so a parser ignoring the bytes can never match render (see
/// FontSelector.resolveFonts).
pub const ShapeFontResolveFn = *const fn (
    ctx: *anyopaque,
    content: []const u8,
    font_size: f32,
    font_weight: u16,
    use_italic: bool,
    use_monospace: bool,
    /// Font family id (render.FontRegistry). 0 = default family.
    /// Part of 'measured and drawn use the same font': render-side resolveFonts picks the face by
    /// family; if measure omits it, it falls to the default family and custom-font text
    /// cursor/selection are systematically offset.
    font_family: u16,
) ?*text_module.Font;

/// Application-owned authoritative width measurement. A renderer may segment
/// text, select fallback-stack fonts, or force a monospace cell advance after
/// shaping; resolving the same `*Font` is therefore necessary but not always
/// sufficient to reproduce the width that is actually drawn. Hosts should
/// wire this to the renderer's non-emitting draw path.
pub const DrawnTextMeasureFn = *const fn (
    ctx: *anyopaque,
    content: []const u8,
    font_size: f32,
    font_weight: u16,
    use_italic: bool,
    use_monospace: bool,
    font_family: u16,
    use_symbols: bool,
    monospace_char_width: f32,
) ?f32;

var g_shape_font_resolver: ?ShapeFontResolveFn = null;
var g_shape_font_resolver_ctx: ?*anyopaque = null;
var g_drawn_text_measure: ?DrawnTextMeasureFn = null;
var g_drawn_text_measure_ctx: ?*anyopaque = null;
var drawn_text_measure_debug_logged = false;
var g_context_font_owner: ?*anyopaque = null;

/// Load once app startup; pass null unload (revert to findFont old path).
pub fn setShapeFontResolver(f: ?ShapeFontResolveFn, ctx: ?*anyopaque) void {
    g_context_font_owner = null;
    g_shape_font_resolver = f;
    g_shape_font_resolver_ctx = ctx;
}

/// Borrow the host's default UI face; ownership stays with the host.
pub fn resolveDefaultTextFont(text: []const u8, size: f32, weight: u16, italic: bool) ?*text_module.Font {
    return resolveTextFont(text, size, weight, italic, false, 0);
}

pub fn resolveTextFont(text: []const u8, size: f32, weight: u16, italic: bool, mono: bool, family: u16) ?*text_module.Font {
    const resolve = g_shape_font_resolver orelse return null;
    return resolve(g_shape_font_resolver_ctx orelse return null, text, size, weight, italic, mono, family);
}

pub fn setContextFontHooks(owner: *anyopaque, resolve: ?ShapeFontResolveFn, measure: ?DrawnTextMeasureFn, ctx: ?*anyopaque) void {
    setShapeFontResolver(resolve, ctx);
    setDrawnTextMeasure(measure, ctx);
    g_context_font_owner = owner;
}

pub fn clearContextFontHooks(owner: *anyopaque) void {
    if (g_context_font_owner != owner) return;
    setShapeFontResolver(null, null);
    setDrawnTextMeasure(null, null);
}

/// Install the application's authoritative "width as drawn" callback.
/// Passing null removes it and restores the internal shaping fallback.
pub fn setDrawnTextMeasure(f: ?DrawnTextMeasureFn, ctx: ?*anyopaque) void {
    g_context_font_owner = null;
    g_drawn_text_measure = f;
    g_drawn_text_measure_ctx = ctx;
}

/// Inject the hook into text_layout.measureProportional. GlyphRun pipeline unavailable -> NaN,
/// caller falls back to platform measure.
///
/// Outside **layout** (draw/overlay/hit-test), temporarily mounts the same GlyphRun measure
/// hook, then restores.
///
/// # Why it's required
///
/// Hooks only live during `layoutNode` (see setShapeMeasureFn below). Same text: **layout** uses
/// shaping width, but overlay `measureProportional` finds no hook and falls to **platform
/// measure**. The paths mismatch, so selection highlight/caret drift toward the line end.
///
/// Caller (RAII style):
/// ```zig
/// var guard = beginExternalShapeMeasure(cx);
/// defer guard.end();
/// ```
pub const ExternalShapeMeasureGuard = struct {
    prev_cache: ?*shaping_cache_mod.ShapingCache,
    prev_fs: ?*text_module.FontSystem,
    prev_installed: bool,

    pub fn end(self: ExternalShapeMeasureGuard) void {
        g_active_shaping_cache = self.prev_cache;
        g_active_font_system = self.prev_fs;
        if (!self.prev_installed) text_layout.setShapeMeasureFn(null);
    }
};

pub fn beginExternalShapeMeasure(
    cache: ?*shaping_cache_mod.ShapingCache,
    fs: ?*text_module.FontSystem,
) ExternalShapeMeasureGuard {
    const guard = ExternalShapeMeasureGuard{
        .prev_cache = g_active_shaping_cache,
        .prev_fs = g_active_font_system,
        .prev_installed = text_layout.hasShapeMeasure(),
    };
    g_active_shaping_cache = cache;
    g_active_font_system = fs;
    text_layout.setShapeMeasureFn(&shapeMeasureBridge);
    return guard;
}

fn shapeMeasureBridge(text: []const u8, font_size: f32, font_weight: u16, use_italic: bool, use_monospace: bool) f32 {
    return shapeViaPipeline(g_active_shaping_cache, g_active_font_system, text, font_size, font_weight, use_italic, use_monospace, 0, false, 0) orelse std.math.nan(f32);
}

/// cx-aware variant, spans empty -> GlyphRun pipeline (cache hit direct return
/// total_advance), else downgrade to measureTextWidthWithSpans old span path.
/// Full switch needs GlyphRun sub-range shape, phase D+ work.
fn measureIntrinsicTextWidthCtx(
    cache: ?*shaping_cache_mod.ShapingCache,
    fs: ?*text_module.FontSystem,
    t: types.TextProps,
) f32 {
    const layout_spans = if (t.spans_affect_layout) t.spans else &.{};
    if (t.wrap != .none) {
        const layout = text_layout.computeTextLayout(
            t.content,
            std.math.inf(f32),
            t.wrap,
            t.max_lines,
            t.font_size,
            t.line_height,
            t.font_weight,
            t.use_italic_font,
            t.use_monospace_font,
            layout_spans,
        );
        return layout.max_line_width;
    }
    // Single-line measure no spans -> GlyphRun pipeline fast path
    if (layout_spans.len == 0) {
        if (shapeViaPipeline(cache, fs, t.content, t.font_size, t.font_weight, t.use_italic_font, t.use_monospace_font, t.font_family, t.use_symbols_font, t.monospace_char_width)) |w| {
            return w;
        }
    }
    return text_layout.measureTextWidthWithSpans(
        t.content,
        0,
        @intCast(t.content.len),
        t.font_size,
        t.font_weight,
        t.use_italic_font,
        t.use_monospace_font,
        layout_spans,
    );
}

/// Internal helper: measure text width via the GlyphRun pipeline from layout_engine. Mirrors
/// cx.shapeText / measureSegmentWidthCtx and uses the same ShapingKey schema.
/// Fail (FontLookupFailed/OOM) -> null, caller falls back to the old path.
/// Shapes and measures through the same font resolver used by the renderer. Render-time
/// rich-text chunk positioning also uses this entry point so it cannot silently fall back to a
/// different family than layout/drawing.
pub fn shapeViaPipeline(
    cache_opt: ?*shaping_cache_mod.ShapingCache,
    fs_opt: ?*text_module.FontSystem,
    text: []const u8,
    font_size: f32,
    font_weight: u16,
    use_italic: bool,
    use_monospace: bool,
    font_family: u16,
    use_symbols: bool,
    monospace_char_width: f32,
) ?f32 {
    if (text.len == 0) return 0;
    // This is the only answer that can be guaranteed identical to drawing:
    // it executes the TextRenderer's own segment/font/advance loop without
    // emitting glyphs. The local shaper below remains a compatibility fallback
    // for bare Cx/tests and hosts that have not installed the new callback.
    if (g_drawn_text_measure) |measure| {
        if (g_drawn_text_measure_ctx) |ctx| {
            if (measure(ctx, text, font_size, font_weight, use_italic, use_monospace, font_family, use_symbols, monospace_char_width)) |width| {
                if (!drawn_text_measure_debug_logged and @import("zenit_environment").has("ZENIT_TEXT_MEASURE_IDENTITY_CHECK")) {
                    drawn_text_measure_debug_logged = true;
                    std.log.info("[text-measure-source] drawn-active", .{});
                }
                return width;
            }
        }
    }
    // Only the compatibility shaper needs these objects. The authoritative
    // width-as-drawn callback above must remain usable by lightweight/bare
    // contexts, otherwise installing it can still be silently bypassed.
    const cache = cache_opt orelse return null;
    const fs = fs_opt orelse return null;
    var hasher = std.hash.Wyhash.init(0);
    hasher.update(text);
    var weight_buf: [2]u8 = undefined;
    std.mem.writeInt(u16, &weight_buf, font_weight, .little);
    hasher.update(&weight_buf);
    const flag_byte: [1]u8 = .{(if (use_italic) @as(u8, 1) else 0) | (if (use_monospace) @as(u8, 2) else 0)};
    hasher.update(&flag_byte);
    const key = shaping_cache_mod.ShapingKey{
        .text_hash = hasher.final(),
        .text_len = @intCast(text.len),
        // family must enter key: family change needs re-shape, else hit previous
        // family cache.
        .font_id = (@as(u32, font_family) << 1) | (if (use_monospace) @as(u32, 1) else 0),
        .max_width = 0,
        .font_size = font_size,
    };
    if (cache.lookup(key)) |run| return run.total_advance;

    // Priority ask App's resolver: it returns renderer-running **same** *Font,
    // let shape pipeline (caret/selection/hit) measure same as draw. Fallback
    // by-name query system fonts (no App bare Cx / unit test goes this).
    // Ownership differs: resolver borrow (App holds), findFont new -> must deinit.
    var owned_font: ?*text_module.Font = null;
    defer if (owned_font) |f| f.deinit();
    const font = blk: {
        if (g_shape_font_resolver) |resolve| {
            if (g_shape_font_resolver_ctx) |ctx| {
                if (resolve(ctx, text, font_size, font_weight, use_italic, use_monospace, font_family)) |f| break :blk f;
            }
        }
        const desc = text_module.FontDescriptor{
            .family = "system",
            .size = font_size,
            .weight = mapFontWeight(font_weight),
            .style = if (use_italic) .italic else .normal,
        };
        const f = fs.findFont(desc) catch return null;
        owned_font = f;
        break :blk f;
    };
    var shaper = text_module.TextShaper.init(cache.allocator) catch return null;
    defer shaper.deinit();
    const shaped = shaper.shapeWithOptions(text, font, use_italic) catch return null;
    defer cache.allocator.free(shaped);
    defer releaseShapedFallbackFontRefs(shaped);
    const metrics = glyph_run_mod.FontMetrics{ .ascent = 0, .descent = 0, .line_gap = 0, .font_size = font_size };
    const run = text_shaper_adapter.fromShapedGlyphs(cache.allocator, shaped, metrics, .ltr) catch return null;
    defer cache.allocator.free(run.glyphs);
    defer cache.allocator.free(run.clusters);
    // Shaper per font's own pixelSize shapes advance. Resolver may return
    // neighboring-size font preloaded (FontSelector only derives past epsilon),
    // must scale to requested size, exactly same formula as
    // FontSelector.measureTextWidth `font_size / font.pixelSize()`,
    // both paths align.
    const font_px = font.pixelSize();
    const text_scale: f32 = if (font_px > 0) font_size / font_px else 1.0;
    const total = run.total_advance * text_scale;
    cache.insert(key, run.glyphs, run.clusters, run.metrics, run.direction, total) catch return total;
    return total;
}

fn mapFontWeight(weight: u16) text_module.FontWeight {
    return if (weight <= 100) .thin else if (weight <= 300) .light else if (weight <= 400) .regular else if (weight <= 500) .medium else if (weight <= 600) .semibold else if (weight <= 700) .bold else if (weight <= 800) .heavy else .black;
}

test "shapeViaPipeline prefers the authoritative drawn-width callback" {
    const Bridge = struct {
        var calls: usize = 0;

        fn measure(
            _: *anyopaque,
            content: []const u8,
            font_size: f32,
            font_weight: u16,
            use_italic: bool,
            use_monospace: bool,
            font_family: u16,
            use_symbols: bool,
            monospace_char_width: f32,
        ) ?f32 {
            calls += 1;
            std.debug.assert(std.mem.eql(u8, content, "mono span"));
            std.debug.assert(font_size == 13);
            std.debug.assert(font_weight == 600);
            std.debug.assert(use_italic);
            std.debug.assert(use_monospace);
            std.debug.assert(font_family == 7);
            std.debug.assert(use_symbols);
            std.debug.assert(monospace_char_width == 8.25);
            return 123.5;
        }
    };

    var marker: u8 = 0;
    setDrawnTextMeasure(&Bridge.measure, @ptrCast(&marker));
    defer setDrawnTextMeasure(null, null);
    Bridge.calls = 0;

    // The authoritative renderer callback must not be gated on the optional
    // local-shaper objects; otherwise a partially configured Cx bypasses the
    // correct answer and silently returns to platform measurement.
    const width = shapeViaPipeline(null, null, "mono span", 13, 600, true, true, 7, true, 8.25);
    try std.testing.expectEqual(@as(?f32, 123.5), width);
    try std.testing.expectEqual(@as(usize, 1), Bridge.calls);
}

/// Calculate node intrinsic size (fit mode). Text nodes return text estimate,
/// container nodes recursively sum children.
fn calcIntrinsicSize(node: *Node, comptime is_main_row: bool) f32 {
    // Subtree layout dirty -> offspring size may changed, but node
    // content_version doesn't track offspring change; cache entry can't see;
    // must bypass cache to recalc (fix stale intrinsic layout bug).
    const subtree_dirty = node.frame_state.state_bits.dirty.core.layout or
        node.frame_state.state_bits.dirty.core.subtree_layout;
    // Cache lookup (by node.id + content_version)
    if (!subtree_dirty) {
        if (intrinsicCacheLookup(node, is_main_row)) |cached| return cached;
    }

    if (!enterLayoutRecursion()) return 0;
    defer leaveLayoutRecursion();

    const result = calcIntrinsicSizeUncached(node, is_main_row);
    intrinsicCacheStore(node, is_main_row, result);
    return result;
}

fn calcIntrinsicSizeUncached(node: *Node, comptime is_main_row: bool) f32 {
    // Text node: estimate text size + node self padding
    if (node.getText()) |t| {
        const pad = if (is_main_row) node.style.padding.horizontal() else node.style.padding.vertical();
        // Multi-line text: use computed text_layout
        if (t.wrap != .none) {
            if (node.layoutTextLayout()) |tl| {
                if (is_main_row) {
                    return tl.max_line_width + pad;
                } else {
                    return tl.total_height + pad;
                }
            }
        }
        // Single-line text: prefer precise measure, fallback estimate
        const text_size = if (is_main_row) blk: {
            const measured = measureIntrinsicTextWidth(t);
            if (measured > 0) break :blk measured;
            // fallback: rough estimate
            const char_count = countUtf8Chars(t.content);
            break :blk @as(f32, @floatFromInt(char_count)) * t.font_size * 0.6;
        } else t.font_size * t.line_height;
        return text_size + pad;
    }

    // Container node: sum children main-axis
    if (node.children.items.len == 0) return 0;

    const pad = if (is_main_row) node.style.padding.horizontal() else node.style.padding.vertical();
    // Absolute children don't participate in intrinsic (avoid overlay impact layout)
    var flow_count: usize = 0;
    for (node.children.items) |child| {
        if (!isOutOfFlow(child)) flow_count += 1;
    }
    if (flow_count == 0) return pad;

    const gap_total = if (flow_count > 1)
        @as(f32, @floatFromInt(flow_count - 1)) * node.style.gap
    else
        0;

    const child_is_row = node.style.direction.isRow();

    // Main and cross axis depend on container's own direction
    if (child_is_row == is_main_row) {
        // Same direction: sum children main
        var total: f32 = 0;
        for (node.children.items) |child| {
            if (isOutOfFlow(child)) continue;
            total += calcChildIntrinsicSize(child, is_main_row) + childMarginForAxis(child, is_main_row);
        }
        return total + gap_total + pad;
    } else {
        // Cross direction: take max of children
        var max_size: f32 = 0;
        for (node.children.items) |child| {
            if (isOutOfFlow(child)) continue;
            max_size = @max(max_size, calcChildIntrinsicSize(child, is_main_row) + childMarginForAxis(child, is_main_row));
        }
        return max_size + pad;
    }
}

/// Calculate single child intrinsic main-axis. Note: .grow child in .fit parent
/// has no space to allocate, should fallback to intrinsic (matches CSS
/// flex-grow in fit-content).
fn calcChildIntrinsicSize(child: *Node, comptime is_main_row: bool) f32 {
    if (isOutOfFlow(child)) return 0;
    // flex_basis > 0 -> intrinsic main-axis (fit parent compute use)
    if (child.style.flex_basis() > 0) return child.style.flex_basis();
    const sizing = if (is_main_row) child.style.width else child.style.height;
    return switch (sizing) {
        .px => |v| v,
        // grow/fit min/max with ext.min_X/ext.max_X merged via effectiveMinMax
        // (unified clamp). Else .fit{.max=N} and ext.max=M out-of-sync ->
        // one works one doesn't (small popup bust-oversized bug).
        .grow, .fit => blk: {
            const mm = effectiveMinMax(sizing, child, is_main_row);
            break :blk std.math.clamp(calcIntrinsicSize(child, is_main_row), mm.min, mm.max);
        },
        .percent => 0,
    };
}

fn childMarginForAxis(child: *const Node, comptime is_main_row: bool) f32 {
    return if (is_main_row) child.style.marginHorizontal() else child.style.marginVertical();
}

const ResolvedAxisMargins = struct {
    start: f32,
    end: f32,
};

/// Main size: flex_basis/px/grow/fit/percent, unified minus flex_shrink shrink.
/// `is_row` pick width or height, only difference between row/column.
fn resolveMainAxisSize(
    child: *Node,
    comptime is_row: bool,
    available: Size,
    shrink_delta: f32,
    flex_unit: f32,
) f32 {
    const sizing = if (is_row) child.style.width else child.style.height;
    const avail = if (is_row) available.width else available.height;

    // flex_basis > 0 and non-grow -> use flex_basis as main
    if (child.style.flex_basis() > 0 and sizing != .grow) {
        return @max(0, child.style.flex_basis() - shrink_delta);
    }
    return @max(0, switch (sizing) {
        .px => |v| v - shrink_delta,
        // grow allocated per flex_unit, skips shrink (shrink only when flex_total==0)
        .grow => child.style.flex * flex_unit,
        .fit => calcIntrinsicSize(child, is_row) - shrink_delta,
        .percent => |p| avail * p / 100.0 - shrink_delta,
    });
}

/// Cross size: px/grow/fit/percent, plus align-stretch override.
/// Cross not participate in flex_shrink.
fn resolveCrossAxisSize(
    child: *Node,
    comptime is_row: bool,
    available: Size,
    cross_align: types.AlignItems,
) f32 {
    const sizing = if (is_row) child.style.height else child.style.width;
    const avail = if (is_row) available.height else available.width;
    const margin_cross = if (is_row) child.style.marginVertical() else child.style.marginHorizontal();

    var size = switch (sizing) {
        .px => |v| v,
        .grow => |mm| std.math.clamp(avail - margin_cross, mm.min, mm.max),
        .fit => calcIntrinsicSize(child, !is_row),
        .percent => |p| avail * p / 100.0,
    };
    // stretch override: only applies to content-driven sizing (grow / fit); px / percent are
    // explicit sizes
    if ((sizing == .grow or sizing == .fit) and cross_align == .stretch) {
        size = avail - margin_cross;
    }
    return size;
}

fn resolveAxisMargins(
    available_outer: f32,
    child_size: f32,
    start_value: f32,
    end_value: f32,
    start_auto: bool,
    end_auto: bool,
) ResolvedAxisMargins {
    const fixed = (if (start_auto) 0 else start_value) + (if (end_auto) 0 else end_value);
    const free = @max(@as(f32, 0), available_outer - child_size - fixed);
    if (start_auto and end_auto) {
        const half = free / 2.0;
        return .{ .start = half, .end = half };
    }
    if (start_auto) return .{ .start = free, .end = end_value };
    if (end_auto) return .{ .start = start_value, .end = free };
    return .{ .start = start_value, .end = end_value };
}

/// Measure phase: computes the node's precise intrinsic size under given constraints.
///
/// Difference from calcIntrinsicSize:
/// - measureNode wraps text once width is known (resolves "width determines height")
/// - result is more precise, used to eliminate backfill in fit containers
///
/// constraints.definite_width != null -> text can wrap, returns exact height
/// constraints.definite_width == null -> returns minimum intrinsic size
pub fn measureNode(node: *Node, constraints: types.LayoutConstraints) Size {
    if (!enterLayoutRecursion()) {
        return Size.init(
            std.math.clamp(node.style.padding.horizontal(), constraints.min_width, constraints.max_width),
            std.math.clamp(node.style.padding.vertical(), constraints.min_height, constraints.max_height),
        );
    }
    defer leaveLayoutRecursion();

    // text node
    if (node.getText()) |t| {
        const pad_w = node.style.padding.horizontal();
        const pad_h = node.style.padding.vertical();

        // width
        const text_w = blk: {
            if (constraints.definite_width) |dw| {
                break :blk dw;
            }
            // intrinsic width: precise measurement
            const measured = measureIntrinsicTextWidth(t);
            if (measured > 0) break :blk measured + pad_w;
            const char_count = countUtf8Chars(t.content);
            break :blk @as(f32, @floatFromInt(char_count)) * t.font_size * 0.6 + pad_w;
        };

        // height: performs text wrapping with definite width
        const text_h = blk: {
            if (t.wrap != .none) {
                const avail_w = if (constraints.definite_width) |dw|
                    dw - pad_w
                else if (constraints.max_width < std.math.inf(f32))
                    constraints.max_width - pad_w
                else
                    0;

                if (avail_w > 0) {
                    // execute wrapping calculation
                    const tl = text_layout.computeTextLayout(
                        t.content,
                        avail_w,
                        t.wrap,
                        t.max_lines,
                        t.font_size,
                        t.line_height,
                        t.font_weight,
                        t.use_italic_font,
                        t.use_monospace_font,
                        t.spans,
                    );
                    // cache to node, avoiding redundant computation in subsequent layout phase
                    node.storeTextLayout(&tl) catch {
                        layout_alloc_failure_hits += 1;
                        // Never publish a partial cache or render stale wraps.
                        node.clearTextLayout();
                        node.frame_state.state_bits.dirty.core.layout = true;
                    };
                    break :blk tl.total_height + pad_h;
                }
            }
            // single-line or no width constraint
            break :blk t.font_size * t.line_height + pad_h;
        };

        return Size.init(
            std.math.clamp(text_w, constraints.min_width, constraints.max_width),
            std.math.clamp(text_h, constraints.min_height, constraints.max_height),
        );
    }

    // container node: recursively measure children
    if (node.children.items.len == 0) {
        return Size.init(
            std.math.clamp(node.style.padding.horizontal(), constraints.min_width, constraints.max_width),
            std.math.clamp(node.style.padding.vertical(), constraints.min_height, constraints.max_height),
        );
    }

    const is_row = node.style.direction.isRow();
    const pad_w = node.style.padding.horizontal();
    const pad_h = node.style.padding.vertical();

    var main_total: f32 = 0;
    var cross_max: f32 = 0;
    var flow_count: usize = 0;

    for (node.children.items) |child| {
        if (isOutOfFlow(child)) continue;
        flow_count += 1;
        const margin_main = if (is_row) child.style.marginHorizontal() else child.style.marginVertical();
        const margin_cross = if (is_row) child.style.marginVertical() else child.style.marginHorizontal();

        // child's intrinsic size
        const child_main_sizing = if (is_row) child.style.width else child.style.height;
        const child_cross_sizing = if (is_row) child.style.height else child.style.width;

        const child_main: f32 = switch (child_main_sizing) {
            .px => |v| v + margin_main,
            .grow, .fit => blk: {
                // for fit children: if definite main-axis constraint exists, pass to child
                const child_constraints = if (is_row)
                    types.LayoutConstraints{ .max_width = @max(@as(f32, 0), constraints.max_width - pad_w - margin_main) }
                else
                    types.LayoutConstraints{ .max_height = @max(@as(f32, 0), constraints.max_height - pad_h - margin_main) };
                const child_size = measureNode(child, child_constraints);
                break :blk (if (is_row) child_size.width else child_size.height) + margin_main;
            },
            .percent => 0, // percent in intrinsic = auto (CSS spec)
        };

        const child_cross: f32 = switch (child_cross_sizing) {
            .px => |v| v + margin_cross,
            .grow, .fit => blk: {
                const child_constraints = if (is_row)
                    types.LayoutConstraints{ .max_height = @max(@as(f32, 0), constraints.max_height - pad_h - margin_cross) }
                else
                    types.LayoutConstraints{ .max_width = @max(@as(f32, 0), constraints.max_width - pad_w - margin_cross) };
                const child_size = measureNode(child, child_constraints);
                break :blk (if (is_row) child_size.height else child_size.width) + margin_cross;
            },
            .percent => 0,
        };

        main_total += child_main;
        cross_max = @max(cross_max, child_cross);
    }

    if (flow_count > 1) {
        main_total += @as(f32, @floatFromInt(flow_count - 1)) * node.style.gap;
    }

    const w = if (is_row) main_total + pad_w else cross_max + pad_w;
    const h = if (is_row) cross_max + pad_h else main_total + pad_h;

    return Size.init(
        std.math.clamp(w, constraints.min_width, constraints.max_width),
        std.math.clamp(h, constraints.min_height, constraints.max_height),
    );
}

pub fn layoutNode(node: *Node, available: Size, ctx: LayoutContext) void {
    if (!enterLayoutRecursion()) return;
    defer leaveLayoutRecursion();

    // GlyphRun pipeline globals: measureIntrinsicTextWidth's call chain has no ctx parameter, so
    // the layout pass sets/restores globals at entry so it can use the cache.
    // Outer values are saved across nested layoutNode (recursive child) so unwinding restores them.
    //
    // Also installs shapeMeasureBridge as the text_layout.measureProportional callback, so *all*
    // legacy measurement paths (computeTextLayout / findLineBreak / measureSpanAware / textarea
    // direct / input/text_utils direct) use the pipeline without caller changes.
    const prev_cache = g_active_shaping_cache;
    const prev_fs = g_active_font_system;
    g_active_shaping_cache = ctx.shaping_cache;
    g_active_font_system = ctx.font_system;
    text_layout.setShapeMeasureFn(&shapeMeasureBridge);
    defer {
        g_active_shaping_cache = prev_cache;
        g_active_font_system = prev_fs;
        // unwind at nested exit or top-level exit; unset if prev_cache=null, otherwise keep set
        if (prev_cache == null and prev_fs == null) {
            text_layout.setShapeMeasureFn(null);
        }
    }

    // layout_isolation debug assert: isolation node cannot be fit (else internal changes affect
    // outer sizing)
    if (node.style.layout_isolation) {
        std.debug.assert(node.style.width != .fit and node.style.height != .fit);
    }

    // compute self-size only for root node; children's sizes are layoutChildren's responsibility
    if (node.parent == null) {
        const intrinsic_w = calcIntrinsicSize(node, true);
        const intrinsic_h = calcIntrinsicSize(node, false);

        node.setLayoutW(resolveSize(node.style.width, available.width, intrinsic_w));
        node.setLayoutH(resolveSize(node.style.height, available.height, intrinsic_h));
    }

    const w = node.rectFromWorldOrFallback().w;
    const h = node.rectFromWorldOrFallback().h;

    if (node.children.items.len > 0) {
        if (node.frame_state.state_bits.dirty.core.layout) {
            // current node dirty -> full layout children (flex depends on sibling relations)
            const content_w = w - node.style.padding.horizontal();
            const content_h = h - node.style.padding.vertical();
            if (node.style.grid() != null) {
                layoutChildrenGrid(node, Size.init(content_w, content_h), ctx);
            } else {
                layoutChildren(node, Size.init(content_w, content_h), ctx);
            }
        } else if (node.frame_state.state_bits.dirty.core.subtree_layout) {
            const own_main_fit = if (node.style.direction.isRow())
                node.style.width == .fit
            else
                node.style.height == .fit;
            const own_cross_fit = if (node.style.direction.isRow())
                node.style.height == .fit
            else
                node.style.width == .fit;

            // fit containers cannot recurse only dirty subtree: their self-size depends on actual
            // layout results of descendants.
            // Typical scenario: wrapped text deepens, direct child only has subtree_dirty;
            // skip full layout here -> parent keeps old rect, overflow_hidden clips content.
            if (own_main_fit or own_cross_fit) {
                const content_w = w - node.style.padding.horizontal();
                const content_h = h - node.style.padding.vertical();
                if (node.style.grid() != null) {
                    layoutChildrenGrid(node, Size.init(content_w, content_h), ctx);
                } else {
                    layoutChildren(node, Size.init(content_w, content_h), ctx);
                }
            } else
            // Grid container: needs full relayout when direct child layout_dirty.
            // Grid track sizing (including implicit auto rows) depends on child sizes,
            // and child positions are determined by auto-placement (sibling-related),
            // so any dirty child requires full recalculation.
            if (node.style.grid() != null) {
                var need_full = false;
                for (node.children.items) |child| {
                    if (child.frame_state.state_bits.dirty.core.layout) {
                        need_full = true;
                        break;
                    }
                }
                if (need_full) {
                    const content_w = w - node.style.padding.horizontal();
                    const content_h = h - node.style.padding.vertical();
                    layoutChildrenGrid(node, Size.init(content_w, content_h), ctx);
                } else {
                    for (node.children.items) |child| {
                        if (child.frame_state.state_bits.dirty.core.layout or child.frame_state.state_bits.dirty.core.subtree_layout) {
                            layoutNode(child, Size.init(child.rectFromWorldOrFallback().w, child.rectFromWorldOrFallback().h), ctx);
                        }
                    }
                }
            } else {
                const is_row = node.style.direction.isRow();
                // subtree has dirty nodes -> check for flex sibling dependency.
                // If grow children exist, one child's size change affects flex allocation of other
                // siblings,
                // fallback to full relayout required.
                var has_flex_children = false;
                for (node.children.items) |child| {
                    if (isOutOfFlow(child)) continue;
                    const main_sizing = if (is_row) child.style.width else child.style.height;
                    if (main_sizing == .grow) {
                        has_flex_children = true;
                        break;
                    }
                }

                if (has_flex_children) {
                    // optimization: full layout only when "direct child layout may affect sibling
                    // allocation".
                    // Typical scroll scenario is only deep subtree_dirty (direct child size
                    // unchanged), no fallback.
                    var must_full_layout = false;
                    for (node.children.items) |child| {
                        if (isOutOfFlow(child)) continue;
                        const main_sizing = if (is_row) child.style.width else child.style.height;
                        if (child.frame_state.state_bits.dirty.core.layout) {
                            must_full_layout = true;
                            break;
                        }
                        if (child.frame_state.state_bits.dirty.core.subtree_layout and main_sizing == .fit) {
                            must_full_layout = true;
                            break;
                        }
                    }

                    if (must_full_layout) {
                        const content_w = w - node.style.padding.horizontal();
                        const content_h = h - node.style.padding.vertical();
                        layoutChildren(node, Size.init(content_w, content_h), ctx);
                    } else {
                        for (node.children.items) |child| {
                            if (child.frame_state.state_bits.dirty.core.layout or child.frame_state.state_bits.dirty.core.subtree_layout) {
                                // Absolute layout-dirty children must call layoutAbsoluteChild to
                                // re-resolve size/position:
                                // the must_full_layout path above intentionally skips absolute
                                // children (they do not affect flow
                                // siblings), but the fallback recursion layoutNode(child, old_rect)
                                // leaves **absolute children
                                // appended after the first layout with rect = 0**, so text labels
                                // on canvas objects never render.
                                if (isDisplayNone(child)) {
                                    collapseDisplayNone(child);
                                } else if (child.style.position == .absolute and absoluteChildNeedsResolve(child)) {
                                    layoutAbsoluteChild(node, child, ctx);
                                } else {
                                    layoutNode(child, Size.init(child.rectFromWorldOrFallback().w, child.rectFromWorldOrFallback().h), ctx);
                                }
                            }
                        }
                    }
                } else {
                    // without flex dependency: if direct child layout_dirty (size/position style
                    // changed),
                    // still need full layout to update that child's rect in parent.
                    // Just recursing layoutNode(child) won't recalculate flow child x/y/w/h.
                    var must_full_layout = false;
                    for (node.children.items) |child| {
                        if (isOutOfFlow(child)) continue;
                        const main_sizing = if (is_row) child.style.width else child.style.height;
                        if (child.frame_state.state_bits.dirty.core.layout) {
                            must_full_layout = true;
                            break;
                        }
                        if (child.frame_state.state_bits.dirty.core.subtree_layout and main_sizing == .fit) {
                            must_full_layout = true;
                            break;
                        }
                    }

                    if (must_full_layout) {
                        const content_w = w - node.style.padding.horizontal();
                        const content_h = h - node.style.padding.vertical();
                        layoutChildren(node, Size.init(content_w, content_h), ctx);
                    } else {
                        for (node.children.items) |child| {
                            if (child.frame_state.state_bits.dirty.core.layout or child.frame_state.state_bits.dirty.core.subtree_layout) {
                                // Absolute layout-dirty children must call layoutAbsoluteChild to
                                // re-resolve size/position:
                                // the must_full_layout path above intentionally skips absolute
                                // children (they do not affect flow
                                // siblings), but the fallback recursion layoutNode(child, old_rect)
                                // leaves **absolute children
                                // appended after the first layout with rect = 0**, so text labels
                                // on canvas objects never render.
                                if (isDisplayNone(child)) {
                                    collapseDisplayNone(child);
                                } else if (child.style.position == .absolute and absoluteChildNeedsResolve(child)) {
                                    layoutAbsoluteChild(node, child, ctx);
                                } else {
                                    layoutNode(child, Size.init(child.rectFromWorldOrFallback().w, child.rectFromWorldOrFallback().h), ctx);
                                }
                            }
                        }
                    }
                }
            }
        }
        // both false -> skip entire subtree (core optimization for incremental layout)
    }

    // After layout: an overflow_hidden node that is layout_dirty this pass (size/position may have
    // changed) must invalidate its render cache and be marked render dirty. Otherwise:
    // 1. the old cache's push_clip rect and child coordinates are stale -> wrong cache reused
    // 2. children mounted in the first frame, not fully laid out -> incomplete content is rendered
    //    and
    //    cached -> later subtree_render_dirty is cleared -> incomplete cache reused, content lost
    // markRenderDirty bubbles subtree_render_dirty up, so ancestor overflow_hidden containers
    // (e.g. scroll_area) caches are invalidated too.
    if (node.frame_state.state_bits.dirty.core.layout and node.style.overflow_hidden) {
        node.invalidateRenderCache();
        node.markRenderDirty();
    }

    // compute child bounding box (for hitTest culling)
    // only recalculate on layout_dirty or subtree_dirty, avoid redundant per-frame computation
    if (node.frame_state.state_bits.dirty.core.layout or node.frame_state.state_bits.dirty.core.subtree_layout) {
        computeChildrenBBox(node);
    }

    node.frame_state.state_bits.dirty.core.layout = false;
    node.frame_state.state_bits.dirty.core.subtree_layout = false;

    // trigger onMount lifecycle hook (current node only).
    // children fire in their own layoutNode call tail, avoiding full-tree scan per frame.
    node_mod.fireMountIfNeeded(node);
}

/// compute children's painted bounding box union (relative to this node, includes translate
/// offset). A child counts with everything it paints outside its own rect: every shadow layer,
/// its outline, and (unless it clips them) its own descendants' painted box. Used by hitTest
/// culling and as the offscreen surface extent of opacity/composited layers: a descendant's
/// shadow outside this box is cut by the texture edge into a hard rectangle.
fn computeChildrenBBox(node: *Node) void {
    const lo = node.layoutOutputPtr() orelse return;
    var bbox: ?types.ComputedRect = null;
    for (node.children.items) |child| {
        if (child.getOpacity() == 0) continue;
        // z>0 children also count: z_index affects sibling order only, doesn't escape clipping,
        // drawn in parent's opacity surface like z=0, must expand surface bbox (geometry uses it
        // for surface bounds), else z>0 children overflow parent frame get clipped by texture edge.
        const r = child.rectFromWorldOrFallback();
        if (r.w <= 0 or r.h <= 0) continue;
        const cx = r.x + child.style.translate_x + child.frame_state.frame_local.runtime.sticky.x;
        const cy = r.y + child.style.translate_y + child.frame_state.frame_local.runtime.sticky.y;
        const rect = types.ComputedRect.init(cx, cy, r.w, r.h);
        // A minimum margin for ink that styles do not describe (glyph overhang, AA).
        var ink = types.ComputedRect.init(cx - children_ink_margin, cy - children_ink_margin, r.w + children_ink_margin * 2, r.h + children_ink_margin * 2);
        ink = unionComputed(ink, paintedRect(&child.style, rect));
        if (!child.style.overflow_hidden) {
            if (child.layoutOutputPtr()) |child_lo| if (child_lo.artifacts.children_bbox) |nested| {
                ink = unionComputed(ink, types.ComputedRect.init(cx + nested.x, cy + nested.y, nested.w, nested.h));
            };
        }
        bbox = if (bbox) |b| unionComputed(b, ink) else ink;
    }
    lo.artifacts.children_bbox = bbox;
}

const children_ink_margin: f32 = 8;

/// `rect` plus what `style` paints beyond it: each shadow layer (blur on both sides, positive
/// spread, offset) and the outline. Same extent rule as the opacity-layer bounds.
fn paintedRect(style: anytype, rect: types.ComputedRect) types.ComputedRect {
    var out = rect;
    for (style.shadowSlice()) |shadow| {
        const grow = shadow.blur * 2 + @max(@as(f32, 0), shadow.spread);
        out = unionComputed(out, types.ComputedRect.init(rect.x + shadow.offset_x - grow, rect.y + shadow.offset_y - grow, rect.w + grow * 2, rect.h + grow * 2));
    }
    if (style.outline()) |o| {
        const m = @max(@as(f32, 0), o.offset + o.width);
        out = unionComputed(out, types.ComputedRect.init(rect.x - m, rect.y - m, rect.w + m * 2, rect.h + m * 2));
    }
    return out;
}

fn unionComputed(a: types.ComputedRect, b: types.ComputedRect) types.ComputedRect {
    const x0 = @min(a.x, b.x);
    const y0 = @min(a.y, b.y);
    return types.ComputedRect.init(x0, y0, @max(a.x + a.w, b.x + b.w) - x0, @max(a.y + a.h, b.y + b.h) - y0);
}

/// batch reverse: mirror-flip direct children's position on main axis,
/// in relative coords only direct children's rect changes, no O(N) recursive descendant offset
fn batchReverseChildren(
    children: []*Node,
    comptime is_row: bool,
    main_start: f32,
    main_end: f32,
) void {
    for (children) |child| {
        if (isOutOfFlow(child)) continue;
        const child_size = if (is_row) child.rectFromWorldOrFallback().w else child.rectFromWorldOrFallback().h;
        const new_pos = main_start + (main_end - ((if (is_row) child.rectFromWorldOrFallback().x else child.rectFromWorldOrFallback().y) - main_start + child_size));

        // position change must mark dirty: descendants' world coords accumulate from ancestor
        // chain,
        // parent moved but not marked dirty -> entire subtree carries stale coords to next frame
        // (hit test, clipping, compositing all misaligned). layout loop has same check, missed
        // here.
        const old_pos = if (is_row) child.rectFromWorldOrFallback().x else child.rectFromWorldOrFallback().y;
        if (old_pos != new_pos) {
            child.frame_state.state_bits.dirty.core.layout = true;
        }
        if (is_row) {
            child.setLayoutX(new_pos);
        } else {
            child.setLayoutY(new_pos);
        }
    }
}

/// compute child size on main axis (comptime branch avoids runtime comptime parameter call)
fn calcChildMainSize(child: *Node, comptime is_row: bool, available: Size) f32 {
    const main_sizing = if (is_row) child.style.width else child.style.height;
    return switch (main_sizing) {
        .px => |v| v,
        .grow => 0, // flex children in wrap use minimum size
        .fit => calcIntrinsicSize(child, is_row),
        .percent => |p| if (is_row) available.width * p / 100.0 else available.height * p / 100.0,
    };
}

/// compute child size on cross axis
fn calcChildCrossSize(child: *Node, comptime is_row: bool, available: Size) f32 {
    const cross_sizing = if (is_row) child.style.height else child.style.width;
    const margin_cross = if (is_row) child.style.marginVertical() else child.style.marginHorizontal();
    return switch (cross_sizing) {
        .px => |v| v,
        .grow => |mm| if (is_row)
            std.math.clamp(@max(@as(f32, 0), available.height - margin_cross), mm.min, mm.max)
        else
            std.math.clamp(@max(@as(f32, 0), available.width - margin_cross), mm.min, mm.max),
        .fit => calcIntrinsicSize(child, !is_row),
        .percent => |p| if (is_row) available.height * p / 100.0 else available.width * p / 100.0,
    };
}

/// compute child's basis size (for flex_shrink weighted calculation)
/// flex_basis > 0 returns flex_basis, else returns main axis actual size
fn childBasisSize(child: *Node, is_row: bool, available: Size) f32 {
    if (child.style.flex_basis() > 0) return child.style.flex_basis();
    const main_sizing = if (is_row) child.style.width else child.style.height;
    return switch (main_sizing) {
        .px => |v| v,
        .grow => 0,
        .fit => if (is_row) calcIntrinsicSize(child, true) else calcIntrinsicSize(child, false),
        .percent => |p| if (is_row) available.width * p / 100.0 else available.height * p / 100.0,
    };
}

/// flex wrap layout: children auto-wrap when overflowing
fn layoutChildrenWrap(parent: *Node, available: Size, ctx: LayoutContext) void {
    if (parent.style.direction.isRow()) {
        layoutChildrenWrapImpl(parent, available, true, ctx);
    } else {
        layoutChildrenWrapImpl(parent, available, false, ctx);
    }
}

fn layoutChildrenWrapImpl(parent: *Node, available: Size, comptime is_row: bool, ctx: LayoutContext) void {
    const style = parent.style;
    const gap = style.gap;
    const main_available = if (is_row) available.width else available.height;

    // Pass 1: distribute into rows, wrap when accumulated main axis exceeds available space,
    // use fixed-size row structure (expanded 64->256 to support large tag/badge wrap layouts)
    const max_lines = 256;
    var line_starts: [max_lines]usize = undefined;
    var line_ends: [max_lines]usize = undefined;
    var line_cross_sizes: [max_lines]f32 = undefined;
    var n_lines: usize = 0;

    const children = parent.children.items;
    if (children.len == 0) return;

    var line_start: usize = 0;
    var line_main: f32 = 0;
    var line_has_flow = false;

    for (children, 0..) |child, i| {
        if (isOutOfFlow(child)) continue;
        const child_main = calcChildMainSize(child, is_row, available);
        const child_main_outer = child_main + childMarginForAxis(child, is_row);
        const needed = if (line_has_flow) child_main_outer + gap else child_main_outer;

        if (line_has_flow and line_main + needed > main_available and n_lines < max_lines) {
            // end current row
            line_starts[n_lines] = line_start;
            line_ends[n_lines] = i;
            n_lines += 1;
            line_start = i;
            line_main = child_main;
            line_has_flow = true;
        } else {
            line_main += needed;
            line_has_flow = true;
        }
    }
    // last row
    if (n_lines < max_lines) {
        line_starts[n_lines] = line_start;
        line_ends[n_lines] = children.len;
        n_lines += 1;
    } else {
        // exceeds max_lines limit, merge remaining children into last row
        line_ends[max_lines - 1] = children.len;
        std.log.warn("[layoutChildrenWrap] exceeded max_lines={d}, merging remaining children into last line", .{max_lines});
    }

    // Pass 2: compute each row's cross-axis height (take max child size in row)
    for (0..n_lines) |line_idx| {
        var max_cross: f32 = 0;
        for (children[line_starts[line_idx]..line_ends[line_idx]]) |child| {
            if (isOutOfFlow(child)) continue;
            const cross = calcChildCrossSize(child, is_row, available) + childMarginForAxis(child, !is_row);
            max_cross = @max(max_cross, cross);
        }
        line_cross_sizes[line_idx] = max_cross;
    }

    // Pass 3: layout each row
    const pad_main_start: f32 = if (is_row) style.padding.left else style.padding.top;
    const pad_cross_start: f32 = if (is_row) style.padding.top else style.padding.left;
    var cross_cursor: f32 = pad_cross_start;

    for (0..n_lines) |line_idx| {
        var main_cursor: f32 = pad_main_start;
        const line_cross = line_cross_sizes[line_idx];

        for (children[line_starts[line_idx]..line_ends[line_idx]]) |child| {
            if (isOutOfFlow(child)) continue;
            const child_main = calcChildMainSize(child, is_row, available);
            const child_cross = calcChildCrossSize(child, is_row, available);
            const margin_main = childMarginForAxis(child, is_row);
            const margin_cross = childMarginForAxis(child, !is_row);
            const child_cross_outer = child_cross + margin_cross;

            // cross axis alignment
            const cross_offset: f32 = switch (style.align_items) {
                .center => (line_cross - child_cross_outer) / 2.0,
                .end => line_cross - child_cross_outer,
                else => 0,
            };

            const new_w = if (is_row)
                child_main
            else if (style.align_items == .stretch)
                @max(@as(f32, 0), line_cross - margin_cross)
            else
                child_cross;
            const new_h = if (is_row)
                (if (style.align_items == .stretch) @max(@as(f32, 0), line_cross - margin_cross) else child_cross)
            else
                child_main;
            if (child.rectFromWorldOrFallback().w != new_w or child.rectFromWorldOrFallback().h != new_h) {
                child.frame_state.state_bits.dirty.core.layout = true;
            }

            if (is_row) {
                child.setLayoutX(main_cursor + child.style.margin.left);
                child.setLayoutY(cross_cursor + cross_offset + child.style.margin.top);
                child.setLayoutW(new_w);
                child.setLayoutH(new_h);
            } else {
                child.setLayoutY(main_cursor + child.style.margin.top);
                child.setLayoutX(cross_cursor + cross_offset + child.style.margin.left);
                child.setLayoutH(new_h);
                child.setLayoutW(new_w);
            }

            layoutNode(child, Size.init(child.rectFromWorldOrFallback().w, child.rectFromWorldOrFallback().h), ctx);
            main_cursor += child_main + margin_main + gap;
        }

        cross_cursor += line_cross + gap;
    }

    // fit container backfill: wrap's actual cross-axis size = sum of all row heights
    if (n_lines > 0) {
        const pad_cross_end: f32 = if (is_row) style.padding.bottom else style.padding.right;
        // cross_cursor added extra gap, subtract it and add padding
        const total_cross = cross_cursor - gap + pad_cross_end;
        const cross_fit = if (is_row) style.height == .fit else style.width == .fit;
        if (cross_fit) {
            if (is_row) {
                const mm = effectiveMinMax(style.height, parent, false);
                parent.setLayoutH(std.math.clamp(total_cross, mm.min, mm.max));
            } else {
                const mm = effectiveMinMax(style.width, parent, true);
                parent.setLayoutW(std.math.clamp(total_cross, mm.min, mm.max));
            }
        }
    }

    // reverse: flip main axis direction (relative coords, no parent.rect.x/y needed)
    if (style.direction.isReverse()) {
        const main_start = if (is_row) style.padding.left else style.padding.top;
        const main_end = if (is_row) parent.rectFromWorldOrFallback().w - style.padding.right else parent.rectFromWorldOrFallback().h - style.padding.bottom;

        for (children) |child| {
            if (isOutOfFlow(child)) continue;
            if (is_row) {
                child.setLayoutX(main_start + (main_end - (child.rectFromWorldOrFallback().x - main_start + child.rectFromWorldOrFallback().w)));
            } else {
                child.setLayoutY(main_start + (main_end - (child.rectFromWorldOrFallback().y - main_start + child.rectFromWorldOrFallback().h)));
            }
        }
    }

    // wrap_reverse: flip row direction on cross axis (relative coords)
    if (style.flex_wrap() == .wrap_reverse) {
        const cross_start = if (is_row) style.padding.top else style.padding.left;
        const cross_end = if (is_row) parent.rectFromWorldOrFallback().h - style.padding.bottom else parent.rectFromWorldOrFallback().w - style.padding.right;

        for (children) |child| {
            if (isOutOfFlow(child)) continue;
            if (is_row) {
                child.setLayoutY(cross_start + (cross_end - (child.rectFromWorldOrFallback().y - cross_start + child.rectFromWorldOrFallback().h)));
            } else {
                child.setLayoutX(cross_start + (cross_end - (child.rectFromWorldOrFallback().x - cross_start + child.rectFromWorldOrFallback().w)));
            }
        }
    }
}

// fitResizeAfterLayout function deleted.
// Equivalent logic inlined in layoutChildren (search "fit_resize_block:").
// True backfill elimination requires layoutNode signature change to LayoutInput + Constraint
// downward passing,
// that's v0.4-P1 later layoutNode complete rewrite work (continuing in v0.5).

/// Absolute child layout (supports the CSS inset positioning model)
///
/// Positioning priority: inset > static-position-origin (margin only corrects, never positions)
/// - left + right both set -> width=grow stretches to fill the inset gap (CSS width:auto);
///   px/percent/fit still resolve themselves (fit = intrinsic size, empty box is 0), the rest
///   goes to margin
/// - top + bottom both set -> same, height=grow stretches
/// - only one set -> offset from that side, size from width/height
/// - all auto -> containing block origin as static position origin, stack margin
///
/// In incremental layout, an absolute child must re-resolve its size (instead of just recursing
/// into the subtree with its old rect) when: its own layout is dirty; or its width/height is fit
/// and the subtree has layout changes. A fit size depends on descendants; if children are laid out
/// using the old rect as available space, shrinkable descendants get squeezed back to the old size
/// and the container only shrinks, never grows (Popover dropdown: height does not recover after
/// more rows are added).
fn absoluteChildNeedsResolve(child: *const Node) bool {
    const bits = child.frame_state.state_bits.dirty.core;
    if (bits.layout) return true;
    if (!bits.subtree_layout) return false;
    return child.style.width == .fit or child.style.height == .fit;
}

/// compute/cache wrapped text line breaks after width is set (shared by flex and absolute layout
/// paths,
/// absolute-positioned text nodes previously skipped wrapping, wrap always rendered single-line).
/// returns wrapped total height (with vertical padding), for fit height use; null if inapplicable.
fn computeWrapTextLayoutForWidth(child: *Node, child_width: f32) ?f32 {
    const t = child.getText() orelse {
        child.clearTextLayout();
        return null;
    };
    if (t.wrap == .none) {
        child.clearTextLayout();
        return null;
    }
    const text_avail_w = child_width - child.style.padding.horizontal();
    if (text_avail_w <= 0) return null;
    const layout_spans = if (t.spans_affect_layout) t.spans else &.{};
    // cache hit check (layoutOutputPtr gives stable address, isCacheValid takes *const)
    if (child.layoutOutputPtr()) |c_lo| {
        const need_recompute = if (c_lo.artifacts.text_layout) |tl|
            !text_layout.isCacheValid(tl, t.content, text_avail_w, t.font_weight, t.font_size, t.use_italic_font, t.use_monospace_font, t.wrap, t.max_lines, layout_spans)
        else
            true;
        if (need_recompute) {
            const computed = text_layout.computeTextLayout(
                t.content,
                text_avail_w,
                t.wrap,
                t.max_lines,
                t.font_size,
                t.line_height,
                t.font_weight,
                t.use_italic_font,
                t.use_monospace_font,
                layout_spans,
            );
            child.storeTextLayout(&computed) catch {
                layout_alloc_failure_hits += 1;
                child.clearTextLayout();
                child.frame_state.state_bits.dirty.core.layout = true;
                return computed.total_height + child.style.padding.vertical();
            };
        }
    }
    if (child.layoutTextLayout()) |tl| {
        return tl.total_height + child.style.padding.vertical();
    }
    return null;
}

fn layoutAbsoluteChild(parent: *Node, child: *Node, ctx: LayoutContext) void {
    const inset = child.style.inset();
    const margin = child.style.marginSpec();

    // CSS absolute positioning uses the containing block established by the
    // parent's padding edge, not the content box used by in-flow Flex/Grid
    // children. Zenit paints borders inside the layout rect (border widths do
    // not consume layout space), so the parent's local rect is its effective
    // padding-box range and its origin is (0, 0).
    //
    // Do not reuse layoutChildren's `available`: that value has already had
    // parent padding removed. Mixing that content-box size with setLayoutX/Y's
    // parent-local coordinates shifts right/bottom anchored children by the
    // parent's total padding and resolves percentages against the wrong box.
    const parent_rect = parent.rectFromWorldOrFallback();
    const cb_w = @max(@as(f32, 0), parent_rect.w);
    const cb_h = @max(@as(f32, 0), parent_rect.h);

    // --- horizontal axis ---
    const left_val = inset.left.resolve(cb_w);
    const right_val = inset.right.resolve(cb_w);

    var child_width: f32 = undefined;
    var new_x: f32 = undefined;

    if (left_val != null and right_val != null) {
        const available_outer = @max(0, cb_w - left_val.? - right_val.?);
        child_width = switch (child.style.width) {
            .px => |v| v,
            .grow => |mm| std.math.clamp(available_outer - child.style.marginHorizontal(), mm.min, mm.max),
            .fit => calcIntrinsicSize(child, true),
            .percent => |p| cb_w * p / 100.0,
        };
        child_width = std.math.clamp(child_width, child.style.min_width(), child.style.max_width());
        if (child.style.width == .grow) {
            new_x = left_val.? + (if (child.style.marginLeftIsAuto()) 0 else margin.left);
        } else {
            const resolved = resolveAxisMargins(
                available_outer,
                child_width,
                margin.left,
                margin.right,
                child.style.marginLeftIsAuto(),
                child.style.marginRightIsAuto(),
            );
            new_x = left_val.? + resolved.start;
        }
    } else if (left_val) |lv| {
        // only left -> offset from left side
        child_width = switch (child.style.width) {
            .px => |v| v,
            .grow => |mm| std.math.clamp(cb_w - lv - margin.horizontal(), mm.min, mm.max),
            .fit => calcIntrinsicSize(child, true),
            .percent => |p| cb_w * p / 100.0,
        };
        new_x = lv + (if (child.style.marginLeftIsAuto()) 0 else margin.left);
    } else if (right_val) |rv| {
        // only right -> offset from right side
        child_width = switch (child.style.width) {
            .px => |v| v,
            .grow => |mm| std.math.clamp(cb_w - rv - margin.horizontal(), mm.min, mm.max),
            .fit => calcIntrinsicSize(child, true),
            .percent => |p| cb_w * p / 100.0,
        };
        new_x = cb_w - rv - (if (child.style.marginRightIsAuto()) 0 else margin.right) - child_width;
    } else {
        // no inset -> use containing block origin as static position origin, apply margin
        child_width = switch (child.style.width) {
            .px => |v| v,
            .grow => |mm| std.math.clamp(@max(0, cb_w - margin.horizontal()), mm.min, mm.max),
            .fit => calcIntrinsicSize(child, true),
            .percent => |p| cb_w * p / 100.0,
        };
        new_x = if (child.style.marginLeftIsAuto()) 0 else margin.left;
    }

    // --- vertical axis ---
    const top_val = inset.top.resolve(cb_h);
    const bottom_val = inset.bottom.resolve(cb_h);

    var child_height: f32 = undefined;
    var new_y: f32 = undefined;

    if (top_val != null and bottom_val != null) {
        const available_outer = @max(0, cb_h - top_val.? - bottom_val.?);
        child_height = switch (child.style.height) {
            .px => |v| v,
            .grow => |mm| std.math.clamp(available_outer - child.style.marginVertical(), mm.min, mm.max),
            .fit => calcIntrinsicSize(child, false),
            .percent => |p| cb_h * p / 100.0,
        };
        child_height = std.math.clamp(child_height, child.style.min_height(), child.style.max_height());
        if (child.style.height == .grow) {
            new_y = top_val.? + (if (child.style.marginTopIsAuto()) 0 else margin.top);
        } else {
            const resolved = resolveAxisMargins(
                available_outer,
                child_height,
                margin.top,
                margin.bottom,
                child.style.marginTopIsAuto(),
                child.style.marginBottomIsAuto(),
            );
            new_y = top_val.? + resolved.start;
        }
    } else if (top_val) |tv| {
        child_height = switch (child.style.height) {
            .px => |v| v,
            .grow => |mm| std.math.clamp(cb_h - tv - margin.vertical(), mm.min, mm.max),
            .fit => calcIntrinsicSize(child, false),
            .percent => |p| cb_h * p / 100.0,
        };
        new_y = tv + (if (child.style.marginTopIsAuto()) 0 else margin.top);
    } else if (bottom_val) |bv| {
        child_height = switch (child.style.height) {
            .px => |v| v,
            .grow => |mm| std.math.clamp(cb_h - bv - margin.vertical(), mm.min, mm.max),
            .fit => calcIntrinsicSize(child, false),
            .percent => |p| cb_h * p / 100.0,
        };
        new_y = cb_h - bv - (if (child.style.marginBottomIsAuto()) 0 else margin.bottom) - child_height;
    } else {
        // no inset -> use containing block origin as static position origin, apply margin
        child_height = switch (child.style.height) {
            .px => |v| v,
            .grow => |mm| std.math.clamp(@max(0, cb_h - margin.vertical()), mm.min, mm.max),
            .fit => calcIntrinsicSize(child, false),
            .percent => |p| cb_h * p / 100.0,
        };
        new_y = if (child.style.marginTopIsAuto()) 0 else margin.top;
    }

    // independent min/max constraint clamp
    child_width = std.math.clamp(child_width, child.style.min_width(), child.style.max_width());
    child_height = std.math.clamp(child_height, child.style.min_height(), child.style.max_height());

    // text wrapping: absolute text nodes also wrap after definite width (canvas overlay label
    // scenario)
    if (computeWrapTextLayoutForWidth(child, child_width)) |wrapped_h| {
        if (child.style.height == .fit) {
            child_height = std.math.clamp(wrapped_h, child.style.min_height(), child.style.max_height());
        }
    }

    if (child.rectFromWorldOrFallback().w != child_width or child.rectFromWorldOrFallback().h != child_height or
        child.rectFromWorldOrFallback().x != new_x or child.rectFromWorldOrFallback().y != new_y)
    {
        child.frame_state.state_bits.dirty.core.layout = true;
    }
    child.setLayoutX(new_x);
    child.setLayoutY(new_y);
    child.setLayoutW(child_width);
    child.setLayoutH(child_height);
    layoutNode(child, Size.init(child_width, child_height), ctx);

    // absolute + fit height correction: text_layout not generated during calcIntrinsicSize,
    // causing wrapped text fit height underestimated as single-line.
    // after layoutNode completes text shaping executes, re-read child's actual content height and
    // update child.rect.h.
    if (child.style.height == .fit and top_val == null and bottom_val == null and child.children.items.len > 0) {
        var actual_content: f32 = 0;
        const child_is_row = child.style.direction.isRow();
        for (child.children.items) |gc| {
            if (isOutOfFlow(gc)) continue;
            if (child_is_row) {
                actual_content = @max(actual_content, gc.rectFromWorldOrFallback().h + gc.style.marginVertical());
            } else {
                actual_content += gc.rectFromWorldOrFallback().h + gc.style.marginVertical();
            }
        }
        if (!child_is_row) {
            const abs_flow_n = blk: {
                var n: usize = 0;
                for (child.children.items) |gc| {
                    if (gc.style.position != .absolute) n += 1;
                }
                break :blk n;
            };
            if (abs_flow_n > 1) actual_content += @as(f32, @floatFromInt(abs_flow_n - 1)) * child.style.gap;
        }
        actual_content += child.style.padding.vertical();
        const mm = effectiveMinMax(child.style.height, child, false);
        const fit_h = std.math.clamp(actual_content, mm.min, mm.max);
        if (fit_h != child.rectFromWorldOrFallback().h) {
            child.setLayoutH(fit_h);
        }
    }

    // anchor right / anchor bottom only: above calculated x / y before layout using pre-layout size
    // (fit is pre-wrap single-line estimate); subtree layout's wrap backfill may change final size,
    // re-anchor by final size, else bottom-right positioned panel overflows containing block
    // (storybook GlassAdapt regular panel: bottom 20 but edge out 22 pt).
    if (left_val == null) if (right_val) |rv| {
        const x = cb_w - rv - (if (child.style.marginRightIsAuto()) 0 else margin.right) - child.rectFromWorldOrFallback().w;
        if (x != new_x) child.setLayoutX(x);
    };
    if (top_val == null) if (bottom_val) |bv| {
        const y = cb_h - bv - (if (child.style.marginBottomIsAuto()) 0 else margin.bottom) - child.rectFromWorldOrFallback().h;
        if (y != new_y) child.setLayoutY(y);
    };
}

fn layoutChildren(parent: *Node, available: Size, ctx: LayoutContext) void {
    const style = parent.style;
    const is_row = style.direction.isRow();

    // wrap mode: row-by-row (line-broken) layout
    if (style.flex_wrap() != .no_wrap) {
        layoutChildrenWrap(parent, available, ctx);
        return;
    }

    // pass 1: compute fixed sizes, flex total, and flow child count
    var used_space: f32 = 0;
    var flex_total: f32 = 0;
    var flow_count: usize = 0;
    var main_auto_margin_count: usize = 0;

    for (parent.children.items) |child| {
        // absolute children don't participate in flow layout
        if (isOutOfFlow(child)) continue;
        flow_count += 1;

        const margin_main = if (is_row) child.style.marginHorizontal() else child.style.marginVertical();
        if (is_row) {
            if (child.style.marginLeftIsAuto()) main_auto_margin_count += 1;
            if (child.style.marginRightIsAuto()) main_auto_margin_count += 1;
        } else {
            if (child.style.marginTopIsAuto()) main_auto_margin_count += 1;
            if (child.style.marginBottomIsAuto()) main_auto_margin_count += 1;
        }
        const main_sizing = if (is_row) child.style.width else child.style.height;

        // when flex_basis > 0, use flex_basis replacing width/height as main axis size contribution
        if (child.style.flex_basis() > 0 and main_sizing != .grow) {
            used_space += child.style.flex_basis() + margin_main;
        } else switch (main_sizing) {
            .px => |v| used_space += v + margin_main,
            .grow => {
                flex_total += child.style.flex;
                // grow children's self-size doesn't take used_space (allocated from remaining),
                // but their main-axis margin is real fixed cost, must count with .px/.fit/.percent,
                // else remaining overestimated, flex children with margin overflow parent.
                // auto margin already counted as 0 in marginHorizontal/Vertical, won't duplicate
                // with main_auto_margin_count allocation.
                used_space += margin_main;
            },
            .fit => {
                // fit's intrinsic only affects layout when flex siblings exist (for computing
                // remaining).
                // defer until confirming flex_total > 0 to avoid redundant intrinsic calculation on
                // many fit children.
                used_space += margin_main;
            },
            .percent => |p| {
                const main_avail = if (is_row) available.width else available.height;
                used_space += main_avail * p / 100.0 + margin_main;
            },
        }
    }

    // Gap: space_* modes do not use style.gap; spacing is computed from justify.
    // Only exclude the case where the main axis is .fit (a fit container's size comes from its
    // content,
    // so there is no free space to distribute).
    // Parents with .grow / .px / .percent have a definite main-axis size, so space_* should apply.
    const main_is_fit = if (is_row) style.width == .fit else style.height == .fit;
    const is_space_mode = !main_is_fit and
        flex_total == 0 and
        (style.justify == .space_between or
            style.justify == .space_around or
            style.justify == .space_evenly);

    // Fit children's intrinsic size is backfilled only when a precise used_space is needed:
    // - flex_total > 0: need remaining for flex space
    // - is_space_mode: need remaining for justify spacing
    // - justify == .center/.end: need precise remaining for offset
    // The common case "all children fit/px, no flex no justify" skips calcIntrinsicSize entirely,
    // avoiding redundant recursion on 3000+ children.
    // - has_shrinkable_fit: flex_shrink also needs a precise used_space. If "shrinkable fit
    //   children" exist and backfill is skipped, the overflow sum counts only px children, shrink
    //   never triggers, and in a fit + max boxed container (popover chrome with autosize-limited
    //   height) ScrollArea lays out by content height: footer pushed out, list cannot scroll.
    //   "Shrinkable" follows the CSS flex item auto minimum size: overflow != visible items have
    //   min 0; normal fit items' min is their content, so they skip backfill, else ScrollArea ->
    //   content (normal fit) would also count as overflow and content = viewport can no longer
    //   scroll. Shrink amount allocation is unchanged.
    //   Only enabled when the parent's main axis is itself fit (fit only overflows from a max
    //   ceiling): px / grow containers, esp. the "px 0 + overflow_hidden" hiding pattern (Modal
    //   closed barrier, showNode), rely on children keeping content size while hidden; squeezing
    //   to 0 leaves a reopened Modal panel at 0 height (native gate panel_infra).
    var has_shrinkable_fit = false;
    if (main_is_fit) for (parent.children.items) |child| {
        if (isOutOfFlow(child)) continue;
        if (isShrinkableFit(child, is_row)) {
            has_shrinkable_fit = true;
            break;
        }
    };
    const needs_precise_remaining = flex_total > 0 or is_space_mode or
        style.justify == .center or style.justify == .end or has_shrinkable_fit;
    if (needs_precise_remaining) {
        for (parent.children.items) |child| {
            if (isOutOfFlow(child)) continue;
            const main_sizing = if (is_row) child.style.width else child.style.height;
            if (main_sizing == .fit) {
                const intrinsic = if (is_row)
                    calcChildIntrinsicSize(child, true)
                else
                    calcChildIntrinsicSize(child, false);
                used_space += intrinsic;
            }
        }
    }

    const n_children: f32 = @floatFromInt(flow_count);
    const gap_count: f32 = if (flow_count > 1)
        @as(f32, @floatFromInt(flow_count - 1))
    else
        0;

    if (!is_space_mode) {
        used_space += gap_count * style.gap;
    }

    // remaining space
    const main_available = if (is_row) available.width else available.height;

    // flex_shrink: when overflowing with no flex-grow children, distribute shrink amount by CSS
    // weighted algorithm
    // fast path: flow_count <= 512 use stack array; else allocate from frame_allocator
    var shrink_stack: [512]f32 = @as([512]f32, @splat(0));
    const shrink_deltas: []f32 = if (flow_count <= 512)
        shrink_stack[0..flow_count]
    else blk: {
        const buf = ctx.frame_allocator.alloc(f32, flow_count) catch {
            // degrade: shrink_deltas empty => skip flex_shrink entirely, no shrink on overflow.
            layout_alloc_failure_hits +|= 1;
            std.log.warn("[layoutChildren] shrink_deltas alloc failed (flow_count={d}), flex_shrink disabled for this node", .{flow_count});
            break :blk &[_]f32{};
        };
        @memset(buf, 0);
        break :blk buf;
    };
    const overflow = used_space - main_available;
    if (overflow > 0 and flex_total == 0 and shrink_deltas.len > 0) {
        // compute weighted sum: sum(basis_i * shrink_i)
        var weighted_total: f32 = 0;
        var idx: usize = 0;
        for (parent.children.items) |child| {
            if (isOutOfFlow(child)) continue;
            if (idx >= shrink_deltas.len) break;
            const basis = childBasisSize(child, is_row, available);
            weighted_total += basis * child.style.flex_shrink;
            idx += 1;
        }

        if (weighted_total > 0) {
            idx = 0;
            for (parent.children.items) |child| {
                if (isOutOfFlow(child)) continue;
                if (idx >= shrink_deltas.len) break;
                const basis = childBasisSize(child, is_row, available);
                shrink_deltas[idx] = (basis * child.style.flex_shrink / weighted_total) * overflow;
                idx += 1;
            }
            // adjust used_space (after shrink no longer overflows)
            used_space -= overflow;
        }
    }

    // The main-fit container's final main-axis size is set by the backfill below
    // (= clamp(content + padding)) and may differ from main_available (when an ancestor's
    // cross-axis stretch made it wider). justify / auto-margin remaining space uses the predicted
    // backfill size so the first pass places children in their final state, avoiding a
    // "place by stretch width -> reposition after backfill" flip-flop that marks children dirty.
    // The prediction depends only on the intrinsic estimate; deviations caused by text wrapping etc. are
    // corrected by repositionMainAxis after backfill.
    const justify_main_available = if (main_is_fit and flex_total == 0 and needs_precise_remaining) blk: {
        const pad_main = if (is_row) style.padding.horizontal() else style.padding.vertical();
        const mm = if (is_row)
            effectiveMinMax(style.width, parent, true)
        else
            effectiveMinMax(style.height, parent, false);
        break :blk std.math.clamp(used_space + pad_main, mm.min, mm.max) - pad_main;
    } else main_available;
    const remaining = @max(0, justify_main_available - used_space);
    const flex_unit = if (flex_total > 0) remaining / flex_total else 0;
    const auto_margin_unit = if (main_auto_margin_count > 0 and flex_total == 0)
        remaining / @as(f32, @floatFromInt(main_auto_margin_count))
    else
        0;

    // justify: compute spacing and start offset
    const pad_start: f32 = if (is_row) style.padding.left else style.padding.top;

    var justify_offset: f32 = 0;
    var justify_gap: f32 = style.gap;

    if (flex_total > 0 or main_auto_margin_count > 0) {
        // when flex children exist, justify doesn't apply
    } else if (is_space_mode) {
        switch (style.justify) {
            .space_between => {
                justify_gap = if (gap_count > 0) remaining / gap_count else 0;
            },
            .space_around => {
                const item_gap = if (n_children > 0) remaining / n_children else 0;
                justify_gap = item_gap;
                justify_offset = item_gap / 2.0;
            },
            .space_evenly => {
                const item_gap = if (n_children > 0) remaining / (n_children + 1) else 0;
                justify_gap = item_gap;
                justify_offset = item_gap;
            },
            else => unreachable,
        }
    } else {
        justify_offset = switch (style.justify) {
            .start => 0,
            .end => remaining,
            .center => remaining / 2.0,
            .space_between, .space_around, .space_evenly => 0,
        };
    }

    var cursor: f32 = pad_start + justify_offset;
    var shrink_idx: usize = 0;

    for (parent.children.items) |child| {
        if (isDisplayNone(child)) {
            collapseDisplayNone(child);
            continue;
        }
        // absolute children handled separately
        if (child.style.position == .absolute) {
            layoutAbsoluteChild(parent, child, ctx);
            continue;
        }

        const margin = child.style.marginSpec();
        const resolved_main_margins = if (is_row)
            ResolvedAxisMargins{
                .start = if (child.style.marginLeftIsAuto()) auto_margin_unit else margin.left,
                .end = if (child.style.marginRightIsAuto()) auto_margin_unit else margin.right,
            }
        else
            ResolvedAxisMargins{
                .start = if (child.style.marginTopIsAuto()) auto_margin_unit else margin.top,
                .end = if (child.style.marginBottomIsAuto()) auto_margin_unit else margin.bottom,
            };
        var child_width: f32 = undefined;
        var child_height: f32 = undefined;

        // determine cross-axis alignment (align_self priority over align_items; no_cross_stretch
        // only downgrades inherited stretch)
        const cross_align = resolveCrossAlign(child, style.align_items);

        // get current child's shrink delta
        const cur_shrink_delta = if (shrink_idx < shrink_deltas.len) shrink_deltas[shrink_idx] else 0;
        shrink_idx += 1;

        // main axis / cross axis each computed once. previously this was a block of
        // character-for-character mirrored
        // if (is_row) / else with identical logic on both sides, width<->height swapped, changing
        // one side
        // forgetting the other caused bug only in column layout. extract helper functions taking
        // params by axis,
        // rule exists in one place only.
        if (is_row) {
            child_width = resolveMainAxisSize(child, true, available, cur_shrink_delta, flex_unit);
            child_height = resolveCrossAxisSize(child, true, available, cross_align);
        } else {
            child_height = resolveMainAxisSize(child, false, available, cur_shrink_delta, flex_unit);
            child_width = resolveCrossAxisSize(child, false, available, cross_align);
        }

        // Independent min/max constraint clamp (CSS min-width/max-width/min-height/max-height).
        // fit also includes sizing's own fit{.min,.max} (effectiveMinMax is the uniform basis):
        // looking
        // only at ext fails because fit{.max=N} takes effect only after children backfill; children
        // are
        // placed at unboxed size, overflow cannot be computed, flex_shrink never triggers and px
        // siblings get pushed out.
        // grow's mm has different semantics, unchanged.
        // (effectiveMinMax for px/percent is just ext; grow uses a px placeholder and reverts to
        // ext)
        const mm_w = effectiveMinMax(if (child.style.width == .grow) Sizing{ .px = 0 } else child.style.width, child, true);
        const mm_h = effectiveMinMax(if (child.style.height == .grow) Sizing{ .px = 0 } else child.style.height, child, false);
        child_width = std.math.clamp(child_width, mm_w.min, mm_w.max);
        child_height = std.math.clamp(child_height, mm_h.min, mm_h.max);

        // aspect_ratio constraint: infer height from definite width (e.g. image node)
        if (child.style.aspect_ratio() > 0 and child_width > 0) {
            const ar = child.style.aspect_ratio();
            // only applies when height not fixed px (px height priority)
            if (child.style.height != .px) {
                child_height = child_width / ar;
            }
        }

        // text wrapping: compute line breaks after width fixed
        if (computeWrapTextLayoutForWidth(child, child_width)) |wrapped_h| {
            // fit height: use post-wrap total height
            if (child.style.height == .fit) child_height = wrapped_h;
        }

        // position (record old value first, for later marking dirty if changed)
        const old_child_x = child.rectFromWorldOrFallback().x;
        const old_child_y = child.rectFromWorldOrFallback().y;
        if (is_row) {
            const resolved_cross = resolveAxisMargins(
                available.height,
                child_height,
                margin.top,
                margin.bottom,
                child.style.marginTopIsAuto(),
                child.style.marginBottomIsAuto(),
            );
            child.setLayoutX(cursor + resolved_main_margins.start);
            child.setLayoutY(style.padding.top + resolved_cross.start + switch (cross_align) {
                .center => if (child.style.marginTopIsAuto() or child.style.marginBottomIsAuto()) 0 else (available.height - child.style.marginVertical() - child_height) / 2.0,
                .end => if (child.style.marginTopIsAuto() or child.style.marginBottomIsAuto()) 0 else available.height - child.style.marginVertical() - child_height,
                else => 0,
            });
            cursor += child_width + resolved_main_margins.start + resolved_main_margins.end + justify_gap;
        } else {
            const resolved_cross = resolveAxisMargins(
                available.width,
                child_width,
                margin.left,
                margin.right,
                child.style.marginLeftIsAuto(),
                child.style.marginRightIsAuto(),
            );
            child.setLayoutX(style.padding.left + resolved_cross.start + switch (cross_align) {
                .center => if (child.style.marginLeftIsAuto() or child.style.marginRightIsAuto()) 0 else (available.width - child.style.marginHorizontal() - child_width) / 2.0,
                .end => if (child.style.marginLeftIsAuto() or child.style.marginRightIsAuto()) 0 else available.width - child.style.marginHorizontal() - child_width,
                else => 0,
            });
            child.setLayoutY(cursor + resolved_main_margins.start);
            cursor += child_height + resolved_main_margins.start + resolved_main_margins.end + justify_gap;
        }

        // mark dirty on size or position change, ensure children recurse relayout
        if (child.rectFromWorldOrFallback().w != child_width or child.rectFromWorldOrFallback().h != child_height or
            child.rectFromWorldOrFallback().x != old_child_x or child.rectFromWorldOrFallback().y != old_child_y)
        {
            child.frame_state.state_bits.dirty.core.layout = true;
        }
        child.setLayoutW(child_width);
        child.setLayoutH(child_height);

        // shrinkable fit item pushed by flex_shrink: main axis size locked here, tell backfill not
        // to stretch back
        var child_ctx = ctx;
        const main_frozen = cur_shrink_delta > 0 and isShrinkableFit(child, is_row);
        child_ctx.frozen_node = if (main_frozen) child else null;
        child_ctx.frozen_axis_is_width = is_row;
        layoutNode(child, Size.init(child_width, child_height), child_ctx);

        // text wrap backfill correction: layoutNode internally may backfill child size due to
        // wrapped text in subtree,
        // cursor needs compensate by actual size delta, else later sibling positions wrong.
        if (is_row) {
            const actual_w = child.rectFromWorldOrFallback().w;
            if (actual_w != child_width) {
                cursor += actual_w - child_width;
            }
        } else {
            const actual_h = child.rectFromWorldOrFallback().h;
            if (actual_h != child_height) {
                cursor += actual_h - child_height;
            }
        }
    }

    // Text wrap backfill: the parent's fit size must be updated from the child's actual size
    // (text wrap is computed inside child layoutNode; text_layout is still null during
    // calcIntrinsicSize).
    //
    // True "backfill elimination" needs layoutNode to take LayoutInput + Constraint passed down,
    // which is a full layoutNode rewrite; this inline version preserves the old
    // fitResizeAfterLayout behavior exactly.
    fit_resize_block: {
        const pstyle_fit = parent.style;
        // when grow-axis ancestor on same axis is fit, grow has no allocable remaining, final size
        // is content size:
        // backfill by child actual size too—but only grow, never shrink (see w_grow_only below).
        // else fit > grow > ... > wrapped-text chain: wrap deepens inner layer, grow stops at
        // pre-wrap single-line height,
        // fit ancestor sums it—whole chain undersized (GlassBox root fit -> surface grow -> content
        // fit case,
        // wrapped body overflows glass lower edge). ancestor has fixed size don't touch: grow
        // should allocate by assigned space
        // (scroll areas depend on this).
        const gp_w_fit = if (parent.parent) |gp| gp.style.width == .fit else false;
        const gp_h_fit = if (parent.parent) |gp| gp.style.height == .fit else false;
        const w_fit = pstyle_fit.width == .fit or (pstyle_fit.width == .grow and gp_w_fit);
        const h_fit = pstyle_fit.height == .fit or (pstyle_fit.height == .grow and gp_h_fit);
        const main_fit = if (is_row) w_fit else h_fit;
        const cross_fit = if (is_row) h_fit else w_fit;
        // grow axis grow-only: cross-axis stretched grow node (panel in fit row / divider) backfill
        // by self content shrinks first,
        // this function's final alignment pass places children by shrunken size (center offset
        // becomes 0);
        // fit ancestor re-stretches it but won't re-layout children -> content aligned edge
        // (storybook GlassBox Materials
        // one row left-shifted 24 pt, tested).
        const w_grow_only = pstyle_fit.width == .grow;
        const h_grow_only = pstyle_fit.height == .grow;
        const cur_w = parent.rectFromWorldOrFallback().w;
        const cur_h = parent.rectFromWorldOrFallback().h;
        if (!main_fit and !cross_fit) break :fit_resize_block;
        // parent flex_shrink locked this axis not backfill (see LayoutContext.frozen_node)
        const frozen_here = ctx.frozen_node == parent;
        const skip_w = frozen_here and ctx.frozen_axis_is_width;
        const skip_h = frozen_here and !ctx.frozen_axis_is_width;

        var actual_main: f32 = 0;
        var actual_cross: f32 = 0;
        var flow_n: usize = 0;
        for (parent.children.items) |child| {
            if (isOutOfFlow(child)) continue;
            const child_main = if (is_row) child.rectFromWorldOrFallback().w + child.style.marginHorizontal() else child.rectFromWorldOrFallback().h + child.style.marginVertical();
            const child_cross = if (is_row) child.rectFromWorldOrFallback().h + child.style.marginVertical() else child.rectFromWorldOrFallback().w + child.style.marginHorizontal();
            actual_main += child_main;
            actual_cross = @max(actual_cross, child_cross);
            flow_n += 1;
        }
        if (flow_n > 1) actual_main += @as(f32, @floatFromInt(flow_n - 1)) * pstyle_fit.gap;

        if (main_fit) {
            const new_main = actual_main + (if (is_row) pstyle_fit.padding.horizontal() else pstyle_fit.padding.vertical());
            if (is_row) {
                const mm = effectiveMinMax(pstyle_fit.width, parent, true);
                const v = std.math.clamp(new_main, mm.min, mm.max);
                if (!skip_w) parent.setLayoutW(if (w_grow_only) @max(cur_w, v) else v);
            } else {
                const mm = effectiveMinMax(pstyle_fit.height, parent, false);
                const v = std.math.clamp(new_main, mm.min, mm.max);
                if (!skip_h) parent.setLayoutH(if (h_grow_only) @max(cur_h, v) else v);
            }
        }
        if (cross_fit) {
            const new_cross = actual_cross + (if (is_row) pstyle_fit.padding.vertical() else pstyle_fit.padding.horizontal());
            if (is_row) {
                const mm = effectiveMinMax(pstyle_fit.height, parent, false);
                const v = std.math.clamp(new_cross, mm.min, mm.max);
                if (!skip_h) parent.setLayoutH(if (h_grow_only) @max(cur_h, v) else v);
            } else {
                const mm = effectiveMinMax(pstyle_fit.width, parent, true);
                const v = std.math.clamp(new_cross, mm.min, mm.max);
                if (!skip_w) parent.setLayoutW(if (w_grow_only) @max(cur_w, v) else v);
            }

            // backfill correction: after parent cross size growth, grow children cross axis need
            // re-stretch to new space
            const new_cross_avail = if (is_row)
                parent.rectFromWorldOrFallback().h - pstyle_fit.padding.vertical()
            else
                parent.rectFromWorldOrFallback().w - pstyle_fit.padding.horizontal();
            for (parent.children.items) |child| {
                if (isOutOfFlow(child)) continue;
                const cross_sizing = if (is_row) child.style.height else child.style.width;
                if (cross_sizing == .grow) {
                    const margin_cross = if (is_row) child.style.marginVertical() else child.style.marginHorizontal();
                    const resolved = std.math.clamp(new_cross_avail - margin_cross, cross_sizing.grow.min, cross_sizing.grow.max);
                    if (is_row) {
                        child.setLayoutH(resolved);
                    } else {
                        child.setLayoutW(resolved);
                    }
                }
            }
        }
    }

    // main axis final positioning: when fit backfill changed parent main size (typical: fit-width
    // row ancestor-stretched
    // by column then justify offset calculated by stretch width, backfill shrinks to intrinsic
    // width),
    // justify/auto-margin offset from old main_available now invalid, content drifts out frame.
    // rerun main-axis positioning by final size + child actual size. child coords are
    // parent-relative,
    // translate doesn't affect subtree layout, no recursive relayout needed (O(children)).
    // when flex_total > 0 justify/auto-margin ineffective, position from pad_start in order,
    // independent of main size, no relayout. only main-fit backfill changes main size.
    if (main_is_fit and flex_total == 0) {
        const final_main_available = if (is_row)
            parent.rectFromWorldOrFallback().w - style.padding.horizontal()
        else
            parent.rectFromWorldOrFallback().h - style.padding.vertical();
        if (final_main_available != main_available) {
            repositionMainAxis(parent, is_row, final_main_available, main_auto_margin_count);
        }
    }

    // Wrapping can change a child's cross size during recursion, and fit
    // backfill can then change its parent's size. Align using those final
    // dimensions; the preliminary alignment above used intrinsic estimates.
    const final_cross_available = if (is_row)
        parent.rectFromWorldOrFallback().h - style.padding.vertical()
    else
        parent.rectFromWorldOrFallback().w - style.padding.horizontal();
    for (parent.children.items) |child| {
        if (isOutOfFlow(child)) continue;
        const cross_align = resolveCrossAlign(child, style.align_items);
        const child_cross = if (is_row) child.rectFromWorldOrFallback().h else child.rectFromWorldOrFallback().w;
        const margin = child.style.marginSpec();
        const start_auto = if (is_row) child.style.marginTopIsAuto() else child.style.marginLeftIsAuto();
        const end_auto = if (is_row) child.style.marginBottomIsAuto() else child.style.marginRightIsAuto();
        const start_margin = if (is_row) margin.top else margin.left;
        const end_margin = if (is_row) margin.bottom else margin.right;
        const resolved = resolveAxisMargins(final_cross_available, child_cross, start_margin, end_margin, start_auto, end_auto);
        const extra = final_cross_available - start_margin - end_margin - child_cross;
        const offset = if (start_auto or end_auto) 0 else switch (cross_align) {
            .center => extra / 2.0,
            .end => extra,
            else => 0,
        };
        // same as batchReverseChildren: position change must mark dirty. this pass re-aligns by
        // final size,
        // usually matches pre-layout align (most cases won't trigger), but wrap / fit backfill
        // changing
        // cross size really moves children.
        const new_cross = if (is_row)
            style.padding.top + resolved.start + offset
        else
            style.padding.left + resolved.start + offset;
        const old_cross = if (is_row) child.rectFromWorldOrFallback().y else child.rectFromWorldOrFallback().x;
        if (old_cross != new_cross) {
            child.frame_state.state_bits.dirty.core.layout = true;
        }
        if (is_row) {
            child.setLayoutY(new_cross);
        } else {
            child.setLayoutX(new_cross);
        }
    }

    // reverse: mirror-flip child position on main axis (relative coords)
    if (style.direction.isReverse()) {
        const main_start = if (is_row) style.padding.left else style.padding.top;
        const main_end = if (is_row) parent.rectFromWorldOrFallback().w - style.padding.right else parent.rectFromWorldOrFallback().h - style.padding.bottom;

        if (is_row) {
            batchReverseChildren(parent.children.items, true, main_start, main_end);
        } else {
            batchReverseChildren(parent.children.items, false, main_start, main_end);
        }
    }
}

/// main axis final positioning after fit backfill (see layoutChildren call site). only call when
/// parent main axis fit,
/// no grow children, so space_* ineffective (is_space_mode requires main axis non-fit),
/// handle as start like first pass. use child actual sizes (includes wrap backfill).
fn repositionMainAxis(parent: *Node, is_row: bool, final_main_available: f32, main_auto_margin_count: usize) void {
    const style = parent.style;
    var used: f32 = 0;
    var flow_n: usize = 0;
    for (parent.children.items) |child| {
        if (isOutOfFlow(child)) continue;
        const r = child.rectFromWorldOrFallback();
        const m = child.style.marginSpec();
        used += if (is_row) r.w else r.h;
        if (is_row) {
            if (!child.style.marginLeftIsAuto()) used += m.left;
            if (!child.style.marginRightIsAuto()) used += m.right;
        } else {
            if (!child.style.marginTopIsAuto()) used += m.top;
            if (!child.style.marginBottomIsAuto()) used += m.bottom;
        }
        flow_n += 1;
    }
    if (flow_n > 1) used += @as(f32, @floatFromInt(flow_n - 1)) * style.gap;

    const remaining = @max(0, final_main_available - used);
    const auto_margin_unit = if (main_auto_margin_count > 0)
        remaining / @as(f32, @floatFromInt(main_auto_margin_count))
    else
        0;
    const justify_offset: f32 = if (main_auto_margin_count > 0) 0 else switch (style.justify) {
        .end => remaining,
        .center => remaining / 2.0,
        .start, .space_between, .space_around, .space_evenly => 0,
    };

    var cursor: f32 = (if (is_row) style.padding.left else style.padding.top) + justify_offset;
    for (parent.children.items) |child| {
        if (isOutOfFlow(child)) continue;
        const r = child.rectFromWorldOrFallback();
        const m = child.style.marginSpec();
        const start_m = if (is_row)
            (if (child.style.marginLeftIsAuto()) auto_margin_unit else m.left)
        else
            (if (child.style.marginTopIsAuto()) auto_margin_unit else m.top);
        const end_m = if (is_row)
            (if (child.style.marginRightIsAuto()) auto_margin_unit else m.right)
        else
            (if (child.style.marginBottomIsAuto()) auto_margin_unit else m.bottom);
        if (is_row) {
            child.setLayoutX(cursor + start_m);
            cursor += r.w + start_m + end_m + style.gap;
        } else {
            child.setLayoutY(cursor + start_m);
            cursor += r.h + start_m + end_m + style.gap;
        }
    }
}

// ========== Grid Layout ==========

const GridConfig = types.GridConfig;

/// stack placement record
const Placement = struct {
    col: u8, // 0-based column index
    row: u8, // 0-based row index
    col_span: u8,
    row_span: u8,
};

/// grid layout algorithm
fn layoutChildrenGrid(parent: *Node, available: Size, ctx: LayoutContext) void {
    const gc = parent.style.grid() orelse return;
    const children = parent.children.items;
    if (children.len == 0) return;

    // GridConfig is public and can be constructed without the `grid()` builder,
    // so its independent count fields are untrusted. Both backing arrays have
    // exactly MAX_TRACKS entries.
    const col_count = @min(@as(usize, gc.column_count), GridConfig.MAX_TRACKS);
    const explicit_row_count = @min(@as(usize, gc.row_count), GridConfig.MAX_TRACKS);
    const max_rows: usize = 64;

    if (col_count == 0) return;

    // phase A: auto-placement (row-major)
    // occupation bitmap: [max_rows][MAX_TRACKS] bool
    var occupied: [max_rows][GridConfig.MAX_TRACKS]bool = @splat(@splat(false));
    // fast path: children <= 512 use stack array; else allocate from frame_allocator
    var placements_stack: [512]Placement = undefined;
    const child_count = children.len;
    const placements: []Placement = if (child_count <= 512)
        placements_stack[0..child_count]
    else blk: {
        break :blk ctx.frame_allocator.alloc(Placement, child_count) catch {
            // degrade: the whole grid is not laid out (children keep the previous frame's geometry).
            layout_alloc_failure_hits +|= 1;
            std.log.warn("[grid] placements alloc failed (child_count={d}), grid layout skipped", .{child_count});
            return;
        };
    };
    var actual_row_count: usize = explicit_row_count;

    // pass 1: place explicitly-positioned children
    for (children, 0..) |child, i| {
        if (i >= placements.len) break;
        // absolute / display:none children don't participate in grid layout (consistent with
        // flexbox)
        if (isOutOfFlow(child)) {
            placements[i] = .{ .col = 0, .row = 0, .col_span = 0, .row_span = 0 }; // mark skipped
            continue;
        }
        if (child.style.grid_placement()) |gp| {
            if (gp.col_start > 0 and gp.row_start > 0) {
                const col_index = @as(usize, gp.col_start - 1);
                const row_index = @as(usize, gp.row_start - 1);
                // This engine supports implicit rows but not implicit columns;
                // explicit starts outside either bounded backing table cannot
                // be represented safely. Treat the placement as skipped.
                if (col_index >= col_count or row_index >= max_rows or gp.col_span == 0 or gp.row_span == 0) {
                    placements[i] = .{ .col = 0, .row = 0, .col_span = 0, .row_span = 0 };
                    continue;
                }
                const col: u8 = @intCast(col_index);
                const row: u8 = @intCast(row_index);
                placements[i] = .{
                    .col = col,
                    .row = row,
                    .col_span = gp.col_span,
                    .row_span = gp.row_span,
                };
                markOccupied(&occupied, col, row, gp.col_span, gp.row_span, col_count, max_rows);
                actual_row_count = @max(actual_row_count, @as(usize, row) + gp.row_span);
            } else {
                // partially explicit, auto-place later
                placements[i] = .{ .col = 0, .row = 0, .col_span = gp.col_span, .row_span = gp.row_span };
            }
        } else {
            placements[i] = .{ .col = 0, .row = 0, .col_span = 1, .row_span = 1 };
        }
    }

    // pass 2: row-major auto-placement (use usize to avoid u8 overflow)
    var auto_row: usize = 0;
    var auto_col: usize = 0;
    for (children, 0..) |child, i| {
        if (i >= placements.len) break;
        // skip absolute children
        if (isOutOfFlow(child)) continue;
        const gp = child.style.grid_placement();
        // skip already explicitly positioned
        if (gp != null and gp.?.col_start > 0 and gp.?.row_start > 0) continue;

        const cspan: usize = @intCast(placements[i].col_span);
        const rspan: usize = @intCast(placements[i].row_span);

        // span exceeds column count can't place, mark skipped (col_span=0 same as absolute)
        if (cspan > col_count or rspan > max_rows) {
            placements[i] = .{ .col = 0, .row = 0, .col_span = 0, .row_span = 0 };
            continue;
        }

        // find first placeable position
        while (auto_row + rspan <= max_rows) {
            if (auto_col + cspan <= col_count and !isOccupiedRegion(&occupied, @intCast(auto_col), @intCast(auto_row), @intCast(cspan), @intCast(rspan), col_count, max_rows)) {
                break;
            }
            auto_col += 1;
            if (auto_col + cspan > col_count) {
                auto_col = 0;
                auto_row += 1;
            }
        }

        placements[i].col = @intCast(auto_col);
        placements[i].row = @intCast(auto_row);
        markOccupied(&occupied, @intCast(auto_col), @intCast(auto_row), @intCast(cspan), @intCast(rspan), col_count, max_rows);
        actual_row_count = @max(actual_row_count, auto_row + rspan);

        // advance to next position
        auto_col += cspan;
        if (auto_col >= col_count) {
            auto_col = 0;
            auto_row += 1;
        }
    }

    // Phase B: Track sizing
    var col_sizes: [GridConfig.MAX_TRACKS]f32 = @as([GridConfig.MAX_TRACKS]f32, @splat(0));
    var row_sizes: [64]f32 = @as([64]f32, @splat(0));

    // B1: fixed px and auto
    // note: auto track sizing only considers span=1 children.
    // multi-span children contribution to auto track needs CSS Grid Level 1
    // "remaining space allocation" algorithm (complex), not yet implemented.
    var fixed_col_total: f32 = 0;
    var fr_col_total: f32 = 0;
    for (0..col_count) |ci| {
        switch (gc.columns[ci]) {
            .px => |v| {
                col_sizes[ci] = v;
                fixed_col_total += v;
            },
            .auto => {
                // take max intrinsic of all span=1 children in this column
                var max_w: f32 = 0;
                for (children, 0..) |child, idx| {
                    if (idx >= placements.len) break;
                    if (placements[idx].col == ci and placements[idx].col_span == 1) {
                        max_w = @max(max_w, calcIntrinsicSize(child, true) + child.style.marginHorizontal());
                    }
                }
                col_sizes[ci] = max_w;
                fixed_col_total += max_w;
            },
            .fr => |f| fr_col_total += f,
        }
    }

    growMultiSpanAutoColumns(children, placements[0..@min(children.len, placements.len)], gc, col_count, &col_sizes);
    fixed_col_total = 0;
    for (0..col_count) |ci| {
        if (gc.columns[ci] != .fr) {
            fixed_col_total += col_sizes[ci];
        }
    }

    // fr columns: allocate remaining space
    if (fr_col_total > 0) {
        const col_gap_total = if (col_count > 1) @as(f32, @floatFromInt(col_count - 1)) * gc.column_gap else 0;
        const remaining_w = @max(0, available.width - fixed_col_total - col_gap_total);
        for (0..col_count) |ci| {
            if (gc.columns[ci] == .fr) {
                col_sizes[ci] = remaining_w * gc.columns[ci].fr / fr_col_total;
            }
        }
    }

    // B2: Row sizing
    const row_count_capped = @min(actual_row_count, max_rows);
    var fixed_row_total: f32 = 0;
    var fr_row_total: f32 = 0;
    for (0..row_count_capped) |ri| {
        if (ri < explicit_row_count) {
            switch (gc.rows[ri]) {
                .px => |v| {
                    row_sizes[ri] = v;
                    fixed_row_total += v;
                },
                .auto => {
                    var max_h: f32 = 0;
                    for (children, 0..) |child, idx| {
                        if (idx >= placements.len) break;
                        if (placements[idx].row == ri and placements[idx].row_span == 1) {
                            max_h = @max(max_h, calcIntrinsicSize(child, false) + child.style.marginVertical());
                        }
                    }
                    row_sizes[ri] = max_h;
                    fixed_row_total += max_h;
                },
                .fr => |f| fr_row_total += f,
            }
        } else {
            // implicit rows: auto sizing
            var max_h: f32 = 0;
            for (children, 0..) |child, idx| {
                if (idx >= 512) break;
                if (placements[idx].row == ri and placements[idx].row_span == 1) {
                    max_h = @max(max_h, calcIntrinsicSize(child, false) + child.style.marginVertical());
                }
            }
            row_sizes[ri] = max_h;
            fixed_row_total += max_h;
        }
    }

    growMultiSpanAutoRows(children, placements[0..@min(children.len, placements.len)], gc, row_count_capped, &row_sizes);
    fixed_row_total = 0;
    for (0..row_count_capped) |ri| {
        if (ri >= explicit_row_count or gc.rows[ri] != .fr) {
            fixed_row_total += row_sizes[ri];
        }
    }

    // fr rows: allocate remaining space
    if (fr_row_total > 0) {
        const row_gap_total = if (row_count_capped > 1) @as(f32, @floatFromInt(row_count_capped - 1)) * gc.row_gap else 0;
        const remaining_h = @max(0, available.height - fixed_row_total - row_gap_total);
        for (0..row_count_capped) |ri| {
            if (ri < explicit_row_count and gc.rows[ri] == .fr) {
                row_sizes[ri] = remaining_h * gc.rows[ri].fr / fr_row_total;
            }
        }
    }

    // phase C: precompute track offsets
    // col_offsets[i] = starting x of column i (relative to content left edge)
    // after last column no more gap needed, but offset array uses [0..col_count) as start positions
    var col_offsets: [GridConfig.MAX_TRACKS + 1]f32 = @as([(GridConfig.MAX_TRACKS + 1)]f32, @splat(0));
    for (0..col_count) |ci| {
        col_offsets[ci + 1] = col_offsets[ci] + col_sizes[ci] + gc.column_gap;
    }

    var row_offsets: [65]f32 = @as([65]f32, @splat(0));
    for (0..row_count_capped) |ri| {
        row_offsets[ri + 1] = row_offsets[ri] + row_sizes[ri] + gc.row_gap;
    }

    // phase C: child positioning
    const pad_left = parent.style.padding.left;
    const pad_top = parent.style.padding.top;

    for (children, 0..) |child, i| {
        if (i >= placements.len) break;

        if (isDisplayNone(child)) {
            collapseDisplayNone(child);
            continue;
        }
        // absolute children: same as flexbox, not participate in grid positioning
        if (child.style.position == .absolute) {
            layoutAbsoluteChild(parent, child, ctx);
            continue;
        }

        const p = placements[i];
        // col_span == 0 marks skipped children (span exceeded columns etc)
        if (p.col_span == 0) continue;
        const c: usize = @intCast(p.col);
        const r: usize = @intCast(p.row);
        const c_end: usize = @min(c + p.col_span, col_count);
        const r_end: usize = @min(r + p.row_span, row_count_capped);

        // compute cell area (includes span)
        const cell_x = col_offsets[c];
        const cell_y = row_offsets[r];
        // cell size = last spanned track's end - start offset
        // for multi-span, includes gaps between
        var cell_w: f32 = 0;
        for (c..c_end) |ci| {
            cell_w += col_sizes[ci];
            if (ci > c) cell_w += gc.column_gap;
        }
        var cell_h: f32 = 0;
        for (r..r_end) |ri| {
            cell_h += row_sizes[ri];
            if (ri > r) cell_h += gc.row_gap;
        }

        // child size + min/max clamp
        const child_w = std.math.clamp(resolveGridChildSize(child, true, cell_w, cell_h), child.style.min_width(), child.style.max_width());
        const child_h = std.math.clamp(resolveGridChildSize(child, false, cell_h, cell_w), child.style.min_height(), child.style.max_height());

        // alignment (reuse justify/align_items)
        const h_align = parent.style.justify;
        const v_align = resolveCrossAlign(child, parent.style.align_items);

        const resolved_h = resolveAxisMargins(
            cell_w,
            child_w,
            child.style.margin.left,
            child.style.margin.right,
            child.style.marginLeftIsAuto(),
            child.style.marginRightIsAuto(),
        );
        const resolved_v = resolveAxisMargins(
            cell_h,
            child_h,
            child.style.margin.top,
            child.style.margin.bottom,
            child.style.marginTopIsAuto(),
            child.style.marginBottomIsAuto(),
        );
        const outer_w = child_w + resolved_h.start + resolved_h.end;
        const outer_h = child_h + resolved_v.start + resolved_v.end;
        const align_x: f32 = switch (h_align) {
            .center => if (child.style.marginLeftIsAuto() or child.style.marginRightIsAuto()) 0 else (cell_w - outer_w) / 2.0,
            .end => if (child.style.marginLeftIsAuto() or child.style.marginRightIsAuto()) 0 else cell_w - outer_w,
            else => 0,
        };
        const align_y: f32 = switch (v_align) {
            .center => if (child.style.marginTopIsAuto() or child.style.marginBottomIsAuto()) 0 else (cell_h - outer_h) / 2.0,
            .end => if (child.style.marginTopIsAuto() or child.style.marginBottomIsAuto()) 0 else cell_h - outer_h,
            else => 0,
        };

        const new_x = pad_left + cell_x + align_x + resolved_h.start;
        const new_y = pad_top + cell_y + align_y + resolved_v.start;

        if (child.rectFromWorldOrFallback().w != child_w or child.rectFromWorldOrFallback().h != child_h or
            child.rectFromWorldOrFallback().x != new_x or child.rectFromWorldOrFallback().y != new_y)
        {
            child.frame_state.state_bits.dirty.core.layout = true;
        }
        child.setLayoutX(new_x);
        child.setLayoutY(new_y);
        child.setLayoutW(child_w);
        child.setLayoutH(child_h);

        layoutNode(child, Size.init(child_w, child_h), ctx);
    }
}

/// parse grid child's size on an axis
/// child's cross-axis valid alignment: explicit align_self priority;
/// else inherit parent align_items, but `no_cross_stretch` downgrades inherited .stretch to .start
/// (keep intrinsic cross size), parent explicit .start/.center/.end/.baseline pass through as-is.
pub fn resolveCrossAlign(child: *const Node, parent_align_items: AlignItems) AlignItems {
    if (child.style.align_self()) |explicit| return explicit;
    if (parent_align_items == .stretch and child.style.no_cross_stretch()) return .start;
    return parent_align_items;
}

fn resolveGridChildSize(child: *Node, comptime is_width: bool, cell_main: f32, cell_cross: f32) f32 {
    _ = cell_cross;
    const sizing = if (is_width) child.style.width else child.style.height;
    const margin_axis = if (is_width) child.style.marginHorizontal() else child.style.marginVertical();
    return switch (sizing) {
        .px => |v| v,
        .grow => @max(0, cell_main - margin_axis),
        .fit => calcIntrinsicSize(child, is_width),
        .percent => |p| cell_main * p / 100.0,
    };
}

fn growMultiSpanAutoColumns(
    children: []const *Node,
    placements: []const Placement,
    gc: *const GridConfig,
    col_count: usize,
    col_sizes: *[GridConfig.MAX_TRACKS]f32,
) void {
    for (children, 0..) |child, idx| {
        if (idx >= placements.len) break;
        const p = placements[idx];
        if (p.col_span <= 1 or p.col_span == 0) continue;

        const start: usize = @intCast(p.col);
        const end = @min(start + p.col_span, col_count);
        var current: f32 = if (end > start) @as(f32, @floatFromInt(end - start - 1)) * gc.column_gap else 0;
        var auto_track_count: usize = 0;

        for (start..end) |ci| {
            current += col_sizes[ci];
            if (gc.columns[ci] == .auto) auto_track_count += 1;
        }

        if (auto_track_count == 0) continue;

        const deficit = calcIntrinsicSize(child, true) + child.style.marginHorizontal() - current;
        if (deficit <= 0) continue;

        const per_track = deficit / @as(f32, @floatFromInt(auto_track_count));
        for (start..end) |ci| {
            if (gc.columns[ci] == .auto) col_sizes[ci] += per_track;
        }
    }
}

fn growMultiSpanAutoRows(
    children: []const *Node,
    placements: []const Placement,
    gc: *const GridConfig,
    row_count: usize,
    row_sizes: *[64]f32,
) void {
    for (children, 0..) |child, idx| {
        if (idx >= placements.len) break;
        const p = placements[idx];
        if (p.row_span <= 1 or p.col_span == 0) continue;

        const start: usize = @intCast(p.row);
        const end = @min(start + p.row_span, row_count);
        var current: f32 = if (end > start) @as(f32, @floatFromInt(end - start - 1)) * gc.row_gap else 0;
        var auto_track_count: usize = 0;

        for (start..end) |ri| {
            current += row_sizes[ri];
            if (isAutoRowTrack(gc, ri)) auto_track_count += 1;
        }

        if (auto_track_count == 0) continue;

        const deficit = calcIntrinsicSize(child, false) + child.style.marginVertical() - current;
        if (deficit <= 0) continue;

        const per_track = deficit / @as(f32, @floatFromInt(auto_track_count));
        for (start..end) |ri| {
            if (isAutoRowTrack(gc, ri)) row_sizes[ri] += per_track;
        }
    }
}

fn isAutoRowTrack(gc: *const GridConfig, row_index: usize) bool {
    const explicit_row_count = @min(@as(usize, gc.row_count), GridConfig.MAX_TRACKS);
    if (row_index >= explicit_row_count) return true;
    return gc.rows[row_index] == .auto;
}

/// mark occupation bitmap
fn markOccupied(
    occupied: *[64][GridConfig.MAX_TRACKS]bool,
    col: u8,
    row: u8,
    col_span: u8,
    row_span: u8,
    col_count: usize,
    max_rows: usize,
) void {
    var r: usize = row;
    while (r < @min(@as(usize, row) + row_span, max_rows)) : (r += 1) {
        var c: usize = col;
        while (c < @min(@as(usize, col) + col_span, col_count)) : (c += 1) {
            occupied[r][c] = true;
        }
    }
}

/// check if area occupied
fn isOccupiedRegion(
    occupied: *const [64][GridConfig.MAX_TRACKS]bool,
    col: u8,
    row: u8,
    col_span: u8,
    row_span: u8,
    col_count: usize,
    max_rows: usize,
) bool {
    var r: usize = row;
    while (r < @min(@as(usize, row) + row_span, max_rows)) : (r += 1) {
        var c: usize = col;
        while (c < @min(@as(usize, col) + col_span, col_count)) : (c += 1) {
            if (occupied[r][c]) return true;
        }
    }
    return false;
}

const testing = std.testing;

test "measureIntrinsicTextWidth accounts for monospace spans and inline padding" {
    const spans: []const types.TextSpan = &.{
        .{
            .start = 0,
            .end = 13,
            .bg_color = types.Color.rgba(120, 120, 140, 30),
            .use_monospace_font = true,
            .inline_box_padding_left = 3,
            .inline_box_padding_right = 3,
            .inline_box_corner_radius = 4,
        },
    };
    const text_props = types.TextProps{
        .content = "message?: any",
        .font_size = 12,
        .font_weight = 600,
        .use_monospace_font = true,
        .spans = spans,
        .spans_affect_layout = true,
    };

    const measured = measureIntrinsicTextWidth(text_props);
    const expected = text_layout.measureTextWidthWithSpans(
        text_props.content,
        0,
        @intCast(text_props.content.len),
        text_props.font_size,
        text_props.font_weight,
        text_props.use_italic_font,
        text_props.use_monospace_font,
        spans,
    );

    try testing.expectApproxEqAbs(expected, measured, 0.001);
}

test "measureIntrinsicTextWidth respects newline_only max line width" {
    const spans: []const types.TextSpan = &.{
        .{
            .start = 5,
            .end = 18,
            .bg_color = types.Color.rgba(120, 120, 140, 30),
            .use_monospace_font = true,
            .inline_box_padding_left = 3,
            .inline_box_padding_right = 3,
            .inline_box_corner_radius = 4,
        },
    };
    const text_props = types.TextProps{
        .content = "log(\n  message?: any,\n  ...optionalParams: any[]\n): void",
        .font_size = 12,
        .font_weight = 400,
        .line_height = 1.35,
        .wrap = .newline_only,
        .use_monospace_font = true,
        .spans = spans,
        .spans_affect_layout = true,
    };

    const measured = measureIntrinsicTextWidth(text_props);
    const expected_layout = text_layout.computeTextLayout(
        text_props.content,
        std.math.inf(f32),
        text_props.wrap,
        text_props.max_lines,
        text_props.font_size,
        text_props.line_height,
        text_props.font_weight,
        text_props.use_italic_font,
        text_props.use_monospace_font,
        spans,
    );

    try testing.expectApproxEqAbs(expected_layout.max_line_width, measured, 0.001);
}

test "measureNode intrinsic width uses span-aware text width" {
    var node = Node{
        .id = 1,
        .tag = .box,
        .style = .{},
        .children = .empty,
    };
    defer node.children.deinit(testing.allocator);

    const spans: []const types.TextSpan = &.{
        .{
            .start = 0,
            .end = 13,
            .bg_color = types.Color.rgba(120, 120, 140, 30),
            .use_monospace_font = true,
            .inline_box_padding_left = 3,
            .inline_box_padding_right = 3,
            .inline_box_corner_radius = 4,
        },
    };
    node.setText(.{
        .content = "message?: any",
        .font_size = 12,
        .font_weight = 600,
        .use_monospace_font = true,
        .spans = spans,
        .spans_affect_layout = true,
    });

    const size = measureNode(&node, .{});
    const expected = text_layout.measureTextWidthWithSpans(
        node.getText().?.content,
        0,
        @intCast(node.getText().?.content.len),
        node.getText().?.font_size,
        node.getText().?.font_weight,
        node.getText().?.use_italic_font,
        node.getText().?.use_monospace_font,
        spans,
    );

    try testing.expectApproxEqAbs(expected, size.width, 0.001);
}

test "measureNode bounds application-provided tree depth" {
    const count = max_layout_recursion_depth + 16;
    const nodes = try testing.allocator.alloc(Node, count);
    defer testing.allocator.free(nodes);
    var initialized: usize = 0;
    defer for (nodes[0..initialized]) |*node| node.children.deinit(testing.allocator);

    for (nodes, 0..) |*node, i| {
        node.* = .{
            .id = @intCast(i + 1),
            .tag = .box,
            // Column main-axis (.height) recurses; fixed cross-axis width
            // keeps this a linear depth test instead of exercising the
            // intentionally independent width/height measurement passes.
            .style = .{ .width = .{ .px = 1 } },
            .children = .empty,
        };
        initialized += 1;
    }
    for (nodes[0 .. count - 1], 0..) |*node, i| {
        try node.children.append(testing.allocator, &nodes[i + 1]);
    }

    const hits_before = layout_depth_limit_hits;
    const measured = measureNode(&nodes[0], .{});
    try testing.expect(layout_depth_limit_hits > hits_before);
    try testing.expectEqual(@as(usize, 0), g_layout_recursion_depth);
    try testing.expect(std.math.isFinite(measured.width));
    try testing.expect(std.math.isFinite(measured.height));
}

test "managed font hooks clear only the active Cx owner" {
    const Bridge = struct {
        fn measure(_: *anyopaque, _: []const u8, _: f32, _: u16, _: bool, _: bool, _: u16, _: bool, _: f32) ?f32 {
            return 42;
        }
    };
    var first: u8 = 0;
    var second: u8 = 0;
    var shared_selector: u8 = 0;
    defer setDrawnTextMeasure(null, null);
    defer setShapeFontResolver(null, null);
    setContextFontHooks(&first, null, Bridge.measure, &shared_selector);
    setContextFontHooks(&second, null, Bridge.measure, &shared_selector);
    clearContextFontHooks(&first);
    try std.testing.expectEqual(@as(?f32, 42), shapeViaPipeline(null, null, "sample", 16, 400, false, false, 0, false, 0));
    clearContextFontHooks(&second);
    try std.testing.expectEqual(@as(?f32, null), shapeViaPipeline(null, null, "sample", 16, 400, false, false, 0, false, 0));
    setContextFontHooks(&first, null, Bridge.measure, &shared_selector);
    setDrawnTextMeasure(Bridge.measure, &shared_selector); // External owner takes over.
    clearContextFontHooks(&first);
    try std.testing.expectEqual(@as(?f32, 42), shapeViaPipeline(null, null, "sample", 16, 400, false, false, 0, false, 0));
}

test "intrinsic fit gaps exclude hidden anchors and display-none captions" {
    var parent = Node{ .id = 1, .tag = .box, .style = .{ .direction = .row, .gap = 8 }, .children = .empty };
    defer parent.children.deinit(std.testing.allocator);
    var first = Node{ .id = 2, .tag = .box, .style = .{ .width = .{ .px = 28 } }, .children = .empty };
    var hidden = Node{ .id = 3, .tag = .anchor, .style = .{ .display = .none }, .children = .empty };
    var last = Node{ .id = 4, .tag = .box, .style = .{ .width = .{ .px = 146 } }, .children = .empty };
    try parent.children.append(std.testing.allocator, &first);
    try parent.children.append(std.testing.allocator, &hidden);
    try parent.children.append(std.testing.allocator, &last);
    try std.testing.expectEqual(@as(f32, 182), calcIntrinsicSizeUncached(&parent, true));
}
