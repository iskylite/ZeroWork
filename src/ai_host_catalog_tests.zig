const std = @import("std");
const catalog = @import("ai/host_catalog.zig");
const host = @import("ai/host_tools.zig");
const lifecycle = @import("ai/host_lifecycle.zig");
const hosts = @import("config/hosts.zig");
const a = std.testing.allocator;

fn context() host.Context {
    return .{ .conversation_id = .{ .bytes = @splat(1) }, .task_id = .{ .bytes = @splat(2) }, .binding = .{ .group = 7 }, .binding_revision = 3, .grant_revision = 4 };
}
fn invocation(tool: []const u8, arguments: std.json.Value, wire: []const u8) !host.Invocation {
    var hash: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(wire, &hash, .{});
    return .{ .context = context(), .authority = if (catalog.isMutation(tool)) .lifecycle else .conversation_context, .operation_id = 8, .turn_id = 9, .call_id = "host-catalog", .tool_id = tool, .arguments = arguments, .arguments_json = wire, .arguments_hash = hash, .canonical_arguments_hash = try @import("ai/canonical_arguments.zig").digest(a, arguments) };
}
fn parseArguments(wire: []const u8) !std.json.Parsed(std.json.Value) {
    return std.json.parseFromSlice(std.json.Value, a, wire, .{});
}

test "host catalog schema separates read-only static configuration and always-confirm save" {
    var table = try @import("ai/plugin_tools.zig").RequestTable.initWithHost(a, .{ .owner = context().binding, .members = .{} }, &.{}, &.{}, context(), &catalog.contributions);
    defer table.deinit();
    try std.testing.expectEqual(@as(usize, 3), table.entries.len);
    try std.testing.expectEqual(@import("ai/plugin_tools.zig").Effect.resource_write, catalog.contributions[2].definition.effect);
    try std.testing.expectEqual(@import("ai/plugin_tools.zig").ApprovalPolicy.always_confirm, catalog.contributions[2].definition.approval_policy);
    try std.testing.expect(!catalog.supports("host.list_sessions"));
    try std.testing.expect(!catalog.supports("host.update_host"));
    try std.testing.expect(!catalog.supports("host.delete_host"));
    const empty = try parseArguments("{}");
    defer empty.deinit();
    for ([_][]const u8{ "host.update_host", "host.delete_host" }) |tool| try std.testing.expectError(error.ToolNotAvailable, catalog.parse(try invocation(tool, empty.value, "{}")));
}

test "host catalog list and exact lookup project only saved static non-sensitive fields" {
    var registry = try hosts.Registry.parse(a,
        \\[[hosts]]
        \\name = "saved-only"
        \\host = "192.0.2.10"
        \\user = "fixture"
        \\password = "do-not-project-password"
        \\password_ref = "do-not-project-reference"
        \\startup_commands = ["do-not-project-startup"]
        \\[[hosts]]
        \\name = "key-only"
        \\host = "192.0.2.11"
        \\user = "fixture"
        \\identity_file = "/do-not-project-key-path"
        \\key_passphrase = "do-not-project-passphrase"
    );
    defer registry.deinit();
    const args = try parseArguments("{\"limit\":1}");
    defer args.deinit();
    var result = try catalog.executeRead(&registry, try invocation("host.list_hosts", args.value, "{\"limit\":1}"), a);
    defer result.deinit(a);
    try result.validate(context(), 8);
    const wire = result.blocks[0].structured;
    for ([_][]const u8{ "do-not-project", "password", "identity_file", "session", "group", "connected", "state", "credential" }) |forbidden| try std.testing.expect(std.mem.indexOf(u8, wire, forbidden) == null);
    const parsed = try parseArguments(wire);
    defer parsed.deinit();
    const rows = parsed.value.object.get("hosts").?.array.items;
    try std.testing.expectEqual(@as(usize, 1), rows.len);
    try std.testing.expectEqual(@as(usize, 6), rows[0].object.count());
    try std.testing.expectEqual(@as(i64, 1), parsed.value.object.get("next_offset").?.integer);
    const reference = rows[0].object.get("source_ref").?.string;
    try std.testing.expectEqual(registry.hosts[0].owner(), try lifecycle.connectionOwner(context(), reference));
    const lookup_wire = try std.fmt.allocPrint(a, "{{\"source_ref\":\"{s}\"}}", .{reference});
    defer a.free(lookup_wire);
    const lookup = try parseArguments(lookup_wire);
    defer lookup.deinit();
    var exact = try catalog.executeRead(&registry, try invocation("host.get_host", lookup.value, lookup_wire), a);
    defer exact.deinit(a);
    try std.testing.expect(std.mem.indexOf(u8, exact.blocks[0].structured, "saved-only") != null);
    var stale = try invocation("host.get_host", lookup.value, lookup_wire);
    stale.context.conversation_id.bytes[0] += 1;
    try std.testing.expectError(error.StaleReference, catalog.executeRead(&registry, stale, a));
    registry.hosts[0].revision += 1;
    try std.testing.expectError(error.StaleReference, catalog.executeRead(&registry, try invocation("host.get_host", lookup.value, lookup_wire), a));
}

test "host catalog strict parser rejects secrets references live targets and implicit key inputs" {
    const prefix = "\"request_key\":\"create-fixture\",\"name\":\"fixture\",\"host\":\"192.0.2.1\",\"user\":\"tester\"";
    for ([_][]const u8{ "password", "key_passphrase", "private_key", "private_key_material", "password_ref", "key_passphrase_ref", "totp_secret", "session_ref", "group_ref", "route", "startup_commands", "strict_host_key_checking" }) |field| {
        const wire = try std.fmt.allocPrint(a, "{{{s},\"{s}\":\"fixture-forbidden\"}}", .{ prefix, field });
        defer a.free(wire);
        const args = try parseArguments(wire);
        defer args.deinit();
        try std.testing.expectError(error.InvalidArguments, catalog.parse(try invocation("host.create_host", args.value, wire)));
    }
    for ([_][]const u8{
        "{\"request_key\":\"key\",\"name\":\"x\",\"host\":\"192.0.2.1\",\"user\":\"u\",\"identity_file\":\"/tmp/key\"}",
        "{\"request_key\":\"key\",\"name\":\"x\",\"host\":\"192.0.2.1\",\"user\":\"u\",\"auth_mode\":\"private_key\"}",
        "{\"request_key\":\"key\",\"name\":\"x\",\"host\":\"192.0.2.1\",\"user\":\"u\",\"auth_mode\":\"private_key\",\"identity_file\":\"relative-key\"}",
        "{\"request_key\":\"key\",\"name\":\"x\",\"host\":\"192.0.2.1\",\"user\":\"u\",\"port\":0}",
        "{\"name\":\"x\",\"host\":\"192.0.2.1\",\"user\":\"u\"}",
        "{\"request_key\":\"bad key\",\"name\":\"x\",\"host\":\"192.0.2.1\",\"user\":\"u\"}",
    }) |wire| {
        const args = try parseArguments(wire);
        defer args.deinit();
        try std.testing.expectError(error.InvalidArguments, catalog.parse(try invocation("host.create_host", args.value, wire)));
    }
}

test "host catalog exact confirmation binds parsed non-secret fields and full authority" {
    const wire = "{\"request_key\":\"create-fixture\",\"name\":\"fixture\",\"host\":\"192.0.2.1\",\"user\":\"tester\",\"auth_mode\":\"password\"}";
    const args = try parseArguments(wire);
    defer args.deinit();
    const call = try invocation("host.create_host", args.value, wire);
    var prepared = try catalog.prepare(call, a);
    defer prepared.deinit(a);
    const subject = prepared.subject();
    var broker: @import("ai/host_approval.zig").Broker = .{};
    defer broker.stop();
    try broker.configure(context(), 1);
    const permit = try broker.beginSubject(call, subject, 1, a);
    defer broker.finish(permit);
    try std.testing.expectEqual(@import("ai/fetch_url.zig").Decision.approval_required, broker.authorizeSubject(permit, call, subject, 1));
    try broker.decide(permit.sequence, permit.arguments_hash, true);
    try std.testing.expectEqual(@import("ai/fetch_url.zig").Decision.allow, broker.authorizeSubject(permit, call, subject, 1));
    var changed = call;
    changed.context.binding_revision += 1;
    try std.testing.expectEqual(@import("ai/fetch_url.zig").Decision.scope_changed, broker.authorizeSubject(permit, changed, subject, 1));
    var changed_subject = subject;
    changed_subject.detail = "different static configuration";
    try std.testing.expectEqual(@import("ai/fetch_url.zig").Decision.scope_changed, broker.authorizeSubject(permit, call, changed_subject, 1));
}

test "host catalog confirmed save commits registry before returning SourceRef and never connects" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var registry = try hosts.Registry.parse(a, "");
    defer registry.deinit();
    registry.source_hash = null; // A new path has no on-disk baseline.
    const wire = "{\"request_key\":\"create-fixture\",\"name\":\"catalog-fixture\",\"host\":\"192.0.2.42\",\"port\":2222,\"user\":\"tester\",\"auth_mode\":\"password\"}";
    const args = try parseArguments(wire);
    defer args.deinit();
    var call = try invocation("host.create_host", args.value, wire);
    try std.testing.expectError(error.HostApprovalRequired, catalog.saveConfirmed(a, std.testing.io, tmp.dir, "hosts.toml", &registry, call));
    try std.testing.expectEqual(@as(usize, 0), registry.hosts.len);
    call.approval_sequence = 1;
    var result = try catalog.saveConfirmed(a, std.testing.io, tmp.dir, "hosts.toml", &registry, call);
    defer result.deinit(a);
    try result.validate(context(), 8);
    try std.testing.expect(result.receipt.side_effect_started);
    try std.testing.expectEqual(@as(usize, 1), registry.hosts.len);
    const parsed = try parseArguments(result.blocks[0].structured);
    defer parsed.deinit();
    try std.testing.expect(parsed.value.object.get("saved").?.bool);
    try std.testing.expect(!parsed.value.object.get("connection_started").?.bool);
    const reference = parsed.value.object.get("host").?.object.get("source_ref").?.string;
    try std.testing.expectEqual(registry.hosts[0].owner(), try lifecycle.connectionOwner(context(), reference));
    var saved = try @import("config/store.zig").loadHosts(std.testing.io, tmp.dir, a, "hosts.toml");
    defer saved.deinit();
    try std.testing.expectEqual(registry.hosts[0].owner(), saved.hosts[0].owner());
    try std.testing.expectEqual(hosts.AuthMode.password, saved.hosts[0].auth_mode);
    try std.testing.expect(saved.hosts[0].password == null and saved.hosts[0].password_ref == null);
    try std.testing.expectEqual(@as(u16, 2222), saved.hosts[0].port);
    const revision = registry.revision;
    const next_id = registry.connection_ids.next_value;
    try std.testing.expectError(error.DuplicateConnectionName, catalog.saveConfirmed(a, std.testing.io, tmp.dir, "hosts.toml", &registry, call));
    try std.testing.expectEqual(@as(usize, 1), registry.hosts.len);
    try std.testing.expectEqual(revision, registry.revision);
    try std.testing.expectEqual(next_id, registry.connection_ids.next_value);
}

test "host catalog failed atomic save retains original static registry and identity watermark" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var registry = try hosts.Registry.parse(a, "");
    defer registry.deinit();
    registry.source_hash = null;
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "hosts.toml", .data = "# external change\n" });
    const wire = "{\"request_key\":\"create-fixture\",\"name\":\"fixture\",\"host\":\"192.0.2.1\",\"user\":\"tester\"}";
    const args = try parseArguments(wire);
    defer args.deinit();
    var call = try invocation("host.create_host", args.value, wire);
    call.approval_sequence = 1;
    const next_id = registry.connection_ids.next_value;
    try std.testing.expectError(error.FileConflict, catalog.saveConfirmed(a, std.testing.io, tmp.dir, "hosts.toml", &registry, call));
    try std.testing.expectEqual(@as(usize, 0), registry.hosts.len);
    try std.testing.expectEqual(next_id, registry.connection_ids.next_value);
    try std.testing.expectEqual(@as(u64, 1), registry.revision);
    const bytes = try tmp.dir.readFileAlloc(std.testing.io, "hosts.toml", a, .limited(1024));
    defer a.free(bytes);
    try std.testing.expectEqualStrings("# external change\n", bytes);
}

test "host catalog durable request key replays original asset across call changes and restart" {
    const runtime = @import("ai/host_catalog_runtime.zig");
    const ProcessJournal = @import("ai/lifecycle_runtime.zig").ProcessJournal;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var registry = try hosts.Registry.parse(a, "");
    defer registry.deinit();
    registry.source_hash = null;
    const wire = "{\"request_key\":\"save-once\",\"name\":\"fixture\",\"host\":\"192.0.2.1\",\"user\":\"tester\"}";
    const args = try parseArguments(wire);
    defer args.deinit();
    var call = try invocation("host.create_host", args.value, wire);
    call.approval_sequence = 1;
    const owner = try ProcessJournal.acquire(.{ .data_root = "/test/catalog-idempotency", .dir = tmp.dir, .io = std.testing.io });
    var operation = try runtime.begin(owner, call, a);
    const operation_id = operation.handle.operation_ref;
    try operation.dispatched();
    var first = try catalog.saveConfirmedOperation(a, std.testing.io, tmp.dir, "hosts.toml", &registry, call, operation_id);
    defer first.deinit(a);
    const saved_owner = try runtime.createdOwner(first, context());
    try operation.succeeded(saved_owner);
    operation.deinit(a);
    owner.release();

    const reopened = try ProcessJournal.acquire(.{ .data_root = "/test/catalog-idempotency", .dir = tmp.dir, .io = std.testing.io });
    defer reopened.release();
    call.call_id = "a-different-provider-call";
    call.turn_id += 1;
    call.operation_id += 1;
    call.approval_sequence = null; // Replaying a receipt does not mint approval.
    var repeat = try runtime.begin(reopened, call, a);
    defer repeat.deinit(a);
    try std.testing.expect(repeat.handle.reused and repeat.handle.operation_ref.eql(operation_id));
    var replay = try repeat.replay(&registry, call, a);
    defer replay.deinit(a);
    try replay.validate(call.context, call.operation_id);
    try std.testing.expectEqual(saved_owner, try runtime.createdOwner(replay, context()));
    const parsed = try parseArguments(replay.blocks[0].structured);
    defer parsed.deinit();
    try std.testing.expect(parsed.value.object.get("idempotent_reuse").?.bool);
    try std.testing.expectEqual(@as(usize, 1), registry.hosts.len);
    try std.testing.expectError(error.OperationAlreadyStarted, repeat.dispatched());
    registry.hosts[0].revision += 1;
    try std.testing.expectError(error.SourceChanged, repeat.replay(&registry, call, a));
    registry.hosts[0].revision -= 1;
    const changed_wire = "{\"request_key\":\"save-once\",\"name\":\"fixture\",\"host\":\"192.0.2.2\",\"user\":\"tester\"}";
    const changed_args = try parseArguments(changed_wire);
    defer changed_args.deinit();
    try std.testing.expectError(error.IdempotencyConflict, runtime.begin(reopened, try invocation("host.create_host", changed_args.value, changed_wire), a));
    try std.testing.expectEqual(@as(usize, 1), registry.hosts.len);
}

test "host catalog save-before-journal crash stays unknown and never guesses or repeats the asset" {
    const runtime = @import("ai/host_catalog_runtime.zig");
    const ProcessJournal = @import("ai/lifecycle_runtime.zig").ProcessJournal;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var registry = try hosts.Registry.parse(a, "");
    defer registry.deinit();
    registry.source_hash = null;
    const wire = "{\"request_key\":\"unknown-save\",\"name\":\"fixture\",\"host\":\"192.0.2.1\",\"user\":\"tester\"}";
    const args = try parseArguments(wire);
    defer args.deinit();
    var call = try invocation("host.create_host", args.value, wire);
    call.approval_sequence = 1;
    const owner = try ProcessJournal.acquire(.{ .data_root = "/test/catalog-unknown", .dir = tmp.dir, .io = std.testing.io });
    var operation = try runtime.begin(owner, call, a);
    const operation_id = operation.handle.operation_ref;
    try operation.dispatched();
    var saved = try catalog.saveConfirmedOperation(a, std.testing.io, tmp.dir, "hosts.toml", &registry, call, operation_id);
    saved.deinit(a);
    // Simulate process loss before succeeded(asset): the host was saved, but
    // neither its name nor an allocator watermark can prove the operation.
    operation.deinit(a);
    owner.release();
    const reopened = try ProcessJournal.acquire(.{ .data_root = "/test/catalog-unknown", .dir = tmp.dir, .io = std.testing.io });
    defer reopened.release();
    var retry = try runtime.begin(reopened, call, a);
    defer retry.deinit(a);
    try std.testing.expect(retry.handle.reused and retry.handle.operation_ref.eql(operation_id));
    try std.testing.expectEqual(@import("ai/lifecycle_journal.zig").Stage.outcome_unknown, retry.record.stage);
    try std.testing.expect(retry.record.created_asset == null);
    var result = try retry.replay(&registry, call, a);
    defer result.deinit(a);
    try std.testing.expectEqual(@import("ai/plugin_tools.zig").Status.outcome_unknown, result.status);
    try std.testing.expectEqual(@as(usize, 1), registry.hosts.len);
    try std.testing.expectError(error.OperationAlreadyStarted, retry.dispatched());
}

test "host catalog rejected key is durable and a different task creates a separate operation" {
    const runtime = @import("ai/host_catalog_runtime.zig");
    const ProcessJournal = @import("ai/lifecycle_runtime.zig").ProcessJournal;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var registry = try hosts.Registry.parse(a, "");
    defer registry.deinit();
    const owner = try ProcessJournal.acquire(.{ .data_root = "/test/catalog-rejected", .dir = tmp.dir, .io = std.testing.io });
    defer owner.release();
    const wire = "{\"request_key\":\"rejected-save\",\"name\":\"fixture\",\"host\":\"192.0.2.1\",\"user\":\"tester\"}";
    const args = try parseArguments(wire);
    defer args.deinit();
    var call = try invocation("host.create_host", args.value, wire);
    var operation = try runtime.begin(owner, call, a);
    defer operation.deinit(a);
    try operation.failed(error.ToolApprovalRejected);
    var retry = try runtime.begin(owner, call, a);
    defer retry.deinit(a);
    var result = try retry.replay(&registry, call, a);
    defer result.deinit(a);
    try std.testing.expectEqual(@import("ai/plugin_tools.zig").Status.rejected, result.status);
    try std.testing.expect(!result.receipt.side_effect_started);
    try std.testing.expectEqual(@as(usize, 0), registry.hosts.len);
    call.context.task_id.bytes[0] += 1;
    var other_task = try runtime.begin(owner, call, a);
    defer other_task.deinit(a);
    try std.testing.expect(!other_task.handle.reused and !other_task.handle.operation_ref.eql(operation.handle.operation_ref));
    try other_task.failed(error.CancelledBeforeDispatch);
}
