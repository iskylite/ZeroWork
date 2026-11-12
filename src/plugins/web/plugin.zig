//! Web connection contribution. Each session owns its browser and, when
//! configured, a fresh authenticated proxy over the saved SSH route.
const std = @import("std");
const registry = @import("../../host/plugin_registry.zig");
const sessions = @import("../../host/session_host.zig");
const services = @import("../../host/plugin_services.zig");
const contract = @import("../../host/plugin_ui_contract.zig");
const identity = @import("../../host/identity.zig");
const envelope = @import("../../config/connection_envelope.zig");
const imports = @import("../../config/host_import.zig");
const config = @import("config.zig");
const page = @import("page_service.zig");
const Runtime = @import("runtime.zig").Runtime;

pub const workspace_kind = "web";
const lifecycle_key: services.ServiceKey = .{ .name = "lifecycle", .major = 1 };
const declared_services = [_]registry.ServiceDefinition{
    services.Definition.of(sessions.Adapter.VTable, lifecycle_key),
    page.definition,
};
const dependencies = [_]registry.Dependency{
    .{ .id = "host", .major = 2 },
    .{ .id = "host.session_service_access" },
    .{ .id = "host.web_surface" },
};

pub const Plugin = struct {
    allocator: std.mem.Allocator,
    owner_thread: std.Thread.Id,
    runtimes: std.ArrayList(*Runtime) = .empty,
    shutting_down: bool = false,

    pub fn init(a: std.mem.Allocator) !*Plugin {
        const self = try a.create(Plugin);
        self.* = .{ .allocator = a, .owner_thread = std.Thread.getCurrentId() };
        return self;
    }

    pub fn deinit(self: *Plugin) !void {
        try self.requireThread();
        self.shutting_down = true;
        var index: usize = 0;
        while (index < self.runtimes.items.len) {
            const runtime = self.runtimes.items[index];
            if (runtime.close() == .released) {
                _ = self.runtimes.swapRemove(index);
                runtime.deinit();
            } else {
                index += 1;
            }
        }
        if (self.runtimes.items.len != 0) return error.WebCleanupPending;
        self.runtimes.deinit(self.allocator);
        self.allocator.destroy(self);
    }

    pub fn manifest(self: *Plugin) registry.PluginManifest {
        return .{
            .id = config.protocol_id,
            .display_name = "浏览器",
            .plugin_version = "0.6.0",
            .origin = .bundled,
            .host_api_version = 2,
            .order = 40,
            .dependencies = &dependencies,
            .icons = .{ .settings = "globe", .protocol = "globe", .tab = "globe" },
            .connection = .{
                .create_kind = .saved_or_temporary,
                .payload_version = config.payload_version,
                .validate_payload = validatePayload,
                .editor_factory = .{ .context = self, .mount = @import("editor.zig").mount },
                .encode = codec,
                .decode = codec,
                .migrate = migrate,
                .credential_references = credentialReferences,
                .remap_import = remapImport,
            },
            .workspace_kind = workspace_kind,
            .content_renderer = workspace_kind,
            .services = &declared_services,
            .required_services = &declared_services,
            .session_factory = .{ .context = self, .vtable = &factory_vtable, .poll = poll },
        };
    }

    pub fn renderer(self: *Plugin) contract.RendererDefinition {
        return .{ .kind = workspace_kind, .context = self, .mount = @import("renderer.zig").mount };
    }

    fn requireThread(self: *const Plugin) !void {
        if (std.Thread.getCurrentId() != self.owner_thread) return error.WebPluginOffMainThread;
    }

    fn from(raw: *anyopaque) *Plugin {
        return @ptrCast(@alignCast(raw));
    }

    fn runtimeFor(self: *Plugin, owner: identity.SessionHandle) ?*Runtime {
        for (self.runtimes.items) |runtime| if (runtime.owner.eql(owner)) return runtime;
        return null;
    }

    fn create(raw: *anyopaque, request: sessions.CreateRequest) !void {
        const self = from(raw);
        try self.requireThread();
        if (self.shutting_down) return error.PluginShuttingDown;
        if (request.spec != .plugin or !std.mem.eql(u8, request.spec.plugin.protocol_id, config.protocol_id)) return error.ProtocolMismatch;
        if (self.runtimeFor(request.handle) != null) return error.DuplicateWebOwner;
        if (self.runtimes.items.len >= 128) return error.WebSessionLimit;
        const value = request.spec.plugin;
        var decoded = try config.decode(self.allocator, value.payload_version, value.payload);
        defer decoded.deinit();
        const payload = try readyPayload(decoded);
        try self.runtimes.ensureUnusedCapacity(self.allocator, 1);
        self.runtimes.appendAssumeCapacity(try Runtime.init(self.allocator, request, payload));
    }

    fn poll(raw: *anyopaque, host: *sessions.SessionHost) !bool {
        const self = from(raw);
        try self.requireThread();
        var changed = false;
        var index: usize = 0;
        while (index < self.runtimes.items.len) {
            const runtime = self.runtimes.items[index];
            const state = host.queryState(runtime.owner);
            const should_stop = self.shutting_down or state == null or switch (state.?.lifecycle) {
                .closing, .cleanup_unknown, .closed, .failed, .ended => true,
                else => false,
            };
            if (should_stop and !runtime.stopping) {
                _ = runtime.close();
                changed = true;
            }
            if (!runtime.published and !runtime.stopping) {
                const bindings = [_]services.Binding{
                    services.Binding.init(sessions.Adapter.VTable, lifecycle_key, self, &factory_vtable, runtime.owner, 1),
                    services.Binding.init(page.VTable, page.key, runtime, Runtime.pageVTable(), runtime.owner, 1),
                };
                runtime.published = try host.readyPlugin(runtime.owner, runtime.operation, &bindings);
                if (!runtime.published) _ = runtime.close();
                changed = true;
            }
            changed = (try runtime.poll()) or changed;
            if (runtime.stopping) {
                const receipt = runtime.closeReceipt();
                if (runtime.create_report != receipt) {
                    _ = try host.createCleanupReceipt(runtime.owner, runtime.operation, receipt);
                    runtime.create_report = receipt;
                }
                if (runtime.close_operation) |key| if (runtime.close_report != receipt) {
                    _ = try host.closeReceipt(runtime.owner, key, .close_protocol, receipt);
                    runtime.close_report = receipt;
                };
                if (receipt == .released) {
                    _ = self.runtimes.swapRemove(index);
                    runtime.deinit();
                    changed = true;
                    continue;
                }
            }
            index += 1;
        }
        return changed;
    }

    fn cancel(raw: *anyopaque, key: sessions.OperationKey) sessions.CloseReceipt {
        const self = from(raw);
        self.requireThread() catch return .unknown;
        for (self.runtimes.items) |runtime| if (runtime.operation.eql(key)) return runtime.close();
        return .released;
    }

    fn close(raw: *anyopaque, owner: identity.SessionHandle, key: sessions.OperationKey) !sessions.CloseReceipt {
        const self = from(raw);
        try self.requireThread();
        if (key.owner != .session or !key.owner.session.eql(owner) or key.operation_id == 0) return error.InvalidOperationOwner;
        const runtime = self.runtimeFor(owner) orelse return .released;
        if (runtime.close_operation) |existing| if (!existing.eql(key)) return error.StaleCloseOperation;
        runtime.close_operation = key;
        return runtime.close();
    }

    fn releaseStale(raw: *anyopaque, owner: identity.SessionHandle, key: sessions.OperationKey) void {
        const self = from(raw);
        self.requireThread() catch return;
        const runtime = self.runtimeFor(owner) orelse return;
        if (runtime.operation.eql(key)) _ = runtime.close();
    }

    const factory_vtable: sessions.Adapter.VTable = .{
        .create = create,
        .cancel = cancel,
        .close = close,
        .release_stale = releaseStale,
    };
};

fn readyPayload(decoded: config.Decoded) !config.Payload {
    return switch (decoded.content) {
        .ready => |value| value,
        .repair => error.BookmarkRepairRequired,
    };
}

fn validatePayload(bytes: []const u8) !void {
    var decoded = try config.decode(std.heap.page_allocator, config.payload_version, bytes);
    defer decoded.deinit();
    _ = try readyPayload(decoded);
}

fn codec(a: std.mem.Allocator, input: envelope.Envelope) !envelope.Envelope {
    try input.validate();
    if (!std.mem.eql(u8, input.protocol_id, config.protocol_id)) return error.ProtocolMismatch;
    var decoded = try config.decode(a, input.payload_version, input.payload);
    defer decoded.deinit();
    const payload = try config.encode(a, try readyPayload(decoded));
    errdefer a.free(payload);
    const name = try a.dupe(u8, input.name);
    errdefer a.free(name);
    const protocol = try a.dupe(u8, input.protocol_id);
    var output = input;
    output.payload = payload;
    output.name = name;
    output.protocol_id = protocol;
    return output;
}

fn migrate(a: std.mem.Allocator, input: envelope.Envelope, target: u32) !envelope.Envelope {
    if (target != config.payload_version) return error.UnsupportedPayloadVersion;
    return codec(a, input);
}

fn credentialReferences(_: std.mem.Allocator, _: []const u8) ![]const []const u8 {
    // Web payloads store only connection IDs. The SSH assets own their secrets.
    return &.{};
}

fn remapImport(a: std.mem.Allocator, bytes: []const u8, mappings: []const imports.Mapping) ![]u8 {
    var decoded = try config.decode(a, config.payload_version, bytes);
    defer decoded.deinit();
    var payload = try readyPayload(decoded);
    var ids: [config.max_hops]u64 = undefined;
    for (payload.route.hop_asset_ids, 0..) |id, index| {
        ids[index] = @backingInt(try imports.mapped(mappings, @fromBackingInt(id)));
    }
    payload.route.hop_asset_ids = ids[0..payload.route.hop_asset_ids.len];
    return config.encode(a, payload);
}

test "web manual page is bound to one host owner and revokes old mount tokens" {
    const testing = std.testing;
    const a = testing.allocator;
    const plugin = try Plugin.init(a);
    defer plugin.deinit() catch unreachable;
    var host = try sessions.SessionHost.initPlugins(a, &.{plugin.manifest()}, &.{plugin.renderer()});
    defer host.deinit();

    const target: sessions.AttachmentTarget = .{ .window_id = @fromBackingInt(1), .workspace_id = @fromBackingInt(1) };
    const accepted = try host.open(.{ .name = "Manual web", .protocol_id = config.protocol_id, .payload = "{\"url_mode\":\"manual\"}" }, .{ .request_key = 1, .target = target });
    const access = try host.serviceAccess(accepted.handle);
    try testing.expectError(error.ServiceNotReady, page.Page.lookup(access));
    try testing.expect(try host.pollControllers());
    const client = try page.Page.lookup(access);
    try testing.expect(try host.attached(accepted.handle, .{ .target = target, .tab_id = @fromBackingInt(1) }));

    const first = try client.attach();
    try testing.expect((try client.surfaceBinding(first)) == null);
    try client.mutateBookmark(.{ .add = .{ .url = "https://example.test/", .page_title = "Example" } });
    client.detach(first);
    const second = try client.attach();
    try testing.expect(second != first);
    try testing.expectError(error.StaleWebSurfaceMount, client.surfaceBinding(first));
    var state = try client.snapshot(a);
    defer state.deinit();
    try testing.expect(state.page == .blank and state.path == .ready);
    try testing.expectEqualStrings("Example", state.bookmarks[0].title);

    _ = try host.requestClose(accepted.handle, .{});
    try testing.expect(try host.pollControllers());
    try testing.expectEqual(sessions.Lifecycle.closed, host.queryState(accepted.handle).?.lifecycle);
    try testing.expectError(error.ServiceNotReady, client.command(.{ .navigate = "example.test" }));
    try testing.expectEqual(@as(usize, 0), plugin.runtimes.items.len);
}
