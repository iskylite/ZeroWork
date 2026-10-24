const std = @import("std");
const d12 = @import("gpu").Backend.native;
const p = d12.renderer_pipeline;
const r = d12.renderer_resources;
const c = d12.renderer_commands;
const a = std.heap.page_allocator;
const Uniforms = extern struct { texel_size: [2]f32, offset_scale: f32 = 1, padding: f32 = 0, valid_uv: [4]f32 };
comptime {
    if (@sizeOf(Uniforms) != 32 or @offsetOf(Uniforms, "valid_uv") != 16) @compileError("Kawase uniform ABI mismatch");
}
// Independent CPU bilinear reference in byte space, including texture clamp.
fn sample(bytes: []const u8, width: usize, height: usize, uv: [2]f64, channel: usize) f64 {
    const x = uv[0] * @as(f64, @floatFromInt(width)) - 0.5;
    const y = uv[1] * @as(f64, @floatFromInt(height)) - 0.5;
    const ix: i32 = @intFromFloat(@floor(x));
    const iy: i32 = @intFromFloat(@floor(y));
    const fx = x - @floor(x);
    const fy = y - @floor(y);
    var result: f64 = 0;
    for (0..2) |dy| for (0..2) |dx| {
        const sx: usize = @intCast(std.math.clamp(ix + @as(i32, @intCast(dx)), 0, @as(i32, @intCast(width)) - 1));
        const sy: usize = @intCast(std.math.clamp(iy + @as(i32, @intCast(dy)), 0, @as(i32, @intCast(height)) - 1));
        result += @as(f64, @floatFromInt(bytes[(sy * width + sx) * 4 + channel])) * (if (dx == 0) 1 - fx else fx) * (if (dy == 0) 1 - fy else fy);
    };
    return result;
}
fn reference(bytes: []const u8, width: usize, height: usize, u: Uniforms, uv_out: [2]f64, up: bool, channel: usize) u8 {
    // blur.metal: valid_uv bounds are texel centers; the destination maps
    // through the corresponding cell edges (lo - texel/2 .. hi + texel/2).
    const uv: [2]f64 = .{
        (u.valid_uv[0] - u.texel_size[0] * 0.5) + uv_out[0] * ((u.valid_uv[2] + u.texel_size[0] * 0.5) - (u.valid_uv[0] - u.texel_size[0] * 0.5)),
        (u.valid_uv[1] - u.texel_size[1] * 0.5) + uv_out[1] * ((u.valid_uv[3] + u.texel_size[1] * 0.5) - (u.valid_uv[1] - u.texel_size[1] * 0.5)),
    };
    const taps = if (up) [_][3]f64{ .{ -2, 0, 1 }, .{ 2, 0, 1 }, .{ 0, -2, 1 }, .{ 0, 2, 1 }, .{ -1, -1, 2 }, .{ 1, -1, 2 }, .{ -1, 1, 2 }, .{ 1, 1, 2 } } else [_][3]f64{ .{ 0, 0, 4 }, .{ -1, -1, 1 }, .{ 1, -1, 1 }, .{ -1, 1, 1 }, .{ 1, 1, 1 }, .{ 0, 0, 0 }, .{ 0, 0, 0 }, .{ 0, 0, 0 } };
    var sum: f64 = 0;
    for (taps) |tap| {
        const hp = if (up) @as(f64, 0.65) else 0.75;
        const point: [2]f64 = .{ std.math.clamp(uv[0] + tap[0] * u.texel_size[0] * hp * u.offset_scale, u.valid_uv[0], u.valid_uv[2]), std.math.clamp(uv[1] + tap[1] * u.texel_size[1] * hp * u.offset_scale, u.valid_uv[1], u.valid_uv[3]) };
        sum += sample(bytes, width, height, point, channel) * tap[2];
    }
    return @intFromFloat(@round(sum / (if (up) @as(f64, 12) else 8)));
}
fn verify(output: []const u8, width: usize, height: usize, source: []const u8, source_w: usize, source_h: usize, uniforms: Uniforms, up: bool, expect_opaque: bool) !void {
    for (0..height) |y| for (0..width) |x| for (0..4) |channel| {
        const expected = reference(source, source_w, source_h, uniforms, .{ (@as(f64, @floatFromInt(x)) + 0.5) / @as(f64, @floatFromInt(width)), (@as(f64, @floatFromInt(y)) + 0.5) / @as(f64, @floatFromInt(height)) }, up, channel);
        const actual = output[(y * width + x) * 4 + channel];
        if (@abs(@as(i32, actual) - @as(i32, expected)) > 2 or (expect_opaque and channel == 3 and actual != 255)) {
            std.debug.print("blur mismatch up={} x={d} y={d} channel={d} actual={d} expected={d}\n", .{ up, x, y, channel, actual, expected });
            return error.IncorrectKawasePixel;
        }
    };
}
fn render(context: *r.Context, pipeline: *const d12.RenderPipeline, source: *const r.Texture, target: *const r.Texture, sampler: *const d12.Sampler, uniforms: Uniforms) !void {
    var queue = c.Queue.init(context);
    defer queue.deinit();
    var encoder = try c.CommandEncoder.init(&queue);
    defer encoder.deinit();
    var view = target.binding().createView();
    defer view.destroy();
    var pass = try encoder.beginRenderPass(.{ .color_attachments = &.{.{ .view = view, .load_op = .clear, .store_op = .store }} });
    pass.setPipeline(pipeline);
    try pass.setFragmentBytesChecked(0, std.mem.asBytes(&uniforms));
    pass.setFragmentTexture(0, source);
    pass.setFragmentSampler(0, sampler);
    try pass.drawChecked(3, 1, 0, 0);
    pass.end();
    var command = try encoder.finish();
    defer command.deinit();
    try command.submitChecked();
    try command.waitChecked(5000);
}
pub fn run() !void {
    var device = try d12.Device.init(true);
    defer device.destroy();
    const context = try r.Context.init(a, &device);
    defer context.deinit() catch @panic("blur context cleanup");
    var module = try p.ShaderModule.initFromSource(&device, @import("render").shader_sources.blur);
    defer module.deinit();
    var vertex = try module.getFunction("kawase_vertex_main");
    defer vertex.deinit();
    var down = try module.getFunction("kawase_downsample");
    defer down.deinit();
    var up = try module.getFunction("kawase_upsample");
    defer up.deinit();
    var down_pipeline = try p.createRenderPipeline(&device, .{ .vertex_function = &vertex, .fragment_function = &down, .color_attachment_formats = &.{.bgra8_unorm} });
    defer down_pipeline.deinit();
    var up_pipeline = try p.createRenderPipeline(&device, .{ .vertex_function = &vertex, .fragment_function = &up, .color_attachment_formats = &.{.bgra8_unorm} });
    defer up_pipeline.deinit();
    var sampler = try device.createSampler(a, .{ .min_filter = .linear, .mag_filter = .linear });
    defer sampler.destroy();
    var source = try context.createTexture(a, .{ .size = .{ .width = 8, .height = 8 }, .format = .bgra8_unorm, .memory = .host_upload, .usage = .{ .texture_binding = true } });
    defer source.destroy();
    var input: [256]u8 = @splat(0);
    for (0..5) |y| for (0..6) |x| {
        @memcpy(input[(y * 8 + x) * 4 ..][0..4], &[_]u8{ if ((x + y) % 2 == 0) 240 else 40, @intCast(y * 40), @intCast(x * 40), 255 });
    };
    try source.writeRegion(0, 0, 0, 8, 8, &input, 32);
    var small = try context.createTexture(a, .{ .size = .{ .width = 4, .height = 3 }, .format = .bgra8_unorm, .usage = .{ .render_attachment = true, .texture_binding = true, .copy_src = true } });
    defer small.destroy();
    var large = try context.createTexture(a, .{ .size = .{ .width = 8, .height = 6 }, .format = .bgra8_unorm, .usage = .{ .render_attachment = true, .copy_src = true } });
    defer large.destroy();
    const padded = Uniforms{ .texel_size = .{ 1.0 / 8.0, 1.0 / 8.0 }, .offset_scale = 1.7, .valid_uv = .{ 0.5 / 8.0, 0.5 / 8.0, 5.5 / 8.0, 4.5 / 8.0 } };
    var full = padded;
    full.valid_uv = .{ 0, 0, 1, 1 };
    var small_pixels: [48]u8 = undefined;
    var output: [192]u8 = undefined;
    try render(context, &down_pipeline, &source, &small, &sampler, full);
    try small.readBgra8(4, 3, &small_pixels, 16);
    try verify(&small_pixels, 4, 3, &input, 8, 8, full, false, false);
    try render(context, &down_pipeline, &source, &small, &sampler, padded);
    try small.readBgra8(4, 3, &small_pixels, 16);
    try verify(&small_pixels, 4, 3, &input, 8, 8, padded, false, true);
    try render(context, &up_pipeline, &source, &large, &sampler, padded);
    try large.readBgra8(8, 6, &output, 32);
    try verify(&output, 8, 6, &input, 8, 8, padded, true, true);
    const chain = Uniforms{ .texel_size = .{ 1.0 / 4.0, 1.0 / 3.0 }, .valid_uv = .{ 0, 0, 1, 1 } };
    try render(context, &up_pipeline, &small, &large, &sampler, chain);
    try large.readBgra8(8, 6, &output, 32);
    try verify(&output, 8, 6, &small_pixels, 4, 3, chain, true, true);
    for (0..48) |i| std.mem.swap(u8, &output[i * 4], &output[i * 4 + 2]);
    std.debug.print("RENDERER_BLUR_RGBA8_HEX={s}\nPASS: production HLSL Kawase blur, downsample/upsample/two-pass chain, 120 CPU-reference pixels (byte tolerance2), valid-UV mapping and opaque padded-edge preservation\n", .{std.fmt.bytesToHex(output, .lower)});
}
