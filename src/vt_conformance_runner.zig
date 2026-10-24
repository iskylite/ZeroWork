// Keep the module root at src/ so the shared VT's typed host identities are
// available to the same adapter used by the application.
pub const main = @import("vt/conformance_cli.zig").main;
