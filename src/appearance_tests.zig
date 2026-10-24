//! No-window appearance model, assets and configuration transactions.
test {
    _ = @import("config/theme_registry.zig");
    _ = @import("config/background_asset.zig");
    _ = @import("config/background_geometry.zig");
    _ = @import("background_asset_tests.zig");
    _ = @import("theme_installation_tests.zig");
    _ = @import("appearance_apply_tests.zig");
    _ = @import("appearance_ui_worker_tests.zig");
    _ = @import("config/settings_controller.zig");
}
