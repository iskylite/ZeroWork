const std = @import("std");
const gpu = @import("gpu");
const render = @import("render");
const ui = @import("ui");

// Keep logical geometry fixed while varying the physical render target. The
// parent has its own nonzero origin, so parent fades also exercise backdrop
// capture through an opacity surface whose origin differs from the glass.
pub fn run(io: std.Io) !void {
    inline for (.{ 1.0, 1.75, 2.0 }) |scale| {
        inline for (.{ false, true }) |parent_opacity| {
            try runMaterial(io, false, scale, parent_opacity);
            try runMaterial(io, true, scale, parent_opacity);
        }
    }
}

fn runMaterial(io: std.Io, liquid: bool, comptime scale: f32, comptime parent_opacity: bool) !void {
    const side: usize = @intFromFloat(32 * scale);
    const Pixels = [side * side * 4]u8;
    const start: usize = @intFromFloat(8 * scale);
    const end: usize = @intFromFloat(24 * scale);
    const lower_end: usize = @intFromFloat(26 * scale);
    const material = if (liquid) "LIQUID" else "NEUTRAL";
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
    var target = try dq.device.createTexture(a, .{ .size = .{ .width = side, .height = side }, .format = gpu.color_format, .usage = .{ .render_attachment = true, .copy_src = true, .texture_binding = true } });
    defer target.destroy();
    var view = target.binding().createView();
    defer view.destroy();
    var source: Pixels = undefined;
    for (0..side * side) |p| {
        // Unequal upper/lower intensity reveals incorrect main-target capture
        // coordinates when Glass is nested in an opacity surface.
        const white: u8 = if (p / side < side / 2) 255 else 128;
        const v: u8 = if (@as(usize, @intFromFloat(@as(f32, @floatFromInt(p % side)) / (2 * scale))) % 2 == 0) 0 else white;
        source[p * 4 ..][0..4].* = .{ v, v, v, 255 };
    }
    // Stream textures preserve a 1:1 texel mapping; atlas UVs intentionally
    // inset their endpoints and interpolate adjacent stripe pixels.
    const background = try image.texture_store.createStreamTexture(side, side);
    try image.texture_store.updateStreamTexture(background, &source);
    const cx = try ui.Cx.init(a, io);
    defer cx.deinit();
    cx.setWindowMetrics(32, 32, scale);
    const glass = try ui.box(cx, .{ .width = .{ .px = 24 }, .height = .{ .px = 24 } }, .{});
    const ext = try glass.style.ensureExtFallible(cx.allocator);
    ext.glass = .{ .backdrop_blur = 4, .glass_intensity = if (liquid) 1 else 0, .specular_opacity = if (liquid) 0.2 else 0, .refraction_level = if (liquid) 0.7 else 0, .warp_gain = if (liquid) 0.7 else 0 };
    const group = try ui.box(cx, .{ .width = .{ .px = 28 }, .height = .{ .px = 28 }, .padding = ui.Padding.all(2) }, .{glass});
    cx.root = try ui.box(cx, .{ .width = .{ .px = 32 }, .height = .{ .px = 32 }, .padding = ui.Padding.all(2) }, .{group});
    var baseline: Pixels = undefined;
    var full: Pixels = undefined;
    for ([_]f32{ 0, 1, 0.25, 0.5, 0.75, 1, 0.75, 0.5, 0.25, 0 }, 0..) |alpha, frame| {
        (if (parent_opacity) group else glass).setOpacity(alpha);
        _ = cx.render();
        var blur_tokens: usize = 0;
        for (cx.lowerForEncoderPaintTable()) |it| {
            if (it.control_kind == .begin_blur_layer) blur_tokens += 1;
        }
        if (alpha > 0 and blur_tokens == 0) return error.UiGlassNotLowered;
        persistent.beginFrame();
        pool.resetFrame();
        var gpu_encoder = try gpu.Backend.CommandEncoder.init(&dq.queue);
        defer gpu_encoder.deinit();
        var pass = try gpu_encoder.beginRenderPass(.{ .color_attachments = &.{.{ .view = view, .load_op = .clear, .store_op = .store, .clear_value = .TRANSPARENT }} });
        var enc = render.RenderCommandEncoder.initWithImageAndIcon(&sdf, &text, image, icon, &pool, &persistent);
        defer enc.deinit();
        enc.beginFrame(32, 32, scale);
        enc.frame_index = frame + 1;
        enc.gpu_command_encoder = &gpu_encoder;
        enc.main_render_target = target.binding();
        enc.render_pass = &pass;
        const before = gpu.Backend.CommandBuffer.error_count.load(.monotonic);
        try image.addImage(background, 0, 0, 32, 32, 0, 1);
        try enc.encodeDisplay(cx);
        if (enc.render_pass) |rp| {
            try enc.flush(rp);
            rp.end();
        } else return error.MissingGlassRenderPass;
        if (alpha > 0 and (persistent.blur_pipeline_failed or persistent.glass_pipeline_failed or persistent.blur_downsample_pipeline == null or persistent.glass_pipeline == null)) return error.GlassPipelineWasSkipped;
        if (gpu.Backend.CommandBuffer.error_count.load(.monotonic) != before) return error.UiGlassEncodingFailed;
        var command = try gpu_encoder.finish();
        defer command.deinit();
        try command.submitChecked();
        try command.waitChecked(5000);
        var pixels: Pixels = undefined;
        try target.readBgra8(side, side, &pixels, side * 4);
        // Preserve diagnostics even if an assertion fails.
        var rgba = pixels;
        for (0..side * side) |p| std.mem.swap(u8, &rgba[p * 4], &rgba[p * 4 + 2]);
        std.debug.print("UI_GLASS_{s}_SCALE_{d}_PARENT_{d}_FRAME_{d}_RGBA8_HEX={s}\n", .{ material, @as(u32, @intFromFloat(scale * 100)), @intFromBool(parent_opacity), frame, std.fmt.bytesToHex(rgba, .lower) });
        if (frame == 0) {
            baseline = pixels;
            for (1..side - 1) |y| for (1..side - 1) |x| {
                const p = (y * side + x) * 4;
                if (!std.mem.eql(u8, pixels[p..][0..4], source[p..][0..4])) return error.IncorrectGlassBackground;
            };
        }
        if (frame == 1) {
            full = pixels;
            // Contrast reduction must reach both the middle and the bottom.
            // Require the same proportion of mixed physical pixels at each DPI.
            for ([_]usize{ @intFromFloat(12 * scale), @intFromFloat(24 * scale) }) |y| {
                const baseline_contrast: u16 = if (y < side / 2) 255 else 128;
                // A pixel is mixed when it lies strictly inside its row's stripe
                // range (0..baseline): 32/240 of 255, scaled to the 0/128 rows.
                const mixed_low = baseline_contrast * 32 / 255;
                const mixed_high = baseline_contrast * 240 / 255;
                var mixed: usize = 0;
                var low: u8 = 255;
                var high: u8 = 0;
                for (start..end) |x| {
                    const v = pixels[(y * side + x) * 4];
                    low = @min(low, v);
                    high = @max(high, v);
                    if (v > mixed_low and v < mixed_high) mixed += 1;
                }
                std.debug.print("UI Glass {s} row={d} min={d} max={d} mixed={d}\n", .{ material, y, low, high, mixed });
                if (mixed * 4 < (end - start) * 3 or @as(u16, high - low) * 100 > baseline_contrast * 65) return error.GlassBottomNotBlurred;
            }
        }
        // Stable glass must interpolate its full-opacity result over
        // the real main-target background, including within an opacity surface.
        // Blending happens on sRGB-encoded values (gpu.shader_colors_encoded).
        if (frame >= 2) for (start..lower_end) |y| for (start..end) |x| {
            const p = (y * side + x) * 4;
            for (0..3) |c| {
                const expected: i32 = @intFromFloat(@round(@as(f32, @floatFromInt(baseline[p + c])) * (1 - alpha) + @as(f32, @floatFromInt(full[p + c])) * alpha));
                if (@abs(@as(i32, pixels[p + c]) - expected) > 3) {
                    std.debug.print("UI Glass {s} fade mismatch frame={d} alpha={d} ({d},{d}) channel={d} actual={d} expected={d}\n", .{ material, frame, alpha, x, y, c, pixels[p + c], expected });
                    return error.GlassFadeIncorrect;
                }
            }
            if (pixels[p + 3] != 255) return error.GlassFadeAlphaIncorrect;
        };
        if (frame == 5 and !std.mem.eql(u8, &pixels, &full)) return error.UnstableGlassRepeat;
        if (frame == 9 and !std.mem.eql(u8, &pixels, &baseline)) return error.GlassFadeResidual;
        // Glass must not modify the isolated margins of the underlying image.
        for (1..side - 1) |y| for ([_]usize{ 1, side - 2 }) |x| {
            const p = (y * side + x) * 4;
            if (!std.mem.eql(u8, pixels[p..][0..4], baseline[p..][0..4])) return error.GlassEscapedBounds;
        };
    }
    std.debug.print("PASS: actual Cx Glass lowering/main-background capture/Kawase/Glass composite, center and bottom blur, ten frames with {s} glass scale={d} parent_opacity={} CPU interpolation, identical opaque repeat/zero endpoints and isolated margins\n", .{ material, scale, parent_opacity });
}
