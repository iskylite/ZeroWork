//! Production BMC definitions through the real generic schema/approval gateway,
//! real content leases, immutable CPU frames and the real RFB sender.
const std = @import("std");
const T = std.testing;
const a = T.allocator;
const api = @import("ai/plugin_tools.zig");
const scope = @import("ai/tool_scope.zig");
const provider = @import("ai/provider.zig");
const tools = @import("plugins/bmc_ikvm/tools.zig");
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

test "BMC AI gateway preserves read IDs and has seven schema effect matched tools without management writes" {
    try T.expectEqual(@as(usize, 7), tools.definitions.len);
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
    try T.expect(try api.needsApproval(tools.definitions[3], .{ .full_control = true }));
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
    try T.expect(h.grant.?.proof.valid());
    try T.expectEqual(@as(usize, 0), h.wire_length);
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
    try T.expectEqual(api.Status.cancelled_unsent, denied[0].status);
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
    try T.expectError(error.ToolPermissionDenied, Harness.handle(&h, call, a));
    try T.expectEqual(@as(usize, 0), h.wire_length);
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
