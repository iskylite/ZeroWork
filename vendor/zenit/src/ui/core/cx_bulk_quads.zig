//! Cx bulk quad layer: setBulkQuads* (skip retransmit with version) and node attachment, external
//! clip rect injection. Storage and fallback logic in bulk_quad_layer.zig.

const std = @import("std");
const core = @import("../core.zig");
const Cx = core.Cx;
const BulkQuad = core.BulkQuad;
const Node = core.Node;
const bulk_quad_layer_mod = @import("bulk_quad_layer.zig");

/// Pack Cx's six read-only inputs into BulkQuadLayer-required Host.
///
/// After factoring to core/bulk_quad_layer.zig, that layer's only Cx dependency is these six
/// (display_list/property_tree/scene_runtime/root/frame_arena/allocator), doesn't import core.zig,
/// so no reverse dependency.
fn bulkQuadHost(self: *Cx) bulk_quad_layer_mod.Host {
    return .{
        .display_list = &self.display_list,
        .property_tree = &self.property_tree,
        .scene_runtime = &self.scene_runtime,
        .root = self.root,
        .frame_arena = self.frame_arena.allocator(),
        .allocator = self.allocator,
    };
}

/// Bulk layer's five Cx fields (bulk_quads/_anchor/_overlay_z/_version/_unchanged) temporarily
/// borrow views per BulkQuadLayer shape. After factoring, Cx still holds this state as
/// `bulk_quads_*` (tests/devtools direct-read), so reassemble via pointer rather than move.
pub fn bulkQuadLayer(self: *Cx) bulk_quad_layer_mod.BulkQuadLayer {
    return .{
        .quads = self.bulk_quads,
        .anchor = self.bulk_quads_anchor,
        .overlay_z = self.bulk_quads_overlay_z,
        .version = self.bulk_quads_version,
        .unchanged = self.bulk_quads_unchanged,
    };
}

/// View write-back (append doesn't change these five fields, but set* paths do).
pub fn storeBulkQuadLayer(self: *Cx, layer: bulk_quad_layer_mod.BulkQuadLayer) void {
    self.bulk_quads = layer.quads;
    self.bulk_quads_anchor = layer.anchor;
    self.bulk_quads_overlay_z = layer.overlay_z;
    self.bulk_quads_version = layer.version;
    self.bulk_quads_unchanged = layer.unchanged;
}

/// Lower bulk rectangle layer to display item. **Isomorphic** to Node path: background uses
/// `fill_rect`, stroke uses `stroke_rect`, parameters correspond item-by-item, thus same
/// geometry/color/corner/stroke width produces per-bit identical pixels.
///
/// Implementation in core/bulk_quad_layer.zig (three-level insertion point locate / z merge / lower
/// unit tests also there); here just pack Host and delegate.
pub fn appendBulkQuads(self: *Cx) !void {
    var layer = bulkQuadLayer(self);
    defer storeBulkQuadLayer(self, layer);
    try layer.append(bulkQuadHost(self));
}

pub fn setBulkQuads(self: *Cx, anchor: ?*Node, quads: []const BulkQuad) !void {
    return self.setBulkQuadsEx(anchor, quads, null);
}

pub fn setBulkQuadsVersioned(
    self: *Cx,
    anchor: ?*Node,
    quads: []const BulkQuad,
    overlay_z_threshold: ?i16,
    version: ?u64,
) !void {
    // Version check (unchanged/version three-state semantics) in bulk_quad_layer.zig; here borrow
    // view, run complete, write back; Cx field names unchanged (tests/devtools direct-read).
    var layer = bulkQuadLayer(self);
    defer storeBulkQuadLayer(self, layer);
    return layer.setVersioned(bulkQuadHost(self), anchor, quads, overlay_z_threshold, version);
}

pub fn setBulkQuadsEx(
    self: *Cx,
    anchor: ?*Node,
    quads: []const BulkQuad,
    overlay_z_threshold: ?i16,
) !void {
    var layer = bulkQuadLayer(self);
    defer storeBulkQuadLayer(self, layer);
    return layer.set(bulkQuadHost(self), anchor, quads, overlay_z_threshold);
}

pub fn setNodeExternalClipRect(self: *Cx, node_id: u32, rect: ?[4]f32) void {
    if (rect) |r| {
        const gop = self.external_clip_rects.getOrPut(self.allocator, node_id) catch return;
        if (gop.found_existing and std.mem.eql(f32, &gop.value_ptr.*, &r)) return;
        gop.value_ptr.* = r;
    } else {
        if (!self.external_clip_rects.remove(node_id)) return;
    }
    self.requestRedraw();
}
