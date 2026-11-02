//! Production authorization/controller/native TLS acceptance. Only the owned
//! ephemeral 127.0.0.1 fixture is reachable; no real device or credential is used.
const std = @import("std");
const T = std.testing;
const a = T.allocator;
const fixture = @import("bmc_native_driver_tests.zig");
const runtime_api = @import("plugins/bmc_ikvm/runtime.zig");
const console = @import("plugins/bmc_ikvm/console_service.zig");
const svc = @import("plugins/bmc_ikvm/services.zig");
const model = @import("plugins/bmc_ikvm/model.zig");
const ledger = @import("plugins/bmc_ikvm/management_journal.zig");
const management = @import("plugins/bmc_ikvm/management_adapter.zig");
const budgets = @import("host/frame_budget.zig");
const challenges = @import("host/challenge_host.zig");
const actions = @import("host/resource_actions.zig");
const contexts = @import("host/host_context.zig");
const tls = @import("host/tls_trust.zig");
const transports = @import("host/transport_factory.zig");
const ssh = @import("proto/ssh/session.zig");
const owner: svc.identity.SessionHandle = .{ .session_id = @fromBackingInt(977), .generation = 7 };
const operation: svc.OperationKey = .{ .owner = .{ .session = owner }, .operation_id = 1, .attempt_id = 7 };

fn pause() void {
    var fds: [1]std.c.pollfd = undefined;
    _ = std.c.poll(&fds, 0, 1);
}
fn verify(_: ?*anyopaque, authority: tls.Authority, chain: []const []const u8) !tls.VerificationResult {
    try T.expectEqualStrings("127.0.0.1", authority.host);
    try T.expect(chain.len == 1 and chain[0].len > 500);
    return .{ .failures = .{ .untrusted_issuer = true } };
}
const Harness = struct {
    server: fixture.Fixture,
    budget: budgets.Budget,
    backend: ledger.MemoryBackend,
    journal: ledger.Journal,
    host: challenges.Host,
    arbiter: actions.Arbiter,
    trust: tls.Store,
    library: ssh.Library = .{ .active = false },
    runtime: ?*runtime_api.Runtime = null,
    fn init(mode: []const u8, policy: svc.ManagementPolicy) !*Harness {
        return initWithDisplay(mode, policy, false);
    }
    fn initWithDisplay(mode: []const u8, policy: svc.ManagementPolicy, read_only_requested: bool) !*Harness {
        const self = try a.create(Harness);
        errdefer a.destroy(self);
        self.server = try fixture.Fixture.start(mode);
        errdefer self.server.deinit();
        self.budget = budgets.Budget.init(128 * 1024 * 1024);
        errdefer self.budget.deinit() catch unreachable;
        self.backend = .{ .allocator = a };
        errdefer self.backend.deinit();
        self.journal = try ledger.Journal.init(a, self.backend.backend());
        errdefer self.journal.deinit();
        self.host = challenges.Host.init(a);
        errdefer self.host.deinit();
        self.arbiter = actions.Arbiter.init(a);
        errdefer self.arbiter.deinit();
        self.trust = tls.Store.init(a, .{ .verify = verify }, null);
        errdefer self.trust.deinit();
        self.library = .{ .active = false };
        self.runtime = null;
        const payload: model.Payload = .{ .endpoint = .{ .host = "127.0.0.1", .https_port = self.server.port }, .username = "fixture", .display = .{ .read_only_requested = read_only_requested } };
        const bytes = try std.json.Stringify.valueAlloc(a, payload, .{});
        defer a.free(bytes);
        const target: contexts.Target = .{ .window_id = @fromBackingInt(1), .workspace_id = @fromBackingInt(1) };
        const context: contexts.HostContext = .{ .owner = owner, .operation = operation, .target = target, .challenges = &self.host, .resource_actions = self.arbiter.facade(owner), .transports = transports.Factory{ .allocator = a, .library = &self.library }, .trust = .{ .tls = self.trust.facade(owner) } };
        self.runtime = try runtime_api.Runtime.prepareNativeForTest(a, .{ .handle = owner, .key = operation, .target = .{ .window_id = target.window_id, .workspace_id = target.workspace_id }, .spec = .{ .plugin = .{ .protocol_id = model.protocol_id, .name = "Owned loopback fixture", .payload = bytes } }, .context = context }, .{ .frame_budget = &self.budget, .journal = &self.journal, .management_policy = policy }, try fixture.selected(self.server.pem));
        self.runtime.?.published = true;
        errdefer self.stop();
        const deadline = runtime_api.monotonicMs() + 10_000;
        while (self.runtime.?.controller.poll().video != .streaming) {
            try self.pollLogin();
            if (self.runtime.?.controller.poll().failure) |failure| return failure;
            if (runtime_api.monotonicMs() >= deadline) return error.ProductionFixtureConnectTimeout;
            pause();
        }
        return self;
    }
    fn stop(self: *Harness) void {
        if (self.runtime) |runtime| {
            const deadline = runtime_api.monotonicMs() + 20_000;
            while (runtime.close() != .released) {
                _ = runtime.poll() catch false;
                if (runtime_api.monotonicMs() >= deadline) @panic("production fixture did not release");
                pause();
            }
            runtime.deinit() catch @panic("production fixture runtime deinit failed");
            self.runtime = null;
        }
    }
    fn destroy(self: *Harness) void {
        self.stop();
        self.server.deinit();
        self.trust.deinit();
        self.arbiter.deinit();
        self.host.deinit();
        self.journal.deinit();
        self.backend.deinit();
        self.budget.deinit() catch @panic("production fixture leaked frame budget");
        a.destroy(self);
    }
    fn finish(self: *Harness) !void {
        self.stop();
        const term = try self.server.child.wait(std.testing.io);
        try T.expect(term == .exited and term.exited == 0);
        try T.expectEqual(@as(usize, 0), self.budget.usedBytes());
        try T.expectEqual(@as(usize, 0), self.arbiter.count());
    }
    fn pollLogin(self: *Harness) !void {
        _ = try self.runtime.?.poll();
        var index: usize = 0;
        while (self.host.snapshot(index, owner)) |view| {
            if (view.owner == .operation) {
                index += 1;
                continue;
            }
            const reply: challenges.Reply = if (view.kind == .secret_input) .{ .secret_input = &self.server.password } else .{ .choice = "once" };
            try self.host.submitAnswer(view.owner, view.request_id, view.generation, reply, runtime_api.monotonicMs());
            _ = try self.runtime.?.poll();
        }
    }
    fn power(self: *Harness, action: svc.PowerAction, id: u64) !svc.Owned(svc.ManagementRequest) {
        const runtime = self.runtime.?;
        const binding = runtime.powerBinding();
        const table = try binding.borrow(svc.PowerService, svc.power_key, owner);
        var snapshot = try table.snapshot(binding.context, .{ .owner = owner, .binding_generation = owner.generation }, a);
        defer snapshot.deinit();
        return svc.Owned(svc.ManagementRequest).init(a, .{ .power = .{ .execution = execution(snapshot.value.capability, snapshot.value.system_uri, id), .action = action } });
    }
    fn boot(self: *Harness, id: u64) !svc.Owned(svc.ManagementRequest) {
        const runtime = self.runtime.?;
        const binding = runtime.bootBinding();
        const table = try binding.borrow(svc.BootService, svc.boot_key, owner);
        var snapshot = try table.snapshot(binding.context, .{ .owner = owner, .binding_generation = owner.generation }, a);
        defer snapshot.deinit();
        return svc.Owned(svc.ManagementRequest).init(a, .{ .boot = .{ .execution = execution(snapshot.value.capability, snapshot.value.system_uri, id), .baseline = snapshot.value.state, .enabled = "Once", .target = "Pxe", .etag = snapshot.value.etag } });
    }
    fn submit(self: *Harness, request: svc.ManagementRequest) !void {
        const binding = self.runtime.?.consoleBinding();
        const table = try binding.borrow(console.Interface, console.key, owner);
        const accepted = table.request_management.?(binding.context, binding, request);
        if (accepted == .rejected) std.debug.print("production request rejected: {s}\n", .{@tagName(accepted.rejected)});
        try T.expect(accepted == .accepted);
        try T.expect(accepted.accepted.eql(request.execution().operation));
        _ = try self.runtime.?.poll();
    }
    fn answer(self: *Harness, request: svc.ManagementRequest, approved: bool) !void {
        _ = try self.runtime.?.poll();
        const key = request.execution().operation;
        try T.expectEqual(challenges.State.pending, self.host.stateFor(key, key.operation_id, key.attempt_id orelse 1).?);
        try self.host.submitAnswer(key, key.operation_id, key.attempt_id orelse 1, .{ .choice = if (approved) "approve" else "cancel" }, runtime_api.monotonicMs());
        _ = try self.runtime.?.poll();
    }
    fn result(self: *Harness, request: svc.ManagementRequest) !svc.Owned(svc.Result) {
        const binding = self.runtime.?.powerBinding();
        const table = try binding.borrow(svc.PowerService, svc.power_key, owner);
        return table.result(binding.context, request.execution().call, request.execution().operation, a);
    }
    fn terminal(self: *Harness, request: svc.ManagementRequest) !svc.Owned(svc.Result) {
        const deadline = runtime_api.monotonicMs() + 15_000;
        while (true) {
            _ = try self.runtime.?.poll();
            var current = try self.result(request);
            if (current.value.terminal()) return current;
            current.deinit();
            if (self.runtime.?.controller.poll().failure) |failure| return failure;
            if (runtime_api.monotonicMs() >= deadline) return error.ProductionResultTimeout;
            pause();
        }
    }
};
fn execution(cap: svc.Capability, uri: []const u8, id: u64) svc.Execution {
    return .{ .call = .{ .owner = owner, .binding_generation = owner.generation }, .operation = .{ .owner = .{ .session = owner }, .operation_id = id, .attempt_id = owner.generation }, .nonce = @splat(@truncate(id)), .system_uri = uri, .capability_revision = cap.revision, .grant_revision = cap.grant_revision };
}

test "BMC production management explicit approval runs native TLS pre-read If-Match 202 task and verified power readback" {
    const h = try Harness.init("production-power", .user_approved);
    defer h.destroy();
    var request = try h.power(.force_off, 100);
    defer request.deinit();
    const binding = h.runtime.?.powerBinding();
    const table = try binding.borrow(svc.PowerService, svc.power_key, owner);
    var snapshot = try table.snapshot(binding.context, request.value.execution().call, a);
    defer snapshot.deinit();
    try T.expect(snapshot.value.capability.write_requestable);
    try T.expect(!snapshot.value.capability.write_granted);
    try T.expectEqual(svc.Reason.permission_denied, table.request(binding.context, request.value.power).rejected);
    try h.submit(request.value);
    var waiting = try h.result(request.value);
    defer waiting.deinit();
    try T.expectEqual(svc.Phase.awaiting_approval, waiting.value.phase);
    try T.expectEqual(@as(usize, 0), h.backend.writes);
    // Mutating the caller's draft after submit cannot alter the owned approval.
    const frozen = request.value;
    request.value.power.action = .graceful_restart;
    try h.answer(frozen, true);
    var result = try h.terminal(frozen);
    defer result.deinit();
    try T.expectEqual(svc.Phase.succeeded, result.value.phase);
    try T.expectEqual(svc.PowerState.off, result.value.current_power.?);
    try T.expect(result.value.dispatched and result.value.task_uri != null);
    try h.finish();
    try T.expectEqual(@as(usize, 1), h.journal.entries.len);
}

test "BMC production management native Boot PATCH verifies only current values and distinguishes pending settings" {
    for ([_][]const u8{ "production-boot", "production-pending" }) |mode| {
        const h = try Harness.init(mode, .user_approved);
        defer h.destroy();
        var request = try h.boot(101);
        defer request.deinit();
        try h.submit(request.value);
        try h.answer(request.value, true);
        var result = try h.terminal(request.value);
        defer result.deinit();
        if (std.mem.eql(u8, mode, "production-pending")) {
            try T.expectEqual(svc.Phase.outcome_unknown, result.value.phase);
            try T.expectEqual(svc.Reason.pending, result.value.reason.?);
            try T.expectEqualStrings("Disabled", result.value.current_boot.?.enabled.?);
            try T.expectEqualStrings("Once", result.value.pending_boot.?.enabled.?);
        } else {
            try T.expectEqual(svc.Phase.succeeded, result.value.phase);
            try T.expectEqualStrings("Once", result.value.current_boot.?.enabled.?);
            try T.expectEqualStrings("Pxe", result.value.current_boot.?.target.?);
        }
        try h.finish();
    }
}

test "BMC production management native Critical resource diagnostics retain approved power and Boot field operations" {
    for ([_][]const u8{ "production-critical-power", "production-critical-boot", "production-scoped-power", "production-scoped-boot", "production-critical-disabled" }, 0..) |mode, index| {
        const h = try Harness.init(mode, .user_approved);
        defer h.destroy();
        const is_boot = std.mem.eql(u8, mode, "production-critical-boot") or std.mem.eql(u8, mode, "production-scoped-power") or std.mem.eql(u8, mode, "production-critical-disabled");
        const disabled = std.mem.eql(u8, mode, "production-critical-disabled");
        var request = if (is_boot) try h.boot(120 + index) else try h.power(.force_off, 120 + index);
        defer request.deinit();
        const power_binding = h.runtime.?.powerBinding();
        const power_table = try power_binding.borrow(svc.PowerService, svc.power_key, owner);
        var power_snapshot = try power_table.snapshot(power_binding.context, request.value.execution().call, a);
        defer power_snapshot.deinit();
        const boot_binding = h.runtime.?.bootBinding();
        const boot_table = try boot_binding.borrow(svc.BootService, svc.boot_key, owner);
        var boot_snapshot = try boot_table.snapshot(boot_binding.context, request.value.execution().call, a);
        defer boot_snapshot.deinit();
        try T.expectEqual(svc.Validity.partial_with_error, power_snapshot.value.resource_evidence.validity);
        try T.expectEqual(svc.Validity.partial_with_error, boot_snapshot.value.resource_evidence.validity);
        try T.expect(power_snapshot.value.capability.system_mapping_verified and power_snapshot.value.capability.write_requestable);
        try T.expect(boot_snapshot.value.capability.system_mapping_verified and boot_snapshot.value.capability.write_requestable);
        try T.expect(!power_snapshot.value.capability.write_granted and !boot_snapshot.value.capability.write_granted);
        if (std.mem.eql(u8, mode, "production-scoped-power")) {
            try T.expectError(error.UnsupportedAction, management.power.validatePowerFields(power_snapshot.value, .force_off));
            try T.expect(boot_snapshot.value.enabled_evidence.permitsWrite() and boot_snapshot.value.target_evidence.permitsWrite());
        } else if (std.mem.eql(u8, mode, "production-scoped-boot")) {
            try T.expect(!boot_snapshot.value.target_evidence.permitsWrite());
            try management.power.validatePowerFields(power_snapshot.value, .force_off);
        }
        if (disabled) {
            try T.expect(!boot_snapshot.value.target_evidence.permitsWrite() and !boot_snapshot.value.mode_evidence.permitsWrite());
            request.value.boot.enabled = "Disabled";
            request.value.boot.target = null;
            request.value.boot.mode = null;
        }
        try h.submit(request.value);
        var waiting = try h.result(request.value);
        defer waiting.deinit();
        try T.expectEqual(svc.Phase.awaiting_approval, waiting.value.phase);
        try T.expectEqual(@as(usize, 0), h.backend.writes);
        try h.answer(request.value, true);
        var result = try h.terminal(request.value);
        defer result.deinit();
        try T.expectEqual(svc.Phase.succeeded, result.value.phase);
        try T.expect(result.value.dispatched);
        if (is_boot) {
            try T.expectEqualStrings(if (disabled) "Disabled" else "Once", result.value.current_boot.?.enabled.?);
            if (!disabled) try T.expectEqualStrings("Pxe", result.value.current_boot.?.target.?);
        } else try T.expectEqual(svc.PowerState.off, result.value.current_power.?);
        try h.finish();
        try T.expectEqual(@as(usize, 1), h.journal.entries.len);
    }
}

test "BMC production management native 403 409 412 and post-send disconnect never replay mutation" {
    for ([_][]const u8{ "production-forbidden403", "production-conflict409", "production-precondition412", "production-disconnect" }, [_]?u16{ 403, 409, 412, null }) |mode, status| {
        const h = try Harness.init(mode, .user_approved);
        defer h.destroy();
        var request = try h.power(.force_off, 102);
        defer request.deinit();
        try h.submit(request.value);
        try h.answer(request.value, true);
        var result = try h.terminal(request.value);
        defer result.deinit();
        if (status) |code| {
            try T.expectEqual(svc.Phase.failed, result.value.phase);
            try T.expectEqual(code, result.value.http_status.?);
            try T.expectEqual(if (code == 403) svc.Reason.permission_denied else svc.Reason.conflict, result.value.reason.?);
        } else {
            try T.expectEqual(svc.Phase.outcome_unknown, result.value.phase);
            try T.expectEqual(svc.Reason.transport_lost, result.value.reason.?);
        }
        // Duplicate UI intent is the same operation result, never new work.
        const binding = h.runtime.?.consoleBinding();
        const table = try binding.borrow(console.Interface, console.key, owner);
        const duplicate = table.request_management.?(binding.context, binding, request.value);
        try T.expect(duplicate == .accepted or duplicate.rejected == .stale_capability or duplicate.rejected == .permission_denied);
        try h.finish();
        try T.expectEqual(@as(usize, 1), h.journal.entries.len);
    }
}

test "BMC production management readonly factory rejects UI typed adapter and engine write entry points on native backend" {
    for ([_]svc.ManagementPolicy{ .read_only, .user_approved }, [_]bool{ false, true }) |policy, display_readonly| try readonlyScenario(policy, display_readonly);
}
fn readonlyScenario(policy: svc.ManagementPolicy, display_readonly: bool) !void {
    const h = try Harness.initWithDisplay("mapped-read", policy, display_readonly);
    defer h.destroy();
    var request = try h.power(.graceful_shutdown, 103);
    defer request.deinit();
    const runtime = h.runtime.?;
    try T.expectEqual(svc.ManagementPolicy.read_only, runtime.management_policy);
    try T.expectEqual(svc.ManagementPolicy.read_only, runtime.controller.manager.policy);
    try T.expectEqual(svc.ManagementPolicy.read_only, runtime.backend.?.management_policy);
    const binding = runtime.consoleBinding();
    const table = try binding.borrow(console.Interface, console.key, owner);
    try T.expectEqual(svc.Reason.permission_denied, table.request_management.?(binding.context, binding, request.value).rejected);
    const power_binding = runtime.powerBinding();
    const power_table = try power_binding.borrow(svc.PowerService, svc.power_key, owner);
    try T.expectEqual(svc.Reason.permission_denied, power_table.request(power_binding.context, request.value.power).rejected);
    try T.expectEqual(svc.Reason.permission_denied, runtime.controller.manager.approve(request.value).rejected);
    try T.expectError(error.PermissionDenied, runtime.controller.manager.engine.approveUserRequest(@splat(1)));
    try T.expectError(error.PermissionDenied, runtime.controller.manager.engine.requestPower(request.value.power, runtime_api.monotonicMs()));
    const driver = runtime.backend.?.driver();
    for ([_]management.power.Method{ .post, .patch }) |method| try T.expectError(error.ManagementReadOnly, driver.management_io.?(driver.context, .{ .sequence = 1, .operation = request.value.execution().operation, .purpose = .write, .method = method, .uri = request.value.execution().system_uri, .body = "{}" }));
    try T.expectEqual(@as(usize, 0), h.backend.writes);
    try T.expectEqual(@as(usize, 0), h.host.records.items.len);
    try h.finish();
}

test "BMC production management cancelled approval and stale owner cannot create native write work" {
    const h = try Harness.init("mapped-read", .user_approved);
    defer h.destroy();
    var request = try h.power(.graceful_shutdown, 104);
    defer request.deinit();
    try h.submit(request.value);
    try h.answer(request.value, false);
    var result = try h.terminal(request.value);
    defer result.deinit();
    try T.expectEqual(svc.Phase.cancelled_unsent, result.value.phase);
    var stale = request.value;
    stale.power.execution.call.owner = try owner.nextGeneration();
    const binding = h.runtime.?.consoleBinding();
    const table = try binding.borrow(console.Interface, console.key, owner);
    try T.expectEqual(svc.Reason.stale_binding, table.request_management.?(binding.context, binding, stale).rejected);
    var next = try h.power(.graceful_shutdown, 105);
    defer next.deinit();
    try h.submit(next.value);
    const power_binding = h.runtime.?.powerBinding();
    const power_table = try power_binding.borrow(svc.PowerService, svc.power_key, owner);
    try T.expectEqual(svc.CancelResult.cancelled_unsent, power_table.cancel(power_binding.context, next.value.execution().call, next.value.execution().operation));
    try T.expectEqual(@as(usize, 0), h.host.records.items.len);
    var invalid = request.value;
    invalid.power.execution.nonce = @splat(0);
    try T.expectEqual(svc.Reason.stale_binding, table.request_management.?(binding.context, binding, invalid).rejected);
    invalid = request.value;
    invalid.power.execution.call.binding_generation += 1;
    try T.expectEqual(svc.Reason.stale_binding, table.request_management.?(binding.context, binding, invalid).rejected);
    invalid = request.value;
    invalid.power.execution.system_uri = "/redfish/v1/Systems/foreign";
    try T.expectEqual(svc.Reason.stale_binding, table.request_management.?(binding.context, binding, invalid).rejected);
    inline for (.{ "capability_revision", "grant_revision" }) |field| {
        invalid = request.value;
        @field(invalid.power.execution, field) += 1;
        try T.expectEqual(svc.Reason.stale_capability, table.request_management.?(binding.context, binding, invalid).rejected);
    }
    try T.expectEqual(@as(usize, 0), h.backend.writes);
    try h.finish();
}

test "BMC production management cancel after native dispatch preserves unknown and GET-only query resolves power" {
    const h = try Harness.init("production-hold", .user_approved);
    defer h.destroy();
    var request = try h.power(.force_off, 106);
    defer request.deinit();
    try h.submit(request.value);
    try h.answer(request.value, true);
    const deadline = runtime_api.monotonicMs() + 5000;
    while (true) {
        _ = try h.runtime.?.poll();
        var result = try h.result(request.value);
        defer result.deinit();
        if (result.value.dispatched) break;
        if (runtime_api.monotonicMs() >= deadline) return error.ProductionDispatchTimeout;
        pause();
    }
    const binding = h.runtime.?.powerBinding();
    const table = try binding.borrow(svc.PowerService, svc.power_key, owner);
    try T.expectEqual(svc.CancelResult.observation_stopped_remote_may_continue, table.cancel(binding.context, request.value.execution().call, request.value.execution().operation));
    var cancelled = try h.terminal(request.value);
    defer cancelled.deinit();
    try T.expectEqual(svc.Phase.outcome_unknown, cancelled.value.phase);
    try T.expectEqual(svc.Reason.cancelled, cancelled.value.reason.?);
    try table.query.?(binding.context, request.value.execution().call, request.value.execution().operation);
    try T.expectError(error.ManagementBusy, table.query.?(binding.context, request.value.execution().call, request.value.execution().operation));
    // The query waits for the exact late response to drain; it cannot consume
    // that response as its own or send a second POST.
    const query_deadline = runtime_api.monotonicMs() + 5000;
    while (true) {
        _ = try h.runtime.?.poll();
        var current = try h.result(request.value);
        defer current.deinit();
        if (current.value.phase == .succeeded) {
            try T.expectEqual(svc.PowerState.off, current.value.current_power.?);
            break;
        }
        if (runtime_api.monotonicMs() >= query_deadline) return error.ProductionQueryTimeout;
        pause();
    }
    try h.finish();
    try T.expectEqual(@as(usize, 1), h.journal.entries.len);
}

test "BMC production management Success and On cannot prove native restart complete even after explicit query" {
    const h = try Harness.init("production-restart", .user_approved);
    defer h.destroy();
    var request = try h.power(.graceful_restart, 107);
    defer request.deinit();
    try h.submit(request.value);
    try h.answer(request.value, true);
    var result = try h.terminal(request.value);
    defer result.deinit();
    try T.expectEqual(svc.Phase.outcome_unknown, result.value.phase);
    try T.expectEqual(svc.Reason.accepted_unverified, result.value.reason.?);
    const binding = h.runtime.?.powerBinding();
    const table = try binding.borrow(svc.PowerService, svc.power_key, owner);
    try table.query.?(binding.context, request.value.execution().call, request.value.execution().operation);
    const deadline = runtime_api.monotonicMs() + 1500;
    while (runtime_api.monotonicMs() < deadline) {
        _ = try h.runtime.?.poll();
        pause();
    }
    var queried = try h.result(request.value);
    defer queried.deinit();
    try T.expectEqual(svc.Phase.outcome_unknown, queried.value.phase);
    try T.expectEqual(svc.Reason.accepted_unverified, queried.value.reason.?);
    try h.finish();
}

test "BMC production management native restart requires valid LastResetTime advancement and GET query uses frozen baseline" {
    for ([_][]const u8{ "production-restart-advanced", "production-restart-missing", "production-restart-invalid", "production-restart-query" }) |mode| {
        const h = try Harness.init(mode, .user_approved);
        defer h.destroy();
        var request = try h.power(.graceful_restart, 110);
        defer request.deinit();
        try h.submit(request.value);
        try h.answer(request.value, true);
        var result = try h.terminal(request.value);
        defer result.deinit();
        const advanced = std.mem.endsWith(u8, mode, "-advanced");
        try T.expectEqual(if (advanced) svc.Phase.succeeded else svc.Phase.outcome_unknown, result.value.phase);
        try T.expectEqual(svc.PowerState.on, result.value.current_power.?);
        var persisted = (try h.journal.snapshotOperation(a, request.value.execution().operation)).?;
        defer persisted.deinit();
        try T.expectEqualStrings("2026-10-31T01:00:00Z", persisted.entry.value.baseline.last_reset_time.?);
        if (std.mem.endsWith(u8, mode, "-query")) {
            const binding = h.runtime.?.powerBinding();
            const table = try binding.borrow(svc.PowerService, svc.power_key, owner);
            try table.query.?(binding.context, request.value.execution().call, request.value.execution().operation);
            const deadline = runtime_api.monotonicMs() + 5000;
            while (true) {
                _ = try h.runtime.?.poll();
                var queried = try h.result(request.value);
                defer queried.deinit();
                if (queried.value.phase == .succeeded) break;
                if (runtime_api.monotonicMs() >= deadline) return error.RestartQueryTimeout;
                pause();
            }
        } else if (!advanced) try T.expectEqual(svc.Reason.accepted_unverified, result.value.reason.?);
        try h.finish();
        try T.expectEqual(@as(usize, 1), h.journal.entries.len);
    }
}

test "BMC production management LastResetTime parser compares actual offsets fractions and rejects impossible or unknown dates" {
    try T.expectEqual(@as(?i64, 0), svc.lastResetTimeMillis("1970-01-01T00:00:00Z"));
    try T.expectEqual(@as(?i64, 0), svc.lastResetTimeMillis("1970-01-01T08:00:00+08:00"));
    try T.expectEqual(@as(?i64, -1000), svc.lastResetTimeMillis("1969-12-31T23:59:59Z"));
    try T.expect(!svc.lastResetTimeAdvanced("2026-01-01T00:00:00Z", "2026-01-01T08:00:00+08:00"));
    try T.expect(svc.lastResetTimeAdvanced("2026-01-01T00:00:00.000000001Z", "2026-01-01T00:00:00.000000002Z"));
    try T.expect(svc.lastResetTimeAdvanced("2024-02-29T23:59:59Z", "2024-03-01T00:00:00Z"));
    for ([_]?[]const u8{ null, "", "2026-02-30T01:00:00Z", "1900-02-29T00:00:00Z", "2026-13-01T00:00:00Z", "2026-01-01T24:00:00Z", "2026-01-01T00:00:00-00:00", "2026-01-01T00:00:00+15:00", "2026-01-01T00:00:60Z", "2026-01-01T00:00:00", "2026-01-01T00:00:00.Z", "2026-01-01T00:00:00.1234567890Z" }) |invalid| {
        try T.expectEqual(@as(?i64, null), svc.lastResetTimeMillis(invalid));
        try T.expect(!svc.lastResetTimeAdvanced("2026-01-01T00:00:00Z", invalid));
    }
}

test "BMC production management recovered restart query preserves LastResetTime and old journals without it remain unknown" {
    for ([_]bool{ false, true }) |legacy| {
        var backend: ledger.MemoryBackend = .{ .allocator = a };
        defer backend.deinit();
        const snapshots = memorySnapshots();
        const ex = execution(snapshots.p.capability, snapshots.p.system_uri, 111);
        {
            var journal = try ledger.Journal.init(a, backend.backend());
            defer journal.deinit();
            const reserved = try journal.reserve(ex, "https://127.0.0.1:443/redfish/v1/Systems/one", "memory-system", .{ .power = .graceful_restart }, .{ .power = .on });
            try journal.collectLastResetBaseline(reserved.index, "2026-10-31T01:00:00Z");
            try journal.beginDispatch(reserved.index);
            try T.expectError(error.OperationAlreadyDispatched, journal.collectLastResetBaseline(reserved.index, "2026-11-01T01:00:00Z"));
            try journal.setResult(reserved.index, .{ .operation = ex.operation, .phase = .outcome_unknown, .reason = .transport_lost, .dispatched = true });
        }
        if (legacy) {
            var parsed = try std.json.parseFromSlice(std.json.Value, a, backend.bytes.?, .{ .allocate = .alloc_always });
            defer parsed.deinit();
            const entries = parsed.value.object.getPtr("entries").?;
            const baseline = entries.array.items[0].object.getPtr("baseline").?;
            try T.expect(baseline.object.swapRemove("last_reset_time"));
            const old_bytes = backend.bytes.?;
            backend.bytes = try std.json.Stringify.valueAlloc(a, parsed.value, .{});
            a.free(old_bytes);
        }
        var recovered = try ledger.Journal.init(a, backend.backend());
        defer recovered.deinit();
        try T.expectEqual(legacy, recovered.entries[0].baseline.last_reset_time == null);
        var engine = try management.power.Engine.init(a, owner, .{ .authority = "127.0.0.1:443" }, &recovered, null);
        defer engine.deinit();
        try engine.setSnapshots(snapshots.p, snapshots.b);
        try engine.query(ex.operation, 0);
        const read_gate: management.power.Gate = .{ .owner = owner, .binding_generation = owner.generation, .capability_revision = 2, .grant_revision = 3, .authenticated = true, .write_granted = false };
        const work = (try engine.next(0, read_gate)).?;
        try T.expectEqual(management.power.Method.get, work.method);
        try engine.complete(.{ .sequence = work.sequence, .status = 200, .body = "{\"Id\":\"one\",\"UUID\":\"memory-system\",\"PowerState\":\"On\",\"LastResetTime\":\"2026-11-01T01:00:00Z\"}" }, 1);
        const result = try engine.result(ex.operation);
        try T.expectEqual(if (legacy) svc.Phase.outcome_unknown else svc.Phase.succeeded, result.phase);
        try T.expectEqual(@as(?management.power.Outbound, null), try engine.next(1000, read_gate));
        try T.expectError(error.OperationAlreadyDispatched, recovered.beginDispatch(0));
    }
}

fn memorySnapshots() struct { p: svc.PowerSnapshot, b: svc.BootSnapshot } {
    const evidence: svc.Evidence = .{ .source_uri = "/redfish/v1/Systems/one", .collected_ms = 1, .validity = .valid };
    const cap: svc.Capability = .{ .revision = 2, .grant_revision = 3, .binding_generation = owner.generation, .system_mapping_verified = true, .write_granted = true, .write_requestable = true, .secondary_auth = .disabled, .secondary_auth_evidence = evidence };
    return .{ .p = .{ .system_uri = evidence.source_uri, .system_identity = "memory-system", .capability = cap, .state = .{ .value = .on, .evidence = evidence }, .reset_types = .{ .value = &.{"ForceOff"}, .evidence = evidence }, .reset_target = "/redfish/v1/Systems/one/Actions/ComputerSystem.Reset", .etag = "\"one\"" }, .b = .{ .system_uri = evidence.source_uri, .system_identity = "memory-system", .capability = cap } };
}

test "BMC production management approved queue rejects changed capability grant nonce parameters and readonly backend flags" {
    inline for (.{ "revision", "grant_revision" }) |field| {
        var backend: ledger.MemoryBackend = .{ .allocator = a };
        defer backend.deinit();
        var journal = try ledger.Journal.init(a, backend.backend());
        defer journal.deinit();
        var arbiter = actions.Arbiter.init(a);
        defer arbiter.deinit();
        var adapter: management.Adapter = undefined;
        try adapter.initWithPolicy(a, owner, .{ .host = "127.0.0.1" }, &journal, arbiter.facade(owner), .user_approved);
        defer adapter.deinit();
        var snapshots = memorySnapshots();
        try adapter.setSnapshots(snapshots.p, snapshots.b, true);
        const request: svc.ManagementRequest = .{ .power = .{ .execution = execution(snapshots.p.capability, snapshots.p.system_uri, 108), .action = .force_off } };
        try T.expect(adapter.approve(request) == .accepted);
        @field(snapshots.p.capability, field) += 1;
        @field(snapshots.b.capability, field) += 1;
        try adapter.setSnapshots(snapshots.p, snapshots.b, true);
        try T.expectEqual(@as(?management.power.Outbound, null), try adapter.next(2));
        const binding = adapter.powerBinding();
        const table = try binding.borrow(svc.PowerService, svc.power_key, owner);
        var result = try table.result(binding.context, request.execution().call, request.execution().operation, a);
        defer result.deinit();
        try T.expectEqual(svc.Reason.stale_capability, result.value.reason.?);
        try T.expectEqual(@as(usize, 0), backend.writes);
    }
    var backend: ledger.MemoryBackend = .{ .allocator = a };
    defer backend.deinit();
    var journal = try ledger.Journal.init(a, backend.backend());
    defer journal.deinit();
    var engine = try management.power.Engine.init(a, owner, .{ .authority = "127.0.0.1:443" }, &journal, null);
    defer engine.deinit();
    const snapshots = memorySnapshots();
    try engine.setSnapshots(snapshots.p, snapshots.b);
    const request: svc.ManagementRequest = .{ .power = .{ .execution = execution(snapshots.p.capability, snapshots.p.system_uri, 109), .action = .force_off } };
    const hash = try svc.requestFingerprint(a, request, engine.origin.authority, snapshots.p.system_identity);
    try T.expectError(error.PermissionDenied, engine.approveUserRequest(hash));
    try T.expectError(error.PermissionDenied, engine.requestPower(request.power, 2));
    engine.policy = .user_approved;
    var altered = request;
    altered.power.execution.nonce[0] ^= 1;
    try engine.approveUserRequest(hash);
    try T.expectError(error.PermissionDenied, engine.requestPower(altered.power, 2));
    altered = request;
    altered.power.action = .power_cycle;
    try engine.approveUserRequest(hash);
    try T.expectError(error.PermissionDenied, engine.requestPower(altered.power, 2));
    try T.expectEqual(@as(usize, 0), backend.writes);
}
