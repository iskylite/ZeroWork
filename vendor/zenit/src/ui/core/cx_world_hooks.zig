//! Process-level Node -> World router hooks: Node content/paint/layout-output/rect
//! read/write and dirty/structure notifications routed here to active World (SoA table).
//! Cx.init registers these callbacks and maintains g_active_world*; when multiple Cx coexist
//! use Cx.createNode to explicitly affiliate, independent of globals here.

const core = @import("../core.zig");
const Cx = core.Cx;
const ComputedRect = core.ComputedRect;
const ElementTag = core.ElementTag;
const Node = core.Node;
const Style = core.Style;
const core_node = @import("node.zig");
const core_types = @import("types.zig");
const cx_world_sync = @import("cx_world_sync.zig");
const layout_table = core.layout_table;
const world = core.world;

/// Active World (v0.2-P3 global static; v0.3 per-Cx)
pub var g_active_world: ?*world.World = null;

/// Active World id, synced with g_active_world;
/// onNodeCreate uses it to stamp Node.world_id.
pub var g_active_world_id: u16 = core_node.INVALID_WORLD_ID;

/// Monotonically incrementing World id allocator. Each Cx gets unique id (never reuse;
/// reuse lets stale Node from freed Cx falsely match new Cx, exactly the problem this prevents).
pub var g_next_world_id: u16 = 0;

pub fn onPaintBackgroundWrite(element_id_raw: u32, c: core_types.Color) void {
    const w = g_active_world orelse return;
    if (element_id_raw == 0xFFFFFFFF) return;
    const eid = world.ElementId.fromRaw(element_id_raw);
    w.paint_state.ensureSlot(eid) catch return;
    w.paint_state.setBackground(eid, c);
}

pub fn onPaintOpacityWrite(element_id_raw: u32, o: f32) void {
    const w = g_active_world orelse return;
    if (element_id_raw == 0xFFFFFFFF) return;
    const eid = world.ElementId.fromRaw(element_id_raw);
    w.paint_state.ensureSlot(eid) catch return;
    w.paint_state.setOpacity(eid, o);
}

pub fn onPaintBackgroundRead(element_id_raw: u32) ?core_types.Color {
    const w = g_active_world orelse return null;
    if (element_id_raw == 0xFFFFFFFF) return null;
    const eid = world.ElementId.fromRaw(element_id_raw);
    return (w.paint_state.get(eid) orelse return null).background;
}

pub fn onPaintOpacityRead(element_id_raw: u32) ?f32 {
    const w = g_active_world orelse return null;
    if (element_id_raw == 0xFFFFFFFF) return null;
    const eid = world.ElementId.fromRaw(element_id_raw);
    return (w.paint_state.get(eid) orelse return null).opacity;
}

/// Mirror Node.setLayoutOutput write to World.layout_output.
pub fn onLayoutOutputWrite(element_id_raw: u32, v: core_node.NodeLayoutOutput) void {
    const w = g_active_world orelse return;
    if (element_id_raw == 0xFFFFFFFF) return;
    const eid = world.ElementId.fromRaw(element_id_raw);
    w.layout_output.set(eid, v) catch return;
}

pub fn onLayoutOutputRead(element_id_raw: u32) ?core_node.NodeLayoutOutput {
    const w = g_active_world orelse return null;
    if (element_id_raw == 0xFFFFFFFF) return null;
    const eid = world.ElementId.fromRaw(element_id_raw);
    return w.layout_output.get(eid);
}

pub fn onLayoutOutputPtr(element_id_raw: u32) ?*core_node.NodeLayoutOutput {
    const w = g_active_world orelse return null;
    if (element_id_raw == 0xFFFFFFFF) return null;
    const eid = world.ElementId.fromRaw(element_id_raw);
    return w.layout_output.getPtr(eid);
}

/// Mirror Node.setText write to World.content (ContentTable).
/// element_id_raw == 0xFFFFFFFF standalone Node not yet mirrored (fallback stage 2).
pub fn onContentTextWrite(element_id_raw: u32, t: ?core_types.TextProps) void {
    const w = g_active_world orelse return;
    if (element_id_raw == 0xFFFFFFFF) return;
    const eid = world.ElementId.fromRaw(element_id_raw);
    w.content.ensureSlot(eid) catch return;
    w.content.setText(eid, t);
}

pub fn onContentImageWrite(element_id_raw: u32, img: ?core_types.ImageProps) void {
    const w = g_active_world orelse return;
    if (element_id_raw == 0xFFFFFFFF) return;
    const eid = world.ElementId.fromRaw(element_id_raw);
    w.content.ensureSlot(eid) catch return;
    w.content.setImage(eid, img);
}

pub fn onContentIconWrite(element_id_raw: u32, ic: ?core_types.IconProps) void {
    const w = g_active_world orelse return;
    if (element_id_raw == 0xFFFFFFFF) return;
    const eid = world.ElementId.fromRaw(element_id_raw);
    w.content.ensureSlot(eid) catch return;
    w.content.setIcon(eid, ic);
}

// Read side: Node.getText/getImage/getIcon pull value from World.content.
pub fn onContentTextRead(element_id_raw: u32) ?core_types.TextProps {
    const w = g_active_world orelse return null;
    if (element_id_raw == 0xFFFFFFFF) return null;
    const eid = world.ElementId.fromRaw(element_id_raw);
    return w.content.getText(eid);
}

pub fn onContentImageRead(element_id_raw: u32) ?core_types.ImageProps {
    const w = g_active_world orelse return null;
    if (element_id_raw == 0xFFFFFFFF) return null;
    const eid = world.ElementId.fromRaw(element_id_raw);
    if (w.content.get(eid)) |c| return c.image;
    return null;
}

pub fn onContentIconRead(element_id_raw: u32) ?core_types.IconProps {
    const w = g_active_world orelse return null;
    if (element_id_raw == 0xFFFFFFFF) return null;
    const eid = world.ElementId.fromRaw(element_id_raw);
    if (w.content.get(eid)) |c| return c.icon;
    return null;
}

/// v0.5-P3 N-2 (2026-05-03): Node.create hook, auto-register new node to active World.
/// All Node.create paths (including test mock) now have element_id;
/// setLayoutRect truly writes World, frame_state.rect fallback never consumed.
pub fn onNodeCreate(node: *Node) void {
    const w = g_active_world orelse return;
    if (node.element_id_raw != 0xFFFFFFFF) return;
    const eid = w.createElement(.{
        .tag = cx_world_sync.nodeTagToWorldTag(node.tag),
        .key = node.id,
    }) catch return;
    node.element_id_raw = eid.raw();
    // Also record owner, element_id itself lacks World marker (both Worlds allocate from
    // index 0); only this field distinguishes 'window A 0x8' vs 'window B 0x8'.
    node.world_id = g_active_world_id;
    node.world_ref = w;
}

/// Component paint-phase setLayoutRect World sync.
/// Write LayoutTable so 'self-mutating rect' children (cursor/selection/etc) also
/// transparently use World table, read-path hits World not fallback.
pub fn onRectWrite(element_id_raw: u32, r: ComputedRect) void {
    const w = g_active_world orelse return;
    if (element_id_raw == 0xFFFFFFFF) return;
    const eid = world.ElementId.fromRaw(element_id_raw);
    w.layout.ensureSlot(eid) catch return;
    const lr: layout_table.Rect = .{ .x = r.x, .y = r.y, .width = r.w, .height = r.h };
    w.layout.markLaidOut(eid, .{ .width = r.w, .height = r.h }, lr);
}

/// v0.5-P3 Stage 4-2 (session 27): global rect query, for functions without cx.
pub fn onRectQuery(element_id_raw: u32) ?ComputedRect {
    const w = g_active_world orelse return null;
    if (element_id_raw == 0xFFFFFFFF) return null;
    const eid = world.ElementId.fromRaw(element_id_raw);
    // Stage 4-2 critical: World.createElement auto-seeds layout slot (default all 0),
    // so layout.rect() almost always returns Some. Must use epoch == 0 to detect 'slot
    // exists but not markLaidOut yet', fall back to node.rect. Else manual `node.rect =`
    // tests + Stage 4-2 switch read zero.
    if (w.layout.epoch(eid) == 0) return null;
    if (w.layout.rect(eid)) |r| {
        return ComputedRect.init(r.x, r.y, r.width, r.height);
    }
    return null;
}

pub fn createNode(self: *Cx, tag: ElementTag, style: Style) !*Node {
    return core_node.createIn(self.allocator, &self.world, self.world_id, self.nextId(), tag, style);
}

pub fn nodeBelongsToActiveWorldForTest(node: *const Node) bool {
    return nodeBelongsToActiveWorld(node);
}

/// Validate: node belongs to active World.
/// Return false means **cross-Cx wire crossing**, taking node from Window A to mutate Window B
/// World.
/// world_id == INVALID node is cx-less mock (test direct Node.create);
/// they use standalone fallback anyway, not World routing, pass through.
pub fn nodeBelongsToActiveWorld(node: *const Node) bool {
    if (node.world_id == core_node.INVALID_WORLD_ID) return true;
    return node.world_id == g_active_world_id;
}

pub fn onNodeDirty(element_id_raw: u32, kind: core_node.DirtyKind) void {
    const w = g_active_world orelse return;
    if (element_id_raw == 0xFFFFFFFF) return;
    const eid = world.ElementId.fromRaw(element_id_raw);
    const flags: world.DirtyFlags = switch (kind) {
        .layout => .{ .input = .{ .geometry_changed = true } },
        .style => .{ .input = .{ .style_changed = true } },
        .structure => .{ .input = .{ .structure_changed = true } },
        .interaction => .{ .input = .{ .interaction_changed = true } },
    };
    w.markDirty(eid, flags) catch {}; // OOM tolerance - dirty lost one frame, still follows old path
}

/// Node.appendChild / unlink sync World.elements parent-child list.
/// Either endpoint element_id_raw == 0xFFFFFFFF = old-path node, hook return (old path continues).
pub fn onNodeStructure(parent_raw: u32, child_raw: u32, kind: core_node.StructureKind) void {
    const w = g_active_world orelse return;
    if (parent_raw == 0xFFFFFFFF or child_raw == 0xFFFFFFFF) return;
    const parent_eid = world.ElementId.fromRaw(parent_raw);
    const child_eid = world.ElementId.fromRaw(child_raw);
    if (!w.elements.isValid(parent_eid) or !w.elements.isValid(child_eid)) return;
    switch (kind) {
        .append => {
            // If child already has parent (reparent), unlink first.
            const existing = w.elements.links(child_eid) orelse return;
            if (!existing.parent.isNull()) w.elements.unlink(child_eid);
            w.elements.appendChild(parent_eid, child_eid);
        },
        .unlink => w.elements.unlink(child_eid),
    }
}
