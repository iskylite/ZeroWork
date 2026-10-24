//! Node display payload **read-only access**, split out of display_list_lowering.zig (which keeps
//! the lowering core).
//!
//! This cluster answers one question: given node_id and own/subtree scope, where are its
//! DisplayItem/TextLayoutBlob slices. Common trait: **read-only, no allocation, doesn't change
//! cx**: index arithmetic on scene_runtime runtime records, then slicing
//! display_list/text_blob_store.
//!
//! Division with the lowering main path: that side **writes** (lowers display_list into
//! lowering_buffer_paint, owns buffer state and allocation); this side **reads already-written
//! results**. Keeping them in separate files makes the zero-side-effect property a file-level
//! guarantee.
//!
//! own vs subtree: own contains only the node's own items; subtree is its whole subtree's
//! contiguous range (lowering preserves preorder, so a subtree is start+count). count==0 returns
//! null, not an empty slice: callers distinguish "no payload" from "payload but empty", and
//! cross-frame splice depends on it.

const render_context_mod = @import("render_context.zig");
const display_list_mod = @import("../display_list.zig");
const text_blob_mod = @import("../text_blob.zig");

const RenderContext = render_context_mod.RenderContext;

pub const DisplayPayloadScope = enum {
    own,
    subtree,
};

pub const TextBlobPayloadScope = enum {
    own,
    subtree,
};

pub const NodeDisplayPayloadView = struct {
    items: []const display_list_mod.DisplayItem,
    blobs: []const text_blob_mod.TextLayoutBlob,
};

pub fn getNodeDisplayItems(
    cx: *RenderContext,
    node_id: u32,
    scope: DisplayPayloadScope,
) ?[]const display_list_mod.DisplayItem {
    const runtime = cx.scene_runtime.getPtr(node_id) orelse return null;
    const start: usize = switch (scope) {
        .own => runtime.display_item_start,
        .subtree => runtime.subtree_display_item_start,
    };
    const count: usize = switch (scope) {
        .own => runtime.display_item_count,
        .subtree => runtime.subtree_display_item_count,
    };
    if (count == 0) return null;
    return cx.display_list.slice(start, count);
}

pub fn getNodeTextBlobs(
    cx: *RenderContext,
    node_id: u32,
    scope: TextBlobPayloadScope,
) ?[]const text_blob_mod.TextLayoutBlob {
    const runtime = cx.scene_runtime.getPtr(node_id) orelse return null;
    const start: usize = switch (scope) {
        .own => runtime.text_blob_start,
        .subtree => runtime.subtree_text_blob_start,
    };
    const count: usize = switch (scope) {
        .own => runtime.text_blob_count,
        .subtree => runtime.subtree_text_blob_count,
    };
    if (count == 0) return null;
    return cx.text_blob_store.slice(start, count);
}

/// items + blobs together. Missing blobs degrade to empty slice not whole null; pure-graphic nodes
/// lacking text blob normal, shouldn't make whole payload "nonexistent".
pub fn getNodeDisplayPayload(
    cx: *RenderContext,
    node_id: u32,
    scope: DisplayPayloadScope,
) ?NodeDisplayPayloadView {
    const items = getNodeDisplayItems(cx, node_id, scope) orelse return null;
    const blob_scope: TextBlobPayloadScope = switch (scope) {
        .own => .own,
        .subtree => .subtree,
    };
    const blobs = getNodeTextBlobs(cx, node_id, blob_scope) orelse &.{};
    return .{
        .items = items,
        .blobs = blobs,
    };
}
