//! Fault controls and ownership counters compile out of production builds.
pub const enabled = @import("builtin").is_test or @import("build_options").test_mode;

// Native fault state is only referenced by builtin.is_test branches. No Device
// or Buffer layout changes, including application test-mode builds.
pub var fail_buffer_device: ?*anyopaque = null;
pub var buffer_destroy_count: usize = 0;
