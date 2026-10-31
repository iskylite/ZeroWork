const std = @import("std");
const provider = @import("provider.zig");
const loop_mod = @import("tool_loop.zig");
const manager_mod = @import("turn_manager.zig");
const retry = @import("retry.zig");
const scope_mod = @import("tool_scope.zig");
const http = @import("provider_http.zig");
const a = std.testing.allocator;
const scope: scope_mod.Scope = .{ .owner = .{ .session = 101 }, .members = .{ .ids = .{101} ++ @as([15]u64, @splat(0)), .len = 1 } };
const definitions = [_]provider.ToolDefinition{ .{ .tool = .run_command, .session_ids = &.{101} }, .{ .tool = .read_terminal, .session_ids = &.{101} } };
const df: provider.ToolCall = .{ .id = "call-local-df", .name = "run_command", .arguments = "{\"session_ids\":[101],\"command\":\"df -h\"}" };

test "new offline turn retains two host tool turns without inheriting their authority" {
    const tools = @import("plugin_tools.zig");
    const identity = @import("../host/identity.zig");
    const Fixture = struct {
        count: usize = 0,
        fn legacy(_: *anyopaque, _: loop_mod.Invocation, _: std.mem.Allocator, _: ?*provider.CancelToken) !loop_mod.Outcome {
            return error.UnexpectedLegacyDispatch;
        }
        fn invoke(raw: *anyopaque, invocation: tools.host.Invocation, _: std.mem.Allocator, _: ?*provider.CancelToken) !tools.host.Result {
            @as(*@This(), @ptrCast(@alignCast(raw))).count += 1;
            return .{ .status = .succeeded, .receipt = .{ .conversation_id = invocation.context.conversation_id, .task_id = invocation.context.task_id, .operation_id = invocation.operation_id, .binding_revision = invocation.context.binding_revision } };
        }
    };
    var fixture: Fixture = .{};
    var manager = manager_mod.Manager.init(a);
    defer manager.deinit();
    manager.scope = scope;
    manager.tool_host = .{ .context = &fixture, .execute = Fixture.legacy, .execute_host = Fixture.invoke };
    manager.tool_limits.context_window = 200_000;
    var history: @import("wire_history.zig").History = .{};
    defer history.deinit();
    const conversation = identity.ConversationId.generate();
    for (0..2) |index| {
        const context: tools.host.Context = .{ .conversation_id = conversation, .task_id = identity.TaskId.generate(), .binding = scope.owner, .binding_revision = 1, .grant_revision = 1 };
        var table = try tools.RequestTable.initWithHost(a, scope, &.{}, &.{}, context, &.{.{ .authority = .conversation_context, .definition = .{ .id = "host.get_current_context", .schema = "{\"type\":\"object\",\"properties\":{},\"additionalProperties\":false}" } }});
        defer table.deinit();
        const wire = try tools.providerDefinitions(&table, table.arena.allocator());
        const call: provider.ToolCall = .{ .id = if (index == 0) "connected-first" else "connected-second", .name = wire[0].name(), .arguments = "{}" };
        var script: Script = .{ .rounds = &.{ .{ .calls = &.{call} }, .{ .text = "connected answer" } } };
        defer script.deinit();
        var messages: std.ArrayList(provider.Message) = .empty;
        defer messages.deinit(a);
        try messages.appendSlice(a, history.messages);
        try messages.append(a, .{ .content = "connected question" });
        manager.turn_id = index + 1;
        _ = try manager.run(script.interface(), .{ .model = "test", .system = "", .messages = messages.items, .tools = wire, .tool_table = &table });
        try std.testing.expectEqual(index + 1, fixture.count);
        const next = try @import("wire_history.zig").History.copy(a, manager.tool_run.?.messages.items, manager.round_text.items);
        history.deinit();
        history = next;
    }
    var messages: std.ArrayList(provider.Message) = .empty;
    defer messages.deinit(a);
    try messages.appendSlice(a, history.messages);
    try messages.append(a, .{ .content = "terminal disconnected; answer without tools" });
    var offline: Script = .{ .rounds = &.{.{ .text = "OFFLINE_NEW_ANSWER" }} };
    defer offline.deinit();
    manager.tool_host = null;
    const request: provider.ChatRequest = .{ .model = "test", .system = "", .messages = messages.items };
    // Removing authority cannot turn a retry into a new dispatchable turn.
    try std.testing.expectError(error.InvalidHostAuthority, manager.run(offline.interface(), request));
    try std.testing.expectEqual(@as(usize, 0), offline.index);
    manager.turn_id += 1;
    _ = try manager.run(offline.interface(), request);
    try std.testing.expectEqual(@as(usize, 2), fixture.count);
    try std.testing.expectEqualStrings("OFFLINE_NEW_ANSWER", manager.cards.cards.items[0].text);
    try std.testing.expect(manager.tool_run.?.tool_table == null);
    try std.testing.expectEqual(@as(usize, 0), manager.tool_run.?.records.items.len);
    const body = try std.json.parseFromSlice(std.json.Value, a, offline.requests.items[0], .{});
    defer body.deinit();
    try std.testing.expect(body.value.object.get("tools") == null);
    var results: usize = 0;
    for (body.value.object.get("messages").?.array.items) |message| {
        if (std.mem.eql(u8, message.object.get("role").?.string, "tool")) results += 1;
    }
    try std.testing.expectEqual(@as(usize, 2), results);
}

test "round authority handoff preserves old tool pairs and refreshes only the next batch" {
    const tools = @import("plugin_tools.zig");
    const identity = @import("../host/identity.zig");
    const context: tools.host.Context = .{ .conversation_id = identity.ConversationId.generate(), .task_id = identity.TaskId.generate(), .binding = scope.owner, .binding_revision = 1, .grant_revision = 1 };
    const contribution: tools.host.Contribution = .{ .authority = .lifecycle, .definition = .{ .id = "host.create_group", .schema = "{\"type\":\"object\",\"properties\":{},\"additionalProperties\":false}", .effect = .resource_write } };
    var original = try tools.RequestTable.initWithHost(a, scope, &.{}, &.{}, context, &.{contribution});
    defer original.deinit();
    var next_context = context;
    next_context.binding = .{ .group = 7 };
    next_context.binding_revision = 2;
    var successor = try tools.RequestTable.initWithHost(a, .{ .owner = next_context.binding, .members = .{} }, &.{}, &.{}, next_context, &.{.{ .authority = .conversation_context, .definition = .{ .id = "host.get_current_context", .schema = contribution.definition.schema } }});
    defer successor.deinit();
    const Fixture = struct {
        successor: *tools.RequestTable,
        refreshed: bool = false,
        acknowledgements: usize = 0,
        fn old(_: *anyopaque, _: loop_mod.Invocation, _: std.mem.Allocator, _: ?*provider.CancelToken) !loop_mod.Outcome {
            return error.UnexpectedLegacyDispatch;
        }
        fn invoke(_: *anyopaque, invocation: tools.host.Invocation, _: std.mem.Allocator, _: ?*provider.CancelToken) !tools.host.Result {
            return .{ .status = .succeeded, .receipt = .{ .conversation_id = invocation.context.conversation_id, .task_id = invocation.context.task_id, .operation_id = invocation.operation_id, .binding_revision = invocation.context.binding_revision } };
        }
        fn refresh(raw: *anyopaque, _: *const tools.RequestTable, allocator: std.mem.Allocator, _: ?*provider.CancelToken) !?loop_mod.AuthorityRefresh {
            const self: *@This() = @ptrCast(@alignCast(raw));
            if (self.refreshed) return null;
            self.refreshed = true;
            return .{ .table = try tools.cloneTable(self.successor, allocator), .notice = try allocator.dupe(u8, "ZeroWork context notice: original conversation now belongs to group 7; binding revision 2."), .notice_revision = 1 };
        }
        fn ack(raw: *anyopaque, revision: u64) !void {
            try std.testing.expectEqual(@as(u64, 1), revision);
            @as(*@This(), @ptrCast(@alignCast(raw))).acknowledgements += 1;
        }
    };
    var fixture: Fixture = .{ .successor = &successor };
    const callbacks: loop_mod.Host = .{ .context = &fixture, .execute = Fixture.old, .execute_host = Fixture.invoke, .refresh_authority = Fixture.refresh, .acknowledge_notice = Fixture.ack };
    const wire = try tools.providerDefinitions(&original, original.arena.allocator());
    var run = loop_mod.Loop.init(a, scope, 4, .{ .context_window = 100_000 });
    defer run.deinit();
    try run.start(.{ .model = "test", .system = "stable rules", .messages = &.{}, .tools = wire, .tool_table = &original });
    try run.complete("", &.{.{ .id = "create-original", .name = wire[0].name(), .arguments = "{}" }}, callbacks, .{}, 1, null);
    try run.refreshAuthority(callbacks, null);
    try std.testing.expect(run.scope.owner.eql(next_context.binding));
    try std.testing.expect(run.records.items[0].key.owner.eql(context.binding));
    const request = try run.nextRequest();
    try http.validateToolMessages(request);
    try std.testing.expectEqualStrings("create-original", request.messages[1].tool_call_id.?);
    try std.testing.expectEqual(provider.Role.user, request.messages[2].role);
    try run.acknowledgeNotice(callbacks);
    try run.acknowledgeNotice(callbacks);
    try std.testing.expectEqual(@as(usize, 1), fixture.acknowledgements);
    try run.complete("", &.{.{ .id = "query-successor", .name = request.tools[0].name(), .arguments = "{}" }}, callbacks, .{}, 1, null);
    try std.testing.expect(run.records.items[1].key.owner.eql(next_context.binding));
    try http.validateToolMessages(try run.nextRequest());
    // A changed UI owner cannot bypass the same conversation/turn ledger.
    var manager = manager_mod.Manager.init(a);
    defer manager.deinit();
    manager.tool_run = try a.create(loop_mod.Loop);
    manager.tool_run.?.* = loop_mod.Loop.init(a, scope, 4, .{});
    try manager.tool_run.?.start(.{ .model = "test", .system = "", .messages = &.{}, .tools = wire, .tool_table = &original });
    try manager.tool_run.?.records.append(manager.tool_run.?.arena.allocator(), .{ .key = .{ .owner = context.binding, .turn_id = 4, .call_id = "already-dispatched" }, .name = "host.create_group", .arguments = "{}", .arguments_hash = @splat(0), .dispatched = true });
    manager.turn_id = 4;
    manager.scope = successor.captured_scope;
    var script: Script = .{ .rounds = &.{} };
    defer script.deinit();
    try std.testing.expectError(error.ToolTurnAlreadyDispatched, manager.run(script.interface(), .{ .model = "test", .system = "", .messages = &.{}, .tool_table = &successor }));
}

test "host tools retain real call pairs and conversation receipts without session targets" {
    const tools = @import("plugin_tools.zig");
    const identity = @import("../host/identity.zig");
    const authority: tools.host.Context = .{ .conversation_id = identity.ConversationId.generate(), .task_id = identity.TaskId.generate(), .binding = .{ .group = 7 }, .binding_revision = 2, .grant_revision = 3 };
    const definition: tools.ToolDefinition = .{ .id = "host.get_current_context", .schema = "{\"type\":\"object\",\"properties\":{},\"additionalProperties\":false}" };
    const empty: scope_mod.Scope = .{ .owner = authority.binding, .members = .{} };
    var table = try tools.RequestTable.initWithHost(a, empty, &.{}, &.{}, authority, &.{.{ .definition = definition, .authority = .conversation_context }});
    defer table.deinit();
    const wire = try tools.providerDefinitions(&table, table.arena.allocator());
    const Gateway = struct {
        context: tools.host.Context,
        calls: usize = 0,
        wrong_receipt: bool = false,
        fn legacy(_: *anyopaque, _: loop_mod.Invocation, _: std.mem.Allocator, _: ?*provider.CancelToken) !loop_mod.Outcome {
            return error.UnexpectedLegacyDispatch;
        }
        fn invoke(raw: *anyopaque, invocation: tools.host.Invocation, allocator: std.mem.Allocator, _: ?*provider.CancelToken) !tools.host.Result {
            const self: *@This() = @ptrCast(@alignCast(raw));
            if (!self.context.eql(invocation.context)) return error.StaleToolAuthority;
            self.calls += 1;
            const blocks = try allocator.alloc(tools.host.Block, 1);
            errdefer allocator.free(blocks);
            blocks[0] = .{ .structured = try allocator.dupe(u8, "{\"current_binding\":\"group\",\"member_count\":0}") };
            return .{ .status = .succeeded, .blocks = blocks, .receipt = .{ .conversation_id = invocation.context.conversation_id, .task_id = if (self.wrong_receipt) identity.TaskId.generate() else invocation.context.task_id, .operation_id = invocation.operation_id, .binding_revision = invocation.context.binding_revision } };
        }
    };
    var gateway: Gateway = .{ .context = authority };
    const callbacks: loop_mod.Host = .{ .context = &gateway, .execute = Gateway.legacy, .execute_host = Gateway.invoke };
    var loop = loop_mod.Loop.init(a, empty, 1, .{ .context_window = 100_000 });
    defer loop.deinit();
    try loop.start(.{ .model = "model", .system = "", .messages = &.{}, .tools = wire, .tool_table = &table });
    const call: provider.ToolCall = .{ .id = "host-query", .name = wire[0].name(), .arguments = "{}" };
    try loop.complete("", &.{call}, callbacks, .{}, 1, null);
    try loop.complete("", &.{call}, callbacks, .{}, 1, null);
    try std.testing.expectEqual(@as(usize, 1), gateway.calls);
    try std.testing.expect(loop.records.items[0].host_result != null);
    try std.testing.expect(loop.records.items[0].generic_results == null);
    const request = try loop.nextRequest();
    try http.validateToolMessages(request);
    const body = try std.json.parseFromSlice(std.json.Value, a, request.messages[1].content, .{});
    defer body.deinit();
    try std.testing.expect(body.value.object.get("targets") == null);
    try std.testing.expect(body.value.object.get("session_id") == null);
    try std.testing.expectEqualStrings("succeeded", body.value.object.get("status").?.string);
    // A stale grant is rejected before host dispatch. A wrong task receipt is
    // never accepted as success, even with matching tool/call/operation IDs.
    gateway.context.grant_revision += 1;
    var stale = call;
    stale.id = "stale-host-query";
    try loop.complete("", &.{stale}, callbacks, .{}, 1, null);
    try std.testing.expectEqual(@as(usize, 1), gateway.calls);
    try std.testing.expect(!loop.uncertain);
    gateway.context = authority;
    gateway.wrong_receipt = true;
    stale.id = "wrong-task-receipt";
    try loop.complete("", &.{stale}, callbacks, .{}, 1, null);
    try std.testing.expect(loop.uncertain);
    try std.testing.expect(std.mem.indexOf(u8, loop.records.items[2].result_body.?, "InvalidHostToolResult") != null);
    gateway.wrong_receipt = false;
    gateway.calls = 0;
    var script: Script = .{ .rounds = &.{ .{ .calls = &.{call} }, .{ .text = "Host context received" } } };
    defer script.deinit();
    var manager = manager_mod.Manager.init(a);
    defer manager.deinit();
    manager.scope = empty;
    manager.turn_id = 1;
    manager.tool_host = callbacks;
    manager.tool_limits.context_window = 100_000;
    _ = try manager.run(script.interface(), .{ .model = "model", .system = "", .messages = &.{}, .tools = wire, .tool_table = &table });
    try std.testing.expectEqual(@as(usize, 1), gateway.calls);
    try std.testing.expectEqual(@as(usize, 2), script.requests.items.len);
    try std.testing.expect(manager.tool_run.?.records.items[0].host_result != null);
}

const Round = struct { text: []const u8 = "", calls: []const provider.ToolCall = &.{} };
const Script = struct {
    rounds: []const Round,
    index: usize = 0,
    requests: std.ArrayList([]u8) = .empty,
    transient_round: ?usize = null,
    failed: bool = false,
    inside_chat: bool = false,
    dispatch_count: ?*usize = null,

    fn deinit(self: *Script) void {
        for (self.requests.items) |body| a.free(body);
        self.requests.deinit(a);
    }
    fn interface(self: *Script) provider.Provider {
        return .{ .ctx = self, .chat = chat, .models = models };
    }
    fn chat(raw: *anyopaque, request: provider.ChatRequest, sink: *const fn (*anyopaque, provider.Delta) void, sink_ctx: *anyopaque) !provider.ChatStats {
        const self: *Script = @ptrCast(@alignCast(raw));
        self.inside_chat = true;
        defer self.inside_chat = false;
        const body = try http.requestBody(a, .openai_compat, request, 200_000);
        self.requests.append(a, body) catch |err| {
            a.free(body);
            return err;
        };
        if (self.transient_round == self.index and !self.failed) {
            self.failed = true;
            sink(sink_ctx, .{ .text = "failed-attempt-prefix" });
            return error.Transient;
        }
        if (self.index >= self.rounds.len) return error.UnexpectedProviderRound;
        const before = if (self.dispatch_count) |value| value.* else 0;
        const round = self.rounds[self.index];
        self.index += 1;
        if (round.text.len != 0) sink(sink_ctx, .{ .text = round.text });
        for (round.calls, 0..) |call, index| {
            const split = call.arguments.len / 2;
            sink(sink_ctx, .{ .tool_plan = .{ .index = @intCast(index), .call_id = call.id, .name = call.name, .arguments = call.arguments[0..split] } });
            if (self.dispatch_count) |value| try std.testing.expectEqual(before, value.*);
            sink(sink_ctx, .{ .tool_plan = .{ .index = @intCast(index), .call_id = null, .arguments = call.arguments[split..] } });
        }
        sink(sink_ctx, .done);
        sink(sink_ctx, .done); // A repeated final frame is not a second dispatch.
        if (self.dispatch_count) |value| try std.testing.expectEqual(before, value.*);
        return .{ .input_tokens = 3, .output_tokens = 5 };
    }
    fn models(_: *anyopaque, allocator: std.mem.Allocator) ![]provider.ModelInfo {
        return allocator.alloc(provider.ModelInfo, 0);
    }
};

const ControlledHost = struct {
    count: usize = 0,
    script: ?*Script = null,
    mode: enum { success, real_exec, uncertain, remote_unknown, throws, wait_approval, cancel_after_success, no_exit } = .success,
    waiting: std.atomic.Value(bool) = .init(false),
    releases: usize = 0,

    fn interface(self: *ControlledHost) loop_mod.Host {
        return .{ .context = self, .execute = execute };
    }
    fn execute(raw: *anyopaque, invocation: loop_mod.Invocation, allocator: std.mem.Allocator, cancel: ?*provider.CancelToken) !loop_mod.Outcome {
        const self: *ControlledHost = @ptrCast(@alignCast(raw));
        if (self.script) |script| try std.testing.expect(!script.inside_chat);
        try std.testing.expect(scope_mod.Owner.eql(scope.owner, invocation.key.owner));
        try std.testing.expectEqual(@as(u64, 77), invocation.key.turn_id);
        try std.testing.expectEqual(@as(u64, 101), invocation.call.targets.ids[0]);
        try std.testing.expectEqual(@as(u32, 60_000), invocation.timeout_ms);
        try std.testing.expectEqual(@as(u32, 65536), invocation.capture_bytes);
        var hash: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(invocation.arguments, &hash, .{});
        try std.testing.expectEqualSlices(u8, &hash, &invocation.arguments_hash);
        self.count += 1;
        if (self.mode == .throws) return error.LostExecutionReceipt;
        if (self.mode == .wait_approval) {
            try std.testing.expectEqual(@import("permission.zig").Verdict.need_confirm, invocation.verdict);
            self.waiting.store(true, .release);
            while (!cancel.?.isCancelled()) try retry.wait(1, null);
            self.releases += 1;
            return loop_mod.Outcome.copy(allocator, &.{.{ .session_id = 101, .status = .cancelled, .transport = .local, .error_code = "ApprovalCancelled", .local_released = true }});
        }
        if (self.mode == .real_exec) return self.realExec(invocation, allocator, cancel);
        if (self.mode == .cancel_after_success) cancel.?.cancel();
        if (self.mode == .remote_unknown) return loop_mod.Outcome.copy(allocator, &.{.{ .session_id = 101, .status = .cancelled, .transport = .ssh, .stdout = "original partial stdout", .local_released = true, .remote_effect_unknown = true }});
        return loop_mod.Outcome.copy(allocator, &.{.{ .session_id = 101, .status = if (self.mode == .uncertain) .unknown else .succeeded, .transport = .local, .stdout = "actual-controlled-output", .exit = if (self.mode == .uncertain or self.mode == .no_exit) null else 0, .cwd = "/tmp", .local_released = true }});
    }
    fn realExec(self: *ControlledHost, invocation: loop_mod.Invocation, allocator: std.mem.Allocator, cancel: ?*provider.CancelToken) !loop_mod.Outcome {
        const local_exec = @import("../local/exec.zig");
        const native = @import("../local/native.zig");
        const owner: @import("../host/identity.zig").SessionHandle = .{ .session_id = @fromBackingInt(101), .generation = 13 };
        var failure: native.Failure = .{};
        var command = try local_exec.Command.start(allocator, owner, .{ .owner = .{ .session = owner }, .operation_id = 701 }, 91, invocation.call.command, "/tmp", .{ .timeout_ms = invocation.timeout_ms, .capture_bytes = invocation.capture_bytes }, &failure);
        defer command.deinit() catch @panic("controlled local exec did not release");
        while (true) {
            if (cancel) |token| if (token.isCancelled()) try command.cancel(owner);
            const result = try command.poll();
            if (result.cleanup == .released) {
                self.releases += 1;
                return loop_mod.Outcome.copy(allocator, &.{.{ .session_id = 101, .status = if (result.timed_out) .timed_out else if (result.cancelled) .cancelled else if (result.exit != null and result.exit.? == .exited and result.exit.?.exited == 0) .succeeded else .failed, .transport = .local, .stdout = result.stdout, .stderr = result.stderr, .exit = if (result.exit) |exit| if (exit == .exited) exit.exited else null else null, .signal = if (result.exit) |exit| if (exit == .signal) exit.signal else null else null, .cwd = "/tmp", .truncated = result.truncated, .elapsed_ms = native.zw_local_monotonic_ms() - command.started_ms, .local_released = true }});
            }
            try retry.wait(1, null);
        }
    }
};
fn managerFor(host: *ControlledHost) manager_mod.Manager {
    var manager = manager_mod.Manager.init(a);
    manager.scope = scope;
    manager.turn_id = 77;
    manager.tool_host = host.interface();
    manager.tool_limits.context_window = 200_000;
    manager.retry_policy = .{ .delays_ms = .{ 0, 0, 0 } };
    return manager;
}
fn makeRequest(cancel: ?*provider.CancelToken) provider.ChatRequest {
    return .{ .model = "controlled-model", .system = "frozen system", .messages = &.{.{ .content = "Read the filesystem capacity" }}, .tools = &definitions, .cancel = cancel };
}
fn resultFromBody(body: []const u8, message_index: usize) !std.json.Parsed(std.json.Value) {
    const wire = try std.json.parseFromSlice(std.json.Value, a, body, .{});
    defer wire.deinit();
    const messages = wire.value.object.get("messages").?.array.items;
    const result = messages[message_index];
    try std.testing.expectEqualStrings("tool", result.object.get("role").?.string);
    try std.testing.expectEqualStrings(df.id, result.object.get("tool_call_id").?.string);
    return std.json.parseFromSlice(std.json.Value, a, result.object.get("content").?.string, .{ .allocate = .alloc_always });
}

test "tool loop executes real local readonly process before original ID feedback and final answer" {
    var script: Script = .{ .rounds = &.{ .{ .text = "Reading capacity.", .calls = &.{df} }, .{ .text = "Filesystem capacity was read." } } };
    defer script.deinit();
    var host: ControlledHost = .{ .mode = .real_exec, .script = &script };
    script.dispatch_count = &host.count;
    var manager = managerFor(&host);
    defer manager.deinit();
    const stats = try manager.run(script.interface(), makeRequest(null));
    try std.testing.expectEqual(@as(usize, 1), host.count);
    try std.testing.expectEqual(@as(usize, 1), host.releases);
    try std.testing.expectEqual(@as(u32, 6), stats.input_tokens);
    try std.testing.expectEqual(@import("turn.zig").State.done, manager.turn.state);
    const wire = try std.json.parseFromSlice(std.json.Value, a, script.requests.items[1], .{});
    defer wire.deinit();
    const messages = wire.value.object.get("messages").?.array.items;
    try std.testing.expectEqualStrings(df.id, messages[2].object.get("tool_calls").?.array.items[0].object.get("id").?.string);
    var result = try resultFromBody(script.requests.items[1], 3);
    defer result.deinit();
    const target = result.value.object.get("targets").?.array.items[0].object;
    try std.testing.expectEqualStrings("succeeded", target.get("status").?.string);
    try std.testing.expectEqual(@as(i64, 0), target.get("exit").?.integer);
    try std.testing.expect(std.mem.indexOf(u8, target.get("stdout").?.string, "Filesystem") != null);
    try std.testing.expectEqualStrings("/tmp", target.get("cwd").?.string);
    try std.testing.expect(target.get("local_released").?.bool);
    try std.testing.expectEqualStrings("Filesystem capacity was read.", manager.cards.cards.items[manager.cards.count() - 1].text);
}

test "tool loop provider retries and repeated call ID never repeat a completed dispatch" {
    var script: Script = .{ .rounds = &.{ .{ .calls = &.{df} }, .{ .calls = &.{df} }, .{ .text = "final" } }, .transient_round = 1 };
    defer script.deinit();
    var host: ControlledHost = .{ .script = &script };
    script.dispatch_count = &host.count;
    var manager = managerFor(&host);
    defer manager.deinit();
    _ = try manager.run(script.interface(), makeRequest(null));
    try std.testing.expectEqual(@as(usize, 4), script.requests.items.len);
    try std.testing.expectEqual(@as(usize, 1), host.count);
    try std.testing.expectEqual(@as(usize, 1), manager.tool_run.?.records.items.len);
    try std.testing.expectEqualStrings("final", manager.cards.cards.items[0].text);
    var result = try resultFromBody(script.requests.items[3], 5);
    defer result.deinit();
    try std.testing.expectEqualStrings("actual-controlled-output", result.value.object.get("targets").?.array.items[0].object.get("stdout").?.string);
}

test "same call ID with changed arguments is structured rejection without redispatch" {
    var changed = df;
    changed.arguments = "{\"session_ids\":[101],\"command\":\"df -i\"}";
    var script: Script = .{ .rounds = &.{ .{ .calls = &.{df} }, .{ .calls = &.{changed} }, .{ .text = "done" } } };
    defer script.deinit();
    var host: ControlledHost = .{ .script = &script };
    var manager = managerFor(&host);
    defer manager.deinit();
    _ = try manager.run(script.interface(), makeRequest(null));
    try std.testing.expectEqual(@as(usize, 1), host.count);
    var result = try resultFromBody(script.requests.items[2], 5);
    defer result.deinit();
    try std.testing.expectEqualStrings("CallIdentityConflict", result.value.object.get("error_code").?.string);
}

test "strict malformed unavailable and out of scope calls return errors with zero effects" {
    const invalid = [_]provider.ToolCall{
        .{ .id = "unknown", .name = "spawn_agent", .arguments = "{}" },
        .{ .id = "out", .name = "run_command", .arguments = "{\"session_ids\":[999],\"command\":\"df -h\"}" },
        .{ .id = "extra", .name = "run_command", .arguments = "{\"session_ids\":[101],\"command\":\"df -h\",\"max_bytes\":1}" },
        .{ .id = "nul", .name = "run_command", .arguments = "{\"session_ids\":[101],\"command\":\"df\\u0000-h\"}" },
        .{ .id = "file", .name = "read_remote_file", .arguments = "{\"session_ids\":[101],\"path\":\"/etc/hosts\"}" },
        .{ .id = "blocked", .name = "run_command", .arguments = "{\"session_ids\":[101],\"command\":\"rm -rf /\"}" },
    };
    var script: Script = .{ .rounds = &.{ .{ .calls = &invalid }, .{ .text = "rejections received" } } };
    defer script.deinit();
    var host: ControlledHost = .{};
    var manager = managerFor(&host);
    defer manager.deinit();
    _ = try manager.run(script.interface(), makeRequest(null));
    try std.testing.expectEqual(@as(usize, 0), host.count);
    try std.testing.expectEqual(@as(usize, invalid.len), manager.tool_run.?.records.items.len);
    for (manager.tool_run.?.records.items) |record| {
        try std.testing.expect(!record.dispatched);
        const result = try std.json.parseFromSlice(std.json.Value, a, record.result_body.?, .{});
        defer result.deinit();
        try std.testing.expectEqualStrings("rejected", result.value.object.get("status").?.string);
    }
}

test "unknown result or thrown receipt blocks further dispatch and is never failed" {
    for ([_]@FieldType(ControlledHost, "mode"){ .uncertain, .throws, .no_exit }) |mode| {
        var other = df;
        other.id = "second-call";
        var script: Script = .{ .rounds = &.{.{ .calls = &.{ df, other } }} };
        defer script.deinit();
        var host: ControlledHost = .{ .mode = mode };
        var manager = managerFor(&host);
        defer manager.deinit();
        try std.testing.expectError(error.ToolOutcomeUnknown, manager.run(script.interface(), makeRequest(null)));
        try std.testing.expectEqual(@as(usize, 1), host.count);
        try std.testing.expectEqual(@as(usize, 1), script.index);
        try std.testing.expect(manager.tool_run.?.uncertain);
        const record = manager.tool_run.?.records.items[0];
        try std.testing.expect(record.dispatched);
        const result = try std.json.parseFromSlice(std.json.Value, a, record.result_body.?, .{});
        defer result.deinit();
        if (mode == .uncertain) {
            try std.testing.expectEqualStrings("unknown", result.value.object.get("targets").?.array.items[0].object.get("status").?.string);
        } else try std.testing.expectEqualStrings("unknown", result.value.object.get("status").?.string);
    }
}

test "approval waiting remains pending until cancellation receipt and starts no next round" {
    var write = df;
    write.arguments = "{\"session_ids\":[101],\"command\":\"printf pending\"}";
    var script: Script = .{ .rounds = &.{.{ .calls = &.{write} }} };
    defer script.deinit();
    var host: ControlledHost = .{ .mode = .wait_approval };
    var manager = managerFor(&host);
    defer manager.deinit();
    var cancel: provider.CancelToken = .{};
    const Worker = struct {
        manager: *manager_mod.Manager,
        script: *Script,
        cancel: *provider.CancelToken,
        failure: ?anyerror = null,
        done: std.atomic.Value(bool) = .init(false),
        fn run(self: *@This()) void {
            _ = self.manager.run(self.script.interface(), makeRequest(self.cancel)) catch |err| {
                self.failure = err;
                self.done.store(true, .release);
                return;
            };
            self.done.store(true, .release);
        }
    };
    var worker: Worker = .{ .manager = &manager, .script = &script, .cancel = &cancel };
    const thread = try std.Thread.spawn(.{}, Worker.run, .{&worker});
    defer {
        cancel.cancel();
        thread.join();
    }
    var wait_attempts: usize = 0;
    while (!host.waiting.load(.acquire) and !worker.done.load(.acquire) and wait_attempts < 2000) : (wait_attempts += 1) try retry.wait(1, null);
    try std.testing.expect(host.waiting.load(.acquire));
    try std.testing.expect(!worker.done.load(.acquire));
    try std.testing.expectEqual(@import("turn.zig").State.await_confirm, manager.turn.state);
    cancel.cancel();
    while (!worker.done.load(.acquire)) try retry.wait(1, null);
    try std.testing.expectEqual(error.Cancelled, worker.failure.?);
    try std.testing.expectEqual(@as(usize, 1), script.index);
    try std.testing.expectEqual(@as(usize, 1), host.releases);
    try std.testing.expectEqual(loop_mod.Status.cancelled, manager.tool_run.?.records.items[0].outcome.?.targets[0].status);
}

test "Stop preserves proven completed result and prevents followup provider round" {
    var script: Script = .{ .rounds = &.{.{ .calls = &.{df} }} };
    defer script.deinit();
    var host: ControlledHost = .{ .mode = .cancel_after_success };
    var manager = managerFor(&host);
    defer manager.deinit();
    var cancel: provider.CancelToken = .{};
    try std.testing.expectError(error.Cancelled, manager.run(script.interface(), makeRequest(&cancel)));
    const target = manager.tool_run.?.records.items[0].outcome.?.targets[0];
    try std.testing.expectEqual(loop_mod.Status.succeeded, target.status);
    try std.testing.expectEqual(@as(i32, 0), target.exit.?);
    try std.testing.expectEqual(@as(usize, 1), script.index);
}

test "bounded rounds preserve completed ledger and never continue infinitely" {
    var second = df;
    second.id = "call-second";
    var script: Script = .{ .rounds = &.{ .{ .calls = &.{df} }, .{ .calls = &.{second} } } };
    defer script.deinit();
    var host: ControlledHost = .{};
    var manager = managerFor(&host);
    defer manager.deinit();
    manager.tool_limits.max_rounds = 2;
    try std.testing.expectError(error.ToolRoundLimit, manager.run(script.interface(), makeRequest(null)));
    try std.testing.expectEqual(@as(usize, 2), host.count);
    try std.testing.expectEqual(@as(usize, 2), manager.tool_run.?.records.items.len);
    try std.testing.expect(manager.tool_run.?.records.items[1].outcome != null);
}

test "duplicate call IDs in one completed round reject all before dispatch" {
    var script: Script = .{ .rounds = &.{.{ .calls = &.{ df, df } }} };
    defer script.deinit();
    var host: ControlledHost = .{};
    var manager = managerFor(&host);
    defer manager.deinit();
    try std.testing.expectError(error.DuplicateToolCall, manager.run(script.interface(), makeRequest(null)));
    try std.testing.expectEqual(@as(usize, 0), host.count);
}

test "tool request without real host never finishes as a display only plan" {
    var manager = manager_mod.Manager.init(a);
    defer manager.deinit();
    var script: Script = .{ .rounds = &.{.{ .calls = &.{df} }} };
    defer script.deinit();
    try std.testing.expectError(error.ToolHostUnavailable, manager.run(script.interface(), makeRequest(null)));
    try std.testing.expectEqual(@as(usize, 0), script.index);
}

test "answer only retry retains completed ledger and cannot replay the same logical turn" {
    var script: Script = .{ .rounds = &.{ .{ .calls = &.{df} }, .{ .text = "recovered answer" } }, .transient_round = 1 };
    defer script.deinit();
    var host: ControlledHost = .{};
    var manager = managerFor(&host);
    defer manager.deinit();
    manager.retry_policy.max_attempts = 0;
    try std.testing.expectError(error.Transient, manager.run(script.interface(), makeRequest(null)));
    try std.testing.expectEqual(@as(usize, 1), host.count);
    const saved = manager.tool_run.?;
    try std.testing.expectError(error.ToolTurnAlreadyDispatched, manager.run(script.interface(), makeRequest(null)));
    try std.testing.expectEqual(saved, manager.tool_run.?);
    _ = try manager.resumeAnswer(script.interface(), null);
    try std.testing.expectEqual(@as(usize, 1), host.count);
    try std.testing.expectEqual(saved, manager.tool_run.?);
    const body = try std.json.parseFromSlice(std.json.Value, a, script.requests.items[2], .{});
    defer body.deinit();
    try std.testing.expect(body.value.object.get("tools") == null);
    var result = try resultFromBody(script.requests.items[2], 3);
    defer result.deinit();
    try std.testing.expectEqualStrings("actual-controlled-output", result.value.object.get("targets").?.array.items[0].object.get("stdout").?.string);
    try std.testing.expectEqualStrings("recovered answer", manager.cards.cards.items[manager.cards.count() - 1].text);
}

test "answer only retry rejects unexpected tool calls without a second execution" {
    var script: Script = .{ .rounds = &.{ .{ .calls = &.{df} }, .{ .calls = &.{df} } }, .transient_round = 1 };
    defer script.deinit();
    var host: ControlledHost = .{};
    var manager = managerFor(&host);
    defer manager.deinit();
    manager.retry_policy.max_attempts = 0;
    try std.testing.expectError(error.Transient, manager.run(script.interface(), makeRequest(null)));
    try std.testing.expectError(error.ToolInvocationDuringAnswerRetry, manager.resumeAnswer(script.interface(), null));
    try std.testing.expectEqual(@as(usize, 1), host.count);
}

test "frozen messages definitions owner and model own their source buffers" {
    var model = "model-one".*;
    var system = "system-one".*;
    var content = "question-one".*;
    var ids = [_]u64{101};
    var loop = loop_mod.Loop.init(a, scope, 77, .{ .context_window = 200_000 });
    defer loop.deinit();
    try loop.start(.{ .model = &model, .system = &system, .messages = &.{.{ .content = &content }}, .tools = &.{.{ .tool = .run_command, .session_ids = &ids }} });
    @memset(&model, 'x');
    @memset(&system, 'x');
    @memset(&content, 'x');
    ids[0] = 999;
    const frozen = try loop.nextRequest();
    try std.testing.expectEqualStrings("model-one", frozen.model);
    try std.testing.expectEqualStrings("system-one", frozen.system);
    try std.testing.expectEqualStrings("question-one", frozen.messages[0].content);
    try std.testing.expectEqualSlices(u64, &.{101}, frozen.tools[0].session_ids);
    var host: ControlledHost = .{};
    try loop.complete("", &.{df}, host.interface(), .{}, 0, null);
    try std.testing.expectEqual(@as(usize, 1), host.count);
    try std.testing.expectEqualStrings(df.arguments, loop.records.items[0].arguments);
}

test "next round context overflow preserves full actual bounded output" {
    const LargeHost = struct {
        count: usize = 0,
        fn execute(raw: *anyopaque, _: loop_mod.Invocation, allocator: std.mem.Allocator, _: ?*provider.CancelToken) !loop_mod.Outcome {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.count += 1;
            const output = try allocator.alloc(u8, 65536);
            defer allocator.free(output);
            @memset(output, 'x');
            return loop_mod.Outcome.copy(allocator, &.{.{ .session_id = 101, .status = .succeeded, .stdout = output, .exit = 0, .truncated = true }});
        }
    };
    var host: LargeHost = .{};
    var manager = manager_mod.Manager.init(a);
    defer manager.deinit();
    manager.scope = scope;
    manager.turn_id = 77;
    manager.tool_host = .{ .context = &host, .execute = LargeHost.execute };
    var script: Script = .{ .rounds = &.{.{ .calls = &.{df} }} };
    defer script.deinit();
    try std.testing.expectError(error.ToolContextBudget, manager.run(script.interface(), makeRequest(null)));
    try std.testing.expectEqual(@as(usize, 1), script.index);
    const target = manager.tool_run.?.records.items[0].outcome.?.targets[0];
    try std.testing.expectEqual(@as(usize, 65536), target.stdout.len);
    try std.testing.expect(target.truncated);
    try std.testing.expectEqual(loop_mod.Status.succeeded, target.status);
}

test "result storage capacity is checked before any irreversible dispatch" {
    var host: ControlledHost = .{};
    var manager = managerFor(&host);
    defer manager.deinit();
    manager.tool_limits.max_retained_output_bytes = 1024;
    var script: Script = .{ .rounds = &.{ .{ .calls = &.{df} }, .{ .text = "capacity rejection received" } } };
    defer script.deinit();
    _ = try manager.run(script.interface(), makeRequest(null));
    try std.testing.expectEqual(@as(usize, 0), host.count);
    var result = try resultFromBody(script.requests.items[1], 3);
    defer result.deinit();
    try std.testing.expectEqualStrings("ToolResultCapacity", result.value.object.get("error_code").?.string);
}

test "binary stdout is preserved with explicit encoding and no fabricated exit" {
    const BinaryHost = struct {
        fn execute(_: *anyopaque, _: loop_mod.Invocation, allocator: std.mem.Allocator, _: ?*provider.CancelToken) !loop_mod.Outcome {
            return loop_mod.Outcome.copy(allocator, &.{.{ .session_id = 101, .status = .failed, .stdout = &.{ 0xff, 0, 'E' }, .stderr = "Error", .exit = 7, .transport = .local }});
        }
    };
    var loop = loop_mod.Loop.init(a, scope, 77, .{ .context_window = 200_000 });
    defer loop.deinit();
    try loop.start(makeRequest(null));
    _ = try loop.nextRequest();
    try loop.complete("", &.{df}, .{ .context = undefined, .execute = BinaryHost.execute }, .{}, 0, null);
    try std.testing.expectEqualSlices(u8, &.{ 0xff, 0, 'E' }, loop.records.items[0].outcome.?.targets[0].stdout);
    const body = try std.json.parseFromSlice(std.json.Value, a, loop.records.items[0].result_body.?, .{});
    defer body.deinit();
    const target = body.value.object.get("targets").?.array.items[0].object;
    try std.testing.expectEqualStrings("base64", target.get("stdout_encoding").?.string);
    try std.testing.expectEqualStrings("/wBF", target.get("stdout").?.string);
    try std.testing.expectEqual(@as(i64, 7), target.get("exit").?.integer);
    try std.testing.expectEqualStrings("failed", target.get("status").?.string);
}

test "released SSH command with unknown remote effect blocks continuation and answer retry while retaining exact facts" {
    var other = df;
    other.id = "must-not-dispatch";
    var script: Script = .{ .rounds = &.{.{ .calls = &.{ df, other } }} };
    defer script.deinit();
    var host: ControlledHost = .{ .mode = .remote_unknown };
    var manager = managerFor(&host);
    defer manager.deinit();
    try std.testing.expectError(error.ToolOutcomeUnknown, manager.run(script.interface(), makeRequest(null)));
    try std.testing.expectEqual(@as(usize, 1), host.count);
    try std.testing.expectEqual(@as(usize, 1), script.index);
    const run = manager.tool_run.?;
    try std.testing.expect(run.uncertain);
    try std.testing.expectError(error.ToolOutcomeUnknown, run.nextRequest());
    try std.testing.expectError(error.ToolOutcomeUnknown, manager.resumeAnswer(script.interface(), null));
    const target = run.records.items[0].outcome.?.targets[0];
    try std.testing.expect(target.local_released and target.remote_effect_unknown);
    try std.testing.expectEqual(loop_mod.Status.cancelled, target.status);
    try std.testing.expectEqualStrings("original partial stdout", target.stdout);
    const result = try std.json.parseFromSlice(std.json.Value, a, run.records.items[0].result_body.?, .{});
    defer result.deinit();
    const encoded = result.value.object.get("targets").?.array.items[0].object;
    try std.testing.expect(encoded.get("local_released").?.bool);
    try std.testing.expect(encoded.get("remote_effect_unknown").?.bool);
    try std.testing.expectEqualStrings("cancelled", encoded.get("status").?.string);
    try std.testing.expect(!run.records.items[1].dispatched);
}

test "answer retry without tool capability keeps frozen scoped request and partial attempt" {
    var script: Script = .{ .rounds = &.{.{ .text = "recovered without tools" }}, .transient_round = 0 };
    defer script.deinit();
    var manager = manager_mod.Manager.init(a);
    defer manager.deinit();
    manager.scope = scope;
    manager.turn_id = 81;
    manager.retry_policy.max_attempts = 0;
    var request = makeRequest(null);
    request.tools = &.{};
    try std.testing.expectError(error.Transient, manager.run(script.interface(), request));
    const captured = manager.tool_run.?;
    try std.testing.expectEqualStrings("failed-attempt-prefix", manager.cards.cards.items[0].text);
    _ = try manager.resumeAnswer(script.interface(), null);
    try std.testing.expectEqual(captured, manager.tool_run.?);
    try std.testing.expectEqual(@as(u64, 81), manager.turn_id);
    try std.testing.expectEqualStrings("failed-attempt-prefix", manager.cards.cards.items[0].text);
    try std.testing.expectEqualStrings("recovered without tools", manager.cards.cards.items[1].text);
}

test "manual answer retry honors retained Retry-After deadline without requesting or replaying" {
    const Limited = struct {
        calls: usize = 0,
        fn chat(raw: *anyopaque, request: provider.ChatRequest, _: *const fn (*anyopaque, provider.Delta) void, _: *anyopaque) !provider.ChatStats {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.calls += 1;
            request.retry_after_ms.?.* = 60_000;
            return error.RateLimited;
        }
    };
    var limited: Limited = .{};
    var manager = manager_mod.Manager.init(a);
    defer manager.deinit();
    manager.scope = scope;
    manager.turn_id = 82;
    manager.retry_policy.max_attempts = 0;
    var request = makeRequest(null);
    request.tools = &.{};
    const p: provider.Provider = .{ .ctx = &limited, .chat = Limited.chat, .models = Script.models };
    try std.testing.expectError(error.RateLimited, manager.run(p, request));
    try std.testing.expect(manager.cooldownRemainingMs() > 0);
    try std.testing.expectError(error.ProviderCoolingDown, manager.resumeAnswer(p, null));
    try std.testing.expectEqual(@as(usize, 1), limited.calls);
}

test "failed request snapshot construction leaves no resumable uninitialized ledger" {
    var script: Script = .{ .rounds = &.{} };
    defer script.deinit();
    var manager = manager_mod.Manager.init(a);
    defer manager.deinit();
    manager.scope = scope;
    manager.turn_id = 84;
    manager.tool_limits.max_rounds = 0;
    var request = makeRequest(null);
    request.tools = &.{};
    try std.testing.expectError(error.InvalidToolLoopLimits, manager.run(script.interface(), request));
    try std.testing.expect(manager.tool_run == null);
    try std.testing.expectError(error.NoToolTurnToResume, manager.resumeAnswer(script.interface(), null));
    try std.testing.expectEqual(@as(usize, 0), script.index);
}

test "host uncertain execution blocks a fresh command while preserving exact read and stop receipts" {
    const tools = @import("plugin_tools.zig");
    const identity = @import("../host/identity.zig");
    const context: tools.host.Context = .{ .conversation_id = identity.ConversationId.generate(), .task_id = identity.TaskId.generate(), .binding = scope.owner, .binding_revision = 1, .grant_revision = 1 };
    var table = try tools.RequestTable.initWithHost(a, scope, &.{}, &.{}, context, &@import("host_execution.zig").contributions);
    defer table.deinit();
    const wire = try tools.providerDefinitions(&table, table.arena.allocator());
    const Gateway = struct {
        calls: usize = 0,
        writes: usize = 0,
        stops: usize = 0,
        fn legacy(_: *anyopaque, _: loop_mod.Invocation, _: std.mem.Allocator, _: ?*provider.CancelToken) !loop_mod.Outcome {
            return error.UnexpectedLegacyDispatch;
        }
        fn invoke(raw: *anyopaque, invocation: tools.host.Invocation, _: std.mem.Allocator, _: ?*provider.CancelToken) !tools.host.Result {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.calls += 1;
            const writing = std.mem.eql(u8, invocation.tool_id, "host.run_in_terminal");
            self.writes += @intFromBool(writing);
            self.stops += @intFromBool(std.mem.eql(u8, invocation.tool_id, "host.stop_execution"));
            return .{ .status = if (writing) .outcome_unknown else .succeeded, .receipt = .{ .conversation_id = invocation.context.conversation_id, .task_id = invocation.context.task_id, .operation_id = invocation.operation_id, .binding_revision = invocation.context.binding_revision, .side_effect_started = writing, .remote_effect_unknown = writing } };
        }
    };
    var gateway: Gateway = .{};
    var run = loop_mod.Loop.init(a, scope, 17, .{ .context_window = 100_000 });
    defer run.deinit();
    try run.start(.{ .model = "test", .system = "", .messages = &.{}, .tools = wire, .tool_table = &table });
    try run.complete("", &.{
        .{ .id = "original", .name = wire[0].name(), .arguments = "{\"session_ref\":\"s1:opaque\",\"command\":\"printf ok\",\"request_key\":\"original\"}" },
        .{ .id = "new-key", .name = wire[0].name(), .arguments = "{\"session_ref\":\"s1:opaque\",\"command\":\"printf again\",\"request_key\":\"different\"}" },
        .{ .id = "observe", .name = wire[1].name(), .arguments = "{\"execution_ref\":\"x1:opaque\"}" },
        .{ .id = "stop", .name = wire[4].name(), .arguments = "{\"execution_ref\":\"x1:opaque\",\"request_key\":\"stop\"}" },
    }, .{ .context = &gateway, .execute = Gateway.legacy, .execute_host = Gateway.invoke }, .{}, 1, null);
    try std.testing.expect(run.uncertain);
    try std.testing.expectEqual(@as(usize, 1), gateway.writes);
    try std.testing.expectEqual(@as(usize, 1), gateway.stops);
    try std.testing.expectEqual(@as(usize, 3), gateway.calls);
    try std.testing.expect(!run.records.items[1].dispatched);
    try std.testing.expect(std.mem.indexOf(u8, run.records.items[1].result_body.?, "EarlierToolOutcomeUnknown") != null);
    try http.validateToolMessages(.{ .model = "test", .system = "", .messages = run.messages.items });
}
