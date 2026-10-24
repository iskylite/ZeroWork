//! Canonical renderer values shared by UI and token generators.
const std = @import("std");

pub const Color = packed struct {
    r: u8,
    g: u8,
    b: u8,
    a: u8 = 255,

    pub const TRANSPARENT = Color{ .r = 0, .g = 0, .b = 0, .a = 0 };
    pub const WHITE = Color{ .r = 255, .g = 255, .b = 255, .a = 255 };
    pub const BLACK = Color{ .r = 0, .g = 0, .b = 0, .a = 255 };

    pub fn rgb(r: u8, g: u8, b: u8) Color {
        return .{ .r = r, .g = g, .b = b, .a = 255 };
    }

    pub fn rgba(r: u8, g: u8, b: u8, a: u8) Color {
        return .{ .r = r, .g = g, .b = b, .a = a };
    }

    pub fn hex(value: u24) Color {
        return .{
            .r = @truncate(value >> 16),
            .g = @truncate(value >> 8),
            .b = @truncate(value),
            .a = 255,
        };
    }

    /// Interpolates in premultiplied-alpha space (CSS Color 4 §12.3): a transparent endpoint
    /// contributes no hue, so transparent -> gray fades the gray in instead of passing through
    /// dark translucent gray. Equal alphas reduce to the straight per-channel lerp below.
    pub fn lerp(from: Color, to: Color, t: f32) Color {
        const t_clamped = std.math.clamp(t, 0.0, 1.0);
        if (from.a != to.a) {
            const fa = @as(f32, @floatFromInt(from.a)) / 255.0;
            const ta = @as(f32, @floatFromInt(to.a)) / 255.0;
            const a = fa + (ta - fa) * t_clamped;
            if (a <= 0) return TRANSPARENT;
            const channel = struct {
                fn f(fc: u8, tc: u8, fa_: f32, ta_: f32, a_: f32, k: f32) u8 {
                    const fp = @as(f32, @floatFromInt(fc)) * fa_;
                    const tp = @as(f32, @floatFromInt(tc)) * ta_;
                    return @intFromFloat(std.math.clamp(@round((fp + (tp - fp) * k) / a_), 0.0, 255.0));
                }
            }.f;
            return .{
                .r = channel(from.r, to.r, fa, ta, a, t_clamped),
                .g = channel(from.g, to.g, fa, ta, a, t_clamped),
                .b = channel(from.b, to.b, fa, ta, a, t_clamped),
                .a = @intFromFloat(@round(a * 255.0)),
            };
        }
        return .{
            .r = @intFromFloat(@as(f32, @floatFromInt(from.r)) + (@as(f32, @floatFromInt(to.r)) - @as(f32, @floatFromInt(from.r))) * t_clamped),
            .g = @intFromFloat(@as(f32, @floatFromInt(from.g)) + (@as(f32, @floatFromInt(to.g)) - @as(f32, @floatFromInt(from.g))) * t_clamped),
            .b = @intFromFloat(@as(f32, @floatFromInt(from.b)) + (@as(f32, @floatFromInt(to.b)) - @as(f32, @floatFromInt(from.b))) * t_clamped),
            .a = @intFromFloat(@as(f32, @floatFromInt(from.a)) + (@as(f32, @floatFromInt(to.a)) - @as(f32, @floatFromInt(from.a))) * t_clamped),
        };
    }

    pub fn withAlpha(self: Color, alpha: u8) Color {
        return .{ .r = self.r, .g = self.g, .b = self.b, .a = alpha };
    }

    pub fn eql(a: Color, b: Color) bool {
        return a.r == b.r and a.g == b.g and a.b == b.b and a.a == b.a;
    }
};

pub const Shadow = struct {
    color: Color = Color.rgba(0, 0, 0, 80),
    blur: f32 = 8,
    offset_x: f32 = 0,
    offset_y: f32 = 4,
    /// CSS box-shadow spread: positive expands, negative shrinks shadow rect first then blurs (far
    /// drop common).
    spread: f32 = 0,
};

pub const TypographyPatch = struct {
    font_size: ?f32 = null,
    font_weight: ?u16 = null,
    line_height: ?f32 = null,
};

pub const Category = enum { color, space, radius, font_size, font_weight, line_height, border_width, size, opacity, duration, breakpoint, shadow, typography };

pub fn Value(comptime category: Category) type {
    return switch (category) {
        .color => Color,
        .font_weight => u16,
        .shadow => Shadow,
        .typography => TypographyPatch,
        else => f32,
    };
}

/// Theme mode brightness classification; independent of token names.
pub const ColorScheme = enum { light, dark };
