const css = @import("../../css.zig").css;

pub const section = css(.{ .width = .fill, .gap = .space300 });
pub const sectionTitle = css(.{ .color = .fg_primary, .font_size = .xl, .font_weight = .semibold });
pub const sectionDivider = css(.{ .width = .fill, .height = 1, .background = .separator });
