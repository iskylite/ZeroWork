const std = @import("std");
extern fn zenit_test_dual_source_signature() c_int;
pub fn main() void {
    std.c.exit(zenit_test_dual_source_signature());
}
