const std = @import("std");
const ssh = @import("proto/ssh/session.zig");
const exec = @import("proto/ssh/exec_bridge.zig");
const types = @import("ai/execbridge.zig");
const identity = @import("host/identity.zig");
const host = @import("host/session_host.zig");

test "exec bound service rejects stale generation and preserves original call identity" {
    const owner: identity.SessionHandle = .{ .session_id = @fromBackingInt(71), .generation = 3 };
    const key: @import("host/operation.zig").OperationKey = .{ .owner = .{ .session = owner }, .operation_id = 81, .attempt_id = 4 };
    var session: ssh.Session = .{ .state = .active, .resource_key = key };
    var service = exec.SshExecBridge.init(&session, std.testing.allocator);
    defer service.deinitLocal();
    const binding: host.ServiceHandle = .{ .resource_owner = .{ .session = owner }, .origin_session = owner, .kind = .exec, .binding_id = 7, .binding_generation = 2 };
    try service.bindService(binding);
    try std.testing.expectError(error.MissingOperation, service.exec("printf ok", .{}));
    var stale = key;
    stale.owner.session.generation += 1;
    try std.testing.expectError(error.StaleSession, service.exec("printf ok", .{ .key = stale, .call_id = 1 }));
    try std.testing.expectError(error.InvalidCwd, service.exec("printf ok", .{ .key = key, .call_id = 1, .cwd = "relative/path" }));
    const handle = try service.exec("printf ok", .{ .key = key, .call_id = 1, .cwd = "/tmp/a'b\nc" });
    var snapshot = try service.snapshot(handle, std.testing.allocator);
    defer snapshot.deinit();
    try std.testing.expectEqual(key, snapshot.value.key.?);
    try std.testing.expectEqual(binding, snapshot.value.service_binding.?);
    try std.testing.expectEqualStrings("/tmp/a'b\nc", snapshot.value.cwd.?);
    try std.testing.expectEqual(types.Status.queued, snapshot.value.status);
    service.close();
    try service.step();
    try std.testing.expectEqual(ssh.ReleaseReceipt.released, service.closeReceipt());
}

test "exec native step cannot move to a second live IO thread" {
    const Other = struct {
        fn run(service: *exec.SshExecBridge, rejected: *std.atomic.Value(bool)) void {
            service.step() catch |err| {
                rejected.store(err == error.WrongIoOwner, .release);
            };
        }
    };
    var session: ssh.Session = .{ .state = .active };
    var service = exec.SshExecBridge.init(&session, std.testing.allocator);
    defer service.deinitLocal();
    try service.step();
    var rejected: std.atomic.Value(bool) = .init(false);
    const thread = try std.Thread.spawn(.{}, Other.run, .{ &service, &rejected });
    thread.join();
    try std.testing.expect(rejected.load(.acquire));
}

test "exec new generation cannot consume or overwrite the previous call result" {
    const old_owner: identity.SessionHandle = .{ .session_id = @fromBackingInt(71), .generation = 3 };
    const old_key: @import("host/operation.zig").OperationKey = .{ .owner = .{ .session = old_owner }, .operation_id = 81, .attempt_id = 4 };
    var session: ssh.Session = .{ .state = .active, .resource_key = old_key };
    var service = exec.SshExecBridge.init(&session, std.testing.allocator);
    defer service.deinitLocal();
    const old_handle = try service.exec("old command", .{ .key = old_key, .call_id = 1 });
    exec.SshExecBridge.abortHandle(old_handle);
    try service.step();
    const original = exec.SshExecBridge.pollHandle(old_handle).?;
    try std.testing.expectEqual(ssh.ReleaseReceipt.released, session.closeReceipt());
    try service.sessionReleased();
    const new_owner = try old_owner.nextGeneration();
    const new_key: @import("host/operation.zig").OperationKey = .{ .owner = .{ .session = new_owner }, .operation_id = 82, .attempt_id = 5 };
    try service.transportReplaced(.{ .state = .active, .resource_key = new_key });
    const new_handle = try service.exec("new command", .{ .key = new_key, .call_id = 1 });
    try std.testing.expect(new_handle.ptr != old_handle.ptr);
    const preserved = exec.SshExecBridge.pollHandle(old_handle).?;
    try std.testing.expect(preserved.key.?.eql(old_key));
    try std.testing.expectEqualStrings("old command", preserved.command);
    try std.testing.expectEqual(original.elapsed_ms, preserved.elapsed_ms);
    try std.testing.expect(exec.SshExecBridge.pollHandle(new_handle) == null);
    try std.testing.expectError(error.StaleSession, service.exec("late old command", .{ .key = old_key, .call_id = 2 }));
    service.close();
    try service.step();
}

test {
    std.testing.refAllDecls(exec);
    _ = types;
    _ = @import("transfer/sftp_engine.zig");
}
