const std = @import("std");
const queries = @import("ai/host_terminal_queries.zig");
const host = @import("ai/host_tools.zig");
const identity = @import("host/identity.zig");
const terminal = @import("host/terminal_service.zig");
const Adapter = @import("vt/ghostty_adapter.zig").Adapter;
const Source = @import("ui/terminal_document_source.zig").Source;
const a = std.testing.allocator;
const owner: identity.SessionHandle = .{ .session_id = @fromBackingInt(81), .generation = 2 };
const context: host.Context = .{ .conversation_id = .{ .bytes = @splat(1) }, .task_id = .{ .bytes = @splat(2) }, .binding = .{ .session = 81 }, .binding_revision = 1, .grant_revision = 1 };
fn call(tool: []const u8, arguments: std.json.Value) host.Invocation {
    return .{ .context = context, .authority = .conversation_context, .operation_id = 1, .turn_id = 1, .call_id = "call-1", .tool_id = tool, .arguments = arguments, .arguments_json = "", .arguments_hash = @splat(0), .canonical_arguments_hash = @splat(0) };
}
fn content(raw: *anyopaque, _: @import("host/session_host.zig").ServiceHandle, request: terminal.ContentRequest, allocator: std.mem.Allocator) !terminal.ContentCapture {
    const source: *Source = @ptrCast(@alignCast(raw));
    return source.adapter.contentQuery(source.owner, request, allocator);
}
fn parsed(text: []const u8) !std.json.Parsed(std.json.Value) {
    return std.json.parseFromSlice(std.json.Value, a, text, .{});
}
fn ref() ![]const u8 {
    return @import("ai/host_queries.zig").sessionRef(a, context, owner);
}
fn args(reference: []const u8, fields: []const u8) !std.json.Parsed(std.json.Value) {
    const json = try std.fmt.allocPrint(a, "{{\"session_ref\":\"{s}\"{s}}}", .{ reference, fields });
    defer a.free(json);
    return parsed(json);
}
fn snapshot(source: *Source, hooks: *const terminal.Service.VTable) queries.Snapshot {
    var service = source.service();
    service.vtable = hooks;
    return .{ .context = context, .observed_at = 100, .cursor_key = @splat(5), .source = .{ .owner = owner, .service = service } };
}

test "PATCH terminal content schemas remain separate from six metadata queries" {
    try std.testing.expectEqual(@as(usize, 6), @import("ai/host_queries.zig").contributions.len);
    try std.testing.expectEqual(@as(usize, 3), queries.contributions.len);
    for (queries.contributions) |contribution| {
        try @import("ai/plugin_tools.zig").validateDefinition(contribution.definition);
        try std.testing.expect(!@import("ai/host_queries.zig").supports(contribution.definition.id));
    }
}

test "PATCH terminal content validates source and matching range fields" {
    const invalid = [_][]const u8{
        "{}",                                                               "{\"session_ref\":\"s\",\"recording_ref\":\"r\"}",
        "{\"session_ref\":\"s\",\"range_kind\":\"tail\",\"start_line\":0}", "{\"session_ref\":\"s\",\"range_kind\":\"lines\",\"start_line\":2,\"end_line\":1}",
        "{\"session_ref\":\"s\",\"range_kind\":\"time\",\"start_ms\":2}",   "{\"session_ref\":\"s\",\"range_kind\":\"cursor\"}",
        "{\"session_ref\":\"s\",\"max_lines\":501}",                        "{\"session_ref\":\"s\",\"max_bytes\":65537}",
        "{\"session_ref\":\"s\",\"unknown\":true}",
    };
    for (invalid) |text| {
        var value = try parsed(text);
        defer value.deinit();
        if (queries.parse("host.read_terminal", value.value)) |_| return error.ExpectedRejection else |_| {}
    }
    var regex = try parsed("{\"session_ref\":\"s\",\"query\":\"a.*\",\"match_kind\":\"regex\"}");
    defer regex.deinit();
    try std.testing.expectError(error.UnsupportedRegex, queries.parse("host.search_terminal", regex.value));
}

test "PATCH terminal bounded logical ranges read early history without moving viewport" {
    var adapter = try Adapter.init(a, 3, 8);
    defer adapter.destroy();
    _ = try adapter.feed("abcdef界e\u{301}👩‍💻XYZ\r\nsecond\r\nthird\r\nfourth\r\n");
    const before = adapter.viewportOffset();
    var captured = try adapter.contentQuery(owner, .{ .range_kind = .lines, .start_line = 0, .end_line = 1, .max_lines = 1 }, a);
    defer captured.deinit(a);
    try std.testing.expectEqualStrings("abcdef界e\u{301}👩‍💻XYZ", captured.lines[0].text);
    try std.testing.expectEqual(@as(u64, 0), captured.lines[0].line);
    try std.testing.expect(captured.lines[0].last_row > captured.lines[0].first_row);
    try std.testing.expect(captured.truncated and captured.next_line.? == 1);
    try std.testing.expectEqual(before, adapter.viewportOffset());
    var next = try adapter.contentQuery(owner, .{ .range_kind = .lines, .expected_version = captured.source_revision, .start_line = 0, .end_line = 1, .after_line = 1 }, a);
    defer next.deinit(a);
    try std.testing.expectEqualStrings("second", next.lines[0].text);
    _ = try adapter.feed("change");
    try std.testing.expectError(error.SnapshotChanged, adapter.contentQuery(owner, .{ .expected_version = captured.source_revision }, a));
    try std.testing.expectError(error.ResultLimit, adapter.contentQuery(owner, .{ .range_kind = .lines, .start_line = 0, .end_line = 0, .max_bytes = 1 }, a));
}

test "PATCH terminal read and search cursors bind source generation task filters and revision" {
    var adapter = try Adapter.init(a, 3, 20);
    defer adapter.destroy();
    _ = try adapter.feed("needle needle\r\nsecond needle\r\nthird\r\n");
    var source: Source = .{ .adapter = &adapter, .owner = owner };
    var hooks = source.service().vtable.*;
    hooks.content_query = content;
    const s = snapshot(&source, &hooks);
    const reference = try ref();
    defer a.free(reference);
    var arguments = try args(reference, ",\"range_kind\":\"lines\",\"start_line\":0,\"end_line\":2,\"max_lines\":1");
    defer arguments.deinit();
    var read = try queries.execute(s, call("host.read_terminal", arguments.value), null, 0, a);
    defer read.deinit(a);
    try read.validate(context, 1);
    var body = try parsed(read.blocks[0].structured);
    defer body.deinit();
    try std.testing.expectEqualStrings("needle needle", body.value.object.get("lines").?.array.items[0].object.get("text").?.string);
    const cursor = body.value.object.get("next_cursor").?.string;
    const fields = try std.fmt.allocPrint(a, ",\"range_kind\":\"cursor\",\"cursor\":\"{s}\",\"max_lines\":1", .{cursor});
    defer a.free(fields);
    var continuation = try args(reference, fields);
    defer continuation.deinit();
    var next = try queries.execute(s, call("host.read_terminal", continuation.value), null, 0, a);
    defer next.deinit(a);
    try std.testing.expect(std.mem.indexOf(u8, next.blocks[0].structured, "second needle") != null);
    var changed = s;
    changed.context.task_id.bytes = @splat(9);
    var changed_call = call("host.read_terminal", continuation.value);
    changed_call.context = changed.context;
    try std.testing.expectError(error.CursorExpired, queries.execute(changed, changed_call, null, 0, a));
    var foreign = s;
    foreign.source.owner.generation += 1;
    try std.testing.expectError(error.StaleReference, queries.execute(foreign, call("host.read_terminal", continuation.value), null, 0, a));
    var search_args = try args(reference, ",\"query\":\"needle\",\"range_kind\":\"lines\",\"start_line\":0,\"end_line\":2,\"limit\":1");
    defer search_args.deinit();
    var search = try queries.execute(s, call("host.search_terminal", search_args.value), null, 0, a);
    defer search.deinit(a);
    var search_body = try parsed(search.blocks[0].structured);
    defer search_body.deinit();
    try std.testing.expectEqual(@as(usize, 1), search_body.value.object.get("matches").?.array.items.len);
    const search_fields = try std.fmt.allocPrint(a, ",\"range_kind\":\"cursor\",\"query\":\"needle\",\"cursor\":\"{s}\",\"limit\":1", .{search_body.value.object.get("next_cursor").?.string});
    defer a.free(search_fields);
    var search_next_args = try args(reference, search_fields);
    defer search_next_args.deinit();
    var search_next = try queries.execute(s, call("host.search_terminal", search_next_args.value), null, 0, a);
    defer search_next.deinit(a);
    var search_next_body = try parsed(search_next.blocks[0].structured);
    defer search_next_body.deinit();
    try std.testing.expectEqual(@as(i64, 7), search_next_body.value.object.get("matches").?.array.items[0].object.get("start_byte").?.integer);
    _ = try adapter.feed("revision change");
    try std.testing.expectError(error.SnapshotChanged, queries.execute(s, call("host.read_terminal", continuation.value), null, 0, a));
}

test "PATCH terminal command index is typed partial and never infers prompt commands or exit" {
    var adapter = try Adapter.init(a, 3, 40);
    defer adapter.destroy();
    _ = try adapter.feed("$ fake-command\r\n");
    var source: Source = .{ .adapter = &adapter, .owner = owner };
    var hooks = source.service().vtable.*;
    hooks.content_query = content;
    const s = snapshot(&source, &hooks);
    const reference = try ref();
    defer a.free(reference);
    var arguments = try args(reference, "");
    defer arguments.deinit();
    try std.testing.expectError(error.CommandIndexUnavailable, queries.execute(s, call("host.list_terminal_commands", arguments.value), null, 0, a));
    const commands = [_]queries.Command{.{ .reference = "c1:known-host-record", .submitted_command = "printf 中文", .submitted_at_ms = 40 }};
    var listed = try queries.execute(s, call("host.list_terminal_commands", arguments.value), &commands, 1, a);
    defer listed.deinit(a);
    try std.testing.expect(std.mem.indexOf(u8, listed.blocks[0].structured, "fake-command") == null);
    try std.testing.expect(std.mem.indexOf(u8, listed.blocks[0].structured, "\"complete\":false") != null);
    try std.testing.expect(std.mem.indexOf(u8, listed.blocks[0].structured, "\"exit_code\":null") != null);
    try std.testing.expect(std.mem.indexOf(u8, listed.blocks[0].structured, "printf 中文") != null);
    var fake_exit = commands;
    fake_exit[0].exit_code = 0;
    try std.testing.expectError(error.InvalidCommandIndex, queries.execute(s, call("host.list_terminal_commands", arguments.value), &fake_exit, 1, a));
}

test "PATCH terminal UI gate rejects invalid source and uncaptured generation before resolving app services" {
    const ui_queries = @import("ui/ai_host_terminal_queries.zig");
    var app: @import("ui/application_host.zig").ApplicationHost = undefined;
    var empty = try parsed("{}");
    defer empty.deinit();
    const options: ui_queries.Options = .{ .captured_scope = .{ .owner = context.binding, .members = .{} }, .captured_handles = &.{} };
    try std.testing.expectError(error.InvalidArguments, ui_queries.execute(&app, null, options, @splat(1), call("host.read_terminal", empty.value), a));
    const reference = try ref();
    defer a.free(reference);
    var valid = try args(reference, "");
    defer valid.deinit();
    var captured_options = options;
    captured_options.captured_scope.members.ids[0] = 81;
    captured_options.captured_scope.members.len = 1;
    try std.testing.expectError(error.StaleReference, ui_queries.execute(&app, null, captured_options, @splat(1), call("host.read_terminal", valid.value), a));
}

fn fakeTime() i64 {
    return 500;
}
test "PATCH terminal time ranges use receive metadata and expose unknown timestamps" {
    var adapter = try Adapter.init(a, 3, 40);
    defer adapter.destroy();
    adapter.wall_clock_ms = fakeTime;
    _ = try adapter.feed("received\r\n");
    var found = try adapter.contentQuery(owner, .{ .range_kind = .time, .start_ms = 500, .end_ms = 500 }, a);
    defer found.deinit(a);
    try std.testing.expect(found.lines.len > 0);
    try std.testing.expectEqual(@as(?i64, 500), found.lines[0].received_at_ms);
    try std.testing.expectEqualStrings("received", found.lines[0].text);
    var empty_adapter = try Adapter.init(a, 3, 40);
    defer empty_adapter.destroy();
    var unknown = try empty_adapter.contentQuery(owner, .{ .range_kind = .time, .start_ms = 0, .end_ms = 999 }, a);
    defer unknown.deinit(a);
    try std.testing.expect(unknown.unknown_timestamps);
    try std.testing.expectEqual(@as(usize, 0), unknown.lines.len);
}

test "PATCH terminal command cursor preserves time filter and refuses changed filters" {
    var adapter = try Adapter.init(a, 3, 40);
    defer adapter.destroy();
    var source: Source = .{ .adapter = &adapter, .owner = owner };
    var hooks = source.service().vtable.*;
    hooks.content_query = content;
    const s = snapshot(&source, &hooks);
    const reference = try ref();
    defer a.free(reference);
    const commands = [_]queries.Command{
        .{ .reference = "old", .submitted_command = "old", .submitted_at_ms = 1 },
        .{ .reference = "c1", .submitted_command = "one", .submitted_at_ms = 10 },
        .{ .reference = "c2", .submitted_command = "two", .submitted_at_ms = 20 },
    };
    var arguments = try args(reference, ",\"start_ms\":10,\"end_ms\":20,\"limit\":1");
    defer arguments.deinit();
    var first = try queries.execute(s, call("host.list_terminal_commands", arguments.value), &commands, 4, a);
    defer first.deinit(a);
    var first_body = try parsed(first.blocks[0].structured);
    defer first_body.deinit();
    const fields = try std.fmt.allocPrint(a, ",\"cursor\":\"{s}\",\"limit\":1", .{first_body.value.object.get("next_cursor").?.string});
    defer a.free(fields);
    var continued_args = try args(reference, fields);
    defer continued_args.deinit();
    var second = try queries.execute(s, call("host.list_terminal_commands", continued_args.value), &commands, 4, a);
    defer second.deinit(a);
    try std.testing.expect(std.mem.indexOf(u8, second.blocks[0].structured, "two") != null);
    try std.testing.expect(std.mem.indexOf(u8, second.blocks[0].structured, "old") == null);
    try std.testing.expectError(error.CursorExpired, queries.execute(s, call("host.list_terminal_commands", continued_args.value), &commands, 5, a));
}

test "PATCH terminal recording references are conversation bound and require exact source grant" {
    var adapter = try Adapter.init(a, 3, 40);
    defer adapter.destroy();
    _ = try adapter.feed("retained recording slice\r\n");
    var source: Source = .{ .adapter = &adapter, .owner = owner };
    var hooks = source.service().vtable.*;
    hooks.content_query = content;
    var s = snapshot(&source, &hooks);
    const recording_id: [32]u8 = @splat('1');
    const recording = try queries.recordingRef(a, context, recording_id, 3);
    defer a.free(recording);
    const wire = try std.fmt.allocPrint(a, "{{\"recording_ref\":\"{s}\"}}", .{recording});
    defer a.free(wire);
    var arguments = try parsed(wire);
    defer arguments.deinit();
    try std.testing.expectError(error.RangeUnavailable, queries.execute(s, call("host.read_terminal", arguments.value), null, 0, a));
    s.source.recording_ref = recording;
    var read = try queries.execute(s, call("host.read_terminal", arguments.value), null, 0, a);
    defer read.deinit(a);
    try std.testing.expect(std.mem.indexOf(u8, read.blocks[0].structured, "retained recording slice") != null);
    try std.testing.expect(std.mem.indexOf(u8, read.blocks[0].structured, "retained_screen_only") != null);
    var other_context = context;
    other_context.conversation_id.bytes = @splat(9);
    try std.testing.expectError(error.StaleReference, queries.resolveRecording(other_context, recording));
}

test "PATCH terminal session metadata projects real retention ownership legal policies and recording reference" {
    const metadata = @import("ai/host_queries.zig");
    const sessions = [_]metadata.Session{.{ .handle = owner, .title = "local", .protocol = "local", .state = "ready", .ready = true, .connected = true, .task_owned = true, .ownership = .created_task, .ownership_revision = 4, .retention = .ask, .recording_id = @splat('1'), .recording_generation = 3, .control_state = "running", .has_control_lease = true, .input_ready = false, .local_released = false }};
    const reference = try ref();
    defer a.free(reference);
    var arguments = try args(reference, "");
    defer arguments.deinit();
    var got = try metadata.execute(.{ .context = context, .initial_binding = context.binding, .execution_policy = .{ .execution_mode = .auto, .session_retention = .keep }, .permission_mode = .confirm, .observed_at = 10, .source_revision = 1, .cursor_key = @splat(1), .sessions = &sessions, .groups = &.{} }, call("host.get_session", arguments.value), a);
    defer got.deinit(a);
    var body = try parsed(got.blocks[0].structured);
    defer body.deinit();
    const session = body.value.object.get("session").?.object;
    try std.testing.expectEqualStrings("created_task", session.get("ownership").?.string);
    try std.testing.expectEqualStrings("ask", session.get("retention").?.string);
    try std.testing.expectEqualStrings("new_only", session.get("connection_policies").?.array.items[0].string);
    _ = try queries.resolveRecording(context, session.get("recording_ref").?.string);
    try std.testing.expect(session.get("control").?.object.get("lease_held").?.bool);
}

const execution_id: identity.ExecutionId = .{ .bytes = @splat(3) };
fn executionSnapshot(_: *anyopaque, _: @import("host/session_host.zig").ServiceHandle) !terminal.execution.Snapshot {
    return .{ .owner = owner, .execution_id = execution_id, .revision = 9, .output_scope = .session_interval, .output_attribution = .unverified };
}
fn executionOutput(_: *anyopaque, _: @import("host/session_host.zig").ServiceHandle, id: identity.ExecutionId, allocator: std.mem.Allocator, cursor: u64, maximum: usize) !terminal.execution.Output {
    if (!id.eql(execution_id)) return error.ExecutionNotFound;
    const text = "command-output\nsecond\n";
    if (cursor > text.len) return error.InvalidCursor;
    const end = @min(text.len, cursor + maximum);
    return .{ .bytes = try allocator.dupe(u8, text[@intCast(cursor)..@intCast(end)]), .start_cursor = cursor, .next_cursor = end, .gap = false, .truncated = end < text.len };
}

test "PATCH terminal command ranges use typed execution interval raw offsets without invented line index" {
    var adapter = try Adapter.init(a, 3, 40);
    defer adapter.destroy();
    var source: Source = .{ .adapter = &adapter, .owner = owner };
    var hooks = source.service().vtable.*;
    hooks.content_query = content;
    hooks.execution_snapshot = executionSnapshot;
    hooks.execution_output = executionOutput;
    const s = snapshot(&source, &hooks);
    const reference = try ref();
    defer a.free(reference);
    const commands = [_]queries.Command{.{ .reference = "typed-command", .execution_id = execution_id, .submitted_command = "printf" }};
    var arguments = try args(reference, ",\"range_kind\":\"command\",\"command_ref\":\"typed-command\",\"max_lines\":1");
    defer arguments.deinit();
    var first = try queries.execute(s, call("host.read_terminal", arguments.value), &commands, 1, a);
    defer first.deinit(a);
    var body = try parsed(first.blocks[0].structured);
    defer body.deinit();
    try std.testing.expectEqualStrings("execution_raw_byte_offsets", body.value.object.get("coordinate_basis").?.string);
    try std.testing.expectEqualStrings("command-output\n", body.value.object.get("terminal_output").?.string);
    try std.testing.expect(!body.value.object.get("complete").?.bool);
    const fields = try std.fmt.allocPrint(a, ",\"range_kind\":\"cursor\",\"cursor\":\"{s}\",\"max_lines\":1", .{body.value.object.get("next_cursor").?.string});
    defer a.free(fields);
    var continued = try args(reference, fields);
    defer continued.deinit();
    var next = try queries.execute(s, call("host.read_terminal", continued.value), null, 0, a);
    defer next.deinit(a);
    try std.testing.expect(std.mem.indexOf(u8, next.blocks[0].structured, "second") != null);
}
