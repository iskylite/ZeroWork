const assets = @import("ui_font_assets");
extern fn zw_register_ui_font(bytes: [*]const u8, length: usize) bool;
pub fn register() !void {
    if (!zw_register_ui_font(assets.inter.ptr, assets.inter.len)) return error.InterRegistrationFailed;
    if (!zw_register_ui_font(assets.mono.ptr, assets.mono.len)) return error.MonospaceRegistrationFailed;
}
pub const families: []const []const u8 = &.{ "Inter Variable", "Helvetica Neue" };
