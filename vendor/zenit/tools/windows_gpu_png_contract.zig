const std = @import("std");
const gpu = @import("gpu");
extern fn zenit_d12_test_decode_png([*:0]const u8, [*]u8) c_int;
pub fn run(io: std.Io) !void {
    if (gpu.backend_kind != .d3d12) return error.WrongSelectedBackend;
    const a = std.heap.page_allocator;
    const temp = try @import("zenit_environment").getOwned(a, "TEMP");
    defer a.free(temp);
    var random_bytes: [8]u8 = undefined;
    io.random(&random_bytes);
    const path = try std.fmt.allocPrintSentinel(a, "{s}\\zenit-png-字体-{x}.png", .{ temp, std.mem.readInt(u64, &random_bytes, .little) }, 0);
    defer a.free(path);
    defer std.Io.Dir.cwd().deleteFile(io, path) catch {};
    const pixels = [_]u8{ 255, 10, 20, 0, 30, 200, 40, 64, 222, 222, 222, 222, 50, 60, 240, 128, 70, 80, 90, 255, 222, 222, 222, 222 };
    const expected = pixels[0..8].* ++ pixels[12..20].*;
    for (0..4) |_| {
        if (!gpu.Backend.writePngRgba(path, &pixels, 2, 2, 12)) return error.PngEncodingFailed;
        var decoded: [16]u8 = undefined;
        if (zenit_d12_test_decode_png(path, &decoded) != 0 or !std.mem.eql(u8, &decoded, &expected)) return error.IncorrectPngRoundTrip;
    }
    if (gpu.Backend.writePngRgba(path, &pixels, 0, 2, 12) or
        gpu.Backend.writePngRgba(path, pixels[0..23], 2, 2, 12) or
        gpu.Backend.writePngRgba(path, &pixels, 2, 2, 7) or
        gpu.Backend.writePngRgba(path, &pixels, std.math.maxInt(u32), 2, 12) or
        gpu.Backend.writePngRgba("\xff.png", &pixels, 2, 2, 12)) return error.InvalidPngAccepted;
    std.debug.print("PASS: selected gpu.Backend d3d12 contract, WIC PNG four repeated Unicode-path round trips, padded RGBA rows, exact straight-alpha channels 0/64/128/255 and invalid dimensions/length/stride/UTF8 guards\n", .{});
}
