//! Merge an external registry without adopting its identity namespace.
const std = @import("std");
const hosts = @import("hosts.zig");
const identity = hosts.identity;
pub const Mapping = struct { source: identity.ConnectionId, target: identity.ConnectionId };
pub const RemapPayload = *const fn (std.mem.Allocator, []const u8, []const Mapping) anyerror![]u8;
pub const Provider = struct {
    context: *const anyopaque,
    resolve: *const fn (*const anyopaque, []const u8, u32) ?RemapPayload,
};

pub fn mapped(ids: []const Mapping, source: identity.ConnectionId) !identity.ConnectionId {
    for (ids) |entry| if (entry.source == source) return entry.target;
    // Never let an orphan in the source bind to a coincident local ID.
    return error.MissingRouteReference;
}

/// Returns an owned candidate. The caller commits it through HostsTransaction;
/// neither registry is modified on failure, including identity watermarks.
pub fn merge(a: std.mem.Allocator, live: *const hosts.Registry, source: *const hosts.Registry, provider: ?Provider) !hosts.Registry {
    try source.validate();
    for (source.hosts) |host| {
        try live.requireUniqueName(host.name, null);
        try source.requireUniqueName(host.name, host.connection_id);
    }
    var next = try live.clone(a);
    defer next.deinit();
    const owned = next.arena.allocator();
    const ids = try owned.alloc(Mapping, source.hosts.len);
    for (source.hosts, ids) |host, *entry| entry.* = .{ .source = host.connection_id, .target = try next.connection_ids.allocate() };
    const groups = try owned.alloc(identity.AssetGroupId, source.groups.len);
    for (source.groups, groups) |group, *id| {
        const existing = for (next.groups) |local| {
            if (std.mem.eql(u8, local.name, group.name)) break local.group_id;
        } else null;
        id.* = existing orelse try next.addGroup(group.name, group.color);
        if (existing == null) {
            const saved = &next.groups[next.groupIndex(id.*).?];
            saved.collapsed = group.collapsed;
            const fields = try owned.alloc([]const u8, group.unknown_fields.len);
            for (group.unknown_fields, fields) |field, *target| target.* = try owned.dupe(u8, field);
            saved.unknown_fields = fields;
        }
    }
    const merged = try owned.alloc(hosts.HostConfig, live.hosts.len + source.hosts.len);
    @memcpy(merged[0..live.hosts.len], next.hosts);
    for (source.hosts, merged[live.hosts.len..], ids) |host, *target, id| {
        target.* = try hosts.cloneConfig(owned, host);
        target.connection_id = id.target;
        target.revision = 1;
        if (host.asset_group_id) |group| target.asset_group_id = groups[source.groupIndex(group) orelse return error.GroupNotFound];
        const route = try owned.alloc(identity.ConnectionId, host.route.len);
        for (host.route, route) |hop, *mapped_hop| mapped_hop.* = try mapped(ids, hop);
        target.route = route;
        if (host.plugin_payload) |payload| {
            const remap = if (provider) |p| p.resolve(p.context, host.protocolId(), host.payload_version) orelse return error.UnsupportedImportProtocol else return error.UnsupportedImportProtocol;
            target.plugin_payload = try remap(owned, payload, ids);
        }
    }
    next.hosts = merged;
    // Preserve imported group order; an existing same-name group retains its
    // own presentation settings and receives the imported members at the end.
    for (source.groups, groups) |group, id| {
        const local = &next.groups[next.groupIndex(id).?];
        const old_count = local.ordered_connection_ids.len;
        const order = try owned.alloc(identity.ConnectionId, old_count + group.ordered_connection_ids.len);
        @memcpy(order[0..old_count], local.ordered_connection_ids);
        for (group.ordered_connection_ids, order[old_count..]) |member, *target| target.* = try mapped(ids, member);
        local.ordered_connection_ids = order;
        if (live.groupIndex(id) != null and group.ordered_connection_ids.len != 0) local.revision = try identity.advance(local.revision);
    }
    var normalized = try next.clone(a);
    errdefer normalized.deinit();
    for (normalized.hosts[live.hosts.len..]) |host| try normalized.validateSaveReferences(host);
    return normalized;
}
