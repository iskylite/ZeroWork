//! Live Vulkan graphics/readback contract; software devices require opt-in.
const std = @import("std");
const vk = @import("vulkan_device").vulkan_native;

// Vulkan requires actual four-byte storage alignment, not just an aligned
// pointer type cast over the one-byte-aligned @embedFile string.
const vertex_storage align(4) = @embedFile("probe_vertex").*;
const fragment_storage align(4) = @embedFile("probe_fragment").*;
const vertex: []align(4) const u8 = &vertex_storage;
const fragment: []align(4) const u8 = &fragment_storage;

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    var options: vk.Device.Options = .{};
    var output: ?[]const u8 = null;
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--allow-software")) {
            options.allow_software = true;
        } else if (std.mem.eql(u8, args[i], "--validation")) {
            options.require_validation = true;
        } else if (std.mem.eql(u8, args[i], "--output") and i + 1 < args.len) {
            i += 1;
            output = args[i];
        } else {
            std.debug.print("usage: zenit-linux-vulkan-probe [--allow-software] [--validation] [--output image.ppm]\n", .{});
            return error.InvalidArgument;
        }
    }
    var diagnostic: vk.Diagnostic = .{};
    var device = vk.Device.init(options, &diagnostic) catch |err| {
        std.debug.print("VULKAN_PROBE FAIL: error={s} operation={s} vk_result={d}\n", .{ @errorName(err), diagnostic.operationName(), diagnostic.vk_result });
        return err;
    };
    defer _ = device.deinit() catch {};
    std.debug.print("VULKAN_DEVICE: name={s} type={d} software={} api={d}.{d}.{d} vendor=0x{x} queue={d} validation={}\n", .{
        device.info.deviceName(),      device.info.device_type,                 device.info.isSoftware(),
        device.info.api_version >> 22, (device.info.api_version >> 12) & 0x3ff, device.info.api_version & 0xfff,
        device.info.vendor_id,         device.info.queue_family,                options.require_validation,
    });
    try verifyResources(&device, &diagnostic);
    try verifyTextureBlit(&device, &diagnostic);
    // Odd dimensions exercise tightly packed copy strides and non-atom-sized payloads.
    const width = 127;
    const height = 93;
    var pixels: [width * height * 4]u8 = undefined;
    for (0..8) |_| {
        @memset(&pixels, 0x5a);
        device.renderProbe(width, height, &pixels, vertex, fragment, &diagnostic) catch |err| {
            std.debug.print("VULKAN_PROBE FAIL: error={s} operation={s} vk_result={d}\n", .{ @errorName(err), diagnostic.operationName(), diagnostic.vk_result });
            return err;
        };
        try verifyPixels(&pixels, width, height);
    }
    // Invalid descriptors must be rejected before submitting GPU work.
    if (device.renderProbe(0, height, &pixels, vertex, fragment, &diagnostic)) |_| {
        return error.ZeroExtentAccepted;
    } else |err| if (err != error.InvalidDescriptor) return err;
    if (device.renderProbe(width, height, pixels[0 .. pixels.len - 1], vertex, fragment, &diagnostic)) |_| {
        return error.ShortReadbackAccepted;
    } else |err| if (err != error.InvalidDescriptor) return err;
    if (device.renderProbe(width, height, &pixels, vertex[0 .. vertex.len - 1], fragment, &diagnostic)) |_| {
        return error.MisalignedShaderLengthAccepted;
    } else |err| if (err != error.InvalidDescriptor) return err;
    if (output) |path| {
        var ppm: [32 + width * height * 3]u8 = undefined;
        const header = try std.fmt.bufPrint(ppm[0..32], "P6\n{d} {d}\n255\n", .{ width, height });
        for (0..width * height) |p| {
            ppm[header.len + p * 3] = pixels[p * 4 + 2];
            ppm[header.len + p * 3 + 1] = pixels[p * 4 + 1];
            ppm[header.len + p * 3 + 2] = pixels[p * 4];
        }
        try std.Io.Dir.cwd().writeFile(init.io, .{ .sub_path = path, .data = ppm[0 .. header.len + width * height * 3] });
    }
    const software = device.info.isSoftware();
    const errors = try device.deinit();
    if (errors != 0) return error.VulkanValidationErrors;
    std.debug.print("VULKAN_PROBE PASS: mode={s} resources=buffer-copy-texture-regions graphics_pipeline=triangle bgra_readback=exact frames=8 invalid_descriptors=3 validation_errors=0 validation_enabled={}\n", .{ if (software) "software-functional" else "gpu", options.require_validation });
}

fn verifyPixels(pixels: []const u8, width: usize, height: usize) !void {
    var green: usize = 0;
    var red: usize = 0;
    for (0..height) |y| for (0..width) |x| {
        const pixel = pixels[(y * width + x) * 4 ..][0..4];
        if (std.mem.eql(u8, pixel, &.{ 0, 255, 0, 255 })) {
            green += 1;
        } else if (std.mem.eql(u8, pixel, &.{ 0, 0, 255, 255 })) {
            red += 1;
        } else return error.UnexpectedBgraPixel;
        // Independent interior/exterior checks catch clear-only, full-screen,
        // inverted-color and stale readback results without edge tolerances.
        if (x > width * 45 / 100 and x < width * 55 / 100 and
            y > height * 40 / 100 and y < height * 55 / 100 and
            !std.mem.eql(u8, pixel, &.{ 0, 255, 0, 255 })) return error.TriangleInteriorMissing;
        if ((x < width / 10 or x >= width * 9 / 10 or y < height / 10 or y >= height * 9 / 10) and
            !std.mem.eql(u8, pixel, &.{ 0, 0, 255, 255 })) return error.BackgroundMissing;
    };
    if (green < width * height / 4 or green > width * height / 3 or red == 0)
        return error.IncorrectTriangleCoverage;
}

// Test actual resource reuse and partial updates, independent of the triangle.
// Distinct patterns and untouched padding detect wrong strides/offsets.
fn verifyResources(device: *vk.Device, diagnostic: *vk.Diagnostic) !void {
    var source = try device.createBufferResource(513, 12, diagnostic);
    defer source.destroy();
    var destination = try device.createBufferResource(513, 12, diagnostic);
    defer destination.destroy();
    if (device.deinit()) |_| return error.DeviceDestroyedWithLiveResources else |err| {
        if (err != error.ResourcesAlive) return err;
    }
    var pattern: [513]u8 = undefined;
    for (&pattern, 0..) |*byte, i| byte.* = @truncate(i * 37 + 11);
    var result: [513]u8 = @splat(0xa5);
    try source.write(0, &pattern, diagnostic);
    try destination.write(0, &result, diagnostic);
    try source.copyTo(7, &destination, 13, 491, diagnostic);
    try destination.read(0, &result, diagnostic);
    for (result, 0..) |byte, i| {
        const expected = if (i >= 13 and i < 504) pattern[i - 13 + 7] else 0xa5;
        if (byte != expected) return error.BufferCopyMismatch;
    }
    if (source.copyTo(0, &source, 1, 20, diagnostic)) |_| return error.OverlappingCopyAccepted else |err| {
        if (err != error.InvalidDescriptor) return err;
    }
    if (source.write(512, pattern[0..2], diagnostic)) |_| return error.BufferOverflowAccepted else |err| {
        if (err != error.InvalidDescriptor) return err;
    }
    if (device.createBufferResource(0, 12, diagnostic)) |_| return error.ZeroBufferAccepted else |err| {
        if (err != error.InvalidDescriptor) return err;
    }
    for (0..4) |cycle| {
        for ([_]vk.resources.Format{ .r8_unorm, .rgba8_unorm, .bgra8_unorm }) |format| {
            var texture = try device.createTextureResource(17, 13, format, diagnostic);
            defer texture.destroy();
            const texel: usize = if (format == .r8_unorm) 1 else 4;
            const stride = 17 * texel + 7;
            var upload: [13 * 75]u8 = @splat(0xee);
            var readback: [13 * 75]u8 = @splat(0xa5);
            if (texture.readRegion(0, 0, 17, 13, &readback, @intCast(stride), diagnostic)) |_| return error.UndefinedTextureReadAccepted else |err| {
                if (err != error.InvalidDescriptor) return err;
            }
            for (0..13) |y| for (0..17 * texel) |x| {
                upload[y * stride + x] = @truncate(x * 11 + y * 37 + cycle);
            };
            try texture.writeRegion(0, 0, 17, 13, &upload, @intCast(stride), diagnostic);
            // Different tightly packed source updates a subregion.
            var patch: [5 * 3 * 4]u8 = undefined;
            for (&patch, 0..) |*byte, i| byte.* = @truncate(255 - i);
            try texture.writeRegion(3, 4, 5, 3, patch[0 .. 5 * 3 * texel], @intCast(5 * texel), diagnostic);
            try texture.readRegion(0, 0, 17, 13, &readback, @intCast(stride), diagnostic);
            for (0..13) |y| for (0..stride) |x| {
                const expected: u8 = if (x >= 17 * texel) 0xa5 else if (y >= 4 and y < 7 and x >= 3 * texel and x < 8 * texel)
                    patch[(y - 4) * 5 * texel + x - 3 * texel]
                else
                    upload[y * stride + x];
                if (readback[y * stride + x] != expected) return error.TextureRegionMismatch;
            };
            if (texture.writeRegion(16, 0, 2, 1, &patch, 8, diagnostic)) |_| return error.TextureOverflowAccepted else |err| {
                if (err != error.InvalidDescriptor) return err;
            }
            if (texture.readRegion(0, 0, 17, 13, readback[0..10], @intCast(stride), diagnostic)) |_| return error.ShortTextureReadAccepted else |err| {
                if (err != error.InvalidDescriptor) return err;
            }
        }
    }
    std.debug.print("VULKAN_RESOURCES PASS: buffer_offset_copy=exact textures=12 formats=3 partial_updates=exact padded_rows=preserved lifetime_guard=true\n", .{});
}

fn verifyTextureBlit(device: *vk.Device, diag: *vk.Diagnostic) !void {
    for ([_]vk.resources.Format{ .r8_unorm, .rgba8_unorm, .bgra8_unorm }) |format| {
        const bpp: usize = if (format == .r8_unorm) 1 else 4;
        var source = try device.createTextureResource(8, 6, format, diag);
        defer source.destroy();
        var target = try device.createTextureResource(8, 6, format, diag);
        defer target.destroy();
        try source.clear(.{ 1, 1, 1, 1 }, diag);
        try target.clear(.{ 0, 0, 0, 0 }, diag);
        try source.copyTo(1, 1, &target, 2, 3, 3, 2, diag);
        var pixels: [8 * 6 * 4]u8 = undefined;
        try target.readRegion(0, 0, 8, 6, pixels[0 .. 8 * 6 * bpp], @intCast(8 * bpp), diag);
        for (0..6) |y| for (0..8) |x| {
            const expected: u8 = if (x >= 2 and x < 5 and y >= 3 and y < 5) 255 else 0;
            for (pixels[(y * 8 + x) * bpp ..][0..bpp]) |byte| if (byte != expected) return error.TextureCopyMismatch;
        };
        // In-place, nonoverlapping copy needs one GENERAL image layout.
        try target.copyTo(2, 3, &target, 0, 0, 2, 2, diag);
        try target.readRegion(0, 0, 2, 2, pixels[0 .. 4 * bpp], @intCast(2 * bpp), diag);
        for (pixels[0 .. 4 * bpp]) |byte| if (byte != 255) return error.InPlaceTextureCopyMismatch;
        if (target.copyTo(0, 0, &target, 1, 1, 2, 2, diag)) |_| return error.OverlappingTextureCopyAccepted else |err| {
            if (err != error.InvalidDescriptor) return err;
        }
        if (source.copyTo(7, 5, &target, 0, 0, 2, 2, diag)) |_| return error.TextureCopyBoundsAccepted else |err| {
            if (err != error.InvalidDescriptor) return err;
        }
    }
    std.debug.print("VULKAN_TEXTURE_BLIT PASS: formats=3 clear=true region_copy=true in_place_disjoint=true overlap_rejected=true bounds_rejected=true\n", .{});
}
