const std = @import("std");
const tools = @import("plugin_tools.zig");
const scope = @import("tool_scope.zig");
const identity = @import("../host/identity.zig");
const services = @import("../host/plugin_services.zig");
const operations = @import("../host/operation_store.zig");
const schema = "{\"type\":\"object\",\"additionalProperties\":false,\"properties\":{\"session_ids\":{\"type\":\"array\",\"minItems\":1,\"maxItems\":16,\"uniqueItems\":true,\"items\":{\"type\":\"integer\",\"minimum\":1}},\"value\":{\"type\":\"integer\",\"minimum\":0,\"maximum\":20}},\"required\":[\"session_ids\",\"value\"]}";
const captured: scope.Scope = .{ .owner = .{ .group = 7 }, .members = .{ .ids = .{ 101, 102 } ++ @as([14]u64, @splat(0)), .len = 2 } };
const Fake = struct {
    count: usize = 0,
    fail: bool = false,
    clock: i64 = 100,
    approve: bool = true,
    policy: tools.Policy = .{},
    members: []const tools.Member = &.{},
    fn handler(raw: *anyopaque, invocation: tools.Invocation, _: std.mem.Allocator) !tools.ToolResult {
        const self: *Fake = @ptrCast(@alignCast(raw));
        self.count += 1;
        if (self.fail) return error.ResponseLost;
        return .{ .status = .succeeded, .receipt = .{ .owner = invocation.owner, .operation_id = invocation.operation_id } };
    }
    fn liveScope(_: *anyopaque) !scope.Scope {
        return captured;
    }
    fn liveMembers(raw: *anyopaque) ![]const tools.Member {
        return @as(*Fake, @ptrCast(@alignCast(raw))).members;
    }
    fn policyNow(raw: *anyopaque) tools.Policy {
        return @as(*Fake, @ptrCast(@alignCast(raw))).policy;
    }
    fn now(raw: *anyopaque) i64 {
        return @as(*Fake, @ptrCast(@alignCast(raw))).clock;
    }
    fn approval(raw: *anyopaque, _: tools.DynamicInvocation, _: *tools.ApprovalTicket, _: ?*@import("provider.zig").CancelToken) !bool {
        return @as(*Fake, @ptrCast(@alignCast(raw))).approve;
    }
    fn runtime(self: *Fake, history: *operations.Store) tools.Runtime {
        return .{ .context = self, .live_scope = liveScope, .live_members = liveMembers, .current_policy = policyNow, .now_ms = now, .approval = approval, .operations = history };
    }
};
fn definition() tools.ToolDefinition {
    return .{ .id = "example.power_write", .schema = schema, .effect = .resource_write, .approval_policy = .always_confirm };
}
fn member(fake: *Fake, id: u64, bindings: []const tools.ToolBinding) tools.Member {
    return .{ .owner = .{ .session_id = @fromBackingInt(id), .generation = 3 }, .plugin_id = "example", .context = fake, .bindings = bindings };
}
const binding: tools.ToolBinding = .{ .plugin_id = "example", .definition_id = "example.power_write", .handler = Fake.handler };

test "session capabilities narrow each host execution source independently in a mixed group" {
    const a = std.testing.allocator;
    var fake: Fake = .{};
    const read_binding: tools.ToolBinding = .{ .plugin_id = "example", .definition_id = "read_terminal", .handler = Fake.handler };
    const members = [_]tools.Member{ member(&fake, 101, &.{read_binding}), member(&fake, 102, &.{read_binding}) };
    const context: tools.host.Context = .{ .conversation_id = .generate(), .task_id = .generate(), .binding = captured.owner, .binding_revision = 1, .grant_revision = 1 };
    var contributions = @import("host_terminal_queries.zig").contributions ++ @import("host_execution.zig").contributions;
    for (&contributions) |*contribution| {
        if (std.mem.eql(u8, contribution.definition.id, "host.run_in_terminal")) contribution.session_targets = &.{members[0].owner};
        if (std.mem.eql(u8, contribution.definition.id, "host.attach_shell")) contribution.session_targets = &.{members[1].owner};
    }
    var table = try tools.RequestTable.initWithHost(a, captured, &.{@import("legacy_adapter.zig").builtin_definitions[1]}, &members, context, &contributions);
    defer table.deinit();
    const Case = struct { id: []const u8, targets: []const identity.SessionHandle };
    for ([_]Case{
        .{ .id = "host.read_terminal", .targets = &.{ members[0].owner, members[1].owner } },
        .{ .id = "host.run_in_terminal", .targets = &.{members[0].owner} },
        .{ .id = "host.attach_shell", .targets = &.{members[1].owner} },
    }) |case| {
        var name: [64]u8 = undefined;
        const entry = table.lookup(try tools.encodeName(&name, case.id)).?;
        const parsed = try std.json.parseFromSlice(std.json.Value, a, entry.definition.schema, .{});
        defer parsed.deinit();
        const references = parsed.value.object.get("properties").?.object.get("session_ref").?.object.get("enum").?.array.items;
        try std.testing.expectEqual(case.targets.len, references.len);
        for (case.targets, references) |target, reference| {
            const expected = try @import("host_queries.zig").sessionRef(a, context, target);
            defer a.free(expected);
            try std.testing.expectEqualStrings(expected, reference.string);
        }
    }
    const wrong_ref = try @import("host_queries.zig").sessionRef(a, context, members[1].owner);
    defer a.free(wrong_ref);
    const arguments = try std.json.Stringify.valueAlloc(a, .{ .session_ref = wrong_ref, .command = "pwd", .request_key = "wrong-capability" }, .{});
    defer a.free(arguments);
    var name: [64]u8 = undefined;
    try std.testing.expectError(error.InvalidToolArguments, table.parse(a, try tools.encodeName(&name, "host.run_in_terminal"), arguments));
}

test "dynamic terminal read advertises only its captured capable targets without widening dispatch" {
    const a = std.testing.allocator;
    var fake: Fake = .{};
    const read_binding: tools.ToolBinding = .{ .plugin_id = "example", .definition_id = "read_terminal", .handler = Fake.handler };
    const read_definition = @import("legacy_adapter.zig").builtin_definitions[1];
    for ([_]bool{ false, true }) |second_authorized| {
        var members = [_]tools.Member{ member(&fake, 101, &.{read_binding}), member(&fake, 102, &.{read_binding}) };
        members[1].authorized = second_authorized;
        var table = try tools.RequestTable.init(a, captured, &.{read_definition}, &members);
        defer table.deinit();
        const wire = try tools.providerDefinitions(&table, table.arena.allocator());
        const parsed = try std.json.parseFromSlice(std.json.Value, a, wire[0].dynamic.?.schema, .{});
        defer parsed.deinit();
        const targets = parsed.value.object.get("properties").?.object.get("session_ids").?.object;
        const items = targets.get("items").?.object;
        const ids = items.get("enum").?.array.items;
        try std.testing.expectEqual(@as(usize, if (second_authorized) 2 else 1), ids.len);
        try std.testing.expectEqual(@as(i64, @intCast(ids.len)), targets.get("maxItems").?.integer);
        try std.testing.expectEqual(@as(i64, 1), items.get("minimum").?.integer);
        try std.testing.expectEqual(@as(i64, 101), ids[0].integer);
        if (second_authorized) try std.testing.expectEqual(@as(i64, 102), ids[1].integer);
        // The advertised narrowing is not substituted for the captured host
        // table or its independent dispatch checks.
        try std.testing.expectEqualStrings(read_definition.schema, table.entries[0].definition.schema);
        var accepted = try table.parse(a, "read_terminal", "{\"session_ids\":[101]}");
        accepted.deinit();
        if (!second_authorized) try std.testing.expectError(error.ToolCapabilityUnavailable, table.parse(a, "read_terminal", "{\"session_ids\":[102]}"));
        try std.testing.expectError(error.ToolCapabilityUnavailable, table.parse(a, "read_terminal", "{\"session_ids\":[999]}"));
    }
}

test "host terminal read replaces the legacy catalog and advertises authorized history references" {
    const a = std.testing.allocator;
    var fake: Fake = .{};
    const read_binding: tools.ToolBinding = .{ .plugin_id = "example", .definition_id = "read_terminal", .handler = Fake.handler };
    var members = [_]tools.Member{ member(&fake, 101, &.{read_binding}), member(&fake, 102, &.{read_binding}) };
    members[1].authorized = false;
    const context: @import("host_tools.zig").Context = .{ .conversation_id = .{ .bytes = @splat(1) }, .task_id = .{ .bytes = @splat(2) }, .binding = captured.owner, .binding_revision = 1, .grant_revision = 1 };
    var table = try tools.RequestTable.initWithHost(a, captured, &.{@import("legacy_adapter.zig").builtin_definitions[1]}, &members, context, &@import("host_terminal_queries.zig").contributions);
    defer table.deinit();
    try std.testing.expect(table.lookup("read_terminal") == null);
    try std.testing.expectError(error.ToolNotInRequest, table.parse(a, "read_terminal", "{\"session_ids\":[101]}"));
    try std.testing.expectEqual(@as(usize, 3), table.entries.len);
    var cloned = try tools.cloneTable(&table, a);
    defer cloned.deinit();
    const wire = try tools.providerDefinitions(&cloned, cloned.arena.allocator());
    try std.testing.expectEqual(@as(usize, 0), wire[0].session_ids.len);
    const body = try @import("provider_http.zig").requestBody(a, .openai_compat, .{ .model = "fixture", .system = "", .messages = &.{}, .tools = wire }, 200000);
    defer a.free(body);
    const read = wire[0].dynamic.?;
    try std.testing.expectEqualStrings("host.read_terminal", read.id);
    try std.testing.expectEqualStrings(cloned.lookup(read.name).?.definition.schema, read.schema);
    var loop = @import("tool_loop.zig").Loop.init(a, captured, 1, .{});
    defer loop.deinit();
    try loop.start(.{ .model = "fixture", .system = "", .messages = &.{}, .tools = wire, .tool_table = &cloned });
    const schema_value = try std.json.parseFromSlice(std.json.Value, a, read.schema, .{});
    defer schema_value.deinit();
    const properties = schema_value.value.object.get("properties").?.object;
    const references = properties.get("session_ref").?.object.get("enum").?.array.items;
    try std.testing.expectEqual(@as(usize, 1), references.len);
    const expected = try @import("host_queries.zig").sessionRef(a, context, members[0].owner);
    defer a.free(expected);
    try std.testing.expectEqualStrings(expected, references[0].string);
    for ([_][]const u8{ "recording_ref", "range_kind", "start_line", "end_line", "cursor", "max_lines", "max_bytes" }) |field| try std.testing.expect(properties.contains(field));
    const arguments = try std.fmt.allocPrint(a, "{{\"session_ref\":\"{s}\",\"range_kind\":\"lines\",\"start_line\":0,\"end_line\":200,\"max_lines\":20}}", .{expected});
    defer a.free(arguments);
    var parsed_call = try cloned.parse(a, read.name, arguments);
    defer parsed_call.deinit();
    const request = try @import("host_terminal_queries.zig").parse(read.id, parsed_call.json.value);
    try std.testing.expectEqual(.lines, request.range_kind);
    try std.testing.expectEqual(@as(usize, 20), request.max_lines);
}

test "dynamic tool directory keeps 300 frozen members while each call stays bounded" {
    const a = std.testing.allocator;
    var fake: Fake = .{};
    var ids: [300]u64 = undefined;
    var members: [300]tools.Member = undefined;
    for (&ids, &members, 1..) |*id, *target, value| {
        id.* = value;
        target.* = member(&fake, value, &.{binding});
    }
    const wide: scope.Scope = .{ .owner = .{ .group = 7 }, .members = .{}, .inventory = &ids };
    var table = try tools.RequestTable.init(a, wide, &.{definition()}, &members);
    defer table.deinit();
    var cloned = try tools.cloneTable(&table, a);
    defer cloned.deinit();
    ids[299] = 901;
    var parsed = try cloned.parse(a, cloned.entries[0].provider_name, "{\"session_ids\":[300,17],\"value\":1}");
    defer parsed.deinit();
    try std.testing.expectEqualSlices(u64, &.{ 300, 17 }, parsed.targets.slice());
    try std.testing.expectEqual(@as(usize, 300), cloned.entries[0].targets.len);
    try std.testing.expectError(error.ToolCapabilityUnavailable, cloned.parse(a, cloned.entries[0].provider_name, "{\"session_ids\":[901],\"value\":1}"));
    try std.testing.expectError(error.TargetOutsideAssistant, cloned.captured_scope.validate(&.{901}));
    const wire = try tools.providerDefinitions(&cloned, cloned.arena.allocator());
    var loop = @import("tool_loop.zig").Loop.init(a, cloned.captured_scope, 1, .{ .context_window = 100_000 });
    defer loop.deinit();
    try loop.start(.{ .model = "test", .system = "", .messages = &.{}, .tools = wire, .tool_table = &cloned });
    try std.testing.expectEqual(@as(usize, 300), loop.scope.memberIds().len);
    _ = try @import("provider_http.zig").requestBodySize(.openai_compat, try loop.nextRequest(), 100_000);
    try std.testing.expectError(error.InvalidTargetCount, loop.scope.validate(loop.scope.memberIds()));
}

test "API2 names are reversible collision-free and preserve all four legacy names" {
    for ([_][]const u8{ "fixture_probe.ping", "a__b.c_d", "plain-name", "run_command", "read_terminal", "list_remote_files", "read_remote_file" }) |id| {
        var encoded: [64]u8 = undefined;
        var decoded: [64]u8 = undefined;
        const name = try tools.encodeName(&encoded, id);
        try std.testing.expectEqualStrings(id, try tools.decodeName(&decoded, name));
        if (tools.legacyName(id)) try std.testing.expectEqualStrings(id, name);
    }
    var name: [64]u8 = undefined;
    try std.testing.expectError(error.InvalidToolId, tools.encodeName(&name, "a..b"));
    try std.testing.expectError(error.InvalidToolId, tools.encodeName(&name, "a/b"));
    try std.testing.expectError(error.ToolNameTooLong, tools.encodeName(&name, "_________________________________"));
}

test "API2 plugin contributions cannot impersonate the host namespace" {
    var fake: Fake = .{};
    const host_definition: tools.ToolDefinition = .{ .id = "host.get_current_context", .schema = "{\"type\":\"object\"}" };
    const host_binding: tools.ToolBinding = .{ .plugin_id = "example", .definition_id = host_definition.id, .handler = Fake.handler };
    try std.testing.expectError(error.ReservedToolNamespace, tools.validateBindings("example", &.{host_definition}, &.{host_binding}, &.{}));
    try std.testing.expectError(error.ReservedToolNamespace, tools.RequestTable.init(std.testing.allocator, captured, &.{host_definition}, &.{member(&fake, 101, &.{host_binding})}));
}

test "host table captures conversation authority without a fake member and cannot enter plugin runtime" {
    const a = std.testing.allocator;
    const context: tools.host.Context = .{ .conversation_id = identity.ConversationId.generate(), .task_id = identity.TaskId.generate(), .binding = .{ .group = 7 }, .binding_revision = 2, .grant_revision = 3 };
    const host_definition: tools.ToolDefinition = .{ .id = "host.get_current_context", .schema = "{\"type\":\"object\",\"properties\":{},\"additionalProperties\":false}" };
    const empty_scope: scope.Scope = .{ .owner = context.binding, .members = .{} };
    var table = try tools.RequestTable.initWithHost(a, empty_scope, &.{}, &.{}, context, &.{.{ .definition = host_definition, .authority = .conversation_context }});
    defer table.deinit();
    var cloned = try tools.cloneTable(&table, a);
    defer cloned.deinit();
    try std.testing.expect(context.eql(cloned.host_context.?));
    var call = try cloned.parse(a, cloned.entries[0].provider_name, "{}");
    defer call.deinit();
    try std.testing.expectEqual(@as(usize, 0), call.targets.len);
    try std.testing.expectEqual(@as(usize, 0), call.entry.targets.len);
    try std.testing.expectError(error.InvalidToolArguments, cloned.parse(a, call.entry.provider_name, "{\"session_ids\":[101]}"));
    var history = operations.Store.init(a);
    defer history.deinit();
    var fake: Fake = .{};
    try std.testing.expectError(error.InvalidHostAuthority, fake.runtime(&history).execute(.{ .table = &cloned, .parsed = call, .turn_id = 1, .call_id = "host-call", .arguments = "{}", .operation_id = 1 }, a, null));
    try std.testing.expectEqual(@as(usize, 0), fake.count);
    try std.testing.expectError(error.ToolDefinitionConflict, tools.RequestTable.initWithHost(a, empty_scope, &.{}, &.{}, context, &.{ .{ .definition = host_definition, .authority = .conversation_context }, .{ .definition = host_definition, .authority = .conversation_context } }));
}

test "API2 immutable request schemas validate generic values and each selected member" {
    const a = std.testing.allocator;
    var fake: Fake = .{};
    var definitions = [_]tools.ToolDefinition{definition()};
    var members = [_]tools.Member{ member(&fake, 101, &.{binding}), member(&fake, 102, &.{}) };
    var table = try tools.RequestTable.init(a, captured, &definitions, &members);
    defer table.deinit();
    const name = table.entries[0].provider_name;
    definitions[0].schema = "{}";
    members[0].capability_revision = 99;
    var parsed = try table.parse(a, name, "{\"session_ids\":[101],\"value\":3}");
    defer parsed.deinit();
    try std.testing.expectEqual(@as(u64, 1), table.entries[0].targets[0].capability_revision);
    try std.testing.expectError(error.ToolNotInRequest, table.parse(a, "unlisted", "{}"));
    try std.testing.expectError(error.ToolCapabilityUnavailable, table.parse(a, name, "{\"session_ids\":[101,102],\"value\":3}"));
    try std.testing.expectError(error.InvalidToolArguments, table.parse(a, name, "{\"session_ids\":[101],\"value\":21}"));
    try std.testing.expectError(error.InvalidToolArguments, table.parse(a, name, "{\"session_ids\":[101],\"value\":3,\"command\":\"x\"}"));
    try std.testing.expectError(error.InvalidToolArguments, table.parse(a, name, "{\"session_ids\":[101,101],\"value\":3}"));
}

test "API2 confirm approval freezes parameters generation revisions expiry and is consumed once" {
    const a = std.testing.allocator;
    var fake: Fake = .{};
    var members = [_]tools.Member{member(&fake, 101, &.{binding})};
    var table = try tools.RequestTable.init(a, captured, &.{definition()}, &members);
    defer table.deinit();
    var call = try table.parse(a, table.entries[0].provider_name, "{\"session_ids\":[101],\"value\":3}");
    defer call.deinit();
    try std.testing.expectError(error.ToolApprovalRequired, tools.authorize(&table, call, captured, &members, .{}, null, 100));
    var ticket = try tools.ApprovalTicket.create(&table, call, 100, 1000);
    ticket.approve();
    members[0].owner.generation += 1;
    try std.testing.expectError(error.StaleToolAuthority, tools.authorize(&table, call, captured, &members, .{}, &ticket, 101));
    members[0].owner.generation -= 1;
    members[0].policy_revision += 1;
    try std.testing.expectError(error.StaleToolAuthority, tools.authorize(&table, call, captured, &members, .{}, &ticket, 101));
    members[0].policy_revision -= 1;
    var changed = try table.parse(a, table.entries[0].provider_name, "{\"session_ids\":[101],\"value\":4}");
    defer changed.deinit();
    try std.testing.expectError(error.ToolApprovalChanged, tools.authorize(&table, changed, captured, &members, .{}, &ticket, 101));
    try std.testing.expectError(error.ToolApprovalExpired, tools.authorize(&table, call, captured, &members, .{}, &ticket, 1100));
    try tools.authorize(&table, call, captured, &members, .{}, &ticket, 101);
    try std.testing.expectError(error.ToolApprovalAlreadyUsed, tools.authorize(&table, call, captured, &members, .{}, &ticket, 102));
    try std.testing.expectEqual(@as(usize, 0), fake.count);
}

test "API2 runtime rejects denial and cancellation without effects and never replays unknown" {
    const a = std.testing.allocator;
    var fake: Fake = .{ .approve = false };
    const members = [_]tools.Member{member(&fake, 101, &.{binding})};
    fake.members = &members;
    var table = try tools.RequestTable.init(a, captured, &.{definition()}, &members);
    defer table.deinit();
    var call = try table.parse(a, table.entries[0].provider_name, "{\"session_ids\":[101],\"value\":3}");
    defer call.deinit();
    var history = operations.Store.init(a);
    defer history.deinit();
    var invocation: tools.DynamicInvocation = .{ .table = &table, .parsed = call, .turn_id = 1, .call_id = "original", .arguments = "{\"session_ids\":[101],\"value\":3}", .operation_id = 1 };
    try std.testing.expectError(error.ToolApprovalRejected, fake.runtime(&history).execute(invocation, a, null));
    fake.approve = true;
    invocation.operation_id = 2;
    var cancel: @import("provider.zig").CancelToken = .{};
    cancel.cancel();
    try std.testing.expectError(error.CancelledBeforeDispatch, fake.runtime(&history).execute(invocation, a, &cancel));
    try std.testing.expectEqual(@as(usize, 0), fake.count);
    fake.fail = true;
    invocation.operation_id = 3;
    const results = try fake.runtime(&history).execute(invocation, a, null);
    defer {
        for (results) |*result| result.deinit(a);
        a.free(results);
    }
    try std.testing.expectEqual(tools.Status.outcome_unknown, results[0].status);
    const failure = try std.json.parseFromSlice(std.json.Value, a, results[0].blocks[0].structured, .{});
    defer failure.deinit();
    try std.testing.expectEqualStrings("ResponseLost", failure.value.object.get("error_code").?.string);
    try std.testing.expect(failure.value.object.get("side_effect_started").?.bool);
    try std.testing.expectEqual(operations.Stage.outcome_unknown, history.lookup(members[0].owner, 3).?.stage);
    try std.testing.expectError(error.ToolOperationAlreadyRecorded, fake.runtime(&history).execute(invocation, a, null));
    try std.testing.expectEqual(@as(usize, 1), fake.count);
}

test "API2 runtime unsent members release reserved resources without clearing unknown dispatches" {
    const a = std.testing.allocator;
    const provider = @import("provider.zig");
    const Fixture = struct {
        mode: enum { preflight, cancelled, unknown },
        members: [2]tools.Member,
        history: *operations.Store,
        reads: usize = 0,
        dispatches: usize = 0,
        fn liveScope(_: *anyopaque) !scope.Scope {
            return captured;
        }
        fn liveMembers(raw: *anyopaque) ![]const tools.Member {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.reads += 1;
            if (self.mode == .preflight and self.reads >= 3) self.members[0].authorized = false;
            return &self.members;
        }
        fn policy(_: *anyopaque) tools.Policy {
            return .{};
        }
        fn now(_: *anyopaque) i64 {
            return 100;
        }
        fn invoke(raw: *anyopaque, target: tools.TargetBinding, request: tools.Invocation, _: std.mem.Allocator, cancel: ?*provider.CancelToken) !tools.ToolResult {
            const self: *@This() = @ptrCast(@alignCast(raw));
            try tools.markSent(self.history, request.owner, request.operation_id, request.call_id, request.tool_id, request.arguments_hash);
            self.dispatches += 1;
            if (self.mode == .cancelled) cancel.?.cancel();
            return .{ .status = if (self.mode == .unknown) .outcome_unknown else .succeeded, .receipt = .{ .owner = target.owner, .operation_id = request.operation_id, .local_released = self.mode != .unknown, .remote_effect_unknown = self.mode == .unknown } };
        }
    };
    for ([_]@FieldType(Fixture, "mode"){ .preflight, .cancelled, .unknown }) |mode| {
        var fake: Fake = .{};
        var history = operations.Store.init(a);
        defer history.deinit();
        var fixture: Fixture = .{ .mode = mode, .members = .{ member(&fake, 101, &.{binding}), member(&fake, 102, &.{binding}) }, .history = &history };
        var read = definition();
        read.effect = .read_state;
        read.approval_policy = .read_only;
        var table = try tools.RequestTable.init(a, captured, &.{read}, &fixture.members);
        defer table.deinit();
        const arguments = "{\"session_ids\":[101,102],\"value\":3}";
        var call = try table.parse(a, table.entries[0].provider_name, arguments);
        defer call.deinit();
        const runtime: tools.Runtime = .{ .context = &fixture, .live_scope = Fixture.liveScope, .live_members = Fixture.liveMembers, .current_policy = Fixture.policy, .now_ms = Fixture.now, .operations = &history, .invoke = Fixture.invoke };
        var cancel: provider.CancelToken = .{};
        const results = try runtime.execute(.{ .table = &table, .parsed = call, .turn_id = 1, .call_id = "group-release", .arguments = arguments, .operation_id = 1 }, a, &cancel);
        defer {
            for (results) |*result| result.deinit(a);
            a.free(results);
        }
        try std.testing.expectEqual(tools.Status.cancelled_unsent, results[1].status);
        try std.testing.expect(results[1].receipt.local_released);
        try std.testing.expect(history.lookup(fixture.members[1].owner, 1).?.resources_released);
        if (mode == .preflight) {
            try std.testing.expectEqual(@as(usize, 0), fixture.dispatches);
            try std.testing.expect(history.lookup(fixture.members[0].owner, 1).?.resources_released);
            try std.testing.expectEqual(@as(usize, 2), history.clearCompleted(false));
        } else {
            try std.testing.expectEqual(@as(usize, 1), fixture.dispatches);
            const first = history.lookup(fixture.members[0].owner, 1).?;
            try std.testing.expectEqual(operations.Stage.outcome_unknown, first.stage);
            try std.testing.expectEqual(mode != .unknown, first.resources_released);
            try std.testing.expectEqual(@as(usize, 1), history.clearCompleted(false));
            if (mode == .unknown) try std.testing.expectEqual(@as(usize, 0), history.clearCompleted(true));
        }
    }
}

test "API2 approved controller input preserves focus rejection before dispatch" {
    const a = std.testing.allocator;
    const Rejected = struct {
        fn invoke(_: *anyopaque, target: tools.TargetBinding, _: tools.Invocation, _: std.mem.Allocator, _: ?*@import("provider.zig").CancelToken) !tools.ToolResult {
            const content = @import("../host/content_context.zig");
            // The real content gate checks focus before any window/consumer
            // callback. Reproduce approval followed by loss of native focus.
            var context: content.Context = .{ .owner = target.owner, .window_id = @fromBackingInt(1), .window = undefined, .consumer = undefined };
            _ = try context.acquireAutomation(1, null, null, std.math.maxInt(u64));
            return error.UnexpectedDispatch;
        }
    };
    var fake: Fake = .{ .approve = true };
    const members = [_]tools.Member{member(&fake, 101, &.{binding})};
    fake.members = &members;
    var table = try tools.RequestTable.init(a, captured, &.{definition()}, &members);
    defer table.deinit();
    const arguments = "{\"session_ids\":[101],\"value\":3}";
    var call = try table.parse(a, table.entries[0].provider_name, arguments);
    defer call.deinit();
    var history = operations.Store.init(a);
    defer history.deinit();
    var runtime = fake.runtime(&history);
    runtime.invoke = Rejected.invoke;
    const invocation: tools.DynamicInvocation = .{ .table = &table, .parsed = call, .turn_id = 1, .call_id = "approved-input", .arguments = arguments, .operation_id = 1 };
    const results = try runtime.execute(invocation, a, null);
    defer {
        for (results) |*result| result.deinit(a);
        a.free(results);
    }
    try std.testing.expectEqual(tools.Status.cancelled_unsent, results[0].status);
    try results[0].validate(members[0].owner, 1);
    const failure = try std.json.parseFromSlice(std.json.Value, a, results[0].blocks[0].structured, .{});
    defer failure.deinit();
    try std.testing.expectEqualStrings("WindowNotFocused", failure.value.object.get("error_code").?.string);
    try std.testing.expectEqualStrings("preflight", failure.value.object.get("stage").?.string);
    try std.testing.expect(!failure.value.object.get("side_effect_started").?.bool);
    try std.testing.expect(!results[0].receipt.remote_effect_unknown);
    try std.testing.expectEqual(@as(usize, 0), fake.count);
    try std.testing.expectError(error.ToolOperationAlreadyRecorded, runtime.execute(invocation, a, null));
}

test "API2 per-plugin eight and request union sixteen are independent limits" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var fake: Fake = .{};
    const definitions = try a.alloc(tools.ToolDefinition, 17);
    const bindings = try a.alloc(tools.ToolBinding, 17);
    for (definitions, bindings, 0..) |*definition_value, *binding_value, index| {
        const id = try std.fmt.allocPrint(a, "example.tool{d}", .{index});
        definition_value.* = .{ .id = id, .schema = schema };
        binding_value.* = .{ .plugin_id = "example", .definition_id = id, .handler = Fake.handler };
    }
    try std.testing.expectError(error.TooManyPluginTools, tools.RequestTable.init(a, captured, definitions, &.{member(&fake, 101, bindings[0..9])}));
    var two = try tools.RequestTable.init(a, captured, definitions, &.{ member(&fake, 101, bindings[0..8]), member(&fake, 102, bindings[8..16]) });
    defer two.deinit();
    try std.testing.expectEqual(@as(usize, 16), two.entries.len);
    var three_scope = captured;
    three_scope.members.ids[2] = 103;
    three_scope.members.len = 3;
    try std.testing.expectError(error.TooManyRequestTools, tools.RequestTable.init(a, three_scope, definitions, &.{ member(&fake, 101, bindings[0..8]), member(&fake, 102, bindings[8..16]), member(&fake, 103, bindings[16..17]) }));
}

test "API2 required services verify type major authorization and current binding identity" {
    const Interface = struct {};
    const Wrong = struct {};
    var fake: Fake = .{};
    const a = std.testing.allocator;
    var definition_value = definition();
    definition_value.required_services = &.{services.Definition.of(Interface, .{ .name = "example.read" })};
    var service_binding = services.Binding.init(Interface, .{ .name = "example.read" }, &fake, &.{}, member(&fake, 101, &.{}).owner, 1);
    var target = member(&fake, 101, &.{binding});
    target.services = &.{service_binding};
    var table = try tools.RequestTable.init(a, captured, &.{definition_value}, &.{target});
    defer table.deinit();
    var call = try table.parse(a, table.entries[0].provider_name, "{\"session_ids\":[101],\"value\":3}");
    defer call.deinit();
    service_binding.definition = services.Definition.of(Wrong, .{ .name = "example.read" });
    target.services = &.{service_binding};
    try std.testing.expectError(error.RequiredServiceUnavailable, tools.preflight(&table, call, captured, &.{target}));
}

const png = "\x89PNG\r\n\x1a\n\x00\x00\x00\x0dIHDR" ++
    "\x00\x00\x00\x01\x00\x00\x00\x01\x08\x06\x00\x00\x00\x1f\x15\xc4\x89" ++
    "\x00\x00\x00\x0dIDAT\x78\x9c\x63\xf8\xcf\xc0\xf0\x1f\x00\x05\x00\x01\xff\x89\x99\x3d\x1d" ++
    "\x00\x00\x00\x00IEND\xae\x42\x60\x82";
test "API2 actual tool images survive loop and result snapshot and all native provider serializers" {
    const a = std.testing.allocator;
    const provider = @import("provider.zig");
    const Loop = @import("tool_loop.zig");
    const Image = @import("image_attachments.zig");
    const ImageHost = struct {
        count: usize = 0,
        fn old(_: *anyopaque, _: Loop.Invocation, _: std.mem.Allocator, _: ?*provider.CancelToken) !Loop.Outcome {
            return error.UnexpectedLegacyDispatch;
        }
        fn dynamic(raw: *anyopaque, invocation: tools.DynamicInvocation, allocator: std.mem.Allocator, _: ?*provider.CancelToken) ![]tools.ToolResult {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.count += 1;
            const output = try allocator.alloc(tools.ToolResult, 1);
            errdefer allocator.free(output);
            const blocks = try allocator.alloc(tools.ContentBlock, 1);
            errdefer allocator.free(blocks);
            blocks[0] = .{ .image_ref = try Image.ContentRef.create(allocator, "synthetic-observation", png, 0, .{}) };
            output[0] = .{ .status = .succeeded, .blocks = blocks, .receipt = .{ .owner = invocation.parsed.entry.targets[0].owner, .operation_id = invocation.operation_id } };
            return output;
        }
    };
    var fake: Fake = .{};
    var host: ImageHost = .{};
    var image_definition = definition();
    image_definition.id = "example.observe";
    image_definition.effect = .observe_image;
    image_definition.approval_policy = .read_only;
    var image_binding = binding;
    image_binding.definition_id = image_definition.id;
    const members = [_]tools.Member{member(&fake, 101, &.{image_binding})};
    var table = try tools.RequestTable.init(a, captured, &.{image_definition}, &members);
    const wire = try tools.providerDefinitions(&table, table.arena.allocator());
    const app_config = @import("../config/config.zig");
    var configured_models = [_]app_config.AiModel{.{ .id = "codex/gpt-6.1-sol", .context_window = 100_000, .vision = true, .image_token_reservation = 1024, .default = true }};
    var configured_providers = [_]app_config.AiProvider{.{ .kind = .openai_compat, .enabled = true, .endpoint = "http://127.0.0.1:8080/v1/chat/completions", .api_key = "synthetic-test-key", .models = &configured_models, .model_count = 1 }};
    const selected = try @import("provider_config.zig").fromSettings(.{ .default_provider = "openai_compat", .providers = &configured_providers, .provider_count = 1 });
    try std.testing.expect(selected.supportsImageBudget());
    var run = Loop.Loop.init(a, captured, 1, .{ .context_window = 100_000 });
    try run.start(selected.chatRequest(.{ .model = "ignored-caller-model", .system = "", .messages = &.{.{ .content = "Observe synthetic image" }}, .tools = wire, .tool_table = &table, .tool_images = true }));
    table.deinit(); // execution and wire authority have owned copies.
    _ = try run.nextRequest();
    const call: provider.ToolCall = .{ .id = "actual-observation", .name = run.request.tools[0].name(), .arguments = "{\"session_ids\":[101],\"value\":3}" };
    try run.complete("", &.{call}, .{ .context = &host, .execute = ImageHost.old, .execute_dynamic = ImageHost.dynamic }, .{}, 1, null);
    try std.testing.expectEqual(@as(usize, 1), host.count);
    const request = try run.nextRequest();
    try std.testing.expectEqualStrings("codex/gpt-6.1-sol", request.model);
    try std.testing.expectEqual(@as(?u32, 1024), request.image_token_reservation);
    try std.testing.expectEqual(@as(usize, 1024), try @import("image_budget.zig").validate(request));
    var unreserved = request;
    unreserved.image_token_reservation = null;
    try std.testing.expectEqual(@as(usize, @import("image_budget.zig").unknown_model_reservation), try @import("image_budget.zig").validate(unreserved));
    var known = request;
    known.model = "gpt-4o";
    known.image_token_reservation = 1;
    try std.testing.expectEqual(@as(usize, 255), try @import("image_budget.zig").validate(known));
    try std.testing.expectEqual(@as(usize, 1), request.messages[2].images.len);
    var original_hash = request.messages[2].images[0].content().?.sha256;
    for ([_]@import("registry.zig").Kind{ .openai_compat, .anthropic, .ollama }) |kind| {
        const body = try @import("provider_http.zig").requestBody(a, kind, request, 100_000);
        defer a.free(body);
        const decoded = try std.json.parseFromSlice(std.json.Value, a, body, .{});
        defer decoded.deinit();
        if (kind == .openai_compat) {
            const messages = decoded.value.object.get("messages").?.array.items;
            const receipt = messages[messages.len - 2];
            const observation = messages[messages.len - 1];
            try std.testing.expectEqualStrings("tool", receipt.object.get("role").?.string);
            try std.testing.expectEqualStrings(call.id, receipt.object.get("tool_call_id").?.string);
            try std.testing.expect(receipt.object.get("content").? == .string);
            try std.testing.expectEqualStrings("user", observation.object.get("role").?.string);
            try std.testing.expectEqualStrings("image_url", observation.object.get("content").?.array.items[1].object.get("type").?.string);
        }
        const summary = @import("tool_trace.zig").summarize(decoded.value);
        try std.testing.expectEqual(@as(usize, 1), summary.image_count);
        try std.testing.expectEqual(@as(usize, png.len), summary.images[0].bytes);
        try std.testing.expectEqualStrings(&std.fmt.bytesToHex(original_hash, .lower), &summary.images[0].sha256);
        try std.testing.expectEqualStrings("image/png", summary.images[0].mime);
        try std.testing.expectEqual(@as(u32, 1), summary.images[0].width.?);
    }
    var saved = @import("tool_results.zig").Store.init(a);
    defer saved.deinit();
    try std.testing.expect(try saved.capture(&run, &.{}));
    run.deinit();
    try std.testing.expectEqual(@as(usize, 1), saved.records.items[0].images.len);
    try std.testing.expectEqualSlices(u8, &original_hash, &saved.records.items[0].images[0].content().?.sha256);
    // The UI result card and provider next round share immutable actual pixels.
    try std.testing.expectEqual(@as(u32, 1), saved.records.items[0].images[0].content().?.width);
}

test "API2 unknown vision budget keeps observation input new observation and answer retry within 500k" {
    const a = std.testing.allocator;
    const provider = @import("provider.zig");
    const Loop = @import("tool_loop.zig");
    const Image = @import("image_attachments.zig");
    const http = @import("provider_http.zig");
    const Fixture = struct {
        calls: [3]provider.ToolCall = undefined,
        provider_calls: usize = 0,
        observations: usize = 0,
        inputs: usize = 0,
        last_request: ?[]u8 = null,
        fn legacy(_: *anyopaque, _: Loop.Invocation, _: std.mem.Allocator, _: ?*provider.CancelToken) !Loop.Outcome {
            return error.UnexpectedLegacyDispatch;
        }
        fn execute(raw: *anyopaque, invocation: tools.DynamicInvocation, allocator: std.mem.Allocator, _: ?*provider.CancelToken) ![]tools.ToolResult {
            const self: *@This() = @ptrCast(@alignCast(raw));
            const results = try allocator.alloc(tools.ToolResult, 1);
            errdefer allocator.free(results);
            const blocks = try allocator.alloc(tools.ContentBlock, 1);
            errdefer allocator.free(blocks);
            if (invocation.parsed.entry.definition.effect == .observe_image) {
                self.observations += 1;
                blocks[0] = .{ .image_ref = try Image.ContentRef.create(allocator, "synthetic-observation", png, @intCast(self.observations), .{}) };
            } else {
                self.inputs += 1;
                blocks[0] = .{ .text = try allocator.dupe(u8, "controlled input completed once") };
            }
            results[0] = .{ .status = .succeeded, .blocks = blocks, .receipt = .{ .owner = invocation.parsed.entry.targets[0].owner, .operation_id = invocation.operation_id } };
            return results;
        }
        fn chat(raw: *anyopaque, request: provider.ChatRequest, sink: *const fn (*anyopaque, provider.Delta) void, ctx: *anyopaque) !provider.ChatStats {
            const self: *@This() = @ptrCast(@alignCast(raw));
            try std.testing.expect(!request.cancel.?.isCancelled());
            const body = try http.requestBody(a, .openai_compat, request, 500_000);
            if (self.last_request) |previous| a.free(previous);
            self.last_request = body;
            const round = self.provider_calls;
            self.provider_calls += 1;
            if (round < self.calls.len) {
                const call = self.calls[round];
                sink(ctx, .{ .tool_plan = .{ .call_id = call.id, .name = call.name, .arguments = call.arguments } });
            } else if (round == self.calls.len) {
                sink(ctx, .{ .text = "partial after the new screenshot" });
                return error.Timeout;
            } else {
                try std.testing.expectEqual(@as(usize, 0), request.tools.len);
                sink(ctx, .{ .text = "continued from both screenshots and the completed input" });
            }
            sink(ctx, .done);
            return .{ .usage_reported = false };
        }
        fn models(_: *anyopaque, allocator: std.mem.Allocator) ![]provider.ModelInfo {
            return allocator.alloc(provider.ModelInfo, 0);
        }
    };
    var fixture: Fixture = .{};
    defer if (fixture.last_request) |body| a.free(body);
    var fake: Fake = .{};
    const observe: tools.ToolDefinition = .{ .id = "example.observe", .schema = schema, .effect = .observe_image, .approval_policy = .read_only };
    const input: tools.ToolDefinition = .{ .id = "example.input", .schema = schema, .effect = .remote_input, .approval_policy = .always_confirm };
    const bindings = [_]tools.ToolBinding{ .{ .plugin_id = "example", .definition_id = observe.id, .handler = Fake.handler }, .{ .plugin_id = "example", .definition_id = input.id, .handler = Fake.handler } };
    const members = [_]tools.Member{member(&fake, 101, &bindings)};
    var table = try tools.RequestTable.init(a, captured, &.{ observe, input }, &members);
    defer table.deinit();
    const definitions = try tools.providerDefinitions(&table, table.arena.allocator());
    fixture.calls = .{
        .{ .id = "observation-before-input", .name = definitions[0].name(), .arguments = "{\"session_ids\":[101],\"value\":1}" },
        .{ .id = "input-once", .name = definitions[1].name(), .arguments = "{\"session_ids\":[101],\"value\":2}" },
        .{ .id = "new-observation-after-input", .name = definitions[0].name(), .arguments = "{\"session_ids\":[101],\"value\":3}" },
    };
    const callbacks: Loop.Host = .{ .context = &fixture, .execute = Fixture.legacy, .execute_dynamic = Fixture.execute };
    var manager = @import("turn_manager.zig").Manager.init(a);
    defer manager.deinit();
    manager.scope = captured;
    manager.turn_id = 401;
    manager.tool_host = callbacks;
    manager.tool_limits.context_window = 500_000;
    var original_stop: provider.CancelToken = .{};
    const request: provider.ChatRequest = .{ .model = "gateway/custom-vision@500k", .vision = true, .tool_images = true, .system = "synthetic visual task", .messages = &.{.{ .content = "observe, apply one input, then observe the new result" }}, .tools = definitions, .tool_table = &table, .cancel = &original_stop };
    const p: provider.Provider = .{ .ctx = &fixture, .chat = Fixture.chat, .models = Fixture.models };
    try std.testing.expectError(error.Timeout, manager.run(p, request));
    const run = manager.tool_run.?;
    try std.testing.expectEqual(@as(usize, 2), fixture.observations);
    try std.testing.expectEqual(@as(usize, 1), fixture.inputs);
    try std.testing.expectEqual(@as(usize, 2 * @import("image_budget.zig").unknown_model_reservation), try @import("image_budget.zig").validate(run.request));
    try std.testing.expectEqual(@as(i64, 1), run.messages.items[2].images[0].content().?.captured_at_ms);
    try std.testing.expectEqual(@as(i64, 2), run.messages.items[6].images[0].content().?.captured_at_ms);
    original_stop.cancel();
    var next_stop: provider.CancelToken = .{};
    const stats = try manager.resumeAnswer(p, &next_stop);
    try std.testing.expect(!stats.usage_reported);
    try std.testing.expectEqual(@as(usize, 5), fixture.provider_calls);
    try std.testing.expectEqual(@as(usize, 2), fixture.observations);
    try std.testing.expectEqual(@as(usize, 1), fixture.inputs);
    const parsed = try std.json.parseFromSlice(std.json.Value, a, fixture.last_request.?, .{});
    defer parsed.deinit();
    try std.testing.expect(parsed.value.object.get("tools") == null);
    const projection = @import("tool_trace.zig").summarize(parsed.value);
    try std.testing.expectEqual(@as(usize, 2), projection.image_count);
    for (fixture.calls) |call| {
        try std.testing.expect(std.mem.indexOf(u8, fixture.last_request.?, call.id) != null);
    }
    // A third retained frame fits; a fourth exceeds 500k. Preserve every
    // actual result and reject admission instead of dropping/replaying frames.
    var extra = fixture.calls[0];
    extra.id = "third-observation";
    try run.complete("", &.{extra}, callbacks, .{}, 1, null);
    _ = try run.nextRequest();
    extra.id = "fourth-observation-over-window";
    try run.complete("", &.{extra}, callbacks, .{}, 1, null);
    try std.testing.expectError(error.ToolContextBudget, run.nextRequest());
    try std.testing.expectEqual(@as(usize, 5), run.records.items.len);
    try std.testing.expectEqual(@as(usize, 1), run.messages.items[10].images.len);
    try std.testing.expectEqual(@as(usize, 4), fixture.observations);
    try std.testing.expectEqual(@as(usize, 1), fixture.inputs);
}

test "live permission runtime reasks when auto bypass is revoked before dispatch" {
    const a = std.testing.allocator;
    const Fixture = struct {
        fake: Fake = .{},
        asks: usize = 0,
        fn ask(raw: *anyopaque, _: tools.DynamicInvocation, ticket: *tools.ApprovalTicket, _: ?*@import("provider.zig").CancelToken) !bool {
            const fake: *Fake = @ptrCast(@alignCast(raw));
            const self: *@This() = @fieldParentPtr("fake", fake);
            self.asks += 1;
            if (self.asks == 1) {
                // The waiter observed auto, but confirm was restored before
                // Runtime's final authority check. No user decision exists.
                ticket.policy_bypass = true;
                fake.policy.full_control = false;
                return true;
            }
            return false;
        }
    };
    var fixture: Fixture = .{};
    const fake = &fixture.fake;
    var members = [_]tools.Member{member(fake, 101, &.{binding})};
    var def = definition();
    def.approval_policy = .confirm;
    var table = try tools.RequestTable.init(a, captured, &.{def}, &members);
    defer table.deinit();
    var call = try table.parse(a, table.entries[0].provider_name, "{\"session_ids\":[101],\"value\":3}");
    defer call.deinit();
    fake.members = &members;
    var history = operations.Store.init(a);
    defer history.deinit();
    var runtime = fake.runtime(&history);
    runtime.approval = Fixture.ask;
    const invocation: tools.DynamicInvocation = .{ .table = &table, .parsed = call, .turn_id = 1, .call_id = "live-revoked", .arguments = "{\"session_ids\":[101],\"value\":3}", .operation_id = 1 };
    try std.testing.expectError(error.ToolApprovalRejected, runtime.execute(invocation, a, null));
    try std.testing.expectEqual(@as(usize, 2), fixture.asks);
    try std.testing.expectEqual(@as(usize, 0), fake.count);
}

test "API2 automatic permission covers both confirmation policies and keeps deny gates" {
    const a = std.testing.allocator;
    for ([_]tools.ApprovalPolicy{ .confirm, .always_confirm }) |confirmation| {
        for ([_]tools.Effect{ .resource_write, .remote_input, .observe_image }) |effect| {
            var fake: Fake = .{ .approve = false, .policy = .{ .engine = .{ .mode = .auto } } };
            const members = [_]tools.Member{ member(&fake, 101, &.{binding}), member(&fake, 102, &.{binding}) };
            fake.members = &members;
            var def = definition();
            def.approval_policy = confirmation;
            def.effect = effect;
            var table = try tools.RequestTable.init(a, captured, &.{def}, &members);
            defer table.deinit();
            var call = try table.parse(a, table.entries[0].provider_name, "{\"session_ids\":[101,102],\"value\":3}");
            defer call.deinit();
            var history = operations.Store.init(a);
            defer history.deinit();
            const invocation: tools.DynamicInvocation = .{ .table = &table, .parsed = call, .turn_id = 1, .call_id = "auto-group-write", .arguments = "{\"session_ids\":[101,102],\"value\":3}", .operation_id = 1 };
            const results = try fake.runtime(&history).execute(invocation, a, null);
            defer a.free(results);
            defer for (results) |*result| result.deinit(a);
            try std.testing.expectEqual(@as(usize, 2), fake.count);
            try std.testing.expectEqual(@as(usize, 2), results.len);
            for (results) |result| try std.testing.expectEqual(tools.Status.succeeded, result.status);
            const denied: tools.Policy = .{ .engine = .{ .mode = .auto }, .full_control = true, .allow_write = false, .allow_input = false, .allow_read = false };
            try std.testing.expectError(error.ToolExecutionDenied, tools.needsApproval(def, denied));
        }
    }
}

test "API2 user approval waits indefinitely while exact authority and one use remain enforced" {
    const a = std.testing.allocator;
    var fake: Fake = .{};
    var members = [_]tools.Member{member(&fake, 101, &.{binding})};
    var table = try tools.RequestTable.init(a, captured, &.{definition()}, &members);
    defer table.deinit();
    var call = try table.parse(a, table.entries[0].provider_name, "{\"session_ids\":[101],\"value\":3}");
    defer call.deinit();
    var ticket = try tools.ApprovalTicket.waiting(&table, call);
    ticket.approve();
    const later = 30 * 24 * 60 * 60 * 1000;
    members[0].owner.generation += 1;
    try std.testing.expectError(error.StaleToolAuthority, tools.authorize(&table, call, captured, &members, .{}, &ticket, later));
    members[0].owner.generation -= 1;
    try tools.authorize(&table, call, captured, &members, .{}, &ticket, later);
    try std.testing.expectError(error.ToolApprovalAlreadyUsed, tools.authorize(&table, call, captured, &members, .{}, &ticket, later + 1));
    try std.testing.expectEqual(@as(usize, 0), fake.count);
}
