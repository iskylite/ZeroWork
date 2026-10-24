const std = @import("std");
pub const identity = @import("../host/identity.zig");
pub const Protocol = enum { ssh, sftp };
pub const AuthMode = enum { agent, private_key, password };
pub const schema_version: u32 = 2;
pub const Digest = [32]u8;

pub const HostConfig = struct {
    /// Zero is allowed only for an unsaved, legacy caller's draft. Registry
    /// normalization allocates a persistent identity before serialization.
    connection_id: identity.ConnectionId = @fromBackingInt(0),
    revision: u64 = 1,
    protocol: Protocol = .ssh,
    /// Authoritative provider ID for records outside the legacy enum.
    protocol_id: ?[]const u8 = null,
    payload_version: u32 = 1,
    plugin_payload: ?[]const u8 = null,
    unknown_fields: []const []const u8 = &.{},
    unknown_options: []const []const u8 = &.{},
    unknown_auth: []const []const u8 = &.{},
    auth_mode: AuthMode = .agent,
    pinned: bool = false,
    strict_host_key_checking: bool = true,
    asset_group_id: ?identity.AssetGroupId = null,
    route: []const identity.ConnectionId = &.{},
    name: []const u8,
    host: []const u8,
    port: u16 = 22,
    user: []const u8,
    identity_file: ?[]const u8 = null,
    key_passphrase: ?[]const u8 = null,
    password: ?[]const u8 = null,
    totp_secret: ?[]const u8 = null,
    password_ref: ?[]const u8 = null,
    key_passphrase_ref: ?[]const u8 = null,
    totp_secret_ref: ?[]const u8 = null,
    jump_chain: []const []const u8 = &.{},
    startup_commands: []const []const u8 = &.{},
    group: ?[]const u8 = null,
    ts_default: bool = true,
    terminal_type: []const u8 = "xterm-256color",
    /// Programmatic configs specify their values; the parser records omitted keys.
    terminal_type_explicit: bool = true,
    scrollback: u32 = 50000,
    keepalive: bool = true,
    compression: bool = false,
    compression_explicit: bool = true,
    socks_enabled: bool = false,
    socks_port: u16 = 1080,
    socks_bind: []const u8 = "127.0.0.1",
    socks_exit: ?usize = null,
    socks_auto_start: bool = false,
    socks_max_connections: u16 = 64,

    pub fn protocolId(self: HostConfig) []const u8 {
        return self.protocol_id orelse @tagName(self.protocol);
    }

    pub fn isLegacy(self: HostConfig) bool {
        return eq(self.protocolId(), "ssh") or eq(self.protocolId(), "sftp");
    }

    pub fn validate(self: HostConfig) ValidationError!void {
        if (!self.isLegacy() or self.payload_version > 1) {
            if (trim(self.name).len == 0) return error.MissingName;
            if (self.protocolId().len == 0 or self.revision == 0 or self.payload_version == 0) return error.InvalidValue;
            return;
        }
        if (self.totp_secret) |seed| @import("../proto/ssh/totp.zig").validate(seed) catch return error.InvalidTotpSeed;
        if (trim(self.name).len == 0) return error.MissingName;
        if (trim(self.host).len == 0) return error.MissingHost;
        if (trim(self.user).len == 0) return error.MissingUser;
        if (self.port == 0 or self.socks_port == 0) return error.InvalidPort;
        if (self.socks_max_connections == 0) return error.InvalidValue;
        if (trim(self.terminal_type).len == 0 or trim(self.socks_bind).len == 0) return error.InvalidValue;
        if (self.socks_exit) |exit| if (exit >= @max(self.route.len, self.jump_chain.len)) return error.InvalidSocksExit;
        if (self.jump_chain.len > 8 or self.route.len > 8) return error.TooManyJumps;
        if (self.revision == 0) return error.InvalidRevision;
        inline for (.{ "name", "host", "user" }) |field| {
            const value = @field(self, field);
            if (!std.unicode.utf8ValidateSlice(value) or std.mem.indexOfAny(u8, value, "\x00\r\n\t") != null) return error.InvalidValue;
        }
        if (self.identity_file != null and (self.password != null or self.password_ref != null)) return error.AmbiguousCredential;
        if ((self.key_passphrase != null or self.key_passphrase_ref != null) and self.identity_file == null) return error.PassphraseWithoutKey;
    }

    pub fn owner(self: HostConfig) identity.AssetOwner {
        return .{ .id = self.connection_id, .revision = self.revision };
    }

    pub fn cloneName(self: HostConfig, buffer: []u8) std.Io.Writer.Error![]const u8 {
        var writer = std.Io.Writer.fixed(buffer);
        try writer.print("{s}-副本", .{self.name});
        return writer.buffered();
    }
};

pub const AssetGroup = struct {
    group_id: identity.AssetGroupId,
    revision: u64 = 1,
    name: []const u8,
    color: []const u8 = "",
    collapsed: bool = false,
    ordered_connection_ids: []const identity.ConnectionId = &.{},
    unknown_fields: []const []const u8 = &.{},
};

/// The sole persisted host registry. Names/jump_chain remain compatibility
/// projections; connection_id/asset_group_id/route are the durable identities.
pub const Registry = struct {
    arena: std.heap.ArenaAllocator,
    hosts: []HostConfig,
    groups: []AssetGroup = &.{},
    revision: u64 = 1,
    connection_ids: identity.Allocator(identity.ConnectionId) = .{},
    group_ids: identity.Allocator(identity.AssetGroupId) = .{},
    needs_migration: bool = false,
    /// Exact loaded bytes, not a canonical re-encoding. Used for optimistic
    /// disk conflicts, including edits which did not increment a revision.
    source_hash: ?Digest = null,
    unknown_fields: []const []const u8 = &.{},

    pub fn parse(backing: std.mem.Allocator, text: []const u8) !Registry {
        var result: Registry = .{ .arena = .init(backing), .hosts = &.{} };
        errdefer result.deinit();
        const allocator = result.arena.allocator();
        var hosts: std.ArrayList(HostConfig) = .empty;
        var groups: std.ArrayList(AssetGroup) = .empty;
        var builder: ?Builder = null;
        var group: ?GroupBuilder = null;
        var section: enum { none, registry, host, group } = .none;
        var meta_seen: Seen = .empty;
        var has_meta = false;
        var connection_watermark = false;
        var group_watermark = false;
        var statements: StatementIterator = .{ .text = text };
        while (try statements.next()) |raw| {
            var statement = raw;
            const header: ?struct { text: []const u8, kind: @TypeOf(section) } = if (std.mem.startsWith(u8, statement, "[[hosts]]"))
                .{ .text = "[[hosts]]", .kind = .host }
            else if (std.mem.startsWith(u8, statement, "[[groups]]"))
                .{ .text = "[[groups]]", .kind = .group }
            else if (std.mem.startsWith(u8, statement, "[registry]"))
                .{ .text = "[registry]", .kind = .registry }
            else
                null;
            if (header) |h| {
                if (builder) |previous| try hosts.append(allocator, try previous.finish());
                if (group) |previous| try groups.append(allocator, try previous.finish());
                builder = null;
                group = null;
                section = h.kind;
                switch (section) {
                    .host => builder = .{},
                    .group => group = .{},
                    .registry => {
                        if (has_meta) return error.DuplicateKey;
                        has_meta = true;
                    },
                    .none => unreachable,
                }
                statement = trim(statement[h.text.len..]);
                if (statement.len == 0) continue;
            }
            const split = findTopLevel(statement, '=') orelse return error.InvalidAssignment;
            const key = trim(statement[0..split]);
            const value = trim(statement[split + 1 ..]);
            switch (section) {
                .none => return error.MissingHostHeader,
                .host => try builder.?.apply(allocator, key, value),
                .group => try group.?.apply(allocator, key, value),
                .registry => {
                    try mark(&meta_seen, allocator, key);
                    if (eq(key, "schema_version")) {
                        if (try number(u32, value) != schema_version) return error.UnsupportedSchema;
                    } else if (eq(key, "revision")) result.revision = try nonzero(value) else if (eq(key, "next_connection_id")) {
                        result.connection_ids.next_value = try nonzero(value);
                        connection_watermark = true;
                    } else if (eq(key, "connection_ids_exhausted")) result.connection_ids.exhausted = try parseBool(value) else if (eq(key, "next_group_id")) {
                        result.group_ids.next_value = try nonzero(value);
                        group_watermark = true;
                    } else if (eq(key, "group_ids_exhausted")) result.group_ids.exhausted = try parseBool(value) else result.unknown_fields = try appendRaw(allocator, result.unknown_fields, key, value);
                },
            }
        }
        if (builder) |last| try hosts.append(allocator, try last.finish());
        if (group) |last| try groups.append(allocator, try last.finish());
        if (has_meta and (!meta_seen.contains("schema_version") or !meta_seen.contains("revision"))) return error.InvalidRegistryMetadata;
        result.hosts = try hosts.toOwnedSlice(allocator);
        result.groups = try groups.toOwnedSlice(allocator);
        result.needs_migration = !has_meta;
        // Explicit watermarks may never be lower than retained identities.
        if (connection_watermark) for (result.hosts) |host| {
            if (!result.connection_ids.exhausted and @backingInt(host.connection_id) >= result.connection_ids.next_value) return error.InvalidIdentityWatermark;
        };
        if (group_watermark) for (result.groups) |item| {
            if (!result.group_ids.exhausted and @backingInt(item.group_id) >= result.group_ids.next_value) return error.InvalidIdentityWatermark;
        };
        try result.normalize();
        try result.validate();
        result.source_hash = digest(text);
        return result;
    }

    pub fn deinit(self: *Registry) void {
        self.arena.deinit();
        self.* = undefined;
    }

    pub fn indexOf(self: *const Registry, id: identity.ConnectionId) ?usize {
        for (self.hosts, 0..) |host, i| if (host.connection_id == id) return i;
        return null;
    }
    pub fn groupIndex(self: *const Registry, id: identity.AssetGroupId) ?usize {
        for (self.groups, 0..) |group, i| if (group.group_id == id) return i;
        return null;
    }
    pub fn get(self: *const Registry, owner: identity.AssetOwner) !HostConfig {
        const host = self.hosts[self.indexOf(owner.id) orelse return error.ConnectionNotFound];
        if (host.revision != owner.revision) return error.RevisionConflict;
        return host;
    }

    pub fn clone(self: *const Registry, backing: std.mem.Allocator) !Registry {
        var result: Registry = .{ .arena = .init(backing), .hosts = &.{}, .revision = self.revision, .connection_ids = self.connection_ids, .group_ids = self.group_ids, .needs_migration = self.needs_migration, .source_hash = self.source_hash };
        result.unknown_fields = try cloneStrings(result.arena.allocator(), self.unknown_fields);
        errdefer result.deinit();
        const allocator = result.arena.allocator();
        result.hosts = try allocator.alloc(HostConfig, self.hosts.len);
        for (self.hosts, result.hosts) |host, *target| target.* = try cloneConfig(allocator, host);
        result.groups = try allocator.alloc(AssetGroup, self.groups.len);
        for (self.groups, result.groups) |item, *target| target.* = .{ .group_id = item.group_id, .revision = item.revision, .name = try allocator.dupe(u8, item.name), .color = try allocator.dupe(u8, item.color), .collapsed = item.collapsed, .ordered_connection_ids = try allocator.dupe(identity.ConnectionId, item.ordered_connection_ids), .unknown_fields = try cloneStrings(allocator, item.unknown_fields) };
        try result.normalize();
        try result.validate();
        return result;
    }

    fn normalize(self: *Registry) !void {
        const allocator = self.arena.allocator();
        for (self.hosts, 0..) |host, i| if (@backingInt(host.connection_id) != 0) {
            for (self.hosts[0..i]) |previous| if (previous.connection_id == host.connection_id) return error.DuplicateConnectionId;
            try self.connection_ids.reserve(host.connection_id);
        };
        for (self.groups, 0..) |group, i| {
            if (@backingInt(group.group_id) == 0) return error.InvalidIdentity;
            for (self.groups[0..i]) |previous| {
                if (previous.group_id == group.group_id) return error.DuplicateGroupId;
                if (eq(previous.name, group.name)) return error.DuplicateGroupName;
            }
            try self.group_ids.reserve(group.group_id);
        }
        for (self.hosts) |*host| {
            if (host.identity_file != null) host.auth_mode = .private_key else if (host.password != null) host.auth_mode = .password;
            if (@backingInt(host.connection_id) == 0) {
                host.connection_id = try self.connection_ids.allocate();
                self.needs_migration = true;
            }
            if (host.asset_group_id == null) if (host.group) |name| {
                var found: ?identity.AssetGroupId = null;
                for (self.groups) |group| if (eq(group.name, name)) {
                    found = group.group_id;
                    break;
                };
                if (found == null) {
                    const id = try self.group_ids.allocate();
                    const next = try allocator.alloc(AssetGroup, self.groups.len + 1);
                    @memcpy(next[0..self.groups.len], self.groups);
                    next[self.groups.len] = .{ .group_id = id, .name = name };
                    self.groups = next;
                    found = id;
                }
                host.asset_group_id = found;
            };
        }
        for (self.hosts) |*host| {
            if (host.route.len == 0 and host.jump_chain.len != 0) {
                const route = try allocator.alloc(identity.ConnectionId, host.jump_chain.len);
                for (host.jump_chain, route) |name, *id| {
                    var found: ?identity.ConnectionId = null;
                    for (self.hosts) |candidate| if (eq(candidate.protocolId(), "ssh") and eq(candidate.name, name)) {
                        if (found != null) return error.AmbiguousLegacyRoute;
                        found = candidate.connection_id;
                    };
                    id.* = found orelse return error.MissingLegacyRoute;
                }
                host.route = route;
            }
            if (host.asset_group_id) |id| host.group = self.groups[self.groupIndex(id) orelse return error.GroupNotFound].name;
            const names = try allocator.alloc([]const u8, host.route.len);
            for (host.route, names) |id, *name| {
                name.* = if (self.indexOf(id)) |index| self.hosts[index].name else try std.fmt.allocPrint(allocator, "缺失连接 #{d}", .{@backingInt(id)});
            }
            host.jump_chain = names;
        }
        for (self.groups) |*group| {
            var order: std.ArrayList(identity.ConnectionId) = .empty;
            for (group.ordered_connection_ids) |id| {
                const index = self.indexOf(id) orelse return error.InvalidGroupOrder;
                if (self.hosts[index].asset_group_id != group.group_id) return error.InvalidGroupOrder;
                for (order.items) |previous| if (previous == id) return error.InvalidGroupOrder;
                try order.append(allocator, id);
            }
            for (self.hosts) |host| if (host.asset_group_id == group.group_id) {
                var present = false;
                for (order.items) |id| if (id == host.connection_id) {
                    present = true;
                    break;
                };
                if (!present) try order.append(allocator, host.connection_id);
            };
            group.ordered_connection_ids = try order.toOwnedSlice(allocator);
        }
    }

    pub fn validate(self: *const Registry) !void {
        if (self.revision == 0) return error.InvalidRevision;
        for (self.groups, 0..) |group, i| {
            if (@backingInt(group.group_id) == 0) return error.InvalidIdentity;
            for (self.groups[0..i]) |previous| if (previous.group_id == group.group_id) return error.DuplicateGroupId;
            if (group.revision == 0) return error.InvalidGroup;
            try validGroupName(group.name);
        }
        for (self.hosts, 0..) |host, index| {
            try host.validate();
            if (@backingInt(host.connection_id) == 0) return error.InvalidIdentity;
            for (self.hosts[0..index]) |previous| if (previous.connection_id == host.connection_id) return error.DuplicateConnectionId;
            if (host.asset_group_id) |id| if (self.groupIndex(id) == null) return error.GroupNotFound;
            for (host.route, 0..) |id, i| {
                if (@backingInt(id) == 0) return error.InvalidIdentity;
                if (id == host.connection_id) return error.RouteCycle;
                for (host.route[0..i]) |previous| if (id == previous) return error.DuplicateRoute;
                // Missing stable references are retained for repair/display;
                // resolveRoute rejects them before a caller can begin IO.
                if (self.indexOf(id)) |hop_index| if (!eq(self.hosts[hop_index].protocolId(), "ssh")) return error.InvalidRouteProtocol;
            }
        }
    }

    /// Owned array of borrowed configs, ordered [jump..., target]. The caller
    /// must freeze configs before asynchronous use. Never resolves a missing ID
    /// through its current display name or recursively inherits a hop's route.
    pub fn resolveRoute(self: *const Registry, owner: identity.AssetOwner, allocator: std.mem.Allocator) ![]HostConfig {
        const target = try self.get(owner);
        try self.validate();
        if (!target.isLegacy() or target.payload_version != 1) return error.UnsupportedProtocol;
        const result = try allocator.alloc(HostConfig, target.route.len + 1);
        errdefer allocator.free(result);
        for (target.route, 0..) |id, i| {
            const hop = self.hosts[self.indexOf(id) orelse return error.MissingRouteReference];
            if (!eq(hop.protocolId(), "ssh") or hop.payload_version != 1) return error.UnsupportedProtocol;
            // Explicit route is flat: referenced hosts do not contribute their own route.
            for (result[0..i]) |previous| if (previous.port == hop.port and eq(previous.host, hop.host)) return error.RouteCycle;
            if (target.port == hop.port and eq(target.host, hop.host)) return error.RouteCycle;
            result[i] = hop;
        }
        result[target.route.len] = target;
        return result;
    }

    /// Stable base order is retained separately from this pinned-first view.
    pub fn orderedIds(self: *const Registry, allocator: std.mem.Allocator, group_id: ?identity.AssetGroupId) ![]identity.ConnectionId {
        var result: std.ArrayList(identity.ConnectionId) = .empty;
        errdefer result.deinit(allocator);
        const base: ?[]const identity.ConnectionId = if (group_id) |id| self.groups[self.groupIndex(id) orelse return error.GroupNotFound].ordered_connection_ids else null;
        for ([_]bool{ true, false }) |pinned| {
            if (base) |ids| {
                for (ids) |id| {
                    const host = self.hosts[self.indexOf(id) orelse return error.ConnectionNotFound];
                    if (host.pinned == pinned) try result.append(allocator, id);
                }
            } else for (self.hosts) |host| if (host.asset_group_id == null and host.pinned == pinned) {
                try result.append(allocator, host.connection_id);
            };
        }
        return result.toOwnedSlice(allocator);
    }

    pub fn format(self: Registry, writer: *std.Io.Writer) !void {
        var normalized = try self.clone(std.heap.page_allocator);
        defer normalized.deinit();
        try normalized.formatCanonical(writer);
    }
    fn formatCanonical(self: *const Registry, writer: *std.Io.Writer) !void {
        try writer.print("[registry]\nschema_version = {d}\nrevision = {d}\nnext_connection_id = {d}\nconnection_ids_exhausted = {}\nnext_group_id = {d}\ngroup_ids_exhausted = {}\n", .{ schema_version, self.revision, self.connection_ids.next_value, self.connection_ids.exhausted, self.group_ids.next_value, self.group_ids.exhausted });
        for (self.unknown_fields) |field| {
            try writer.writeAll(field);
            try writer.writeByte('\n');
        }
        for (self.groups) |group| {
            try writer.print("\n[[groups]]\ngroup_id = {d}\nrevision = {d}\nname = ", .{ @backingInt(group.group_id), group.revision });
            try writeString(writer, group.name);
            try writer.writeAll("\ncolor = ");
            try writeString(writer, group.color);
            try writer.print("\ncollapsed = {}\nordered_connection_ids = ", .{group.collapsed});
            try writeIds(writer, group.ordered_connection_ids);
            for (group.unknown_fields) |field| {
                try writer.writeByte('\n');
                try writer.writeAll(field);
            }
            try writer.writeByte('\n');
        }
        for (self.hosts) |host| {
            try writer.writeByte('\n');
            try formatOne(host, writer);
        }
    }
    pub fn encode(self: *const Registry, allocator: std.mem.Allocator) ![]u8 {
        var writer: std.Io.Writer.Allocating = .init(allocator);
        defer writer.deinit();
        try self.format(&writer.writer);
        return allocator.dupe(u8, writer.written());
    }
    /// Full persistence, including existing explicitly stored credentials.
    /// Use duplicate() for configuration copying; it strips all secrets.
    pub fn formatOne(host: HostConfig, writer: *std.Io.Writer) !void {
        try writer.writeAll("[[hosts]]\n");
        if (@backingInt(host.connection_id) != 0) try writer.print("connection_id = {d}\nrevision = {d}\n", .{ @backingInt(host.connection_id), host.revision });
        try writer.print("protocol = \"{s}\"\npinned = {}\noptions = {{ strict_host_key = {}", .{ host.protocolId(), host.pinned, host.strict_host_key_checking });
        for (host.unknown_options) |field| {
            try writer.writeAll(", ");
            try writer.writeAll(field);
        }
        try writer.writeAll(" }\nname = ");
        try writeString(writer, host.name);
        try writer.print("\nauth_mode = \"{s}\"", .{@tagName(host.auth_mode)});
        try writer.writeAll("\nhost = ");
        try writeString(writer, host.host);
        try writer.print("\nport = {d}\nuser = ", .{host.port});
        try writeString(writer, host.user);
        if (host.identity_file) |key| {
            try writer.writeAll("\nauth = { key = ");
            try writeString(writer, key);
            if (host.key_passphrase_ref) |reference| {
                try writer.writeAll(", passphrase_ref = ");
                try writeString(writer, reference);
            } else if (host.key_passphrase) |passphrase| {
                try writer.writeAll(", passphrase = ");
                try writeString(writer, passphrase);
            }
            for (host.unknown_auth) |field| {
                try writer.writeAll(", ");
                try writer.writeAll(field);
            }
            try writer.writeAll(" }");
        } else if (host.password_ref) |reference| {
            try writer.writeAll("\nauth = { password_ref = ");
            try writeString(writer, reference);
            for (host.unknown_auth) |field| {
                try writer.writeAll(", ");
                try writer.writeAll(field);
            }
            try writer.writeAll(" }");
        } else if (host.password) |password| {
            try writer.writeAll("\nauth = { password = ");
            try writeString(writer, password);
            for (host.unknown_auth) |field| {
                try writer.writeAll(", ");
                try writer.writeAll(field);
            }
            try writer.writeAll(" }");
        } else if (host.unknown_auth.len != 0) {
            try writer.writeAll("\nauth = { ");
            for (host.unknown_auth, 0..) |field, i| {
                if (i != 0) try writer.writeAll(", ");
                try writer.writeAll(field);
            }
            try writer.writeAll(" }");
        }
        if (host.route.len != 0) {
            try writer.writeAll("\nroute = ");
            try writeIds(writer, host.route);
        } else if (host.jump_chain.len != 0) {
            try writer.writeAll("\njump_chain = ");
            try writeStringArray(writer, host.jump_chain);
        }
        if (host.asset_group_id) |id| try writer.print("\nasset_group_id = {d}", .{@backingInt(id)}) else if (host.group) |name| {
            try writer.writeAll("\ngroup = ");
            try writeString(writer, name);
        }
        if (host.totp_secret_ref) |reference| {
            try writer.writeAll("\ntotp_secret_ref = ");
            try writeString(writer, reference);
        } else if (host.totp_secret) |secret| {
            try writer.writeAll("\ntotp_secret = ");
            try writeString(writer, secret);
        }
        if (host.startup_commands.len != 0) {
            try writer.writeAll("\nstartup_commands = ");
            try writeStringArray(writer, host.startup_commands);
        }
        try writer.print("\nts_default = {}", .{host.ts_default});
        if (host.terminal_type_explicit) {
            try writer.writeAll("\nterminal_type = ");
            try writeString(writer, host.terminal_type);
        }
        try writer.print("\nscrollback = {d}\nkeepalive = {}", .{ host.scrollback, host.keepalive });
        if (host.compression_explicit) try writer.print("\ncompression = {}", .{host.compression});
        try writer.print("\nsocks_enabled = {}\nsocks_port = {d}\nsocks_bind = ", .{ host.socks_enabled, host.socks_port });
        try writeString(writer, host.socks_bind);
        if (host.socks_exit) |exit| try writer.print("\nsocks_exit = {d}", .{exit});
        try writer.print("\nsocks_auto_start = {}\nsocks_max_connections = {d}\n", .{ host.socks_auto_start, host.socks_max_connections });
        if (host.payload_version != 1) try writer.print("payload_version = {d}\n", .{host.payload_version});
        if (host.plugin_payload) |payload| {
            try writer.writeAll("payload = ");
            try writeString(writer, payload);
            try writer.writeByte('\n');
        }
        for (host.unknown_fields) |field| {
            try writer.writeAll(field);
            try writer.writeByte('\n');
        }
    }

    /// Mutations operate only on an owned candidate (store.HostsTransaction).
    /// The live registry is published only after its atomic disk commit.
    pub fn add(self: *Registry, value: HostConfig) !identity.AssetOwner {
        var next = try self.clone(self.arena.child_allocator);
        errdefer next.deinit();
        const result = try next.addInPlace(value);
        try self.advanceMembershipRevisions(&next);
        self.deinit();
        self.* = next;
        return result;
    }
    fn addInPlace(self: *Registry, value: HostConfig) !identity.AssetOwner {
        const allocator = self.arena.allocator();
        var host = try cloneConfig(allocator, value);
        host.connection_id = try self.connection_ids.allocate();
        host.revision = 1;
        try self.checkName(host, null);
        try host.validate();
        const next = try allocator.alloc(HostConfig, self.hosts.len + 1);
        @memcpy(next[0..self.hosts.len], self.hosts);
        next[self.hosts.len] = host;
        self.hosts = next;
        try self.normalize();
        try self.validate();
        try self.validateSaveReferences(self.hosts[self.indexOf(host.connection_id).?]);
        return host.owner();
    }
    pub fn update(self: *Registry, expected: identity.AssetOwner, value: HostConfig) !identity.AssetOwner {
        var next = try self.clone(self.arena.child_allocator);
        errdefer next.deinit();
        const result = try next.updateInPlace(expected, value);
        try self.advanceMembershipRevisions(&next);
        self.deinit();
        self.* = next;
        return result;
    }
    fn updateInPlace(self: *Registry, expected: identity.AssetOwner, value: HostConfig) !identity.AssetOwner {
        _ = try self.get(expected);
        var host = try cloneConfig(self.arena.allocator(), value);
        host.connection_id = expected.id;
        host.revision = try identity.advance(expected.revision);
        try self.checkName(host, expected.id);
        try host.validate();
        if (self.hosts[self.indexOf(expected.id).?].asset_group_id != host.asset_group_id) self.removeFromGroupOrders(expected.id);
        self.hosts[self.indexOf(expected.id).?] = host;
        try self.normalize();
        try self.validate();
        try self.validateSaveReferences(self.hosts[self.indexOf(host.connection_id).?]);
        return host.owner();
    }
    pub fn duplicate(self: *Registry, expected: identity.AssetOwner, name: []const u8) !identity.AssetOwner {
        var source = try self.get(expected);
        source.name = name;
        source.pinned = false;
        source.password_ref = null;
        source.key_passphrase_ref = null;
        source.totp_secret_ref = null;
        source.password = null;
        source.key_passphrase = null;
        source.totp_secret = null;
        return self.add(source);
    }
    pub fn setPinned(self: *Registry, expected: identity.AssetOwner, pinned: bool) !identity.AssetOwner {
        const index = self.indexOf(expected.id) orelse return error.ConnectionNotFound;
        _ = try self.get(expected);
        const next = try identity.advance(expected.revision);
        self.hosts[index].pinned = pinned;
        self.hosts[index].revision = next;
        return self.hosts[index].owner();
    }
    pub fn move(self: *Registry, expected: identity.AssetOwner, destination: ?identity.AssetGroupId) !identity.AssetOwner {
        var host = try self.get(expected);
        host.asset_group_id = destination;
        host.group = if (destination) |id| self.groups[self.groupIndex(id) orelse return error.GroupNotFound].name else null;
        return self.update(expected, host);
    }
    pub fn remove(self: *Registry, expected: identity.AssetOwner) !void {
        _ = try self.get(expected);
        const index = self.indexOf(expected.id).?;
        if (self.hosts[index].asset_group_id) |id| {
            const group = &self.groups[self.groupIndex(id).?];
            group.revision = try identity.advance(group.revision);
        }
        self.removeFromGroupOrders(expected.id);
        std.mem.copyForwards(HostConfig, self.hosts[index .. self.hosts.len - 1], self.hosts[index + 1 ..]);
        self.hosts = self.hosts[0 .. self.hosts.len - 1];
        // Route references deliberately retain the removed ID for repair.
        // ID allocators are never rewound, even when the last asset is removed.
    }
    fn advanceMembershipRevisions(self: *const Registry, next: *Registry) !void {
        for (next.groups) |*group| if (self.groupIndex(group.group_id)) |index| {
            const previous = self.groups[index];
            if (!std.mem.eql(identity.ConnectionId, previous.ordered_connection_ids, group.ordered_connection_ids)) group.revision = try identity.advance(previous.revision);
        };
    }
    pub fn addGroup(self: *Registry, name: []const u8, color: []const u8) !identity.AssetGroupId {
        try validGroupName(name);
        for (self.groups) |group| if (eq(group.name, name)) return error.DuplicateGroupName;
        const allocator = self.arena.allocator();
        var ids = self.group_ids;
        const id = try ids.allocate();
        const next = try allocator.alloc(AssetGroup, self.groups.len + 1);
        @memcpy(next[0..self.groups.len], self.groups);
        next[self.groups.len] = .{ .group_id = id, .name = try allocator.dupe(u8, name), .color = try allocator.dupe(u8, color) };
        self.groups = next;
        self.group_ids = ids;
        return id;
    }
    pub fn updateGroup(self: *Registry, id: identity.AssetGroupId, expected_revision: u64, name: []const u8, color: []const u8, collapsed: bool) !u64 {
        const index = self.groupIndex(id) orelse return error.GroupNotFound;
        if (self.groups[index].revision != expected_revision) return error.RevisionConflict;
        try validGroupName(name);
        for (self.groups) |group| if (group.group_id != id and eq(group.name, name)) return error.DuplicateGroupName;
        const revision = try identity.advance(expected_revision);
        const owned_name = try self.arena.allocator().dupe(u8, name);
        const owned_color = try self.arena.allocator().dupe(u8, color);
        self.groups[index].name = owned_name;
        self.groups[index].color = owned_color;
        self.groups[index].collapsed = collapsed;
        self.groups[index].revision = revision;
        for (self.hosts) |*host| if (host.asset_group_id == id) {
            host.group = owned_name;
        };
        return revision;
    }
    pub fn removeEmptyGroup(self: *Registry, id: identity.AssetGroupId, expected_revision: u64) !void {
        const index = self.groupIndex(id) orelse return error.GroupNotFound;
        if (self.groups[index].revision != expected_revision) return error.RevisionConflict;
        for (self.hosts) |host| if (host.asset_group_id == id) return error.GroupNotEmpty;
        std.mem.copyForwards(AssetGroup, self.groups[index .. self.groups.len - 1], self.groups[index + 1 ..]);
        self.groups = self.groups[0 .. self.groups.len - 1];
    }
    fn removeFromGroupOrders(self: *Registry, id: identity.ConnectionId) void {
        for (self.groups) |*group| {
            const mutable = @constCast(group.ordered_connection_ids);
            var len: usize = 0;
            for (mutable) |item| if (item != id) {
                mutable[len] = item;
                len += 1;
            };
            group.ordered_connection_ids = mutable[0..len];
        }
    }
    /// Save is offline, but explicit references must already be resolvable.
    /// Loading and deletion may retain an orphan for display/repair/export.
    pub fn validateSaveReferences(self: *const Registry, host: HostConfig) !void {
        for (host.route, 0..) |id, i| {
            const hop = self.hosts[self.indexOf(id) orelse return error.MissingRouteReference];
            if (!eq(hop.protocolId(), "ssh")) return error.InvalidRouteProtocol;
            if (hop.payload_version != 1) return error.UnsupportedPayloadVersion;
            if (id == host.connection_id) return error.RouteCycle;
            for (host.route[0..i]) |previous_id| {
                const previous = self.hosts[self.indexOf(previous_id) orelse return error.MissingRouteReference];
                if (previous.port == hop.port and std.ascii.eqlIgnoreCase(std.mem.trimEnd(u8, previous.host, "."), std.mem.trimEnd(u8, hop.host, "."))) return error.RouteCycle;
            }
            if (host.isLegacy() and host.port == hop.port and std.ascii.eqlIgnoreCase(std.mem.trimEnd(u8, host.host, "."), std.mem.trimEnd(u8, hop.host, "."))) return error.RouteCycle;
        }
    }
    fn checkName(self: *const Registry, host: HostConfig, except: ?identity.ConnectionId) !void {
        for (self.hosts) |other| if (other.connection_id != except and eq(other.protocolId(), host.protocolId()) and other.asset_group_id == host.asset_group_id and eq(other.name, host.name)) return error.DuplicateConnectionName;
    }
};

pub fn digest(bytes: []const u8) Digest {
    var result: Digest = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &result, .{});
    return result;
}

const Seen = std.StringHashMapUnmanaged(void);
fn mark(seen: *Seen, allocator: std.mem.Allocator, key: []const u8) !void {
    const entry = try seen.getOrPut(allocator, key);
    if (entry.found_existing) return error.DuplicateKey;
}
fn eq(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}
fn validGroupName(value: []const u8) !void {
    if (trim(value).len == 0 or !std.unicode.utf8ValidateSlice(value) or std.mem.indexOfAny(u8, value, "\x00\r\n\t") != null) return error.InvalidGroup;
}
fn number(comptime T: type, text: []const u8) !T {
    if (text.len == 0) return error.InvalidValue;
    for (text) |byte| if (byte < '0' or byte > '9') return error.InvalidValue;
    return std.fmt.parseInt(T, text, 10) catch error.InvalidValue;
}
fn nonzero(text: []const u8) !u64 {
    const value = try number(u64, text);
    if (value == 0) return error.InvalidIdentity;
    return value;
}
fn parseIds(allocator: std.mem.Allocator, value: []const u8) ![]const identity.ConnectionId {
    if (value.len < 2 or value[0] != '[' or value[value.len - 1] != ']') return error.InvalidValue;
    var result: std.ArrayList(identity.ConnectionId) = .empty;
    var items: SplitIterator = .{ .text = trim(value[1 .. value.len - 1]), .delimiter = ',' };
    while (try items.next()) |item| try result.append(allocator, @fromBackingInt(try nonzero(item)));
    return result.toOwnedSlice(allocator);
}
fn writeIds(writer: *std.Io.Writer, values: []const identity.ConnectionId) !void {
    try writer.writeByte('[');
    for (values, 0..) |id, i| {
        if (i != 0) try writer.writeAll(", ");
        try writer.print("{d}", .{@backingInt(id)});
    }
    try writer.writeByte(']');
}
pub fn cloneConfig(allocator: std.mem.Allocator, source: HostConfig) !HostConfig {
    var result = source;
    const structure = @typeInfo(HostConfig).@"struct";
    inline for (structure.field_names, structure.field_types) |name, FieldType| {
        if (FieldType == []const u8) @field(result, name) = try allocator.dupe(u8, @field(source, name)) else if (FieldType == ?[]const u8) @field(result, name) = if (@field(source, name)) |value| try allocator.dupe(u8, value) else null else if (FieldType == []const []const u8) {
            const values = @field(source, name);
            const copied = try allocator.alloc([]const u8, values.len);
            for (values, copied) |value, *target| target.* = try allocator.dupe(u8, value);
            @field(result, name) = copied;
        } else if (FieldType == []const identity.ConnectionId) @field(result, name) = try allocator.dupe(identity.ConnectionId, @field(source, name));
    }
    return result;
}
const GroupBuilder = struct {
    group_id: ?identity.AssetGroupId = null,
    revision: u64 = 1,
    name: ?[]const u8 = null,
    color: []const u8 = "",
    collapsed: bool = false,
    ordered_connection_ids: []const identity.ConnectionId = &.{},
    unknown_fields: []const []const u8 = &.{},
    seen: Seen = .empty,
    fn apply(self: *GroupBuilder, allocator: std.mem.Allocator, key: []const u8, value: []const u8) !void {
        try mark(&self.seen, allocator, key);
        if (eq(key, "group_id")) self.group_id = @fromBackingInt(try nonzero(value)) else if (eq(key, "revision")) self.revision = try nonzero(value) else if (eq(key, "name")) self.name = try parseString(allocator, value) else if (eq(key, "color")) self.color = try parseString(allocator, value) else if (eq(key, "collapsed")) self.collapsed = try parseBool(value) else if (eq(key, "ordered_connection_ids")) self.ordered_connection_ids = try parseIds(allocator, value) else self.unknown_fields = try appendRaw(allocator, self.unknown_fields, key, value);
    }
    fn finish(self: GroupBuilder) !AssetGroup {
        return .{ .group_id = self.group_id orelse return error.InvalidIdentity, .revision = self.revision, .name = self.name orelse return error.InvalidGroup, .color = self.color, .collapsed = self.collapsed, .ordered_connection_ids = self.ordered_connection_ids, .unknown_fields = self.unknown_fields };
    }
};

const Builder = struct {
    connection_id: identity.ConnectionId = @fromBackingInt(0),
    revision: u64 = 1,
    protocol: Protocol = .ssh,
    /// Authoritative provider ID for records outside the legacy enum.
    protocol_id: ?[]const u8 = null,
    payload_version: u32 = 1,
    plugin_payload: ?[]const u8 = null,
    unknown_fields: []const []const u8 = &.{},
    unknown_options: []const []const u8 = &.{},
    unknown_auth: []const []const u8 = &.{},
    auth_mode: ?AuthMode = null,
    pinned: bool = false,
    strict_host_key_checking: bool = true,
    asset_group_id: ?identity.AssetGroupId = null,
    route: []const identity.ConnectionId = &.{},
    seen: Seen = .empty,
    strict_seen: bool = false,
    name: ?[]const u8 = null,
    host: ?[]const u8 = null,
    port: u16 = 22,
    user: ?[]const u8 = null,
    identity_file: ?[]const u8 = null,
    key_passphrase: ?[]const u8 = null,
    password: ?[]const u8 = null,
    totp_secret: ?[]const u8 = null,
    password_ref: ?[]const u8 = null,
    key_passphrase_ref: ?[]const u8 = null,
    totp_secret_ref: ?[]const u8 = null,
    jump_chain: []const []const u8 = &.{},
    startup_commands: []const []const u8 = &.{},
    group: ?[]const u8 = null,
    ts_default: bool = true,
    terminal_type: []const u8 = "xterm-256color",
    terminal_type_explicit: bool = false,
    scrollback: u32 = 50000,
    keepalive: bool = true,
    compression: bool = false,
    compression_explicit: bool = false,
    socks_enabled: bool = false,
    socks_port: u16 = 1080,
    socks_bind: []const u8 = "127.0.0.1",
    socks_exit: ?usize = null,
    socks_auto_start: bool = false,
    socks_max_connections: u16 = 64,

    fn apply(self: *Builder, allocator: std.mem.Allocator, key: []const u8, value: []const u8) !void {
        try mark(&self.seen, allocator, key);
        if (eq(key, "terminal_type")) self.terminal_type_explicit = true;
        if (eq(key, "compression")) self.compression_explicit = true;
        if (eq(key, "socks_max_connections")) {
            self.socks_max_connections = std.fmt.parseInt(u16, value, 10) catch return error.InvalidValue;
            return;
        }
        if (eq(key, "connection_id")) {
            self.connection_id = @fromBackingInt(try nonzero(value));
            return;
        }
        if (eq(key, "revision")) {
            self.revision = try nonzero(value);
            return;
        }
        if (eq(key, "protocol")) {
            if (self.seen.contains("plugin_id")) return error.ConflictingProtocol;
            const protocol = try parseString(allocator, value);
            if (eq(protocol, "ssh")) self.protocol = .ssh else if (eq(protocol, "sftp")) self.protocol = .sftp else self.protocol_id = protocol;
            return;
        }
        if (eq(key, "payload_version")) {
            self.payload_version = try number(u32, value);
            return;
        }
        if (eq(key, "payload")) {
            self.plugin_payload = try parseString(allocator, value);
            return;
        }
        if (eq(key, "plugin_id")) {
            const provider = try parseString(allocator, value);
            if (self.seen.contains("protocol")) return error.ConflictingProtocol;
            if (eq(provider, "ssh")) self.protocol = .ssh else if (eq(provider, "sftp")) self.protocol = .sftp else self.protocol_id = provider;
            return;
        }
        if (eq(key, "auth_mode")) {
            const mode = try parseString(allocator, value);
            self.auth_mode = if (eq(mode, "agent")) .agent else if (eq(mode, "private_key")) .private_key else if (eq(mode, "password")) .password else return error.InvalidValue;
            return;
        }
        if (eq(key, "pinned")) {
            self.pinned = try parseBool(value);
            return;
        }
        if (eq(key, "asset_group_id")) {
            self.asset_group_id = @fromBackingInt(try nonzero(value));
            return;
        }
        if (eq(key, "route")) {
            self.route = try parseIds(allocator, value);
            return;
        }
        if (eq(key, "strict_host_key_checking")) {
            if (self.strict_seen) return error.DuplicateKey;
            self.strict_seen = true;
            self.strict_host_key_checking = try parseBool(value);
            return;
        }
        if (eq(key, "options")) {
            if (value.len < 2 or value[0] != '{' or value[value.len - 1] != '}') return error.InvalidValue;
            var fields: SplitIterator = .{ .text = trim(value[1 .. value.len - 1]), .delimiter = ',' };
            while (try fields.next()) |field| {
                const split = findTopLevel(field, '=') orelse return error.InvalidAssignment;
                if (!eq(trim(field[0..split]), "strict_host_key")) {
                    self.unknown_options = try appendRaw(allocator, self.unknown_options, trim(field[0..split]), trim(field[split + 1 ..]));
                    continue;
                }
                if (self.strict_seen) return error.DuplicateKey;
                self.strict_seen = true;
                self.strict_host_key_checking = try parseBool(trim(field[split + 1 ..]));
            }
            return;
        }
        if (std.mem.eql(u8, key, "name")) self.name = try parseString(allocator, value) else if (std.mem.eql(u8, key, "host")) self.host = try parseString(allocator, value) else if (std.mem.eql(u8, key, "port")) self.port = std.fmt.parseInt(u16, value, 10) catch return error.InvalidValue else if (std.mem.eql(u8, key, "user")) self.user = try parseString(allocator, value) else if (std.mem.eql(u8, key, "auth")) try self.parseAuth(allocator, value) else if (std.mem.eql(u8, key, "totp_secret_ref")) self.totp_secret_ref = try parseString(allocator, value) else if (std.mem.eql(u8, key, "totp_secret")) self.totp_secret = try parseString(allocator, value) else if (std.mem.eql(u8, key, "jump_chain")) self.jump_chain = try parseStringArray(allocator, value) else if (std.mem.eql(u8, key, "startup_commands")) self.startup_commands = try parseStringArray(allocator, value) else if (std.mem.eql(u8, key, "group")) self.group = try parseString(allocator, value) else if (std.mem.eql(u8, key, "ts_default")) self.ts_default = try parseBool(value) else if (std.mem.eql(u8, key, "terminal_type")) self.terminal_type = try parseString(allocator, value) else if (std.mem.eql(u8, key, "socks_bind")) self.socks_bind = try parseString(allocator, value) else if (std.mem.eql(u8, key, "keepalive")) self.keepalive = try parseBool(value) else if (std.mem.eql(u8, key, "compression")) self.compression = try parseBool(value) else if (std.mem.eql(u8, key, "socks_enabled")) self.socks_enabled = try parseBool(value) else if (std.mem.eql(u8, key, "socks_auto_start")) self.socks_auto_start = try parseBool(value) else if (std.mem.eql(u8, key, "scrollback")) self.scrollback = std.fmt.parseInt(u32, value, 10) catch return error.InvalidValue else if (std.mem.eql(u8, key, "socks_port")) self.socks_port = std.fmt.parseInt(u16, value, 10) catch return error.InvalidValue else if (std.mem.eql(u8, key, "socks_exit")) self.socks_exit = std.fmt.parseInt(usize, value, 10) catch return error.InvalidValue else self.unknown_fields = try appendRaw(allocator, self.unknown_fields, key, value);
    }

    fn parseAuth(self: *Builder, allocator: std.mem.Allocator, value: []const u8) !void {
        if (value.len < 2 or value[0] != '{' or value[value.len - 1] != '}') return error.InvalidValue;
        var fields = SplitIterator{ .text = value[1 .. value.len - 1], .delimiter = ',' };
        var seen: Seen = .empty;
        while (try fields.next()) |field| {
            const separator = findTopLevel(field, '=') orelse return error.InvalidAssignment;
            const key = trim(field[0..separator]);
            try mark(&seen, allocator, key);
            const item = trim(field[separator + 1 ..]);
            if (std.mem.eql(u8, key, "key")) self.identity_file = try parseString(allocator, item) else if (std.mem.eql(u8, key, "passphrase")) self.key_passphrase = try parseString(allocator, item) else if (std.mem.eql(u8, key, "password")) self.password = try parseString(allocator, item) else if (eq(key, "password_ref")) self.password_ref = try parseString(allocator, item) else if (eq(key, "passphrase_ref")) self.key_passphrase_ref = try parseString(allocator, item) else self.unknown_auth = try appendRaw(allocator, self.unknown_auth, key, item);
        }
    }

    fn finish(self: Builder) !HostConfig {
        const inferred: AuthMode = if (self.identity_file != null) .private_key else if (self.password != null or self.password_ref != null) .password else .agent;
        if (self.auth_mode) |mode| if ((self.identity_file != null or self.password != null or self.password_ref != null) and mode != inferred) return error.AmbiguousCredential;
        if (self.route.len != 0 and self.jump_chain.len != 0) return error.ConflictingRoute;
        if (self.group != null and self.asset_group_id != null) return error.ConflictingGroup;
        const result: HostConfig = .{ .connection_id = self.connection_id, .revision = self.revision, .protocol = self.protocol, .protocol_id = self.protocol_id, .payload_version = self.payload_version, .plugin_payload = self.plugin_payload, .unknown_fields = self.unknown_fields, .unknown_options = self.unknown_options, .unknown_auth = self.unknown_auth, .auth_mode = self.auth_mode orelse inferred, .pinned = self.pinned, .strict_host_key_checking = self.strict_host_key_checking, .asset_group_id = self.asset_group_id, .route = self.route, .name = self.name orelse return error.MissingName, .host = self.host orelse if (self.protocol_id != null or self.payload_version > 1) "" else return error.MissingHost, .port = self.port, .user = self.user orelse if (self.protocol_id != null or self.payload_version > 1) "" else return error.MissingUser, .identity_file = self.identity_file, .key_passphrase = self.key_passphrase, .password = self.password, .totp_secret = self.totp_secret, .password_ref = self.password_ref, .key_passphrase_ref = self.key_passphrase_ref, .totp_secret_ref = self.totp_secret_ref, .jump_chain = self.jump_chain, .startup_commands = self.startup_commands, .group = self.group, .ts_default = self.ts_default, .terminal_type = self.terminal_type, .terminal_type_explicit = self.terminal_type_explicit, .scrollback = self.scrollback, .keepalive = self.keepalive, .compression = self.compression, .compression_explicit = self.compression_explicit, .socks_enabled = self.socks_enabled, .socks_port = self.socks_port, .socks_bind = self.socks_bind, .socks_exit = self.socks_exit, .socks_auto_start = self.socks_auto_start, .socks_max_connections = self.socks_max_connections };
        try result.validate();
        return result;
    }
};

pub const ValidationError = error{ MissingName, MissingHost, MissingUser, InvalidPort, TooManyJumps, AmbiguousCredential, PassphraseWithoutKey, InvalidValue, InvalidSocksExit, InvalidRevision, InvalidTotpSeed };

test "SOCKS max connections defaults for old hosts and survives clone save reload" {
    var old = try Registry.parse(std.testing.allocator, "[[hosts]]\nname=\"old\"\nhost=\"old.test\"\nuser=\"root\"\n");
    defer old.deinit();
    try std.testing.expectEqual(@as(u16, 64), old.hosts[0].socks_max_connections);
    var configured = try Registry.parse(std.testing.allocator, "[[hosts]]\nname=\"configured\"\nhost=\"configured.test\"\nuser=\"root\"\nsocks_max_connections=17\n");
    defer configured.deinit();
    var cloned = try configured.clone(std.testing.allocator);
    defer cloned.deinit();
    try std.testing.expectEqual(@as(u16, 17), cloned.hosts[0].socks_max_connections);
    const text = try cloned.encode(std.testing.allocator);
    defer std.testing.allocator.free(text);
    var reloaded = try Registry.parse(std.testing.allocator, text);
    defer reloaded.deinit();
    try std.testing.expectEqual(@as(u16, 17), reloaded.hosts[0].socks_max_connections);
    try std.testing.expectEqualStrings("configured.test", reloaded.hosts[0].host);
}

test "SOCKS max connections rejects zero overflow duplicate and unrelated unknown keys" {
    try std.testing.expectError(error.InvalidValue, Registry.parse(std.testing.allocator, "[[hosts]] name=\"n\";host=\"h\";user=\"u\";socks_max_connections=0"));
    try std.testing.expectError(error.InvalidValue, Registry.parse(std.testing.allocator, "[[hosts]] name=\"n\";host=\"h\";user=\"u\";socks_max_connections=65536"));
    try std.testing.expectError(error.DuplicateKey, Registry.parse(std.testing.allocator, "[[hosts]] name=\"n\";host=\"h\";user=\"u\";socks_max_connections=2;socks_max_connections=3"));
    var future = try Registry.parse(std.testing.allocator, "[[hosts]] name=\"n\";host=\"h\";user=\"u\";socks_unknown_option=3");
    defer future.deinit();
    try std.testing.expectEqual(@as(usize, 1), future.hosts[0].unknown_fields.len);
}

const StatementIterator = struct {
    text: []const u8,
    index: usize = 0,

    fn next(self: *StatementIterator) !?[]const u8 {
        while (self.index < self.text.len) {
            while (self.index < self.text.len and (self.text[self.index] == ' ' or self.text[self.index] == '\t' or self.text[self.index] == '\r' or self.text[self.index] == '\n' or self.text[self.index] == ';')) self.index += 1;
            if (self.index == self.text.len) return null;
            if (self.text[self.index] == '#') {
                while (self.index < self.text.len and self.text[self.index] != '\n') self.index += 1;
                continue;
            }
            const start = self.index;
            var quote = false;
            var escape = false;
            var depth: usize = 0;
            while (self.index < self.text.len) : (self.index += 1) {
                const char = self.text[self.index];
                if (quote) {
                    if (escape) escape = false else if (char == '\\') escape = true else if (char == '"') quote = false;
                    continue;
                }
                if (char == '"') quote = true else if (char == '[' or char == '{') depth += 1 else if (char == ']' or char == '}') {
                    if (depth == 0) return error.UnbalancedDelimiter;
                    depth -= 1;
                } else if (depth == 0 and (char == ';' or char == '\n' or char == '#')) break;
            }
            if (quote or depth != 0) return error.UnbalancedDelimiter;
            const statement = trim(self.text[start..self.index]);
            if (self.index < self.text.len and self.text[self.index] == '#') {
                while (self.index < self.text.len and self.text[self.index] != '\n') self.index += 1;
            }
            if (statement.len != 0) return statement;
        }
        return null;
    }
};

const SplitIterator = struct {
    text: []const u8,
    delimiter: u8,
    index: usize = 0,
    fn next(self: *SplitIterator) !?[]const u8 {
        if (self.index >= self.text.len) return null;
        const start = self.index;
        var quote = false;
        var escape = false;
        var depth: usize = 0;
        while (self.index < self.text.len) : (self.index += 1) {
            const char = self.text[self.index];
            if (quote) {
                if (escape) escape = false else if (char == '\\') escape = true else if (char == '"') quote = false;
            } else if (char == '"') quote = true else if (char == '[' or char == '{' or char == '(') depth += 1 else if (char == ']' or char == '}' or char == ')') {
                if (depth == 0) return error.UnbalancedDelimiter;
                depth -= 1;
            } else if (char == self.delimiter and depth == 0) {
                const part = trim(self.text[start..self.index]);
                self.index += 1;
                return part;
            }
        }
        if (quote or depth != 0) return error.UnbalancedDelimiter;
        return trim(self.text[start..]);
    }
};

fn parseString(allocator: std.mem.Allocator, value: []const u8) ![]const u8 {
    if (value.len < 2 or value[0] != '"' or value[value.len - 1] != '"') return error.InvalidValue;
    var result: std.ArrayList(u8) = .empty;
    var i: usize = 1;
    while (i < value.len - 1) : (i += 1) {
        if (value[i] != '\\') {
            try result.append(allocator, value[i]);
            continue;
        }
        i += 1;
        if (i >= value.len - 1) return error.InvalidEscape;
        try result.append(allocator, switch (value[i]) {
            '"' => '"',
            '\\' => '\\',
            'n' => '\n',
            'r' => '\r',
            't' => '\t',
            else => return error.InvalidEscape,
        });
    }
    return result.toOwnedSlice(allocator);
}
fn parseStringArray(allocator: std.mem.Allocator, value: []const u8) ![]const []const u8 {
    if (value.len < 2 or value[0] != '[' or value[value.len - 1] != ']') return error.InvalidValue;
    var result: std.ArrayList([]const u8) = .empty;
    const inner = trim(value[1 .. value.len - 1]);
    if (inner.len == 0) return result.toOwnedSlice(allocator);
    var items = SplitIterator{ .text = inner, .delimiter = ',' };
    while (try items.next()) |item| try result.append(allocator, try parseString(allocator, item));
    return result.toOwnedSlice(allocator);
}
fn parseBool(value: []const u8) !bool {
    if (std.mem.eql(u8, value, "true")) return true;
    if (std.mem.eql(u8, value, "false")) return false;
    return error.InvalidValue;
}
fn writeString(writer: *std.Io.Writer, value: []const u8) std.Io.Writer.Error!void {
    try writer.writeByte('"');
    for (value) |char| switch (char) {
        '"' => try writer.writeAll("\\\""),
        '\\' => try writer.writeAll("\\\\"),
        '\n' => try writer.writeAll("\\n"),
        '\r' => try writer.writeAll("\\r"),
        '\t' => try writer.writeAll("\\t"),
        else => try writer.writeByte(char),
    };
    try writer.writeByte('"');
}
fn writeStringArray(writer: *std.Io.Writer, values: []const []const u8) std.Io.Writer.Error!void {
    try writer.writeByte('[');
    for (values, 0..) |value, i| {
        if (i != 0) try writer.writeAll(", ");
        try writeString(writer, value);
    }
    try writer.writeByte(']');
}
fn findTopLevel(value: []const u8, needle: u8) ?usize {
    var quote = false;
    var escape = false;
    for (value, 0..) |char, i| {
        if (quote) {
            if (escape) escape = false else if (char == '\\') escape = true else if (char == '"') quote = false;
        } else if (char == '"') quote = true else if (char == needle) return i;
    }
    return null;
}
fn trim(value: []const u8) []const u8 {
    return std.mem.trim(u8, value, " \t\r\n");
}

test "registry parses documented hosts and round trips escapes" {
    const source = "[[hosts]] name = \"K8s-Node01\"; host = \"10.200.1.18\"; port = 22; user = \"ubuntu\"\nauth = { key = \"~/.ssh/id_ed25519\", passphrase = \"p#ass\" }\njump_chain = [\"bastion-01\"]; group = \"Production\"; totp_secret = \"JBSWY3DPEHPK3PXP\"\nstartup_commands = [\"cd /opt/deploy\", \"echo \\\"ok\\\"\"]\n";
    var registry = try Registry.parse(std.testing.allocator, source ++ "\n[[hosts]] name=\"bastion-01\";host=\"jump.test\";user=\"ops\"\n");
    defer registry.deinit();
    try std.testing.expectEqual(@as(usize, 2), registry.hosts.len);
    try std.testing.expectEqualStrings("p#ass", registry.hosts[0].key_passphrase.?);
    var buffer: [2048]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    try registry.format(&writer);
    var reparsed = try Registry.parse(std.testing.allocator, writer.buffered());
    defer reparsed.deinit();
    try std.testing.expectEqualStrings("echo \"ok\"", reparsed.hosts[0].startup_commands[1]);
}

test "registry rejects incomplete ambiguous and excessive hosts" {
    try std.testing.expectError(error.MissingUser, Registry.parse(std.testing.allocator, "[[hosts]]; name=\"n\"; host=\"h\""));
    try std.testing.expectError(error.AmbiguousCredential, Registry.parse(std.testing.allocator, "[[hosts]]; name=\"n\"; host=\"h\"; user=\"u\"; auth={key=\"k\",password=\"p\"}"));
    try std.testing.expectError(error.TooManyJumps, Registry.parse(std.testing.allocator, "[[hosts]]; name=\"n\"; host=\"h\"; user=\"u\"; jump_chain=[\"1\",\"2\",\"3\",\"4\",\"5\",\"6\",\"7\",\"8\",\"9\"]"));
}

test "clone name follows the specified suffix" {
    const host: HostConfig = .{ .name = "node", .host = "example.test", .user = "root" };
    var buffer: [64]u8 = undefined;
    try std.testing.expectEqualStrings("node-副本", try host.cloneName(&buffer));
}

test "wizard host options persist through registry serialization and snapshot" {
    const text = "[[hosts]]\nname=\"n\"\nhost=\"h\"\nuser=\"u\"\nterminal_type=\"vt100\"\nscrollback=1234\nkeepalive=false\ncompression=true\nsocks_enabled=true\nsocks_port=9090\nsocks_bind=\"0.0.0.0\"\nsocks_exit=0\nsocks_auto_start=true\njump_chain=[\"jump\"]\n";
    var registry = try Registry.parse(std.testing.allocator, text ++ "\n[[hosts]] name=\"jump\";host=\"jump.test\";user=\"ops\"\n");
    defer registry.deinit();
    var buffer: [4096]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    try registry.format(&writer);
    var read = try Registry.parse(std.testing.allocator, writer.buffered());
    defer read.deinit();
    const host = read.hosts[0];
    try std.testing.expectEqualStrings("vt100", host.terminal_type);
    try std.testing.expectEqual(@as(u32, 1234), host.scrollback);
    try std.testing.expect(!host.keepalive and host.compression and host.socks_enabled and host.socks_auto_start);
    try std.testing.expectEqual(@as(u16, 9090), host.socks_port);
    try std.testing.expectEqualStrings("0.0.0.0", host.socks_bind);
    try std.testing.expectEqual(@as(?usize, 0), host.socks_exit);
    var snapshot = try @import("../ui/session_lifecycle.zig").Snapshot(HostConfig).init(std.testing.allocator, host);
    defer snapshot.deinit();
    try std.testing.expect(snapshot.value.terminal_type.ptr != host.terminal_type.ptr);
    try std.testing.expect(snapshot.value.socks_bind.ptr != host.socks_bind.ptr);
}

test "invalid wizard SOCKS exit and terminal settings fail registry parsing" {
    try std.testing.expectError(error.InvalidSocksExit, Registry.parse(std.testing.allocator, "[[hosts]] name=\"n\";host=\"h\";user=\"u\";socks_exit=0"));
    try std.testing.expectError(error.InvalidValue, Registry.parse(std.testing.allocator, "[[hosts]] name=\"n\";host=\"h\";user=\"u\";terminal_type=\"\""));
}

test "SSH host inheritance survives clone encode reload with explicit defaults preserved" {
    var registry = try Registry.parse(std.testing.allocator, "[[hosts]] name=\"inherited\";host=\"h\";user=\"u\"\n" ++
        "[[hosts]] name=\"explicit\";host=\"h\";user=\"u\";terminal_type=\"xterm-256color\";compression=false\n" ++
        "[[hosts]] name=\"custom\";host=\"h\";user=\"u\";terminal_type=\"ansi\";compression=true\n");
    defer registry.deinit();
    var cloned = try registry.clone(std.testing.allocator);
    defer cloned.deinit();
    const encoded = try cloned.encode(std.testing.allocator);
    defer std.testing.allocator.free(encoded);
    var reloaded = try Registry.parse(std.testing.allocator, encoded);
    defer reloaded.deinit();
    try std.testing.expect(!reloaded.hosts[0].terminal_type_explicit);
    try std.testing.expect(!reloaded.hosts[0].compression_explicit);
    try std.testing.expect(reloaded.hosts[1].terminal_type_explicit);
    try std.testing.expect(reloaded.hosts[1].compression_explicit);
    try std.testing.expectEqualStrings("xterm-256color", reloaded.hosts[1].terminal_type);
    try std.testing.expect(!reloaded.hosts[1].compression);
    try std.testing.expect(reloaded.hosts[2].terminal_type_explicit);
    try std.testing.expect(reloaded.hosts[2].compression_explicit);
    try std.testing.expectEqualStrings("ansi", reloaded.hosts[2].terminal_type);
    try std.testing.expect(reloaded.hosts[2].compression);
}

fn appendRaw(allocator: std.mem.Allocator, old: []const []const u8, key: []const u8, value: []const u8) ![]const []const u8 {
    const next = try allocator.alloc([]const u8, old.len + 1);
    @memcpy(next[0..old.len], old);
    next[old.len] = try std.fmt.allocPrint(allocator, "{s} = {s}", .{ key, value });
    return next;
}
fn cloneStrings(allocator: std.mem.Allocator, old: []const []const u8) ![]const []const u8 {
    const next = try allocator.alloc([]const u8, old.len);
    for (old, next) |item, *target| target.* = try allocator.dupe(u8, item);
    return next;
}

test "unknown provider, future payload and unknown fields survive clone and canonical round trip" {
    const source =
        "[registry]\nschema_version=2\nrevision=1\nfuture_meta={ a = 1 }\n" ++
        "[[groups]]\ngroup_id=1\nname=\"g\"\nfuture_group=\"kept\"\n" ++
        "[[hosts]]\nconnection_id=1\nname=\"future\"\nprotocol=\"future.protocol\"\npayload_version=6\npayload=\"opaque bytes\"\nasset_group_id=1\nfuture_host=[1,2]\noptions={strict_host_key=true, future_option=7}\nauth={future_reference=\"opaque-ref\"}\n" ++
        "[[hosts]]\nconnection_id=2\nname=\"newer ssh\"\nprotocol=\"ssh\"\npayload_version=8\npayload=\"new shape\"\n";
    var first = try Registry.parse(std.testing.allocator, source);
    defer first.deinit();
    const encoded = try first.encode(std.testing.allocator);
    defer std.testing.allocator.free(encoded);
    var second = try Registry.parse(std.testing.allocator, encoded);
    defer second.deinit();
    try std.testing.expectEqualStrings("future.protocol", second.hosts[0].protocolId());
    try std.testing.expectEqual(@as(u32, 6), second.hosts[0].payload_version);
    try std.testing.expectEqualStrings("opaque bytes", second.hosts[0].plugin_payload.?);
    try std.testing.expectEqualStrings("future_host = [1,2]", second.hosts[0].unknown_fields[0]);
    try std.testing.expectEqualStrings("future_option = 7", second.hosts[0].unknown_options[0]);
    try std.testing.expectEqualStrings("future_reference = \"opaque-ref\"", second.hosts[0].unknown_auth[0]);
    try std.testing.expectEqualStrings("future_group = \"kept\"", second.groups[0].unknown_fields[0]);
    try std.testing.expectEqualStrings("future_meta = { a = 1 }", second.unknown_fields[0]);
    try std.testing.expectError(error.UnsupportedProtocol, second.resolveRoute(second.hosts[0].owner(), std.testing.allocator));
    try std.testing.expectError(error.UnsupportedProtocol, second.resolveRoute(second.hosts[1].owner(), std.testing.allocator));
}
