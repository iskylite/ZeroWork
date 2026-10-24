//! SSH/SFTP contribute their real three-step editor through the ordinary slot.
const std = @import("std");
const ui = @import("ui");
const contract = @import("../../host/plugin_ui_contract.zig");
const envelopes = @import("../../config/connection_envelope.zig");
const types = @import("editor.zig");
pub const RemoteEditor = types.RemoteEditor;
pub const Instance = struct {
    editor: RemoteEditor = .{ .embedded = true },
    events: contract.EditorEvents,
    on_result: ?*const fn (*anyopaque, types.Result) anyerror!?types.SaveReceipt = null,
    result_context: ?*anyopaque = null,
    released: bool = false,
    allocator: std.mem.Allocator,
    scope_finished: bool = false,
    node_finished: bool = true,
};
pub fn current(shell: anytype) ?*Instance {
    const instance = shell.plugin_editor orelse return null;
    return fromInstance(instance);
}
pub fn fromInstance(instance: contract.EditorInstance) ?*Instance {
    if (instance.vtable != &vtable) return null;
    return @ptrCast(@alignCast(instance.context));
}
pub fn mount(_: ?*anyopaque, args: contract.EditorMount) !contract.EditorInstance {
    const self = try args.cx.allocator.create(Instance);
    self.* = .{ .events = args.events, .allocator = args.cx.allocator };
    args.scope.onCleanup(Instance, self, scopeFinished) catch |err| {
        args.cx.allocator.destroy(self);
        return err;
    };
    self.editor.protocol_id = args.protocol_id;
    self.editor.protocol = std.meta.stringToEnum(types.Protocol, args.protocol_id) orelse return error.UnsupportedProtocol;
    if (self.editor.protocol != .ssh and self.editor.protocol != .sftp) return error.UnsupportedProtocol;
    self.editor.connection_configs = args.connection_configs;
    self.editor.draft_id = args.editor_id;
    self.editor.draft_revision = args.draft_revision;
    self.editor.on_result = result;
    self.editor.result_ctx = self;
    const root = try self.editor.mount(args.cx, args.scope);
    self.node_finished = false;
    self.editor.root.?.meta.ownership.hooks.on_cleanup = .{ .context = self, .callback = nodeFinished };
    try args.slot.appendChild(args.cx.allocator, root);
    if (args.initial) |initial| {
        var arena = std.heap.ArenaAllocator.init(args.cx.allocator);
        defer arena.deinit();
        const host = try envelopes.decodeLegacy(arena.allocator(), initial);
        self.editor.loadDraft(types.Draft.fromHost(host));
    } else self.editor.loadDraft(.{ .protocol = self.editor.protocol });
    self.editor.show();
    return .{ .context = self, .vtable = &vtable, .handles_actions = true };
}
fn result(raw: *anyopaque, value: types.Result) !?types.SaveReceipt {
    const self: *Instance = @ptrCast(@alignCast(raw));
    const receipt = if (self.on_result) |callback| try callback(self.result_context orelse return error.EditorCallbackUnavailable, value) else switch (value) {
        .cancelled => null,
        .save_only, .saved => |draft| blk: {
            var arena = std.heap.ArenaAllocator.init(self.editor.alloc);
            defer arena.deinit();
            const envelope = try envelopes.fromLegacy(arena.allocator(), try draft.toHostConfig());
            try self.events.submit(self.events.context, envelope, if (value == .save_only) .save else .save_and_open);
            // The generic transaction owns persistence. This receipt is used
            // only to finish the provider's synchronous save state machine.
            break :blk types.SaveReceipt{ .owner = .{ .id = envelope.id, .revision = envelope.revision } };
        },
    };
    if (value == .cancelled) {
        if (self.events.cancelled) |callback| callback(self.events.context) else if (self.events.dismiss) |dismiss| dismiss(self.events.context);
    } else if (receipt != null and receipt.?.open_failure == null) {
        if (self.events.dismiss) |dismiss| dismiss(self.events.context);
    }
    return receipt;
}
fn snapshot(raw: *anyopaque, allocator: std.mem.Allocator) !envelopes.Envelope {
    const self: *Instance = @ptrCast(@alignCast(raw));
    return envelopes.fromLegacy(allocator, try self.editor.currentDraft().toHostConfig());
}
fn clear(raw: *anyopaque) void {
    const self: *Instance = @ptrCast(@alignCast(raw));
    if (self.editor.sig_password) |value| value.set("");
    if (self.editor.sig_key_passphrase) |value| value.set("");
}
fn cancel(raw: *anyopaque) void {
    const self: *Instance = @ptrCast(@alignCast(raw));
    self.editor.cancel();
}
fn visibility(raw: *anyopaque, visible: bool) void {
    const self: *Instance = @ptrCast(@alignCast(raw));
    if (visible) self.editor.show() else self.editor.hide();
}
fn release(raw: *anyopaque) void {
    const self: *Instance = @ptrCast(@alignCast(raw));
    self.released = true;
}
const vtable: contract.EditorInstance.VTable = .{ .snapshot = snapshot, .clear_secrets = clear, .unmount = release, .cancel = cancel, .visibility_changed = visibility };

/// Explicit legacy remote UI adapter for the application's existing Draft and
/// probe callers. A missing/replaced contribution cannot construct this view.
pub fn loadDraft(shell: anytype, draft: types.Draft) !void {
    const protocol_id = @tagName(draft.protocol);
    if (!std.mem.eql(u8, shell.protocol_id, protocol_id) or current(shell) == null) try shell.selectContribution(protocol_id);
    const state = current(shell) orelse return error.RemoteEditorUnavailable;
    state.editor.loadDraft(draft);
}
pub fn editor(shell: anytype) ?*RemoteEditor {
    const state = current(shell) orelse return null;
    return &state.editor;
}

fn scopeFinished(self: *Instance) void {
    self.scope_finished = true;
    if (self.node_finished) self.allocator.destroy(self);
}
fn nodeFinished(raw: *anyopaque) void {
    const self: *Instance = @ptrCast(@alignCast(raw));
    self.node_finished = true;
    self.editor.nodes_alive = false;
    if (self.scope_finished) self.allocator.destroy(self);
}

pub fn projectAssets(allocator: std.mem.Allocator, hosts: []const @import("../../config/hosts.zig").HostConfig) ![]types.Draft {
    var projected: std.ArrayList(types.Draft) = .empty;
    errdefer {
        for (projected.items) |*draft| draft.deinit(allocator);
        projected.deinit(allocator);
    }
    for (hosts) |host| {
        if (!host.isLegacy()) continue;
        var draft = try types.Draft.fromHost(host).dupe(allocator);
        errdefer draft.deinit(allocator);
        try projected.append(allocator, draft);
    }
    return projected.toOwnedSlice(allocator);
}
pub fn assetsCurrent(assets: []const types.Draft, hosts: []const @import("../../config/hosts.zig").HostConfig) bool {
    var index: usize = 0;
    for (hosts) |host| {
        if (!host.isLegacy()) continue;
        if (index >= assets.len) return false;
        const asset = assets[index];
        index += 1;
        const projected = types.Draft.fromHost(host);
        if (!std.meta.eql(projected.source_owner, asset.source_owner) or
            projected.protocol != asset.protocol or projected.auth != asset.auth or
            projected.strict_host_key_checking != asset.strict_host_key_checking or
            !std.mem.eql(@import("../../host/identity.zig").ConnectionId, projected.route, asset.route)) return false;
        if (!std.mem.eql(u8, host.name, asset.name) or
            !std.mem.eql(u8, host.host, asset.host) or host.port != asset.port or
            !std.mem.eql(u8, host.user, asset.user) or
            !optionalTextEqual(host.group, asset.group) or
            !optionalTextEqual(host.password, asset.password) or
            !optionalTextEqual(host.identity_file, asset.key_path) or
            !optionalTextEqual(host.key_passphrase, asset.key_passphrase) or
            !textListEqual(host.jump_chain, asset.jump_chain) or
            !textListEqual(host.startup_commands, asset.startup_commands) or
            !std.mem.eql(u8, host.terminal_type, asset.terminal_type) or
            host.terminal_type_explicit != asset.terminal_type_explicit or
            !std.mem.eql(u8, host.socks_bind, asset.socks_bind) or
            host.scrollback != asset.scrollback or host.keepalive != asset.keepalive or
            host.compression != asset.compression or host.compression_explicit != asset.compression_explicit or
            host.socks_enabled != asset.socks_enabled or
            host.socks_port != asset.socks_port or host.socks_exit != asset.socks_exit or
            host.socks_auto_start != asset.socks_auto_start or host.socks_max_connections != asset.socks_max_connections) return false;
    }
    return index == assets.len;
}

fn optionalTextEqual(a: ?[]const u8, b: ?[]const u8) bool {
    if (a) |text| return if (b) |other| std.mem.eql(u8, text, other) else false;
    return b == null;
}

fn textListEqual(a: []const []const u8, b: []const []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |text, other| if (!std.mem.eql(u8, text, other)) return false;
    return true;
}
