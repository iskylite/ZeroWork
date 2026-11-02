//! Isolated updater process/verification fixture. Never installed by production builds.
comptime { _ = @import("crypto.zig"); }
extern fn zw_update_fixture_main() void;
pub fn main() void { zw_update_fixture_main(); }
