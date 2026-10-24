const std = @import("std");
const ui = @import("ui");
const LocalTools = @import("ui/ai_local_tools.zig");
const Application = @import("ui/application_host.zig").ApplicationHost;
const Workspace = @import("ui/workspace.zig").Workspace;
const Config = @import("config/config.zig").Config;
const scope_mod = @import("ai/tool_scope.zig");
const Loop = @import("ai/tool_loop.zig");
const provider = @import("ai/provider.zig");
const clock = @import("platform/realtime.zig");
const a = std.testing.allocator;
extern "c" fn setenv([*:0]const u8, [*:0]const u8, c_int) c_int;
extern "c" fn unsetenv([*:0]const u8) c_int;
test {
    _ = @import("ui/ai_group_tools.zig");
    _ = @import("ai/group_context.zig");
    _ = @import("ui/ai_group_context.zig");
    _ = @import("ai/tool_results.zig");
    _ = @import("ai_tool_results_view_tests.zig");
}

const Fixture = struct {
    cx: *ui.Cx,
    scope: *ui.Scope,
    workspace: *Workspace,
    app: *Application,
    config: Config = .{},
    tmp: @TypeOf(std.testing.tmpDir(.{})),
    path: [:0]u8,
    directory: [:0]u8,
    previous_zdotdir: ?[:0]u8 = null,
    fn init(self: *Fixture) !void {
        return self.initWithFilePlugin(null);
    }
    fn initWithFilePlugin(self: *Fixture, file_plugin: ?@import("ui/application_host.zig").FilePlugin) !void {
        self.* = .{ .cx = try ui.Cx.init(a, std.testing.io), .scope = undefined, .workspace = undefined, .app = undefined, .tmp = std.testing.tmpDir(.{}), .path = undefined, .directory = undefined };
        self.cx.setViewport(1100, 720);
        self.cx.root = try ui.box(self.cx, .{ .width = .fill(), .height = .fill(), .direction = .column }, .{});
        self.scope = try ui.Scope.init(a, null, self.cx.owner);
        var nodes: [4]*ui.Node = undefined;
        for (&nodes) |*node| {
            node.* = try ui.box(self.cx, .{ .width = .fill(), .height = .{ .px = 100 } }, .{});
            try self.cx.root.?.appendChild(a, node.*);
        }
        try self.tmp.dir.writeFile(std.testing.io, .{ .sub_path = "hosts.toml", .data = "" });
        try self.tmp.dir.writeFile(std.testing.io, .{ .sub_path = "probe.txt", .data = "LOCAL_AI_TOOL_OK" });
        self.path = try self.tmp.dir.realPathFileAlloc(std.testing.io, "hosts.toml", a);
        self.directory = try self.tmp.dir.realPathFileAlloc(std.testing.io, ".", a);
        // Both the interactive PTY and exec children must use fixture-owned
        // shell startup, rather than inherit the user's login configuration.
        try self.tmp.dir.writeFile(std.testing.io, .{ .sub_path = ".zshenv", .data = "setopt NO_RCS\nPROMPT=''\nRPROMPT=''\n" });
        self.previous_zdotdir = if (std.c.getenv("ZDOTDIR")) |value| try a.dupeSentinel(u8, std.mem.span(value), 0) else null;
        if (setenv("ZDOTDIR", self.directory.ptr, 1) != 0) {
            if (self.previous_zdotdir) |value| a.free(value);
            return error.EnvironmentFailed;
        }
        errdefer self.restoreShellEnvironment();
        self.workspace = try Workspace.init(a, self.cx, self.scope, std.testing.io, &self.config, self.path, nodes[0], nodes[1], nodes[2], nodes[3]);
        self.app = if (file_plugin) |plugin| try Application.initWithFilePlugin(a, self.workspace, plugin) else try Application.init(a, self.workspace);
        try self.scope.onCleanup(Application, self.app, Application.deinit);
        self.app.install();
    }
    fn tick(self: *Fixture, bridge: ?*LocalTools.Bridge) !void {
        _ = try self.app.safeTick();
        if (bridge) |value| value.pump(self.app);
        self.cx.advanceFrameClock();
        self.cx.layout();
        _ = self.cx.render();
        var unused: [1]std.c.pollfd = undefined;
        _ = std.c.poll(&unused, 0, 2);
    }
    fn prepare(self: *Fixture, bridge: *LocalTools.Bridge) !@import("host/identity.zig").SessionHandle {
        const created = try self.app.createLocal(self.directory);
        const deadline = clock.monotonicNs() + 5 * std.time.ns_per_s;
        while (clock.monotonicNs() < deadline) {
            try self.tick(null);
            if (bridge.prepare(self.app, created.handle)) |_| return created.handle else |err| switch (err) {
                error.ServiceUnavailable, error.WorkerBusy, error.StaleSession => {},
                else => return err,
            }
        }
        return error.LocalServiceNotReady;
    }
    fn deinit(self: *Fixture) void {
        var ids: [16]u64 = undefined;
        const count = @min(ids.len, self.workspace.tabs.items.len);
        for (self.workspace.tabs.items[0..count], ids[0..count]) |tab, *id| id.* = tab.id;
        for (ids[0..count]) |id| _ = self.app.requestCloseLegacy(id) catch |err| std.debug.panic("Local AI fixture close request failed: {s}", .{@errorName(err)});
        const deadline = clock.monotonicNs() + 8 * std.time.ns_per_s;
        // Content can detach one controller tick before the original Local
        // worker joins. Drain its real receipt before disposing this fixture.
        while (self.workspace.tabs.items.len != 0 or self.app.local_adapter.shutdownStep() != .released) {
            self.tick(null) catch |err| std.debug.panic("Local AI fixture cleanup tick failed: {s}", .{@errorName(err)});
            if (clock.monotonicNs() >= deadline) @panic("Local AI fixture did not release its real sessions");
        }
        self.cx.clearFocus();
        self.scope.dispose();
        self.cx.deinit();
        self.restoreShellEnvironment();
        a.free(self.directory);
        a.free(self.path);
        self.tmp.cleanup();
    }
    fn restoreShellEnvironment(self: *Fixture) void {
        if (self.previous_zdotdir) |value| {
            if (setenv("ZDOTDIR", value.ptr, 1) != 0) @panic("Local AI fixture could not restore ZDOTDIR");
            a.free(value);
        } else if (unsetenv("ZDOTDIR") != 0) @panic("Local AI fixture could not restore ZDOTDIR");
    }
};
const Worker = struct {
    host: Loop.Host,
    invocation: Loop.Invocation,
    token: provider.CancelToken = .{},
    done: std.atomic.Value(bool) = .init(false),
    outcome: ?Loop.Outcome = null,
    failure: ?anyerror = null,
    fn run(self: *Worker) void {
        self.outcome = self.host.execute(self.host.context, self.invocation, a, &self.token) catch |err| blk: {
            self.failure = err;
            break :blk null;
        };
        self.done.store(true, .release);
    }
    fn finish(self: *Worker, bridge: *LocalTools.Bridge, app: *Application, thread: std.Thread) void {
        bridge.shutdown(app);
        thread.join();
        if (self.outcome) |*outcome| outcome.deinit(a);
    }
};
fn invocation(id: u64, command: []const u8, verdict: @import("ai/permission.zig").Verdict) Loop.Invocation {
    var hash: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(command, &hash, .{});
    return .{ .key = .{ .owner = .{ .session = id }, .turn_id = 1, .call_id = "local-call-1" }, .scope = .{ .owner = .{ .session = id }, .members = .{ .ids = .{id} ++ @as([15]u64, @splat(0)), .len = 1 } }, .round_index = 0, .call_index = 0, .arguments = command, .arguments_hash = hash, .call = .{ .tool = .run_command, .command = command, .targets = .{ .ids = .{id} ++ @as([15]u64, @splat(0)), .len = 1 } }, .verdict = verdict, .policy_revision = 1, .timeout_ms = 5000 };
}
fn awaitResult(f: *Fixture, bridge: *LocalTools.Bridge, worker: *Worker) !void {
    const deadline = clock.monotonicNs() + 6 * std.time.ns_per_s;
    while (!worker.done.load(.acquire) and clock.monotonicNs() < deadline) try f.tick(bridge);
    try std.testing.expect(worker.done.load(.acquire));
    if (worker.failure) |err| return err;
}

test "Local AI bridge executes in the captured cwd and returns actual output without using the interactive PTY" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    var bridge = LocalTools.Bridge.init(a);
    defer bridge.deinit();
    const owner = try f.prepare(&bridge);
    var worker: Worker = .{ .host = bridge.interface(), .invocation = invocation(@backingInt(owner.session_id), "cat probe.txt", .allow_auto) };
    const thread = try std.Thread.spawn(.{}, Worker.run, .{&worker});
    defer worker.finish(&bridge, f.app, thread);
    try awaitResult(&f, &bridge, &worker);
    const result = worker.outcome.?.targets[0];
    try std.testing.expectEqual(Loop.Status.succeeded, result.status);
    try std.testing.expectEqualStrings("LOCAL_AI_TOOL_OK", result.stdout);
    try std.testing.expectEqualStrings(f.directory, result.cwd.?);
    try std.testing.expectEqual(@as(?i32, 0), result.exit);
    try std.testing.expect(result.local_released);
    const binding = switch (f.app.sessions.queryService(owner, .terminal)) {
        .available => |value| value,
        else => return error.TerminalNotReady,
    };
    const service = try f.app.local_adapter.terminalService(binding);
    var lines = try service.readLines(.{ .max_lines = 100, .max_bytes = 4096 }, a);
    defer lines.deinit(a);
    for (lines.lines) |line| try std.testing.expect(std.mem.indexOf(u8, line, "LOCAL_AI_TOOL_OK") == null);
}

test "Local AI bridge approval is bound to the exact call and rejection starts no child" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    var bridge = LocalTools.Bridge.init(a);
    defer bridge.deinit();
    const owner = try f.prepare(&bridge);
    var worker: Worker = .{ .host = bridge.interface(), .invocation = invocation(@backingInt(owner.session_id), "printf REJECTED", .need_confirm) };
    const thread = try std.Thread.spawn(.{}, Worker.run, .{&worker});
    defer worker.finish(&bridge, f.app, thread);
    const deadline = clock.monotonicNs() + 3 * std.time.ns_per_s;
    while (bridge.pendingApproval() == null and clock.monotonicNs() < deadline) try f.tick(&bridge);
    const approval = bridge.pendingApproval() orelse return error.ApprovalMissing;
    try std.testing.expect(bridge.active == null);
    var changed = approval.arguments_hash;
    changed[0] ^= 1;
    try std.testing.expectError(error.StaleApproval, bridge.decide(approval.sequence, changed, true));
    try bridge.decide(approval.sequence, approval.arguments_hash, false);
    try awaitResult(&f, &bridge, &worker);
    try std.testing.expectEqual(Loop.Status.rejected, worker.outcome.?.targets[0].status);
    try std.testing.expectEqualStrings("ToolApprovalRejected", worker.outcome.?.targets[0].error_code.?);
    try std.testing.expect(bridge.active == null);
}

test "Local AI bridge cancellation waits for actual child release" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    var bridge = LocalTools.Bridge.init(a);
    defer bridge.deinit();
    const owner = try f.prepare(&bridge);
    var worker: Worker = .{ .host = bridge.interface(), .invocation = invocation(@backingInt(owner.session_id), "sleep 10", .need_confirm) };
    const thread = try std.Thread.spawn(.{}, Worker.run, .{&worker});
    defer worker.finish(&bridge, f.app, thread);
    const deadline = clock.monotonicNs() + 3 * std.time.ns_per_s;
    while (bridge.pendingApproval() == null and clock.monotonicNs() < deadline) try f.tick(&bridge);
    const approval = bridge.pendingApproval() orelse return error.ApprovalMissing;
    try bridge.decide(approval.sequence, approval.arguments_hash, true);
    while (bridge.active == null and clock.monotonicNs() < deadline) try f.tick(&bridge);
    try std.testing.expect(bridge.active != null);
    worker.token.cancel();
    try awaitResult(&f, &bridge, &worker);
    try std.testing.expectEqual(Loop.Status.cancelled, worker.outcome.?.targets[0].status);
    try std.testing.expect(worker.outcome.?.targets[0].local_released);
    try std.testing.expect(bridge.active == null);
}

test "Local AI close gate ignores another generation and waits for the original process" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    var bridge = LocalTools.Bridge.init(a);
    defer bridge.deinit();
    const owner = try f.prepare(&bridge);
    var worker: Worker = .{ .host = bridge.interface(), .invocation = invocation(@backingInt(owner.session_id), "sleep 10", .allow_auto) };
    const thread = try std.Thread.spawn(.{}, Worker.run, .{&worker});
    defer worker.finish(&bridge, f.app, thread);
    const deadline = clock.monotonicNs() + 3 * std.time.ns_per_s;
    while (bridge.active == null and clock.monotonicNs() < deadline) try f.tick(&bridge);
    try std.testing.expect(bridge.active != null);
    try std.testing.expectEqual(@import("ui/application_host.zig").CloseReceipt.released, bridge.stopOwner(try owner.nextGeneration()));
    try std.testing.expect(bridge.active != null and !worker.done.load(.acquire));
    try std.testing.expectEqual(@import("ui/application_host.zig").CloseReceipt.awaiting, bridge.stopOwner(owner));
    try awaitResult(&f, &bridge, &worker);
    try std.testing.expectEqual(Loop.Status.cancelled, worker.outcome.?.targets[0].status);
    try std.testing.expect(worker.outcome.?.targets[0].local_released);
    try std.testing.expectEqual(@import("ui/application_host.zig").CloseReceipt.released, bridge.stopOwner(owner));
}

const GroupTools = @import("ui/ai_group_tools.zig");
fn groupInvocation(ids: []const u64, command: []const u8) !Loop.Invocation {
    const scope: scope_mod.Scope = .{ .owner = .{ .group = 1 }, .members = blk: {
        var targets: scope_mod.Targets = .{};
        for (ids, 0..) |id, index| targets.ids[index] = id;
        targets.len = ids.len;
        break :blk targets;
    } };
    var value = invocation(ids[0], command, .need_confirm);
    value.key.owner = scope.owner;
    value.scope = scope;
    value.call.targets = try scope.validate(ids);
    return value;
}
fn tickGroup(f: *Fixture, bridge: *GroupTools.Bridge) !void {
    try f.tick(null);
    bridge.pump(f.app);
}
fn awaitGroup(f: *Fixture, bridge: *GroupTools.Bridge, worker: *Worker) !void {
    const deadline = clock.monotonicNs() + 8 * std.time.ns_per_s;
    while (!worker.done.load(.acquire) and clock.monotonicNs() < deadline) try tickGroup(f, bridge);
    try std.testing.expect(worker.done.load(.acquire));
    if (worker.failure) |err| return err;
}
fn prepareSecond(f: *Fixture, cwd: []const u8) !@import("host/identity.zig").SessionHandle {
    const created = try f.app.createLocal(cwd);
    var probe = LocalTools.Bridge.init(a);
    defer probe.deinit();
    const deadline = clock.monotonicNs() + 5 * std.time.ns_per_s;
    while (clock.monotonicNs() < deadline) {
        try f.tick(null);
        if (probe.prepare(f.app, created.handle)) |_| return created.handle else |_| {}
    }
    return error.LocalServiceNotReady;
}

test "real group Local tools freeze both original sessions, approve once, preserve mixed outcomes and pin only ordering" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    var probe = LocalTools.Bridge.init(a);
    defer probe.deinit();
    const first = try f.prepare(&probe);
    const second = try prepareSecond(&f, "/tmp");
    var roster = @import("ui/group_model.zig").Roster.init(a);
    defer roster.deinit();
    const pane1 = f.app.legacyForHandle(first).?;
    const pane2 = f.app.legacyForHandle(second).?;
    _ = try roster.join("group", pane1, 0);
    _ = try roster.join("group", pane2, 0);
    var bridge = GroupTools.Bridge.init(a);
    defer bridge.deinit();
    const ids = [_]u64{ @backingInt(first.session_id), @backingInt(second.session_id) };
    const call = try groupInvocation(&ids, "if test -f probe.txt; then printf GROUP_FIRST_OK; else printf GROUP_SECOND_FAILURE; exit 7; fi");
    try bridge.prepare(f.app, &roster, call.scope);
    var whole_context = try @import("ui/ai_group_context.zig").assemble(a, f.app, &roster, call.scope, 8192, false);
    defer whole_context.deinit(a);
    for ([_]@import("host/identity.zig").SessionHandle{ first, second }) |owner| {
        const marker = try std.fmt.allocPrint(a, "session_id={d} generation={d} transport=plugin available=yes ", .{ @backingInt(owner.session_id), owner.generation });
        defer a.free(marker);
        const start = std.mem.indexOf(u8, whole_context.text, marker) orelse return error.OriginalMemberContextMissing;
        const remainder = whole_context.text[start + marker.len ..];
        const end = std.mem.indexOf(u8, remainder, "\nsession_id=") orelse remainder.len;
        // The outer group envelope is generic. The owning Local adapter
        // supplies this exact canonical identity inside each member snapshot.
        try std.testing.expect(std.mem.indexOf(u8, remainder[0..end], "\nhost=本机 · zsh user= hops=0") != null);
    }
    try std.testing.expectEqualSlices(u64, &ids, bridge.toolIds(.run_command).slice());
    try std.testing.expectEqual(@as(usize, 0), bridge.toolIds(.read_remote_file).len);
    var worker: Worker = .{ .host = bridge.interface(), .invocation = call };
    const thread = try std.Thread.spawn(.{}, Worker.run, .{&worker});
    defer {
        bridge.shutdown(f.app);
        thread.join();
        if (worker.outcome) |*outcome| outcome.deinit(a);
    }
    const deadline = clock.monotonicNs() + 3 * std.time.ns_per_s;
    while (bridge.pendingApproval() == null and clock.monotonicNs() < deadline) try tickGroup(&f, &bridge);
    const approval = bridge.pendingApproval() orelse return error.ApprovalMissing;
    try std.testing.expect(approval.group);
    const pending_impact = bridge.closeImpact(first);
    try std.testing.expect(pending_impact.ai != 0);
    try std.testing.expect(std.mem.indexOf(u8, pending_impact.detailText(), "待批准 1") != null);
    try std.testing.expect(std.mem.indexOf(u8, approval.target, "generation") != null);
    try std.testing.expect(!worker.done.load(.acquire));
    try roster.pin("group", pane2);
    try bridge.decide(approval.sequence, approval.arguments_hash, true);
    try std.testing.expect(pending_impact.ai != bridge.closeImpact(first).ai);
    try awaitGroup(&f, &bridge, &worker);
    try std.testing.expectEqual(@as(u64, 0), bridge.closeImpact(first).ai);
    try std.testing.expectEqual(@as(usize, 2), worker.outcome.?.targets.len);
    try std.testing.expectEqual(Loop.Status.succeeded, worker.outcome.?.targets[0].status);
    try std.testing.expectEqualStrings("GROUP_FIRST_OK", worker.outcome.?.targets[0].stdout);
    try std.testing.expectEqual(Loop.Status.failed, worker.outcome.?.targets[1].status);
    try std.testing.expectEqual(@as(?i32, 7), worker.outcome.?.targets[1].exit);
    try std.testing.expectEqualStrings("GROUP_SECOND_FAILURE", worker.outcome.?.targets[1].stdout);
    try std.testing.expect(worker.outcome.?.targets[0].local_released and worker.outcome.?.targets[1].local_released);
}

test "AI shared history survives source Bridge disposal with concurrent owned snapshots and fresh live-owner reads" {
    const Dynamic = @import("ui/ai_tools.zig");
    const tools = @import("ai/plugin_tools.zig");
    const Writer = struct {
        bridge: *Dynamic.Bridge,
        owner: @import("host/identity.zig").SessionHandle,
        base: u64,
        label: []const u8,
        start: *std.atomic.Value(bool),
        reads: *std.atomic.Value(usize),
        done: *std.atomic.Value(usize),
        failure: ?anyerror = null,
        fn run(self: *@This()) void {
            self.write() catch |err| {
                self.failure = err;
            };
            _ = self.done.fetchAdd(1, .release);
        }
        fn write(self: *@This()) !void {
            while (!self.start.load(.acquire)) std.atomic.spinLoopHint();
            for (0..16) |index| {
                const history = self.bridge.operationHistory();
                const id = self.base + index;
                _ = try history.beginNew(self.owner, id, "fixture.read", @splat(0), 1);
                try history.markSent(self.owner, id);
                try history.finish(self.owner, id, true, self.label);
                try history.resourcesReleased(self.owner, id);
                try history.transition(self.owner, 9001, .verifying, self.label);
                while (self.reads.load(.acquire) <= index) std.atomic.spinLoopHint();
            }
        }
    };
    const Reader = struct {
        host: Loop.Host,
        invocation: tools.DynamicInvocation,
        cancel: provider.CancelToken = .{},
        done: std.atomic.Value(bool) = .init(false),
        results: ?[]tools.ToolResult = null,
        failure: ?anyerror = null,
        fn run(self: *@This()) void {
            self.results = self.host.execute_dynamic.?(self.host.context, self.invocation, a, &self.cancel) catch |err| blk: {
                self.failure = err;
                break :blk null;
            };
            self.done.store(true, .release);
        }
    };
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    var probe = LocalTools.Bridge.init(a);
    defer probe.deinit();
    const owner = try f.prepare(&probe);
    var old = Dynamic.Bridge.init(a);
    var old_alive = true;
    defer if (old_alive) old.deinit();
    try old.prepare(f.app, owner);
    var next = Dynamic.Bridge.init(a);
    defer next.deinit();
    try next.prepare(f.app, owner);
    try std.testing.expect(old.operationHistory() == &f.app.domain.operation_history);
    try std.testing.expect(next.operationHistory() == old.operationHistory());
    const history = old.operationHistory();
    _ = try history.beginNew(owner, 9001, "fixture.write", @splat(0), 1);
    try history.markSent(owner, 9001);
    try history.transition(owner, 9001, .verifying, "seed result");
    var retained = (try old.queryOperation(a, owner, 9001)).?;
    defer retained.deinit();
    var start: std.atomic.Value(bool) = .init(false);
    var reads: std.atomic.Value(usize) = .init(0);
    var done: std.atomic.Value(usize) = .init(0);
    var first_writer: Writer = .{ .bridge = &old, .owner = owner, .base = 100, .label = "source result", .start = &start, .reads = &reads, .done = &done };
    var next_writer: Writer = .{ .bridge = &next, .owner = owner, .base = 200, .label = "destination result", .start = &start, .reads = &reads, .done = &done };
    const one = try std.Thread.spawn(.{}, Writer.run, .{&first_writer});
    var one_joined = false;
    defer if (!one_joined) {
        start.store(true, .release);
        reads.store(std.math.maxInt(usize), .release);
        one.join();
    };
    const two = try std.Thread.spawn(.{}, Writer.run, .{&next_writer});
    var two_joined = false;
    defer if (!two_joined) {
        start.store(true, .release);
        reads.store(std.math.maxInt(usize), .release);
        two.join();
    };
    start.store(true, .release);
    while (done.load(.acquire) < 2) {
        if (try next.queryOperation(a, owner, 9001)) |snapshot| {
            var owned = snapshot;
            try std.testing.expect(owned.value.stage == .verifying);
            try std.testing.expect(std.mem.eql(u8, owned.value.result_text, "seed result") or std.mem.eql(u8, owned.value.result_text, "source result") or std.mem.eql(u8, owned.value.result_text, "destination result"));
            owned.deinit();
        }
        _ = reads.fetchAdd(1, .release);
    }
    one.join();
    one_joined = true;
    two.join();
    two_joined = true;
    if (first_writer.failure) |err| return err;
    if (next_writer.failure) |err| return err;
    try std.testing.expectEqual(@as(usize, 33), history.count());
    try std.testing.expect(reads.load(.acquire) >= 16);
    try std.testing.expectEqualStrings("seed result", retained.value.result_text);
    try history.transition(owner, 9001, .outcome_unknown, "response lost");
    try history.resourcesReleased(owner, 9001);
    var old_table = try tools.cloneTable(old.requestTable().?, a);
    defer old_table.deinit();
    const arguments = try std.fmt.allocPrint(a, "{{\"session_ids\":[{d}]}}", .{@backingInt(owner.session_id)});
    defer a.free(arguments);
    var old_call = try old_table.parse(a, "read_terminal", arguments);
    defer old_call.deinit();
    old.shutdown(f.app);
    old.deinit();
    old_alive = false;
    var unknown = (try next.queryOperation(a, owner, 9001)).?;
    defer unknown.deinit();
    try std.testing.expectEqual(@import("host/operation_store.zig").Stage.outcome_unknown, unknown.value.stage);
    try std.testing.expectEqualStrings("response lost", unknown.value.result_text);
    try std.testing.expect(!unknown.value.owner_closed);
    var completed = (try next.queryOperation(a, owner, 100)).?;
    defer completed.deinit();
    try std.testing.expectEqualStrings("source result", completed.value.result_text);
    const host = next.interface();
    const stale: tools.DynamicInvocation = .{ .table = &old_table, .parsed = old_call, .turn_id = 1, .call_id = "old-binding", .arguments = arguments, .operation_id = 9100 };
    try std.testing.expectError(error.StaleToolAuthority, host.execute_dynamic.?(host.context, stale, a, null));
    var call = try next.requestTable().?.parse(a, "read_terminal", arguments);
    defer call.deinit();
    var fresh: tools.DynamicInvocation = .{ .table = next.requestTable().?, .parsed = call, .turn_id = 2, .call_id = "new-read", .arguments = arguments, .operation_id = 9001 };
    try std.testing.expectError(error.ToolOperationAlreadyRecorded, host.execute_dynamic.?(host.context, fresh, a, null));
    fresh.operation_id = 9200;
    var reader: Reader = .{ .host = host, .invocation = fresh };
    const thread = try std.Thread.spawn(.{}, Reader.run, .{&reader});
    defer {
        reader.cancel.cancel();
        next.shutdown(f.app);
        thread.join();
        if (reader.results) |results| {
            for (results) |*result| result.deinit(a);
            a.free(results);
        }
    }
    const deadline = clock.monotonicNs() + 5 * std.time.ns_per_s;
    while (!reader.done.load(.acquire) and clock.monotonicNs() < deadline) {
        try f.tick(null);
        next.pump(f.app);
    }
    try std.testing.expect(reader.done.load(.acquire));
    if (reader.failure) |err| return err;
    try std.testing.expectEqual(tools.Status.succeeded, reader.results.?[0].status);
    try std.testing.expectEqual(@import("host/operation_store.zig").Stage.succeeded, history.lookup(owner, 9200).?.stage);
    try std.testing.expect(!history.lookup(owner, 9200).?.owner_closed);
    try std.testing.expectEqual(@import("host/operation_store.zig").Stage.outcome_unknown, history.lookup(owner, 9001).?.stage);
}

test "SFTP AI registration prepares only file tools and rejects terminal or revoked source bindings" {
    const sessions = @import("host/session_host.zig");
    const plugins = @import("host/plugin_registry.zig");
    const FileBridge = @import("ui/ai_file_tools.zig");
    const FileHost = @import("ui/file_application_host.zig").Host;
    const Dynamic = @import("ui/ai_tools.zig");
    // Controlled adapter-boundary ready services, no remote network success is
    // claimed. Catalog/preparation/preflight use the actual production classes.
    const Adapter = struct {
        fn create(_: *anyopaque, _: sessions.CreateRequest) !void {}
        fn cancel(_: *anyopaque, _: sessions.OperationKey) sessions.CloseReceipt {
            return .released;
        }
        fn close(_: *anyopaque, _: sessions.SessionHandle, _: sessions.OperationKey) !sessions.CloseReceipt {
            return .released;
        }
        fn stale(_: *anyopaque, _: sessions.SessionHandle, _: sessions.OperationKey) void {}
        fn tick(_: *anyopaque, _: *sessions.SessionHost) !bool {
            return false;
        }
        fn shutdown(_: *anyopaque) sessions.CloseReceipt {
            return .released;
        }
    };
    var adapter: Adapter = .{};
    var f: Fixture = undefined;
    try f.initWithFilePlugin(.{ .adapter = .{ .registration = .{ .plugin_id = .sftp, .workspace_kind = .file, .services = plugins.requiredServices(.sftp) }, .context = &adapter, .vtable = &.{ .create = Adapter.create, .cancel = Adapter.cancel, .close = Adapter.close, .release_stale = Adapter.stale } }, .context = &adapter, .tick = Adapter.tick, .shutdown = Adapter.shutdown });
    defer f.deinit();
    const accepted = try f.app.create(.{ .connection_id = @fromBackingInt(888), .revision = 1, .protocol = .sftp, .name = "AI File Fixture", .host = "sftp-ai-fixture.invalid", .user = "fixture", .password = "fixture-only" }, 888, 0, "");
    const directory = try f.app.sessions.reserveService(accepted.handle, accepted.operation, .directory);
    const file_read = try f.app.sessions.reserveService(accepted.handle, accepted.operation, .file_read);
    _ = try f.app.sessions.reserveService(accepted.handle, accepted.operation, .transfer);
    try std.testing.expect(try f.app.sessions.ready(accepted.handle, accepted.operation, plugins.requiredServices(.sftp)));
    try std.testing.expect(f.app.sessions.bindingIsLive(directory) and f.app.sessions.bindingIsLive(file_read));
    const content_scope = try f.scope.childScope();
    const content = try ui.box(f.cx, .{ .width = .fill(), .height = .fill() }, .{});
    const attached = try f.app.attachFileSession(accepted.handle, accepted.operation, content, content_scope);
    try std.testing.expect(try f.app.sessions.attached(accepted.handle, attached));
    const manifest = f.app.sessions.manifestFor(accepted.handle).?;
    try std.testing.expect(manifest.integration.ai);
    try std.testing.expect(manifest.ai_context != null and manifest.ai_adapter_factory != null);
    try std.testing.expect(manifest.ai_adapter_factory.? == FileBridge.createAdapter);
    try std.testing.expectEqual(@as(usize, 2), manifest.tools.len);
    const file_host = try FileHost.create(a, f.workspace);
    defer {
        _ = file_host.shutdownStep();
        file_host.deinit() catch unreachable;
    }
    // This initialized provider only resolves the controlled session's existing
    // typed directory/file_read source. No reader/backend is invoked by this test.
    file_host.app = f.app;
    var bridge = Dynamic.Bridge.init(a);
    defer bridge.deinit();
    bridge.configureFiles(file_host);
    try bridge.prepare(f.app, accepted.handle);
    try std.testing.expectEqual(@as(usize, 2), bridge.requestTable().?.entries.len);
    try std.testing.expectEqualSlices(u64, &.{@backingInt(accepted.handle.session_id)}, bridge.toolIds(.list_remote_files).slice());
    try std.testing.expectEqual(@as(usize, 1), bridge.toolIds(.read_remote_file).len);
    try std.testing.expectEqual(@as(usize, 0), bridge.toolIds(.run_command).len);
    try std.testing.expectEqual(@as(usize, 0), bridge.toolIds(.read_terminal).len);
    var original = FileBridge.Bridge.init(a);
    defer original.deinit();
    original.files = file_host;
    try original.prepare(f.app, accepted.handle);
    var call = invocation(@backingInt(accepted.handle.session_id), "", .allow_auto);
    try std.testing.expectError(error.UnsupportedTool, original.preflight(f.app, call));
    call.call.tool = .read_terminal;
    try std.testing.expectError(error.UnsupportedTool, original.preflight(f.app, call));
    call.call.tool = .list_remote_files;
    call.call.path = "/";
    try original.preflight(f.app, call);
    call.call.tool = .read_remote_file;
    try original.preflight(f.app, call);
    var context = try @import("ui/ai_session_context.zig").assemble(a, f.app, accepted.handle, 8192, false);
    defer context.deinit(a);
    try std.testing.expect(std.mem.indexOf(u8, context.text, "Only directory and bounded text-file tools are available.") != null);
    const identity_line = try std.fmt.allocPrint(a, "provider={s} session_id={d} generation={d}\n", .{ manifest.display_name, @backingInt(accepted.handle.session_id), accepted.handle.generation });
    defer a.free(identity_line);
    try std.testing.expect(std.mem.startsWith(u8, context.text, identity_line));
    try std.testing.expect(f.app.sessions.queryService(accepted.handle, .exec) == .unsupported);
    try std.testing.expect(f.app.sessions.queryService(accepted.handle, .terminal) == .unsupported);
    try std.testing.expect(try f.app.sessions.revokeTypedService(accepted.handle, accepted.operation, .{ .name = "file_read" }));
    try std.testing.expectError(error.StaleBinding, original.preflight(f.app, call));
}

test "real group roster changes invalidate a pending approval and preflight stops every target" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    var probe = LocalTools.Bridge.init(a);
    defer probe.deinit();
    const first = try f.prepare(&probe);
    const second = try prepareSecond(&f, "/tmp");
    var roster = @import("ui/group_model.zig").Roster.init(a);
    defer roster.deinit();
    const pane1 = f.app.legacyForHandle(first).?;
    const pane2 = f.app.legacyForHandle(second).?;
    _ = try roster.join("group", pane1, 0);
    _ = try roster.join("group", pane2, 0);
    var bridge = GroupTools.Bridge.init(a);
    defer bridge.deinit();
    const ids = [_]u64{ @backingInt(first.session_id), @backingInt(second.session_id) };
    const call = try groupInvocation(&ids, "printf SHOULD_NEVER_EXECUTE");
    try bridge.prepare(f.app, &roster, call.scope);
    var worker: Worker = .{ .host = bridge.interface(), .invocation = call };
    const thread = try std.Thread.spawn(.{}, Worker.run, .{&worker});
    defer {
        bridge.shutdown(f.app);
        thread.join();
        if (worker.outcome) |*outcome| outcome.deinit(a);
    }
    const deadline = clock.monotonicNs() + 3 * std.time.ns_per_s;
    while (bridge.pendingApproval() == null and clock.monotonicNs() < deadline) try tickGroup(&f, &bridge);
    const approval = bridge.pendingApproval() orelse return error.ApprovalMissing;
    try roster.leave("group", pane2);
    try bridge.decide(approval.sequence, approval.arguments_hash, true);
    try awaitGroup(&f, &bridge, &worker);
    for (worker.outcome.?.targets) |target| {
        try std.testing.expectEqual(Loop.Status.rejected, target.status);
        try std.testing.expectEqualStrings("GroupMembershipChanged", target.error_code.?);
        try std.testing.expectEqualStrings("", target.stdout);
        try std.testing.expect(target.exit == null);
    }
    try std.testing.expect(bridge.pendingApproval() == null);
}

test "real group stop revokes pending approval and drains original exchange without dispatch" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    var probe = LocalTools.Bridge.init(a);
    defer probe.deinit();
    const first = try f.prepare(&probe);
    var roster = @import("ui/group_model.zig").Roster.init(a);
    defer roster.deinit();
    _ = try roster.join("group", f.app.legacyForHandle(first).?, 0);
    var bridge = GroupTools.Bridge.init(a);
    defer bridge.deinit();
    const call = try groupInvocation(&.{@backingInt(first.session_id)}, "printf NEVER_AFTER_GROUP_STOP");
    try bridge.prepare(f.app, &roster, call.scope);
    var worker: Worker = .{ .host = bridge.interface(), .invocation = call };
    const thread = try std.Thread.spawn(.{}, Worker.run, .{&worker});
    defer {
        bridge.shutdown(f.app);
        thread.join();
        if (worker.outcome) |*outcome| outcome.deinit(a);
    }
    const deadline = clock.monotonicNs() + 3 * std.time.ns_per_s;
    while (bridge.pendingApproval() == null and clock.monotonicNs() < deadline) try tickGroup(&f, &bridge);
    const approval = bridge.pendingApproval() orelse return error.ApprovalMissing;
    try std.testing.expectEqual(@import("host/session_host.zig").CloseReceipt.released, bridge.stopGroup(999));
    try std.testing.expectEqual(@import("host/session_host.zig").CloseReceipt.awaiting, bridge.stopGroup(1));
    try std.testing.expectError(error.StaleApproval, bridge.decide(approval.sequence, approval.arguments_hash, true));
    try awaitGroup(&f, &bridge, &worker);
    try std.testing.expectEqual(Loop.Status.cancelled, worker.outcome.?.targets[0].status);
    try std.testing.expect(!worker.outcome.?.targets[0].remote_effect_unknown);
    try std.testing.expect(worker.outcome.?.targets[0].exit == null);
    try std.testing.expectEqualStrings("", worker.outcome.?.targets[0].stdout);
    try std.testing.expectEqual(@import("host/session_host.zig").CloseReceipt.released, bridge.stopGroup(1));
    try std.testing.expectEqual(@as(u64, 0), bridge.closeImpact(first).ai);
}

test "real group newly joined member cannot inherit pending approval or frozen tool targets" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    var probe = LocalTools.Bridge.init(a);
    defer probe.deinit();
    const first = try f.prepare(&probe);
    const second = try prepareSecond(&f, "/tmp");
    var roster = @import("ui/group_model.zig").Roster.init(a);
    defer roster.deinit();
    _ = try roster.join("group", f.app.legacyForHandle(first).?, 0);
    var bridge = GroupTools.Bridge.init(a);
    defer bridge.deinit();
    const ids = [_]u64{@backingInt(first.session_id)};
    const call = try groupInvocation(&ids, "printf NEW_MEMBER_MUST_NOT_INHERIT");
    try bridge.prepare(f.app, &roster, call.scope);
    var worker: Worker = .{ .host = bridge.interface(), .invocation = call };
    const thread = try std.Thread.spawn(.{}, Worker.run, .{&worker});
    defer {
        bridge.shutdown(f.app);
        thread.join();
        if (worker.outcome) |*outcome| outcome.deinit(a);
    }
    const deadline = clock.monotonicNs() + 3 * std.time.ns_per_s;
    while (bridge.pendingApproval() == null and clock.monotonicNs() < deadline) try tickGroup(&f, &bridge);
    const approval = bridge.pendingApproval() orelse return error.ApprovalMissing;
    try std.testing.expect(bridge.writeRisk(first));
    try std.testing.expect(!bridge.writeRisk(second));
    _ = try roster.join("group", f.app.legacyForHandle(second).?, 0);
    try std.testing.expectEqualSlices(u64, &ids, bridge.toolIds(.run_command).slice());
    try bridge.decide(approval.sequence, approval.arguments_hash, true);
    try awaitGroup(&f, &bridge, &worker);
    try std.testing.expectEqual(@as(usize, 1), worker.outcome.?.targets.len);
    const result = worker.outcome.?.targets[0];
    try std.testing.expectEqual(Loop.Status.rejected, result.status);
    try std.testing.expectEqualStrings("GroupMembershipChanged", result.error_code.?);
    try std.testing.expectEqualStrings("", result.stdout);
    try std.testing.expect(result.exit == null and !result.remote_effect_unknown);
    try std.testing.expect(!bridge.writeRisk(first));
}

test "real group active child observes outer request stop while worker is blocked in execute" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    var probe = LocalTools.Bridge.init(a);
    defer probe.deinit();
    const first = try f.prepare(&probe);
    const second = try prepareSecond(&f, "/tmp");
    var roster = @import("ui/group_model.zig").Roster.init(a);
    defer roster.deinit();
    _ = try roster.join("group", f.app.legacyForHandle(first).?, 0);
    _ = try roster.join("group", f.app.legacyForHandle(second).?, 0);
    var bridge = GroupTools.Bridge.init(a);
    defer bridge.deinit();
    const ids = [_]u64{ @backingInt(first.session_id), @backingInt(second.session_id) };
    const call = try groupInvocation(&ids, "sleep 10; printf MUST_NOT_FINISH");
    try bridge.prepare(f.app, &roster, call.scope);
    var worker: Worker = .{ .host = bridge.interface(), .invocation = call };
    const thread = try std.Thread.spawn(.{}, Worker.run, .{&worker});
    defer {
        bridge.shutdown(f.app);
        thread.join();
        if (worker.outcome) |*outcome| outcome.deinit(a);
    }
    const deadline = clock.monotonicNs() + 3 * std.time.ns_per_s;
    while (bridge.pendingApproval() == null and clock.monotonicNs() < deadline) try tickGroup(&f, &bridge);
    const approval = bridge.pendingApproval() orelse return error.ApprovalMissing;
    try bridge.decide(approval.sequence, approval.arguments_hash, true);
    const first_child = bridge.children.items[0];
    while (clock.monotonicNs() < deadline) {
        const execution = first_child.bridge.vtable.impact(first_child.bridge.context, first);
        if (first_child.bridge.vtable.risk(first_child.bridge.context, first) and std.mem.indexOf(u8, execution.detailText(), "执行中 1") != null) break;
        try tickGroup(&f, &bridge);
    }
    try std.testing.expect(first_child.bridge.vtable.risk(first_child.bridge.context, first));
    const execution = first_child.bridge.vtable.impact(first_child.bridge.context, first);
    try std.testing.expect(std.mem.indexOf(u8, execution.detailText(), "执行中 1") != null);
    const started = clock.monotonicNs();
    worker.token.cancel();
    try awaitGroup(&f, &bridge, &worker);
    try std.testing.expect(clock.monotonicNs() - started < 5 * std.time.ns_per_s);
    for (worker.outcome.?.targets) |target| {
        try std.testing.expectEqual(Loop.Status.cancelled, target.status);
        try std.testing.expectEqualStrings("", target.stdout);
        try std.testing.expect(target.local_released and !target.remote_effect_unknown);
    }
    try std.testing.expect(!bridge.writeRisk(first));
    try std.testing.expect(!bridge.writeRisk(second));
}
