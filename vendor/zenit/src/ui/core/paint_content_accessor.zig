//! paint_content_accessor: routes access to NodeContent SoA, paint state SoA and
//! NodeLayoutOutput SoA, split out of node.zig.
//! Contains: callback type defs + global callback slots + registrar +
//! standalone fallback hashmap (element_id == 0xFFFFFFFF for non-cx mock test
//! nodes, keyed by node ptr) + Node-agnostic routing free functions. Node methods
//! (get/setText/Image/Icon, getBackground/setBackgroundRaw,
//! getLayoutOutput/setLayoutOutput/layoutOutputPtr) are thin one-liners
//! delegating here. Source of truth: world.ContentTable / world.PaintStateTable /
//! world.LayoutOutputTable; this layer handles callback dispatch + mock fallback.

const std = @import("std");
const world_mod = @import("world.zig");

/// Count of property accesses still using **old process-level global callbacks**
/// (world_ref == null nodes). After P0-3 phase 3 migration, production paths
/// should be 0; only cx-less test mocks hit this.
pub var legacy_callback_hits: u64 = 0;
const types = @import("types.zig");
const nlo = @import("node_layout_output.zig");

const Color = types.Color;
const TextProps = types.TextProps;
const ImageProps = types.ImageProps;
const IconProps = types.IconProps;
const NodeLayoutOutput = nlo.NodeLayoutOutput;

// ─────────────────────────────────────────────────────────────────────
// §b paint state SoA, write/read callback + standalone fallback
// ─────────────────────────────────────────────────────────────────────

pub const PaintStateBackgroundWriteFn = *const fn (element_id_raw: u32, c: Color) void;
pub const PaintStateOpacityWriteFn = *const fn (element_id_raw: u32, o: f32) void;
pub const PaintStateBackgroundReadFn = *const fn (element_id_raw: u32) ?Color;
pub const PaintStateOpacityReadFn = *const fn (element_id_raw: u32) ?f32;

var g_paint_bg_write: ?PaintStateBackgroundWriteFn = null;
var g_paint_opacity_write: ?PaintStateOpacityWriteFn = null;
var g_paint_bg_read: ?PaintStateBackgroundReadFn = null;
var g_paint_opacity_read: ?PaintStateOpacityReadFn = null;

pub fn setPaintBackgroundWriteCallback(cb: ?PaintStateBackgroundWriteFn) void {
    g_paint_bg_write = cb;
}
pub fn setPaintOpacityWriteCallback(cb: ?PaintStateOpacityWriteFn) void {
    g_paint_opacity_write = cb;
}
pub fn setPaintBackgroundReadCallback(cb: ?PaintStateBackgroundReadFn) void {
    g_paint_bg_read = cb;
}
pub fn setPaintOpacityReadCallback(cb: ?PaintStateOpacityReadFn) void {
    g_paint_opacity_read = cb;
}

// Non-degradable: these maps are the **sole authoritative storage** for fallback
// node paint/content (writes in, reads out). A put failure silently discards written
// styles/text and reads get defaults, so nodes render wrong without error.
// Therefore OOM always panics. Standalone fallback for non-cx mock tests
// (element_id == 0xFFFFFFFF). Paint state is simpler than content: Color/f32
// are POD with no inline_buf self-reference issues; hashmap rehash needs no
// re-fixup.
var g_standalone_paint_bg: std.AutoHashMap(usize, Color) = undefined;
var g_standalone_paint_opacity: std.AutoHashMap(usize, f32) = undefined;
var g_standalone_paint_init: bool = false;

fn ensureStandalonePaintInit() void {
    if (g_standalone_paint_init) return;
    g_standalone_paint_bg = std.AutoHashMap(usize, Color).init(std.heap.page_allocator);
    g_standalone_paint_opacity = std.AutoHashMap(usize, f32).init(std.heap.page_allocator);
    g_standalone_paint_init = true;
}

/// Side-effect-free background write routing: element_id!=0xFFFFFFFF uses World
/// callback; mock nodes fall through to standalone fallback by node ptr.
pub fn writeBackground(world_ref: ?*world_mod.World, element_id_raw: u32, node_ptr: usize, color: Color) void {
    // P0-3 phase 3: prefer direct owner World connection; degrade to old global
    // callbacks only for cx-less mocks.
    if (element_id_raw != 0xFFFFFFFF) {
        if (world_ref) |w| {
            const eid = world_mod.ElementId.fromRaw(element_id_raw);
            if (w.paint_state.ensureSlot(eid)) |_| {
                w.paint_state.setBackground(eid, color);
                return;
            } else |_| {}
        } else if (g_paint_bg_write) |cb| {
            legacy_callback_hits += 1;
            cb(element_id_raw, color);
            return;
        }
    }
    ensureStandalonePaintInit();
    g_standalone_paint_bg.put(node_ptr, color) catch @panic("OOM: standalone paint background store");
}

pub fn writeOpacity(world_ref: ?*world_mod.World, element_id_raw: u32, node_ptr: usize, value: f32) void {
    if (element_id_raw != 0xFFFFFFFF) {
        if (world_ref) |w| {
            const eid = world_mod.ElementId.fromRaw(element_id_raw);
            if (w.paint_state.ensureSlot(eid)) |_| {
                w.paint_state.setOpacity(eid, value);
                return;
            } else |_| {}
        } else if (g_paint_opacity_write) |cb| {
            legacy_callback_hits += 1;
            cb(element_id_raw, value);
            return;
        }
    }
    ensureStandalonePaintInit();
    g_standalone_paint_opacity.put(node_ptr, value) catch @panic("OOM: standalone paint opacity store");
}

/// Background read routing: World callback -> standalone fallback -> default
/// TRANSPARENT.
pub fn readBackground(world_ref: ?*world_mod.World, element_id_raw: u32, node_ptr: usize) Color {
    if (element_id_raw != 0xFFFFFFFF) {
        if (world_ref) |w| {
            const eid = world_mod.ElementId.fromRaw(element_id_raw);
            if (w.paint_state.get(eid)) |ps| return ps.background;
        } else if (g_paint_bg_read) |cb| {
            legacy_callback_hits += 1;
            if (cb(element_id_raw)) |c| return c;
        }
    }
    if (!g_standalone_paint_init) return Color.TRANSPARENT;
    return g_standalone_paint_bg.get(node_ptr) orelse Color.TRANSPARENT;
}

pub fn readOpacity(world_ref: ?*world_mod.World, element_id_raw: u32, node_ptr: usize) f32 {
    if (element_id_raw != 0xFFFFFFFF) {
        if (world_ref) |w| {
            const eid = world_mod.ElementId.fromRaw(element_id_raw);
            if (w.paint_state.get(eid)) |ps| return ps.opacity;
        } else if (g_paint_opacity_read) |cb| {
            legacy_callback_hits += 1;
            if (cb(element_id_raw)) |o| return o;
        }
    }
    if (!g_standalone_paint_init) return 1.0;
    return g_standalone_paint_opacity.get(node_ptr) orelse 1.0;
}

// ─────────────────────────────────────────────────────────────────────
// §a NodeContent SoA, write/read callback + standalone fallback
// ─────────────────────────────────────────────────────────────────────

pub const ContentTextWriteFn = *const fn (element_id_raw: u32, t: ?TextProps) void;
pub const ContentImageWriteFn = *const fn (element_id_raw: u32, img: ?ImageProps) void;
pub const ContentIconWriteFn = *const fn (element_id_raw: u32, ic: ?IconProps) void;
pub const ContentTextReadFn = *const fn (element_id_raw: u32) ?TextProps;
pub const ContentImageReadFn = *const fn (element_id_raw: u32) ?ImageProps;
pub const ContentIconReadFn = *const fn (element_id_raw: u32) ?IconProps;

var g_content_text_write: ?ContentTextWriteFn = null;
var g_content_image_write: ?ContentImageWriteFn = null;
var g_content_icon_write: ?ContentIconWriteFn = null;
var g_content_text_read: ?ContentTextReadFn = null;
var g_content_image_read: ?ContentImageReadFn = null;
var g_content_icon_read: ?ContentIconReadFn = null;

pub fn setContentTextWriteCallback(cb: ?ContentTextWriteFn) void {
    g_content_text_write = cb;
}
pub fn setContentImageWriteCallback(cb: ?ContentImageWriteFn) void {
    g_content_image_write = cb;
}
pub fn setContentIconWriteCallback(cb: ?ContentIconWriteFn) void {
    g_content_icon_write = cb;
}
pub fn setContentTextReadCallback(cb: ?ContentTextReadFn) void {
    g_content_text_read = cb;
}
pub fn setContentImageReadCallback(cb: ?ContentImageReadFn) void {
    g_content_image_read = cb;
}
pub fn setContentIconReadCallback(cb: ?ContentIconReadFn) void {
    g_content_icon_read = cb;
}

var g_standalone_content_text: std.AutoHashMap(usize, TextProps) = undefined;
var g_standalone_content_image: std.AutoHashMap(usize, ImageProps) = undefined;
var g_standalone_content_icon: std.AutoHashMap(usize, IconProps) = undefined;
var g_standalone_content_init: bool = false;

fn ensureStandaloneContentInit() void {
    if (g_standalone_content_init) return;
    g_standalone_content_text = std.AutoHashMap(usize, TextProps).init(std.heap.page_allocator);
    g_standalone_content_image = std.AutoHashMap(usize, ImageProps).init(std.heap.page_allocator);
    g_standalone_content_icon = std.AutoHashMap(usize, IconProps).init(std.heap.page_allocator);
    g_standalone_content_init = true;
}

fn standaloneSetText(node_ptr: usize, t: ?TextProps) void {
    ensureStandaloneContentInit();
    if (t) |val| {
        g_standalone_content_text.put(node_ptr, val) catch @panic("OOM: standalone content text store");
        // hashmap put may rehash and move entry; re-fixup entire table.
        var it = g_standalone_content_text.iterator();
        while (it.next()) |e| {
            if (e.value_ptr.inline_len > 0) {
                if (e.value_ptr.content.len == e.value_ptr.inline_len) {
                    if (std.mem.eql(u8, e.value_ptr.content, e.value_ptr.inline_buf[0..e.value_ptr.inline_len])) {
                        e.value_ptr.content = e.value_ptr.inline_buf[0..e.value_ptr.inline_len];
                    }
                }
            }
        }
    } else {
        _ = g_standalone_content_text.remove(node_ptr);
    }
}

/// Text write routing: element_id!=0xFFFFFFFF uses World callback; mock falls
/// through to standalone (including inline_buf self-reference re-fixup).
pub fn writeText(world_ref: ?*world_mod.World, element_id_raw: u32, node_ptr: usize, t: ?TextProps) void {
    if (element_id_raw != 0xFFFFFFFF) {
        if (world_ref) |w| {
            const eid = world_mod.ElementId.fromRaw(element_id_raw);
            if (w.content.ensureSlot(eid)) |_| {
                w.content.setText(eid, t);
                return;
            } else |_| {}
        } else if (g_content_text_write) |cb| {
            legacy_callback_hits += 1;
            cb(element_id_raw, t);
            return;
        }
    }
    standaloneSetText(node_ptr, t);
}

pub fn writeImage(world_ref: ?*world_mod.World, element_id_raw: u32, node_ptr: usize, img: ?ImageProps) void {
    if (element_id_raw != 0xFFFFFFFF) {
        if (world_ref) |w| {
            const eid = world_mod.ElementId.fromRaw(element_id_raw);
            if (w.content.ensureSlot(eid)) |_| {
                w.content.setImage(eid, img);
                return;
            } else |_| {}
        } else if (g_content_image_write) |cb| {
            legacy_callback_hits += 1;
            cb(element_id_raw, img);
            return;
        }
    }
    ensureStandaloneContentInit();
    if (img) |val| {
        g_standalone_content_image.put(node_ptr, val) catch @panic("OOM: standalone content image store");
    } else {
        _ = g_standalone_content_image.remove(node_ptr);
    }
}

pub fn writeIcon(world_ref: ?*world_mod.World, element_id_raw: u32, node_ptr: usize, ic: ?IconProps) void {
    if (element_id_raw != 0xFFFFFFFF) {
        if (world_ref) |w| {
            const eid = world_mod.ElementId.fromRaw(element_id_raw);
            if (w.content.ensureSlot(eid)) |_| {
                w.content.setIcon(eid, ic);
                return;
            } else |_| {}
        } else if (g_content_icon_write) |cb| {
            legacy_callback_hits += 1;
            cb(element_id_raw, ic);
            return;
        }
    }
    ensureStandaloneContentInit();
    if (ic) |val| {
        g_standalone_content_icon.put(node_ptr, val) catch @panic("OOM: standalone content icon store");
    } else {
        _ = g_standalone_content_icon.remove(node_ptr);
    }
}

pub fn readText(world_ref: ?*world_mod.World, element_id_raw: u32, node_ptr: usize) ?TextProps {
    if (element_id_raw != 0xFFFFFFFF) {
        if (world_ref) |w| {
            return w.content.getText(world_mod.ElementId.fromRaw(element_id_raw));
        } else if (g_content_text_read) |cb| return cb(element_id_raw);
    }
    if (!g_standalone_content_init) return null;
    return g_standalone_content_text.get(node_ptr);
}

pub fn readImage(world_ref: ?*world_mod.World, element_id_raw: u32, node_ptr: usize) ?ImageProps {
    if (element_id_raw != 0xFFFFFFFF) {
        if (world_ref) |w| {
            if (w.content.getPtr(world_mod.ElementId.fromRaw(element_id_raw))) |c| return c.image;
            return null;
        } else if (g_content_image_read) |cb| return cb(element_id_raw);
    }
    if (!g_standalone_content_init) return null;
    return g_standalone_content_image.get(node_ptr);
}

pub fn readIcon(world_ref: ?*world_mod.World, element_id_raw: u32, node_ptr: usize) ?IconProps {
    if (element_id_raw != 0xFFFFFFFF) {
        if (world_ref) |w| {
            if (w.content.getPtr(world_mod.ElementId.fromRaw(element_id_raw))) |c| return c.icon;
            return null;
        } else if (g_content_icon_read) |cb| return cb(element_id_raw);
    }
    if (!g_standalone_content_init) return null;
    return g_standalone_content_icon.get(node_ptr);
}

// ---------------------------------------------------------------------------
// NodeLayoutOutput SoA, write/read/ptr callback + standalone fallback
// ---------------------------------------------------------------------------
//
// layout_output is used only in render/hit paths. Production callers are cx-backed
// (valid element_id) and use World.LayoutOutputTable. hit_runtime and tests use
// cx-less Node.create + setPathHitGeometry (element_id==0xFFFFFFFF) and need a
// standalone fallback.
//
// layoutOutputPtr requires a stable address (owner methods modify child fields
// in place, display_list pointers escape). AutoHashMap value addresses move on
// rehash, so standalone stores *NodeLayoutOutput (heap pool, stable address) and
// the map holds only pointers. Path geometry is freed by Node.releaseAllGeometry
// on freeNode; entries are not reclaimed (cx-less mocks are short-lived).

pub const LayoutOutputWriteFn = *const fn (element_id_raw: u32, v: NodeLayoutOutput) void;
pub const LayoutOutputReadFn = *const fn (element_id_raw: u32) ?NodeLayoutOutput;
pub const LayoutOutputPtrFn = *const fn (element_id_raw: u32) ?*NodeLayoutOutput;

var g_layout_output_write: ?LayoutOutputWriteFn = null;
var g_layout_output_read: ?LayoutOutputReadFn = null;
var g_layout_output_ptr: ?LayoutOutputPtrFn = null;

pub fn setLayoutOutputWriteCallback(cb: ?LayoutOutputWriteFn) void {
    g_layout_output_write = cb;
}
pub fn setLayoutOutputReadCallback(cb: ?LayoutOutputReadFn) void {
    g_layout_output_read = cb;
}
pub fn setLayoutOutputPtrCallback(cb: ?LayoutOutputPtrFn) void {
    g_layout_output_ptr = cb;
}

var g_standalone_layout_output: std.AutoHashMap(usize, *NodeLayoutOutput) = undefined;
var g_standalone_layout_output_init: bool = false;

fn ensureStandaloneLayoutOutputInit() void {
    if (g_standalone_layout_output_init) return;
    g_standalone_layout_output = std.AutoHashMap(usize, *NodeLayoutOutput).init(std.heap.page_allocator);
    g_standalone_layout_output_init = true;
}

/// Stable layout_output slot for cx-less mock nodes (heap pool, permanently
/// stable address).
fn standaloneLayoutOutputPtr(node_ptr: usize) ?*NodeLayoutOutput {
    ensureStandaloneLayoutOutputInit();
    if (g_standalone_layout_output.get(node_ptr)) |p| return p;
    const slot = std.heap.page_allocator.create(NodeLayoutOutput) catch return null;
    slot.* = .{};
    g_standalone_layout_output.put(node_ptr, slot) catch {
        std.heap.page_allocator.destroy(slot);
        return null;
    };
    return slot;
}

pub fn layoutOutputPtr(world_ref: ?*world_mod.World, element_id_raw: u32, node_ptr: usize) ?*NodeLayoutOutput {
    if (element_id_raw != 0xFFFFFFFF) {
        if (world_ref) |w| {
            const eid = world_mod.ElementId.fromRaw(element_id_raw);
            return w.layout_output.getPtr(eid);
        }
        if (g_layout_output_ptr) |cb| return cb(element_id_raw);
        return null;
    }
    return standaloneLayoutOutputPtr(node_ptr);
}

/// Read-only view of a node's layout output, or null before it has one
/// (callers treat null as the default `.{}`). Never allocates. Read paths that
/// run per node per frame use this rather than copying the output header.
/// Fixed-address chunk borrows survive growth, but not clear/reuse/teardown.
pub fn layoutOutputConstPtr(world_ref: ?*world_mod.World, element_id_raw: u32, node_ptr: usize) ?*const NodeLayoutOutput {
    if (element_id_raw != 0xFFFFFFFF) {
        if (world_ref) |w| return w.layout_output.getConstPtr(world_mod.ElementId.fromRaw(element_id_raw));
        if (g_layout_output_ptr) |cb| return cb(element_id_raw);
        return null;
    }
    if (!g_standalone_layout_output_init) return null;
    return g_standalone_layout_output.get(node_ptr);
}

pub fn writeLayoutOutput(world_ref: ?*world_mod.World, element_id_raw: u32, node_ptr: usize, v: NodeLayoutOutput) void {
    if (element_id_raw != 0xFFFFFFFF) {
        if (world_ref) |w| {
            const eid = world_mod.ElementId.fromRaw(element_id_raw);
            // Only World.createElement may establish a generation. A late
            // write from a freed node must not resurrect its old slot.
            w.layout_output.set(eid, v) catch return;
            return;
        }
        if (g_layout_output_write) |cb| cb(element_id_raw, v);
        return;
    }
    if (standaloneLayoutOutputPtr(node_ptr)) |p| {
        if (v.artifacts.text_layout) |text| {
            storeTextLayout(null, element_id_raw, node_ptr, text) catch return;
        } else clearTextLayout(null, element_id_raw, node_ptr);
        const owned_text = p.artifacts.text_layout;
        p.* = v;
        p.artifacts.text_layout = owned_text;
    }
}

/// Layout cache writes are fallible and transactional. The mock fallback owns
/// one stable allocation per actual text node; production uses chunked storage.
pub fn storeTextLayout(world_ref: ?*world_mod.World, element_id_raw: u32, node_ptr: usize, value: *const @import("text_layout.zig").TextLayout) !void {
    if (world_ref) |w| return w.layout_output.storeTextLayout(world_mod.ElementId.fromRaw(element_id_raw), value);
    const p = standaloneLayoutOutputPtr(node_ptr) orelse return error.OutOfMemory;
    const target = if (p.artifacts.text_layout) |text| @constCast(text) else try std.heap.page_allocator.create(@import("text_layout.zig").TextLayout);
    target.* = value.*;
    p.artifacts.text_layout = target;
}
pub fn clearTextLayout(world_ref: ?*world_mod.World, element_id_raw: u32, node_ptr: usize) void {
    if (world_ref) |w| return w.layout_output.clearTextLayout(world_mod.ElementId.fromRaw(element_id_raw));
    if (!g_standalone_layout_output_init) return;
    const p = g_standalone_layout_output.get(node_ptr) orelse return;
    if (p.artifacts.text_layout) |text| std.heap.page_allocator.destroy(text);
    p.artifacts.text_layout = null;
}

/// Node.destroy must not leave a mock's text payload pinned until process
/// teardown, nor let a later node at the same address inherit its output.
pub fn releaseStandaloneLayoutOutput(node_ptr: usize) void {
    if (!g_standalone_layout_output_init) return;
    const entry = g_standalone_layout_output.fetchRemove(node_ptr) orelse return;
    if (entry.value.artifacts.text_layout) |text| std.heap.page_allocator.destroy(text);
    std.heap.page_allocator.destroy(entry.value);
}

/// Remove all pointer-keyed fallback records after the node has released owned
/// content/geometry. A later allocation at the same address is a new owner.
pub fn releaseStandaloneNode(node_ptr: usize) void {
    releaseStandaloneLayoutOutput(node_ptr);
    if (g_standalone_paint_init) {
        _ = g_standalone_paint_bg.remove(node_ptr);
        _ = g_standalone_paint_opacity.remove(node_ptr);
    }
    if (g_standalone_content_init) {
        _ = g_standalone_content_text.remove(node_ptr);
        _ = g_standalone_content_image.remove(node_ptr);
        _ = g_standalone_content_icon.remove(node_ptr);
    }
}

pub fn readLayoutOutput(world_ref: ?*world_mod.World, element_id_raw: u32, node_ptr: usize) NodeLayoutOutput {
    if (element_id_raw != 0xFFFFFFFF) {
        if (world_ref) |w| {
            if (w.layout_output.get(world_mod.ElementId.fromRaw(element_id_raw))) |v| return v;
            return .{};
        }
        if (g_layout_output_read) |cb| {
            if (cb(element_id_raw)) |v| return v;
        }
        return .{};
    }
    if (standaloneLayoutOutputPtr(node_ptr)) |p| return p.*;
    return .{};
}

// ---------------------------------------------------------------------------
// Explicit cleanup of standalone fallback storage
//
// These tables are process-level, use page_allocator and have no implicit teardown,
// so the GPA leak check in `zig build test` cannot see them: all-green does not
// mean this path is leak-free.
//
// They only serve cx-less test mocks (bare Node with element_id == INVALID);
// production never hits them. Explicit cleanup lets tests/tools tear down and
// assert "no leaks left".
// ---------------------------------------------------------------------------

/// Current entry count in standalone fallback table (diagnostic/acceptance use).
pub fn standaloneEntryCount() usize {
    var n: usize = 0;
    if (g_standalone_paint_init) {
        n += g_standalone_paint_bg.count();
        n += g_standalone_paint_opacity.count();
    }
    if (g_standalone_content_init) {
        n += g_standalone_content_text.count();
        n += g_standalone_content_image.count();
        n += g_standalone_content_icon.count();
    }
    if (g_standalone_layout_output_init) n += g_standalone_layout_output.count();
    return n;
}

/// Free all standalone fallback storage. Called at process/test shutdown.
/// Idempotent: safe to call repeatedly; subsequent use reinitializes on-demand.
pub fn deinitStandaloneStorage() void {
    if (g_standalone_paint_init) {
        g_standalone_paint_bg.deinit();
        g_standalone_paint_opacity.deinit();
        g_standalone_paint_init = false;
    }
    if (g_standalone_content_init) {
        g_standalone_content_text.deinit();
        g_standalone_content_image.deinit();
        g_standalone_content_icon.deinit();
        g_standalone_content_init = false;
    }
    if (g_standalone_layout_output_init) {
        // Value is raw pointer from page_allocator.create; must destroy individually,
        // otherwise freeing the map alone leaks each NodeLayoutOutput.
        var it = g_standalone_layout_output.valueIterator();
        while (it.next()) |slot_ptr| {
            if (slot_ptr.*.artifacts.text_layout) |text| std.heap.page_allocator.destroy(text);
            std.heap.page_allocator.destroy(slot_ptr.*);
        }
        g_standalone_layout_output.deinit();
        g_standalone_layout_output_init = false;
    }
}
