//! Dedicated headless regression entry; no model or network requests.
test {
    _ = @import("ai/wire_history.zig");
    _ = @import("ai/assistant_store.zig");
    _ = @import("ai/provider_json.zig");
}
