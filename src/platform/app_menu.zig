extern fn zw_app_menu_apply_branding() void;

/// Apply product names to the framework's native application menu.
/// Call on the UI thread after the macOS application has initialized.
pub fn apply() void {
    zw_app_menu_apply_branding();
}
