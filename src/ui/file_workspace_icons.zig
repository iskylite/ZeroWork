//! Same Material Icon Theme subset as docs/UI_V3/assets/file-icons (MIT).
//! Source and full license remain in that directory. These embedded SVG bytes
//! preserve the reference colors; they are content, not theme-tinted chrome.
const std = @import("std");
pub fn kind(name: []const u8) []const u8 {
    const ext = std.fs.path.extension(name);
    if (std.ascii.eqlIgnoreCase(ext, ".md") or std.ascii.eqlIgnoreCase(ext, ".mdx")) return "markdown";
    if (std.ascii.eqlIgnoreCase(ext, ".json") or std.ascii.eqlIgnoreCase(ext, ".jsonc")) return "json";
    if (std.ascii.eqlIgnoreCase(ext, ".yaml") or std.ascii.eqlIgnoreCase(ext, ".yml")) return "yaml";
    if (std.ascii.eqlIgnoreCase(ext, ".toml") or std.ascii.eqlIgnoreCase(ext, ".ini") or std.ascii.eqlIgnoreCase(ext, ".conf")) return "settings";
    if (std.ascii.eqlIgnoreCase(ext, ".zig")) return "zig";
    if (std.ascii.eqlIgnoreCase(ext, ".js") or std.ascii.eqlIgnoreCase(ext, ".mjs") or std.ascii.eqlIgnoreCase(ext, ".cjs")) return "javascript";
    if (std.ascii.eqlIgnoreCase(ext, ".ts") or std.ascii.eqlIgnoreCase(ext, ".tsx")) return "typescript";
    if (std.ascii.eqlIgnoreCase(ext, ".html") or std.ascii.eqlIgnoreCase(ext, ".htm")) return "html";
    if (std.ascii.eqlIgnoreCase(ext, ".css") or std.ascii.eqlIgnoreCase(ext, ".scss")) return "css";
    if (std.ascii.eqlIgnoreCase(ext, ".log")) return "log";
    if (std.ascii.eqlIgnoreCase(ext, ".gz") or std.ascii.eqlIgnoreCase(ext, ".zip") or std.ascii.eqlIgnoreCase(ext, ".bz2") or std.ascii.eqlIgnoreCase(ext, ".xz") or std.ascii.eqlIgnoreCase(ext, ".tar") or std.ascii.eqlIgnoreCase(ext, ".7z")) return "zip";
    if (std.ascii.eqlIgnoreCase(ext, ".png") or std.ascii.eqlIgnoreCase(ext, ".jpg") or std.ascii.eqlIgnoreCase(ext, ".jpeg") or std.ascii.eqlIgnoreCase(ext, ".webp") or std.ascii.eqlIgnoreCase(ext, ".gif") or std.ascii.eqlIgnoreCase(ext, ".svg")) return "image";
    if (std.ascii.eqlIgnoreCase(ext, ".sh") or std.ascii.eqlIgnoreCase(ext, ".zsh") or std.ascii.eqlIgnoreCase(ext, ".bash")) return "console";
    return "document";
}
const ui = @import("ui");
const assets = @import("file_workspace_icons_assets.zig");
pub fn asset(name: []const u8) ui.SvgAsset {
    return assets.get(kind(name)).?;
}
pub fn color(name: []const u8) ui.Color {
    const value = kind(name);
    if (std.mem.eql(u8, value, "javascript")) return ui.Color.rgb(0xff, 0xca, 0x28);
    if (std.mem.eql(u8, value, "zig")) return ui.Color.rgb(0xf9, 0xa8, 0x25);
    if (std.mem.eql(u8, value, "zip")) return ui.Color.rgb(0xaf, 0xb4, 0x2b);
    if (std.mem.eql(u8, value, "json")) return ui.Color.rgb(0xf9, 0xa8, 0x25);
    if (std.mem.eql(u8, value, "settings")) return ui.Color.rgb(0x42, 0xa5, 0xf5);
    if (std.mem.eql(u8, value, "markdown")) return ui.Color.rgb(0x42, 0xa5, 0xf5);
    if (std.mem.eql(u8, value, "document")) return ui.Color.rgb(0x42, 0xa5, 0xf5);
    if (std.mem.eql(u8, value, "image")) return ui.Color.rgb(0x26, 0xa6, 0x9a);
    if (std.mem.eql(u8, value, "css")) return ui.Color.rgb(0x7e, 0x57, 0xc2);
    if (std.mem.eql(u8, value, "typescript")) return ui.Color.rgb(0x02, 0x88, 0xd1);
    if (std.mem.eql(u8, value, "log")) return ui.Color.rgb(0xaf, 0xb4, 0x2b);
    if (std.mem.eql(u8, value, "yaml")) return ui.Color.rgb(0xff, 0x52, 0x52);
    if (std.mem.eql(u8, value, "html")) return ui.Color.rgb(0xe6, 0x51, 0x00);
    if (std.mem.eql(u8, value, "console")) return ui.Color.rgb(0xff, 0x70, 0x43);
    return ui.Color.rgb(0x90, 0xa4, 0xae);
}
/// Source bytes for tools that can rasterize SVG; native consumers should use
/// asset()/color(), since the main application has no generic SVG texture loader.
pub fn svg(name: []const u8) []const u8 {
    return asset(name).svg_data;
}
