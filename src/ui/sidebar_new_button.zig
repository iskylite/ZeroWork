//! M-NEWHOST: a native dashed empty slot, independent of SVG texture loading.
const std = @import("std");
const ui = @import("ui");
const S = @import("sidebar_styles.zig");
const T = S.theme;

pub fn mount(cx: *ui.Cx, scope: *ui.Scope, slot: *ui.Node, id: []const u8, empty: bool, disabled: *ui.Signal(bool), on_click: ui.Handler(void)) !void {
    const base = try scope.createSignal(ui.BoxStyle, if (empty) S.emptyFooter() else S.footer());
    const interaction = try scope.createSignal(?ui.BoxStyle, .{});
    const tint = try scope.createSignal(?ui.Color, T.current().fg_2);
    const button = try ui.widgets.Button(.{ .label = "新建连接", .icon_asset = ui.icons.plus, .icon_size = @as(f32, 14), .icon_tint = tint, .variant = .ghost, .focus_ring = .{ .color = T.current().accent, .width = 0, .offset = 0 }, .a11y_label = "新建连接", .base_style = base, .hover_style = interaction, .pressed_style = interaction, .disabled = disabled, .on_click = on_click }).mount(scope, cx);
    // This component paints keyboard focus with its theme fill, without an outline.
    if (button.meta.per_frame.hooks.slots.focus_ring_anim) |raw| {
        const focus: *ui.hooks.FocusRingAnimState = @ptrCast(@alignCast(raw));
        focus.focus_color = ui.Color.TRANSPARENT;
    }
    button.meta.ownership.meta.test_id = id;
    button.applyTransition(cx.allocator, &(comptime ui.transition("background 160ms ease")));
    try slot.appendChild(cx.allocator, button);
    const frame = try ui.box(cx, .{ .position = .absolute, .inset = .{ .left = .{ .px = 0 }, .top = .{ .px = 0 } }, .width = .fill(), .height = .{ .px = 34 }, .border = .{ .color = T.current().well_border, .radius = if (empty) 9 else 8 }, .hit_behavior = .pass_through }, .{});
    frame.meta.ownership.meta.test_id = "sidebar.footer.frame";
    frame.applyTransition(cx.allocator, &(comptime ui.transition("border-color 160ms ease")));
    frame.setHitTestVisible(false);
    frame.setCustomDraw(draw, frame);
    try slot.appendChild(cx.allocator, frame);
    try scope.createEffect(.{ .cx = cx, .base = base, .interaction = interaction, .tint = tint, .frame = frame, .empty = empty, .disabled = disabled, .hovered = try ui.hooks.useHover(scope, button), .pressed = try ui.hooks.usePressed(scope, cx, button), .focused = (try ui.hooks.useFocusState(scope, cx, button)).visible, .publication = try cx.themeSignal(scope) }, struct {
        fn paint(ctx: anytype) void {
            _ = ctx.publication.get();
            const unavailable = ctx.disabled.get();
            const hot = !unavailable and (ctx.hovered.get() or ctx.focused.get());
            const down = !unavailable and ctx.pressed.get() and ctx.hovered.get();
            var style = if (ctx.empty) S.emptyFooter() else S.footer();
            style.background = if (down) T.states().pressed else if (ctx.focused.get() and !unavailable) T.states().focus else if (hot) T.states().selected else ui.Color.TRANSPARENT;
            style.text_color = if (hot) T.current().accent_ink else T.current().fg_2;
            ctx.base.set(style);
            ctx.interaction.set(.{ .background = style.background });
            ctx.tint.set(style.text_color);
            ctx.frame.setBorderColor(if (hot) T.current().accent else T.current().well_border);
            ctx.frame.setOpacity(if (unavailable) 0.5 else 1);
        }
    }.paint);
}

fn point(w: f32, h: f32, radius: f32, distance: f32) ui.Point {
    const inset: f32 = 0.75;
    const r = radius - inset;
    const arc = std.math.pi / 2.0 * r;
    var remaining = distance;
    for (0..4) |side| {
        const length = if (side % 2 == 0) w - 2 * radius else h - 2 * radius;
        if (remaining <= length) return switch (side) {
            0 => .{ .x = radius + remaining, .y = inset },
            1 => .{ .x = w - inset, .y = radius + remaining },
            2 => .{ .x = w - radius - remaining, .y = h - inset },
            else => .{ .x = inset, .y = h - radius - remaining },
        };
        remaining -= length;
        if (remaining <= arc) {
            const angle = -std.math.pi / 2.0 + @as(f32, @floatFromInt(side)) * std.math.pi / 2.0 + remaining / r;
            return .{ .x = (if (side < 2) w - radius else radius) + r * @cos(angle), .y = (if (side == 0 or side == 3) radius else h - radius) + r * @sin(angle) };
        }
        remaining -= arc;
    }
    return .{ .x = radius, .y = inset };
}

fn draw(ctx: ui.DrawContext, raw: ?*anyopaque) anyerror!void {
    const node: *ui.Node = @ptrCast(@alignCast(raw orelse return));
    const dl = ctx.display_list orelse return;
    const header = ctx.display_header orelse return;
    const w = ctx.local_w;
    const h = ctx.local_h;
    const radius = node.style.border.radius;
    const perimeter = 2 * (w + h - 4 * radius) + std.math.tau * (radius - 0.75);
    if (w < 2 * radius or h < 2 * radius) return;
    const dashes: usize = @intFromFloat(@ceil(perimeter / 9));
    const commands = try ctx.frame_allocator.alloc(ui.path.PathCommand, dashes * 6);
    var count: usize = 0;
    for (0..dashes) |index| {
        const start = @as(f32, @floatFromInt(index)) * 9;
        const end = @min(start + 4.5, perimeter);
        commands[count] = .{ .move_to = point(w, h, radius, start) };
        count += 1;
        for (1..6) |step| {
            commands[count] = .{ .line_to = point(w, h, radius, start + (end - start) * @as(f32, @floatFromInt(step)) / 5) };
            count += 1;
        }
    }
    const path = try ctx.frame_allocator.create(ui.path.PathGeometry);
    path.* = .{ .commands = commands[0..count], .bounds = .{ .x = 0, .y = 0, .w = w, .h = h } };
    try dl.append(.{ .stroke_path = .{ .header = header, .geometry = path, .color = node.style.border.color, .width = 1.5 } });
}
