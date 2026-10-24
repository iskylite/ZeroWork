const std = @import("std");
const types = @import("core/types.zig");

pub const Rect = types.ComputedRect;

pub const Placement = enum {
    top,
    top_start,
    top_end,
    bottom,
    bottom_start,
    bottom_end,
    left,
    left_start,
    left_end,
    right,
    right_start,
    right_end,
};

pub const Side = enum {
    top,
    bottom,
    left,
    right,
};

pub const Overflow = struct {
    top: f32,
    right: f32,
    bottom: f32,
    left: f32,
};

/// Offset value, can be static or derivable (caller provides fn(state) -> f32, computed dynamic by
/// placement). Align floating-ui `OffsetOptions` support `Derivable<OffsetValue>`.
/// Typical use: when a docs popover flips to the opposite side of the cursor, offset by an extra
/// line_height to clear the cursor row:
///   .main_axis = .{ .derive = .{ .ctx = popup_ptr, .compute = computeOffsetByPlacement } }
pub const OffsetValue = union(enum) {
    static: f32,
    derive: struct {
        ctx: ?*anyopaque,
        compute: *const fn (ctx: ?*anyopaque, state: OffsetDeriveState) f32,
    },

    pub fn resolve(self: OffsetValue, state: OffsetDeriveState) f32 {
        return switch (self) {
            .static => |v| v,
            .derive => |d| d.compute(d.ctx, state),
        };
    }
};

/// Offset derivable callback's state (caller decides value by placement).
pub const OffsetDeriveState = struct {
    placement: Placement,
    reference: Rect,
    floating: Rect,
};

pub const OffsetOptions = struct {
    main_axis: OffsetValue = .{ .static = 0 },
    cross_axis: OffsetValue = .{ .static = 0 },
};

pub const FlipOptions = struct {
    /// Reserve the same viewport margin used by shift/autosize. Otherwise a
    /// placement can appear to fit here and lose content to the later cap.
    padding: f32 = 0,
    /// Fallback placement list tried when preferred overflows. Empty default = classic 2-way flip
    /// (preferred <-> opposite). Align floating-ui `fallbackPlacements`. Typical (docs panel):
    /// `fallback_placements = &.{.right_start, .bottom_start, .top_start}` means 'right doesn't fit
    /// try bottom, bottom try top, **never flip left** (avoid sidebar occlusion)'.
    fallback_placements: []const Placement = &.{},
};

pub const ShiftOptions = struct {
    padding: f32 = 0,
    main_axis: bool = false,
    cross_axis: bool = true,
};

pub const SizeOptions = struct {
    padding: f32 = 0,
};

/// Autosize: max width/height available in current placement becomes floating commit constraint.
/// Differs from `size`: `size` advisory (writes middleware_data.size, caller decides), `autosize`
/// commits (writes autosize, caller applies as max_width/max_height hard ceiling in layout,
/// overflow scrolls). Typical chain: offset -> flip -> shift -> autosize (let flip/shift decide
/// final placement, autosize then computes available space).
pub const AutosizeOptions = struct {
    padding: f32 = 0,
    apply_width: bool = true,
    apply_height: bool = true,
};

pub const Middleware = union(enum) {
    offset: OffsetOptions,
    flip: FlipOptions,
    shift: ShiftOptions,
    size: SizeOptions,
    autosize: AutosizeOptions,
};

pub const OffsetData = struct {
    x: f32,
    y: f32,
};

pub const FlipData = struct {
    placement: Placement,
    overflow: Overflow,
};

pub const ShiftData = struct {
    x: f32,
    y: f32,
    overflow: Overflow,
};

pub const SizeData = struct {
    available_width: f32,
    available_height: f32,
};

/// Autosize middleware output, caller applies these as floating layout hard ceiling.
pub const AutosizeData = struct {
    committed_max_width: f32,
    committed_max_height: f32,
    apply_width: bool,
    apply_height: bool,
};

pub const MiddlewareData = struct {
    offset: ?OffsetData = null,
    flip: ?FlipData = null,
    shift: ?ShiftData = null,
    size: ?SizeData = null,
    autosize: ?AutosizeData = null,
};

pub const ComputePositionConfig = struct {
    placement: Placement = .bottom_start,
    middleware: []const Middleware = &.{},
    /// Group layout coordination: list of 'rectangles already occupied by prior popover'.
    /// flip/shift/autosize treat these as 'soft boundaries', don't penetrate: flip: candidate
    /// placement overlaps any excluded rect -> treat as overflow, trigger flip/fallback; shift:
    /// push popover clear of excluded rect during cross-axis correction; autosize:
    /// available_width/height deducts excluded rect occupation. Rects must be absolute screen
    /// coords (viewport space). Empty = single popover behavior, zero overhead.
    excluded_rects: []const Rect = &.{},
};

pub const ComputePositionResult = struct {
    x: f32,
    y: f32,
    placement: Placement,
    middleware_data: MiddlewareData,
};

pub fn getSide(pos: Placement) Side {
    return switch (pos) {
        .top, .top_start, .top_end => .top,
        .bottom, .bottom_start, .bottom_end => .bottom,
        .left, .left_start, .left_end => .left,
        .right, .right_start, .right_end => .right,
    };
}

pub fn getOppositePlacement(pos: Placement) Placement {
    return switch (pos) {
        .top => .bottom,
        .top_start => .bottom_start,
        .top_end => .bottom_end,
        .bottom => .top,
        .bottom_start => .top_start,
        .bottom_end => .top_end,
        .left => .right,
        .left_start => .right_start,
        .left_end => .right_end,
        .right => .left,
        .right_start => .left_start,
        .right_end => .left_end,
    };
}

pub fn computeTranslate(pos: Placement, tw: f32, th: f32, fw: f32, fh: f32, main_axis_offset: f32) [2]f32 {
    return switch (pos) {
        .top => .{ (tw - fw) / 2, -fh - main_axis_offset },
        .top_start => .{ 0, -fh - main_axis_offset },
        .top_end => .{ tw - fw, -fh - main_axis_offset },
        .bottom => .{ (tw - fw) / 2, th + main_axis_offset },
        .bottom_start => .{ 0, th + main_axis_offset },
        .bottom_end => .{ tw - fw, th + main_axis_offset },
        .left => .{ -fw - main_axis_offset, (th - fh) / 2 },
        .left_start => .{ -fw - main_axis_offset, 0 },
        .left_end => .{ -fw - main_axis_offset, th - fh },
        .right => .{ tw + main_axis_offset, (th - fh) / 2 },
        .right_start => .{ tw + main_axis_offset, 0 },
        .right_end => .{ tw + main_axis_offset, th - fh },
    };
}

pub fn computeOverflow(
    pos: Placement,
    reference: Rect,
    floating: Rect,
    viewport: Rect,
    main_axis_offset: f32,
    padding: f32,
) Overflow {
    const translate = computeTranslate(pos, reference.w, reference.h, floating.w, floating.h, main_axis_offset);
    const x = reference.x + translate[0];
    const y = reference.y + translate[1];
    return computeOverflowFromCoords(x, y, floating, viewport, padding);
}

pub fn mainAxisOverflow(overflow: Overflow, side: Side) f32 {
    return switch (side) {
        .top => overflow.top,
        .bottom => overflow.bottom,
        .left => overflow.left,
        .right => overflow.right,
    };
}

pub fn flipPlacement(
    preferred: Placement,
    reference: Rect,
    floating: Rect,
    viewport: Rect,
    main_axis_offset: f32,
    padding: f32,
) Placement {
    const opposite = getOppositePlacement(preferred);
    const candidates = [_]Placement{ preferred, opposite };

    var best = preferred;
    var best_overflow: f32 = std.math.inf(f32);

    for (candidates) |candidate| {
        const overflow = computeOverflow(candidate, reference, floating, viewport, main_axis_offset, padding);
        const current = mainAxisOverflow(overflow, getSide(candidate));
        if (current <= 0) return candidate;
        if (current < best_overflow) {
            best_overflow = current;
            best = candidate;
        }
    }

    return best;
}

/// Group-aware flip: over classic flip/fallback, treat 'candidate placement overlaps any excluded
/// rect' as unavailable (infinite overflow, force fallback). Empty excluded_rects -> bitwise
/// identical flipPlacement.
pub fn flipPlacementGroupAware(
    preferred: Placement,
    fallbacks: []const Placement,
    reference: Rect,
    floating: Rect,
    viewport: Rect,
    main_axis_offset: f32,
    padding: f32,
    excluded: []const Rect,
) Placement {
    // Compute effective overflow for placement: viewport main-axis overflow + overlap excluded rect
    // -> add INF.
    const score = struct {
        fn s(p: Placement, ref: Rect, flt: Rect, vp: Rect, mo: f32, pad: f32, ex: []const Rect) f32 {
            const ov = computeOverflow(p, ref, flt, vp, mo, pad);
            const main_ov = mainAxisOverflow(ov, getSide(p));
            // Check overlap with excluded.
            const tr = computeTranslate(p, ref.w, ref.h, flt.w, flt.h, mo);
            const fx = ref.x + tr[0];
            const fy = ref.y + tr[1];
            if (collidesWithExcluded(fx, fy, flt, ex)) return std.math.inf(f32);
            return main_ov;
        }
    }.s;

    var best = preferred;
    var best_overflow = score(preferred, reference, floating, viewport, main_axis_offset, padding, excluded);
    if (best_overflow <= 0) return preferred;

    if (fallbacks.len > 0) {
        for (fallbacks) |candidate| {
            const cur = score(candidate, reference, floating, viewport, main_axis_offset, padding, excluded);
            if (cur <= 0) return candidate;
            if (cur < best_overflow) {
                best_overflow = cur;
                best = candidate;
            }
        }
    } else {
        // Classic 2-way flip.
        const opp = getOppositePlacement(preferred);
        const cur = score(opp, reference, floating, viewport, main_axis_offset, padding, excluded);
        if (cur <= 0) return opp;
        if (cur < best_overflow) {
            best_overflow = cur;
            best = opp;
        }
    }
    return best;
}

pub fn computePosition(reference: Rect, floating: Rect, viewport: Rect, config: ComputePositionConfig) ComputePositionResult {
    var state = ComputePositionResult{
        .x = 0,
        .y = 0,
        .placement = config.placement,
        .middleware_data = .{},
    };

    var offset_options = OffsetOptions{};
    for (config.middleware) |middleware| {
        switch (middleware) {
            .offset => |options| offset_options = options,
            else => {},
        }
    }

    // Resolve offset value, derivable uses (placement, reference, floating) to compute actual
    // number.
    const resolveMain = struct {
        fn r(opts: OffsetOptions, p: Placement, ref: Rect, flt: Rect) f32 {
            return opts.main_axis.resolve(.{ .placement = p, .reference = ref, .floating = flt });
        }
    }.r;
    const resolveCross = struct {
        fn r(opts: OffsetOptions, p: Placement, ref: Rect, flt: Rect) f32 {
            return opts.cross_axis.resolve(.{ .placement = p, .reference = ref, .floating = flt });
        }
    }.r;

    const initial_main = resolveMain(offset_options, state.placement, reference, floating);
    const initial_translate = computeTranslate(state.placement, reference.w, reference.h, floating.w, floating.h, initial_main);
    state.x = reference.x + initial_translate[0];
    state.y = reference.y + initial_translate[1];

    for (config.middleware) |middleware| {
        switch (middleware) {
            .offset => |options| {
                const cross_v = resolveCross(options, state.placement, reference, floating);
                const delta = applyCrossAxisOffset(state.placement, cross_v);
                state.x += delta[0];
                state.y += delta[1];
                state.middleware_data.offset = .{ .x = delta[0], .y = delta[1] };
            },
            .flip => |options| {
                const main_v = resolveMain(offset_options, state.placement, reference, floating);
                const chosen = flipPlacementGroupAware(
                    state.placement,
                    options.fallback_placements,
                    reference,
                    floating,
                    viewport,
                    main_v,
                    options.padding,
                    config.excluded_rects,
                );
                if (chosen != state.placement) {
                    state.placement = chosen;
                    const new_main = resolveMain(offset_options, chosen, reference, floating);
                    const new_cross = resolveCross(offset_options, chosen, reference, floating);
                    const translated = computeTranslate(chosen, reference.w, reference.h, floating.w, floating.h, new_main);
                    state.x = reference.x + translated[0];
                    state.y = reference.y + translated[1];
                    const delta = applyCrossAxisOffset(chosen, new_cross);
                    state.x += delta[0];
                    state.y += delta[1];
                }
                state.middleware_data.flip = .{
                    .placement = state.placement,
                    .overflow = computeOverflowFromCoords(state.x, state.y, floating, viewport, options.padding),
                };
            },
            .shift => |options| {
                var dx: f32 = 0;
                var dy: f32 = 0;
                const overflow = computeOverflowFromCoords(state.x, state.y, floating, viewport, options.padding);
                const side = getSide(state.placement);

                if (options.cross_axis) {
                    if (side == .top or side == .bottom) {
                        if (overflow.right > 0) dx -= overflow.right;
                        if (overflow.left > 0) dx += overflow.left;
                    } else {
                        if (overflow.bottom > 0) dy -= overflow.bottom;
                        if (overflow.top > 0) dy += overflow.top;
                    }
                }

                if (options.main_axis) {
                    switch (side) {
                        .top => {
                            if (overflow.top > 0) dy += overflow.top;
                        },
                        .bottom => {
                            if (overflow.bottom > 0) dy -= overflow.bottom;
                        },
                        .left => {
                            if (overflow.left > 0) dx += overflow.left;
                        },
                        .right => {
                            if (overflow.right > 0) dx -= overflow.right;
                        },
                    }
                }

                // Group-aware: push popover clear of excluded rects along main axis.
                if (config.excluded_rects.len > 0) {
                    const main_push = pushOutOfExcludedAlongMain(state.x + dx, state.y + dy, floating, side, config.excluded_rects);
                    if (side == .top or side == .bottom) dy += main_push else dx += main_push;
                }

                state.x += dx;
                state.y += dy;
                state.middleware_data.shift = .{
                    .x = dx,
                    .y = dy,
                    .overflow = computeOverflowFromCoords(state.x, state.y, floating, viewport, options.padding),
                };
            },
            .size => |options| {
                // Main-axis offset occupies available space (floating-ui sizes after offset,
                // calculates overflow; explicit subtract here).
                const main_v = resolveMain(offset_options, state.placement, reference, floating);
                state.middleware_data.size = .{
                    .available_width = availableWidthForPlacement(state.placement, reference, viewport, options.padding) -
                        excludedShrinkWidth(state.placement, reference, viewport, options.padding, config.excluded_rects) -
                        mainOffsetOnWidth(state.placement, main_v),
                    .available_height = availableHeightForPlacement(state.placement, reference, viewport, options.padding) -
                        excludedShrinkHeight(state.placement, reference, viewport, options.padding, config.excluded_rects) -
                        mainOffsetOnHeight(state.placement, main_v),
                };
            },
            .autosize => |options| {
                const main_v = resolveMain(offset_options, state.placement, reference, floating);
                state.middleware_data.autosize = .{
                    .committed_max_width = @max(0, availableWidthForPlacement(state.placement, reference, viewport, options.padding) -
                        excludedShrinkWidth(state.placement, reference, viewport, options.padding, config.excluded_rects) -
                        mainOffsetOnWidth(state.placement, main_v)),
                    .committed_max_height = @max(0, availableHeightForPlacement(state.placement, reference, viewport, options.padding) -
                        excludedShrinkHeight(state.placement, reference, viewport, options.padding, config.excluded_rects) -
                        mainOffsetOnHeight(state.placement, main_v)),
                    .apply_width = options.apply_width,
                    .apply_height = options.apply_height,
                };
            },
        }
    }

    return state;
}

fn computeOverflowFromCoords(x: f32, y: f32, floating: Rect, viewport: Rect, padding: f32) Overflow {
    return .{
        .top = (viewport.y + padding) - y,
        .right = (x + floating.w) - (viewport.x + viewport.w - padding),
        .bottom = (y + floating.h) - (viewport.y + viewport.h - padding),
        .left = (viewport.x + padding) - x,
    };
}

fn rectsOverlap(a: Rect, b: Rect) bool {
    return a.x < b.x + b.w and b.x < a.x + a.w and a.y < b.y + b.h and b.y < a.y + a.h;
}

/// Check if popover candidate rect overlaps any excluded rect. flip use: overlap = treat placement
/// unavailable, trigger flip.
fn collidesWithExcluded(x: f32, y: f32, floating: Rect, excluded: []const Rect) bool {
    if (excluded.len == 0) return false;
    const fl = Rect{ .x = x, .y = y, .w = floating.w, .h = floating.h };
    for (excluded) |er| {
        if (rectsOverlap(fl, er)) return true;
    }
    return false;
}

/// Signed displacement to push popover clear of all excluded rects along placement main axis. shift
/// main_axis use: add to viewport-push result. side=bottom: positive (push down); side=top:
/// negative (push up); similar left/right.
fn pushOutOfExcludedAlongMain(
    x: f32,
    y: f32,
    floating: Rect,
    side: Side,
    excluded: []const Rect,
) f32 {
    if (excluded.len == 0) return 0;
    const fl = Rect{ .x = x, .y = y, .w = floating.w, .h = floating.h };
    var max_push: f32 = 0;
    for (excluded) |er| {
        if (!rectsOverlap(fl, er)) continue;
        const p: f32 = switch (side) {
            .bottom => (er.y + er.h) - fl.y, // Push popover top to er bottom.
            .top => (fl.y + fl.h) - er.y, // Push popover bottom to er top (return positive, caller applies sign by side).
            .right => (er.x + er.w) - fl.x,
            .left => (fl.x + fl.w) - er.x,
        };
        if (p > max_push) max_push = p;
    }
    return switch (side) {
        .bottom, .right => max_push,
        .top, .left => -max_push,
    };
}

/// Autosize use: compute available width for popover at placement (deduct excluded rect
/// occupation). Only deduct 'part excluded rect occupies cross-axis when popover sticks to anchor
/// main-axis'.
fn excludedShrinkWidth(placement: Placement, reference: Rect, viewport: Rect, padding: f32, excluded: []const Rect) f32 {
    _ = padding;
    if (excluded.len == 0) return 0;
    const side = getSide(placement);
    // Only meaningful for left/right main-axis placement (width is main-axis).
    return switch (side) {
        .left => blk: {
            // Popover left of reference, width range [viewport.x, reference.x]. Any excluded rect
            // in this vertical band reduces available.
            var min_left = viewport.x;
            for (excluded) |er| {
                if (er.x + er.w <= viewport.x) continue;
                if (er.x >= reference.x) continue;
                // Er overlaps reference vertical band (reference around) only counts. Simplify:
                // check er in popover's likely y band (reference center +/- popover height). Rough:
                // er.y..er.y+er.h overlaps reference vertical.
                if (er.y + er.h <= reference.y or er.y >= reference.y + reference.h) {
                    // Er completely clears reference vertical band -> doesn't affect popover.
                    // (Note: actual popover taller than reference, rough here, sufficient.)
                }
                if (er.x + er.w > min_left) min_left = er.x + er.w;
            }
            const recovered = reference.x - min_left;
            const original = reference.x - viewport.x;
            break :blk @max(0, original - recovered);
        },
        .right => blk: {
            var max_right = viewport.x + viewport.w;
            const ref_right = reference.x + reference.w;
            for (excluded) |er| {
                if (er.x >= viewport.x + viewport.w) continue;
                if (er.x + er.w <= ref_right) continue;
                if (er.x < max_right) max_right = er.x;
            }
            const recovered = max_right - ref_right;
            const original = (viewport.x + viewport.w) - ref_right;
            break :blk @max(0, original - recovered);
        },
        else => 0,
    };
}

fn excludedShrinkHeight(placement: Placement, reference: Rect, viewport: Rect, padding: f32, excluded: []const Rect) f32 {
    _ = padding;
    if (excluded.len == 0) return 0;
    const side = getSide(placement);
    return switch (side) {
        .top => blk: {
            // Popover above reference, available height [viewport.y, reference.y]. Find lowest
            // excluded.bottom (in popover zone) -> reduce available.
            var min_top = viewport.y;
            for (excluded) |er| {
                if (er.y + er.h <= viewport.y) continue;
                if (er.y >= reference.y) continue;
                if (er.y + er.h > min_top) min_top = er.y + er.h;
            }
            const recovered = reference.y - min_top;
            const original = reference.y - viewport.y;
            break :blk @max(0, original - recovered);
        },
        .bottom => blk: {
            var max_bottom = viewport.y + viewport.h;
            const ref_bottom = reference.y + reference.h;
            for (excluded) |er| {
                if (er.y >= viewport.y + viewport.h) continue;
                if (er.y + er.h <= ref_bottom) continue;
                if (er.y < max_bottom) max_bottom = er.y;
            }
            const recovered = max_bottom - ref_bottom;
            const original = (viewport.y + viewport.h) - ref_bottom;
            break :blk @max(0, original - recovered);
        },
        else => 0,
    };
}

fn applyCrossAxisOffset(placement: Placement, cross_axis: f32) [2]f32 {
    return switch (getSide(placement)) {
        .top, .bottom => .{ cross_axis, 0 },
        .left, .right => .{ 0, cross_axis },
    };
}

fn availableWidthForPlacement(placement: Placement, reference: Rect, viewport: Rect, padding: f32) f32 {
    return switch (getSide(placement)) {
        .top, .bottom => @max(0, viewport.w - padding * 2),
        .left => @max(0, reference.x - viewport.x - padding),
        .right => @max(0, viewport.x + viewport.w - (reference.x + reference.w) - padding),
    };
}

/// Main-axis offset width (left/right side).
fn mainOffsetOnWidth(placement: Placement, main_v: f32) f32 {
    return switch (getSide(placement)) {
        .left, .right => main_v,
        .top, .bottom => 0,
    };
}

/// Main-axis offset height (top/bottom side).
fn mainOffsetOnHeight(placement: Placement, main_v: f32) f32 {
    return switch (getSide(placement)) {
        .top, .bottom => main_v,
        .left, .right => 0,
    };
}

fn availableHeightForPlacement(placement: Placement, reference: Rect, viewport: Rect, padding: f32) f32 {
    return switch (getSide(placement)) {
        .top => @max(0, reference.y - viewport.y - padding),
        .bottom => @max(0, viewport.y + viewport.h - (reference.y + reference.h) - padding),
        .left, .right => @max(0, viewport.h - padding * 2),
    };
}

test "flip fallbacks: preferred fits — returns preferred" {
    const reference = Rect.init(100, 100, 80, 32);
    const floating = Rect.init(0, 0, 120, 60);
    const viewport = Rect.init(0, 0, 600, 400);
    const middleware = [_]Middleware{
        .{ .offset = .{ .main_axis = .{ .static = 4 } } },
        .{ .flip = .{ .fallback_placements = &.{ .bottom_start, .top_start } } },
    };
    const result = computePosition(reference, floating, viewport, .{
        .placement = .right_start,
        .middleware = &middleware,
    });
    try std.testing.expectEqual(Placement.right_start, result.placement);
}

test "flip fallbacks: preferred overflows — tries fallback list in order" {
    // Viewport 240x160, reference (200, 50, 30, 20), right 10px only, won't fit 120 wide.
    const reference = Rect.init(200, 50, 30, 20);
    const floating = Rect.init(0, 0, 120, 60);
    const viewport = Rect.init(0, 0, 240, 160);
    const middleware = [_]Middleware{
        .{ .offset = .{ .main_axis = .{ .static = 4 } } },
        // Right doesn't fit -> try bottom -> bottom has 60h + 100 available should fit.
        .{ .flip = .{ .fallback_placements = &.{ .bottom_start, .top_start } } },
    };
    const result = computePosition(reference, floating, viewport, .{
        .placement = .right_start,
        .middleware = &middleware,
    });
    // Expect bottom_start (first non-overflowing fallback).
    try std.testing.expectEqual(Placement.bottom_start, result.placement);
}

test "flip fallbacks: 所有 fallback 都溢出 — 选溢出最小的" {
    // Tiny viewport all directions insufficient.
    const reference = Rect.init(10, 10, 20, 20);
    const floating = Rect.init(0, 0, 200, 200); // Larger than viewport.
    const viewport = Rect.init(0, 0, 100, 100);
    const middleware = [_]Middleware{
        .{ .offset = .{ .main_axis = .{ .static = 4 } } },
        .{ .flip = .{ .fallback_placements = &.{ .bottom_start, .top_start } } },
    };
    const result = computePosition(reference, floating, viewport, .{
        .placement = .right_start,
        .middleware = &middleware,
    });
    // All candidates overflow; should return some candidate (no crash). Specific one depends on
    // overflow calc details, verify not left-related (fallback list omits).
    try std.testing.expect(result.placement != .left_start);
    try std.testing.expect(result.placement != .left_end);
    try std.testing.expect(result.placement != .left);
}

test "flip fallbacks: 空 fallback list — 退回经典 2-way flip" {
    const reference = Rect.init(200, 50, 30, 20);
    const floating = Rect.init(0, 0, 120, 60);
    const viewport = Rect.init(0, 0, 240, 160);
    const middleware = [_]Middleware{
        .{ .offset = .{ .main_axis = .{ .static = 4 } } },
        .{ .flip = .{} }, // Empty fallback.
    };
    const result = computePosition(reference, floating, viewport, .{
        .placement = .right_start,
        .middleware = &middleware,
    });
    // Right overflows -> 2-way flip tries left_start.
    try std.testing.expectEqual(Placement.left_start, result.placement);
}

test "computePosition: flip then shift" {
    const reference = Rect.init(100, 10, 80, 32);
    const floating = Rect.init(0, 0, 160, 60);
    const viewport = Rect.init(0, 0, 240, 160);
    const middleware = [_]Middleware{
        .{ .offset = .{ .main_axis = .{ .static = 4 } } },
        .{ .flip = .{} },
        .{ .shift = .{} },
    };

    const result = computePosition(reference, floating, viewport, .{
        .placement = .top_start,
        .middleware = &middleware,
    });

    try std.testing.expectEqual(Placement.bottom_start, result.placement);
    try std.testing.expect(result.y >= reference.y + reference.h);
}

test "computePosition: size middleware reports available space" {
    const reference = Rect.init(40, 50, 80, 20);
    const floating = Rect.init(0, 0, 100, 60);
    const viewport = Rect.init(0, 0, 320, 200);
    const middleware = [_]Middleware{
        .{ .size = .{ .padding = 8 } },
    };

    const result = computePosition(reference, floating, viewport, .{
        .placement = .bottom,
        .middleware = &middleware,
    });

    try std.testing.expect(result.middleware_data.size != null);
    try std.testing.expectEqual(@as(f32, 304), result.middleware_data.size.?.available_width);
    try std.testing.expectEqual(@as(f32, 122), result.middleware_data.size.?.available_height);
}

test "computePosition: autosize commits max dimensions for committing callers" {
    const reference = Rect.init(40, 50, 80, 20);
    const floating = Rect.init(0, 0, 100, 60);
    const viewport = Rect.init(0, 0, 320, 200);
    const middleware = [_]Middleware{
        .{ .autosize = .{ .padding = 8 } },
    };

    const result = computePosition(reference, floating, viewport, .{
        .placement = .bottom,
        .middleware = &middleware,
    });

    try std.testing.expect(result.middleware_data.autosize != null);
    const a = result.middleware_data.autosize.?;
    try std.testing.expectEqual(@as(f32, 304), a.committed_max_width);
    try std.testing.expectEqual(@as(f32, 122), a.committed_max_height);
    try std.testing.expect(a.apply_width);
    try std.testing.expect(a.apply_height);
}

test "computePosition: autosize applies after flip decides final placement" {
    // Reference near bottom, triggers flip bottom->top.
    const reference = Rect.init(100, 180, 60, 16);
    const floating = Rect.init(0, 0, 80, 100);
    const viewport = Rect.init(0, 0, 320, 220);
    const middleware = [_]Middleware{
        .{ .offset = .{ .main_axis = .{ .static = 4 } } },
        .{ .flip = .{} },
        .{ .autosize = .{ .padding = 4 } },
    };

    const result = computePosition(reference, floating, viewport, .{
        .placement = .bottom,
        .middleware = &middleware,
    });

    // flip should cut to top side.
    try std.testing.expect(getSide(result.placement) == .top);
    try std.testing.expect(result.middleware_data.autosize != null);
    // autosize at top placement reports space above reference, deduct padding and main-axis offset
    // (= 180 - 4 - 4 = 172).
    const a = result.middleware_data.autosize.?;
    try std.testing.expectEqual(@as(f32, 172), a.committed_max_height);
}

// ============================================================================
// Group-aware tests: excluded_rects enables flip / shift / autosize cooperate avoidance
// ============================================================================

test "group-aware flip: bottom_start 被前序 popover 占住 → 翻到 top_start" {
    // Anchor center, bottom occupied by prior popover -> flip should go top.
    const reference = Rect.init(100, 100, 80, 32);
    const floating = Rect.init(0, 0, 120, 60);
    const viewport = Rect.init(0, 0, 600, 400);

    // Prior popover occupies bottom region (directly below anchor).
    const excluded = [_]Rect{
        Rect.init(100, 140, 120, 60),
    };

    const middleware = [_]Middleware{
        .{ .offset = .{ .main_axis = .{ .static = 4 } } },
        .{ .flip = .{} },
    };
    const result = computePosition(reference, floating, viewport, .{
        .placement = .bottom_start,
        .middleware = &middleware,
        .excluded_rects = &excluded,
    });
    try std.testing.expectEqual(Placement.top_start, result.placement);
}

test "group-aware flip: 多个 fallback 都被 excluded 占住 → 退回最不冲突的" {
    const reference = Rect.init(100, 100, 80, 32);
    const floating = Rect.init(0, 0, 120, 60);
    const viewport = Rect.init(0, 0, 600, 400);

    // Both bottom and top occupied -> only right left in fallback list.
    const excluded = [_]Rect{
        Rect.init(100, 140, 120, 60), // Bottom region.
        Rect.init(100, 30, 120, 60), // Top region.
    };

    const middleware = [_]Middleware{
        .{ .offset = .{ .main_axis = .{ .static = 4 } } },
        .{ .flip = .{ .fallback_placements = &.{ .top_start, .right_start, .left_start } } },
    };
    const result = computePosition(reference, floating, viewport, .{
        .placement = .bottom_start,
        .middleware = &middleware,
        .excluded_rects = &excluded,
    });
    // bottom_start collides -> top_start collides -> remaining side with least overflow wins.
    try std.testing.expectEqual(Placement.left_start, result.placement);
}

test "group-aware shift main_axis: popover 被推出 excluded rect" {
    const reference = Rect.init(100, 100, 80, 32);
    const floating = Rect.init(0, 0, 120, 30);
    const viewport = Rect.init(0, 0, 600, 400);

    // bottom_start lands (100, 132) by default. Prior popover (100, 130, 120, 40) -> overlap.
    const excluded = [_]Rect{
        Rect.init(100, 130, 120, 40),
    };

    const middleware = [_]Middleware{
        .{ .offset = .{ .main_axis = .{ .static = 0 } } },
        // flip static (force no fallback, isolate shift behavior).
        .{ .shift = .{ .main_axis = true } },
    };
    const result = computePosition(reference, floating, viewport, .{
        .placement = .bottom_start,
        .middleware = &middleware,
        .excluded_rects = &excluded,
    });
    // shift should push popover below excluded rect: y >= 130 + 40 = 170.
    try std.testing.expect(result.y >= 170);
}

test "group-aware autosize: bottom available_height 扣除 excluded rect 占用" {
    const reference = Rect.init(100, 50, 80, 20);
    const floating = Rect.init(0, 0, 120, 60);
    const viewport = Rect.init(0, 0, 320, 400);

    // Anchor below 320px (400 - 70 - 8 padding = 322), excluded in lower half occupies 200px.
    const excluded = [_]Rect{
        Rect.init(100, 200, 120, 200), // Bottom region lower half.
    };

    const middleware = [_]Middleware{
        .{ .autosize = .{ .padding = 8 } },
    };
    const result = computePosition(reference, floating, viewport, .{
        .placement = .bottom,
        .middleware = &middleware,
        .excluded_rects = &excluded,
    });
    try std.testing.expect(result.middleware_data.autosize != null);
    const a = result.middleware_data.autosize.?;
    // Original height = 400 - 70 - 8 = 322. excluded.y=200, from ref_bottom=70 start, max_bottom
    // pushed to 200 -> recovered=130, original=322 -> 322-(322-130)=130.
    try std.testing.expect(a.committed_max_height < 322);
    try std.testing.expect(a.committed_max_height >= 120);
    try std.testing.expect(a.committed_max_height <= 140);
}

test "group-aware: 空 excluded_rects → 行为完全等同非 group 版本" {
    const reference = Rect.init(100, 100, 80, 32);
    const floating = Rect.init(0, 0, 120, 60);
    const viewport = Rect.init(0, 0, 600, 400);
    const middleware = [_]Middleware{
        .{ .offset = .{ .main_axis = .{ .static = 4 } } },
        .{ .flip = .{} },
        .{ .shift = .{} },
        .{ .autosize = .{ .padding = 4 } },
    };
    const r1 = computePosition(reference, floating, viewport, .{
        .placement = .bottom_start,
        .middleware = &middleware,
    });
    const r2 = computePosition(reference, floating, viewport, .{
        .placement = .bottom_start,
        .middleware = &middleware,
        .excluded_rects = &.{},
    });
    try std.testing.expectEqual(r1.placement, r2.placement);
    try std.testing.expectEqual(r1.x, r2.x);
    try std.testing.expectEqual(r1.y, r2.y);
}

test "flip preserves complete content inside autosize viewport padding" {
    const reference = Rect.init(288, 691.6, 352, 32);
    const panel = Rect.init(0, 0, 352, 150);
    const viewport = Rect.init(0, 0, 1100, 879);
    const middleware = [_]Middleware{
        .{ .offset = .{ .main_axis = .{ .static = 4 } } },
        .{ .flip = .{ .padding = 8 } },
        .{ .shift = .{ .padding = 8 } },
        .{ .autosize = .{ .padding = 8, .apply_width = false } },
    };
    const result = computePosition(reference, panel, viewport, .{ .placement = .bottom_start, .middleware = &middleware });
    try std.testing.expectEqual(Placement.top_start, result.placement);
    try std.testing.expect(result.middleware_data.autosize.?.committed_max_height >= panel.h);
    try std.testing.expect(result.y >= 8 and result.y + panel.h <= reference.y - 4 + 0.01);
    // Zero padding remains source-compatible and this exact panel fits below.
    const legacy = computePosition(reference, panel, viewport, .{ .placement = .bottom_start, .middleware = &.{.{ .flip = .{} }} });
    try std.testing.expectEqual(Placement.bottom_start, legacy.placement);
}
