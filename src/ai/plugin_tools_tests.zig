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

test "API2 approval freezes parameters generation revisions expiry and is consumed once in full control" {
    const a = std.testing.allocator;
    var fake: Fake = .{};
    var members = [_]tools.Member{member(&fake, 101, &.{binding})};
    var table = try tools.RequestTable.init(a, captured, &.{definition()}, &members);
    defer table.deinit();
    var call = try table.parse(a, table.entries[0].provider_name, "{\"session_ids\":[101],\"value\":3}");
    defer call.deinit();
    try std.testing.expectError(error.ToolApprovalRequired, tools.authorize(&table, call, captured, &members, .{ .full_control = true }, null, 100));
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
    try tools.authorize(&table, call, captured, &members, .{ .full_control = true }, &ticket, 101);
    try std.testing.expectError(error.ToolApprovalAlreadyUsed, tools.authorize(&table, call, captured, &members, .{}, &ticket, 102));
    try std.testing.expectEqual(@as(usize, 0), fake.count);
}

test "API2 runtime rejects denial and cancellation without effects and never replays unknown" {
    const a = std.testing.allocator;
    var fake: Fake = .{ .approve = false, .policy = .{ .full_control = true } };
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
    try std.testing.expectEqual(operations.Stage.outcome_unknown, history.lookup(members[0].owner, 3).?.stage);
    try std.testing.expectError(error.ToolOperationAlreadyRecorded, fake.runtime(&history).execute(invocation, a, null));
    try std.testing.expectEqual(@as(usize, 1), fake.count);
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
    try std.testing.expectError(error.UnknownImageBudget, @import("image_budget.zig").validate(unreserved));
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
