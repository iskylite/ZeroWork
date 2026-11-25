const std = @import("std");
const ui = @import("ui");
const icons = @import("ui/file_workspace_icons.zig");

fn expectFile(path: []const u8, expected: icons.Variant) !void {
    const icon = icons.fileIcon(path);
    try std.testing.expectEqual(expected, icon.variant);
    try std.testing.expect(icon.asset.icon_id != null);
    try std.testing.expect(icon.asset.pickRep(16) != null);
    try std.testing.expect(icon.asset.pickRep(18) != null);
    try std.testing.expect(icon.asset.svg_data.len > 0);
    try std.testing.expectEqual(icon.asset.icon_id.?, icons.asset(path).icon_id.?);
    const direct = icons.color(path);
    try std.testing.expectEqual(icon.color.r, direct.r);
    try std.testing.expectEqual(icon.color.g, direct.g);
    try std.testing.expectEqual(icon.color.b, direct.b);
    try std.testing.expectEqual(icon.color.a, direct.a);
}

fn expectDirectory(path: []const u8, state: icons.DirectoryState, expected: icons.Variant) !void {
    const icon = icons.directoryIcon(path, state);
    try std.testing.expectEqual(expected, icon.variant);
    try std.testing.expect(icon.asset.icon_id != null);
    try std.testing.expect(icon.asset.pickRep(16) != null);
    try std.testing.expect(icon.asset.pickRep(18) != null);
}

fn expectRgb(color_value: ui.Color, r: u8, g: u8, b: u8) !void {
    try std.testing.expectEqual(r, color_value.r);
    try std.testing.expectEqual(g, color_value.g);
    try std.testing.expectEqual(b, color_value.b);
    try std.testing.expectEqual(@as(u8, 255), color_value.a);
}

test "file workspace icons: directory states and hidden directories" {
    try expectDirectory("src", .{}, .folder);
    try expectDirectory("SRC", .{}, .folder);
    try expectDirectory("src", .{ .expanded = true }, .folder_open);
    try std.testing.expectEqual(icons.Variant.folder_open, icons.iconFor("src", .{ .kind = .directory, .expanded = true }).variant);
    try expectDirectory("/Users/me/workspace", .{ .root = true }, .folder_root);
    try expectDirectory("/Users/me/workspace", .{ .root = true, .expanded = true }, .folder_root);

    try expectDirectory(".git", .{}, .folder_git);
    try expectDirectory(".GIT", .{}, .folder_git);
    try expectDirectory(".github", .{}, .folder_github);
    try expectDirectory(".ssh", .{}, .folder_ssh);
    try expectDirectory(".vscode", .{}, .folder_config);
    try expectDirectory(".config", .{ .expanded = true }, .folder_config);
    try expectDirectory("secret", .{ .hidden = true }, .folder_config);
    try expectDirectory(".git", .{ .hidden = true }, .folder_git);

    try expectDirectory("linked-src", .{ .symlink = true }, .folder_symlink);
    // Explicit state wins over name-based decoration.
    try expectDirectory(".git", .{ .symlink = true }, .folder_symlink);
    try expectDirectory(".git", .{ .root = true, .symlink = true }, .folder_root);

    try std.testing.expect(icons.directoryIcon("src", .{}).asset.icon_id != icons.directoryIcon("src", .{ .expanded = true }).asset.icon_id);
    try std.testing.expect(icons.directoryIcon(".git", .{}).asset.icon_id != icons.directoryIcon("src", .{}).asset.icon_id);
    try std.testing.expect(icons.directoryIcon(".git", .{}).asset.icon_id != icons.directoryIcon(".github", .{}).asset.icon_id);
}

test "file workspace icons: language and script families" {
    try expectFile("main.zig", .zig);
    try expectFile("build.zig.zon", .zig);
    try expectFile("main.rs", .rust);
    try expectFile("MAIN.RS", .rust);
    try expectFile("app.go", .go);
    try expectFile("go.mod", .go);
    try expectFile("go.sum", .go);
    try expectFile("script.py", .python);
    try expectFile("stub.pyi", .python);
    try expectFile("notebook.ipynb", .python);
    try expectFile("main.c", .c_lang);
    try expectFile("main.h", .c_lang);
    try expectFile("main.cpp", .cpp);
    try expectFile("main.cc", .cpp);
    try expectFile("main.hpp", .cpp);
    try expectFile("app.js", .javascript);
    try expectFile("app.jsx", .javascript);
    try expectFile("app.mjs", .javascript);
    try expectFile("app.ts", .typescript);
    try expectFile("app.tsx", .typescript);
    try expectFile("types.d.ts", .typescript);
    try expectFile("Main.java", .java);
    try expectFile("Main.kt", .kotlin);
    try expectFile("build.gradle.kts", .kotlin);
    try expectFile("App.swift", .swift);
    try expectFile("App.m", .objc);
    try expectFile("App.mm", .objc);
    try expectFile("Program.cs", .csharp);
    try expectFile("app.rb", .ruby);
    try expectFile("index.php", .php);
    try expectFile("init.lua", .lua);
    try expectFile("script.pl", .perl);
    try expectFile("script.ex", .code);
    try expectFile("solver.f90", .code);
    try expectFile("run.sh", .console);
    try expectFile("run.zsh", .console);
    try expectFile("run.bash", .console);
    try expectFile("run.fish", .console);
    try expectFile("run.ps1", .console);
    try expectFile("run.bat", .console);
}

test "file workspace icons: web and interface definitions" {
    try expectFile("index.html", .html);
    try expectFile("index.htm", .html);
    try expectFile("style.css", .css);
    try expectFile("style.scss", .css);
    try expectFile("style.sass", .css);
    try expectFile("style.less", .css);
    try expectFile("App.vue", .vue);
    try expectFile("App.svelte", .svelte);
    try expectFile("schema.graphql", .graphql);
    try expectFile("service.proto", .protobuf);
    try expectFile("layout.xml", .xml);
    try expectFile("schema.xsd", .xml);
    // SVG is intentionally kept as an image, matching the existing semantics.
    try expectFile("icon.svg", .image);
}

test "file workspace icons: operations, containers and configuration" {
    try expectFile("Dockerfile", .docker);
    try expectFile("Dockerfile.prod", .docker);
    try expectFile("DOCKERFILE.PROD", .docker);
    try expectFile("Containerfile", .docker);
    try expectFile("Containerfile.test", .docker);
    try expectFile("docker-compose.yml", .docker);
    try expectFile("docker-compose.override.yaml", .docker);
    try expectFile("compose.yml", .docker);
    try expectFile("app.dockerfile", .docker);

    try expectFile("config.yaml", .yaml);
    try expectFile("values.yml", .yaml);
    try expectFile("main.tf", .terraform);
    try expectFile("prod.tfvars", .terraform);
    try expectFile("main.hcl", .terraform);

    try expectFile("app.conf", .settings);
    try expectFile("nginx.conf", .service);
    try expectFile("app.service", .service);
    try expectFile("app.socket", .socket);
    try expectFile("app.timer", .timer);
    try expectFile("Makefile", .build);
    try expectFile("Justfile", .build);
    try expectFile("CMakeLists.txt", .build);
    try expectFile("build.gradle", .build);

    try expectFile(".gitignore", .git);
    try expectFile(".gitattributes", .git);
    try expectFile(".gitmodules", .git);
    try expectFile(".env", .settings);
    try expectFile(".env.production", .settings);
    try expectFile("config.toml", .settings);
    try expectFile("config.ini", .settings);
    try expectFile("app.properties", .settings);
    try expectFile("Cargo.lock", .lock);
    try expectFile("package-lock.json", .lock);

    try expectFile("id_rsa", .key);
    try expectFile("id_ed25519", .key);
    try expectFile("known_hosts", .key);
    try expectFile("authorized_keys", .key);
    try expectFile("server.pem", .key);
    try expectFile("server.key", .key);
    try expectFile("server.crt", .key);
    try expectFile("identity.p12", .key);
}

test "file workspace icons: data, documents, archives and binaries" {
    try expectFile("README.md", .markdown);
    try expectFile("guide.mdx", .markdown);
    try expectFile("data.json", .json);
    try expectFile("events.jsonl", .json);
    try expectFile("settings.jsonc", .json);
    try expectFile("query.sql", .database);
    try expectFile("cache.db", .database);
    try expectFile("cache.sqlite", .database);
    try expectFile("cache.sqlite3", .database);
    try expectFile("server.log", .log);
    try expectFile("manual.pdf", .pdf);
    try expectFile("table.csv", .spreadsheet);
    try expectFile("table.tsv", .spreadsheet);
    try expectFile("table.xlsx", .spreadsheet);
    try expectFile("notes.txt", .document);
    try expectFile("notes.docx", .document);
    try expectFile("notes.rtf", .document);
    try expectFile("photo.png", .image);
    try expectFile("photo.jpeg", .image);
    try expectFile("song.mp3", .audio);
    try expectFile("song.flac", .audio);
    try expectFile("clip.mp4", .video);
    try expectFile("clip.mkv", .video);
    try expectFile("archive.tar.gz", .zip);
    try expectFile("archive.tgz", .zip);
    try expectFile("archive.zip", .zip);
    try expectFile("archive.zst", .zip);
    try expectFile("archive.7z", .zip);
    try expectFile("archive.rar", .zip);
    try expectFile("system.iso", .disk);
    try expectFile("system.qcow2", .disk);
    try expectFile("system.dmg", .disk);
    try expectFile("system.vmdk", .disk);
    try expectFile("system.img", .disk);
    try expectFile("font.ttf", .font);
    try expectFile("font.woff2", .font);
    try expectFile("app.deb", .package);
    try expectFile("app.rpm", .package);
    try expectFile("app.pkg", .package);
    try expectFile("lib.so", .binary);
    try expectFile("lib.dylib", .binary);
    try expectFile("module.wasm", .binary);
    try expectFile("firmware.bin", .binary);
    try expectFile("app.exe", .binary);
}

test "file workspace icons: dotfiles, composite extensions and casing" {
    try expectFile("ARCHIVE.TAR.GZ", .zip);
    try expectFile("backup.TAR.ZST", .zip);
    try expectFile("bundle.tar.xz", .zip);
    try expectFile("types.d.ts", .typescript);
    try expectFile("Dockerfile.PROD", .docker);
    try expectFile("CONTAINERFILE.dev", .docker);
    try expectFile("docker-compose.PROD.YML", .docker);
    try expectFile(".ENV.PRODUCTION", .settings);
    try expectFile(".GITIGNORE", .git);
    try expectFile("README.MD", .markdown);
    try expectFile("unknown.weird", .file);
    try std.testing.expectEqual(ui.icons.file.icon_id.?, icons.asset("unknown.weird").icon_id.?);
    try expectFile("", .file);
    try expectFile("trailing.", .file);
    try expectFile("/parent.iso/unknown", .file);

    try std.testing.expectEqualStrings("code", icons.kind("main.rs"));
    try std.testing.expectEqualStrings("code", icons.kind("go.mod"));
    try std.testing.expectEqualStrings("code", icons.kind("main.tf"));
    try std.testing.expectEqualStrings("settings", icons.kind("app.service"));
    try std.testing.expectEqualStrings("settings", icons.kind("known_hosts"));
    try std.testing.expectEqualStrings("console", icons.kind("CMakeLists.txt"));
    try std.testing.expectEqualStrings("console", icons.kind("Dockerfile"));
    try std.testing.expectEqualStrings("yaml", icons.kind("docker-compose.yml"));
}

test "file workspace icons: stable semantic colors" {
    try expectRgb(icons.color("main.zig"), 0xf9, 0xa8, 0x25);
    try expectRgb(icons.color("main.rs"), 0xce, 0x42, 0x2b);
    try expectRgb(icons.color("app.go"), 0x00, 0xad, 0xd8);
    try expectRgb(icons.color("script.py"), 0x37, 0x76, 0xab);
    try expectRgb(icons.color("app.ts"), 0x02, 0x88, 0xd1);
    try expectRgb(icons.color("Dockerfile"), 0x24, 0x96, 0xed);
    try expectRgb(icons.color("main.tf"), 0x7b, 0x42, 0xbc);
    try expectRgb(icons.color("server.pem"), 0xf9, 0xa8, 0x25);

    try expectRgb(icons.directoryIcon("src", .{}).color, 0x90, 0xa4, 0xae);
    try expectRgb(icons.directoryIcon("workspace", .{ .root = true }).color, 0x42, 0xa5, 0xf5);
    try expectRgb(icons.directoryIcon(".git", .{}).color, 0xf4, 0x51, 0x1e);
    try expectRgb(icons.directoryIcon(".ssh", .{}).color, 0x26, 0xa6, 0x9a);
    try expectRgb(icons.directoryIcon("link", .{ .symlink = true }).color, 0xab, 0x7a, 0xc9);

    // The palette is content-owned and does not vary with application theme.
    try std.testing.expectEqual(icons.color("main.rs").r, icons.color("main.rs").r);
    try std.testing.expect(icons.color("main.rs").r != icons.color("app.go").r);
    try std.testing.expect(icons.asset("main.rs").icon_id != icons.asset("app.go").icon_id);
    try std.testing.expect(icons.asset("main.rs").icon_id != icons.asset("script.py").icon_id);
}
