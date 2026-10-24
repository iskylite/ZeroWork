//! A single background transform in window logical coordinates. Compute once
//! for the window, then clip it for APP/pane viewports; never fit each pane.
const std = @import("std");
const asset = @import("background_asset.zig");

pub const Fit = asset.Fit;
pub const Horizontal = asset.Horizontal;
pub const Vertical = asset.Vertical;

pub const Rect = struct { x: f64 = 0, y: f64 = 0, width: f64, height: f64 };

pub const Source = struct {
    pixel_width: u32,
    pixel_height: u32,
    /// Source image density, independent of the display's Retina scale. E.g.
    /// 400 x 200 pixels at 2 pixels/point has original size 200 x 100 points.
    pixels_per_point: f64 = 1,
};

pub const Request = struct {
    source: Source,
    window: Rect,
    fit: Fit = .fill,
    horizontal: Horizontal = .center,
    vertical: Vertical = .center,
};

pub const Error = error{ InvalidSource, InvalidViewport, InvalidGeometry };

pub const Geometry = struct {
    window: Rect,
    /// The single image rectangle, or one aligned tile when repeats is true.
    /// This origin is also the tile phase; all values remain window-relative.
    image: Rect,
    /// Logical points per source pixel; use identically for all viewports.
    pixels_to_points: f64,
    repeats: bool,

    /// Project only the clip. Image origin, scale, and tiling phase remain the
    /// same even when a pane is moved/resized. A renderer using pane-local
    /// coordinates must translate both image and clip by that pane's origin.
    pub fn forViewport(self: Geometry, viewport: Rect) Error!Projection {
        if (!validRect(viewport)) return error.InvalidViewport;
        return .{
            .clip = intersection(self.window, viewport),
            .image = self.image,
            .pixels_to_points = self.pixels_to_points,
            .repeats = self.repeats,
        };
    }
};

pub const Projection = struct {
    /// Null means the viewport is wholly outside the window.
    clip: ?Rect,
    image: Rect,
    pixels_to_points: f64,
    repeats: bool,
};

pub fn resolve(request: Request) Error!Geometry {
    const source = request.source;
    if (source.pixel_width == 0 or source.pixel_height == 0 or
        !std.math.isFinite(source.pixels_per_point) or source.pixels_per_point <= 0) return error.InvalidSource;
    if (!validRect(request.window)) return error.InvalidViewport;
    const width: f64 = @floatFromInt(source.pixel_width);
    const height: f64 = @floatFromInt(source.pixel_height);
    const natural_width = width / source.pixels_per_point;
    const natural_height = height / source.pixels_per_point;
    if (!positiveFinite(natural_width) or !positiveFinite(natural_height)) return error.InvalidSource;

    // Cover/contain depend on aspect ratio, while Center/Tile preserve source
    // logical size. Do not round to physical pixels or fit the image per pane.
    const scale = switch (request.fit) {
        .fill => @max(request.window.width / width, request.window.height / height),
        .fit => @min(request.window.width / width, request.window.height / height),
        .center, .tile => 1 / source.pixels_per_point,
    };
    const image_width = width * scale;
    const image_height = height * scale;
    if (!positiveFinite(scale) or !positiveFinite(image_width) or !positiveFinite(image_height)) return error.InvalidGeometry;
    const x: f64 = switch (request.horizontal) {
        .left => 0,
        .center => 0.5,
        .right => 1,
    };
    const y: f64 = switch (request.vertical) {
        .top => 0,
        .center => 0.5,
        .bottom => 1,
    };
    const image: Rect = .{
        .x = request.window.x + (request.window.width - image_width) * x,
        .y = request.window.y + (request.window.height - image_height) * y,
        .width = image_width,
        .height = image_height,
    };
    if (!validRect(image)) return error.InvalidGeometry;
    return .{
        .window = request.window,
        .image = image,
        .pixels_to_points = scale,
        .repeats = request.fit == .tile,
    };
}

fn positiveFinite(value: f64) bool {
    return std.math.isFinite(value) and value > 0;
}

fn validRect(rect: Rect) bool {
    return std.math.isFinite(rect.x) and std.math.isFinite(rect.y) and
        positiveFinite(rect.width) and positiveFinite(rect.height) and
        std.math.isFinite(rect.x + rect.width) and std.math.isFinite(rect.y + rect.height);
}

fn intersection(a: Rect, b: Rect) ?Rect {
    const left = @max(a.x, b.x);
    const top = @max(a.y, b.y);
    const right = @min(a.x + a.width, b.x + b.width);
    const bottom = @min(a.y + a.height, b.y + b.height);
    if (right <= left or bottom <= top) return null;
    return .{ .x = left, .y = top, .width = right - left, .height = bottom - top };
}

fn expectRect(expected: Rect, actual: Rect) !void {
    try std.testing.expectApproxEqAbs(expected.x, actual.x, 0.000000001);
    try std.testing.expectApproxEqAbs(expected.y, actual.y, 0.000000001);
    try std.testing.expectApproxEqAbs(expected.width, actual.width, 0.000000001);
    try std.testing.expectApproxEqAbs(expected.height, actual.height, 0.000000001);
}

test "background geometry wide and tall cover contain original size and tile" {
    const Case = struct { source: Source, fit: Fit, image: Rect, scale: f64 };
    const wide: Source = .{ .pixel_width = 400, .pixel_height = 200, .pixels_per_point = 2 };
    const tall: Source = .{ .pixel_width = 200, .pixel_height = 400, .pixels_per_point = 2 };
    const window: Rect = .{ .x = 10, .y = 20, .width = 300, .height = 300 };
    for ([_]Case{
        .{ .source = wide, .fit = .fill, .image = .{ .x = -140, .y = 20, .width = 600, .height = 300 }, .scale = 1.5 },
        .{ .source = wide, .fit = .fit, .image = .{ .x = 10, .y = 95, .width = 300, .height = 150 }, .scale = 0.75 },
        .{ .source = wide, .fit = .center, .image = .{ .x = 60, .y = 120, .width = 200, .height = 100 }, .scale = 0.5 },
        .{ .source = wide, .fit = .tile, .image = .{ .x = 60, .y = 120, .width = 200, .height = 100 }, .scale = 0.5 },
        .{ .source = tall, .fit = .fill, .image = .{ .x = 10, .y = -130, .width = 300, .height = 600 }, .scale = 1.5 },
        .{ .source = tall, .fit = .fit, .image = .{ .x = 85, .y = 20, .width = 150, .height = 300 }, .scale = 0.75 },
        .{ .source = tall, .fit = .center, .image = .{ .x = 110, .y = 70, .width = 100, .height = 200 }, .scale = 0.5 },
        .{ .source = tall, .fit = .tile, .image = .{ .x = 110, .y = 70, .width = 100, .height = 200 }, .scale = 0.5 },
    }) |case| {
        const geometry = try resolve(.{ .source = case.source, .window = window, .fit = case.fit });
        try expectRect(case.image, geometry.image);
        try std.testing.expectEqual(case.scale, geometry.pixels_to_points);
        try std.testing.expectEqual(case.fit == .tile, geometry.repeats);
    }
}

test "background geometry nine alignments position cropping gaps and tile phase independently" {
    const Case = struct { fit: Fit, xs: [3]f64, ys: [3]f64 };
    const horizontal = [_]Horizontal{ .left, .center, .right };
    const vertical = [_]Vertical{ .top, .center, .bottom };
    for ([_]Case{
        .{ .fit = .fill, .xs = .{ 31, 1, -29 }, .ys = .{ 47, 47, 47 } },
        .{ .fit = .fit, .xs = .{ 31, 31, 31 }, .ys = .{ 47, 62, 77 } },
        .{ .fit = .center, .xs = .{ 31, 61, 91 }, .ys = .{ 47, 77, 107 } },
        .{ .fit = .tile, .xs = .{ 31, 61, 91 }, .ys = .{ 47, 77, 107 } },
    }) |case| {
        for (horizontal, 0..) |x, xi| {
            for (vertical, 0..) |y, yi| {
                const geometry = try resolve(.{
                    .source = .{ .pixel_width = 40, .pixel_height = 20 },
                    .window = .{ .x = 31, .y = 47, .width = 100, .height = 80 },
                    .fit = case.fit,
                    .horizontal = x,
                    .vertical = y,
                });
                try std.testing.expectEqual(case.xs[xi], geometry.image.x);
                try std.testing.expectEqual(case.ys[yi], geometry.image.y);
            }
        }
    }
}

test "background geometry panes share the window transform and only intersect clipping" {
    const window: Rect = .{ .x = 10, .y = 20, .width = 900, .height = 600 };
    for ([_]Fit{ .fill, .fit, .center, .tile }) |fit| {
        const geometry = try resolve(.{
            .source = .{ .pixel_width = 240, .pixel_height = 160, .pixels_per_point = 2 },
            .window = window,
            .fit = fit,
            .horizontal = .right,
            .vertical = .bottom,
        });
        const app = try geometry.forViewport(window);
        const left = try geometry.forViewport(.{ .x = 10, .y = 80, .width = 400, .height = 540 });
        const right = try geometry.forViewport(.{ .x = 410, .y = 80, .width = 500, .height = 540 });
        for ([_]Projection{ app, left, right }) |pane| {
            try expectRect(geometry.image, pane.image);
            try std.testing.expectEqual(geometry.pixels_to_points, pane.pixels_to_points);
            try std.testing.expectEqual(geometry.repeats, pane.repeats);
        }
        try expectRect(window, app.clip.?);
        try expectRect(.{ .x = 10, .y = 80, .width = 400, .height = 540 }, left.clip.?);
        try expectRect(.{ .x = 410, .y = 80, .width = 500, .height = 540 }, right.clip.?);
        const partial = try geometry.forViewport(.{ .x = -50, .y = 100, .width = 100, .height = 100 });
        try expectRect(.{ .x = 10, .y = 100, .width = 40, .height = 100 }, partial.clip.?);
        try std.testing.expect((try geometry.forViewport(.{ .x = 910, .y = 20, .width = 50, .height = 50 })).clip == null);
        if (fit == .tile) try expectRect(.{ .x = 790, .y = 540, .width = 120, .height = 80 }, right.image);
    }
}

test "background geometry rejects invalid and nonfinite dimensions density and derived overflow" {
    const source: Source = .{ .pixel_width = 200, .pixel_height = 100 };
    const window: Rect = .{ .width = 300, .height = 200 };
    try std.testing.expectError(error.InvalidSource, resolve(.{ .source = .{ .pixel_width = 0, .pixel_height = 100 }, .window = window }));
    for ([_]f64{ 0, -1, std.math.nan(f64), std.math.inf(f64), 1e-308 }) |density| {
        try std.testing.expectError(error.InvalidSource, resolve(.{ .source = .{ .pixel_width = 200, .pixel_height = 100, .pixels_per_point = density }, .window = window }));
    }
    for ([_]Rect{
        .{ .width = 0, .height = 100 },
        .{ .width = 100, .height = -1 },
        .{ .width = std.math.nan(f64), .height = 100 },
        .{ .width = 100, .height = std.math.inf(f64) },
        .{ .x = std.math.inf(f64), .width = 100, .height = 100 },
        .{ .x = 1e308, .width = 1e308, .height = 100 },
    }) |invalid| {
        try std.testing.expectError(error.InvalidViewport, resolve(.{ .source = source, .window = invalid }));
    }
    try std.testing.expectError(error.InvalidGeometry, resolve(.{ .source = .{ .pixel_width = 2, .pixel_height = 1 }, .window = .{ .width = 1, .height = 1e308 } }));
    const geometry = try resolve(.{ .source = source, .window = window });
    try std.testing.expectError(error.InvalidViewport, geometry.forViewport(.{ .width = std.math.nan(f64), .height = 10 }));
}
