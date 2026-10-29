//! API 2 tools: immutable request authority, generic JSON parameters and results.
const std = @import("std");
const scope = @import("tool_scope.zig");
const services = @import("../host/plugin_services.zig");
const identity = @import("../host/identity.zig");
const images = @import("image_attachments.zig");
pub const host = @import("host_tools.zig");

pub const max_plugin_tools = 8;
pub const max_plugin_request_tools = @import("provider.zig").max_plugin_tool_definitions;
pub const max_host_request_tools = @import("provider.zig").max_host_tool_definitions;
pub const max_request_tools = max_plugin_request_tools + max_host_request_tools;
pub const Effect = enum { read_state, observe_image, remote_input, resource_write };
pub const ApprovalPolicy = enum { read_only, confirm, always_confirm };
pub const ToolDefinition = struct {
    id: []const u8,
    version: u32 = 1,
    description: []const u8 = "",
    /// Supported JSON Schema subset is checked at registration; unknown keywords
    /// fail closed instead of being silently ignored during host validation.
    schema: []const u8,
    validate: ?*const fn (std.json.Value) anyerror!void = null,
    required_services: []const services.Requirement = &.{},
    effect: Effect = .read_state,
    approval_policy: ApprovalPolicy = .read_only,
    evaluate_policy: ?*const fn (std.json.Value, Policy, bool) anyerror!bool = null,
};
pub const Invocation = struct {
    owner: identity.SessionHandle,
    operation_id: u64,
    call_id: []const u8 = "",
    turn_id: u64 = 0,
    tool_id: []const u8,
    effect: Effect = .read_state,
    arguments: std.json.Value,
    arguments_json: []const u8,
    arguments_hash: [32]u8,
};
pub const ToolBinding = struct {
    plugin_id: []const u8,
    definition_id: []const u8,
    handler: *const fn (*anyopaque, Invocation, std.mem.Allocator) anyerror!ToolResult,
    execution: enum { controller, worker } = .controller,
    required_services: []const services.Requirement = &.{},
};
pub const Status = enum { succeeded, failed, rejected, cancelled_unsent, outcome_unknown };
pub const ContentBlock = union(enum) { text: []const u8, structured: []const u8, image_ref: images.ContentRef };
pub const Receipt = struct { operation_id: u64, owner: identity.SessionHandle, local_released: bool = true, remote_effect_unknown: bool = false };
pub const ToolResult = struct {
    status: Status,
    blocks: []const ContentBlock = &.{},
    receipt: Receipt,
    /// All handlers allocate blocks/text through the invocation allocator and
    /// return owned image references. Both result cards and providers retain the
    /// same immutable references; neither receives a filesystem path as pixels.
    pub fn deinit(self: *ToolResult, allocator: std.mem.Allocator) void {
        for (self.blocks) |block| switch (block) {
            .text, .structured => |bytes| allocator.free(bytes),
            .image_ref => |reference| {
                var owned = reference;
                owned.release();
            },
        };
        allocator.free(self.blocks);
        self.* = undefined;
    }
    pub fn validate(self: ToolResult, owner: identity.SessionHandle, operation_id: u64) !void {
        if (!self.receipt.owner.eql(owner) or self.receipt.operation_id != operation_id or self.blocks.len > 32) return error.InvalidToolResult;
        var text_bytes: usize = 0;
        var image_bytes: usize = 0;
        var image_count: usize = 0;
        for (self.blocks) |block| switch (block) {
            .text, .structured => |bytes| {
                if (!std.unicode.utf8ValidateSlice(bytes)) return error.InvalidToolResult;
                text_bytes = std.math.add(usize, text_bytes, bytes.len) catch return error.ToolResultTooLarge;
                if (text_bytes > 64 * 1024) return error.ToolResultTooLarge;
                if (block == .structured) {
                    const parsed = try std.json.parseFromSlice(std.json.Value, std.heap.page_allocator, bytes, .{});
                    parsed.deinit();
                }
            },
            .image_ref => |reference| {
                const content = reference.content() orelse return error.EmptyAttachmentResult;
                image_count += 1;
                image_bytes += content.bytes.len;
                if (image_count > images.max_count or image_bytes > images.max_bytes) return error.ToolResultTooLarge;
            },
        };
        if (self.status == .succeeded and (!self.receipt.local_released or self.receipt.remote_effect_unknown)) return error.InvalidToolResult;
    }
};

const legacy_names = [_][]const u8{ "run_command", "read_terminal", "list_remote_files", "read_remote_file" };
pub fn legacyName(id: []const u8) bool {
    for (legacy_names) |name| if (std.mem.eql(u8, id, name)) return true;
    return false;
}
/// '.' => '__', '_' => '_u'. Escaping underscores makes this reversible even
/// for IDs containing literal '__', unlike replacing only the separator.
pub fn encodeName(buffer: []u8, id: []const u8) ![]const u8 {
    if (id.len == 0 or id.len > 64 or id[0] == '.' or id[id.len - 1] == '.') return error.InvalidToolId;
    if (legacyName(id)) {
        if (buffer.len < id.len) return error.ToolNameTooLong;
        @memcpy(buffer[0..id.len], id);
        return buffer[0..id.len];
    }
    var len: usize = 0;
    var previous_dot = false;
    for (id) |byte| {
        if (!std.ascii.isAlphanumeric(byte) and byte != '_' and byte != '-' and byte != '.') return error.InvalidToolId;
        if (previous_dot and byte == '.') return error.InvalidToolId;
        previous_dot = byte == '.';
        const size: usize = if (byte == '.' or byte == '_') 2 else 1;
        if (len + size > @min(buffer.len, 64)) return error.ToolNameTooLong;
        if (byte == '.' or byte == '_') {
            buffer[len] = '_';
            buffer[len + 1] = if (byte == '.') '_' else 'u';
        } else buffer[len] = byte;
        len += size;
    }
    const name = buffer[0..len];
    if (legacyName(name)) return error.ToolNameCollision;
    return name;
}
pub fn decodeName(buffer: []u8, name: []const u8) ![]const u8 {
    if (legacyName(name)) {
        if (buffer.len < name.len) return error.ToolNameTooLong;
        @memcpy(buffer[0..name.len], name);
        return buffer[0..name.len];
    }
    var src: usize = 0;
    var dst: usize = 0;
    while (src < name.len) : (src += 1) {
        if (dst == buffer.len) return error.ToolNameTooLong;
        if (name[src] == '_') {
            src += 1;
            if (src == name.len) return error.InvalidToolName;
            buffer[dst] = switch (name[src]) {
                '_' => '.',
                'u' => '_',
                else => return error.InvalidToolName,
            };
        } else buffer[dst] = name[src];
        dst += 1;
    }
    var encoded: [64]u8 = undefined;
    if (!std.mem.eql(u8, try encodeName(&encoded, buffer[0..dst]), name)) return error.InvalidToolName;
    return buffer[0..dst];
}
pub fn validateDefinition(definition: ToolDefinition) !void {
    var name: [64]u8 = undefined;
    _ = try encodeName(&name, definition.id);
    if (definition.version == 0 or definition.description.len > 4096 or definition.schema.len > 32 * 1024) return error.InvalidToolDefinition;
    const parsed = try std.json.parseFromSlice(std.json.Value, std.heap.page_allocator, definition.schema, .{});
    defer parsed.deinit();
    try validateSchema(parsed.value, 0);
    const kind = parsed.value.object.get("type") orelse return error.InvalidToolSchema;
    if (kind != .string or !std.mem.eql(u8, kind.string, "object")) return error.InvalidToolSchema;
}
pub fn sameDefinition(a: ToolDefinition, b: ToolDefinition) bool {
    if (!std.mem.eql(u8, a.id, b.id) or a.version != b.version or !std.mem.eql(u8, a.schema, b.schema) or !std.mem.eql(u8, a.description, b.description) or a.effect != b.effect or a.approval_policy != b.approval_policy or a.evaluate_policy != b.evaluate_policy or a.validate != b.validate or a.required_services.len != b.required_services.len) return false;
    for (a.required_services, b.required_services) |left, right| if (!left.matches(right)) return false;
    return true;
}
pub fn validateBindings(plugin_id: []const u8, definitions: []const ToolDefinition, bindings: []const ToolBinding, declared: []const services.Definition) !void {
    if (bindings.len > max_plugin_tools) return error.TooManyPluginTools;
    for (bindings, 0..) |binding, index| {
        if (std.mem.startsWith(u8, binding.definition_id, "host.")) return error.ReservedToolNamespace;
        if (!std.mem.eql(u8, plugin_id, binding.plugin_id)) return error.ToolPluginMismatch;
        for (bindings[0..index]) |previous| if (std.mem.eql(u8, previous.definition_id, binding.definition_id)) return error.DuplicateToolBinding;
        const definition = findDefinition(definitions, binding.definition_id) orelse return error.UnknownToolDefinition;
        try validateDefinition(definition);
        for ([_][]const services.Requirement{ definition.required_services, binding.required_services }) |requirements| for (requirements) |requirement| {
            var found = false;
            for (declared) |service| if (service.matches(requirement)) {
                found = true;
                break;
            };
            if (!found) return error.ToolServiceUndeclared;
        };
    }
}
fn findDefinition(definitions: []const ToolDefinition, id: []const u8) ?ToolDefinition {
    for (definitions) |definition| if (std.mem.eql(u8, definition.id, id)) return definition;
    return null;
}

pub const Member = struct {
    owner: identity.SessionHandle,
    plugin_id: []const u8,
    context: *anyopaque,
    bindings: []const ToolBinding,
    services: []const services.Binding = &.{},
    capability_revision: u64 = 1,
    policy_revision: u64 = 1,
    authorized: bool = true,
};
pub const TargetBinding = struct { owner: identity.SessionHandle, binding: ToolBinding, context: *anyopaque, capability_revision: u64, policy_revision: u64, services: []const services.Binding };
pub const Entry = struct { definition: ToolDefinition, provider_name: []const u8, targets: []const TargetBinding, authority: @import("provider.zig").ToolAuthority = .session_targets };
pub const RequestTable = struct {
    arena: std.heap.ArenaAllocator,
    captured_scope: scope.Scope,
    entries: []const Entry,
    host_context: ?host.Context = null,
    pub fn init(allocator: std.mem.Allocator, captured_scope: scope.Scope, definitions: []const ToolDefinition, members: []const Member) !RequestTable {
        var arena = std.heap.ArenaAllocator.init(allocator);
        errdefer arena.deinit();
        const a = arena.allocator();
        for (definitions, 0..) |definition, index| {
            try validateDefinition(definition);
            for (definitions[0..index]) |previous| if (std.mem.eql(u8, previous.id, definition.id) and !sameDefinition(previous, definition)) return error.ToolDefinitionConflict;
        }
        var entries: std.ArrayList(Entry) = .empty;
        for (members, 0..) |member, member_index| {
            _ = try captured_scope.validate(&.{@backingInt(member.owner.session_id)});
            for (members[0..member_index]) |previous| if (previous.owner.session_id == member.owner.session_id) return error.DuplicateTarget;
            if (!member.authorized) continue;
            if (member.bindings.len > max_plugin_tools) return error.TooManyPluginTools;
            for (member.bindings, 0..) |binding, binding_index| {
                if (std.mem.startsWith(u8, binding.definition_id, "host.")) return error.ReservedToolNamespace;
                if (!std.mem.eql(u8, member.plugin_id, binding.plugin_id)) return error.ToolPluginMismatch;
                for (member.bindings[0..binding_index]) |previous| if (std.mem.eql(u8, previous.definition_id, binding.definition_id)) return error.DuplicateToolBinding;
                const definition = findDefinition(definitions, binding.definition_id) orelse return error.UnknownToolDefinition;
                try validateDefinition(definition);
                checkServices(definition, binding, member) catch |err| switch (err) {
                    error.RequiredServiceUnavailable, error.ServiceDenied => continue,
                    else => return err,
                };
                var found: ?usize = null;
                for (entries.items, 0..) |entry, i| if (std.mem.eql(u8, entry.definition.id, definition.id)) {
                    found = i;
                    break;
                };
                const index = found orelse blk: {
                    if (entries.items.len == max_plugin_request_tools) return error.TooManyRequestTools;
                    var encoded: [64]u8 = undefined;
                    const name = try encodeName(&encoded, definition.id);
                    const owned_definition = try copyDefinition(a, definition);
                    try entries.append(a, .{ .definition = owned_definition, .provider_name = try a.dupe(u8, name), .targets = &.{} });
                    break :blk entries.items.len - 1;
                };
                var entry = &entries.items[index];
                const targets = try a.alloc(TargetBinding, entry.targets.len + 1);
                @memcpy(targets[0..entry.targets.len], entry.targets);
                const copied_services = try a.dupe(services.Binding, member.services);
                for (copied_services) |*service| service.definition.key.name = try a.dupe(u8, service.definition.key.name);
                var copied_binding = binding;
                copied_binding.plugin_id = try a.dupe(u8, binding.plugin_id);
                copied_binding.definition_id = entry.definition.id;
                copied_binding.required_services = try copyRequirements(a, binding.required_services);
                targets[entry.targets.len] = .{ .owner = member.owner, .binding = copied_binding, .context = member.context, .capability_revision = member.capability_revision, .policy_revision = member.policy_revision, .services = copied_services };
                entry.targets = targets;
            }
        }
        return .{ .arena = arena, .captured_scope = try captured_scope.clone(a), .entries = try entries.toOwnedSlice(a) };
    }
    pub fn deinit(self: *RequestTable) void {
        self.arena.deinit();
        self.* = undefined;
    }
    pub fn initWithHost(allocator: std.mem.Allocator, captured_scope: scope.Scope, definitions: []const ToolDefinition, members: []const Member, context: host.Context, contributions: []const host.Contribution) !RequestTable {
        try context.validate();
        if (!context.binding.eql(captured_scope.owner)) return error.InvalidHostAuthority;
        if (contributions.len > max_host_request_tools) return error.ToolCatalogLimit;
        var table = try init(allocator, captured_scope, definitions, members);
        errdefer table.deinit();
        const a = table.arena.allocator();
        const entries = try a.alloc(Entry, table.entries.len + contributions.len);
        @memcpy(entries[0..table.entries.len], table.entries);
        for (contributions, table.entries.len..) |contribution, index| {
            const definition = contribution.definition;
            if (contribution.authority == .session_targets or !std.mem.startsWith(u8, definition.id, "host.") or definition.required_services.len != 0) return error.InvalidHostAuthority;
            try validateDefinition(definition);
            var encoded: [64]u8 = undefined;
            const name = try encodeName(&encoded, definition.id);
            for (entries[0..index]) |entry| if (std.mem.eql(u8, entry.provider_name, name)) return error.ToolDefinitionConflict;
            entries[index] = .{ .definition = try copyDefinition(a, definition), .provider_name = try a.dupe(u8, name), .targets = &.{}, .authority = contribution.authority };
        }
        table.entries = entries;
        table.host_context = context;
        _ = try @import("provider.zig").catalogTextBytes(try providerDefinitions(&table, a));
        return table;
    }
    pub fn lookup(self: *const RequestTable, provider_name: []const u8) ?*const Entry {
        for (self.entries) |*entry| if (std.mem.eql(u8, entry.provider_name, provider_name)) return entry;
        return null;
    }
    pub fn parse(self: *const RequestTable, allocator: std.mem.Allocator, name: []const u8, arguments: []const u8) !ParsedCall {
        const entry = self.lookup(name) orelse return error.ToolNotInRequest;
        if (arguments.len > 64 * 1024) return error.InvalidToolArguments;
        var parsed = try std.json.parseFromSlice(std.json.Value, allocator, arguments, .{ .allocate = .alloc_always });
        errdefer parsed.deinit();
        if (parsed.value != .object) return error.InvalidToolArguments;
        const schema = try std.json.parseFromSlice(std.json.Value, allocator, entry.definition.schema, .{});
        defer schema.deinit();
        try validateValue(schema.value, parsed.value, 0);
        if (entry.definition.validate) |validator| try validator(parsed.value);
        var hash: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(arguments, &hash, .{});
        if (entry.authority != .session_targets) {
            try (self.host_context orelse return error.InvalidHostAuthority).validate();
            return .{ .json = parsed, .entry = entry, .targets = .{}, .arguments_hash = hash, .canonical_arguments_hash = try @import("canonical_arguments.zig").digest(allocator, parsed.value) };
        }
        const ids = parsed.value.object.get("session_ids") orelse return error.InvalidToolArguments;
        if (ids != .array or ids.array.items.len == 0 or ids.array.items.len > scope.max_targets) return error.InvalidTargetCount;
        var targets: scope.Targets = .{};
        for (ids.array.items, 0..) |id, index| {
            if (id != .integer or id.integer <= 0) return error.InvalidToolArguments;
            targets.ids[index] = @intCast(id.integer);
            if (entryTarget(entry, targets.ids[index]) == null) return error.ToolCapabilityUnavailable;
        }
        targets.len = ids.array.items.len;
        _ = try self.captured_scope.validate(targets.slice());
        return .{ .json = parsed, .entry = entry, .targets = targets, .arguments_hash = hash };
    }
};
pub const ParsedCall = struct {
    json: std.json.Parsed(std.json.Value),
    entry: *const Entry,
    targets: scope.Targets,
    arguments_hash: [32]u8,
    canonical_arguments_hash: ?[32]u8 = null,
    pub fn deinit(self: *ParsedCall) void {
        self.json.deinit();
    }
};
fn copyRequirements(a: std.mem.Allocator, input: []const services.Requirement) ![]const services.Requirement {
    const output = try a.dupe(services.Requirement, input);
    for (output) |*requirement| requirement.key.name = try a.dupe(u8, requirement.key.name);
    return output;
}
fn copyDefinition(a: std.mem.Allocator, input: ToolDefinition) !ToolDefinition {
    var output = input;
    output.id = try a.dupe(u8, input.id);
    output.schema = try a.dupe(u8, input.schema);
    output.description = try a.dupe(u8, input.description);
    output.required_services = try copyRequirements(a, input.required_services);
    return output;
}
fn entryTarget(entry: *const Entry, session_id: u64) ?TargetBinding {
    for (entry.targets) |target| if (@backingInt(target.owner.session_id) == session_id) return target;
    return null;
}
fn checkServices(definition: ToolDefinition, binding: ToolBinding, member: Member) !void {
    for ([_][]const services.Requirement{ definition.required_services, binding.required_services }) |requirements| for (requirements) |requirement| {
        var found = false;
        for (member.services) |service| if (service.definition.matches(requirement)) {
            if (!service.owner.eql(member.owner) or service.generation != member.owner.generation) return error.StaleBinding;
            if (!service.authorized) return error.ServiceDenied;
            found = true;
            break;
        };
        if (!found) return error.RequiredServiceUnavailable;
    };
}

pub const Policy = struct { engine: @import("permission.zig").Engine = .{}, full_control: bool = false, allow_read: bool = true, allow_input: bool = true, allow_write: bool = true };
pub fn needsApproval(definition: ToolDefinition, policy: Policy) !bool {
    if (!policy.allow_read and (definition.effect == .read_state or definition.effect == .observe_image)) return error.ToolExecutionDenied;
    if (!policy.allow_input and definition.effect == .remote_input) return error.ToolExecutionDenied;
    if (!policy.allow_write and definition.effect == .resource_write) return error.ToolExecutionDenied;
    return switch (definition.approval_policy) {
        .always_confirm => true,
        .confirm => !policy.full_control,
        .read_only => false,
    };
}
pub fn callNeedsApproval(call: ParsedCall, policy: Policy, grouped: bool) !bool {
    const basic = try needsApproval(call.entry.definition, policy);
    if (call.entry.definition.approval_policy == .always_confirm) return true;
    if (call.entry.definition.evaluate_policy) |evaluate| return evaluate(call.json.value, policy, grouped);
    return basic;
}
pub const ApprovalTicket = struct {
    owner: scope.Owner,
    arguments_hash: [32]u8,
    tool_id_hash: u64,
    targets: [scope.max_targets]FrozenTarget = @splat(.{}),
    len: usize,
    expires_at_ms: i64,
    used: bool = false,
    approved: bool = false,
    const FrozenTarget = struct { owner: identity.SessionHandle = .{ .session_id = @fromBackingInt(0) }, capability_revision: u64 = 0, policy_revision: u64 = 0, service_revision_hash: u64 = 0 };
    pub fn create(table: *const RequestTable, call: ParsedCall, now_ms: i64, ttl_ms: u32) !ApprovalTicket {
        if (ttl_ms == 0 or ttl_ms > 300_000) return error.InvalidApprovalExpiry;
        var ticket: ApprovalTicket = .{ .owner = table.captured_scope.owner, .arguments_hash = call.arguments_hash, .tool_id_hash = std.hash.Wyhash.hash(0, call.entry.definition.id), .len = call.targets.len, .expires_at_ms = std.math.add(i64, now_ms, ttl_ms) catch return error.InvalidApprovalExpiry };
        for (call.targets.slice(), 0..) |id, index| {
            const target = entryTarget(call.entry, id).?;
            ticket.targets[index] = .{ .owner = target.owner, .capability_revision = target.capability_revision, .policy_revision = target.policy_revision, .service_revision_hash = serviceRevisionHash(target.services) };
        }
        return ticket;
    }
    pub fn approve(self: *ApprovalTicket) void {
        if (!self.used) self.approved = true;
    }
};
fn serviceRevisionHash(bindings: []const services.Binding) u64 {
    var hash = std.hash.Wyhash.init(0);
    for (bindings) |binding| {
        hash.update(binding.definition.key.name);
        hash.update(std.mem.asBytes(&binding.definition.key.major));
        hash.update(std.mem.asBytes(&binding.revision));
        hash.update(std.mem.asBytes(&binding.authorized));
        const token = @intFromPtr(binding.definition.type_token);
        const context = @intFromPtr(binding.context);
        const vtable = @intFromPtr(binding.vtable);
        const owner = @backingInt(binding.owner.session_id);
        hash.update(std.mem.asBytes(&token));
        hash.update(std.mem.asBytes(&context));
        hash.update(std.mem.asBytes(&vtable));
        hash.update(std.mem.asBytes(&owner));
        hash.update(std.mem.asBytes(&binding.owner.generation));
        hash.update(std.mem.asBytes(&binding.generation));
    }
    return hash.final();
}
/// Validate every group member before invoking any handler. Live services must
/// retain the exact captured type, owner and revisions, including read tools.
pub fn preflight(table: *const RequestTable, call: ParsedCall, live_scope: scope.Scope, members: []const Member) !void {
    if (!table.captured_scope.owner.eql(live_scope.owner)) return error.AssistantOwnerChanged;
    _ = try live_scope.validate(call.targets.slice());
    for (call.targets.slice()) |id| {
        const captured = entryTarget(call.entry, id).?;
        const member = for (members) |candidate| {
            if (@backingInt(candidate.owner.session_id) == id) break candidate;
        } else return error.ToolCapabilityUnavailable;
        if (!member.authorized) return error.ToolExecutionDenied;
        if (!captured.owner.eql(member.owner) or captured.capability_revision != member.capability_revision or captured.policy_revision != member.policy_revision) return error.StaleToolAuthority;
        const binding = for (member.bindings) |candidate| {
            if (std.mem.eql(u8, candidate.definition_id, call.entry.definition.id)) break candidate;
        } else return error.ToolCapabilityUnavailable;
        if (!std.mem.eql(u8, binding.plugin_id, captured.binding.plugin_id) or binding.handler != captured.binding.handler or member.context != captured.context) return error.StaleToolAuthority;
        try checkServices(call.entry.definition, binding, member);
        if (serviceRevisionHash(captured.services) != serviceRevisionHash(member.services)) return error.StaleToolAuthority;
    }
}
/// Consumes approval before crossing the effect boundary. Repeated approval,
/// changed parameters, expiry, reconnect and revocation all remain zero dispatch.
pub fn authorize(table: *const RequestTable, call: ParsedCall, live_scope: scope.Scope, members: []const Member, policy: Policy, ticket: ?*ApprovalTicket, now_ms: i64) !void {
    try preflight(table, call, live_scope, members);
    if (!try callNeedsApproval(call, policy, table.captured_scope.owner == .group)) return;
    const approved = ticket orelse return error.ToolApprovalRequired;
    if (approved.used) return error.ToolApprovalAlreadyUsed;
    if (!approved.approved) return error.ToolApprovalRequired;
    if (now_ms >= approved.expires_at_ms) return error.ToolApprovalExpired;
    if (!approved.owner.eql(table.captured_scope.owner) or !std.mem.eql(u8, &approved.arguments_hash, &call.arguments_hash) or approved.tool_id_hash != std.hash.Wyhash.hash(0, call.entry.definition.id) or approved.len != call.targets.len) return error.ToolApprovalChanged;
    for (call.targets.slice(), 0..) |id, index| {
        const target = entryTarget(call.entry, id).?;
        const frozen = approved.targets[index];
        if (!frozen.owner.eql(target.owner) or frozen.capability_revision != target.capability_revision or frozen.policy_revision != target.policy_revision or frozen.service_revision_hash != serviceRevisionHash(target.services)) return error.ToolApprovalChanged;
    }
    approved.used = true;
}

fn validateSchema(schema: std.json.Value, depth: usize) anyerror!void {
    if (depth > 12 or schema != .object) return error.InvalidToolSchema;
    const type_value = schema.object.get("type") orelse return error.InvalidToolSchema;
    if (type_value != .string) return error.InvalidToolSchema;
    const kinds = [_][]const u8{ "object", "array", "string", "integer", "number", "boolean", "null" };
    var supported = false;
    for (kinds) |kind| if (std.mem.eql(u8, type_value.string, kind)) {
        supported = true;
        break;
    };
    if (!supported) return error.InvalidToolSchema;
    const allowed = [_][]const u8{ "type", "properties", "required", "additionalProperties", "items", "minItems", "maxItems", "uniqueItems", "minLength", "maxLength", "minimum", "maximum", "enum", "description", "default", "title" };
    var fields = schema.object.iterator();
    while (fields.next()) |field| {
        var known = false;
        for (allowed) |key| if (std.mem.eql(u8, field.key_ptr.*, key)) {
            known = true;
            break;
        };
        if (!known) return error.UnsupportedToolSchema;
    }
    if (schema.object.get("properties")) |properties| {
        if (properties != .object) return error.InvalidToolSchema;
        var iterator = properties.object.iterator();
        while (iterator.next()) |property| try validateSchema(property.value_ptr.*, depth + 1);
    }
    if (schema.object.get("items")) |items| try validateSchema(items, depth + 1);
    if (schema.object.get("additionalProperties")) |additional| if (additional != .bool) return error.InvalidToolSchema;
    for ([_][]const u8{ "required", "enum" }) |key| if (schema.object.get(key)) |values| {
        if (values != .array) return error.InvalidToolSchema;
        if (std.mem.eql(u8, key, "required")) for (values.array.items) |value| {
            if (value != .string) return error.InvalidToolSchema;
        };
    };
    for ([_][]const u8{ "minItems", "maxItems", "minLength", "maxLength" }) |key| if (schema.object.get(key)) |value| if (value != .integer or value.integer < 0) return error.InvalidToolSchema;
    for ([_][]const u8{ "minimum", "maximum" }) |key| if (schema.object.get(key)) |value| if (value != .integer and value != .float) return error.InvalidToolSchema;
    if (schema.object.get("uniqueItems")) |value| if (value != .bool) return error.InvalidToolSchema;
}
fn number(value: std.json.Value) ?f64 {
    return switch (value) {
        .integer => |v| @floatFromInt(v),
        .float => |v| v,
        else => null,
    };
}
fn jsonEqual(a: std.json.Value, b: std.json.Value) bool {
    if (std.meta.activeTag(a) != std.meta.activeTag(b)) return if (number(a)) |left| if (number(b)) |right| left == right else false else false;
    return switch (a) {
        .null => true,
        .bool => |v| v == b.bool,
        .integer => |v| v == b.integer,
        .float => |v| v == b.float,
        .string => |v| std.mem.eql(u8, v, b.string),
        else => false,
    };
}
fn validateValue(schema: std.json.Value, value: std.json.Value, depth: usize) anyerror!void {
    if (depth > 12) return error.InvalidToolArguments;
    const kind = schema.object.get("type").?.string;
    const matches = if (std.mem.eql(u8, kind, "object")) value == .object else if (std.mem.eql(u8, kind, "array")) value == .array else if (std.mem.eql(u8, kind, "string")) value == .string else if (std.mem.eql(u8, kind, "integer")) value == .integer else if (std.mem.eql(u8, kind, "number")) number(value) != null else if (std.mem.eql(u8, kind, "boolean")) value == .bool else value == .null;
    if (!matches) return error.InvalidToolArguments;
    if (schema.object.get("enum")) |values| {
        var found = false;
        for (values.array.items) |candidate| if (jsonEqual(candidate, value)) {
            found = true;
            break;
        };
        if (!found) return error.InvalidToolArguments;
    }
    if (number(value)) |numeric| {
        if (schema.object.get("minimum")) |min| if (numeric < number(min).?) return error.InvalidToolArguments;
        if (schema.object.get("maximum")) |max| if (numeric > number(max).?) return error.InvalidToolArguments;
    }
    if (value == .string) {
        if (!std.unicode.utf8ValidateSlice(value.string) or std.mem.indexOfScalar(u8, value.string, 0) != null) return error.InvalidToolArguments;
        const length = std.unicode.utf8CountCodepoints(value.string) catch return error.InvalidToolArguments;
        if (schema.object.get("minLength")) |min| if (length < min.integer) return error.InvalidToolArguments;
        if (schema.object.get("maxLength")) |max| if (length > max.integer) return error.InvalidToolArguments;
    }
    if (value == .array) {
        if (schema.object.get("minItems")) |min| if (value.array.items.len < min.integer) return error.InvalidToolArguments;
        if (schema.object.get("maxItems")) |max| if (value.array.items.len > max.integer) return error.InvalidToolArguments;
        for (value.array.items, 0..) |item, index| {
            if (schema.object.get("items")) |item_schema| try validateValue(item_schema, item, depth + 1);
            if (schema.object.get("uniqueItems")) |unique| if (unique.bool) for (value.array.items[0..index]) |previous| if (jsonEqual(previous, item)) return error.InvalidToolArguments;
        }
    }
    if (value == .object) {
        if (schema.object.get("required")) |required| for (required.array.items) |key| if (value.object.get(key.string) == null) return error.InvalidToolArguments;
        const properties = schema.object.get("properties");
        var iterator = value.object.iterator();
        while (iterator.next()) |field| {
            if (properties) |all| if (all.object.get(field.key_ptr.*)) |field_schema| {
                try validateValue(field_schema, field.value_ptr.*, depth + 1);
                continue;
            };
            if (schema.object.get("additionalProperties")) |additional| if (!additional.bool) return error.InvalidToolArguments;
        }
    }
}

/// Generates wire definitions from the same captured table used for execution.
/// Target IDs and narrowed terminal-read schemas live in the caller allocator;
/// other definitions retain the captured table's lifetime.
pub fn providerDefinitions(table: *const RequestTable, allocator: std.mem.Allocator) ![]@import("provider.zig").ToolDefinition {
    const output = try allocator.alloc(@import("provider.zig").ToolDefinition, table.entries.len);
    for (table.entries, output) |entry, *definition| {
        const ids = try allocator.alloc(u64, entry.targets.len);
        for (entry.targets, ids) |target, *id| id.* = @backingInt(target.owner.session_id);
        definition.* = .{ .session_ids = ids, .authority = entry.authority, .dynamic = .{ .id = entry.definition.id, .name = entry.provider_name, .schema = try terminalReadSchema(allocator, entry, ids), .description = entry.definition.description } };
    }
    return output;
}

/// Expose the already captured read targets so an unambiguous current-terminal
/// read does not need a discovery round just to learn its ID. Dispatch still
/// validates the original schema, target binding, generation and live scope.
fn terminalReadSchema(allocator: std.mem.Allocator, entry: Entry, ids: []const u64) ![]const u8 {
    if (entry.authority != .session_targets or !std.mem.eql(u8, entry.definition.id, "read_terminal")) return entry.definition.schema;
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, entry.definition.schema, .{});
    defer parsed.deinit();
    var schema = parsed.value;
    const properties = schema.object.getPtr("properties") orelse return entry.definition.schema;
    const targets = properties.object.getPtr("session_ids") orelse return entry.definition.schema;
    const items = targets.object.getPtr("items") orelse return entry.definition.schema;
    // Do not replace a plugin's own enum or remove any declared constraints.
    if (items.object.contains("enum")) return entry.definition.schema;
    const a = parsed.arena.allocator();
    var allowed: std.array_list.Managed(std.json.Value) = .init(a);
    for (ids) |id| try allowed.append(if (std.math.cast(i64, id)) |value| .{ .integer = value } else .{ .number_string = try std.fmt.allocPrint(a, "{d}", .{id}) });
    try items.object.put(a, "enum", .{ .array = allowed });
    if (targets.object.getPtr("maxItems")) |maximum| if (maximum.* == .integer) {
        maximum.integer = @min(maximum.integer, @as(i64, @intCast(ids.len)));
    };
    return std.json.Stringify.valueAlloc(allocator, schema, .{});
}

pub fn cloneTable(input: *const RequestTable, allocator: std.mem.Allocator) !RequestTable {
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const a = arena.allocator();
    const entries = try a.dupe(Entry, input.entries);
    for (entries) |*entry| {
        entry.definition = try copyDefinition(a, entry.definition);
        entry.provider_name = try a.dupe(u8, entry.provider_name);
        const targets = try a.dupe(TargetBinding, entry.targets);
        for (targets) |*target| {
            target.binding.plugin_id = try a.dupe(u8, target.binding.plugin_id);
            target.binding.definition_id = entry.definition.id;
            target.binding.required_services = try copyRequirements(a, target.binding.required_services);
            const copied = try a.dupe(services.Binding, target.services);
            for (copied) |*service| service.definition.key.name = try a.dupe(u8, service.definition.key.name);
            target.services = copied;
        }
        entry.targets = targets;
    }
    return .{ .arena = arena, .captured_scope = try input.captured_scope.clone(a), .entries = entries, .host_context = input.host_context };
}

pub const DynamicInvocation = struct {
    table: *const RequestTable,
    parsed: ParsedCall,
    turn_id: u64,
    call_id: []const u8,
    arguments: []const u8,
    operation_id: u64,
};
/// Main-thread facade implementations may marshal this synchronous call onto
/// their owner thread. The worker never accesses a SessionHost or UI root.
pub const Runtime = struct {
    context: *anyopaque,
    live_scope: *const fn (*anyopaque) anyerror!scope.Scope,
    live_members: *const fn (*anyopaque) anyerror![]const Member,
    current_policy: *const fn (*anyopaque) Policy,
    now_ms: *const fn (*anyopaque) i64,
    /// Blocks only in the caller's worker, respects token and deadline. Returning
    /// true is a user decision; authorize still checks all frozen facts again.
    approval: ?*const fn (*anyopaque, DynamicInvocation, *ApprovalTicket, ?*@import("provider.zig").CancelToken) anyerror!bool = null,
    operations: *@import("../host/operation_store.zig").Store,
    invoke: ?*const fn (*anyopaque, TargetBinding, Invocation, std.mem.Allocator, ?*@import("provider.zig").CancelToken) anyerror!ToolResult = null,

    pub fn execute(self: Runtime, invocation: DynamicInvocation, allocator: std.mem.Allocator, cancel: ?*@import("provider.zig").CancelToken) ![]ToolResult {
        const parsed = invocation.parsed;
        if (parsed.entry.authority != .session_targets) return error.InvalidHostAuthority;
        if (self.operations.count() + parsed.targets.len > @import("../host/operation_store.zig").Store.capacity) return error.OperationHistoryFull;
        var ticket: ?ApprovalTicket = null;
        // No effects or approval prompts before complete group preflight.
        try preflight(invocation.table, parsed, try self.live_scope(self.context), try self.live_members(self.context));
        // Reserve all operation records before sending any group member.
        for (parsed.targets.slice()) |id| {
            const target = entryTarget(parsed.entry, id).?;
            const existing = self.operations.lookup(target.owner, invocation.operation_id);
            if (existing != null) return error.ToolOperationAlreadyRecorded;
        }
        var reserved: scope.Targets = .{};
        errdefer for (reserved.slice()) |id| {
            self.operations.cancel(entryTarget(parsed.entry, id).?.owner, invocation.operation_id) catch {};
        };
        for (parsed.targets.slice()) |id| {
            const target = entryTarget(parsed.entry, id).?;
            _ = try self.operations.beginNew(target.owner, invocation.operation_id, parsed.entry.definition.id, parsed.arguments_hash, target.policy_revision);
            reserved.ids[reserved.len] = id;
            reserved.len += 1;
        }
        if (try callNeedsApproval(parsed, self.current_policy(self.context), invocation.table.captured_scope.owner == .group)) {
            ticket = try ApprovalTicket.create(invocation.table, parsed, self.now_ms(self.context), 60_000);
            for (parsed.targets.slice()) |id| {
                const owner = entryTarget(parsed.entry, id).?.owner;
                try self.operations.transition(owner, invocation.operation_id, .pending_approval, "");
            }
            const ask = self.approval orelse return error.ToolApprovalRequired;
            if (!try ask(self.context, invocation, &ticket.?, cancel)) {
                for (parsed.targets.slice()) |id| {
                    const owner = entryTarget(parsed.entry, id).?.owner;
                    try self.operations.transition(owner, invocation.operation_id, .rejected, "rejected");
                }
                return error.ToolApprovalRejected;
            }
            ticket.?.approve();
        }
        if (cancel) |token| if (token.isCancelled()) return error.CancelledBeforeDispatch;
        try authorize(invocation.table, parsed, try self.live_scope(self.context), try self.live_members(self.context), self.current_policy(self.context), if (ticket) |*value| value else null, self.now_ms(self.context));
        if (ticket != null) for (parsed.targets.slice()) |id| {
            const owner = entryTarget(parsed.entry, id).?.owner;
            try self.operations.transition(owner, invocation.operation_id, .approved, "");
        };
        const output = try allocator.alloc(ToolResult, parsed.targets.len);
        var initialized: usize = 0;
        errdefer {
            for (output[0..initialized]) |*result| result.deinit(allocator);
            allocator.free(output);
        }
        var uncertain = false;
        for (parsed.targets.slice(), output) |id, *result| {
            const target = entryTarget(parsed.entry, id).?;
            const cancelled = if (cancel) |token| token.isCancelled() else false;
            if (cancelled or uncertain) {
                try self.operations.cancel(target.owner, invocation.operation_id);
                result.* = .{ .status = .cancelled_unsent, .receipt = .{ .owner = target.owner, .operation_id = invocation.operation_id } };
                initialized += 1;
                continue;
            }
            // Revalidate just before each send; earlier callbacks can revoke a
            // later member, but can never redirect it to another connection.
            preflight(invocation.table, parsed, try self.live_scope(self.context), try self.live_members(self.context)) catch {
                try self.operations.cancel(target.owner, invocation.operation_id);
                result.* = .{ .status = .cancelled_unsent, .receipt = .{ .owner = target.owner, .operation_id = invocation.operation_id } };
                initialized += 1;
                continue;
            };
            if (self.invoke == null) try markSent(self.operations, target.owner, invocation.operation_id, invocation.call_id, parsed.entry.definition.id, parsed.arguments_hash);
            const request: Invocation = .{ .owner = target.owner, .operation_id = invocation.operation_id, .call_id = invocation.call_id, .turn_id = invocation.turn_id, .tool_id = parsed.entry.definition.id, .effect = parsed.entry.definition.effect, .arguments = parsed.json.value, .arguments_json = invocation.arguments, .arguments_hash = parsed.arguments_hash };
            result.* = (if (self.invoke) |invoke| invoke(self.context, target, request, allocator, cancel) else target.binding.handler(target.context, request, allocator)) catch {
                const stage = self.operations.lookup(target.owner, invocation.operation_id).?.stage;
                const was_sent = stage == .sent or stage == .verifying or stage == .outcome_unknown;
                try self.operations.cancel(target.owner, invocation.operation_id);
                uncertain = was_sent;
                result.* = .{ .status = if (was_sent) .outcome_unknown else .cancelled_unsent, .receipt = .{ .owner = target.owner, .operation_id = invocation.operation_id, .remote_effect_unknown = was_sent } };
                initialized += 1;
                if (result.receipt.local_released) try self.operations.resourcesReleased(target.owner, invocation.operation_id);
                @import("tool_trace.zig").emit(.{ .event = "dynamic_result", .call_id = invocation.call_id, .tool_id = parsed.entry.definition.id, .owner = target.owner, .operation_id = invocation.operation_id, .status = result.status, .local_released = result.receipt.local_released, .remote_effect_unknown = result.receipt.remote_effect_unknown });
                continue;
            };
            initialized += 1;
            result.validate(target.owner, invocation.operation_id) catch |err| {
                try self.operations.cancel(target.owner, invocation.operation_id);
                return err;
            };
            const historical_unknown = self.operations.lookup(target.owner, invocation.operation_id).?.stage == .outcome_unknown;
            if ((if (cancel) |token| token.isCancelled() else false) or historical_unknown or result.status == .outcome_unknown or result.receipt.remote_effect_unknown or !result.receipt.local_released) {
                result.status = .outcome_unknown;
                result.receipt.remote_effect_unknown = true;
                try self.operations.cancel(target.owner, invocation.operation_id);
                uncertain = true;
            } else try self.operations.finish(target.owner, invocation.operation_id, result.status == .succeeded, @tagName(result.status));
            if (result.receipt.local_released) try self.operations.resourcesReleased(target.owner, invocation.operation_id);
            @import("tool_trace.zig").emit(.{ .event = "dynamic_result", .call_id = invocation.call_id, .tool_id = parsed.entry.definition.id, .owner = target.owner, .operation_id = invocation.operation_id, .status = result.status, .local_released = result.receipt.local_released, .remote_effect_unknown = result.receipt.remote_effect_unknown });
        }
        return output;
    }
};

test {
    _ = @import("plugin_tools_tests.zig");
}

pub fn markSent(store: *@import("../host/operation_store.zig").Store, owner: identity.SessionHandle, operation_id: u64, call_id: []const u8, tool_id: []const u8, arguments_hash: [32]u8) !void {
    try store.markSent(owner, operation_id);
    @import("tool_trace.zig").emit(.{ .event = "dynamic_dispatch", .call_id = call_id, .tool_id = tool_id, .owner = owner, .operation_id = operation_id, .arguments_hash = std.fmt.bytesToHex(arguments_hash, .lower) });
}

test {
    _ = @import("plugin_gateway_live_tests.zig");
}
