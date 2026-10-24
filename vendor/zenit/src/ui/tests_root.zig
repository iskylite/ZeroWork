//! Test root for src/ui/core/tests.zig (integration test bundle).
//!
//! Located in src/ui/ so relative @import("../components/...") paths in tests.zig resolve.
//! tests.zig must import the core via @import("../core.zig"), not an unregistered module
//! name such as @import("ui_core"), or its tests are never compiled/run.

test {
    _ = @import("core/counting_allocator.zig");
    _ = @import("core/shaping_cache.zig");
    _ = @import("core/layout_output_table.zig"); // Explicitly discover sparse storage/OOM tests.
    _ = @import("core/tests.zig");
    _ = @import("core/bulk_quad_layer.zig"); // Cx split: BulkQuad layer unit test (refAllDecls won't auto-discover)
    _ = @import("core/render_engine/gpu_draw_shadow.zig");
    _ = @import("core/text_shaper_adapter.zig"); // v0.5 §5 GlyphRun pipeline
    _ = @import("core/a11y_projection.zig"); // a11y projection rules unit test (no longer driven via cx.render)
}

// Named entry keeps the chrome suite discoverable with -Dtest-filter='window chrome'.
test "window chrome imports" {
    _ = @import("core/window_chrome_tests.zig");
}
