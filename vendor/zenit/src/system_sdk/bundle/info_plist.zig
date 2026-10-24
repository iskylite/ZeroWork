/// Info.plist generator, render BundleSpec to XML.
///
/// Code generation not template substitution: CFBundleDocumentTypes / UTExportedTypeDeclarations
/// are array structures, count caller-determined, template strings unwieldy with nesting.
const std = @import("std");

pub const FileType = struct {
    /// User-visible name (shown in Finder).
    name: []const u8,
    /// File extension (no dot).
    extensions: []const []const u8,
    /// UTI identifier. E.g., "com.acme.myapp.document".
    uti: []const u8,
    /// "Editor" / "Viewer" / "Shell" / "None"
    role: []const u8 = "Editor",
    /// "Owner" / "Default" / "Alternate" / "None"
    handler_rank: []const u8 = "Owner",
    /// Whether UTType defined by this app (exported). false means just referenced (imported, e.g.,
    /// markdown).
    exported: bool = true,
    /// Parent type inherited by UTI. Imported typically ["public.plain-text"]; exported documents
    /// typically ["public.data", "public.content"].
    conforms_to: []const []const u8 = &.{ "public.data", "public.content" },
};

pub const BundleSpec = struct {
    /// CFBundleDisplayName / CFBundleName, user-visible name.
    display_name: []const u8,
    /// CFBundleIdentifier, reverse DNS. E.g., "com.acme.myapp".
    bundle_id: []const u8,
    /// CFBundleExecutable, filename in Contents/MacOS/<name>.
    executable: []const u8,
    /// CFBundleShortVersionString + CFBundleVersion
    version: []const u8 = "0.1.0",
    /// 4-character OSType signature. Convention: APPL = application, ???? for other. Used in
    /// PkgInfo file + CFBundleSignature.
    signature: []const u8 = "????",
    /// LSMinimumSystemVersion. E.g., "12.0".
    min_macos: []const u8 = "12.0",
    /// CFBundleIconFile, filename in Resources/<icon_file>.icns (no extension).
    icon_file: ?[]const u8 = null,
    /// LSApplicationCategoryType
    category: []const u8 = "public.app-category.developer-tools",
    /// Copyright string (NSHumanReadableCopyright).
    copyright: ?[]const u8 = null,
    /// File type registration (CFBundleDocumentTypes + UT*TypeDeclarations).
    file_types: []const FileType = &.{},
    /// NSAppTransportSecurity.NSAllowsArbitraryLoads, default false (secure). Callers explicitly
    /// enable if app needs arbitrary HTTP images/links.
    allow_arbitrary_loads: bool = false,
    /// CADisableMinimumFrameDuration, unlock ProMotion 120Hz. Default true (editor scenes worth
    /// it).
    disable_min_frame_duration: bool = true,
    /// NSSupportsAutomaticGraphicsSwitching, default true (laptop power saving).
    auto_graphics_switching: bool = true,
    /// NSHighResolutionCapable, Retina required.
    high_resolution: bool = true,
};

/// Render BundleSpec as complete Info.plist XML string.
pub fn render(allocator: std.mem.Allocator, spec: BundleSpec) ![]u8 {
    var buf: std.Io.Writer.Allocating = .init(allocator);
    defer buf.deinit();
    const w = &buf.writer;

    try w.writeAll(
        \\<?xml version="1.0" encoding="UTF-8"?>
        \\<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        \\<plist version="1.0">
        \\<dict>
        \\
    );

    if (spec.disable_min_frame_duration) {
        try w.writeAll("\t<key>CADisableMinimumFrameDuration</key>\n\t<true/>\n");
    }
    try writeKVString(w, "CFBundleDisplayName", spec.display_name);

    // CFBundleDocumentTypes
    if (spec.file_types.len > 0) {
        try w.writeAll("\t<key>CFBundleDocumentTypes</key>\n\t<array>\n");
        for (spec.file_types) |ft| {
            try w.writeAll("\t\t<dict>\n");
            try w.writeAll("\t\t\t<key>CFBundleTypeExtensions</key>\n\t\t\t<array>\n");
            for (ft.extensions) |ext| {
                try w.print("\t\t\t\t<string>{s}</string>\n", .{ext});
            }
            try w.writeAll("\t\t\t</array>\n");
            try w.print("\t\t\t<key>CFBundleTypeName</key>\n\t\t\t<string>{s}</string>\n", .{ft.name});
            try w.print("\t\t\t<key>CFBundleTypeRole</key>\n\t\t\t<string>{s}</string>\n", .{ft.role});
            try w.print("\t\t\t<key>LSHandlerRank</key>\n\t\t\t<string>{s}</string>\n", .{ft.handler_rank});
            try w.writeAll("\t\t\t<key>LSItemContentTypes</key>\n\t\t\t<array>\n");
            try w.print("\t\t\t\t<string>{s}</string>\n", .{ft.uti});
            try w.writeAll("\t\t\t</array>\n");
            try w.writeAll("\t\t</dict>\n");
        }
        try w.writeAll("\t</array>\n");
    }

    try writeKVString(w, "CFBundleExecutable", spec.executable);
    if (spec.icon_file) |icon| {
        try writeKVString(w, "CFBundleIconFile", icon);
    }
    try writeKVString(w, "CFBundleIdentifier", spec.bundle_id);
    try writeKVString(w, "CFBundleName", spec.display_name);
    try writeKVString(w, "CFBundlePackageType", "APPL");
    try writeKVString(w, "CFBundleShortVersionString", spec.version);
    try writeKVString(w, "CFBundleSignature", spec.signature);
    try writeKVString(w, "CFBundleVersion", spec.version);
    try writeKVString(w, "LSApplicationCategoryType", spec.category);
    try writeKVString(w, "LSMinimumSystemVersion", spec.min_macos);

    if (spec.allow_arbitrary_loads) {
        try w.writeAll("\t<key>NSAppTransportSecurity</key>\n");
        try w.writeAll("\t<dict>\n");
        try w.writeAll("\t\t<key>NSAllowsArbitraryLoads</key>\n");
        try w.writeAll("\t\t<true/>\n");
        try w.writeAll("\t</dict>\n");
    }
    if (spec.high_resolution) {
        try w.writeAll("\t<key>NSHighResolutionCapable</key>\n\t<true/>\n");
    }
    if (spec.copyright) |cp| {
        try writeKVString(w, "NSHumanReadableCopyright", cp);
    }
    if (spec.auto_graphics_switching) {
        try w.writeAll("\t<key>NSSupportsAutomaticGraphicsSwitching</key>\n\t<true/>\n");
    }

    // UTExportedTypeDeclarations / UTImportedTypeDeclarations
    var has_exported = false;
    var has_imported = false;
    for (spec.file_types) |ft| {
        if (ft.exported) has_exported = true else has_imported = true;
    }
    if (has_exported) {
        try w.writeAll("\t<key>UTExportedTypeDeclarations</key>\n\t<array>\n");
        for (spec.file_types) |ft| {
            if (!ft.exported) continue;
            try writeUtTypeDecl(w, ft);
        }
        try w.writeAll("\t</array>\n");
    }
    if (has_imported) {
        try w.writeAll("\t<key>UTImportedTypeDeclarations</key>\n\t<array>\n");
        for (spec.file_types) |ft| {
            if (ft.exported) continue;
            try writeUtTypeDecl(w, ft);
        }
        try w.writeAll("\t</array>\n");
    }

    try w.writeAll("</dict>\n</plist>\n");

    return buf.toOwnedSlice();
}

fn writeKVString(w: anytype, key: []const u8, value: []const u8) !void {
    try w.print("\t<key>{s}</key>\n\t<string>{s}</string>\n", .{ key, value });
}

fn writeUtTypeDecl(w: anytype, ft: FileType) !void {
    try w.writeAll("\t\t<dict>\n");
    try w.writeAll("\t\t\t<key>UTTypeConformsTo</key>\n\t\t\t<array>\n");
    for (ft.conforms_to) |parent| {
        try w.print("\t\t\t\t<string>{s}</string>\n", .{parent});
    }
    try w.writeAll("\t\t\t</array>\n");
    try w.print("\t\t\t<key>UTTypeDescription</key>\n\t\t\t<string>{s}</string>\n", .{ft.name});
    try w.print("\t\t\t<key>UTTypeIdentifier</key>\n\t\t\t<string>{s}</string>\n", .{ft.uti});
    try w.writeAll("\t\t\t<key>UTTypeTagSpecification</key>\n");
    try w.writeAll("\t\t\t<dict>\n");
    try w.writeAll("\t\t\t\t<key>public.filename-extension</key>\n");
    try w.writeAll("\t\t\t\t<array>\n");
    for (ft.extensions) |ext| {
        try w.print("\t\t\t\t\t<string>{s}</string>\n", .{ext});
    }
    try w.writeAll("\t\t\t\t</array>\n\t\t\t</dict>\n\t\t</dict>\n");
}

test "render minimal Info.plist" {
    const allocator = std.testing.allocator;
    const xml = try render(allocator, .{
        .display_name = "Hello",
        .bundle_id = "com.example.hello",
        .executable = "hello",
    });
    defer allocator.free(xml);
    try std.testing.expect(std.mem.indexOf(u8, xml, "com.example.hello") != null);
    try std.testing.expect(std.mem.indexOf(u8, xml, "<string>hello</string>") != null);
}

test "render with file types" {
    const allocator = std.testing.allocator;
    const xml = try render(allocator, .{
        .display_name = "Demo App",
        .bundle_id = "com.example.demo",
        .executable = "demo",
        .file_types = &.{
            // Owner of a custom format, exported UTType
            .{
                .name = "Demo Document",
                .extensions = &.{"demo"},
                .uti = "com.example.demo.document",
            },
            // Imported UTType, registers as a handler for an existing
            // system UTI without re-defining it.
            .{
                .name = "Markdown",
                .extensions = &.{ "md", "markdown" },
                .uti = "net.daringfireball.markdown",
                .handler_rank = "Alternate",
                .exported = false,
                .conforms_to = &.{"public.plain-text"},
            },
        },
    });
    defer allocator.free(xml);
    try std.testing.expect(std.mem.indexOf(u8, xml, "UTExportedTypeDeclarations") != null);
    try std.testing.expect(std.mem.indexOf(u8, xml, "UTImportedTypeDeclarations") != null);
    try std.testing.expect(std.mem.indexOf(u8, xml, "com.example.demo.document") != null);
    try std.testing.expect(std.mem.indexOf(u8, xml, "net.daringfireball.markdown") != null);
}
