//! Headless opt-in acceptance for the production AI provider and tool loop.
test {
    _ = @import("ai/plugin_gateway_live_tests.zig");
    _ = @import("config/config.zig");
}
