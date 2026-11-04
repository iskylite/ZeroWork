//! Production BMC definitions through the real generic schema/approval gateway,
//! real content leases, immutable CPU frames and the real RFB sender.
const std = @import("std");
const T = std.testing;
const a = T.allocator;
const api = @import("ai/plugin_tools.zig");
const scope = @import("ai/tool_scope.zig");
const provider = @import("ai/provider.zig");
const tools = @import("plugins/bmc_ikvm/tools.zig");
const console = @import("plugins/bmc_ikvm/console_service.zig");
const control = @import("plugins/bmc_ikvm/ai_control.zig");
const remote = @import("plugins/bmc_ikvm/remote_input.zig");
const framebuffer = @import("plugins/bmc_ikvm/framebuffer.zig");
const content = @import("host/content_context.zig");
const budgets = @import("host/frame_budget.zig");
const operations = @import("host/operation_store.zig");
const typed = @import("host/plugin_services.zig");
const identity = @import("host/identity.zig");
const owner: identity.SessionHandle = .{ .session_id = @fromBackingInt(83), .generation = 7 };
const captured: scope.Scope = .{ .owner = .{ .session = 83 }, .members = .{ .ids = .{83} ++ @as([15]u64, @splat(0)), .len = 1 } };
const tool_bindings = tools.bindings(Harness.handle);

const Harness = struct {
    budget: budgets.Budget = budgets.Budget.init(1024 * 1024),
    frame: framebuffer.Service = undefined,
    input: remote.Service = undefined,
    control: control.Service = undefined,
    context: content.Context = undefined,
    grant: ?content.AutomationGrant = null,
    bindings: [1]typed.Binding = undefined,
    member: [1]api.Member = undefined,
    table: api.RequestTable = undefined,
    history: operations.Store = undefined,
    policy: api.Policy = .{},
    allow_approval: bool = true,
    mutate_policy_on_approval: bool = false,
    approvals: usize = 0,
    dispatches: usize = 0,
    cancelled: std.atomic.Value(bool) = .init(false),
    stopped: std.atomic.Value(bool) = .init(false),
    wire_bytes: [4096]u8 = undefined,
    wire_length: usize = 0,
    partial_wire: bool = false,
    aborted: bool = false,

    fn init(self: *Harness) !void {
        self.frame = framebuffer.Service.init(a, owner, &self.budget);
        self.input = remote.Service.init(owner);
        try self.input.setConnected(true, 1);
        try self.input.setControl(true, 1);
        self.control = control.Service.init(owner, &self.frame, &self.input);
        _ = try self.frame.publishComplete(2, 2, &.{ 1, 2, 3, 255, 4, 5, 6, 255, 7, 8, 9, 255, 10, 11, 12, 255 }, nowMs(self) * std.time.ns_per_ms);
        self.context = .{ .owner = owner, .window_id = @fromBackingInt(1), .window = .{ .context = self, .request_fullscreen = fullscreen, .fullscreen_state = fullState, .transfer = transfer }, .consumer = .{ .context = &self.input, .consume = consume } };
        self.context.setFocus(true, false);
        self.bindings = .{self.control.binding()};
        self.member = .{.{ .owner = owner, .plugin_id = "bmc_ikvm", .context = self, .bindings = tool_bindings[3..], .services = &self.bindings, .policy_revision = 9 }};
        self.table = try api.RequestTable.init(a, captured, &tools.definitions, &self.member);
        self.history = operations.Store.init(a);
    }
    fn deinit(self: *Harness) void {
        self.context.close();
        self.control.close();
        while (!self.control.drainEncoding()) {
            const delay: std.c.timespec = .{ .sec = 0, .nsec = std.time.ns_per_ms };
            _ = std.c.nanosleep(&delay, null);
        }
        self.input.close();
        self.table.deinit();
        self.history.deinit();
        self.frame.deinit() catch unreachable;
        self.budget.deinit() catch unreachable;
    }
    fn fullscreen(_: *anyopaque, _: bool) !void {}
    fn fullState(_: *anyopaque) bool {
        return false;
    }
    fn transfer(_: *anyopaque, _: identity.SessionHandle, _: identity.WindowId) !void {}
    fn consume(raw: *anyopaque, event: content.Input) !void {
        if (event != .release_all) return error.TypedInputRequired;
        const input: *remote.Service = @ptrCast(@alignCast(raw));
        _ = input.releaseAll(input.binding(), .released);
    }
    fn from(raw: *anyopaque) *Harness {
        return @ptrCast(@alignCast(raw));
    }
    fn nowMs(_: *anyopaque) u64 {
        return @intCast(@divTrunc(@import("platform/realtime.zig").monotonicNs(), std.time.ns_per_ms));
    }
    fn now(raw: *anyopaque) i64 {
        return @intCast(nowMs(raw));
    }
    fn liveScope(_: *anyopaque) !scope.Scope {
        return captured;
    }
    fn liveMembers(raw: *anyopaque) ![]const api.Member {
        return &from(raw).member;
    }
    fn currentPolicy(raw: *anyopaque) api.Policy {
        return from(raw).policy;
    }
    fn approve(raw: *anyopaque, invocation: api.DynamicInvocation, ticket: *api.ApprovalTicket, _: ?*provider.CancelToken) !bool {
        const self = from(raw);
        self.approvals += 1;
        try T.expectEqualSlices(u8, &invocation.parsed.arguments_hash, &ticket.arguments_hash);
        try T.expect(ticket.targets[0].owner.eql(owner));
        if (self.mutate_policy_on_approval) self.member[0].policy_revision += 1;
        return self.allow_approval;
    }
    fn handle(raw: *anyopaque, invocation: api.Invocation, allocator: std.mem.Allocator) !api.ToolResult {
        const self = from(raw);
        self.dispatches += 1;
        return tools.invoke(.{ .owner = owner, .console = undefined, .power = undefined, .boot = undefined, .ai = self.control.binding() }, invocation, allocator);
    }
    fn invoke(raw: *anyopaque, target: api.TargetBinding, original: api.Invocation, allocator: std.mem.Allocator, _: ?*provider.CancelToken) !api.ToolResult {
        const self = from(raw);
        var invocation = original;
        if (invocation.effect == .remote_input) {
            if (self.context.human != null) return error.HumanInputActive;
            if (self.grant == null) {
                try self.context.setAuthorization(true, self.member[0].policy_revision);
                self.grant = try self.context.acquireAutomation(self.member[0].policy_revision, &self.cancelled, &self.stopped, nowMs(self) + 600_000);
            }
            invocation.automation_proof = self.grant.?.proof;
        }
        try api.markSent(&self.history, invocation.owner, invocation.operation_id, invocation.call_id, invocation.tool_id, invocation.arguments_hash);
        const result = try target.binding.handler(target.context, invocation, allocator);
        if (result.status == .outcome_unknown or result.receipt.remote_effect_unknown) if (self.grant) |grant| {
            grant.release();
            self.grant = null;
        };
        return result;
    }
    fn runtime(self: *Harness) api.Runtime {
        return .{ .context = self, .live_scope = liveScope, .live_members = liveMembers, .current_policy = currentPolicy, .now_ms = now, .approval = approve, .operations = &self.history, .invoke = invoke };
    }
    fn execute(self: *Harness, id: []const u8, arguments: []const u8, operation: u64) ![]api.ToolResult {
        var name: [64]u8 = undefined;
        var parsed = try self.table.parse(a, try api.encodeName(&name, id), arguments);
        defer parsed.deinit();
        return self.runtime().execute(.{ .table = &self.table, .parsed = parsed, .turn_id = 1, .call_id = "gateway-fixture", .arguments = arguments, .operation_id = operation }, a, null);
    }
    fn observe(self: *Harness, operation: u64) !u64 {
        const result = try self.execute("bmc_ikvm.screenshot", "{\"session_ids\":[83]}", operation);
        defer release(result);
        try T.expectEqual(api.Status.succeeded, result[0].status);
        try T.expectEqual(@as(usize, 2), result[0].blocks.len);
        try T.expect(result[0].blocks[1] == .image_ref);
        try T.expectEqual(@as(u32, 2), result[0].blocks[1].image_ref.content().?.width);
        const metadata = try std.json.parseFromSlice(std.json.Value, a, result[0].blocks[0].structured, .{});
        defer metadata.deinit();
        try T.expect(!metadata.value.object.contains("path"));
        return @intCast(metadata.value.object.get("observation_id").?.integer);
    }
    fn move(self: *Harness, observation: u64, operation: u64) ![]api.ToolResult {
        const args = try std.fmt.allocPrint(a, "{{\"session_ids\":[83],\"observation_id\":{d},\"action\":\"move\",\"x\":1,\"y\":0}}", .{observation});
        defer a.free(args);
        return self.execute("bmc_ikvm.pointer", args, operation);
    }
    fn write(raw: *anyopaque, bytes: []const u8) !usize {
        const self = from(raw);
        if (self.partial_wire and self.wire_length != 0) return error.WouldBlock;
        const count = if (self.partial_wire) 1 else bytes.len;
        if (self.wire_length + count > self.wire_bytes.len) return error.FixtureFull;
        @memcpy(self.wire_bytes[self.wire_length..][0..count], bytes[0..count]);
        self.wire_length += count;
        return count;
    }
    fn abort(raw: *anyopaque) void {
        from(raw).aborted = true;
    }
    fn pump(self: *Harness) !void {
        _ = try self.input.pump(.{ .context = self, .generation = 1, .write = write, .abort = abort });
    }
};
fn release(results: []api.ToolResult) void {
    for (results) |*result| result.deinit(a);
    a.free(results);
}
fn expectState(result: api.ToolResult, expected: []const u8) !void {
    const parsed = try std.json.parseFromSlice(std.json.Value, a, result.blocks[0].structured, .{});
    defer parsed.deinit();
    try T.expectEqualStrings(expected, parsed.value.object.get("state").?.string);
    try T.expect(!parsed.value.object.get("remote_effect_verified").?.bool);
    try T.expect(!parsed.value.object.get("automatic_replay_allowed").?.bool);
}
fn expectRejection(result: api.ToolResult, code: []const u8) !void {
    const parsed = try std.json.parseFromSlice(std.json.Value, a, result.blocks[0].structured, .{});
    defer parsed.deinit();
    try T.expectEqualStrings(code, parsed.value.object.get("error_code").?.string);
    try T.expect(!parsed.value.object.get("dispatch").?.bool);
    try T.expect(!parsed.value.object.get("image_generated").?.bool);
}

test "BMC AI gateway preserves read IDs and has eight schema effect matched tools without management writes" {
    try T.expectEqual(@as(usize, 8), tools.definitions.len);
    try T.expectEqualStrings("bmc_ikvm.read_power_state", tools.definitions[0].id);
    try T.expectEqualStrings("bmc_ikvm.read_boot", tools.definitions[1].id);
    try T.expectEqualStrings("bmc_ikvm.describe_frame", tools.definitions[2].id);
    for (tools.definitions) |definition| {
        try api.validateDefinition(definition);
        try T.expect(definition.effect != .resource_write);
    }
    try T.expectEqual(api.Effect.observe_image, tools.definitions[3].effect);
    try T.expectEqual(api.ApprovalPolicy.always_confirm, tools.definitions[3].approval_policy);
    try T.expectEqual(api.Effect.remote_input, tools.definitions[4].effect);
    try T.expectEqual(api.Effect.remote_input, tools.definitions[5].effect);
    try T.expectEqual(api.Effect.read_state, tools.definitions[6].effect);
    try T.expect(try api.needsApproval(tools.definitions[3], .{}));
    try T.expect(!(try api.needsApproval(tools.definitions[3], .{ .full_control = true })));
    try T.expect(!(try api.needsApproval(tools.definitions[3], .{ .engine = .{ .mode = .auto } })));
    try T.expectError(error.ToolExecutionDenied, api.needsApproval(tools.definitions[3], .{ .full_control = true, .allow_read = false }));
}

const SnapshotCopyFixture = struct {
    fn source(allocator: std.mem.Allocator) !*console.Snapshot {
        const value = try allocator.create(console.Snapshot);
        const text = try allocator.dupe(u8, &@as([1024]u8, @splat('c')));
        var path: [4096]u8 = @splat('p');
        const prefix = "/redfish/v1/Systems/";
        @memcpy(path[0..prefix.len], prefix);
        value.* = .{
            .owner = owner,
            .operation = .{ .owner = .{ .session = owner }, .operation_id = 1 },
            .name = text,
            .target = text,
            .route_summary = text,
            .failure_code = text,
            .input = .{ .input_epoch = 1, .control_generation = 1, .transport_generation = 1, .connected = true, .controlled = true, .focused = false, .capture_paused = true, .queued = 0, .remote_unconfirmed = false },
        };
        value.progress.failure_code = text;
        value.progress.event_count = console.progress.capacity;
        for (&value.progress.events, 0..) |*event, i| event.* = .{
            .sequence = i + 1,
            .stage = .redfish_discovery,
            .error_code = text,
            .context = .{
                .resource_path = console.progress.resourcePath(&path),
                .source_path = console.progress.resourcePath(&path),
                .source_property = console.progress.LogText(128).init("BootSourceOverrideTarget"),
                .response_errors = console.progress.ResponseErrors.init(text),
                .http_status = 404,
            },
        };
        value.progress.failure_event = value.progress.events[0];
        value.progress.discovery_issue = value.progress.events[console.progress.capacity - 1];
        return value;
    }
    fn expectText(text: []const u8) !void {
        try T.expectEqual(@as(usize, 1024), text.len);
        for (text) |byte| try T.expectEqual(@as(u8, 'c'), byte);
    }
    fn copy(allocator: std.mem.Allocator, value: *const console.Snapshot) !void {
        var snapshot = try console.OwnedSnapshot.init(allocator, value.*);
        defer snapshot.deinit();
        try expectText(snapshot.value.name);
        try expectText(snapshot.value.progress.events[console.progress.capacity - 1].error_code.?);
    }
};

test "BMC AI console snapshot full telemetry copies on a small stack and owns all borrowed strings" {
    var source_arena: std.heap.ArenaAllocator = .init(a);
    defer source_arena.deinit();
    const source = try SnapshotCopyFixture.source(source_arena.allocator());
    const Worker = struct {
        source: *const console.Snapshot,
        output: *console.OwnedSnapshot,
        failure: ?anyerror = null,
        fn run(self: *@This()) void {
            self.output.* = console.OwnedSnapshot.init(a, self.source.*) catch |err| {
                self.failure = err;
                return;
            };
        }
    };
    const snapshot = try a.create(console.OwnedSnapshot);
    defer a.destroy(snapshot);
    var worker: Worker = .{ .source = source, .output = snapshot };
    // The previous generic JSON parse needed a single frame larger than 6 MiB.
    // Keep the production copy usable on a smaller worker stack as well.
    const thread = try std.Thread.spawn(.{ .stack_size = 4 * 1024 * 1024 }, Worker.run, .{&worker});
    thread.join();
    if (worker.failure) |err| return err;
    defer snapshot.deinit();
    @memset(@constCast(source.name), 'x');
    source.progress = .{};
    source_arena.deinit();
    source_arena = .init(a);
    const value = &snapshot.value;
    for ([_][]const u8{ value.name, value.target, value.route_summary, value.failure_code.?, value.progress.failure_code.?, value.progress.failure_event.?.error_code.?, value.progress.discovery_issue.?.error_code.? }) |text| try SnapshotCopyFixture.expectText(text);
    try T.expectEqual(@as(u8, console.progress.capacity), value.progress.event_count);
    for (&value.progress.events, 0..) |*event, i| {
        try T.expectEqual(@as(u64, i + 1), event.sequence);
        try SnapshotCopyFixture.expectText(event.error_code.?);
        const context = &event.context.?;
        try T.expectEqual(@as(u16, 404), context.http_status.?);
        try T.expectEqual(@as(usize, 4096), context.resource_path.?.text().len);
        try T.expect(std.mem.startsWith(u8, context.resource_path.?.text(), "/redfish/v1/Systems/"));
        try T.expectEqualStrings(context.resource_path.?.text(), context.source_path.?.text());
        try T.expectEqualStrings("BootSourceOverrideTarget", context.source_property.?.text());
        try SnapshotCopyFixture.expectText(context.response_errors.?.text());
    }
}

test "BMC AI console snapshot allocation failures release partial copies" {
    var source_arena: std.heap.ArenaAllocator = .init(a);
    defer source_arena.deinit();
    const source = try SnapshotCopyFixture.source(source_arena.allocator());
    try T.checkAllAllocationFailures(a, SnapshotCopyFixture.copy, .{source});
    try SnapshotCopyFixture.expectText(source.progress.failure_code.?);
}

test "BMC AI describe frame reports real connection stages and requires a current complete frame" {
    const Stub = struct {
        value: console.Snapshot = .{ .owner = owner, .operation = .{ .owner = .{ .session = owner }, .operation_id = 1 }, .route = .connecting, .video = .authenticating, .progress = .{ .stage = .public_script }, .input = .{ .input_epoch = 1, .control_generation = 1, .transport_generation = 1, .connected = false, .controlled = false, .focused = false, .capture_paused = true, .queued = 0, .remote_unconfirmed = false } },
        unavailable: bool = false,
        fn snapshot(raw: *anyopaque, binding: typed.Binding, allocator: std.mem.Allocator) !console.OwnedSnapshot {
            const self: *@This() = @ptrCast(@alignCast(raw));
            if (!binding.owner.eql(owner) or self.unavailable) return error.SnapshotUnavailable;
            return console.OwnedSnapshot.init(allocator, self.value);
        }
        fn invoke(self: *@This(), arguments: std.json.Value) !api.ToolResult {
            // Only snapshot is initialized: discovery must never use any
            // control, refresh, focus or retry entry point.
            var table: console.Interface = undefined;
            table.snapshot = snapshot;
            const binding = typed.Binding.init(console.Interface, console.key, self, &table, owner, 1);
            return tools.invoke(.{ .owner = owner, .console = binding, .power = undefined, .boot = undefined }, .{ .owner = owner, .operation_id = 9, .tool_id = "bmc_ikvm.describe_frame", .arguments = arguments, .arguments_json = "{\"session_ids\":[83]}", .arguments_hash = @splat(0) }, a);
        }
        fn expect(self: *@This(), arguments: std.json.Value, state: []const u8, connected: bool, ready: bool) !void {
            var result = try self.invoke(arguments);
            defer result.deinit(a);
            const parsed = try std.json.parseFromSlice(std.json.Value, a, result.blocks[0].structured, .{});
            defer parsed.deinit();
            const facts = parsed.value.object;
            try T.expectEqualStrings(state, facts.get("connection_state").?.string);
            try T.expectEqual(connected, facts.get("connected").?.bool);
            try T.expectEqual(ready, facts.get("ready").?.bool);
            try T.expectEqual(self.value.rfb_ready, facts.get("rfb_ready").?.bool);
            try T.expectEqualStrings(@tagName(self.value.progress.stage), facts.get("connection_stage").?.string);
            try T.expect(!facts.get("pixel_access").?.bool);
            try T.expect(!facts.contains("pixels"));
            try T.expectEqual(api.Status.succeeded, result.status);
        }
    };
    const arguments = try std.json.parseFromSlice(std.json.Value, a, "{\"session_ids\":[83]}", .{});
    defer arguments.deinit();
    var stub: Stub = .{};
    try stub.expect(arguments.value, "public_script", false, false);
    stub.value.route = .connected;
    stub.value.video = .awaiting_frame;
    stub.value.progress.stage = .awaiting_first_frame;
    stub.value.rfb_ready = true;
    stub.value.input.connected = true;
    try stub.expect(arguments.value, "awaiting_first_frame", true, false);
    stub.value.video = .streaming;
    stub.value.progress.stage = .streaming;
    try stub.expect(arguments.value, "awaiting_first_frame", true, false);
    stub.value.width = 2;
    stub.value.height = 1;
    stub.value.stride = 8;
    stub.value.frame_sequence = 6;
    stub.value.frame_generation = 2;
    stub.value.input.geometry_generation = 2;
    try stub.expect(arguments.value, "streaming", true, true);
    // A retained frame cannot make a resize or a newer generation ready.
    stub.value.input.geometry_pending = true;
    try stub.expect(arguments.value, "awaiting_first_frame", true, false);
    stub.value.input.geometry_pending = false;
    stub.value.input.geometry_generation = 3;
    try stub.expect(arguments.value, "awaiting_first_frame", true, false);
    stub.value.input.geometry_generation = 2;
    stub.value.rfb_ready = false;
    try stub.expect(arguments.value, "connecting", false, false);
    stub.value.rfb_ready = true;
    stub.value.progress.failure_stage = .public_script;
    stub.value.progress.failure_code = "HttpTimeout";
    stub.value.progress.stage = .released;
    try stub.expect(arguments.value, "failed", false, false);
    stub.value.progress.failure_code = null;
    stub.value.progress.failure_stage = null;
    try stub.expect(arguments.value, "closed", false, false);
    stub.value.owner = try owner.nextGeneration();
    try T.expectError(error.StaleBinding, stub.invoke(arguments.value));
    stub.value.owner = owner;
    stub.unavailable = true;
    try T.expectError(error.SnapshotUnavailable, stub.invoke(arguments.value));
}

test "BMC AI gateway image approval rejection revision change and foreign owner stay zero dispatch" {
    var h: Harness = .{};
    try h.init();
    defer h.deinit();
    h.allow_approval = false;
    try T.expectError(error.ToolApprovalRejected, h.observe(1));
    try T.expectEqual(@as(usize, 0), h.dispatches);
    try T.expect(h.context.automation == null);
    h.allow_approval = true;
    h.mutate_policy_on_approval = true;
    try T.expectError(error.StaleToolAuthority, h.observe(2));
    try T.expectEqual(@as(usize, 0), h.dispatches);
    h.mutate_policy_on_approval = false;
    h.member[0].policy_revision = 9;
    try T.expectError(error.ToolCapabilityUnavailable, h.execute("bmc_ikvm.screenshot", "{\"session_ids\":[84]}", 3));
    h.member[0].owner = try owner.nextGeneration();
    try T.expectError(error.StaleToolAuthority, h.observe(4));
    try T.expectEqual(@as(usize, 0), h.dispatches);
    try T.expectEqual(@as(usize, 0), h.wire_length);
}

test "BMC AI gateway rejects unknown top nested and action fields before approval or input" {
    var h: Harness = .{};
    try h.init();
    defer h.deinit();
    const cases = [_]struct { id: []const u8, args: []const u8 }{
        .{ .id = "bmc_ikvm.screenshot", .args = "{\"session_ids\":[83],\"send_password\":true}" },
        .{ .id = "bmc_ikvm.screenshot", .args = "{\"session_ids\":[83],\"region\":{\"x\":0,\"y\":0,\"width\":1,\"height\":1,\"local_window\":true}}" },
        .{ .id = "bmc_ikvm.pointer", .args = "{\"session_ids\":[83],\"observation_id\":1,\"action\":\"move\",\"x\":0,\"y\":0,\"button\":\"left\"}" },
        .{ .id = "bmc_ikvm.pointer", .args = "{\"session_ids\":[83],\"observation_id\":1,\"action\":\"drag\",\"points\":[{\"x\":0,\"y\":0},{\"x\":1,\"y\":1,\"submit\":true}]}" },
        .{ .id = "bmc_ikvm.keyboard", .args = "{\"session_ids\":[83],\"observation_id\":1,\"action\":\"key\",\"keysym\":65505,\"down\":true}" },
        .{ .id = "bmc_ikvm.keyboard", .args = "{\"session_ids\":[83],\"observation_id\":1,\"action\":\"text\",\"text\":\"echo hi\\n\",\"layout\":\"us_ascii\"}" },
        .{ .id = "bmc_ikvm.operation_status", .args = "{\"session_ids\":[83],\"operation_id\":1,\"retry\":true}" },
    };
    for (cases) |case| try T.expectError(error.InvalidToolArguments, h.execute(case.id, case.args, 1));
    try T.expectEqual(@as(usize, 0), h.approvals);
    try T.expectEqual(@as(usize, 0), h.dispatches);
    try T.expectEqual(@as(usize, 0), h.wire_length);
}

test "BMC AI gateway queues then reports real RFB sent and consumes operation without replay" {
    var h: Harness = .{};
    try h.init();
    defer h.deinit();
    const observation = try h.observe(1);
    const queued = try h.move(observation, 2);
    defer release(queued);
    try expectState(queued[0], "queued");
    try T.expectEqual(@as(usize, 0), h.wire_length);
    try T.expect(h.grant.?.proof.valid());
    const pending = try h.execute("bmc_ikvm.screenshot", "{\"session_ids\":[83]}", 3);
    defer release(pending);
    try T.expectEqual(api.Status.failed, pending[0].status);
    try expectRejection(pending[0], "OperationPending");
    try T.expect(!pending[0].receipt.remote_effect_unknown);
    try h.pump();
    try T.expectEqualSlices(u8, &.{ 5, 0, 0, 1, 0, 0 }, h.wire_bytes[0..h.wire_length]);
    const status = try h.execute("bmc_ikvm.operation_status", "{\"session_ids\":[83],\"operation_id\":2}", 4);
    defer release(status);
    try expectState(status[0], "sent");
    try T.expectError(error.ToolOperationAlreadyRecorded, h.move(observation, 2));
    const reused = try h.move(observation, 5);
    defer release(reused);
    try T.expectEqual(api.Status.rejected, reused[0].status);
    try expectRejection(reused[0], "FreshObservationRequired");
    const fence = try h.execute("bmc_ikvm.screenshot", "{\"session_ids\":[83]}", 6);
    defer release(fence);
    try T.expectEqual(api.Status.failed, fence[0].status);
    try expectRejection(fence[0], "PostActionFramePending");
    try T.expect(!fence[0].receipt.remote_effect_unknown);
    try T.expectEqual(@as(usize, 6), h.wire_length);
}

test "BMC AI gateway observation timeout explains unsent input without claiming permission rejection" {
    var h: Harness = .{};
    try h.init();
    defer h.deinit();
    const observation = try h.observe(1);
    for (&h.control.observations) |*slot| if (slot.*) |*value| {
        if (value.id == observation) value.valid_until_monotonic_ms = value.captured_monotonic_ms;
    };
    const rejected = try h.move(observation, 2);
    defer release(rejected);
    try T.expectEqual(api.Status.rejected, rejected[0].status);
    try expectRejection(rejected[0], "ObservationExpired");
    const parsed = try std.json.parseFromSlice(std.json.Value, a, rejected[0].blocks[0].structured, .{});
    defer parsed.deinit();
    try T.expectEqualStrings("画面观察已超过有效期。", parsed.value.object.get("message").?.string);
    const next_step = parsed.value.object.get("next_step").?.string;
    try T.expect(std.mem.indexOf(u8, next_step, "重新截图") != null);
    try T.expect(std.mem.indexOf(u8, next_step, "授权") == null);
    try T.expect(!parsed.value.object.get("automatic_action_replay_allowed").?.bool);
    try T.expect(h.grant.?.proof.valid());
    try T.expectEqual(@as(usize, 0), h.wire_length);
}

test "BMC AI gateway geometry pending returns a structured wait without image or input" {
    var h: Harness = .{};
    try h.init();
    defer h.deinit();
    const observation = try h.observe(1);
    try h.input.beginGeometryChange(1);
    const waiting = try h.execute("bmc_ikvm.screenshot", "{\"session_ids\":[83]}", 2);
    defer release(waiting);
    try T.expectEqual(api.Status.failed, waiting[0].status);
    try expectRejection(waiting[0], "FrameGeometryPending");
    const state = try std.json.parseFromSlice(std.json.Value, a, waiting[0].blocks[0].structured, .{});
    defer state.deinit();
    try T.expectEqualStrings("waiting", state.value.object.get("state").?.string);
    try T.expect(state.value.object.get("retry_read_only").?.bool);
    try T.expect(!state.value.object.get("automatic_action_replay_allowed").?.bool);
    try T.expectEqual(@as(usize, 1), waiting[0].blocks.len);
    try T.expect(!waiting[0].receipt.remote_effect_unknown);
    const rejected = try h.move(observation, 3);
    defer release(rejected);
    try T.expectEqual(api.Status.rejected, rejected[0].status);
    try expectRejection(rejected[0], "FrameGeometryPending");
    const input_state = try std.json.parseFromSlice(std.json.Value, a, rejected[0].blocks[0].structured, .{});
    defer input_state.deinit();
    try T.expectEqualStrings("rejected", input_state.value.object.get("state").?.string);
    try T.expect(!input_state.value.object.get("retry_read_only").?.bool);
    try T.expect(rejected[0].observation_retry_ms == null);
    try T.expect(h.grant.?.proof.valid());
    try T.expectEqual(@as(usize, 0), h.wire_length);
}

test "BMC AI gateway screenshot wait finalizes deadline and preserves immediate unavailability" {
    const feedback = @import("ai/kvm_tool_feedback.zig");
    for ([_]bool{ false, true }) |waited| {
        var h: Harness = .{};
        try h.init();
        defer h.deinit();
        try h.input.beginGeometryChange(1);
        const results = try h.execute("bmc_ikvm.screenshot", "{\"session_ids\":[83]}", 1);
        defer release(results);
        try feedback.finishWait(a, "bmc_ikvm.screenshot", &results[0], waited);
        const value = try std.json.parseFromSlice(std.json.Value, a, results[0].blocks[0].structured, .{});
        defer value.deinit();
        try T.expectEqualStrings(if (waited) "ObservationWaitTimedOut" else "FrameGeometryPending", value.value.object.get("error_code").?.string);
        try T.expectEqualStrings(if (waited) "timed_out" else "failed", value.value.object.get("state").?.string);
        if (waited) try T.expectEqualStrings("FrameGeometryPending", value.value.object.get("cause_code").?.string);
        try T.expect(!value.value.object.get("dispatch").?.bool);
        try T.expect(!value.value.object.get("image_generated").?.bool);
        try T.expect(!value.value.object.get("automatic_action_replay_allowed").?.bool);
        try T.expect(results[0].observation_retry_ms == null);
        try T.expectEqual(@as(usize, 0), h.wire_length);
    }
}

test "BMC AI gateway human lease rejects automation and takeover cancels queued input with fresh epoch" {
    var h: Harness = .{};
    try h.init();
    defer h.deinit();
    const first = try h.observe(1);
    try h.context.setAuthorization(true, 9);
    h.context.setFocus(true, true);
    const human = try h.context.acquire(.human_focus, 9);
    const denied = try h.move(first, 2);
    defer release(denied);
    try T.expectEqual(api.Status.rejected, denied[0].status);
    try expectRejection(denied[0], "HumanInputActive");
    try T.expectEqual(@as(usize, 1), h.dispatches);
    try T.expect(h.context.automation == null);
    h.context.release(human);
    h.context.setFocus(true, false);
    const second = try h.observe(3);
    const queued = try h.move(second, 4);
    defer release(queued);
    const old = h.grant.?.proof;
    const epoch = (try h.input.snapshot(h.input.binding())).input_epoch;
    h.context.takeHumanControl();
    try T.expect(!old.valid());
    try T.expect((try h.input.snapshot(h.input.binding())).input_epoch > epoch);
    try h.pump();
    const status = try h.execute("bmc_ikvm.operation_status", "{\"session_ids\":[83],\"operation_id\":4}", 5);
    defer release(status);
    try expectState(status[0], "cancelled_unsent");
    try T.expectEqual(@as(usize, 0), h.wire_length);
}

test "BMC AI gateway cancellation guard and partial wire interruption never report execution success" {
    var h: Harness = .{};
    try h.init();
    defer h.deinit();
    const first = try h.observe(1);
    const queued = try h.move(first, 2);
    defer release(queued);
    h.cancelled.store(true, .release);
    try T.expect(!h.grant.?.proof.valid());
    try h.pump();
    try T.expectEqual(@as(usize, 0), h.wire_length);
    const cancelled = try h.execute("bmc_ikvm.operation_status", "{\"session_ids\":[83],\"operation_id\":2}", 3);
    defer release(cancelled);
    try expectState(cancelled[0], "cancelled_unsent");
    h.grant.?.release();
    h.grant = null;
    h.cancelled.store(false, .release);
    const second = try h.observe(4);
    const partial = try h.move(second, 5);
    defer release(partial);
    h.partial_wire = true;
    try h.pump();
    try T.expectEqual(@as(usize, 1), h.wire_length);
    h.context.takeHumanControl();
    const unknown = try h.execute("bmc_ikvm.operation_status", "{\"session_ids\":[83],\"operation_id\":5}", 6);
    defer release(unknown);
    try T.expectEqual(api.Status.outcome_unknown, unknown[0].status);
    try T.expect(unknown[0].receipt.remote_effect_unknown);
    try expectState(unknown[0], "partial_unknown");
    try T.expect(h.grant == null);
    const wire_receipt = try h.input.automationStatus(h.input.binding(), 5);
    try T.expectEqual(@as(u16, 0), wire_receipt.sent_events);
    try T.expect(wire_receipt.possibly_written);
}

test "BMC AI gateway invocation effect cannot grant input without a real current host proof" {
    var h: Harness = .{};
    try h.init();
    defer h.deinit();
    const arguments = try std.json.parseFromSlice(std.json.Value, a, "{\"session_ids\":[83],\"observation_id\":1,\"action\":\"move\",\"x\":0,\"y\":0}", .{});
    defer arguments.deinit();
    var call: api.Invocation = .{ .owner = owner, .operation_id = 1, .tool_id = "bmc_ikvm.pointer", .effect = .read_state, .arguments = arguments.value, .arguments_json = "", .arguments_hash = @splat(0) };
    try T.expectError(error.ToolPermissionDenied, Harness.handle(&h, call, a));
    call.effect = .remote_input;
    var rejected = try Harness.handle(&h, call, a);
    defer rejected.deinit(a);
    try T.expectEqual(api.Status.rejected, rejected.status);
    try expectRejection(rejected, "ToolPermissionDenied");
    try T.expectEqual(@as(usize, 0), h.wire_length);
}

test "BMC AI gateway malformed parameters return actionable model diagnostics before dispatch" {
    const loop = @import("ai/tool_loop.zig");
    const Host = struct {
        fn execute(_: *anyopaque, _: loop.Invocation, _: std.mem.Allocator, _: ?*provider.CancelToken) !loop.Outcome {
            return error.UnexpectedDispatch;
        }
    };
    var h: Harness = .{};
    try h.init();
    defer h.deinit();
    var run = loop.Loop.init(a, captured, 1, .{});
    defer run.deinit();
    try run.start(.{ .model = "fixture", .system = "", .messages = &.{}, .tool_table = &h.table });
    try run.complete("", &.{.{ .id = "invalid-kvm", .name = "bmc_uikvm__keyboard", .arguments = "{\"session_ids\":[83],\"observation_id\":1,\"action\":\"text\",\"text\":\"非 ASCII\",\"layout\":\"us_ascii\"}" }}, .{ .context = &h, .execute = Host.execute }, .{}, 1, null);
    const result = try std.json.parseFromSlice(std.json.Value, a, run.records.items[0].result_body.?, .{});
    defer result.deinit();
    try T.expectEqualStrings("InvalidToolArguments", result.value.object.get("error_code").?.string);
    try T.expectEqualStrings("rejected", result.value.object.get("state").?.string);
    try T.expect(result.value.object.get("message").?.string.len > 0);
    try T.expect(std.mem.indexOf(u8, result.value.object.get("next_step").?.string, "修正请求") != null);
    try T.expect(!result.value.object.get("dispatch").?.bool);
    try T.expect(!run.records.items[0].dispatched);
    try T.expectEqual(@as(usize, 0), h.dispatches);
}

test "BMC AI gateway stale control observation is a structured zero dispatch rejection" {
    var h: Harness = .{};
    try h.init();
    defer h.deinit();
    const observation = try h.observe(1);
    try h.input.setControl(true, 2);
    const rejected = try h.move(observation, 2);
    defer release(rejected);
    try T.expectEqual(api.Status.rejected, rejected[0].status);
    try expectRejection(rejected[0], "ObservationInvalidated");
    try T.expect(!rejected[0].receipt.remote_effect_unknown);
    try h.pump();
    try T.expectEqual(@as(usize, 0), h.wire_length);
}

test "BMC AI gateway worker proof revocation unlocks guard before the transport release callback" {
    var h: Harness = .{};
    try h.init();
    defer h.deinit();
    const observation = try h.observe(1);
    const queued = try h.move(observation, 2);
    defer release(queued);
    const old = h.grant.?.proof;
    var foreign_task: std.atomic.Value(bool) = .init(false);
    try T.expectError(error.AutomationTaskActive, h.context.acquireAutomation(9, &foreign_task, null, Harness.nowMs(&h) + 1000));
    try T.expect(old.valid());
    const Callback = struct {
        input: *remote.Service,
        proof: content.AutomationProof,
        checked: bool = false,
        fn consume(raw: *anyopaque, event: content.Input) !void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            if (event != .release_all) return error.TypedInputRequired;
            // This would deadlock if Context held Guard while entering a
            // consumer that acquires remote_input's mutex in the other order.
            if (self.proof.valid()) return error.AuthorityNotRevoked;
            _ = self.input.releaseAll(self.input.binding(), .released);
            self.checked = true;
        }
    };
    var callback: Callback = .{ .input = &h.input, .proof = old };
    try h.context.setConsumer(.{ .context = &callback, .consume = Callback.consume });
    const Worker = struct {
        proof: content.AutomationProof,
        started: std.atomic.Value(bool) = .init(false),
        observed_revoked: bool = false,
        fn run(self: *@This()) void {
            self.started.store(true, .release);
            const deadline = Harness.nowMs(self) + 2000;
            while (self.proof.valid() and Harness.nowMs(self) < deadline) std.atomic.spinLoopHint();
            self.observed_revoked = !self.proof.valid();
        }
    };
    var worker: Worker = .{ .proof = old };
    const thread = try std.Thread.spawn(.{}, Worker.run, .{&worker});
    while (!worker.started.load(.acquire)) std.atomic.spinLoopHint();
    try h.context.setAuthorization(false, 10);
    thread.join();
    try T.expect(callback.checked and worker.observed_revoked);
    try T.expect(!old.valid());
    try h.context.setAuthorization(true, 11);
    const renewed = try h.context.acquireAutomation(11, null, null, Harness.nowMs(&h) + 1000);
    try T.expect(renewed.proof.lease.id != old.lease.id);
    try T.expect(!old.valid());
    renewed.release();
    try T.expect(!h.context.authorized);
    try T.expect(!renewed.proof.valid());
    try T.expectEqual(@as(usize, 0), h.wire_length);
    // Restore a consumer whose lifetime includes Harness.deinit.
    try h.context.setConsumer(.{ .context = &h.input, .consume = Harness.consume });
}

test "BMC efficiency frame cache reuses exact pixels but creates fresh observations" {
    var h: Harness = .{};
    try h.init();
    defer h.deinit();
    var first = try h.control.screenshot(h.control.binding(), a, .{});
    defer first.deinit();
    var second = try h.control.screenshot(h.control.binding(), a, .{});
    defer second.deinit();
    try T.expect(first.id != second.id);
    try T.expect(first.image_ref.snapshot == second.image_ref.snapshot);
    _ = try h.frame.publishComplete(2, 2, &.{ 1, 2, 3, 255, 4, 5, 6, 255, 7, 8, 9, 255, 10, 11, 12, 255 }, Harness.nowMs(&h) * std.time.ns_per_ms);
    var third = try h.control.screenshot(h.control.binding(), a, .{});
    defer third.deinit();
    try T.expect(third.sequence > second.sequence);
    try T.expect(first.image_ref.snapshot == third.image_ref.snapshot);
    try T.expectEqual(@as(usize, 1), h.control.encoded_images);
    try T.expectEqual(@as(usize, 2), h.control.reused_images);
    _ = try h.frame.publishComplete(2, 2, &.{ 99, 2, 3, 255, 4, 5, 6, 255, 7, 8, 9, 255, 10, 11, 12, 255 }, Harness.nowMs(&h) * std.time.ns_per_ms);
    var changed = try h.control.screenshot(h.control.binding(), a, .{});
    defer changed.deinit();
    try T.expect(first.image_ref.snapshot != changed.image_ref.snapshot);
    try T.expectEqual(@as(usize, 2), h.control.encoded_images);
    try T.expectError(error.UnknownOperation, h.control.screenshot(h.control.binding(), a, .{ .after_operation_id = 99 }));
}

test "BMC efficiency text input compiles 256 ASCII characters without Enter" {
    const automation = @import("plugins/bmc_ikvm/automation_input.zig");
    const text: [256]u8 = @splat('A');
    const batch = try automation.compile(.{ .text = try automation.Text.init(&text, .us_ascii) });
    try T.expectEqual(@as(u16, 1024), batch.count);
    for (batch.events[0..batch.count]) |event| if (event == .key) try T.expect(event.key.keysym != 0xff0d);
    const too_long: [257]u8 = @splat('A');
    try T.expectError(error.InvalidTextLength, automation.Text.init(&too_long, .us_ascii));
    try T.expectError(error.UnsupportedText, automation.compile(.{ .text = try automation.Text.init("a\nb", .us_ascii) }));
}

test "BMC efficiency 256 byte text uses bounded sender turns and never replays a partial takeover" {
    for ([_]bool{ false, true }) |takeover| {
        var h: Harness = .{};
        try h.init();
        defer h.deinit();
        const observation = try h.observe(1);
        const text: [256]u8 = @splat('A');
        const args = try std.fmt.allocPrint(a, "{{\"session_ids\":[83],\"observation_id\":{d},\"action\":\"text\",\"layout\":\"us_ascii\",\"text\":\"{s}\"}}", .{ observation, text });
        defer a.free(args);
        const accepted = try h.execute("bmc_ikvm.keyboard", args, 2);
        defer release(accepted);
        try T.expectEqual(api.Status.succeeded, accepted[0].status);
        var messages: usize = 0;
        for (0..20) |turn| {
            h.wire_length = 0;
            try h.pump();
            try T.expect(h.wire_length <= 64 * 8 and h.wire_length % 8 == 0);
            var offset: usize = 0;
            while (offset < h.wire_length) : (offset += 8) {
                try T.expectEqual(@as(u8, 4), h.wire_bytes[offset]);
                try T.expect(std.mem.readInt(u32, h.wire_bytes[offset + 4 ..][0..4], .big) != 0xff0d);
            }
            messages += h.wire_length / 8;
            if (takeover and turn == 0) h.context.takeHumanControl();
        }
        const receipt = try h.input.automationStatus(h.input.binding(), 2);
        try T.expectEqual(@as(usize, if (takeover) 64 else 1024), messages);
        try T.expectEqual(@as(u16, @intCast(messages)), receipt.sent_events);
        try T.expectEqual(@as(u16, 1024), receipt.total_events);
        try T.expectEqual(if (takeover) control.automation.Status.outcome_unknown else control.automation.Status.sent, receipt.status);
    }
}

test "BMC efficiency full resolution reuse retains one encoding and matching decoded pixels" {
    var h: Harness = .{};
    h.budget = budgets.Budget.init(64 * 1024 * 1024);
    try h.init();
    defer h.deinit();
    const pixels = try a.alloc(u8, 1920 * 1200 * 4);
    defer a.free(pixels);
    for (0..1200) |y| for (0..1920) |x| {
        const offset = (y * 1920 + x) * 4;
        pixels[offset] = @intCast(x % 256);
        pixels[offset + 1] = @intCast(y % 256);
        pixels[offset + 2] = @intCast((x + y) % 256);
        pixels[offset + 3] = 255;
    };
    _ = try h.frame.publishComplete(1920, 1200, pixels, Harness.nowMs(&h) * std.time.ns_per_ms);
    const started = @import("platform/realtime.zig").monotonicNs();
    var first = try h.control.screenshot(h.control.binding(), a, .{});
    defer first.deinit();
    const encoded = @import("platform/realtime.zig").monotonicNs();
    var second = try h.control.screenshot(h.control.binding(), a, .{});
    defer second.deinit();
    const reused = @import("platform/realtime.zig").monotonicNs();
    try T.expect(first.image_ref.snapshot == second.image_ref.snapshot);
    try T.expectEqual(@as(usize, 1), h.control.encoded_images);
    const saved = first.image_ref.content().?;
    var decoded = try @import("ai/image_attachments.zig").ContentRef.create(a, "check.png", saved.bytes, 0, .{});
    defer decoded.release();
    try T.expectEqualSlices(u8, saved.pixels, decoded.content().?.pixels);
    if (std.c.getenv("ZEROWORK_AI_EFFICIENCY_PROFILE") != null) std.debug.print("KVM 1920x1200 encode_us={d} reuse_us={d} encoded_bytes={d} cache_bytes={d}\n", .{ @divTrunc(encoded - started, 1000), @divTrunc(reused - encoded, 1000), saved.bytes.len, h.control.cache_reservation.?.bytes });
}

test "BMC efficiency asynchronous encoding settles once and close drains without publishing stale observations" {
    var h: Harness = .{};
    h.budget = budgets.Budget.init(64 * 1024 * 1024);
    try h.init();
    defer h.deinit();
    h.control.asynchronous_encoding = true;
    try T.expectError(error.ImageEncodingPending, h.control.screenshot(h.control.binding(), a, .{}));
    const deadline = Harness.nowMs(&h) + 3000;
    var result: ?control.Observation = null;
    while (result == null) {
        result = h.control.screenshot(h.control.binding(), a, .{}) catch |err| switch (err) {
            error.ImageEncodingPending => null,
            else => return err,
        };
        if (Harness.nowMs(&h) >= deadline) return error.EncodingTimedOut;
        const delay: std.c.timespec = .{ .sec = 0, .nsec = std.time.ns_per_ms };
        _ = std.c.nanosleep(&delay, null);
    }
    result.?.deinit();
    try T.expectEqual(@as(usize, 1), h.control.encoded_images);
    try T.expect(h.control.encoding == null);
    const original = h.control.cached_image.snapshot;
    _ = try h.frame.publishComplete(2, 2, &.{ 1, 2, 3, 255, 4, 5, 6, 255, 7, 8, 9, 255, 10, 11, 12, 255 }, Harness.nowMs(&h) * std.time.ns_per_ms);
    try T.expectError(error.ImageEncodingPending, h.control.screenshot(h.control.binding(), a, .{}));
    // A result prepared before a different input operation is never published,
    // even when its pixels happen to equal a later frame.
    h.control.encoding.?.operation_id = 123;
    while (!h.control.encoding.?.done.load(.acquire)) {
        if (Harness.nowMs(&h) >= deadline) return error.EncodingTimedOut;
        const delay: std.c.timespec = .{ .sec = 0, .nsec = std.time.ns_per_ms };
        _ = std.c.nanosleep(&delay, null);
    }
    try T.expectError(error.ObservationInvalidated, h.control.screenshot(h.control.binding(), a, .{}));
    result = null;
    while (result == null) {
        result = h.control.screenshot(h.control.binding(), a, .{}) catch |err| switch (err) {
            error.ImageEncodingPending => null,
            else => return err,
        };
        if (Harness.nowMs(&h) >= deadline) return error.EncodingTimedOut;
        const delay: std.c.timespec = .{ .sec = 0, .nsec = std.time.ns_per_ms };
        _ = std.c.nanosleep(&delay, null);
    }
    try T.expect(result.?.image_ref.snapshot == original);
    result.?.deinit();
    try T.expectEqual(@as(usize, 1), h.control.encoded_images);
    try T.expectEqual(@as(usize, 1), h.control.reused_images);
    _ = try h.frame.publishComplete(2, 2, &.{ 9, 2, 3, 255, 4, 5, 6, 255, 7, 8, 9, 255, 10, 11, 12, 255 }, Harness.nowMs(&h) * std.time.ns_per_ms);
    try T.expectError(error.ImageEncodingPending, h.control.screenshot(h.control.binding(), a, .{}));
    const next_observation = h.control.next_observation;
    h.control.close();
    try T.expectError(error.OwnerClosed, h.control.screenshot(h.control.binding(), a, .{}));
    while (!h.control.drainEncoding()) {
        if (Harness.nowMs(&h) >= deadline) return error.EncodingTimedOut;
        const delay: std.c.timespec = .{ .sec = 0, .nsec = std.time.ns_per_ms };
        _ = std.c.nanosleep(&delay, null);
    }
    try T.expectEqual(next_observation, h.control.next_observation);
    try T.expect(h.control.cached_image.snapshot == null);
}
