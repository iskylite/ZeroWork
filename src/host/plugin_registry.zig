const std = @import("std");

pub const host_api_version: u32 = 2;
pub const plugin_version = "0.2.0";
/// Compatibility IDs for the three legacy engine adapters only. Public IDs are strings.
pub const LegacyPluginId = enum { local, ssh, sftp, external };
pub const PluginId = LegacyPluginId;
/// Compatibility layout hints; renderer lookup uses the open workspace kind string.
pub const LegacyWorkspaceKind = enum { terminal, file, custom };
pub const WorkspaceKind = LegacyWorkspaceKind;
pub const CreateKind = enum { local, saved_or_temporary, saved };
/// No public plugin/service identity is added to this old engine compatibility list.
pub const LegacyServiceKind = enum { lifecycle, terminal, process, cwd, auth, route, directory, file_read, transfer, exec, forward };
pub const ServiceKind = LegacyServiceKind;

/// Fixed engine-only metadata. API-v2 declarations and capabilities use typed slices.
pub const LegacyServices = struct {
    bits: u16 = 0,

    pub fn of(comptime kinds: []const ServiceKind) Services {
        var value: Services = .{};
        for (kinds) |kind| value.bits |= @as(u16, 1) << @backingInt(kind);
        return value;
    }

    pub fn has(self: Services, kind: ServiceKind) bool {
        return self.bits & (@as(u16, 1) << @backingInt(kind)) != 0;
    }

    pub fn contains(self: Services, required: Services) bool {
        return self.bits & required.bits == required.bits;
    }
};

pub const Services = LegacyServices;

/// Legacy engine metadata projection; never the executable plugin contract.
pub const PluginDescriptor = struct {
    plugin_id: PluginId,
    display_name: []const u8,
    icon: []const u8,
    host_api_version: u32,
    plugin_version: []const u8,
    workspace_kind: WorkspaceKind,
    create_kind: CreateKind,
    services: Services,
};

pub const builtin_descriptors = [_]PluginDescriptor{
    .{ .plugin_id = .local, .display_name = "Local · zsh", .icon = "terminal", .host_api_version = host_api_version, .plugin_version = plugin_version, .workspace_kind = .terminal, .create_kind = .local, .services = Services.of(&.{ .lifecycle, .terminal, .process, .cwd, .exec }) },
    .{ .plugin_id = .ssh, .display_name = "SSH", .icon = "server", .host_api_version = host_api_version, .plugin_version = plugin_version, .workspace_kind = .terminal, .create_kind = .saved_or_temporary, .services = Services.of(&.{ .lifecycle, .terminal, .process, .cwd, .auth, .route, .exec, .forward, .transfer }) },
    .{ .plugin_id = .sftp, .display_name = "SFTP", .icon = "folder", .host_api_version = host_api_version, .plugin_version = plugin_version, .workspace_kind = .file, .create_kind = .saved, .services = Services.of(&.{ .lifecycle, .auth, .route, .directory, .file_read, .transfer }) },
};

/// Legacy engine capability bridge. New plugins use typed definitions exclusively.
pub const AdapterRegistration = struct {
    plugin_id: PluginId,
    host_api_version: u32 = host_api_version,
    workspace_kind: WorkspaceKind,
    services: Services,
};
pub const typed = @import("plugin_services.zig");
pub const ServiceKey = typed.ServiceKey;
pub const ServiceDefinition = typed.Definition;
pub const ServiceBinding = typed.Binding;
pub const ServiceRequirement = typed.Requirement;
pub const Origin = enum { builtin, bundled };
pub const Dependency = struct { id: []const u8, major: u32 = 1 };
pub const ApiDefinition = struct { id: []const u8, major: u32 = 1 };
pub const Icons = struct { settings: []const u8 = "terminal", protocol: []const u8 = "terminal", tab: []const u8 = "terminal", archive: []const u8 = "history" };
/// These flags describe legacy independent file engines, never identify a plugin.
pub const Integration = struct {
    retry_after_end: bool = false,
    transport_loss: bool = false,
    auxiliary_readonly: bool = false,
    auxiliary_transfer: bool = false,
    directory_recovery: bool = false,
    ai: bool = false,
};
pub const PreferenceField = struct {
    key: []const u8,
    label: []const u8,
    kind: enum { boolean, string, choice },
    default_value: ?[]const u8 = null,
    options: []const struct { value: []const u8, label: []const u8 } = &.{},
    apply_timing: enum { immediate, next_connection } = .next_connection,
};
pub const SettingsSection = struct { fields: []const PreferenceField };
pub const ConnectionContribution = struct {
    create_kind: enum { saved, saved_or_temporary } = .saved,
    payload_version: u32 = 1,
    editor_factory: @import("plugin_ui_contract.zig").EditorFactory = .{},
    validate_payload: *const fn ([]const u8) anyerror!void,
    encode: ?*const fn (std.mem.Allocator, @import("../config/connection_envelope.zig").Envelope) anyerror!@import("../config/connection_envelope.zig").Envelope = null,
    decode: ?*const fn (std.mem.Allocator, @import("../config/connection_envelope.zig").Envelope) anyerror!@import("../config/connection_envelope.zig").Envelope = null,
    migrate: ?*const fn (std.mem.Allocator, @import("../config/connection_envelope.zig").Envelope, u32) anyerror!@import("../config/connection_envelope.zig").Envelope = null,
};
/// A non-persistent creation entry (for example a native process). It has no
/// remote asset/editor and uses the same session factory and owner lifecycle.
pub const QuickCreateContribution = struct {
    payload_version: u32 = 1,
    validate_payload: *const fn ([]const u8) anyerror!void,
    new_session_payload: ?*const fn (std.mem.Allocator, []const u8) anyerror![]u8 = null,
    action_id: ?[]const u8 = null,
    encode_creation_payload: ?*const fn (std.mem.Allocator, ?[]const u8) anyerror![]u8 = null,
};
pub const RendererDefinition = @import("plugin_ui_contract.zig").RendererDefinition;
pub const AiContextContribution = struct {
    identity: []const u8,
    context: ?*anyopaque = null,
    summarize: ?*const fn (?*anyopaque, @import("identity.zig").SessionHandle, std.mem.Allocator) anyerror![]const u8 = null,
};
pub const PluginManifest = struct {
    id: []const u8,
    display_name: []const u8,
    plugin_version: []const u8 = plugin_version,
    origin: Origin = .bundled,
    host_api_version: u32 = host_api_version,
    order: i32 = 0,
    dependencies: []const Dependency = &.{},
    provides: []const ApiDefinition = &.{},
    icons: Icons = .{},
    integration: Integration = .{},
    connection: ?ConnectionContribution = null,
    quick_create: ?QuickCreateContribution = null,
    settings_section: ?SettingsSection = null,
    session_factory: ?@import("session_host.zig").SessionFactory = null,
    workspace_kind: []const u8,
    content_renderer: []const u8,
    services: []const ServiceDefinition = &.{},
    required_services: []const ServiceRequirement = &.{},
    notifications: []const @import("notification_coordinator.zig").NotificationDefinition = &.{},
    tools: []const @import("../ai/plugin_tools.zig").ToolBinding = &.{},
    tool_definitions: []const @import("../ai/plugin_tools.zig").ToolDefinition = &.{},
    ai_context: ?AiContextContribution = null,
    ai_adapter_factory: ?@import("../ai/legacy_adapter.zig").Factory = null,
    legacy_descriptor: ?PluginDescriptor = null,
    legacy_registration: ?AdapterRegistration = null,
    pub fn supports(self: PluginManifest, requirement: ServiceRequirement) bool {
        for (self.services) |definition| if (definition.matches(requirement)) return true;
        return false;
    }
};
pub const Availability = enum {
    available,
    adapter_not_connected,
    pub fn reason(self: Availability) ?[]const u8 {
        return if (self == .available) null else "运行适配器尚未接入";
    }
};
pub const BuiltinSnapshot = struct { descriptor: PluginDescriptor, availability: Availability, ready_services: Services };
pub const RegistrySnapshot = struct { entries: []const PluginManifest, renderers: []const RendererDefinition };
pub const Registry = struct {
    arena: ?std.heap.ArenaAllocator = null,
    published: RegistrySnapshot = .{ .entries = &.{}, .renderers = &.{} },
    legacy_snapshots: []const BuiltinSnapshot = &builtin_snapshots,
    descriptors: []const PluginDescriptor = &builtin_descriptors,
    registrations: []const AdapterRegistration = &.{},

    /// Metadata-only planning registry. No factory is exposed as executable.
    pub fn builtins() Registry {
        return .{};
    }
    pub fn deinit(self: *Registry) void {
        if (self.arena) |*arena| arena.deinit();
        self.* = .{};
    }
    pub fn manifests(self: Registry) []const PluginManifest {
        return self.published.entries;
    }
    pub fn find(self: Registry, id: []const u8) ?*const PluginManifest {
        for (self.published.entries) |*manifest| if (std.mem.eql(u8, manifest.id, id)) return manifest;
        return null;
    }
    pub fn renderer(self: Registry, kind: []const u8) ?*const RendererDefinition {
        for (self.published.renderers) |*definition| if (std.mem.eql(u8, definition.kind, kind)) return definition;
        return null;
    }
    pub fn descriptor(self: Registry, id: PluginId) PluginDescriptor {
        for (self.descriptors) |item| if (item.plugin_id == id) return item;
        unreachable;
    }
    pub fn registration(self: Registry, id: PluginId) ?AdapterRegistration {
        for (self.registrations) |item| if (item.plugin_id == id) return item;
        return null;
    }
    pub fn availability(self: Registry, id: PluginId) Availability {
        return if (self.registration(id) != null) .available else .adapter_not_connected;
    }
    pub fn snapshot(self: Registry) []const BuiltinSnapshot {
        return self.legacy_snapshots;
    }
};
const builtin_snapshots = blk: {
    var snapshots: [builtin_descriptors.len]BuiltinSnapshot = undefined;
    for (builtin_descriptors, 0..) |descriptor, i| snapshots[i] = .{ .descriptor = descriptor, .availability = .adapter_not_connected, .ready_services = .{} };
    break :blk snapshots;
};
/// Collect immutable definitions, then validate the entire graph before publishing.
/// Nothing is externally visible if publish fails. No network or controller runs.
pub const PluginHost = struct {
    allocator: std.mem.Allocator,
    manifests_list: std.ArrayList(PluginManifest) = .empty,
    renderers: std.ArrayList(RendererDefinition) = .empty,
    apis: []const ApiDefinition = &.{.{ .id = "host", .major = host_api_version }},
    pub fn init(allocator: std.mem.Allocator) PluginHost {
        return .{ .allocator = allocator };
    }
    pub fn deinit(self: *PluginHost) void {
        self.manifests_list.deinit(self.allocator);
        self.renderers.deinit(self.allocator);
    }
    pub fn register(self: *PluginHost, manifest: PluginManifest) !void {
        try self.manifests_list.append(self.allocator, manifest);
    }
    pub fn registerRenderer(self: *PluginHost, definition: RendererDefinition) !void {
        try self.renderers.append(self.allocator, definition);
    }
    pub fn publish(self: *PluginHost) !Registry {
        const manifests = self.manifests_list.items;
        for (self.renderers.items, 0..) |renderer, i| {
            if (!validId(renderer.kind) or (renderer.mount == null and !renderer.shared_renderer)) return error.InvalidRenderer;
            for (self.renderers.items[0..i]) |earlier| if (std.mem.eql(u8, earlier.kind, renderer.kind)) return error.DuplicateRenderer;
        }
        const tool_api = @import("../ai/plugin_tools.zig");
        var definitions: std.ArrayList(tool_api.ToolDefinition) = .empty;
        defer definitions.deinit(self.allocator);
        for (manifests) |manifest| for (manifest.tool_definitions) |definition| {
            try tool_api.validateDefinition(definition);
            var shared = false;
            for (definitions.items) |earlier| if (std.mem.eql(u8, earlier.id, definition.id)) {
                if (!tool_api.sameDefinition(earlier, definition)) return error.ToolDefinitionConflict;
                shared = true;
                break;
            };
            if (!shared) try definitions.append(self.allocator, definition);
        };
        for (manifests, 0..) |manifest, i| {
            if (!validId(manifest.id) or manifest.display_name.len == 0 or manifest.plugin_version.len == 0) return error.InvalidDescriptor;
            if (manifest.host_api_version != host_api_version) return error.IncompatibleHostVersion;
            for (manifests[0..i]) |earlier| if (std.mem.eql(u8, earlier.id, manifest.id)) return error.DuplicatePlugin;
            if (manifest.session_factory == null) return error.MissingSessionFactory;
            if (manifest.icons.settings.len == 0 or manifest.icons.protocol.len == 0 or manifest.icons.tab.len == 0) return error.InvalidIcon;
            try tool_api.validateBindings(manifest.id, definitions.items, manifest.tools, manifest.services);
            if (manifest.settings_section) |section| for (section.fields, 0..) |field, n| {
                if (!validId(field.key) or field.label.len == 0) return error.InvalidPreference;
                for (section.fields[0..n]) |other| if (std.mem.eql(u8, field.key, other.key)) return error.DuplicatePreference;
                if (field.kind == .choice and field.options.len == 0) return error.InvalidPreference;
                for (field.options, 0..) |option, option_index| {
                    if (option.value.len == 0 or option.label.len == 0) return error.InvalidPreference;
                    for (field.options[0..option_index]) |other| if (std.mem.eql(u8, option.value, other.value)) return error.DuplicateChoice;
                }
            };
            for (manifest.notifications, 0..) |definition, n| {
                if (!validId(definition.id) or definition.version == 0) return error.InvalidNotificationDefinition;
                for (manifest.notifications[0..n]) |other| if (std.mem.eql(u8, other.id, definition.id)) return error.DuplicateNotificationDefinition;
                for (manifests[0..i]) |earlier| for (earlier.notifications) |other| {
                    if (std.mem.eql(u8, definition.id, other.id) and !std.meta.eql(definition, other)) return error.NotificationDefinitionConflict;
                };
            }

            var renderer_found = false;
            for (self.renderers.items) |renderer| if (std.mem.eql(u8, renderer.kind, manifest.content_renderer)) {
                if (renderer.supports_window_transfer and manifest.session_factory.?.vtable.rebind_context == null) return error.MissingContextRebinding;
                renderer_found = true;
                break;
            };
            if (!renderer_found or !std.mem.eql(u8, manifest.workspace_kind, manifest.content_renderer)) return error.MissingRenderer;
            for (manifest.services, 0..) |definition, n| {
                if (!validId(definition.key.name) or definition.key.major == 0) return error.InvalidService;
                var reserved = false;
                for (std.meta.tags(ServiceKind)) |kind| if (std.mem.eql(u8, definition.key.name, @tagName(kind))) {
                    reserved = true;
                    const expected = legacyServiceDefinition(kind);
                    if (definition.key.major != expected.key.major) return error.ServiceVersionMismatch;
                    if (definition.type_token != expected.type_token) return error.ServiceTypeMismatch;
                };
                if (!reserved and std.mem.indexOfScalar(u8, definition.key.name, '.') == null) return error.InvalidServiceNamespace;

                for (manifest.services[0..n]) |earlier| if (earlier.key.eql(definition.key)) return error.DuplicateService;
                for (manifests[0..i]) |earlier| for (earlier.services) |other| {
                    if (other.key.eql(definition.key) and other.type_token != definition.type_token) return error.ServiceTypeMismatch;
                };
            }
            for (manifest.required_services) |required| if (!manifest.supports(required)) return error.MissingRequiredService;
            if (manifest.connection) |connection| {
                if (connection.payload_version == 0) return error.InvalidPayloadVersion;
                if (connection.encode == null or connection.decode == null or connection.migrate == null) return error.MissingConnectionCodec;
                if (connection.editor_factory.mount == null and connection.editor_factory.shared_editor == null) return error.MissingConnectionEditor;
            }
            if (manifest.quick_create) |quick| {
                if (manifest.connection != null) return error.ConflictingCreateContributions;
                if (quick.payload_version == 0) return error.InvalidPayloadVersion;
                if (quick.action_id) |action_id| {
                    if (!validId(action_id) or quick.encode_creation_payload == null) return error.InvalidCreationAction;
                    for (manifests[0..i]) |other| if (other.quick_create) |earlier| if (earlier.action_id) |earlier_action| {
                        if (std.mem.eql(u8, action_id, earlier_action)) return error.DuplicateCreationAction;
                    };
                }
            }
            for (manifest.provides, 0..) |provided, n| {
                if (!validId(provided.id) or provided.major == 0) return error.InvalidDependency;
                for (manifest.provides[0..n]) |other| if (std.mem.eql(u8, provided.id, other.id)) return error.DuplicateApi;
                for (self.apis) |api| if (std.mem.eql(u8, provided.id, api.id)) return error.DuplicateApi;
                for (manifests[0..i]) |earlier| for (earlier.provides) |other| if (std.mem.eql(u8, provided.id, other.id)) return error.DuplicateApi;
            }
            for (manifest.dependencies) |dependency| {
                var found = false;
                for (self.apis) |api| if (std.mem.eql(u8, api.id, dependency.id)) {
                    if (api.major != dependency.major) return error.DependencyVersionMismatch;
                    found = true;
                };
                for (manifests) |provider| for (provider.provides) |api| if (std.mem.eql(u8, api.id, dependency.id)) {
                    if (api.major != dependency.major) return error.DependencyVersionMismatch;
                    found = true;
                };
                if (!found) return error.MissingDependency;
            }
        }
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        errdefer arena.deinit();
        const allocator = arena.allocator();
        const sorted = try allocator.alloc(PluginManifest, manifests.len);
        const visited = try allocator.alloc(bool, manifests.len);
        @memset(visited, false);
        for (sorted, 0..) |*destination, n| {
            var chosen: ?usize = null;
            for (manifests, 0..) |candidate, i| {
                if (visited[i]) continue;
                var ready = true;
                for (candidate.dependencies) |dependency| for (manifests, 0..) |provider, j| for (provider.provides) |api| {
                    if (std.mem.eql(u8, dependency.id, api.id) and !visited[j]) ready = false;
                };
                if (!ready) continue;
                if (chosen == null or less(candidate, manifests[chosen.?])) chosen = i;
            }
            const index = chosen orelse return error.DependencyCycle;
            visited[index] = true;
            destination.* = manifests[index];
            _ = n;
        }
        // Copy all metadata (including strings) so later mutation of collection
        // storage cannot change a published registry. Runtime contexts stay borrowed.
        const clone = @import("../ui/session_lifecycle.zig").cloneValue;
        const owned = try clone([]const PluginManifest, allocator, sorted);
        const renderer_defs = try clone([]const RendererDefinition, allocator, self.renderers.items);
        var descriptors: std.ArrayList(PluginDescriptor) = .empty;
        var registrations: std.ArrayList(AdapterRegistration) = .empty;
        var snapshots: std.ArrayList(BuiltinSnapshot) = .empty;
        for (owned) |manifest| if (manifest.legacy_descriptor) |descriptor| {
            try descriptors.append(allocator, descriptor);
            if (manifest.legacy_registration) |registration| try registrations.append(allocator, registration);
            try snapshots.append(allocator, .{ .descriptor = descriptor, .availability = .available, .ready_services = if (manifest.legacy_registration) |r| r.services else .{} });
        };
        return .{ .arena = arena, .published = .{ .entries = owned, .renderers = renderer_defs }, .descriptors = try descriptors.toOwnedSlice(allocator), .registrations = try registrations.toOwnedSlice(allocator), .legacy_snapshots = try snapshots.toOwnedSlice(allocator) };
    }
};
fn less(a: PluginManifest, b: PluginManifest) bool {
    return if (a.order != b.order) a.order < b.order else std.mem.order(u8, a.id, b.id) == .lt;
}
fn validId(value: []const u8) bool {
    if (value.len == 0 or value.len > 128) return false;
    for (value) |byte| if (!std.ascii.isAlphanumeric(byte) and byte != '_' and byte != '-' and byte != '.') return false;
    return true;
}
pub fn legacyId(id: PluginId) []const u8 {
    return @tagName(id);
}
pub fn requiredServices(id: PluginId) Services {
    return switch (id) {
        .local => Services.of(&.{ .lifecycle, .terminal, .process, .cwd, .exec }),
        .ssh => Services.of(&.{ .lifecycle, .terminal, .auth, .route, .exec }),
        .sftp => Services.of(&.{ .lifecycle, .auth, .route, .directory, .file_read, .transfer }),
        .external => .{},
    };
}

/// Actual legacy service interfaces, used by both manifest validation and the
/// engine compatibility API. Each interface has a distinct compile-time token.
pub fn legacyServiceDefinition(kind: ServiceKind) ServiceDefinition {
    const sessions = @import("session_host.zig");
    if (kind == .lifecycle) return ServiceDefinition.of(sessions.Adapter.VTable, .{ .name = "lifecycle" });
    inline for (comptime std.meta.tags(ServiceKind)) |candidate| if (kind == candidate) return ServiceDefinition.of(sessions.LegacyService(candidate), .{ .name = @tagName(candidate) });
    unreachable;
}
pub fn legacyServiceDefinitions(comptime kinds: []const ServiceKind) []const ServiceDefinition {
    const Static = struct {
        const definitions = blk: {
            var result: [kinds.len]ServiceDefinition = undefined;
            for (kinds, 0..) |kind, i| result[i] = legacyServiceDefinition(kind);
            break :blk result;
        };
    };
    return &Static.definitions;
}

const RegistryTestFactory = struct {
    var context: u8 = 0;
    fn create(_: *anyopaque, _: @import("session_host.zig").CreateRequest) !void {}
    fn cancel(_: *anyopaque, _: @import("operation.zig").OperationKey) @import("session_host.zig").CloseReceipt {
        return .released;
    }
    fn close(_: *anyopaque, _: @import("identity.zig").SessionHandle, _: @import("operation.zig").OperationKey) !@import("session_host.zig").CloseReceipt {
        return .released;
    }
    fn stale(_: *anyopaque, _: @import("identity.zig").SessionHandle, _: @import("operation.zig").OperationKey) void {}
    const vtable: @import("session_host.zig").Adapter.VTable = .{ .create = create, .cancel = cancel, .close = close, .release_stale = stale };
    fn manifest(id: []const u8) PluginManifest {
        return .{ .id = id, .display_name = id, .workspace_kind = "shared", .content_renderer = "shared", .session_factory = .{ .context = &context, .vtable = &vtable } };
    }
};

test "quick creation action conflicts reject the entire registry" {
    const Payload = struct {
        fn validate(_: []const u8) !void {}
        fn encode(allocator: std.mem.Allocator, argument: ?[]const u8) ![]u8 {
            return allocator.dupe(u8, argument orelse "");
        }
    };
    var collector = PluginHost.init(std.testing.allocator);
    defer collector.deinit();
    try collector.registerRenderer(.{ .kind = "shared", .shared_renderer = true });
    var first = RegistryTestFactory.manifest("native.one");
    first.quick_create = .{ .validate_payload = Payload.validate, .action_id = "native.create", .encode_creation_payload = Payload.encode };
    try collector.register(first);
    var second = RegistryTestFactory.manifest("native.two");
    second.quick_create = first.quick_create;
    try collector.register(second);
    try std.testing.expectError(error.DuplicateCreationAction, collector.publish());
}

test "a transferable renderer requires provider context rebinding before publication" {
    var collector = PluginHost.init(std.testing.allocator);
    defer collector.deinit();
    try collector.registerRenderer(.{ .kind = "shared", .shared_renderer = true, .supports_window_transfer = true });
    try collector.register(RegistryTestFactory.manifest("native.transfer"));
    try std.testing.expectError(error.MissingContextRebinding, collector.publish());
}

test "registration publishes arbitrary count in stable dependency order and owns metadata" {
    var host = PluginHost.init(std.testing.allocator);
    defer host.deinit();
    try host.registerRenderer(.{ .kind = "shared", .shared_renderer = true });
    var dependent = RegistryTestFactory.manifest("alpha");
    dependent.dependencies = &.{.{ .id = "fixture.api" }};
    var provider = RegistryTestFactory.manifest("zeta");
    provider.provides = &.{.{ .id = "fixture.api" }};
    try host.register(dependent);
    try host.register(RegistryTestFactory.manifest("delta"));
    try host.register(provider);
    try host.register(RegistryTestFactory.manifest("beta"));
    var registry = try host.publish();
    defer registry.deinit();
    try std.testing.expectEqual(@as(usize, 4), registry.manifests().len);
    try std.testing.expectEqualStrings("beta", registry.manifests()[0].id);
    try std.testing.expectEqualStrings("zeta", registry.manifests()[2].id);
    try std.testing.expectEqualStrings("alpha", registry.manifests()[3].id);
    host.manifests_list.items[0].id = "mutated";
    try std.testing.expect(registry.find("alpha") != null);
    try std.testing.expectEqual(@as(usize, 0), registry.snapshot().len);
}

test "registration refuses missing dependency cycle wrong type or incomplete executable atomically" {
    var host = PluginHost.init(std.testing.allocator);
    defer host.deinit();
    try host.registerRenderer(.{ .kind = "shared", .shared_renderer = true });
    var first = RegistryTestFactory.manifest("first");
    first.dependencies = &.{.{ .id = "missing" }};
    try host.register(first);
    try std.testing.expectError(error.MissingDependency, host.publish());
    host.manifests_list.items[0].dependencies = &.{};
    host.manifests_list.items[0].session_factory = null;
    try std.testing.expectError(error.MissingSessionFactory, host.publish());
    host.manifests_list.items[0] = RegistryTestFactory.manifest("first");
    host.manifests_list.items[0].provides = &.{.{ .id = "first.api" }};
    host.manifests_list.items[0].dependencies = &.{.{ .id = "second.api" }};
    var second = RegistryTestFactory.manifest("second");
    second.provides = &.{.{ .id = "second.api" }};
    second.dependencies = &.{.{ .id = "first.api" }};
    try host.register(second);
    try std.testing.expectError(error.DependencyCycle, host.publish());
    host.manifests_list.items[0].dependencies = &.{};
    host.manifests_list.items[1].dependencies = &.{};
    host.manifests_list.items[0].services = &.{typed.Definition.of(u8, .{ .name = "fixture.value" })};
    host.manifests_list.items[1].services = &.{typed.Definition.of(u32, .{ .name = "fixture.value" })};
    try std.testing.expectError(error.ServiceTypeMismatch, host.publish());
    host.manifests_list.items[1].services = &.{};
    host.manifests_list.items[0].required_services = &.{typed.Definition.of(u8, .{ .name = "fixture.value", .major = 2 })};
    try std.testing.expectError(error.MissingRequiredService, host.publish());
}
