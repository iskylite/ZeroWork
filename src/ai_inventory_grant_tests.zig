//! Headless metadata grant tests. No application, host service or data access.
comptime {
    _ = @import("ai/inventory_grants.zig");
    _ = @import("ai/inventory_approval.zig");
}
