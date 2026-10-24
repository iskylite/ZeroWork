const std = @import("std");
const gpu = @import("gpu");

test "Metal texture uploads reject incomplete rows before touching native handles" {
    // SKIP-REASON: Validates Metal upload rejection before using fake native handles.
    if (gpu.backend_kind != .metal) return error.SkipZigTest;
    const cases = [_]struct { format: gpu.TextureFormat, row_bytes: u32 }{
        .{ .format = .r8_unorm, .row_bytes = 8 },
        .{ .format = .r16_float, .row_bytes = 16 },
        .{ .format = .bgra8_unorm, .row_bytes = 32 },
        .{ .format = .rgba8_unorm_srgb, .row_bytes = 32 },
        .{ .format = .rgba16_float, .row_bytes = 64 },
        .{ .format = .rgba32_float, .row_bytes = 128 },
        .{ .format = .depth24_plus_stencil8, .row_bytes = 64 },
        .{ .format = .bc1_rgba_unorm, .row_bytes = 16 },
        .{ .format = .bc3_rgba_unorm, .row_bytes = 32 },
    };
    const backing = @as([256]u8, @splat(0));
    for (cases) |case| {
        var texture = gpu.Backend.Texture.fakeForTesting(8, 2, case.format);
        texture.memory = .host_upload;
        const stride = case.row_bytes - 1;
        try std.testing.expectError(error.InvalidTextureData, texture.writeRegion(0, 0, 0, 8, 2, backing[0 .. stride * 2], stride));
    }
    var texture = gpu.Backend.Texture.fakeForTesting(8, 2, .bgra8_unorm);
    texture.memory = .host_upload;
    try std.testing.expectError(error.InvalidTextureData, texture.writeRegion(0, 0, 0, 8, 2, backing[0..63], 32));
    texture.mip_level_count = 2;
    try std.testing.expectError(error.InvalidTextureData, texture.writeRegion(1, 0, 0, 4, 1, backing[0..15], 15));
}
