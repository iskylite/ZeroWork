//! Bounded Redfish discovery and schema readers. Every URI is checked before it
//! reaches the transport; no collection member is selected as a write target by
//! position. Parsed response fields borrow their Document.
const std = @import("std");
const svc = @import("../services.zig");
const model = @import("../model.zig");
pub const max_body_bytes = 4 * 1024 * 1024;
pub const max_resources = 1024;
pub const max_collection_members = 256;
pub const Origin = struct {
    authority: []const u8,
    pub fn init(a: std.mem.Allocator, endpoint: model.Endpoint) !Origin {
        try model.validate(.{ .endpoint = endpoint, .username = "validation" });
        var host = endpoint.host;
        if (host[0] == '[') host = host[1 .. host.len - 1];
        host = std.mem.trimEnd(u8, host, ".");
        const lower = try a.dupe(u8, host);
        defer a.free(lower);
        for (lower) |*byte| byte.* = std.ascii.toLower(byte.*);
        const authority = if (std.mem.indexOfScalar(u8, lower, ':') != null)
            try std.fmt.allocPrint(a, "[{s}]:{d}", .{ lower, endpoint.https_port })
        else
            try std.fmt.allocPrint(a, "{s}:{d}", .{ lower, endpoint.https_port });
        return .{ .authority = authority };
    }
};

/// Returns a same-origin HTTP resource target. Encoded path bytes, dot segments,
/// fragments, userinfo, backslashes and protocol-relative links are rejected.
pub fn resourceUri(a: std.mem.Allocator, origin: Origin, resource_link: []const u8) ![]const u8 {
    if (resource_link.len == 0 or resource_link.len > 4096 or std.mem.indexOfAny(u8, resource_link, "\x00 \t\r\n\\#%") != null) return error.InvalidResourceUri;
    for (resource_link) |byte| if (byte <= 0x20 or byte >= 0x7f) return error.InvalidResourceUri;
    var path = resource_link;
    if (std.mem.startsWith(u8, resource_link, "https://")) {
        const authority_end = std.mem.indexOfScalarPos(u8, resource_link, 8, '/') orelse return error.InvalidResourceUri;
        const authority = resource_link[8..authority_end];
        if (std.mem.indexOfScalar(u8, authority, '@') != null) return error.CrossOriginResource;
        if (!std.ascii.eqlIgnoreCase(authority, origin.authority)) {
            if (!std.mem.endsWith(u8, origin.authority, ":443") or !std.ascii.eqlIgnoreCase(authority, origin.authority[0 .. origin.authority.len - 4])) return error.CrossOriginResource;
        }
        path = resource_link[authority_end..];
    }
    if (!std.mem.startsWith(u8, path, "/redfish/v1") or (path.len > 11 and path[11] != '/' and path[11] != '?') or std.mem.indexOf(u8, path, "//") != null) return error.InvalidResourceUri;
    const query = std.mem.indexOfScalar(u8, path, '?') orelse path.len;
    var segments = std.mem.splitScalar(u8, path[0..query], '/');
    while (segments.next()) |part| if (std.mem.eql(u8, part, ".") or std.mem.eql(u8, part, "..")) return error.InvalidResourceUri;
    if (query < path.len) for (path[query + 1 ..]) |byte| {
        if (!(std.ascii.isAlphanumeric(byte) or std.mem.indexOfScalar(u8, "-._~!$&'()*+,;=:@/?", byte) != null)) return error.InvalidResourceUri;
    };
    return a.dupe(u8, path);
}
pub fn canonicalTarget(a: std.mem.Allocator, origin: Origin, resource_link: []const u8) ![]const u8 {
    const path = try resourceUri(a, origin, resource_link);
    defer a.free(path);
    if (std.mem.indexOfScalar(u8, path, '?') != null) return error.InvalidResourceUri;
    return std.fmt.allocPrint(a, "https://{s}{s}", .{ origin.authority, path });
}
pub const Document = struct {
    arena: std.heap.ArenaAllocator,
    value: std.json.Value,
    uri: []const u8,
    etag: ?[]const u8,
    status: u16,
    collected_ms: u64,
    validity: svc.Validity,
    pub fn parse(a: std.mem.Allocator, uri: []const u8, status: u16, body: []const u8, etag: ?[]const u8, now_ms: u64) !Document {
        if (body.len > max_body_bytes) return error.ResponseTooLarge;
        var arena: std.heap.ArenaAllocator = .init(a);
        errdefer arena.deinit();
        const parsed = try std.json.parseFromSlice(std.json.Value, arena.allocator(), if (body.len == 0) "{}" else body, .{ .allocate = .alloc_always, .max_value_len = max_body_bytes });
        if (parsed.value != .object) return error.InvalidRedfishResponse;
        const owned_uri = try arena.allocator().dupe(u8, uri);
        const owned_etag = if (etag) |tag| try arena.allocator().dupe(u8, tag) else null;
        return .{ .arena = arena, .value = parsed.value, .uri = owned_uri, .etag = owned_etag, .status = status, .collected_ms = now_ms, .validity = if (status < 200 or status >= 300) .unavailable else if (hasBodyError(parsed.value)) .partial_with_error else .valid };
    }
    pub fn deinit(self: *Document) void {
        wipeValue(self.value);
        std.crypto.secureZero(u8, @constCast(self.uri));
        if (self.etag) |tag| std.crypto.secureZero(u8, @constCast(tag));
        self.arena.deinit();
        self.* = undefined;
    }
    pub fn evidence(self: Document, present: bool) svc.Evidence {
        return .{ .source_uri = self.uri, .collected_ms = self.collected_ms, .validity = if (present) self.validity else .unavailable };
    }
    pub fn accepted(self: Document) bool {
        return self.status >= 200 and self.status < 300 and !hasBodyError(self.value);
    }
};
fn wipeValue(value: std.json.Value) void {
    switch (value) {
        .string, .number_string => |bytes| std.crypto.secureZero(u8, @constCast(bytes)),
        .object => |object| {
            var it = object.iterator();
            while (it.next()) |entry| {
                std.crypto.secureZero(u8, @constCast(entry.key_ptr.*));
                wipeValue(entry.value_ptr.*);
            }
        },
        .array => |array| for (array.items) |item| wipeValue(item),
        else => {},
    }
}
pub fn member(value: std.json.Value, key: []const u8) ?std.json.Value {
    return if (value == .object) value.object.get(key) else null;
}
pub fn text(value: std.json.Value, key: []const u8) ?[]const u8 {
    const field = member(value, key) orelse return null;
    return if (field == .string) field.string else null;
}
pub fn link(value: std.json.Value, key: []const u8) ?[]const u8 {
    const field = member(value, key) orelse return null;
    return text(field, "@odata.id");
}
pub fn hasBodyError(value: std.json.Value) bool {
    if (member(value, "error") != null) return true;
    return failedInfo(value, 0);
}
fn failedInfo(value: std.json.Value, depth: usize) bool {
    if (depth > 32) return true;
    switch (value) {
        .object => |object| {
            if (text(value, "MessageSeverity") orelse text(value, "Severity")) |severity| if (std.ascii.eqlIgnoreCase(severity, "Critical") or std.ascii.eqlIgnoreCase(severity, "Warning") or std.ascii.eqlIgnoreCase(severity, "Fatal")) return true;
            var it = object.iterator();
            while (it.next()) |entry| if (failedInfo(entry.value_ptr.*, depth + 1)) return true;
        },
        .array => |array| for (array.items) |item| {
            if (failedInfo(item, depth + 1)) return true;
        },
        else => {},
    }
    return false;
}
fn stringList(a: std.mem.Allocator, value: ?std.json.Value) !?[]const []const u8 {
    const array = value orelse return null;
    if (array != .array or array.array.items.len > max_collection_members) return null;
    const result = try a.alloc([]const u8, array.array.items.len);
    for (array.array.items, 0..) |item, i| {
        if (item != .string or item.string.len > 4096) return null;
        result[i] = item.string;
    }
    return result;
}
pub const Root = struct { systems: []const u8, managers: []const u8, sessions: []const u8 };
pub fn parseRoot(a: std.mem.Allocator, origin: Origin, doc: Document) !Root {
    if (!doc.accepted()) return error.InvalidServiceRoot;
    const systems = try resourceUri(a, origin, link(doc.value, "Systems") orelse return error.MissingSystems);
    const managers = try resourceUri(a, origin, link(doc.value, "Managers") orelse return error.MissingManagers);
    const sessions = try resourceUri(a, origin, link(doc.value, "SessionService") orelse return error.MissingSessionService);
    return .{ .systems = systems, .managers = managers, .sessions = sessions };
}
pub const Collection = struct { members: []const []const u8, next: ?[]const u8 };
pub fn parseCollection(a: std.mem.Allocator, origin: Origin, doc: Document) !Collection {
    const array = member(doc.value, "Members") orelse return error.MissingMembers;
    if (array != .array or array.array.items.len > max_collection_members) return error.CollectionTooLarge;
    const result = try a.alloc([]const u8, array.array.items.len);
    for (array.array.items, 0..) |item, i| result[i] = try resourceUri(a, origin, text(item, "@odata.id") orelse return error.InvalidMember);
    return .{ .members = result, .next = if (text(doc.value, "Members@odata.nextLink") orelse text(doc.value, "@odata.nextLink")) |next| try resourceUri(a, origin, next) else null };
}
pub const ParsedSystem = struct { power: svc.PowerSnapshot, boot: svc.BootSnapshot, action_info: ?[]const u8 = null, boot_options: ?[]const u8 = null, managed_by: []const []const u8 = &.{} };
pub fn parseSystem(a: std.mem.Allocator, origin: Origin, doc: Document) !ParsedSystem {
    var result: ParsedSystem = .{ .power = .{ .system_uri = doc.uri, .system_identity = text(doc.value, "UUID") orelse text(doc.value, "Id") orelse "", .etag = doc.etag }, .boot = .{ .system_uri = doc.uri, .system_identity = text(doc.value, "UUID") orelse text(doc.value, "Id") orelse "", .etag = doc.etag } };
    if (text(doc.value, "PowerState")) |state| result.power.state = .{ .value = if (std.mem.eql(u8, state, "On")) .on else if (std.mem.eql(u8, state, "Off")) .off else if (std.mem.eql(u8, state, "PoweringOn")) .powering_on else if (std.mem.eql(u8, state, "PoweringOff")) .powering_off else .unknown, .evidence = doc.evidence(true) };
    if (member(doc.value, "Actions")) |actions| if (member(actions, "#ComputerSystem.Reset")) |reset| {
        if (text(reset, "target")) |target| result.power.reset_target = try resourceUri(a, origin, target);
        const values = try stringList(a, member(reset, "ResetType@Redfish.AllowableValues"));
        result.power.reset_types = .{ .value = values, .evidence = doc.evidence(values != null) };
        if (text(reset, "@Redfish.ActionInfo")) |info| result.action_info = try resourceUri(a, origin, info);
    };
    if (member(doc.value, "Boot")) |boot| {
        result.boot.state = .{ .enabled = text(boot, "BootSourceOverrideEnabled"), .target = text(boot, "BootSourceOverrideTarget"), .mode = text(boot, "BootSourceOverrideMode") };
        result.boot.enabled_evidence = doc.evidence(result.boot.state.enabled != null);
        result.boot.target_evidence = doc.evidence(result.boot.state.target != null);
        result.boot.mode_evidence = doc.evidence(result.boot.state.mode != null);
        const enabled = try stringList(a, member(boot, "BootSourceOverrideEnabled@Redfish.AllowableValues"));
        const targets = try stringList(a, member(boot, "BootSourceOverrideTarget@Redfish.AllowableValues"));
        const modes = try stringList(a, member(boot, "BootSourceOverrideMode@Redfish.AllowableValues"));
        const order = try stringList(a, member(boot, "BootOrder"));
        const alias = try stringList(a, member(boot, "AliasBootOrder"));
        result.boot.allowed_enabled = .{ .value = enabled, .evidence = doc.evidence(enabled != null) };
        result.boot.allowed_targets = .{ .value = targets, .evidence = doc.evidence(targets != null) };
        result.boot.allowed_modes = .{ .value = modes, .evidence = doc.evidence(modes != null) };
        result.boot.boot_order = .{ .value = order, .evidence = doc.evidence(order != null) };
        result.boot.alias_boot_order = .{ .value = alias, .evidence = doc.evidence(alias != null) };
        if (link(boot, "BootOptions")) |options| result.boot_options = try resourceUri(a, origin, options);
        if (member(doc.value, "@Redfish.Settings")) |settings| {
            if (link(settings, "SettingsObject")) |uri| result.boot.settings_uri = try resourceUri(a, origin, uri);
            // A SettingsObject does not prove which Boot fields are writable.
        } else result.boot.write_uri = doc.uri;
    }
    if (member(doc.value, "Links")) |links| result.managed_by = try resourceLinks(a, origin, member(links, "ManagedBy"));
    return result;
}
fn resourceLinks(a: std.mem.Allocator, origin: Origin, value: ?std.json.Value) ![]const []const u8 {
    const array = value orelse return &.{};
    if (array != .array or array.array.items.len > max_collection_members) return error.InvalidLinks;
    const result = try a.alloc([]const u8, array.array.items.len);
    for (array.array.items, 0..) |item, i| result[i] = try resourceUri(a, origin, text(item, "@odata.id") orelse return error.InvalidLinks);
    return result;
}
pub fn applyActionInfo(a: std.mem.Allocator, snapshot: *svc.PowerSnapshot, doc: Document) !void {
    const params = member(doc.value, "Parameters") orelse return;
    if (params != .array or params.array.items.len > 32) return error.InvalidActionInfo;
    for (params.array.items) |param| if (text(param, "Name")) |name| if (std.mem.eql(u8, name, "ResetType")) {
        const values = try stringList(a, member(param, "AllowableValues")) orelse return;
        if (snapshot.reset_types.value) |inline_values| {
            var intersection: std.ArrayList([]const u8) = .empty;
            for (values) |value| if (svc.contains(inline_values, value)) try intersection.append(a, value);
            snapshot.reset_types.value = try intersection.toOwnedSlice(a);
        } else snapshot.reset_types.value = values;
        snapshot.reset_types.evidence = doc.evidence(true);
        return;
    };
}
pub fn secondaryAuth(doc: Document) svc.SecondaryAuth {
    if (!doc.accepted()) return .unknown;
    var value = member(doc.value, "EnableAuthConfirm");
    if (value == null) if (member(doc.value, "Oem")) |oem| if (member(oem, "Public")) |public| {
        value = member(public, "EnableAuthConfirm");
    };
    const flag = value orelse return .unknown;
    return if (flag == .bool) (if (flag.bool) .required else .disabled) else .unknown;
}
pub const Task = struct { state: enum { running, completed, failed, unknown }, percent: ?u8 = null };
pub fn parseTask(doc: Document) Task {
    if (!doc.accepted()) return .{ .state = .failed };
    if (text(doc.value, "TaskStatus")) |status| if (!std.mem.eql(u8, status, "OK")) return .{ .state = .failed };
    const state = text(doc.value, "TaskState") orelse return .{ .state = .unknown };
    if (std.mem.eql(u8, state, "Completed")) return .{ .state = .completed };
    if (std.mem.eql(u8, state, "Exception") or std.mem.eql(u8, state, "Killed") or std.mem.eql(u8, state, "Cancelled") or std.mem.eql(u8, state, "Interrupted")) return .{ .state = .failed };
    if (std.mem.eql(u8, state, "Running") or std.mem.eql(u8, state, "New") or std.mem.eql(u8, state, "Pending") or std.mem.eql(u8, state, "Starting")) return .{ .state = .running };
    return .{ .state = .unknown };
}

pub const ResourceKind = enum { root, systems, managers, system, manager, action_info, boot_options, boot_option, security, settings, session_service };
pub const Resource = struct { kind: ResourceKind, doc: Document, system_scope: ?[]const u8 = null };
pub const ReadRequest = struct { uri: []const u8, kind: ResourceKind, system_scope: ?[]const u8 = null };
pub const Discovery = struct {
    arena: std.heap.ArenaAllocator,
    backing: std.mem.Allocator,
    origin: Origin,
    queue: std.ArrayList(ReadRequest) = .empty,
    resources: std.ArrayList(Resource) = .empty,
    outstanding: std.ArrayList(ReadRequest) = .empty,
    cursor: usize = 0,
    mapping_system: ?[]const u8 = null,
    mapping_manager: ?[]const u8 = null,
    boot_write_targets: std.ArrayList(struct { system_uri: []const u8, write_uri: []const u8 }) = .empty,
    pub fn init(a: std.mem.Allocator, endpoint: model.Endpoint) !Discovery {
        var self: Discovery = .{ .arena = .init(a), .backing = a, .origin = undefined };
        errdefer self.arena.deinit();
        self.origin = try Origin.init(self.arena.allocator(), endpoint);
        try self.outstanding.ensureTotalCapacity(self.arena.allocator(), 8);
        try self.schedule("/redfish/v1/", .root);
        return self;
    }
    pub fn deinit(self: *Discovery) void {
        for (self.resources.items) |*resource| resource.doc.deinit();
        self.resources.deinit(self.backing);
        self.arena.deinit();
        self.* = undefined;
    }
    fn schedule(self: *Discovery, uri: []const u8, kind: ResourceKind) !void {
        return self.scheduleScoped(uri, kind, null);
    }
    fn scheduleScoped(self: *Discovery, uri: []const u8, kind: ResourceKind, system_scope: ?[]const u8) !void {
        const checked = try resourceUri(self.arena.allocator(), self.origin, uri);
        for (self.queue.items) |existing| if (std.mem.eql(u8, existing.uri, checked)) return;
        if (self.queue.items.len >= max_resources) return error.DiscoveryLimit;
        try self.queue.append(self.arena.allocator(), .{ .uri = checked, .kind = kind, .system_scope = system_scope });
    }
    pub fn next(self: *Discovery) ?ReadRequest {
        if (self.cursor == self.queue.items.len or self.outstanding.items.len >= 8) return null;
        const result = self.queue.items[self.cursor];
        self.cursor += 1;
        self.outstanding.appendAssumeCapacity(result);
        return result;
    }
    pub fn ingest(self: *Discovery, request: ReadRequest, status: u16, body: []const u8, etag: ?[]const u8, now_ms: u64) !void {
        var outstanding_index: ?usize = null;
        for (self.outstanding.items, 0..) |pending, i| if (pending.kind == request.kind and std.mem.eql(u8, pending.uri, request.uri)) {
            outstanding_index = i;
            break;
        };
        _ = self.outstanding.swapRemove(outstanding_index orelse return error.StaleDiscoveryCompletion);
        const a = self.arena.allocator();
        var doc = try Document.parse(self.backing, request.uri, status, body, etag, now_ms);
        errdefer doc.deinit();
        if (doc.validity != .unavailable) switch (request.kind) {
            .root => {
                const root = try parseRoot(a, self.origin, doc);
                try self.schedule(root.systems, .systems);
                try self.schedule(root.managers, .managers);
                try self.schedule(root.sessions, .session_service);
            },
            .systems, .managers, .boot_options => {
                const collection = try parseCollection(a, self.origin, doc);
                const kind: ResourceKind = switch (request.kind) {
                    .systems => .system,
                    .managers => .manager,
                    else => .boot_option,
                };
                for (collection.members) |uri| try self.scheduleScoped(uri, kind, request.system_scope);
                if (collection.next) |next_uri| {
                    for (self.queue.items[0..self.cursor]) |existing| if (std.mem.eql(u8, existing.uri, next_uri)) return error.PaginationCycle;
                    try self.scheduleScoped(next_uri, request.kind, request.system_scope);
                }
            },
            .system => {
                const parsed_system = try parseSystem(a, self.origin, doc);
                if (parsed_system.action_info) |uri| try self.schedule(uri, .action_info);
                if (parsed_system.boot_options) |uri| try self.scheduleScoped(uri, .boot_options, doc.uri);
                if (parsed_system.boot.settings_uri) |uri| try self.scheduleScoped(uri, .settings, doc.uri);
            },
            .manager => {
                // The manager can identify the canonical ComputerSystem even
                // when Systems collection members use another resource alias.
                // Follow only validated same-origin links; proveKvmMapping
                // still requires an accepted system with identity and a
                // reciprocal ManagedBy relationship before publishing reads.
                if (member(doc.value, "Links")) |links| {
                    const managed = try resourceLinks(a, self.origin, member(links, "ManagerForServers"));
                    for (managed) |uri| try self.schedule(uri, .system);
                }
                if (link(doc.value, "SecurityService")) |uri| try self.schedule(uri, .security);
            },
            else => {},
        };
        try self.resources.append(self.backing, .{ .kind = request.kind, .doc = doc, .system_scope = request.system_scope });
    }
    pub fn find(self: *const Discovery, uri: []const u8) ?*const Document {
        for (self.resources.items) |*resource| if (std.mem.eql(u8, resource.doc.uri, uri)) return &resource.doc;
        return null;
    }
    /// The profile must independently prove this manager owns the KVM channel.
    /// Relationship links then have to identify exactly one ComputerSystem.
    pub fn proveKvmMapping(self: *Discovery, manager_uri: []const u8, channel: []const u8, profile_evidence_verified: bool) !void {
        self.mapping_system = null;
        self.mapping_manager = null;
        if (!profile_evidence_verified or !std.mem.eql(u8, channel, "/kvm/0")) return error.MappingUnverified;
        const manager = self.find(manager_uri) orelse return error.MappingUnverified;
        if (!manager.accepted()) return error.MappingUnverified;
        const links = member(manager.value, "Links") orelse return error.MappingUnverified;
        const managed = try resourceLinks(self.arena.allocator(), self.origin, member(links, "ManagerForServers"));
        if (managed.len != 1) return error.MappingAmbiguous;
        const system_doc = self.find(managed[0]) orelse return error.MappingUnverified;
        const parsed_system = try parseSystem(self.arena.allocator(), self.origin, system_doc.*);
        if (!system_doc.accepted() or !svc.contains(parsed_system.managed_by, manager_uri) or parsed_system.power.system_identity.len == 0) return error.MappingUnverified;
        self.mapping_system = managed[0];
        self.mapping_manager = try self.arena.allocator().dupe(u8, manager_uri);
    }
    pub fn system(self: *Discovery, uri: []const u8, capability: svc.Capability) !ParsedSystem {
        const doc = self.find(uri) orelse return error.ResourceUnavailable;
        const a = self.arena.allocator();
        var result = try parseSystem(a, self.origin, doc.*);
        if (result.action_info) |info| if (self.find(info)) |action_doc| try applyActionInfo(a, &result.power, action_doc.*);
        var cap = capability;
        cap.system_mapping_verified = self.mapping_system != null and std.mem.eql(u8, self.mapping_system.?, uri);
        cap.secondary_auth = .unknown;
        cap.secondary_auth_evidence = .{};
        if (self.mapping_manager) |manager_uri| if (self.find(manager_uri)) |manager| if (link(manager.value, "SecurityService")) |security_uri| if (self.find(security_uri)) |security| {
            cap.secondary_auth = secondaryAuth(security.*);
            cap.secondary_auth_evidence = security.evidence(cap.secondary_auth != .unknown);
        };
        result.power.capability = cap;
        result.boot.capability = cap;
        if (result.boot.settings_uri) |settings_uri| if (self.find(settings_uri)) |pending| {
            const parsed_pending = try parseSystem(a, self.origin, pending.*);
            if (pending.accepted()) result.boot.pending = parsed_pending.boot.state;
        };
        for (self.boot_write_targets.items) |target| if (std.mem.eql(u8, target.system_uri, uri)) {
            result.boot.write_uri = target.write_uri;
            result.boot.etag = (self.find(target.write_uri) orelse return error.ResourceUnavailable).etag;
            break;
        };
        var options: std.ArrayList(svc.BootOption) = .empty;
        for (self.resources.items) |resource| if (resource.kind == .boot_option and resource.doc.validity != .unavailable and svc.optionalEqual(resource.system_scope, uri)) {
            const reference = text(resource.doc.value, "BootOptionReference") orelse continue;
            var duplicate = false;
            for (options.items) |old| if (std.mem.eql(u8, old.reference, reference)) {
                duplicate = true;
                break;
            };
            if (!duplicate) {
                if (options.items.len >= max_collection_members) return error.CollectionTooLarge;
                const enabled = member(resource.doc.value, "BootOptionEnabled");
                try options.append(a, .{ .reference = reference, .id = text(resource.doc.value, "Id") orelse resource.doc.uri, .name = text(resource.doc.value, "DisplayName"), .enabled = if (enabled != null and enabled.? == .bool) enabled.?.bool else null, .evidence = resource.doc.evidence(true) });
            }
        };
        result.boot.options = try options.toOwnedSlice(a);
        return result;
    }
    /// A firmware/profile can explicitly establish which discovered resource
    /// owns the Boot fields. Discovery never tries both current and Settings.
    pub fn confirmBootWriteTarget(self: *Discovery, system_uri: []const u8, write_uri: []const u8, field_mapping_verified: bool) !void {
        if (!field_mapping_verified) return error.BootWriteTargetUnverified;
        const system_doc = self.find(system_uri) orelse return error.ResourceUnavailable;
        const parsed_system = try parseSystem(self.arena.allocator(), self.origin, system_doc.*);
        const target = try resourceUri(self.arena.allocator(), self.origin, write_uri);
        if (!system_doc.accepted() or (!std.mem.eql(u8, target, system_uri) and !svc.optionalEqual(parsed_system.boot.settings_uri, target))) return error.BootWriteTargetUnverified;
        const target_doc = self.find(target) orelse return error.ResourceUnavailable;
        if (!target_doc.accepted()) return error.BootWriteTargetUnverified;
        for (self.boot_write_targets.items) |*entry| if (std.mem.eql(u8, entry.system_uri, system_uri)) {
            entry.write_uri = target;
            return;
        };
        try self.boot_write_targets.append(self.arena.allocator(), .{ .system_uri = system_doc.uri, .write_uri = target });
    }
};
