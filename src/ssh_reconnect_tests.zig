//! Reconnection controller and original-pane integration. No native window.
test {
    _ = @import("vt/reconnect.zig");
    _ = @import("host/session_host.zig");
    _ = @import("ui/application_host.zig");
    _ = @import("ui/workspace.zig");
    _ = @import("ssh_resource_ledger_tests.zig");
}
