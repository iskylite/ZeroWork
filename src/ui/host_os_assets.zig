//! Saved-host source SVGs and 72px RGBA derivatives. See assets/host-os/README.md.
//! Geometry is only a temporary fallback before the window renderer is ready.
const ui = @import("ui");
const fallback = @import("session_os_assets.zig").linux;
fn source(comptime name: []const u8, comptime id: u16) ui.SvgAsset {
    var value = fallback;
    value.icon_id = id;
    value.svg_data = @embedFile("assets/host-os/" ++ name ++ ".svg");
    return value;
}
pub const alpine = source("alpine", 54100);
pub const archlinux = source("archlinux", 54101);
pub const debian = source("debian", 54102);
pub const fedora = source("fedora", 54103);
pub const freebsd = source("freebsd", 54104);
pub const linux = source("linux", 54105);
pub const ubuntu = source("ubuntu", 54106);
pub const windows = source("windows", 54107);
pub const rocky = source("rocky", 54108);
pub fn index(id: u32) ?usize {
    return if (id >= 54100 and id < 54100 + pixels.len) @intCast(id - 54100) else null;
}
pub const pixels = [_][]const u8{
    @embedFile("assets/host-os/alpine.rgba"),
    @embedFile("assets/host-os/archlinux.rgba"),
    @embedFile("assets/host-os/debian.rgba"),
    @embedFile("assets/host-os/fedora.rgba"),
    @embedFile("assets/host-os/freebsd.rgba"),
    @embedFile("assets/host-os/linux.rgba"),
    @embedFile("assets/host-os/ubuntu.rgba"),
    @embedFile("assets/host-os/windows.rgba"),
    @embedFile("assets/host-os/rocky.rgba"),
};
