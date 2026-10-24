//! Read-only identities plus native window selection/close for the existing
//! opt-in Zenit file-RPC harness. Production builds erase this entire route.
//! Commands address a captured WindowId, never whichever window became active.
const std = @import("std");
const zenit = @import("zenit_app");
const application = @import("application_host.zig");
const plugin_window = @import("plugin_window_host.zig");
const identity = @import("../host/identity.zig");
var domain: ?*application.Domain = null;
var runtime: ?*zenit.MultiWindowApp = null;
// App routes run serially on the main thread and CommandQueue copies the
// returned slice immediately. Its result capacity is 256 KiB; the supplied
// route scratch slice is only 1 KiB and cannot hold a multi-window snapshot.
var response_buffer: [256 * 1024]u8 = undefined;

pub fn install(app_domain: *application.Domain, windows: *zenit.MultiWindowApp) void {
    if (!zenit.test_harness.enabled) return;
    domain = app_domain;
    runtime = windows;
    zenit.setTestRouteHandler(route);
}

fn route(path: []const u8, body: []const u8, _: []u8) ?[]const u8 {
    if (!zenit.test_harness.enabled) return null;
    if (!std.mem.eql(u8, path, "/zerowork/windows")) return null;
    const app_domain = domain orelse return "{\"ok\":false}";
    const windows = runtime orelse return "{\"ok\":false}";
    if (body.len != 0) {
        const Input = struct { action: []const u8 = "snapshot", window: u64 = 0, session: u64 = 0, generation: u64 = 1, destination: u64 = 0, x: f32 = 0, y: f32 = 0, enabled: bool = false };
        var parsed = std.json.parseFromSlice(Input, app_domain.allocator, body, .{}) catch return "{\"ok\":false,\"error\":\"InvalidCommand\"}";
        defer parsed.deinit();
        const command = parsed.value;
        if (std.mem.eql(u8, command.action, "quit")) {
            windows.quit();
        } else if (std.mem.eql(u8, command.action, "fullscreen_content")) {
            const owner: identity.SessionHandle = .{ .session_id = @fromBackingInt(command.session), .generation = command.generation };
            const source = app_domain.ownerForHandle(owner) orelse return "{\"ok\":false,\"error\":\"OwnerMissing\"}";
            if (command.window != 0 and source.window_id != @as(identity.WindowId, @fromBackingInt(command.window))) return "{\"ok\":false,\"error\":\"StaleWindow\"}";
            const host = plugin_window.Host.forApplication(source) orelse return "{\"ok\":false}";
            const input = host.inputFor(owner) orelse return "{\"ok\":false}";
            input.requestFullscreen(command.enabled) catch return "{\"ok\":false,\"error\":\"FullscreenRejected\"}";
        } else if (std.mem.eql(u8, command.action, "transfer_content") or std.mem.eql(u8, command.action, "input_content")) {
            const owner: identity.SessionHandle = .{ .session_id = @fromBackingInt(command.session), .generation = command.generation };
            const source = app_domain.ownerForHandle(owner) orelse return "{\"ok\":false,\"error\":\"OwnerMissing\"}";
            if (command.window != 0 and source.window_id != @as(identity.WindowId, @fromBackingInt(command.window))) return "{\"ok\":false,\"error\":\"StaleWindow\"}";
            const host = plugin_window.Host.forApplication(source) orelse return "{\"ok\":false,\"error\":\"PluginWindowMissing\"}";
            const input = host.inputFor(owner) orelse return "{\"ok\":false,\"error\":\"ContentMissing\"}";
            // Harness-only lease probe dispatches no key, text or pointer. It
            // supplies a real host lease so teardown can prove its revocation.
            if (input.human) |lease| input.release(lease);
            input.setAuthorization(true, input.authorization_revision) catch return "{\"ok\":false}";
            input.setFocus(true, false);
            _ = input.acquire(.automation, input.authorization_revision) catch return "{\"ok\":false,\"error\":\"LeaseUnavailable\"}";
            if (std.mem.eql(u8, command.action, "input_content")) {
                const lease = input.acquire(.automation, input.authorization_revision) catch return "{\"ok\":false}";
                _ = input.route(lease, nextInputSequence(input.last_automation_event) catch return "{\"ok\":false,\"error\":\"InputSequenceExhausted\"}", .{ .pointer = .{ .x = command.x, .y = command.y, .buttons = 0 } }, false) catch return "{\"ok\":false,\"error\":\"InputRejected\"}";
            } else input.transferWindow(@fromBackingInt(command.destination)) catch |err| {
                var failed = std.Io.Writer.fixed(&response_buffer);
                std.json.Stringify.value(.{ .ok = false, .error_code = @errorName(err) }, .{}, &failed) catch return "{\"ok\":false,\"error\":\"SnapshotCapacityExceeded\"}";
                return failed.buffered();
            };
        } else if (!std.mem.eql(u8, command.action, "snapshot")) {
            const target = app_domain.ownerForWindow(@fromBackingInt(command.window)) orelse return "{\"ok\":false,\"error\":\"WindowClosed\"}";
            const app = findNative(windows, target.workspace.cx) orelse return "{\"ok\":false,\"error\":\"NativeWindowMissing\"}";
            if (std.mem.eql(u8, command.action, "select")) {
                _ = windows.activateWindow(app.windowId());
                app.rebindTestHarness();
            } else if (std.mem.eql(u8, command.action, "close")) {
                _ = windows.closeWindow(app.windowId());
            } else return "{\"ok\":false,\"error\":\"UnsupportedAction\"}";
        }
    }
    var writer = std.Io.Writer.fixed(&response_buffer);
    writer.writeAll("{\"ok\":true,\"native_count\":") catch return "{\"ok\":false,\"error\":\"SnapshotCapacityExceeded\"}";
    std.json.Stringify.value(zenit.MultiWindowApp.nativeWindowCount(), .{}, &writer) catch return "{\"ok\":false,\"error\":\"SnapshotCapacityExceeded\"}";
    writer.writeAll(",\"windows\":[") catch return "{\"ok\":false,\"error\":\"SnapshotCapacityExceeded\"}";
    for (app_domain.attachments.items, 0..) |host, index| {
        if (index != 0) writer.writeByte(',') catch return "{\"ok\":false,\"error\":\"SnapshotCapacityExceeded\"}";
        const native = findNative(windows, host.workspace.cx);
        std.json.Stringify.value(.{
            .window = @backingInt(host.window_id),
            .workspace = @backingInt(host.workspace_id),
            .native_window = if (native) |app| app.windowId() else 0,
            .shared_registry = host.sessions == &app_domain.sessions,
            .shared_local_adapter = host.local_adapter == app_domain.local_adapter,
            .closing = host.windowClosePending(),
        }, .{}, &writer) catch return "{\"ok\":false,\"error\":\"SnapshotCapacityExceeded\"}";
    }
    writer.writeAll("],\"sessions\":[") catch return "{\"ok\":false,\"error\":\"SnapshotCapacityExceeded\"}";
    var count: usize = 0;
    for (app_domain.sessions.sessions.items) |entry| {
        const state = app_domain.sessions.queryState(entry.handle) orelse continue;
        if (count != 0) writer.writeByte(',') catch return "{\"ok\":false,\"error\":\"SnapshotCapacityExceeded\"}";
        count += 1;
        const facade = if (app_domain.ownerForHandle(state.handle)) |host| plugin_window.Host.forApplication(host) else null;
        const input = if (facade) |host| host.inputFor(state.handle) else null;
        const sink = if (facade) |host| host.framesFor(state.handle) else null;
        std.json.Stringify.value(.{ .session = @backingInt(state.handle.session_id), .generation = state.handle.generation, .window = @backingInt(state.target.window_id), .workspace = @backingInt(state.target.workspace_id), .plugin = @tagName(state.plugin_id), .tab = if (state.attachment) |attachment| @backingInt(attachment.tab_id) else 0, .lifecycle = @tagName(state.lifecycle), .close_operation = if (state.close_operation) |key| key.operation_id else null, .close_cleanup_released = if (state.close_operation) |key| closeReleased(app_domain, key) else false, .create_operation = state.create_operation.operation_id, .attempt = state.create_operation.attempt_id, .capability_revision = app_domain.sessions.capabilityRevisionFor(state.handle), .fullscreen = if (input) |value| value.fullscreen() else false, .input_instance = if (input) |value| value.context_instance else 0, .transfer_state = if (input) |value| @tagName(value.transfer_state) else "unavailable", .transfer_error = if (input) |value| (if (value.transfer_state == .failed) @errorName(value.transfer_state.failed) else "") else "", .texture = if (sink) |value| value.texture else null, .frame_revision = if (sink) |value| value.revision else 0 }, .{}, &writer) catch return "{\"ok\":false,\"error\":\"SnapshotCapacityExceeded\"}";
    }
    writer.writeAll("],\"content_states\":[") catch return "{\"ok\":false,\"error\":\"SnapshotCapacityExceeded\"}";
    var content_count: usize = 0;
    for (app_domain.attachments.items) |app_host| if (plugin_window.Host.forApplication(app_host)) |host| {
        for (host.content_host.entries.items) |entry| {
            if (content_count != 0) writer.writeByte(',') catch return "{\"ok\":false,\"error\":\"SnapshotCapacityExceeded\"}";
            content_count += 1;
            std.json.Stringify.value(.{ .window = @backingInt(app_host.window_id), .session = @backingInt(entry.input.owner.session_id), .generation = entry.input.owner.generation, .context_instance = entry.input.context_instance, .retired = entry.retired, .input_closed = entry.input.closed, .frame_closed = !entry.frames.accepting.load(.acquire), .texture = entry.frames.texture, .frame_revision = entry.frames.revision }, .{}, &writer) catch return "{\"ok\":false,\"error\":\"SnapshotCapacityExceeded\"}";
        }
    };
    writer.writeAll("],\"transfers\":") catch return "{\"ok\":false,\"error\":\"SnapshotCapacityExceeded\"}";
    std.json.Stringify.value(plugin_window.transfer_receipts[0..plugin_window.transfer_receipt_count], .{}, &writer) catch return "{\"ok\":false,\"error\":\"SnapshotCapacityExceeded\"}";
    writer.writeAll(",\"tasks\":[") catch return "{\"ok\":false,\"error\":\"SnapshotCapacityExceeded\"}";
    if (app_domain.tasks) |tasks| for (0..tasks.manager.count()) |index| {
        const progress = tasks.manager.progressAt(index) orelse continue;
        if (index != 0) writer.writeByte(',') catch return "{\"ok\":false,\"error\":\"SnapshotCapacityExceeded\"}";
        const retained = tasks.manager.retainedOwner(progress.job);
        const binding = tasks.manager.transferBinding(progress.job);
        std.json.Stringify.value(.{
            .job = progress.job,
            .attempt = progress.attempt,
            .state = @tagName(progress.state),
            .cleanup = @tagName(progress.job_cleanup),
            .done_bytes = progress.done_bytes,
            .total_bytes = progress.total_bytes,
            .session = tasks.manager.sessionId(progress.job),
            .binding = if (binding) |value| value.binding_id else 0,
            .binding_generation = if (binding) |value| value.binding_generation else 0,
            .retained_owner = if (retained) |value| @backingInt(value.id) else 0,
            .original_session = if (retained) |value| @backingInt(value.original_handle.session_id) else 0,
            .original_generation = if (retained) |value| value.original_handle.generation else 0,
        }, .{}, &writer) catch return "{\"ok\":false,\"error\":\"SnapshotCapacityExceeded\"}";
    };
    writer.writeAll("],\"backgrounds\":[") catch return "{\"ok\":false,\"error\":\"SnapshotCapacityExceeded\"}";
    if (app_domain.tasks) |tasks| if (tasks.backgrounds) |model| for (model.rows.items, 0..) |row, index| {
        if (index != 0) writer.writeByte(',') catch return "{\"ok\":false,\"error\":\"SnapshotCapacityExceeded\"}";
        std.json.Stringify.value(.{
            .session = @backingInt(row.owner.session_id),
            .generation = row.owner.generation,
            .asset = @backingInt(row.source.id),
            .asset_revision = row.source.revision,
            .name = row.name,
            .phase = @tagName(row.phase),
            .local_port = row.local_port,
        }, .{}, &writer) catch return "{\"ok\":false,\"error\":\"SnapshotCapacityExceeded\"}";
    };
    writer.writeAll("]}") catch return "{\"ok\":false,\"error\":\"SnapshotCapacityExceeded\"}";
    return writer.buffered();
}

fn findNative(windows: *zenit.MultiWindowApp, cx: *@import("ui").Cx) ?*zenit.App {
    for (windows.windows.items) |managed| if (managed.app.cx == cx) return managed.app;
    return null;
}

fn closeReleased(app_domain: *application.Domain, key: @import("../host/operation.zig").OperationKey) bool {
    for (app_domain.sessions.journal.records.items) |record| if (record.key.eql(key)) return record.cleanup_released;
    return false;
}

fn nextInputSequence(previous: u64) error{InputSequenceExhausted}!u64 {
    if (previous == std.math.maxInt(u64)) return error.InputSequenceExhausted;
    return previous + 1;
}

test "content input event sequence starts at one and never wraps" {
    try std.testing.expectEqual(@as(u64, 1), try nextInputSequence(0));
    try std.testing.expectEqual(@as(u64, 2), try nextInputSequence(1));
    try std.testing.expectError(error.InputSequenceExhausted, nextInputSequence(std.math.maxInt(u64)));
}
