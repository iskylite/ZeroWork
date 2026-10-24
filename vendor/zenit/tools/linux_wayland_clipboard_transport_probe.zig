extern "c" fn zenit_clipboard_transport_contract() c_int;

pub fn main() !void {
    if (zenit_clipboard_transport_contract() != 0) return error.ClipboardTransportContractFailed;
}
