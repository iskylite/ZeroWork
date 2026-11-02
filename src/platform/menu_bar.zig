//! AppKit menu bar boundary; all functions are main-thread only.
const assets = @import("app_icon_assets");
extern fn zw_menu_bar_start([*]const u8, usize) bool;
extern fn zw_menu_bar_set_action_handler(*anyopaque, *const fn (*anyopaque, u64) callconv(.c) void) void;
extern fn zw_menu_bar_stop() void;
extern fn zw_menu_bar_active() bool;
extern fn zw_menu_bar_update(u64) void;
extern fn zw_menu_bar_add_session(u64, [*]const u8, usize, [*]const u8, usize, u32, bool, [*]const u8, usize) void;
extern fn zw_menu_bar_finish() void;
extern fn zw_menu_bar_take_action() u64;
pub fn start() bool {
    return zw_menu_bar_start(assets.transparent.ptr, assets.transparent.len);
}
pub fn addSession(token: u64, item: @import("../host/tab_presentation.zig").Presentation) void {
    zw_menu_bar_add_session(token, item.title.ptr, item.title.len, item.icon_svg.ptr, item.icon_svg.len, item.icon_tint, item.current, item.status.ptr, item.status.len);
}
pub const setActionHandler = zw_menu_bar_set_action_handler;
pub const stop = zw_menu_bar_stop;
pub const active = zw_menu_bar_active;
pub const update = zw_menu_bar_update;
pub const finish = zw_menu_bar_finish;
pub const takeAction = zw_menu_bar_take_action;

extern fn zw_menu_bar_snapshot([*]u8, usize) usize;
pub fn testSnapshot(buffer: []u8) ?[]const u8 {
    if (!@import("zenit_app").test_harness.enabled) return null;
    const length = zw_menu_bar_snapshot(buffer.ptr, buffer.len);
    return if (length == 0) null else buffer[0..length];
}
