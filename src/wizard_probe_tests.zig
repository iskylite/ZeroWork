const std = @import("std");
const probe = @import("ui/wizard_probe.zig");
const wizard = @import("ui/wizard.zig");
const hosts = @import("config/hosts.zig");
const runtime = @import("ui/session_runtime.zig");
const ssh = @import("proto/ssh/session.zig");
const operations = @import("host/operation.zig");

fn draft() wizard.Draft {
    return .{ .draft_id = 17, .revision = 4, .name = "target", .host = "127.0.0.1", .port = 1, .user = "test", .auth = .agent };
}

fn isolatedStorePath(tmp: std.Io.Dir) ![]u8 {
    var buffer: [std.fs.max_path_bytes]u8 = undefined;
    const len = try tmp.realPath(std.testing.io, &buffer);
    return std.fs.path.join(std.testing.allocator, &.{ buffer[0..len], "known_hosts" });
}

fn finishWorker(job: *probe.Job) void {
    if (job.thread) |thread| thread.join();
    job.thread = null;
}

test "probe requires the actual app operation and never invents a session handle" {
    var library = try ssh.Library.init();
    defer library.deinit();
    try std.testing.expectError(error.OperationKeyRequired, probe.Job.start(draft(), &.{}, .{}, 1, &library));
    try std.testing.expectError(error.InvalidOperation, probe.Job.startForOperation(draft(), &.{}, .{}, 1, &library, .{ .owner = .app, .operation_id = 0, .attempt_id = 1 }));
    try std.testing.expectError(error.InvalidOperation, probe.Job.startForOperation(draft(), &.{}, .{}, 1, &library, .{ .owner = .{ .session = .{ .session_id = @fromBackingInt(1) } }, .operation_id = 4, .attempt_id = 1 }));
}

test "probe numeric route shares formal validation without name fallbacks" {
    const registry = [_]hosts.HostConfig{
        .{ .connection_id = @fromBackingInt(41), .revision = 2, .name = "same", .host = "bridge-a.test", .user = "a" },
        .{ .connection_id = @fromBackingInt(42), .revision = 3, .name = "same", .host = "bridge-b.test", .user = "b" },
    };
    var value = draft();
    value.route = &.{ @fromBackingInt(42), @fromBackingInt(41) };
    try probe.validateRoute(value, &registry);
    value.route = &.{@fromBackingInt(99)};
    try std.testing.expectError(error.MissingRouteReference, probe.validateRoute(value, &registry));
    value.route = &.{ @fromBackingInt(41), @fromBackingInt(41) };
    try std.testing.expectError(error.DuplicateRoute, probe.validateRoute(value, &registry));
    value.route = &.{};
    value.jump_chain = &.{"same"};
    try std.testing.expectError(error.UnmigratedRoute, probe.validateRoute(value, &registry));
}

test "probe and formal plans freeze the same hop policies with purpose-specific shell gates" {
    var address = "target.test".*;
    const hop: hosts.HostConfig = .{ .connection_id = @fromBackingInt(41), .revision = 8, .name = "bridge", .host = "bridge.test", .user = "bridge-user", .auth_mode = .password, .password = "fixture", .strict_host_key_checking = true };
    var target = runtime.targetFromHost(.{ .connection_id = @fromBackingInt(77), .revision = 6, .name = "target", .host = &address, .user = "target-user", .auth_mode = .agent, .strict_host_key_checking = false, .route = &.{hop.connection_id}, .startup_commands = &.{"never run in a probe"} }, &.{hop});
    target.operation_key = .{ .owner = .app, .operation_id = 71, .attempt_id = 3 };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const test_options = try runtime.prepareConnectionOptions(arena.allocator(), .{}, target, .@"test");
    for (test_options) |option| {
        try std.testing.expect(!option.open_shell);
        try std.testing.expect(option.operation_key.?.eql(target.operation_key.?));
    }
    try std.testing.expect(test_options[0].strict_host_key_checking);
    try std.testing.expect(!test_options[1].strict_host_key_checking);
    try std.testing.expectEqual(hop.owner(), test_options[0].source_owner.?);
    try std.testing.expectEqual(@as(u64, 6), test_options[1].source_owner.?.revision);
    try std.testing.expect(test_options[0].auth == .password);
    try std.testing.expect(test_options[1].auth == .agent);
    target.operation_key = .{ .owner = .{ .session = .{ .session_id = @fromBackingInt(9), .generation = 2 } }, .operation_id = 72, .attempt_id = 4 };
    const formal_options = try runtime.prepareConnectionOptions(arena.allocator(), .{}, target, .session);
    try std.testing.expect(!formal_options[0].open_shell);
    try std.testing.expect(formal_options[1].open_shell);
    @memset(&address, 'x');
    try std.testing.expectEqualStrings("target.test", test_options[1].host);
    try std.testing.expectEqualStrings("target.test", formal_options[1].host);
    try std.testing.expectError(error.UnsupportedPurpose, runtime.prepareConnectionOptions(arena.allocator(), .{}, target, .transfer_binding));
}

test "probe controller publishes only released frozen results and retries OOM publication" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "known_hosts", .data = "malformed\n" });
    const path = try isolatedStorePath(tmp.dir);
    defer std.testing.allocator.free(path);
    var library = try ssh.Library.init();
    defer library.deinit();
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    var journal = operations.Journal.init(failing.allocator());
    defer journal.deinit();
    var controller = probe.Controller.init(std.testing.allocator, &journal);
    defer controller.deinit();
    var name = "before".*;
    var value = draft();
    value.name = &name;
    value.source_owner = .{ .id = @fromBackingInt(93), .revision = 7 };
    const job = try controller.startWithTrustStore(value, &.{}, .{}, 42, &library, path);
    @memset(&name, 'x');
    finishWorker(job);
    try std.testing.expectEqualStrings("before", job.source.value.host.name);
    failing.fail_index = failing.alloc_index;
    try std.testing.expectError(error.OutOfMemory, controller.poll(job));
    try std.testing.expect(!job.result_published);
    try std.testing.expectEqual(@as(usize, 1), controller.jobs.items.len);
    try std.testing.expect(!journal.isTerminal(job.key));
    failing.fail_index = std.math.maxInt(usize);
    const outcome = (try controller.poll(job)).finished;
    try std.testing.expectEqual(error.InvalidKnownHosts, outcome.failure.?);
    try std.testing.expectEqual(operations.Cleanup.released, outcome.cleanup);
    try std.testing.expectEqual(runtime.Purpose.@"test", outcome.purpose);
    try std.testing.expectEqual(@as(u64, 17), outcome.draft_id);
    try std.testing.expectEqual(@as(u64, 4), outcome.draft_revision);
    try std.testing.expectEqual(@as(u64, 42), outcome.generation);
    try std.testing.expectEqual(value.source_owner.?, outcome.source_owner.?);
    try std.testing.expect(outcome.key.owner == .app);
    try std.testing.expect(journal.isTerminal(outcome.key));
    try controller.retire(job);
    try std.testing.expectEqual(@as(usize, 0), controller.jobs.items.len);
    try std.testing.expectEqual(@as(usize, 0), journal.records.items.len);
}

test "probe draft projection preserves explicit identity auth route and strict policy" {
    const original: hosts.HostConfig = .{ .connection_id = @fromBackingInt(71), .revision = 12, .name = "source", .host = "source.test", .user = "user", .auth_mode = .password, .password = null, .strict_host_key_checking = false, .route = &.{@fromBackingInt(42)}, .jump_chain = &.{"display-only"} };
    var copy = try wizard.Draft.fromHost(original).dupe(std.testing.allocator);
    defer copy.deinit(std.testing.allocator);
    const host = try copy.toHostConfig();
    try std.testing.expectEqual(original.owner(), copy.source_owner.?);
    try std.testing.expectEqual(original.connection_id, host.connection_id);
    try std.testing.expectEqual(original.revision, host.revision);
    try std.testing.expectEqual(hosts.AuthMode.password, host.auth_mode);
    try std.testing.expect(host.password == null);
    try std.testing.expect(!host.strict_host_key_checking);
    try std.testing.expectEqualSlices(hosts.identity.ConnectionId, original.route, host.route);
}

test "SFTP probe freezes a direct no shell plan and rejects routed workspace before IO" {
    var value = draft();
    value.protocol = .sftp;
    value.startup_commands = &.{"MUST_NOT_EXECUTE"};
    try probe.validateRoute(value, &.{});
    const host = try value.toHostConfig();
    var target = runtime.targetFromHost(host, &.{});
    target.operation_key = .{ .owner = .app, .operation_id = 701, .attempt_id = 1 };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const options = try runtime.prepareConnectionOptions(arena.allocator(), .{}, target, .@"test");
    try std.testing.expectEqual(@as(usize, 1), options.len);
    try std.testing.expect(!options[0].open_shell);
    try std.testing.expectError(error.UnsupportedProtocol, runtime.prepareConnectionOptions(arena.allocator(), .{}, target, .session));
    value.route = &.{@fromBackingInt(41)};
    try std.testing.expectError(error.ProxyJumpTransportUnavailable, probe.validateRoute(value, &.{}));
    const routed = runtime.targetFromHost(try value.toHostConfig(), &.{});
    try std.testing.expectError(error.ProxyJumpTransportUnavailable, runtime.prepareConnectionOptions(arena.allocator(), .{}, routed, .@"test"));
}
