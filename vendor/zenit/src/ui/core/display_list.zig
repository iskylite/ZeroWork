/// Display List: internal IR of the paint pass.
///
/// **core/ internal only; external code must not import it directly.**
/// The encoder main path uses paint_table.DisplayItem (struct, not union). This file remains as
/// the IR bridge between paint pass -> display_list_lowering; snapshot.zig also holds this union
/// across frames (Snapshot.commands). Modules needing paint data should import `paint_table.zig`.
/// `grep -rn "@import.*display_list.zig" src/` should only hit the src/ui/core/ subtree.
///
/// DisplayItem is the unique IR between paint pass -> encoder. Each item associates via ItemHeader
/// with transform/clip/effect in PropertyTree. The paint pass emits local coordinates;
/// display_list_lowering applies the transform to get world coordinates, and the encoder directly
/// consumes the lowered DisplayItem.
const std = @import("std");
const types = @import("types.zig");
const icon_ir = @import("icon_ir");
const property_tree = @import("property_tree.zig");
const text_blob_mod = @import("text_blob.zig");

pub const TextRasterPolicy = text_blob_mod.TextRasterPolicy;

const Allocator = std.mem.Allocator;
const Color = types.Color;
const TextSpan = types.TextSpan;
const GradientDirection = types.GradientDirection;
pub const INVALID_ID = property_tree.INVALID_ID;

/// Clip primitive type (R3f defined in display_list), shared with ClipNode/clip token. PathFillRule
/// reused from types.PathFillRule (cross-module shared, not defined here).
pub const max_clip_polygon_points: usize = 32;
pub const max_clip_polygon_contours: usize = 8;

/// Sentinel in `begin_opacity_layer.surface_stable_id`: doesn't participate in GPU retained
/// composite. Semantically 'no stable identity', encoder seeing it must take old
/// every-frame-repaint path.
pub const INVALID_SURFACE_ID: u32 = std.math.maxInt(u32);

pub const ClipShapeKind = enum(u8) {
    rect = 0,
    rounded_rect = 1,
    ellipse = 2,
    polygon = 3,
};

pub const ClipPolygon = struct {
    point_count: u8 = 0,
    contour_count: u8 = 0,
    fill_rule: types.PathFillRule = .evenodd,
    contour_end_points: [max_clip_polygon_contours]u8 = @as([max_clip_polygon_contours]u8, @splat(0)),
    points: [max_clip_polygon_points][2]f32 = @as([max_clip_polygon_points][2]f32, @splat(.{ 0, 0 })),

    pub fn empty() ClipPolygon {
        return .{};
    }
};

/// Common associating header for each DisplayItem (PropertyTree reference)
pub const ItemHeader = struct {
    /// Frozen snapshot geometry has no dependency on the current property tree.
    already_lowered: bool = false,
    transform_id: u32,
    clip_id: u32 = INVALID_ID,
    effect_id: u32 = INVALID_ID,
    node_id: u32,
    paint_order: u64 = 0,
};

pub const DisplayItem = union(enum) {
    fill_rect: struct {
        header: ItemHeader,
        x: f32,
        y: f32,
        w: f32,
        h: f32,
        color: Color,
        radius: [4]f32 = .{ 0, 0, 0, 0 },
        /// Draw shape (0 = rounded_rect, 1 = ellipse). Same sequence as types.ShapeSpec. Radius
        /// ignored when ellipse (SDF determined by semi-axes).
        shape: u8 = 0,
    },
    stroke_rect: struct {
        header: ItemHeader,
        x: f32,
        y: f32,
        w: f32,
        h: f32,
        color: Color,
        width: f32,
        radius: [4]f32 = .{ 0, 0, 0, 0 },
        /// See fill_rect.shape
        shape: u8 = 0,
    },
    border_side: struct {
        header: ItemHeader,
        x: f32,
        y: f32,
        w: f32,
        h: f32,
        color: Color,
        width: f32,
        radius: [4]f32 = .{ 0, 0, 0, 0 },
        clip_x: f32,
        clip_y: f32,
        clip_w: f32,
        clip_h: f32,
        clip_radius: f32 = 0,
        clip_shape_kind: ClipShapeKind = .rect,
        clip_polygon: ClipPolygon = .{},
    },
    /// Per-side border: shader computes inner outline, no clip needed
    border_per_side: struct {
        header: ItemHeader,
        x: f32,
        y: f32,
        w: f32,
        h: f32,
        color: Color,
        widths: [4]f32, // top, right, bottom, left
        radius: [4]f32 = .{ 0, 0, 0, 0 },
    },
    gradient_rect: struct {
        header: ItemHeader,
        x: f32,
        y: f32,
        w: f32,
        h: f32,
        from: Color,
        to: Color,
        direction: GradientDirection = .vertical,
        radius: [4]f32 = .{ 0, 0, 0, 0 },
        radial_center_x: f32 = 0,
        radial_center_y: f32 = 0,
        conic_start_angle: f32 = 0,
        extend_mode: types.GradientExtendMode = .pad,
        /// See fill_rect.shape
        shape: u8 = 0,
    },
    shadow_rect: struct {
        header: ItemHeader,
        x: f32,
        y: f32,
        w: f32,
        h: f32,
        color: Color,
        blur: f32,
        offset_x: f32 = 0,
        offset_y: f32 = 0,
        /// CSS spread (positive outer expand / negative shrink shadow shape; body always hollowed
        /// below).
        spread: f32 = 0,
        radius: [4]f32 = .{ 0, 0, 0, 0 },
    },
    outline_rect: struct {
        header: ItemHeader,
        x: f32,
        y: f32,
        w: f32,
        h: f32,
        color: Color,
        width: f32,
        radius: [4]f32 = .{ 0, 0, 0, 0 },
    },
    text_run: struct {
        header: ItemHeader,
        /// local origin x
        x: f32,
        /// local baseline y
        y: f32,
        content: []const u8,
        blob_byte_start: u32 = 0,
        blob_byte_end: u32 = 0,
        color: Color,
        /// Logical font size (not multiplied by scale!)
        font_size: f32,
        font_weight: u16 = 400,
        /// Font family id (see TextProps.font_family). 0 = default family.
        font_family: u16 = 0,
        use_symbols_font: bool = false,
        use_monospace_font: bool = false,
        monospace_char_width: f32 = 0,
        use_italic_font: bool = false,
        /// TextProps.font_smoothing
        font_smoothing: bool = true,
        spans: ?[]const TextSpan = null,
        /// Phase L3: associated TextLayoutBlob (INVALID_ID = none)
        blob_id: u32 = INVALID_ID,
        /// Snapshot of this blob's content_hash, used to verify blob_id still points to the same
        /// text.
        ///
        /// blob_id is a **frame-local sequence number**; text_blob_store is cleared and
        /// re-allocated each
        /// frame. A persisted item (replay/cache) holding an old number may find it claimed by
        /// another
        /// widget this frame, then slices that widget's bytes by its own offset (e.g. state bar
        /// "plaintext" drawn as "plainte"). The hash detects the misidentity and falls back to
        /// content.
        blob_content_hash: u64 = 0,
        /// Phase L3: rasterization strategy
        raster_policy: TextRasterPolicy = .static_crisp,
        /// Right-edge fade-out mask window, **offset relative to run start x** (0/0 = off).
        /// Relative quantity during lowering only needs scale multiply; snapshot translation
        /// naturally avoids change. See TextProps.fade_right.
        fade_dx0: f32 = 0,
        fade_dx1: f32 = 0,
    },
    image_quad: struct {
        header: ItemHeader,
        x: f32,
        y: f32,
        w: f32,
        h: f32,
        texture_id: u32,
        tint: Color = Color.WHITE,
        corner_radius: f32 = 0,
        opacity: f32 = 1,
        rotate: f32 = 0,
    },
    icon_rep: struct {
        header: ItemHeader,
        icon_id: u16,
        rep_size: u8,
        rep: icon_ir.Rep,
        x: f32,
        y: f32,
        w: f32,
        h: f32,
        tint: Color = Color.WHITE,
        corner_clip_radius: f32 = 0,
        opacity: f32 = 1,
        rotate: f32 = 0,
        /// Snap the quad to device pixels (static icons, like static_crisp text).
        /// The mask is rasterized at whole physical pixels; drawn at a fractional
        /// offset, bilinear sampling smears each stroke over two pixels.
        snap: bool = true,
    },
    arc: struct {
        header: ItemHeader,
        cx: f32,
        cy: f32,
        outer_radius: f32,
        stroke_width: f32,
        start_angle: f32,
        end_angle: f32,
        color: Color,
    },
    /// Multi-color gradient (multiple stops)
    multi_gradient_rect: struct {
        header: ItemHeader,
        x: f32,
        y: f32,
        w: f32,
        h: f32,
        direction: GradientDirection = .vertical,
        radius: [4]f32 = .{ 0, 0, 0, 0 },
        stop_colors: [16]Color = @as([16]Color, @splat(Color.rgba(0, 0, 0, 0))),
        stop_positions: [16]f32 = @as([16]f32, @splat(0)),
        stop_count: u8 = 0,
        radial_center_x: f32 = 0,
        radial_center_y: f32 = 0,
        /// Radial ellipse radii (UV units; 0.5 = inscribed).
        radial_radius_x: f32 = 0.5,
        radial_radius_y: f32 = 0.5,
        conic_start_angle: f32 = 0,
        extend_mode: types.GradientExtendMode = .pad,
        /// See fill_rect.shape (0 = rounded_rect, 1 = ellipse). Gradient must also obey shape, else
        /// ellipse gradient fills entire bounding box.
        shape: u8 = 0,
    },
    /// Procedural noise texture
    noise_rect: struct {
        header: ItemHeader,
        x: f32,
        y: f32,
        w: f32,
        h: f32,
        fill: Color,
        mode: u8 = 1,
        scale: f32 = 2.0,
        intensity: f32 = 0.04,
        seed: u8 = 0,
        radius: [4]f32 = .{ 0, 0, 0, 0 },
    },
    /// Inset Shadow inner shadow
    inset_shadow_rect: struct {
        header: ItemHeader,
        x: f32,
        y: f32,
        w: f32,
        h: f32,
        fill: Color,
        shadow_color: Color,
        blur: f32,
        offset_x: f32 = 0,
        offset_y: f32 = 0,
        radius: [4]f32 = .{ 0, 0, 0, 0 },
    },
    /// Double outer shadow
    shadow_dual_rect: struct {
        header: ItemHeader,
        x: f32,
        y: f32,
        w: f32,
        h: f32,
        fill: Color,
        shadow1_color: Color,
        shadow1_blur: f32,
        shadow1_offset_x: f32 = 0,
        shadow1_offset_y: f32 = 0,
        shadow2_color: Color,
        shadow2_blur: f32,
        shadow2_offset_x: f32 = 0,
        shadow2_offset_y: f32 = 0,
        radius: [4]f32 = .{ 0, 0, 0, 0 },
    },
    /// Vector path fill (local coordinates, offset relative to node top-left)
    fill_path: struct {
        header: ItemHeader,
        /// PathGeometry lifetime managed by caller (scene runtime)
        geometry: *const types.PathGeometry,
        color: Color,
        offset_x: f32 = 0,
        offset_y: f32 = 0,
        opacity: f32 = 1.0,
        /// Optional gradient fill. `gradient_direction == 0` means pure color via `color`.
        /// Per-vertex coloring done by path_renderer (GPU PathVertex.color already supported),
        /// polygon gradient fill (triangle/star) via this, else degrades to pure color.
        gradient_direction: u8 = 0,
        gradient_stop_colors: [16]Color = @as([16]Color, @splat(Color.rgba(0, 0, 0, 0))),
        gradient_stop_positions: [16]f32 = @as([16]f32, @splat(0)),
        gradient_stop_count: u8 = 0,
        gradient_center_x: f32 = 0.5,
        gradient_center_y: f32 = 0.5,
        gradient_start_angle: f32 = 0,
    },
    /// Vector path stroke (local coordinates, offset relative to node top-left)
    stroke_path: struct {
        header: ItemHeader,
        geometry: *const types.PathGeometry,
        color: Color,
        width: f32 = 1.0,
        line_join: types.LineJoin = .miter,
        offset_x: f32 = 0,
        offset_y: f32 = 0,
        opacity: f32 = 1.0,
    },

    // ─── Effect/clip literal token variant ───
    // Effect bridge tokens already lowered to active content frame.
    // Node-owned push_clip is exception: node_local requests same
    // property-tree/replay transform as paint items before encoder dispatch.

    push_clip: struct {
        header: ItemHeader,
        /// Node clips share the paint item transform; literal bridge/snapshot clips are already lowered.
        node_local: bool = false,
        x: f32,
        y: f32,
        w: f32,
        h: f32,
        radius: f32 = 0,
        shape_kind: ClipShapeKind = .rect,
        polygon: ClipPolygon = .{},
    },
    pop_clip: struct {
        header: ItemHeader,
    },

    begin_opacity_layer: struct {
        header: ItemHeader,
        x: f32,
        y: f32,
        w: f32,
        h: f32,
        opacity: f32,
        /// Stage 3 rounded-clip fold: when same-node rounded_clip folds into opacity layer, rounded
        /// mask radius applied by composite blit (0 = no radius, semantics same as
        /// begin_blur_layer).
        corner_radius: f32 = 0,
        rotate: f32 = 0,
        draw_x: f32 = std.math.nan(f32),
        draw_y: f32 = std.math.nan(f32),
        draw_w: f32 = std.math.nan(f32),
        draw_h: f32 = std.math.nan(f32),
        use_draw_transform: bool = false,
        draw_transform: types.Transform2D = types.Transform2D.identity(),
        blend_mode: types.BlendMode = .normal,
        /// Lens warp of the layer surface at composite (see types.ContentWarp; {cap, edge,
        /// fade_start, fade_width} logical px; all zero = none).
        warp: [4]f32 = .{ 0, 0, 0, 0 },
        /// GPU retained composite cache key.
        ///
        /// `surface_stable_id` = this layer's cross-frame stable identity (packed raw of retained
        /// LayerId,
        /// includes generation ABA guard); `surface_content_version` = content version, incremented
        /// once
        /// per content change. Encoder: same layer and unchanged content -> reuse last frame's
        /// rasterized offscreen texture and skip the content pass.
        ///
        /// INVALID (= std.math.maxInt(u32)) means the layer doesn't participate in GPU retained
        /// (non-promoted / no stable identity); the encoder must repaint every frame (safe
        /// default).
        surface_stable_id: u32 = INVALID_SURFACE_ID,
        surface_content_version: u32 = 0,
    },
    end_opacity_layer: struct {
        header: ItemHeader,
    },

    begin_blur_layer: struct {
        header: ItemHeader,
        x: f32,
        y: f32,
        w: f32,
        h: f32,
        corner_radius: f32 = 0,
        /// Four-corner radii TL/TR/BR/BL (x<0 = uniform corner_radius): ConcentricRectangle glass's
        /// corners differ
        corner_radii: [4]f32 = .{ -1, -1, -1, -1 },
        /// glass owner node id (stable key for luminance region slot; header is CONTROL without it)
        owner_node: u32 = std.math.maxInt(u32),
        glass: types.ResolvedGlassParams = .{},
        rotate: f32 = 0,
        draw_x: f32 = std.math.nan(f32),
        draw_y: f32 = std.math.nan(f32),
        draw_w: f32 = std.math.nan(f32),
        draw_h: f32 = std.math.nan(f32),
        use_draw_transform: bool = false,
        draw_transform: types.Transform2D = types.Transform2D.identity(),
    },
    end_blur_layer: struct {
        header: ItemHeader,
    },

    begin_rounded_clip: struct {
        header: ItemHeader,
        x: f32,
        y: f32,
        w: f32,
        h: f32,
        radius: f32,
        rotate: f32 = 0,
        draw_x: f32 = std.math.nan(f32),
        draw_y: f32 = std.math.nan(f32),
        draw_w: f32 = std.math.nan(f32),
        draw_h: f32 = std.math.nan(f32),
        use_draw_transform: bool = false,
        draw_transform: types.Transform2D = types.Transform2D.identity(),
    },
    end_rounded_clip: struct {
        header: ItemHeader,
    },

    /// Return common ItemHeader of all variants (eliminate caller's switch repetition)
    pub fn header(self: DisplayItem) ItemHeader {
        return switch (self) {
            inline else => |it| it.header,
        };
    }

    /// Mutable header access: cross-frame cache splice rewrites frame-local
    /// transform/clip/effect_id to this frame's values by node_id (see render_engine
    /// rewriteSplicedItemHeaders).
    /// Control items (layer begin/end, push/pop clip) only group/toggle state, no geometry.
    /// The scroll-clip token carries a **real header** (node_id = the node that sent it); any scan
    /// by node_id attributing "child subtree content" must skip it, else the token is treated as
    /// that node's last content.
    pub fn isControl(self: DisplayItem) bool {
        return switch (self) {
            .begin_opacity_layer,
            .end_opacity_layer,
            .begin_blur_layer,
            .end_blur_layer,
            .begin_rounded_clip,
            .end_rounded_clip,
            .push_clip,
            .pop_clip,
            => true,
            else => false,
        };
    }

    pub fn headerPtr(self: *DisplayItem) *ItemHeader {
        return switch (self.*) {
            inline else => |*it| &it.header,
        };
    }
};

pub const TextRunItem = @FieldType(DisplayItem, "text_run");

pub const DisplayList = struct {
    allocator: Allocator,
    items: std.ArrayList(DisplayItem),
    /// Pointer-backed items can be replayed after their node/cache/snapshot has
    /// rebuilt or been replaced. Keep text slices and path geometry with the
    /// list rather than borrowing them from mutable producer storage.
    payload_arena: std.heap.ArenaAllocator,

    pub fn init(allocator: Allocator) DisplayList {
        return .{
            .allocator = allocator,
            .items = .empty,
            .payload_arena = std.heap.ArenaAllocator.init(allocator),
        };
    }

    pub fn deinit(self: *DisplayList) void {
        self.items.deinit(self.allocator);
        self.payload_arena.deinit();
    }

    pub const MemoryStats = struct { item_capacity_bytes: usize, payload_capacity_bytes: usize };
    pub fn memoryStats(self: *const DisplayList) MemoryStats {
        return .{ .item_capacity_bytes = self.items.capacity * @sizeOf(DisplayItem), .payload_capacity_bytes = self.payload_arena.queryCapacity() };
    }

    pub fn clear(self: *DisplayList) void {
        self.items.clearRetainingCapacity();
        _ = self.payload_arena.reset(.retain_capacity);
    }

    pub fn append(self: *DisplayList, item: DisplayItem) !void {
        var owned_item = item;
        switch (owned_item) {
            .text_run => |*text| {
                const arena = self.payload_arena.allocator();
                text.content = if (text.content.len > 0) try arena.dupe(u8, text.content) else "";
                if (text.spans) |spans| {
                    text.spans = if (spans.len > 0) try arena.dupe(types.TextSpan, spans) else null;
                }
            },
            .fill_path => |*path| path.geometry = try self.clonePathGeometry(path.geometry),
            .stroke_path => |*path| path.geometry = try self.clonePathGeometry(path.geometry),
            else => {},
        }
        try self.items.append(self.allocator, owned_item);
    }

    fn clonePathGeometry(self: *DisplayList, source: *const types.PathGeometry) !*const types.PathGeometry {
        const arena = self.payload_arena.allocator();
        const clone = try arena.create(types.PathGeometry);
        clone.* = source.*;
        clone.commands = try arena.dupe(types.PathCommand, source.commands);
        // The arena owns the command slice and releases it as a group.
        clone.owned = false;
        return clone;
    }

    pub fn slice(self: *const DisplayList, start: usize, len: usize) []const DisplayItem {
        const clamped_start = @min(start, self.items.items.len);
        const clamped_end = @min(clamped_start + len, self.items.items.len);
        return self.items.items[clamped_start..clamped_end];
    }

    pub fn count(self: *const DisplayList) usize {
        return self.items.items.len;
    }
};

pub fn resolveTextRunContent(
    blob_store: *const text_blob_mod.BlobStore,
    run: TextRunItem,
) []const u8 {
    if (run.blob_id != INVALID_ID) {
        if (blob_store.get(run.blob_id)) |blob| {
            // WARNING: identity check: blob_id is a frame-local sequence number; the store is
            // cleared and
            // re-allocated each frame. A persisted item (replay/cache path) holds an old number
            // that may land
            // on another widget's new blob this frame; unchecked, it would slice by its own offset
            // into
            // others' bytes (e.g. terminal state bar "plaintext" drawn as "plainte").
            // Hash mismatch signals the number changed owners; fall back to the item's own content.
            const identity_ok = run.blob_content_hash == 0 or
                run.blob_content_hash == blob.content_hash;
            if (identity_ok and
                run.blob_byte_start < run.blob_byte_end and
                run.blob_byte_end <= blob.content.len)
            {
                return blob.content[run.blob_byte_start..run.blob_byte_end];
            }
        }
    }
    return run.content;
}

test "resolveTextRunContent: blob_id 易主时回退到 item 自带文本" {
    // Regression: blob_id is a **frame-local sequence number**; text_blob_store is cleared and
    // re-allocated each frame. A persisted item (replay / command cache) holds an old number that
    // may
    // land on another widget's new blob this frame; without an identity check it slices by its own
    // byte offset into others' bytes.
    //
    // Symptoms: terminal state bar "plaintext" drawn as "plainte", editor tab name "hello.txt"
    // drawn as "hello.t".
    const testing = std.testing;
    var store = text_blob_mod.BlobStore.init(testing.allocator);
    defer store.deinit();

    // This frame's 0th blob belongs to status bar
    var other = text_blob_mod.TextLayoutBlob{
        .style_key = .{ .font_size = 13, .font_weight = 400, .line_height = 1.35 },
        .content_hash = std.hash.Wyhash.hash(0, "plaintext"),
        .content = "plaintext",
        .line_count = 1,
    };
    other.lines[0] = .{ .byte_start = 0, .byte_end = 9, .width = 70 };
    const other_id = try store.append(other);

    // Last frame's terminal-line item: also points to 0th, but content hash is its own
    const stale_run = TextRunItem{
        .header = .{ .transform_id = 0, .node_id = 0 },
        .x = 0,
        .y = 0,
        .content = "(base) ",
        .blob_byte_start = 0,
        .blob_byte_end = 7,
        .color = .{ .r = 0, .g = 0, .b = 0, .a = 255 },
        .font_size = 13,
        .blob_id = other_id,
        .blob_content_hash = std.hash.Wyhash.hash(0, "(base) "),
    };

    // Must detect and fall back, not draw 'plainte'
    try testing.expectEqualStrings("(base) ", resolveTextRunContent(&store, stale_run));

    // Same sequence number, hash match, still use blob indirect path (can't degrade just because we
    // added validation)
    const live_run = TextRunItem{
        .header = .{ .transform_id = 0, .node_id = 0 },
        .x = 0,
        .y = 0,
        .content = "",
        .blob_byte_start = 0,
        .blob_byte_end = 5,
        .color = .{ .r = 0, .g = 0, .b = 0, .a = 255 },
        .font_size = 13,
        .blob_id = other_id,
        .blob_content_hash = other.content_hash,
    };
    try testing.expectEqualStrings("plain", resolveTextRunContent(&store, live_run));
}

test "resolveTextRunContent: 漏传 blob_content_hash 会让身份校验退化成永真" {
    // Regression (downstream editor status bar '3 × 4' -> '4 × 5' draws as '4 × 4'):
    // display_list_lowering's re-lower branch rebuilding TextRunItem field-by-field, only copied
    // blob_id but **omitted blob_content_hash**. Omit makes field default 0,
    // resolveTextRunContent's `run.blob_content_hash == 0` short-circuits identity check into
    // always-true, item with last-frame frame-local sequence number cuts **another blob's** bytes
    // this frame.
    //
    // This test uses 'same sequence + different content' construction to lay out both values:
    // hashed must detect and fall back to own text, hash=0 does take imposter blob's bytes. Latter
    // is actual behavior when field omitted, pinning it makes any new re-lower site failing here
    // rather than on user's screen if it forgets paired forwarding.
    const testing = std.testing;
    var store = text_blob_mod.BlobStore.init(testing.allocator);
    defer store.deinit();

    var impostor = text_blob_mod.TextLayoutBlob{
        .style_key = .{ .font_size = 11, .font_weight = 400, .line_height = 1.35 },
        .content_hash = std.hash.Wyhash.hash(0, "3 \xc3\x97 4"),
        .content = "3 \xc3\x97 4",
        .line_count = 1,
    };
    impostor.lines[0] = .{ .byte_start = 0, .byte_end = 6, .width = 40 };
    const impostor_id = try store.append(impostor);

    const base = TextRunItem{
        .header = .{ .transform_id = 0, .node_id = 0 },
        .x = 0,
        .y = 0,
        .content = "4 \xc3\x97 5",
        .blob_byte_start = 0,
        .blob_byte_end = 6,
        .color = .{ .r = 0, .g = 0, .b = 0, .a = 255 },
        .font_size = 11,
        .blob_id = impostor_id,
    };

    // Correct passthrough: hash mismatch -> detect ownership change, fall back to item's own
    // current-frame text.
    var carried = base;
    carried.blob_content_hash = std.hash.Wyhash.hash(0, "4 \xc3\x97 5");
    try testing.expectEqualStrings("4 \xc3\x97 5", resolveTextRunContent(&store, carried));

    // Omitted (=0): validation bypassed, cuts into imposter blob's bytes—exactly the stale glyphs
    // on screen.
    try testing.expectEqualStrings("3 \xc3\x97 4", resolveTextRunContent(&store, base));
}
