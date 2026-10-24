//! Cx -> World table sync: node hook into World (ElementTag mapping), layerize,
//! layout / paint / interaction 3-table per-frame sync, layout shadow-sync completeness audit.

const std = @import("std");
const core = @import("../core.zig");
const Cx = core.Cx;
const ComputedRect = core.ComputedRect;
const ElementTag = core.ElementTag;
const Node = core.Node;
const interaction_table = core.interaction_table;
const layerize_mod = core.layerize_mod;
const paint_table = core.paint_table;
const render_engine = core.render_engine;
const world = core.world;

/// Node.tag (UI side) -> ElementTable.ElementTag (SoA side) mapping.
/// Two enums uncoupled: UI side component-level (box/button/scroll/list/...),
/// SoA side render categories (container/text/image/input/component/...).
pub fn nodeTagToWorldTag(t: ElementTag) world.ElementTag {
    return switch (t) {
        .box, .scroll, .list, .spacer, .anchor => .container,
        .text => .text,
        .image => .image,
        .input, .button => .input,
        .custom => .component,
    };
}

pub fn linkNodeToWorld(self: *Cx, node: *Node) void {
    if (node.element_id_raw != 0xFFFFFFFF) return; // Already registered, idempotent
    const eid = self.world.createElement(.{
        .tag = nodeTagToWorldTag(node.tag),
        .key = node.id,
    }) catch return;
    node.element_id_raw = eid.raw();
}

/// Frame start: layerize, group World.elements into LayerTree.
/// Returns layer count (includes root).
///
/// Auto-collects PromotionHint from World.interaction; scroll containers
/// are auto-promoted to their own layer. No caller hints needed.
/// PaintTable.bounds primary + LayoutTable.rect fallback.
fn paintChunkBoundsOrLayoutFallback(w: *world.World, eid: world.ElementId) paint_table.Bounds {
    if (w.paint.get(eid)) |chunk| {
        if (!chunk.bounds.isEmpty()) return chunk.bounds;
    }
    if (w.layout.rect(eid)) |r| {
        return paint_table.Bounds{
            .min_x = r.x,
            .min_y = r.y,
            .max_x = r.x + r.width,
            .max_y = r.y + r.height,
        };
    }
    return paint_table.Bounds{};
}

pub fn layerizeFrame(self: *Cx, extra_hints: []const layerize_mod.LayerizeInput) u32 {
    ensureWorldTablesSynced(self);
    // Frame start: clear layer damage state
    self.layer_tree.beginFrame();

    // Auto-collect promotion hints from InteractionTable (scroll containers etc)
    var collected = @as(std.ArrayList(layerize_mod.LayerizeInput), .empty);
    defer collected.deinit(self.allocator);

    var iter = self.world.interaction.data.iterator();
    while (iter.next()) |entry| {
        const eid = world.ElementId.fromRaw(entry.key_ptr.*);
        const data = entry.value_ptr.*;
        // scroll_id valid -> promotion hint = scroll container
        if (data.scroll_id != std.math.maxInt(u32)) {
            // Take chunk bounds from PaintTable (shadow-sync ready).
            const bounds = paintChunkBoundsOrLayoutFallback(&self.world, eid);
            collected.append(self.allocator, .{
                .element = eid,
                .hint = .{ .is_scroll_container = true },
                .world_bounds = bounds,
            }) catch continue;
        }
    }

    // v0.5-P3 Stage 3-3 Phase 4 (session 38): also promote elements with non-root effect via
    // PaintChunk.property_state.effect_id (opacity layer / backdrop_blur etc).
    // Stage 5 deletes deferred file key dependency: layerize no longer listens to InteractionTable
    // alone,
    // truly consumes PaintTable 4-table SoT.
    for (self.world.paint.chunks.items, 0..) |chunk, idx| {
        const effect_id = chunk.property_state.effect_id;
        if (effect_id == std.math.maxInt(u32)) continue;
        if (effect_id >= self.property_tree.effects.items.len) continue;
        const effect = self.property_tree.effects.items[effect_id];
        // Only promote effects truly needing offscreen (opacity layer / backdrop blur)
        if (!effect.requires_offscreen) continue;

        const eid_idx: u24 = @intCast(idx);
        const eid: world.ElementId = .{
            .index = eid_idx,
            .generation = self.world.elements.generations.items[eid_idx],
        };
        // Skip already added by scroll_id, prevent duplicate
        var already_collected = false;
        for (collected.items) |c| {
            if (c.element.eql(eid)) {
                already_collected = true;
                break;
            }
        }
        if (already_collected) continue;

        const hint: layerize_mod.PromotionHint = switch (effect.kind) {
            .opacity, .composited_group => .{ .opacity_animating = true },
            .backdrop_blur => .{ .has_filter = true },
            else => layerize_mod.PromotionHint.NONE,
        };
        if (!hint.shouldPromote() and !hint.has_filter) continue;

        collected.append(self.allocator, .{
            .element = eid,
            .hint = hint,
            .world_bounds = paintChunkBoundsOrLayoutFallback(&self.world, eid),
        }) catch break;
    }
    // Append caller's explicit hints
    for (extra_hints) |h| collected.append(self.allocator, h) catch break;

    layerize_mod.layerize(&self.layer_tree, collected.items) catch return 0;
    return self.layer_tree.liveLayerCount();
}

/// See `Cx.syncLayoutToTable`. Flip to true to restore the old defensive walk.
const walk_layout_tree_each_frame = false;

pub fn syncLayoutToTable(self: *Cx, root: *Node) void {
    if (comptime walk_layout_tree_each_frame) syncLayoutNodeRecursive(self, root);
}

pub fn syncNodeRect(self: *Cx, node: *Node) void {
    if (node.element_id_raw == 0xFFFFFFFF) return;
    const eid = world.ElementId.fromRaw(node.element_id_raw);
    self.world.layout.ensureSlot(eid) catch return;
}

fn syncLayoutNodeRecursive(self: *Cx, node: *Node) void {
    self.syncNodeRect(node);
    for (node.children.items) |child| syncLayoutNodeRecursive(self, child);
}

/// Mirror the last rendered frame into World.paint and World.interaction if a
/// render happened since the previous mirror.
///
/// Both tables were rebuilt at the end of every `Cx.render`, a full-tree walk
/// that hashed each node's paint content and probed two hash maps per node, yet
/// nothing in rendering, hit testing or event dispatch reads them: their readers
/// are `layerizeFrame`, the sampled layout integrity audit and tests. In a Debug
/// build of a ~700-node Markdown editor the walk was about a sixth of every
/// scroll frame. Readers call this instead (the same lazy pattern as the a11y
/// projection). The mirror reads the display list and scene runtime of the last
/// render, which stay intact until the next one begins.
pub fn ensureWorldTablesSynced(self: *Cx) void {
    if (!self.world_tables_stale) return;
    const root = self.root orelse return;
    self.world_tables_stale = false;
    // Same order as the former end-of-frame passes: the paint chunk reads the
    // scroll_id that ScrollArea stored in the interaction table.
    syncPaintToTable(self, root);
    syncInteractionToTable(self, root);
}

pub fn syncPaintToTable(self: *Cx, root: *Node) void {
    self.perf.synced_node_count = 0;
    syncPaintNodeRecursive(self, root);
}

fn syncPaintNodeRecursive(self: *Cx, node: *Node) void {
    self.perf.synced_node_count +|= 1;
    if (node.element_id_raw != 0xFFFFFFFF) {
        const eid = world.ElementId.fromRaw(node.element_id_raw);
        // rect read once-reused: per-frame per-node path, rectFromWorldOrFallback
        // once ≈ 6-8 layer calls (Debug without CSE, write 4 times = 4 full chains).
        const rect = node.rectFromWorldOrFallback();
        const hash = paintContentHash(node, rect);
        const bounds: paint_table.Bounds = .{
            .min_x = rect.x,
            .min_y = rect.y,
            .max_x = rect.x + rect.w,
            .max_y = rect.y + rect.h,
        };
        // Items always come from the last render (see PaintTable.mirrorBegin for why a hash
        // hit cannot skip the copy); `changed` only says whether the content moved.
        const changed = self.world.paint.mirrorBegin(eid, hash) catch return;
        // v0.5-P3 Stage 3-3 Phase 3 (session 37): take property tree refs from SceneRuntime
        // (transform_id / clip_id / effect_id), take scroll_id from InteractionTable, write to
        // chunk.property_state.
        const runtime = self.scene_runtime.getPtr(node.id);
        const interaction_data = self.world.interaction.getPtr(eid);
        const property_state = paint_table.PropertyStateRef{
            .transform_id = if (runtime) |rt| rt.transform_id else std.math.maxInt(u32),
            .clip_id = if (runtime) |rt| rt.clip_id else std.math.maxInt(u32),
            .effect_id = if (runtime) |rt| rt.effect_id else std.math.maxInt(u32),
            .scroll_id = if (interaction_data) |d| d.scroll_id else std.math.maxInt(u32),
        };
        {
            // Truly mirror node's own DisplayItem range.
            if (runtime) |rt| {
                const start: usize = rt.display_item_start;
                const count: usize = rt.display_item_count;
                if (count > 0 and start + count <= self.display_list.items.items.len) {
                    const gpu_draw_shadow = @import("render_engine/gpu_draw_shadow.zig");
                    var i: usize = 0;
                    while (i < count) : (i += 1) {
                        const di = self.display_list.items.items[start + i];
                        // Unique display_list -> paint_table
                        // mapping point (merged mapDisplayItem from cx internal to shadow path's
                        // lowerDisplayItem). Both paths produce identical paint_table.DisplayItem.
                        const mapped = gpu_draw_shadow.lowerDisplayItem(di);
                        // Failure causes node's paint chunk **lose some items** ->
                        // local screen gap, no signal. Count for diagnostics
                        // (review report §3's silent-error family).
                        self.world.paint.pushItem(eid, mapped) catch {
                            core.paint_push_failures += 1;
                        };
                    }
                }
            }
            self.world.paint.mirrorEnd(eid, property_state, changed);
        }
        // chunk.bounds is the world-space element rect. pushItem's internal unionWith
        // accumulates local_bounds (item-local coords), a semantic mismatch with world
        // bounds, so override here. Downstream (LayerTree.layerizeFrame) needs world bounds.
        if (self.world.paint.get(eid)) |chunk| chunk.bounds = bounds;
    }
    for (node.children.items) |child| syncPaintNodeRecursive(self, child);
}

/// Lightweight content hash for Stage 3-3 Phase 1+ cache invalidation.
/// Takes background + border + opacity + width/height + text + image/icon refs.
/// Session 43: expanded from background-only to 8 common visual properties,
/// letting PaintTable cache invalidation cover more real-world change scenarios.
fn paintContentHash(node: *const Node, rect: ComputedRect) u64 {
    // Runs for every node on every rendered frame. One-shot Wyhash calls chained
    // through the seed instead of a streaming Wyhash: the streaming form copies
    // each update into its 48-byte buffer and drains it in `final`, which in a
    // Debug build cost about as much as the rest of the paint sync. The key is
    // process-local (compared against last frame's value only), so its exact
    // value carries no compatibility contract; every visual field still feeds it.
    // Field bytes are concatenated rather than hashing struct memory, so padding
    // never enters the key.
    const visual_bytes = std.mem.toBytes(node.getBackground()) ++
        std.mem.toBytes(node.style.border.color) ++
        std.mem.toBytes(node.style.border.width) ++
        std.mem.toBytes(node.getOpacity()) ++
        std.mem.toBytes(rect.w) ++ std.mem.toBytes(rect.h);
    var h = std.hash.Wyhash.hash(0, &visual_bytes);
    if (node.getText()) |t| {
        const text_bytes = std.mem.toBytes(t.font_size) ++ std.mem.toBytes(t.color);
        h = std.hash.Wyhash.hash(h, &text_bytes);
        // Length-prefixed by the seed chain: content moving between text and the
        // fixed fields cannot alias.
        h = std.hash.Wyhash.hash(h ^ t.content.len, t.content);
    }
    if (node.getImage()) |im| {
        const image_bytes = std.mem.toBytes(im.texture_id) ++ std.mem.toBytes(im.tint);
        h = std.hash.Wyhash.hash(h +% 1, &image_bytes);
    }
    if (node.getIcon()) |ic| {
        const icon_bytes = std.mem.toBytes(ic.icon_id) ++ std.mem.toBytes(ic.tint);
        h = std.hash.Wyhash.hash(h +% 2, &icon_bytes);
    }
    return h;
}

test "paint content hash is stable and reacts to each visual field" {
    const Fixture = struct {
        fn changed(previous: *u64, node: *const Node, rect: ComputedRect) !void {
            const next = paintContentHash(node, rect);
            // Deterministic for identical input (the cache compares frame to frame)...
            try std.testing.expectEqual(next, paintContentHash(node, rect));
            // ...and every visual field below moves the key.
            try std.testing.expect(previous.* != next);
            previous.* = next;
        }
    };
    const cx = try Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    const node = try core.box(cx, .{}, .{});
    cx.root = node;
    var rect = ComputedRect{ .x = 7, .y = 9, .w = 100, .h = 80 };
    var previous = paintContentHash(node, rect);
    // Position is not part of the key: bounds are written separately every frame.
    try std.testing.expectEqual(previous, paintContentHash(node, .{ .x = 70, .y = 90, .w = 100, .h = 80 }));

    node.setBackgroundRaw(core.Color.rgba(10, 20, 30, 255));
    try Fixture.changed(&previous, node, rect);
    node.style.border.color = core.Color.rgba(40, 50, 60, 255);
    try Fixture.changed(&previous, node, rect);
    node.style.border.width = 2;
    try Fixture.changed(&previous, node, rect);
    node.setOpacityRaw(0.5);
    try Fixture.changed(&previous, node, rect);
    rect.w = 120;
    try Fixture.changed(&previous, node, rect);
    rect.h = 90;
    try Fixture.changed(&previous, node, rect);

    // Exercise strings across Wyhash block boundaries and its buffered tail,
    // followed by every optional payload in the original order.
    node.setText(.{ .content = "Label", .font_size = 14, .color = core.Color.WHITE });
    try Fixture.changed(&previous, node, rect);
    var text = node.getText().?;
    text.content = "A longer label crossing the hash block boundary and buffered tail";
    node.setText(text);
    try Fixture.changed(&previous, node, rect);
    text.font_size = 18;
    node.setText(text);
    try Fixture.changed(&previous, node, rect);
    text.color = core.Color.rgba(80, 90, 100, 255);
    node.setText(text);
    try Fixture.changed(&previous, node, rect);
    node.setImage(.{ .texture_id = 17 });
    try Fixture.changed(&previous, node, rect);
    var image = node.getImage().?;
    image.texture_id = 23;
    node.setImage(image);
    try Fixture.changed(&previous, node, rect);
    image.tint = core.Color.rgba(110, 120, 130, 255);
    node.setImage(image);
    try Fixture.changed(&previous, node, rect);
    node.setIcon(.{ .icon_id = 31, .rep = .{ .size = 24, .shapes = &.{} } });
    try Fixture.changed(&previous, node, rect);
    var icon = node.getIcon().?;
    icon.icon_id = 37;
    node.setIcon(icon);
    try Fixture.changed(&previous, node, rect);
    icon.tint = core.Color.rgba(140, 150, 160, 255);
    node.setIcon(icon);
    try Fixture.changed(&previous, node, rect);
}

pub fn syncInteractionToTable(self: *Cx, root: *Node) void {
    syncInteractionNodeRecursive(self, root);
}

fn syncInteractionNodeRecursive(self: *Cx, node: *Node) void {
    if (node.element_id_raw != 0xFFFFFFFF) {
        const eid = world.ElementId.fromRaw(node.element_id_raw);
        const has_a11y = node.behavior.interaction.a11y != null;
        const has_event = nodeHasAnyEvent(node);
        // v0.5-P3 Stage 3-4 fix (session 34): preserve existing scroll_id
        // (ScrollArea.mount injection), not erased by syncInteractionToTable after each frame
        // render.
        // One probe per node: the existing slot is both the scroll_id source and,
        // when present, the write target (put/remove would probe again).
        const existing = self.world.interaction.getPtr(eid);
        const existing_scroll_id: u32 = if (existing) |e| e.scroll_id else std.math.maxInt(u32);
        const has_scroll = existing_scroll_id != std.math.maxInt(u32);
        if (node.behavior.interaction.focusable or has_a11y or has_event or has_scroll) {
            const focused = if (self.focus_manager.current_focus) |fn_node| (fn_node == node) else false;
            const ti: i16 = if (node.behavior.interaction.tab_index) |t|
                @as(i16, @intCast(@max(@min(t, std.math.maxInt(i16)), std.math.minInt(i16))))
            else
                0;
            const role: u16 = if (node.behavior.interaction.a11y) |*a| @backingInt(a.role) else 0;
            const data: interaction_table.InteractionData = .{
                .focus = .{
                    .focusable = node.behavior.interaction.focusable,
                    .tabbable = node.behavior.interaction.tab_index != null,
                    .focused = focused,
                },
                .tab_index = ti,
                .event_mask = if (has_event) 0xFFFF_FFFF else 0,
                .a11y_role = role,
                .scroll_id = existing_scroll_id,
            };
            if (existing) |slot| {
                slot.* = data;
            } else {
                // failure -> that node this frame **cannot be hit** (click/hover fail silent),
                // completely silent. Same 'silent degradation' family as core.paint_push_failures.
                self.world.interaction.put(eid, data) catch {
                    core.interaction_put_failures += 1;
                };
            }
        } else if (existing != null) {
            _ = self.world.interaction.remove(eid);
        }
    }
    for (node.children.items) |child| syncInteractionNodeRecursive(self, child);
}

fn nodeHasAnyEvent(node: *const Node) bool {
    const e = &node.behavior.events;
    return e.on_click != null or e.on_hover != null or e.on_leave != null or
        e.on_focus != null or e.on_blur != null or
        e.on_key_down != null or e.on_key_up != null or
        e.on_event != null or e.on_event_capture != null or e.on_action != null;
}

pub fn assertLayoutSyncIntegrity(self: *Cx, root: *Node) bool {
    ensureWorldTablesSynced(self);
    return assertLayoutSyncIntegrityRecursive(self, root);
}

fn assertLayoutSyncIntegrityRecursive(self: *Cx, node: *Node) bool {
    if (node.element_id_raw != 0xFFFFFFFF) {
        const eid = world.ElementId.fromRaw(node.element_id_raw);
        const lr = self.rectOf(eid) orelse return false;
        const eps: f32 = 0.001;
        // World.LayoutTable is the sole source of truth for rect (no frame_state.rect).
        // Invariant enforced below: PaintTable.bounds must equal LayoutTable.rect
        // (shadow-sync guaranteed by syncPaintToTable). Any PaintTable shadow miss is caught here.
        if (self.world.paint.get(eid)) |chunk| {
            if (!chunk.bounds.isEmpty()) {
                if (@abs(chunk.bounds.min_x - lr.x) > eps) return false;
                if (@abs(chunk.bounds.min_y - lr.y) > eps) return false;
                if (@abs(chunk.bounds.max_x - (lr.x + lr.width)) > eps) return false;
                if (@abs(chunk.bounds.max_y - (lr.y + lr.height)) > eps) return false;
            }
        }
        // v0.5-P3 Stage 3-2 Phase 2 attempt (session 41, REVERTED):
        // tried adding ElementTable parent-child chain consistency invariant, but Node.parent vs
        // World.elements parent are stale mid-layout pass (Input component reparent timing
        // complex).
        // Crashed panic, reverted. True ElementTable invariant gate needs prior hook 'sync when'
        // granularity.
    }
    for (node.children.items) |child| {
        if (!assertLayoutSyncIntegrityRecursive(self, child)) return false;
    }
    return true;
}
