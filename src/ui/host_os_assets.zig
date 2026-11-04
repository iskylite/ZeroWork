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
pub const kylin = source("kylin", 54109);
pub const neokylin = source("neokylin", 54110);
pub const openkylin = source("openkylin", 54111);
pub const ubuntukylin = source("ubuntukylin", 54112);
pub const uos = source("uos", 54113);
pub const deepin = source("deepin", 54114);
pub const openeuler = source("openeuler", 54115);
pub const euleros = source("euleros", 54116);
pub const anolis = source("anolis", 54117);
pub const opencloudos = source("opencloudos", 54118);
pub const tencentos = source("tencentos", 54119);
pub const alinux = source("alinux", 54120);
pub const loongnix = source("loongnix", 54121);
pub const aosc = source("aosc", 54122);
pub const bclinux = source("bclinux", 54123);
pub const kylinsec = source("kylinsec", 54124);
pub const nfs = source("nfs", 54125);
pub const linx = source("linx", 54126);
pub const isoft = source("isoft", 54127);
pub const redflag = source("redflag", 54128);
pub const rhel = source("rhel", 54129);
pub const centos = source("centos", 54130);
pub const almalinux = source("almalinux", 54131);
pub const oraclelinux = source("oraclelinux", 54132);
pub const sles = source("sles", 54133);
pub const opensuse = source("opensuse", 54134);
pub const amazonlinux = source("amazonlinux", 54135);
pub const nixos = source("nixos", 54136);
pub const gentoo = source("gentoo", 54137);
pub const kali = source("kali", 54138);
pub const linuxmint = source("linuxmint", 54139);
pub const manjaro = source("manjaro", 54140);
pub const openbsd = source("openbsd", 54141);
pub const netbsd = source("netbsd", 54142);
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
    @embedFile("assets/host-os/kylin.rgba"),
    @embedFile("assets/host-os/neokylin.rgba"),
    @embedFile("assets/host-os/openkylin.rgba"),
    @embedFile("assets/host-os/ubuntukylin.rgba"),
    @embedFile("assets/host-os/uos.rgba"),
    @embedFile("assets/host-os/deepin.rgba"),
    @embedFile("assets/host-os/openeuler.rgba"),
    @embedFile("assets/host-os/euleros.rgba"),
    @embedFile("assets/host-os/anolis.rgba"),
    @embedFile("assets/host-os/opencloudos.rgba"),
    @embedFile("assets/host-os/tencentos.rgba"),
    @embedFile("assets/host-os/alinux.rgba"),
    @embedFile("assets/host-os/loongnix.rgba"),
    @embedFile("assets/host-os/aosc.rgba"),
    @embedFile("assets/host-os/bclinux.rgba"),
    @embedFile("assets/host-os/kylinsec.rgba"),
    @embedFile("assets/host-os/nfs.rgba"),
    @embedFile("assets/host-os/linx.rgba"),
    @embedFile("assets/host-os/isoft.rgba"),
    @embedFile("assets/host-os/redflag.rgba"),
    @embedFile("assets/host-os/rhel.rgba"),
    @embedFile("assets/host-os/centos.rgba"),
    @embedFile("assets/host-os/almalinux.rgba"),
    @embedFile("assets/host-os/oraclelinux.rgba"),
    @embedFile("assets/host-os/sles.rgba"),
    @embedFile("assets/host-os/opensuse.rgba"),
    @embedFile("assets/host-os/amazonlinux.rgba"),
    @embedFile("assets/host-os/nixos.rgba"),
    @embedFile("assets/host-os/gentoo.rgba"),
    @embedFile("assets/host-os/kali.rgba"),
    @embedFile("assets/host-os/linuxmint.rgba"),
    @embedFile("assets/host-os/manjaro.rgba"),
    @embedFile("assets/host-os/openbsd.rgba"),
    @embedFile("assets/host-os/netbsd.rgba"),
};

/// Selective readability helpers for source-colour artwork. Original pixels
/// remain the source for warning-state alpha masks and logo provenance.
pub const display_pixels = blk: {
    var result = pixels;
    result[index(debian.icon_id.?).?] = @embedFile("assets/host-os/debian-contrast.rgba");
    result[index(alpine.icon_id.?).?] = @embedFile("assets/host-os/alpine-contrast.rgba");
    result[index(freebsd.icon_id.?).?] = @embedFile("assets/host-os/freebsd-contrast.rgba");
    result[index(bclinux.icon_id.?).?] = @embedFile("assets/host-os/bclinux-contrast.rgba");
    result[index(netbsd.icon_id.?).?] = @embedFile("assets/host-os/netbsd-contrast.rgba");
    result[index(redflag.icon_id.?).?] = @embedFile("assets/host-os/redflag-contrast.rgba");
    break :blk result;
};
