//! Capability-based routing: SSH's auxiliary/shared transport and SFTP's native
//! transfer binding are distinct. Neither requires a terminal service.
const std = @import("std");
const app_mod = @import("application_host.zig");
const identity = @import("../host/identity.zig");
const sessions = @import("../host/session_host.zig");
pub const Source = struct {
    auxiliary: bool,
    binding: ?sessions.ServiceHandle = null,
};
pub fn resolve(app: *app_mod.ApplicationHost, owner: identity.SessionHandle, require_ready: bool) !Source {
    const state = app.sessions.queryState(owner) orelse return error.StaleSession;
    const manifest = app.sessions.manifestFor(owner) orelse return error.StaleSession;
    const capabilities = (try app.sessions.capabilitySnapshot(owner)) orelse return error.StaleSession;
    const capability = for (capabilities.services) |service| {
        if (std.mem.eql(u8, service.key.name, "transfer")) break service;
    } else return error.TransferUnsupported;
    if (!capability.declared or !capability.authorized) return error.TransferNotAuthorized;
    if (!require_ready) return .{ .auxiliary = manifest.integration.auxiliary_transfer };
    if (state.lifecycle != .attached) return error.TransferSessionNotAttached;
    const tab = app.workspace.sessionTab(app.legacyForHandle(owner) orelse return error.StaleSession) orelse return error.StaleSession;
    if (tab.closing or tab.archived or tab.failed) return error.StaleSession;
    if (manifest.integration.auxiliary_transfer) {
        if (tab.runtime == null or tab.runtime.?.torn_down) return error.TransferNotReady;
        return .{ .auxiliary = true };
    }
    if (!tab.file_ready) return error.TransferNotReady;
    const binding = switch (app.sessions.queryService(owner, .transfer)) {
        .available => |value| value,
        else => return error.TransferNotReady,
    };
    if (!app.sessions.bindingIsLive(binding)) return error.StaleBinding;
    return .{ .auxiliary = false, .binding = binding };
}
