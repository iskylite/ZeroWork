const ir = @import("icon_ir");
const points = [_]ir.Point{ .{ .x = 13, .y = 2 }, .{ .x = 3, .y = 14 }, .{ .x = 11, .y = 14 }, .{ .x = 10, .y = 22 }, .{ .x = 21, .y = 10 }, .{ .x = 13, .y = 10 } };
const contours = [_]ir.Contour{.{ .points = &points, .closed = true }};
const shapes = [_]ir.Shape{.{ .contours = &contours, .fill = false, .stroke_width = 2 }};
const reps = [_]ir.Rep{.{ .size = 24, .view_min_x = 0, .view_min_y = 0, .view_width = 24, .view_height = 24, .shapes = &shapes }};
pub const asset: ir.Asset = .{ .svg_data = "<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"0 0 24 24\"><path d=\"M13 2L3 14H11L10 22L21 10H13Z\" fill=\"none\" stroke=\"currentColor\" stroke-width=\"2\"/></svg>", .default_width = 24, .default_height = 24, .icon_id = 60020, .reps = &reps };
