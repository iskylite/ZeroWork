//! Send real WM_ERASEBKGND to the gallery HWND with a private memory DC.
//! The negative control runs Windows' default eraser on that same DC. No
//! desktop pixels are changed and no second App/window is created.
const App = @import("zenit_app").App;
extern "user32" fn SendMessageW(*anyopaque, u32, usize, isize) callconv(.winapi) isize;
extern "user32" fn DefWindowProcW(*anyopaque, u32, usize, isize) callconv(.winapi) isize;
extern "gdi32" fn CreateCompatibleDC(?*anyopaque) callconv(.winapi) ?*anyopaque;
extern "gdi32" fn DeleteDC(*anyopaque) callconv(.winapi) c_int;
extern "gdi32" fn CreateBitmap(c_int, c_int, u32, u32, ?*const anyopaque) callconv(.winapi) ?*anyopaque;
extern "gdi32" fn SelectObject(*anyopaque, *anyopaque) callconv(.winapi) ?*anyopaque;
extern "gdi32" fn DeleteObject(*anyopaque) callconv(.winapi) c_int;
extern "gdi32" fn SetPixel(*anyopaque, c_int, c_int, u32) callconv(.winapi) u32;
extern "gdi32" fn GetPixel(*anyopaque, c_int, c_int) callconv(.winapi) u32;
pub fn run(app: *App) !void {
    const dc = CreateCompatibleDC(null) orelse return error.CreateMemoryDcFailed;
    defer _ = DeleteDC(dc);
    const bitmap = CreateBitmap(8, 8, 1, 32, null) orelse return error.CreateBitmapFailed;
    defer _ = DeleteObject(bitmap);
    const previous = SelectObject(dc, bitmap) orelse return error.SelectBitmapFailed;
    if (@intFromPtr(previous) == ~@as(usize, 0)) return error.SelectBitmapFailed;
    defer _ = SelectObject(dc, previous);
    const owner = app.win.getNativeSurfaceHandle();
    const colour: u32 = 0x00332211;
    if (SetPixel(dc, 4, 4, colour) != colour) return error.SetSentinelFailed;
    if (DefWindowProcW(owner, 0x14, @intFromPtr(dc), 0) == 0 or GetPixel(dc, 4, 4) == colour)
        return error.NegativeControlDidNotErase;
    if (SetPixel(dc, 4, 4, colour) != colour) return error.ResetSentinelFailed;
    if (SendMessageW(owner, 0x14, @intFromPtr(dc), 0) != 1 or GetPixel(dc, 4, 4) != colour)
        return error.GpuWindowBackgroundWasErased;
}
