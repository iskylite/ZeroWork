//! Persist legacy names and exact numeric weights without rounding to tiers.
const std = @import("std");
pub const Weight = enum(u16) {
    thin = 100,
    extra_light = 200,
    light = 300,
    regular = 400,
    medium = 500,
    semibold = 600,
    bold = 700,
    extra_bold = 800,
    black = 900,
    _,

    pub fn label(self: Weight) []const u8 {
        return switch (self) {
            .thin => "Thin",
            .extra_light => "Extra Light",
            .light => "Light",
            .regular => "Regular",
            .medium => "Medium",
            .semibold => "Semibold",
            .bold => "Bold",
            .extra_bold => "Extra Bold",
            .black => "Black",
            _ => "自定义字重",
        };
    }
};

pub fn parse(text: []const u8) ?Weight {
    if (std.meta.stringToEnum(Weight, text)) |weight| return weight;
    if (text.len == 0) return null;
    for (text) |byte| if (!std.ascii.isDigit(byte)) return null;
    const value = std.fmt.parseInt(u16, text, 10) catch return null;
    if (value < 1 or value > 1000) return null;
    return @fromBackingInt(value);
}
