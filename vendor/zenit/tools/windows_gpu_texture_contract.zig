const std = @import("std");
const gpu = @import("gpu");
const d12 = @import("gpu").Backend.native;
extern fn zenit_d12_test_gate_create(*anyopaque, *anyopaque) *anyopaque;
extern fn zenit_d12_test_gate_signal(*anyopaque) void;
extern fn zenit_d12_test_gate_release(*anyopaque) void;
extern fn zenit_d12_test_debug_check(*anyopaque) void;
var submissions: u64 = 0;
var verified_bytes: u64 = 0;
fn expectError(expected: anyerror, result: anytype) !void {
    if (result) |_| return error.ExpectedFailure else |actual| if (actual != expected) return actual;
}
fn pixelBytes(format: gpu.TextureFormat) ?u32 {
    return switch (format) {
        .r8_unorm, .r8_snorm, .r8_uint, .r8_sint => 1,
        .r16_uint, .r16_sint, .r16_float, .rg8_unorm, .rg8_snorm, .rg8_uint, .rg8_sint => 2,
        .r32_uint, .r32_sint, .r32_float, .rg16_uint, .rg16_sint, .rg16_float, .rgba8_unorm, .rgba8_unorm_srgb, .rgba8_snorm, .rgba8_uint, .rgba8_sint, .bgra8_unorm, .bgra8_unorm_srgb, .rgb10a2_unorm => 4,
        .rg32_uint, .rg32_sint, .rg32_float, .rgba16_uint, .rgba16_sint, .rgba16_float => 8,
        .rgba32_uint, .rgba32_sint, .rgba32_float => 16,
        else => null,
    };
}
fn bpp(format: gpu.TextureFormat) u32 {
    return pixelBytes(format).?;
}
fn pattern(mip: u32, layer: u32, x: u32, y: u32, z: u32, channel: u32, patched: bool) u8 {
    return @truncate(mip * 19 + layer * 47 + x * 3 + y * 11 + z * 29 + channel * 7 + @as(u32, if (patched) 133 else 5));
}
fn patchRegion(region: d12.TextureRegion, dimension: gpu.TextureDimension) ?d12.TextureRegion {
    if (region.width < 8 or (dimension != .@"1d" and region.height < 4) or (dimension == .@"3d" and region.depth < 3)) return null;
    return .{ .mip = region.mip, .layer = region.layer, .x = 3, .y = if (dimension == .@"1d") 0 else 1, .z = if (dimension == .@"3d") 1 else 0, .width = 5, .height = if (dimension == .@"1d") 1 else 3, .depth = if (dimension == .@"3d") 2 else 1 };
}
fn fill(bytes: []u8, layout: d12.TextureCopyLayout, region: d12.TextureRegion, pixel_bytes: u32, patched: bool) void {
    @memset(bytes, 0xa5);
    for (0..region.depth) |z| for (0..region.height) |y| for (0..region.width) |x| for (0..pixel_bytes) |c| {
        const index = layout.offset + (z * region.height + y) * layout.row_pitch + x * pixel_bytes + c;
        bytes[@intCast(index)] = pattern(region.mip, region.layer, @intCast(x + region.x), @intCast(y + region.y), @intCast(z + region.z), @intCast(c), patched);
    };
}
fn verify(bytes: []const u8, layout: d12.TextureCopyLayout, region: d12.TextureRegion, pixel_bytes: u32, patch: ?d12.TextureRegion) !void {
    for (0..region.depth) |z| for (0..region.height) |y| for (0..region.width) |x| for (0..pixel_bytes) |c| {
        const patched = if (patch) |p| x >= p.x and x < p.x + p.width and y >= p.y and y < p.y + p.height and z >= p.z and z < p.z + p.depth else false;
        const index = layout.offset + (z * region.height + y) * layout.row_pitch + x * pixel_bytes + c;
        if (bytes[@intCast(index)] != pattern(region.mip, region.layer, @intCast(x), @intCast(y), @intCast(z), @intCast(c), patched)) return error.TexturePixelMismatch;
    };
    verified_bytes += @as(u64, region.width) * region.height * region.depth * pixel_bytes;
}
fn layoutWithExtraPitch(texture: *d12.Texture, region: d12.TextureRegion) !d12.TextureCopyLayout {
    var layout = try texture.copyLayout(region, 512);
    if (layout.offset != 512 or layout.row_pitch % 256 != 0 or layout.row_bytes != region.width * bpp(texture.format)) return error.IncorrectCopyFootprint;
    layout.row_pitch += 256;
    layout.required_bytes = layout.offset + @as(u64, layout.row_pitch) * (@as(u64, region.height) * region.depth - 1) + layout.row_bytes;
    return layout;
}
fn roundTrip(device: *d12.Device, queue: *d12.Queue, format: gpu.TextureFormat, dimension: gpu.TextureDimension) !void {
    var texture = try device.createTexture(std.heap.page_allocator, .{ .size = switch (dimension) {
        .@"1d" => .{ .width = 17, .height = 1, .depth = 2 },
        .@"2d" => .{ .width = 17, .height = 9, .depth = 2 },
        .@"3d" => .{ .width = 11, .height = 7, .depth = 5 },
    }, .dimension = dimension, .mip_level_count = if (dimension == .@"3d") 4 else 5, .format = format, .usage = .{ .copy_src = true, .copy_dst = true, .texture_binding = true } });
    defer texture.destroy();
    const layers: u32 = if (dimension == .@"3d") 1 else 2;
    for (0..layers) |layer| for (0..texture.mip_level_count) |mip| {
        const region = try texture.fullRegion(@intCast(mip), @intCast(layer));
        const layout = try layoutWithExtraPitch(&texture, region);
        var upload = try device.createBuffer(std.heap.page_allocator, .{ .size = layout.required_bytes, .usage = .{ .map_write = true, .copy_src = true } });
        defer upload.destroy();
        fill(try upload.getMappedRange(0, upload.size), layout, region, bpp(format), false);
        var encoder = try device.createCommandEncoder();
        defer encoder.deinit();
        try encoder.copyBufferToTexture(&upload, layout.offset, layout.row_pitch, &texture, region);
        if (patchRegion(region, dimension)) |patch| {
            const patch_layout = try layoutWithExtraPitch(&texture, patch);
            var patch_upload = try device.createBuffer(std.heap.page_allocator, .{ .size = patch_layout.required_bytes, .usage = .{ .map_write = true, .copy_src = true } });
            defer patch_upload.destroy();
            fill(try patch_upload.getMappedRange(0, patch_upload.size), patch_layout, patch, bpp(format), true);
            try encoder.copyBufferToTexture(&patch_upload, patch_layout.offset, patch_layout.row_pitch, &texture, patch);
        }
        var command = try encoder.finish();
        defer command.deinit();
        const serial = try queue.submit(&.{command});
        try queue.wait(serial, 5000);
        submissions += 1;
    };
    // Verify every subresource after all updates. Upload/readback using the same
    // wrong layer or mip would fail this independent later revisit.
    for (0..layers) |layer| for (0..texture.mip_level_count) |mip| {
        const region = try texture.fullRegion(@intCast(mip), @intCast(layer));
        const layout = try layoutWithExtraPitch(&texture, region);
        var readback = try device.createBuffer(std.heap.page_allocator, .{ .size = layout.required_bytes, .usage = .{ .map_read = true, .copy_dst = true } });
        defer readback.destroy();
        var encoder = try device.createCommandEncoder();
        defer encoder.deinit();
        try encoder.copyTextureToBuffer(&texture, region, &readback, layout.offset, layout.row_pitch);
        var command = try encoder.finish();
        defer command.deinit();
        const serial = try queue.submit(&.{command});
        try queue.wait(serial, 5000);
        submissions += 1;
        try verify(try readback.getMappedRange(0, readback.size), layout, region, bpp(format), patchRegion(region, dimension));
    };
    std.debug.print("PASS: texture {s} {s}, all mips/layers, padded rows, 512-byte offset and partial updates\n", .{ @tagName(format), @tagName(dimension) });
}
fn validation(device: *d12.Device) !void {
    try expectError(error.InvalidTextureDescriptor, device.createTexture(std.heap.page_allocator, .{ .size = .{ .width = 4, .height = 2 }, .dimension = .@"1d", .format = .bgra8_unorm, .usage = .{ .copy_dst = true } }));
    try expectError(error.InvalidTextureDescriptor, device.createTexture(std.heap.page_allocator, .{ .size = .{ .width = 4, .height = 4 }, .format = .bgra8_unorm, .usage = .{} }));
    try expectError(error.InvalidTextureDescriptor, device.createTexture(std.heap.page_allocator, .{ .size = .{ .width = 4, .height = 4 }, .format = .bgra8_unorm, .usage = @bitCast(@as(u32, 1 << 31)) }));
    try expectError(error.UnsupportedViewFormat, device.createTexture(std.heap.page_allocator, .{ .size = .{ .width = 4, .height = 4 }, .format = .bgra8_unorm, .view_formats = &.{.rgba8_unorm}, .usage = .{ .copy_dst = true } }));
    try expectError(error.InvalidTextureDescriptor, device.createTexture(std.heap.page_allocator, .{ .size = .{ .width = 0, .height = 4 }, .format = .bgra8_unorm, .usage = .{ .copy_dst = true } }));
    try expectError(error.InvalidTextureDescriptor, device.createTexture(std.heap.page_allocator, .{ .size = .{ .width = 4, .height = 4 }, .mip_level_count = 4, .format = .bgra8_unorm, .usage = .{ .copy_dst = true } }));
    try expectError(error.UnsupportedSampleCount, device.createTexture(std.heap.page_allocator, .{ .size = .{ .width = 4, .height = 4 }, .sample_count = 3, .format = .bgra8_unorm, .usage = .{ .copy_dst = true } }));
    try expectError(error.UnsupportedTextureMemory, device.createTexture(std.heap.page_allocator, .{ .size = .{ .width = 4, .height = 4 }, .memory = .host_upload, .format = .bgra8_unorm, .usage = .{ .copy_dst = true } }));
    try expectError(error.UnsupportedTextureFormat, device.createTexture(std.heap.page_allocator, .{ .size = .{ .width = 4, .height = 4 }, .format = .bc1_rgba_unorm, .usage = .{ .copy_dst = true } }));
    var texture = try device.createTexture(std.heap.page_allocator, .{ .size = .{ .width = 4, .height = 4 }, .format = .bgra8_unorm, .usage = .{ .copy_src = true, .copy_dst = true } });
    defer texture.destroy();
    var input = try device.createBuffer(std.heap.page_allocator, .{ .size = 1024, .usage = .{ .map_write = true, .copy_src = true } });
    defer input.destroy();
    var output = try device.createBuffer(std.heap.page_allocator, .{ .size = 1024, .usage = .{ .map_read = true, .copy_dst = true } });
    defer output.destroy();
    var encoder = try device.createCommandEncoder();
    defer encoder.deinit();
    const region = try texture.fullRegion(0, 0);
    var foreign = try d12.Device.init(true);
    defer foreign.destroy();
    var foreign_texture = try foreign.createTexture(std.heap.page_allocator, .{ .size = .{ .width = 4, .height = 4 }, .format = .bgra8_unorm, .usage = .{ .copy_src = true, .copy_dst = true } });
    defer foreign_texture.destroy();
    try expectError(error.InvalidTextureCopy, encoder.copyBufferToTexture(&input, 0, 256, &foreign_texture, region));
    try expectError(error.InvalidTextureCopy, encoder.copyTextureToBuffer(&foreign_texture, region, &output, 0, 256));
    var dst_only = try device.createTexture(std.heap.page_allocator, .{ .size = .{ .width = 4, .height = 4 }, .format = .bgra8_unorm, .usage = .{ .copy_dst = true } });
    defer dst_only.destroy();
    try expectError(error.InvalidTextureCopy, encoder.copyTextureToBuffer(&dst_only, region, &output, 0, 256));
    var src_only = try device.createTexture(std.heap.page_allocator, .{ .size = .{ .width = 4, .height = 4 }, .format = .bgra8_unorm, .usage = .{ .copy_src = true } });
    defer src_only.destroy();
    try expectError(error.InvalidTextureCopy, encoder.copyBufferToTexture(&input, 0, 256, &src_only, region));
    try expectError(error.InvalidTextureRegion, texture.copyLayout(region, 1));
    try expectError(error.InvalidTextureRegion, texture.copyLayout(region, std.math.maxInt(u64) - 511));
    try expectError(error.InvalidTextureRegion, texture.fullRegion(1, 0));
    try expectError(error.InvalidTextureRegion, texture.fullRegion(0, 1));
    try expectError(error.InvalidTextureCopy, encoder.copyBufferToTexture(&input, 0, 16, &texture, region));
    try expectError(error.InvalidTextureCopy, encoder.copyBufferToTexture(&input, 512, 256, &texture, region));
    try expectError(error.InvalidTextureCopy, encoder.copyBufferToTexture(&input, 0, 256, &texture, .{ .width = 4, .height = 4, .x = 1 }));
    try expectError(error.InvalidTextureCopy, encoder.copyTextureToBuffer(&texture, region, &input, 0, 256));
    try expectError(error.InvalidTextureCopy, encoder.copyBufferToTexture(&output, 0, 256, &texture, region));
    try expectError(error.InvalidTextureCopy, encoder.copyBufferToTexture(&input, 0, 256, &texture, .{ .width = 0, .height = 4 }));
    try expectError(error.InvalidTextureCopy, encoder.copyTextureToTexture(&foreign_texture, region, &texture, region));
    try expectError(error.InvalidTextureCopy, encoder.copyTextureToTexture(&texture, region, &foreign_texture, region));
    try expectError(error.InvalidTextureCopy, encoder.copyTextureToTexture(&dst_only, region, &texture, region));
    try expectError(error.InvalidTextureCopy, encoder.copyTextureToTexture(&texture, region, &src_only, region));
    var wrong_format = try device.createTexture(std.heap.page_allocator, .{ .size = texture.size, .format = .rgba8_unorm, .usage = .{ .copy_dst = true } });
    defer wrong_format.destroy();
    try expectError(error.InvalidTextureCopy, encoder.copyTextureToTexture(&texture, region, &wrong_format, region));
    var wrong_dimension = try device.createTexture(std.heap.page_allocator, .{ .size = texture.size, .dimension = .@"3d", .format = .bgra8_unorm, .usage = .{ .copy_dst = true } });
    defer wrong_dimension.destroy();
    try expectError(error.InvalidTextureCopy, encoder.copyTextureToTexture(&texture, region, &wrong_dimension, region));
    var target = try device.createTexture(std.heap.page_allocator, .{ .size = texture.size, .format = .bgra8_unorm, .usage = .{ .render_attachment = true } });
    defer target.destroy();
    var pass = try encoder.beginRenderPass(.{ .color_attachments = &.{.{ .texture = &target }} });
    try expectError(error.InvalidTextureCopy, encoder.copyTextureToTexture(&texture, region, &dst_only, region));
    try pass.end();
    var command = try encoder.finish();
    defer command.deinit();
    try expectError(error.CommandEncoderFinished, encoder.copyTextureToTexture(&texture, region, &dst_only, region));
}
fn lifetime() !void {
    var device = try d12.Device.init(true);
    var released = false;
    defer if (!released) device.destroy();
    var queue = try device.createQueue();
    defer queue.deinit(5000) catch @panic("texture queue teardown failed");
    const gate = zenit_d12_test_gate_create(device.raw, queue.raw);
    var signaled = false;
    defer {
        if (!signaled) zenit_d12_test_gate_signal(gate);
        queue.waitIdle(5000) catch @panic("texture gate teardown failed");
        zenit_d12_test_gate_release(gate);
    }
    var texture = try device.createTexture(std.heap.page_allocator, .{ .size = .{ .width = 7, .height = 3 }, .format = .bgra8_unorm, .usage = .{ .copy_src = true, .copy_dst = true } });
    var texture_live = true;
    defer if (texture_live) texture.destroy();
    const region = try texture.fullRegion(0, 0);
    const layout = try texture.copyLayout(region, 512);
    var upload = try device.createBuffer(std.heap.page_allocator, .{ .size = layout.required_bytes, .usage = .{ .map_write = true, .copy_src = true } });
    var upload_live = true;
    defer if (upload_live) upload.destroy();
    fill(try upload.getMappedRange(0, upload.size), layout, region, 4, false);
    var readback = try device.createBuffer(std.heap.page_allocator, .{ .size = layout.required_bytes, .usage = .{ .map_read = true, .copy_dst = true } });
    defer readback.destroy();
    var encoder = try device.createCommandEncoder();
    defer encoder.deinit();
    try encoder.copyBufferToTexture(&upload, layout.offset, layout.row_pitch, &texture, region);
    try encoder.copyTextureToBuffer(&texture, region, &readback, layout.offset, layout.row_pitch);
    texture.destroy();
    texture_live = false;
    upload.destroy();
    upload_live = false;
    var command = try encoder.finish();
    const serial = try queue.submit(&.{command});
    command.deinit();
    const native_owner = device.raw;
    device.destroy();
    released = true;
    try expectError(error.GpuTimeout, queue.deinit(0));
    zenit_d12_test_gate_signal(gate);
    signaled = true;
    try queue.wait(serial, 5000);
    submissions += 1;
    try verify(try readback.getMappedRange(0, readback.size), layout, region, 4, null);
    zenit_d12_test_debug_check(native_owner);
    std.debug.print("PASS: GPU-blocked texture lifetime after pre-finish destroy; timeout/retry and 84 pixel bytes\n", .{});
}
fn textureCopy(device: *d12.Device, queue: *d12.Queue, format: gpu.TextureFormat, dimension: gpu.TextureDimension) !void {
    const one = dimension == .@"1d";
    const volume = dimension == .@"3d";
    var source = try device.createTexture(std.heap.page_allocator, .{ .size = .{ .width = 8, .height = if (one) 1 else 6, .depth = 4 }, .dimension = dimension, .format = format, .mip_level_count = 3, .usage = .{ .copy_src = true, .copy_dst = true } });
    var destination = try device.createTexture(std.heap.page_allocator, .{ .size = source.size, .dimension = dimension, .format = format, .mip_level_count = 3, .usage = .{ .copy_src = true, .copy_dst = true } });
    var textures_live = true;
    defer if (textures_live) {
        source.destroy();
        destination.destroy();
    };
    const src_full = try source.fullRegion(0, if (volume) 0 else 1);
    const dst_full = try destination.fullRegion(1, if (volume) 0 else 2);
    const src_layout = try source.copyLayout(src_full, 0);
    const dst_layout = try destination.copyLayout(dst_full, 0);
    var upload = try device.createBuffer(std.heap.page_allocator, .{ .size = src_layout.required_bytes, .usage = .{ .map_write = true, .copy_src = true } });
    var seed = try device.createBuffer(std.heap.page_allocator, .{ .size = dst_layout.required_bytes, .usage = .{ .map_write = true, .copy_src = true } });
    var uploads_live = true;
    defer if (uploads_live) {
        upload.destroy();
        seed.destroy();
    };
    fill(try upload.getMappedRange(0, upload.size), src_layout, src_full, bpp(format), false);
    @memset(try seed.getMappedRange(0, seed.size), 0xcc);
    var readback = try device.createBuffer(std.heap.page_allocator, .{ .size = dst_layout.required_bytes, .usage = .{ .map_read = true, .copy_dst = true } });
    defer readback.destroy();
    var second = try device.createBuffer(std.heap.page_allocator, .{ .size = 256, .usage = .{ .map_read = true, .copy_dst = true } });
    defer second.destroy();
    var encoder = try device.createCommandEncoder();
    defer encoder.deinit();
    try encoder.copyBufferToTexture(&upload, 0, src_layout.row_pitch, &source, src_full);
    try encoder.copyBufferToTexture(&seed, 0, dst_layout.row_pitch, &destination, dst_full);
    const src = d12.TextureRegion{ .layer = src_full.layer, .x = 1, .y = if (one) 0 else 1, .z = if (volume) 1 else 0, .width = 3, .height = if (one) 1 else 2, .depth = if (volume) 2 else 1 };
    const dst = d12.TextureRegion{ .mip = 1, .layer = dst_full.layer, .x = 1, .y = if (one) 0 else 1, .width = src.width, .height = src.height, .depth = src.depth };
    var bad = dst;
    bad.width = 2;
    try expectError(error.InvalidTextureCopy, encoder.copyTextureToTexture(&source, src, &destination, bad));
    bad = src;
    bad.x = std.math.maxInt(u32);
    try expectError(error.InvalidTextureCopy, encoder.copyTextureToTexture(&source, bad, &destination, dst));
    bad = dst;
    bad.mip = 3;
    try expectError(error.InvalidTextureCopy, encoder.copyTextureToTexture(&source, src, &destination, bad));
    bad = dst;
    bad.width = 0;
    try expectError(error.InvalidTextureCopy, encoder.copyTextureToTexture(&source, src, &destination, bad));
    try expectError(error.InvalidTextureCopy, encoder.copyTextureToTexture(&source, src, &source, src));
    try encoder.copyTextureToTexture(&source, src, &destination, dst);
    const same_src = d12.TextureRegion{ .mip = 1, .layer = dst.layer, .x = dst.x, .y = dst.y, .width = 1, .height = 1 };
    const same_dst = d12.TextureRegion{ .mip = 2, .width = 1, .height = 1 };
    try encoder.copyTextureToTexture(&destination, same_src, &destination, same_dst);
    try encoder.copyTextureToBuffer(&destination, dst_full, &readback, 0, dst_layout.row_pitch);
    try encoder.copyTextureToBuffer(&destination, same_dst, &second, 0, 256);
    source.destroy();
    destination.destroy();
    textures_live = false;
    upload.destroy();
    seed.destroy();
    uploads_live = false;
    var command = try encoder.finish();
    const gate = zenit_d12_test_gate_create(device.raw, queue.raw);
    var signaled = false;
    defer {
        if (!signaled) zenit_d12_test_gate_signal(gate);
        queue.waitIdle(5000) catch @panic("copy gate teardown");
        zenit_d12_test_gate_release(gate);
    }
    _ = try queue.submit(&.{command});
    command.deinit();
    try expectError(error.GpuTimeout, queue.waitIdle(0));
    try expectError(error.GpuTimeout, queue.deinit(0));
    zenit_d12_test_gate_signal(gate);
    signaled = true;
    try queue.waitIdle(5000);
    const bytes = try readback.getMappedRange(0, readback.size);
    for (0..dst_full.depth) |z| for (0..dst_full.height) |y| for (0..dst_full.width) |x| for (0..bpp(format)) |c| {
        const copied = x >= dst.x and x < dst.x + dst.width and y >= dst.y and y < dst.y + dst.height;
        const expected: u8 = if (copied) pattern(0, src.layer, @intCast(x - dst.x + src.x), @intCast(y - dst.y + src.y), @intCast(z + src.z), @intCast(c), false) else 0xcc;
        if (bytes[(z * dst_full.height + y) * dst_layout.row_pitch + x * bpp(format) + c] != expected) return error.IncorrectTextureRegionCopy;
        verified_bytes += 1;
    };
    if (format == .rgba8_unorm and dimension == .@"2d") {
        var pixels: [4 * 3 * 4]u8 = undefined;
        for (0..3) |y| @memcpy(pixels[y * 16 ..][0..16], bytes[y * dst_layout.row_pitch ..][0..16]);
        std.debug.print("TEXTURE_COPY_RGBA8_HEX={s}\n", .{std.fmt.bytesToHex(pixels, .lower)});
    }
    const same_bytes = try second.getMappedRange(0, second.size);
    for (0..bpp(format)) |c| {
        if (same_bytes[c] != pattern(0, src.layer, src.x, src.y, src.z, @intCast(c), false)) return error.IncorrectSameTextureCopy;
        verified_bytes += 1;
    }
    submissions += 1;
    std.debug.print("PASS: texture-to-texture {s} {s}, partial offset/mip/layer/volume, untouched pixels, same-resource different mip, invalid regions and blocked-GPU early-owner retention\n", .{ @tagName(format), @tagName(dimension) });
}
pub fn run() !void {
    submissions = 0;
    verified_bytes = 0;
    var device = try d12.Device.init(true);
    defer device.destroy();
    var queue = try device.createQueue();
    defer queue.deinit(5000) catch @panic("texture queue teardown failed");
    try validation(&device);
    for (std.enums.values(gpu.TextureFormat)) |format| {
        if (pixelBytes(format) != null) {
            try roundTrip(&device, &queue, format, .@"2d");
            for ([_]gpu.TextureDimension{ .@"1d", .@"2d", .@"3d" }) |dimension| try textureCopy(&device, &queue, format, dimension);
        } else {
            const expected = switch (format) {
                .depth16_unorm, .depth24_plus, .depth24_plus_stencil8, .depth32_float, .depth32_float_stencil8 => error.InvalidTextureDescriptor,
                else => error.UnsupportedTextureFormat,
            };
            try expectError(expected, device.createTexture(std.heap.page_allocator, .{ .size = .{ .width = 4, .height = 4 }, .format = format, .usage = .{ .copy_dst = true } }));
        }
    }
    try roundTrip(&device, &queue, .bgra8_unorm, .@"1d");
    try roundTrip(&device, &queue, .rgba16_float, .@"3d");
    zenit_d12_test_debug_check(device.raw);
    try lifetime();
    std.debug.print("PASS: texture contract total {d} production submissions, {d} pixel bytes verified\n", .{ submissions, verified_bytes });
}
