/// ScrollArea scroll physics
///
/// Vertical/horizontal scroll application + overscroll + near-boundary resistance
const std = @import("std");
const state_mod = @import("state.zig");
const ScrollState = state_mod.ScrollState;
const debug = @import("debug.zig");
const logScroll = debug.logScroll;

/// Scroll input source. Only trackpad gesture and its inertia have rubber-band overshoot (same as
/// NSScrollView: mouse wheel to edge stops).
pub const InputKind = enum { wheel, gesture, momentum };

/// Vertical scroll: clamp normal range, overshoot damped via damping function accumulate to bonus
pub fn applyVerticalScroll(state: *ScrollState, dy: f32, speed: f32, kind: InputKind) void {
    const raw_delta = -dy * speed;
    const max = state.maxScrollY();
    if (kind == .wheel) {
        state.scroll_y = std.math.clamp(state.scroll_y + raw_delta, 0, max);
        return;
    }
    const delta = applyVerticalNearBoundaryResistance(state, raw_delta, max, kind == .momentum);
    logScroll(
        "apply v: raw_delta={d:.2} delta={d:.2} max={d:.2} scroll_y={d:.2} bonus_y={d:.2} kind={s}",
        .{ raw_delta, delta, max, state.scroll_y, state.bonus_y, @tagName(kind) },
    );
    applyVerticalDelta(state, delta, max);
}

fn applyVerticalDelta(state: *ScrollState, delta_in: f32, max: f32) void {
    var delta = delta_in;

    // If already in overshoot zone, first consume bonus with this input (iOS style: don't move
    // content until back to edge)
    if (state.bonus_y != 0 and delta != 0) {
        const raw_bonus = state.rubber_band.unclamp(state.bonus_y, state.viewport_height);
        if ((raw_bonus > 0 and delta < 0) or (raw_bonus < 0 and delta > 0)) {
            const raw_sum = raw_bonus + delta;
            if (raw_sum == 0) {
                state.bonus_y = 0;
                logScroll("v consume bonus->0: delta={d:.2} raw_bonus={d:.2}", .{ delta, raw_bonus });
                return;
            }
            if ((raw_sum > 0 and raw_bonus < 0) or (raw_sum < 0 and raw_bonus > 0)) {
                // Cross zero backward: remainder continues normal scroll
                delta = raw_sum;
                state.bonus_y = 0;
                logScroll("v consume bonus cross0: remain_delta={d:.2} prev_raw_bonus={d:.2}", .{
                    delta,
                    raw_bonus,
                });
            } else {
                // Still in overshoot zone
                state.bonus_y = state.rubber_band.clamp(raw_sum, state.viewport_height);
                logScroll("v consume bonus stay: delta={d:.2} raw_bonus={d:.2} bonus={d:.2}", .{
                    delta,
                    raw_bonus,
                    state.bonus_y,
                });
                return;
            }
        }
    }

    if (max <= 0) {
        // Content too short, all scroll is overshoot -> direct rubber band
        applyOverscrollY(state, delta);
        return;
    }

    const new_y = state.scroll_y + delta;

    if (new_y < 0) {
        state.scroll_y = 0;
        applyOverscrollY(state, new_y); // new_y is negative
    } else if (new_y > max) {
        state.scroll_y = max;
        applyOverscrollY(state, new_y - max); // Positive value
    } else {
        state.scroll_y = new_y;
    }
}

/// Horizontal scroll: clamp normal range, overshoot damped via damping function accumulate to
/// bonus_x
pub fn applyHorizontalScroll(state: *ScrollState, dx: f32, speed: f32, kind: InputKind) void {
    const raw_delta = -dx * speed;
    const max = state.maxScrollX();
    if (kind == .wheel) {
        state.scroll_x = std.math.clamp(state.scroll_x + raw_delta, 0, max);
        return;
    }
    const delta = applyHorizontalNearBoundaryResistance(state, raw_delta, max, kind == .momentum);
    logScroll(
        "apply h: raw_delta={d:.2} delta={d:.2} max={d:.2} scroll_x={d:.2} bonus_x={d:.2} kind={s}",
        .{ raw_delta, delta, max, state.scroll_x, state.bonus_x, @tagName(kind) },
    );
    applyHorizontalDelta(state, delta, max);
}

fn applyHorizontalDelta(state: *ScrollState, delta_in: f32, max: f32) void {
    var delta = delta_in;

    if (state.bonus_x != 0 and delta != 0) {
        const raw_bonus = state.rubber_band_x.unclamp(state.bonus_x, state.viewport_width);
        if ((raw_bonus > 0 and delta < 0) or (raw_bonus < 0 and delta > 0)) {
            const raw_sum = raw_bonus + delta;
            if (raw_sum == 0) {
                state.bonus_x = 0;
                logScroll("h consume bonus->0: delta={d:.2} raw_bonus={d:.2}", .{ delta, raw_bonus });
                return;
            }
            if ((raw_sum > 0 and raw_bonus < 0) or (raw_sum < 0 and raw_bonus > 0)) {
                delta = raw_sum;
                state.bonus_x = 0;
                logScroll("h consume bonus cross0: remain_delta={d:.2} prev_raw_bonus={d:.2}", .{
                    delta,
                    raw_bonus,
                });
            } else {
                state.bonus_x = state.rubber_band_x.clamp(raw_sum, state.viewport_width);
                logScroll("h consume bonus stay: delta={d:.2} raw_bonus={d:.2} bonus={d:.2}", .{
                    delta,
                    raw_bonus,
                    state.bonus_x,
                });
                return;
            }
        }
    }

    if (max <= 0) {
        applyOverscrollX(state, delta);
        return;
    }

    const new_x = state.scroll_x + delta;

    if (new_x < 0) {
        state.scroll_x = 0;
        applyOverscrollX(state, new_x);
    } else if (new_x > max) {
        state.scroll_x = max;
        applyOverscrollX(state, new_x - max);
    } else {
        state.scroll_x = new_x;
    }
}

/// Unified overshoot handling: overflow direct to rubber band formula (manual and inertia
/// consistent)
pub fn applyOverscrollY(state: *ScrollState, overflow: f32) void {
    if (!state.rubber_band_y_enabled) return;
    const prev_bonus = state.bonus_y;
    state.bonus_y = state.rubber_band.applyDelta(state.bonus_y, overflow, state.viewport_height);
    // Estimate visual velocity (px/s) per event, carries as v0 at spring start -> velocity
    // continuous with rubber-band phase
    state.bonus_velocity = (state.bonus_y - prev_bonus) / ScrollState.default_dt;
    if (@abs(state.bonus_y) < ScrollState.scroll_tuning.jitter_snap_epsilon and @abs(overflow) < ScrollState.scroll_tuning.jitter_snap_epsilon) {
        state.bonus_y = 0;
        state.bonus_velocity = 0;
        return;
    }
    if (prev_bonus == 0 and state.bonus_y != 0) {
        logScroll("!! BOUNCE RETRIGGER Y: overflow={d:.2} bonus 0->{d:.2} bounce_active={} scroll_y={d:.1}", .{
            overflow, state.bonus_y, state.bounce_active_y, state.scroll_y,
        });
    } else {
        logScroll("v overscroll: overflow={d:.2} bonus {d:.2}->{d:.2}", .{
            overflow, prev_bonus, state.bonus_y,
        });
    }
}

/// Unified horizontal overshoot handling
pub fn applyOverscrollX(state: *ScrollState, overflow: f32) void {
    if (!state.rubber_band_x_enabled) return;
    const prev_bonus = state.bonus_x;
    state.bonus_x = state.rubber_band_x.applyDelta(state.bonus_x, overflow, state.viewport_width);
    state.bonus_velocity_x = (state.bonus_x - prev_bonus) / ScrollState.default_dt;
    if (@abs(state.bonus_x) < ScrollState.scroll_tuning.jitter_snap_epsilon and @abs(overflow) < ScrollState.scroll_tuning.jitter_snap_epsilon) {
        state.bonus_x = 0;
        state.bonus_velocity_x = 0;
        return;
    }
    logScroll("h overscroll: overflow={d:.2} bonus {d:.2}->{d:.2}", .{
        overflow, prev_bonus, state.bonus_x,
    });
}

pub fn applyNearBoundaryResistance(distance_to_boundary: f32, delta: f32, is_momentum: bool) f32 {
    const t = ScrollState.scroll_tuning;
    const zone = @max(t.edge_resistance_zone_px, 1.0);
    if (distance_to_boundary >= zone) return delta;
    const ratio = std.math.clamp(distance_to_boundary / zone, 0.0, 1.0);
    const eased = ratio * ratio;
    const min_factor = if (is_momentum)
        t.momentum_edge_resistance_min_factor
    else
        t.edge_resistance_min_factor;
    const factor = std.math.clamp(min_factor + (1.0 - min_factor) * eased, min_factor, 1.0);
    if (factor < 0.999) {
        logScroll(
            "edge resistance: dist={d:.2} delta={d:.2} factor={d:.3} momentum={}",
            .{ distance_to_boundary, delta, factor, is_momentum },
        );
    }
    return delta * factor;
}

pub fn applyVerticalNearBoundaryResistance(state: *const ScrollState, delta: f32, max: f32, is_momentum: bool) f32 {
    if (delta == 0 or max <= 0) return delta;
    if (delta < 0) {
        // Push toward top boundary exterior
        return applyNearBoundaryResistance(@max(state.scroll_y, 0), delta, is_momentum);
    }
    // Push toward bottom boundary exterior
    return applyNearBoundaryResistance(@max(max - state.scroll_y, 0), delta, is_momentum);
}

pub fn applyHorizontalNearBoundaryResistance(state: *const ScrollState, delta: f32, max: f32, is_momentum: bool) f32 {
    if (delta == 0 or max <= 0) return delta;
    if (delta < 0) {
        return applyNearBoundaryResistance(@max(state.scroll_x, 0), delta, is_momentum);
    }
    return applyNearBoundaryResistance(@max(max - state.scroll_x, 0), delta, is_momentum);
}
