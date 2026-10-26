//! Test-only, non-terminal provider. Production linked_plugins never imports it.
const std = @import("std");
const registry = @import("../../host/plugin_registry.zig");
const sessions = @import("../../host/session_host.zig");
const services = @import("../../host/plugin_services.zig");
const identity = @import("../../host/identity.zig");
const contract = @import("../../host/plugin_ui_contract.zig");
const content = @import("../../host/content_context.zig");
const tools = @import("../../ai/plugin_tools.zig");
const images = @import("../../ai/image_attachments.zig");
const model = @import("model.zig");
const views = @import("views.zig");
const contexts = @import("../../host/host_context.zig");
const routes = @import("../../host/connection_config_resolver.zig");
const transports = @import("transport.zig");
const notifications = @import("../../host/notification_coordinator.zig");
const frames = @import("../../host/frame_texture_sink.zig");
const transport_api = @import("../../host/transport_factory.zig");
pub const Lifecycle = sessions.Adapter.VTable;
pub const lifecycle_key: services.ServiceKey = .{ .name = "lifecycle", .major = 1 };
pub const lifecycle = services.Definition.of(Lifecycle, lifecycle_key);
pub const definitions = [_]tools.ToolDefinition{
    .{ .id = "fixture_probe.ping", .description = "Read the synthetic workspace state", .schema = targets_schema, .required_services = &.{lifecycle} },
    .{ .id = "fixture_probe.observe", .description = "Observe the current synthetic RGBA canvas", .schema = targets_schema, .required_services = &.{lifecycle}, .effect = .observe_image },
    .{ .id = "fixture_probe.input", .description = "Simulate a pointer or key action on the synthetic canvas", .schema = input_schema, .validate = validateInput, .required_services = &.{lifecycle}, .effect = .remote_input, .approval_policy = .confirm },
    .{ .id = "fixture_probe.write", .description = "Simulate synthetic device power configuration", .schema = write_schema, .required_services = &.{lifecycle}, .effect = .resource_write, .approval_policy = .always_confirm },
};
pub const tool_bindings = [_]tools.ToolBinding{
    .{ .plugin_id = model.protocol_id, .definition_id = "fixture_probe.ping", .handler = Plugin.tool, .required_services = &.{lifecycle} },
    .{ .plugin_id = model.protocol_id, .definition_id = "fixture_probe.observe", .handler = Plugin.tool, .required_services = &.{lifecycle} },
    .{ .plugin_id = model.protocol_id, .definition_id = "fixture_probe.input", .handler = Plugin.tool, .required_services = &.{lifecycle} },
    .{ .plugin_id = model.protocol_id, .definition_id = "fixture_probe.write", .handler = Plugin.tool, .required_services = &.{lifecycle} },
};
const targets_schema = "{\"type\":\"object\",\"properties\":{\"session_ids\":{\"type\":\"array\",\"items\":{\"type\":\"integer\",\"minimum\":1},\"minItems\":1,\"uniqueItems\":true}},\"required\":[\"session_ids\"],\"additionalProperties\":false}";
const input_schema = "{\"type\":\"object\",\"properties\":{\"session_ids\":{\"type\":\"array\",\"items\":{\"type\":\"integer\",\"minimum\":1},\"minItems\":1,\"uniqueItems\":true},\"kind\":{\"type\":\"string\",\"enum\":[\"pointer\",\"key\"]},\"x\":{\"type\":\"integer\",\"minimum\":0,\"maximum\":63},\"y\":{\"type\":\"integer\",\"minimum\":0,\"maximum\":39},\"code\":{\"type\":\"integer\",\"minimum\":0,\"maximum\":65535}},\"required\":[\"session_ids\",\"kind\"],\"additionalProperties\":false}";
const write_schema = "{\"type\":\"object\",\"properties\":{\"session_ids\":{\"type\":\"array\",\"items\":{\"type\":\"integer\",\"minimum\":1},\"minItems\":1,\"uniqueItems\":true},\"powered\":{\"type\":\"boolean\"}},\"required\":[\"session_ids\",\"powered\"],\"additionalProperties\":false}";
fn validateInput(value: std.json.Value) !void {
    const kind = value.object.get("kind") orelse return error.InvalidToolArguments;
    if (std.mem.eql(u8, kind.string, "pointer")) {
        if (value.object.get("x") == null or value.object.get("y") == null or value.object.get("code") != null) return error.InvalidToolArguments;
    } else if (value.object.get("code") == null or value.object.get("x") != null or value.object.get("y") != null) return error.InvalidToolArguments;
}
pub const Runtime = struct {
    owner: identity.SessionHandle,
    key: sessions.OperationKey,
    phase: enum { accepted, authenticating, preparing, connecting, ready, closed } = .accepted,
    frame: model.Frame = .{},
    binding: services.Binding = undefined,
    input: ?*content.Context = null,
    frame_sink: ?*frames.Sink = null,
    frame_lock: std.atomic.Value(bool) = .init(false),
    input_events: usize = 0,
    write_events: usize = 0,
    released: bool = false,
    cleanup_receipt: sessions.CloseReceipt = .released,
    cleanup_transferred: bool = false,
    show_grid: bool = true,
    context: ?contexts.HostContext = null,
    route: ?routes.FrozenRoute = null,
    destination: [256]u8 = @splat(0),
    destination_len: usize = 0,
    port: u16 = 5900,
    pair: ?transports.Pair = null,
    prepared: ?*transport_api.OwnedTransport = null,
    worker: ?std.Thread = null,
    cancel_source: std.atomic.Value(bool) = .init(false),
    completed: std.atomic.Value(bool) = .init(false),
    problem: ?anyerror = null,
    transport_failure_receipt: transport_api.ReleaseReceipt = .released,
    notification_revision: u64 = 0,
    challenge_id: u64 = 0,
    challenge_deadline: u64 = 0,
    authenticated: bool = false,
    fn lock(self: *Runtime) void {
        while (self.frame_lock.swap(true, .acquire)) std.atomic.spinLoopHint();
    }
    fn unlock(self: *Runtime) void {
        self.frame_lock.store(false, .release);
    }
    pub fn copyFrame(self: *Runtime, a: std.mem.Allocator) !frames.Frame {
        self.lock();
        defer self.unlock();
        return frames.Frame.copy(a, self.owner, self.frame.revision, model.Frame.width, model.Frame.height, &self.frame.pixels);
    }
    fn publishFrame(self: *Runtime) !void {
        const sink = self.frame_sink orelse return;
        var cpu = try frames.Frame.copy(std.heap.c_allocator, self.owner, self.frame.revision, model.Frame.width, model.Frame.height, &self.frame.pixels);
        sink.submit(cpu) catch |err| {
            cpu.deinit();
            return err;
        };
    }
    fn notify(self: *Runtime, phase: notifications.Phase) !void {
        const context = self.context orelse return;
        const facade = context.notifications orelse return;
        self.notification_revision = if (self.notification_revision == 0) 1 else try identity.advance(self.notification_revision);
        _ = try facade.publish(.{ .definition_id = "fixture_probe.connection", .owner = facade.owner, .operation_id = self.key.operation_id, .attempt_id = self.key.attempt_id, .event_revision = self.notification_revision, .phase = phase, .title = "合成画面连接", .detail = switch (phase) {
            .accepted => "已接受独立连接",
            .verifying => "准备合成画面与本次资源",
            .succeeded => "合成画面已就绪",
            .failed => "本次连接失败",
            .cancelled => "已取消本次连接",
            .outcome_unknown => "远端结果待确认",
        } });
    }
    fn connect(self: *Runtime) void {
        defer self.completed.store(true, .release);
        const prepared = self.prepared.?;
        self.prepared = null;
        self.pair = transports.Pair.openPreparedWithReceipt(prepared, .{ .host = self.destination[0..self.destination_len], .port = self.port }, &self.transport_failure_receipt) catch |err| {
            self.problem = err;
            return;
        };
    }
    pub fn consume(ptr: *anyopaque, value: content.Input) !void {
        const self: *Runtime = @ptrCast(@alignCast(ptr));
        self.lock();
        defer self.unlock();
        if (self.phase == .closed) return error.OwnerClosed;
        switch (value) {
            .pointer => |pointer| {
                self.frame.pointer_x = @intFromFloat(std.math.clamp(pointer.x, 0, @as(f32, @floatFromInt(model.Frame.width - 1))));
                self.frame.pointer_y = @intFromFloat(std.math.clamp(pointer.y, 0, @as(f32, @floatFromInt(model.Frame.height - 1))));
                self.input_events += 1;
            },
            .key => |key| if (key.down) {
                self.frame.key_count += 1;
                self.input_events += 1;
            },
            .text => {
                self.frame.key_count += 1;
                self.input_events += 1;
            },
            .release_all => {},
        }
        self.frame.revision = try identity.advance(self.frame.revision);
        self.frame.render(self.show_grid);
        try self.publishFrame();
    }
    fn release(self: *Runtime) void {
        if (self.released) return;
        if (self.input) |input| input.close();
        self.input = null;
        self.frame_sink = null;
        if (self.context) |context| if (context.challenges) |challenges| challenges.ownerClosed(self.owner);
        self.cancel_source.store(true, .release);
        if (self.worker) |worker| {
            worker.join();
            self.worker = null;
        }
        if (self.prepared) |prepared| {
            if (prepared.close() == .released) {
                prepared.deinit() catch {
                    self.cleanup_receipt = .unknown;
                };
                if (self.cleanup_receipt == .released) self.prepared = null;
            } else {
                self.cleanup_receipt = .unknown;
                const adopted: ?transport_api.ReleaseReceipt = prepared.adoptFailedOpen() catch null;
                if (adopted != null) {
                    self.cleanup_transferred = true;
                    self.prepared = null;
                }
            }
        }
        if (self.pair) |*pair| {
            if (pair.close() == .released) {
                pair.deinit() catch {
                    self.cleanup_receipt = .unknown;
                };
                if (self.cleanup_receipt == .released) self.pair = null;
            } else {
                self.cleanup_receipt = .unknown;
                const adopted: ?transport_api.ReleaseReceipt = pair.owned.adoptFailedOpen() catch null;
                if (adopted != null) {
                    self.cleanup_transferred = true;
                    self.pair = null;
                }
            }
        }
        if (self.route) |*route| route.deinit();
        self.route = null;
        self.phase = .closed;
        self.released = true;
    }
};
pub const Plugin = struct {
    allocator: std.mem.Allocator,
    runtimes: std.ArrayList(*Runtime) = .empty,
    creates: usize = 0,
    releases: usize = 0,
    pub fn init(a: std.mem.Allocator) !*Plugin {
        const self = try a.create(Plugin);
        self.* = .{ .allocator = a };
        return self;
    }
    pub fn deinit(self: *Plugin) void {
        for (self.runtimes.items) |runtime| {
            runtime.release();
            if (runtime.cleanup_receipt == .released or runtime.cleanup_transferred) self.allocator.destroy(runtime);
        }
        self.runtimes.deinit(self.allocator);
        const a = self.allocator;
        a.destroy(self);
    }
    pub fn manifest(self: *Plugin) registry.PluginManifest {
        return .{
            .id = model.protocol_id,
            .display_name = "Fixture · 合成画面",
            .plugin_version = "0.2.0-test",
            .origin = .bundled,
            .order = 100,
            .icons = .{ .settings = "server", .protocol = "server", .tab = "server" },
            .integration = .{ .ai = true },
            .connection = .{ .create_kind = .saved_or_temporary, .validate_payload = model.validatePayload, .editor_factory = .{ .context = self, .mount = views.mountEditor }, .encode = codec, .decode = codec, .migrate = migrate },
            .workspace_kind = model.workspace_kind,
            .content_renderer = model.workspace_kind,
            .services = &.{lifecycle},
            .required_services = &.{lifecycle},
            .tool_definitions = &definitions,
            .tools = &tool_bindings,
            .notifications = &.{.{ .id = "fixture_probe.connection", .category = .connection_change }},
            .ai_context = .{ .identity = "Synthetic non-terminal fixture", .context = self, .summarize = summarize },
            .settings_section = .{ .fields = &.{.{ .key = "show_grid", .label = "显示合成网格", .kind = .boolean, .default_value = "true", .apply_timing = .next_connection }} },
            .session_factory = .{ .context = self, .vtable = &factory_vtable, .poll = poll },
        };
    }
    fn codec(a: std.mem.Allocator, value: @import("../../config/connection_envelope.zig").Envelope) !@import("../../config/connection_envelope.zig").Envelope {
        if (!std.mem.eql(u8, value.protocol_id, model.protocol_id)) return error.ProtocolMismatch;
        if (value.payload_version != 1) return error.UnsupportedPayloadVersion;
        try value.validate();
        try model.validatePayload(value.payload);
        return value.clone(a);
    }
    fn migrate(a: std.mem.Allocator, value: @import("../../config/connection_envelope.zig").Envelope, target_version: u32) !@import("../../config/connection_envelope.zig").Envelope {
        if (target_version != 1) return error.UnsupportedPayloadVersion;
        return codec(a, value);
    }
    fn summarize(ptr: ?*anyopaque, owner: identity.SessionHandle, a: std.mem.Allocator) ![]const u8 {
        const self: *Plugin = @ptrCast(@alignCast(ptr.?));
        const runtime = self.runtimeFor(owner) orelse return error.StaleBinding;
        return std.fmt.allocPrint(a, "Synthetic canvas {d}×{d}, revision {d}; no terminal or exec capability.", .{ model.Frame.width, model.Frame.height, runtime.frame.revision });
    }
    pub fn renderer(self: *Plugin) contract.RendererDefinition {
        return .{ .kind = model.workspace_kind, .context = self, .mount = views.mountContent, .supports_window_transfer = true };
    }
    pub fn runtimeFor(self: *Plugin, owner: identity.SessionHandle) ?*Runtime {
        for (self.runtimes.items) |runtime| if (runtime.owner.eql(owner)) return runtime;
        return null;
    }
    fn create(ptr: *anyopaque, request: sessions.CreateRequest) !void {
        const self: *Plugin = @ptrCast(@alignCast(ptr));
        const config = switch (request.spec) {
            .plugin => |value| value,
            else => return error.InvalidFixtureRequest,
        };
        try model.validatePayload(config.payload);
        const decoded = try std.json.parseFromSlice(model.Payload, self.allocator, config.payload, .{});
        defer decoded.deinit();
        const runtime = try self.allocator.create(Runtime);
        errdefer self.allocator.destroy(runtime);
        runtime.* = .{ .owner = request.handle, .key = request.key, .show_grid = decoded.value.show_grid };
        errdefer runtime.release();
        runtime.context = request.context;
        if (request.context) |context| {
            runtime.input = context.presentation.input;
            runtime.frame_sink = context.presentation.frame_sink;
        }
        if (request.context == null or request.context.?.challenges == null) return error.ChallengeHostUnavailable;
        if (request.context.?.preferences) |preferences| if (preferences.read("show_grid")) |value| {
            runtime.show_grid = std.mem.eql(u8, value, "true");
        };
        if (decoded.value.routed) {
            const context = request.context orelse return error.HostContextUnavailable;
            try context.requireOwner(request.handle);
            const configs = context.connection_configs orelse return error.ConfigurationResolverUnavailable;
            if (context.transports == null) return error.TransportFactoryUnavailable;
            var ids: [8]identity.ConnectionId = undefined;
            for (decoded.value.ssh_assets, 0..) |id, i| ids[i] = @fromBackingInt(id);
            runtime.route = try configs.freezeRoute(ids[0..decoded.value.ssh_assets.len], self.allocator);
            runtime.destination_len = decoded.value.destination.len;
            @memcpy(runtime.destination[0..runtime.destination_len], decoded.value.destination);
            runtime.port = decoded.value.port;
        }
        runtime.frame.render(runtime.show_grid);
        runtime.binding = services.Binding.init(Lifecycle, lifecycle_key, self, &factory_vtable, request.handle, 1);
        try self.runtimes.append(self.allocator, runtime);
        self.creates += 1;
    }
    pub fn poll(ptr: *anyopaque, host: *sessions.SessionHost) !bool {
        const self: *Plugin = @ptrCast(@alignCast(ptr));
        var changed = false;
        for (self.runtimes.items) |runtime| {
            if (runtime.phase != .closed) if (runtime.context) |context| if (context.tasks) |tasks| if (tasks.cancelled()) {
                runtime.cancel_source.store(true, .release);
                _ = try host.cancel(runtime.key);
                changed = true;
                continue;
            };
            switch (runtime.phase) {
                .accepted => {
                    try runtime.notify(.accepted);
                    runtime.challenge_id = runtime.key.operation_id;
                    runtime.challenge_deadline = try monotonicMs() + 30_000;
                    try runtime.context.?.challenges.?.offer(runtime.owner, runtime.challenge_id, runtime.owner.generation, .secret_input, .{ .title = "合成画面 · 本次连接密码", .detail = "仅用于本次测试连接，不保存。请输入非空密码。", .source_name = "Fixture · 合成画面" }, runtime.challenge_deadline);
                    runtime.phase = .authenticating;
                    changed = true;
                },
                .authenticating => {
                    const challenges = runtime.context.?.challenges.?;
                    if (try monotonicMs() >= runtime.challenge_deadline) {
                        _ = challenges.withdraw(runtime.owner, runtime.challenge_id, runtime.owner.generation) catch false;
                        _ = try host.failed(runtime.owner, runtime.key, .{ .domain = .plugin, .code = "ChallengeExpired", .safe_message = "本次密码请求已超时", .cleanup = .released });
                        self.release(runtime);
                        changed = true;
                        continue;
                    }
                    if (challenges.takeAnswer(runtime.owner, runtime.challenge_id, runtime.owner.generation)) |incoming| {
                        var answer = incoming;
                        defer answer.deinit();
                        if (answer.value != .secret_input or answer.value.secret_input.len == 0) {
                            _ = try host.failed(runtime.owner, runtime.key, .{ .domain = .plugin, .code = "EmptyConnectSecret", .safe_message = "本次连接需要非空密码", .cleanup = .released });
                            self.release(runtime);
                        } else {
                            runtime.authenticated = true;
                            runtime.phase = .preparing;
                        }
                        changed = true;
                    } else {
                        const state = challenges.stateFor(runtime.owner, runtime.challenge_id, runtime.owner.generation);
                        if (state == null or state == .withdrawn or state == .cancelled or state == .timed_out) {
                            _ = try host.cancel(runtime.key);
                            self.release(runtime);
                            changed = true;
                        }
                    }
                },
                .preparing => {
                    try runtime.notify(.verifying);
                    if (runtime.route != null) {
                        var factory = runtime.context.?.transports.?;
                        if (runtime.context.?.credentials) |credentials| factory.credentials = credentials;
                        runtime.prepared = factory.prepareOwned(.{ .session = runtime.owner }, &runtime.route.?, .connection, &runtime.cancel_source) catch |err| {
                            _ = try host.failed(runtime.owner, runtime.key, .{ .domain = .transport, .code = @errorName(err), .safe_message = "本次路由凭据无法准备", .cleanup = .released });
                            self.release(runtime);
                            changed = true;
                            continue;
                        };
                        runtime.worker = std.Thread.spawn(.{}, Runtime.connect, .{runtime}) catch |err| {
                            _ = try host.failed(runtime.owner, runtime.key, .{ .domain = .plugin, .code = @errorName(err), .safe_message = "无法启动本次连接任务", .cleanup = .released });
                            self.release(runtime);
                            changed = true;
                            continue;
                        };
                        runtime.phase = .connecting;
                        changed = true;
                        continue;
                    }
                    if (try host.readyPlugin(runtime.owner, runtime.key, &.{runtime.binding})) {
                        runtime.phase = .ready;
                        try runtime.notify(.succeeded);
                    } else {
                        runtime.release();
                        self.releases += 1;
                    }
                    changed = true;
                },
                .connecting => {
                    if (!runtime.completed.load(.acquire)) continue;
                    if (runtime.worker) |worker| {
                        worker.join();
                        runtime.worker = null;
                    }
                    if (runtime.problem) |problem| {
                        runtime.cleanup_receipt = if (runtime.transport_failure_receipt == .released) .released else .unknown;
                        runtime.cleanup_transferred = runtime.transport_failure_receipt != .released;
                        try runtime.notify(.failed);
                        _ = try host.failed(runtime.owner, runtime.key, .{ .domain = .transport, .code = @errorName(problem), .safe_message = "Fixture transport could not be established", .cleanup = if (runtime.cleanup_receipt == .released) .released else .unknown });
                        self.release(runtime);
                    } else if (try host.readyPlugin(runtime.owner, runtime.key, &.{runtime.binding})) {
                        runtime.phase = .ready;
                        try runtime.notify(.succeeded);
                    } else self.release(runtime);
                    changed = true;
                },
                .ready, .closed => {},
            }
        }
        return changed;
    }
    fn cancel(ptr: *anyopaque, key: sessions.OperationKey) sessions.CloseReceipt {
        const self: *Plugin = @ptrCast(@alignCast(ptr));
        for (self.runtimes.items) |runtime| if (runtime.key.eql(key)) {
            self.release(runtime);
            return runtime.cleanup_receipt;
        };
        return .released;
    }
    fn close(ptr: *anyopaque, owner: identity.SessionHandle, _: sessions.OperationKey) !sessions.CloseReceipt {
        const self: *Plugin = @ptrCast(@alignCast(ptr));
        if (self.runtimeFor(owner)) |runtime| {
            self.release(runtime);
            return runtime.cleanup_receipt;
        }
        return .released;
    }
    fn stale(ptr: *anyopaque, owner: identity.SessionHandle, _: sessions.OperationKey) void {
        const self: *Plugin = @ptrCast(@alignCast(ptr));
        if (self.runtimeFor(owner)) |runtime| self.release(runtime);
    }
    fn release(self: *Plugin, runtime: *Runtime) void {
        if (!runtime.released) {
            runtime.release();
            self.releases += 1;
        }
    }
    fn ping(ptr: *anyopaque) !u64 {
        const runtime: *Runtime = @ptrCast(@alignCast(ptr));
        if (runtime.phase == .closed) return error.OwnerClosed;
        return runtime.frame.revision;
    }
    fn rebindContext(raw: *anyopaque, owner: identity.SessionHandle, next: contexts.HostContext) !void {
        const self: *Plugin = @ptrCast(@alignCast(raw));
        const runtime = self.runtimeFor(owner) orelse return error.UnknownSession;
        if (runtime.phase != .ready or runtime.released or !next.operation.eql(runtime.key)) return error.StaleHostContext;
        try next.requireOwner(owner);
        const presentation = next.presentation;
        if (presentation.input == null or presentation.frame_sink == null) return error.ContentContextUnavailable;
        runtime.context = next;
        runtime.input = presentation.input;
        runtime.frame_sink = presentation.frame_sink;
    }
    const factory_vtable: sessions.Adapter.VTable = .{ .create = create, .cancel = cancel, .close = close, .release_stale = stale, .rebind_context = rebindContext };
    pub fn tool(ptr: *anyopaque, call: tools.Invocation, a: std.mem.Allocator) !tools.ToolResult {
        const self: *Plugin = @ptrCast(@alignCast(ptr));
        const runtime = self.runtimeFor(call.owner) orelse return error.StaleBinding;
        _ = try runtime.binding.borrow(Lifecycle, lifecycle_key, call.owner);
        if (runtime.phase != .ready) return error.OwnerClosed;
        var result: tools.ToolResult = .{ .status = .succeeded, .receipt = .{ .operation_id = call.operation_id, .owner = call.owner } };
        const blocks = try a.alloc(tools.ContentBlock, 1);
        errdefer a.free(blocks);
        if (std.mem.eql(u8, call.tool_id, "fixture_probe.observe")) {
            runtime.lock();
            defer runtime.unlock();
            const png = try runtime.frame.png(a);
            defer a.free(png);
            blocks[0] = .{ .image_ref = try images.ContentRef.create(a, "fixture_probe:synthetic-canvas", png, 0, .{}) };
        } else if (std.mem.eql(u8, call.tool_id, "fixture_probe.input")) {
            const input = runtime.input orelse return error.InputFacadeUnavailable;
            const lease = try input.acquire(.automation, input.authorization_revision);
            const kind = call.arguments.object.get("kind").?.string;
            const event: content.Input = if (std.mem.eql(u8, kind, "pointer")) .{ .pointer = .{ .x = @floatFromInt((call.arguments.object.get("x") orelse return error.MissingPointerCoordinates).integer), .y = @floatFromInt((call.arguments.object.get("y") orelse return error.MissingPointerCoordinates).integer), .buttons = 1 } } else .{ .key = .{ .code = @intCast((call.arguments.object.get("code") orelse return error.MissingKeyCode).integer), .down = true } };
            _ = try input.route(lease, call.operation_id, event, false);
            blocks[0] = .{ .structured = try a.dupe(u8, "{\"input\":\"simulated\"}") };
        } else if (std.mem.eql(u8, call.tool_id, "fixture_probe.write")) {
            runtime.lock();
            defer runtime.unlock();
            runtime.write_events += 1;
            runtime.frame.powered = call.arguments.object.get("powered").?.bool;
            runtime.frame.revision = try identity.advance(runtime.frame.revision);
            runtime.frame.render(runtime.show_grid);
            try runtime.publishFrame();
            blocks[0] = .{ .structured = try a.dupe(u8, "{\"configuration\":\"simulated\"}") };
        } else if (std.mem.eql(u8, call.tool_id, "fixture_probe.ping")) {
            blocks[0] = .{ .structured = try std.fmt.allocPrint(a, "{{\"revision\":{d},\"terminal\":false}}", .{runtime.frame.revision}) };
        } else return error.UnknownTool;
        result.blocks = blocks;
        return result;
    }
};
pub fn register(host: *registry.PluginHost, plugin: *Plugin) !void {
    try host.registerRenderer(plugin.renderer());
    try host.register(plugin.manifest());
}
fn monotonicMs() !u64 {
    var ts: std.c.timespec = undefined;
    if (std.c.clock_gettime(.MONOTONIC, &ts) != 0) return error.ClockUnavailable;
    return @as(u64, @intCast(ts.sec)) * 1000 + @as(u64, @intCast(ts.nsec)) / 1_000_000;
}
