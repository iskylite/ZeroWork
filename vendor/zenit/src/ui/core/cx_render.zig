//! Cx frame pipeline: render() (before-render tick -> layout -> after-layout hooks ->
//! runtime indexing -> layerize -> display list), encoder paint table downgrade,
//! redraw dispatch, and scene-fresh before hit-test (ensureHitTestSceneFresh).

const std = @import("std");
const core = @import("../core.zig");
const Cx = core.Cx;
const cx_frame = @import("cx_frame.zig");
const cx_bulk_quads = @import("cx_bulk_quads.zig");
const PartialInteractionRoots = cx_runtime_index.PartialInteractionRoots;
const AfterLayoutOutcome = struct { ran_layout: bool = false, interaction_dirty: bool = false };
const text_core_module = @import("text_core");
const AfterLayoutFn = core.AfterLayoutFn;
const ComputedRect = core.ComputedRect;
const LayoutContext = layout_engine.LayoutContext;
const LayoutTable = core.LayoutTable;
const Node = core.Node;
const cx_cursor = @import("cx_cursor.zig");
const cx_node_lifetime = @import("cx_node_lifetime.zig");
const cx_runtime_index = @import("cx_runtime_index.zig");
const debug_env = @import("debug_env.zig");
const display_list = core.display_list;
const display_list_mod = @import("display_list.zig");
const hitSceneDebugEnabled = debug_env.hitSceneDebugEnabled;
const layoutIntegrityEveryFrameEnabled = debug_env.layoutIntegrityEveryFrameEnabled;
const layout_engine = core.layout_engine;
const max_after_layout_rounds = core.max_after_layout_rounds;
const paint_table = core.paint_table;
const renderDirtyDebugEnabled = debug_env.renderDirtyDebugEnabled;
const render_engine = core.render_engine;
const text = core.text;

fn startPerfTimer(self: *const Cx) @import("zenit_time").Timer {
    // Cx.init validated this I/O clock when creating deferred_epoch. A frame
    // only needs a fresh sample; querying its resolution again adds a syscall
    // to every measured phase and used to leave an undefined timer on failure.
    var timer: @import("zenit_time").Timer = .{ .io = self.io, .started = self.deferred_epoch };
    timer.reset();
    return timer;
}

test "frame timers reuse clock validation and keep window I/O independent" {
    const Clock = struct {
        value: i96,
        resolutions: usize = 0,
        fn now(raw: ?*anyopaque, _: std.Io.Clock) std.Io.Timestamp {
            const clock: *@This() = @ptrCast(@alignCast(raw.?));
            return .{ .nanoseconds = clock.value };
        }
        fn resolution(raw: ?*anyopaque, _: std.Io.Clock) std.Io.Clock.ResolutionError!std.Io.Duration {
            const clock: *@This() = @ptrCast(@alignCast(raw.?));
            clock.resolutions += 1;
            return .{ .nanoseconds = 1 };
        }
    };
    var a: Clock = .{ .value = 100 };
    var b: Clock = .{ .value = 1000 };
    var vtable = std.testing.io.vtable.*;
    vtable.now = Clock.now;
    vtable.clockResolution = Clock.resolution;
    // Only the two clock fields are consumed by this private helper.
    var ca: Cx = undefined;
    ca.io = .{ .userdata = &a, .vtable = &vtable };
    ca.deferred_epoch = try @import("zenit_time").Instant.now(ca.io);
    var cb: Cx = undefined;
    cb.io = .{ .userdata = &b, .vtable = &vtable };
    cb.deferred_epoch = try @import("zenit_time").Instant.now(cb.io);
    a.value = 200;
    b.value = 2000;
    var ta = startPerfTimer(&ca);
    var tb = startPerfTimer(&cb);
    a.value = 225;
    b.value = 2075;
    try std.testing.expectEqual(@as(u64, 25), ta.read());
    try std.testing.expectEqual(@as(u64, 75), tb.read());
    ta = startPerfTimer(&ca);
    a.value = 250;
    try std.testing.expectEqual(@as(u64, 25), ta.read());
    try std.testing.expectEqual(@as(usize, 1), a.resolutions);
    try std.testing.expectEqual(@as(usize, 1), b.resolutions);
}

pub fn render(self: *Cx) []const display_list_mod.DisplayItem {
    // system a11y pref change (reduce motion / lower transparency): whole tree invalidate must
    // ahead of zero-dirty fast-path.
    self.syncA11yPreferences();
    // timer callbacks run first: nodes they mark dirty must catch this frame (not skip zero-dirty
    // path).
    self.fireDueTimers();
    // overlay exit done restore focus to control opened it.
    // WARNING: **ahead of zero-dirty fast-path**: after close overlay often exactly zero-dirty,
    // place after it'd early-return skip, focus never restore.
    cx_node_lifetime.drainOverlayFocusRestore(self);

    // zero-dirty fast-path: root fully-clean + prior frame cache valid return cache.
    // perf #1 matrix: 10k-node zero-dirty < 0.5ms key skip.
    // Safety: no pending scene work (including non-bubbling interaction bits
    // and active animations), and no inspector/virtual pointer paint.
    if (self.root != null) {
        const time_unchanged = self.frame_time_ms == self.last_render_frame_time_ms;
        if (self.last_render_valid and
            time_unchanged and
            // The bulk rect layer is resubmitted every frame by the host and zenit does no
            // cross-frame diff,
            // so it cannot detect content changes -> conservative redraw by default (see
            // setBulkQuads).
            // A host that can prove "same batch as last frame" via setBulkQuadsVersioned lets a
            // static
            // picture return to zero-dirty; for a 20k-quad canvas this is 21.6ms vs ~0 per frame.
            (self.bulk_quads.items.len == 0 or self.bulk_quads_unchanged) and
            // Match the host's frame gate. Loose hit/interaction bits do not
            // bubble into paint/layout flags, but still need before-render
            // index refresh. Returning the cache leaves that work pending.
            !self.hasPendingSceneWork() and
            // The automated virtual pointer is **drawn in the real render target**
            // (screenshots/recordings
            // show it) but has no Node tree, so moving it leaves the whole tree clean. Without
            // this, a pure
            // mouse_move (no node change) takes the zero-dirty early return and overlay code never
            // runs,
            // so the harness virtual mouse never draws. Visible = counted as dirty; invisible =
            // zero cost.
            !self.virtual_cursor.visible and
            !self.inspector.enabled and
            !self.inspector.debug_paint.anyActive())
        {
            self.perf.resetFrame();
            return self.display_list.items.items;
        }
    }
    // reset frame arena, free all prior-frame temp alloc
    _ = self.frame_arena.reset(.retain_capacity);
    self.perf.resetFrame();
    // gesture_arena tick, long_press time-related recognizer advance by this.
    // must call before render pass; else long_press began emit then dispatch
    // render (one-frame extra delay, user feel lag).
    if (self.gesture_arena.recognizers.items.len != 0) {
        self.gesture_arena.tick(@import("zenit_time").nanoTimestamp(self.io));
    }
    // advance ShapingCache epoch; prior-frame unreached entry driven out at config threshold
    // frames. GlyphRun pipeline inherit old measure path so text measure
    // single cache layer.
    self.text.beginFrame();
    self.lowering.main_paint.clearRetainingCapacity();
    if (self.root) |r| {
        // OverlayStack: unified outside-click handle (before has_new_mouse_down cleared)
        // mouseDown + render between virtual list / condition render may freed hit node.
        // bare pointer kept for sync-event compat only; cross-frame consume must re-parse
        // handle with generation, avoid OverlayStack.isDescendantOf dangling parent chain.
        const outside_click_target = self.node_registry.resolve(self.last_mouse_down_handle, &self.perf);
        self.last_mouse_down_target = outside_click_target;
        if (outside_click_target == null) self.last_mouse_down_handle = null;
        self.overlay_stack.handleOutsideClickOwned(self.has_new_mouse_down, outside_click_target, self.press_overlay_owner);

        const tick_mod = @import("render_engine/tick.zig");
        tick_mod.g_tick_node_count = 0;
        tick_mod.g_tick_hook_count = 0;
        tick_mod.g_slow_hook_us = 0;
        tick_mod.g_slow_hook_name_len = 0;
        tick_mod.g_debug_frame = self.frame_count;
        tick_mod.g_debug_dirty_hooks = 0;
        var bt = startPerfTimer(self);
        ensureBeforeRenderTicked(self);
        self.perf.before_render_us = bt.read() / 1000;
        self.perf.tick_nodes = tick_mod.g_tick_node_count;
        self.perf.tick_hooks = tick_mod.g_tick_hook_count;
        self.perf.slow_hook_us = tick_mod.g_slow_hook_us;
        const sn_len = tick_mod.g_slow_hook_name_len;
        const sn_max = @min(sn_len, self.perf.slow_hook_name.len);
        @memcpy(self.perf.slow_hook_name[0..sn_max], tick_mod.g_slow_hook_name[0..sn_max]);
        self.perf.slow_hook_name_len = sn_max;
        // DEBUG: print render_dirty nodes every 300 frames
        if (renderDirtyDebugEnabled() and self.frame_count % 300 == 1) {
            cx_frame.debugPrintRenderDirtyNodes(self, r);
        }
        // on_before_render consumed has_new_mouse_down, clear
        self.has_new_mouse_down = false;

        // OverlayStack: update anchor geometry first, after layout done advance animation time.
        self.overlay_stack.updateAnchors(self.viewport.width, self.viewport.height);

        // Pass 1.5: incremental layout
        // Cx.init already validated this clock. Reuse bt's I/O binding and
        // sample a new epoch without querying clock resolution a second time.
        var inner_timer = bt;
        inner_timer.reset();
        if (r.frame_state.state_bits.dirty.core.layout or r.frame_state.state_bits.dirty.core.subtree_layout) {
            layout_engine.layoutNode(r, self.viewport, LayoutContext{ .frame_allocator = self.frame_arena.allocator(), .shaping_cache = &self.text.shaping_cache, .font_system = self.text.font_system });
            self.syncLayoutToTable(r);
        }
        self.perf.inner_layout_us = inner_timer.lap() / 1000;

        const animations_active = self.overlay_stack.tickAnimations(self.frame_time_ms, self.frame_dt_seconds, self.allocator);
        if (animations_active) {
            self.needs_redraw = true;
        }

        // Pass 2: render command generation
        var render_ctx = render_engine.RenderContext{
            .lowering_buffer = &self.lowering._dead_main,
            .lowering_buffer_paint = &self.lowering.main_paint,
            .display_list = &self.display_list,
            .text_blob_store = &self.text_blob_store,
            .scene_runtime = &self.scene_runtime,
            .property_tree = &self.property_tree,
            .layer_tree = &self.layer_tree,
            .world = &self.world,
            .allocator = self.allocator,
            .frame_allocator = self.frame_arena.allocator(),
            .viewport = self.viewport,
            .perf = &self.perf,
            .external_clip_rects = &self.external_clip_rects,
            // transport GlyphRun pipeline resource to render engine
            .shaping_cache = &self.text.shaping_cache,
            .font_system = self.text.font_system,
            .measure_font_context = self.text.font_resolve_ctx,
            .measure_font_fn = self.text.font_props_measure_fn,
            .visual_line_context = self,
            .visual_line_fn = &renderVisualLine,
        };
        const render_node_start = inner_timer.read();
        render_engine.renderNode(&render_ctx, r) catch |err| {
            std.debug.print("[ui] renderNode error: {}\n", .{err});
        };
        self.perf.render_node_us = (inner_timer.read() - render_node_start) / 1000;

        // bulk rect layer: absolute viewport coords => use identity transform (id 0).
        // hierarchy/clip by host anchor (see setBulkQuads): insert to anchor subtree end
        // bring its clip_id.
        cx_bulk_quads.appendBulkQuads(self) catch |err| {
            std.debug.print("[ui] bulk quad append error: {}\n", .{err});
        };

        // Stage B R3f: derive + inspector overlay still run at cx.render() end (compat
        // test expect cx.lowering.main readable immediately after cx.render()). lowerForEncoder
        // for encoder call, **idempotent**, filled return directly, no repeat derive.
        self.lowering._dead_main.clearRetainingCapacity();
        self.lowering.main_paint.clearRetainingCapacity();
        const lowering_mod = @import("render_engine/display_list_lowering.zig");
        // correctness path: main_paint just clearRetainingCapacity, here whole-frame
        // display item re-lower in. OOM leave **truncated** paint list
        // (begin/end layer mismatched, second-half tree no-draw), render() return is it
        // screen silently broken not clean fail.
        if (@import("zenit_environment").has("ZENIT_DEBUG_DLIST")) {
            std.debug.print("[dlist] ── frame {d} items={d} ──\n", .{ self.scene_runtime.frame_epoch, self.display_list.items.items.len });
            for (self.display_list.items.items, 0..) |it, di| {
                const h = it.header();
                switch (it) {
                    .text_run => |t| std.debug.print("[dlist] {d}: text node={d} eff={d} clip={d} \"{s}\"\n", .{ di, h.node_id, h.effect_id, h.clip_id, t.content[0..@min(t.content.len, 12)] }),
                    .fill_rect => |fr| std.debug.print("[dlist] {d}: rect node={d} eff={d} clip={d} ({d:.0},{d:.0},{d:.0}x{d:.0}) r={d:.3} a={d}\n", .{ di, h.node_id, h.effect_id, h.clip_id, fr.x, fr.y, fr.w, fr.h, fr.radius[0], fr.color.a }),
                    // stroke-width / corner-radius "content property scale" regression validate
                    // observation point
                    // (downstream app: stroke + corner == world * scale).
                    .stroke_rect => |sr| std.debug.print("[dlist] {d}: stroke node={d} eff={d} clip={d} ({d:.1},{d:.1},{d:.1}x{d:.1}) w={d:.3} r={d:.3}\n", .{ di, h.node_id, h.effect_id, h.clip_id, sr.x, sr.y, sr.w, sr.h, sr.width, sr.radius[0] }),
                    .border_side => |bs| std.debug.print("[dlist] {d}: border node={d} eff={d} clip={d} ({d:.1},{d:.1},{d:.1}x{d:.1}) w={d:.3} r={d:.3}\n", .{ di, h.node_id, h.effect_id, h.clip_id, bs.x, bs.y, bs.w, bs.h, bs.width, bs.radius[0] }),
                    else => std.debug.print("[dlist] {d}: {s} node={d} eff={d} clip={d}\n", .{ di, @tagName(it), h.node_id, h.effect_id, h.clip_id }),
                }
            }
        }
        // Timed as `phase_prebuild_us`: lowering walks the whole display
        // list every frame and was the largest untimed region inside
        // render(), so a slow frame here looked like unattributed
        // `render_us`.
        const lower_start = inner_timer.read();
        lowering_mod.appendAllDisplayItemsToRenderList(&render_ctx) catch @panic("OOM: lower display list into main render list");
        self.perf.phase_prebuild_us = (inner_timer.read() - lower_start) / 1000;
        if (@import("zenit_environment").has("ZENIT_DEBUG_SURFDUMP")) {
            var in_surf: bool = false;
            var counts: [64]u32 = @splat(0);
            for (self.lowering.main_paint.items) |it| {
                const k = @backingInt(it.kind);
                if (it.kind == .control and it.control_kind == .begin_opacity_layer) {
                    in_surf = true;
                    std.debug.print("[surfdump] f={d} BEGIN op={d:.2}\n", .{ self.scene_runtime.frame_epoch, it.opacity });
                } else if (in_surf and it.kind == .control and it.control_kind == .end_opacity_layer) {
                    in_surf = false;
                    std.debug.print("[surfdump] f={d} END counts:", .{self.scene_runtime.frame_epoch});
                    for (counts, 0..) |c, ki| {
                        if (c > 0) std.debug.print(" {s}={d}", .{ @tagName(@as(@TypeOf(it.kind), @fromBackingInt(@intCast(ki)))), c });
                    }
                    std.debug.print("\n", .{});
                    counts = @splat(0);
                } else if (in_surf) {
                    if (k < counts.len) counts[k] += 1;
                    std.debug.print("[surfitem] {s} x={d:.1} y={d:.1} w={d:.1} h={d:.1} a={d:.2}\n", .{
                        @tagName(it.kind),                           it.geom.x, it.geom.y, it.geom.w, it.geom.h,
                        @as(f32, @floatFromInt(it.color.a)) / 255.0,
                    });
                }
            }
        }
        // v0.5-P3 Stage 4-1+: render end do one more layout sync, capture before_render hook (like
        // ScrollArea scrollbar directly
        // rewrite node.rect loose path). This is patch-style fix, real solution is give
        // scrollbar/modal etc direct cx.syncNodeRect(node) call.
        // Timed together as `phase_sync_us`: these four shadow-sync passes each walk node tree at
        // every frame end. They were untimed, cost
        // showed only as gap between render_node_us and render_us.
        const sync_start = inner_timer.read();
        self.syncLayoutToTable(r);
        // World.paint / World.interaction mirror this frame on demand
        // (see cx_world_sync.ensureWorldTablesSynced).
        self.world_tables_stale = true;
        // Project Node tree a11y metadata to AccessibilityTree. Next step (sec 2.1 ObjC bridge):
        // cx.render() end calls a11y_router.flushToBridge to post dirty queue to macOS
        // NSAccessibility.
        self.syncOrDeferA11yProjection(r);
        self.perf.phase_sync_us = (inner_timer.read() - sync_start) / 1000;
        // Debug build validates whole-tree invariants. Downsampled to every 64 frames to avoid
        // ~5ms debug tax per frame; regressions like shadow-sync are continuous and hit within
        // 64 frames. ZENIT_LAYOUT_INTEGRITY=1 restores per-frame validation (for sync timing
        // issues).
        const integrity_start = inner_timer.read();
        if (std.debug.runtime_safety) {
            const every_frame = layoutIntegrityEveryFrameEnabled();
            if (every_frame or self.frame_count % 64 == 1) {
                if (!self.assertLayoutSyncIntegrity(r)) {
                    std.debug.panic("LayoutTable shadow-sync integrity check failed\n", .{});
                }
            }
        }
        // `phase_retained_us` reports the debug-only integrity walk. It is
        // a full-tree traversal that exists only under runtime_safety, so
        // it inflates render() in debug builds and vanishes in release,
        // worth seeing separately rather than blaming the paint pass.
        self.perf.phase_retained_us = (inner_timer.read() - integrity_start) / 1000;
    }
    // Self-check paint invariants of scene content (before inspector/automation cursor overlays;
    // see core/paint_invariants.zig)
    if (self.paint_invariant_check) {
        const r = core.paint_invariants.duplicateFills(self.frame_arena.allocator(), self.display_list.items.items) catch |err| blk: {
            std.log.warn("paint invariant check skipped this frame: {s}", .{@errorName(err)});
            break :blk core.paint_invariants.Result{};
        };
        if (r.duplicates != 0) {
            self.paint_duplicate_fills += r.duplicates;
            self.paint_duplicate_node = r.first_node;
            std.log.warn("paint invariant: node {d} emitted an identical fill_rect / stroke_rect twice in frame {d} (cache replay double emission?)", .{ r.first_node, self.frame_count });
        }
    }
    self.inspector.renderOverlay(self);
    // Final layer: automation cursor must enter real render target to appear in
    // screenshots/recording.
    // Drawn after inspector, not in Node/hit-test tree.
    if (self.virtual_cursor.renderOverlay(self, self.frame_time_ms)) {
        self.needs_redraw = true;
    }

    // Zero-dirty fast path returns self.display_list.items.items. display_list is source of truth,
    // frame-stable (cleared only at paint pass start), no snapshot needed.
    self.last_render_valid = true;
    self.last_render_frame_time_ms = self.frame_time_ms;
    return self.display_list.items.items;
}

pub fn lowerForEncoderPaintTable(self: *Cx) []const paint_table.DisplayItem {
    return self.lowering.main_paint.items;
}

/// Check if entire tree is clean. markDirty bubbles to root, so all of root's
/// layout/render/composite/subtree_* being clean implies whole tree clean. O(1) check.
pub fn isTreeFullyClean(self: *const Cx, root: *Node) bool {
    return !root.frame_state.state_bits.dirty.core.layout and
        !root.frame_state.state_bits.dirty.core.subtree_layout and
        !root.frame_state.state_bits.dirty.core.render and
        !root.frame_state.state_bits.dirty.core.subtree_render and
        !root.frame_state.state_bits.dirty.pipeline.composite and
        !root.frame_state.state_bits.dirty.pipeline.subtree_composite and
        !root.frame_state.state_bits.dirty.runtime.dirty and
        !root.frame_state.state_bits.dirty.runtime.subtree_dirty and
        !root.frame_state.state_bits.dirty.pipeline.order and
        !root.frame_state.state_bits.dirty.pipeline.subtree_order and
        !root.frame_state.state_bits.dirty.pipeline.interaction and
        !root.frame_state.state_bits.dirty.pipeline.subtree_interaction and
        !cx_runtime_index.subtreeHasLooseInteractionDirty(self, root);
}

pub fn scheduleRedrawAfterNs(self: *Cx, delay_ns: u64) void {
    const now = @import("zenit_time").Instant.now(self.io) catch return;
    if (self.next_redraw_scheduled_at) |scheduled_at| {
        if (self.next_redraw_delay_ns) |current_delay| {
            const elapsed = now.since(scheduled_at);
            const remaining = current_delay -| elapsed;
            if (delay_ns >= remaining) return;
        }
    }
    self.next_redraw_scheduled_at = now;
    self.next_redraw_delay_ns = delay_ns;
}

pub fn processScheduledRedraw(self: *Cx) bool {
    const scheduled_at = self.next_redraw_scheduled_at orelse return false;
    const delay_ns = self.next_redraw_delay_ns orelse return false;
    const now = @import("zenit_time").Instant.now(self.io) catch return false;
    if (now.since(scheduled_at) < delay_ns) return false;
    self.next_redraw_scheduled_at = null;
    self.next_redraw_delay_ns = null;
    self.needs_redraw = true;
    return true;
}

/// Force-update interaction index before event handling. Not gated by before_render_frame
/// cache (runs even when idle frame does not increment frame_count).
pub fn ensureHitTestSceneFresh(self: *Cx) void {
    if (self.tick_depth > 0 or self.draining_deferred_frees) return;
    _ = self.processScheduledRedraw();
    if (!self.hasPendingSceneWork()) return;
    forceTickAndRebuildForHitTest(self);
}

pub fn forceTickAndRebuildForHitTest(self: *Cx) void {
    defer cx_cursor.updateCursorShape(self);
    const r = self.root orelse return;
    const root_handle = self.node_registry.handleFor(r);
    const viewport_clip = ComputedRect.init(0, 0, self.viewport.width, self.viewport.height);
    const had_initial_layout_dirty = r.frame_state.state_bits.dirty.core.layout or r.frame_state.state_bits.dirty.core.subtree_layout;
    const had_initial_interaction_dirty = r.frame_state.state_bits.dirty.pipeline.subtree_interaction or cx_runtime_index.subtreeHasLooseInteractionDirty(self, r);
    var partial_interaction_roots = PartialInteractionRoots{};
    if ((had_initial_layout_dirty or had_initial_interaction_dirty) and !r.frame_state.state_bits.dirty.runtime.subtree_dirty and !r.frame_state.state_bits.dirty.pipeline.subtree_order) {
        cx_runtime_index.collectPartialInteractionRootsWithFallback(self, r, &partial_interaction_roots);
    }
    if (had_initial_layout_dirty) {
        layout_engine.layoutNode(r, self.viewport, LayoutContext{ .frame_allocator = self.frame_arena.allocator(), .shaping_cache = &self.text.shaping_cache, .font_system = self.text.font_system });
        self.syncLayoutToTable(r);
    }
    // Hit-test freshness must not consume animation time. This path can run multiple times
    // within one visual frame during mouse down/up/move, and advancing dt causes
    // popovers/selects/pickers
    // to skip opening frames. Absolute timestamp must sync with current logic frame, else
    // animations
    // advance but render stalls, causing hit test to use old frame time and lag visible position.
    render_engine.setFrameClock(.{
        .io = self.io,
        .time_ms = self.frame_time_ms,
        .dt_ms = 0,
        .dt_seconds = 0,
    });
    // Same as render path: freeNode deferred during traversal (see freeNode comment).
    self.tick_depth += 1;
    self.owner.beginBatch();
    self.last_tick_animations_active = render_engine.tickBeforeRender(r, 0, 0, viewport_clip, self.allocator, 0);
    // Batch before tick_depth returns to zero; freeNode in effects still deferred.
    self.owner.endBatch();
    self.tick_depth -= 1;
    // Handles make the collection itself memory-safe. Resetting after a
    // structural mutation also prevents pre-hook ancestry decisions from
    // being merged with the post-hook tree; the fresh collection below is
    // authoritative for the new topology.
    if (self.deferred_free_nodes.len > 0) partial_interaction_roots = .{};
    cx_node_lifetime.drainDeferredFrees(self);
    const current_root = self.root orelse return;
    if (current_root != r or self.node_registry.resolve(root_handle, null) != current_root) {
        cx_runtime_index.fullRebuildRuntimeIndexes(self, current_root) catch @panic("OOM: root changed during hit-test tick");
        return;
    }
    self.overlay_stack.updateAnchors(self.viewport.width, self.viewport.height);
    const had_post_tick_layout_dirty = current_root.frame_state.state_bits.dirty.core.layout or current_root.frame_state.state_bits.dirty.core.subtree_layout;
    const had_post_tick_interaction_dirty = current_root.frame_state.state_bits.dirty.pipeline.subtree_interaction or cx_runtime_index.subtreeHasLooseInteractionDirty(self, current_root);
    if ((had_post_tick_layout_dirty or had_post_tick_interaction_dirty) and !current_root.frame_state.state_bits.dirty.runtime.subtree_dirty and !current_root.frame_state.state_bits.dirty.pipeline.subtree_order) {
        cx_runtime_index.collectPartialInteractionRootsWithFallback(self, current_root, &partial_interaction_roots);
    }
    if (had_post_tick_layout_dirty) {
        layout_engine.layoutNode(current_root, self.viewport, LayoutContext{ .frame_allocator = self.frame_arena.allocator(), .shaping_cache = &self.text.shaping_cache, .font_system = self.text.font_system });
        self.syncLayoutToTable(current_root);
    }
    const has_layout_dirty = had_initial_layout_dirty or had_post_tick_layout_dirty;
    const has_interaction_dirty = had_initial_interaction_dirty or had_post_tick_interaction_dirty;
    // OOM not swallowed (see rebuildRuntimeIndexesIfCurrentRootDirty).
    if (current_root.frame_state.state_bits.dirty.runtime.subtree_dirty) {
        if (hitSceneDebugEnabled()) std.debug.print("[hit-scene] rebuild=runtime\n", .{});
        cx_runtime_index.rebuildRuntimeIndexes(self) catch @panic("OOM: rebuildRuntimeIndexes (hit-test scene refresh)");
    } else if (current_root.frame_state.state_bits.dirty.pipeline.subtree_order) {
        if (hitSceneDebugEnabled()) std.debug.print("[hit-scene] rebuild=order\n", .{});
        cx_runtime_index.rebuildOrderIndexes(self) catch @panic("OOM: rebuildOrderIndexes (hit-test scene refresh)");
    } else if (has_layout_dirty or has_interaction_dirty) {
        if (hitSceneDebugEnabled()) std.debug.print("[hit-scene] rebuild=partial roots={d} overflow={}\n", .{ partial_interaction_roots.len, partial_interaction_roots.overflow });
        cx_runtime_index.rebuildInteractionIndexWithPartialRoots(self, partial_interaction_roots) catch @panic("OOM: rebuildInteractionIndex (hit-test scene refresh)");
    }
}

pub fn addAfterLayoutHook(self: *Cx, ctx: *anyopaque, run: AfterLayoutFn) !void {
    for (self.after_layout_hooks.items) |h| {
        if (h.ctx == ctx) return;
    }
    try self.after_layout_hooks.append(self.allocator, .{ .ctx = ctx, .run = run });
}

pub fn removeAfterLayoutHook(self: *Cx, ctx: *anyopaque) void {
    var i: usize = 0;
    while (i < self.after_layout_hooks.items.len) {
        if (self.after_layout_hooks.items[i].ctx == ctx) {
            _ = self.after_layout_hooks.orderedRemove(i);
            if (self.after_layout_cursor) |*next| {
                if (i < next.*) next.* -= 1;
            }
        } else i += 1;
    }
}

/// Callback -> (if dirty) layout, loop until no callback requests or iteration limit hit.
fn runAfterLayoutHooks(self: *Cx, partial: *PartialInteractionRoots) AfterLayoutOutcome {
    var out = AfterLayoutOutcome{};
    if (self.after_layout_hooks.items.len == 0) return out;
    var round: u8 = 0;
    while (round < max_after_layout_rounds) : (round += 1) {
        const last_round = round + 1 == max_after_layout_rounds;
        var again = false;
        // Same gate as before_render: freeNode in callbacks deferred until end of round.
        self.tick_depth += 1;
        self.owner.beginBatch();
        const saved_cursor = self.after_layout_cursor;
        self.after_layout_cursor = 0;
        while (self.after_layout_cursor.? < self.after_layout_hooks.items.len) {
            const h = self.after_layout_hooks.items[self.after_layout_cursor.?];
            self.after_layout_cursor.? += 1;
            if (h.run(h.ctx, round, last_round) == .needs_layout) again = true;
        }
        self.after_layout_cursor = saved_cursor;
        self.owner.endBatch();
        self.tick_depth -= 1;
        if (self.deferred_free_nodes.len > 0) partial.* = .{};
        cx_node_lifetime.drainDeferredFrees(self);
        const root = self.root orelse return out;
        const layout_dirty = root.frame_state.state_bits.dirty.core.layout or root.frame_state.state_bits.dirty.core.subtree_layout;
        const interaction_dirty = root.frame_state.state_bits.dirty.pipeline.subtree_interaction or cx_runtime_index.subtreeHasLooseInteractionDirty(self, root);
        if (interaction_dirty) out.interaction_dirty = true;
        if (layout_dirty) {
            if (!root.frame_state.state_bits.dirty.runtime.subtree_dirty and !root.frame_state.state_bits.dirty.pipeline.subtree_order) {
                cx_runtime_index.collectPartialInteractionRootsWithFallback(self, root, partial);
            }
            layout_engine.layoutNode(root, self.viewport, LayoutContext{ .frame_allocator = self.frame_arena.allocator(), .shaping_cache = &self.text.shaping_cache, .font_system = self.text.font_system });
            self.syncLayoutToTable(root);
            out.ran_layout = true;
        }
        if (!again) break;
    }
    return out;
}

fn ensureBeforeRenderTicked(self: *Cx) void {
    defer cx_cursor.updateCursorShape(self);
    if (self.before_render_frame == self.frame_count and
        std.math.approxEqAbs(f64, self.before_render_time_ms, self.frame_time_ms, 0.0001))
    {
        return;
    }
    if (self.root) |r| {
        const root_handle = self.node_registry.handleFor(r);
        self.perf.tick_before_render_count += 1;
        std.debug.assert(self.perf.tick_before_render_count <= 1);
        // First layout pass lets on_before_render / overlay enter tick read real rect of current
        // frame.
        // Critical for layers positioned by content size; otherwise first open shows old 0x0 /
        // stale geometry.
        const had_initial_layout_dirty = r.frame_state.state_bits.dirty.core.layout or r.frame_state.state_bits.dirty.core.subtree_layout;
        const had_initial_interaction_dirty = r.frame_state.state_bits.dirty.pipeline.subtree_interaction or cx_runtime_index.subtreeHasLooseInteractionDirty(self, r);
        var partial_interaction_roots = PartialInteractionRoots{};
        if ((had_initial_layout_dirty or had_initial_interaction_dirty) and !r.frame_state.state_bits.dirty.runtime.subtree_dirty and !r.frame_state.state_bits.dirty.pipeline.subtree_order) {
            cx_runtime_index.collectPartialInteractionRootsWithFallback(self, r, &partial_interaction_roots);
        }
        // These four attribution points were deleted as write-but-zero-read, making before_render
        // a black box measured at 4.7ms constant (571 nodes) with no way to drill down. Restored.
        var br_timer = startPerfTimer(self);
        if (had_initial_layout_dirty) {
            layout_engine.layoutNode(r, self.viewport, LayoutContext{ .frame_allocator = self.frame_arena.allocator(), .shaping_cache = &self.text.shaping_cache, .font_system = self.text.font_system });
            self.syncLayoutToTable(r);
        }
        self.perf.br_initial_layout_us = br_timer.lap() / 1000;
        const viewport_clip = ComputedRect.init(0, 0, self.viewport.width, self.viewport.height);
        // Set global frame time for on_before_render hooks and animation system (single-threaded
        // safe, sole entry point).
        render_engine.setFrameClock(.{
            .io = self.io,
            .time_ms = self.frame_time_ms,
            .dt_ms = self.frame_dt_ms,
            .dt_seconds = self.frame_dt_seconds,
            .reduced_motion = self.reduced_motion or self.renderer_reduced_motion,
        });
        // tick_depth gate: freeNode always deferred during traversal (see freeNode comment).
        self.tick_depth += 1;
        // Signal writes during animation tick batched until tick end; batch collected before
        // tick_depth returns to zero, effects' freeNode still deferred.
        self.owner.beginBatch();
        const tick_active = render_engine.tickBeforeRender(r, 0, 0, viewport_clip, self.allocator, self.frame_dt_seconds * 1000.0);
        self.owner.endBatch();
        self.tick_depth -= 1;
        self.perf.br_tick_us = br_timer.lap() / 1000;
        // See forceTickAndRebuildForHitTest: discard pre-hook ancestry
        // decisions after structural mutation and recollect from handles.
        if (self.deferred_free_nodes.len > 0) partial_interaction_roots = .{};
        cx_node_lifetime.drainDeferredFrees(self);
        const current_root = self.root orelse return;
        if (current_root != r or self.node_registry.resolve(root_handle, null) != current_root) {
            if (current_root.frame_state.state_bits.dirty.core.layout or current_root.frame_state.state_bits.dirty.core.subtree_layout) {
                layout_engine.layoutNode(current_root, self.viewport, LayoutContext{ .frame_allocator = self.frame_arena.allocator(), .shaping_cache = &self.text.shaping_cache, .font_system = self.text.font_system });
                self.syncLayoutToTable(current_root);
            }
            // Index rebuilt afterwards, no need for local hit root.
            var ignored_partial = PartialInteractionRoots{};
            _ = runAfterLayoutHooks(self, &ignored_partial);
            cx_runtime_index.fullRebuildRuntimeIndexes(self, self.root orelse current_root) catch @panic("OOM: root changed during before-render tick");
            self.before_render_frame = self.frame_count;
            self.before_render_time_ms = self.frame_time_ms;
            return;
        }
        self.last_tick_animations_active = tick_active;
        if (tick_active) {
            self.needs_redraw = true;
        }
        // on_before_render hooks may mark layout (translate/rect) and interaction dirty. Must
        // complete layout before rebuilding interaction index, else hitTest world position stale.
        // Note:
        // has_layout_dirty must read before layout (layout clears dirty flags). If layout runs this
        // frame,
        // interaction index must update (children's absolute positions changed).
        const had_post_tick_layout_dirty = current_root.frame_state.state_bits.dirty.core.layout or current_root.frame_state.state_bits.dirty.core.subtree_layout;
        const had_post_tick_interaction_dirty = current_root.frame_state.state_bits.dirty.pipeline.subtree_interaction or cx_runtime_index.subtreeHasLooseInteractionDirty(self, current_root);
        if ((had_post_tick_layout_dirty or had_post_tick_interaction_dirty) and !current_root.frame_state.state_bits.dirty.runtime.subtree_dirty and !current_root.frame_state.state_bits.dirty.pipeline.subtree_order) {
            cx_runtime_index.collectPartialInteractionRootsWithFallback(self, current_root, &partial_interaction_roots);
        }
        if (had_post_tick_layout_dirty) {
            layout_engine.layoutNode(current_root, self.viewport, LayoutContext{ .frame_allocator = self.frame_arena.allocator(), .shaping_cache = &self.text.shaping_cache, .font_system = self.text.font_system });
            self.syncLayoutToTable(current_root);
        }
        self.perf.br_post_layout_us = br_timer.lap() / 1000;
        const after_layout = runAfterLayoutHooks(self, &partial_interaction_roots);
        const has_layout_dirty = had_initial_layout_dirty or had_post_tick_layout_dirty or after_layout.ran_layout;
        const has_interaction_dirty = had_initial_interaction_dirty or had_post_tick_interaction_dirty or after_layout.interaction_dirty;
        // OOM not swallowed (see rebuildRuntimeIndexesIfCurrentRootDirty).
        if (current_root.frame_state.state_bits.dirty.runtime.subtree_dirty) {
            cx_runtime_index.rebuildRuntimeIndexes(self) catch @panic("OOM: rebuildRuntimeIndexes (before-render tick)");
        } else if (current_root.frame_state.state_bits.dirty.pipeline.subtree_order) {
            cx_runtime_index.rebuildOrderIndexes(self) catch @panic("OOM: rebuildOrderIndexes (before-render tick)");
        } else if (has_layout_dirty or has_interaction_dirty) {
            cx_runtime_index.rebuildInteractionIndexWithPartialRoots(self, partial_interaction_roots) catch @panic("OOM: rebuildInteractionIndex (before-render tick)");
        }
        self.perf.br_index_us = br_timer.lap() / 1000;
    }
    self.before_render_frame = self.frame_count;
    self.before_render_time_ms = self.frame_time_ms;
}

fn renderVisualLine(context: *anyopaque, content: []const u8, font_size: f32, font_weight: u16, italic: bool, family: u16, mono: bool, symbols: bool) ?text_core_module.VisualLine {
    const self: *Cx = @ptrCast(@alignCast(context));
    return self.text.visualLine(.{
        .text = content,
        .font_family = "system",
        .font_size = font_size,
        .font_weight = font_weight,
        .use_italic = italic,
        .font_family_id = family,
        .use_monospace = mono,
        .use_symbols = symbols,
    }) catch null;
}
