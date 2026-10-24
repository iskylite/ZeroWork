const std = @import("std");
const d12 = @import("gpu").Backend.native;
const adapter = d12.renderer_resources;
const a = std.heap.page_allocator;
fn expectError(expected: anyerror, result: anytype) !void {
    if (result) |_| return error.ExpectedFailure else |err| if (err != expected) return err;
}
extern fn zenit_d12_test_gate_create(*anyopaque, *anyopaque) *anyopaque;
extern fn zenit_d12_test_gate_signal(*anyopaque) void;
extern fn zenit_d12_test_gate_release(*anyopaque) void;
fn timeoutRetry() !void {
    var device = try d12.Device.init(true);
    defer device.destroy();
    const context = try adapter.Context.init(a, &device);
    var context_live = true;
    defer if (context_live) {
        context.timeout_ms = 5000;
        context.deinit() catch @panic("timeout context cleanup");
    };
    const gate = zenit_d12_test_gate_create(device.raw, context.queue.raw);
    var signaled = false;
    defer {
        if (!signaled) zenit_d12_test_gate_signal(gate);
        if (context_live) context.queue.waitIdle(5000) catch @panic("timeout gate cleanup");
        zenit_d12_test_gate_release(gate);
    }
    var texture = try context.createTexture(a, .{ .size = .{ .width = 2, .height = 2 }, .format = .bgra8_unorm, .memory = .host_upload, .usage = .{ .copy_src = true } });
    var texture_live = true;
    defer if (texture_live) texture.destroy();
    const bytes = [_]u8{ 1, 2, 3, 255, 4, 5, 6, 255, 7, 8, 9, 255, 10, 11, 12, 255 };
    context.timeout_ms = 0;
    // Writes are recorded, not waited on: a blocked GPU must not stall them.
    try texture.writeRegion(0, 0, 0, 2, 2, &bytes, 8);
    if (context.pending_uploads == null) return error.UploadNotRecorded;
    var readback = try context.device.createBuffer(a, .{ .size = 264, .usage = .{ .map_read = true, .copy_dst = true } });
    defer readback.destroy();
    var encoder = try context.device.createCommandEncoder();
    defer encoder.deinit();
    try encoder.copyTextureToBuffer(&texture.inner, .{ .width = 2, .height = 2 }, &readback, 0, 256);
    var command = try encoder.finish();
    defer command.deinit();
    // The recorded write is submitted first, so this readback observes it.
    _ = try context.submitCommands(&.{command});
    if (context.pending_uploads != null) return error.UploadNotFlushed;
    texture.destroy();
    texture_live = false;
    try expectError(error.GpuTimeout, context.deinit());
    zenit_d12_test_gate_signal(gate);
    signaled = true;
    context.timeout_ms = 5000;
    try context.deinit();
    context_live = false;
    const mapped = try readback.getMappedRange(0, 264);
    if (!std.mem.eql(u8, mapped[0..8], bytes[0..8]) or !std.mem.eql(u8, mapped[256..264], bytes[8..16])) return error.TimeoutLostStagingData;
    std.debug.print("PASS: renderer uploads record without waiting on a blocked GPU, precede later submissions, and survive texture destruction and context deinit retry; 16 BGRA bytes verified\n", .{});
}
pub fn run() !void {
    try timeoutRetry();
    var device = try d12.Device.init(true);
    const context = try adapter.Context.init(a, &device);
    device.destroy(); // Context independently owns the native device.
    defer context.deinit() catch @panic("renderer resource context cleanup");
    var texture = try context.createTexture(a, .{ .size = .{ .width = 8, .height = 4 }, .mip_level_count = 3, .format = .bgra8_unorm, .memory = .host_upload, .usage = .{ .texture_binding = true, .copy_src = true } });
    var live = true;
    defer if (live) texture.destroy();
    try expectError(error.ResourcesStillAlive, context.deinit());
    var data: [4 * 40]u8 = @splat(0x55);
    for (0..4) |y| for (0..8) |x| {
        @memcpy(data[y * 40 + x * 4 ..][0..4], &[_]u8{ @as(u8, @intCast(x * 17)), @as(u8, @intCast(y * 41)), 100, 255 });
    };
    try texture.writeRegion(0, 0, 0, 8, 4, &data, 40);
    const patch = [_]u8{ 1, 2, 3, 255, 4, 5, 6, 255, 99, 99, 99, 99, 7, 8, 9, 255, 10, 11, 12, 255, 99, 99, 99, 99 };
    try texture.writeRegion(0, 2, 1, 2, 2, &patch, 12);
    try texture.writeRegion(1, 1, 0, 2, 2, &patch, 12);
    var output: [4 * 36]u8 = @splat(0xa5);
    try texture.readBgra8(8, 4, &output, 36);
    var pixels: [128]u8 = undefined;
    for (0..4) |y| {
        for (0..8) |x| {
            const expected = if (x >= 2 and x < 4 and y >= 1 and y < 3) patch[(y - 1) * 12 + (x - 2) * 4 ..][0..4] else data[y * 40 + x * 4 ..][0..4];
            const pixel = output[y * 36 + x * 4 ..][0..4];
            if (!std.mem.eql(u8, pixel, expected)) return error.IncorrectRendererUpload;
            @memcpy(pixels[(y * 8 + x) * 4 ..][0..4], &[_]u8{ pixel[2], pixel[1], pixel[0], pixel[3] });
        }
        for (output[y * 36 + 32 ..][0..4]) |value| if (value != 0xa5) return error.ReadbackChangedPadding;
    }
    try expectError(error.InvalidTextureData, texture.writeRegion(0, 0, 0, 2, 2, &patch, 4));
    try expectError(error.InvalidTextureData, texture.writeRegion(0, 0, 0, 2, 2, patch[0..10], 8));
    try expectError(error.InvalidTextureRegion, texture.writeRegion(3, 0, 0, 1, 1, &patch, 4));
    try expectError(error.InvalidTextureRegion, texture.writeRegion(0, std.math.maxInt(u32), 0, 1, 1, &patch, 4));
    try expectError(error.InvalidTextureRegion, texture.readBgra8(0, 4, &output, 36));
    try expectError(error.InvalidTextureData, texture.readBgra8(8, 4, &output, 31));
    try expectError(error.InvalidTextureData, texture.readBgra8(8, 4, output[0..10], 32));
    const binding = texture.binding();
    var view = binding.createView();
    defer view.destroy();
    if (!binding.eql(texture.binding())) return error.BindingIdentityChanged;
    texture.destroy();
    live = false;
    try expectError(error.ResourcesStillAlive, context.deinit());
    const mip = d12.TextureRegion{ .mip = 1, .x = 1, .width = 2, .height = 2 };
    const layout = try view.inner.copyLayout(mip, 0);
    var readback = try context.device.createBuffer(a, .{ .size = layout.required_bytes, .usage = .{ .map_read = true, .copy_dst = true } });
    defer readback.destroy();
    var encoder = try context.device.createCommandEncoder();
    defer encoder.deinit();
    try encoder.copyTextureToBuffer(&view.inner, mip, &readback, 0, layout.row_pitch);
    var command = try encoder.finish();
    defer command.deinit();
    _ = try context.submitCommands(&.{command});
    try context.queue.waitIdle(5000);
    const mapped = try readback.getMappedRange(0, readback.size);
    for (0..2) |row| if (!std.mem.eql(u8, mapped[row * layout.row_pitch ..][0..8], patch[row * 12 ..][0..8])) return error.IncorrectOwnedViewMip;
    var atlas = try context.createTexture(a, .{ .size = .{ .width = 7, .height = 3 }, .format = .r8_unorm, .memory = .host_upload, .usage = .{ .texture_binding = true, .copy_src = true } });
    defer atlas.destroy();
    const glyph = [_]u8{ 1, 2, 3, 4, 5, 6 };
    try atlas.writeRegion(0, 1, 1, 3, 2, &glyph, 3);
    var glyph_read = try context.device.createBuffer(a, .{ .size = 259, .usage = .{ .map_read = true, .copy_dst = true } });
    defer glyph_read.destroy();
    var glyph_encoder = try context.device.createCommandEncoder();
    defer glyph_encoder.deinit();
    try glyph_encoder.copyTextureToBuffer(&atlas.inner, .{ .x = 1, .y = 1, .width = 3, .height = 2 }, &glyph_read, 0, 256);
    var glyph_command = try glyph_encoder.finish();
    defer glyph_command.deinit();
    _ = try context.submitCommands(&.{glyph_command});
    try context.queue.waitIdle(5000);
    const glyph_bytes = try glyph_read.getMappedRange(0, 259);
    if (!std.mem.eql(u8, glyph_bytes[0..3], glyph[0..3]) or !std.mem.eql(u8, glyph_bytes[256..259], glyph[3..6])) return error.IncorrectGlyphAtlasUpload;

    try expectError(error.UnsupportedTextureFormat, atlas.readBgra8(1, 1, &output, 4));
    var local = try context.createTexture(a, .{ .size = .{ .width = 2, .height = 2 }, .format = .bgra8_unorm, .usage = .{ .render_attachment = true } });
    defer local.destroy();
    if (binding.eql(local.binding())) return error.DistinctBindingsEqual;
    try expectError(error.TextureNotHostWritable, local.writeRegion(0, 0, 0, 1, 1, &patch, 4));
    std.debug.print("RENDERER_TEXTURE_RGBA8_HEX={s}\nPASS: renderer texture API staged BGRA/R8 uploads, padded rows/readback, mip patch, borrowed binding identity and view ownership after texture/device destruction\n", .{std.fmt.bytesToHex(pixels, .lower)});
}
