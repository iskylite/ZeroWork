//! Production API-2 contribution. Composition owns the shared frame budget and
//! stable durable journal backend; factories only prepare and submit workers.
const std = @import("std");
const builtin = @import("builtin");
const registry = @import("../../host/plugin_registry.zig");
const sessions = @import("../../host/session_host.zig");
const contract = @import("../../host/plugin_ui_contract.zig");
const probes = @import("../../host/probe_contract.zig");
const challenges = @import("../../host/challenge_host.zig");
const tls = @import("../../host/tls_trust.zig");
const budgets = @import("../../host/frame_budget.zig");
const api = @import("../../ai/plugin_tools.zig");
const svc = @import("services.zig");
const model = @import("model.zig");
const codec = @import("codec.zig");
const runtime_api = @import("runtime.zig");
const console = @import("console_service.zig");
const tools = @import("tools.zig");
const probe = @import("probe.zig");
const auth = @import("protocol/auth.zig");
const ledger = @import("management_journal.zig");
pub const Options = struct {
    /// The same application-level 512 MiB budget used by every frame sink.
    /// Its stable owner and the journal backend outlive successful deinit.
    frame_budget: *budgets.Budget,
    journal_backend: ledger.Backend,
    management_policy: svc.ManagementPolicy = .user_approved,
    /// ProbeContext intentionally has no presentation/UI capabilities. This
    /// mailbox host is supplied by composition and is touched only in poll.
    probe_challenges: ?*challenges.Host = null,
    /// Composition tracks the new attempt for its existing attach flow.
    retry_context: ?*anyopaque = null,
    retry_accepted: ?*const fn (?*anyopaque, sessions.Accepted) anyerror!void = null,
};
pub const declared_services = [_]registry.ServiceDefinition{ runtime_api.lifecycle_definition, console.definition, @import("framebuffer.zig").definition, @import("remote_input.zig").definition, svc.power_definition, svc.boot_definition, @import("ai_control.zig").definition };
pub const dependencies = [_]registry.Dependency{
    .{ .id = "host", .major = 2 }, .{ .id = "host.session_service_access" }, .{ .id = "host.probes" }, .{ .id = "host.tls_trust" }, .{ .id = "host.secrets" }, .{ .id = "host.resource_actions" }, .{ .id = "host.frame_budget" },
};
pub const tool_bindings = tools.bindings(Plugin.tool);
const ProbeEntry = struct { key: svc.OperationKey, bridge: runtime_api.ChallengeBridge };
pub const Plugin = struct {
    allocator: std.mem.Allocator,
    options: Options,
    journal: ledger.Journal,
    provider: ?*probe.Provider = null,
    runtimes: std.ArrayList(*runtime_api.Runtime) = .empty,
    probe_entries: [probe.Provider.capacity]?*ProbeEntry = @splat(null),
    probe_mutex: std.atomic.Mutex = .unlocked,
    owner_thread: std.Thread.Id,
    shutting_down: bool = false,
    test_driver: if (builtin.is_test) ?@import("controller.zig").Driver else void = if (builtin.is_test) null else {},

    /// The backend may read/recover its durable file here. create never reads
    /// this file or performs network IO. init does not silently use HOME.
    pub fn init(a: std.mem.Allocator, options: Options) !*Plugin {
        const self = try a.create(Plugin);
        errdefer a.destroy(self);
        self.* = .{ .allocator = a, .options = options, .journal = try ledger.Journal.init(a, options.journal_backend), .owner_thread = std.Thread.getCurrentId() };
        errdefer self.journal.deinit();
        self.provider = try probe.Provider.init(a, .{ .callbacks = .{ .context = self, .trust_reply = probeTrustReply, .password_reply = probePasswordReply } });
        return self;
    }
    /// Nonblocking. A pending/unknown worker or live FrameLease keeps the
    /// plugin, facade stores, journal and frame budget alive for later drains.
    pub fn deinit(self: *Plugin) !void {
        try self.requireThread();
        self.shutting_down = true;
        var pending = false;
        for (self.runtimes.items) |runtime| {
            runtime.retry_disabled = true;
            runtime.retry_requested = false;
            runtime.cancel_requested = false;
            if (runtime.close() != .released) pending = true;
        }
        for (self.probe_entries) |slot| if (slot) |entry| {
            entry.bridge.cancel();
            if (self.provider) |provider| {
                const factory = provider.factory();
                _ = factory.cancel(factory.context, entry.key);
            }
        };
        if (pending) return error.BmcCleanupPending;
        if (self.provider) |provider| {
            provider.deinit() catch |err| {
                if (err == error.ProbeCleanupPending) return error.BmcCleanupPending;
                return err;
            };
            self.provider = null;
        }
        while (self.runtimes.items.len != 0) {
            const runtime = self.runtimes.items[self.runtimes.items.len - 1];
            try runtime.deinit();
            self.runtimes.items.len -= 1;
        }
        self.runtimes.deinit(self.allocator);
        for (&self.probe_entries) |*slot| if (slot.*) |entry| {
            entry.bridge.deinit();
            self.allocator.destroy(entry);
            slot.* = null;
        };
        self.journal.deinit();
        const a = self.allocator;
        a.destroy(self);
    }
    pub fn manifest(self: *Plugin) registry.PluginManifest {
        return .{
            .id = model.protocol_id,
            .display_name = "BMC · iKVM",
            .plugin_version = "0.3.2",
            .origin = .bundled,
            .host_api_version = 2,
            .order = 30,
            .dependencies = &dependencies,
            .icons = .{ .settings = "monitor", .protocol = "monitor", .tab = "monitor" },
            .integration = .{ .ai = true, .transport_loss = true, .retry_after_end = true },
            .connection = .{ .create_kind = .saved_or_temporary, .payload_version = 1, .validate_payload = model.validatePayload, .editor_factory = .{ .context = self, .mount = @import("editor.zig").mountEditor }, .encode = codec.encode, .decode = codec.decode, .migrate = codec.migrate, .credential_references = codec.credentialReferences, .probe_factory = .{ .context = self, .begin = beginProbe, .poll = pollProbe, .cancel = cancelProbe } },
            .workspace_kind = model.workspace_kind,
            .content_renderer = model.workspace_kind,
            .services = &declared_services,
            .frame_limits = .kvm,
            .required_services = &.{ runtime_api.lifecycle_definition, console.definition, @import("framebuffer.zig").definition, @import("remote_input.zig").definition },
            .settings_section = .{ .fields = &.{} },
            .notifications = &.{.{ .id = "bmc_ikvm.connection", .category = .connection_change }},
            .tool_definitions = &tools.definitions,
            .tools = &tool_bindings,
            .ai_context = .{ .identity = "BMC console with read-only management, approved remote-frame observation and exclusive bounded input", .context = self, .summarize = summarize },
            .session_factory = .{ .context = self, .vtable = &factory_vtable, .poll = poll },
        };
    }
    pub fn renderer(self: *Plugin) contract.RendererDefinition {
        return .{ .kind = model.workspace_kind, .context = self, .mount = @import("views.zig").mount, .supports_window_transfer = false };
    }
    fn requireThread(self: *Plugin) !void {
        if (self.owner_thread != std.Thread.getCurrentId()) return error.BmcWrongConfigurationThread;
    }
    fn from(raw: *anyopaque) *Plugin {
        return @ptrCast(@alignCast(raw));
    }
    pub fn runtimeFor(self: *Plugin, owner: svc.identity.SessionHandle) ?*runtime_api.Runtime {
        for (self.runtimes.items) |runtime| if (runtime.owner.eql(owner)) return runtime;
        return null;
    }
    fn create(raw: *anyopaque, request: sessions.CreateRequest) !void {
        const self = from(raw);
        try self.requireThread();
        if (self.shutting_down) return error.PluginShuttingDown;
        if (self.runtimeFor(request.handle) != null) return error.DuplicateBmcOwner;
        try self.runtimes.ensureUnusedCapacity(self.allocator, 1);
        const resources: runtime_api.Resources = .{ .frame_budget = self.options.frame_budget, .journal = &self.journal, .management_policy = self.options.management_policy };
        const injected_driver: ?@import("controller.zig").Driver = if (builtin.is_test) self.test_driver else null;
        const runtime = if (injected_driver) |driver|
            try runtime_api.Runtime.prepareForTest(self.allocator, request, resources, driver)
        else
            try runtime_api.Runtime.prepare(self.allocator, request, resources);
        self.runtimes.appendAssumeCapacity(runtime);
    }
    pub fn poll(raw: *anyopaque, host: *sessions.SessionHost) !bool {
        const self = from(raw);
        try self.requireThread();
        var changed = false;
        var retry_owner: ?svc.identity.SessionHandle = null;
        // A retry appends a runtime; start it only after this borrowed slice is
        // drained, so ArrayList reallocation cannot invalidate the iteration.
        for (self.runtimes.items) |runtime| {
            if (runtime.cancel_requested) {
                runtime.cancel_requested = false;
                if (!runtime.stopping and !self.shutting_down and runtime.published and !runtime.stale and runtime.close_operation == null) {
                    runtime.cancelled_by_user = true;
                    _ = runtime.close();
                    changed = true;
                }
            }
            if (runtime.context.tasks) |tasks| if (tasks.cancelled() and !runtime.stopping) {
                runtime.retry_disabled = true;
                _ = try host.cancel(runtime.operation);
                _ = runtime.close();
                changed = true;
            };
            if (!runtime.published and !runtime.stopping) {
                const bindings = runtime.bindings(self, &factory_vtable);
                runtime.published = try host.readyPlugin(runtime.owner, runtime.operation, &bindings);
                if (!runtime.published) {
                    runtime.stale = true;
                    _ = runtime.close();
                }
                changed = true;
                if (runtime.published) try runtime.notify(.accepted, "正在建立独立 BMC 连接，等待视频首帧");
            }
            changed = (try runtime.poll()) or changed;
            if (runtime.retry_requested and !runtime.stopping and !self.shutting_down and !runtime.stale and runtime.close_operation == null) {
                _ = runtime.close();
                changed = true;
            }
            if (runtime.stopping) {
                const receipt = runtime.receipt();
                if (runtime.reported_create_receipt != receipt) {
                    _ = try host.createCleanupReceipt(runtime.owner, runtime.operation, receipt);
                    runtime.reported_create_receipt = receipt;
                }
                if (runtime.close_operation) |key| if (runtime.reported_close_receipt != receipt) {
                    _ = try host.closeReceipt(runtime.owner, key, .close_protocol, receipt);
                    runtime.reported_close_receipt = receipt;
                };
                if (runtime.retry_requested and receipt == .released and retry_owner == null and !self.shutting_down and runtime.published and !runtime.stale and runtime.close_operation == null) {
                    const failure: @import("../../host/operation.zig").Failure = .{ .domain = .plugin, .code = "ManualRetry", .retryable = true, .cleanup = .released, .safe_message = "用户请求重新连接 BMC" };
                    _ = try host.transportLost(runtime.owner, runtime.operation, failure);
                    _ = try host.failed(runtime.owner, runtime.operation, failure);
                    runtime.retry_requested = false;
                    retry_owner = runtime.owner;
                }
            }
        }
        if (retry_owner) |owner| {
            const accepted = try host.retry(owner);
            if (self.runtimeFor(owner)) |old_runtime| old_runtime.stale = true;
            if (self.options.retry_accepted) |callback| try callback(self.options.retry_context, accepted);
            changed = true;
        }
        return changed;
    }
    fn cancel(raw: *anyopaque, key: svc.OperationKey) sessions.CloseReceipt {
        const self = from(raw);
        self.requireThread() catch return .unknown;
        for (self.runtimes.items) |runtime| if (runtime.operation.eql(key)) return runtime.close();
        return .released;
    }
    fn close(raw: *anyopaque, owner: svc.identity.SessionHandle, key: svc.OperationKey) !sessions.CloseReceipt {
        const self = from(raw);
        try self.requireThread();
        try tls.requireOperation(owner, key);
        const runtime = self.runtimeFor(owner) orelse return .released;
        if (runtime.close_operation) |previous| if (!previous.eql(key)) return error.StaleCloseOperation;
        runtime.close_operation = key;
        runtime.retry_disabled = true;
        runtime.retry_requested = false;
        runtime.cancel_requested = false;
        runtime.cancelled_by_user = false;
        return runtime.close();
    }
    fn releaseStale(raw: *anyopaque, owner: svc.identity.SessionHandle, key: svc.OperationKey) void {
        const self = from(raw);
        self.requireThread() catch return;
        const runtime = self.runtimeFor(owner) orelse return;
        if (!runtime.operation.eql(key)) return;
        runtime.stale = true;
        _ = runtime.close();
    }
    const factory_vtable: sessions.Adapter.VTable = .{ .create = create, .cancel = cancel, .close = close, .release_stale = releaseStale };
    pub fn tool(raw: *anyopaque, invocation: api.Invocation, a: std.mem.Allocator) !api.ToolResult {
        const self = from(raw);
        try self.requireThread();
        const runtime = self.runtimeFor(invocation.owner) orelse return error.StaleBinding;
        if (!runtime.published or runtime.stopping or runtime.stale) return error.StaleBinding;
        return tools.invoke(.{ .owner = runtime.owner, .console = runtime.consoleBinding(), .power = runtime.powerBinding(), .boot = runtime.bootBinding(), .ai = runtime.aiBinding() }, invocation, a);
    }
    fn summarize(raw: ?*anyopaque, owner: svc.identity.SessionHandle, a: std.mem.Allocator) ![]const u8 {
        const self = from(raw orelse return error.PluginUnavailable);
        const runtime = self.runtimeFor(owner) orelse return error.StaleBinding;
        var snapshot = try runtime.snapshot(a);
        defer snapshot.deinit();
        return std.fmt.allocPrint(a, "BMC {s}; video {s}; frame {d}×{d}; management is read-only; screenshot needs image-sharing approval; input needs an exclusive host lease and fresh observation. Queued/sent input never proves its intended screen effect.", .{ snapshot.value.name, @tagName(snapshot.value.video), snapshot.value.width, snapshot.value.height });
    }
    fn beginProbe(raw: *anyopaque, request: probes.ProbeRequest) !void {
        const self = from(raw);
        try self.requireThread();
        if (self.shutting_down) return error.PluginShuttingDown;
        const provider = self.provider orelse return error.PluginUnavailable;
        const slot = for (&self.probe_entries) |*candidate| {
            if (candidate.* == null) break candidate;
        } else return error.ProbeCapacity;
        const entry = try self.allocator.create(ProbeEntry);
        errdefer self.allocator.destroy(entry);
        entry.* = .{ .key = request.operation, .bridge = runtime_api.ChallengeBridge.init(self.allocator, request.handle, request.operation, request.restricted_context.challenges orelse self.options.probe_challenges) };
        errdefer entry.bridge.deinit();
        while (!self.probe_mutex.tryLock()) std.atomic.spinLoopHint();
        slot.* = entry;
        self.probe_mutex.unlock();
        errdefer {
            while (!self.probe_mutex.tryLock()) std.atomic.spinLoopHint();
            slot.* = null;
            self.probe_mutex.unlock();
        }
        const factory = provider.factory();
        try factory.begin(factory.context, request);
    }
    fn probeEntry(self: *Plugin, owner: svc.identity.SessionHandle, operation: svc.OperationKey) ?*ProbeEntry {
        while (!self.probe_mutex.tryLock()) std.atomic.spinLoopHint();
        defer self.probe_mutex.unlock();
        for (self.probe_entries) |slot| if (slot) |entry| if (entry.bridge.owner.eql(owner) and entry.key.eql(operation)) return entry;
        return null;
    }
    fn pollProbe(raw: *anyopaque, key: svc.OperationKey) !?probes.ProbeUpdate {
        const self = from(raw);
        try self.requireThread();
        const provider = self.provider orelse return error.PluginUnavailable;
        const owner = switch (key.owner) {
            .session => |value| value,
            else => return error.InvalidOperationOwner,
        };
        const entry = self.probeEntry(owner, key) orelse return error.StaleProbeOperation;
        _ = try entry.bridge.poll();
        const factory = provider.factory();
        const update = try factory.poll(factory.context, key);
        if (update != null and update.? == .result and update.?.result.cleanup == .released) {
            while (!self.probe_mutex.tryLock()) std.atomic.spinLoopHint();
            for (&self.probe_entries) |*slot| if (slot.* == entry) {
                slot.* = null;
                break;
            };
            self.probe_mutex.unlock();
            entry.bridge.deinit();
            self.allocator.destroy(entry);
        }
        return update;
    }
    fn cancelProbe(raw: *anyopaque, key: svc.OperationKey) sessions.CloseReceipt {
        const self = from(raw);
        self.requireThread() catch return .unknown;
        const provider = self.provider orelse return .released;
        if (key.owner == .session) if (self.probeEntry(key.owner.session, key)) |entry| entry.bridge.cancel();
        const factory = provider.factory();
        return factory.cancel(factory.context, key);
    }
    fn probeTrustReply(raw: *anyopaque, challenge: tls.Challenge, cancel_value: *const std.atomic.Value(bool)) !tls.TrustChoice {
        const self = from(raw);
        const entry = self.probeEntry(challenge.owner, challenge.operation) orelse return error.StaleProbeOperation;
        return runtime_api.ChallengeBridge.trustReply(&entry.bridge, challenge, cancel_value);
    }
    fn probePasswordReply(raw: *anyopaque, owner: svc.identity.SessionHandle, key: svc.OperationKey, cancel_value: *const std.atomic.Value(bool), a: std.mem.Allocator) !auth.Secret {
        const self = from(raw);
        const entry = self.probeEntry(owner, key) orelse return error.StaleProbeOperation;
        return runtime_api.ChallengeBridge.passwordReply(&entry.bridge, owner, key, cancel_value, a);
    }
};
pub fn register(host: *registry.PluginHost, plugin: *Plugin) !void {
    try host.registerRenderer(plugin.renderer());
    try host.register(plugin.manifest());
}
