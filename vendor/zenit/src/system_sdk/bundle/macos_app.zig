/// macOS .app bundle build helper
///
/// Caller (any build.zig):
///
///   const macos_bundle = @import("system_sdk/bundle/macos_app.zig");
///
///   // 1) bundle .app (dev ad-hoc signing)
///   const result = macos_bundle.bundleApp(b, .{
///       .exe = my_exe,
///       .display_name = "My App",
///       .bundle_id = "com.acme.myapp",
///       .signing = .ad_hoc,
///   });
///
///   // 2) distribution release (Developer ID signature + entitlements + hardened runtime)
///   _ = macos_bundle.bundleApp(b, .{
///       .exe = my_exe,
///       .display_name = "My App",
///       .bundle_id = "com.acme.myapp",
///       .signing = .{ .developer_id = .{
///           .identity = "Developer ID Application: ACME Corp (TEAM12345)",
///           .entitlements = b.path("macos/MyApp.entitlements"),
///       }},
///   });
///
///   // 3) notarization (separate step: network operation, minutes; shouldn't block the main build)
///   const notarize_step = macos_bundle.notarizeBundle(b, .{
///       .bundle_path = result.bundle_path,
///       .keychain_profile = "AC_PASSWORD",  // see notarytool store-credentials
///   });
///   notarize_step.dependOn(result.final_step);
///   _ = b.step("notarize", "Submit .app to Apple notarization service")
///       .dependOn(notarize_step);
///
/// Output path: <install_path>/<display_name>.app
const std = @import("std");
const info_plist_mod = @import("info_plist.zig");

pub const FileType = info_plist_mod.FileType;

/// Resource copy item, src is source file, dst is relative path in Resources/.
pub const ResourceCopy = struct {
    src: std.Build.LazyPath,
    /// Relative to bundle's Contents/Resources/ directory. Example: dst = "fonts/Inter.ttf" ->
    /// Contents/Resources/fonts/Inter.ttf.
    dst: []const u8,
};

/// Developer ID signing config for distribution to external users. Signed .app must also go through
/// notarizeBundle() for Apple notarization to open without warning by default.
pub const DeveloperIdSigning = struct {
    /// Identifier accepted by `codesign --sign`. Can be:
    ///   - Full string: "Developer ID Application: ACME Corp (TEAM12345)"
    ///   - Team ID: "TEAM12345" (codesign auto-selects best matching cert)
    ///   - Cert SHA-1: 40 hex digits
    /// The keychain must hold this cert + private key.
    identity: []const u8,
    /// Entitlements .plist path. If hardened runtime enabled, typically need at least
    /// com.apple.security.cs.* entitlements.
    /// null = omit --entitlements parameter (minimal scenarios only).
    entitlements: ?std.Build.LazyPath = null,
    /// Enable hardened runtime, required by Apple notarization. Default true.
    hardened_runtime: bool = true,
    /// Add secure timestamp, required by Apple notarization. Requires codesign process internet
    /// access. Disable for offline CI, but artifact won't pass notarize.
    timestamp: bool = true,
    /// Add --deep to codesign (recursively sign Frameworks/ Plugins/). Default true. Note: Apple
    /// marked --deep deprecated, but works for simple .apps like zenit without nested frameworks.
    deep: bool = true,
};

pub const Signing = union(enum) {
    /// No signing, artifact blocked by macOS Gatekeeper.
    none,
    /// Ad-hoc signing, common during development. Runs locally; distributed to other machines still
    /// blocked by Gatekeeper unless user right-click Open. `codesign --sign -`
    ad_hoc,
    /// Developer ID signing for distribution to external users. Requires Apple Developer account +
    /// certificate in keychain. Still needs notarizeBundle() notarization to open without warning
    /// by default.
    developer_id: DeveloperIdSigning,
};

pub const BundleSpec = struct {
    /// Built executable, bundleApp places it at Contents/MacOS/<executable>.
    exe: *std.Build.Step.Compile,
    /// App display name (determines .app directory name + CFBundle{Display,}Name in Info.plist).
    display_name: []const u8,
    /// Reverse DNS bundle id.
    bundle_id: []const u8,
    /// Filename for .app/Contents/MacOS/<executable>. Default equals exe.name.
    executable: ?[]const u8 = null,
    version: []const u8 = "0.1.0",
    /// 4-char OSType. Determines PkgInfo content "APPL<signature>" and CFBundleSignature. Default
    /// "????", no signature is valid.
    signature: []const u8 = "????",
    min_macos: []const u8 = "12.0",
    /// Icon file (.icns). Optional, omit for no icon (system default).
    icon: ?std.Build.LazyPath = null,
    category: []const u8 = "public.app-category.utilities",
    copyright: ?[]const u8 = null,
    /// File type registration (CFBundleDocumentTypes + UT*TypeDeclarations).
    file_types: []const FileType = &.{},
    /// Additional resources (fonts, images, etc), placed at Contents/Resources/<dst>.
    resources: []const ResourceCopy = &.{},
    /// NSAppTransportSecurity.NSAllowsArbitraryLoads, default false.
    allow_arbitrary_loads: bool = false,
    disable_min_frame_duration: bool = true,
    auto_graphics_switching: bool = true,
    high_resolution: bool = true,
    /// Signing policy.
    signing: Signing = .ad_hoc,
    /// Clear quarantine attribute. Recommended true during development (prevents LaunchServices
    /// rejection).
    clear_quarantine: bool = true,
};

pub const BundleResult = struct {
    /// Final step (user connects bundle to own build graph with
    /// `app_step.dependOn(result.final_step)`).
    final_step: *std.Build.Step,
    /// .app directory absolute path (for follow-up steps like dmg packaging / notarize).
    bundle_path: std.Build.LazyPath,
};

/// Main entry, build macOS .app bundle, return final step.
pub fn bundleApp(b: *std.Build, spec: BundleSpec) BundleResult {
    const exe_name = spec.executable orelse spec.exe.name;
    const bundle_dirname = b.fmt("{s}.app", .{spec.display_name});
    const contents_rel = b.fmt("{s}/Contents", .{bundle_dirname});
    const macos_rel = b.fmt("{s}/MacOS", .{contents_rel});
    const resources_rel = b.fmt("{s}/Resources", .{contents_rel});

    // 1) Place exe at Contents/MacOS/<executable>.
    const install_exe = b.addInstallArtifact(spec.exe, .{
        .dest_dir = .{ .override = .{ .custom = macos_rel } },
    });

    // 2) Render Info.plist.
    const plist_xml = info_plist_mod.render(b.allocator, .{
        .display_name = spec.display_name,
        .bundle_id = spec.bundle_id,
        .executable = exe_name,
        .version = spec.version,
        .signature = spec.signature,
        .min_macos = spec.min_macos,
        .icon_file = if (spec.icon != null) iconStem(b, spec.icon.?) else null,
        .category = spec.category,
        .copyright = spec.copyright,
        .file_types = spec.file_types,
        .allow_arbitrary_loads = spec.allow_arbitrary_loads,
        .disable_min_frame_duration = spec.disable_min_frame_duration,
        .auto_graphics_switching = spec.auto_graphics_switching,
        .high_resolution = spec.high_resolution,
    }) catch @panic("OOM rendering Info.plist");

    const plist_wf = b.addWriteFiles();
    const plist_path = plist_wf.add("Info.plist", plist_xml);
    const install_plist = b.addInstallFile(plist_path, b.fmt("{s}/Info.plist", .{contents_rel}));

    // 3) PkgInfo (8 bytes: "APPL" + 4-char signature).
    const pkginfo_content = b.fmt("APPL{s}", .{spec.signature});
    const pkginfo_wf = b.addWriteFiles();
    const pkginfo_path = pkginfo_wf.add("PkgInfo", pkginfo_content);
    const install_pkginfo = b.addInstallFile(pkginfo_path, b.fmt("{s}/PkgInfo", .{contents_rel}));

    // 4) Icon (if present).
    var resource_steps: std.ArrayList(*std.Build.Step) = .empty;
    resource_steps.append(b.allocator, &install_exe.step) catch @panic("OOM");
    resource_steps.append(b.allocator, &install_plist.step) catch @panic("OOM");
    resource_steps.append(b.allocator, &install_pkginfo.step) catch @panic("OOM");

    if (spec.icon) |icon_path| {
        const icon_filename = iconBasename(b, icon_path);
        const install_icon = b.addInstallFile(
            icon_path,
            b.fmt("{s}/{s}", .{ resources_rel, icon_filename }),
        );
        resource_steps.append(b.allocator, &install_icon.step) catch @panic("OOM");
    }

    // 5) Additional resources.
    for (spec.resources) |res| {
        const install_res = b.addInstallFile(
            res.src,
            b.fmt("{s}/{s}", .{ resources_rel, res.dst }),
        );
        resource_steps.append(b.allocator, &install_res.step) catch @panic("OOM");
    }

    const bundle_abs: std.Build.LazyPath = .{ .relative = .{ .base = .install_prefix, .sub_path = bundle_dirname } };

    var last_step: *std.Build.Step = blk: {
        // Use the PkgInfo install as the resource join. A top-level aggregate
        // is advertised by Zig 0.17 even when omitted from b.top_level_steps.
        const agg = &install_pkginfo.step;
        for (resource_steps.items) |s| {
            if (s != agg) agg.dependOn(s);
        }
        break :blk agg;
    };

    if (spec.clear_quarantine) {
        const xattr = b.addSystemCommand(&.{ "xattr", "-dr", "com.apple.quarantine" });
        xattr.addDirectoryArg2(bundle_abs, .{});
        xattr.step.dependOn(last_step);
        last_step = &xattr.step;
    }

    switch (spec.signing) {
        .none => {},
        .ad_hoc => {
            const codesign = b.addSystemCommand(&.{ "codesign", "--force", "--sign", "-", "--deep" });
            codesign.addDirectoryArg2(bundle_abs, .{});
            codesign.step.dependOn(last_step);
            last_step = &codesign.step;
        },
        .developer_id => |cfg| {
            const codesign = b.addSystemCommand(&.{ "codesign", "--force", "--sign" });
            codesign.addArg(cfg.identity);
            if (cfg.deep) codesign.addArg("--deep");
            if (cfg.hardened_runtime) {
                codesign.addArg("--options");
                codesign.addArg("runtime");
            }
            if (cfg.timestamp) codesign.addArg("--timestamp");
            if (cfg.entitlements) |ent| {
                codesign.addArg("--entitlements");
                codesign.addFileArg(ent);
            }
            codesign.addDirectoryArg2(bundle_abs, .{});
            codesign.step.dependOn(last_step);
            last_step = &codesign.step;
        },
    }

    return .{
        .final_step = last_step,
        .bundle_path = bundle_abs,
    };
}

// ============================================================================
// Notarization
// ============================================================================

/// Notarization auth method, choose one.
pub const NotaryAuth = union(enum) {
    /// Recommended: store credentials in the keychain once with `xcrun notarytool
    /// store-credentials <profile> --apple-id ... --team-id ... --password <app_specific_pwd>`,
    /// then only reference the profile name here.
    keychain_profile: []const u8,
    /// Pass Apple ID + team ID + app-specific password directly. **Not recommended**, password
    /// exposed in command line, captured by ps / shell history. For CI, consider env var.
    inline_credentials: struct {
        apple_id: []const u8,
        team_id: []const u8,
        password: []const u8,
    },
};

pub const NotarizeSpec = struct {
    /// From bundleApp return's BundleResult.bundle_path.
    bundle_path: std.Build.LazyPath,
    /// Step producing 'signed, submittable' output, usually bundleApp's final_step or custom
    /// re-sign step after it. **Must pass**, otherwise no dependency between zip and signing: Zig
    /// can zip before signing finishes, or re-sign after staple, overwriting ticket with signature.
    /// Symptom: staple reports `Record not found`, notarization says Accepted, but disk app's
    /// cdhash changed since upload. (Just making notarizeBundle's return step dependOn signing step
    /// is insufficient: only constrains chain tail, can't control chain head zip.)
    depends_on: ?*std.Build.Step = null,
    /// Apple Developer account credentials.
    auth: NotaryAuth,
    /// Staple ticket into .app after notarization (enables offline distribution verification).
    /// Default true.
    staple: bool = true,
    /// notarytool submit is async by default. Force --wait here (max 2 hours), step fails on error.
    /// CI-friendly. Default true.
    wait: bool = true,
};

/// Submit .app to Apple notarization service, return final step. Caller must connect to build
/// graph:
///   const step = b.step("notarize", "...");
///   step.dependOn(notarizeBundle(b, ...));
///   notarize_inner_step.dependOn(bundle_result.final_step);  // bundle first, then notarize
pub fn notarizeBundle(b: *std.Build, spec: NotarizeSpec) *std.Build.Step {
    // 1) Zip .app, Apple notarytool accepts zip or dmg/pkg, not bare .app.
    const zip_cmd = b.addSystemCommand(&.{ "ditto", "-c", "-k", "--keepParent" });
    zip_cmd.addDirectoryArg2(spec.bundle_path, .{});
    const zip_path = zip_cmd.addOutputFileArg("bundle.zip");
    // Zipping must happen after signing, see NotarizeSpec.depends_on.
    if (spec.depends_on) |dep| zip_cmd.step.dependOn(dep);

    // 2) Submit for notarization.
    const submit_cmd = b.addSystemCommand(&.{ "xcrun", "notarytool", "submit" });
    submit_cmd.addFileArg(zip_path);
    switch (spec.auth) {
        .keychain_profile => |profile| {
            submit_cmd.addArg("--keychain-profile");
            submit_cmd.addArg(profile);
        },
        .inline_credentials => |creds| {
            submit_cmd.addArg("--apple-id");
            submit_cmd.addArg(creds.apple_id);
            submit_cmd.addArg("--team-id");
            submit_cmd.addArg(creds.team_id);
            submit_cmd.addArg("--password");
            submit_cmd.addArg(creds.password);
        },
    }
    if (spec.wait) submit_cmd.addArg("--wait");
    submit_cmd.step.dependOn(&zip_cmd.step);

    var last: *std.Build.Step = &submit_cmd.step;

    // 3) Staple notarization ticket into .app.
    if (spec.staple) {
        const staple_cmd = b.addSystemCommand(&.{ "xcrun", "stapler", "staple" });
        staple_cmd.addDirectoryArg2(spec.bundle_path, .{});
        staple_cmd.step.dependOn(last);
        last = &staple_cmd.step;

        // Verify staple success (spctl checks Gatekeeper perspective).
        const verify_cmd = b.addSystemCommand(&.{ "spctl", "--assess", "--verbose=2", "--type", "execute" });
        verify_cmd.addDirectoryArg2(spec.bundle_path, .{});
        verify_cmd.step.dependOn(last);
        last = &verify_cmd.step;
    }

    return last;
}

/// Extract filename from LazyPath ("icon.icns" etc). Only supports b.path() form.
fn iconBasename(b: *std.Build, lp: std.Build.LazyPath) []const u8 {
    _ = b;
    const full = switch (lp) {
        .src_path => |sp| sp.sub_path,
        else => @panic("bundle icon must use b.path()"),
    };
    const slash = std.mem.lastIndexOfScalar(u8, full, '/');
    return if (slash) |i| full[i + 1 ..] else full;
}

/// Extract icon filename (without extension) for CFBundleIconFile.
fn iconStem(b: *std.Build, lp: std.Build.LazyPath) []const u8 {
    const base = iconBasename(b, lp);
    const dot = std.mem.lastIndexOfScalar(u8, base, '.');
    return if (dot) |i| base[0..i] else base;
}
