const metadata = @import("application_options");
extern fn zw_app_menu_apply_branding([*:0]const u8) void;

/// Apply product names to the framework's native application menu.
/// Call on the UI thread after the macOS application has initialized.
pub fn apply() void {
    zw_app_menu_apply_branding(metadata.version_metadata ++ "\x00");
}
