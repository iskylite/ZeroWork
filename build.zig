const std = @import("std");
const zenit = @import("zenit");

pub fn build(b: *std.Build) void {
    // ZeroWork is intentionally macOS 14+ on Apple Silicon only (SPEC baseline).
    // Zig 0.17 build graph; the active Xcode SDK is selected by the toolchain.

    const target = b.resolveTargetQuery(.{
        .cpu_arch = .aarch64,
        .os_tag = .macos,
        .os_version_min = .{ .semver = .{
            .major = 14,
            .minor = 0,
            .patch = 0,
        } },
    });
    const optimize = b.standardOptimizeOption(.{});
    const verify_ssh = b.addSystemCommand(&.{ "python3", "scripts/verify_ssh_deps.py" });
    verify_ssh.setCwd(b.path("."));
    verify_ssh.has_side_effects = true;
    b.step("verify-ssh-deps", "Verify SSH source, configuration and archive provenance").dependOn(&verify_ssh.step);
    const test_mode = b.option(bool, "test-mode", "Enable the Zenit UI automation harness") orelse false;
    const plugin_fixture = b.option(bool, "plugin-fixture", "Link the non-terminal plugin acceptance fixture (test builds only)") orelse false;
    if (plugin_fixture and !test_mode) @panic("plugin-fixture requires -Dtest-mode=true; it must not enter production builds");
    const e2e_port = b.option(u16, "e2e-port", "Zenit Harness file-RPC directory suffix") orelse 19816;
    const zenit_dep = b.dependency("zenit", .{
        .target = target,
        .optimize = optimize,
        .@"test-mode" = test_mode,
        .@"e2e-port" = e2e_port,
    });

    const core = b.addModule("zerowork", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    // transfer_panel（root.zig 挂载）用 @import("ui")；纯 Zig 模块引用，
    // 不带 .m 源（.m 只经 attach/addNativeLibs 落到具体二进制）。
    core.addImport("ui", zenit_dep.module("ui"));
    core.addImport("icon_ir", zenit_dep.module("icon_ir"));
    // NOTE: core 不挂 "ui"——exe 已由 zenit.attach 挂载；重复挂载会让同一份
    // zenit .m 桥在 exe 链接里出现两份（duplicate symbol）。transfer_panel 的
    // 测试编译走 tests.root_module 的独立挂载（见 tests 段）。

    // Prebuilt libghostty-vt is produced by the official Ghostty Zig 0.17
    // branch and is the ONLY VT engine: ghostty_adapter.zig wraps its C ABI
    // behind the VtEngine contract (feed/resize/snapshot/lineAt/selection).
    core.addLibraryPath(b.path("vendor/libghostty-vt"));
    core.addIncludePath(b.path("vendor/libghostty-vt/include"));
    core.linkSystemLibrary("ghostty-vt", .{});

    const ghostty_translate = b.addTranslateC(.{ .root_source_file = b.path("vendor/libghostty-vt/include/ghostty/vt.h"), .target = target, .optimize = optimize });
    ghostty_translate.addIncludePath(b.path("vendor/libghostty-vt/include"));
    core.addImport("generated_ghostty_vt", ghostty_translate.createModule());
    // The static Local plugin owns the native PTY/process boundary.
    core.addCSourceFile(.{ .file = b.path("src/local/darwin_process.c"), .flags = &.{"-std=c11"} });
    core.addCSourceFile(.{ .file = b.path("src/platform/macos_credentials.m"), .flags = &.{} });
    core.addCSourceFile(.{ .file = b.path("src/platform/data_scope_lock.c"), .flags = &.{"-std=c11"} });
    core.linkFramework("Security", .{});
    core.linkFramework("CoreFoundation", .{});
    addUrlFetchFrameworks(core);
    core.addCSourceFile(.{ .file = b.path("src/local/trusted_edit_native.c"), .flags = &.{"-std=c11"} });
    core.addCSourceFile(.{ .file = b.path("src/local/secret_native.c"), .flags = &.{"-std=c11"} });
    core.addSystemIncludePath(.{ .cwd_relative = "/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk/usr/include" });
    core.addLibraryPath(.{ .cwd_relative = "/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk/usr/lib" });
    const ssh_channel_translate = b.addTranslateC(.{ .root_source_file = b.path("src/proto/ssh/libssh2_channel_shim.h"), .target = target, .optimize = optimize });
    ssh_channel_translate.addIncludePath(b.path("vendor/libssh2/include"));
    core.addImport("generated_ssh_channel", ssh_channel_translate.createModule());
    const ssh_session_translate = b.addTranslateC(.{ .root_source_file = b.path("src/proto/ssh/libssh2_session_shim.h"), .target = target, .optimize = optimize });
    ssh_session_translate.addIncludePath(b.path("vendor/libssh2/include"));
    core.addImport("generated_ssh_session", ssh_session_translate.createModule());

    // libssh2 and Mbed TLS are built as pinned static dependencies by the reproducible
    // scripts/build_ssh_deps.sh step; compile the stable ZeroWork shims here.
    core.addIncludePath(b.path("vendor/libssh2/include"));
    core.addIncludePath(b.path("src/proto/ssh"));
    core.addCSourceFiles(.{ .files = &.{
        "src/proto/ssh/libssh2_channel_shim.c",
        "src/proto/ssh/libssh2_session_shim.c",
    }, .flags = &.{"-std=c11"} });
    // The dependency script emits these archives; fail with a useful build error
    // instead of silently searching unrelated host libraries.
    core.addLibraryPath(b.path("vendor/libssh2/src/.libs"));
    core.addLibraryPath(b.path("vendor/mbedtls/library"));
    core.linkSystemLibrary("ssh2", .{});
    core.linkSystemLibrary("mbedcrypto", .{});
    core.linkSystemLibrary("z", .{});

    // VT conformance/perf runner: same engine as production (ghostty), driven
    // through the adapter-agnostic conformance_runner.zig harness.
    const vt_runner = b.addExecutable(.{
        .name = "vt-conformance-runner",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/vt_conformance_runner.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "generated_ghostty_vt", .module = ghostty_translate.createModule() }},
        }),
    });
    vt_runner.root_module.addLibraryPath(b.path("vendor/libghostty-vt"));
    vt_runner.root_module.addIncludePath(b.path("vendor/libghostty-vt/include"));
    vt_runner.root_module.linkSystemLibrary("ghostty-vt", .{});
    b.installArtifact(vt_runner);
    const vt_run = b.addRunArtifact(vt_runner);
    b.step("vt-perf", "Run deterministic VT conformance and performance samples").dependOn(&vt_run.step);

    const exe = b.addExecutable(.{
        .name = "zerowork",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "zerowork", .module = core }},
        }),
    });
    exe.step.dependOn(&verify_ssh.step);
    const application_options = b.addOptions();
    application_options.addOption(bool, "plugin_fixture", plugin_fixture);
    application_options.addOption(bool, "test_mode", test_mode);
    exe.root_module.addOptions("application_options", application_options);

    // Zenit owns the native macOS window/input/Metal boundary. ZeroWork adds no separate UI bridge.
    exe.root_module.addImport("generated_ghostty_vt", ghostty_translate.createModule());
    exe.root_module.addImport("generated_ssh_channel", ssh_channel_translate.createModule());
    exe.root_module.addImport("generated_ssh_session", ssh_session_translate.createModule());

    zenit.attach(zenit_dep, exe);
    exe.root_module.addCSourceFile(.{ .file = b.path("src/platform/macos_notifications.m"), .flags = &.{"-fobjc-arc"} });
    exe.root_module.linkFramework("UserNotifications", .{});
    exe.root_module.addCSourceFile(.{ .file = b.path("src/platform/macos_data_alert.m"), .flags = &.{"-fobjc-arc"} });
    exe.root_module.addCSourceFile(.{ .file = b.path("src/platform/macos_transfer_picker.m"), .flags = &.{"-fobjc-arc"} });
    exe.root_module.addCSourceFile(.{ .file = b.path("src/platform/app_icon.m"), .flags = &.{"-fobjc-arc"} });
    exe.root_module.addAnonymousImport("app_icon_assets", .{ .root_source_file = b.path("assets/macos/icons.zig") });
    exe.root_module.addAnonymousImport("ui_font_assets", .{ .root_source_file = b.path("docs/UI_V3/assets/fonts/native.zig") });
    exe.root_module.addCSourceFile(.{ .file = b.path("src/platform/ui_fonts.m"), .flags = &.{} });
    exe.root_module.addCSourceFile(.{ .file = b.path("src/platform/macos_file_promises.m"), .flags = &.{"-fobjc-arc"} });
    exe.root_module.addCSourceFile(.{ .file = b.path("src/platform/macos_host_secret.m"), .flags = &.{"-fobjc-arc"} });
    exe.root_module.linkFramework("Carbon", .{});
    exe.root_module.addImport("icon_ir", zenit_dep.module("icon_ir"));
    zenit.installHarnessClient(b, zenit_dep);
    exe.root_module.addSystemFrameworkPath(.{ .cwd_relative = "/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk/System/Library/Frameworks" });
    exe.root_module.addSystemIncludePath(.{ .cwd_relative = "/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk/usr/include" });
    exe.root_module.addLibraryPath(.{ .cwd_relative = "/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk/usr/lib" });

    b.installArtifact(exe);
    // The local ZSH edit bridge is loaded only by this process's private
    // bootstrap, from beside the executable in both CLI and app bundles.
    const zsh_bridge = b.addSystemCommand(&.{ "xcrun", "clang", "-target", "arm64-apple-macos14.0", "-bundle", "-undefined", "dynamic_lookup", "-O2" });
    zsh_bridge.addFileArg(b.path("src/local/shell/zw_ipc.c"));
    zsh_bridge.addArg("-o");
    const zsh_bridge_file = zsh_bridge.addOutputFileArg("zw_ipc.so");
    b.getInstallStep().dependOn(&b.addInstallFileWithDir(zsh_bridge_file, .bin, "zw_ipc.so").step);
    const execution_bridge = b.addSystemCommand(&.{ "xcrun", "clang", "-target", "arm64-apple-macos14.0", "-bundle", "-undefined", "dynamic_lookup", "-O2", "-DZW_EXECUTION=1" });
    execution_bridge.addFileArg(b.path("src/local/shell/zw_ipc.c"));
    execution_bridge.addArg("-o");
    const execution_bridge_file = execution_bridge.addOutputFileArg("zw_execution.so");
    b.getInstallStep().dependOn(&b.addInstallFileWithDir(execution_bridge_file, .bin, "zw_execution.so").step);
    const secret_consumer = b.addSystemCommand(&.{ "xcrun", "clang", "-target", "arm64-apple-macos14.0", "-bundle", "-undefined", "dynamic_lookup", "-std=c11", "-O2" });
    secret_consumer.addFileArg(b.path("src/local/shell/secret_consume.c"));
    secret_consumer.addArg("-o");
    const secret_consumer_file = secret_consumer.addOutputFileArg("zw_secret_consume.so");
    b.getInstallStep().dependOn(&b.addInstallFileWithDir(secret_consumer_file, .bin, "zw_secret_consume.so").step);
    const execution_guard = b.addSystemCommand(&.{ "xcrun", "clang", "-target", "arm64-apple-macos14.0", "-std=c11", "-Wall", "-Wextra", "-Werror", "-O2" });
    execution_guard.addFileArg(b.path("src/local/shell/execution_guard.c"));
    execution_guard.addArg("-o");
    const execution_guard_file = execution_guard.addOutputFileArg("zw_execution_guard");
    b.getInstallStep().dependOn(&b.addInstallFileWithDir(execution_guard_file, .bin, "zw_execution_guard").step);
    // Versioned remote resources are bundled, never fetched by a target host.
    // Building Linux candidates does not grant runtime compatibility/ready.
    const ssh_bootstrap = b.addSystemCommand(&.{ "python3", "scripts/build_ssh_bootstrap.py", "--output" });
    const ssh_bootstrap_directory = ssh_bootstrap.addOutputDirectoryArg("ssh-bootstrap-v1");
    for ([_][]const u8{ "scripts/build_ssh_bootstrap.py", "src/proto/ssh/bootstrap/v1/launcher.c", "src/proto/ssh/bootstrap/v1/zw_ssh_execution.c", "src/proto/ssh/bootstrap/v1/execution.zsh" }) |source| ssh_bootstrap.addFileInput(b.path(source));
    const install_ssh_bootstrap = b.addInstallDirectory(.{ .source_dir = ssh_bootstrap_directory, .install_dir = .prefix, .install_subdir = "share/zerowork/ssh-bootstrap/v1" });
    b.getInstallStep().dependOn(&install_ssh_bootstrap.step);
    b.step("ssh-bootstrap-resources", "Build hash-manifested BootstrapV1 remote candidates without deployment").dependOn(&install_ssh_bootstrap.step);

    // ── Mockup 预览（设计稿实机比对基建） ───────────────────────────
    // Build only the selected native design preview, outside production sources.
    const mockup_name = b.option([]const u8, "mockup", "Mockup preview name (docs/SPEC/html/mockup-<name>.html)") orelse "";
    if (mockup_name.len > 0) {
        // 视图文件名 = mockup 名（'-'→'_'，与 stub 生成规则一致）。
        const file_zig_name = b.allocator.dupe(u8, mockup_name) catch @panic("OOM");
        for (file_zig_name) |*c| {
            if (c.* == '-') c.* = '_';
        }
        const view_path = b.fmt("tools/mockups/{s}.zig", .{file_zig_name});
        // 隔离关键：视图文件由 build 层装配为独立模块 —— 每次构建的
        // import 图只包含被选中的这一个 mockup，其他子智能体文件的
        // 语法错误不会波及本次构建（Zig @import 是 AstGen 急切解析，
        // mockup_main 内的 comptime if 剪枝挡不住）。
        const view_module = b.createModule(.{
            .root_source_file = b.path(view_path),
            .target = target,
            .optimize = optimize,
        });
        view_module.addImport("ui", zenit_dep.module("ui"));
        const design_tokens = b.createModule(.{
            .root_source_file = b.path("src/ui/design_tokens.zig"),
            .target = target,
            .optimize = optimize,
        });
        design_tokens.addImport("ui", zenit_dep.module("ui"));
        view_module.addImport("design_tokens", design_tokens);
        const mockup_options = b.addOptions();
        mockup_options.addOption([]const u8, "mockup", mockup_name);
        const mockup_exe = b.addExecutable(.{
            .name = b.fmt("mockup-{s}", .{mockup_name}),
            .root_module = b.createModule(.{
                .root_source_file = b.path("tools/mockups/runner.zig"),
                .target = target,
                .optimize = optimize,
            }),
        });
        mockup_exe.root_module.addOptions("build_options", mockup_options);
        mockup_exe.root_module.addImport("mockup_view", view_module);
        // Mockup 预览不链接 ghostty/libssh2（纯 UI 复刻，构建更快、依赖更少）。
        zenit.attach(zenit_dep, mockup_exe);
        mockup_exe.root_module.addSystemFrameworkPath(.{ .cwd_relative = "/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk/System/Library/Frameworks" });
        mockup_exe.root_module.addSystemIncludePath(.{ .cwd_relative = "/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk/usr/include" });
        mockup_exe.root_module.addLibraryPath(.{ .cwd_relative = "/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk/usr/lib" });
        // 专用 install step：`zig build mockup -Dmockup=<name>` 只构建预览程序，
        // 不触发主程序构建（否则并行开发时互相拖慢）。
        const mockup_step = b.step("mockup", "Build one design-mockup preview executable (-Dmockup=<name>)");
        mockup_step.dependOn(&b.addInstallArtifact(mockup_exe, .{}).step);
    }

    // Explicit component acceptance only; never part of the default install.
    // This mounts production SettingsController/content without the app shell.
    const settings_preview = b.addExecutable(.{
        .name = "settings-preview-runner",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/settings_preview_runner.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    zenit.attach(zenit_dep, settings_preview);
    settings_preview.root_module.addSystemFrameworkPath(.{ .cwd_relative = "/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk/System/Library/Frameworks" });
    settings_preview.root_module.addSystemIncludePath(.{ .cwd_relative = "/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk/usr/include" });
    settings_preview.root_module.addLibraryPath(.{ .cwd_relative = "/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk/usr/lib" });
    b.step("settings-preview", "Build the read-only planning component acceptance runner").dependOn(&b.addInstallArtifact(settings_preview, .{}).step);

    if (test_mode) {
        const files_preview = b.addExecutable(.{ .name = "file-workspace-preview", .root_module = b.createModule(.{ .root_source_file = b.path("src/file_workspace_native_fixture.zig"), .target = target, .optimize = optimize }) });
        zenit.attach(zenit_dep, files_preview);
        files_preview.root_module.addSystemFrameworkPath(.{ .cwd_relative = "/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk/System/Library/Frameworks" });
        files_preview.root_module.addSystemIncludePath(.{ .cwd_relative = "/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk/usr/include" });
        files_preview.root_module.addLibraryPath(.{ .cwd_relative = "/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk/usr/lib" });
        files_preview.root_module.addImport("icon_ir", zenit_dep.module("icon_ir"));
        b.step("file-workspace-preview", "Build the production file component for isolated theme acceptance").dependOn(&b.addInstallArtifact(files_preview, .{}).step);
    }

    // Retained legacy authentication component acceptance; never installed by default.
    const auth_preview = b.addExecutable(.{ .name = "auth-challenge-preview", .root_module = b.createModule(.{ .root_source_file = b.path("src/auth_challenge_native_fixture.zig"), .target = target, .optimize = optimize }) });
    zenit.attach(zenit_dep, auth_preview);
    auth_preview.root_module.addSystemFrameworkPath(.{ .cwd_relative = "/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk/System/Library/Frameworks" });
    auth_preview.root_module.addSystemIncludePath(.{ .cwd_relative = "/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk/usr/include" });
    auth_preview.root_module.addLibraryPath(.{ .cwd_relative = "/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk/usr/lib" });
    auth_preview.root_module.addImport("icon_ir", zenit_dep.module("icon_ir"));
    b.step("auth-challenge-preview", "Build isolated retained authentication component acceptance window").dependOn(&b.addInstallArtifact(auth_preview, .{}).step);

    const connection_progress_preview = b.addExecutable(.{ .name = "connection-progress-preview", .root_module = b.createModule(.{ .root_source_file = b.path("src/connection_progress_preview_runner.zig"), .target = target, .optimize = optimize }) });
    zenit.attach(zenit_dep, connection_progress_preview);
    connection_progress_preview.root_module.addImport("generated_ssh_session", ssh_session_translate.createModule());
    connection_progress_preview.root_module.addImport("generated_ssh_channel", ssh_channel_translate.createModule());
    connection_progress_preview.root_module.addSystemFrameworkPath(.{ .cwd_relative = "/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk/System/Library/Frameworks" });
    connection_progress_preview.root_module.addSystemIncludePath(.{ .cwd_relative = "/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk/usr/include" });
    connection_progress_preview.root_module.addLibraryPath(.{ .cwd_relative = "/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk/usr/lib" });
    b.step("connection-progress-preview", "Build isolated production connection progress view").dependOn(&b.addInstallArtifact(connection_progress_preview, .{}).step);

    const events_preview = b.addExecutable(.{ .name = "transfer-events-preview", .root_module = b.createModule(.{ .root_source_file = b.path("src/transfer_events_native_fixture.zig"), .target = target, .optimize = optimize }) });
    zenit.attach(zenit_dep, events_preview);
    events_preview.root_module.addSystemFrameworkPath(.{ .cwd_relative = "/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk/System/Library/Frameworks" });
    events_preview.root_module.addSystemIncludePath(.{ .cwd_relative = "/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk/usr/include" });
    events_preview.root_module.addLibraryPath(.{ .cwd_relative = "/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk/usr/lib" });
    events_preview.root_module.addImport("icon_ir", zenit_dep.module("icon_ir"));
    b.step("transfer-events-preview", "Build isolated native transfer event acceptance fixture").dependOn(&b.addInstallArtifact(events_preview, .{}).step);

    const conflict_preview = b.addExecutable(.{ .name = "transfer-conflict-preview", .root_module = b.createModule(.{ .root_source_file = b.path("src/transfer_conflict_native_fixture.zig"), .target = target, .optimize = optimize }) });
    zenit.attach(zenit_dep, conflict_preview);
    conflict_preview.root_module.addSystemFrameworkPath(.{ .cwd_relative = "/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk/System/Library/Frameworks" });
    conflict_preview.root_module.addSystemIncludePath(.{ .cwd_relative = "/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk/usr/include" });
    conflict_preview.root_module.addLibraryPath(.{ .cwd_relative = "/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk/usr/lib" });
    conflict_preview.root_module.addImport("icon_ir", zenit_dep.module("icon_ir"));
    b.step("transfer-conflict-preview", "Build isolated native transfer conflict acceptance fixture").dependOn(&b.addInstallArtifact(conflict_preview, .{}).step);

    const transfer_controls_preview = b.addExecutable(.{ .name = "transfer-controls-preview", .root_module = b.createModule(.{ .root_source_file = b.path("src/transfer_controls_preview_runner.zig"), .target = target, .optimize = optimize }) });
    const transfer_controls_options = b.addOptions();
    transfer_controls_options.addOption([]const u8, "presentation", b.option([]const u8, "transfer-preview-presentation", "global_popover, session_popover or session_tray") orelse "global_popover");
    transfer_controls_preview.root_module.addOptions("preview_options", transfer_controls_options);
    zenit.attach(zenit_dep, transfer_controls_preview);
    transfer_controls_preview.root_module.addSystemFrameworkPath(.{ .cwd_relative = "/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk/System/Library/Frameworks" });
    transfer_controls_preview.root_module.addSystemIncludePath(.{ .cwd_relative = "/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk/usr/include" });
    transfer_controls_preview.root_module.addLibraryPath(.{ .cwd_relative = "/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk/usr/lib" });
    transfer_controls_preview.root_module.addImport("icon_ir", zenit_dep.module("icon_ir"));
    b.step("transfer-controls-preview", "Build shared Figma transfer cards and close-control acceptance fixture").dependOn(&b.addInstallArtifact(transfer_controls_preview, .{}).step);

    const run = b.addRunArtifact(exe);
    run.step.dependOn(b.getInstallStep());
    b.step("run", "Run the ZeroWork bootstrap").dependOn(&run.step);

    const root_test_filter = b.option([]const u8, "test-filter", "Run only matching unit and contract tests");
    const tests = b.addTest(.{ .filters = if (root_test_filter) |filter| &.{filter} else &.{}, .root_module = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    }) });
    // A separate module keeps native test bridges out of the production
    // module, while collecting every root.zig test in this test binary.
    tests.root_module.addImport("ui", zenit_dep.module("ui"));
    tests.root_module.addImport("zenit_app", zenit_dep.module("zenit_app"));
    tests.root_module.addImport("icon_ir", zenit_dep.module("icon_ir"));
    // Production terminal event tests instantiate the real input path without
    // opening an SSH connection. Supply the same native ABI as the app.
    tests.root_module.addImport("generated_ghostty_vt", ghostty_translate.createModule());
    tests.root_module.addImport("generated_ssh_session", ssh_session_translate.createModule());
    tests.root_module.addImport("generated_ssh_channel", ssh_channel_translate.createModule());
    tests.root_module.addLibraryPath(b.path("vendor/libghostty-vt"));
    tests.root_module.linkSystemLibrary("ghostty-vt", .{});
    tests.root_module.addIncludePath(b.path("vendor/libssh2/include"));
    tests.root_module.addIncludePath(b.path("src/proto/ssh"));
    tests.root_module.addCSourceFiles(.{ .files = &.{ "src/proto/ssh/libssh2_channel_shim.c", "src/proto/ssh/libssh2_session_shim.c", "src/local/darwin_process.c", "src/local/trusted_edit_native.c", "src/local/secret_native.c" }, .flags = &.{"-std=c11"} });
    tests.root_module.addCSourceFile(.{ .file = b.path("src/platform/data_scope_lock.c"), .flags = &.{"-std=c11"} });
    tests.root_module.addLibraryPath(b.path("vendor/libssh2/src/.libs"));
    tests.root_module.addLibraryPath(b.path("vendor/mbedtls/library"));
    tests.root_module.linkSystemLibrary("ssh2", .{});
    tests.step.dependOn(&verify_ssh.step);
    tests.root_module.linkSystemLibrary("mbedcrypto", .{});
    tests.root_module.linkSystemLibrary("z", .{});
    addUrlFetchFrameworks(tests.root_module);

    addCoreTextBridgeForTest(zenit_dep, tests);
    tests.root_module.addCSourceFile(.{ .file = zenit_dep.path("native/macos/metal_bridge.m"), .flags = &.{"-fobjc-arc"} });
    tests.root_module.linkFramework("Metal", .{});
    tests.root_module.linkFramework("QuartzCore", .{});
    const root_test_step = b.step("test", "Run unit and contract tests");
    const root_test_files = b.addWriteFiles();
    const root_test_binary = root_test_files.addCopyFile(tests.getEmittedBin(), "unit-tests");
    _ = root_test_files.addCopyFile(zsh_bridge_file, "zw_ipc.so");
    _ = root_test_files.addCopyFile(execution_bridge_file, "zw_execution.so");
    _ = root_test_files.addCopyFile(secret_consumer_file, "zw_secret_consume.so");
    _ = root_test_files.addCopyFile(execution_guard_file, "zw_execution_guard");
    const root_test_run = std.Build.Step.Run.create(b, "run unit and contract tests");
    root_test_run.addFileArg(root_test_binary);
    root_test_step.dependOn(&root_test_run.step);
    // Every Security entry point is mocked: this regression cannot access a
    // user's Keychain or display authentication UI.
    const native_credentials = b.addSystemCommand(&.{ "xcrun", "clang", "-Wall", "-Wextra", "-Werror" });
    native_credentials.addFileArg(b.path("src/platform/macos_credentials_tests.m"));
    native_credentials.addArgs(&.{ "-framework", "Security", "-framework", "CoreFoundation", "-o" });
    const native_credentials_binary = native_credentials.addOutputFileArg("credentials-native-mock");
    const native_credentials_run = std.Build.Step.Run.create(b, "credentials-native-mock");
    native_credentials_run.addFileArg(native_credentials_binary);
    root_test_step.dependOn(&native_credentials_run.step);
    b.step("test-credentials-native", "Run credential cache and no-UI regressions with mocked Security APIs").dependOn(&native_credentials_run.step);
    const secret_transport = b.addSystemCommand(&.{ "xcrun", "clang", "-target", "arm64-apple-macos14.0", "-std=c11", "-Wall", "-Wextra", "-Werror" });
    secret_transport.addFileArg(b.path("src/local/secret_native.c"));
    secret_transport.addFileArg(b.path("src/local/secret_native_tests.c"));
    secret_transport.addArg("-o");
    const secret_transport_binary = secret_transport.addOutputFileArg("secret-native-transport-tests");
    const secret_transport_run = std.Build.Step.Run.create(b, "secret-native-transport-tests");
    secret_transport_run.addFileArg(secret_transport_binary);
    b.step("test-secret-transport", "Run isolated fresh-connection secret transport and child-PID rejection tests").dependOn(&secret_transport_run.step);

    // Real child processes exercise runtime flock ownership without launching
    // ZeroWork, touching application data, or calling Security APIs.
    const scope_native = b.addSystemCommand(&.{ "xcrun", "clang", "-std=c11", "-Wall", "-Wextra", "-Werror" });
    scope_native.addFileArg(b.path("src/platform/data_scope_lock_tests.c"));
    scope_native.addArgs(&.{ "-framework", "CoreFoundation", "-o" });
    const scope_native_binary = scope_native.addOutputFileArg("data-scope-lock-tests");
    const scope_native_run = std.Build.Step.Run.create(b, "data-scope-lock-tests");
    scope_native_run.addFileArg(scope_native_binary);
    root_test_step.dependOn(&scope_native_run.step);
    b.step("test-data-scope-lock", "Run real-process data scope lock and crash recovery regressions").dependOn(&scope_native_run.step);

    // Local process/VT integration stays headless and uses isolated test data.
    const local_tests_step = b.step("test-local", "Run real local PTY, terminal controller and adapter tests");
    const local_test_filter = b.option([]const u8, "local-test-filter", "Run only matching local terminal tests");
    for ([_][]const u8{ "src/local_process_tests.zig", "src/terminal_controller_tests.zig", "src/local_adapter_tests.zig", "src/local_trusted_edit_tests.zig", "src/terminal_execution_tests.zig" }) |source| {
        const local_tests = b.addTest(.{ .filters = if (local_test_filter) |filter| &.{filter} else &.{}, .root_module = b.createModule(.{
            .root_source_file = b.path(source),
            .target = target,
            .optimize = optimize,
        }) });
        local_tests.root_module.addImport("generated_ghostty_vt", ghostty_translate.createModule());
        local_tests.root_module.addLibraryPath(b.path("vendor/libghostty-vt"));
        local_tests.root_module.linkSystemLibrary("ghostty-vt", .{});
        local_tests.root_module.addCSourceFile(.{ .file = b.path("src/local/darwin_process.c"), .flags = &.{"-std=c11"} });
        local_tests.root_module.addCSourceFile(.{ .file = b.path("src/local/trusted_edit_native.c"), .flags = &.{"-std=c11"} });
        local_tests.root_module.addCSourceFile(.{ .file = b.path("src/local/secret_native.c"), .flags = &.{"-std=c11"} });
        local_tests.root_module.addSystemIncludePath(.{ .cwd_relative = "/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk/usr/include" });
        local_tests.root_module.addLibraryPath(.{ .cwd_relative = "/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk/usr/lib" });
        local_tests.root_module.link_libc = true;
        if (std.mem.eql(u8, source, "src/local_adapter_tests.zig") or std.mem.eql(u8, source, "src/local_trusted_edit_tests.zig") or std.mem.eql(u8, source, "src/terminal_execution_tests.zig")) {
            // SessionHost's registry now contains public UI/service contracts.
            // These runners need the same linked ABI while remaining headless.
            local_tests.root_module.addImport("ui", zenit_dep.module("ui"));
            local_tests.root_module.addImport("zenit_app", zenit_dep.module("zenit_app"));
            local_tests.root_module.addImport("icon_ir", zenit_dep.module("icon_ir"));
            local_tests.root_module.addImport("generated_ssh_session", ssh_session_translate.createModule());
            local_tests.root_module.addImport("generated_ssh_channel", ssh_channel_translate.createModule());
            local_tests.root_module.addIncludePath(b.path("vendor/libssh2/include"));
            local_tests.root_module.addIncludePath(b.path("src/proto/ssh"));
            local_tests.root_module.addCSourceFiles(.{ .files = &.{ "src/proto/ssh/libssh2_channel_shim.c", "src/proto/ssh/libssh2_session_shim.c" }, .flags = &.{"-std=c11"} });
            local_tests.root_module.addLibraryPath(b.path("vendor/libssh2/src/.libs"));
            local_tests.root_module.addLibraryPath(b.path("vendor/mbedtls/library"));
            local_tests.root_module.linkSystemLibrary("ssh2", .{});
            local_tests.step.dependOn(&verify_ssh.step);
            local_tests.root_module.linkSystemLibrary("mbedcrypto", .{});
            local_tests.root_module.linkSystemLibrary("z", .{});
            addCoreTextBridgeForTest(zenit_dep, local_tests);
            local_tests.root_module.addCSourceFile(.{ .file = zenit_dep.path("native/macos/metal_bridge.m"), .flags = &.{"-fobjc-arc"} });
            local_tests.root_module.linkFramework("Metal", .{});
            local_tests.root_module.linkFramework("QuartzCore", .{});
        }
        if (std.mem.eql(u8, source, "src/local_trusted_edit_tests.zig") or std.mem.eql(u8, source, "src/terminal_execution_tests.zig")) {
            // ZSH resolves its private module beside this isolated test binary,
            // exactly as the installed application does.
            const files = b.addWriteFiles();
            const runner = files.addCopyFile(local_tests.getEmittedBin(), if (std.mem.eql(u8, source, "src/terminal_execution_tests.zig")) "terminal-execution-tests" else "trusted-edit-tests");
            _ = files.addCopyFile(zsh_bridge_file, "zw_ipc.so");
            _ = files.addCopyFile(execution_bridge_file, "zw_execution.so");
            _ = files.addCopyFile(secret_consumer_file, "zw_secret_consume.so");
            _ = files.addCopyFile(execution_guard_file, "zw_execution_guard");
            const trusted_run = std.Build.Step.Run.create(b, "run trusted ZLE tests");
            trusted_run.addFileArg(runner);
            local_tests_step.dependOn(&trusted_run.step);
            b.step(if (std.mem.eql(u8, source, "src/terminal_execution_tests.zig")) "test-terminal-execution" else "test-trusted-edit", "Run isolated real ZSH integration tests").dependOn(&trusted_run.step);
        } else {
            const local_run = b.addRunArtifact(local_tests);
            local_tests_step.dependOn(&local_run.step);
            if (std.mem.eql(u8, source, "src/local_adapter_tests.zig")) b.step("test-local-adapter", "Run local PTY adapter regressions").dependOn(&local_run.step);
        }
    }

    const notification_preview = b.addExecutable(.{ .name = "notification-preview", .root_module = b.createModule(.{
        .root_source_file = b.path("src/notification_preview_runner.zig"),
        .target = target,
        .optimize = optimize,
    }) });
    zenit.attach(zenit_dep, notification_preview);
    notification_preview.root_module.addSystemFrameworkPath(.{ .cwd_relative = "/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk/System/Library/Frameworks" });
    notification_preview.root_module.addSystemIncludePath(.{ .cwd_relative = "/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk/usr/include" });
    notification_preview.root_module.addLibraryPath(.{ .cwd_relative = "/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk/usr/lib" });
    b.step("test-notification-preview", "Build isolated native notification acceptance fixture").dependOn(&b.addInstallArtifact(notification_preview, .{}).step);
    for ([_][]const u8{ "host-approval", "task-finish", "execution-result", "inventory-grant" }, [_][]const u8{ "src/host_approval_preview_runner.zig", "src/task_finish_preview_runner.zig", "src/execution_result_preview_runner.zig", "src/inventory_grant_preview_runner.zig" }) |name, source| {
        const preview = b.addExecutable(.{ .name = b.fmt("{s}-preview", .{name}), .root_module = b.createModule(.{ .root_source_file = b.path(source), .target = target, .optimize = optimize }) });
        zenit.attach(zenit_dep, preview);
        preview.root_module.addImport("icon_ir", zenit_dep.module("icon_ir"));
        preview.root_module.addSystemFrameworkPath(.{ .cwd_relative = "/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk/System/Library/Frameworks" });
        preview.root_module.addSystemIncludePath(.{ .cwd_relative = "/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk/usr/include" });
        preview.root_module.addLibraryPath(.{ .cwd_relative = "/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk/usr/lib" });
        b.step(b.fmt("{s}-preview", .{name}), b.fmt("Build isolated production {s} UI acceptance window", .{name})).dependOn(&b.addInstallArtifact(preview, .{}).step);
    }

    const font_tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("src/appearance_font_tests.zig"),
        .target = target,
        .optimize = optimize,
    }) });
    font_tests.root_module.addImport("zenit_app", zenit_dep.module("zenit_app"));
    addCoreTextBridgeForTest(zenit_dep, font_tests);
    b.step("test-font", "Resolve appearance fonts and verify actual native metrics without windows").dependOn(&b.addRunArtifact(font_tests).step);

    const appearance_tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("src/appearance_tests.zig"),
        .target = target,
        .optimize = optimize,
    }) });
    appearance_tests.root_module.addImport("ui", zenit_dep.module("ui"));
    appearance_tests.root_module.addImport("zenit_app", zenit_dep.module("zenit_app"));
    appearance_tests.root_module.addImport("icon_ir", zenit_dep.module("icon_ir"));
    // Production terminal event tests instantiate the real input path without
    // opening an SSH connection. Supply the same native ABI as the app.
    appearance_tests.root_module.addImport("generated_ghostty_vt", ghostty_translate.createModule());
    appearance_tests.root_module.addImport("generated_ssh_session", ssh_session_translate.createModule());
    appearance_tests.root_module.addImport("generated_ssh_channel", ssh_channel_translate.createModule());
    appearance_tests.root_module.addLibraryPath(b.path("vendor/libghostty-vt"));
    appearance_tests.root_module.linkSystemLibrary("ghostty-vt", .{});
    appearance_tests.root_module.addIncludePath(b.path("vendor/libssh2/include"));
    appearance_tests.root_module.addIncludePath(b.path("src/proto/ssh"));
    appearance_tests.root_module.addCSourceFiles(.{ .files = &.{ "src/proto/ssh/libssh2_channel_shim.c", "src/proto/ssh/libssh2_session_shim.c", "src/local/darwin_process.c", "src/local/trusted_edit_native.c", "src/local/secret_native.c" }, .flags = &.{"-std=c11"} });
    appearance_tests.root_module.addLibraryPath(b.path("vendor/libssh2/src/.libs"));
    appearance_tests.root_module.addLibraryPath(b.path("vendor/mbedtls/library"));
    appearance_tests.root_module.linkSystemLibrary("ssh2", .{});
    appearance_tests.step.dependOn(&verify_ssh.step);
    appearance_tests.root_module.linkSystemLibrary("mbedcrypto", .{});
    appearance_tests.root_module.linkSystemLibrary("z", .{});

    addCoreTextBridgeForTest(zenit_dep, appearance_tests);
    appearance_tests.root_module.addCSourceFile(.{ .file = zenit_dep.path("native/macos/metal_bridge.m"), .flags = &.{"-fobjc-arc"} });
    appearance_tests.root_module.linkFramework("Metal", .{});
    appearance_tests.root_module.linkFramework("QuartzCore", .{});
    appearance_tests.root_module.link_libc = true;
    for ([_][]const u8{ "CoreFoundation", "ImageIO", "CoreGraphics" }) |framework| {
        appearance_tests.root_module.linkFramework(framework, .{});
    }
    appearance_tests.root_module.addSystemFrameworkPath(.{ .cwd_relative = "/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk/System/Library/Frameworks" });
    appearance_tests.root_module.addSystemIncludePath(.{ .cwd_relative = "/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk/usr/include" });
    appearance_tests.root_module.addLibraryPath(.{ .cwd_relative = "/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk/usr/lib" });
    b.step("test-appearance", "Run headless appearance asset, theme and configuration tests").dependOn(&b.addRunArtifact(appearance_tests).step);

    // transfer_panel 的整面板装配测试要跑 zenit 布局 → 独立测试模块（zenit
    // 注释警告：C 源挂在被 exe 依赖的模块上会传播，core 挂了会让 exe 里
    // zenit .m 桥出现两份 → duplicate symbol。独立模块只在此路径挂 .m）。
    const ui_test_filter = b.option([]const u8, "ui-test-filter", "Run only matching UI tests");
    const ui_tests = b.addTest(.{ .filters = if (ui_test_filter) |filter| &.{filter} else &.{}, .root_module = b.createModule(.{
        .root_source_file = b.path("src/transfer_panel_tests.zig"),
        .target = target,
        .optimize = optimize,
    }) });
    ui_tests.root_module.addImport("ui", zenit_dep.module("ui"));
    ui_tests.root_module.addImport("zenit_app", zenit_dep.module("zenit_app"));
    ui_tests.root_module.addImport("icon_ir", zenit_dep.module("icon_ir"));
    // Production terminal event tests instantiate the real input path without
    // opening an SSH connection. Supply the same native ABI as the app.
    ui_tests.root_module.addImport("generated_ghostty_vt", ghostty_translate.createModule());
    ui_tests.root_module.addImport("generated_ssh_session", ssh_session_translate.createModule());
    ui_tests.root_module.addImport("generated_ssh_channel", ssh_channel_translate.createModule());
    ui_tests.root_module.addLibraryPath(b.path("vendor/libghostty-vt"));
    ui_tests.root_module.linkSystemLibrary("ghostty-vt", .{});
    ui_tests.root_module.addIncludePath(b.path("vendor/libssh2/include"));
    ui_tests.root_module.addIncludePath(b.path("src/proto/ssh"));
    ui_tests.root_module.addCSourceFiles(.{ .files = &.{ "src/proto/ssh/libssh2_channel_shim.c", "src/proto/ssh/libssh2_session_shim.c", "src/local/darwin_process.c", "src/local/trusted_edit_native.c", "src/local/secret_native.c" }, .flags = &.{"-std=c11"} });
    ui_tests.root_module.addLibraryPath(b.path("vendor/libssh2/src/.libs"));
    ui_tests.root_module.addLibraryPath(b.path("vendor/mbedtls/library"));
    ui_tests.root_module.linkSystemLibrary("ssh2", .{});
    ui_tests.step.dependOn(&verify_ssh.step);
    ui_tests.root_module.linkSystemLibrary("mbedcrypto", .{});
    ui_tests.root_module.linkSystemLibrary("z", .{});

    addCoreTextBridgeForTest(zenit_dep, ui_tests);
    ui_tests.root_module.addCSourceFile(.{ .file = zenit_dep.path("native/macos/metal_bridge.m"), .flags = &.{"-fobjc-arc"} });
    ui_tests.root_module.linkFramework("Metal", .{});
    ui_tests.root_module.linkFramework("QuartzCore", .{});
    const ui_test_files = b.addWriteFiles();
    const ui_test_binary = ui_test_files.addCopyFile(ui_tests.getEmittedBin(), "ui-tests");
    _ = ui_test_files.addCopyFile(zsh_bridge_file, "zw_ipc.so");
    _ = ui_test_files.addCopyFile(execution_bridge_file, "zw_execution.so");
    _ = ui_test_files.addCopyFile(secret_consumer_file, "zw_secret_consume.so");
    _ = ui_test_files.addCopyFile(execution_guard_file, "zw_execution_guard");
    const run_ui_tests = std.Build.Step.Run.create(b, "run transfer-panel and layout tests");
    run_ui_tests.addFileArg(ui_test_binary);
    b.step("test-ui", "Run transfer-panel/zenit-layout tests").dependOn(&run_ui_tests.step);

    // API-v2 acceptance runs separately so the non-terminal fixture is never
    // registered or linked by the production executable.
    const plugin_tests = b.addTest(.{ .filters = &.{"fixture "}, .root_module = b.createModule(.{
        .root_source_file = b.path("src/plugin_fixture_tests.zig"),
        .target = target,
        .optimize = optimize,
    }) });
    plugin_tests.root_module.addImport("ui", zenit_dep.module("ui"));
    plugin_tests.root_module.addImport("zenit_app", zenit_dep.module("zenit_app"));
    plugin_tests.root_module.addImport("icon_ir", zenit_dep.module("icon_ir"));
    plugin_tests.root_module.addImport("generated_ghostty_vt", ghostty_translate.createModule());
    plugin_tests.root_module.addImport("generated_ssh_session", ssh_session_translate.createModule());
    plugin_tests.root_module.addImport("generated_ssh_channel", ssh_channel_translate.createModule());
    plugin_tests.root_module.addLibraryPath(b.path("vendor/libghostty-vt"));
    plugin_tests.root_module.linkSystemLibrary("ghostty-vt", .{});
    plugin_tests.root_module.addIncludePath(b.path("vendor/libssh2/include"));
    plugin_tests.root_module.addIncludePath(b.path("src/proto/ssh"));
    plugin_tests.root_module.addCSourceFiles(.{ .files = &.{ "src/proto/ssh/libssh2_channel_shim.c", "src/proto/ssh/libssh2_session_shim.c", "src/local/darwin_process.c", "src/local/trusted_edit_native.c", "src/local/secret_native.c" }, .flags = &.{"-std=c11"} });
    plugin_tests.root_module.addLibraryPath(b.path("vendor/libssh2/src/.libs"));
    plugin_tests.root_module.addLibraryPath(b.path("vendor/mbedtls/library"));
    plugin_tests.root_module.linkSystemLibrary("ssh2", .{});
    plugin_tests.step.dependOn(&verify_ssh.step);
    plugin_tests.root_module.linkSystemLibrary("mbedcrypto", .{});
    plugin_tests.root_module.linkSystemLibrary("z", .{});
    addCoreTextBridgeForTest(zenit_dep, plugin_tests);
    plugin_tests.root_module.addCSourceFile(.{ .file = zenit_dep.path("native/macos/metal_bridge.m"), .flags = &.{"-fobjc-arc"} });
    plugin_tests.root_module.linkFramework("Metal", .{});
    plugin_tests.root_module.linkFramework("QuartzCore", .{});
    b.step("test-plugin-fixture", "Run the non-terminal plugin acceptance contract").dependOn(&b.addRunArtifact(plugin_tests).step);

    const transport_runner = b.addExecutable(.{ .name = "connection-transport-runner", .root_module = b.createModule(.{
        .root_source_file = b.path("src/connection_transport_runner.zig"),
        .target = target,
        .optimize = optimize,
    }) });
    transport_runner.root_module.addImport("generated_ssh_session", ssh_session_translate.createModule());
    transport_runner.root_module.addImport("generated_ssh_channel", ssh_channel_translate.createModule());
    transport_runner.root_module.addIncludePath(b.path("vendor/libssh2/include"));
    transport_runner.root_module.addIncludePath(b.path("src/proto/ssh"));
    transport_runner.root_module.addCSourceFiles(.{ .files = &.{ "src/proto/ssh/libssh2_channel_shim.c", "src/proto/ssh/libssh2_session_shim.c" }, .flags = &.{"-std=c11"} });
    transport_runner.root_module.addLibraryPath(b.path("vendor/libssh2/src/.libs"));
    transport_runner.root_module.addLibraryPath(b.path("vendor/mbedtls/library"));
    transport_runner.root_module.addSystemIncludePath(.{ .cwd_relative = "/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk/usr/include" });
    transport_runner.root_module.addLibraryPath(.{ .cwd_relative = "/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk/usr/lib" });
    transport_runner.root_module.linkSystemLibrary("ssh2", .{});
    transport_runner.step.dependOn(&verify_ssh.step);
    transport_runner.root_module.linkSystemLibrary("mbedcrypto", .{});
    transport_runner.root_module.linkSystemLibrary("z", .{});
    b.step("transport-acceptance", "Build the opt-in real SSH independent transport runner").dependOn(&b.addInstallArtifact(transport_runner, .{}).step);

    const hardening = b.step("ssh-hardening-acceptance", "Build owned SSH timeout and liveness acceptance runners");
    for ([_]struct { name: []const u8, source: []const u8 }{
        .{ .name = "ssh-connection-wait-runner", .source = "src/ssh_connection_wait_runner.zig" },
        .{ .name = "ssh-hardening-runner", .source = "src/ssh_hardening_runner.zig" },
        .{ .name = "ssh-auth-loopback-runner", .source = "src/ssh_auth_loopback_runner.zig" },
    }) |spec| {
        const runner = b.addExecutable(.{ .name = spec.name, .root_module = b.createModule(.{
            .root_source_file = b.path(spec.source),
            .target = target,
            .optimize = optimize,
        }) });
        runner.step.dependOn(&verify_ssh.step);
        runner.root_module.addImport("generated_ssh_session", ssh_session_translate.createModule());
        runner.root_module.addImport("generated_ssh_channel", ssh_channel_translate.createModule());
        runner.root_module.addIncludePath(b.path("vendor/libssh2/include"));
        runner.root_module.addIncludePath(b.path("src/proto/ssh"));
        runner.root_module.addCSourceFiles(.{ .files = &.{ "src/proto/ssh/libssh2_channel_shim.c", "src/proto/ssh/libssh2_session_shim.c" }, .flags = &.{"-std=c11"} });
        runner.root_module.addLibraryPath(b.path("vendor/libssh2/src/.libs"));
        runner.root_module.addLibraryPath(b.path("vendor/mbedtls/library"));
        runner.root_module.linkSystemLibrary("ssh2", .{});
        runner.root_module.linkSystemLibrary("mbedcrypto", .{});
        runner.root_module.linkSystemLibrary("z", .{});
        runner.root_module.addSystemIncludePath(.{ .cwd_relative = "/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk/usr/include" });
        runner.root_module.addLibraryPath(.{ .cwd_relative = "/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk/usr/lib" });
        runner.root_module.link_libc = true;
        hardening.dependOn(&b.addInstallArtifact(runner, .{}).step);
    }

    const disconnect_acceptance = b.step("ssh-disconnect-acceptance", "Build headless explicit SSH disconnect lifecycle acceptance runner");
    const bootstrap_acceptance = b.step("ssh-bootstrap-acceptance", "Build headless production BootstrapV1 loopback acceptance runner");
    const forward_acceptance = b.step("forward-acceptance", "Build real forwarding and production Worker/Relay lifecycle acceptance runners");
    const shared_acceptance = b.step("shared-connection-acceptance", "Build independent SSH channel and reconnect acceptance runner");
    const reconnect_acceptance = b.step("reconnect-acceptance", "Build original-terminal reconnect acceptance runner");
    for ([_]struct { name: []const u8, source: []const u8 }{
        .{ .name = "ssh-disconnect-runner", .source = "src/ssh_disconnect_runner.zig" },
        .{ .name = "ssh-bootstrap-runner", .source = "src/ssh_bootstrap_runner.zig" },
        .{ .name = "fixed-forward-runner", .source = "src/fixed_forward_runner.zig" },
        .{ .name = "socks-worker-host-runner", .source = "src/socks_worker_host_runner.zig" },
        .{ .name = "forward-load-runner", .source = "src/forward_load_runner.zig" },
        .{ .name = "ssh-connection-details-runner", .source = "src/ssh_connection_details_runner.zig" },
        .{ .name = "ssh-reconnect-loopback-runner", .source = "src/ssh_reconnect_loopback_runner.zig" },
        .{ .name = "ssh-shared-connection-runner", .source = "src/ssh_shared_connection_runner.zig" },
    }) |runner| {
        const fixed_forward_runner = b.addExecutable(.{ .name = runner.name, .root_module = b.createModule(.{
            .root_source_file = b.path(runner.source),
            .target = target,
            .optimize = optimize,
        }) });
        fixed_forward_runner.root_module.addImport("ui", zenit_dep.module("ui"));
        fixed_forward_runner.root_module.addImport("icon_ir", zenit_dep.module("icon_ir"));
        fixed_forward_runner.root_module.addImport("generated_ssh_session", ssh_session_translate.createModule());
        fixed_forward_runner.root_module.addImport("generated_ssh_channel", ssh_channel_translate.createModule());
        fixed_forward_runner.root_module.addImport("generated_ghostty_vt", ghostty_translate.createModule());
        fixed_forward_runner.root_module.addLibraryPath(b.path("vendor/libghostty-vt"));
        fixed_forward_runner.root_module.linkSystemLibrary("ghostty-vt", .{});
        fixed_forward_runner.root_module.addIncludePath(b.path("vendor/libssh2/include"));
        fixed_forward_runner.root_module.addIncludePath(b.path("src/proto/ssh"));
        fixed_forward_runner.root_module.addCSourceFiles(.{ .files = &.{ "src/proto/ssh/libssh2_channel_shim.c", "src/proto/ssh/libssh2_session_shim.c" }, .flags = &.{"-std=c11"} });
        fixed_forward_runner.root_module.addLibraryPath(b.path("vendor/libssh2/src/.libs"));
        fixed_forward_runner.root_module.addLibraryPath(b.path("vendor/mbedtls/library"));
        fixed_forward_runner.root_module.addSystemIncludePath(.{ .cwd_relative = "/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk/usr/include" });
        fixed_forward_runner.root_module.addLibraryPath(.{ .cwd_relative = "/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk/usr/lib" });
        fixed_forward_runner.root_module.linkSystemLibrary("ssh2", .{});
        fixed_forward_runner.step.dependOn(&verify_ssh.step);
        fixed_forward_runner.root_module.linkSystemLibrary("mbedcrypto", .{});
        fixed_forward_runner.root_module.linkSystemLibrary("z", .{});
        addCoreTextBridgeForTest(zenit_dep, fixed_forward_runner);
        if (std.mem.eql(u8, runner.name, "ssh-disconnect-runner") or std.mem.eql(u8, runner.name, "ssh-bootstrap-runner") or std.mem.eql(u8, runner.name, "ssh-reconnect-loopback-runner") or std.mem.eql(u8, runner.name, "ssh-shared-connection-runner")) {
            fixed_forward_runner.root_module.addCSourceFiles(.{ .files = &.{ "src/local/darwin_process.c", "src/local/trusted_edit_native.c", "src/local/secret_native.c" }, .flags = &.{"-std=c11"} });
            fixed_forward_runner.root_module.addCSourceFile(.{ .file = b.path("src/platform/macos_credentials.m"), .flags = &.{} });
            fixed_forward_runner.root_module.linkFramework("Security", .{});
        }
        const runner_install = b.addInstallArtifact(fixed_forward_runner, .{});
        forward_acceptance.dependOn(&runner_install.step);
        if (std.mem.eql(u8, runner.name, "ssh-disconnect-runner")) disconnect_acceptance.dependOn(&runner_install.step);
        if (std.mem.eql(u8, runner.name, "ssh-bootstrap-runner")) bootstrap_acceptance.dependOn(&runner_install.step);
        if (std.mem.eql(u8, runner.name, "ssh-shared-connection-runner")) shared_acceptance.dependOn(&runner_install.step);
        if (std.mem.eql(u8, runner.name, "ssh-reconnect-loopback-runner")) reconnect_acceptance.dependOn(&runner_install.step);
    }

    const forward_preview = b.addExecutable(.{ .name = "forward-config-preview", .root_module = b.createModule(.{
        .root_source_file = b.path("src/forward_config_preview_runner.zig"),
        .target = target,
        .optimize = optimize,
    }) });
    zenit.attach(zenit_dep, forward_preview);
    forward_preview.root_module.addImport("generated_ssh_session", ssh_session_translate.createModule());
    forward_preview.root_module.addImport("generated_ssh_channel", ssh_channel_translate.createModule());
    forward_preview.root_module.addIncludePath(b.path("vendor/libssh2/include"));
    forward_preview.root_module.addIncludePath(b.path("src/proto/ssh"));
    forward_preview.root_module.addCSourceFiles(.{ .files = &.{ "src/proto/ssh/libssh2_channel_shim.c", "src/proto/ssh/libssh2_session_shim.c" }, .flags = &.{"-std=c11"} });
    forward_preview.root_module.addLibraryPath(b.path("vendor/libssh2/src/.libs"));
    forward_preview.root_module.addLibraryPath(b.path("vendor/mbedtls/library"));
    forward_preview.root_module.linkSystemLibrary("ssh2", .{});
    forward_preview.step.dependOn(&verify_ssh.step);
    forward_preview.root_module.linkSystemLibrary("mbedcrypto", .{});
    forward_preview.root_module.linkSystemLibrary("z", .{});
    forward_preview.root_module.addLibraryPath(.{ .cwd_relative = "/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk/usr/lib" });
    b.step("forward-config-preview", "Build isolated actual native forwarding config for click acceptance").dependOn(&b.addInstallArtifact(forward_preview, .{}).step);

    const gateway_tests = b.addTest(.{ .filters = &.{"API2 LIVE"}, .root_module = b.createModule(.{
        .root_source_file = b.path("src/ai_gateway_runner.zig"),
        .target = target,
        .optimize = optimize,
    }) });
    gateway_tests.root_module.link_libc = true;
    for ([_][]const u8{ "CoreFoundation", "ImageIO", "CoreGraphics" }) |framework| gateway_tests.root_module.linkFramework(framework, .{});
    gateway_tests.root_module.addSystemFrameworkPath(.{ .cwd_relative = "/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk/System/Library/Frameworks" });
    gateway_tests.root_module.addSystemIncludePath(.{ .cwd_relative = "/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk/usr/include" });
    gateway_tests.root_module.addLibraryPath(.{ .cwd_relative = "/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk/usr/lib" });
    const run_gateway_tests = b.addRunArtifact(gateway_tests);
    // Endpoint/model/opt-in are supplied at execution time; a cached success
    // from another environment is never evidence of a live gateway run.
    run_gateway_tests.has_side_effects = true;
    b.step("test-ai-gateway", "Run opt-in production gateway tool/image acceptance").dependOn(&run_gateway_tests.step);

    const environment_probe = b.addExecutable(.{ .name = "application-environment-contract", .root_module = b.createModule(.{
        .root_source_file = b.path("src/application_environment_contract.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    }) });
    const formal_environment = b.createModule(.{ .root_source_file = zenit_dep.path("src/environment.zig"), .target = target, .optimize = optimize, .link_libc = true });
    const formal_environment_options = b.addOptions();
    formal_environment_options.addOption(bool, "test_mode", false);
    formal_environment.addOptions("automation_options", formal_environment_options);
    environment_probe.root_module.addImport("formal_environment", formal_environment);
    b.step("test-app-environment", "Verify formal defaults ignore process environment overrides").dependOn(&b.addRunArtifact(environment_probe).step);
}

fn addCoreTextBridgeForTest(zenit_dep: *std.Build.Dependency, exe: *std.Build.Step.Compile) void {
    exe.root_module.addCSourceFile(.{
        .file = zenit_dep.path("native/macos/coretext_bridge.m"),
        .flags = &.{"-fobjc-arc"},
    });
    for ([_][]const u8{ "CoreText", "CoreGraphics", "CoreFoundation", "CFNetwork", "Foundation", "ImageIO" }) |fw| {
        exe.root_module.linkFramework(fw, .{});
    }
    const sdk = "/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk";
    exe.root_module.addSystemFrameworkPath(.{ .cwd_relative = sdk ++ "/System/Library/Frameworks" });
    exe.root_module.addSystemIncludePath(.{ .cwd_relative = sdk ++ "/usr/include" });
    // libobjc.A.tbd 的解析需要 SDK 的 usr/lib 在搜索路径（与 exe/mockup 同款）。
    exe.root_module.addLibraryPath(.{ .cwd_relative = sdk ++ "/usr/lib" });
    exe.root_module.link_libc = true;
}

fn addUrlFetchFrameworks(module: *std.Build.Module) void {
    module.linkFramework("CoreFoundation", .{});
    module.linkFramework("CFNetwork", .{});
}
