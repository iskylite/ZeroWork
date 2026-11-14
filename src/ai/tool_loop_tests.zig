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
            return .{ .table = try tools.cloneTable(self.successor, allocator), .notice = try allocator.dupe(u8, "ZeroWork context notice: original conversation now belongs to group 7; binding revision 2."), .notice_revision = 1, .system = try @import("session_prompt.zig").build(allocator, .auto, try tools.providerDefinitions(self.successor, self.successor.arena.allocator())) };
        }
        fn ack(raw: *anyopaque, revision: u64, _: ?*provider.CancelToken) !void {
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
    try std.testing.expect(std.mem.indexOf(u8, request.system, "connection assistant") != null);
    try std.testing.expect(std.mem.indexOf(u8, request.system, "stable rules") == null);
    try std.testing.expect(std.mem.indexOf(u8, request.system, "Current host execution mode") == null);
    try http.validateToolMessages(request);
    try std.testing.expectEqualStrings("create-original", request.messages[1].tool_call_id.?);
    try std.testing.expectEqual(provider.Role.user, request.messages[2].role);
    try run.acknowledgeNotice(callbacks, null);
    try run.acknowledgeNotice(callbacks, null);
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

test "tool deadline cancelled authority refresh releases the candidate and keeps the old snapshot" {
    const tools = @import("plugin_tools.zig");
    const identity = @import("../host/identity.zig");
    const context: tools.host.Context = .{ .conversation_id = identity.ConversationId.generate(), .task_id = identity.TaskId.generate(), .binding = scope.owner, .binding_revision = 1, .grant_revision = 1 };
    var table = try tools.RequestTable.initWithHost(a, scope, &.{}, &.{}, context, &.{.{ .authority = .conversation_context, .definition = .{ .id = "host.get_current_context", .schema = "{\"type\":\"object\"}" } }});
    defer table.deinit();
    const Fixture = struct {
        calls: usize = 0,
        fn execute(_: *anyopaque, _: loop_mod.Invocation, _: std.mem.Allocator, _: ?*provider.CancelToken) !loop_mod.Outcome {
            return error.UnexpectedDispatch;
        }
        fn refresh(raw: *anyopaque, previous: *const tools.RequestTable, allocator: std.mem.Allocator, cancel: ?*provider.CancelToken) !?loop_mod.AuthorityRefresh {
            @as(*@This(), @ptrCast(@alignCast(raw))).calls += 1;
            var next = try tools.cloneTable(previous, allocator);
            errdefer next.deinit();
            const notice = try allocator.dupe(u8, "cancelled candidate");
            errdefer allocator.free(notice);
            const system = try allocator.dupe(u8, "cancelled system");
            cancel.?.cancel();
            return .{ .table = next, .notice = notice, .notice_revision = 1, .system = system };
        }
    };
    var fixture: Fixture = .{};
    var run = loop_mod.Loop.init(a, scope, 1, .{});
    defer run.deinit();
    const wire = try tools.providerDefinitions(&table, table.arena.allocator());
    try run.start(.{ .model = "fixture", .system = "", .messages = &.{}, .tools = wire, .tool_table = &table });
    var cancel: provider.CancelToken = .{};
    const callbacks: loop_mod.Host = .{ .context = &fixture, .execute = Fixture.execute, .refresh_authority = Fixture.refresh };
    try std.testing.expectError(error.Cancelled, run.refreshAuthority(callbacks, &cancel));
    try std.testing.expectEqual(@as(u64, 0), run.notice_revision);
    try std.testing.expectEqualStrings("", run.request.system);
    try std.testing.expectEqual(@as(usize, 0), run.messages.items.len);
    try std.testing.expectEqual(@as(usize, 1), fixture.calls);
    try std.testing.expectError(error.Cancelled, run.refreshAuthority(callbacks, &cancel));
    try std.testing.expectEqual(@as(usize, 1), fixture.calls);
}

test "tool deadline Stop after accepted result skips later notifications without dropping facts" {
    const tools = @import("plugin_tools.zig");
    const identity = @import("../host/identity.zig");
    const context: tools.host.Context = .{ .conversation_id = identity.ConversationId.generate(), .task_id = identity.TaskId.generate(), .binding = scope.owner, .binding_revision = 1, .grant_revision = 1 };
    var table = try tools.RequestTable.initWithHost(a, scope, &.{}, &.{}, context, &.{.{ .authority = .conversation_context, .definition = .{ .id = "host.get_current_context", .schema = "{\"type\":\"object\"}" } }});
    defer table.deinit();
    const Fixture = struct {
        executed: usize = 0,
        notifications: usize = 0,
        fn legacy(_: *anyopaque, _: loop_mod.Invocation, _: std.mem.Allocator, _: ?*provider.CancelToken) !loop_mod.Outcome {
            return error.UnexpectedDispatch;
        }
        fn invoke(raw: *anyopaque, invocation: tools.host.Invocation, _: std.mem.Allocator, _: ?*provider.CancelToken) !tools.host.Result {
            @as(*@This(), @ptrCast(@alignCast(raw))).executed += 1;
            return .{ .status = .succeeded, .receipt = .{ .conversation_id = invocation.context.conversation_id, .task_id = invocation.context.task_id, .operation_id = invocation.operation_id, .binding_revision = invocation.context.binding_revision } };
        }
        fn accepted(raw: *anyopaque, _: tools.host.Context, _: []const u8, _: *const tools.host.Result, cancel: ?*provider.CancelToken) !void {
            @as(*@This(), @ptrCast(@alignCast(raw))).notifications += 1;
            cancel.?.cancel();
        }
    };
    var fixture: Fixture = .{};
    var run = loop_mod.Loop.init(a, scope, 1, .{});
    defer run.deinit();
    const wire = try tools.providerDefinitions(&table, table.arena.allocator());
    try run.start(.{ .model = "fixture", .system = "", .messages = &.{}, .tools = wire, .tool_table = &table });
    var cancel: provider.CancelToken = .{};
    const callbacks: loop_mod.Host = .{ .context = &fixture, .execute = Fixture.legacy, .execute_host = Fixture.invoke, .accepted_host_result = Fixture.accepted };
    try run.complete("", &.{ .{ .id = "first", .name = wire[0].name(), .arguments = "{}" }, .{ .id = "second", .name = wire[0].name(), .arguments = "{}" } }, callbacks, .{}, 1, &cancel);
    try std.testing.expectEqual(@as(usize, 2), fixture.executed);
    try std.testing.expectEqual(@as(usize, 1), fixture.notifications);
    try std.testing.expectEqual(@as(usize, 2), run.records.items.len);
    try std.testing.expect(run.records.items[0].host_result != null and run.records.items[1].host_result != null);
    try http.validateToolMessages(run.request);
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
    interrupted_error: anyerror = error.Transient,
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
            return self.interrupted_error;
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

test "notes new conversation retrieves committed context and old citations keep local access" {
    const tools = @import("plugin_tools.zig");
    const notes = @import("../plugins/notes/ai_tools.zig");
    const queries = @import("../plugins/notes/queries.zig");
    const notes_view = @import("../plugins/notes/view.zig");
    const identity = @import("../host/identity.zig");
    const ui = @import("ui");
    const io = std.testing.io;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var store = try @import("../plugins/notes/store.zig").Store.init(a, io, temporary.dir);
    defer store.deinit();
    var documents = @import("../plugins/notes/document_sessions.zig").Sessions.init(a, &store);
    defer documents.deinit();
    var evidence = std.heap.ArenaAllocator.init(a);
    defer evidence.deinit();
    const scratch = evidence.allocator();

    const library = try store.createLibrary("运维");
    const private_library = try store.createLibrary("私密目录");
    const note = try store.createNote(library, null, "部署约定");
    const private_note = try store.createNote(private_library, null, "证书");
    const committed = "证书提前 30 天续期。";
    const draft = "未提交的续期修改。";
    const revision = try store.changeNote(note, 1, .{ .save = .{ .title = "部署约定", .body_md = committed } });
    const local_owner: identity.SessionHandle = .{ .session_id = @fromBackingInt(101), .generation = 1 };
    const lease = (try documents.open(note, local_owner)).lease;
    try documents.edit((try documents.snapshot(lease)).stamp, .{ .title = "部署约定", .body_md = draft });
    const query: queries.Queries = .{ .store = &store };
    try std.testing.expectEqual(@as(usize, 0), (try notes.available(query, a, false)).len);
    _ = try store.changeLibrary(library, 1, .{ .ai_readable = true });

    const authority: tools.host.Context = .{ .conversation_id = .generate(), .task_id = .generate(), .binding = scope.owner, .binding_revision = 1, .grant_revision = 1 };
    var table = try tools.RequestTable.initWithHost(a, scope, &.{}, &.{}, authority, try notes.available(query, a, false));
    defer table.deinit();
    const wire = try tools.providerDefinitions(&table, table.arena.allocator());
    try std.testing.expectEqual(@as(usize, 3), wire.len);
    try std.testing.expect(table.lookup("host__notes_uread_uimage") == null);
    const search_name = table.lookup("host__notes_usearch").?.provider_name;
    const read_name = table.lookup("host__notes_uread").?.provider_name;
    const prompt = try @import("session_prompt.zig").build(scratch, .auto, wire);
    try std.testing.expect(std.mem.indexOf(u8, prompt, search_name) != null);
    try std.testing.expect(std.mem.indexOf(u8, prompt, read_name) != null);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "exact source_ref") != null);

    const Gateway = struct {
        context: tools.host.Context,
        query: queries.Queries,
        calls: usize = 0,
        fn legacy(_: *anyopaque, _: loop_mod.Invocation, _: std.mem.Allocator, _: ?*provider.CancelToken) !loop_mod.Outcome {
            return error.UnexpectedLegacyDispatch;
        }
        fn invoke(raw: *anyopaque, call: tools.host.Invocation, allocator: std.mem.Allocator, cancel: ?*provider.CancelToken) !tools.host.Result {
            const self: *@This() = @ptrCast(@alignCast(raw));
            if (!self.context.eql(call.context)) return error.StaleToolAuthority;
            self.calls += 1;
            return notes.execute(self.query, call, allocator, cancel, null);
        }
    };
    var gateway: Gateway = .{ .context = authority, .query = query };
    const callbacks: loop_mod.Host = .{ .context = &gateway, .execute = Gateway.legacy, .execute_host = Gateway.invoke };
    const read_call: provider.ToolCall = .{ .id = "notes-read", .name = read_name, .arguments = try std.json.Stringify.valueAlloc(scratch, .{ .note_id = note.note_id, .expected_revision = revision }, .{}) };
    const private_args = try std.json.Stringify.valueAlloc(scratch, .{ .note_id = private_note.note_id }, .{});
    const stale_args = try std.json.Stringify.valueAlloc(scratch, .{ .note_id = note.note_id, .expected_revision = revision + 1 }, .{});
    const expected: queries.SourceRef = .{ .key = note, .revision = revision, .range = .{ .start_byte = 0, .end_byte = committed.len } };
    const answer = try std.fmt.allocPrint(scratch, "{s}[部署约定]({s})", .{ committed, try expected.format(scratch) });
    var script: Script = .{ .rounds = &.{
        .{ .calls = &.{.{ .id = "notes-search", .name = search_name, .arguments = "{\"query\":\"证书\",\"limit\":1}" }} },
        .{ .calls = &.{
            read_call,
            .{ .id = "notes-empty", .name = search_name, .arguments = "{\"query\":\"不存在的搜索词\"}" },
            .{ .id = "notes-denied", .name = read_name, .arguments = private_args },
            .{ .id = "notes-stale", .name = read_name, .arguments = stale_args },
        } },
        .{ .text = answer },
    } };
    defer script.deinit();
    var manager = manager_mod.Manager.init(a);
    defer manager.deinit();
    manager.scope = scope;
    manager.turn_id = 1;
    manager.tool_host = callbacks;
    manager.tool_limits.context_window = 100_000;
    const request: provider.ChatRequest = .{ .model = "fixture", .system = prompt, .messages = &.{.{ .content = "按照之前约定，证书应提前多久续期？" }}, .tools = wire, .tool_table = &table };
    _ = try manager.run(script.interface(), request);
    try std.testing.expectEqual(@as(usize, 3), script.requests.items.len);
    try std.testing.expectEqual(@as(usize, 5), gateway.calls);
    const search = try notesWireResult(scratch, script.requests.items[1], "notes-search");
    const hits = (try notesWireContent(scratch, search)).object.get("entries").?.array.items;
    try std.testing.expectEqual(@as(usize, 1), hits.len);
    try std.testing.expectEqualStrings("部署约定", hits[0].object.get("title").?.string);
    const read = try notesWireContent(scratch, try notesWireResult(scratch, script.requests.items[2], read_call.id));
    try std.testing.expectEqualStrings(committed, read.object.get("body_md").?.string);
    const source = try queries.SourceRef.parse(read.object.get("source_ref").?.string);
    try std.testing.expectEqualDeep(expected, source);
    const empty = try notesWireContent(scratch, try notesWireResult(scratch, script.requests.items[2], "notes-empty"));
    try std.testing.expectEqual(@as(usize, 0), empty.object.get("entries").?.array.items.len);
    const denied = try notesWireResult(scratch, script.requests.items[2], "notes-denied");
    try std.testing.expectEqualStrings("Unavailable", denied.object.get("error_code").?.string);
    try std.testing.expect(denied.object.get("content") == null);
    const stale = try notesWireResult(scratch, script.requests.items[2], "notes-stale");
    try std.testing.expectEqualStrings("RevisionChanged", stale.object.get("error_code").?.string);
    try std.testing.expect(stale.object.get("content") == null);
    try std.testing.expectEqualStrings(answer, manager.round_text.items);

    var pending = loop_mod.Loop.init(a, scope, 2, .{ .context_window = 100_000 });
    defer pending.deinit();
    try pending.start(request);
    try pending.complete("", &.{read_call}, callbacks, .{}, 1, null);
    try std.testing.expect(pending.records.items[0].host_result != null);

    // Exercise the real vision tool and provider encoder on both sides of the
    // authorization fence. A denied text result alone cannot prove bytes were removed.
    const png = "\x89PNG\r\n\x1a\n\x00\x00\x00\x0dIHDR" ++
        "\x00\x00\x00\x01\x00\x00\x00\x01\x08\x06\x00\x00\x00\x1f\x15\xc4\x89" ++
        "\x00\x00\x00\x0dIDAT\x78\x9c\x63\xf8\xcf\xc0\xf0\x1f\x00\x05\x00\x01\xff\x89\x99\x3d\x1d" ++
        "\x00\x00\x00\x00IEND\xae\x42\x60\x82";
    const assets = @import("../plugins/notes/assets.zig");
    var image_cancel: assets.CancelToken = .{};
    const image = try assets.importBytes(a, &store, library, png, &image_cancel, .{});
    const image_note = try store.createNote(library, null, "拓扑");
    const image_body = try std.fmt.allocPrint(scratch, "![测试拓扑]({s})", .{image.relativePath()});
    const image_revision = try store.changeNote(image_note, 1, .{ .save = .{ .title = "拓扑", .body_md = image_body } });
    var vision_table = try tools.RequestTable.initWithHost(a, scope, &.{}, &.{}, authority, try notes.available(query, a, true));
    defer vision_table.deinit();
    const vision_wire = try tools.providerDefinitions(&vision_table, vision_table.arena.allocator());
    const image_call: provider.ToolCall = .{
        .id = "notes-image",
        .name = vision_table.lookup("host__notes_uread_uimage").?.provider_name,
        .arguments = try std.json.Stringify.valueAlloc(scratch, .{ .note_id = image_note.note_id, .expected_revision = image_revision, .asset_ref = image.relativePath() }, .{}),
    };
    var image_loop = loop_mod.Loop.init(a, scope, 3, .{ .context_window = 100_000 });
    defer image_loop.deinit();
    var vision_request = request;
    vision_request.tool_table = &vision_table;
    vision_request.tools = vision_wire;
    vision_request.vision = true;
    vision_request.tool_images = true;
    vision_request.image_token_reservation = 1024;
    try image_loop.start(vision_request);
    try image_loop.complete("", &.{image_call}, callbacks, .{}, 1, null);
    const allowed_image_request = try image_loop.nextRequest();
    try http.validateToolMessages(allowed_image_request);
    try std.testing.expectEqual(@as(usize, 1), allowed_image_request.messages[2].images.len);
    const base64 = std.base64.standard.Encoder;
    const encoded_png = base64.encode(try scratch.alloc(u8, base64.calcSize(png.len)), png);
    const image_url = try std.fmt.allocPrint(scratch, "data:image/png;base64,{s}", .{encoded_png});
    const allowed_image_wire = try http.requestBody(scratch, .openai_compat, allowed_image_request, 100_000);
    try std.testing.expect(std.mem.indexOf(u8, allowed_image_wire, image_url) != null);

    _ = try store.changeLibrary(library, 2, .{ .ai_readable = false });
    const denied_image_request = try image_loop.nextRequest();
    try http.validateToolMessages(denied_image_request);
    try std.testing.expectEqual(@as(usize, 0), denied_image_request.messages[2].images.len);
    try std.testing.expectEqual(@as(usize, 0), denied_image_request.messages[2].offloaded_images.len);
    try std.testing.expect(image_loop.records.items[0].host_result == null);
    const denied_image_wire = try http.requestBody(scratch, .openai_compat, denied_image_request, 100_000);
    try std.testing.expect(std.mem.indexOf(u8, denied_image_wire, "data:image/") == null);
    const denied_image = try notesWireResult(scratch, denied_image_wire, image_call.id);
    try std.testing.expectEqualStrings("Unavailable", denied_image.object.get("error_code").?.string);
    const after_revoke = try pending.nextRequest();
    try http.validateToolMessages(after_revoke);
    try std.testing.expectEqualStrings("{\"status\":\"rejected\",\"error_code\":\"Unavailable\"}", after_revoke.messages[2].content);
    try std.testing.expectEqualStrings(read_call.id, after_revoke.messages[2].tool_call_id.?);
    try std.testing.expectEqual(@as(usize, 0), (try notes.available(query, a, true)).len);
    try std.testing.expectEqual(.current, (try query.resolveSource(a, source, null)).state);

    const cx = try ui.Cx.init(a, io);
    defer cx.deinit();
    const ui_scope = try ui.Scope.init(a, null, cx.owner);
    defer ui_scope.dispose();
    cx.setViewport(1154, 828);
    cx.root = try ui.box(cx, .{ .width = .fill(), .height = .fill() }, .{});
    const instance = try notes_view.mount(.{
        .cx = cx,
        .scope = ui_scope,
        .slot = cx.root.?,
        .owner = local_owner,
        .connection = .{ .protocol_id = "notes", .name = "笔记", .payload_version = 1, .payload = "{}" },
    }, &store, &documents);
    defer instance.vtable.unmount(instance.context);
    instance.vtable.presentation_changed.?(instance.context, .active);
    try std.testing.expect(notes_view.openNote(instance, note));
    notesFrames(cx);
    const Citation = struct {
        renderer: @import("../host/plugin_ui_contract.zig").RendererInstance,
        clicked: ?queries.SourceRef = null,
        fn open(raw: *anyopaque, selected: queries.SourceRef) void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            if (notes_view.openSource(self.renderer, selected)) self.clicked = selected;
        }
    };
    var citation: Citation = .{ .renderer = instance };
    const answer_ui = try ui.box(cx, .{}, .{});
    try cx.root.?.appendChild(a, answer_ui);
    try @import("../ui/ai_notes_citations.zig").append(cx, ui_scope, answer_ui, manager.round_text.items, .{ .context = &citation, .open = Citation.open });
    try std.testing.expectEqual(@as(usize, 1), answer_ui.children.items.len);
    const source_button = answer_ui.children.items[0];
    try std.testing.expectEqualStrings("ai.notes.source", source_button.meta.ownership.meta.test_id.?);
    source_button.behavior.events.on_click.?.invoke();
    notesFrames(cx);
    try std.testing.expectEqualDeep(source, citation.clicked.?);
    try std.testing.expectEqualStrings(draft, (try documents.snapshot(lease)).body_md);
    try std.testing.expect((try documents.snapshot(lease)).dirty);
    const status = findNotesNode(cx.root.?, "notes.save.error").?;
    try std.testing.expectEqualStrings("内容已更新", status.getText().?.content);

    try documents.flush(lease);
    const changed = try query.resolveSource(a, source, null);
    try std.testing.expectEqual(.updated, changed.state);
    try std.testing.expect(changed.range == null);
    try std.testing.expect(notes_view.openNote(instance, private_note));
    notesFrames(cx);
    source_button.behavior.events.on_click.?.invoke();
    notesFrames(cx);
    try std.testing.expectEqualStrings("内容已更新", status.getText().?.content);
    const current_lease = (try documents.open(note, local_owner)).lease;
    const current_draft = try documents.snapshot(current_lease);
    try std.testing.expect(!current_draft.dirty);
    try std.testing.expectEqualStrings(draft, current_draft.body_md);
    _ = try store.changeNote(note, changed.revision.?, .delete);
    source_button.behavior.events.on_click.?.invoke();
    notesFrames(cx);
    try std.testing.expectEqualStrings("笔记已删除", status.getText().?.content);
    try std.testing.expect(findNotesNode(cx.root.?, "notes.recent.restore").?.isDisplayedInTree());
}

fn notesWireResult(allocator: std.mem.Allocator, request: []const u8, call_id: []const u8) !std.json.Value {
    const wire = try std.json.parseFromSliceLeaky(std.json.Value, allocator, request, .{});
    for (wire.object.get("messages").?.array.items) |message| {
        const id = message.object.get("tool_call_id") orelse continue;
        if (std.mem.eql(u8, id.string, call_id)) return std.json.parseFromSliceLeaky(std.json.Value, allocator, message.object.get("content").?.string, .{});
    }
    return error.MissingNotesResult;
}

fn notesWireContent(allocator: std.mem.Allocator, result: std.json.Value) !std.json.Value {
    try std.testing.expectEqualStrings("succeeded", result.object.get("status").?.string);
    const content = result.object.get("content").?.array.items;
    try std.testing.expectEqual(@as(usize, 1), content.len);
    return std.json.parseFromSliceLeaky(std.json.Value, allocator, content[0].object.get("text").?.string, .{});
}

fn notesFrames(cx: *@import("ui").Cx) void {
    for (0..6) |_| {
        cx.advanceFrameClock();
        cx.layout();
        _ = cx.render();
    }
}

fn findNotesNode(node: *@import("ui").Node, id: []const u8) ?*@import("ui").Node {
    if (node.meta.ownership.meta.test_id) |test_id| if (std.mem.eql(u8, test_id, id)) return node;
    for (node.children.items) |child| if (findNotesNode(child, id)) |match| return match;
    return null;
}

const ControlledHost = struct {
    count: usize = 0,
    script: ?*Script = null,
    mode: enum { success, real_exec, uncertain, remote_unknown, cleanup_unknown, throws, wait_approval, cancel_after_success, no_exit } = .success,
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
        if (self.mode == .cleanup_unknown) return loop_mod.Outcome.copy(allocator, &.{.{ .session_id = 101, .status = .unknown, .transport = .ssh, .stdout = "completed output", .exit = 0, .local_released = false, .error_code = "SshCleanupUnknown" }});
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
        var script: Script = .{ .rounds = &.{ .{ .calls = &.{ df, other } }, .{ .text = "已有工具结果待核实。" } } };
        defer script.deinit();
        var host: ControlledHost = .{ .mode = mode };
        var manager = managerFor(&host);
        defer manager.deinit();
        _ = try manager.run(script.interface(), makeRequest(null));
        try std.testing.expectEqual(@as(usize, 1), host.count);
        try std.testing.expectEqual(@as(usize, 2), script.index);
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

test "tool execution continues beyond former round and call limits" {
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    var calls: [80]provider.ToolCall = undefined;
    var rounds: [81]Round = undefined;
    for (&calls, 0..) |*call, index| {
        call.* = df;
        call.id = try std.fmt.allocPrint(arena.allocator(), "call-{d}", .{index});
        rounds[index] = .{ .calls = calls[index .. index + 1] };
    }
    rounds[80] = .{ .text = "all completed" };
    var script: Script = .{ .rounds = &rounds };
    defer script.deinit();
    var host: ControlledHost = .{};
    var manager = managerFor(&host);
    defer manager.deinit();
    manager.tool_limits.context_window = 200_000;
    _ = try manager.run(script.interface(), makeRequest(null));
    try std.testing.expectEqual(@as(usize, 80), host.count);
    try std.testing.expectEqual(@as(usize, 80), manager.tool_run.?.records.items.len);
    try std.testing.expectEqual(@as(u64, 81), manager.tool_run.?.round_index);
    try std.testing.expectEqualStrings("all completed", manager.round_text.items);
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

test "answer only retry requests text again when a provider emits a tool call" {
    var script: Script = .{ .rounds = &.{ .{ .calls = &.{df} }, .{ .text = "I will execute this again.", .calls = &.{df} }, .{ .text = "recovered text" } }, .transient_round = 1 };
    defer script.deinit();
    var host: ControlledHost = .{};
    var manager = managerFor(&host);
    defer manager.deinit();
    manager.retry_policy.max_attempts = 0;
    try std.testing.expectError(error.Transient, manager.run(script.interface(), makeRequest(null)));
    const stats = try manager.resumeAnswer(script.interface(), null);
    try std.testing.expectEqual(@as(u32, 2), stats.request_count);
    try std.testing.expectEqual(@as(usize, 1), host.count);
    try std.testing.expectEqualStrings("recovered text", manager.round_text.items);
    try std.testing.expectEqual(@as(usize, 1), manager.tool_run.?.records.items.len);
    for (script.requests.items[2..]) |wire| {
        const request = try std.json.parseFromSlice(std.json.Value, a, wire, .{});
        defer request.deinit();
        try std.testing.expect(request.value.object.get("tools") == null);
    }
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

test "retained output size does not prevent a later tool dispatch" {
    var host: ControlledHost = .{};
    var manager = managerFor(&host);
    defer manager.deinit();
    var script: Script = .{ .rounds = &.{ .{ .calls = &.{df} }, .{ .text = "completed" } } };
    defer script.deinit();
    _ = try manager.run(script.interface(), makeRequest(null));
    try std.testing.expectEqual(@as(usize, 1), host.count);
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

test "answer recovery explains unknown SSH effects without replaying or changing exact facts" {
    var other = df;
    other.id = "must-not-dispatch";
    var script: Script = .{ .rounds = &.{ .{ .calls = &.{ df, other } }, .{ .text = "已有部分输出，原操作结果仍待核实。" } } };
    defer script.deinit();
    var host: ControlledHost = .{ .mode = .remote_unknown };
    var manager = managerFor(&host);
    defer manager.deinit();
    const stats = try manager.run(script.interface(), makeRequest(null));
    try std.testing.expectEqual(@as(u32, 2), stats.request_count);
    const run = manager.tool_run.?;
    try std.testing.expect(run.uncertain);
    try std.testing.expectError(error.ToolOutcomeUnknown, run.nextRequest());
    try std.testing.expectEqual(@as(usize, 1), host.count);
    try std.testing.expectEqual(run, manager.tool_run.?);
    try std.testing.expect(run.uncertain);
    try std.testing.expectError(error.ToolOutcomeUnknown, run.nextRequest());
    try std.testing.expectEqual(@as(u64, 77), manager.turn_id);
    try std.testing.expectEqualStrings("frozen system", run.request.system);
    const request = try std.json.parseFromSlice(std.json.Value, a, script.requests.items[1], .{});
    defer request.deinit();
    try std.testing.expect(request.value.object.get("tools") == null);
    const wire = script.requests.items[1];
    try std.testing.expect(std.mem.indexOf(u8, wire, "[Answer-only recovery]") != null);
    try std.testing.expect(std.mem.indexOf(u8, wire, "Partial output is not proof of completion") != null);
    try std.testing.expect(std.mem.indexOf(u8, wire, "original partial stdout") != null);
    try std.testing.expect(std.mem.indexOf(u8, wire, "EarlierToolOutcomeUnknown") != null);
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

test "answer retry of unknown tools rejects new calls and preserves owner and budget gates" {
    var script: Script = .{ .rounds = &.{ .{ .calls = &.{df} }, .{ .calls = &.{df} }, .{ .calls = &.{df} } }, .transient_round = 1, .interrupted_error = error.ProviderFailure };
    defer script.deinit();
    var host: ControlledHost = .{ .mode = .throws };
    var manager = managerFor(&host);
    defer manager.deinit();
    try std.testing.expectError(error.ProviderFailure, manager.run(script.interface(), makeRequest(null)));
    const run = manager.tool_run.?;
    const body = try a.dupe(u8, run.records.items[0].result_body.?);
    defer a.free(body);
    manager.cooldown_deadline_ms = std.math.maxInt(u64);
    try std.testing.expectError(error.ProviderCoolingDown, manager.resumeAnswer(script.interface(), null));
    manager.cooldown_deadline_ms = 0;
    manager.scope.?.owner = .{ .session = 102 };
    try std.testing.expectError(error.ToolOwnerChanged, manager.resumeAnswer(script.interface(), null));
    manager.scope = scope;
    run.compaction_failure = error.ProviderFailure;
    try std.testing.expectError(error.ContextCompactionFailed, manager.resumeAnswer(script.interface(), null));
    run.compaction_failure = null;
    run.limits.context_window = 1;
    try std.testing.expectError(error.ContextFixedOverhead, manager.resumeAnswer(script.interface(), null));
    run.limits.context_window = 200_000;
    try run.verification_notes.appendSlice(run.arena.allocator(), "Verified original operation: local cleanup remains unknown.");
    _ = try manager.resumeAnswer(script.interface(), null);
    try std.testing.expect(std.mem.indexOf(u8, script.requests.items[2], "Verified original operation: local cleanup remains unknown.") != null);
    try std.testing.expect(std.mem.indexOf(u8, manager.round_text.items, "结果仍待核实") != null);
    try std.testing.expectEqual(@as(usize, 1), host.count);
    try std.testing.expectEqual(@as(usize, 3), script.index);
    try std.testing.expect(run.uncertain);
    try std.testing.expectEqualStrings(body, run.records.items[0].result_body.?);
    try std.testing.expectEqualStrings("frozen system", run.request.system);
}

test "answer recovery keeps known exit separate from unknown SSH cleanup" {
    var script: Script = .{ .rounds = &.{ .{ .calls = &.{df} }, .{ .text = "命令已返回退出码 0，但资源清理仍待确认。" } } };
    defer script.deinit();
    var host: ControlledHost = .{ .mode = .cleanup_unknown };
    var manager = managerFor(&host);
    defer manager.deinit();
    _ = try manager.run(script.interface(), makeRequest(null));
    const run = manager.tool_run.?;
    const target = run.records.items[0].outcome.?.targets[0];
    try std.testing.expectEqual(@as(usize, 1), host.count);
    try std.testing.expect(run.uncertain);
    try std.testing.expectEqual(@as(?i32, 0), target.exit);
    try std.testing.expectEqual(loop_mod.Status.unknown, target.status);
    try std.testing.expect(!target.local_released and !target.remote_effect_unknown);
    try std.testing.expectEqualStrings("completed output", target.stdout);
    try std.testing.expect(std.mem.indexOf(u8, script.requests.items[1], "SshCleanupUnknown") != null);
    try std.testing.expectError(error.ToolOutcomeUnknown, run.nextRequest());
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

test "answer retry after timeout or interrupted text sends a fresh request with the original context" {
    for ([_]anyerror{ error.Timeout, error.ProviderMissingDone }) |failure| {
        var script: Script = .{ .rounds = &.{.{ .text = "continued answer" }}, .transient_round = 0, .interrupted_error = failure };
        defer script.deinit();
        var manager = manager_mod.Manager.init(a);
        defer manager.deinit();
        manager.scope = scope;
        manager.turn_id = 85;
        manager.retry_policy.max_attempts = 0;
        var original_stop: provider.CancelToken = .{};
        const request: provider.ChatRequest = .{ .model = "test", .system = "original system", .messages = &.{ .{ .content = "previous question" }, .{ .role = .assistant, .content = "previous answer" }, .{ .content = "current question" } }, .cancel = &original_stop };
        try std.testing.expectError(failure, manager.run(script.interface(), request));
        const captured = manager.tool_run.?;
        original_stop.cancel();
        var next_stop: provider.CancelToken = .{};
        _ = try manager.resumeAnswer(script.interface(), &next_stop);
        try std.testing.expectEqual(captured, manager.tool_run.?);
        try std.testing.expectEqual(@as(usize, 2), script.requests.items.len);
        try std.testing.expect(!next_stop.isCancelled());
        const body = try std.json.parseFromSlice(std.json.Value, a, script.requests.items[1], .{});
        defer body.deinit();
        const messages = body.value.object.get("messages").?.array.items;
        try std.testing.expect(std.mem.startsWith(u8, messages[0].object.get("content").?.string, "original system\n\n[Answer-only recovery]"));
        try std.testing.expectEqualStrings("previous question", messages[1].object.get("content").?.string);
        try std.testing.expectEqualStrings("previous answer", messages[2].object.get("content").?.string);
        try std.testing.expectEqualStrings("current question", messages[3].object.get("content").?.string);
        try std.testing.expect(body.value.object.get("tools") == null);
        try std.testing.expectEqualStrings("failed-attempt-prefix", manager.cards.cards.items[0].text);
        try std.testing.expectEqualStrings("continued answer", manager.cards.cards.items[1].text);
    }
}

test "answer retry after a completed tool and provider timeout retains paired results without replay" {
    var script: Script = .{ .rounds = &.{ .{ .calls = &.{df} }, .{ .text = "continued from tool result" } }, .transient_round = 1, .interrupted_error = error.Timeout };
    defer script.deinit();
    var host: ControlledHost = .{};
    var manager = managerFor(&host);
    defer manager.deinit();
    manager.retry_policy.max_attempts = 0;
    var original_stop: provider.CancelToken = .{};
    try std.testing.expectError(error.Timeout, manager.run(script.interface(), makeRequest(&original_stop)));
    const captured = manager.tool_run.?;
    try std.testing.expectEqual(@as(usize, 1), host.count);
    original_stop.cancel();
    var next_stop: provider.CancelToken = .{};
    _ = try manager.resumeAnswer(script.interface(), &next_stop);
    try std.testing.expectEqual(captured, manager.tool_run.?);
    try std.testing.expectEqual(@as(usize, 1), host.count);
    try std.testing.expectEqual(@as(usize, 3), script.requests.items.len);
    const body = try std.json.parseFromSlice(std.json.Value, a, script.requests.items[2], .{});
    defer body.deinit();
    const messages = body.value.object.get("messages").?.array.items;
    const calls = messages[2].object.get("tool_calls").?.array.items;
    try std.testing.expectEqualStrings(df.id, calls[0].object.get("id").?.string);
    try std.testing.expectEqualStrings(df.id, messages[3].object.get("tool_call_id").?.string);
    var result = try resultFromBody(script.requests.items[2], 3);
    defer result.deinit();
    try std.testing.expectEqualStrings("actual-controlled-output", result.value.object.get("targets").?.array.items[0].object.get("stdout").?.string);
    try std.testing.expect(body.value.object.get("tools") == null);
    try std.testing.expect(!next_stop.isCancelled());
}

test "interrupted follow-up stream retries the model round with the original tool receipt" {
    for ([_]anyerror{ error.Timeout, error.ProviderMissingDone }) |failure| {
        var script: Script = .{ .rounds = &.{ .{ .calls = &.{df} }, .{ .text = "continued from the original result" } }, .transient_round = 1, .interrupted_error = failure };
        defer script.deinit();
        var host: ControlledHost = .{};
        var manager = managerFor(&host);
        defer manager.deinit();
        const stats = try manager.run(script.interface(), makeRequest(null));
        try std.testing.expectEqual(@as(u32, 3), stats.request_count);
        try std.testing.expectEqual(@as(usize, 1), host.count);
        try std.testing.expectEqualStrings(script.requests.items[1], script.requests.items[2]);
        try std.testing.expectEqualStrings("continued from the original result", manager.round_text.items);
    }
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
    manager.tool_limits.context_window = 0;
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
    const observation = try run.nextRequest();
    try std.testing.expect(run.host_observation_only);
    for (observation.tools) |definition| {
        const entry = run.tool_table.?.lookup(definition.name()).?;
        try std.testing.expect(entry.definition.effect == .read_state or std.mem.eql(u8, entry.definition.id, "host.stop_execution"));
        try std.testing.expect(!std.mem.eql(u8, entry.definition.id, "host.attach_shell"));
    }
    try run.complete("读取原执行核验结果，不重发命令。", &.{.{ .id = "observe-next-round", .name = wire[1].name(), .arguments = "{\"execution_ref\":\"x1:opaque\"}" }}, .{ .context = &gateway, .execute = Gateway.legacy, .execute_host = Gateway.invoke }, .{}, 1, null);
    try std.testing.expectEqual(@as(usize, 1), gateway.writes);
    try std.testing.expectEqual(@as(usize, 4), gateway.calls);
    try http.validateToolMessages(.{ .model = "test", .system = "", .messages = run.messages.items });
}

test "batch SSH unknown receipt allows read-only follow-up without redispatch" {
    const tools = @import("plugin_tools.zig");
    const legacy = @import("legacy_adapter.zig");
    const Gateway = struct {
        commands: usize = 0,
        reads: usize = 0,
        fn legacyDispatch(_: *anyopaque, _: loop_mod.Invocation, _: std.mem.Allocator, _: ?*provider.CancelToken) !loop_mod.Outcome {
            return error.UnexpectedLegacyDispatch;
        }
        fn handler(_: *anyopaque, _: tools.Invocation, _: std.mem.Allocator) !tools.ToolResult {
            return error.UnexpectedDirectDispatch;
        }
        fn execute(raw: *anyopaque, call: tools.DynamicInvocation, allocator: std.mem.Allocator, _: ?*provider.CancelToken) ![]tools.ToolResult {
            const self: *@This() = @ptrCast(@alignCast(raw));
            const command = std.mem.eql(u8, call.parsed.entry.definition.id, "run_command");
            if (command) self.commands += 1 else self.reads += 1;
            const results = try allocator.alloc(tools.ToolResult, 1);
            results[0] = .{ .status = if (command) .outcome_unknown else .succeeded, .receipt = .{ .owner = call.parsed.entry.targets[0].owner, .operation_id = call.operation_id, .local_released = !command, .remote_effect_unknown = command } };
            return results;
        }
    };
    var gateway: Gateway = .{};
    const bindings = [_]tools.ToolBinding{
        .{ .plugin_id = "ssh", .definition_id = "run_command", .handler = Gateway.handler },
        .{ .plugin_id = "ssh", .definition_id = "read_remote_file", .handler = Gateway.handler },
    };
    const members = [_]tools.Member{.{ .owner = .{ .session_id = @fromBackingInt(101), .generation = 1 }, .plugin_id = "ssh", .context = &gateway, .bindings = &bindings }};
    var table = try tools.RequestTable.init(a, scope, &legacy.builtin_definitions, &members);
    defer table.deinit();
    const wire = try tools.providerDefinitions(&table, table.arena.allocator());
    const read_name = for (wire) |tool| {
        if (std.mem.eql(u8, tool.name(), "read_remote_file")) break tool.name();
    } else return error.MissingReadTool;
    const run_name = for (wire) |tool| {
        if (std.mem.eql(u8, tool.name(), "run_command")) break tool.name();
    } else return error.MissingRunTool;
    const initial: provider.ToolCall = .{ .id = "initial-batch", .name = run_name, .arguments = "{\"session_ids\":[101],\"command\":\"sleep 75\"}" };
    var replay = initial;
    replay.id = "new-call-id";
    const read: provider.ToolCall = .{ .id = "read-after-timeout", .name = read_name, .arguments = "{\"session_ids\":[101],\"path\":\"/tmp/observed.log\"}" };
    var script: Script = .{ .rounds = &.{ .{ .calls = &.{initial} }, .{ .calls = &.{ replay, read } }, .{ .text = "读取成功，原命令结果仍待核实。" } } };
    defer script.deinit();
    var manager = manager_mod.Manager.init(a);
    defer manager.deinit();
    manager.scope = scope;
    manager.tool_host = .{ .context = &gateway, .execute = Gateway.legacyDispatch, .execute_dynamic = Gateway.execute };
    manager.tool_limits.context_window = 100_000;
    _ = try manager.run(script.interface(), .{ .model = "test", .system = "", .messages = &.{.{ .content = "check the existing log" }}, .tools = wire, .tool_table = &table });
    try std.testing.expectEqual(@as(usize, 1), gateway.commands);
    try std.testing.expectEqual(@as(usize, 1), gateway.reads);
    const run = manager.tool_run.?;
    try std.testing.expect(run.uncertain and run.host_observation_only);
    try std.testing.expect(!run.records.items[1].dispatched and run.records.items[2].dispatched);
    const request = try std.json.parseFromSlice(std.json.Value, a, script.requests.items[1], .{});
    defer request.deinit();
    const visible = request.value.object.get("tools").?.array.items;
    try std.testing.expectEqual(@as(usize, 1), visible.len);
    try std.testing.expectEqualStrings(read_name, visible[0].object.get("function").?.object.get("name").?.string);
}

test "group terminal continuation stops when a second dispatch has no receipt" {
    const tools = @import("plugin_tools.zig");
    const identity = @import("../host/identity.zig");
    const group: scope_mod.Scope = .{ .owner = .{ .group = 1 }, .members = .{ .ids = .{ 101, 102, 103 } ++ @as([13]u64, @splat(0)), .len = 3 } };
    const context: tools.host.Context = .{ .conversation_id = .generate(), .task_id = .generate(), .binding = group.owner, .binding_revision = 1, .grant_revision = 1 };
    const lost: identity.SessionHandle = .{ .session_id = @fromBackingInt(101), .generation = 1 };
    var table = try tools.RequestTable.initWithHost(a, group, &.{}, &.{}, context, &.{@import("host_execution.zig").contributions[0]});
    defer table.deinit();
    const wire = try tools.providerDefinitions(&table, table.arena.allocator());
    const Gateway = struct {
        calls: usize = 0,
        fn legacy(_: *anyopaque, _: loop_mod.Invocation, _: std.mem.Allocator, _: ?*provider.CancelToken) !loop_mod.Outcome {
            return error.UnexpectedLegacyDispatch;
        }
        fn invoke(raw: *anyopaque, invocation: tools.host.Invocation, _: std.mem.Allocator, _: ?*provider.CancelToken) !tools.host.Result {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.calls += 1;
            if (std.mem.eql(u8, invocation.call_id, "missing-receipt")) return error.FixtureTransportFailed;
            return .{ .status = .outcome_unknown, .uncertain_terminal = lost, .receipt = .{
                .conversation_id = invocation.context.conversation_id,
                .task_id = invocation.context.task_id,
                .operation_id = invocation.operation_id,
                .binding_revision = invocation.context.binding_revision,
                .side_effect_started = true,
                .remote_effect_unknown = true,
            } };
        }
    };
    var gateway: Gateway = .{};
    const host: loop_mod.Host = .{ .context = &gateway, .execute = Gateway.legacy, .execute_host = Gateway.invoke };
    var run = loop_mod.Loop.init(a, group, 17, .{ .context_window = 100_000 });
    defer run.deinit();
    try run.start(.{ .model = "test", .system = "", .messages = &.{}, .tools = wire, .tool_table = &table });
    var calls: [4]provider.ToolCall = undefined;
    for (&calls, [_]u64{ 101, 101, 102, 103 }, [_][]const u8{ "lost", "same-target", "missing-receipt", "other-target" }) |*call, id, key| {
        const ref = try @import("host_queries.zig").sessionRef(table.arena.allocator(), context, .{ .session_id = @fromBackingInt(id), .generation = 1 });
        const arguments = try std.json.Stringify.valueAlloc(table.arena.allocator(), .{ .session_ref = ref, .command = "printf ok", .request_key = key }, .{});
        call.* = .{ .id = key, .name = wire[0].name(), .arguments = arguments };
    }
    try run.complete("", calls[0..1], host, .{}, 1, null);
    try std.testing.expectEqual(@as(usize, 1), (try run.nextRequest()).tools.len);
    try run.complete("", calls[1..], host, .{}, 1, null);
    try std.testing.expectEqual(@as(usize, 2), gateway.calls);
    try std.testing.expect(!run.records.items[1].dispatched and run.records.items[2].dispatched and !run.records.items[3].dispatched);
    try std.testing.expectError(error.ToolOutcomeUnknown, run.nextRequest());
}

test "plugin dispatch remains available after a large completed operation history" {
    const tools = @import("plugin_tools.zig");
    const operations = @import("../host/operation_store.zig");
    const identity = @import("../host/identity.zig");
    var history = operations.Store.init(a);
    defer history.deinit();
    const owner: identity.SessionHandle = .{ .session_id = @fromBackingInt(101), .generation = 3 };
    for (0..256) |index| {
        const id = index + 10000;
        _ = try history.beginNew(owner, id, "fixture.completed", @splat(0), 1);
        try history.markSent(owner, id);
        try history.finish(owner, id, true, "observed");
        try history.resourcesReleased(owner, id);
    }
    const Fixture = struct {
        history: *operations.Store,
        members: []const tools.Member = &.{},
        gateway_calls: usize = 0,
        approvals: usize = 0,
        effects: usize = 0,
        fn legacy(_: *anyopaque, _: loop_mod.Invocation, _: std.mem.Allocator, _: ?*provider.CancelToken) !loop_mod.Outcome {
            return error.UnexpectedLegacyDispatch;
        }
        fn handler(raw: *anyopaque, invocation: tools.Invocation, _: std.mem.Allocator) !tools.ToolResult {
            @as(*@This(), @ptrCast(@alignCast(raw))).effects += 1;
            return .{ .status = .succeeded, .receipt = .{ .owner = invocation.owner, .operation_id = invocation.operation_id } };
        }
        fn liveScope(_: *anyopaque) !scope_mod.Scope {
            return scope;
        }
        fn liveMembers(raw: *anyopaque) ![]const tools.Member {
            return @as(*@This(), @ptrCast(@alignCast(raw))).members;
        }
        fn policy(_: *anyopaque) tools.Policy {
            return .{};
        }
        fn now(_: *anyopaque) i64 {
            return 100;
        }
        fn approval(raw: *anyopaque, _: tools.DynamicInvocation, _: *tools.ApprovalTicket, _: ?*provider.CancelToken) !bool {
            @as(*@This(), @ptrCast(@alignCast(raw))).approvals += 1;
            return true;
        }
        fn invoke(raw: *anyopaque, call: tools.DynamicInvocation, allocator: std.mem.Allocator, cancel: ?*provider.CancelToken) ![]tools.ToolResult {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.gateway_calls += 1;
            const runtime: tools.Runtime = .{ .context = self, .live_scope = liveScope, .live_members = liveMembers, .current_policy = policy, .now_ms = now, .approval = approval, .operations = self.history };
            return runtime.execute(call, allocator, cancel);
        }
    };
    var fixture: Fixture = .{ .history = &history };
    const schema = "{\"type\":\"object\",\"additionalProperties\":false,\"properties\":{\"session_ids\":{\"type\":\"array\",\"minItems\":1,\"maxItems\":16,\"uniqueItems\":true,\"items\":{\"type\":\"integer\",\"minimum\":1}}},\"required\":[\"session_ids\"]}";
    const definition: tools.ToolDefinition = .{ .id = "fixture.capacity_write", .schema = schema, .effect = .resource_write, .approval_policy = .always_confirm };
    const members = [_]tools.Member{.{ .owner = owner, .plugin_id = "fixture", .context = &fixture, .bindings = &.{.{ .plugin_id = "fixture", .definition_id = definition.id, .handler = Fixture.handler }} }};
    fixture.members = &members;
    var table = try tools.RequestTable.init(a, scope, &.{definition}, &members);
    defer table.deinit();
    const wire = try tools.providerDefinitions(&table, table.arena.allocator());
    var run = loop_mod.Loop.init(a, scope, 19, .{ .context_window = 100_000 });
    defer run.deinit();
    try run.start(.{ .model = "test", .system = "", .messages = &.{}, .tools = wire, .tool_table = &table });
    try run.complete("", &.{
        .{ .id = "capacity-first", .name = wire[0].name(), .arguments = "{\"session_ids\":[101]}" },
        .{ .id = "capacity-second", .name = wire[0].name(), .arguments = "{\"session_ids\":[101]}" },
    }, .{ .context = &fixture, .execute = Fixture.legacy, .execute_dynamic = Fixture.invoke }, .{}, 1, null);
    try std.testing.expectEqual(@as(usize, 2), fixture.gateway_calls);
    try std.testing.expectEqual(@as(usize, 2), fixture.approvals);
    try std.testing.expectEqual(@as(usize, 2), fixture.effects);
    try std.testing.expect(!run.uncertain);
    try std.testing.expectEqual(@as(usize, 258), history.count());
    for (run.records.items) |record| {
        try std.testing.expect(record.dispatched);
        const body = try std.json.parseFromSlice(std.json.Value, a, record.result_body.?, .{});
        defer body.deinit();
        try std.testing.expect(record.generic_results != null);
    }
    try http.validateToolMessages(.{ .model = "test", .system = "", .messages = run.messages.items });
}

test "execution deadline known unsent timeout never becomes an unknown side effect" {
    const tools = @import("plugin_tools.zig");
    const identity = @import("../host/identity.zig");
    const context: tools.host.Context = .{ .conversation_id = identity.ConversationId.generate(), .task_id = identity.TaskId.generate(), .binding = scope.owner, .binding_revision = 1, .grant_revision = 1 };
    var table = try tools.RequestTable.initWithHost(a, scope, &.{}, &.{}, context, &.{.{ .authority = .execution_control, .definition = .{ .id = "host.run_in_terminal", .effect = .resource_write, .schema = "{\"type\":\"object\"}" } }});
    defer table.deinit();
    const Fixture = struct {
        fn legacy(_: *anyopaque, _: loop_mod.Invocation, _: std.mem.Allocator, _: ?*provider.CancelToken) !loop_mod.Outcome {
            return error.UnexpectedDispatch;
        }
        fn invoke(_: *anyopaque, _: tools.host.Invocation, _: std.mem.Allocator, _: ?*provider.CancelToken) !tools.host.Result {
            return error.ExecutionDeadlineBeforeDispatch;
        }
    };
    const wire = try tools.providerDefinitions(&table, table.arena.allocator());
    var run = loop_mod.Loop.init(a, scope, 1, .{});
    defer run.deinit();
    try run.start(.{ .model = "fixture", .system = "", .messages = &.{}, .tools = wire, .tool_table = &table });
    try run.complete("", &.{.{ .id = "expired", .name = wire[0].name(), .arguments = "{}" }}, .{ .context = undefined, .execute = Fixture.legacy, .execute_host = Fixture.invoke }, .{}, 1, null);
    try std.testing.expect(!run.uncertain and !run.records.items[0].dispatched);
    var body = try std.json.parseFromSlice(std.json.Value, a, run.records.items[0].result_body.?, .{});
    defer body.deinit();
    try std.testing.expectEqualStrings("ExecutionDeadlineBeforeDispatch", body.value.object.get("error_code").?.string);
    try std.testing.expect(!body.value.object.get("side_effect_started").?.bool);
    try std.testing.expect(!body.value.object.get("remote_effect_unknown").?.bool);
    try http.validateToolMessages(run.request);
}

test "live permission manager rechecks calls in one batch and following rounds" {
    const permission = @import("permission.zig");
    const Fixture = struct {
        manager: *manager_mod.Manager,
        verdicts: [3]permission.Verdict = undefined,
        count: usize = 0,
        fn execute(raw: *anyopaque, call: loop_mod.Invocation, allocator: std.mem.Allocator, _: ?*provider.CancelToken) !loop_mod.Outcome {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.verdicts[self.count] = call.verdict;
            self.count += 1;
            self.manager.setPermissionMode(if (self.count == 1) .auto else .confirm);
            return loop_mod.Outcome.copy(allocator, &.{.{ .session_id = 101, .status = .succeeded, .exit = 0 }});
        }
    };
    var manager = manager_mod.Manager.init(a);
    defer manager.deinit();
    manager.permission_engine = .{ .mode = .confirm, .whitelist = &.{"touch"} };
    manager.scope = scope;
    manager.tool_limits.context_window = 200_000;
    var fixture: Fixture = .{ .manager = &manager };
    manager.tool_host = .{ .context = &fixture, .execute = Fixture.execute };
    const second: provider.ToolCall = .{ .id = "live-second", .name = "run_command", .arguments = "{\"session_ids\":[101],\"command\":\"touch /tmp/fixture\"}" };
    var third = second;
    third.id = "live-third";
    var script: Script = .{ .rounds = &.{ .{ .calls = &.{ df, second } }, .{ .calls = &.{third} }, .{ .text = "done" } } };
    defer script.deinit();
    _ = try manager.run(script.interface(), .{ .model = "test", .system = "", .messages = &.{.{ .content = "permission test" }}, .tools = &definitions });
    try std.testing.expectEqual(@as(usize, 3), fixture.count);
    try std.testing.expectEqualSlices(permission.Verdict, &.{ .allow_auto, .allow_auto, .need_confirm }, &fixture.verdicts);
}

test "AI context budget tool overhead does not attempt first-turn compaction" {
    var run = loop_mod.Loop.init(a, scope, 77, .{ .context_window = 256 });
    defer run.deinit();
    run.compaction_config = .{ .kind = .openai_compat, .endpoint = "http://127.0.0.1:1/v1", .model = "fixture", .auth = .none, .context_window = 256 };
    try std.testing.expectError(error.ContextFixedOverhead, run.start(.{ .model = "fixture", .system = "rules", .messages = &.{.{ .content = "look at terminal" }}, .tools = &definitions }));
    try std.testing.expect(run.compaction_failure == null);
    try std.testing.expectEqual(@as(usize, 0), run.round_index);
    try std.testing.expectEqualStrings("look at terminal", run.messages.items[0].content);
    try std.testing.expectError(error.ContextFixedOverhead, run.nextRequest());
}

test "one model response dispatches more than sixteen tool calls" {
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    var calls: [20]provider.ToolCall = undefined;
    for (&calls, 0..) |*call, index| {
        call.* = df;
        call.id = try std.fmt.allocPrint(arena.allocator(), "batch-{d}", .{index});
    }
    var script: Script = .{ .rounds = &.{ .{ .calls = &calls }, .{ .text = "batch completed" } } };
    defer script.deinit();
    var host: ControlledHost = .{};
    var manager = managerFor(&host);
    defer manager.deinit();
    _ = try manager.run(script.interface(), makeRequest(null));
    try std.testing.expectEqual(@as(usize, 20), host.count);
    try std.testing.expectEqual(@as(usize, 20), manager.tool_run.?.records.items.len);
    try http.validateToolMessages(manager.tool_run.?.request);
}
