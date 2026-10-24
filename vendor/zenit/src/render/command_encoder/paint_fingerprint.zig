//! command_encoder/paint_fingerprint.zig: pure-function toolkit for paint commands.
//!
//! Common trait: **zero encoder-instance state dependency**. All are `fn(anytype) -> value` pure
//! functions depending only on the passed paint command.
//!
//! Three responsibility groups:
//! 1. **damage bounds**: pixel range affected by one command, for damage-rect partial-redraw
//!    dirty-union. Contract: **prefer overestimate**: a missed pixel = stale content persists.
//! 2. **content fingerprint**: feed command fields affecting pixels into a hasher, for retained
//!    layer hit judgment. Contract: **prefer over-feed**: a missing feed = changed content but a
//!    hit = stale frame.
//! 3. **structural folding**: detect empty begin/end blocks, skip the whole span.
//!
//! WARNING: before changing any function here, read both contracts above: the failure mode is a
//! **stale frame**, not a crash; e2e may not catch it.

const std = @import("std");

// Structural token classification, pure function in same cluster as tryFindNoOpStructuralBlock.
pub const StructuralToken = enum {
    none,
    begin_clip,
    end_clip,
    begin_rounded_clip,
    end_rounded_clip,
    begin_blur_layer,
    end_blur_layer,
    begin_opacity_layer,
    end_opacity_layer,
};

pub inline fn structuralToken(it: anytype) StructuralToken {
    if (it.kind != .control) return .none;
    return switch (it.control_kind) {
        .push_clip => .begin_clip,
        .pop_clip => .end_clip,
        .begin_rounded_clip => .begin_rounded_clip,
        .end_rounded_clip => .end_rounded_clip,
        .begin_blur_layer => .begin_blur_layer,
        .end_blur_layer => .end_blur_layer,
        .begin_opacity_layer => .begin_opacity_layer,
        .end_opacity_layer => .end_opacity_layer,
        else => .none,
    };
}

pub inline fn isBeginStructuralToken(tok: StructuralToken) bool {
    return switch (tok) {
        .begin_clip, .begin_rounded_clip, .begin_blur_layer, .begin_opacity_layer => true,
        else => false,
    };
}

pub inline fn matchingEndStructuralToken(begin_tok: StructuralToken) StructuralToken {
    return switch (begin_tok) {
        .begin_clip => .end_clip,
        .begin_rounded_clip => .end_rounded_clip,
        .begin_blur_layer => .end_blur_layer,
        .begin_opacity_layer => .end_opacity_layer,
        else => .none,
    };
}

/// damage-rect: conservative over-expanded bounds for one command. Prefer overestimate; miss one
/// dirty pixel = stale pixel persists.
pub fn damageItemBounds(it: anytype) [4]f32 {
    const sh1 = it.shadow_blur * 2 + @max(@abs(it.shadow_offset_x), @abs(it.shadow_offset_y)) + @max(0, it.shadow_spread);
    const sh2 = it.shadow2_blur * 2 + @max(@abs(it.shadow2_offset_x), @abs(it.shadow2_offset_y));
    var pad: f32 = 2 + it.stroke_width + @max(sh1, sh2);
    // Text glyphs may overflow measurement box (italic overhang / descenders), extra margin.
    if (it.kind == .text) pad += 8;
    var y = it.geom.y;
    var w = it.geom.w;
    var h = it.geom.h;
    if (it.kind == .text) {
        // WARNING: a text command's geom.w/h is **always 0** (lowering only fills the draw origin;
        // see the
        // .text_run branch in render_engine/gpu_draw_shadow.zig). Computing bounds directly yields
        // a tiny
        // ~20px pad*2 region around the origin; only the first one or two chars per line enter the
        // dirty
        // area and the rest keep previous-frame pixels (e.g. '3 x 4' -> '3 x 5': dirty x in
        // [331,351]
        // covers only the lead glyph, trailing '5' at x=368 stays stale).
        //
        // So use a conservative upper bound from content length: max 1 em (font_size) per byte; for
        // monospace, use the explicit cell width. Contract: prefer overestimate; overestimating
        // redraws a
        // few pixels, underestimating leaves stale pixels.
        const per_byte = if (it.text_monospace_char_width > 0)
            it.text_monospace_char_width
        else
            it.text_font_size;
        const n: f32 = @floatFromInt(it.text_content.len);
        w = @max(w, n * per_byte);
        // WARNING: text's geom.y is the **baseline** (text_item_render fills baseline_y in all
        // .text_run
        // branches); glyphs draw **above** it (glyph_y = cursor_y - bearing_y). A [y, y+2fs] range
        // misses
        // ascenders entirely: at fs>=14 the retained layer keeps stale pixels at the text top / new
        // glyphs
        // get clipped. Use 1.3em above (covers CJK/emoji/accented capitals ascent), 0.6em below
        // (descenders + inline decoration).
        const fs = @max(it.text_font_size, 0);
        y -= fs * 1.3;
        h = @max(h, fs * 1.9);
    }
    // Rotation (image/icon rotates around center, see rotate param in addImage/addIcon):
    // axis-aligned
    // geom doesn't cover rotated corners, rotation animation leaves trails at corners. Use
    // circumscribed circle like local_sort.localSortImageLikeBounds.
    if (it.kind != .text and @abs(it.rotate) > 0.0001) {
        const cx = it.geom.x + w * 0.5;
        const cy = it.geom.y + h * 0.5;
        const r = 0.5 * @sqrt(w * w + h * h) + pad;
        return .{ cx - r, cy - r, r * 2, r * 2 };
    }
    return .{
        it.geom.x - pad,
        y - pad,
        w + pad * 2,
        h + pad * 2,
    };
}

/// damage-rect: conservative bounds for path command. path's geom.w/h always 0 (lowering only fills
/// offset); bounds must compute from points. Quad/cubic control points upper-bound curve's convex
/// hull, include directly (over-inclusive but safe).
pub fn pathItemBounds(it: anytype) [4]f32 {
    // arc (spinner/progress ring) reuses the `.path` kind but has **no** path_geometry_ptr; geom is
    // the
    // center, w/h always 0. Without special handling the dirty region is only the center point, and
    // a
    // Spinner in a retained layer (Modal/Sheet/Popover) with partial redraw gets its ring
    // scissor-clipped and freezes on screen. Criteria match isArcCommand / localSortArcBounds (only
    // checks arc_outer_radius); over-expand by stroke_width + 2px AA margin (prefer overestimate).
    if (it.arc_outer_radius > 0) {
        const r = it.arc_outer_radius + @max(it.stroke_width, 0) + 2;
        return .{ it.geom.x - r, it.geom.y - r, r * 2, r * 2 };
    }
    const pg = it.path_geometry_ptr orelse
        return .{ it.geom.x, it.geom.y, 0, 0 };
    var min_x: f32 = std.math.floatMax(f32);
    var min_y: f32 = std.math.floatMax(f32);
    var max_x: f32 = -std.math.floatMax(f32);
    var max_y: f32 = -std.math.floatMax(f32);
    var any = false;
    for (pg.commands) |cmd| {
        switch (cmd) {
            .move_to, .line_to => |pt| {
                min_x = @min(min_x, pt.x);
                min_y = @min(min_y, pt.y);
                max_x = @max(max_x, pt.x);
                max_y = @max(max_y, pt.y);
                any = true;
            },
            .quad_to => |q| {
                min_x = @min(min_x, @min(q.ctrl.x, q.end.x));
                min_y = @min(min_y, @min(q.ctrl.y, q.end.y));
                max_x = @max(max_x, @max(q.ctrl.x, q.end.x));
                max_y = @max(max_y, @max(q.ctrl.y, q.end.y));
                any = true;
            },
            .cubic_to => |c| {
                min_x = @min(min_x, @min(c.ctrl1.x, @min(c.ctrl2.x, c.end.x)));
                min_y = @min(min_y, @min(c.ctrl1.y, @min(c.ctrl2.y, c.end.y)));
                max_x = @max(max_x, @max(c.ctrl1.x, @max(c.ctrl2.x, c.end.x)));
                max_y = @max(max_y, @max(c.ctrl1.y, @max(c.ctrl2.y, c.end.y)));
                any = true;
            },
            .close => {},
        }
    }
    if (!any) return .{ it.geom.x, it.geom.y, 0, 0 };
    // stroke expands half width outward, join/cap adds 1x more; +2 base pad.
    const pad: f32 = 2 + it.stroke_width * 1.5;
    return .{
        it.geom.x + min_x - pad,
        it.geom.y + min_y - pad,
        (max_x - min_x) + pad * 2,
        (max_y - min_y) + pad * 2,
    };
}

/// damage-rect: composite rect of nested opacity sublayer (geom union draw rect union axis-aligned
/// transform rect, over-expand 4px to tolerate composite bilinear/rounded edges). Rotation /
/// non-axis-aligned transform returns null -> that top-level layer judges unsafe.
pub fn nestedCompositeBounds(it: anytype) ?[4]f32 {
    if (it.rotate != 0) return null;
    var min_x = it.geom.x;
    var min_y = it.geom.y;
    var max_x = it.geom.x + it.geom.w;
    var max_y = it.geom.y + it.geom.h;
    if (it.use_draw_transform) {
        const t = it.draw_transform;
        if (t[1] != 0 or t[2] != 0 or t[0] <= 0 or t[3] <= 0) return null;
        // dt composite: geom.xy is nested-local content envelope origin, independent of parent
        // coords;
        // composite rect depends only on transform (t4,t5,a·w,d·h).
        min_x = t[4];
        min_y = t[5];
        max_x = t[4] + t[0] * it.geom.w;
        max_y = t[5] + t[3] * it.geom.h;
    } else if (!std.math.isNan(it.draw_x) and it.draw_w > 0 and it.draw_h > 0) {
        min_x = @min(min_x, it.draw_x);
        min_y = @min(min_y, it.draw_y);
        max_x = @max(max_x, it.draw_x + it.draw_w);
        max_y = @max(max_y, it.draw_y + it.draw_h);
    }
    const pad: f32 = 4;
    return .{ min_x - pad, min_y - pad, (max_x - min_x) + pad * 2, (max_y - min_y) + pad * 2 };
}

/// Strictly increasing across every encoded frame of every window (not a
/// per-window frame index: two windows' indices can coincide, and a frame's
/// damage pass hashes before its own encoder begins). Items whose pixels are
/// reseeded every frame mix it into their fingerprint so neither the damage
/// tracker nor a retained surface treats them as unchanged. Rendering is
/// serial on the main thread.
pub var frame_salt: u64 = 0;
pub fn nextFrameSalt() void {
    frame_salt +%= 1;
}

pub fn hashPaintItemInto(hasher: *std.hash.Wyhash, it: anytype) void {
    hashPaintItem(hasher, it, true);
}

/// Synchronous caret preparation compares separate lowered frames. Glass
/// and icon payloads are arena copies, so their addresses are not content.
/// Retained encoding keeps its existing within-frame identity contract above.
pub fn hashCaretPaintItemInto(hasher: *std.hash.Wyhash, it: anytype) void {
    hashPaintItem(hasher, it, false);
}

fn hashPaintItem(hasher: *std.hash.Wyhash, it: anytype, comptime glass_address: bool) void {
    hasher.update(std.mem.asBytes(&it.kind));
    hasher.update(std.mem.asBytes(&it.control_kind));
    hasher.update(std.mem.asBytes(&it.geom));
    hasher.update(std.mem.asBytes(&it.color));
    hasher.update(std.mem.asBytes(&it.radii));
    hasher.update(std.mem.asBytes(&it.opacity));
    hasher.update(std.mem.asBytes(&it.rotate));
    hasher.update(std.mem.asBytes(&it.blend_mode));
    hasher.update(std.mem.asBytes(&it.use_draw_transform));
    hasher.update(std.mem.asBytes(&it.draw_transform));
    hasher.update(std.mem.asBytes(&it.stroke_width));
    hasher.update(std.mem.asBytes(&it.clip_shape_kind));
    // Drawing shape (rounded_rect / ellipse) changes distance field itself; same geom changes
    // pixels.
    hasher.update(std.mem.asBytes(&it.shape_kind));
    // Text horizontal fade (marquee / truncation fade): fade range animation doesn't change content
    // bytes.
    hasher.update(std.mem.asBytes(&it.text_fade_dx0));
    hasher.update(std.mem.asBytes(&it.text_fade_dx1));
    // Full shadow parameters (all influencing pixels).
    hasher.update(std.mem.asBytes(&it.shadow_blur));
    hasher.update(std.mem.asBytes(&it.shadow_offset_x));
    hasher.update(std.mem.asBytes(&it.shadow_offset_y));
    hasher.update(std.mem.asBytes(&it.shadow_spread));
    hasher.update(std.mem.asBytes(&it.shadow_secondary_color));
    hasher.update(std.mem.asBytes(&it.shadow2_blur));
    hasher.update(std.mem.asBytes(&it.shadow2_offset_x));
    hasher.update(std.mem.asBytes(&it.shadow2_offset_y));
    // Full gradient (end colors / direction / radial center / conic angle + multi-stop).
    hasher.update(std.mem.asBytes(&it.gradient_to_color));
    hasher.update(std.mem.asBytes(&it.gradient_direction));
    hasher.update(std.mem.asBytes(&it.gradient_extend_mode));
    hasher.update(std.mem.asBytes(&it.gradient_radial_center_x));
    hasher.update(std.mem.asBytes(&it.gradient_radial_center_y));
    hasher.update(std.mem.asBytes(&it.gradient_radial_radius_x));
    hasher.update(std.mem.asBytes(&it.gradient_radial_radius_y));
    hasher.update(std.mem.asBytes(&it.gradient_conic_start_angle));
    hasher.update(std.mem.asBytes(&it.mg_stop_count));
    if (it.mg_stop_count > 0) {
        const n = @min(@as(usize, it.mg_stop_count), it.mg_stop_colors.len);
        hasher.update(std.mem.sliceAsBytes(it.mg_stop_colors[0..n]));
        hasher.update(std.mem.sliceAsBytes(it.mg_stop_positions[0..n]));
    }
    // glass parameters (begin_blur_layer): only pointer, content must feed field-by-field; if
    // per-frame changes like scroll_edge_strength / interactive boost don't enter fingerprint,
    // retained
    // layer gets stale hit (existing gap, added 2026-07-30).
    if (it.glass_ptr) |gp| {
        const g = gp.*;
        if (@typeInfo(@TypeOf(g)) == .@"struct") {
            inline for (@import("zenit_reflection").fields(@TypeOf(g))) |f| {
                hasher.update(std.mem.asBytes(&@field(g, f.name)));
            }
            if (!glass_address and @hasField(@TypeOf(g), "group")) {
                // The group itself has scope lifetime and stable identity, but
                // its table can mutate in place between the two snapshots.
                if (g.group) |group| hasher.update(std.mem.asBytes(&group.version));
            }
        }
    }
    // arc: spinner/progress ring angle changes per-frame while geom (center) stays; not feeding
    // ensures stale.
    hasher.update(std.mem.asBytes(&it.arc_start_angle));
    hasher.update(std.mem.asBytes(&it.arc_end_angle));
    hasher.update(std.mem.asBytes(&it.arc_outer_radius));
    // Border / noise.
    hasher.update(std.mem.asBytes(&it.border_widths));
    hasher.update(std.mem.asBytes(&it.noise_mode));
    hasher.update(std.mem.asBytes(&it.noise_scale));
    hasher.update(std.mem.asBytes(&it.noise_intensity));
    hasher.update(std.mem.asBytes(&it.noise_seed));
    // Film grain (noise mode 2) is reseeded from the frame index in the shader:
    // a retained surface holding it froze the grain (the legacy painter never
    // retained such groups), and the damage tracker saw no change.
    if (it.noise_mode == 2 and it.noise_intensity > 0) hasher.update(std.mem.asBytes(&frame_salt));
    hasher.update(std.mem.asBytes(&it.path_line_join));
    // text: content + font-size / font-weight / font flags all affect pixels.
    hasher.update(it.text_content);
    hasher.update(std.mem.asBytes(&it.text_font_size));
    hasher.update(std.mem.asBytes(&it.text_font_weight));
    // Font family must enter fingerprint: changing font with same size/weight, missing fingerprint
    // skips redraw.
    hasher.update(std.mem.asBytes(&it.text_font_family));
    hasher.update(std.mem.asBytes(&it.text_font_flags));
    hasher.update(std.mem.asBytes(&it.text_raster_policy));
    // Image/icon identity. text's resource_handle is blob_id (shaping cache handle); pixels
    // determined
    // entirely by content + font params; blob identity **doesn't enter fingerprint**: overlay
    // subtree
    // rebuild re-allocates blob for identical-content text, feeding kills retained hit and ruins
    // per-item
    // diff (100% dirty).
    if (it.kind != .text) hasher.update(std.mem.asBytes(&it.resource_handle));
    hasher.update(std.mem.asBytes(&it.text_monospace_char_width));
    hasher.update(std.mem.asBytes(&it.image_opacity));
    hasher.update(std.mem.asBytes(&it.image_tint));
    hasher.update(std.mem.asBytes(&it.image_corner_radius));
    hasher.update(std.mem.asBytes(&it.icon_tint));
    hasher.update(std.mem.asBytes(&it.icon_rep_size));
    hasher.update(std.mem.asBytes(&it.icon_corner_clip_radius));
    // Shadow / gradient also affect pixels.
    hasher.update(std.mem.asBytes(&it.shadow2_color));
    // text_spans: span coloring/weight changes (selection highlight, syntax color) don't modify
    // text
    // bytes; feed field-by-field (struct bytewise hash reads padding, unstable).
    if (it.text_spans) |spans| {
        var span_len: usize = spans.len;
        hasher.update(std.mem.asBytes(&span_len));
        for (spans) |sp| {
            hasher.update(std.mem.asBytes(&sp.start));
            hasher.update(std.mem.asBytes(&sp.end));
            hashOptionalColor(hasher, sp.color);
            if (sp.font_weight) |fw| hasher.update(std.mem.asBytes(&fw)) else hasher.update("n");
            const flags = [_]bool{ sp.use_italic_font, sp.use_monospace_font, sp.strikethrough };
            hasher.update(std.mem.asBytes(&flags));
            hashOptionalColor(hasher, sp.bg_color);
        }
    }
    // path geometry: **must feed vertex content**. Feeding only pointer value: after frame_arena
    // reset
    // each frame, same allocation order reuses address; same pointer, new content = stale path
    // false hit
    // (P0). PathCommand is union; bytewise hash reads padding; feed per-tag payload.
    if (it.path_geometry_ptr) |pg| {
        hasher.update(std.mem.asBytes(&pg.fill_rule));
        var cmd_len: usize = pg.commands.len;
        hasher.update(std.mem.asBytes(&cmd_len));
        for (pg.commands) |cmd| {
            const tag: u8 = @backingInt(cmd);
            hasher.update(std.mem.asBytes(&tag));
            switch (cmd) {
                .move_to, .line_to => |pt| hasher.update(std.mem.asBytes(&pt)),
                .quad_to => |q| hasher.update(std.mem.asBytes(&q)),
                .cubic_to => |c| hasher.update(std.mem.asBytes(&c)),
                .close => {},
            }
        }
    }
    // polygon clip: points live in frame_arena, same address after reset each frame; feeding only
    // pointer = same pointer, new content false hit (same class as path geometry P0). Feed
    // field-by-field by content (whole asBytes reads padding); points outside valid range don't
    // affect
    // pixels, don't feed.
    if (it.clip_polygon_ptr) |cp| {
        const pc: usize = @min(@as(usize, cp.point_count), cp.points.len);
        const cc: usize = @min(@as(usize, cp.contour_count), cp.contour_end_points.len);
        hasher.update(std.mem.asBytes(&cp.point_count));
        hasher.update(std.mem.asBytes(&cp.contour_count));
        const fr: u8 = @backingInt(cp.fill_rule);
        hasher.update(std.mem.asBytes(&fr));
        hasher.update(std.mem.sliceAsBytes(cp.contour_end_points[0..cc]));
        hasher.update(std.mem.sliceAsBytes(cp.points[0..pc]));
    } else {
        hasher.update("np");
    }
    // Remaining pointer payload (glass/icon_rep): feed the pointer value. glass content is already
    // fed
    // field by field above; icon_rep is generated statically from icon_id and never mutated in
    // place;
    // the pointer value distinguishes within a frame only. WARNING: implicit contract:
    // resource_handle's
    // GPU texture content must be immutable (an animated/video in-place texture-update path would
    // need
    // a version number fed into the fingerprint).
    if (glass_address) hasher.update(std.mem.asBytes(&@intFromPtr(it.glass_ptr)));
    if (glass_address) {
        hasher.update(std.mem.asBytes(&@intFromPtr(it.icon_rep_ptr)));
    } else if (it.icon_rep_ptr) |rep| {
        hasher.update("icon");
        hasher.update(std.mem.asBytes(&rep.size));
        hasher.update(std.mem.asBytes(&rep.view_min_x));
        hasher.update(std.mem.asBytes(&rep.view_min_y));
        hasher.update(std.mem.asBytes(&rep.view_width));
        hasher.update(std.mem.asBytes(&rep.view_height));
        hasher.update(std.mem.asBytes(&rep.shapes.len));
        for (rep.shapes) |shape| {
            hasher.update(std.mem.asBytes(&shape.fill));
            hasher.update(std.mem.asBytes(&shape.stroke_width));
            hasher.update(std.mem.asBytes(&shape.fill_rule));
            hasher.update(std.mem.asBytes(&shape.contours.len));
            for (shape.contours) |contour| {
                hasher.update(std.mem.asBytes(&contour.closed));
                hasher.update(std.mem.asBytes(&contour.points.len));
                for (contour.points) |point| {
                    hasher.update(std.mem.asBytes(&point.x));
                    hasher.update(std.mem.asBytes(&point.y));
                }
            }
        }
    } else hasher.update("no-icon");
}

pub fn hashOptionalColor(hasher: *std.hash.Wyhash, c: anytype) void {
    if (c) |v| {
        hasher.update("c");
        hasher.update(std.mem.asBytes(&v));
    } else {
        hasher.update("n");
    }
}

pub const NoOpStructuralBlock = struct {
    end_index: usize,
    pair_count: u32,
};

pub fn tryFindNoOpStructuralBlock(commands: anytype, start: usize) ?NoOpStructuralBlock {
    if (start >= commands.len) return null;
    const begin_tok = structuralToken(commands[start]);
    if (!isBeginStructuralToken(begin_tok)) return null;
    const expected_end = matchingEndStructuralToken(begin_tok);
    if (expected_end == .none) return null;

    var pair_count: u32 = 1;
    var i = start + 1;
    while (i < commands.len) {
        const tok = structuralToken(commands[i]);
        if (tok == .none) return null; // encounter real paint command, non-empty struct block.
        if (tok == expected_end) {
            return .{
                .end_index = i,
                .pair_count = pair_count,
            };
        }
        if (isBeginStructuralToken(tok)) {
            const nested = tryFindNoOpStructuralBlock(commands, i) orelse return null;
            pair_count +|= nested.pair_count;
            i = nested.end_index + 1;
            continue;
        }
        // unexpected end token (unbalanced struct) or other struct noise, don't fold.
        return null;
    }
    return null; // no matching end found.
}
