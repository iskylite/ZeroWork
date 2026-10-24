const std = @import("std");
const gpu = @import("gpu");
const PathRenderer = @import("path_renderer.zig").PathRenderer;
const Contour = @import("path_tessellator.zig").Contour;

/// GPU readback oracle: every drawable edge must be covered at fractional DPI.
/// The UNORM blend is independently fixed at (32 + 240) / 2 = 136.
pub fn run(allocator: std.mem.Allocator, device: *gpu.Backend.Device, queue: *gpu.Backend.Queue) !void {
    try runFractionalClip(allocator, device, queue);
    var path = try PathRenderer.init(allocator, device);
    defer path.deinit();
    for ([_]u32{ 1900, 1901, 1907 }) |pixels| {
        const logical = @as(f32, @floatFromInt(pixels)) / 1.75;
        var texture = try device.createTexture(allocator, .{
            .size = .{ .width = pixels, .height = pixels },
            .format = .bgra8_unorm,
            .memory = .host_upload,
            .usage = .{ .render_attachment = true, .copy_src = true },
        });
        defer texture.destroy();
        const bytes = try allocator.alloc(u8, @as(usize, pixels) * pixels * 4);
        defer allocator.free(bytes);
        for ([_]u8{ 0, 1, 2, 3 }) |clip_mode| {
            path.beginFrame(logical, logical, 1.75);
            path.setDrawableExtent(texture.size.width, texture.size.height);
            if (clip_mode == 1) path.setRectClip(.{ 0, 0, logical, logical });
            if (clip_mode == 2) path.setRectClip(.{ logical, 0, 0, logical });
            if (clip_mode == 3) path.setRectClip(.{ logical / 2, 0, 0, logical });
            var points = [_]f32{ -2, -2, logical + 2, -2, logical + 2, logical + 2, -2, logical + 2 };
            _ = try path.addFillPath(&.{Contour{ .vertices = &points, .closed = true }}, .{ 240.0 / 255.0, 240.0 / 255.0, 240.0 / 255.0, 0.5 }, 0, 0);
            var encoder = try gpu.Backend.CommandEncoder.init(queue);
            var view = texture.binding().createView();
            defer view.destroy();
            var pass = try encoder.beginRenderPass(.{ .color_attachments = &.{.{
                .view = view,
                .load_op = .clear,
                .store_op = .store,
                .clear_value = .{ .r = 32.0 / 255.0, .g = 32.0 / 255.0, .b = 32.0 / 255.0, .a = 1 },
            }} });
            try path.flush(&pass);
            pass.end();
            var command = try encoder.finish();
            defer command.deinit();
            command.submit();
            command.waitUntilCompleted();
            try texture.readBgra8(pixels, pixels, bytes, pixels * 4);
            for (0..pixels) |i| {
                for ([_]usize{ i, (pixels - 1) * @as(usize, pixels) + i, i * pixels, i * pixels + pixels - 1 }) |index| {
                    for (0..3) |channel| if (bytes[index * 4 + channel] != (if (clip_mode >= 2) @as(u8, 32) else @as(u8, 136))) {
                        std.debug.print("drawable edge pixels={d} clip_mode={d} index={d} actual={d}\n", .{ pixels, clip_mode, index, bytes[index * 4 + channel] });
                        return error.DrawableEdgePixelMismatch;
                    };
                }
            }
        }
    }
}

pub fn runFractionalClip(allocator: std.mem.Allocator, device: *gpu.Backend.Device, queue: *gpu.Backend.Queue) !void {
    var path = try PathRenderer.init(allocator, device);
    defer path.deinit();
    var target = try device.createTexture(allocator, .{
        .size = .{ .width = 32, .height = 32 },
        .format = .bgra8_unorm,
        .memory = .host_upload,
        .usage = .{ .render_attachment = true, .copy_src = true },
    });
    defer target.destroy();
    for ([_][4]f32{ .{ 3.25, 2.25, 7.5, 6.5 }, .{ -1.25, -1.25, 5.5, 5.5 } }, 0..) |clip, mode| {
        path.beginFrame(32.0 / 1.75, 32.0 / 1.75, 1.75);
        path.setDrawableExtent(32, 32);
        path.setRectClip(clip);
        var points = [_]f32{ -2, -2, 40, -2, 40, 40, -2, 40 };
        _ = try path.addFillPath(&.{Contour{ .vertices = &points, .closed = true }}, .{ 240.0 / 255.0, 240.0 / 255.0, 240.0 / 255.0, 0.5 }, 0, 0);
        var encoder = try gpu.Backend.CommandEncoder.init(queue);
        var view = target.binding().createView();
        defer view.destroy();
        var pass = try encoder.beginRenderPass(.{ .color_attachments = &.{.{ .view = view, .load_op = .clear, .store_op = .store, .clear_value = .{ .r = 32.0 / 255.0, .g = 32.0 / 255.0, .b = 32.0 / 255.0, .a = 1 } }} });
        try path.flush(&pass);
        pass.end();
        var command = try encoder.finish();
        defer command.deinit();
        command.submit();
        command.waitUntilCompleted();
        var bytes: [32 * 32 * 4]u8 = undefined;
        try target.readBgra8(32, 32, &bytes, 32 * 4);
        // Independent rational pixel-center oracle: clip 0 is [5.6875,18.8125)
        // x [3.9375,15.3125); clip 1 ends at 7.4375 on both axes.
        for (0..32) |y| for (0..32) |x| {
            const inside = if (mode == 0) x >= 6 and x < 19 and y >= 4 and y < 15 else x < 7 and y < 7;
            const expected: u8 = if (inside) 136 else 32;
            for (0..3) |channel| if (bytes[(y * 32 + x) * 4 + channel] != expected) {
                std.debug.print("fractional clip mode={d} pixel={d},{d} actual={d} expected={d}\n", .{ mode, x, y, bytes[(y * 32 + x) * 4 + channel], expected });
                return error.FractionalClipPixelMismatch;
            };
        };
    }
}
