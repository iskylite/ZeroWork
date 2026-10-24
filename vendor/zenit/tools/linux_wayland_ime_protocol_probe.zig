extern "c" fn zenit_ime_protocol_contract() c_int;
extern "c" fn zenit_ime_wrapper_contract(*const fn (*anyopaque, c_int) callconv(.c) c_int) c_int;

fn setSurrounding(handle: *anyopaque, secure: c_int) callconv(.c) c_int {
    var window = @import("wayland_window").Window{ .handle = @ptrCast(handle) };
    return if (secure != 0)
        window.imeSetSurrounding("secret", 6, 6, true)
    else
        window.imeSetSurrounding("A你好", 7, 1, false);
}

pub fn main() !void {
    if (zenit_ime_protocol_contract() != 0) return error.ImeProtocolContractFailed;
    if (zenit_ime_wrapper_contract(&setSurrounding) != 0) return error.ImeWrapperContractFailed;
}
