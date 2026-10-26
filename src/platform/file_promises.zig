//! Main-thread API for native Finder download promises. Unit tests never start
//! system drag sessions; native runtime returns failure for missing pointer events.
const builtin = @import("builtin");
extern fn zw_file_promises_begin(u32, [*]const [*:0]const u8, usize, f32, f32) u64;
extern fn zw_file_promises_poll(u64, *u32, [*]u8, usize) c_int;
extern fn zw_file_promises_status(u64) c_int;
extern fn zw_file_promises_complete(u64, u32, ?[*:0]const u8) c_int;
extern fn zw_file_promises_release(u64) void;
pub fn begin(window: u32, names: []const [*:0]const u8, x: f32, y: f32) u64 {
    if (builtin.is_test) return 0;
    return zw_file_promises_begin(window, names.ptr, names.len, x, y);
}
pub fn poll(token: u64, index: *u32, path: []u8) c_int {
    if (builtin.is_test) return -1;
    return zw_file_promises_poll(token, index, path.ptr, path.len);
}
pub fn status(token: u64) c_int {
    if (builtin.is_test) return -1;
    return zw_file_promises_status(token);
}
pub fn complete(token: u64, index: u32, staged_path: ?[*:0]const u8) bool {
    if (builtin.is_test) return false;
    return zw_file_promises_complete(token, index, staged_path) != 0;
}
pub fn release(token: u64) void {
    if (!builtin.is_test) zw_file_promises_release(token);
}
