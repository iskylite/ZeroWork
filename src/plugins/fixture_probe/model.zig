//! Non-terminal fixture business state. No native SSH, terminal or App access.
const std = @import("std");
const identity = @import("../../host/identity.zig");
const envelope = @import("../../config/connection_envelope.zig");
const resolver = @import("../../host/connection_config_resolver.zig");

pub const protocol_id = "fixture_probe";
pub const workspace_kind = "fixture_probe.canvas";
pub const Payload = struct {
    routed: bool = false,
    ssh_assets: []const u64 = &.{},
    destination: []const u8 = "synthetic.invalid",
    port: u16 = 5900,
    show_grid: bool = true,
};
pub fn validatePayload(bytes: []const u8) !void {
    const parsed = try std.json.parseFromSlice(Payload, std.heap.page_allocator, bytes, .{});
    defer parsed.deinit();
    try validate(parsed.value);
}
pub fn validate(value: Payload) !void {
    if (value.destination.len == 0 or value.destination.len > 255 or std.mem.indexOfAny(u8, value.destination, " \t\r\n\x00") != null or value.port == 0) return error.InvalidDestination;
    if (value.ssh_assets.len > 8) return error.TooManyJumps;
    if (value.routed and value.ssh_assets.len == 0) return error.MissingSshReference;
    if (!value.routed and value.ssh_assets.len != 0) return error.UnexpectedSshReference;
    for (value.ssh_assets, 0..) |id, index| {
        if (id == 0) return error.InvalidSshReference;
        for (value.ssh_assets[0..index]) |earlier| if (earlier == id) return error.DuplicateRoute;
    }
}
pub const Editor = struct {
    arena: std.heap.ArenaAllocator,
    name: []const u8 = "合成画面",
    asset_id: identity.ConnectionId = @fromBackingInt(0),
    asset_revision: u64 = 1,
    group_id: ?identity.AssetGroupId = null,
    value: Payload = .{},
    revision: u64 = 1,
    alive: bool = true,
    secret: [128]u8 = @splat(0),
    secret_len: usize = 0,
    probe_revision: ?u64 = null,
    pub fn init(a: std.mem.Allocator) Editor {
        return .{ .arena = .init(a) };
    }
    pub fn deinit(self: *Editor) void {
        self.clearSecrets();
        self.alive = false;
        self.arena.deinit();
    }
    pub fn changeName(self: *Editor, value: []const u8) !void {
        self.name = try self.arena.allocator().dupe(u8, value);
        self.revision = try identity.advance(self.revision);
    }
    pub fn setRouted(self: *Editor, enabled: bool) !void {
        self.value.routed = enabled;
        if (!enabled) self.value.ssh_assets = &.{};
        self.revision = try identity.advance(self.revision);
    }
    /// This editor has two sections in basic mode and four in routed mode;
    /// it is not the shared protocol/form/confirm three-step state machine.
    pub fn sectionCount(self: *const Editor) usize {
        return if (self.value.routed) 4 else 2;
    }
    pub fn setSecret(self: *Editor, value: []const u8) !void {
        if (value.len > self.secret.len) return error.SecretTooLong;
        self.clearSecrets();
        @memcpy(self.secret[0..value.len], value);
        self.secret_len = value.len;
    }
    pub fn clearSecrets(self: *Editor) void {
        std.crypto.secureZero(u8, &self.secret);
        self.secret_len = 0;
    }
    pub fn applyChild(self: *Editor, parent_revision: u64, asset_id: identity.ConnectionId, _: u64) !bool {
        if (!self.alive or self.revision != parent_revision) return false;
        self.value.ssh_assets = try self.arena.allocator().dupe(u64, &.{@backingInt(asset_id)});
        self.value.routed = true;
        self.revision = try identity.advance(self.revision);
        return true;
    }
    pub fn beginProbe(self: *Editor) u64 {
        self.probe_revision = self.revision;
        return self.revision;
    }
    pub fn finishProbe(self: *Editor, revision: u64) bool {
        if (!self.alive or self.probe_revision != revision or self.revision != revision) return false;
        self.probe_revision = null;
        return true;
    }
    pub fn cancelProbe(self: *Editor) void {
        self.probe_revision = null;
    }
    pub fn snapshot(self: *const Editor, a: std.mem.Allocator) !envelope.Envelope {
        try validate(self.value);
        const result: envelope.Envelope = .{ .id = self.asset_id, .protocol_id = protocol_id, .group_id = self.group_id, .name = try a.dupe(u8, self.name), .revision = self.asset_revision, .payload = try std.json.Stringify.valueAlloc(a, self.value, .{}) };
        try result.validate();
        return result;
    }
    /// Offline validation uses immutable AssetStore references and never asks
    /// for the connect-time secret or a running SSH terminal.
    pub fn freezeRoute(self: *const Editor, configs: resolver.Resolver, a: std.mem.Allocator) !resolver.FrozenRoute {
        try validate(self.value);
        var ids: [8]identity.ConnectionId = undefined;
        for (self.value.ssh_assets, 0..) |id, i| ids[i] = @fromBackingInt(id);
        return configs.freezeRoute(ids[0..self.value.ssh_assets.len], a);
    }
};

pub const Frame = struct {
    pub const width: u32 = 64;
    pub const height: u32 = 40;
    pixels: [width * height * 4]u8 = undefined,
    revision: u64 = 1,
    pointer_x: u32 = 12,
    pointer_y: u32 = 12,
    key_count: u32 = 0,
    powered: bool = true,
    pub fn render(self: *Frame, grid: bool) void {
        for (0..height) |y| for (0..width) |x| {
            const i = (y * width + x) * 4;
            const line = grid and (x % 8 == 0 or y % 8 == 0);
            self.pixels[i..][0..4].* = if (!self.powered) .{ 10, 10, 12, 255 } else if (x == self.pointer_x or y == self.pointer_y) .{ 115, 167, 255, 255 } else if (line) .{ 48, 51, 62, 255 } else .{ 24, 25, @intCast(30 + self.key_count % 32), 255 };
        };
    }
    /// Valid PNG with a stored DEFLATE block. The provider receives actual
    /// immutable image content, never a filesystem/base64 text surrogate.
    pub fn png(self: *const Frame, a: std.mem.Allocator) ![]u8 {
        const stride = width * 4 + 1;
        var raw: [height * stride]u8 = undefined;
        for (0..height) |y| {
            raw[y * stride] = 0;
            @memcpy(raw[y * stride + 1 ..][0 .. width * 4], self.pixels[y * width * 4 ..][0 .. width * 4]);
        }
        var output: std.ArrayList(u8) = .empty;
        errdefer output.deinit(a);
        try output.appendSlice(a, "\x89PNG\r\n\x1a\n");
        var header: [13]u8 = .{ 0, 0, 0, width, 0, 0, 0, height, 8, 6, 0, 0, 0 };
        try chunk(&output, a, "IHDR", &header);
        var compressed: [raw.len + 11]u8 = undefined;
        compressed[0..7].* = .{ 0x78, 0x01, 0x01, @intCast(raw.len & 255), @intCast(raw.len >> 8), @intCast((~@as(u16, raw.len)) & 255), @intCast((~@as(u16, raw.len)) >> 8) };
        @memcpy(compressed[7..][0..raw.len], &raw);
        var first: u32 = 1;
        var second: u32 = 0;
        for (raw) |byte| {
            first = (first + byte) % 65521;
            second = (second + first) % 65521;
        }
        std.mem.writeInt(u32, compressed[compressed.len - 4 ..][0..4], (second << 16) | first, .big);
        try chunk(&output, a, "IDAT", &compressed);
        try chunk(&output, a, "IEND", "");
        return output.toOwnedSlice(a);
    }
};
fn chunk(out: *std.ArrayList(u8), a: std.mem.Allocator, kind: *const [4]u8, data: []const u8) !void {
    var bytes: [4]u8 = undefined;
    std.mem.writeInt(u32, &bytes, @intCast(data.len), .big);
    try out.appendSlice(a, &bytes);
    const start = out.items.len;
    try out.appendSlice(a, kind);
    try out.appendSlice(a, data);
    std.mem.writeInt(u32, &bytes, std.hash.Crc32.hash(out.items[start..]), .big);
    try out.appendSlice(a, &bytes);
}
