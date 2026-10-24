//! Entry point for the independent native D3D11 resource acceptance.
const std = @import("std");
extern fn zenit_d11_test_contract() c_int;

pub fn main() void {
    std.c.exit(zenit_d11_test_contract());
}
