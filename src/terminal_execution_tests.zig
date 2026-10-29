//! Real production Local adapter execution. Disposable ZDOTDIR and recording
//! root; never reads/writes the user's config, dotfiles or external hosts.
const std = @import("std");
const local = @import("local/adapter.zig");
const native = @import("local/native.zig");
const host = @import("host/session_host.zig");
const terminal = @import("host/terminal_service.zig");
const execution = @import("host/terminal_execution.zig");
const protocol = @import("local/execution.zig");
const a = std.testing.allocator;
test {
    _ = protocol;
    _ = execution;
    _ = @import("local/recording.zig");
    _ = @import("ai/host_execution.zig");
    _ = @import("ai/host_execution_driver.zig");
}
extern "c" fn setenv([*:0]const u8, [*:0]const u8, c_int) c_int;
extern "c" fn unsetenv([*:0]const u8) c_int;
fn pause() void {
    const delay: std.c.timespec = .{ .sec = 0, .nsec = 5 * std.time.ns_per_ms };
    _ = std.c.nanosleep(&delay, null);
}
const Fixture = struct {
    tmp: std.testing.TmpDir,
    path: [:0]u8,
    previous: ?[:0]u8,
    adapter: *local.LocalAdapter,
    sessions: *host.SessionHost,
    service: ?terminal.Service = null,
    output: std.ArrayList(u8) = .empty,
    scratch: []u8,
    projection_generation: u64 = 0,
    fn init() !Fixture {
        return initWithStartup("");
    }
    fn initWithStartup(startup: []const u8) !Fixture {
        return initConfigured(startup, true);
    }
    fn initConfigured(startup: []const u8, recording_enabled: bool) !Fixture {
        var tmp = std.testing.tmpDir(.{});
        errdefer tmp.cleanup();
        try tmp.dir.writeFile(std.testing.io, .{ .sub_path = ".zshenv", .data = "PROMPT=''\nRPROMPT=''\n" });
        const script = try std.mem.concat(a, u8, &.{ "bindkey -e\n", startup });
        defer a.free(script);
        try tmp.dir.writeFile(std.testing.io, .{ .sub_path = ".zshrc", .data = script });
        const path = try tmp.dir.realPathFileAlloc(std.testing.io, ".", a);
        errdefer a.free(path);
        const previous = if (std.c.getenv("ZDOTDIR")) |v| try a.dupeSentinel(u8, std.mem.span(v), 0) else null;
        errdefer if (previous) |old| a.free(old);
        if (setenv("ZDOTDIR", path.ptr, 1) != 0) return error.EnvironmentFailed;
        errdefer if (previous) |old| {
            _ = setenv("ZDOTDIR", old.ptr, 1);
        } else {
            _ = unsetenv("ZDOTDIR");
        };
        const options: local.Options = if (recording_enabled) .{ .recording = .{ .io = std.testing.io, .directory = path, .log = .{ .ring_mb = 2, .checkpoint_sec = 1 } } } else .{ .metadata = .{ .io = std.testing.io, .directory = path, .retention_days = 14 } };
        const adapter = try local.LocalAdapter.init(a, options);
        errdefer adapter.deinit() catch unreachable;
        const sessions = try a.create(host.SessionHost);
        errdefer a.destroy(sessions);
        sessions.* = try host.SessionHost.init(a, &.{adapter.adapter()});
        errdefer sessions.deinit();
        const accepted = try sessions.create(.{ .local = .{ .initial_cwd = path } }, .{ .window_id = @fromBackingInt(1), .workspace_id = @fromBackingInt(1) });
        var f: Fixture = .{ .tmp = tmp, .path = path, .previous = previous, .adapter = adapter, .sessions = sessions, .scratch = try a.alloc(u8, @import("vt/text_slot.zig").TextSlot.default_capacity) };
        const until = native.zw_local_monotonic_ms() + 8000;
        while (native.zw_local_monotonic_ms() < until) {
            try f.tick();
            if (f.sessions.queryService(accepted.handle, .terminal) == .available) {
                f.service = try f.adapter.terminalService(f.sessions.queryService(accepted.handle, .terminal).available);
                return f;
            }
            pause();
        }
        return error.ServiceTimeout;
    }
    fn tick(self: *Fixture) !void {
        _ = try self.adapter.drain(self.sessions);
        if (self.service) |service| {
            const slot = service.textSlot() catch |err| {
                if (err == error.WorkerBusy) return;
                return err;
            };
            if (try slot.take(self.projection_generation, self.scratch)) |frame| self.projection_generation = frame.generation;
            var bytes: [8192]u8 = undefined;
            for (0..16) |_| switch (service.readOutput(&bytes) catch |err| {
                if (err == error.WorkerBusy) return;
                return err;
            }) {
                .bytes => |count| try self.output.appendSlice(a, bytes[0..count]),
                else => break,
            };
        }
    }
    fn deinit(self: *Fixture) void {
        const until = native.zw_local_monotonic_ms() + 8000;
        while (self.adapter.shutdownStep() != .released) {
            self.tick() catch {};
            if (native.zw_local_monotonic_ms() >= until) @panic("execution worker failed to close");
            pause();
        }
        self.adapter.deinit() catch unreachable;
        self.sessions.deinit();
        a.destroy(self.sessions);
        self.output.deinit(a);
        a.free(self.scratch);
        if (self.previous) |old| {
            _ = setenv("ZDOTDIR", old.ptr, 1);
            a.free(old);
        } else {
            _ = unsetenv("ZDOTDIR");
        }
        a.free(self.path);
        self.tmp.cleanup();
    }
    fn ready(self: *Fixture) !execution.Snapshot {
        const until = native.zw_local_monotonic_ms() + 5000;
        while (native.zw_local_monotonic_ms() < until) {
            try self.tick();
            const snapshot = self.service.?.executionSnapshot() catch |err| {
                if (err == error.WorkerBusy) {
                    pause();
                    continue;
                }
                return err;
            };
            if (snapshot.interactive_execution) {
                if (self.service.?.trustedSnapshot(a) catch null) |value| {
                    var edit = value;
                    defer edit.deinit(a);
                    if (edit.editable() and edit.buffer.len == 0) return snapshot;
                }
            }
            pause();
        }
        std.debug.print("PTY output: {s}\n", .{self.output.items});
        return error.ExecutionIntegrationTimeout;
    }
    fn run(self: *Fixture, command: []const u8) !void {
        return self.runWithScope(command, .session_interval);
    }
    fn runWithScope(self: *Fixture, command: []const u8, scope: execution.OutputScope) !void {
        const snapshot = try self.ready();
        const request: execution.Request = .{ .execution_id = .generate(), .task_id = .generate(), .expected_input_epoch = snapshot.input_epoch, .ownership_revision = 1, .command = command, .command_hash = execution.digest(command), .output_scope = scope };
        const until = native.zw_local_monotonic_ms() + 3000;
        while (native.zw_local_monotonic_ms() < until) {
            self.service.?.executionRequest(request) catch |err| {
                if (err == error.WorkerBusy or err == error.InputConflict) {
                    try self.tick();
                    pause();
                    continue;
                }
                return err;
            };
            return;
        }
        return error.ExecutionSubmitTimeout;
    }
    fn expectFailure(self: *Fixture, comptime function: anytype, args: anytype, expected: anyerror) !void {
        const until = native.zw_local_monotonic_ms() + 3000;
        while (native.zw_local_monotonic_ms() < until) {
            if (@call(.auto, function, args)) |_| return error.UnexpectedSuccess else |err| {
                if (err == error.WorkerBusy) {
                    try self.tick();
                    pause();
                    continue;
                }
                try std.testing.expectEqual(expected, err);
                return;
            }
        }
        return error.MailboxTimeout;
    }
    fn bells(self: *Fixture) !u64 {
        const until = native.zw_local_monotonic_ms() + 3000;
        while (native.zw_local_monotonic_ms() < until) {
            const value = self.service.?.status() catch |err| {
                if (err == error.WorkerBusy) {
                    pause();
                    continue;
                }
                return err;
            };
            return value.bell_count;
        }
        return error.MailboxTimeout;
    }
    fn awaitSnapshot(self: *Fixture) !execution.Snapshot {
        const until = native.zw_local_monotonic_ms() + 3000;
        while (native.zw_local_monotonic_ms() < until) {
            return self.service.?.executionSnapshot() catch |err| {
                if (err == error.WorkerBusy) {
                    try self.tick();
                    pause();
                    continue;
                }
                return err;
            };
        }
        return error.MailboxTimeout;
    }
    fn wait(self: *Fixture, state: execution.State) !execution.Snapshot {
        const until = native.zw_local_monotonic_ms() + 10_000;
        var last: execution.Snapshot = undefined;
        while (native.zw_local_monotonic_ms() < until) {
            try self.tick();
            last = self.service.?.executionSnapshot() catch |err| {
                if (err == error.WorkerBusy) {
                    pause();
                    continue;
                }
                return err;
            };
            if (last.state == state) return last;
            if (last.failure != null) break;
            pause();
        }
        std.debug.print("Execution state={s} failure={?s} accepted={} submitted={} start={any} end={any}\nPTY: {s}\n", .{ @tagName(last.state), last.failure, last.command_accepted, last.submit_sent, last.start, last.end, self.output.items });
        return error.ExecutionStateTimeout;
    }
};

test "production Local interval private submit saves nonzero exit after ordered PTY end and ignores forged OSC" {
    var f = try Fixture.initWithStartup("_test_precmd() { return 77; }\nprecmd_functions+=(_test_precmd)\n");
    defer f.deinit();
    try f.run("printf '\\033]133;D;0\\007forged-finish\\n'; printf '真实输出\\n'; /bin/sh -c \"test ! -e /dev/fd/$_zw_exec_fd\" && printf 'child-fd-closed\\n'; /bin/sleep 0.1; /usr/bin/false");
    const sealed = try f.wait(.interval_recorded);
    try std.testing.expectEqual(@as(?u8, 1), sealed.process.?.exit_code);
    try std.testing.expect(sealed.process.?.foreground_finished and !sealed.process.?.background_jobs);
    try std.testing.expect(sealed.start != null and sealed.end != null and sealed.end.?.raw_offset > sealed.start.?.raw_offset);
    try std.testing.expect(sealed.manifest_revision > 0 and sealed.recording_id != null and sealed.recording_generation == 1);
    try std.testing.expect(sealed.local_released and !sealed.remote_effect_unknown and sealed.interval_saved and sealed.recording_settled);
    try std.testing.expect(sealed.output_scope == .session_interval);
    const receipt = execution.PublicReceipt.fromSnapshot(sealed).?;
    try receipt.validate();
    try std.testing.expect(!receipt.sealed and receipt.interval_saved);
    try std.testing.expect(std.mem.indexOf(u8, f.output.items, "真实输出\r\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, f.output.items, "zerowork-exec-v1;") == null);
    try std.testing.expect(std.mem.indexOf(u8, f.output.items, "child-fd-closed\r\n") != null);
    // Same shell and recording, a distinct command and fence; no replay.
    try f.run("printf 'multiline-a\\n'\nprintf 'multiline-b\\n'");
    const second = try f.wait(.interval_recorded);
    try std.testing.expectEqual(@as(?u8, 0), second.process.?.exit_code);
    const before_zero = try f.bells();
    try f.run("true");
    const zero = try f.wait(.interval_recorded);
    try std.testing.expectEqual(@as(?u8, 0), zero.process.?.exit_code);
    try std.testing.expect(zero.start != null and zero.end != null and zero.recording_settled);
    // The private NUL wake must be consumed without a terminal bell.
    try std.testing.expectEqual(before_zero, try f.bells());
}

test "production Local input lease gates ordinary write paste key and edit and explicit takeover revokes old fence" {
    var f = try Fixture.init();
    defer f.deinit();
    try f.run("/bin/sleep 5");
    const running = try f.wait(.running);
    const grant = running.grant.?;
    const until = native.zw_local_monotonic_ms() + 3000;
    while (true) {
        if (native.zw_local_monotonic_ms() >= until) return error.GateTimeout;
        const result = f.service.?.write(.{ .input_sequence = 1, .bytes = "never-injected" });
        if (result) |_| return error.UnexpectedWrite else |err| {
            if (err == error.WorkerBusy) {
                pause();
                continue;
            }
            try std.testing.expectEqual(error.TerminalControlled, err);
        }
        break;
    }
    try f.expectFailure(terminal.Service.writeKey, .{ f.service.?, terminal.KeyRequest{ .input_sequence = 1, .mode_revision = 1, .event = .{ .key = .enter } } }, error.TerminalControlled);
    try f.expectFailure(terminal.Service.writeMouse, .{ f.service.?, terminal.MouseRequest{ .input_sequence = 1, .mode_revision = 1, .geometry_revision = 1, .event = .{ .action = .press, .button = .left, .x = 1, .y = 1, .screen_width = 640, .screen_height = 480, .cell_width = 8, .cell_height = 16 } } }, error.TerminalControlled);
    try f.expectFailure(terminal.Service.commitPaste, .{ f.service.?, terminal.Paste{ .binding = f.service.?.binding, .input_revision = 0, .mode_revision = 1, .text = "never-paste", .requires_confirmation = false }, @as(u64, 1), false }, error.TerminalControlled);
    try f.expectFailure(terminal.Service.trustedRequest, .{ f.service.?, terminal.trusted_edit.Request{ .operation = 1, .token = 1, .revision = 0, .replacement = "never-edit" } }, error.TerminalControlled);
    while (true) {
        f.service.?.executionRevoke(grant, true) catch |err| {
            if (err == error.WorkerBusy) {
                pause();
                continue;
            }
            return err;
        };
        break;
    }
    const handed = try f.awaitSnapshot();
    try std.testing.expect(handed.input_handed_off and handed.state == .running and !handed.remote_effect_unknown and handed.local_released and handed.grant == null);
    try f.expectFailure(terminal.Service.executionRenew, .{ f.service.?, grant }, error.StaleFence);
    try std.testing.expect(std.mem.indexOf(u8, f.output.items, "never-injected") == null);
}

test "production Local incomplete syntax never submits or repairs the shell buffer" {
    var f = try Fixture.init();
    defer f.deinit();
    try f.run("printf 'unterminated");
    const cancelled = try f.wait(.cancelled_unsent);
    try std.testing.expect(!cancelled.submit_sent and !cancelled.command_accepted and cancelled.local_released);
}

test "BoundaryFence streaming parser preserves unregistered forged output through every read split" {
    const Capture = struct {
        data: std.ArrayList(u8) = .empty,
        fn output(raw: *anyopaque, bytes: []const u8, _: u64) void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.data.appendSlice(a, bytes) catch @panic("oom");
        }
    };
    const owner: @import("host/identity.zig").SessionHandle = .{ .session_id = @fromBackingInt(9) };
    const start = "\x1b]777;zerowork-exec-v1;aaaaaaaa;start\x07";
    const end = "\x1b]777;zerowork-exec-v1;bbbbbbbb;end\x07";
    const bytes = "before" ++ start ++ "中文\x1b]133;D;0\x07forged" ++ end ++ "after";
    for (0..bytes.len) |split| {
        var capture: Capture = .{};
        defer capture.data.deinit(a);
        var bridge = protocol.Bridge.init(a, owner, @ptrFromInt(8));
        defer bridge.deinit();
        @memcpy(bridge.start_frame[0..start.len], start);
        bridge.start_frame_len = start.len;
        @memcpy(bridge.end_frame[0..end.len], end);
        bridge.end_frame_len = end.len;
        bridge.output(bytes[0..split], .{ .context = &capture, .output = Capture.output });
        bridge.output(bytes[split..], .{ .context = &capture, .output = Capture.output });
        bridge.flushOutput(.{ .context = &capture, .output = Capture.output });
        try std.testing.expectEqualStrings("before中文\x1b]133;D;0\x07forgedafter", capture.data.items);
        try std.testing.expect(bridge.start_seen != null and bridge.end_seen != null);
        try std.testing.expect(!bridge.startPaired() and !bridge.endPaired());
        try std.testing.expectEqual(@as(u64, bytes.len), bridge.raw_received);
    }
}
comptime {
    _ = execution;
}

test "host execution catalog and journal controller instantiate without a session-target authority" {
    const host_execution = @import("ai/host_execution.zig");
    const Backend = struct {
        fn authorize(_: *anyopaque, _: @import("ai/host_tools.zig").Invocation, _: []const u8, _: []const u8, _: [32]u8) !host_execution.Target {
            return error.PermissionDenied;
        }
        fn resolve(_: *anyopaque, _: @import("ai/host_tools.zig").Context, _: @import("host/identity.zig").SessionHandle) !terminal.Service {
            return error.SessionClosed;
        }
    };
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var journal = try @import("ai/lifecycle_journal.zig").Journal.open(a, std.testing.io, tmp.dir, "journal.json");
    defer journal.deinit();
    var backend: u8 = 0;
    var controller = host_execution.Controller.init(a, &journal, .{ .context = &backend, .authorize = Backend.authorize, .resolve = Backend.resolve });
    defer controller.deinit();
    const context: @import("ai/host_tools.zig").Context = .{ .conversation_id = .generate(), .task_id = .generate(), .binding = .{ .session = 1 }, .binding_revision = 1, .grant_revision = 1 };
    var table = try @import("ai/plugin_tools.zig").RequestTable.initWithHost(a, .{ .owner = context.binding, .members = .{} }, &.{}, &.{}, context, &host_execution.contributions);
    defer table.deinit();
    const parsed = try std.json.parseFromSlice(std.json.Value, a, "{\"session_ref\":\"s1:no-authority\",\"command\":\"true\",\"request_key\":\"run-one\"}", .{});
    defer parsed.deinit();
    const invocation: @import("ai/host_tools.zig").Invocation = .{ .context = context, .authority = .execution_control, .operation_id = 1, .turn_id = 1, .call_id = "call-one", .tool_id = "host.run_in_terminal", .arguments = parsed.value, .arguments_json = "", .arguments_hash = @splat(1), .canonical_arguments_hash = @splat(2) };
    try std.testing.expectError(error.PermissionDenied, controller.execute(invocation, 0));
    controller.tick(0);
    try std.testing.expectError(error.ExecutionNotFound, controller.takeover(context, "x1:bad", 0));
    const wait: host_execution.Wait = .{ .context = context, .operation_id = 1, .index = 0, .after_revision = 1, .deadline = 1, .output_cursor = 0, .max_bytes = 8192 };
    try std.testing.expectError(error.ExecutionNotFound, controller.pollWait(wait, 0));
}

test "production Local explicit stop requests a real foreground interrupt and keeps outcome unknown" {
    var f = try Fixture.init();
    defer f.deinit();
    try f.run("/bin/sleep 30");
    const running = try f.wait(.running);
    const until = native.zw_local_monotonic_ms() + 3000;
    while (true) {
        f.service.?.executionRevoke(running.grant.?, false) catch |err| {
            if (err == error.WorkerBusy and native.zw_local_monotonic_ms() < until) {
                pause();
                continue;
            }
            return err;
        };
        break;
    }
    const stopped = try f.wait(.outcome_unknown);
    try std.testing.expect(stopped.local_released and stopped.remote_effect_unknown);
    // The actual shell must return to a fresh trusted empty prompt; an
    // interrupt request alone cannot satisfy this observation.
    _ = try f.ready();
}

test "production Local interval saves observed concurrent output without claiming exact completion" {
    var f = try Fixture.init();
    defer f.deinit();
    try f.run("/bin/sleep 1 &");
    const saved = try f.wait(.interval_recorded);
    try std.testing.expect(saved.process != null and saved.process.?.background_jobs and saved.end != null);
    try std.testing.expect(saved.local_released and !saved.remote_effect_unknown and saved.interval_saved);
    try std.testing.expect(saved.output_attribution == .concurrent_observed);
}

test "production Local interval accepts existing background owners while exact remains zero submit" {
    var f = try Fixture.initWithStartup("/bin/sleep 20 &\n");
    defer f.deinit();
    try f.run("printf 'interval-with-existing-job\\n'");
    const saved = try f.wait(.interval_recorded);
    try std.testing.expect(saved.command_accepted and saved.submit_sent and saved.interval_saved);
    try std.testing.expect(saved.output_attribution == .concurrent_observed and !saved.remote_effect_unknown);
    try std.testing.expect(saved.process.?.foreground_finished and saved.process.?.exit_code == 0);
    try f.runWithScope("printf 'exact-must-not-run\\n'", .exact);
    const rejected = try f.wait(.cancelled_unsent);
    try std.testing.expect(rejected.output_scope == .exact and !rejected.command_accepted and !rejected.submit_sent and rejected.submit_native_bytes == 0);
    try std.testing.expect(rejected.end == null and !rejected.interval_saved);
}

test "production Local detached child retaining the slave is observed before END" {
    var f = try Fixture.init();
    defer f.deinit();
    // Python leaves zsh's job table before its child exits. The child creates a
    // new session while retaining this slave's stdout/stderr descriptors.
    try f.run("/usr/bin/python3 -c 'import subprocess; subprocess.Popen([\"/bin/sleep\", \"1\"], start_new_session=True)' ");
    const saved = try f.wait(.interval_recorded);
    try std.testing.expect(saved.process != null and (saved.process.?.background_jobs or saved.process.?.background_jobs_unknown) and saved.end != null);
    try std.testing.expect(saved.local_released and !saved.remote_effect_unknown and saved.interval_saved);
    try std.testing.expect(saved.output_attribution != .no_concurrent_owner_observed);
}

test "production host controller returns one real execution and preserves idempotency waits and bounded output" {
    const host_execution = @import("ai/host_execution.zig");
    const host_tools = @import("ai/host_tools.zig");
    const Backend = struct {
        fn authorize(raw: *anyopaque, _: host_tools.Invocation, _: []const u8, command: []const u8, hash: [32]u8) !host_execution.Target {
            const fixture: *Fixture = @ptrCast(@alignCast(raw));
            if (!std.mem.eql(u8, &execution.digest(command), &hash)) return error.CommandHashMismatch;
            const service = fixture.service.?;
            return .{ .handle = (try service.executionSnapshot()).owner, .service = service, .ownership_revision = 1 };
        }
        fn resolve(raw: *anyopaque, _: host_tools.Context, owner: @import("host/identity.zig").SessionHandle) !terminal.Service {
            const fixture: *Fixture = @ptrCast(@alignCast(raw));
            const service = fixture.service.?;
            const actual = try service.executionSnapshot();
            if (!owner.eql(actual.owner)) return error.StaleGeneration;
            return service;
        }
    };
    var f = try Fixture.init();
    defer f.deinit();
    const ready = try f.ready();
    var journal = try @import("ai/lifecycle_journal.zig").Journal.open(a, std.testing.io, f.tmp.dir, "execution-journal.json");
    defer journal.deinit();
    var controller = host_execution.Controller.init(a, &journal, .{ .context = &f, .authorize = Backend.authorize, .resolve = Backend.resolve });
    defer controller.deinit();
    const context: host_tools.Context = .{ .conversation_id = .generate(), .task_id = .generate(), .binding = .{ .session = @backingInt(ready.owner.session_id) }, .binding_revision = 1, .grant_revision = 1 };
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const aa = arena.allocator();
    const arguments = try std.json.parseFromSliceLeaky(std.json.Value, aa, "{\"session_ref\":\"fixture-authorized-exact-owner\",\"command\":\"printf 'host-output\\\\n'\",\"request_key\":\"host-real-one\"}", .{});
    const invocation: host_tools.Invocation = .{ .context = context, .authority = .execution_control, .operation_id = 31, .turn_id = 41, .call_id = "host-real-call", .tool_id = "host.run_in_terminal", .arguments = arguments, .arguments_json = "", .arguments_hash = @splat(1), .canonical_arguments_hash = @splat(2) };
    const response = try controller.execute(invocation, @intCast(native.zw_local_monotonic_ms()));
    try std.testing.expect(response == .result);
    var result = response.result;
    defer result.deinit(a);
    try result.validate(context, invocation.operation_id);
    const json = try std.json.parseFromSlice(std.json.Value, aa, result.blocks[0].structured, .{});
    const reference = json.value.object.get("execution_ref").?.string;
    const until = native.zw_local_monotonic_ms() + 8000;
    while (native.zw_local_monotonic_ms() < until) {
        try f.tick();
        controller.tick(@intCast(native.zw_local_monotonic_ms()));
        const current = f.service.?.executionSnapshot() catch {
            pause();
            continue;
        };
        if (current.state == .interval_recorded) break;
        pause();
    }
    _ = try f.wait(.interval_recorded);
    controller.tick(@intCast(native.zw_local_monotonic_ms()));
    const query_json = try std.json.Stringify.valueAlloc(aa, .{ .execution_ref = reference, .max_bytes = 16 }, .{});
    const query_args = try std.json.parseFromSliceLeaky(std.json.Value, aa, query_json, .{});
    var query = invocation;
    query.operation_id = 32;
    query.tool_id = "host.get_execution";
    query.arguments = query_args;
    var query_result = (try controller.execute(query, @intCast(native.zw_local_monotonic_ms()))).result;
    defer query_result.deinit(a);
    try query_result.validate(context, query.operation_id);
    const body = try std.json.parseFromSliceLeaky(std.json.Value, aa, query_result.blocks[0].structured, .{});
    try std.testing.expectEqualStrings("interval_recorded", body.object.get("state").?.string);
    try std.testing.expect(body.object.get("output").?.string.len <= 16);
    try std.testing.expect(body.object.get("next_cursor").? == .string);
    var duplicate = invocation;
    duplicate.call_id = "different-provider-call";
    duplicate.operation_id = 33;
    var replay = (try controller.execute(duplicate, @intCast(native.zw_local_monotonic_ms()))).result;
    defer replay.deinit(a);
    const repeated = try std.json.parseFromSliceLeaky(std.json.Value, aa, replay.blocks[0].structured, .{});
    try std.testing.expectEqualStrings(reference, repeated.object.get("execution_ref").?.string);
    try std.testing.expectEqual(@as(usize, 1), controller.entries.items.len);
    const wait_json = try std.json.Stringify.valueAlloc(aa, .{ .execution_ref = reference, .after_revision = controller.entries.items[0].snapshot.revision, .wait_ms = 10 }, .{});
    var waiting = query;
    waiting.tool_id = "host.wait_execution";
    waiting.arguments = try std.json.parseFromSliceLeaky(std.json.Value, aa, wait_json, .{});
    const now: i64 = @intCast(native.zw_local_monotonic_ms());
    const pending = try controller.execute(waiting, now);
    try std.testing.expect(pending == .wait);
    try std.testing.expect(try controller.pollWait(pending.wait, now) == null);
    var waited = (try controller.pollWait(pending.wait, now + 11)).?;
    defer waited.deinit(a);
    const timed = try std.json.parseFromSliceLeaky(std.json.Value, aa, waited.blocks[0].structured, .{});
    try std.testing.expect(timed.object.get("timed_out").?.bool);
}

const DriverPump = struct {
    const Call = struct { context: *anyopaque, function: *const fn (*anyopaque) anyerror!void, done: std.atomic.Value(bool) = .init(false), failure: ?anyerror = null };
    mutex: std.atomic.Mutex = .unlocked,
    pending: ?*Call = null,
    fn lock(self: *DriverPump) void {
        while (!self.mutex.tryLock()) std.atomic.spinLoopHint();
    }
    fn schedule(raw: *anyopaque, context: *anyopaque, function: *const fn (*anyopaque) anyerror!void, cancel: ?*@import("ai/provider.zig").CancelToken) !void {
        const self: *DriverPump = @ptrCast(@alignCast(raw));
        if (cancel) |token| if (token.isCancelled()) return error.CancelledBeforeDispatch;
        var call: Call = .{ .context = context, .function = function };
        self.lock();
        if (self.pending != null) {
            self.mutex.unlock();
            return error.WorkerBusy;
        }
        self.pending = &call;
        self.mutex.unlock();
        while (!call.done.load(.acquire)) {
            if (cancel) |token| if (token.isCancelled()) {
                self.lock();
                if (self.pending == &call) {
                    self.pending = null;
                    self.mutex.unlock();
                    return error.CancelledBeforeDispatch;
                }
                self.mutex.unlock();
            };
            pause();
        }
        if (call.failure) |failure| return failure;
    }
    fn pump(self: *DriverPump) void {
        self.lock();
        const call = self.pending;
        self.pending = null;
        self.mutex.unlock();
        if (call) |value| {
            value.function(value.context) catch |err| {
                value.failure = err;
            };
            value.done.store(true, .release);
        }
    }
};

test "production execution driver owns journal and renews a real Local lease while the provider makes no calls" {
    const driver_mod = @import("ai/host_execution_driver.zig");
    const host_execution = @import("ai/host_execution.zig");
    const host_tools = @import("ai/host_tools.zig");
    const Runtime = @import("ai/lifecycle_runtime.zig");
    const Backend = struct {
        fixture: *Fixture,
        ui_thread: std.Thread.Id,
        handed_to_user: bool = false,
        fn check(self: *@This()) !void {
            if (std.Thread.getCurrentId() != self.ui_thread) return error.ControllerThreadViolated;
        }
        fn authorize(raw: *anyopaque, _: host_tools.Invocation, _: []const u8, _: []const u8, _: [32]u8) !host_execution.Target {
            const self: *@This() = @ptrCast(@alignCast(raw));
            try self.check();
            const service = self.fixture.service.?;
            return .{ .handle = (try service.executionSnapshot()).owner, .service = service, .ownership_revision = 1 };
        }
        fn resolve(raw: *anyopaque, _: host_tools.Context, _: @import("host/identity.zig").SessionHandle) !terminal.Service {
            const self: *@This() = @ptrCast(@alignCast(raw));
            try self.check();
            return self.fixture.service.?;
        }
        fn handoff(raw: *anyopaque, _: @import("host/identity.zig").SessionHandle) !void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            try self.check();
            self.handed_to_user = true;
        }
    };
    var f = try Fixture.init();
    defer f.deinit();
    const ready = try f.ready();
    const journal = try Runtime.ProcessJournal.acquire(.{ .data_root = f.path, .path = "driver-journal.json", .dir = f.tmp.dir, .io = std.testing.io });
    defer journal.release();
    var pump: DriverPump = .{};
    var backend: Backend = .{ .fixture = &f, .ui_thread = std.Thread.getCurrentId() };
    const driver = try driver_mod.Driver.start(a, journal, .{ .context = &pump, .call = DriverPump.schedule }, .{ .context = &backend, .authorize = Backend.authorize, .resolve = Backend.resolve, .handed_to_user = Backend.handoff });
    var driver_alive = true;
    defer if (driver_alive) {
        driver.requestShutdown();
        while (true) {
            pump.pump();
            driver.finish() catch {
                pause();
                continue;
            };
            break;
        }
    };
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const context: host_tools.Context = .{ .conversation_id = .generate(), .task_id = .generate(), .binding = .{ .session = @backingInt(ready.owner.session_id) }, .binding_revision = 1, .grant_revision = 1 };
    const args = try std.json.parseFromSliceLeaky(std.json.Value, arena.allocator(), "{\"session_ref\":\"fixture-authorized-owner\",\"command\":\"/bin/sleep 8\",\"request_key\":\"driver-lease\"}", .{});
    const Tool = struct {
        driver: *driver_mod.Driver,
        invocation: host_tools.Invocation,
        result: ?host_tools.Result = null,
        failure: ?anyerror = null,
        done: std.atomic.Value(bool) = .init(false),
        fn run(self: *@This()) void {
            self.result = self.driver.execute(self.invocation, null) catch |err| {
                self.failure = err;
                self.done.store(true, .release);
                return;
            };
            self.done.store(true, .release);
        }
    };
    var tool: Tool = .{ .driver = driver, .invocation = .{ .context = context, .authority = .execution_control, .operation_id = 101, .turn_id = 201, .call_id = "driver-call", .tool_id = "host.run_in_terminal", .arguments = args, .arguments_json = "", .arguments_hash = @splat(1), .canonical_arguments_hash = @splat(2) } };
    const tool_thread = try std.Thread.spawn(.{}, Tool.run, .{&tool});
    const until = native.zw_local_monotonic_ms() + 10_000;
    while (!tool.done.load(.acquire) and native.zw_local_monotonic_ms() < until) {
        pump.pump();
        try f.tick();
        pause();
    }
    tool_thread.join();
    if (tool.failure) |failure| return failure;
    var result = tool.result.?;
    defer result.deinit(a);
    const response = try std.json.parseFromSliceLeaky(std.json.Value, arena.allocator(), result.blocks[0].structured, .{});
    const reference = response.object.get("execution_ref").?.string;
    var expiry: i64 = 0;
    while (native.zw_local_monotonic_ms() < until) {
        pump.pump();
        try f.tick();
        const current = f.service.?.executionSnapshot() catch {
            pause();
            continue;
        };
        if (current.state == .running) {
            expiry = current.lease_expires_at;
            break;
        }
        pause();
    }
    try std.testing.expect(expiry > 0 and driver.hasWork());
    try driver.finishTask(context);
    const finish_until = native.zw_local_monotonic_ms() + 2000;
    while (native.zw_local_monotonic_ms() < finish_until) {
        pump.pump();
        try f.tick();
        if (driver.taskEvidence(context.task_id)) |fact| if (fact.model_done) {
            try std.testing.expect(fact.execution_count == 1 and fact.active_executions == 1 and !fact.executions_settled and !fact.input_grants_released);
            break;
        };
        pause();
    }
    try std.testing.expect(driver.taskEvidenceFor(context).?.model_done);
    const renew_until = native.zw_local_monotonic_ms() + 5600;
    while (native.zw_local_monotonic_ms() < renew_until) {
        pump.pump();
        try f.tick();
        pause();
    }
    const renewed = try f.service.?.executionSnapshot();
    try std.testing.expect(renewed.lease_expires_at >= expiry + 4000);
    try std.testing.expect(renewed.state == .running);
    try driver.requestTakeover(context, reference);
    const handoff_until = native.zw_local_monotonic_ms() + 2000;
    while (!backend.handed_to_user and native.zw_local_monotonic_ms() < handoff_until) {
        pump.pump();
        try f.tick();
        pause();
    }
    try std.testing.expect(backend.handed_to_user);
    try driver.finishTask(context);
    driver.requestShutdown();
    while (true) {
        pump.pump();
        driver.finish() catch {
            pause();
            continue;
        };
        break;
    }
    driver_alive = false;
}

test "production Local explicitly unrecorded real PTY closes into metadata without storing terminal content" {
    var f = try Fixture.initConfigured("", false);
    defer f.deinit();
    const until = native.zw_local_monotonic_ms() + 5000;
    var input_ready = false;
    while (native.zw_local_monotonic_ms() < until) {
        try f.tick();
        if (f.service.?.trustedSnapshot(a) catch null) |snapshot| {
            var observed = snapshot;
            defer observed.deinit(a);
            if (observed.editable()) {
                input_ready = true;
                break;
            }
        }
        pause();
    }
    try std.testing.expect(input_ready);
    while (true) {
        const state = f.service.?.status() catch {
            pause();
            continue;
        };
        _ = f.service.?.write(.{ .input_sequence = 1, .mode_revision = state.mode_revision, .bytes = "printf 'METADATA_ONLY_PAYLOAD\\n'\r" }) catch |err| {
            if (err == error.WorkerBusy) {
                pause();
                continue;
            }
            return err;
        };
        break;
    }
    while (native.zw_local_monotonic_ms() < until) {
        try f.tick();
        if (std.mem.indexOf(u8, f.output.items, "METADATA_ONLY_PAYLOAD\r\n") != null) break;
        pause();
    }
    try std.testing.expect(std.mem.indexOf(u8, f.output.items, "METADATA_ONLY_PAYLOAD\r\n") != null);
    while (true) {
        f.service.?.setRecordingDisplay(.{ .title = "Unrecorded Local fixture", .host = "Local", .cwd = f.path, .timestamps = true, .font_family = "Monaco", .font_size_px = 14, .line_height = 1.5 }) catch |err| {
            if (err == error.WorkerBusy) {
                pause();
                continue;
            }
            return err;
        };
        break;
    }
    const capability = try f.awaitSnapshot();
    try std.testing.expect(!capability.interactive_execution);
    const close_until = native.zw_local_monotonic_ms() + 8000;
    while (f.adapter.shutdownStep() != .released) {
        f.tick() catch {};
        if (native.zw_local_monotonic_ms() >= close_until) return error.MetadataCloseTimeout;
        pause();
    }
    var archive: @import("vt/session_archive.zig").Archive = .{ .allocator = a, .io = std.testing.io, .dir = f.tmp.dir };
    var catalog = try archive.loadCatalog(a);
    defer catalog.deinit();
    try std.testing.expectEqual(@as(usize, 1), catalog.entries.items.len);
    const record = catalog.entries.items[0];
    try std.testing.expectEqualStrings("Unrecorded Local fixture", record.title);
    try std.testing.expect(!record.can_open and record.coverage == .unavailable and record.replayability == .unsupported);
    try std.testing.expectEqualStrings("RecordingDisabled", record.failure.?);
    try std.testing.expect(record.document.?.files.len == 0 and record.display.timestamps);
    try std.testing.expectError(error.FileNotFound, f.tmp.dir.openFile(std.testing.io, "logs/history/index.tsv", .{}));
}

test "production Local precise user input handoff keeps builtin foreground and authentic finish observation" {
    var f = try Fixture.init();
    defer f.deinit();
    try f.run("IFS= read -r reply; printf 'USER_HANDOFF_%s\\n' \"$reply\"");
    const running = try f.wait(.running);
    const grant = running.grant.?;
    const until = native.zw_local_monotonic_ms() + 3000;
    while (true) {
        f.service.?.executionRevoke(grant, true) catch |err| {
            if (err == error.WorkerBusy and native.zw_local_monotonic_ms() < until) {
                pause();
                continue;
            }
            return err;
        };
        break;
    }
    const handed = try f.awaitSnapshot();
    try std.testing.expect(handed.input_handed_off and handed.state == .running and handed.process == null);
    try std.testing.expect(handed.input_ready and handed.local_released and handed.grant == null and !handed.remote_effect_unknown);
    try f.expectFailure(terminal.Service.executionRenew, .{ f.service.?, grant }, error.StaleFence);
    var written = false;
    while (native.zw_local_monotonic_ms() < until) {
        const current = f.service.?.status() catch |err| {
            if (err == error.WorkerBusy) {
                pause();
                continue;
            }
            return err;
        };
        const accepted = f.service.?.write(.{ .input_sequence = 91, .mode_revision = current.mode_revision, .bytes = "human-value\n" }) catch |err| {
            if (err == error.WorkerBusy or err == error.StaleMode) {
                pause();
                continue;
            }
            return err;
        };
        try std.testing.expect(accepted.input_sequence == 91 and accepted.queued_bytes == "human-value\n".len);
        written = true;
        break;
    }
    try std.testing.expect(written);
    const ended = try f.wait(.interval_recorded);
    try std.testing.expect(ended.input_handed_off and ended.process.?.foreground_finished and ended.process.?.exit_code == 0 and !ended.remote_effect_unknown);
    var output = try f.service.?.executionOutput(grant.execution_id, a, 0, 65536);
    defer output.deinit(a);
    try std.testing.expect(std.mem.indexOf(u8, output.bytes, "USER_HANDOFF_human-value\r\n") != null);
    try f.run("true");
    const fresh = try f.wait(.interval_recorded);
    try std.testing.expect(fresh.execution_fence > grant.fence and !fresh.input_handed_off);
}

test "production Local controlled helper privately consumes bounded text and Enter without guessing child input" {
    var f = try Fixture.init();
    defer f.deinit();
    try f.run("zerowork_read; print -r -- \"received:$REPLY\"");
    const deadline = native.zw_local_monotonic_ms() + 5000;
    var waiting: execution.Snapshot = undefined;
    while (true) {
        try f.tick();
        waiting = try f.awaitSnapshot();
        if (waiting.input_wait != null) break;
        if (waiting.failure != null or native.zw_local_monotonic_ms() >= deadline) return error.InputWaitTimeout;
        pause();
    }
    try std.testing.expect(waiting.state == .running and waiting.input_wait.?.kind == .controlled_line);
    const text = "private-line-界😀";
    const request: execution.InputRequest = .{ .grant = waiting.grant.?, .wait_sequence = waiting.input_wait.?.sequence, .input_sequence = 19, .kind = .text, .text = text };
    var queued: execution.InputReceipt = undefined;
    while (true) {
        queued = f.service.?.executionInput(request) catch |err| {
            if (err == error.WorkerBusy) {
                try f.tick();
                pause();
                continue;
            }
            return err;
        };
        break;
    }
    try std.testing.expect(queued.stage == .queued);
    while (true) {
        try f.tick();
        waiting = try f.awaitSnapshot();
        if (waiting.input_receipt != null and waiting.input_receipt.?.stage == .consumed) break;
        if (waiting.failure != null or native.zw_local_monotonic_ms() >= deadline) return error.InputConsumedTimeout;
        pause();
    }
    try std.testing.expectEqual(text.len, waiting.input_receipt.?.accepted_bytes);
    try std.testing.expect(waiting.input_wait != null);
    try std.testing.expect(std.mem.indexOf(u8, f.output.items, text) == null);
    // Exact replay returns its original consumed receipt without another frame.
    while (true) {
        const repeated = f.service.?.executionInput(request) catch |err| {
            if (err == error.WorkerBusy) {
                try f.tick();
                pause();
                continue;
            }
            return err;
        };
        try std.testing.expect(repeated.stage == .consumed and repeated.input_sequence == 19);
        break;
    }
    var conflict = request;
    conflict.text = "different";
    try f.expectFailure(@TypeOf(f.service.?).executionInput, .{ f.service.?, conflict }, error.InputConflict);
    const enter: execution.InputRequest = .{ .grant = waiting.grant.?, .wait_sequence = waiting.input_wait.?.sequence, .input_sequence = 20, .kind = .enter };
    while (true) {
        _ = f.service.?.executionInput(enter) catch |err| {
            if (err == error.WorkerBusy) {
                try f.tick();
                pause();
                continue;
            }
            return err;
        };
        break;
    }
    const finished = try f.wait(.interval_recorded);
    try std.testing.expect(finished.input_wait == null and finished.input_receipt.?.stage == .consumed and finished.input_receipt.?.kind == .enter);
    try std.testing.expectEqual(@as(?u8, 0), finished.process.?.exit_code);
    try std.testing.expect(std.mem.indexOf(u8, f.output.items, "received:" ++ text) != null);
}

test "production Local controlled helper hands input to user and ordinary child read never attests a wait" {
    var f = try Fixture.init();
    defer f.deinit();
    try f.run("zerowork_read; print -r -- \"user:$REPLY\"");
    const deadline = native.zw_local_monotonic_ms() + 5000;
    var waiting: execution.Snapshot = undefined;
    while (true) {
        try f.tick();
        waiting = try f.awaitSnapshot();
        if (waiting.input_wait != null) break;
        if (waiting.failure != null or native.zw_local_monotonic_ms() >= deadline) return error.InputWaitTimeout;
        pause();
    }
    const grant = waiting.grant.?;
    const stale: execution.InputRequest = .{ .grant = grant, .wait_sequence = waiting.input_wait.?.sequence, .input_sequence = 31, .kind = .text, .text = "never-replayed" };
    while (true) {
        f.service.?.executionRevoke(grant, true) catch |err| {
            if (err == error.WorkerBusy) {
                try f.tick();
                pause();
                continue;
            }
            return err;
        };
        break;
    }
    try f.expectFailure(terminal.Service.executionInput, .{ f.service.?, stale }, error.StaleFence);
    while (true) {
        const current = f.service.?.status() catch |err| {
            if (err == error.WorkerBusy) {
                try f.tick();
                pause();
                continue;
            }
            return err;
        };
        _ = f.service.?.write(.{ .input_sequence = 1, .mode_revision = current.mode_revision, .bytes = "human-line\r" }) catch |err| {
            if (err == error.WorkerBusy) {
                try f.tick();
                pause();
                continue;
            }
            return err;
        };
        break;
    }
    const finished = try f.wait(.interval_recorded);
    try std.testing.expect(finished.input_handed_off and finished.process.?.exit_code == 0 and !finished.remote_effect_unknown);
    try std.testing.expect(std.mem.indexOf(u8, f.output.items, "user:human-line") != null);
    try std.testing.expect(std.mem.indexOf(u8, f.output.items, "never-replayed") == null);
    try f.run("builtin read -r REPLY; print -r -- \"ordinary:$REPLY\"");
    const running = try f.wait(.running);
    try std.testing.expect(running.input_wait == null);
    const unsupported: execution.InputRequest = .{ .grant = running.grant.?, .wait_sequence = 99, .input_sequence = 32, .kind = .text, .text = "never-child-input" };
    try f.expectFailure(terminal.Service.executionInput, .{ f.service.?, unsupported }, error.InputNotExpected);
    while (true) {
        f.service.?.executionRevoke(running.grant.?, true) catch |err| {
            if (err == error.WorkerBusy) {
                try f.tick();
                pause();
                continue;
            }
            return err;
        };
        break;
    }
    while (true) {
        const current = f.service.?.status() catch |err| {
            if (err == error.WorkerBusy) {
                try f.tick();
                pause();
                continue;
            }
            return err;
        };
        _ = f.service.?.write(.{ .input_sequence = 2, .mode_revision = current.mode_revision, .bytes = "manual-only\r" }) catch |err| {
            if (err == error.WorkerBusy) {
                try f.tick();
                pause();
                continue;
            }
            return err;
        };
        break;
    }
    _ = try f.wait(.interval_recorded);
    try std.testing.expect(std.mem.indexOf(u8, f.output.items, "ordinary:manual-only") != null);
    try std.testing.expect(std.mem.indexOf(u8, f.output.items, "never-child-input") == null);
}

test "production Local native secret consumer uses private bytes and reports only erased consumption" {
    var f = try Fixture.init();
    defer f.deinit();
    // A forked builtin child inherits the old control descriptor before the
    // consumer opens its new socket. It must never receive secret bytes.
    try f.run("(if zselect -r $_zw_exec_fd -t 10; then sysread -i $_zw_exec_fd stolen; print -r -- 'OLD-FD-'\"READ:$stolen\"; fi) & zerowork_secret_consume; wait; print -r -- 'native-secret-consumer-finished'");
    const deadline = native.zw_local_monotonic_ms() + 5000;
    var waiting: execution.Snapshot = undefined;
    while (true) {
        try f.tick();
        waiting = try f.awaitSnapshot();
        if (waiting.input_wait != null) break;
        if (waiting.failure != null or native.zw_local_monotonic_ms() >= deadline) return error.SecretWaitTimeout;
        pause();
    }
    try std.testing.expect(waiting.input_wait.?.kind == .host_secret);
    const request: execution.InputRequest = .{ .grant = waiting.grant.?, .wait_sequence = waiting.input_wait.?.sequence, .input_sequence = 52, .kind = .host_secret };
    var forbidden = request;
    forbidden.kind = .text;
    forbidden.text = "not-a-password";
    try f.expectFailure(terminal.Service.executionInput, .{ f.service.?, forbidden }, error.SecretMustUseHost);
    while (true) {
        const receipt = f.service.?.executionSecret(.{ .begin = request }) catch |err| {
            if (err == error.WorkerBusy) {
                try f.tick();
                pause();
                continue;
            }
            return err;
        };
        try std.testing.expect(receipt.stage == .awaiting_host_secret and receipt.kind == .host_secret);
        break;
    }
    // Includes NUL/control/non-UTF8 bytes to prove counted private framing. They
    // must never be mistaken for a terminal key, echo, shell value or command.
    var secret = "TEST-PRIVATE-SECRET-946c\x00\xff\n".*;
    defer std.crypto.secureZero(u8, &secret);
    while (true) {
        const receipt = f.service.?.executionSecret(.{ .submit = .{ .request = request, .bytes = &secret } }) catch |err| {
            if (err == error.WorkerBusy) {
                try f.tick();
                pause();
                continue;
            }
            return err;
        };
        try std.testing.expect(receipt.stage == .queued);
        break;
    }
    const finished = try f.wait(.interval_recorded);
    try std.testing.expect(finished.input_wait == null and finished.input_receipt.?.kind == .host_secret and finished.input_receipt.?.stage == .consumed and finished.input_receipt.?.accepted_bytes == 0);
    try std.testing.expectEqual(@as(?u8, 0), finished.process.?.exit_code);
    try std.testing.expect(std.mem.indexOf(u8, f.output.items, "TEST-PRIVATE-SECRET-946c") == null);
    var observed = try f.service.?.executionOutput(finished.execution_id.?, a, 0, 8192);
    defer observed.deinit(a);
    try std.testing.expect(std.mem.indexOf(u8, observed.bytes, "TEST-PRIVATE-SECRET-946c") == null);
    try std.testing.expect(std.mem.indexOf(u8, observed.bytes, "OLD-FD-READ:") == null);
    try std.testing.expect(std.mem.indexOf(u8, observed.bytes, "native-secret-consumer-finished") != null);
    for ([_]terminal.RecordingKind{ .txt, .cast }) |kind| {
        const path = if (kind == .txt) "secret-safe.txt" else "secret-safe.cast";
        while (true) {
            f.service.?.exportRecording(kind, std.testing.io, f.tmp.dir, path) catch |err| {
                if (err == error.WorkerBusy) {
                    try f.tick();
                    pause();
                    continue;
                }
                return err;
            };
            break;
        }
        const recording = try f.tmp.dir.readFileAlloc(std.testing.io, path, a, .limited(1024 * 1024));
        defer a.free(recording);
        try std.testing.expect(std.mem.indexOf(u8, recording, "TEST-PRIVATE-SECRET-946c") == null);
        try std.testing.expect(std.mem.indexOf(u8, recording, "native-secret-consumer-finished") != null);
    }
}

test "production Local native secret request cancels and loses its exact grant without replay or terminal bytes" {
    var f = try Fixture.init();
    defer f.deinit();
    for ([_]bool{ false, true }) |takeover| {
        try f.run("zerowork_secret_consume");
        const deadline = native.zw_local_monotonic_ms() + 5000;
        var waiting: execution.Snapshot = undefined;
        while (true) {
            try f.tick();
            waiting = try f.awaitSnapshot();
            if (waiting.input_wait != null) break;
            if (waiting.failure != null or native.zw_local_monotonic_ms() >= deadline) return error.SecretWaitTimeout;
            pause();
        }
        const request: execution.InputRequest = .{ .grant = waiting.grant.?, .wait_sequence = waiting.input_wait.?.sequence, .input_sequence = 1, .kind = .host_secret };
        while (true) {
            _ = f.service.?.executionSecret(.{ .begin = request }) catch |err| {
                if (err == error.WorkerBusy) {
                    try f.tick();
                    pause();
                    continue;
                }
                return err;
            };
            break;
        }
        while (true) {
            if (takeover) {
                f.service.?.executionRevoke(request.grant, true) catch |err| {
                    if (err == error.WorkerBusy) {
                        try f.tick();
                        pause();
                        continue;
                    }
                    return err;
                };
            } else {
                const receipt = f.service.?.executionSecret(.{ .cancel = request }) catch |err| {
                    if (err == error.WorkerBusy) {
                        try f.tick();
                        pause();
                        continue;
                    }
                    return err;
                };
                try std.testing.expect(receipt.stage == .cancelled_unsent);
            }
            break;
        }
        const finished = try f.wait(.interval_recorded);
        try std.testing.expectEqual(@as(?u8, 1), finished.process.?.exit_code);
        try std.testing.expect(finished.input_receipt.?.stage == .cancelled_unsent and finished.input_wait == null and finished.local_released and !finished.remote_effect_unknown);
        try std.testing.expectEqual(takeover, finished.input_handed_off);
        try f.expectFailure(terminal.Service.executionSecret, .{ f.service.?, execution.SecretAction{ .submit = .{ .request = request, .bytes = "CANCELLED-SECRET-NEVER-SENT" } } }, error.StaleFence);
        try std.testing.expect(std.mem.indexOf(u8, f.output.items, "CANCELLED-SECRET-NEVER-SENT") == null);
    }
}
