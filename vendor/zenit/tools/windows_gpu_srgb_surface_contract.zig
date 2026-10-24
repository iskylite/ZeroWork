const std = @import("std");
const gpu = @import("gpu");
const b = gpu.Backend;
const render = @import("render");
const a = std.heap.page_allocator;
extern fn zenit_d12_test_hidden_window_create() ?*anyopaque;
extern fn zenit_d12_test_hidden_window_destroy(*anyopaque) void;
extern fn zenit_d12_test_texture_allocation_format(*anyopaque) u32;
fn srgbByte(linear: f64) u8 {
    const value = if (linear <= 0.0031308) linear * 12.92 else 1.055 * std.math.pow(f64, linear, 1.0 / 2.4) - 0.055;
    return @intFromFloat(@round(value * 255));
}
/// Shader colors are sRGB-encoded (gpu.shader_colors_encoded): a UNORM target
/// stores them unchanged, an _sRGB view encodes the shader's output again.
fn expectedByte(value: f32, srgb_view: bool) u8 {
    return if (srgb_view) srgbByte(value) else @intFromFloat(@round(value * 255));
}
fn check(pixels: []const u8, color: [4]f32, bgra: bool, srgb_view: bool) !void {
    const expected = [_]u8{ expectedByte(color[if (bgra) 2 else 0], srgb_view), expectedByte(color[1], srgb_view), expectedByte(color[if (bgra) 0 else 2], srgb_view), 255 };
    for (0..pixels.len / 4) |p| for (0..4) |channel| {
        if (@abs(@as(i32, pixels[p * 4 + channel]) - @as(i32, expected[channel])) > 1) return error.IncorrectSrgbSurfacePixel;
    };
}
pub fn run() !void {
    const hwnd = zenit_d12_test_hidden_window_create() orelse return error.WindowCreationFailed;
    defer zenit_d12_test_hidden_window_destroy(hwnd);
    var instance = try b.Instance.init(a, .{});
    defer instance.deinit();
    const adapters = try instance.enumerateAdapters();
    defer a.free(adapters);
    defer for (adapters) |*adapter| adapter.deinit();
    var dq = try adapters[0].requestDevice(a, .{});
    defer dq.device.deinit();
    defer dq.queue.deinit();
    {
        var surface = b.Surface.init(hwnd);
        defer surface.deinit();
        // The production surface format, as App configures it.
        var config = b.SurfaceConfiguration{ .format = gpu.color_format, .width = 8, .height = 4, .present_mode = .immediate };
        try surface.configure(a, &dq.device, config);
        var sdf = try render.SdfRenderer.init(a, &dq.device);
        defer sdf.deinit();
        var sync = b.FrameSync.init(3);
        defer sync.deinit();
        defer sync.drain(3);
        const before = b.CommandBuffer.error_count.load(.monotonic);
        for (0..7) |i| {
            if (i == 3) {
                sync.drain(3);
                config.width = 6;
                try surface.configure(a, &dq.device, config);
            }
            try sync.waitForNextFrame();
            var frame = try surface.acquireTexture(a);
            defer frame.deinit();
            if (frame.texture.format != gpu.color_format or zenit_d12_test_texture_allocation_format(frame.texture.inner.raw) != 87 or frame.texture.size.width != config.width) return error.IncorrectSrgbBackBufferFormat;
            var view = frame.texture.binding().createView();
            defer view.destroy();
            var encoder = try b.CommandEncoder.init(&dq.queue);
            defer encoder.deinit();
            var pass = try encoder.beginRenderPass(.{ .color_attachments = &.{.{ .view = view, .load_op = .clear, .store_op = .store, .clear_value = .BLACK }} });
            const color: [4]f32 = if (i % 2 == 0) .{ 0.18, 0.5, 0.75, 1 } else .{ 0.8, 0.1, 0.03, 1 };
            const w: f32 = @floatFromInt(config.width);
            sdf.beginFrame(w, 4, 1, 0);
            try sdf.addRoundedRect(-2, -2, w + 4, 8, color, @splat(0));
            try sdf.flush(&pass);
            pass.end();
            if (b.CommandBuffer.error_count.load(.monotonic) != before) return error.SharedSurfaceEncodingFailed;
            var command = try encoder.finish();
            defer command.deinit();
            frame.preparePresent(&command);
            sync.signalOnCompletion(&command); // Same register/submit order as App.
            try command.submitChecked();
            try command.waitChecked(5000);
            var pixels: [128]u8 = undefined;
            const length = config.width * 4 * 4;
            try frame.texture.readBgra8(config.width, 4, pixels[0..length], config.width * 4);
            try check(pixels[0..length], color, true, false);
            if (i == 2) {
                for (0..32) |p| std.mem.swap(u8, &pixels[p * 4], &pixels[p * 4 + 2]);
                std.debug.print("SHARED_SURFACE_SRGB_RGBA8_HEX={s}\n", .{std.fmt.bytesToHex(pixels, .lower)});
            }
            try frame.presentAfterSubmitChecked(&command);
        }
    }
    // sRGB views over both UNORM allocation families, through a typed pipeline.
    for ([_]struct { format: gpu.TextureFormat, allocation: u32, bgra: bool }{
        .{ .format = .rgba8_unorm_srgb, .allocation = 28, .bgra = false },
        .{ .format = .bgra8_unorm_srgb, .allocation = 87, .bgra = true },
    }) |case| {
        var surface = b.Surface.init(hwnd);
        defer surface.deinit();
        try surface.configure(a, &dq.device, .{ .format = case.format, .width = 8, .height = 4, .present_mode = .fifo });
        var module = try b.ShaderModule.initFromSource(&dq.device,
            \\// zenit-entry: vertex vertex
            \\// zenit-entry: fragment fragment
            \\cbuffer Color:register(b0,space1){float4 color;}
            \\float4 vertex(uint id:SV_VertexID):SV_Position {return float4(id==0?float2(-1,-1):id==1?float2(3,-1):float2(-1,3),0,1);}
            \\float4 fragment():SV_Target{return color;}
        );
        defer module.deinit();
        var vertex = try module.getFunction("vertex");
        defer vertex.deinit();
        var fragment = try module.getFunction("fragment");
        defer fragment.deinit();
        var pipeline = try b.createRenderPipeline(&dq.device, .{ .vertex_function = &vertex, .fragment_function = &fragment, .color_attachment_formats = &.{case.format} });
        defer pipeline.deinit();
        var frame = try surface.acquireTexture(a);
        defer frame.deinit();
        if (frame.texture.format != case.format or zenit_d12_test_texture_allocation_format(frame.texture.inner.raw) != case.allocation) return error.IncorrectRgbaSrgbAllocation;
        var view = frame.texture.binding().createView();
        defer view.destroy();
        var encoder = try b.CommandEncoder.init(&dq.queue);
        defer encoder.deinit();
        var pass = try encoder.beginRenderPass(.{ .color_attachments = &.{.{ .view = view, .load_op = .clear, .store_op = .store }} });
        const color: [4]f32 = .{ 0.18, 0.5, 0.75, 1 };
        pass.setPipeline(&pipeline);
        try pass.setFragmentBytesChecked(0, std.mem.asBytes(&color));
        try pass.drawChecked(3, 1, 0, 0);
        pass.end();
        var command = try encoder.finish();
        defer command.deinit();
        try command.submitChecked();
        try command.waitChecked(5000);
        const region = b.native.TextureRegion{ .width = 8, .height = 4 };
        const layout = try frame.texture.inner.copyLayout(region, 0);
        var readback = try dq.device.createBuffer(a, .{ .size = layout.required_bytes, .usage = .{ .map_read = true, .copy_dst = true } });
        defer readback.destroy();
        var copy = try dq.device.context.device.createCommandEncoder();
        defer copy.deinit();
        try copy.copyTextureToBuffer(&frame.texture.inner, region, &readback, 0, layout.row_pitch);
        var copy_command = try copy.finish();
        defer copy_command.deinit();
        const copy_serial = try dq.device.context.submitCommands(&.{copy_command});
        try dq.device.context.queue.wait(copy_serial, 5000);
        const mapped = try readback.getMappedRange(0, readback.size);
        for (0..4) |row| try check(mapped[row * layout.row_pitch ..][0..32], color, case.bgra, true);
        try frame.presentAfterSubmitChecked(&command);
    }
    std.debug.print("PASS: production UNORM HWND back buffer with seven actual shared SDF frames (encoded colors stored unchanged) with FrameSync and resize, plus typed draws through sRGB views over BGRA/RGBA UNORM allocations; 256 CPU-reference pixels tolerance1, real immediate/FIFO Present calls; visible presentation/timing not claimed\n", .{});
}
