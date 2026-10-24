extern "c" fn zenit_scroll_protocol_contract() c_int;
pub fn main() !void {
    if (zenit_scroll_protocol_contract() != 0) return error.ScrollProtocolContractFailed;
}
