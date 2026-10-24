//! Real ImageIO decoding and draft-resource tests, without a window or GPU.
const std = @import("std");
const asset = @import("config/background_asset.zig");

// Standard PNG: 1 x 1, 8-bit RGBA, opaque red, no color profile. IDAT contains
// zlib-compressed filter byte + ff 00 00 ff; all chunk CRCs are valid.
const red_png =
    "\x89PNG\r\n\x1a\n\x00\x00\x00\x0dIHDR" ++
    "\x00\x00\x00\x01\x00\x00\x00\x01\x08\x06\x00\x00\x00\x1f\x15\xc4\x89" ++
    "\x00\x00\x00\x0dIDAT\x78\x9c\x63\xf8\xcf\xc0\xf0\x1f\x00\x05\x00\x01\xff\x89\x99\x3d\x1d" ++
    "\x00\x00\x00\x00IEND\xae\x42\x60\x82";

// A valid IHDR/CRC with invalid IDAT zlib bytes. Metadata alone is insufficient
// to accept an image: a lazy decode must not masquerade as an all-zero bitmap.
const invalid_raster_png =
    "\x89PNG\r\n\x1a\n\x00\x00\x00\x0dIHDR" ++
    "\x00\x00\x00\x01\x00\x00\x00\x01\x08\x06\x00\x00\x00\x1f\x15\xc4\x89" ++
    "\x00\x00\x00\x08IDATbad-zlib\xa9\xbf\xb9\xcf" ++
    "\x00\x00\x00\x00IEND\xae\x42\x60\x82";

test "background asset decodes a real one-pixel RGBA PNG" {
    var image = try asset.decode(std.testing.allocator, red_png, .{});
    defer image.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u32, 1), image.width);
    try std.testing.expectEqual(@as(u32, 1), image.height);
    try std.testing.expectEqualSlices(u8, &.{ 255, 0, 0, 255 }, image.pixels);
}

test "background asset rejects empty bytes bad headers and corrupt raster data" {
    for ([_][]const u8{ "", "not an image", invalid_raster_png }) |bytes| {
        const result = asset.decode(std.testing.allocator, bytes, .{});
        defer {
            if (result) |value| {
                var unexpected = value;
                unexpected.deinit(std.testing.allocator);
            } else |_| {}
        }
        try std.testing.expectError(error.InvalidImage, result);
    }
    try std.testing.expectEqual(asset.DecodeState.invalid, asset.failureState(error.InvalidImage));
}

test "background asset enforces source dimension and pixel budgets before returning pixels" {
    const exact: asset.Limits = .{ .source_bytes = red_png.len, .dimension = 1, .pixels = 1 };
    var image = try asset.decode(std.testing.allocator, red_png, exact);
    defer image.deinit(std.testing.allocator);
    for ([_]asset.Limits{
        .{ .source_bytes = red_png.len - 1 },
        .{ .dimension = 0 },
        .{ .pixels = 0 },
    }) |limits| {
        try std.testing.expectError(error.ImageTooLarge, asset.decode(std.testing.allocator, red_png, limits));
    }
    try std.testing.expectEqual(asset.DecodeState.invalid, asset.failureState(error.ImageTooLarge));
}

test "background asset prepares only absolute paths with bounded reads and missing file errors" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "pixel.png", .data = red_png });
    const path = try tmp.dir.realPathFileAlloc(std.testing.io, "pixel.png", allocator);
    defer allocator.free(path);
    const request: asset.Request = .{ .draft_id = 21, .asset_revision = 3, .path = path };
    var prepared = try asset.prepare(std.testing.io, tmp.dir, allocator, request, .{});
    defer prepared.deinit(allocator);
    try std.testing.expectEqual(request.draft_id, prepared.draft_id);
    try std.testing.expectEqual(request.asset_revision, prepared.asset_revision);
    try std.testing.expectEqualStrings(path, prepared.path);
    try std.testing.expect(path.ptr != prepared.path.ptr);
    try std.testing.expectEqualSlices(u8, &.{ 255, 0, 0, 255 }, prepared.image.pixels);
    for ([_][]const u8{ "", "pixel.png" }) |invalid_path| {
        try std.testing.expectError(error.InvalidImagePath, asset.prepare(std.testing.io, tmp.dir, allocator, .{ .draft_id = 21, .asset_revision = 4, .path = invalid_path }, .{}));
    }
    try std.testing.expectError(error.StreamTooLong, asset.prepare(std.testing.io, tmp.dir, allocator, request, .{ .source_bytes = red_png.len - 1 }));
    try tmp.dir.deleteFile(std.testing.io, "pixel.png");
    try std.testing.expectError(error.FileNotFound, asset.prepare(std.testing.io, tmp.dir, allocator, request, .{}));
    try std.testing.expectEqual(asset.DecodeState.missing, asset.failureState(error.FileNotFound));
}

test "background asset late completions free their resources and failure preserves last good image" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "pixel.png", .data = red_png });
    const path = try tmp.dir.realPathFileAlloc(std.testing.io, "pixel.png", std.testing.allocator);
    defer std.testing.allocator.free(path);
    var tracking = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    const allocator = tracking.allocator();
    {
        var draft: asset.Draft = .{ .draft_id = 31 };
        defer draft.deinit(allocator);
        const first = try draft.select(path);
        try std.testing.expectEqual(asset.DecodeState.loading, draft.state);
        try std.testing.expect(!draft.canSave(.{ .enabled = true, .path = path }));
        var initial = try asset.prepare(std.testing.io, tmp.dir, allocator, first, .{});
        try std.testing.expect(draft.complete(allocator, &initial));
        try std.testing.expectEqual(asset.DecodeState.ready, draft.state);
        try std.testing.expect(draft.canSave(.{ .enabled = true, .path = path }));
        try std.testing.expect(!draft.canSave(.{ .enabled = true, .path = "/another.png" }));
        const initial_live_bytes = tracking.allocated_bytes - tracking.freed_bytes;

        const second = try draft.select("/missing-new-selection.png");
        try std.testing.expect(!draft.canSave(.{ .enabled = true, .path = second.path }));
        var late = try asset.prepare(std.testing.io, tmp.dir, allocator, first, .{});
        const late_owned_bytes = late.path.len + late.image.pixels.len;
        const before_stale_release = tracking.freed_bytes;
        try std.testing.expect(!draft.complete(allocator, &late));
        try std.testing.expectEqual(before_stale_release + late_owned_bytes, tracking.freed_bytes);
        try std.testing.expectEqual(initial_live_bytes, tracking.allocated_bytes - tracking.freed_bytes);
        try std.testing.expectEqual(asset.DecodeState.loading, draft.state);
        try std.testing.expectEqualStrings(path, draft.last_good.?.path);
        try std.testing.expectEqualSlices(u8, &.{ 255, 0, 0, 255 }, draft.last_good.?.image.pixels);

        try std.testing.expect(draft.fail(second, error.FileNotFound));
        try std.testing.expectEqual(asset.DecodeState.missing, draft.state);
        try std.testing.expectEqual(error.FileNotFound, draft.problem.?);
        try std.testing.expect(!draft.fail(first, error.AccessDenied));
        try std.testing.expectEqual(asset.DecodeState.missing, draft.state);
        try std.testing.expectEqualStrings(path, draft.last_good.?.path);
        try std.testing.expect(!draft.canSave(.{ .enabled = true, .path = second.path }));
        try std.testing.expect(draft.canSave(.{ .enabled = false, .path = second.path }));

        var wrong_owner = try asset.prepare(std.testing.io, tmp.dir, allocator, .{ .draft_id = 99, .asset_revision = second.asset_revision, .path = path }, .{});
        try std.testing.expect(!draft.complete(allocator, &wrong_owner));
        try std.testing.expectEqual(initial_live_bytes, tracking.allocated_bytes - tracking.freed_bytes);
        const third = try draft.select(path);
        var replacement = try asset.prepare(std.testing.io, tmp.dir, allocator, third, .{});
        try std.testing.expect(draft.complete(allocator, &replacement));
        try std.testing.expect(draft.canSave(.{ .enabled = true, .path = path }));
        try std.testing.expect(draft.problem == null);
        try std.testing.expectEqual(initial_live_bytes, tracking.allocated_bytes - tracking.freed_bytes);
    }
    try std.testing.expectEqual(tracking.allocated_bytes, tracking.freed_bytes);
}

test "background asset alpha and disabled missing paths retain valid save semantics" {
    for ([_]struct { transparency: f32, alpha: f32 }{
        .{ .transparency = 0, .alpha = 1 },
        .{ .transparency = 12, .alpha = 0.88 },
        .{ .transparency = 100, .alpha = 0 },
    }) |case| {
        const background: asset.Background = .{ .transparency = case.transparency };
        try std.testing.expectApproxEqAbs(case.alpha, background.alpha(), 0.000001);
    }
    const background: asset.Background = .{ .enabled = false, .path = "/no-such-image.png", .fit = .tile, .alignment_x = .right, .alignment_y = .bottom, .transparency = 12 };
    try (asset.Materials{ .background = background, .blur_px = 24 }).validate();
    const draft: asset.Draft = .{ .draft_id = 41, .state = .missing, .problem = error.FileNotFound };
    try std.testing.expect(draft.canSave(background));
    try std.testing.expect(!draft.canSave(.{ .enabled = true, .path = background.path }));
    for ([_]f32{ -1, 101, std.math.nan(f32), std.math.inf(f32) }) |invalid| {
        try std.testing.expectError(error.OutOfRange, (asset.Materials{ .background = .{ .transparency = invalid } }).validate());
    }
}
