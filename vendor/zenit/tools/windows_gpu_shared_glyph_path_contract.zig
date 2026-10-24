const std = @import("std");
const gpu = @import("gpu");
const b = gpu.Backend;
const render = @import("render");
const text = @import("text");
const ir = @import("icon_ir");
const a = std.heap.page_allocator;
fn finish(encoder: *b.CommandEncoder, target: *b.Texture, pixels: []u8, before: u64) !void {
    if (b.CommandBuffer.error_count.load(.monotonic) != before) return error.SharedEncodingFailed;
    var command = try encoder.finish();
    defer command.deinit();
    try command.submitChecked();
    try command.waitChecked(5000);
    try target.readBgra8(64, 32, pixels, 256);
}
fn coloredRects(pixels: []const u8) !void {
    for (6..10) |y| for ([_]usize{ 6, 7, 22, 23 }) |x| {
        const expected: [4]u8 = if (x < 16) .{ 0, 0, 255, 255 } else .{ 0, 255, 0, 255 };
        if (!std.mem.eql(u8, pixels[(y * 64 + x) * 4 ..][0..4], &expected)) return error.IncorrectSharedPathIconPixel;
    };
    if (!std.mem.eql(u8, pixels[0..4], &.{ 0, 0, 0, 0 })) return error.IncorrectOutsideCoverage;
}
pub fn run(io: std.Io) !void {
    var instance = try b.Instance.init(a, .{});
    defer instance.deinit();
    const adapters = try instance.enumerateAdapters();
    defer a.free(adapters);
    defer for (adapters) |*adapter| adapter.deinit();
    var dq = try adapters[0].requestDevice(a, .{});
    defer dq.device.deinit();
    defer dq.queue.deinit();
    var target = try dq.device.createTexture(a, .{ .size = .{ .width = 64, .height = 32 }, .format = gpu.color_format, .usage = .{ .render_attachment = true, .copy_src = true } });
    defer target.destroy();
    var view = target.binding().createView();
    defer view.destroy();
    var pixels: [8192]u8 = undefined;
    const before = b.CommandBuffer.error_count.load(.monotonic);
    {
        var path = try render.PathRenderer.init(a, &dq.device);
        defer path.deinit();
        path.beginFrame(64, 32, 1);
        var points = [_]f32{ 4, 4, 12, 4, 12, 12, 4, 12 };
        const contours = [_]render.Contour{.{ .vertices = &points, .closed = true }};
        var encoder = try b.CommandEncoder.init(&dq.queue);
        defer encoder.deinit();
        var pass = try encoder.beginRenderPass(.{ .color_attachments = &.{.{ .view = view, .load_op = .clear, .store_op = .store, .clear_value = .TRANSPARENT }} });
        if (try path.addFillPath(&contours, .{ 1, 0, 0, 1 }, 0, 0) == null) return error.NoPathMesh;
        try path.flush(&pass);
        if (try path.addFillPath(&contours, .{ 0, 1, 0, 1 }, 16, 0) == null) return error.NoSecondPathMesh;
        try path.flush(&pass);
        pass.end();
        try finish(&encoder, &target, &pixels, before);
        try coloredRects(&pixels);
    }
    {
        const icon = try a.create(render.IconRenderer);
        defer a.destroy(icon);
        try icon.init(a, &dq.device);
        defer icon.deinit();
        const points = [_]ir.Point{ .{ .x = 0, .y = 0 }, .{ .x = 24, .y = 0 }, .{ .x = 24, .y = 24 }, .{ .x = 0, .y = 24 } };
        const contours = [_]ir.Contour{.{ .points = &points, .closed = true }};
        const shapes = [_]ir.Shape{.{ .contours = &contours, .fill = true }};
        const rep = ir.Rep{ .size = 24, .shapes = &shapes };
        icon.beginFrame(64, 32, 1);
        var encoder = try b.CommandEncoder.init(&dq.queue);
        defer encoder.deinit();
        var pass = try encoder.beginRenderPass(.{ .color_attachments = &.{.{ .view = view, .load_op = .clear, .store_op = .store, .clear_value = .TRANSPARENT }} });
        try icon.addIcon(123, rep, 4, 4, 8, 8, .{ 1, 0, 0, 1 }, 0, 1, 0, true);
        try icon.flush(&pass);
        try icon.addIcon(123, rep, 20, 4, 8, 8, .{ 0, 1, 0, 1 }, 0, 1, 0, true);
        try icon.flush(&pass);
        pass.end();
        try finish(&encoder, &target, &pixels, before);
        try coloredRects(&pixels);
    }
    {
        var fonts = try text.FontSystem.init(a, io);
        defer fonts.deinit();
        fonts.setDefaultLocale("zh-CN");
        const font = try fonts.findFont(.{ .family = "Microsoft YaHei UI", .size = 16 });
        var tr = try render.TextRenderer.init(a, &dq.device);
        defer tr.deinit();
        for ([_][]const u8{ "A", "中" }) |content| {
            tr.beginFrame(64, 32, 1);
            var encoder = try b.CommandEncoder.init(&dq.queue);
            defer encoder.deinit();
            var pass = try encoder.beginRenderPass(.{ .color_attachments = &.{.{ .view = view, .load_op = .clear, .store_op = .store, .clear_value = .TRANSPARENT }} });
            try tr.drawTextWithOptions(content, 4, 24, font, .WHITE, 16, false, null, false, true, 0);
            if (tr.getPendingInstanceCount() == 0) return error.NoSharedGlyphInstances;
            try tr.flush(&pass);
            try tr.drawTextWithOptions(content, 28, 24, font, .WHITE, 16, false, null, false, true, 0);
            try tr.flush(&pass);
            pass.end();
            try finish(&encoder, &target, &pixels, before);
            var visible: usize = 0;
            var partial: usize = 0;
            for (0..32) |y| for (0..24) |x| {
                const left = pixels[(y * 64 + x) * 4 ..][0..4];
                const right = pixels[(y * 64 + x + 24) * 4 ..][0..4];
                if (!std.mem.eql(u8, left, right)) return error.IncorrectTranslatedSharedGlyph;
                if (left[3] != 0) {
                    visible += 1;
                    if (left[3] < 255) partial += 1;
                    if (left[0] != left[1] or left[1] != left[2]) return error.IncorrectWhiteGlyphChannels;
                } else if (!std.mem.eql(u8, left, &.{ 0, 0, 0, 0 })) return error.IncorrectTransparentGlyphPixel;
            };
            if (visible < 10 or partial == 0 or tr.getAtlasCacheSize() == 0 or tr.getPendingInstanceCount() != 0) return error.IncorrectSharedGlyphCoverage;
            for (0..64) |x| if (pixels[x * 4 + 3] != 0 or pixels[(31 * 64 + x) * 4 + 3] != 0) return error.VerticallyClippedSharedGlyph;
            for (0..32) |y| {
                for ([_]usize{ 0, 23, 24, 47 }) |x| if (pixels[(y * 64 + x) * 4 + 3] != 0) return error.HorizontallyClippedSharedGlyph;
                for (48..64) |x| if (pixels[(y * 64 + x) * 4 + 3] != 0) return error.UnexpectedSharedGlyphOutsideRegion;
            }
        }
        const selected = try fonts.findFont(.{ .family = "Consolas", .size = 24 });
        var ranges = try text.FontRanges.init(a, "A", &.{.{ .font = selected, .start = 0, .length = 1, .size = 24 }});
        defer ranges.deinit();
        var reference: [8192]u8 = undefined;
        for (0..3) |mode| {
            tr.beginFrame(64, 32, 1);
            var encoder = try b.CommandEncoder.init(&dq.queue);
            defer encoder.deinit();
            var pass = try encoder.beginRenderPass(.{ .color_attachments = &.{.{ .view = view, .load_op = .clear, .store_op = .store, .clear_value = .TRANSPARENT }} });
            tr.active_font_ranges = if (mode > 0) &ranges else null;
            defer tr.active_font_ranges = null;
            const source = if (mode == 0) selected else font;
            const size: f32 = if (mode == 0) 24 else 16;
            if (mode == 2) {
                try tr.drawTextWithSpans("A", 4, 26, source, .WHITE, size, false, null, true, false, 0, &.{.{ .start = 0, .end = 1, .color = .{ .r = 1, .g = 0, .b = 0, .a = 1 } }});
            } else {
                try tr.drawTextWithOptions("A", 4, 26, source, .{ .r = 1, .g = 0, .b = 0, .a = 1 }, size, false, null, true, false, 0);
            }
            try tr.flush(&pass);
            pass.end();
            try finish(&encoder, &target, &pixels, before);
            if (mode == 0) {
                reference = pixels;
            } else {
                var ink: usize = 0;
                for (pixels, reference) |actual, expected| {
                    if (@abs(@as(i32, actual) - expected) > 1) {
                        std.debug.print("font range mode={d} channel actual={d} expected={d}\n", .{ mode, actual, expected });
                        return error.ExplicitFontRangeRasterMismatch;
                    }
                    ink += @intFromBool(actual > 0);
                }
                if (ink < 20) return error.ExplicitFontRangeMissingInk;
            }
        }
        std.debug.print("PASS: explicit 24px font range drawn from 16px primary matches direct selected-font pixels, plain and color-span paths\n", .{});
        for (0..2048) |p| std.mem.swap(u8, &pixels[p * 4], &pixels[p * 4 + 2]);
        std.debug.print("SHARED_TEXT_RGBA8_HEX={s}\n", .{std.fmt.bytesToHex(pixels, .lower)});
    }
    std.debug.print("PASS: actual shared Path triangulation/two flushes, IconIR mask rasterization/cache/upload/two flushes (32 exact interior pixels), DirectWrite Latin/CJK shaping/atlas upload/two text flushes, 1536 exact translated glyph pixel pairs and visible partial-alpha checks on sRGB target\n", .{});
}
