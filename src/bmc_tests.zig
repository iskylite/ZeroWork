//! Isolated V0.3 public seam and protocol tests; no user credentials or BMC IO.
comptime {
    _ = @import("plugins/bmc_ikvm/input_mapping.zig");
    _ = @import("bmc_security_tests.zig");
    _ = @import("bmc_frame_input_tests.zig");
    _ = @import("bmc_wire_tests.zig");
    _ = @import("bmc_rfb_tests.zig");
    _ = @import("bmc_management_tests.zig");
    _ = @import("bmc_probe_access_tests.zig");
    _ = @import("bmc_credential_gc_tests.zig");
    _ = @import("plugins/bmc_ikvm/route.zig");
    _ = @import("bmc_controller_tests.zig");
    _ = @import("bmc_native_driver_tests.zig");
    _ = @import("bmc_plugin_probe_tests.zig");
    _ = @import("bmc_plugin_runtime_tests.zig");
    _ = @import("bmc_view_tests.zig");
    _ = @import("bmc_editor_tests.zig");
    _ = @import("bmc_editor_capability_tests.zig");
    _ = @import("bmc_bootstrap_tests.zig");
    _ = @import("bmc_composition_tests.zig");
    _ = @import("bmc_explicit_input_tests.zig");
    _ = @import("bmc_live_backend_tests.zig");
    _ = @import("bmc_connection_progress_tests.zig");
    _ = @import("bmc_ai_observation_tests.zig");
    _ = @import("bmc_ai_input_tests.zig");
    _ = @import("bmc_ai_tool_tests.zig");
    _ = @import("ui/plugin_window_host.zig");
}
