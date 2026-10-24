const std = @import("std");
const gpu = @import("gpu");
const render = @import("render");
const ui = @import("ui");
const DisplayItem = std.meta.Child(@typeInfo(@TypeOf(ui.Cx.lowerForEncoderPaintTable)).@"fn".return_type.?);

pub fn run(io: std.Io) !void {
    const a = std.heap.page_allocator;
    var instance = try gpu.Backend.Instance.init(a, .{});
    defer instance.deinit();
    const adapters = try instance.enumerateAdapters();
    defer a.free(adapters);
    defer for (adapters) |*adapter| adapter.deinit();
    var dq = try adapters[0].requestDevice(a, .{});
    defer dq.device.deinit();
    defer dq.queue.deinit();
    var sdf = try render.SdfRenderer.init(a, &dq.device);
    defer sdf.deinit();
    var text = try render.TextRenderer.init(a, &dq.device);
    defer text.deinit();
    const image = try a.create(render.ImageRenderer);
    defer a.destroy(image);
    try image.init(a, &dq.device);
    defer image.deinit();
    const icon = try a.create(render.IconRenderer);
    defer a.destroy(icon);
    try icon.init(a, &dq.device);
    defer icon.deinit();
    var pool: render.OffscreenTexturePool = .{};
    defer pool.deinit();
    var persistent: render.PersistentGpuCache = .{};
    defer persistent.deinit();
    var target = try dq.device.createTexture(a, .{ .size = .{ .width = 16, .height = 8 }, .format = gpu.color_format, .usage = .{ .render_attachment = true, .copy_src = true, .texture_binding = true } });
    defer target.destroy();
    var view = target.binding().createView();
    defer view.destroy();
    const cx = try ui.Cx.init(a, io);
    defer cx.deinit();
    cx.setWindowMetrics(16, 8, 1);
    cx.root = try ui.box(cx, .{ .width = .{ .px = 16 }, .height = .{ .px = 8 }, .background = ui.Color.hex(0x00ff00) }, .{});
    _ = cx.render();
    if (cx.lowerForEncoderPaintTable().len == 0) return error.EmptyUiPaintTable;
    for ([_]f32{ 0, 0.25, 0.5, 0.75, 1, 0.75, 0.5, 0.25, 0 }, 0..) |alpha, frame| {
        persistent.beginFrame();
        pool.resetFrame();
        var gpu_encoder = try gpu.Backend.CommandEncoder.init(&dq.queue);
        defer gpu_encoder.deinit();
        var pass = try gpu_encoder.beginRenderPass(.{ .color_attachments = &.{.{ .view = view, .load_op = .clear, .store_op = .store, .clear_value = .TRANSPARENT }} });
        var enc = render.RenderCommandEncoder.initWithImageAndIcon(&sdf, &text, image, icon, &pool, &persistent);
        defer enc.deinit();
        enc.beginFrame(16, 8, 1);
        enc.frame_index = frame + 1;
        enc.gpu_command_encoder = &gpu_encoder;
        enc.main_render_target = target.binding();
        enc.render_pass = &pass;
        const commands = [_]DisplayItem{
            .{ .kind = .control, .control_kind = .push_clip, .geom = .{ .x = 4, .y = 2, .w = 8, .h = 4 } },
            .{ .kind = .rect, .geom = .{ .w = 16, .h = 8 }, .color = .{ .r = 255, .a = 255 } },
            .{ .kind = .control, .control_kind = .pop_clip },
            .{ .kind = .control, .control_kind = .begin_opacity_layer, .geom = .{ .x = 12, .w = 4, .h = 8 }, .draw_x = 12, .draw_w = 4, .draw_h = 8, .opacity = alpha },
            .{ .kind = .rect, .geom = .{ .x = 12, .w = 4, .h = 8 }, .color = .{ .b = 255, .a = 255 } },
            .{ .kind = .control, .control_kind = .end_opacity_layer },
        };
        const before = gpu.Backend.CommandBuffer.error_count.load(.monotonic);
        const identity_group = [_]DisplayItem{.{ .kind = .control, .control_kind = .begin_opacity_layer, .geom = .{ .x = -2, .y = -2, .w = 20, .h = 12 }, .opacity = 1, .use_draw_transform = true, .draw_transform = .{ 1, 0, 0, 1, -2, -2 } }};
        try enc.encodeCommands(&identity_group);
        if (enc.offscreen_depth != 0) return error.IdentitySurfaceWasNotElided;
        try enc.encodeDisplay(cx);
        try enc.encodeCommands(&commands);
        try enc.encodeCommands(&[_]DisplayItem{.{ .kind = .control, .control_kind = .end_opacity_layer }});
        if (enc.render_pass) |rp| {
            try enc.flush(rp);
            rp.end();
        } else return error.MissingActiveRenderPass;
        if (alpha > 0 and alpha < 1 and pool.count == 0) return error.OpacityLayerWasSkipped;
        if (gpu.Backend.CommandBuffer.error_count.load(.monotonic) != before) return error.DisplayEncodingFailed;
        var command = try gpu_encoder.finish();
        defer command.deinit();
        try command.submitChecked();
        try command.waitChecked(5000);
        var pixels: [16 * 8 * 4]u8 = undefined;
        try target.readBgra8(16, 8, &pixels, 64);
        for (0..8) |y| for (0..16) |x| {
            // Avoid the antialiased clip boundary; both the interior and far exterior matter.
            const inside = x >= 5 and x < 11 and y >= 3 and y < 5;
            // Background outer edges are also antialiased; sample its interior.
            const outside = x >= 1 and x < 3 and y >= 1 and y < 7;
            if (inside or outside) {
                const expected: [4]u8 = if (inside) .{ 0, 0, 255, 255 } else .{ 0, 255, 0, 255 };
                if (!std.mem.eql(u8, pixels[(y * 16 + x) * 4 ..][0..4], &expected)) {
                    std.debug.print("Display clip mismatch ({d},{d}) BGRA={any} expected={any} lowered={d}\n", .{ x, y, pixels[(y * 16 + x) * 4 ..][0..4].*, expected, cx.lowerForEncoderPaintTable().len });
                    return error.IncorrectDisplayClip;
                }
            }
        };
        for (2..6) |y| for (13..15) |x| {
            const pixel = pixels[(y * 16 + x) * 4 ..][0..4];
            if (@abs(@as(i32, pixel[0]) - encoded(alpha)) > 1 or @abs(@as(i32, pixel[1]) - encoded(1 - alpha)) > 1 or pixel[2] != 0 or pixel[3] != 255) {
                std.debug.print("Display opacity mismatch frame={d} alpha={d} ({d},{d}) BGRA={any}\n", .{ frame, alpha, x, y, pixel[0..4].* });
                return error.IncorrectDisplayOpacity;
            }
        };
        for (0..128) |p| std.mem.swap(u8, &pixels[p * 4], &pixels[p * 4 + 2]);
        std.debug.print("DISPLAY_FRAME_{d}_RGBA8_HEX={s}\n", .{ frame, std.fmt.bytesToHex(pixels, .lower) });
        if (frame == 2) {
            std.debug.print("DISPLAY_RGBA8_HEX={s}\nPASS: actual Cx box layout/lowering and production UI DisplayItem through shared RenderCommandEncoder with rectangular clip and real offscreen composite (half-opacity capture)\n", .{std.fmt.bytesToHex(pixels, .lower)});
        }
    }
    std.debug.print("PASS: nine continuous opacity frames 0/.25/.5/.75/1/.75/.5/.25/0, 288 interior/exterior/composite pixels; sRGB-encoded compositing (gpu.shader_colors_encoded, as AppKit) CPU reference tolerance one\n", .{});
}
/// Opacity groups composite in sRGB-encoded space: blue over green at alpha
/// leaves alpha·255 and (1 − alpha)·255 in the two channels.
fn encoded(fraction: f32) i32 {
    return @intFromFloat(@round(fraction * 255));
}
