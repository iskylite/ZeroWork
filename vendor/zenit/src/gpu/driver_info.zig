/// Identity of the selected adapter. Unknown driver versions are explicit.
pub const DriverInfo = struct {
    vendor_id: u32 = 0,
    device_id: u32 = 0,
    driver_version: ?[4]u16 = null,
    software: bool = false,
};
