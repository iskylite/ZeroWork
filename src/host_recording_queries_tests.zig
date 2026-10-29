const std = @import("std");
const backend = @import("ai/host_recording_queries.zig");
const queries = @import("ai/host_terminal_queries.zig");
const host = @import("ai/host_tools.zig");
const archive = @import("vt/session_archive.zig");
const identity = @import("host/identity.zig");
const a = std.testing.allocator;
const recording_id: [32]u8 = "11111111111111111111111111111111".*;
fn context() host.Context {
    return .{ .conversation_id = .{ .bytes = @splat(1) }, .task_id = .{ .bytes = @splat(2) }, .binding = .{ .session = 9 }, .binding_revision = 1, .grant_revision = 1 };
}
fn invoke(tool: []const u8, args_value: std.json.Value) host.Invocation {
    return .{ .context = context(), .authority = .conversation_context, .operation_id = 1, .turn_id = 1, .call_id = "test", .tool_id = tool, .arguments = args_value, .arguments_json = "{}", .arguments_hash = @splat(0), .canonical_arguments_hash = @splat(0) };
}
const Fixture = struct {
    tmp: std.testing.TmpDir,
    archive_: archive.Archive,
    grant: backend.Grant,
    fn init(kind: archive.manifest.SourceKind, cast: []const u8) !Fixture {
        var tmp = std.testing.tmpDir(.{});
        errdefer tmp.cleanup();
        try tmp.dir.createDirPath(std.testing.io, "logs/history");
        const file = try tmp.dir.createFile(std.testing.io, "logs/history/query.cast", .{ .read = true });
        try file.writeStreamingAll(std.testing.io, cast);
        const checksum = try archive.manifest.fingerprint(std.testing.io, file, cast.len);
        file.close(std.testing.io);
        const header = try std.json.parseFromSlice(std.json.Value, a, cast[0..std.mem.indexOfScalar(u8, cast, '\n').?], .{});
        defer header.deinit();
        try archive.manifest.save(a, std.testing.io, tmp.dir, "logs/history/query.session.json", .{
            .archive_key = "22222222222222222222222222222222",
            .recording_id = &recording_id,
            .manifest_revision = 7,
            .source_kind = kind,
            .started_ms = 1000,
            .ended_ms = 4000,
            .state = .closed,
            .coverage = .complete,
            .replayability = .verified,
            .recording = .{ .generations = &.{.{ .recording_generation = 2, .session_id = 9, .session_generation = 3, .initial_cols = @intCast(header.value.object.get("width").?.integer), .initial_rows = @intCast(header.value.object.get("height").?.integer), .receive_time_origin = 1000, .baselines = &.{.{ .event_sequence = 0, .raw_offset = 0, .kind = .initial_empty }} }} },
            .files = &.{.{ .path = "logs/history/query.cast", .kind = .cast, .committed_length = cast.len, .checksum = &checksum }},
        });
        return .{ .tmp = tmp, .archive_ = .{ .allocator = a, .io = std.testing.io, .dir = tmp.dir }, .grant = .{ .context = context(), .owner = .{ .session_id = @fromBackingInt(9), .generation = 3 }, .recording_id = recording_id, .recording_generation = 2, .manifest_path = "logs/history/query.session.json", .manifest_revision = 7, .origin = .task_owned_closed } };
    }
    fn deinit(self: *Fixture) void {
        self.tmp.cleanup();
    }
};
fn arguments(extra: []const u8) !std.json.Parsed(std.json.Value) {
    const reference = try queries.recordingRef(a, context(), recording_id, 2);
    defer a.free(reference);
    const wire = try std.fmt.allocPrint(a, "{{\"recording_ref\":\"{s}\"{s}}}", .{ reference, extra });
    defer a.free(wire);
    return std.json.parseFromSlice(std.json.Value, a, wire, .{ .allocate = .alloc_always });
}
const fixture_cast = "{\"version\":2,\"width\":8,\"height\":2}\n[0,\"o\",\"abcdefghijk\\r\\nsecond\\r\\nlast\"]\n[1,\"o\",\"!\"]\n";

test "recording_query closed Local and SSH fixtures decode genuine soft wrapped logical lines" {
    for ([_]archive.manifest.SourceKind{ .local, .ssh }) |kind| {
        var fixture = try Fixture.init(kind, fixture_cast);
        defer fixture.deinit();
        var service: backend.Backend = .{ .archive = fixture.archive_, .grants = &.{fixture.grant} };
        defer service.deinit();
        const args = try arguments(",\"range_kind\":\"lines\",\"start_line\":0,\"end_line\":0");
        defer args.deinit();
        var result = try service.execute(invoke("host.read_terminal", args.value), a);
        defer result.deinit(a);
        const parsed = try std.json.parseFromSlice(std.json.Value, a, result.blocks[0].structured, .{});
        defer parsed.deinit();
        try std.testing.expectEqualStrings("recorded_snapshot_logical_lines", parsed.value.object.get("coordinate_basis").?.string);
        try std.testing.expectEqualStrings("abcdefghijk", parsed.value.object.get("lines").?.array.items[0].object.get("text").?.string);
        try std.testing.expectEqual(@as(i64, 7), parsed.value.object.get("source_revision").?.integer);
        try std.testing.expect(!try archive.isReferenced(std.testing.io, fixture.tmp.dir, "logs/history/query.cast"));
    }
}

test "recording_query content grants reject guessed identities other Tasks owner and commit" {
    var fixture = try Fixture.init(.local, fixture_cast);
    defer fixture.deinit();
    const args = try arguments("");
    defer args.deinit();
    var service: backend.Backend = .{ .archive = fixture.archive_ };
    defer service.deinit();
    try std.testing.expectError(error.PermissionDenied, service.execute(invoke("host.read_terminal", args.value), a));
    service.grants = &.{fixture.grant};
    var invocation = invoke("host.read_terminal", args.value);
    invocation.context.task_id.bytes[0] = 3;
    try std.testing.expectError(error.PermissionDenied, service.execute(invocation, a));
    var wrong = fixture.grant;
    wrong.owner.generation = 4;
    service.grants = &.{wrong};
    try std.testing.expectError(error.StaleGeneration, service.execute(invoke("host.read_terminal", args.value), a));
    wrong = fixture.grant;
    wrong.manifest_revision = 8;
    service.grants = &.{wrong};
    try std.testing.expectError(error.StaleRecordingRevision, service.execute(invoke("host.read_terminal", args.value), a));
    try std.testing.expect(!try archive.isReferenced(std.testing.io, fixture.tmp.dir, "logs/history/query.cast"));
}

test "recording_query literal search and receive time ranges use recorded events" {
    var fixture = try Fixture.init(.ssh, fixture_cast);
    defer fixture.deinit();
    var service: backend.Backend = .{ .archive = fixture.archive_, .grants = &.{fixture.grant} };
    defer service.deinit();
    const search = try arguments(",\"query\":\"DEFG\",\"case_sensitive\":false");
    defer search.deinit();
    var result = try service.execute(invoke("host.search_terminal", search.value), a);
    defer result.deinit(a);
    const parsed = try std.json.parseFromSlice(std.json.Value, a, result.blocks[0].structured, .{});
    defer parsed.deinit();
    try std.testing.expectEqual(@as(usize, 1), parsed.value.object.get("matches").?.array.items.len);
    const timed = try arguments(",\"range_kind\":\"time\",\"start_ms\":0,\"end_ms\":500");
    defer timed.deinit();
    var timed_result = try service.execute(invoke("host.read_terminal", timed.value), a);
    defer timed_result.deinit(a);
    const time_json = try std.json.parseFromSlice(std.json.Value, a, timed_result.blocks[0].structured, .{});
    defer time_json.deinit();
    try std.testing.expectEqual(@as(i64, 0), time_json.value.object.get("snapshot_event").?.object.get("received_at_ms").?.integer);
    try std.testing.expect(time_json.value.object.get("lines").?.array.items.len > 0);
    try std.testing.expect(std.mem.indexOf(u8, timed_result.blocks[0].structured, "last!") == null);
}

test "recording_query missing typed command index remains unknown" {
    var fixture = try Fixture.init(.local, fixture_cast);
    defer fixture.deinit();
    var service: backend.Backend = .{ .archive = fixture.archive_, .grants = &.{fixture.grant} };
    defer service.deinit();
    const args = try arguments("");
    defer args.deinit();
    try std.testing.expectError(error.CommandIndexUnavailable, service.execute(invoke("host.list_terminal_commands", args.value), a));
    try std.testing.expect(!try archive.isReferenced(std.testing.io, fixture.tmp.dir, "logs/history/query.cast"));
}

test "recording_query lease positional reads are bounded and detect truncation" {
    var fixture = try Fixture.init(.local, fixture_cast);
    defer fixture.deinit();
    var lease = try archive.acquireLease(a, std.testing.io, fixture.tmp.dir, "logs/history/query.cast");
    defer lease.deinit();
    var bytes: [5]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 5), try lease.readRange(1, &bytes));
    try std.testing.expectEqualStrings(fixture_cast[1..6], &bytes);
    try std.testing.expectError(error.InvalidRecordingRange, lease.readRange(fixture_cast.len + 1, &bytes));
    const file = try fixture.tmp.dir.createFile(std.testing.io, "logs/history/query.cast", .{ .truncate = true });
    file.close(std.testing.io);
    try std.testing.expectError(error.RecordingChanged, lease.readRange(0, &bytes));
}

test "recording_query bounded scan cursor is single use expires cancels and releases group lease" {
    var bytes: std.ArrayList(u8) = .empty;
    defer bytes.deinit(a);
    try bytes.appendSlice(a, "{\"version\":2,\"width\":80,\"height\":2}\n");
    const long: [1024]u8 = @splat('x');
    for (0..300) |_| {
        try bytes.appendSlice(a, "[0,\"o\",\"\\r");
        try bytes.appendSlice(a, &long);
        try bytes.appendSlice(a, "\"]\n");
    }
    var fixture = try Fixture.init(.ssh, bytes.items);
    defer fixture.deinit();
    var service: backend.Backend = .{ .archive = fixture.archive_, .grants = &.{fixture.grant}, .now_override = 100 };
    defer service.deinit();
    const args = try arguments("");
    defer args.deinit();
    var first = try service.execute(invoke("host.read_terminal", args.value), a);
    defer first.deinit(a);
    const json = try std.json.parseFromSlice(std.json.Value, a, first.blocks[0].structured, .{});
    defer json.deinit();
    try std.testing.expectEqualStrings("verifying_committed_dependencies", json.value.object.get("phase").?.string);
    try std.testing.expect(json.value.object.get("scan_progress").?.object.get("verified_file_offset").?.integer <= 256 * 1024);
    const cursor = json.value.object.get("next_cursor").?.string;
    const extra = try std.fmt.allocPrint(a, ",\"range_kind\":\"cursor\",\"cursor\":\"{s}\"", .{cursor});
    defer a.free(extra);
    const next = try arguments(extra);
    defer next.deinit();
    try std.testing.expect(try archive.isReferenced(std.testing.io, fixture.tmp.dir, "logs/history/query.cast"));
    var second = try service.execute(invoke("host.read_terminal", next.value), a);
    defer second.deinit(a);
    try std.testing.expectError(error.CursorExpired, service.execute(invoke("host.read_terminal", next.value), a));
    service.cancel(context());
    try std.testing.expect(!try archive.isReferenced(std.testing.io, fixture.tmp.dir, "logs/history/query.cast"));
    var expiring = try service.execute(invoke("host.read_terminal", args.value), a);
    defer expiring.deinit(a);
    const expired_json = try std.json.parseFromSlice(std.json.Value, a, expiring.blocks[0].structured, .{});
    defer expired_json.deinit();
    const expired_extra = try std.fmt.allocPrint(a, ",\"range_kind\":\"cursor\",\"cursor\":\"{s}\"", .{expired_json.value.object.get("next_cursor").?.string});
    defer a.free(expired_extra);
    const expired_args = try arguments(expired_extra);
    defer expired_args.deinit();
    service.now_override = 60_101;
    service.expireIdle();
    try std.testing.expectError(error.CursorExpired, service.execute(invoke("host.read_terminal", expired_args.value), a));
    try std.testing.expect(!try archive.isReferenced(std.testing.io, fixture.tmp.dir, "logs/history/query.cast"));
}

test "recording_query checksum tampering and unavailable baseline release all leases" {
    var fixture = try Fixture.init(.local, fixture_cast);
    defer fixture.deinit();
    var service: backend.Backend = .{ .archive = fixture.archive_, .grants = &.{fixture.grant} };
    defer service.deinit();
    const args = try arguments("");
    defer args.deinit();
    const file = try fixture.tmp.dir.openFile(std.testing.io, "logs/history/query.cast", .{ .mode = .read_write });
    try file.writePositionalAll(std.testing.io, "!", 0);
    file.close(std.testing.io);
    try std.testing.expectError(error.RecordingChecksumMismatch, service.execute(invoke("host.read_terminal", args.value), a));
    try std.testing.expect(!try archive.isReferenced(std.testing.io, fixture.tmp.dir, "logs/history/query.cast"));
    const parsed = try archive.manifest.load(a, std.testing.io, fixture.tmp.dir, fixture.grant.manifest_path);
    defer parsed.deinit();
    var doc = parsed.value;
    doc.replayability = .baseline_unavailable;
    try archive.manifest.save(a, std.testing.io, fixture.tmp.dir, fixture.grant.manifest_path, doc);
    try std.testing.expectError(error.RecordingBaselineUnavailable, service.execute(invoke("host.read_terminal", args.value), a));
    try std.testing.expect(!try archive.isReferenced(std.testing.io, fixture.tmp.dir, fixture.grant.manifest_path));
}

test "recording_query typed application commands retain unknown exit and command output" {
    const owner: identity.SessionHandle = .{ .session_id = @fromBackingInt(9), .generation = 3 };
    const application: @import("host/terminal_service.zig").ApplicationRecord = .{ .id = 12, .owner = owner, .timestamp_ms = 1050, .command = "@help", .output = "genuine typed output\nnext", .state = .success };
    const record_json = try std.json.Stringify.valueAlloc(a, application, .{});
    defer a.free(record_json);
    const event = try std.json.Stringify.valueAlloc(a, .{ 0, "a", record_json }, .{});
    defer a.free(event);
    const cast_bytes = try std.fmt.allocPrint(a, "{{\"version\":2,\"width\":80,\"height\":2}}\n{s}\n", .{event});
    defer a.free(cast_bytes);
    var fixture = try Fixture.init(.local, cast_bytes);
    defer fixture.deinit();
    var service: backend.Backend = .{ .archive = fixture.archive_, .grants = &.{fixture.grant} };
    defer service.deinit();
    const args = try arguments("");
    defer args.deinit();
    var result = try service.execute(invoke("host.list_terminal_commands", args.value), a);
    defer result.deinit(a);
    const json = try std.json.parseFromSlice(std.json.Value, a, result.blocks[0].structured, .{});
    defer json.deinit();
    const command = json.value.object.get("commands").?.array.items[0];
    try std.testing.expectEqualStrings("@help", command.object.get("submitted_command").?.string);
    try std.testing.expect(command.object.get("exit_code").? == .null);
    try std.testing.expect(!json.value.object.get("complete").?.bool);
    const extra = try std.fmt.allocPrint(a, ",\"range_kind\":\"command\",\"command_ref\":\"{s}\"", .{command.object.get("reference").?.string});
    defer a.free(extra);
    const read_args = try arguments(extra);
    defer read_args.deinit();
    var read = try service.execute(invoke("host.read_terminal", read_args.value), a);
    defer read.deinit(a);
    try std.testing.expect(std.mem.indexOf(u8, read.blocks[0].structured, "genuine typed output") != null);
}

test "recording_query c1 command range selects only committed manifest event interval" {
    const cast_bytes = "{\"version\":2,\"width\":80,\"height\":2}\n[0,\"o\",\"before\"]\n[1,\"o\",\"actual interval\"]\n[2,\"o\",\"after\"]\n";
    var fixture = try Fixture.init(.ssh, cast_bytes);
    defer fixture.deinit();
    const parsed = try archive.manifest.load(a, std.testing.io, fixture.tmp.dir, fixture.grant.manifest_path);
    defer parsed.deinit();
    var doc = parsed.value;
    doc.events = &.{ .{ .sequence = 1, .raw_offset = 0, .raw_length = 6, .cast_line = 1, .kind = .output }, .{ .sequence = 3, .raw_offset = 6, .raw_length = 15, .cast_line = 2, .kind = .output }, .{ .sequence = 5, .raw_offset = 21, .raw_length = 5, .cast_line = 3, .kind = .output } };
    const execution_id = "33333333333333333333333333333333";
    doc.execution_ranges = &.{.{ .execution_id = execution_id, .recording_generation = 2, .start = .{ .raw_offset = 6, .event_sequence = 2 }, .end = .{ .raw_offset = 21, .event_sequence = 4 } }};
    try archive.manifest.save(a, std.testing.io, fixture.tmp.dir, fixture.grant.manifest_path, doc);
    var service: backend.Backend = .{ .archive = fixture.archive_, .grants = &.{fixture.grant} };
    defer service.deinit();
    const command_ref = try std.fmt.allocPrint(a, "c1:{s}:9:3:{s}", .{ std.fmt.bytesToHex(context().conversation_id.bytes, .lower), execution_id });
    defer a.free(command_ref);
    const extra = try std.fmt.allocPrint(a, ",\"range_kind\":\"command\",\"command_ref\":\"{s}\"", .{command_ref});
    defer a.free(extra);
    const args = try arguments(extra);
    defer args.deinit();
    var result = try service.execute(invoke("host.read_terminal", args.value), a);
    defer result.deinit(a);
    const json = try std.json.parseFromSlice(std.json.Value, a, result.blocks[0].structured, .{});
    defer json.deinit();
    try std.testing.expectEqualStrings("actual interval", json.value.object.get("output").?.string);
    try std.testing.expectEqualStrings("recorded_event_range", json.value.object.get("coordinate_basis").?.string);
}

test "recording_query UI history grant captures exact selected closed manifest" {
    const controller = @import("ui/ai_host_recording_queries.zig");
    var fixture = try Fixture.init(.local, fixture_cast);
    defer fixture.deinit();
    var resolved = try fixture.archive_.resolveRecord(a, .{ .recording_id = &recording_id });
    defer resolved.deinit();
    const grant = try controller.selectedHistory(context(), resolved.descriptor, 2);
    try std.testing.expectEqual(@as(u64, 7), grant.manifest_revision);
    try std.testing.expect(grant.owner.eql(fixture.grant.owner));
    try std.testing.expectEqualStrings(fixture.grant.manifest_path, grant.manifest_path);
    try std.testing.expectEqual(.explicit_history_selection, grant.origin);
}

test "recording_query time basis rejects absolute recording and elapsed live requests before IO" {
    const absolute = try arguments(",\"range_kind\":\"time\",\"start_ms\":1700000000000,\"end_ms\":1700000001000,\"time_basis\":\"client_receive_absolute_ms\"");
    defer absolute.deinit();
    var service: backend.Backend = .{ .archive = .{ .allocator = a, .io = undefined, .dir = undefined } };
    defer service.deinit();
    try std.testing.expectError(error.UnsupportedTimeBasis, service.execute(invoke("host.read_terminal", absolute.value), a));
    const elapsed = try arguments(",\"range_kind\":\"time\",\"start_ms\":0,\"end_ms\":1000,\"time_basis\":\"cast_first_event_elapsed_ms\"");
    defer elapsed.deinit();
    try std.testing.expectEqual(queries.TimeBasis.cast_first_event_elapsed_ms, (try queries.parse("host.read_terminal", elapsed.value)).time_basis);
    const live = try std.json.parseFromSlice(std.json.Value, a, "{\"session_ref\":\"live\",\"range_kind\":\"time\",\"start_ms\":0,\"end_ms\":1000,\"time_basis\":\"cast_first_event_elapsed_ms\"}", .{});
    defer live.deinit();
    try std.testing.expectError(error.UnsupportedTimeBasis, queries.parse("host.read_terminal", live.value));
    const schema = try std.json.parseFromSlice(std.json.Value, a, queries.contributions[0].definition.schema, .{});
    defer schema.deinit();
    const declared = schema.value.object.get("properties").?.object.get("time_basis").?.object.get("enum").?.array.items;
    try std.testing.expectEqualStrings("client_receive_absolute_ms", declared[0].string);
    try std.testing.expectEqualStrings("cast_first_event_elapsed_ms", declared[1].string);
}
