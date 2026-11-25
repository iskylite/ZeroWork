//! Shared file-type icons: the existing Material subset plus bundled Lucide
//! categories. Source/license for the Material assets: assets/file-icons.
//! File colors belong to content and remain stable across application themes.
//!
//! Two layers are intentionally exposed:
//! - `kind()` keeps the original coarse category strings for compatibility.
//! - `iconFor()` / `directoryIcon()` return an `Icon` with a precise variant,
//!   asset and fixed semantic color for file trees, transfer rows, AI change
//!   cards, @file candidates and SFTP panes.
const std = @import("std");
const ui = @import("ui");
const assets = @import("file_workspace_icons_assets.zig");

pub const EntryKind = enum { file, directory };

/// State of one tree row. For directories the precedence is:
/// root > symlink > .git/.github/.ssh > hidden/dot-config > expanded.
pub const EntryState = struct {
    kind: EntryKind = .file,
    expanded: bool = false,
    root: bool = false,
    symlink: bool = false,
    hidden: bool = false,
};

/// Convenience state for directory rows; same precedence as EntryState.
pub const DirectoryState = struct {
    expanded: bool = false,
    root: bool = false,
    symlink: bool = false,
    hidden: bool = false,
};

/// Stable visual identity shared by every file/directory consumer.
pub const Variant = enum {
    file,
    folder,
    folder_open,
    folder_root,
    folder_config,
    folder_git,
    folder_github,
    folder_ssh,
    folder_symlink,
    settings,
    console,
    document,
    markdown,
    json,
    yaml,
    zig,
    javascript,
    typescript,
    html,
    css,
    code,
    rust,
    go,
    python,
    c_lang,
    cpp,
    java,
    kotlin,
    swift,
    objc,
    csharp,
    ruby,
    php,
    lua,
    perl,
    vue,
    svelte,
    graphql,
    protobuf,
    xml,
    docker,
    terraform,
    service,
    socket,
    timer,
    build,
    git,
    lock,
    log,
    zip,
    image,
    disk,
    pdf,
    spreadsheet,
    presentation,
    audio,
    video,
    database,
    key,
    font,
    package,
    binary,
};

pub const Icon = struct {
    asset: ui.SvgAsset,
    color: ui.Color,
    variant: Variant,
};

/// Coarse, backwards-compatible category string. New code should prefer
/// `iconFor()`, which keeps the same broad semantics but adds precise
/// language, tooling and directory variants.
// Match basenames only, so dotted parent directories cannot change the type.
// Keep this shared by file panes, pickers, transfers and AI attachments.
pub fn kind(path: []const u8) []const u8 {
    const name = std.fs.path.basename(path);
    const names = .{
        .{ "settings", &.{ ".env", ".envrc", ".dockerignore", ".gitignore", ".gitattributes", ".gitmodules", ".editorconfig", ".npmrc", ".yarnrc", ".prettierrc", ".eslintrc", ".bashrc", ".zshrc", ".bash_profile", ".zprofile", "config", "known_hosts", "authorized_keys" } },
        .{ "console", &.{ "Makefile", "GNUmakefile", "Justfile", "Dockerfile", "Containerfile", "CMakeLists.txt", "Taskfile.yml", "Taskfile.yaml" } },
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
    if (std.ascii.eqlIgnoreCase(name, "id_rsa") or std.ascii.eqlIgnoreCase(name, "id_dsa") or std.ascii.eqlIgnoreCase(name, "id_ed25519") or std.ascii.eqlIgnoreCase(name, "id_ecdsa") or std.ascii.eqlIgnoreCase(name, "id_ed25519_sk") or std.ascii.eqlIgnoreCase(name, "id_rsa_sk")) return "key";
    const ext = std.fs.path.extension(name);
    const extensions = .{
        .{ "markdown", &.{ ".md", ".mdx", ".markdown" } },
        .{ "json", &.{ ".json", ".jsonc", ".jsonl", ".ipynb" } },
        .{ "yaml", &.{ ".yaml", ".yml" } },
        .{ "settings", &.{ ".toml", ".ini", ".conf", ".cfg", ".config", ".properties", ".env", ".lock", ".service", ".socket", ".timer", ".desktop" } },
        .{ "zig", &.{ ".zig", ".zon" } },
        .{ "javascript", &.{ ".js", ".jsx", ".mjs", ".cjs" } },
        .{ "typescript", &.{ ".ts", ".tsx", ".mts", ".cts" } },
        .{ "html", &.{ ".html", ".htm" } },
        .{ "css", &.{ ".css", ".scss", ".sass", ".less" } },
        .{ "code", &.{ ".py", ".pyi", ".rs", ".go", ".mod", ".sum", ".c", ".h", ".cpp", ".cc", ".cxx", ".hpp", ".hh", ".hxx", ".java", ".kt", ".kts", ".swift", ".m", ".mm", ".rb", ".php", ".lua", ".pl", ".ex", ".exs", ".erl", ".hrl", ".cs", ".fs", ".vue", ".svelte", ".xml", ".xsd", ".xsl", ".graphql", ".proto", ".cmake", ".tf", ".tfvars", ".hcl", ".gradle", ".mk", ".mak", ".patch", ".diff" } },
        .{ "log", &.{".log"} },
        .{ "zip", &.{ ".gz", ".zip", ".bz2", ".xz", ".tar", ".7z", ".rar", ".tgz", ".tbz", ".tbz2", ".txz", ".zst", ".lz", ".lzma", ".bz", ".lz4" } },
        .{ "image", &.{ ".png", ".jpg", ".jpeg", ".webp", ".gif", ".svg", ".bmp", ".ico", ".icns", ".tif", ".tiff", ".heic", ".heif", ".avif", ".psd" } },
        .{ "console", &.{ ".sh", ".zsh", ".bash", ".fish", ".ps1", ".bat", ".cmd", ".ksh", ".csh", ".tcsh", ".nu" } },
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

/// Resolve a file/directory entry to its stable icon identity.
pub fn iconFor(path: []const u8, state: EntryState) Icon {
    const variant = if (state.kind == .directory) directoryVariant(path, state) else fileVariant(path);
    return .{ .asset = assetFor(variant), .color = colorFor(variant), .variant = variant };
}

pub fn fileIcon(path: []const u8) Icon {
    return iconFor(path, .{});
}

pub fn directoryIcon(path: []const u8, state: DirectoryState) Icon {
    return iconFor(path, .{ .kind = .directory, .expanded = state.expanded, .root = state.root, .symlink = state.symlink, .hidden = state.hidden });
}

pub fn asset(name: []const u8) ui.SvgAsset {
    return fileIcon(name).asset;
}

pub fn color(name: []const u8) ui.Color {
    return fileIcon(name).color;
}

/// Source bytes for tools that can rasterize SVG; native consumers should use
/// asset()/color(), since the main application has no generic SVG texture loader.
pub fn svg(name: []const u8) []const u8 {
    return asset(name).svg_data;
}

const NameRule = struct {
    variant: Variant,
    names: []const []const u8,
};

const ExtensionRule = struct {
    variant: Variant,
    extensions: []const []const u8,
};

fn eqlAnyIgnoreCase(name: []const u8, candidates: []const []const u8) bool {
    for (candidates) |candidate| {
        if (std.ascii.eqlIgnoreCase(name, candidate)) return true;
    }
    return false;
}

fn endsWithIgnoreCase(name: []const u8, suffix: []const u8) bool {
    return name.len >= suffix.len and std.ascii.eqlIgnoreCase(name[name.len - suffix.len ..], suffix);
}

fn directoryVariant(path: []const u8, state: EntryState) Variant {
    const name = std.fs.path.basename(path);
    if (state.root) return .folder_root;
    if (state.symlink) return .folder_symlink;
    if (std.ascii.eqlIgnoreCase(name, ".git")) return .folder_git;
    if (std.ascii.eqlIgnoreCase(name, ".github")) return .folder_github;
    if (std.ascii.eqlIgnoreCase(name, ".ssh")) return .folder_ssh;
    if (state.hidden or (name.len > 1 and name[0] == '.')) return .folder_config;
    if (state.expanded) return .folder_open;
    return .folder;
}

fn fileVariant(path: []const u8) Variant {
    const name = std.fs.path.basename(path);

    const exact = [_]NameRule{
        .{ .variant = .git, .names = &.{ ".gitignore", ".gitattributes", ".gitmodules", ".gitconfig", ".gitkeep", ".git-blame-ignore-revs" } },
        .{ .variant = .key, .names = &.{ "id_rsa", "id_dsa", "id_ecdsa", "id_ed25519", "id_ed25519_sk", "id_rsa_sk", "known_hosts", "authorized_keys" } },
        .{ .variant = .build, .names = &.{ "Makefile", "GNUmakefile", "Justfile", "CMakeLists.txt", "meson.build", "BUILD", "BUILD.bazel", "WORKSPACE", "WORKSPACE.bazel", "Rakefile", "Gemfile", "Taskfile", "Taskfile.yml", "Taskfile.yaml" } },
        .{ .variant = .docker, .names = &.{ "Dockerfile", "Containerfile", ".dockerignore", "docker-compose.yml", "docker-compose.yaml", "compose.yml", "compose.yaml" } },
        .{ .variant = .service, .names = &.{ "nginx.conf", "httpd.conf", "apache2.conf" } },
        .{ .variant = .settings, .names = &.{ ".env", ".envrc", ".editorconfig", ".npmrc", ".yarnrc", ".prettierrc", ".eslintrc", ".bashrc", ".zshrc", ".bash_profile", ".zprofile", "config" } },
        .{ .variant = .document, .names = &.{ "README", "LICENSE", "LICENCE", "COPYING", "NOTICE", "CHANGELOG", "AUTHORS" } },
        .{ .variant = .lock, .names = &.{ "package-lock.json", "pnpm-lock.yaml", "yarn.lock", "Cargo.lock", "Gemfile.lock", "poetry.lock", "Pipfile.lock", "composer.lock", "mix.lock", "flake.lock" } },
    };
    for (exact) |rule| {
        if (eqlAnyIgnoreCase(name, rule.names)) return rule.variant;
    }

    if (std.ascii.startsWithIgnoreCase(name, "Dockerfile") or
        std.ascii.startsWithIgnoreCase(name, "Containerfile") or
        endsWithIgnoreCase(name, ".dockerfile") or
        endsWithIgnoreCase(name, ".containerfile"))
    {
        return .docker;
    }
    if (std.ascii.startsWithIgnoreCase(name, "docker-compose") or std.ascii.startsWithIgnoreCase(name, "compose.")) {
        const compose_ext = std.fs.path.extension(name);
        if (std.ascii.eqlIgnoreCase(compose_ext, ".yml") or std.ascii.eqlIgnoreCase(compose_ext, ".yaml")) return .docker;
    }
    if (std.ascii.startsWithIgnoreCase(name, ".env.")) return .settings;
    if (std.ascii.startsWithIgnoreCase(name, "Makefile.") or std.ascii.startsWithIgnoreCase(name, "Justfile.")) return .build;

    const ext = std.fs.path.extension(name);
    const extensions = [_]ExtensionRule{
        .{ .variant = .markdown, .extensions = &.{ ".md", ".mdx", ".markdown" } },
        .{ .variant = .json, .extensions = &.{ ".json", ".jsonc", ".jsonl" } },
        .{ .variant = .yaml, .extensions = &.{ ".yaml", ".yml" } },
        .{ .variant = .settings, .extensions = &.{ ".toml", ".ini", ".conf", ".cfg", ".config", ".properties", ".env", ".desktop" } },
        .{ .variant = .zig, .extensions = &.{ ".zig", ".zon" } },
        .{ .variant = .javascript, .extensions = &.{ ".js", ".jsx", ".mjs", ".cjs" } },
        .{ .variant = .typescript, .extensions = &.{ ".ts", ".tsx", ".mts", ".cts" } },
        .{ .variant = .html, .extensions = &.{ ".html", ".htm" } },
        .{ .variant = .css, .extensions = &.{ ".css", ".scss", ".sass", ".less" } },
        .{ .variant = .rust, .extensions = &.{".rs"} },
        .{ .variant = .go, .extensions = &.{ ".go", ".mod", ".sum" } },
        .{ .variant = .python, .extensions = &.{ ".py", ".pyi", ".ipynb" } },
        .{ .variant = .c_lang, .extensions = &.{ ".c", ".h" } },
        .{ .variant = .cpp, .extensions = &.{ ".cpp", ".cc", ".cxx", ".hpp", ".hh", ".hxx", ".ipp", ".tpp" } },
        .{ .variant = .java, .extensions = &.{".java"} },
        .{ .variant = .kotlin, .extensions = &.{ ".kt", ".kts" } },
        .{ .variant = .swift, .extensions = &.{".swift"} },
        .{ .variant = .objc, .extensions = &.{ ".m", ".mm" } },
        .{ .variant = .csharp, .extensions = &.{".cs"} },
        .{ .variant = .ruby, .extensions = &.{ ".rb", ".rake", ".gemspec" } },
        .{ .variant = .php, .extensions = &.{ ".php", ".php3", ".php4", ".php5", ".phtml" } },
        .{ .variant = .lua, .extensions = &.{".lua"} },
        .{ .variant = .perl, .extensions = &.{ ".pl", ".pm", ".pod", ".t" } },
        .{ .variant = .vue, .extensions = &.{".vue"} },
        .{ .variant = .svelte, .extensions = &.{".svelte"} },
        .{ .variant = .graphql, .extensions = &.{ ".graphql", ".gql" } },
        .{ .variant = .protobuf, .extensions = &.{".proto"} },
        .{ .variant = .xml, .extensions = &.{ ".xml", ".xsd", ".xsl", ".xslt", ".plist" } },
        .{ .variant = .terraform, .extensions = &.{ ".tf", ".tfvars", ".hcl" } },
        .{ .variant = .service, .extensions = &.{".service"} },
        .{ .variant = .socket, .extensions = &.{".socket"} },
        .{ .variant = .timer, .extensions = &.{".timer"} },
        .{ .variant = .build, .extensions = &.{ ".cmake", ".mk", ".mak", ".gradle" } },
        .{ .variant = .git, .extensions = &.{ ".patch", ".diff" } },
        .{ .variant = .lock, .extensions = &.{".lock"} },
        .{ .variant = .log, .extensions = &.{".log"} },
        .{ .variant = .zip, .extensions = &.{ ".gz", ".zip", ".bz2", ".xz", ".tar", ".7z", ".rar", ".tgz", ".tbz", ".tbz2", ".txz", ".zst", ".lz", ".lzma", ".bz", ".lz4" } },
        .{ .variant = .image, .extensions = &.{ ".png", ".jpg", ".jpeg", ".webp", ".gif", ".svg", ".bmp", ".ico", ".icns", ".tif", ".tiff", ".heic", ".heif", ".avif", ".psd" } },
        .{ .variant = .console, .extensions = &.{ ".sh", ".zsh", ".bash", ".fish", ".ps1", ".bat", ".cmd", ".ksh", ".csh", ".tcsh", ".nu" } },
        .{ .variant = .disk, .extensions = &.{ ".iso", ".dmg", ".img", ".vhd", ".vhdx", ".vmdk", ".qcow", ".qcow2", ".vdi", ".toast" } },
        .{ .variant = .pdf, .extensions = &.{".pdf"} },
        .{ .variant = .document, .extensions = &.{ ".txt", ".text", ".rtf", ".doc", ".docx", ".odt", ".pages", ".rst" } },
        .{ .variant = .spreadsheet, .extensions = &.{ ".csv", ".tsv", ".xls", ".xlsx", ".xlsm", ".ods", ".numbers" } },
        .{ .variant = .presentation, .extensions = &.{ ".ppt", ".pptx", ".odp" } },
        .{ .variant = .audio, .extensions = &.{ ".mp3", ".wav", ".flac", ".aac", ".m4a", ".ogg", ".opus", ".aiff", ".wma", ".mid", ".midi" } },
        .{ .variant = .video, .extensions = &.{ ".mp4", ".mkv", ".mov", ".avi", ".webm", ".m4v", ".wmv", ".mpeg", ".mpg" } },
        .{ .variant = .database, .extensions = &.{ ".sql", ".db", ".sqlite", ".sqlite3", ".mdb" } },
        .{ .variant = .key, .extensions = &.{ ".key", ".pem", ".pub", ".crt", ".cer", ".p12", ".pfx", ".p7b", ".der", ".ppk" } },
        .{ .variant = .font, .extensions = &.{ ".ttf", ".otf", ".woff", ".woff2", ".ttc" } },
        .{ .variant = .package, .extensions = &.{ ".deb", ".rpm", ".pkg", ".apk", ".app", ".msi", ".appimage" } },
        .{ .variant = .binary, .extensions = &.{ ".exe", ".dll", ".so", ".dylib", ".a", ".o", ".bin", ".wasm", ".class", ".jar" } },
        .{ .variant = .code, .extensions = &.{ ".ex", ".exs", ".erl", ".hrl", ".fs", ".fsx", ".fsi", ".clj", ".cljs", ".cljc", ".edn", ".scala", ".sc", ".groovy", ".dart", ".r", ".jl", ".nim", ".v", ".asm", ".s", ".vb", ".pas", ".f", ".f90", ".f95", ".for", ".cob", ".cbl", ".adb", ".ads", ".hx", ".elm", ".ml", ".mli", ".re", ".rei", ".sol" } },
    };
    for (extensions) |rule| {
        for (rule.extensions) |candidate| {
            if (std.ascii.eqlIgnoreCase(ext, candidate)) return rule.variant;
        }
    }
    return .file;
}

fn bundledAssetName(variant: Variant) ?[]const u8 {
    return switch (variant) {
        .settings => "settings",
        .console => "console",
        .document => "document",
        .markdown => "markdown",
        .json => "json",
        .yaml => "yaml",
        .zig => "zig",
        .javascript => "javascript",
        .typescript => "typescript",
        .html => "html",
        .css => "css",
        .log => "log",
        .zip => "zip",
        .image => "image",
        else => null,
    };
}

fn assetFor(variant: Variant) ui.SvgAsset {
    if (bundledAssetName(variant)) |name| {
        if (assets.get(name)) |existing| return existing;
    }
    return switch (variant) {
        .file => ui.icons.file,
        .folder => ui.icons.folder,
        .folder_open => ui.icons.folder_open,
        .folder_root => ui.icons.folder_root,
        .folder_config => ui.icons.folder_cog,
        .folder_git => ui.icons.folder_git,
        .folder_github => ui.icons.folder_git_2,
        .folder_ssh => ui.icons.folder_key,
        .folder_symlink => ui.icons.folder_symlink,
        .settings => ui.icons.settings,
        .console => ui.icons.terminal,
        .document => ui.icons.file_text,
        .markdown => ui.icons.file_text,
        .json => ui.icons.file_json,
        .yaml => ui.icons.file_code,
        .zig => ui.icons.file_code,
        .javascript => ui.icons.file_code,
        .typescript => ui.icons.file_code,
        .html => ui.icons.file_code,
        .css => ui.icons.file_code,
        .code => ui.icons.file_code,
        .rust => ui.icons.cog,
        .go => ui.icons.square_code,
        .python => ui.icons.file_code,
        .c_lang => ui.icons.file_code,
        .cpp => ui.icons.file_code_2,
        .java => ui.icons.coffee,
        .kotlin => ui.icons.square_code,
        .swift => ui.icons.bird,
        .objc => ui.icons.file_code,
        .csharp => ui.icons.hash,
        .ruby => ui.icons.gem,
        .php => ui.icons.file_code,
        .lua => ui.icons.moon,
        .perl => ui.icons.file_code,
        .vue => ui.icons.component,
        .svelte => ui.icons.flame,
        .graphql => ui.icons.network,
        .protobuf => ui.icons.file_json,
        .xml => ui.icons.code_xml,
        .docker => ui.icons.container,
        .terraform => ui.icons.blocks,
        .service => ui.icons.server_cog,
        .socket => ui.icons.plug,
        .timer => ui.icons.timer,
        .build => ui.icons.hammer,
        .git => ui.icons.git_branch,
        .lock => ui.icons.file_lock,
        .log => ui.icons.file_text,
        .zip => ui.icons.file_archive,
        .image => ui.icons.file_image,
        .disk => ui.icons.disc_3,
        .pdf => ui.icons.file_text,
        .spreadsheet => ui.icons.file_spreadsheet,
        .presentation => ui.icons.presentation,
        .audio => ui.icons.file_audio,
        .video => ui.icons.file_video,
        .database => ui.icons.database,
        .key => ui.icons.file_key,
        .font => ui.icons.type,
        .package => ui.icons.package,
        .binary => ui.icons.binary,
    };
}

fn colorFor(variant: Variant) ui.Color {
    return switch (variant) {
        .file => ui.Color.rgb(0x90, 0xa4, 0xae),
        .folder, .folder_open => ui.Color.rgb(0x90, 0xa4, 0xae),
        .folder_root => ui.Color.rgb(0x42, 0xa5, 0xf5),
        .folder_config => ui.Color.rgb(0x78, 0x90, 0x9c),
        .folder_git => ui.Color.rgb(0xf4, 0x51, 0x1e),
        .folder_github => ui.Color.rgb(0x8b, 0x94, 0x9e),
        .folder_ssh => ui.Color.rgb(0x26, 0xa6, 0x9a),
        .folder_symlink => ui.Color.rgb(0xab, 0x7a, 0xc9),
        .settings => ui.Color.rgb(0x42, 0xa5, 0xf5),
        .console => ui.Color.rgb(0xff, 0x70, 0x43),
        .document => ui.Color.rgb(0x42, 0xa5, 0xf5),
        .markdown => ui.Color.rgb(0x42, 0xa5, 0xf5),
        .json => ui.Color.rgb(0xf9, 0xa8, 0x25),
        .yaml => ui.Color.rgb(0xff, 0x52, 0x52),
        .zig => ui.Color.rgb(0xf9, 0xa8, 0x25),
        .javascript => ui.Color.rgb(0xff, 0xca, 0x28),
        .typescript => ui.Color.rgb(0x02, 0x88, 0xd1),
        .html => ui.Color.rgb(0xe6, 0x51, 0x00),
        .css => ui.Color.rgb(0x7e, 0x57, 0xc2),
        .code => ui.Color.rgb(0x42, 0xa5, 0xf5),
        .rust => ui.Color.rgb(0xce, 0x42, 0x2b),
        .go => ui.Color.rgb(0x00, 0xad, 0xd8),
        .python => ui.Color.rgb(0x37, 0x76, 0xab),
        .c_lang => ui.Color.rgb(0x5c, 0x6b, 0xc0),
        .cpp => ui.Color.rgb(0x15, 0x65, 0xc0),
        .java => ui.Color.rgb(0xe7, 0x6f, 0x00),
        .kotlin => ui.Color.rgb(0x7f, 0x52, 0xff),
        .swift => ui.Color.rgb(0xf0, 0x51, 0x38),
        .objc => ui.Color.rgb(0x43, 0x8e, 0xff),
        .csharp => ui.Color.rgb(0x8e, 0x44, 0xad),
        .ruby => ui.Color.rgb(0xcc, 0x34, 0x2d),
        .php => ui.Color.rgb(0x77, 0x7b, 0xb4),
        .lua => ui.Color.rgb(0x5c, 0x6b, 0xc0),
        .perl => ui.Color.rgb(0x79, 0x86, 0xcb),
        .vue => ui.Color.rgb(0x41, 0xb8, 0x83),
        .svelte => ui.Color.rgb(0xff, 0x3e, 0x00),
        .graphql => ui.Color.rgb(0xe1, 0x00, 0x98),
        .protobuf => ui.Color.rgb(0x42, 0x85, 0xf4),
        .xml => ui.Color.rgb(0x8d, 0x6e, 0x63),
        .docker => ui.Color.rgb(0x24, 0x96, 0xed),
        .terraform => ui.Color.rgb(0x7b, 0x42, 0xbc),
        .service => ui.Color.rgb(0x42, 0xa5, 0xf5),
        .socket => ui.Color.rgb(0x26, 0xa6, 0x9a),
        .timer => ui.Color.rgb(0xff, 0xb3, 0x00),
        .build => ui.Color.rgb(0xff, 0x70, 0x43),
        .git => ui.Color.rgb(0xf0, 0x50, 0x33),
        .lock => ui.Color.rgb(0xf9, 0xa8, 0x25),
        .log => ui.Color.rgb(0xaf, 0xb4, 0x2b),
        .zip => ui.Color.rgb(0xaf, 0xb4, 0x2b),
        .image => ui.Color.rgb(0x26, 0xa6, 0x9a),
        .disk => ui.Color.rgb(0x60, 0x7d, 0x8b),
        .pdf => ui.Color.rgb(0xef, 0x53, 0x50),
        .spreadsheet => ui.Color.rgb(0x26, 0xa6, 0x9a),
        .presentation => ui.Color.rgb(0xff, 0x70, 0x43),
        .audio, .video => ui.Color.rgb(0xab, 0x7a, 0xc9),
        .database => ui.Color.rgb(0x42, 0xa5, 0xf5),
        .key => ui.Color.rgb(0xf9, 0xa8, 0x25),
        .font => ui.Color.rgb(0x90, 0xa4, 0xae),
        .package => ui.Color.rgb(0xf9, 0xa8, 0x25),
        .binary => ui.Color.rgb(0x90, 0xa4, 0xae),
    };
}

test "every icon variant resolves a bundled asset and opaque semantic color" {
    inline for (std.enums.values(Variant)) |variant| {
        const icon_asset = assetFor(variant);
        try std.testing.expect(icon_asset.icon_id != null);
        try std.testing.expect(icon_asset.pickRep(16) != null);
        try std.testing.expect(icon_asset.pickRep(18) != null);
        try std.testing.expect(icon_asset.svg_data.len > 0);
        const semantic_color = colorFor(variant);
        try std.testing.expectEqual(@as(u8, 255), semantic_color.a);
    }
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
