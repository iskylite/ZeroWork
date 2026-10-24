/// ScrollArea Component
///
/// Scrollable container component with Apple-level scroll physics.
///
/// Features:
/// - overflow_hidden clipping + translate_y/x scroll offset
/// - event-driven scroll (system momentum auto-supported)
/// - scrollbar indicator: auto fade in/out, brighter/wider on hover
/// - Apple UIScrollView-level rubber banding:
///   - Damping phase: rational function f(x)=x*d*c/(d+c*x) (c=0.55, Apple standard)
///   - Rebound phase: WebKit exponential decay x(t)=(x0+v0*t*0.31)*exp(-12.5*t)
///   - Momentum overscroll directly triggers rubber band + exponential decay to zero
/// - Content size auto-adaptation
const std = @import("std");
const core = @import("../../core.zig");
const view = @import("../../view.zig");
const Cx = core.Cx;
const Node = core.Node;
const box = core.box;
const BoxStyle = core.BoxStyle;
const Color = core.Color;
const ComputedRect = core.ComputedRect;
const theme = core.theme;
const Padding = core.Padding;
const HitProxySpec = core.HitProxySpec;
const physics = @import("../../physics.zig");
const Scope = @import("../../reactive.zig").Scope;

// Submodules
pub const debug = @import("debug.zig");
const state_mod = @import("state.zig");
const scroll_event = @import("event.zig");
const scroll_scrollbar = @import("scrollbar.zig");
pub const scroll_physics = @import("physics.zig");

// Re-exports, keep external API unchanged
pub const ScrollDirection = state_mod.ScrollDirection;
pub const ScrollbarVisual = state_mod.ScrollbarVisual;
pub const ScrollbarAxisMetrics = state_mod.ScrollbarAxisMetrics;
pub const ScrollState = state_mod.ScrollState;
pub const ScrollTuning = state_mod.ScrollTuningT;

pub const scrollEventHandler = scroll_event.scrollEventHandler;
pub const isOutwardAtBoundary = scroll_event.isOutwardAtBoundary;

pub const scrollbarBeforeRender = scroll_scrollbar.scrollbarBeforeRender;
pub const scrollbarEventHandler = scroll_scrollbar.scrollbarEventHandler;
pub const scrollbarHEventHandler = scroll_scrollbar.scrollbarHEventHandler;
pub const computeVerticalScrollbarMetrics = scroll_scrollbar.computeVerticalScrollbarMetrics;
pub const computeHorizontalScrollbarMetrics = scroll_scrollbar.computeHorizontalScrollbarMetrics;

pub const applyVerticalScroll = scroll_physics.applyVerticalScroll;
pub const applyHorizontalScroll = scroll_physics.applyHorizontalScroll;

/// ScrollArea properties
pub const ScrollAreaProps = struct {
    width: ?f32 = null,
    height: ?f32 = null,
    direction: ScrollDirection = .vertical,
    content_height: ?f32 = null,
    content_width: ?f32 = null,
    /// Scroll speed multiplier (scroll dx/dy are logical px, normalized at the event bridge, default 1.0)
    scroll_speed: f32 = 1,
    padding: Padding = Padding.ZERO,
    background: Color = Color.TRANSPARENT,
    /// Custom state ID (for cross-instance reuse or distinguishing scroll state)
    state_id: ?u64 = null,
    /// Enable rubber band (jelly rebound) effect for vertical direction
    rubber_band_y: bool = true,
    /// Enable rubber band (jelly rebound) effect for horizontal direction
    rubber_band_x: bool = true,
};

/// ScrollArea mount return value
pub const ScrollAreaResult = struct {
    container: *Node,
    content: *Node,
    state: *ScrollState,
    /// `ui.view` integration (see src/ui/view_parts.zig).
    pub fn viewParts(self: ScrollAreaResult) core.ViewParts {
        return .{ .root = self.container, .slot = self.content };
    }
};

/// Create ScrollArea: `W.ScrollArea(.{ .width = 320, .height = 240 }).mount(scope, cx)`.
/// Scope manages ScrollState + ScrollEventCtx lifecycle.
/// AXScrollToVisible implementation for ScrollArea (registered with
/// core.a11y_scroll_into_view_hook).
fn a11yScrollIntoView(scroll: *Node, target: *Node) bool {
    if (scroll.behavior.events.on_event != scrollEventHandler) return false;
    const ev_ctx: *ScrollEventCtx = @ptrCast(@alignCast(scroll.behavior.events.event_context orelse return false));
    const content = ev_ctx.content orelse return false;
    const before = ev_ctx.state.scroll_y;
    scrollIntoView(ev_ctx.state, content, target, .nearest);
    return ev_ctx.state.scroll_y != before;
}

pub fn ScrollArea(props: anytype) ScrollAreaBuilder {
    return .{ .props = @import("../../reactive.zig").props.coerce(ScrollAreaProps, props) };
}

pub const ScrollAreaBuilder = struct {
    props: ScrollAreaProps,

    pub fn mount(self: ScrollAreaBuilder, scope: *Scope, cx: *Cx) !ScrollAreaResult {
        return mountImpl(self.props, scope, cx);
    }
};

fn mountImpl(props: ScrollAreaProps, scope: *Scope, cx: *Cx) !ScrollAreaResult {
    core.a11y_scroll_into_view_hook = &a11yScrollIntoView;
    {
        const my_scope = try scope.childScope();
        var scope_bound = false;
        errdefer if (!scope_bound) my_scope.dispose();
        const allocator = cx.allocator;
        const p = props;

        // Outer container: fixed size + overflow_hidden
        // ScrollArea container defaults to grow (fill parent); explicit size uses px
        var container_style = BoxStyle{
            .direction = .column,
            .overflow_hidden = true,
            .background = p.background,
            .padding = p.padding,
            .width = .{ .grow = .{} },
            .height = .{ .grow = .{} },
        };
        if (p.width) |w| container_style.width = .{ .px = w };
        if (p.height) |h| container_style.height = .{ .px = h };

        // Structure: container / content column / two scrollbars (absolute positioned, hit proxy
        // for hitTest)
        const Parts = struct { content: *Node = undefined, bar_v: *Node = undefined, bar_h: *Node = undefined };
        var parts: Parts = .{};
        const bar_radius = ScrollbarVisual.idle_thickness / 2;
        const container = try view.render(my_scope, cx, view.box(.{ .style = container_style, .tag = .scroll }, .{
            // Inner content container. will_change_transform -> compositor_plan auto-promotes
            // scroll content.
            // Matrix #3: scroll = modify promoted layer transform, no repaint of paint chunks.
            view.capture(&parts.content, view.box(.{ .style = BoxStyle{
                .direction = .column,
                .width = .{ .grow = .{} },
                .height = .{ .fit = .{} },
                .will_change_transform = true,
            } }, {})),
            view.capture(&parts.bar_v, view.box(.{ .style = BoxStyle{
                .width = .{ .px = ScrollbarVisual.idle_thickness },
                .height = .{ .px = 30 },
                .position = .absolute,
                .background = Color.TRANSPARENT,
                .border = .{ .radius = bar_radius },
                .hit_shape = .{ .rounded_rect = bar_radius },
                .clip_shape = .{ .rounded_rect = bar_radius },
            } }, {})),
            view.capture(&parts.bar_h, view.box(.{ .style = BoxStyle{
                .width = .{ .px = 30 },
                .height = .{ .px = ScrollbarVisual.idle_thickness },
                .position = .absolute,
                .background = Color.TRANSPARENT,
                .border = .{ .radius = bar_radius },
                .hit_shape = .{ .rounded_rect = bar_radius },
                .clip_shape = .{ .rounded_rect = bar_radius },
            } }, {})),
        }));
        errdefer cx.freeNode(container);
        container.meta.ownership.meta.component_name = "ScrollArea";
        container.frame_state.state_bits.flags.disable_render_cache = true;
        try core.bindScopeToNode(my_scope, container);
        scope_bound = true;

        const content = parts.content;
        const scrollbar_v = parts.bar_v;
        const scrollbar_h = parts.bar_h;
        for ([_]*Node{ scrollbar_v, scrollbar_h }) |bar| {
            bar.frame_state.state_bits.flags.inspectable = false;
            bar.setHitProxyProvider(scrollbarHitProxyProvider, null);
        }

        // Scope allocates ScrollState (retain mode: nodes not rebuilt, state lives with scope)
        const state = blk: {
            const state = try my_scope.allocator.create(ScrollState);
            errdefer my_scope.allocator.destroy(state);
            state.* = ScrollState{};
            try my_scope.registerResource(@ptrCast(state), struct {
                fn destroy(ptr: *anyopaque, alloc: std.mem.Allocator) void {
                    const s: *ScrollState = @ptrCast(@alignCast(ptr));
                    alloc.destroy(s);
                }
            }.destroy);
            break :blk state;
        };
        container.addDebugState(@ptrCast(state));

        if (p.content_height) |ch| state.content_height = ch;
        if (p.content_width) |cw| state.content_width = cw;
        state.rubber_band_y_enabled = p.rubber_band_y;
        state.rubber_band_x_enabled = p.rubber_band_x;
        if (p.height) |h| {
            if (state.viewport_height == 0) state.viewport_height = h - p.padding.vertical();
        }
        if (p.width) |w| {
            if (state.viewport_width == 0) state.viewport_width = w - p.padding.horizontal();
        }

        // Node on_cleanup relay cell: must outlive my_scope (see ScrollCtxCell),
        // so attached to Cx for cleanup fallback, not my_scope.
        // After registration, ownership goes to Cx (deinit unified cleanup), so errdefer only
        // covers
        // the 'allocated but not yet registered' window, use block to limit scope.
        const cell = blk: {
            const c = try allocator.create(ScrollCtxCell);
            errdefer allocator.destroy(c);
            c.* = .{};
            try cx.registerScrollCtxCell(.{
                .ptr = @ptrCast(c),
                .destroyFn = struct {
                    fn destroy(ptr: *anyopaque, alloc: std.mem.Allocator) void {
                        const cc: *ScrollCtxCell = @ptrCast(@alignCast(ptr));
                        alloc.destroy(cc);
                    }
                }.destroy,
            });
            break :blk c;
        };

        // Scope allocates ScrollEventCtx
        const event_ctx = blk: {
            const event_ctx = try my_scope.allocator.create(ScrollEventCtx);
            errdefer my_scope.allocator.destroy(event_ctx);
            event_ctx.* = ScrollEventCtx{
                .state = state,
                .cell = cell,
                .content = content,
                .container = container,
                .scrollbar = scrollbar_v,
                .scrollbar_h = scrollbar_h,
                .cx = cx,
                .scroll_speed = p.scroll_speed,
                .direction = p.direction,
                .scrollbar_thumb = cx.tokens.tokens.color.scrollbar_thumb,
            };
            try my_scope.registerResource(@ptrCast(event_ctx), struct {
                fn destroy(ptr: *anyopaque, alloc: std.mem.Allocator) void {
                    const s: *ScrollEventCtx = @ptrCast(@alignCast(ptr));
                    // ctx vanishes here: sever relay cell backref. Node still alive but unbound:
                    // callbacks see cell.ctx == null, safe no-op.
                    if (s.cell) |c| c.ctx = null;
                    alloc.destroy(s);
                }
            }.destroy);

            break :blk event_ctx;
        };
        cell.ctx = event_ctx;
        // Node may outlive scope.dispose() for one reuse cycle (e.g., VirtualList slot rebind).
        // Unbind event_ctx-based hooks/handlers before freeing ScrollEventCtx to avoid dangling
        // pointers.
        try my_scope.onCleanup(ScrollEventCtx, event_ctx, detachScrollAreaBindings);
        container.behavior.events.on_event = scrollEventHandler;
        container.behavior.events.event_context = event_ctx;
        container.behavior.events.scroll_direction_hint = switch (p.direction) {
            .vertical => .vertical,
            .horizontal => .horizontal,
            .both => .both,
        };
        container.meta.per_frame.hooks.before_render.main = scrollbarBeforeRender;

        // Scrollbar attaches its own handler for hitTest hit + drag interaction handling
        scrollbar_v.behavior.events.on_event = scrollbarEventHandler;
        scrollbar_v.behavior.events.event_context = event_ctx;

        // Horizontal scrollbar attaches handler
        scrollbar_h.behavior.events.on_event = scrollbarHEventHandler;
        scrollbar_h.behavior.events.event_context = event_ctx;

        // Reverse: node freed before scope (e.g., ancestor freeNode releases container children,
        // but
        // ScrollArea scope is subtree of outer scope, cleanup runs on outer dispose)
        // -> on node freeNode, immediately null the event_ctx field,
        //   then detachScrollAreaBindings skips on null to avoid use-after-free.
        // Context is **cell not event_ctx**: node may outlive ctx and unbinding can't reach it
        // (see ScrollCtxCell). Writing cell is always safe, null ctx is safe no-op.
        container.meta.ownership.hooks.on_cleanup = .{ .callback = clearContainerOnNodeFree, .context = @ptrCast(cell) };
        scrollbar_v.meta.ownership.hooks.on_cleanup = .{ .callback = clearScrollbarOnNodeFree, .context = @ptrCast(cell) };
        scrollbar_h.meta.ownership.hooks.on_cleanup = .{ .callback = clearScrollbarHOnNodeFree, .context = @ptrCast(cell) };
        content.meta.ownership.hooks.on_cleanup = .{ .callback = clearContentOnNodeFree, .context = @ptrCast(cell) };

        // Apply initial scroll position
        content.style.translate_y = state.contentTranslateY();
        content.style.translate_x = state.contentTranslateX();

        // Register ScrollArea container to PropertyTree.scrolls + InteractionTable.
        // Write real scroll_id to InteractionTable for layerize's PromotionHint to recognize.
        // ScrollArea state also holds scroll_id for updateScrollOffset during scroll.
        if (container.element_id_raw != 0xFFFFFFFF) {
            const cx_core = @import("../../core.zig");
            const property_tree_mod = @import("../../core/property_tree.zig");
            const eid = cx_core.world.ElementId.fromRaw(container.element_id_raw);

            const w_size: f32 = if (p.width) |w| w else 0;
            const h_size: f32 = if (p.height) |h| h else 0;
            const scroll_id = cx.property_tree.appendScroll(.{
                .parent = property_tree_mod.INVALID_ID,
                .transform_id = property_tree_mod.INVALID_ID,
                .node_id = container.id,
                .content_size = .{ .width = w_size, .height = h_size },
                .viewport_size = .{ .width = w_size, .height = h_size },
            }) catch property_tree_mod.INVALID_ID;

            // Registration failure = scroll_id allocated but layerize's PromotionHint never sees
            // it,
            // manifests as silent scroll failure (no error). Propagate here, don't swallow.
            try cx.world.interaction.put(eid, .{
                .scroll_id = scroll_id,
            });

            state.world_scroll_id = scroll_id;
            state.world_ref = @ptrCast(&cx.world);
        }

        return .{ .container = container, .content = content, .state = state };
    }
}

// ============================================================================
// Programmatic scroll: public API
//
// Apps scrolling an element into view must not write `state.scroll_y` directly: that
// skips three essentials (clamp, momentum/bounce reset, translate pixel alignment),
// leaving residual momentum scrolling content away and text half-pixel jitter.
// This is the single correct entry point.
// ============================================================================

/// Alignment mode
pub const ScrollAlign = enum {
    /// If fully visible, don't scroll (minimum motion to bring into view)
    nearest,
    /// Align element top to viewport top
    start,
    /// Align element bottom to viewport bottom
    end,
    /// Center element in viewport
    center,
};

/// Programmatically set vertical scroll position. **Only correct way to write scroll_y.**
///
/// Does: clamp to [0, maxScrollY], zero rubber-band bonus and spring velocity,
/// cancel in-flight rebound animation, snap translate_y to pixel_scale grid.
pub fn setScrollY(state: *ScrollState, content: *Node, y: f32) void {
    const clamped = std.math.clamp(y, 0, state.maxScrollY());
    state.scroll_y = clamped;
    // Reset momentum/rebound together; else residual inertia pushes content away next frames
    state.bonus_y = 0;
    state.bonus_velocity = 0;
    state.bounce_active_y = false;
    state.momentum_spent_y = false;
    // Pixel-snap like scrollbarBeforeRender to eliminate text jitter
    content.style.translate_y = state.contentTranslateY();
    content.markCompositePropDirty();
}

/// Scroll [top, top+height) content range vertically into view.
///
/// `top` is offset in **content coordinates** (element's distance from content top,
/// not including current scroll_y).
pub fn scrollRectIntoView(
    state: *ScrollState,
    content: *Node,
    top: f32,
    height: f32,
    alignment: ScrollAlign,
) void {
    const vh = state.viewport_height;
    const bottom = top + height;
    const cur = state.scroll_y;

    const target: f32 = switch (alignment) {
        .start => top,
        .end => bottom - vh,
        .center => top + (height - vh) / 2,
        .nearest => blk: {
            if (top < cur) break :blk top; // Above viewport -> align top
            if (bottom > cur + vh) break :blk bottom - vh; // Below viewport -> align bottom
            break :blk cur; // Fully visible -> no-op
        },
    };
    setScrollY(state, content, target);
}

/// Scroll a **fully laid-out** node into view.
///
/// Uses node-vs-content rect delta for content coords; must call after layout
/// (zero rect is no-op, won't scroll viewport to weird position).
pub fn scrollIntoView(
    state: *ScrollState,
    content: *Node,
    node: *Node,
    alignment: ScrollAlign,
) void {
    const nr = node.rectFromWorldOrFallback();
    if (nr.h <= 0) return; // Not yet laid out: don't scroll viewport to weird position with zero rect

    // Accumulate layout-local y along parent chain up to content: that's the
    // content-coordinate offset (not including content's translate/scroll, as needed).
    var top: f32 = 0;
    var cur: ?*Node = node;
    var found = false;
    while (cur) |n| {
        if (n == content) {
            found = true;
            break;
        }
        top += n.rectFromWorldOrFallback().y;
        cur = n.parent;
    }
    if (!found) return; // node not in this ScrollArea

    scrollRectIntoView(state, content, top, nr.h, alignment);
}

pub const ScrollEventCtx = state_mod.ScrollEventCtx;
pub const ScrollCtxCell = state_mod.ScrollCtxCell;

fn clearContainerOnNodeFree(ctx: *anyopaque) void {
    const cell: *ScrollCtxCell = @ptrCast(@alignCast(ctx));
    if (cell.ctx) |event_ctx| event_ctx.container = null;
}

fn clearScrollbarOnNodeFree(ctx: *anyopaque) void {
    const cell: *ScrollCtxCell = @ptrCast(@alignCast(ctx));
    if (cell.ctx) |event_ctx| event_ctx.scrollbar = null;
}

fn clearScrollbarHOnNodeFree(ctx: *anyopaque) void {
    const cell: *ScrollCtxCell = @ptrCast(@alignCast(ctx));
    if (cell.ctx) |event_ctx| event_ctx.scrollbar_h = null;
}

fn clearContentOnNodeFree(ctx: *anyopaque) void {
    const cell: *ScrollCtxCell = @ptrCast(@alignCast(ctx));
    if (cell.ctx) |event_ctx| event_ctx.content = null;
}

fn detachScrollAreaBindings(event_ctx: *ScrollEventCtx) void {
    const raw_ctx: *anyopaque = @ptrCast(event_ctx);
    // on_cleanup context is cell (see mountScrollArea), compare by cell here.
    const raw_cell: ?*anyopaque = if (event_ctx.cell) |c| @ptrCast(c) else null;

    // IMPORTANT: must clear on_cleanup on each node **before** event_ctx is freed by scope.
    // Else node's freeNode invokes callback to freed ScrollEventCtx (clearContainerOnNodeFree/
    // clearContentOnNodeFree, etc), UAF. Critical path for Textarea/VirtualList with embedded
    // ScrollArea: on outer cx.deinit the nodes survive until freeNode, but my_scope has already
    // been disposed.

    if (event_ctx.container) |container| {
        if (container.behavior.events.event_context == raw_ctx) {
            if (container.behavior.events.on_event == scrollEventHandler) {
                container.behavior.events.on_event = null;
            }
            if (container.meta.per_frame.hooks.before_render.main == scrollbarBeforeRender) {
                container.meta.per_frame.hooks.before_render.main = null;
            }
            container.behavior.events.event_context = null;
            container.behavior.events.scroll_direction_hint = null;
        }
        if (container.meta.ownership.hooks.on_cleanup) |cu| {
            if (raw_cell != null and cu.context == raw_cell.? and cu.callback == clearContainerOnNodeFree) {
                container.meta.ownership.hooks.on_cleanup = null;
            }
        }
        event_ctx.container = null;
    }

    if (event_ctx.scrollbar) |scrollbar| {
        if (scrollbar.behavior.events.event_context == raw_ctx) {
            if (scrollbar.behavior.events.on_event == scrollbarEventHandler) {
                scrollbar.behavior.events.on_event = null;
            }
            scrollbar.behavior.events.event_context = null;
        }
        if (scrollbar.meta.ownership.hooks.on_cleanup) |cu| {
            if (raw_cell != null and cu.context == raw_cell.? and cu.callback == clearScrollbarOnNodeFree) {
                scrollbar.meta.ownership.hooks.on_cleanup = null;
            }
        }
        event_ctx.scrollbar = null;
    }

    if (event_ctx.scrollbar_h) |scrollbar_h| {
        if (scrollbar_h.behavior.events.event_context == raw_ctx) {
            if (scrollbar_h.behavior.events.on_event == scrollbarHEventHandler) {
                scrollbar_h.behavior.events.on_event = null;
            }
            scrollbar_h.behavior.events.event_context = null;
        }
        if (scrollbar_h.meta.ownership.hooks.on_cleanup) |cu| {
            if (raw_cell != null and cu.context == raw_cell.? and cu.callback == clearScrollbarHOnNodeFree) {
                scrollbar_h.meta.ownership.hooks.on_cleanup = null;
            }
        }
        event_ctx.scrollbar_h = null;
    }

    if (event_ctx.content) |content| {
        if (content.meta.ownership.hooks.on_cleanup) |cu| {
            if (raw_cell != null and cu.context == raw_cell.? and cu.callback == clearContentOnNodeFree) {
                content.meta.ownership.hooks.on_cleanup = null;
            }
        }
        event_ctx.content = null;
    }
}

fn scrollbarHitProxyProvider(node: *const Node, _: ?*anyopaque, out: []HitProxySpec) usize {
    // NOTE: ScrollArea nested-chain tests rely on node.rect direct read (World vs scrollbar rect
    // write order).
    // Session 31 attempted World hook switch, reverted.
    if (out.len < 2 or node.rectFromWorldOrFallback().w <= 0 or node.rectFromWorldOrFallback().h <= 0) return 0;
    const slop = ScrollbarVisual.hover_slop;
    out[0] = .{
        .local_rect = ComputedRect.init(-slop, -slop, node.rectFromWorldOrFallback().w + slop * 2, node.rectFromWorldOrFallback().h + slop * 2),
        .shape = .{ .rounded_rect = node.style.border.radius },
        .behavior = .self_only,
    };
    out[1] = .{
        .local_rect = ComputedRect.init(0, 0, node.rectFromWorldOrFallback().w, node.rectFromWorldOrFallback().h),
        .shape = .{ .rounded_rect = node.style.border.radius },
        .behavior = .self_only,
    };
    return 2;
}

// ========== Tests ==========

test "ScrollArea: basic vertical" {
    var ctx = try Cx.init(std.testing.allocator, std.testing.io);
    defer ctx.deinit();

    const root = try box(ctx, .{ .width = .{ .px = 400 }, .height = .{ .px = 300 } }, .{});
    ctx.root = root;

    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);

    defer scope.dispose();

    const result = try ScrollArea(.{
        .width = 300,
        .height = 200,
    }).mount(scope, ctx);

    try root.appendChild(std.testing.allocator, result.container);

    for (0..10) |_| {
        const item = try box(ctx, .{
            .width = .{ .grow = .{} },
            .height = .{ .px = 40 },
            .background = theme.dark.tokens.color.bg_tertiary,
        }, .{});
        try result.content.appendChild(std.testing.allocator, item);
    }

    // content + scrollbar (vertical) + scrollbar (horizontal)
    try std.testing.expectEqual(@as(usize, 3), result.container.children.items.len);
    try std.testing.expectEqual(@as(usize, 10), result.content.children.items.len);
    try std.testing.expect(result.container.style.overflow_hidden);
}

test "ScrollArea: scroll state" {
    var ctx = try Cx.init(std.testing.allocator, std.testing.io);
    defer ctx.deinit();

    const root = try box(ctx, .{ .width = .{ .px = 400 }, .height = .{ .px = 300 } }, .{});
    ctx.root = root;

    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);

    defer scope.dispose();

    const result = try ScrollArea(.{
        .width = 300,
        .height = 200,
        .content_height = 600,
    }).mount(scope, ctx);

    try root.appendChild(std.testing.allocator, result.container);
    ctx.layout();

    try std.testing.expectEqual(@as(f32, 0), result.content.style.translate_y);

    const event = core.Event{ .scroll = .{ .x = 150, .y = 100, .dx = 0, .dy = -1 } };
    const handler_result = scrollEventHandler(event, result.container.behavior.events.event_context);
    try std.testing.expectEqual(core.EventResult.stop, handler_result);
    try std.testing.expect(result.content.style.translate_y < 0);
}

/// Single 300x200 vertical ScrollArea (content 600), return mounted result.
fn mountTestScrollArea(ctx: *Cx, scope: *Scope) !ScrollAreaResult {
    const root = try box(ctx, .{ .width = .{ .px = 400 }, .height = .{ .px = 300 } }, .{});
    ctx.root = root;
    const result = try ScrollArea(.{
        .width = 300,
        .height = 200,
        .content_height = 600,
    }).mount(scope, ctx);
    try root.appendChild(std.testing.allocator, result.container);
    ctx.layout();
    return result;
}

fn testState(result: ScrollAreaResult) *ScrollState {
    const event_ctx: *ScrollEventCtx = @ptrCast(@alignCast(result.container.behavior.events.event_context.?));
    return event_ctx.state;
}

fn sendScroll(result: ScrollAreaResult, ev: @import("../../events.zig").ScrollEvent) core.EventResult {
    return scrollEventHandler(.{ .scroll = ev }, result.container.behavior.events.event_context);
}

fn settleSpring(state: *ScrollState) void {
    var ms: f64 = 1000.0;
    state.tickBonus(ms);
    while ((state.bounce_active_y or state.bounce_active_x) and ms < 4000.0) {
        ms += 16.667;
        state.tickBonus(ms);
        state.tickBonusX(ms);
    }
}

test "ScrollArea: lifting while overscrolled hands outward momentum to the spring" {
    var ctx = try Cx.init(std.testing.allocator, std.testing.io);
    defer ctx.deinit();
    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);
    defer scope.dispose();
    const result = try mountTestScrollArea(ctx, scope);
    const state = testState(result);

    // Finger drags content past bottom
    state.scroll_y = state.maxScrollY();
    _ = sendScroll(result, .{ .x = 150, .y = 100, .dx = 0, .dy = 0, .phase = .began });
    _ = sendScroll(result, .{ .x = 150, .y = 100, .dx = 0, .dy = -30, .phase = .changed });
    try std.testing.expect(state.touching);
    try std.testing.expect(state.bonus_y > 0);
    _ = sendScroll(result, .{ .x = 150, .y = 100, .dx = 0, .dy = 0, .phase = .ended });
    try std.testing.expect(!state.touching);

    // After release, outward inertia no longer pushes; overscroll goes to spring
    const bonus_at_lift = state.bonus_y;
    try std.testing.expectEqual(core.EventResult.stop, sendScroll(result, .{ .x = 150, .y = 100, .dx = 0, .dy = -80, .momentum = .began }));
    try std.testing.expectEqual(bonus_at_lift, state.bonus_y);
    try std.testing.expectEqual(state.maxScrollY(), state.scroll_y);

    // After rebound completes, outward inertia tail won't overscroll again
    settleSpring(state);
    try std.testing.expectEqual(@as(f32, 0), state.bonus_y);
    _ = sendScroll(result, .{ .x = 150, .y = 100, .dx = 0, .dy = -80, .momentum = .changed });
    try std.testing.expectEqual(@as(f32, 0), state.bonus_y);

    // Inward inertia scrolls normally
    _ = sendScroll(result, .{ .x = 150, .y = 100, .dx = 0, .dy = 20, .momentum = .changed });
    try std.testing.expect(state.scroll_y < state.maxScrollY());
}

test "ScrollArea: momentum that reaches the edge bounces once per stream" {
    var ctx = try Cx.init(std.testing.allocator, std.testing.io);
    defer ctx.deinit();
    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);
    defer scope.dispose();
    const result = try mountTestScrollArea(ctx, scope);
    const state = testState(result);

    state.scroll_y = 5;
    _ = sendScroll(result, .{ .x = 150, .y = 100, .dx = 0, .dy = 40, .momentum = .began });
    try std.testing.expectEqual(@as(f32, 0), state.scroll_y);
    try std.testing.expect(state.bonus_y < 0);
    try std.testing.expect(state.momentum_spent_y);

    settleSpring(state);
    for (0..5) |_| {
        _ = sendScroll(result, .{ .x = 150, .y = 100, .dx = 0, .dy = 30, .momentum = .changed });
        try std.testing.expectEqual(@as(f32, 0), state.bonus_y);
    }

    // Next gesture can pull overscroll again
    _ = sendScroll(result, .{ .x = 150, .y = 100, .dx = 0, .dy = 0, .phase = .began });
    try std.testing.expect(!state.momentum_spent_y);
    _ = sendScroll(result, .{ .x = 150, .y = 100, .dx = 0, .dy = 20, .phase = .changed });
    try std.testing.expect(state.bonus_y < 0);
}

test "ScrollArea: momentum means the finger is up, so the spring can run" {
    var ctx = try Cx.init(std.testing.allocator, std.testing.io);
    defer ctx.deinit();
    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);
    defer scope.dispose();
    const result = try mountTestScrollArea(ctx, scope);
    const state = testState(result);

    _ = sendScroll(result, .{ .x = 150, .y = 100, .dx = 0, .dy = 20, .phase = .changed });
    try std.testing.expect(state.touching);
    // ended event lost, momentum arrives directly
    _ = sendScroll(result, .{ .x = 150, .y = 100, .dx = 0, .dy = 5, .momentum = .began });
    try std.testing.expect(!state.touching);
    try std.testing.expect(state.momentum_active);
}

test "ScrollArea: inputActive follows begin/end signals without timers" {
    var ctx = try Cx.init(std.testing.allocator, std.testing.io);
    defer ctx.deinit();
    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);
    defer scope.dispose();
    const result = try mountTestScrollArea(ctx, scope);
    const state = testState(result);
    state.scroll_y = 200;

    try std.testing.expect(!state.inputActive());
    _ = sendScroll(result, .{ .x = 150, .y = 100, .dx = 0, .dy = 0, .phase = .began });
    _ = sendScroll(result, .{ .x = 150, .y = 100, .dx = 0, .dy = -10, .phase = .changed });
    try std.testing.expect(state.inputActive());
    _ = sendScroll(result, .{ .x = 150, .y = 100, .dx = 0, .dy = 0, .phase = .ended });
    try std.testing.expect(!state.inputActive());
    _ = sendScroll(result, .{ .x = 150, .y = 100, .dx = 0, .dy = -10, .momentum = .began });
    try std.testing.expect(state.inputActive());
    // Won't auto-revert to idle; depends on signal only
    for (0..100) |_| scrollbarBeforeRender(result.container);
    try std.testing.expect(state.inputActive());
    _ = sendScroll(result, .{ .x = 150, .y = 100, .dx = 0, .dy = 0, .momentum = .ended });
    try std.testing.expect(!state.inputActive());

    // New gesture interrupts inertia
    _ = sendScroll(result, .{ .x = 150, .y = 100, .dx = 0, .dy = -10, .momentum = .began });
    _ = sendScroll(result, .{ .x = 150, .y = 100, .dx = 0, .dy = 0, .phase = .may_begin });
    try std.testing.expect(!state.momentum_active);
}

test "ScrollArea: input_serial counts applied input only" {
    var ctx = try Cx.init(std.testing.allocator, std.testing.io);
    defer ctx.deinit();
    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);
    defer scope.dispose();
    const result = try mountTestScrollArea(ctx, scope);
    const state = testState(result);
    state.scroll_y = 200;

    const s0 = state.input_serial;
    _ = sendScroll(result, .{ .x = 150, .y = 100, .dx = 0, .dy = -10 });
    try std.testing.expectEqual(s0 + 1, state.input_serial);
    _ = sendScroll(result, .{ .x = 150, .y = 100, .dx = 0, .dy = -10, .phase = .changed });
    try std.testing.expectEqual(s0 + 2, state.input_serial);
    _ = sendScroll(result, .{ .x = 150, .y = 100, .dx = 0, .dy = 0, .phase = .ended });
    try std.testing.expectEqual(s0 + 2, state.input_serial);
}

test "ScrollArea: mouse wheel stops at the edge without rubber band" {
    var ctx = try Cx.init(std.testing.allocator, std.testing.io);
    defer ctx.deinit();
    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);
    defer scope.dispose();
    const result = try mountTestScrollArea(ctx, scope);
    const state = testState(result);

    state.scroll_y = 3;
    _ = sendScroll(result, .{ .x = 150, .y = 100, .dx = 0, .dy = 40 });
    try std.testing.expectEqual(@as(f32, 0), state.scroll_y);
    try std.testing.expectEqual(@as(f32, 0), state.bonus_y);
    try std.testing.expect(!state.touching);
    try std.testing.expect(!state.inputActive());
}

test "ScrollArea: finger down catches a running bounce" {
    var ctx = try Cx.init(std.testing.allocator, std.testing.io);
    defer ctx.deinit();
    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);
    defer scope.dispose();
    const result = try mountTestScrollArea(ctx, scope);
    const state = testState(result);

    state.bonus_y = -20;
    state.tickBonus(1000.0);
    state.tickBonus(1032.0);
    try std.testing.expect(state.bounce_active_y);
    const held = state.bonus_y;

    _ = sendScroll(result, .{ .x = 150, .y = 100, .dx = 0, .dy = 0, .phase = .may_begin });
    try std.testing.expect(state.touching);
    try std.testing.expect(!state.bounce_active_y);
    try std.testing.expectEqual(held, state.bonus_y);
    // Spring doesn't run while pressed
    state.tickBonus(1100.0);
    try std.testing.expectEqual(held, state.bonus_y);
    // Spring takes over on release
    _ = sendScroll(result, .{ .x = 150, .y = 100, .dx = 0, .dy = 0, .phase = .cancelled });
    settleSpring(state);
    try std.testing.expectEqual(@as(f32, 0), state.bonus_y);
}

test "ScrollArea: nested chain delegates outward boundary scroll to ancestor" {
    var ctx = try Cx.init(std.testing.allocator, std.testing.io);
    defer ctx.deinit();

    const root = try box(ctx, .{ .width = .{ .px = 500 }, .height = .{ .px = 400 } }, .{});
    ctx.root = root;

    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);

    defer scope.dispose();

    const outer = try ScrollArea(.{
        .width = 320,
        .height = 220,
    }).mount(scope, ctx);
    try root.appendChild(std.testing.allocator, outer.container);

    const inner = try ScrollArea(.{
        .width = 280,
        .height = 120,
        .content_height = 420,
    }).mount(scope, ctx);
    try outer.content.appendChild(std.testing.allocator, inner.container);

    const spacer = try box(ctx, .{
        .width = .{ .grow = .{} },
        .height = .{ .px = 420 },
    }, .{});
    try outer.content.appendChild(std.testing.allocator, spacer);

    ctx.layout();

    const outer_ctx: *ScrollEventCtx = @ptrCast(@alignCast(outer.container.behavior.events.event_context.?));
    const inner_ctx: *ScrollEventCtx = @ptrCast(@alignCast(inner.container.behavior.events.event_context.?));
    outer_ctx.state.scroll_y = 0;
    outer_ctx.state.bonus_y = 0;
    inner_ctx.state.scroll_y = 0;
    inner_ctx.state.bonus_y = 0;

    const inner_global = inner.container.globalRect();
    const px = inner_global.x + 8;
    const py = inner_global.y + 8;
    ctx.handleScroll(.{ .x = px, .y = py, .dx = 0, .dy = 8, .phase = .changed });

    try std.testing.expectEqual(@as(f32, 0), inner_ctx.state.scroll_y);
    try std.testing.expectEqual(@as(f32, 0), inner_ctx.state.bonus_y);
    try std.testing.expect(outer_ctx.state.bonus_y < 0);
}

test "ScrollArea: nested chain delegates on boundary crossing frame" {
    var ctx = try Cx.init(std.testing.allocator, std.testing.io);
    defer ctx.deinit();

    const root = try box(ctx, .{ .width = .{ .px = 500 }, .height = .{ .px = 400 } }, .{});
    ctx.root = root;

    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);

    defer scope.dispose();

    const outer = try ScrollArea(.{
        .width = 320,
        .height = 220,
    }).mount(scope, ctx);
    try root.appendChild(std.testing.allocator, outer.container);

    const inner = try ScrollArea(.{
        .width = 280,
        .height = 120,
        .content_height = 420,
    }).mount(scope, ctx);
    try outer.content.appendChild(std.testing.allocator, inner.container);

    const spacer = try box(ctx, .{
        .width = .{ .grow = .{} },
        .height = .{ .px = 420 },
    }, .{});
    try outer.content.appendChild(std.testing.allocator, spacer);

    ctx.layout();
    _ = ctx.render(); // Ensure hitTest scene updates

    const outer_ctx: *ScrollEventCtx = @ptrCast(@alignCast(outer.container.behavior.events.event_context.?));
    const inner_ctx: *ScrollEventCtx = @ptrCast(@alignCast(inner.container.behavior.events.event_context.?));
    outer_ctx.state.scroll_y = 0;
    outer_ctx.state.bonus_y = 0;
    inner_ctx.state.scroll_y = 2; // Not yet at boundary, but will overscroll this frame
    inner_ctx.state.bonus_y = 0;

    const inner_global = inner.container.globalRect();
    const px = inner_global.x + 8;
    const py = inner_global.y + 8;
    ctx.handleScroll(.{ .x = px, .y = py, .dx = 0, .dy = 8, .phase = .changed });

    try std.testing.expectEqual(@as(f32, 0), inner_ctx.state.scroll_y);
    try std.testing.expectEqual(@as(f32, 0), inner_ctx.state.bonus_y);
    try std.testing.expect(outer_ctx.state.bonus_y < 0);
}

test "ScrollArea: nested chain snaps inner to boundary before delegating" {
    var ctx = try Cx.init(std.testing.allocator, std.testing.io);
    defer ctx.deinit();

    const root = try box(ctx, .{ .width = .{ .px = 500 }, .height = .{ .px = 400 } }, .{});
    ctx.root = root;

    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);

    defer scope.dispose();

    const outer = try ScrollArea(.{
        .width = 320,
        .height = 220,
    }).mount(scope, ctx);
    try root.appendChild(std.testing.allocator, outer.container);

    const inner = try ScrollArea(.{
        .width = 280,
        .height = 120,
        .content_height = 420,
    }).mount(scope, ctx);
    try outer.content.appendChild(std.testing.allocator, inner.container);

    const spacer = try box(ctx, .{
        .width = .{ .grow = .{} },
        .height = .{ .px = 420 },
    }, .{});
    try outer.content.appendChild(std.testing.allocator, spacer);

    ctx.layout();
    _ = ctx.render(); // Ensure hitTest scene updates

    const inner_ctx: *ScrollEventCtx = @ptrCast(@alignCast(inner.container.behavior.events.event_context.?));
    inner_ctx.state.scroll_y = inner_ctx.state.maxScrollY() - 2;
    inner_ctx.state.bonus_y = 0;

    const inner_global = inner.container.globalRect();
    const px = inner_global.x + 8;
    const py = inner_global.y + 8;
    ctx.handleScroll(.{ .x = px, .y = py, .dx = 0, .dy = -8, .phase = .changed });

    try std.testing.expectApproxEqAbs(inner_ctx.state.maxScrollY(), inner_ctx.state.scroll_y, 0.01);
    try std.testing.expectEqual(@as(f32, 0), inner_ctx.state.bonus_y);
}

test "ScrollArea: an outer layer holding the gesture keeps it over an inner one" {
    var ctx = try Cx.init(std.testing.allocator, std.testing.io);
    defer ctx.deinit();

    const root = try box(ctx, .{ .width = .{ .px = 500 }, .height = .{ .px = 400 } }, .{});
    ctx.root = root;
    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);
    defer scope.dispose();

    const outer = try ScrollArea(.{ .width = 320, .height = 220 }).mount(scope, ctx);
    try root.appendChild(std.testing.allocator, outer.container);
    const inner = try ScrollArea(.{ .width = 280, .height = 120, .content_height = 420 }).mount(scope, ctx);
    try outer.content.appendChild(std.testing.allocator, inner.container);
    const spacer = try box(ctx, .{ .width = .{ .grow = .{} }, .height = .{ .px = 420 } }, .{});
    try outer.content.appendChild(std.testing.allocator, spacer);
    ctx.layout();
    _ = ctx.render();

    const outer_state = testState(outer);
    const inner_state = testState(inner);
    inner_state.scroll_y = 60;
    const g = inner.container.globalRect();

    // outer idle: inner scrolls normally under pointer
    ctx.handleScroll(.{ .x = g.x + 8, .y = g.y + 8, .dx = 0, .dy = -6, .phase = .changed });
    try std.testing.expectEqual(@as(f32, 66), inner_state.scroll_y);
    ctx.handleScroll(.{ .x = g.x + 8, .y = g.y + 8, .dx = 0, .dy = 0, .phase = .ended });

    // outer holds gesture (finger on pad, content moves under pointer): no handoff to inner
    // mid-gesture
    outer_state.touching = true;
    const outer_before = outer_state.scroll_y;
    ctx.handleScroll(.{ .x = g.x + 8, .y = g.y + 8, .dx = 0, .dy = -6, .phase = .changed });
    try std.testing.expectEqual(@as(f32, 66), inner_state.scroll_y);
    try std.testing.expect(outer_state.scroll_y > outer_before);
}

test "ScrollArea: an outer bounce does not steal a gesture that starts on the inner layer" {
    var ctx = try Cx.init(std.testing.allocator, std.testing.io);
    defer ctx.deinit();

    const root = try box(ctx, .{ .width = .{ .px = 500 }, .height = .{ .px = 400 } }, .{});
    ctx.root = root;
    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);
    defer scope.dispose();

    const outer = try ScrollArea(.{ .width = 320, .height = 220 }).mount(scope, ctx);
    try root.appendChild(std.testing.allocator, outer.container);
    const inner = try ScrollArea(.{ .width = 280, .height = 120, .content_height = 420 }).mount(scope, ctx);
    try outer.content.appendChild(std.testing.allocator, inner.container);
    const spacer = try box(ctx, .{ .width = .{ .grow = .{} }, .height = .{ .px = 420 } }, .{});
    try outer.content.appendChild(std.testing.allocator, spacer);
    ctx.layout();
    _ = ctx.render();

    const outer_state = testState(outer);
    const inner_state = testState(inner);
    // outer is rebounding
    outer_state.bonus_y = -12;
    outer_state.tickBonus(1000.0);
    try std.testing.expect(outer_state.bounce_active_y);
    inner_state.scroll_y = 60;

    const g = inner.container.globalRect();
    ctx.handleScroll(.{ .x = g.x + 8, .y = g.y + 8, .dx = 0, .dy = 0, .phase = .began });
    try std.testing.expect(!outer_state.touching);
    ctx.handleScroll(.{ .x = g.x + 8, .y = g.y + 8, .dx = 0, .dy = -6, .phase = .changed });
    try std.testing.expectEqual(@as(f32, 66), inner_state.scroll_y);
}

test "ScrollArea: ended reaches every layer of a delegated nested gesture" {
    var ctx = try Cx.init(std.testing.allocator, std.testing.io);
    defer ctx.deinit();

    const root = try box(ctx, .{ .width = .{ .px = 500 }, .height = .{ .px = 400 } }, .{});
    ctx.root = root;
    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);
    defer scope.dispose();

    const outer = try ScrollArea(.{ .width = 320, .height = 220 }).mount(scope, ctx);
    try root.appendChild(std.testing.allocator, outer.container);
    const inner = try ScrollArea(.{ .width = 280, .height = 120, .content_height = 420 }).mount(scope, ctx);
    try outer.content.appendChild(std.testing.allocator, inner.container);
    const spacer = try box(ctx, .{ .width = .{ .grow = .{} }, .height = .{ .px = 420 } }, .{});
    try outer.content.appendChild(std.testing.allocator, spacer);
    ctx.layout();
    _ = ctx.render();

    const outer_state = testState(outer);
    const inner_state = testState(inner);
    // Gesture delegated to outer; inner retains prior overscroll amount
    outer_state.touching = true;
    inner_state.bonus_y = 5;

    const g = inner.container.globalRect();
    ctx.handleScroll(.{ .x = g.x + 8, .y = g.y + 8, .dx = 0, .dy = 0, .phase = .began });
    ctx.handleScroll(.{ .x = g.x + 8, .y = g.y + 8, .dx = 0, .dy = 0, .phase = .ended });
    try std.testing.expect(!outer_state.touching);
    try std.testing.expect(!inner_state.touching);
}

test "ScrollArea: a gesture whose ended was lost is cancelled when the next one begins" {
    var ctx = try Cx.init(std.testing.allocator, std.testing.io);
    defer ctx.deinit();

    const root = try box(ctx, .{ .width = .{ .px = 700 }, .height = .{ .px = 300 }, .direction = .row }, .{});
    ctx.root = root;
    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);
    defer scope.dispose();

    const a = try ScrollArea(.{ .width = 300, .height = 200, .content_height = 600 }).mount(scope, ctx);
    try root.appendChild(std.testing.allocator, a.container);
    const b = try ScrollArea(.{ .width = 300, .height = 200, .content_height = 600 }).mount(scope, ctx);
    try root.appendChild(std.testing.allocator, b.container);
    ctx.layout();
    _ = ctx.render();

    const a_state = testState(a);
    const b_state = testState(b);
    a_state.scroll_y = 100;
    b_state.scroll_y = 100;
    const ga = a.container.globalRect();
    const gb = b.container.globalRect();

    ctx.handleScroll(.{ .x = ga.x + 20, .y = ga.y + 20, .dx = 0, .dy = 0, .phase = .began });
    ctx.handleScroll(.{ .x = ga.x + 20, .y = ga.y + 20, .dx = 0, .dy = -10, .phase = .changed });
    try std.testing.expect(a_state.touching);

    ctx.handleScroll(.{ .x = gb.x + 20, .y = gb.y + 20, .dx = 0, .dy = 0, .phase = .began });
    ctx.handleScroll(.{ .x = gb.x + 20, .y = gb.y + 20, .dx = 0, .dy = -10, .phase = .changed });
    try std.testing.expect(!a_state.touching);
    try std.testing.expect(b_state.touching);
}

test "ScrollArea: window blur cancels an in-progress gesture" {
    var ctx = try Cx.init(std.testing.allocator, std.testing.io);
    defer ctx.deinit();
    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);
    defer scope.dispose();
    const result = try mountTestScrollArea(ctx, scope);
    _ = ctx.render();
    const state = testState(result);
    state.scroll_y = 200;

    const g = result.container.globalRect();
    ctx.handleScroll(.{ .x = g.x + 20, .y = g.y + 20, .dx = 0, .dy = 0, .phase = .began });
    ctx.handleScroll(.{ .x = g.x + 20, .y = g.y + 20, .dx = 0, .dy = -10, .phase = .changed });
    try std.testing.expect(state.touching);

    ctx.cancelPointerInteractions(.window_blur);
    try std.testing.expect(!state.touching);
    try std.testing.expect(!state.inputActive());
}

test "ScrollArea: window blur ends in-progress momentum" {
    var ctx = try Cx.init(std.testing.allocator, std.testing.io);
    defer ctx.deinit();
    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);
    defer scope.dispose();
    const result = try mountTestScrollArea(ctx, scope);
    _ = ctx.render();
    const state = testState(result);
    state.scroll_y = 200;

    const g = result.container.globalRect();
    ctx.handleScroll(.{ .x = g.x + 20, .y = g.y + 20, .dx = 0, .dy = 0, .phase = .began });
    ctx.handleScroll(.{ .x = g.x + 20, .y = g.y + 20, .dx = 0, .dy = -10, .phase = .changed });
    ctx.handleScroll(.{ .x = g.x + 20, .y = g.y + 20, .dx = 0, .dy = 0, .phase = .ended });
    ctx.handleScroll(.{ .x = g.x + 20, .y = g.y + 20, .dx = 0, .dy = -10, .momentum = .began });
    try std.testing.expect(state.momentum_active);

    ctx.cancelPointerInteractions(.window_blur);
    try std.testing.expect(!state.momentum_active);
}

test "ScrollArea: bounce animation blocks outward momentum" {
    const render_engine = @import("../../core/render_engine/mod.zig");
    render_engine.current_frame_time_ms = 1000.0;
    var state = ScrollState{
        .content_height = 500,
        .viewport_height = 200,
        .scroll_y = 0,
        .bonus_y = -20,
    };

    // Start rebound
    state.tickBonus(1016.0);
    state.tickBonus(1032.0);
    try std.testing.expect(state.bounce_active_y);

    // During animation, outward momentum should be rejected
    const scroll_event_mod = @import("event.zig");
    const bounce_active = scroll_event_mod.hasBounceActive(&state, .vertical);
    try std.testing.expect(bounce_active);

    // Run to completion
    var ms: f64 = 1000.0;
    while (state.bounce_active_y and ms < 3000.0) {
        ms += 16.667;
        state.tickBonus(ms);
    }
    try std.testing.expectEqual(@as(f32, 0), state.bonus_y);
    try std.testing.expect(!state.bounce_active_y);
}

fn mountBothInsideVertical(ctx: *Cx, scope: *Scope) !struct { outer: ScrollAreaResult, inner: ScrollAreaResult } {
    const root = try box(ctx, .{ .width = .{ .px = 500 }, .height = .{ .px = 400 } }, .{});
    ctx.root = root;
    const outer = try ScrollArea(.{ .width = 320, .height = 220 }).mount(scope, ctx);
    try root.appendChild(std.testing.allocator, outer.container);
    // Horizontal-only both area: content wider than viewport, same height
    const inner = try ScrollArea(.{ .width = 280, .height = 120, .direction = .both }).mount(scope, ctx);
    try outer.content.appendChild(std.testing.allocator, inner.container);
    const strip = try box(ctx, .{ .width = .{ .px = 900 }, .height = .{ .px = 120 } }, .{});
    try inner.content.appendChild(std.testing.allocator, strip);
    const spacer = try box(ctx, .{ .width = .{ .grow = .{} }, .height = .{ .px = 420 } }, .{});
    try outer.content.appendChild(std.testing.allocator, spacer);
    ctx.layout();
    _ = ctx.render();
    // Horizontal content width managed by host (Grid / VirtualList usage)
    const inner_state = testState(inner);
    inner_state.external_content_width = true;
    inner_state.content_width = 900;
    return .{ .outer = outer, .inner = inner };
}

test "ScrollArea: both mode hands a diagonal event to the layer of its dominant axis" {
    var ctx = try Cx.init(std.testing.allocator, std.testing.io);
    defer ctx.deinit();
    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);
    defer scope.dispose();
    const areas = try mountBothInsideVertical(ctx, scope);
    const outer_state = testState(areas.outer);
    const inner_state = testState(areas.inner);
    try std.testing.expectEqual(@as(f32, 0), inner_state.maxScrollY());
    const g = areas.inner.container.globalRect();

    // Vertical dominant: hand entire event to outer, preserve y component
    ctx.handleScroll(.{ .x = g.x + 8, .y = g.y + 8, .dx = -2, .dy = -8 });
    try std.testing.expectEqual(@as(f32, 8), outer_state.scroll_y);
    try std.testing.expectEqual(@as(f32, 0), inner_state.scroll_x);

    // Horizontal dominant: handle x here, discard small y per axis lock
    ctx.handleScroll(.{ .x = g.x + 8, .y = g.y + 8, .dx = -8, .dy = -2 });
    try std.testing.expectEqual(@as(f32, 8), inner_state.scroll_x);
    try std.testing.expectEqual(@as(f32, 8), outer_state.scroll_y);
}

test "ScrollArea: both mode keeps a held gesture when the dominant axis changes" {
    var ctx = try Cx.init(std.testing.allocator, std.testing.io);
    defer ctx.deinit();
    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);
    defer scope.dispose();
    const areas = try mountBothInsideVertical(ctx, scope);
    const outer_state = testState(areas.outer);
    const inner_state = testState(areas.inner);
    const g = areas.inner.container.globalRect();

    ctx.handleScroll(.{ .x = g.x + 8, .y = g.y + 8, .dx = 0, .dy = 0, .phase = .began });
    ctx.handleScroll(.{ .x = g.x + 8, .y = g.y + 8, .dx = -8, .dy = -1, .phase = .changed });
    try std.testing.expect(inner_state.touching);
    // Mid-gesture switch to vertical dominant: no handoff to outer
    ctx.handleScroll(.{ .x = g.x + 8, .y = g.y + 8, .dx = -1, .dy = -8, .phase = .changed });
    try std.testing.expectEqual(@as(f32, 0), outer_state.scroll_y);
    try std.testing.expectEqual(@as(f32, 9), inner_state.scroll_x);
}

test "ScrollArea: both mode keeps the momentum of a gesture it held" {
    var ctx = try Cx.init(std.testing.allocator, std.testing.io);
    defer ctx.deinit();
    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);
    defer scope.dispose();
    const areas = try mountBothInsideVertical(ctx, scope);
    const outer_state = testState(areas.outer);
    const inner_state = testState(areas.inner);
    const g = areas.inner.container.globalRect();

    ctx.handleScroll(.{ .x = g.x + 8, .y = g.y + 8, .dx = 0, .dy = 0, .phase = .began });
    ctx.handleScroll(.{ .x = g.x + 8, .y = g.y + 8, .dx = -8, .dy = -1, .phase = .changed });
    ctx.handleScroll(.{ .x = g.x + 8, .y = g.y + 8, .dx = 0, .dy = 0, .phase = .ended });
    // Inertia tail becomes vertical dominant: still inner's inertia, no leak to outer
    ctx.handleScroll(.{ .x = g.x + 8, .y = g.y + 8, .dx = -1, .dy = -6, .momentum = .changed });
    try std.testing.expectEqual(@as(f32, 0), outer_state.scroll_y);
    try std.testing.expectEqual(@as(f32, 9), inner_state.scroll_x);
}

test "ScrollArea: both mode does not inject bonus on non-scrollable axis" {
    var ctx = try Cx.init(std.testing.allocator, std.testing.io);
    defer ctx.deinit();

    const root = try box(ctx, .{ .width = .{ .px = 600 }, .height = .{ .px = 400 } }, .{});
    ctx.root = root;

    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);
    defer scope.dispose();

    const result = try ScrollArea(.{
        .width = 300,
        .height = 200,
        .direction = .both,
        .content_height = 200,
        .content_width = 500,
    }).mount(scope, ctx);
    try root.appendChild(std.testing.allocator, result.container);
    ctx.layout();

    const event_ctx: *ScrollEventCtx = @ptrCast(@alignCast(result.container.behavior.events.event_context.?));
    const state = event_ctx.state;
    try std.testing.expectEqual(@as(f32, 0), state.maxScrollY());
    try std.testing.expect(state.maxScrollX() > 0);

    const y_only = core.Event{
        .scroll = .{
            .x = 150,
            .y = 100,
            .dx = 0,
            .dy = 24,
            .phase = .changed,
        },
    };
    const routed = scrollEventHandler(y_only, result.container.behavior.events.event_context);
    try std.testing.expectEqual(core.EventResult.ignored, routed);
    try std.testing.expectEqual(@as(f32, 0), state.bonus_y);
}

test "ScrollArea: both-mode momentum x bounce does not block vertical scrolling" {
    var ctx = try Cx.init(std.testing.allocator, std.testing.io);
    defer ctx.deinit();

    const root = try box(ctx, .{ .width = .{ .px = 600 }, .height = .{ .px = 400 } }, .{});
    ctx.root = root;

    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);
    defer scope.dispose();

    const result = try ScrollArea(.{
        .width = 300,
        .height = 200,
        .direction = .both,
        .content_height = 1200,
        .content_width = 1200,
    }).mount(scope, ctx);
    try root.appendChild(std.testing.allocator, result.container);
    ctx.layout();

    const event_ctx: *ScrollEventCtx = @ptrCast(@alignCast(result.container.behavior.events.event_context.?));
    const state = event_ctx.state;
    state.scroll_x = 0;
    state.scroll_y = 329;
    state.bonus_x = -0.04;
    state.bonus_y = 0;

    const momentum_vertical = core.Event{
        .scroll = .{
            .x = 150,
            .y = 100,
            .dx = 0,
            .dy = -38,
            .momentum = .changed,
        },
    };

    const handled = scrollEventHandler(momentum_vertical, result.container.behavior.events.event_context);
    try std.testing.expectEqual(core.EventResult.stop, handled);
    try std.testing.expectEqual(@as(f32, 367), state.scroll_y);
    try std.testing.expectApproxEqAbs(@as(f32, -0.04), state.bonus_x, 0.001);
}

test "ScrollArea: isOutwardAtBoundary both returns false when no active delta" {
    const state = ScrollState{
        .content_height = 600,
        .viewport_height = 200,
        .content_width = 800,
        .viewport_width = 300,
        .scroll_y = 20,
        .scroll_x = 40,
    };
    try std.testing.expect(!isOutwardAtBoundary(&state, .both, 0, 0, 1.0));
}

test "ScrollState: effectiveScrollY with bonus" {
    var state = ScrollState{
        .content_height = 500,
        .viewport_height = 200,
    };

    // Normal range: effective = scroll_y (bonus=0)
    state.scroll_y = 100;
    try std.testing.expectEqual(@as(f32, 100), state.effectiveScrollY());

    // With bonus: effective = scroll_y + bonus
    state.scroll_y = 0;
    state.bonus_y = -90;
    try std.testing.expectEqual(@as(f32, -90), state.effectiveScrollY());

    state.scroll_y = 300;
    state.bonus_y = 60;
    try std.testing.expectEqual(@as(f32, 360), state.effectiveScrollY());
}

test "ScrollState: duration-based bounce decay" {
    const render_engine = @import("../../core/render_engine/mod.zig");
    render_engine.current_frame_time_ms = 1000.0;
    var state = ScrollState{
        .content_height = 500,
        .viewport_height = 200,
    };

    state.bonus_y = 100;
    state.tickBonus(1000.0);
    // First frame: bonus should start decreasing
    try std.testing.expect(state.bonus_y <= 100);
    try std.testing.expect(state.bonus_y > 0);
    try std.testing.expect(state.bounce_active_y);

    // Run to completion
    var ms: f64 = 1000.0;
    while (state.bounce_active_y and ms < 3000.0) {
        ms += 16.667;
        state.tickBonus(ms);
    }
    try std.testing.expectEqual(@as(f32, 0), state.bonus_y);
    try std.testing.expect(!state.bounce_active_y);
}

test "ScrollState: bonus bounce blocked while touching" {
    const render_engine = @import("../../core/render_engine/mod.zig");
    render_engine.current_frame_time_ms = 1000.0;
    var state = ScrollState{
        .content_height = 500,
        .viewport_height = 200,
    };

    state.bonus_y = 100;
    state.touching = true;
    state.tickBonus(1000.0);
    // Spring doesn't start
    try std.testing.expect(!state.bounce_active_y);
    try std.testing.expectEqual(@as(f32, 100), state.bonus_y);
}

test "ScrollState: larger displacement settles later (critically damped spring)" {
    const render_engine = @import("../../core/render_engine/mod.zig");
    render_engine.current_frame_time_ms = 1000.0;
    var small = ScrollState{
        .content_height = 500,
        .viewport_height = 200,
        .bonus_y = 20,
    };
    var large = ScrollState{
        .content_height = 500,
        .viewport_height = 200,
        .bonus_y = 120,
    };

    small.tickBonus(1000.0);
    large.tickBonus(1000.0);

    var small_done_ms: f64 = 0;
    var large_done_ms: f64 = 0;
    var ms: f64 = 1000.0;
    while ((small.bounce_active_y or large.bounce_active_y) and ms < 3000.0) {
        ms += 16.667;
        small.tickBonus(ms);
        large.tickBonus(ms);
        if (!small.bounce_active_y and small_done_ms == 0) small_done_ms = ms;
        if (!large.bounce_active_y and large_done_ms == 0) large_done_ms = ms;
    }
    // Both converge to zero; larger displacement converges later
    try std.testing.expectEqual(@as(f32, 0), small.bonus_y);
    try std.testing.expectEqual(@as(f32, 0), large.bonus_y);
    try std.testing.expect(large_done_ms >= small_done_ms);
}

test "ScrollState: spring bounce carries inbound velocity (overshoot then return)" {
    var state = ScrollState{
        .content_height = 500,
        .viewport_height = 200,
        .bonus_y = 30,
        .bonus_velocity = 800, // Incoming inertia still pushes outward
    };
    state.tickBonus(1000.0);
    try std.testing.expect(state.bounce_active_y);

    // Should deepen briefly (velocity continuous -> smooth)
    state.tickBonus(1030.0);
    try std.testing.expect(state.bonus_y > 30);

    var ms: f64 = 1030.0;
    while (state.bounce_active_y and ms < 4000.0) {
        ms += 16.667;
        state.tickBonus(ms);
    }
    try std.testing.expectEqual(@as(f32, 0), state.bonus_y);
}

test "ScrollState: rubberBand round-trip (via physics.RubberBand)" {
    // clamp -> unclamp should restore original value (test via ScrollState.rubber_band)
    const rb = physics.RubberBand{};
    const dim: f32 = 200;
    const inputs = [_]f32{ 5, 20, 50, 100, -10, -80 };
    for (inputs) |input| {
        const clamped = rb.clamp(input, dim);
        const recovered = rb.unclamp(clamped, dim);
        try std.testing.expectApproxEqAbs(input, recovered, 0.1);
    }
}

test "ScrollState: rubberBand asymptotic (via physics.RubberBand)" {
    const rb = physics.RubberBand{};
    const dim: f32 = 200;
    // Small input: output < input (with damping) and close to input
    const small = rb.clamp(10, dim);
    try std.testing.expect(small > 0);
    try std.testing.expect(small <= 10.0);
    // Large input approaches dim asymptotically
    const large = rb.clamp(10000, dim);
    try std.testing.expect(large > 0);
    try std.testing.expect(large <= dim);
    // Monotonically increasing
    try std.testing.expect(large > small);
    // Symmetric for negative input
    const neg = rb.clamp(-50, dim);
    try std.testing.expect(neg < 0);
}

test "applyVerticalScroll: boundary bonus with damping" {
    var state = ScrollState{
        .content_height = 500,
        .viewport_height = 200,
    };

    // Normal scroll
    applyVerticalScroll(&state, -5, 1, .gesture);
    try std.testing.expectEqual(@as(f32, 0), state.bonus_y);
    try std.testing.expect(state.scroll_y > 0);

    // Overshoot top -> bonus becomes negative (with damping decay)
    state.scroll_y = 0;
    state.bonus_y = 0;
    applyVerticalScroll(&state, 10, 1, .gesture); // delta = -10
    try std.testing.expectEqual(@as(f32, 0), state.scroll_y);
    try std.testing.expect(state.bonus_y < 0);
    // Damping: |bonus| should be < 10 (after decay)
    try std.testing.expect(@abs(state.bonus_y) <= 10);

    // Overshoot bottom -> bonus becomes positive (with damping decay)
    state.scroll_y = 300;
    state.bonus_y = 0;
    applyVerticalScroll(&state, -10, 1, .gesture); // delta = +10
    try std.testing.expectEqual(@as(f32, 300), state.scroll_y);
    try std.testing.expect(state.bonus_y > 0);
    try std.testing.expect(state.bonus_y <= 10);

    // Repeated overshoot: damping accumulates, each increment smaller
    state.scroll_y = 0;
    state.bonus_y = 0;
    applyVerticalScroll(&state, 5, 1, .gesture);
    const first_bonus = @abs(state.bonus_y);
    const prev_bonus = state.bonus_y;
    applyVerticalScroll(&state, 5, 1, .gesture);
    const second_increment = @abs(state.bonus_y - prev_bonus);
    try std.testing.expect(second_increment < first_bonus);
}

test "ScrollState: scrollbar metrics" {
    var state = ScrollState{
        .content_height = 1000,
        .viewport_height = 200,
    };

    try std.testing.expect(state.needsScrollbar());
    try std.testing.expectEqual(@as(f32, 40), state.scrollbarHeight());

    state.scroll_y = 0;
    try std.testing.expectEqual(@as(f32, 2), state.scrollbarY());

    state.scroll_y = 800;
    try std.testing.expectEqual(@as(f32, 158), state.scrollbarY());

    state.content_height = 100;
    try std.testing.expect(!state.needsScrollbar());
}

test "ScrollState: overscroll shrinks vertical thumb and pins to edge" {
    var state = ScrollState{
        .content_height = 1000,
        .viewport_height = 200,
        .scroll_y = 400,
    };

    const base = computeVerticalScrollbarMetrics(&state);
    try std.testing.expectApproxEqAbs(@as(f32, 40), base.length, 0.01);

    state.scroll_y = 0;
    state.bonus_y = -28;
    const top = computeVerticalScrollbarMetrics(&state);
    try std.testing.expect(top.length < base.length);
    try std.testing.expectApproxEqAbs(@as(f32, 2), top.pos, 0.01);

    state.scroll_y = state.maxScrollY();
    state.bonus_y = 28;
    const bottom = computeVerticalScrollbarMetrics(&state);
    try std.testing.expect(bottom.length < base.length);
    try std.testing.expectApproxEqAbs(@as(f32, 198), bottom.pos + bottom.length, 0.05);
}

test "ScrollArea: scrollbar thumb rect updates in before-render hook" {
    var ctx = try Cx.init(std.testing.allocator, std.testing.io);
    defer ctx.deinit();

    const root = try box(ctx, .{ .width = .{ .px = 400 }, .height = .{ .px = 300 } }, .{});
    ctx.root = root;

    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);

    defer scope.dispose();

    const result = try ScrollArea(.{
        .width = 300,
        .height = 200,
        .content_height = 1000,
        .padding = Padding.all(10),
    }).mount(scope, ctx);
    try root.appendChild(std.testing.allocator, result.container);
    ctx.layout();

    const event_ctx: *ScrollEventCtx = @ptrCast(@alignCast(result.container.behavior.events.event_context.?));
    const state = event_ctx.state;
    state.scrollbar_fade.opacity = 1.0;

    state.scroll_y = state.maxScrollY() / 2;
    scrollbarBeforeRender(result.container);

    const thumb_node = result.container.children.items[1];
    try std.testing.expectApproxEqAbs(@as(f32, ScrollbarVisual.idle_thickness), thumb_node.rectFromWorldOrFallback().w, 0.01);
    const expected_x = result.container.rectFromWorldOrFallback().x + result.container.rectFromWorldOrFallback().w - thumb_node.rectFromWorldOrFallback().w - ScrollbarVisual.edge_inset;
    try std.testing.expectApproxEqAbs(expected_x, thumb_node.rectFromWorldOrFallback().x, 0.01);
    const first_y = thumb_node.rectFromWorldOrFallback().y;
    try std.testing.expect(first_y > result.container.rectFromWorldOrFallback().y + result.container.style.padding.top);

    state.scroll_y = state.maxScrollY();
    scrollbarBeforeRender(result.container);
    try std.testing.expect(thumb_node.rectFromWorldOrFallback().y > first_y);
}

test "ScrollArea: scope dispose detaches before-render hook and event handlers" {
    var ctx = try Cx.init(std.testing.allocator, std.testing.io);
    defer ctx.deinit();

    const root = try box(ctx, .{ .width = .{ .px = 400 }, .height = .{ .px = 300 } }, .{});
    ctx.root = root;

    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);
    var scope_disposed = false;
    defer if (!scope_disposed) scope.dispose();

    const result = try ScrollArea(.{
        .width = 300,
        .height = 200,
        .content_height = 600,
    }).mount(scope, ctx);
    try root.appendChild(std.testing.allocator, result.container);

    const scrollbar_v = result.container.children.items[1];
    const scrollbar_h = result.container.children.items[2];

    scope.dispose();
    scope_disposed = true;

    try std.testing.expect(result.container.behavior.events.on_event == null);
    try std.testing.expect(result.container.behavior.events.event_context == null);
    try std.testing.expect(result.container.meta.per_frame.hooks.before_render.main == null);
    try std.testing.expect(scrollbar_v.behavior.events.on_event == null);
    try std.testing.expect(scrollbar_v.behavior.events.event_context == null);
    try std.testing.expect(scrollbar_h.behavior.events.on_event == null);
    try std.testing.expect(scrollbar_h.behavior.events.event_context == null);

    scrollbarBeforeRender(result.container);
}

test "ScrollState: scrollbar fade" {
    var state = ScrollState{
        .content_height = 500,
        .viewport_height = 200,
    };

    state.onScrollActivity();
    try std.testing.expectEqual(@as(f32, 0.7), state.scrollbar_fade.opacity);

    for (0..90) |_| _ = state.tickScrollbar();
    try std.testing.expectEqual(@as(f32, 0.7), state.scrollbar_fade.opacity);

    _ = state.tickScrollbar();
    try std.testing.expect(state.scrollbar_fade.opacity < 0.7);

    for (0..40) |_| _ = state.tickScrollbar();
    try std.testing.expectEqual(@as(f32, 0), state.scrollbar_fade.opacity);

    state.onScrollActivity();
    state.scrollbar_hovered = true;
    _ = state.tickScrollbar();
    try std.testing.expectEqual(@as(f32, 1.0), state.scrollbar_fade.opacity);
}

test "ScrollState: scrollbar fade tick stays idle while opacity is unchanged" {
    var state = ScrollState{
        .content_height = 500,
        .viewport_height = 200,
    };

    state.onScrollActivity();
    try std.testing.expectEqual(@as(f32, 0.7), state.scrollbar_fade.opacity);

    var i: usize = 0;
    while (i < state.scrollbar_fade.fade_delay) : (i += 1) {
        const changed = state.tickScrollbar();
        try std.testing.expect(!changed);
        try std.testing.expectEqual(@as(f32, 0.7), state.scrollbar_fade.opacity);
    }

    const changed = state.tickScrollbar();
    try std.testing.expect(changed);
    try std.testing.expect(state.scrollbar_fade.opacity < 0.7);
}

// -- Programmatic scroll API ----------------

test "setScrollY: clamp + 动量复位 + 像素对齐（裸写 scroll_y 三样全没有）" {
    const testing = std.testing;
    var cx = try Cx.init(testing.allocator, std.testing.io);
    defer cx.deinit();
    const content = try box(cx, .{ .width = .{ .px = 200 }, .height = .{ .px = 1000 } }, .{});
    cx.root = content;

    var state = ScrollState{
        .content_height = 1000,
        .viewport_height = 200,
        .pixel_scale = 2.0,
    };
    // Fabricate 'residual inertia + in-flight rebound' scenario
    state.bonus_y = 37;
    state.bonus_velocity = 900;
    state.bounce_active_y = true;
    state.momentum_spent_y = true;

    setScrollY(&state, content, 300.4);

    try testing.expectEqual(@as(f32, 300.4), state.scroll_y);
    // Reset momentum/rebound; else next frames' inertia pushes content away
    try testing.expectEqual(@as(f32, 0), state.bonus_y);
    try testing.expectEqual(@as(f32, 0), state.bonus_velocity);
    try testing.expect(!state.bounce_active_y);
    try testing.expect(!state.momentum_spent_y);
    // Snap translate to physical pixel grid (pixel_scale=2 -> 0.5px grid)
    const ty = content.style.translate_y;
    try testing.expectEqual(@as(f32, -300.5), ty);

    // Clamp both top and bottom
    setScrollY(&state, content, -100);
    try testing.expectEqual(@as(f32, 0), state.scroll_y);
    setScrollY(&state, content, 99999);
    try testing.expectEqual(@as(f32, 800), state.scroll_y); // maxScrollY = 1000-200
}

test "scrollRectIntoView: 四种对齐" {
    const testing = std.testing;
    var cx = try Cx.init(testing.allocator, std.testing.io);
    defer cx.deinit();
    const content = try box(cx, .{ .width = .{ .px = 200 }, .height = .{ .px = 1000 } }, .{});
    cx.root = content;

    var state = ScrollState{ .content_height = 1000, .viewport_height = 200 };

    // start: align top
    scrollRectIntoView(&state, content, 500, 40, .start);
    try testing.expectEqual(@as(f32, 500), state.scroll_y);
    // end: align bottom to viewport bottom
    scrollRectIntoView(&state, content, 500, 40, .end);
    try testing.expectEqual(@as(f32, 340), state.scroll_y); // 540 - 200
    // center: center in viewport
    scrollRectIntoView(&state, content, 500, 40, .center);
    try testing.expectEqual(@as(f32, 420), state.scroll_y); // 500 + (40-200)/2

    // nearest: fully visible -> no-op
    state.scroll_y = 480;
    scrollRectIntoView(&state, content, 500, 40, .nearest);
    try testing.expectEqual(@as(f32, 480), state.scroll_y);
    // nearest: below viewport -> align bottom (min motion)
    state.scroll_y = 200;
    scrollRectIntoView(&state, content, 500, 40, .nearest);
    try testing.expectEqual(@as(f32, 340), state.scroll_y);
    // nearest: above viewport -> align top
    state.scroll_y = 700;
    scrollRectIntoView(&state, content, 500, 40, .nearest);
    try testing.expectEqual(@as(f32, 500), state.scroll_y);
}

test "scrollIntoView: 按节点 rect 把子节点滚进视野" {
    const testing = std.testing;
    var cx = try Cx.init(testing.allocator, std.testing.io);
    defer cx.deinit();

    const root = try box(cx, .{ .width = .{ .px = 200 }, .height = .{ .px = 200 } }, .{});
    cx.root = root;
    const scope = try Scope.init(testing.allocator, null, cx.owner);
    defer scope.dispose();

    const sa = try ScrollArea(.{ .width = 200, .height = 200 }).mount(scope, cx);
    try root.appendChild(testing.allocator, sa.container);

    sa.state.content_height = 1000;
    sa.state.viewport_height = 200;
    sa.state.external_content_height = true;

    // Create child at content y=600, height 40 (with intermediate container, verify ancestor chain)
    const mid = try box(cx, .{ .width = .{ .px = 200 }, .height = .{ .px = 1000 } }, .{});
    const target = try box(cx, .{ .width = .{ .px = 200 }, .height = .{ .px = 40 } }, .{});
    try sa.content.appendChild(testing.allocator, mid);
    try mid.appendChild(testing.allocator, target);
    mid.setLayoutRect(.{ .x = 0, .y = 100, .w = 200, .h = 1000 });
    target.setLayoutRect(.{ .x = 0, .y = 500, .w = 200, .h = 40 });

    // Content coordinate top = 100 + 500 = 600
    scrollIntoView(sa.state, sa.content, target, .start);
    try testing.expectEqual(@as(f32, 600), sa.state.scroll_y);

    scrollIntoView(sa.state, sa.content, target, .end);
    try testing.expectEqual(@as(f32, 440), sa.state.scroll_y); // 640 - 200

    // Node outside ScrollArea -> no-op, won't scroll viewport away
    const outsider = try box(cx, .{ .width = .{ .px = 10 }, .height = .{ .px = 10 } }, .{});
    try root.appendChild(testing.allocator, outsider); // Attached outside ScrollArea
    outsider.setLayoutRect(.{ .x = 0, .y = 0, .w = 10, .h = 10 });
    const before = sa.state.scroll_y;
    scrollIntoView(sa.state, sa.content, outsider, .start);
    try testing.expectEqual(before, sa.state.scroll_y);

    // Unlaid-out (h=0) is also no-op
    const unlaid = try box(cx, .{ .width = .{ .px = 10 }, .height = .{ .px = 10 } }, .{});
    try sa.content.appendChild(testing.allocator, unlaid);
    scrollIntoView(sa.state, sa.content, unlaid, .start);
    try testing.expectEqual(before, sa.state.scroll_y);
}

test "ScrollArea: mountScrollArea 在任意分配点失败时不泄漏" {
    // OOM injection of PlainTextEditor.mount: 98 leak stacks top out at mountScrollArea, but
    // in isolation it leaks 0. Stack tops show *where* memory was allocated, not *who* must free.
    // The real bug was in the caller (LineVirtualList): missing errdefer on my_scope and
    // sa.container.
    //
    // Regression guard: don't regress mountScrollArea's cleanup contract.
    const t = std.testing;

    // First measure how many allocation points a successful call consumes.
    const total_allocs = blk: {
        var arena = std.heap.ArenaAllocator.init(t.allocator);
        defer arena.deinit();
        var counting = t.FailingAllocator.init(arena.allocator(), .{});
        const ctx = try Cx.init(counting.allocator(), std.testing.io);
        defer ctx.deinit();
        const scope = try Scope.init(counting.allocator(), null, ctx.owner);
        defer scope.dispose();
        const before = counting.alloc_index;
        _ = try ScrollArea(.{ .width = 300, .height = 200 }).mount(scope, ctx);
        break :blk counting.alloc_index - before;
    };
    try t.expect(total_allocs > 0);

    var induced: usize = 0;
    var leaked: usize = 0;
    var first_leak: ?usize = null;

    for (0..total_allocs) |failure_index| {
        // Each injection point uses independent GPA; use deinit() == .leak to detect leaks.
        // Arena would reclaim leaks as a whole, hiding these defects.
        var gpa = std.heap.DebugAllocator(.{ .safety = true }){};
        {
            var failing = t.FailingAllocator.init(gpa.allocator(), .{});
            const ctx = Cx.init(failing.allocator(), std.testing.io) catch {
                _ = gpa.deinit();
                continue;
            };
            const scope = Scope.init(failing.allocator(), null, ctx.owner) catch {
                ctx.deinit();
                _ = gpa.deinit();
                continue;
            };

            failing.fail_index = failing.alloc_index + failure_index;
            failing.resize_fail_index = failing.resize_index + failure_index;
            const result = ScrollArea(.{ .width = 300, .height = 200 }).mount(scope, ctx);
            failing.fail_index = std.math.maxInt(usize);
            failing.resize_fail_index = std.math.maxInt(usize);

            if (result) |r| {
                // Success: caller owns this detached subtree.
                ctx.freeNode(r.container);
            } else |_| {
                induced += 1;
            }
            scope.dispose();
            ctx.deinit();
        }
        if (gpa.deinit() == .leak) {
            leaked += 1;
            if (first_leak == null) first_leak = failure_index;
        }
    }

    // No-op guard uses ratio not absolute floor (calibration as oom_sweep.zig): induced > 0
    // threshold is three orders below measured value, can't block allocation-point collapse.
    const min_induced = total_allocs / 2;
    if (induced < min_induced) {
        std.debug.print(
            "\n[{s}] sweep 覆盖坍塌: induced={d} / total_allocs={d}（要求 >= {d}）\n",
            .{ "scroll_area", induced, total_allocs, min_induced },
        );
    }
    try t.expect(induced >= min_induced);
    if (leaked > 0) {
        std.debug.print(
            "\n[scroll_area] LEAK at {d}/{d} failure points; first={?d}\n",
            .{ leaked, total_allocs, first_leak },
        );
    }
    try t.expectEqual(@as(usize, 0), leaked);
}

test "ScrollArea: mountScrollArea 在 childScope 下失败时不泄漏" {
    // Prior test used root scope and didn't attach container to any parent tree, result clean.
    // Consumer (downstream editor line_virtual_list) calls differently: passes scope.childScope()
    // derived scope, and container later attaches to main_lane. This test replicates that pattern
    // to determine if 'dependency-side leak' needs consumer context.
    const t = std.testing;

    const total_allocs = blk: {
        var arena = std.heap.ArenaAllocator.init(t.allocator);
        defer arena.deinit();
        var counting = t.FailingAllocator.init(arena.allocator(), .{});
        const ctx = try Cx.init(counting.allocator(), std.testing.io);
        defer ctx.deinit();
        const root_scope = try Scope.init(counting.allocator(), null, ctx.owner);
        defer root_scope.dispose();
        const child = try root_scope.childScope();
        const before = counting.alloc_index;
        _ = try ScrollArea(.{ .width = 300, .height = 200 }).mount(child, ctx);
        break :blk counting.alloc_index - before;
    };
    try t.expect(total_allocs > 0);

    var induced: usize = 0;
    var leaked: usize = 0;
    var first_leak: ?usize = null;

    for (0..total_allocs) |failure_index| {
        var gpa = std.heap.DebugAllocator(.{ .safety = true }){};
        {
            var failing = t.FailingAllocator.init(gpa.allocator(), .{});
            const ctx = Cx.init(failing.allocator(), std.testing.io) catch {
                _ = gpa.deinit();
                continue;
            };
            const root_scope = Scope.init(failing.allocator(), null, ctx.owner) catch {
                ctx.deinit();
                _ = gpa.deinit();
                continue;
            };
            const parent = box(ctx, .{ .width = .{ .px = 400 }, .height = .{ .px = 300 } }, .{}) catch {
                root_scope.dispose();
                ctx.deinit();
                _ = gpa.deinit();
                continue;
            };
            const child = root_scope.childScope() catch {
                ctx.freeNode(parent);
                root_scope.dispose();
                ctx.deinit();
                _ = gpa.deinit();
                continue;
            };

            failing.fail_index = failing.alloc_index + failure_index;
            failing.resize_fail_index = failing.resize_index + failure_index;
            const result = ScrollArea(.{ .width = 300, .height = 200 }).mount(child, ctx);
            const appended = if (result) |r| blk2: {
                parent.appendChild(failing.allocator(), r.container) catch break :blk2 false;
                break :blk2 true;
            } else |_| false;
            failing.fail_index = std.math.maxInt(usize);
            failing.resize_fail_index = std.math.maxInt(usize);

            if (result) |r| {
                if (!appended) ctx.freeNode(r.container);
            } else |_| {
                induced += 1;
                // KEY: on failure path, **only dispose scope, don't freeNode separately**.
                // This matches consumer LineVirtualList pattern: when mountScrollArea fails
                // internally,
                // caller doesn't get sa, relies on scope cleanup alone. If we freeNode here too,
                // we mask the defect (first version did this, showed 0 leaks).
            }
            // Order matches consumer pt_editor.mount errdefer: dispose scope first, then freeNode.
            root_scope.dispose();
            ctx.freeNode(parent);
            ctx.deinit();
        }
        if (gpa.deinit() == .leak) {
            leaked += 1;
            if (first_leak == null) first_leak = failure_index;
        }
    }

    // No-op guard uses ratio not absolute floor (calibration as oom_sweep.zig): induced > 0
    // threshold is three orders below measured value, can't block allocation-point collapse.
    const min_induced = total_allocs / 2;
    if (induced < min_induced) {
        std.debug.print(
            "\n[{s}] sweep 覆盖坍塌: induced={d} / total_allocs={d}（要求 >= {d}）\n",
            .{ "scroll_area", induced, total_allocs, min_induced },
        );
    }
    try t.expect(induced >= min_induced);
    if (leaked > 0) {
        std.debug.print(
            "\n[scroll_area/childScope] LEAK at {d}/{d} failure points; first={?d}\n",
            .{ leaked, total_allocs, first_leak },
        );
    }
    try t.expectEqual(@as(usize, 0), leaked);
}

test "ScrollArea: fit + max 被夹住的列容器里收缩成可滚动，px 兄弟不被推出容器" {
    // Pattern like popover chrome height-limited by autosize: head(px) + ScrollArea(fit) +
    // footer(px).
    // Pre-fix: layoutChildren didn't recompute fit child's intrinsic, overflow underestimated,
    // ScrollArea still laid out at content height 300, footer pushed to y=320 (container only 100
    // tall).
    const t = std.testing;
    var ctx = try Cx.init(t.allocator, std.testing.io);
    defer ctx.deinit();
    const root = try box(ctx, .{ .width = .{ .px = 400 }, .height = .{ .px = 800 }, .align_items = .start }, .{});
    ctx.root = root;
    const scope = try Scope.init(t.allocator, null, ctx.owner);
    defer scope.dispose();

    const panel = try box(ctx, .{ .width = .{ .px = 300 }, .height = .{ .fit = .{ .max = 100 } }, .direction = .column, .overflow_hidden = true }, .{});
    try root.appendChild(t.allocator, panel);
    const head = try box(ctx, .{ .width = .{ .grow = .{} }, .height = .{ .px = 20 }, .flex_shrink = 0 }, .{});
    try panel.appendChild(t.allocator, head);
    const sa = try ScrollArea(.{}).mount(scope, ctx);
    sa.container.style.height = .{ .fit = .{} };
    try panel.appendChild(t.allocator, sa.container);
    for (0..10) |_| {
        const row = try box(ctx, .{ .width = .{ .grow = .{} }, .height = .{ .px = 30 } }, .{});
        try sa.content.appendChild(t.allocator, row);
    }
    const foot = try box(ctx, .{ .width = .{ .grow = .{} }, .height = .{ .px = 20 }, .flex_shrink = 0 }, .{});
    try panel.appendChild(t.allocator, foot);

    ctx.layout();
    const p = panel.globalRect();
    try t.expectApproxEqAbs(@as(f32, 100), p.h, 0.5);
    // Container squeezed to 100 - 20 - 20, content stays 300 (not squashed, can scroll)
    try t.expectApproxEqAbs(@as(f32, 60), sa.container.globalRect().h, 0.5);
    try t.expectApproxEqAbs(@as(f32, 300), sa.content.globalRect().h, 0.5);
    // footer fully inside container
    const f = foot.globalRect();
    try t.expectApproxEqAbs(@as(f32, 20), f.h, 0.5);
    try t.expect(f.y + f.h <= p.y + p.h + 0.5);

    // Enough space: no shrink, content-driven as usual
    panel.style.height = .{ .fit = .{ .max = 1000 } };
    panel.markSizingDirty();
    ctx.layout();
    try t.expectApproxEqAbs(@as(f32, 340), panel.globalRect().h, 0.5);
    try t.expectApproxEqAbs(@as(f32, 300), sa.container.globalRect().h, 0.5);
}

test "ScrollArea: ext.max_height（popover autosize 的写法）夹住的列容器里同样收缩可滚" {
    const t = std.testing;
    var ctx = try Cx.init(t.allocator, std.testing.io);
    defer ctx.deinit();
    const root = try box(ctx, .{ .width = .{ .px = 400 }, .height = .{ .px = 800 }, .align_items = .start }, .{});
    ctx.root = root;
    const scope = try Scope.init(t.allocator, null, ctx.owner);
    defer scope.dispose();

    const panel = try box(ctx, .{ .width = .{ .px = 300 }, .height = .{ .fit = .{} }, .direction = .column, .overflow_hidden = true }, .{});
    try root.appendChild(t.allocator, panel);
    (try panel.style.ensureExtFallible(t.allocator)).max_height = 100;
    const sa = try ScrollArea(.{}).mount(scope, ctx);
    sa.container.style.height = .{ .fit = .{} };
    try panel.appendChild(t.allocator, sa.container);
    for (0..10) |_| {
        const row = try box(ctx, .{ .width = .{ .grow = .{} }, .height = .{ .px = 30 } }, .{});
        try sa.content.appendChild(t.allocator, row);
    }
    const foot = try box(ctx, .{ .width = .{ .grow = .{} }, .height = .{ .px = 20 }, .flex_shrink = 0 }, .{});
    try panel.appendChild(t.allocator, foot);

    ctx.layout();
    const p = panel.globalRect();
    try t.expectApproxEqAbs(@as(f32, 100), p.h, 0.5);
    try t.expectApproxEqAbs(@as(f32, 80), sa.container.globalRect().h, 0.5);
    try t.expectApproxEqAbs(@as(f32, 300), sa.content.globalRect().h, 0.5);
    const f = foot.globalRect();
    try t.expect(f.y + f.h <= p.y + p.h + 0.5);
}

test "ScrollArea: px 0 + overflow_hidden 的隐藏容器里，fit 可收缩子节点保持内容尺寸（隐藏惯用法）" {
    // Modal closed: barrier = px 0 + overflow_hidden (same as showNode). On hidden children,
    // content size must stay clipped-only; shrink rules on px parent would crush to 0. After
    // Quick Open reopens, panel stuck at 0 height (observed with native gate
    // panel_infra/save_path_identity).
    const t = std.testing;
    var ctx = try Cx.init(t.allocator, std.testing.io);
    defer ctx.deinit();
    const root = try box(ctx, .{ .width = .{ .px = 400 }, .height = .{ .px = 800 }, .align_items = .start }, .{});
    ctx.root = root;
    const scope = try Scope.init(t.allocator, null, ctx.owner);
    defer scope.dispose();

    const hidden = try box(ctx, .{ .width = .{ .px = 0 }, .height = .{ .px = 0 }, .direction = .column, .overflow_hidden = true }, .{});
    try root.appendChild(t.allocator, hidden);
    const dialog = try box(ctx, .{ .width = .{ .px = 300 }, .height = .{ .fit = .{ .max = 600 } }, .direction = .column, .overflow_hidden = true }, .{});
    try hidden.appendChild(t.allocator, dialog);
    const sa = try ScrollArea(.{}).mount(scope, ctx);
    sa.container.style.height = .{ .fit = .{} };
    try dialog.appendChild(t.allocator, sa.container);
    for (0..4) |_| {
        const row = try box(ctx, .{ .width = .{ .grow = .{} }, .height = .{ .px = 30 } }, .{});
        try sa.content.appendChild(t.allocator, row);
    }

    ctx.layout();
    try t.expectApproxEqAbs(@as(f32, 120), dialog.globalRect().h, 0.5);
    try t.expectApproxEqAbs(@as(f32, 120), sa.container.globalRect().h, 0.5);
}
