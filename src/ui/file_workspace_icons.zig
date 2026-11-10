//! Shared file-type icons: the existing Material subset plus bundled Lucide
//! categories. Source/license for the Material assets: assets/file-icons.
//! File colors belong to content and remain stable across application themes.
const std = @import("std");
// Match basenames only, so dotted parent directories cannot change the type.
// Keep this shared by file panes, pickers, transfers and AI attachments.
pub fn kind(path: []const u8) []const u8 {
    const name = std.fs.path.basename(path);
    const names = .{
        .{ "settings", &.{ ".env", ".gitignore", ".gitattributes", ".gitmodules", ".editorconfig", ".npmrc", ".yarnrc", ".prettierrc", ".eslintrc", ".bashrc", ".zshrc", ".bash_profile", ".zprofile", "config", "known_hosts", "authorized_keys" } },
        .{ "console", &.{ "Makefile", "GNUmakefile", "Justfile", "Dockerfile", "Containerfile" } },
        .{ "document", &.{ "README", "LICENSE", "LICENCE", "COPYING", "NOTICE", "CHANGELOG", "AUTHORS" } },
    };
    inline for (names) |group| {
        inline for (group[1]) |candidate| {
            if (std.ascii.eqlIgnoreCase(name, candidate)) return group[0];
        }
    }
    inline for (.{ ".env.", "Dockerfile.", "Containerfile." }) |prefix| {
        if (std.ascii.startsWithIgnoreCase(name, prefix)) return if (prefix[0] == '.') "settings" else "console";
    }
    if (std.ascii.eqlIgnoreCase(name, "id_rsa") or std.ascii.eqlIgnoreCase(name, "id_ed25519") or std.ascii.eqlIgnoreCase(name, "id_ecdsa")) return "key";
    const ext = std.fs.path.extension(name);
    const extensions = .{
        .{ "markdown", &.{ ".md", ".mdx", ".markdown" } },
        .{ "json", &.{ ".json", ".jsonc", ".jsonl", ".ipynb" } },
        .{ "yaml", &.{ ".yaml", ".yml" } },
        .{ "settings", &.{ ".toml", ".ini", ".conf", ".cfg", ".config", ".properties", ".env", ".lock" } },
        .{ "zig", &.{ ".zig", ".zon" } },
        .{ "javascript", &.{ ".js", ".jsx", ".mjs", ".cjs" } },
        .{ "typescript", &.{ ".ts", ".tsx", ".mts", ".cts" } },
        .{ "html", &.{ ".html", ".htm" } },
        .{ "css", &.{ ".css", ".scss", ".sass", ".less" } },
        .{ "code", &.{ ".py", ".pyi", ".rs", ".go", ".c", ".h", ".cpp", ".cc", ".cxx", ".hpp", ".java", ".kt", ".kts", ".swift", ".m", ".mm", ".rb", ".php", ".lua", ".pl", ".ex", ".exs", ".erl", ".hrl", ".cs", ".fs", ".vue", ".svelte", ".xml", ".xsd", ".xsl", ".graphql", ".proto", ".cmake" } },
        .{ "log", &.{".log"} },
        .{ "zip", &.{ ".gz", ".zip", ".bz2", ".xz", ".tar", ".7z", ".rar", ".tgz", ".tbz", ".tbz2", ".txz", ".zst", ".lz", ".lzma", ".bz", ".lz4" } },
        .{ "image", &.{ ".png", ".jpg", ".jpeg", ".webp", ".gif", ".svg", ".bmp", ".ico", ".icns", ".tif", ".tiff", ".heic", ".heif", ".avif", ".psd" } },
        .{ "console", &.{ ".sh", ".zsh", ".bash", ".fish", ".ps1", ".bat", ".cmd" } },
        .{ "disk", &.{ ".iso", ".dmg", ".img", ".vhd", ".vhdx", ".vmdk", ".qcow", ".qcow2", ".vdi", ".toast" } },
        .{ "pdf", &.{".pdf"} },
        .{ "document", &.{ ".txt", ".text", ".rtf", ".doc", ".docx", ".odt", ".pages", ".rst" } },
        .{ "spreadsheet", &.{ ".csv", ".tsv", ".xls", ".xlsx", ".xlsm", ".ods", ".numbers" } },
        .{ "presentation", &.{ ".ppt", ".pptx", ".odp" } },
        .{ "audio", &.{ ".mp3", ".wav", ".flac", ".aac", ".m4a", ".ogg", ".opus", ".aiff", ".wma", ".mid", ".midi" } },
        .{ "video", &.{ ".mp4", ".mkv", ".mov", ".avi", ".webm", ".m4v", ".wmv", ".mpeg", ".mpg" } },
        .{ "database", &.{ ".sql", ".db", ".sqlite", ".sqlite3", ".mdb" } },
        .{ "key", &.{ ".key", ".pem", ".pub", ".crt", ".cer", ".p12", ".pfx", ".p7b", ".der", ".ppk" } },
        .{ "font", &.{ ".ttf", ".otf", ".woff", ".woff2", ".ttc" } },
        .{ "package", &.{ ".deb", ".rpm", ".pkg", ".apk", ".app", ".msi", ".appimage" } },
        .{ "binary", &.{ ".exe", ".dll", ".so", ".dylib", ".a", ".o", ".bin", ".wasm", ".class", ".jar" } },
    };
    inline for (extensions) |group| {
        inline for (group[1]) |candidate| {
            if (std.ascii.eqlIgnoreCase(ext, candidate)) return group[0];
        }
    }
    return "file";
}
const ui = @import("ui");
const assets = @import("file_workspace_icons_assets.zig");
pub fn asset(name: []const u8) ui.SvgAsset {
    const value = kind(name);
    if (assets.get(value)) |existing| return existing;
    // Use the bundled Lucide provider for categories outside the Material subset.
    const additional = .{
        .{ "disk", ui.icons.disc_3 },
        .{ "pdf", ui.icons.file_text },
        .{ "spreadsheet", ui.icons.file_spreadsheet },
        .{ "presentation", ui.icons.presentation },
        .{ "audio", ui.icons.file_audio },
        .{ "video", ui.icons.file_video },
        .{ "database", ui.icons.database },
        .{ "key", ui.icons.file_key },
        .{ "font", ui.icons.type },
        .{ "package", ui.icons.package },
        .{ "binary", ui.icons.binary },
        .{ "code", ui.icons.file_code },
    };
    inline for (additional) |entry| {
        if (std.mem.eql(u8, value, entry[0])) return entry[1];
    }
    return ui.icons.file;
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
    if (std.mem.eql(u8, value, "pdf")) return ui.Color.rgb(0xef, 0x53, 0x50);
    if (std.mem.eql(u8, value, "spreadsheet")) return ui.Color.rgb(0x26, 0xa6, 0x9a);
    if (std.mem.eql(u8, value, "presentation")) return ui.Color.rgb(0xff, 0x70, 0x43);
    if (std.mem.eql(u8, value, "audio") or std.mem.eql(u8, value, "video")) return ui.Color.rgb(0xab, 0x7a, 0xc9);
    if (std.mem.eql(u8, value, "database") or std.mem.eql(u8, value, "code")) return ui.Color.rgb(0x42, 0xa5, 0xf5);
    if (std.mem.eql(u8, value, "key") or std.mem.eql(u8, value, "package")) return ui.Color.rgb(0xf9, 0xa8, 0x25);
    return ui.Color.rgb(0x90, 0xa4, 0xae);
}
/// Source bytes for tools that can rasterize SVG; native consumers should use
/// asset()/color(), since the main application has no generic SVG texture loader.
pub fn svg(name: []const u8) []const u8 {
    return asset(name).svg_data;
}

test "file type icons resolve formats, special names and safe fallback" {
    const cases = .{
        .{ "/downloads/Rocky-8.10-x86_64-dvd1.iso", "disk" },
        .{ "INSTALL.ISO", "disk" },
        .{ "system.qcow2", "disk" },
        .{ "setup.DMG", "disk" },
        .{ "archive.tar.gz", "zip" },
        .{ "backup.TAR.ZST", "zip" },
        .{ "logs.tgz", "zip" },
        .{ "data.rar", "zip" },
        .{ "report.PDF", "pdf" },
        .{ "notes.docx", "document" },
        .{ "data.csv", "spreadsheet" },
        .{ "book.xlsx", "spreadsheet" },
        .{ "slides.pptx", "presentation" },
        .{ "photo.HEIC", "image" },
        .{ "icon.svg", "image" },
        .{ "song.flac", "audio" },
        .{ "clip.mkv", "video" },
        .{ "cache.sqlite3", "database" },
        .{ "server.pem", "key" },
        .{ "server.key", "key" },
        .{ "id_ed25519", "key" },
        .{ "font.woff2", "font" },
        .{ "setup.deb", "package" },
        .{ "app.exe", "binary" },
        .{ "module.wasm", "binary" },
        .{ "script.py", "code" },
        .{ "main.rs", "code" },
        .{ "app.go", "code" },
        .{ "main.zig", "zig" },
        .{ "build.zig.zon", "zig" },
        .{ "app.jsx", "javascript" },
        .{ "types.d.ts", "typescript" },
        .{ "README.md", "markdown" },
        .{ "style.scss", "css" },
        .{ "index.html", "html" },
        .{ "data.jsonl", "json" },
        .{ "config.yaml", "yaml" },
        .{ "error.log", "log" },
        .{ "run.ps1", "console" },
        .{ "Dockerfile", "console" },
        .{ "Dockerfile.prod", "console" },
        .{ "Makefile", "console" },
        .{ ".env", "settings" },
        .{ ".ENV.production", "settings" },
        .{ ".gitignore", "settings" },
        .{ ".zshrc", "settings" },
        .{ "config.toml", "settings" },
        .{ "LICENSE", "document" },
        .{ "README", "document" },
        .{ "/parent.iso/unknown", "file" },
        .{ "unknown.weird", "file" },
        .{ "", "file" },
        .{ "trailing.", "file" },
    };
    inline for (cases) |case| {
        try std.testing.expectEqualStrings(case[1], kind(case[0]));
        const icon = asset(case[0]);
        try std.testing.expect(icon.pickRep(16) != null);
        try std.testing.expect(icon.pickRep(18) != null);
        try std.testing.expect(icon.icon_id != null);
    }
    try std.testing.expect(asset("disk.iso").icon_id != asset("notes.txt").icon_id);
    try std.testing.expect(asset("unknown").icon_id != asset("notes.txt").icon_id);
}
