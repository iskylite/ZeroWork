//! Native clipboard contracts run inside the gallery's owned Windows process.
const std = @import("std");
const App = @import("zenit_app").App;
extern "user32" fn OpenClipboard(?*anyopaque) callconv(.winapi) c_int;
extern "user32" fn GetOpenClipboardWindow() callconv(.winapi) ?*anyopaque;
extern "kernel32" fn GetLastError() callconv(.winapi) u32;
extern "kernel32" fn GetTickCount64() callconv(.winapi) u64;
extern fn zenit_win_contract_clipboard_lock(u32) ?*anyopaque;
extern fn zenit_win_contract_clipboard_unlock(*anyopaque) c_int;
extern fn zenit_win_contract_clipboard_busy_attempts() c_uint;
extern "user32" fn GetForegroundWindow() callconv(.winapi) ?*anyopaque;
extern "user32" fn EmptyClipboard() callconv(.winapi) c_int;
extern "user32" fn CloseClipboard() callconv(.winapi) c_int;
extern "user32" fn SetClipboardData(u32, *anyopaque) callconv(.winapi) ?*anyopaque;
extern "kernel32" fn GlobalAlloc(u32, usize) callconv(.winapi) ?*anyopaque;
extern "kernel32" fn GlobalLock(*anyopaque) callconv(.winapi) ?*anyopaque;
extern "kernel32" fn GlobalUnlock(*anyopaque) callconv(.winapi) c_int;
extern "kernel32" fn GlobalFree(*anyopaque) callconv(.winapi) ?*anyopaque;
extern "gdi32" fn CreateBitmap(c_int, c_int, u32, u32, *const anyopaque) callconv(.winapi) ?*anyopaque;
extern "gdi32" fn DeleteObject(*anyopaque) callconv(.winapi) c_int;
const png = [_]u8{ 137, 80, 78, 71, 13, 10, 26, 10, 0, 0, 0, 13, 73, 72, 68, 82, 0, 0, 0, 2, 0, 0, 0, 2, 8, 6, 0, 0, 0, 114, 182, 13, 36, 0, 0, 0, 22, 73, 68, 65, 84, 120, 156, 99, 248, 207, 192, 240, 31, 8, 27, 24, 64, 116, 133, 205, 22, 7, 0, 58, 29, 6, 37, 218, 114, 79, 209, 0, 0, 0, 0, 73, 69, 78, 68, 174, 66, 96, 130 };
const expected = [_]u8{ 255, 0, 0, 255, 0, 128, 0, 128, 0, 0, 0, 0, 30, 15, 45, 64 };
fn require(ok: bool) !void {
    if (!ok) return error.ClipboardContractFailed;
}
fn contention(app: *App, image: bool, write: bool) !void {
    const before = zenit_win_contract_clipboard_busy_attempts();
    const foreground = GetForegroundWindow();
    const lock = zenit_win_contract_clipboard_lock(50) orelse return error.ClipboardLockFixtureFailed;
    var unlocked = false;
    defer if (!unlocked) {
        _ = zenit_win_contract_clipboard_unlock(lock);
    };
    if (image) {
        if (write) try app.sdk.clipboardSetImagePng(&png) else {
            var result = (try app.sdk.clipboardGetImageAlloc(app.allocator, 0)) orelse return error.MissingImage;
            defer result.deinit(app.allocator);
            try require(std.mem.eql(u8, result.rgba, &expected));
        }
    } else {
        if (write) try app.sdk.clipboardSetText("contention 中文 😀") else {
            const result = (try app.sdk.clipboardGetTextAlloc(app.allocator)) orelse return error.MissingText;
            defer app.allocator.free(result);
            try require(std.mem.eql(u8, result, "contention 中文 😀"));
        }
    }
    try require(zenit_win_contract_clipboard_busy_attempts() > before);
    const closed = zenit_win_contract_clipboard_unlock(lock);
    unlocked = true;
    try require(closed == 1);
    try require(GetForegroundWindow() == foreground);
}
fn setDib(owner: *anyopaque, format: u32, bytes: []const u8) !void {
    const memory = GlobalAlloc(2, bytes.len) orelse return error.OutOfMemory;
    var transferred = false;
    defer if (!transferred) {
        _ = GlobalFree(memory);
    };
    const dest: [*]u8 = @ptrCast(GlobalLock(memory) orelse return error.NativeFailure);
    @memcpy(dest[0..bytes.len], bytes);
    _ = GlobalUnlock(memory);
    try require(OpenClipboard(owner) != 0);
    defer _ = CloseClipboard();
    try require(EmptyClipboard() != 0);
    try require(SetClipboardData(format, memory) != null);
    transferred = true;
}
fn put32(bytes: []u8, offset: usize, value: u32) void {
    std.mem.writeInt(u32, bytes[offset..][0..4], value, .little);
}
fn put16(bytes: []u8, offset: usize, value: u16) void {
    std.mem.writeInt(u16, bytes[offset..][0..2], value, .little);
}
pub fn run(app: *App) !void {
    var stage: []const u8 = "set-text";
    errdefer std.log.err("Windows clipboard stage={s}, last_error={d}, open_window={any}", .{ stage, GetLastError(), GetOpenClipboardWindow() });
    const alloc = app.allocator;
    const sdk = &app.sdk;
    const owner = app.win.getNativeSurfaceHandle();
    const text = "Windows 中文 😀 clipboard";
    try sdk.clipboardSetText(text);
    stage = "read-text";
    const copied = (try sdk.clipboardGetTextAlloc(alloc)) orelse return error.MissingText;
    defer alloc.free(copied);
    try require(std.mem.eql(u8, copied, text));
    var small: [2]u8 = undefined;
    stage = "text-small-buffer";
    if (sdk.clipboardGetText(&small)) |_| return error.ExpectedBufferTooSmall else |err| try require(err == error.BufferTooSmall);
    stage = "text-probe";
    const text_kinds = try sdk.clipboardProbe();
    try require(text_kinds.text and !text_kinds.image and try sdk.clipboardImageCount() == 0);
    try require(try sdk.clipboardGetImageAlloc(alloc, 0) == null);

    stage = "set-png";
    try sdk.clipboardSetImagePng(&png);
    stage = "png-probe";
    const kinds = try sdk.clipboardProbe();
    try require(kinds.image and !kinds.text and try sdk.clipboardImageCount() == 1);
    stage = "read-png";
    var image = (try sdk.clipboardGetImageAlloc(alloc, 0)) orelse return error.MissingImage;
    defer image.deinit(alloc);
    try require(image.width == 2 and image.height == 2 and std.mem.eql(u8, image.rgba, &expected));
    try require(std.mem.eql(u8, image.raw_bytes orelse return error.MissingRaw, &png));
    try require(std.mem.eql(u8, image.uti orelse return error.MissingUti, "public.png"));
    try require(try sdk.clipboardGetImageAlloc(alloc, 1) == null);
    // Invalid PNG must fail before clearing a previously valid clipboard.
    stage = "invalid-png";
    if (sdk.clipboardSetImagePng("bad png")) |_| return error.ExpectedInvalidPng else |_| {}
    if (sdk.clipboardSetImagePng(png[0..40])) |_| return error.ExpectedTruncatedPng else |_| {}
    stage = "read-preserved-png";
    var preserved = (try sdk.clipboardGetImageAlloc(alloc, 0)) orelse return error.LostImage;
    defer preserved.deinit(alloc);
    try require(std.mem.eql(u8, preserved.rgba, &expected));

    var dibv5 = @as([140]u8, @splat(0));
    put32(&dibv5, 0, 124);
    put32(&dibv5, 4, 2);
    put32(&dibv5, 8, @bitCast(@as(i32, -2)));
    put16(&dibv5, 12, 1);
    put16(&dibv5, 14, 32);
    put32(&dibv5, 16, 3);
    put32(&dibv5, 20, 16);
    put32(&dibv5, 40, 0xff0000);
    put32(&dibv5, 44, 0xff00);
    put32(&dibv5, 48, 0xff);
    put32(&dibv5, 52, 0xff000000);
    put32(&dibv5, 56, 0x73524742);
    @memcpy(dibv5[124..], &[_]u8{ 0, 0, 255, 255, 0, 255, 0, 128, 255, 0, 0, 0, 180, 60, 120, 64 });
    stage = "set-dibv5";
    try setDib(owner, 17, &dibv5);
    stage = "read-dibv5";
    var dib_image = (try sdk.clipboardGetImageAlloc(alloc, 0)) orelse return error.MissingDib;
    defer dib_image.deinit(alloc);
    try require(std.mem.eql(u8, dib_image.rgba, &expected) and dib_image.raw_bytes == null);

    var dib24 = @as([48]u8, @splat(0));
    put32(&dib24, 0, 40);
    put32(&dib24, 4, 2);
    put32(&dib24, 8, 1);
    put16(&dib24, 12, 1);
    put16(&dib24, 14, 24);
    put32(&dib24, 20, 8);
    @memcpy(dib24[40..], &[_]u8{ 0, 0, 255, 0, 255, 0, 0, 0 });
    stage = "set-dib24";
    try setDib(owner, 8, &dib24);
    stage = "read-dib24";
    var dib24_image = (try sdk.clipboardGetImageAlloc(alloc, 0)) orelse return error.MissingDib24;
    defer dib24_image.deinit(alloc);
    try require(dib24_image.width == 2 and dib24_image.height == 1 and std.mem.eql(u8, dib24_image.rgba, &[_]u8{ 255, 0, 0, 255, 0, 255, 0, 255 }));
    // A truncated external DIB must report failure, never return partial pixels.
    stage = "invalid-dib";
    try setDib(owner, 17, dibv5[0..20]);
    if (sdk.clipboardGetImageAlloc(alloc, 0)) |_| return error.ExpectedInvalidDib else |_| {}

    stage = "set-bitmap";
    const pixels = [_]u8{ 0, 0, 255, 0, 0, 255, 0, 0 };
    const bitmap = CreateBitmap(2, 1, 1, 32, &pixels) orelse return error.BitmapCreationFailed;
    var transferred = false;
    defer if (!transferred) {
        _ = DeleteObject(bitmap);
    };
    try require(OpenClipboard(owner) != 0);
    const ok = EmptyClipboard() != 0 and SetClipboardData(2, bitmap) != null;
    _ = CloseClipboard();
    transferred = ok;
    try require(ok);
    stage = "read-bitmap";
    var bitmap_image = (try sdk.clipboardGetImageAlloc(alloc, 0)) orelse return error.MissingBitmap;
    defer bitmap_image.deinit(alloc);
    try require(bitmap_image.width == 2 and bitmap_image.height == 1 and std.mem.eql(u8, bitmap_image.rgba, &[_]u8{ 255, 0, 0, 255, 0, 255, 0, 255 }));
    stage = "final-set-text";
    try sdk.clipboardSetText(text);
    stage = "final-probe";
    try require(!(try sdk.clipboardProbe()).image);

    stage = "text-write-contention";
    try contention(app, false, true);
    stage = "text-read-contention";
    try contention(app, false, false);
    stage = "png-write-contention";
    try contention(app, true, true);
    stage = "png-read-contention";
    try contention(app, true, false);

    stage = "persistent-contention";
    const lock = zenit_win_contract_clipboard_lock(0) orelse return error.ClipboardLockFixtureFailed;
    {
        var unlocked = false;
        defer if (!unlocked) {
            _ = zenit_win_contract_clipboard_unlock(lock);
        };
        var timer = try @import("zenit_time").Timer.start(app.cx.io);
        const started = GetTickCount64();
        if (sdk.clipboardSetText("must not overwrite locked PNG")) |_| return error.ExpectedBusyFailure else |err| try require(err == error.BackendFailure);
        const elapsed = timer.read();
        try require(GetTickCount64() - started >= 100 and elapsed < 500 * std.time.ns_per_ms);
        const closed = zenit_win_contract_clipboard_unlock(lock);
        unlocked = true;
        try require(closed == 1);
    }
    stage = "persistent-lock-preserved-png";
    var after_busy = (try sdk.clipboardGetImageAlloc(alloc, 0)) orelse return error.LostImage;
    defer after_busy.deinit(alloc);
    try require(std.mem.eql(u8, after_busy.rgba, &expected));
    std.log.info("Windows clipboard contention: text/PNG read/write recover after held lock; persistent lock bounded and image preserved PASS", .{});
}
