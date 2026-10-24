//! Run the Windows SDK backend's mock-window tests on the development host.
const windows = @import("backends/windows.zig");
const std = @import("std");
pub export fn zenit_win_file_dialog(_: *anyopaque, _: c_uint, _: [*:0]const u16, _: [*:0]const u16, _: [*]u8, _: usize) c_int {
    return -4;
}

// The backend's clipboard vtable is present in the mock build, but these
// tests exercise event ordering without a native Win32 clipboard.
pub export fn zenit_win_clipboard_set_text(_: *anyopaque, _: [*]const u8, _: usize) c_int {
    return 0;
}

pub export fn zenit_win_clipboard_probe() u32 {
    return 0;
}
pub export fn zenit_win_clipboard_get_image(_: *anyopaque) c_int {
    return 0;
}
pub export fn zenit_win_clipboard_free_image(_: *anyopaque) void {}
pub export fn zenit_win_clipboard_set_image_png(_: *anyopaque, _: [*]const u8, _: usize) c_int {
    return 0;
}
pub export fn zenit_win_clipboard_get_text_len() c_int {
    return 0;
}
pub export fn zenit_win_clipboard_get_text(_: [*]u8, _: usize) c_int {
    return 0;
}

test {
    std.testing.refAllDecls(windows);
}
