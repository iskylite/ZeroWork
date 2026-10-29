const std = @import("std");
const journal = @import("lifecycle_journal.zig");
const identity = @import("../host/identity.zig");
const a = std.testing.allocator;
const io = std.testing.io;
fn request() journal.Request {
    return .{ .context = .{ .conversation_id = identity.ConversationId.generate(), .task_id = identity.TaskId.generate(), .binding = .{ .session = 101 }, .binding_revision = 1, .grant_revision = 1 }, .tool_id = "host.create_group", .request_key = "create-1", .canonical_hash = @splat(4), .turn_id = 1, .call_id = "provider-call-1" };
}

test "lifecycle journal durably reuses semantic keys across calls and restart without storing arguments" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var first = try journal.Journal.open(a, io, tmp.dir, "lifecycle.json");
    var input = request();
    const handle = try first.begin(input);
    input.call_id = "provider-retry-call-2";
    const repeated = try first.begin(input);
    try std.testing.expect(repeated.reused and repeated.operation_ref.eql(handle.operation_ref));
    try first.update(handle, 1, .{ .stage = .committed, .created_group = 7, .committed_binding = .{ .group = 7 }, .committed_binding_revision = 2, .notice_revision = 2 });
    first.deinit();
    var second = try journal.Journal.open(a, io, tmp.dir, "lifecycle.json");
    defer second.deinit();
    input.context.binding = .{ .group = 7 };
    input.context.binding_revision = 2;
    const recovered = try second.begin(input);
    try std.testing.expect(recovered.reused and recovered.operation_ref.eql(handle.operation_ref));
    var receipt = try second.snapshot(a, recovered);
    defer receipt.deinit(a);
    try std.testing.expectEqual(journal.Stage.committed, receipt.stage);
    try std.testing.expectEqual(@as(?u64, 7), receipt.created_group);
    try std.testing.expectEqual(@as(u64, 0), receipt.wire_notice_revision);
    try std.testing.expectEqualStrings("provider-call-1", receipt.original_call);
    try std.testing.expectEqual(@as(u64, 101), receipt.context.binding.session);
    input.canonical_hash[0] = 9;
    try std.testing.expectError(error.IdempotencyConflict, second.begin(input));
    input.context.task_id = identity.TaskId.generate();
    try std.testing.expect(!(try second.begin(input)).reused);
    const source = try tmp.dir.readFileAlloc(io, "lifecycle.json", a, .limited(journal.max_file_bytes));
    defer a.free(source);
    try std.testing.expect(std.mem.indexOf(u8, source, "canonical_hash") != null);
    try std.testing.expect(std.mem.indexOf(u8, source, "arguments_json") == null);
}

test "lifecycle journal recovers dispatched effects as unknown and never makes them dispatchable" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var first = try journal.Journal.open(a, io, tmp.dir, "journal.json");
    const input = request();
    const active = try first.begin(input);
    try first.update(active, 1, .{ .stage = .dispatch_started, .local_released = false });
    var unsent_input = input;
    unsent_input.request_key = "not-dispatched";
    const unsent = try first.begin(unsent_input);
    first.deinit();
    var second = try journal.Journal.open(a, io, tmp.dir, "journal.json");
    defer second.deinit();
    var active_fact = try second.snapshot(a, active);
    defer active_fact.deinit(a);
    var unsent_fact = try second.snapshot(a, unsent);
    defer unsent_fact.deinit(a);
    try std.testing.expect(active_fact.stage == .outcome_unknown and active_fact.remote_effect_unknown and !active_fact.local_released);
    try std.testing.expectEqual(journal.Stage.cancelled_unsent, unsent_fact.stage);
    try std.testing.expect((try second.begin(input)).reused);
    try std.testing.expectError(error.InvalidJournalTransition, second.update(active, active_fact.revision, .{ .stage = .dispatch_started }));
    try std.testing.expectError(error.JournalRevisionChanged, second.update(active, 1, .{ .stage = .outcome_unknown }));
}

test "journal failed publication preserves prior memory and durable receipts and unknown schemas" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var store = try journal.Journal.open(a, io, tmp.dir, "journal.json");
    const handle = try store.begin(request());
    const original = try tmp.dir.readFileAlloc(io, "journal.json", a, .limited(journal.max_file_bytes));
    defer a.free(original);
    try tmp.dir.writeFile(io, .{ .sub_path = "journal.json", .data = "external change" });
    try std.testing.expectError(error.JournalConflict, store.update(handle, 1, .{ .stage = .dispatch_started }));
    var fact = try store.snapshot(a, handle);
    defer fact.deinit(a);
    try std.testing.expectEqual(journal.Stage.prepared, fact.stage);
    try std.testing.expectEqual(@as(u64, 1), fact.revision);
    store.deinit();
    try tmp.dir.writeFile(io, .{ .sub_path = "journal.json", .data = "{\"schema_version\":99,\"records\":[]}" });
    try std.testing.expectError(error.UnsupportedJournalSchema, journal.Journal.open(a, io, tmp.dir, "journal.json"));
    const unchanged = try tmp.dir.readFileAlloc(io, "journal.json", a, .limited(1024));
    defer a.free(unchanged);
    try std.testing.expectEqualStrings("{\"schema_version\":99,\"records\":[]}", unchanged);
}

test "journal ownership handoff is irreversible and resource and notice identities are fenced" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var store = try journal.Journal.open(a, io, tmp.dir, "journal.json");
    defer store.deinit();
    var input = request();
    input.tool_id = "host.open_session";
    const handle = try store.begin(input);
    try store.update(handle, 1, .{ .stage = .dispatch_started, .local_released = false });
    try store.update(handle, 2, .{ .stage = .committed, .created_session = .{ .session_id = @fromBackingInt(9), .generation = 2 }, .ownership = .created_task, .notice_revision = 3 });
    try store.update(handle, 3, .{ .stage = .running, .ownership = .handed_to_user });
    try std.testing.expectError(error.OwnershipChanged, store.update(handle, 4, .{ .stage = .cleanup_pending, .ownership = .created_task }));
    try std.testing.expectError(error.ResourceIdentityChanged, store.update(handle, 4, .{ .stage = .cleanup_pending, .created_session = .{ .session_id = @fromBackingInt(9), .generation = 3 } }));
    try std.testing.expectError(error.StaleNotice, store.update(handle, 4, .{ .stage = .cleanup_pending, .wire_notice_revision = 4 }));
}

test "lifecycle execution receipts persist precise monotonic native and recording facts and old records stay readable" {
    const execution = @import("../host/terminal_execution.zig");
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var store = try journal.Journal.open(a, io, tmp.dir, "execution.json");
    var input = request();
    input.tool_id = "host.run_in_terminal";
    const handle = try store.begin(input);
    const id = identity.ExecutionId.generate();
    try store.update(handle, 1, .{ .stage = .dispatch_started, .execution = id, .local_released = false });
    var receipt: execution.PublicReceipt = .{ .execution_id = id, .command_hash = @splat(3), .input_fence = 7, .input_epoch = 2, .accepted_sequence = 3, .submit_sequence = 4, .submit_ack_sequence = 5, .submit_native_bytes = 156, .native_wake_written = true, .recording_id = "0123456789abcdef0123456789abcdef".*, .recording_generation = 1, .start = .{ .raw_offset = 100, .sequence = 1, .event_sequence = 4 }, .manifest_revision = 3 };
    try store.update(handle, 2, .{ .stage = .running, .execution_receipt = receipt, .local_released = false });
    var backwards = receipt;
    backwards.submit_native_bytes = 155;
    try std.testing.expectError(error.ExecutionReceiptRegression, store.update(handle, 3, .{ .stage = .outcome_unknown, .execution_receipt = backwards, .local_released = false, .remote_effect_unknown = true }));
    backwards = receipt;
    backwards.execution_id = .generate();
    try std.testing.expectError(error.ResourceIdentityChanged, store.update(handle, 3, .{ .stage = .outcome_unknown, .execution_receipt = backwards, .local_released = false, .remote_effect_unknown = true }));
    receipt.end = .{ .raw_offset = 140, .sequence = 2, .event_sequence = 9 };
    receipt.manifest_revision = 6;
    receipt.process = .{ .exit_code = 0, .foreground_finished = true };
    receipt.recording_settled = true;
    receipt.sealed = true;
    receipt.local_released = true;
    try store.update(handle, 3, .{ .stage = .succeeded, .execution_receipt = receipt });
    store.deinit();
    var recovered = try journal.Journal.open(a, io, tmp.dir, "execution.json");
    var fact = try recovered.snapshot(a, handle);
    defer fact.deinit(a);
    try std.testing.expect(fact.execution_receipt.?.sealed and fact.execution_receipt.?.native_wake_written);
    try std.testing.expectEqual(@as(u64, 156), fact.execution_receipt.?.submit_native_bytes);
    try std.testing.expectEqual(@as(u64, 9), fact.execution_receipt.?.end.?.event_sequence);
    recovered.deinit();
    // Legacy v1 JSON contains no execution_receipt member. Remove only that
    // member and prove the same committed operation remains readable.
    const source = try tmp.dir.readFileAlloc(io, "execution.json", a, .limited(journal.max_file_bytes));
    defer a.free(source);
    const parsed = try std.json.parseFromSlice(std.json.Value, a, source, .{});
    defer parsed.deinit();
    const old_receipt = parsed.value.object.get("records").?.array.items[0].object.getPtr("execution_receipt").?;
    for ([_][]const u8{ "output_scope", "output_attribution", "output_attribution_reason", "interval_saved" }) |field| _ = old_receipt.object.swapRemove(field);
    const prior_fields = try std.json.Stringify.valueAlloc(a, parsed.value, .{});
    defer a.free(prior_fields);
    try tmp.dir.writeFile(io, .{ .sub_path = "execution.json", .data = prior_fields });
    var prior_store = try journal.Journal.open(a, io, tmp.dir, "execution.json");
    var prior_fact = try prior_store.snapshot(a, handle);
    defer prior_fact.deinit(a);
    try std.testing.expect(prior_fact.execution_receipt.?.sealed and prior_fact.execution_receipt.?.output_scope == .exact and !prior_fact.execution_receipt.?.interval_saved);
    prior_store.deinit();
    _ = parsed.value.object.get("records").?.array.items[0].object.swapRemove("execution_receipt");
    const legacy = try std.json.Stringify.valueAlloc(a, parsed.value, .{});
    defer a.free(legacy);
    try tmp.dir.writeFile(io, .{ .sub_path = "execution.json", .data = legacy });
    var old = try journal.Journal.open(a, io, tmp.dir, "execution.json");
    defer old.deinit();
    var old_fact = try old.snapshot(a, handle);
    defer old_fact.deinit(a);
    try std.testing.expect(old_fact.stage == .succeeded and old_fact.execution_receipt == null);
}

test "lifecycle interval receipt owns attribution reasons across publication snapshots and restart" {
    const execution = @import("../host/terminal_execution.zig");
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var store = try journal.Journal.open(a, io, tmp.dir, "interval.json");
    var store_open = true;
    defer if (store_open) store.deinit();
    var input = request();
    input.tool_id = "host.run_in_terminal";
    const handle = try store.begin(input);
    const id = identity.ExecutionId.generate();
    try store.update(handle, 1, .{ .stage = .dispatch_started, .execution = id, .local_released = false });
    const borrowed = try a.dupe(u8, "OutputProcessIdentityUnknown");
    defer a.free(borrowed);
    var receipt: execution.PublicReceipt = .{ .execution_id = id, .command_hash = @splat(3), .input_fence = 7, .input_epoch = 2, .accepted_sequence = 3, .submit_sequence = 4, .submit_ack_sequence = 5, .submit_native_bytes = 156, .native_wake_written = true, .recording_id = "0123456789abcdef0123456789abcdef".*, .recording_generation = 1, .start = .{ .raw_offset = 100, .sequence = 1, .event_sequence = 4 }, .manifest_revision = 3, .output_scope = .session_interval, .output_attribution = .unverified, .output_attribution_reason = borrowed };
    try store.update(handle, 2, .{ .stage = .running, .execution_receipt = receipt, .local_released = false });
    borrowed[0] = 'X';
    var before = try store.snapshot(a, handle);
    defer before.deinit(a);
    try std.testing.expectEqualStrings("OutputProcessIdentityUnknown", before.execution_receipt.?.output_attribution_reason.?);
    const durable = try tmp.dir.readFileAlloc(io, "interval.json", a, .limited(journal.max_file_bytes));
    defer a.free(durable);
    try tmp.dir.writeFile(io, .{ .sub_path = "interval.json", .data = "external change" });
    receipt.output_attribution_reason = "ConcurrentOutputOwner";
    try std.testing.expectError(error.JournalConflict, store.update(handle, 3, .{ .stage = .running, .execution_receipt = receipt, .local_released = false }));
    var after_failure = try store.snapshot(a, handle);
    defer after_failure.deinit(a);
    try std.testing.expectEqualStrings("OutputProcessIdentityUnknown", after_failure.execution_receipt.?.output_attribution_reason.?);
    try tmp.dir.writeFile(io, .{ .sub_path = "interval.json", .data = durable });
    receipt.output_attribution = .concurrent_observed;
    receipt.end = .{ .raw_offset = 140, .sequence = 2, .event_sequence = 9 };
    receipt.manifest_revision = 6;
    receipt.process = .{ .exit_code = 0, .foreground_finished = true };
    receipt.recording_settled = true;
    receipt.interval_saved = true;
    receipt.local_released = true;
    try store.update(handle, 3, .{ .stage = .succeeded, .execution_receipt = receipt });
    try std.testing.expectEqualStrings("OutputProcessIdentityUnknown", before.execution_receipt.?.output_attribution_reason.?);
    store.deinit();
    store_open = false;
    var recovered = try journal.Journal.open(a, io, tmp.dir, "interval.json");
    defer recovered.deinit();
    var fact = try recovered.snapshot(a, handle);
    defer fact.deinit(a);
    const saved = fact.execution_receipt.?;
    try std.testing.expect(fact.stage == .succeeded and !fact.remote_effect_unknown);
    try std.testing.expect(saved.output_scope == .session_interval and saved.interval_saved and !saved.sealed and saved.output_attribution == .concurrent_observed);
    try std.testing.expectEqualStrings("ConcurrentOutputOwner", saved.output_attribution_reason.?);
    try std.testing.expect((try recovered.begin(input)).reused);
}
