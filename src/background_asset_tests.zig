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
        .{ .transparency = 0, .alpha = 0 },
        .{ .transparency = 12, .alpha = 0.12 },
        .{ .transparency = 100, .alpha = 1 },
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

test "background directory decodes the selected child and skips broken images on demand" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDir(io, "nested", .default_dir);
    try tmp.dir.writeFile(io, .{ .sub_path = "nested/1.png", .data = red_png });
    for ([_][]const u8{ "10.png", "2.PNG", "01.png" }) |name| try tmp.dir.writeFile(io, .{ .sub_path = name, .data = red_png });
    try tmp.dir.writeFile(io, .{ .sub_path = "bad.png", .data = "corrupt raster" });
    try tmp.dir.writeFile(io, .{ .sub_path = "notes.txt", .data = red_png });
    const file = try tmp.dir.realPathFileAlloc(io, "10.png", a);
    defer a.free(file);
    const path = std.fs.path.dirname(file).?;
    var prepared = try asset.prepare(io, tmp.dir, a, .{ .draft_id = 9, .asset_revision = 4, .path = path, .source = .directory }, .{});
    defer prepared.deinit(a);
    try std.testing.expectEqualStrings(path, prepared.path);
    try std.testing.expectEqual(asset.Source.directory, prepared.source);
    // Undisplayed files have not been decoded or filtered during startup.
    try std.testing.expectEqual(@as(usize, 4), prepared.playlist.?.paths.items.len);
    try std.testing.expectEqualStrings("01.png", std.fs.path.basename(prepared.selectedPath()));
    var copy = try prepared.clone(a);
    defer copy.deinit(a);
    try std.testing.expect(copy.playlist.?.paths.items[0].ptr != prepared.playlist.?.paths.items[0].ptr);
    var next = try asset.prepareNext(io, tmp.dir, a, path, &copy.playlist.?);
    defer next.deinit(a);
    try std.testing.expectEqualStrings("2.PNG", std.fs.path.basename(next.selectedPath()));
    try tmp.dir.deleteFile(io, "10.png");
    try tmp.dir.writeFile(io, .{ .sub_path = "01.png", .data = "damaged after scan" });
    var wrapped = try asset.prepareNext(io, tmp.dir, a, path, &next.playlist.?);
    defer wrapped.deinit(a);
    try std.testing.expectEqualStrings("2.PNG", std.fs.path.basename(wrapped.selectedPath()));
    try tmp.dir.deleteFile(io, "2.PNG");
    try std.testing.expectError(error.NoUsableImages, asset.prepareNext(io, tmp.dir, a, path, &wrapped.playlist.?));
    try std.testing.expectEqualSlices(u8, &.{ 255, 0, 0, 255 }, wrapped.image.pixels);
    try std.testing.expectError(error.NoUsableImages, asset.prepare(io, tmp.dir, a, .{ .draft_id = 9, .asset_revision = 5, .path = path, .source = .directory }, .{}));
}

test "background directory skips a corrupt first image and honors initial decode limits" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "1.png", .data = invalid_raster_png });
    try tmp.dir.writeFile(io, .{ .sub_path = "2.png", .data = red_png });
    const file = try tmp.dir.realPathFileAlloc(io, "2.png", a);
    defer a.free(file);
    const request: asset.Request = .{ .draft_id = 19, .asset_revision = 7, .path = std.fs.path.dirname(file).?, .source = .directory };
    var prepared = try asset.prepare(io, tmp.dir, a, request, .{});
    defer prepared.deinit(a);
    try std.testing.expectEqualStrings("2.png", std.fs.path.basename(prepared.selectedPath()));
    try std.testing.expectEqual(request.draft_id, prepared.draft_id);
    try std.testing.expectEqual(request.asset_revision, prepared.asset_revision);
    try std.testing.expectEqual(@as(usize, 2), prepared.playlist.?.paths.items.len);
    try std.testing.expectError(error.NoUsableImages, asset.prepare(io, tmp.dir, a, request, .{ .pixels = 0 }));
}

test "background random cycles do not repeat within a cycle or across its boundary" {
    const a = std.testing.allocator;
    var list: asset.Playlist = .{};
    defer list.deinit(a);
    for ([_][]const u8{ "1.png", "2.png", "3.png", "4.png" }) |path| try list.append(a, path);
    list.setOrder(true, 12345);
    var previous: ?[]const u8 = null;
    for (0..50) |_| {
        var seen: [4][]const u8 = undefined;
        for (&seen, 0..) |*entry, i| {
            entry.* = list.paths.items[list.index];
            if (previous) |last| try std.testing.expect(!std.mem.eql(u8, last, entry.*));
            for (seen[0..i]) |earlier| try std.testing.expect(!std.mem.eql(u8, earlier, entry.*));
            previous = entry.*;
            list.advance();
        }
    }
    var single: asset.Playlist = .{};
    defer single.deinit(a);
    try single.append(a, "only.png");
    single.setOrder(true, 10);
    single.advance();
    try std.testing.expectEqual(@as(usize, 0), single.index);
}

test "background directory configuration round trips and old file configurations keep defaults" {
    const config = @import("config/config.zig");
    const old = try config.Config.parse("[ui.materials.background]\nenabled = true\npath = \"/tmp/old.png\"\n");
    try std.testing.expectEqual(asset.Source.file, old.ui.materials.background.source);
    try std.testing.expectEqual(@as(u16, 5), old.ui.materials.background.interval_minutes);
    var candidate: config.Config = .{};
    candidate.ui.materials.background = .{ .enabled = true, .source = .directory, .order = .random, .path = "/tmp/images", .interval_minutes = 15 };
    var buffer: [32768]u8 = undefined;
    const parsed = try config.Config.parse(try candidate.format(&buffer));
    try std.testing.expectEqual(asset.Source.directory, parsed.ui.materials.background.source);
    try std.testing.expectEqual(asset.Order.random, parsed.ui.materials.background.order);
    try std.testing.expectEqualStrings("/tmp/images", parsed.ui.materials.background.path);
    try std.testing.expectEqual(@as(u16, 15), parsed.ui.materials.background.interval_minutes);
    candidate.ui.materials.background.interval_minutes = 0;
    try std.testing.expectError(error.OutOfRange, candidate.validate());
}

test "background rotation timer starts at successful display and skips missed intervals" {
    const Rotation = @import("config/background_rotation.zig").Rotation;
    var rotation: Rotation = .{};
    defer rotation.deinit();
    rotation.sync(7, 1000, 5, false);
    try std.testing.expect(rotation.deadline_ms == null);
    rotation.sync(7, 2000, 5, true);
    try std.testing.expect(!rotation.due(301999));
    try std.testing.expect(rotation.due(302000));
    // A long sleep produces a single due result, then a full new interval.
    try std.testing.expect(rotation.due(9_000_000));
    rotation.reset(9_000_000, 5);
    try std.testing.expect(!rotation.due(9_000_001));
    try std.testing.expectEqual(@as(u64, 9_300_000), rotation.deadline_ms.?);
    rotation.sync(8, 9_000_010, 1, true);
    try std.testing.expectEqual(@as(u64, 9_060_010), rotation.deadline_ms.?);
    rotation.sync(8, 9_000_020, 1, false);
    try std.testing.expect(rotation.deadline_ms == null);
}

test "background rotation worker owns its resources and never changes saved configuration" {
    const Rotation = @import("config/background_rotation.zig").Rotation;
    const config = @import("config/config.zig");
    const io = std.testing.io;
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "1.png", .data = red_png });
    try tmp.dir.writeFile(io, .{ .sub_path = "2.png", .data = red_png });
    const file = try tmp.dir.realPathFileAlloc(io, "1.png", a);
    defer a.free(file);
    const path = std.fs.path.dirname(file).?;
    var current = try asset.prepare(io, tmp.dir, a, .{ .draft_id = 12, .asset_revision = 3, .source = .directory, .path = path }, .{});
    defer current.deinit(a);
    var saved: config.Config = .{};
    saved.ui.materials.background = .{ .enabled = true, .source = .directory, .path = path };
    var buffer: [32768]u8 = undefined;
    try tmp.dir.writeFile(io, .{ .sub_path = "config.toml", .data = try saved.format(&buffer) });
    var rotation: Rotation = .{};
    defer rotation.deinit();
    rotation.sync(Rotation.identity(saved.ui.materials.background, 1), 0, 5, true);
    try rotation.start(a, io, tmp.dir, &current, false);
    for (0..1_000_000) |_| {
        if (rotation.ready()) break;
        std.Thread.yield() catch {};
    }
    const job = rotation.take() orelse return error.WorkerTimeout;
    defer job.destroy();
    try std.testing.expect(job.problem == null);
    try std.testing.expectEqualStrings("2.png", std.fs.path.basename(job.result.?.selectedPath()));
    try std.testing.expectEqual(@as(u64, 3), job.result.?.asset_revision);
    try std.testing.expectEqualStrings("1.png", std.fs.path.basename(current.selectedPath()));
    const persisted = try tmp.dir.readFileAlloc(io, "config.toml", a, .limited(32768));
    defer a.free(persisted);
    try std.testing.expectEqualStrings(try saved.format(&buffer), persisted);
    const stale_key = job.key;
    rotation.sync(Rotation.identity(saved.ui.materials.background, 2), 1, 5, true);
    try std.testing.expect(stale_key != rotation.key);
}

test "background selection detects files and directories instead of trusting the previous mode" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "image.png", .data = red_png });
    const path = try tmp.dir.realPathFileAlloc(io, "image.png", a);
    defer a.free(path);
    var file = try asset.prepare(io, tmp.dir, a, .{ .draft_id = 1, .asset_revision = 1, .path = path, .source = .directory, .detect_source = true }, .{});
    defer file.deinit(a);
    try std.testing.expectEqual(asset.Source.file, file.source);
    var directory = try asset.prepare(io, tmp.dir, a, .{ .draft_id = 1, .asset_revision = 2, .path = std.fs.path.dirname(path).?, .source = .file, .detect_source = true }, .{});
    defer directory.deinit(a);
    try std.testing.expectEqual(asset.Source.directory, directory.source);
    try std.testing.expectEqual(@as(usize, 1), directory.playlist.?.paths.items.len);
}
