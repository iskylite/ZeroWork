const std = @import("std");
const assets = @import("plugins/notes/assets.zig");
const Store = @import("plugins/notes/store.zig").Store;
const Mime = @import("ai/image_attachments.zig").Mime;
const a = std.testing.allocator;
const io = std.testing.io;
const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;
const expectEqualSlices = std.testing.expectEqualSlices;
const expectEqualStrings = std.testing.expectEqualStrings;
const expectError = std.testing.expectError;

const red_png = "\x89PNG\r\n\x1a\n\x00\x00\x00\x0dIHDR" ++
    "\x00\x00\x00\x01\x00\x00\x00\x01\x08\x06\x00\x00\x00\x1f\x15\xc4\x89" ++
    "\x00\x00\x00\x0dIDAT\x78\x9c\x63\xf8\xcf\xc0\xf0\x1f\x00\x05\x00\x01\xff\x89\x99\x3d\x1d" ++
    "\x00\x00\x00\x00IEND\xae\x42\x60\x82";

const gray_jpeg = "\xff\xd8\xff\xdb\x00\x43\x00" ++ @as([64]u8, @splat(0x10)) ++
    "\xff\xc0\x00\x0b\x08\x00\x01\x00\x01\x01\x01\x11\x00" ++
    "\xff\xc4\x00\x14\x00\x01" ++ @as([16]u8, @splat(0)) ++
    "\xff\xc4\x00\x14\x10\x01" ++ @as([16]u8, @splat(0)) ++
    "\xff\xda\x00\x08\x01\x01\x00\x00\x3f\x00\x3f\xff\xd9";

const animated_gif = "GIF89a\x01\x00\x01\x00\x80\x00\x00\x00\x00\x00\xff\x00\x00" ++
    "\x21\xf9\x04\x00\x01\x00\x00\x00\x2c\x00\x00\x00\x00\x01\x00\x01\x00\x00\x02\x02\x4c\x01\x00" ++
    "\x21\xf9\x04\x00\x01\x00\x00\x00\x2c\x00\x00\x00\x00\x01\x00\x01\x00\x00\x02\x02\x44\x01\x00\x3b";

const red_bmp = "BM\x3a\x00\x00\x00\x00\x00\x00\x00\x36\x00\x00\x00" ++
    "\x28\x00\x00\x00\x01\x00\x00\x00\x01\x00\x00\x00\x01\x00\x18\x00" ++
    "\x00\x00\x00\x00\x04\x00\x00\x00" ++ @as([16]u8, @splat(0)) ++
    "\x00\x00\xff\x00";

// Uncompressed one-pixel RGB screenshot representation.
const red_tiff = "II\x2a\x00\x08\x00\x00\x00\x0a\x00" ++
    "\x00\x01\x04\x00\x01\x00\x00\x00\x01\x00\x00\x00" ++
    "\x01\x01\x04\x00\x01\x00\x00\x00\x01\x00\x00\x00" ++
    "\x02\x01\x03\x00\x03\x00\x00\x00\x86\x00\x00\x00" ++
    "\x03\x01\x03\x00\x01\x00\x00\x00\x01\x00\x00\x00" ++
    "\x06\x01\x03\x00\x01\x00\x00\x00\x02\x00\x00\x00" ++
    "\x11\x01\x04\x00\x01\x00\x00\x00\x8c\x00\x00\x00" ++
    "\x15\x01\x03\x00\x01\x00\x00\x00\x03\x00\x00\x00" ++
    "\x16\x01\x04\x00\x01\x00\x00\x00\x01\x00\x00\x00" ++
    "\x17\x01\x04\x00\x01\x00\x00\x00\x03\x00\x00\x00" ++
    "\x1c\x01\x03\x00\x01\x00\x00\x00\x01\x00\x00\x00" ++
    "\x00\x00\x00\x00\x08\x00\x08\x00\x08\x00\xff\x00\x00";

// A synthetic 16×16 raster encoded with the macOS ImageIO HEIC writer.
const red_heic_base64 = "AAAAJGZ0eXBoZWljAAAAAG1pZjFNaVBybWlhZk1pSEJoZWljAAABhm1ldGEAAAAAAAAAIWhkbHIA" ++
    "AAAAAAAAAHBpY3QAAAAAAAAAAAAAAAAAAAAAJGRpbmYAAAAcZHJlZgAAAAAAAAABAAAADHVybCAA" ++
    "AAABAAAADnBpdG0AAAAAAAEAAAAjaWluZgAAAAAAAQAAABVpbmZlAgAAAAABAABodmMxAAAAAOZp" ++
    "cHJwAAAAxWlwY28AAAATY29scm5jbHgAAgACAAaAAAAADGNsbGkAywBAAAAAFGlzcGUAAAAAAAAA" ++
    "EAAAABAAAAAJaXJvdAAAAAAQcGl4aQAAAAADCAgIAAAAcWh2Y0MBA3AAAACwAAAAAAAe8AD8/fj4" ++
    "AAALA6AAAQAXQAEMAf//A3AAAAMAsAAAAwAAAwAecCShAAEAI0IBAQNwAAADALAAAAMAAAMAHqAU" ++
    "IEHAkwziHuRZVNwICBgCogABAAlEAcBhcshAUyQAAAAZaXBtYQAAAAAAAAABAAEGgQIDBYaEAAAA" ++
    "Hmlsb2MAAAAARAAAAQABAAAAAQAAAboAAAA/AAAAAW1kYXQAAAAAAAAATwAAADsoAa+i+kaBfP/9" ++
    "2s//9uX7L9AKPVf/tCfI+buy/6ZQ90yyZ/og+cI53hzw5nPv9uVCL2FfgrcISbIrgA==";

test "notes assets publish verified original PNG and JPEG under private library directories" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var store = try Store.init(a, io, tmp.dir);
    defer store.deinit();
    const library = try store.createLibrary("值班手册");
    const other = try store.createLibrary("另一资料库");
    var cancel: assets.CancelToken = .{};

    const photo = try assets.importBytes(a, &store, library, red_png, &cancel, .{});
    const duplicate = try assets.importBytes(a, &store, library, red_png, &cancel, .{});
    try expectEqualStrings(photo.relativePath(), duplicate.relativePath());
    try expectEqual(@as(u32, 1), photo.width);
    try expectEqual(@as(u32, 1), photo.height);
    const markdown = "![报警示例](" ++ photo.path ++ ")";
    try expectError(error.FileNotFound, assets.readReferenced(a, &store, other, markdown, photo.relativePath(), &cancel, .{}));
    const other_photo = try assets.importBytes(a, &store, other, red_png, &cancel, .{});
    try expectEqualStrings(photo.relativePath(), other_photo.relativePath());
    var raster = try assets.readReferenced(a, &store, library, markdown, photo.relativePath(), &cancel, .{});
    defer raster.release();
    try expectError(error.ImageTooLarge, assets.readReferenced(a, &store, library, markdown, photo.relativePath(), &cancel, .{ .bytes = red_png.len - 1 }));
    try expectEqualStrings(red_png, raster.content().?.bytes);
    try expectEqualStrings(photo.relativePath(), raster.content().?.path);
    try expectEqualSlices(u8, &.{ 255, 0, 0, 255 }, raster.content().?.pixels);

    try tmp.dir.writeFile(io, .{ .sub_path = "selected.jpg", .data = gray_jpeg });
    const selected = try tmp.dir.realPathFileAlloc(io, "selected.jpg", a);
    defer a.free(selected);
    const imported = try assets.importFile(a, &store, library, selected, &cancel, .{});
    try expect(std.mem.endsWith(u8, imported.relativePath(), ".jpg"));
    var jpeg = try assets.readReferenced(a, &store, library, "![](" ++ imported.path ++ ")", imported.relativePath(), &cancel, .{});
    defer jpeg.release();
    try expectEqual(Mime.jpeg, jpeg.content().?.mime);
    try expectEqualStrings(gray_jpeg, jpeg.content().?.bytes);

    const dir_path = "notes/libraries/" ++ std.fmt.bytesToHex(library.bytes, .lower) ++ "/assets";
    const directory = try tmp.dir.openDir(io, dir_path, .{ .iterate = true });
    defer directory.close(io);
    var entries = directory.iterate();
    var count: usize = 0;
    while (try entries.next(io)) |_| count += 1;
    try expectEqual(@as(usize, 2), count);
    try expectEqual(@as(std.posix.mode_t, 0o700), (try directory.stat(io)).permissions.toMode() & 0o777);
    const photo_stat = try directory.statFile(io, photo.relativePath()["assets/".len..], .{ .follow_symlinks = false });
    try expectEqual(@as(std.posix.mode_t, 0o600), photo_stat.permissions.toMode() & 0o777);
}

test "notes assets normalize the first animation frame and reject invalid or oversize input before writing" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var store = try Store.init(a, io, tmp.dir);
    defer store.deinit();
    const library = try store.createLibrary("截图");
    var cancel: assets.CancelToken = .{};

    try expectError(error.UnsupportedImage, assets.importBytes(a, &store, library, "not a picture", &cancel, .{}));
    try expectError(error.InvalidImage, assets.importBytes(a, &store, library, red_png[0..32], &cancel, .{}));
    try expectError(error.ImageTooLarge, assets.importBytes(a, &store, library, red_png, &cancel, .{ .bytes = red_png.len - 1 }));
    try expectError(error.ImageTooLarge, assets.importBytes(a, &store, library, red_png, &cancel, .{ .pixels = 0 }));
    var stopped: assets.CancelToken = .{};
    stopped.cancel();
    try expectError(error.Cancelled, assets.importBytes(a, &store, library, red_png, &stopped, .{}));

    const lib = try store.openLibrary(library);
    defer lib.close(io);
    try expectError(error.FileNotFound, lib.openDir(io, "assets", .{}));
    const image = try assets.importBytes(a, &store, library, animated_gif, &cancel, .{});
    try expect(std.mem.endsWith(u8, image.relativePath(), ".png"));
    var reference = try assets.readReferenced(a, &store, library, "![](" ++ image.path ++ ")", image.relativePath(), &cancel, .{});
    defer reference.release();
    try expectEqual(Mime.png, reference.content().?.mime);
    try expectEqualSlices(u8, &.{ 255, 0, 0, 255 }, reference.content().?.pixels);
}

test "notes clipboard normalizes TIFF bytes and Finder rasters after bounded verification" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var store = try Store.init(a, io, tmp.dir);
    defer store.deinit();
    const library = try store.createLibrary("剪贴板图片");
    var cancel: assets.CancelToken = .{};

    try tmp.dir.writeFile(io, .{ .sub_path = "伪装图片.PNG", .data = "not a picture" });
    const spoof = try tmp.dir.realPathFileAlloc(io, "伪装图片.PNG", a);
    defer a.free(spoof);
    try expectError(error.UnsupportedImage, assets.importFile(a, &store, library, spoof, &cancel, .{}));
    const lib = try store.openLibrary(library);
    defer lib.close(io);
    try expectError(error.FileNotFound, lib.openDir(io, "assets", .{}));

    try tmp.dir.writeFile(io, .{ .sub_path = "示例 图.BMP", .data = red_bmp });
    const selected = try tmp.dir.realPathFileAlloc(io, "示例 图.BMP", a);
    defer a.free(selected);
    try expectError(error.ImageTooLarge, assets.importFile(a, &store, library, selected, &cancel, .{ .bytes = red_bmp.len - 1 }));
    const result = try assets.importFile(a, &store, library, selected, &cancel, .{});
    try expect(std.mem.endsWith(u8, result.relativePath(), ".png"));
    var reference = try assets.readReferenced(a, &store, library, "![](" ++ result.path ++ ")", result.relativePath(), &cancel, .{});
    defer reference.release();
    try expectEqualSlices(u8, &.{ 255, 0, 0, 255 }, reference.content().?.pixels);

    const screenshot = try assets.importBytes(a, &store, library, red_tiff, &cancel, .{});
    try expect(std.mem.endsWith(u8, screenshot.relativePath(), ".png"));
    var screenshot_image = try assets.readReferenced(a, &store, library, "![](" ++ screenshot.path ++ ")", screenshot.relativePath(), &cancel, .{});
    defer screenshot_image.release();
    try expectEqualSlices(u8, &.{ 255, 0, 0, 255 }, screenshot_image.content().?.pixels);

    var heic: [505]u8 = undefined;
    try std.base64.standard.Decoder.decode(&heic, red_heic_base64);
    const converted = try assets.importBytes(a, &store, library, &heic, &cancel, .{});
    try expect(std.mem.endsWith(u8, converted.relativePath(), ".png"));
    try expectEqual(@as(u32, 16), converted.width);
    try expectEqual(@as(u32, 16), converted.height);
}

test "notes assets accept only canonical independent image blocks and ignore opaque text" {
    const png_path = "assets/" ++ @as([64]u8, @splat('a')) ++ ".png";
    const jpg_path = "assets/" ++ @as([64]u8, @splat('b')) ++ ".jpg";
    const ignored = "assets/" ++ @as([64]u8, @splat('c')) ++ ".png";
    const markdown = "![正常 [说明]](" ++ png_path ++ ")\r\n" ++
        " ![重复](" ++ png_path ++ ")\n" ++
        "  ![括号\\]](" ++ jpg_path ++ ") \t\n" ++
        "~~~md\n![围栏](" ++ ignored ++ ")\n~~~\n" ++
        "````\n```\n![围栏](" ++ ignored ++ ")\n````\n" ++
        "<!--\n![注释](" ++ ignored ++ ")\n-->\n" ++
        "    ![缩进代码](" ++ ignored ++ ")\n" ++
        "[普通链接](" ++ ignored ++ ")\n" ++
        "![外链](https://example.org/image.png)\n" ++
        "![越界](../" ++ ignored ++ ")\n" ++
        "![假扩展](assets/" ++ @as([64]u8, @splat('d')) ++ ".gif)\n" ++
        "![大小写](assets/" ++ @as([64]u8, @splat('E')) ++ ".png)\n" ++
        "![转义路径](assets/" ++ @as([61]u8, @splat('f')) ++ "%2f.png)\n";
    const found = try assets.references(a, markdown);
    defer a.free(found);
    try expectEqual(@as(usize, 2), found.len);
    try expectEqualStrings(png_path, found[0]);
    try expectEqualStrings(jpg_path, found[1]);
    try expect(!assets.isReferenced(markdown, ignored));
    try expect(assets.isReferenced(markdown, jpg_path));
    try expect(assets.parseImageLine("![](" ++ png_path ++ ")").?.alt.len == 0);
}

test "notes assets refuse unreferenced, replaced, and redirected assets" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var store = try Store.init(a, io, tmp.dir);
    defer store.deinit();
    const library = try store.createLibrary("安全验证");
    var cancel: assets.CancelToken = .{};
    const imported = try assets.importBytes(a, &store, library, red_png, &cancel, .{});
    const relative_path = imported.relativePath();
    const markdown = "![原图](" ++ imported.path ++ ")";
    try expectError(error.UnreferencedAsset, assets.readReferenced(a, &store, library, "这篇没有图片", relative_path, &cancel, .{}));
    try expectError(error.InvalidAssetReference, assets.readReferenced(a, &store, library, markdown, "../outside.png", &cancel, .{}));

    const lib = try store.openLibrary(library);
    defer lib.close(io);
    try lib.writeFile(io, .{ .sub_path = relative_path, .data = gray_jpeg });
    try expectError(error.InvalidAsset, assets.readReferenced(a, &store, library, markdown, relative_path, &cancel, .{}));
    try expectError(error.InvalidAsset, assets.importBytes(a, &store, library, red_png, &cancel, .{}));

    try lib.deleteFile(io, relative_path);
    try lib.writeFile(io, .{ .sub_path = "outside.png", .data = red_png });
    try lib.symLink(io, "../outside.png", relative_path, .{});
    try expectError(error.NotRegularImage, assets.readReferenced(a, &store, library, markdown, relative_path, &cancel, .{}));
    try expectError(error.NotRegularImage, assets.importBytes(a, &store, library, red_png, &cancel, .{}));
    try lib.rename("assets", lib, "outside_assets", io);
    try lib.symLink(io, "outside_assets", "assets", .{ .is_directory = true });
    if (assets.readReferenced(a, &store, library, markdown, relative_path, &cancel, .{})) |value| {
        var image = value;
        image.release();
        return error.FollowedAssetDirectorySymlink;
    } else |err| {
        try expect(err == error.SymLinkLoop or err == error.NotDir);
    }
}

fn failPublish(_: ?*anyopaque, _: std.Io.Dir, _: []const u8, _: std.Io.Dir, _: []const u8) std.Io.Dir.RenamePreserveError!void {
    return error.AccessDenied;
}

test "notes assets discard temporary bytes on atomic publish failure and allow retry" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var store = try Store.init(a, io, tmp.dir);
    defer store.deinit();
    const library = try store.createLibrary("保存重试");
    var cancel: assets.CancelToken = .{};

    var broken = io.vtable.*;
    broken.dirRenamePreserve = failPublish;
    store.io.vtable = &broken;
    try expectError(error.AccessDenied, assets.importBytes(a, &store, library, red_png, &cancel, .{}));
    store.io = io;
    const lib = try store.openLibrary(library);
    defer lib.close(io);
    const assets_dir = try lib.openDir(io, "assets", .{ .iterate = true });
    defer assets_dir.close(io);
    var entries = assets_dir.iterate();
    try expect((try entries.next(io)) == null);

    const imported = try assets.importBytes(a, &store, library, red_png, &cancel, .{});
    var reference = try assets.readReferenced(a, &store, library, "![](" ++ imported.path ++ ")", imported.relativePath(), &cancel, .{});
    defer reference.release();
    try expectEqualStrings(red_png, reference.content().?.bytes);
    _ = try store.changeLibrary(library, 1, .delete);
    try expectError(error.Unavailable, assets.readReferenced(a, &store, library, "![](" ++ imported.path ++ ")", imported.relativePath(), &cancel, .{}));
}
