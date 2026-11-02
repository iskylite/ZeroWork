//! Borrowed main-thread projection of an existing visible workspace Tab.
//! Consumers copy strings/artwork before the next workspace mutation.
const identity = @import("identity.zig");
pub const Presentation = struct {
    tab_id: identity.TabId,
    order: usize,
    title: []const u8,
    icon_svg: []const u8 = "",
    icon_id: u16 = 0,
    icon_tint: u32 = 0x888888ff,
    current: bool = false,
    status: []const u8 = "",
};
