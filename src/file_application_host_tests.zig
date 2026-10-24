//! Real empty-window file-plugin lifecycle; no remote session or network.
const std = @import("std");
const ui = @import("ui");
const FileApplication = @import("ui/file_application_host.zig");
const Application = @import("ui/application_host.zig").ApplicationHost;
const Workspace = @import("ui/workspace.zig").Workspace;
const Config = @import("config/config.zig").Config;
const local = @import("local/fs_service.zig");
const clock = @import("platform/realtime.zig");
const a = std.testing.allocator;

fn frame(app: *Application, cx: *ui.Cx) !void {
    _ = try app.safeTick();
    cx.advanceFrameClock();
    cx.layout();
    _ = cx.render();
    var unused: [1]std.c.pollfd = undefined;
    _ = std.c.poll(&unused, 0, 2);
}
fn cleanupApplication(app: *Application, cx: *ui.Cx) void {
    if (!app.windowCloseReady()) _ = app.requestWindowClose() catch unreachable;
    const deadline = clock.monotonicNs() + 5 * std.time.ns_per_s;
    while (!app.windowCloseReady()) {
        if (clock.monotonicNs() > deadline) @panic("empty file application failed to release");
        frame(app, cx) catch unreachable;
    }
    app.completeWindowClose() catch unreachable;
    app.deinit();
}

test "file application host empty window close waits for actual local worker and clears external authentication after app deinit" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    try temporary.dir.writeFile(std.testing.io, .{ .sub_path = "hosts.toml", .data = "" });
    const hosts_path = try temporary.dir.realPathFileAlloc(std.testing.io, "hosts.toml", a);
    defer a.free(hosts_path);
    const cx = try ui.Cx.init(a, std.testing.io);
    defer cx.deinit();
    cx.setViewport(1100, 720);
    cx.root = try ui.box(cx, .{ .width = .fill(), .height = .fill(), .direction = .column }, .{});
    const scope = try ui.Scope.init(a, null, cx.owner);
    defer scope.dispose();
    var nodes: [4]*ui.Node = undefined;
    for (&nodes, 0..) |*node, index| {
        node.* = try ui.box(cx, .{ .width = .fill(), .height = if (index == 2) .fill() else .{ .px = 20 }, .min_height = 0 }, .{});
        try cx.root.?.appendChild(a, node.*);
    }
    var config: Config = .{};
    const workspace = try Workspace.init(a, cx, scope, std.testing.io, &config, hosts_path, nodes[0], nodes[1], nodes[2], nodes[3]);
    const file = try FileApplication.Host.create(a, workspace);
    var file_live = true;
    defer if (file_live) {
        file.abortInitialization();
        file.deinit() catch unreachable;
    };
    const app = try Application.initWithFilePlugin(a, workspace, file.plugin());
    var app_live = true;
    defer if (app_live) cleanupApplication(app, cx);
    try file.bind(app);
    app.install();

    const service = file.local_service.?;
    try std.testing.expect(service.thread != null);
    try std.testing.expectEqual(local.ReleaseReceipt.awaiting, service.closeReceipt());
    try std.testing.expect(!service.worker_done.load(.acquire));
    try std.testing.expect(workspace.external_auth != null);
    try std.testing.expect(workspace.external_auth.?.context == @as(*anyopaque, file));
    try std.testing.expect(workspace.pendingAuthentication() == null);
    try std.testing.expectEqual(@as(usize, 0), app.sessions.sessions.items.len);
    try std.testing.expectEqual(@as(usize, 0), workspace.tabs.items.len);
    try std.testing.expectEqual(@as(usize, 0), workspace.connect_jobs.items.len);
    try std.testing.expectError(error.Busy, file.deinit());

    const key = try app.requestWindowClose();
    try std.testing.expect(key.owner == .app);
    try std.testing.expect(!app.windowCloseReady());
    try std.testing.expectError(error.WindowCloseNotReady, app.completeWindowClose());
    const deadline = clock.monotonicNs() + 5 * std.time.ns_per_s;
    while (!app.windowCloseReady()) {
        if (clock.monotonicNs() > deadline) return error.EmptyFileWindowCloseTimeout;
        try frame(app, cx);
        if (service.closeReceipt() != .released) {
            try std.testing.expect(!app.windowCloseReady());
            try std.testing.expect(!file.released);
        }
    }
    // The old empty-target shortcut would reach ready while this worker was
    // still alive. Actual native receipt is required, even with zero tabs.
    try std.testing.expect(service.closing.load(.acquire));
    try std.testing.expect(service.worker_done.load(.acquire));
    try std.testing.expectEqual(local.ReleaseReceipt.released, service.closeReceipt());
    try std.testing.expectEqual(@as(usize, 0), service.works.items.len);
    try std.testing.expectEqual(@as(usize, 0), service.results.items.len);
    try std.testing.expect(file.released);
    try std.testing.expectEqual(@as(usize, 0), file.authentication.?.contexts.items.len);
    try std.testing.expectEqual(@as(usize, 0), file.file_host.?.bindings.items.len);
    try std.testing.expectEqual(@as(usize, 0), file.transfer_host.?.entries.items.len);
    try std.testing.expectEqual(@as(usize, 0), file.adapter.entries.items.len);
    try std.testing.expectEqual(@as(usize, 0), file.mux.?.registrations.items.len);
    try std.testing.expectEqual(@as(usize, 0), file.mux.?.jobs.items.len);
    try std.testing.expectEqual(@as(usize, 0), file.presentation.?.entries.items.len);
    try app.completeWindowClose();
    try std.testing.expect(app.window_close.?.state == .closed);
    try std.testing.expect(workspace.window_close_request == null);

    // ApplicationHost consumes FilePlugin's actual released receipt before
    // destroying its SessionHost. File owner teardown must not dereference it.
    app.deinit();
    app_live = false;
    try std.testing.expect(workspace.external_auth != null);
    try file.deinit();
    file_live = false;
    try std.testing.expect(workspace.external_auth == null);
    try std.testing.expect(workspace.pendingAuthentication() == null);
    try std.testing.expectEqual(@as(usize, 0), workspace.tabs.items.len);
    cx.clearFocus();
    cx.layout();
    _ = cx.render();
}

test "file application host resolves file services by contribution and readiness instead of protocol identity" {
    const sessions = @import("host/session_host.zig");
    const plugins = @import("host/plugin_registry.zig");
    const envelopes = @import("config/connection_envelope.zig");
    const identity = @import("host/identity.zig");
    const Driver = struct {
        const advertised = plugins.Services.of(&.{ .lifecycle, .directory, .file_read });
        fn create(_: *anyopaque, _: sessions.CreateRequest) !void {}
        fn cancel(_: *anyopaque, _: sessions.OperationKey) sessions.CloseReceipt {
            return .released;
        }
        fn close(_: *anyopaque, _: identity.SessionHandle, _: sessions.OperationKey) !sessions.CloseReceipt {
            return .released;
        }
        fn stale(_: *anyopaque, _: identity.SessionHandle, _: sessions.OperationKey) void {}
        fn validate(_: []const u8) !void {}
        fn codec(allocator: std.mem.Allocator, value: envelopes.Envelope) !envelopes.Envelope {
            return value.clone(allocator);
        }
        fn migrate(allocator: std.mem.Allocator, value: envelopes.Envelope, _: u32) !envelopes.Envelope {
            return value.clone(allocator);
        }
        fn editor(_: ?*anyopaque, _: @import("host/plugin_ui_contract.zig").EditorMount) !@import("host/plugin_ui_contract.zig").EditorInstance {
            return error.UnusedEditor;
        }
        fn manifest(context: *u8, id: []const u8) plugins.PluginManifest {
            return .{ .id = id, .display_name = "File service contribution", .workspace_kind = "terminal", .content_renderer = "terminal", .connection = .{ .editor_factory = .{ .mount = editor }, .validate_payload = validate, .encode = codec, .decode = codec, .migrate = migrate }, .session_factory = .{ .context = context, .vtable = &.{ .create = create, .cancel = cancel, .close = close, .release_stale = stale } }, .services = plugins.legacyServiceDefinitions(&.{ .lifecycle, .directory, .file_read }), .legacy_registration = .{ .plugin_id = .external, .workspace_kind = .terminal, .services = advertised } };
        }
    };
    // Both a replaced builtin ID and an entirely new ID expose the same file
    // interfaces. Neither manifest carries the SFTP legacy descriptor.
    for ([_][]const u8{ "sftp", "vendor.files" }) |protocol_id| {
        var context: u8 = 0;
        var domain = try sessions.SessionHost.initPlugins(a, &.{Driver.manifest(&context, protocol_id)}, &.{});
        defer domain.deinit();
        const accepted = try domain.open(.{ .id = @fromBackingInt(8), .revision = 2, .protocol_id = protocol_id, .name = "reader", .payload = "{}" }, .{ .request_key = 1, .target = .{ .window_id = @fromBackingInt(1), .workspace_id = @fromBackingInt(1) } });
        var app: Application = undefined;
        app.sessions = &domain;
        var file: FileApplication.Host = undefined;
        file.app = &app;
        // A direct contributed pair must not allocate or require the SFTP
        // provider's auxiliary native backend.
        file.file_host = null;
        try std.testing.expectError(error.FileSourceUnavailable, file.ensureReadonlySource(accepted.handle));
        try std.testing.expect(try domain.ready(accepted.handle, accepted.operation, Driver.advertised));
        try std.testing.expectEqual(plugins.PluginId.external, domain.queryState(accepted.handle).?.plugin_id);
        const bindings = try file.ensureReadonlySource(accepted.handle);
        try std.testing.expect(domain.bindingIsLive(bindings.directory));
        try std.testing.expect(domain.bindingIsLive(bindings.file_read));
        try std.testing.expectEqual(@as(usize, 0), domain.auxiliary_readonly.items.len);
        try domain.authorizeService(accepted.handle, .{ .name = "file_read" }, false);
        try std.testing.expectError(error.FileSourceUnavailable, file.ensureReadonlySource(accepted.handle));
        try domain.authorizeService(accepted.handle, .{ .name = "file_read" }, true);
        _ = try file.ensureReadonlySource(accepted.handle);
        try std.testing.expectError(error.StaleSession, file.ensureReadonlySource(try accepted.handle.nextGeneration()));
    }
}

test "file application host selects independent readonly setup only from declared integration" {
    // This is a real registered SSH adapter, deliberately not started: the
    // auxiliary branch must require its provider backend before native IO.
    const sessions = @import("host/session_host.zig");
    const plugins = @import("host/plugin_registry.zig");
    const identity = @import("host/identity.zig");
    const Driver = struct {
        fn create(_: *anyopaque, _: sessions.CreateRequest) !void {}
        fn cancel(_: *anyopaque, _: sessions.OperationKey) sessions.CloseReceipt {
            return .released;
        }
        fn close(_: *anyopaque, _: identity.SessionHandle, _: sessions.OperationKey) !sessions.CloseReceipt {
            return .released;
        }
        fn stale(_: *anyopaque, _: identity.SessionHandle, _: sessions.OperationKey) void {}
    };
    var context: u8 = 0;
    const adapter: sessions.Adapter = .{ .registration = .{ .plugin_id = .ssh, .workspace_kind = .terminal, .services = plugins.requiredServices(.ssh) }, .context = &context, .vtable = &.{ .create = Driver.create, .cancel = Driver.cancel, .close = Driver.close, .release_stale = Driver.stale } };
    var domain = try sessions.SessionHost.init(a, &.{adapter});
    defer domain.deinit();
    const accepted = try domain.create(.{ .temporary_ssh = .{ .structured_endpoint = .{ .host = "unused.invalid", .port = 22, .user = "operator" } } }, .{ .window_id = @fromBackingInt(1), .workspace_id = @fromBackingInt(1) });
    var app: Application = undefined;
    app.sessions = &domain;
    var file: FileApplication.Host = undefined;
    file.app = &app;
    file.file_host = null;
    try std.testing.expectError(error.FileHostNotBound, file.ensureReadonlySource(accepted.handle));
    try std.testing.expectEqual(@as(usize, 0), domain.auxiliary_readonly.items.len);
}
