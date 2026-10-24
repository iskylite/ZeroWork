//! Static composition root. Provider IDs and legacy configuration knowledge
//! are confined to this adapter boundary, never to generic session dispatch.
const std = @import("std");
const plugins = @import("../host/plugin_registry.zig");
const sessions = @import("../host/session_host.zig");
const typed = plugins.typed;
pub const lifecycle_definition = typed.Definition.of(sessions.Adapter.VTable, .{ .name = "lifecycle" });
pub const shared_renderers = [_]plugins.RendererDefinition{
    .{ .kind = "terminal", .shared_renderer = true },
    .{ .kind = "file", .shared_renderer = true },
};
const ai = @import("../ai/legacy_adapter.zig");
fn bindings(comptime plugin_id: []const u8, comptime names: []const []const u8) []const @import("../ai/plugin_tools.zig").ToolBinding {
    const Static = struct {
        const value = blk: {
            var result = ai.builtinBindings(plugin_id, names);
            for (&result) |*binding| {
                const kind: plugins.ServiceKind = if (std.mem.eql(u8, binding.definition_id, "run_command")) .exec else if (std.mem.eql(u8, binding.definition_id, "read_terminal")) .terminal else if (std.mem.eql(u8, binding.definition_id, "list_remote_files")) .directory else .file_read;
                binding.required_services = switch (kind) {
                    .exec => plugins.legacyServiceDefinitions(&.{.exec}),
                    .terminal => plugins.legacyServiceDefinitions(&.{.terminal}),
                    .directory => plugins.legacyServiceDefinitions(&.{.directory}),
                    .file_read => plugins.legacyServiceDefinitions(&.{.file_read}),
                    else => unreachable,
                };
            }
            break :blk result;
        };
    };
    return &Static.value;
}
const envelopes = @import("../config/connection_envelope.zig");
fn RemoteCodec(comptime protocol: []const u8) type {
    return struct {
        fn validate(payload: []const u8) !void {
            var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
            defer arena.deinit();
            const host = try envelopes.decodeLegacy(arena.allocator(), .{ .protocol_id = protocol, .name = "validation", .payload = payload });
            try host.validate();
        }
        fn codec(allocator: std.mem.Allocator, envelope: envelopes.Envelope) !envelopes.Envelope {
            if (!std.mem.eql(u8, envelope.protocol_id, protocol)) return error.ProtocolMismatch;
            try validate(envelope.payload);
            return envelope.clone(allocator);
        }
        fn migrate(allocator: std.mem.Allocator, envelope: envelopes.Envelope, target_version: u32) !envelopes.Envelope {
            if (target_version != 1) return error.UnsupportedPayloadVersion;
            return envelopes.migrate(allocator, envelope);
        }
    };
}

pub fn registerAll(host: *plugins.PluginHost, adapters: []const sessions.Adapter) !void {
    for (shared_renderers) |renderer| try host.registerRenderer(renderer);
    for (adapters) |adapter| {
        const registration = adapter.registration;
        if (registration.plugin_id == .external) return error.InvalidLegacyAdapter;
        const descriptor = plugins.builtin_descriptors[@backingInt(registration.plugin_id)];
        if (registration.host_api_version != plugins.host_api_version) return error.IncompatibleHostVersion;
        if (registration.workspace_kind != descriptor.workspace_kind) return error.IncompatibleWorkspace;
        if (!registration.services.contains(plugins.requiredServices(registration.plugin_id))) return error.MissingRequiredService;
        if (!descriptor.services.contains(registration.services)) return error.UndeclaredService;
        try host.register(.{
            .id = plugins.legacyId(descriptor.plugin_id),
            .display_name = descriptor.display_name,
            .origin = .builtin,
            .order = @intCast(@backingInt(descriptor.plugin_id)),
            .icons = switch (descriptor.plugin_id) {
                .local => .{ .settings = "terminal", .protocol = "terminal", .tab = "local_apple", .archive = "local_apple" },
                .ssh => .{ .settings = "server", .protocol = "terminal", .tab = "terminal" },
                .sftp => .{ .settings = "folder", .protocol = "folder_open", .tab = "folder" },
                .external => unreachable,
            },
            .quick_create = if (descriptor.plugin_id == .local) .{ .validate_payload = @import("local/provider.zig").validateQuick, .new_session_payload = @import("local/provider.zig").newSessionPayload, .action_id = "session.local.create", .encode_creation_payload = @import("local/provider.zig").encodeCreationPayload } else null,
            .connection = switch (descriptor.create_kind) {
                .local => null,
                .saved => .{ .create_kind = .saved, .editor_factory = .{ .mount = @import("remote/editor_factory.zig").mount }, .validate_payload = RemoteCodec("sftp").validate, .encode = RemoteCodec("sftp").codec, .decode = RemoteCodec("sftp").codec, .migrate = RemoteCodec("sftp").migrate },
                .saved_or_temporary => .{ .create_kind = .saved_or_temporary, .editor_factory = .{ .mount = @import("remote/editor_factory.zig").mount }, .validate_payload = RemoteCodec("ssh").validate, .encode = RemoteCodec("ssh").codec, .decode = RemoteCodec("ssh").codec, .migrate = RemoteCodec("ssh").migrate },
            },
            .session_factory = .{ .context = adapter.context, .vtable = adapter.vtable },
            .workspace_kind = @tagName(descriptor.workspace_kind),
            .content_renderer = @tagName(descriptor.workspace_kind),
            .services = switch (descriptor.plugin_id) {
                .local => plugins.legacyServiceDefinitions(&.{ .lifecycle, .terminal, .process, .cwd, .exec }),
                .ssh => plugins.legacyServiceDefinitions(&.{ .lifecycle, .terminal, .process, .cwd, .auth, .route, .directory, .file_read, .exec, .forward, .transfer }),
                .sftp => plugins.legacyServiceDefinitions(&.{ .lifecycle, .auth, .route, .directory, .file_read, .transfer }),
                .external => unreachable,
            },
            .required_services = switch (descriptor.plugin_id) {
                .local => plugins.legacyServiceDefinitions(&.{ .lifecycle, .terminal, .process, .cwd, .exec }),
                .ssh => plugins.legacyServiceDefinitions(&.{ .lifecycle, .terminal, .auth, .route, .exec }),
                .sftp => plugins.legacyServiceDefinitions(&.{ .lifecycle, .auth, .route, .directory, .file_read, .transfer }),
                .external => unreachable,
            },
            .tool_definitions = &ai.builtin_definitions,
            .tools = switch (descriptor.plugin_id) {
                .local => bindings("local", &.{ "run_command", "read_terminal" }),
                .ssh => bindings("ssh", &.{ "run_command", "read_terminal", "list_remote_files", "read_remote_file" }),
                .sftp => bindings("sftp", &.{ "list_remote_files", "read_remote_file" }),
                .external => unreachable,
            },
            .ai_adapter_factory = switch (descriptor.plugin_id) {
                .local => @import("../ui/ai_local_tools.zig").createAdapter,
                .ssh => @import("../ui/ai_ssh_tools.zig").createAdapter,
                .sftp => @import("../ui/ai_file_tools.zig").createAdapter,
                .external => unreachable,
            },
            .ai_context = .{ .identity = descriptor.display_name },
            .integration = switch (descriptor.plugin_id) {
                .local => .{ .ai = true },
                .ssh => .{ .retry_after_end = true, .transport_loss = true, .auxiliary_readonly = true, .auxiliary_transfer = true, .ai = true },
                .sftp => .{ .directory_recovery = true, .ai = true },
                .external => unreachable,
            },
            .legacy_descriptor = descriptor,
            .legacy_registration = registration,
        });
    }
}
pub fn initRegistry(allocator: std.mem.Allocator, adapters: []const sessions.Adapter, extra_manifests: []const plugins.PluginManifest, extra_renderers: []const plugins.RendererDefinition) !plugins.Registry {
    var host = plugins.PluginHost.init(allocator);
    defer host.deinit();
    try registerAll(&host, adapters);
    for (extra_renderers) |renderer| try host.registerRenderer(renderer);
    for (extra_manifests) |manifest| try host.register(manifest);
    return host.publish();
}

/// Executable builtin bindings are assembled here, outside Domain/App dispatch.
pub fn applicationAdapters(comptime Domain: type, comptime WindowAttachment: type, domain: *Domain, local: *@import("../host/process_service.zig").Service) [3]sessions.Adapter {
    const Static = struct {
        const ssh_binding = Domain.windowFactory(@import("ssh/application_binding.zig").Binding(WindowAttachment).vtable);
        const local_binding = Domain.windowFactory(@import("local/application_binding.zig").Binding(WindowAttachment).vtable);
        const file_binding = Domain.windowFactory(@import("sftp/application_binding.zig").Binding(WindowAttachment).vtable);
    };
    return .{
        .{ .registration = .{ .plugin_id = .ssh, .workspace_kind = .terminal, .services = sshServices() }, .context = domain, .vtable = &Static.ssh_binding },
        .{ .registration = local.adapter().registration, .context = domain, .vtable = &Static.local_binding },
        .{ .registration = .{ .plugin_id = .sftp, .workspace_kind = .file, .services = plugins.requiredServices(.sftp) }, .context = domain, .vtable = &Static.file_binding },
    };
}
pub fn sshServices() plugins.Services {
    var value = plugins.requiredServices(.ssh);
    value.bits |= plugins.Services.of(&.{.forward}).bits;
    return value;
}

pub fn createProcess(allocator: std.mem.Allocator) !*@import("../host/process_service.zig").Service {
    return @import("local/provider.zig").create(allocator);
}
