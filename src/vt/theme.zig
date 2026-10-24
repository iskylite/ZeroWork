//! Published appearance values. RGBA32 is always 0xRRGGBBAA. The VT owns
//! effective RGB defaults/OSC overrides; selection remains UI decoration.
pub const Theme = struct {
    revision: u64,
    foreground: u32,
    background: u32,
    cursor: u32,
    selection: u32,
    ansi: [16]u32,
};
