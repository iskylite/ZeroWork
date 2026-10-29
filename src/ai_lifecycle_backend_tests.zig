//! Standalone lifecycle backend regression root (no native UI launch).
test {
    _ = @import("ai/host_lifecycle.zig");
    _ = @import("ai/lifecycle_runtime.zig");
}
