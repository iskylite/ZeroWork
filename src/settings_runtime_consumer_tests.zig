//! Focused settings consumers: real matcher, retained TerminalView and file IO.
//! No native window, OS notifications, remote host or user configuration.
const std = @import("std");
const ui = @import("ui");
const config = @import("config/config.zig");
const keys = @import("config/keybindings.zig");
const terminal = @import("host/terminal_service.zig");
const service_host = @import("host/session_host.zig");
const fixture = @import("ui/terminal_surface_tests.zig");
const View = @import("ui/terminal_view.zig").TerminalViewNode;
const a = std.testing.allocator;

test "settings runtime matcher invalidates replaced chords for every editable action" {
    const defaults: keys.Map = .{};
    for (std.meta.tags(keys.Action)) |action| {
        if (action != .recent_tab and action != .accept_completion) {
            var current = defaults;
            const old = defaults.get(action);
            try current.set(action, .{ .key = .f12, .shift = true, .option = true });
            var bytes: [4096]u8 = undefined;
            current = try keys.Map.parse(try current.format(&bytes));
            try std.testing.expect(current.match(old.key, ui.events.Modifiers{ .super = old.command, .shift = old.shift, .alt = old.option, .ctrl = old.control }) == null);
            try std.testing.expectEqual(action, current.match(keys.KeyCode.f12, ui.events.Modifiers{ .super = true, .shift = true, .alt = true }).?);
            for (std.meta.tags(keys.Action)) |other| {
                if (other != action) try std.testing.expectEqualDeep(defaults.get(other), current.get(other));
            }
            current.reset();
            try std.testing.expectEqual(action, current.match(old.key, ui.events.Modifiers{ .super = old.command, .shift = old.shift, .alt = old.option, .ctrl = old.control }).?);
        }
    }
}

const CompletionFixture = struct {
    base: fixture.FakeTransport = undefined,
    table: terminal.Service.VTable = undefined,
    fn init(self: *@This(), view: *View) !void {
        try self.base.init(12, 50);
        const service = self.base.service();
        self.table = service.vtable.*;
        self.table.trusted_snapshot = snapshot;
        try view.bindTerminalService(.{ .binding = service.binding, .context = &self.base, .vtable = &self.table });
        view.cx.setFocus(view.root);
        _ = try view.refreshTerminalService(fixture.owner, true);
    }
    fn snapshot(_: *anyopaque, _: service_host.ServiceHandle, allocator: std.mem.Allocator) !?terminal.trusted_edit.Snapshot {
        return try (terminal.trusted_edit.Snapshot{ .owner = fixture.owner, .token = 1, .revision = 1, .buffer = @constCast("git st"), .cursor = 6, .mark = 0, .region = 0, .keymap = @constCast("emacs"), .context = @constCast("start"), .prebuffer = @constCast(""), .lease = 0 }).clone(allocator);
    }
};

test "settings runtime completion disables an already open real terminal menu and restores same owner" {
    const cx = try ui.Cx.init(a, std.testing.io);
    defer cx.deinit();
    cx.setViewport(800, 450);
    var view = try View.mount(cx);
    cx.root = view.root;
    defer view.releaseBuffers(cx);
    var source: CompletionFixture = .{};
    try source.init(&view);
    defer source.base.deinit();
    defer view.unbindTerminalService(fixture.owner);
    try view.completion.add("git status", .history, 1, 0);
    view.refreshCompletionState();
    try std.testing.expect(view.completion.state.menu_open);
    try std.testing.expectEqual(@as(usize, 1), view.completion_count);
    const focus = cx.focus_manager.getFocused();
    const root = view.root;
    view.completion_enabled = false;
    view.refreshCompletionState();
    try std.testing.expect(!view.completion.state.menu_open);
    try std.testing.expect(!view.completion.enabled);
    try std.testing.expectEqual(focus, cx.focus_manager.getFocused());
    try std.testing.expectEqual(root, view.root);
    view.completion_enabled = true;
    view.refreshCompletionState();
    try std.testing.expect(view.completion.state.menu_open);
    try std.testing.expectEqual(@as(usize, 1), view.completion_count);
    try std.testing.expectEqualStrings("git st", view.line.content.items);
    try std.testing.expectEqualStrings("", source.base.written.items);
}

test "settings runtime log interval and capacity reach real bounded checkpoint files" {
    const Checkpoint = @import("vt/checkpoint_controller.zig").Controller;
    const Tap = @import("vt/raw_stream_tap.zig").Tap;
    const runtime = @import("ui/session_runtime.zig");
    var cfg: config.Config = .{};
    cfg.log.ring_mb = 1;
    cfg.log.checkpoint_sec = 2;
    const options = runtime.workerRuntimeOptions(cfg);
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var controller = try Checkpoint.init(a, options.timeline_max_bytes, cfg.log.checkpoint_sec, 1000, std.testing.io, tmp.dir, "state/checkpoint");
    defer controller.deinit();
    try controller.enableRawFile("state/raw");
    const output = try a.alloc(u8, options.timeline_max_bytes + 17);
    defer a.free(output);
    @memset(output, 'x');
    @memcpy(output[output.len - 4 ..], "TAIL");
    try std.testing.expect(!try controller.append(output, 2999));
    try std.testing.expectError(error.FileNotFound, tmp.dir.openFile(std.testing.io, "state/checkpoint", .{}));
    try std.testing.expect(try controller.append("!", 3000));
    const raw = try Checkpoint.loadRaw(a, std.testing.io, tmp.dir, "state/raw", options.timeline_max_bytes);
    defer a.free(raw);
    try std.testing.expectEqual(options.timeline_max_bytes, raw.len);
    try std.testing.expectEqualStrings("TAIL!", raw[raw.len - 5 ..]);
    const checkpoint = try Tap.loadCheckpoint(std.testing.io, tmp.dir, a, "state/checkpoint");
    try std.testing.expectEqual(@as(i64, 3000), checkpoint.timestamp_ms);
    try std.testing.expectEqual(@as(u64, output.len + 1), checkpoint.sequence);
    var file = try tmp.dir.openFile(std.testing.io, "state/raw", .{});
    defer file.close(std.testing.io);
    try std.testing.expectEqual(@as(u64, options.timeline_max_bytes + 32), (try file.stat(std.testing.io)).size);
}

test "settings runtime saved reconnect policy drives real machine exhaustion and recovery" {
    const runtime = @import("ui/session_runtime.zig");
    const reconnect = @import("vt/reconnect.zig");
    var cfg: config.Config = .{};
    cfg.ssh.reconnect_max = 2;
    cfg.ssh.reconnect_backoff = .{ 3, 7, 11, 19, 23 };
    const options = runtime.workerRuntimeOptions(cfg);
    var machine = try reconnect.Machine.init(options.reconnect_max, &options.reconnect_backoff);
    machine.suspect(0);
    try std.testing.expectEqual(@as(u8, 3), try machine.nextDelay());
    machine.failed();
    try std.testing.expectEqual(@as(u8, 7), try machine.nextDelay());
    machine.failed();
    try std.testing.expectEqual(reconnect.State.dead, machine.currentState());
    machine.connected();
    machine.suspect(null);
    try std.testing.expectEqual(@as(u8, 3), try machine.nextDelay());
    cfg.ssh.auto_reconnect = false;
    try std.testing.expect(!runtime.workerRuntimeOptions(cfg).auto_reconnect);
    cfg.ssh.auto_reconnect = true;
    cfg.ssh.reconnect_max = 0;
    try std.testing.expect(!runtime.workerRuntimeOptions(cfg).auto_reconnect);
}

test "settings runtime network factory freezes keepalive timeout term compression and OTP presentation" {
    const runtime = @import("ui/session_runtime.zig");
    const auth = @import("proto/ssh/auth_challenge.zig");
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    var cfg: config.Config = .{};
    cfg.ssh.keepalive_sec = 47;
    cfg.ssh.connect_timeout_sec = 9;
    cfg.ssh.term = "vt100";
    cfg.ssh.compression = true;
    cfg.ssh.otp_modal = false;
    cfg.config_revision = 37;
    var bridge: auth.InteractiveBridge = .{};
    const target: runtime.HostTarget = .{ .host = "controlled.invalid", .user = "fixture", .auth_mode = .agent, .keyboard_bridge = &bridge, .operation_key = .{ .owner = .{ .session = fixture.owner }, .operation_id = 7, .attempt_id = 1 } };
    const first = (try runtime.prepareConnectionOptions(arena.allocator(), cfg, target, .session))[0];
    cfg.ssh.keepalive_sec = 5;
    cfg.ssh.connect_timeout_sec = 2;
    cfg.ssh.term = "xterm";
    cfg.ssh.compression = false;
    cfg.ssh.otp_modal = true;
    const next = (try runtime.prepareConnectionOptions(arena.allocator(), cfg, target, .session))[0];
    try std.testing.expectEqual(@as(u16, 47), first.keepalive_sec);
    try std.testing.expectEqual(@as(u32, 9000), first.connect_timeout_ms);
    try std.testing.expectEqualStrings("vt100", first.term);
    try std.testing.expect(first.compression);
    try std.testing.expectEqual(auth.Presentation.protected_form, first.auth_interaction.?.presentation);
    try std.testing.expectEqual(@as(u16, 5), next.keepalive_sec);
    try std.testing.expectEqual(@as(u32, 2000), next.connect_timeout_ms);
    try std.testing.expectEqualStrings("xterm", next.term);
    try std.testing.expect(!next.compression);
    try std.testing.expectEqual(auth.Presentation.otp_modal, next.auth_interaction.?.presentation);
    var override = target;
    override.keepalive = false;
    override.terminal_type = "ansi";
    override.compression = true;
    const owned = (try runtime.prepareConnectionOptions(arena.allocator(), cfg, override, .session))[0];
    try std.testing.expectEqual(@as(u16, 0), owned.keepalive_sec);
    try std.testing.expectEqualStrings("ansi", owned.term);
    try std.testing.expect(owned.compression);
}

test "settings runtime AI selected provider effort redaction and permission feed production request policy" {
    const provider_config = @import("ai/provider_config.zig");
    const http = @import("ai/provider_http.zig");
    const snapshot = @import("ai/session_snapshot_context.zig");
    const permission = @import("ai/permission.zig");
    var models = [_]config.AiModel{.{ .id = "fixture-reasoner", .context_window = 32768, .default = true, .reasoning = true }};
    var providers = [_]config.AiProvider{.{ .name = "fixture", .kind = .openai_compat, .endpoint = "https://controlled.invalid/v1", .api_key = "fixture-only-key", .enabled = true, .models = &models, .model_count = 1 }};
    var cfg: config.Config = .{};
    cfg.ai.providers = &providers;
    cfg.ai.provider_count = 1;
    cfg.ai.default_provider = "fixture";
    cfg.ai.redact_ip = true;
    const selected = try provider_config.fromSettings(cfg.ai);
    try provider_config.validateEffort(cfg.ai, null, .high);
    var context = try snapshot.assembleText(a, "echo 10.0.0.1", .{ .host = "10.0.0.1", .user = "fixture-user" }, null, null, cfg.ai.redact_ip, selected.context_window);
    defer context.deinit(a);
    const request = selected.chatRequest(.{ .model = "stale-default", .system = context.text, .messages = &.{}, .effort = .high });
    const body = try http.requestBody(a, selected.kind, request, selected.context_window);
    defer a.free(body);
    const parsed = try std.json.parseFromSlice(std.json.Value, a, body, .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings("fixture-reasoner", parsed.value.object.get("model").?.string);
    try std.testing.expectEqualStrings("high", parsed.value.object.get("reasoning_effort").?.string);
    try std.testing.expect(std.mem.indexOf(u8, body, "host=<redacted> user=<redacted>") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "echo 10.0.0.1") != null);
    cfg.ai.redact_ip = false;
    var plain = try snapshot.assembleText(a, "echo 10.0.0.1", .{ .host = "10.0.0.1", .user = "fixture-user" }, null, null, cfg.ai.redact_ip, selected.context_window);
    defer plain.deinit(a);
    try std.testing.expect(std.mem.indexOf(u8, plain.text, "host=10.0.0.1 user=fixture-user") != null);
    const command = "fixture read";
    const whitelist: []const []const u8 = &.{"fixture read"};
    try std.testing.expectEqual(permission.Verdict.need_confirm, permission.classify(.{ .mode = .confirm, .whitelist = whitelist }, command, false));
    try std.testing.expectEqual(permission.Verdict.allow_auto, permission.classify(.{ .mode = .auto, .whitelist = whitelist }, command, false));
    try std.testing.expectEqual(permission.Verdict.need_confirm, permission.classify(.{ .mode = .auto, .whitelist = whitelist }, "fixture read; touch /tmp/never-executed", false));
}

test "settings runtime saved retention controls actual Recording close pruning" {
    const Recording = @import("local/recording.zig").Recording;
    const Archive = @import("vt/session_archive.zig").Archive;
    for ([_]u16{ 2, 7 }) |days| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        const path = try tmp.dir.realPathFileAlloc(std.testing.io, ".", a);
        defer a.free(path);
        try tmp.dir.createDirPath(std.testing.io, "logs/history");
        try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "logs/history/older.cast", .data = "older recording" });
        var archive: Archive = .{ .allocator = a, .io = std.testing.io, .dir = tmp.dir };
        try archive.append(.{ .id = 123, .started_ms = 0, .ended_ms = std.time.ms_per_day, .duration_ms = 0, .host = "fixture", .user = "fixture", .cast_path = "logs/history/older.cast" });
        var cfg: config.Config = .{};
        cfg.log.ring_mb = 1;
        cfg.log.retention_days = days;
        var recording = try Recording.init(a, fixture.owner, .{ .io = std.testing.io, .directory = path, .log = cfg.log }, 80, 24, 1000);
        defer recording.deinit();
        recording.close(fixture.owner, 5 * std.time.ms_per_day, 0);
        try std.testing.expect(recording.snapshot().archived);
        try std.testing.expect(recording.snapshot().failure == null);
        var entries = try archive.load(a);
        defer archive.freeEntries(&entries);
        if (days == 2) {
            try std.testing.expectEqual(@as(usize, 1), entries.items.len);
            try std.testing.expectError(error.FileNotFound, tmp.dir.openFile(std.testing.io, "logs/history/older.cast", .{}));
        } else {
            try std.testing.expectEqual(@as(usize, 2), entries.items.len);
            var retained = try tmp.dir.openFile(std.testing.io, "logs/history/older.cast", .{});
            retained.close(std.testing.io);
        }
    }
}

test "auto shell integration source freezes global inheritance and host override" {
    const source_codec = @import("plugins/ssh/connection_source.zig");
    var global: @import("config/config.zig").Config = .{};
    global.ssh.auto_shell_integration = false;
    const host: @import("config/hosts.zig").HostConfig = .{ .connection_id = @fromBackingInt(1), .name = "fixture", .host = "host", .user = "user" };
    var inherited = try source_codec.freezeSource(std.testing.allocator, host, global, &.{}, 1, 0, "");
    defer inherited.deinit();
    global.ssh.auto_shell_integration = true;
    var hops: [8]@import("host/session_host.zig").RouteHop = undefined;
    try std.testing.expect(!source_codec.sourceSpec(inherited.value, &hops, "").saved.immutable_config.auto_shell_integration);
    var override = host;
    override.auto_shell_integration = false;
    var disabled = try source_codec.freezeSource(std.testing.allocator, override, global, &.{}, 1, 0, "");
    defer disabled.deinit();
    try std.testing.expect(!source_codec.sourceSpec(disabled.value, &hops, "").saved.immutable_config.auto_shell_integration);
    override.auto_shell_integration = true;
    global.ssh.auto_shell_integration = false;
    var enabled = try source_codec.freezeSource(std.testing.allocator, override, global, &.{}, 1, 0, "");
    defer enabled.deinit();
    try std.testing.expect(source_codec.sourceSpec(enabled.value, &hops, "").saved.immutable_config.auto_shell_integration);
}

comptime {
    _ = @import("config/command_info.zig");
}
