//! node_layout_output, v0.10 §L: NodeLayoutOutput and child struct independent definitions.
//!
//! Factored from node.zig so both node.zig and layout_output_table.zig reference without import
//! cycle (types.zig can't hold LayoutArtifacts because text_layout.zig already imports types.zig,
//! reverse would cycle). This module only depends types.zig + text_layout.zig, neither imports this
//! module, no cycle.

const types = @import("types.zig");
const text_layout_mod = @import("text_layout.zig");

const PathGeometry = types.PathGeometry;
const ComputedRect = types.ComputedRect;
const Color = types.Color;

/// Fill/clip path geometries (path + custom_clip). Warning: path/custom_clip hold clonePathGeometry
/// heap alloc, owner must freePathGeometry.
pub const NodeGeometries = struct {
    /// For SVG <path> rendering etc vector path
    path: ?PathGeometry = null,
    /// User-provided custom clip mask (separate from style.clip_shape)
    custom_clip: ?PathGeometry = null,
};

/// Vector stroke (separate from fill.path, can coexist). geometry holds heap alloc.
pub const NodeStroke = struct {
    geometry: ?PathGeometry = null,
    color: Color = Color.rgba(0, 0, 0, 255),
    width: f32 = 1.0,
    line_join: types.LineJoin = .miter,
};

pub const NodeVector = struct {
    /// Fill/clip path geometries (path + custom_clip)
    fill: NodeGeometries = .{},
    /// Vector stroke (separate from fill.path, can coexist)
    stroke: NodeStroke = .{},
};

pub const LayoutArtifacts = struct {
    /// Children AABB (relative to own rect, hitTest prune); computed after layout, null if
    /// uncomputed or no children
    children_bbox: ?ComputedRect = null,
    /// Table-owned cache borrowed until clear, replacement, reuse or teardown.
    /// Stable across table growth; write only through storeTextLayout.
    text_layout: ?*const text_layout_mod.TextLayout = null,
};

pub const NodeLayoutOutput = struct {
    vector: NodeVector = .{},
    artifacts: LayoutArtifacts = .{},
};
