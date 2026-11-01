//! Owned editor draft. Only snapshot() crosses the persistence boundary; the
//! password remains in a separate, zeroed allocation and never enters JSON.
const std = @import("std");
const identity = @import("../../host/identity.zig");
const envelopes = @import("../../config/connection_envelope.zig");
const configs_mod = @import("../../host/connection_config_resolver.zig");
const probes = @import("../../host/probe_contract.zig");
const model = @import("model.zig");

pub const TextField = enum { name, host, username };

/// Zenit's current Select accepts 64 options. Search the complete saved SSH
/// inventory before applying that bound and always retain the row's selection.
pub fn visibleSshAssets(configs: configs_mod.Resolver, filter: []const u8, selected: ?identity.ConnectionId, allocator: std.mem.Allocator) ![]identity.ConnectionId {
    var result: std.ArrayList(identity.ConnectionId) = .empty;
    errdefer result.deinit(allocator);
    if (selected) |id| if (configs.registry.indexOf(id)) |index| {
        if (std.mem.eql(u8, configs.registry.hosts[index].protocolId(), "ssh")) try result.append(allocator, id);
    };
    for (configs.registry.hosts) |host| {
        if (!std.mem.eql(u8, host.protocolId(), "ssh") or selected == host.connection_id) continue;
        if (filter.len != 0 and std.ascii.findIgnoreCase(host.name, filter) == null and std.ascii.findIgnoreCase(host.host, filter) == null) continue;
        if (result.items.len == 64) break;
        try result.append(allocator, host.connection_id);
    }
    return result.toOwnedSlice(allocator);
}

pub const Editor = struct {
    allocator: std.mem.Allocator,
    asset_id: identity.ConnectionId = @fromBackingInt(0),
    asset_revision: u64 = 1,
    revision: u64 = 1,
    name: []u8 = &.{},
    host: []u8 = &.{},
    username: []u8 = &.{},
    https_port: u16 = 443,
    group_id: ?identity.AssetGroupId = null,
    credential_ref: ?[]u8 = null,
    password: []u8 = &.{},
    save_password: bool = true,
    routed: bool = false,
    route: [8]model.Hop = undefined,
    route_count: usize = 0,
    scale: model.Scale = .fit,
    read_only_requested: bool = false,

    pub fn init(allocator: std.mem.Allocator, revision: u64) Editor {
        return .{ .allocator = allocator, .revision = revision };
    }
    pub fn deinit(self: *Editor) void {
        self.clearSecrets();
        inline for (.{ self.name, self.host, self.username }) |text| if (text.len != 0) self.allocator.free(text);
        if (self.credential_ref) |reference| self.allocator.free(reference);
        self.name = &.{};
        self.host = &.{};
        self.username = &.{};
        self.credential_ref = null;
    }
    pub fn load(self: *Editor, initial: envelopes.Envelope) !void {
        try initial.validate();
        if (!std.mem.eql(u8, initial.protocol_id, model.protocol_id)) return error.ProtocolMismatch;
        if (initial.payload_version != model.payload_version) return error.UnsupportedPayloadVersion;
        var parsed = try model.parse(self.allocator, initial.payload);
        defer parsed.deinit();
        const value = parsed.value();
        try self.replace(&self.name, initial.name);
        try self.replace(&self.host, value.endpoint.host);
        try self.replace(&self.username, value.username);
        const reference = if (value.credential_ref) |ref| try self.allocator.dupe(u8, ref) else null;
        if (self.credential_ref) |old| self.allocator.free(old);
        self.credential_ref = reference;
        self.asset_id = initial.id;
        self.asset_revision = initial.revision;
        self.group_id = initial.group_id;
        self.https_port = value.endpoint.https_port;
        self.scale = value.display.scale;
        self.read_only_requested = value.display.read_only_requested;
        self.routed = value.access == .ssh_route;
        self.route_count = 0;
        if (value.access == .ssh_route) {
            const hops = value.access.ssh_route.hops;
            @memcpy(self.route[0..hops.len], hops);
            self.route_count = hops.len;
        }
        self.clearSecrets();
    }
    fn replace(self: *Editor, target: *[]u8, text: []const u8) !void {
        const owned: []u8 = if (text.len == 0) &.{} else try self.allocator.dupe(u8, text);
        if (target.len != 0) self.allocator.free(target.*);
        target.* = owned;
    }
    fn nextRevision(self: *const Editor) !u64 {
        return identity.advance(self.revision);
    }
    pub fn setText(self: *Editor, field: TextField, text: []const u8) !void {
        const target = switch (field) {
            .name => &self.name,
            .host => &self.host,
            .username => &self.username,
        };
        if (std.mem.eql(u8, target.*, text)) return;
        const revision = try self.nextRevision();
        try self.replace(target, text);
        self.revision = revision;
    }
    pub fn setPort(self: *Editor, value: u16) !void {
        if (self.https_port == value) return;
        const revision = try self.nextRevision();
        self.https_port = value;
        self.revision = revision;
    }
    pub fn setGroup(self: *Editor, value: ?identity.AssetGroupId) !void {
        if (self.group_id == value) return;
        const revision = try self.nextRevision();
        self.group_id = value;
        self.revision = revision;
    }
    pub fn setPassword(self: *Editor, value: []const u8) !void {
        if (std.mem.eql(u8, self.password, value)) return;
        const revision = try self.nextRevision();
        const owned: []u8 = if (value.len == 0) &.{} else try self.allocator.dupe(u8, value);
        self.clearSecrets();
        self.password = owned;
        self.revision = revision;
    }
    pub fn clearSecrets(self: *Editor) void {
        if (self.password.len != 0) {
            std.crypto.secureZero(u8, self.password);
            self.allocator.rawFree(self.password, .of(u8), @returnAddress());
        }
        self.password = &.{};
    }
    pub fn setSavePassword(self: *Editor, value: bool) !void {
        if (self.save_password == value) return;
        const revision = try self.nextRevision();
        self.save_password = value;
        self.revision = revision;
    }
    pub fn setAccess(self: *Editor, routed: bool) !void {
        if (self.routed == routed) return;
        const revision = try self.nextRevision();
        self.routed = routed;
        self.revision = revision;
    }
    pub fn setScale(self: *Editor, value: model.Scale) !void {
        if (self.scale == value) return;
        const revision = try self.nextRevision();
        self.scale = value;
        self.revision = revision;
    }
    pub fn setReadOnly(self: *Editor, value: bool) !void {
        if (self.read_only_requested == value) return;
        const revision = try self.nextRevision();
        self.read_only_requested = value;
        self.revision = revision;
    }
    pub fn containsHop(self: *const Editor, id: u64, except: ?usize) bool {
        for (self.route[0..self.route_count], 0..) |hop, i| if (hop.asset_id == id and except != i) return true;
        return false;
    }
    pub fn addHop(self: *Editor, id: identity.ConnectionId) !void {
        if (self.route_count == self.route.len) return error.TooManyJumps;
        const value = @backingInt(id);
        if (value == 0) return error.InvalidSshReference;
        if (self.containsHop(value, null)) return error.DuplicateRoute;
        const revision = try self.nextRevision();
        self.route[self.route_count] = .{ .asset_id = value };
        self.route_count += 1;
        self.routed = true;
        self.revision = revision;
    }
    pub fn replaceHop(self: *Editor, index: usize, id: identity.ConnectionId) !void {
        if (index >= self.route_count) return error.InvalidRouteIndex;
        const value = @backingInt(id);
        if (value == 0) return error.InvalidSshReference;
        if (self.containsHop(value, index)) return error.DuplicateRoute;
        if (self.route[index].asset_id == value) return;
        const revision = try self.nextRevision();
        self.route[index] = .{ .asset_id = value };
        self.revision = revision;
    }
    pub fn removeHop(self: *Editor, index: usize) !void {
        if (index >= self.route_count) return error.InvalidRouteIndex;
        const revision = try self.nextRevision();
        std.mem.copyForwards(model.Hop, self.route[index .. self.route_count - 1], self.route[index + 1 .. self.route_count]);
        self.route_count -= 1;
        self.revision = revision;
    }
    pub fn moveHop(self: *Editor, index: usize, up: bool) !void {
        if (index >= self.route_count or (up and index == 0) or (!up and index + 1 >= self.route_count)) return error.InvalidRouteIndex;
        const revision = try self.nextRevision();
        const destination = if (up) index - 1 else index + 1;
        std.mem.swap(model.Hop, &self.route[index], &self.route[destination]);
        self.revision = revision;
    }
    /// Child replies carry only an asset identity; never copy the SSH draft or
    /// its nested route into the BMC payload.
    pub fn applyChild(self: *Editor, parent_revision: u64, id: identity.ConnectionId, configs: configs_mod.Resolver) !bool {
        if (parent_revision != self.revision) return false;
        var resolved = try configs.resolve(id, "ssh", self.allocator);
        defer resolved.deinit();
        try self.addHop(id);
        return true;
    }
    pub fn payload(self: *const Editor, reference: ?[]const u8) model.Payload {
        return .{
            .endpoint = .{ .host = std.mem.trim(u8, self.host, " \t\r\n"), .https_port = self.https_port },
            .username = std.mem.trim(u8, self.username, " \t"),
            .credential_ref = reference,
            .access = if (self.routed) .{ .ssh_route = .{ .hops = self.route[0..self.route_count] } } else .direct,
            .display = .{ .scale = self.scale, .read_only_requested = self.read_only_requested },
        };
    }
    pub fn validateOffline(self: *const Editor, configs: ?configs_mod.Resolver, allocator: std.mem.Allocator) !void {
        return self.validateInputs(configs, allocator, true);
    }
    pub fn validateRuntime(self: *const Editor, configs: ?configs_mod.Resolver, allocator: std.mem.Allocator) !void {
        return self.validateInputs(configs, allocator, false);
    }
    fn validateInputs(self: *const Editor, configs: ?configs_mod.Resolver, allocator: std.mem.Allocator, require_name: bool) !void {
        const value = self.payload(if (self.save_password) self.credential_ref else null);
        try model.validate(value);
        if (self.revision == 0 or self.asset_revision == 0) return error.InvalidIdentity;
        if (require_name and std.mem.trim(u8, self.name, " \t\r\n").len == 0) return error.MissingName;
        if (self.group_id) |id| {
            if (@backingInt(id) == 0) return error.InvalidGroup;
            if (configs) |resolver| if (resolver.registry.groupIndex(id) == null) return error.GroupNotFound;
        }
        if (self.routed) {
            var frozen = try model.freezeRoute(value, configs orelse return error.ConfigurationResolverUnavailable, allocator);
            defer frozen.deinit();
        }
    }
    /// The reference may be a staged opaque Keychain ref. Callers must retain
    /// its transaction until the host's atomic asset submission succeeds.
    pub fn snapshotWithReference(self: *const Editor, allocator: std.mem.Allocator, reference: ?[]const u8) !envelopes.Envelope {
        return self.makeEnvelope(allocator, reference, std.mem.trim(u8, self.name, " \t\r\n"), self.asset_id);
    }
    /// A probe/temporary display name is derived only for this submission. The
    /// saved draft and its identity remain unchanged, even when editing an asset.
    pub fn snapshotRuntime(self: *const Editor, allocator: std.mem.Allocator, reference: ?[]const u8) !envelopes.Envelope {
        const name = std.mem.trim(u8, self.name, " \t\r\n");
        return self.makeEnvelope(allocator, reference, if (name.len == 0) std.mem.trim(u8, self.host, " \t\r\n") else name, @fromBackingInt(0));
    }
    fn makeEnvelope(self: *const Editor, allocator: std.mem.Allocator, reference: ?[]const u8, name: []const u8, asset_id: identity.ConnectionId) !envelopes.Envelope {
        const value = self.payload(reference);
        try model.validate(value);
        if (name.len == 0) return error.MissingName;
        if (!std.unicode.utf8ValidateSlice(name) or std.mem.indexOfAny(u8, name, "\x00\r\n") != null) return error.InvalidEnvelope;
        const protocol = try allocator.dupe(u8, model.protocol_id);
        errdefer allocator.free(protocol);
        const owned_name = try allocator.dupe(u8, name);
        errdefer allocator.free(owned_name);
        const payload_json = try std.json.Stringify.valueAlloc(allocator, value, .{});
        errdefer allocator.free(payload_json);
        const result: envelopes.Envelope = .{
            .id = asset_id,
            .revision = self.asset_revision,
            .protocol_id = protocol,
            .payload_version = model.payload_version,
            .name = owned_name,
            .group_id = self.group_id,
            .payload = payload_json,
        };
        try result.validate();
        return result;
    }
    pub fn snapshot(self: *const Editor, allocator: std.mem.Allocator) !envelopes.Envelope {
        return self.snapshotWithReference(allocator, if (self.save_password) self.credential_ref else null);
    }
};

/// Tracks a real host probe token. A result is publishable only for the same
/// draft and after the host confirms that all probe resources were released.
pub const ProbeState = struct {
    token: ?probes.ProbeToken = null,
    outcome: ?probes.Outcome = null,
    cancelled: bool = false,
    stale: bool = false,
    pub fn begin(self: *ProbeState, token: probes.ProbeToken) !void {
        if (self.token != null) return error.ProbeInProgress;
        self.* = .{ .token = token };
    }
    pub fn invalidate(self: *ProbeState) void {
        if (self.token != null) self.stale = true;
        self.outcome = null;
    }
    pub fn cancel(self: *ProbeState) void {
        self.cancelled = true;
        self.outcome = null;
    }
    pub fn apply(self: *ProbeState, snapshot: probes.ProbeSnapshot, revision: u64) bool {
        const token = self.token orelse return false;
        if (!token.eql(snapshot.token)) return false;
        const current = !self.stale and !self.cancelled and snapshot.applies_to_draft and token.draft_revision == revision;
        if (snapshot.complete and snapshot.cleanup == .released) {
            self.token = null;
            self.outcome = if (current) snapshot.outcome else null;
        }
        return current;
    }
};

/// One editor attempt's bounded, memory-only diagnostic history. Only known
/// static phase labels and numeric timing are retained; provider text, device
/// identity and credentials are never kept in the log. The main thread calls
/// observe while its owned host snapshot is alive.
pub const ProbeLog = struct {
    pub const capacity = 32;
    const progress = @import("connection_progress.zig");
    pub const Detail = union(enum) {
        phase: progress.Stage,
        host_stage: probes.Stage,
        route: u8,
        cancel_requested,
        draft_changed,
        status_unavailable,
        cleanup_unknown,
        result: probes.Outcome,
        old_draft_released,
    };
    pub const Entry = struct { elapsed_seconds: u64 = 0, detail: Detail = .{ .host_stage = .accepted } };
    token: ?probes.ProbeToken = null,
    attempt: u64 = 0,
    revision: u64 = 0,
    entries: [capacity]Entry = @splat(.{}),
    count: usize = 0,
    elapsed_seconds: u64 = 0,
    stale: bool = false,
    cancelled: bool = false,
    complete: bool = false,
    outcome: ?probes.Outcome = null,
    last_detail: ?Detail = null,
    last_cleanup: ?probes.CloseReceipt = null,

    pub fn begin(self: *ProbeLog, owner: probes.ProbeToken) void {
        const attempt = self.attempt +| 1;
        const revision = self.revision +| 1;
        self.* = .{ .token = owner, .attempt = attempt, .revision = revision };
        self.append(.{ .host_stage = .accepted });
    }
    pub fn invalidate(self: *ProbeLog, draft_revision: u64) void {
        const owner = self.token orelse return;
        if (self.stale or owner.draft_revision == draft_revision) return;
        self.stale = true;
        self.append(.draft_changed);
    }
    pub fn cancel(self: *ProbeLog) void {
        if (self.token == null or self.complete or self.cancelled) return;
        self.cancelled = true;
        self.append(.cancel_requested);
    }
    pub fn unavailable(self: *ProbeLog) void {
        if (self.token != null and !self.complete) self.append(.status_unavailable);
    }
    pub fn observe(self: *ProbeLog, snapshot: probes.ProbeSnapshot) void {
        const owner = self.token orelse return;
        if (!owner.eql(snapshot.token) or self.complete) return;
        if (totalSeconds(snapshot.safe_message)) |seconds| self.elapsed_seconds = seconds;
        if (!snapshot.applies_to_draft and !self.stale) {
            self.stale = true;
            self.append(.draft_changed);
        }
        if (snapshot.complete and snapshot.cleanup == .released) {
            self.complete = true;
            self.outcome = if (self.stale) null else if (self.cancelled) .cancelled else snapshot.outcome orelse .failed;
            if (self.stale) self.append(.old_draft_released) else self.append(.{ .result = self.outcome.? });
            return;
        }
        const current_detail = detail(snapshot);
        if (self.last_detail == null or !std.meta.eql(self.last_detail.?, current_detail)) self.append(current_detail);
        self.last_detail = current_detail;
        if (snapshot.cleanup == .unknown and self.last_cleanup != .unknown) self.append(.cleanup_unknown);
        self.last_cleanup = snapshot.cleanup;
    }
    fn append(self: *ProbeLog, value: Detail) void {
        if (self.count != 0 and std.meta.eql(self.entries[self.count - 1].detail, value)) return;
        if (self.count == capacity) {
            std.mem.copyForwards(Entry, self.entries[0 .. capacity - 1], self.entries[1..]);
            self.count -= 1;
        }
        self.entries[self.count] = .{ .elapsed_seconds = self.elapsed_seconds, .detail = value };
        self.count += 1;
        self.revision +|= 1;
    }
    fn detail(snapshot: probes.ProbeSnapshot) Detail {
        const delimiter = " · 阶段 ";
        const text = snapshot.safe_message[0 .. std.mem.indexOf(u8, snapshot.safe_message, delimiter) orelse snapshot.safe_message.len];
        inline for (std.enums.values(progress.Stage)) |phase| {
            if (std.mem.eql(u8, text, progress.stageLabel(phase))) return .{ .phase = phase };
        }
        const prefix = "建立 ";
        const suffix = " 跳 SSH 链";
        if (std.mem.startsWith(u8, text, prefix) and std.mem.endsWith(u8, text, suffix) and text.len > prefix.len + suffix.len) {
            const hops = std.fmt.parseInt(u8, text[prefix.len .. text.len - suffix.len], 10) catch 0;
            if (hops > 0 and hops <= 8) return .{ .route = hops };
        }
        return .{ .host_stage = snapshot.stage };
    }
    fn totalSeconds(text: []const u8) ?u64 {
        const delimiter = " · 总计 ";
        const start = (std.mem.indexOf(u8, text, delimiter) orelse return null) + delimiter.len;
        const end = start + (std.mem.indexOf(u8, text[start..], " 秒") orelse return null);
        return std.fmt.parseInt(u64, text[start..end], 10) catch null;
    }
    pub fn label(value: Detail, buffer: []u8) []const u8 {
        return switch (value) {
            .phase => |phase| progress.stageLabel(phase),
            .route => |hops| std.fmt.bufPrint(buffer, "建立 {d} 跳 SSH 链", .{hops}) catch "建立 SSH 路径",
            .host_stage => |stage| switch (stage) {
                .accepted => "管理测试已提交",
                .transport => "验证 SSH 路径和目标 TLS",
                .trust => "等待用户确认目标身份",
                .authentication => "验证 BMC 管理认证",
                .discovery => "发现管理资源与能力",
                .cleanup, .finished => "释放管理测试资源",
            },
            .cancel_requested => "已请求取消管理测试",
            .draft_changed => "配置已更改，此测试记录仅供参考",
            .status_unavailable => "正在等待管理测试状态",
            .cleanup_unknown => "管理测试资源仍待确认释放",
            .old_draft_released => "上次草稿的测试已结束，资源已释放",
            .result => |outcome| switch (outcome) {
                .succeeded => "管理连接测试成功；未打开视频",
                .failed => "管理连接测试失败，配置草稿已保留",
                .cancelled => "管理连接测试已取消，资源已释放",
            },
        };
    }
    pub fn format(self: *const ProbeLog, buffer: []u8) []const u8 {
        var written: usize = 0;
        for (self.entries[0..self.count]) |entry| {
            var label_buffer: [96]u8 = undefined;
            const line = std.fmt.bufPrint(buffer[written..], "[{d} 秒] {s}\n", .{ entry.elapsed_seconds, label(entry.detail, &label_buffer) }) catch break;
            written += line.len;
        }
        return buffer[0..written];
    }
};
