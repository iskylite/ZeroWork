//! A real shared resource domain with independent window borrowers. No native
//! window or SSH connection is created; queued jobs exercise retained identity.
const std = @import("std");
const tasks_mod = @import("host/application_task_domain.zig");
const sessions = @import("host/session_host.zig");
const plugins = @import("host/plugin_registry.zig");
const identity = @import("host/identity.zig");
const operations = @import("host/operation.zig");
const Config = @import("config/config.zig").Config;
const a = std.testing.allocator;
const Adapter = struct {
    fn create(_: *anyopaque, _: sessions.CreateRequest) !void {}
    fn cancel(_: *anyopaque, _: operations.OperationKey) sessions.CloseReceipt {
        return .released;
    }
    fn close(_: *anyopaque, _: identity.SessionHandle, _: operations.OperationKey) !sessions.CloseReceipt {
        return .released;
    }
    fn stale(_: *anyopaque, _: identity.SessionHandle, _: operations.OperationKey) void {}
    fn interface(self: *Adapter) sessions.Adapter {
        return .{ .registration = .{ .plugin_id = .sftp, .workspace_kind = .file, .services = plugins.requiredServices(.sftp) }, .context = self, .vtable = &.{ .create = create, .cancel = cancel, .close = close, .release_stale = stale } };
    }
};
fn ready(domain: *sessions.SessionHost, window: u64) !sessions.Accepted {
    const accepted = try domain.create(.{ .saved = .{ .connection_id = @fromBackingInt(90 + window), .config_revision = 1, .protocol = .sftp, .immutable_config = .{ .endpoint = .{ .host = "task-domain.invalid", .user = "fixture" } } } }, .{ .window_id = @fromBackingInt(window), .workspace_id = @fromBackingInt(window) });
    try std.testing.expect(try domain.ready(accepted.handle, accepted.operation, plugins.requiredServices(.sftp)));
    try std.testing.expect(try domain.attached(accepted.handle, .{ .target = .{ .window_id = @fromBackingInt(window), .workspace_id = @fromBackingInt(window) }, .tab_id = @fromBackingInt(window) }));
    return accepted;
}
test "shared task domain retains original window owner while sibling continues independently" {
    var adapter: Adapter = .{};
    var session_domain = try sessions.SessionHost.init(a, &.{adapter.interface()});
    defer session_domain.deinit();
    var config: Config = .{};
    const domain = try tasks_mod.Domain.init(a, std.testing.io, &session_domain, &config, "/tmp/zerowork-task-domain-test-known-hosts", null);
    defer domain.deinit() catch unreachable;
    const first = try ready(&session_domain, 1);
    const second = try ready(&session_domain, 2);
    const first_binding = session_domain.queryService(first.handle, .transfer).available;
    const second_binding = session_domain.queryService(second.handle, .transfer).available;
    const first_job = try domain.manager.enqueue(.{ .session_id = @backingInt(first.handle.session_id), .transfer_binding = first_binding, .direction = .upload, .sources = &.{"one.txt"}, .local_dir = "/tmp", .remote_dir = "/upload" });
    const second_job = try domain.manager.enqueue(.{ .session_id = @backingInt(second.handle.session_id), .transfer_binding = second_binding, .direction = .upload, .sources = &.{"two.txt"}, .local_dir = "/tmp", .remote_dir = "/upload" });
    try domain.job_owners.append(a, .{ .job = first_job, .owner = first.handle });
    try domain.job_owners.append(a, .{ .job = second_job, .owner = second.handle });
    try std.testing.expect(first_job != second_job);
    try domain.manager.pause(first_job);
    const retained_id = try session_domain.retainTransferSource(first.handle);
    const owner: identity.TransferOwner = .{ .id = retained_id, .original_handle = first.handle };
    try domain.manager.retainPaused(first_job, 0, null, owner);
    _ = try session_domain.requestClose(first.handle, .{});
    // A second window borrows the same Manager and sees the frozen original
    // source after the first window's session is already closed.
    const second_view = &domain.manager;
    try std.testing.expectEqual(@as(usize, 2), second_view.count());
    try std.testing.expectEqualDeep(owner, second_view.retainedOwner(first_job).?);
    try std.testing.expect(domain.ownerForJob(first_job).?.eql(first.handle));
    const snapshot = try domain.jobSnapshots(a);
    defer a.free(snapshot);
    try std.testing.expectEqual(@as(usize, 2), snapshot.len);
    try std.testing.expectEqualDeep(owner, snapshot[0].retained_owner.?);
    try std.testing.expect(snapshot[0].owner.?.eql(first.handle));
    try std.testing.expectEqual(@import("transfer/manager.zig").State.queued, second_view.progress(second_job).?.state);
    try std.testing.expect(domain.ownerForJob(second_job).?.eql(second.handle));
    try domain.manager.retainedCancelReceipt(first_job, 0, owner, .released);
    try std.testing.expectEqual(@import("transfer/manager.zig").State.queued, second_view.progress(second_job).?.state);
    try domain.manager.cancel(second_job);
    try std.testing.expectEqual(sessions.CloseReceipt.released, domain.shutdownStep());
}
