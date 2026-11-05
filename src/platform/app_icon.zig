const config = @import("../config/config.zig");
const assets = @import("app_icon_assets");
extern fn zw_app_icon_apply(bytes: [*]const u8, length: usize) bool;
var applied: ?config.IconBackground = null;

/// Running Dock tile and persistent application file icon; UI thread only.
pub fn apply(background: config.IconBackground) bool {
    if (applied == background) return true;
    const bytes = switch (background) {
        .transparent => assets.transparent,
        .light => assets.light,
        .dark => assets.dark,
    };
    if (!zw_app_icon_apply(bytes.ptr, bytes.len)) return false;
    applied = background;
    return true;
}
