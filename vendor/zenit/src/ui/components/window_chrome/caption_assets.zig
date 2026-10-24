//! Caption line geometry; compile-time vector assets, no SVG raster loader.
const ir = @import("icon_ir");
pub const win_min = ir.Asset{ .icon_id = 65500, .svg_data = "", .default_width = 10, .default_height = 10, .reps = &.{.{ .size = 10, .view_width = 10, .view_height = 10, .shapes = &.{.{ .stroke_width = 1, .contours = &.{
    .{ .closed = false, .points = &.{ .{ .x = 0, .y = 5.5 }, .{ .x = 10, .y = 5.5 } } },
} }} }} };
pub const win_max = ir.Asset{ .icon_id = 65501, .svg_data = "", .default_width = 10, .default_height = 10, .reps = &.{.{ .size = 10, .view_width = 10, .view_height = 10, .shapes = &.{.{ .stroke_width = 1, .contours = &.{
    .{ .closed = true, .points = &.{ .{ .x = 0.5, .y = 0.5 }, .{ .x = 9.5, .y = 0.5 }, .{ .x = 9.5, .y = 9.5 }, .{ .x = 0.5, .y = 9.5 } } },
} }} }} };
pub const win_restore = ir.Asset{ .icon_id = 65502, .svg_data = "", .default_width = 10, .default_height = 10, .reps = &.{.{ .size = 10, .view_width = 10, .view_height = 10, .shapes = &.{.{ .stroke_width = 1, .contours = &.{
    .{ .closed = false, .points = &.{ .{ .x = 2.5, .y = 0.5 }, .{ .x = 9.5, .y = 0.5 }, .{ .x = 9.5, .y = 7.5 } } },
    .{ .closed = true, .points = &.{ .{ .x = 0.5, .y = 2.5 }, .{ .x = 7.5, .y = 2.5 }, .{ .x = 7.5, .y = 9.5 }, .{ .x = 0.5, .y = 9.5 } } },
} }} }} };
pub const win_close = ir.Asset{ .icon_id = 65503, .svg_data = "", .default_width = 10, .default_height = 10, .reps = &.{.{ .size = 10, .view_width = 10, .view_height = 10, .shapes = &.{.{ .stroke_width = 1, .contours = &.{
    .{ .closed = false, .points = &.{ .{ .x = 0.5, .y = 0.5 }, .{ .x = 9.5, .y = 9.5 } } },
    .{ .closed = false, .points = &.{ .{ .x = 9.5, .y = 0.5 }, .{ .x = 0.5, .y = 9.5 } } },
} }} }} };
pub const adwaita_min = ir.Asset{ .icon_id = 65504, .svg_data = "", .default_width = 8, .default_height = 8, .reps = &.{.{ .size = 8, .view_width = 8, .view_height = 8, .shapes = &.{.{ .stroke_width = 1.5, .contours = &.{
    .{ .closed = false, .points = &.{ .{ .x = 1, .y = 6.5 }, .{ .x = 7, .y = 6.5 } } },
} }} }} };
pub const adwaita_max = ir.Asset{ .icon_id = 65505, .svg_data = "", .default_width = 8, .default_height = 8, .reps = &.{.{ .size = 8, .view_width = 8, .view_height = 8, .shapes = &.{.{ .stroke_width = 1.5, .contours = &.{
    .{ .closed = true, .points = &.{ .{ .x = 1.5, .y = 1.5 }, .{ .x = 6.5, .y = 1.5 }, .{ .x = 6.5, .y = 6.5 }, .{ .x = 1.5, .y = 6.5 } } },
} }} }} };
pub const adwaita_restore = ir.Asset{ .icon_id = 65506, .svg_data = "", .default_width = 8, .default_height = 8, .reps = &.{.{ .size = 8, .view_width = 8, .view_height = 8, .shapes = &.{.{ .stroke_width = 1.5, .contours = &.{
    .{ .closed = false, .points = &.{ .{ .x = 2.5, .y = 0.75 }, .{ .x = 7.25, .y = 0.75 }, .{ .x = 7.25, .y = 5.5 } } },
    .{ .closed = true, .points = &.{ .{ .x = 0.75, .y = 2.5 }, .{ .x = 5.5, .y = 2.5 }, .{ .x = 5.5, .y = 7.25 }, .{ .x = 0.75, .y = 7.25 } } },
} }} }} };
pub const adwaita_close = ir.Asset{ .icon_id = 65507, .svg_data = "", .default_width = 8, .default_height = 8, .reps = &.{.{ .size = 8, .view_width = 8, .view_height = 8, .shapes = &.{.{ .stroke_width = 1.5, .contours = &.{
    .{ .closed = false, .points = &.{ .{ .x = 1, .y = 1 }, .{ .x = 7, .y = 7 } } },
    .{ .closed = false, .points = &.{ .{ .x = 7, .y = 1 }, .{ .x = 1, .y = 7 } } },
} }} }} };
pub const breeze_min = ir.Asset{ .icon_id = 65508, .svg_data = "", .default_width = 8, .default_height = 8, .reps = &.{.{ .size = 8, .view_width = 8, .view_height = 8, .shapes = &.{.{ .stroke_width = 1.3, .contours = &.{
    .{ .closed = false, .points = &.{ .{ .x = 1, .y = 2.5 }, .{ .x = 4, .y = 5.5 }, .{ .x = 7, .y = 2.5 } } },
} }} }} };
pub const breeze_max = ir.Asset{ .icon_id = 65509, .svg_data = "", .default_width = 8, .default_height = 8, .reps = &.{.{ .size = 8, .view_width = 8, .view_height = 8, .shapes = &.{.{ .stroke_width = 1.3, .contours = &.{
    .{ .closed = false, .points = &.{ .{ .x = 1, .y = 5.5 }, .{ .x = 4, .y = 2.5 }, .{ .x = 7, .y = 5.5 } } },
} }} }} };
pub const breeze_restore = ir.Asset{ .icon_id = 65510, .svg_data = "", .default_width = 8, .default_height = 8, .reps = &.{.{ .size = 8, .view_width = 8, .view_height = 8, .shapes = &.{.{ .stroke_width = 1.3, .contours = &.{
    .{ .closed = true, .points = &.{ .{ .x = 4, .y = 1 }, .{ .x = 7, .y = 4 }, .{ .x = 4, .y = 7 }, .{ .x = 1, .y = 4 } } },
} }} }} };
pub const breeze_close = ir.Asset{ .icon_id = 65511, .svg_data = "", .default_width = 8, .default_height = 8, .reps = &.{.{ .size = 8, .view_width = 8, .view_height = 8, .shapes = &.{.{ .stroke_width = 1.3, .contours = &.{
    .{ .closed = false, .points = &.{ .{ .x = 1, .y = 1 }, .{ .x = 7, .y = 7 } } },
    .{ .closed = false, .points = &.{ .{ .x = 7, .y = 1 }, .{ .x = 1, .y = 7 } } },
} }} }} };
