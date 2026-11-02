comptime {
    _ = @import("crypto.zig");
}
extern fn zw_update_helper_main() void;
pub fn main() void {
    zw_update_helper_main();
}
