//! Explicit native UI fixture. Frozen synthetic metadata only: no Manager,
//! transport, remote mutation, local file transfer, or execution receipt.
const std = @import("std");
const ui = @import("ui");
const App = @import("zenit_app").App;
const MultiWindowApp = @import("zenit_app").MultiWindowApp;
const FontRegistry = @import("zenit_app").FontRegistry;
const view = @import("ui/transfer_conflict_view.zig");
const theme = @import("ui/app_theme.zig");
const identity = @import("host/identity.zig");
const Scene = enum { choice, remote, local, batch };
var scene: Scene = .choice;
const owner: identity.SessionHandle = .{ .session_id = @fromBackingInt(101), .generation = 9 };
const key: view.domain.Key = .{ .intent_id = 501, .owner = .{ .session = owner }, .original_owner = owner, .entry = 0, .job = 42, .attempt = 1, .revision = 1 };
const local: view.domain.Endpoint = .{ .local_fs = .{ .binding_id = 12, .binding_generation = 3 } };
const remote: view.domain.Endpoint = .{ .sftp = .{ .binding_id = 13, .binding_generation = 4, .resource_owner = .{ .session = owner }, .origin_session = owner } };
const Fixture = struct {
    cx: *ui.Cx,
    modal: ?*view.View = null,
    samples: u8 = 0,
    fn observe(raw: *anyopaque, _: u8, _: bool) ui.AfterLayoutResult {
        const self: *Fixture = @ptrCast(@alignCast(raw));
        if (self.samples < 12) {
            self.samples += 1;
            std.debug.print("CONFLICT_UI_FIXTURE frame_sample={d} clock_ms={d:.3} overlay_animating={} overlay_opacity={d:.3} card_opacity={d:.3}\n", .{ self.samples, self.cx.frame_time_ms, self.cx.overlay_stack.hasActiveAnimations(), self.modal.?.root.getOpacity(), self.modal.?.dialog.getOpacity() });
            if (self.samples == 12) {
                const path = self.modal.?.target.getText().?;
                std.debug.print("CONFLICT_UI_FIXTURE path_font size={d} weight={d} mono={} line_height={d}\n", .{ path.font_size, path.font_weight, path.use_monospace_font, path.line_height });
            }
        }
        return .done;
    }
    fn cleanup(self: *Fixture) void {
        self.cx.removeAfterLayoutHook(self);
    }
    fn decision(_: *anyopaque, request: view.Conflict.Request) !void {
        const original = request.key();
        std.debug.print("CONFLICT_UI_FIXTURE event={s} job={d} attempt={d} intent={d} session={d} generation={d} revision={d}\n", .{ @tagName(request), original.job, original.attempt, original.intent_id, @backingInt(original.original_owner.session_id), original.original_owner.generation, original.revision });
    }
    fn pause(_: *anyopaque, original: view.domain.Key) !void {
        std.debug.print("CONFLICT_UI_FIXTURE event=pause_request_only job={d} attempt={d} session={d} generation={d}\n", .{ original.job, original.attempt, @backingInt(original.original_owner.session_id), original.original_owner.generation });
    }
};
fn mount(cx: *ui.Cx, scope: *ui.Scope) !*ui.Node {
    theme.select(.dark);
    cx.setTheme(theme.widgetTheme(.dark));
    const fixture = try scope.createState(Fixture, .{ .cx = cx });
    const modal = try view.View.mount(cx, scope, .{ .context = fixture, .decision = Fixture.decision, .defer_conflict = Fixture.pause });
    fixture.modal = modal;
    try cx.addAfterLayoutHook(fixture, Fixture.observe);
    try scope.onCleanup(Fixture, fixture, Fixture.cleanup);
    const download = scene == .local or scene == .batch;
    const source_metadata: view.domain.Metadata = .{ .kind = .file, .size = (if (download) @as(u64, 124) else 128) * 1024 * 1024, .modified_at = 1792045080 };
    const target_version: view.domain.TargetVersion = .{ .revision = 7, .metadata = .{ .kind = .file, .size = (if (download) @as(u64, 128) else 124) * 1024 * 1024, .modified_at = 1791973920 } };
    var source: view.Conflict.Snapshot = .{ .engine_job = 7, .context = .{ .intent_id = 501, .job = 42, .attempt = 1, .original_owner = owner, .resource_owner = .{ .session = owner }, .source_endpoint = if (download) remote else local, .target_endpoint = if (download) local else remote }, .pending = .{ .choice = .{ .key = key, .direction = if (download) .download else .upload, .source_endpoint = if (download) remote else local, .target_endpoint = if (download) local else remote, .source_path = if (download) "/srv/releases/release.tar.gz" else "/local/release.tar.gz", .source_metadata = source_metadata, .target_path = if (download) "/local/Downloads/ZeroWork/release.tar.gz" else "/srv/releases/release.tar.gz", .target = .{ .present = target_version }, .selection = .{}, .suggested_path = "/srv/releases/release (1).tar.gz", .phase = .waiting, .issue = null } } };
    try modal.show(source);
    if (scene != .choice) {
        var targets: [20]view.domain.OverwriteTarget = undefined;
        const count: usize = if (scene == .batch) targets.len else 1;
        for (targets[0..count], 0..) |*target, index| {
            target.* = .{ .key = key, .path = source.pending.choice.target_path, .version = target_version };
            target.key.entry = @intCast(index);
            if (scene == .batch) target.path = "/local/Downloads/ZeroWork/full-untruncated-directory-name/release-complete-name.tar.gz";
        }
        source.pending = .{ .overwrite_confirmation = .{ .ticket = .{ .intent_id = 501, .owner = .{ .session = owner }, .id = 23 }, .original_owner = owner, .direction = if (download) .download else .upload, .endpoint = if (download) local else remote, .targets = targets[0..count] } };
        try modal.show(source);
    }
    return ui.box(cx, .{ .width = .fill(), .height = .fill(), .background = theme.current().app }, .{});
}
pub fn main(init: std.process.Init) !void {
    var args = init.minimal.args.iterate();
    _ = args.next();
    while (args.next()) |arg| {
        if (!std.mem.startsWith(u8, arg, "--scene=")) return error.InvalidFixtureArgument;
        scene = std.meta.stringToEnum(Scene, arg[8..]) orelse return error.InvalidFixtureScene;
    }
    const width: u16 = switch (scene) {
        .choice => 636,
        .remote => 476,
        .local => 496,
        .batch => 860,
    };
    const height: u16 = switch (scene) {
        .choice => 425,
        .remote => 292,
        .local => 244,
        .batch => 480,
    };
    var registry = FontRegistry.init(std.heap.c_allocator);
    defer registry.deinit();
    var windows = MultiWindowApp.init(std.heap.c_allocator, .{});
    defer windows.deinit();
    // Inactive background windows can stop receiving CVDisplayLink ticks.
    // Use the SDK's supported wall-clock poll pacing for this isolated fixture,
    // without forcing dirty frames or altering the production Modal clock.
    const app = try windows.createWindow(.{ .io = init.io, .frame_pacing = .poll, .window = .{ .width = width, .height = height, .min_width = 320, .min_height = 200, .title = "ZeroWork · Conflict UI Fixture", .titlebar = .custom_inset, .titlebar_height = 0, .hide_native_controls = true } });
    installMonospaceFonts(app);
    registry.setFontSystem(&app.font_manager);
    app.setFontRegistry(&registry);
    try app.mount(mount);
    try windows.run();
}

/// Match the main application's actual mono slots; use the real native font
/// loader so a fixture screenshot cannot silently render paths proportionally.
fn installMonospaceFonts(app: *App) void {
    const attempts = [_]struct { size: f32, bold: bool, italic: bool }{
        .{ .size = 13, .bold = false, .italic = false },
        .{ .size = 13, .bold = true, .italic = false },
        .{ .size = 13, .bold = false, .italic = true },
        .{ .size = 13, .bold = true, .italic = true },
        .{ .size = 14, .bold = false, .italic = false },
        .{ .size = 14, .bold = true, .italic = false },
    };
    for (attempts) |attempt| {
        const font = app.font_manager.findFont(.{ .family = "JetBrains Mono", .size = attempt.size, .weight = if (attempt.bold) .bold else .regular, .style = if (attempt.italic) .italic else .normal }) catch continue;
        font.setScaleFactor(app.scale);
        if (attempt.bold and attempt.italic) {
            app.font_selector.mono_bold_italic_fonts[0] = font;
            app.font_selector.mono_bold_italic_count = 1;
        } else if (attempt.italic) {
            app.font_selector.mono_italic_fonts[0] = font;
            app.font_selector.mono_italic_count = 1;
        } else if (attempt.bold) {
            app.font_selector.mono_bold_fonts[app.font_selector.mono_bold_count] = font;
            app.font_selector.mono_bold_count += 1;
        } else {
            app.font_selector.mono_fonts[app.font_selector.mono_count] = font;
            app.font_selector.mono_count += 1;
        }
    }
}
