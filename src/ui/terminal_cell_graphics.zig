//! Terminal cell graphics use the VT cell, not the font's ink bounds. The
//! original grapheme stays in the text node for inspection/copy/selection.
const std = @import("std");
const ui = @import("ui");

pub fn codepoint(text: []const u8) ?u21 {
    if (text.len != 3 or text[0] != 0xe2) return null;
    const cp = std.unicode.utf8Decode(text) catch return null;
    return if (cp >= 0x2500 and cp <= 0x259f) cp else null;
}

pub const Drawing = struct {
    cp: u21 = 0,
    color: ui.Color = ui.Color.TRANSPARENT,
    font_size: f32 = 14,
    scale: f32 = 1,

    pub fn draw(ctx: ui.DrawContext, raw: ?*anyopaque) anyerror!void {
        const self: *const Drawing = @ptrCast(@alignCast(raw orelse return));
        if (self.cp == 0 or self.color.a == 0) return;
        const dl = ctx.display_list orelse return;
        const header = ctx.display_header orelse return;
        const scale = @max(1, self.scale);
        const t = @max(1, @round(self.font_size / 12 * scale)) / scale;
        const shape = geometry(self.cp, ctx.local_w, ctx.local_h, t);
        for (shape.rects[0..shape.len]) |r| {
            // Snap *shared absolute edges*, including the outer cell edges.
            // Rounding widths independently creates holes at fractional pitches.
            const x = snap(ctx.render_x, r.x, scale);
            const y = snap(ctx.render_y, r.y, scale);
            const right = snap(ctx.render_x, r.x + r.w, scale);
            const bottom = snap(ctx.render_y, r.y + r.h, scale);
            if (right <= x or bottom <= y) continue;
            try dl.append(.{ .fill_rect = .{ .header = header, .x = x, .y = y, .w = right - x, .h = bottom - y, .color = self.color } });
        }
        if (self.cp >= 0x256d and self.cp <= 0x2573) {
            const commands = try ctx.frame_allocator.alloc(ui.path.PathCommand, 6);
            var count: usize = 0;
            const w = ctx.local_w;
            const h = ctx.local_h;
            if (self.cp <= 0x2570) {
                const spec = box_specs[self.cp - 0x2500];
                const dx: f32 = if (spec.r > 0) 1 else -1;
                const dy: f32 = if (spec.d > 0) 1 else -1;
                const radius = @min(w, h) / 2;
                commands[0] = .{ .move_to = .{ .x = if (dx > 0) w else 0, .y = h / 2 } };
                commands[1] = .{ .line_to = .{ .x = w / 2 + dx * radius, .y = h / 2 } };
                commands[2] = .{ .quad_to = .{ .ctrl = .{ .x = w / 2, .y = h / 2 }, .end = .{ .x = w / 2, .y = h / 2 + dy * radius } } };
                commands[3] = .{ .line_to = .{ .x = w / 2, .y = if (dy > 0) h else 0 } };
                count = 4;
            } else {
                if (self.cp != 0x2572) {
                    commands[count] = .{ .move_to = .{ .x = w, .y = 0 } };
                    count += 1;
                    commands[count] = .{ .line_to = .{ .x = 0, .y = h } };
                    count += 1;
                }
                if (self.cp != 0x2571) {
                    commands[count] = .{ .move_to = .{ .x = 0, .y = 0 } };
                    count += 1;
                    commands[count] = .{ .line_to = .{ .x = w, .y = h } };
                    count += 1;
                }
            }
            const path = try ctx.frame_allocator.create(ui.path.PathGeometry);
            path.* = .{ .commands = commands[0..count], .bounds = .{ .x = 0, .y = 0, .w = w, .h = h } };
            try dl.append(.{ .stroke_path = .{ .header = header, .geometry = path, .color = self.color, .width = t } });
        }
    }
};

fn snap(origin: f32, offset: f32, scale: f32) f32 {
    return @round((origin + offset) * scale) / scale - origin;
}

pub const Shape = struct {
    rects: [32]ui.ComputedRect = undefined,
    len: usize = 0,
    fn rect(self: *Shape, x: f32, y: f32, w: f32, h: f32) void {
        if (w <= 0 or h <= 0) return;
        self.rects[self.len] = .{ .x = x, .y = y, .w = w, .h = h };
        self.len += 1;
    }
};

pub fn geometry(cp: u21, w: f32, h: f32, t: f32) Shape {
    var out: Shape = .{};
    if (cp >= 0x2580 and cp <= 0x259f) {
        switch (cp) {
            0x2580 => out.rect(0, 0, w, h / 2),
            0x2581...0x2588 => {
                const height = h * @as(f32, @floatFromInt(cp - 0x2580)) / 8;
                out.rect(0, h - height, w, height);
            },
            0x2589...0x258f => out.rect(0, 0, w * @as(f32, @floatFromInt(0x2590 - cp)) / 8, h),
            0x2590 => out.rect(w / 2, 0, w / 2, h),
            0x2591...0x2593 => {
                // Stable 4x8 stipple tiles; shade density is independent of font fallback.
                for (0..8) |y| for (0..4) |x| {
                    const rank = ((x + y) % 2) * 2 + (y % 2);
                    if (rank < cp - 0x2590) out.rect(w * @as(f32, @floatFromInt(x)) / 4, h * @as(f32, @floatFromInt(y)) / 8, w / 4, h / 8);
                };
            },
            0x2594 => out.rect(0, 0, w, h / 8),
            0x2595 => out.rect(w * 7 / 8, 0, w / 8, h),
            0x2596...0x259f => {
                const masks = [_]u4{ 4, 8, 1, 13, 9, 7, 11, 2, 6, 14 };
                const mask = masks[cp - 0x2596];
                for (0..4) |q| if (mask & (@as(u4, 1) << @intCast(q)) != 0) {
                    out.rect(if (q % 2 == 0) 0 else w / 2, if (q < 2) 0 else h / 2, w / 2, h / 2);
                };
            },
            else => unreachable,
        }
        return out;
    }
    if (cp < 0x2500 or cp > 0x257f or (cp >= 0x256d and cp <= 0x2573)) return out;
    const spec = box_specs[cp - 0x2500];
    if (spec.dash > 0) {
        const vertical = spec.u > 0;
        const length = if (vertical) h else w;
        const thickness = if (@max(spec.u, spec.l) == 2) 2 * t else t;
        for (0..spec.dash) |i| {
            const start = length * (@as(f32, @floatFromInt(i)) + 0.15) / @as(f32, @floatFromInt(spec.dash));
            const end = length * (@as(f32, @floatFromInt(i)) + 0.85) / @as(f32, @floatFromInt(spec.dash));
            if (vertical) out.rect((w - thickness) / 2, start, thickness, end - start) else out.rect(start, (h - thickness) / 2, end - start, thickness);
        }
        return out;
    }
    // Arms meet on the same centre and retain light/heavy/double stroke kinds.
    const arms = [_]u2{ spec.l, spec.r, spec.u, spec.d };
    for (arms, 0..) |kind, direction| {
        if (kind == 0) continue;
        const horizontal = direction < 2;
        const positive = direction == 1 or direction == 3;
        const length = if (horizontal) w else h;
        const breadth = if (horizontal) h else w;
        const perpendicular = if (horizontal) @max(spec.u, spec.d) else @max(spec.l, spec.r);
        const join = if (perpendicular == 3) 1.5 * t else if (perpendicular == 2) t else if (perpendicular == 1) t / 2 else 0;
        const thickness = if (kind == 2) 2 * t else t;
        const lanes: usize = if (kind == 3) 2 else 1;
        for (0..lanes) |lane| {
            const offset: f32 = if (kind != 3) 0 else if (lane == 0) -t else t;
            var end = length / 2 + (if (positive) -join else join);
            // A double elbow joins the corresponding inner and outer lanes,
            // leaving its centre open instead of drawing a solid cross.
            const p1 = if (horizontal) spec.u else spec.l;
            const p2 = if (horizontal) spec.d else spec.r;
            if (kind == 3 and perpendicular == 3 and (p1 == 0 or p2 == 0)) {
                const outer = (p1 == 0 and lane == 0) or (p2 == 0 and lane == 1);
                const reach = if (outer) 1.5 * t else -0.5 * t;
                end = length / 2 + (if (positive) -reach else reach);
            }
            const start: f32 = if (positive) end else 0;
            const finish = if (positive) length else end;
            if (horizontal) out.rect(start, breadth / 2 + offset - thickness / 2, finish - start, thickness) else out.rect(breadth / 2 + offset - thickness / 2, start, thickness, finish - start);
        }
    }
    return out;
}

// Unicode Box Drawing direction/stroke map. 0 absent, 1 light/single,
// 2 heavy, 3 double. Dashed and rounded glyphs retain their intended gaps.
const Box = struct { l: u2, r: u2, u: u2, d: u2, dash: u3 = 0 };
const box_specs = [_]Box{
    .{ .l = 1, .r = 1, .u = 0, .d = 0, .dash = 0 }, // 2500 ─
    .{ .l = 2, .r = 2, .u = 0, .d = 0, .dash = 0 }, // 2501 ━
    .{ .l = 0, .r = 0, .u = 1, .d = 1, .dash = 0 }, // 2502 │
    .{ .l = 0, .r = 0, .u = 2, .d = 2, .dash = 0 }, // 2503 ┃
    .{ .l = 1, .r = 1, .u = 0, .d = 0, .dash = 3 }, // 2504 ┄
    .{ .l = 2, .r = 2, .u = 0, .d = 0, .dash = 3 }, // 2505 ┅
    .{ .l = 0, .r = 0, .u = 1, .d = 1, .dash = 3 }, // 2506 ┆
    .{ .l = 0, .r = 0, .u = 2, .d = 2, .dash = 3 }, // 2507 ┇
    .{ .l = 1, .r = 1, .u = 0, .d = 0, .dash = 4 }, // 2508 ┈
    .{ .l = 2, .r = 2, .u = 0, .d = 0, .dash = 4 }, // 2509 ┉
    .{ .l = 0, .r = 0, .u = 1, .d = 1, .dash = 4 }, // 250A ┊
    .{ .l = 0, .r = 0, .u = 2, .d = 2, .dash = 4 }, // 250B ┋
    .{ .l = 0, .r = 1, .u = 0, .d = 1, .dash = 0 }, // 250C ┌
    .{ .l = 0, .r = 2, .u = 0, .d = 1, .dash = 0 }, // 250D ┍
    .{ .l = 0, .r = 1, .u = 0, .d = 2, .dash = 0 }, // 250E ┎
    .{ .l = 0, .r = 2, .u = 0, .d = 2, .dash = 0 }, // 250F ┏
    .{ .l = 1, .r = 0, .u = 0, .d = 1, .dash = 0 }, // 2510 ┐
    .{ .l = 2, .r = 0, .u = 0, .d = 1, .dash = 0 }, // 2511 ┑
    .{ .l = 1, .r = 0, .u = 0, .d = 2, .dash = 0 }, // 2512 ┒
    .{ .l = 2, .r = 0, .u = 0, .d = 2, .dash = 0 }, // 2513 ┓
    .{ .l = 0, .r = 1, .u = 1, .d = 0, .dash = 0 }, // 2514 └
    .{ .l = 0, .r = 2, .u = 1, .d = 0, .dash = 0 }, // 2515 ┕
    .{ .l = 0, .r = 1, .u = 2, .d = 0, .dash = 0 }, // 2516 ┖
    .{ .l = 0, .r = 2, .u = 2, .d = 0, .dash = 0 }, // 2517 ┗
    .{ .l = 1, .r = 0, .u = 1, .d = 0, .dash = 0 }, // 2518 ┘
    .{ .l = 2, .r = 0, .u = 1, .d = 0, .dash = 0 }, // 2519 ┙
    .{ .l = 1, .r = 0, .u = 2, .d = 0, .dash = 0 }, // 251A ┚
    .{ .l = 2, .r = 0, .u = 2, .d = 0, .dash = 0 }, // 251B ┛
    .{ .l = 0, .r = 1, .u = 1, .d = 1, .dash = 0 }, // 251C ├
    .{ .l = 0, .r = 2, .u = 1, .d = 1, .dash = 0 }, // 251D ┝
    .{ .l = 0, .r = 1, .u = 2, .d = 1, .dash = 0 }, // 251E ┞
    .{ .l = 0, .r = 1, .u = 1, .d = 2, .dash = 0 }, // 251F ┟
    .{ .l = 0, .r = 1, .u = 2, .d = 2, .dash = 0 }, // 2520 ┠
    .{ .l = 0, .r = 2, .u = 2, .d = 1, .dash = 0 }, // 2521 ┡
    .{ .l = 0, .r = 2, .u = 1, .d = 2, .dash = 0 }, // 2522 ┢
    .{ .l = 0, .r = 2, .u = 2, .d = 2, .dash = 0 }, // 2523 ┣
    .{ .l = 1, .r = 0, .u = 1, .d = 1, .dash = 0 }, // 2524 ┤
    .{ .l = 2, .r = 0, .u = 1, .d = 1, .dash = 0 }, // 2525 ┥
    .{ .l = 1, .r = 0, .u = 2, .d = 1, .dash = 0 }, // 2526 ┦
    .{ .l = 1, .r = 0, .u = 1, .d = 2, .dash = 0 }, // 2527 ┧
    .{ .l = 1, .r = 0, .u = 2, .d = 2, .dash = 0 }, // 2528 ┨
    .{ .l = 2, .r = 0, .u = 2, .d = 1, .dash = 0 }, // 2529 ┩
    .{ .l = 2, .r = 0, .u = 1, .d = 2, .dash = 0 }, // 252A ┪
    .{ .l = 2, .r = 0, .u = 2, .d = 2, .dash = 0 }, // 252B ┫
    .{ .l = 1, .r = 1, .u = 0, .d = 1, .dash = 0 }, // 252C ┬
    .{ .l = 2, .r = 1, .u = 0, .d = 1, .dash = 0 }, // 252D ┭
    .{ .l = 1, .r = 2, .u = 0, .d = 1, .dash = 0 }, // 252E ┮
    .{ .l = 2, .r = 2, .u = 0, .d = 1, .dash = 0 }, // 252F ┯
    .{ .l = 1, .r = 1, .u = 0, .d = 2, .dash = 0 }, // 2530 ┰
    .{ .l = 2, .r = 1, .u = 0, .d = 2, .dash = 0 }, // 2531 ┱
    .{ .l = 1, .r = 2, .u = 0, .d = 2, .dash = 0 }, // 2532 ┲
    .{ .l = 2, .r = 2, .u = 0, .d = 2, .dash = 0 }, // 2533 ┳
    .{ .l = 1, .r = 1, .u = 1, .d = 0, .dash = 0 }, // 2534 ┴
    .{ .l = 2, .r = 1, .u = 1, .d = 0, .dash = 0 }, // 2535 ┵
    .{ .l = 1, .r = 2, .u = 1, .d = 0, .dash = 0 }, // 2536 ┶
    .{ .l = 2, .r = 2, .u = 1, .d = 0, .dash = 0 }, // 2537 ┷
    .{ .l = 1, .r = 1, .u = 2, .d = 0, .dash = 0 }, // 2538 ┸
    .{ .l = 2, .r = 1, .u = 2, .d = 0, .dash = 0 }, // 2539 ┹
    .{ .l = 1, .r = 2, .u = 2, .d = 0, .dash = 0 }, // 253A ┺
    .{ .l = 2, .r = 2, .u = 2, .d = 0, .dash = 0 }, // 253B ┻
    .{ .l = 1, .r = 1, .u = 1, .d = 1, .dash = 0 }, // 253C ┼
    .{ .l = 2, .r = 1, .u = 1, .d = 1, .dash = 0 }, // 253D ┽
    .{ .l = 1, .r = 2, .u = 1, .d = 1, .dash = 0 }, // 253E ┾
    .{ .l = 2, .r = 2, .u = 1, .d = 1, .dash = 0 }, // 253F ┿
    .{ .l = 1, .r = 1, .u = 2, .d = 1, .dash = 0 }, // 2540 ╀
    .{ .l = 1, .r = 1, .u = 1, .d = 2, .dash = 0 }, // 2541 ╁
    .{ .l = 1, .r = 1, .u = 2, .d = 2, .dash = 0 }, // 2542 ╂
    .{ .l = 2, .r = 1, .u = 2, .d = 1, .dash = 0 }, // 2543 ╃
    .{ .l = 1, .r = 2, .u = 2, .d = 1, .dash = 0 }, // 2544 ╄
    .{ .l = 2, .r = 1, .u = 1, .d = 2, .dash = 0 }, // 2545 ╅
    .{ .l = 1, .r = 2, .u = 1, .d = 2, .dash = 0 }, // 2546 ╆
    .{ .l = 2, .r = 2, .u = 2, .d = 1, .dash = 0 }, // 2547 ╇
    .{ .l = 2, .r = 2, .u = 1, .d = 2, .dash = 0 }, // 2548 ╈
    .{ .l = 2, .r = 1, .u = 2, .d = 2, .dash = 0 }, // 2549 ╉
    .{ .l = 1, .r = 2, .u = 2, .d = 2, .dash = 0 }, // 254A ╊
    .{ .l = 2, .r = 2, .u = 2, .d = 2, .dash = 0 }, // 254B ╋
    .{ .l = 1, .r = 1, .u = 0, .d = 0, .dash = 2 }, // 254C ╌
    .{ .l = 2, .r = 2, .u = 0, .d = 0, .dash = 2 }, // 254D ╍
    .{ .l = 0, .r = 0, .u = 1, .d = 1, .dash = 2 }, // 254E ╎
    .{ .l = 0, .r = 0, .u = 2, .d = 2, .dash = 2 }, // 254F ╏
    .{ .l = 3, .r = 3, .u = 0, .d = 0, .dash = 0 }, // 2550 ═
    .{ .l = 0, .r = 0, .u = 3, .d = 3, .dash = 0 }, // 2551 ║
    .{ .l = 0, .r = 3, .u = 0, .d = 1, .dash = 0 }, // 2552 ╒
    .{ .l = 0, .r = 1, .u = 0, .d = 3, .dash = 0 }, // 2553 ╓
    .{ .l = 0, .r = 3, .u = 0, .d = 3, .dash = 0 }, // 2554 ╔
    .{ .l = 3, .r = 0, .u = 0, .d = 1, .dash = 0 }, // 2555 ╕
    .{ .l = 1, .r = 0, .u = 0, .d = 3, .dash = 0 }, // 2556 ╖
    .{ .l = 3, .r = 0, .u = 0, .d = 3, .dash = 0 }, // 2557 ╗
    .{ .l = 0, .r = 3, .u = 1, .d = 0, .dash = 0 }, // 2558 ╘
    .{ .l = 0, .r = 1, .u = 3, .d = 0, .dash = 0 }, // 2559 ╙
    .{ .l = 0, .r = 3, .u = 3, .d = 0, .dash = 0 }, // 255A ╚
    .{ .l = 3, .r = 0, .u = 1, .d = 0, .dash = 0 }, // 255B ╛
    .{ .l = 1, .r = 0, .u = 3, .d = 0, .dash = 0 }, // 255C ╜
    .{ .l = 3, .r = 0, .u = 3, .d = 0, .dash = 0 }, // 255D ╝
    .{ .l = 0, .r = 3, .u = 1, .d = 1, .dash = 0 }, // 255E ╞
    .{ .l = 0, .r = 1, .u = 3, .d = 3, .dash = 0 }, // 255F ╟
    .{ .l = 0, .r = 3, .u = 3, .d = 3, .dash = 0 }, // 2560 ╠
    .{ .l = 3, .r = 0, .u = 1, .d = 1, .dash = 0 }, // 2561 ╡
    .{ .l = 1, .r = 0, .u = 3, .d = 3, .dash = 0 }, // 2562 ╢
    .{ .l = 3, .r = 0, .u = 3, .d = 3, .dash = 0 }, // 2563 ╣
    .{ .l = 3, .r = 3, .u = 0, .d = 1, .dash = 0 }, // 2564 ╤
    .{ .l = 1, .r = 1, .u = 0, .d = 3, .dash = 0 }, // 2565 ╥
    .{ .l = 3, .r = 3, .u = 0, .d = 3, .dash = 0 }, // 2566 ╦
    .{ .l = 3, .r = 3, .u = 1, .d = 0, .dash = 0 }, // 2567 ╧
    .{ .l = 1, .r = 1, .u = 3, .d = 0, .dash = 0 }, // 2568 ╨
    .{ .l = 3, .r = 3, .u = 3, .d = 0, .dash = 0 }, // 2569 ╩
    .{ .l = 3, .r = 3, .u = 1, .d = 1, .dash = 0 }, // 256A ╪
    .{ .l = 1, .r = 1, .u = 3, .d = 3, .dash = 0 }, // 256B ╫
    .{ .l = 3, .r = 3, .u = 3, .d = 3, .dash = 0 }, // 256C ╬
    .{ .l = 0, .r = 1, .u = 0, .d = 1, .dash = 0 }, // 256D ╭
    .{ .l = 1, .r = 0, .u = 0, .d = 1, .dash = 0 }, // 256E ╮
    .{ .l = 1, .r = 0, .u = 1, .d = 0, .dash = 0 }, // 256F ╯
    .{ .l = 0, .r = 1, .u = 1, .d = 0, .dash = 0 }, // 2570 ╰
    .{ .l = 1, .r = 1, .u = 0, .d = 0, .dash = 0 }, // 2571 ╱
    .{ .l = 1, .r = 1, .u = 0, .d = 0, .dash = 0 }, // 2572 ╲
    .{ .l = 0, .r = 0, .u = 0, .d = 0, .dash = 0 }, // 2573 ╳
    .{ .l = 1, .r = 0, .u = 0, .d = 0, .dash = 0 }, // 2574 ╴
    .{ .l = 0, .r = 0, .u = 1, .d = 0, .dash = 0 }, // 2575 ╵
    .{ .l = 0, .r = 1, .u = 0, .d = 0, .dash = 0 }, // 2576 ╶
    .{ .l = 0, .r = 0, .u = 0, .d = 1, .dash = 0 }, // 2577 ╷
    .{ .l = 2, .r = 0, .u = 0, .d = 0, .dash = 0 }, // 2578 ╸
    .{ .l = 0, .r = 0, .u = 2, .d = 0, .dash = 0 }, // 2579 ╹
    .{ .l = 0, .r = 2, .u = 0, .d = 0, .dash = 0 }, // 257A ╺
    .{ .l = 0, .r = 0, .u = 0, .d = 2, .dash = 0 }, // 257B ╻
    .{ .l = 1, .r = 2, .u = 0, .d = 0, .dash = 0 }, // 257C ╼
    .{ .l = 0, .r = 0, .u = 1, .d = 2, .dash = 0 }, // 257D ╽
    .{ .l = 2, .r = 1, .u = 0, .d = 0, .dash = 0 }, // 257E ╾
    .{ .l = 0, .r = 0, .u = 2, .d = 1, .dash = 0 }, // 257F ╿
};
