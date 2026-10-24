//! Slider style layer, track / fill / thumb style declaration (geometry parameterized by props).
const core = @import("../../core.zig");
const Color = core.Color;
const SliderProps = @import("mod.zig").SliderProps;

pub fn trackStyle(p: SliderProps, t: *const core.ThemeTokens) core.BoxStyle {
    return .{
        .width = .{ .grow = .{} },
        .height = .{ .px = p.track_height },
        .background = t.tokens.color.bg_tertiary,
        .border = .{ .radius = p.track_height / 2 },
    };
}

pub fn fillStyle(p: SliderProps, accent: Color, ratio: f32) core.BoxStyle {
    return .{
        .width = .{ .percent = ratio * 100 },
        .height = .{ .px = p.track_height },
        .background = accent,
        .border = .{ .radius = p.track_height / 2 },
    };
}

pub fn thumbBackground(disabled: bool, t: *const core.ThemeTokens) Color {
    return if (disabled) t.tokens.color.fg_disabled else Color.hex(0xffffff);
}

pub fn thumbStyle(p: SliderProps, disabled: bool, accent: Color, t: *const core.ThemeTokens) core.BoxStyle {
    return .{
        .position = .absolute,
        .width = .{ .px = p.thumb_size },
        .height = .{ .px = p.thumb_size },
        .background = thumbBackground(disabled, t),
        .border = .{ .radius = p.thumb_size / 2, .width = 2, .color = accent },
        // Drag handle shadow: more solid than generic shadow.sm, lets thumb 'float' from track.
        // Small floating controls use higher opacity + compact blur, avoid getting lost on light
        // tracks.
        .shadow = .{ .color = Color.rgba(0, 0, 0, 56), .blur = 3, .offset_x = 0, .offset_y = 1 },
    };
}
