//! Main-thread adapter for the static saved-host catalog. The caller owns the
//! current-context and exact Broker-approval checks; no live-session inventory
//! is read to list, resolve or save a catalog entry.
const std = @import("std");
const catalog = @import("../ai/host_catalog.zig");
const host = @import("../ai/host_tools.zig");
const ApplicationHost = @import("application_host.zig").ApplicationHost;
const identity = @import("../host/identity.zig");

pub const Prepared = catalog.Prepared;
pub const prepare = catalog.prepare;

pub fn execute(app: *ApplicationHost, invocation: host.Invocation, allocator: std.mem.Allocator) !host.Result {
    return executeOperation(app, invocation, allocator, null);
}
pub fn executeOperation(app: *ApplicationHost, invocation: host.Invocation, allocator: std.mem.Allocator, operation: ?identity.HostOperationId) !host.Result {
    const workspace = app.workspace;
    if (!catalog.isMutation(invocation.tool_id)) return catalog.executeRead(&workspace.registry, invocation, allocator);
    // Prepare the process-local sidebar identity projection before the durable
    // transaction. Allocation failure must not invite replay of a saved host.
    _ = try catalog.parse(invocation);
    if (invocation.approval_sequence == null or invocation.approval_sequence.? == 0) return error.HostApprovalRequired;
    try workspace.identities.appendHosts(workspace.allocator, workspace.registry.hosts.len);
    try workspace.identities.hosts.ensureTotalCapacity(workspace.allocator, workspace.registry.hosts.len + 1);
    const receipt = try catalog.saveConfirmedOperation(allocator, workspace.io, std.Io.Dir.cwd(), workspace.hosts_path, &workspace.registry, invocation, operation);
    workspace.identities.appendHosts(workspace.allocator, workspace.registry.hosts.len) catch unreachable;
    workspace.rebuildSidebar() catch {
        workspace.statusFailure("配置已保存，列表刷新失败");
    };
    return receipt;
}
