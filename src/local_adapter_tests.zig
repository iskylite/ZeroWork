//! Real PTY + Ghostty + SessionHost integration, with no windows or user data.
const std = @import("std");
const local = @import("local/adapter.zig");
// Keep worker queue regressions discoverable under a narrow test filter.
comptime {
    _ = @import("local/adapter.zig");
}
const host = @import("host/session_host.zig");
const plugins = @import("host/plugin_registry.zig");
const terminal = @import("host/terminal_service.zig");
const native = @import("local/native.zig");
const text_frame = @import("vt/text_frame.zig");
const TextSlot = @import("vt/text_slot.zig").TextSlot;
const allocator = std.testing.allocator;
const archive_mod = @import("vt/session_archive.zig");
extern "c" fn setenv([*:0]const u8, [*:0]const u8, c_int) c_int;
extern "c" fn unsetenv([*:0]const u8) c_int;
const target: host.AttachmentTarget = .{ .window_id = @fromBackingInt(1), .workspace_id = @fromBackingInt(1) };
fn pause() void {
    const delay: std.c.timespec = .{ .sec = 0, .nsec = 10 * std.time.ns_per_ms };
    _ = std.c.nanosleep(&delay, null);
}
const Sandbox = struct {
    tmp: std.testing.TmpDir,
    path: [:0]u8,
    previous: ?[:0]u8,
    fn init() !Sandbox {
        var tmp = std.testing.tmpDir(.{});
        errdefer tmp.cleanup();
        try tmp.dir.writeFile(std.testing.io, .{ .sub_path = ".zshenv", .data = "setopt NO_RCS\nPROMPT=''\nRPROMPT=''\n" });
        const path = try tmp.dir.realPathFileAlloc(std.testing.io, ".", allocator);
        errdefer allocator.free(path);
        const previous = if (std.c.getenv("ZDOTDIR")) |old| try allocator.dupeSentinel(u8, std.mem.span(old), 0) else null;
        errdefer if (previous) |old| allocator.free(old);
        if (setenv("ZDOTDIR", path.ptr, 1) != 0) return error.EnvironmentFailed;
        return .{ .tmp = tmp, .path = path, .previous = previous };
    }
    fn deinit(self: *Sandbox) void {
        if (self.previous) |old| {
            _ = setenv("ZDOTDIR", old.ptr, 1);
            allocator.free(old);
        } else _ = unsetenv("ZDOTDIR");
        allocator.free(self.path);
        self.tmp.cleanup();
    }
};
const Consumer = struct { service: terminal.Service, generation: u64 = 0 };
const Rig = struct {
    adapter: *local.LocalAdapter,
    sessions: host.SessionHost,
    consumers: std.ArrayList(Consumer) = .empty,
    scratch: []u8,
    fn init() !Rig {
        return initWithOptions(.{});
    }
    fn initWithOptions(options: local.Options) !Rig {
        const adapter = try local.LocalAdapter.init(allocator, options);
        errdefer adapter.deinit() catch unreachable;
        var sessions = try host.SessionHost.init(allocator, &.{adapter.adapter()});
        errdefer sessions.deinit();
        return .{ .adapter = adapter, .sessions = sessions, .scratch = try allocator.alloc(u8, TextSlot.default_capacity) };
    }
    fn tick(self: *Rig) !void {
        _ = try self.adapter.drain(&self.sessions);
        for (self.consumers.items) |*consumer| if (try (try consumer.service.textSlot()).take(consumer.generation, self.scratch)) |frame| {
            consumer.generation = frame.generation;
        };
    }
    fn ready(self: *Rig, accepted: host.Accepted) !terminal.Service {
        const until = native.zw_local_monotonic_ms() + 5000;
        while (native.zw_local_monotonic_ms() < until) {
            try self.tick();
            if (self.sessions.queryService(accepted.handle, .terminal) == .available) {
                const service = try self.adapter.terminalService(self.sessions.queryService(accepted.handle, .terminal).available);
                try self.consumers.append(allocator, .{ .service = service });
                return service;
            }
            pause();
        }
        return error.ReadyTimeout;
    }
    fn discard(self: *Rig) void {
        for (self.consumers.items) |consumer| {
            var buffer: [4096]u8 = undefined;
            while (true) switch (consumer.service.readOutput(&buffer) catch break) {
                .bytes => {},
                else => break,
            };
        }
    }
    fn close(self: *Rig, handle: host.SessionHandle) !void {
        _ = try self.sessions.requestClose(handle, .{});
        const until = native.zw_local_monotonic_ms() + 8000;
        while (native.zw_local_monotonic_ms() < until) {
            try self.tick();
            self.discard();
            if (self.sessions.queryState(handle).?.lifecycle == .closed) return;
            pause();
        }
        return error.CloseTimeout;
    }
    fn deinit(self: *Rig) void {
        const until = native.zw_local_monotonic_ms() + 8000;
        while (self.adapter.shutdownStep() != .released) {
            self.tick() catch unreachable;
            self.discard();
            if (native.zw_local_monotonic_ms() >= until) @panic("Local adapter did not release its real children");
            pause();
        }
        self.adapter.deinit() catch unreachable;
        self.sessions.deinit();
        self.consumers.deinit(allocator);
        allocator.free(self.scratch);
    }
};
fn collect(service: terminal.Service, output: *std.ArrayList(u8)) !void {
    var bytes: [4096]u8 = undefined;
    for (0..16) |_| switch (try service.readOutput(&bytes)) {
        .bytes => |count| try output.appendSlice(allocator, bytes[0..count]),
        else => return,
    };
}
fn waitText(rig: *Rig, service: terminal.Service, output: *std.ArrayList(u8), expected: []const u8) !void {
    const until = native.zw_local_monotonic_ms() + 5000;
    while (native.zw_local_monotonic_ms() < until) {
        try rig.tick();
        try collect(service, output);
        if (std.mem.indexOf(u8, output.items, expected) != null) return;
        pause();
    }
    return error.OutputTimeout;
}

// WorkerBusy is explicit mailbox backpressure; retry the same request ID.
fn write(service: terminal.Service, request: terminal.WriteRequest) !terminal.Submission {
    const until = native.zw_local_monotonic_ms() + 5000;
    var captured = request;
    captured.mode_revision = (try status(service)).mode_revision;
    while (native.zw_local_monotonic_ms() < until) {
        return service.write(captured) catch |err| {
            if (err != error.WorkerBusy) return err;
            pause();
            continue;
        };
    }
    return error.WorkerTimeout;
}
fn resize(service: terminal.Service, geometry: terminal.Geometry) !void {
    const until = native.zw_local_monotonic_ms() + 5000;
    while (native.zw_local_monotonic_ms() < until) {
        return service.resize(geometry) catch |err| {
            if (err != error.WorkerBusy) return err;
            pause();
            continue;
        };
    }
    return error.WorkerTimeout;
}
fn recordingSnapshot(adapter: *local.LocalAdapter, handle: host.SessionHandle) !?@import("local/recording.zig").Snapshot {
    const until = native.zw_local_monotonic_ms() + 5000;
    while (native.zw_local_monotonic_ms() < until) {
        return adapter.recordingSnapshot(handle) catch |err| {
            if (err != error.WorkerBusy) return err;
            pause();
            continue;
        };
    }
    return error.WorkerTimeout;
}
fn status(service: terminal.Service) !terminal.Status {
    const until = native.zw_local_monotonic_ms() + 5000;
    while (native.zw_local_monotonic_ms() < until) {
        return service.status() catch |err| {
            if (err != error.WorkerBusy) return err;
            pause();
            continue;
        };
    }
    return error.WorkerTimeout;
}
fn snapshot(service: terminal.Service) !terminal.TerminalSnapshot {
    const until = native.zw_local_monotonic_ms() + 5000;
    while (native.zw_local_monotonic_ms() < until) {
        return service.snapshot(allocator) catch |err| {
            if (err != error.WorkerBusy) return err;
            pause();
            continue;
        };
    }
    return error.WorkerTimeout;
}
fn preparePaste(service: terminal.Service, text: []const u8) !terminal.Paste {
    const until = native.zw_local_monotonic_ms() + 5000;
    while (native.zw_local_monotonic_ms() < until) {
        return service.preparePaste(allocator, text) catch |err| {
            if (err != error.WorkerBusy) return err;
            pause();
            continue;
        };
    }
    return error.WorkerTimeout;
}
fn commitPaste(service: terminal.Service, paste: terminal.Paste, sequence: u64, confirmed: bool) !terminal.Submission {
    const until = native.zw_local_monotonic_ms() + 5000;
    while (native.zw_local_monotonic_ms() < until) {
        return service.commitPaste(paste, sequence, confirmed) catch |err| {
            if (err != error.WorkerBusy) return err;
            pause();
            continue;
        };
    }
    return error.WorkerTimeout;
}
fn processState(rig: *Rig, handle: host.SessionHandle) !local.ProcessSnapshot {
    const until = native.zw_local_monotonic_ms() + 5000;
    while (native.zw_local_monotonic_ms() < until) {
        return rig.adapter.processSnapshot(handle) catch |err| {
            if (err != error.WorkerBusy) return err;
            pause();
            continue;
        };
    }
    return error.WorkerTimeout;
}
fn closeRisk(rig: *Rig, handle: host.SessionHandle) !local.CloseRiskSnapshot {
    const until = native.zw_local_monotonic_ms() + 5000;
    while (native.zw_local_monotonic_ms() < until) {
        return rig.adapter.closeRiskSnapshot(handle, allocator) catch |err| {
            if (err != error.WorkerBusy) return err;
            pause();
            continue;
        };
    }
    return error.WorkerTimeout;
}
fn contextSnapshot(rig: *Rig, binding: host.ServiceHandle) !local.ContextSnapshot {
    const until = native.zw_local_monotonic_ms() + 5000;
    while (native.zw_local_monotonic_ms() < until) {
        return rig.adapter.contextSnapshot(binding, .{ .max_lines = 8, .max_bytes = 4096 }, allocator) catch |err| {
            if (err != error.WorkerBusy) return err;
            pause();
            continue;
        };
    }
    return error.WorkerTimeout;
}
fn copyCwd(rig: *Rig, handle: host.SessionHandle) !?[]u8 {
    const until = native.zw_local_monotonic_ms() + 5000;
    while (native.zw_local_monotonic_ms() < until) {
        return rig.adapter.copyCwd(handle, allocator) catch |err| {
            if (err != error.WorkerBusy) return err;
            pause();
            continue;
        };
    }
    return error.WorkerTimeout;
}
fn startExec(rig: *Rig, binding: host.ServiceHandle, request: local.ExecRequest) !local.ExecHandle {
    const until = native.zw_local_monotonic_ms() + 5000;
    while (native.zw_local_monotonic_ms() < until) {
        return rig.adapter.startExec(binding, request) catch |err| {
            if (err != error.WorkerBusy) return err;
            pause();
            continue;
        };
    }
    return error.WorkerTimeout;
}
fn execSnapshot(rig: *Rig, handle: local.ExecHandle) !local.ExecSnapshot {
    const until = native.zw_local_monotonic_ms() + 5000;
    while (native.zw_local_monotonic_ms() < until) {
        return rig.adapter.execSnapshot(handle, allocator) catch |err| {
            if (err != error.WorkerBusy) return err;
            pause();
            continue;
        };
    }
    return error.WorkerTimeout;
}
fn waitWriteReceipt(service: terminal.Service) !terminal.WriteReceipt {
    const until = native.zw_local_monotonic_ms() + 5000;
    while (native.zw_local_monotonic_ms() < until) {
        if (try service.takeWriteReceipt()) |value| return value;
        pause();
    }
    return error.WorkerTimeout;
}

test "notification Local service exposes real PTY Bell facts and rejects released bindings" {
    var sandbox = try Sandbox.init();
    defer sandbox.deinit();
    var rig = try Rig.init();
    defer rig.deinit();
    const accepted = try rig.sessions.create(.{ .local = .{ .initial_cwd = sandbox.path } }, target);
    const service = try rig.ready(accepted);
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(allocator);
    _ = try write(service, .{ .input_sequence = 1, .bytes = "printf '\\033]0;notification-title\\007'; printf '%s_%s\\n' 'OSC' 'ONLY'\n" });
    try waitText(&rig, service, &output, "OSC_ONLY");
    const osc = (try status(service)).notification();
    try std.testing.expect(osc.owner.eql(accepted.handle));
    try std.testing.expect(osc.output_sequence > 0);
    try std.testing.expectEqual(@as(u64, 0), osc.bell_count);
    _ = try write(service, .{ .input_sequence = 2, .bytes = "printf '\\007\\007'; printf '%s_%s\\n' 'BELL' 'DONE'\n" });
    try waitText(&rig, service, &output, "BELL_DONE");
    const bell = (try status(service)).notification();
    try std.testing.expect(bell.owner.eql(accepted.handle));
    try std.testing.expect(bell.output_sequence > osc.output_sequence);
    try std.testing.expectEqual(@as(u64, 2), bell.bell_count);
    var displayed = try snapshot(service);
    defer displayed.deinit(allocator);
    try std.testing.expect(displayed.owner.eql(accepted.handle));
    try std.testing.expect(displayed.output_sequence > 0 and displayed.output_sequence <= bell.output_sequence);
    for (0..4) |_| {
        try rig.tick();
        try std.testing.expectEqual(bell.bell_count, (try status(service)).notification().bell_count);
    }
    try rig.close(accepted.handle);
    try std.testing.expectEqual(bell.bell_count, (try status(service)).notification().bell_count);
    rig.consumers.clearRetainingCapacity();
    try rig.adapter.retire(accepted.handle);
    try std.testing.expectError(error.StaleSession, service.status());
}

test "silent local metadata changes wake presentation without text generations or idle sampling redraws" {
    var sandbox = try Sandbox.init();
    defer sandbox.deinit();
    try sandbox.tmp.dir.createDir(std.testing.io, "child", .default_dir);
    try sandbox.tmp.dir.writeFile(std.testing.io, .{ .sub_path = ".zshenv", .data = "setopt NO_RCS\nPROMPT=''\nRPROMPT=''\nsleep 0.6\nbuiltin cd child\nsleep 30\n" });
    var rig = try Rig.init();
    defer rig.deinit();
    const accepted = try rig.sessions.create(.{ .local = .{ .initial_cwd = sandbox.path } }, target);
    const service = try rig.ready(accepted);
    const slot = try service.textSlot();
    for (0..20) |_| pause();
    const generation = slot.generation.load(.acquire);
    _ = @import("platform/presentation_wakeup.zig").take();
    const child = try std.fmt.allocPrint(allocator, "{s}/child", .{sandbox.path});
    defer allocator.free(child);
    const deadline = native.zw_local_monotonic_ms() + 3000;
    while (true) {
        const cwd = try copyCwd(&rig, accepted.handle);
        defer if (cwd) |value| allocator.free(value);
        if (cwd) |value| if (std.mem.eql(u8, value, child)) break;
        if (native.zw_local_monotonic_ms() >= deadline) return error.MetadataTimeout;
        pause();
    }
    try std.testing.expectEqual(generation, slot.generation.load(.acquire));
    try std.testing.expect(@import("platform/presentation_wakeup.zig").take());
    // Cross another metadata deadline while the same child stays foreground.
    for (0..35) |_| pause();
    try std.testing.expect(!@import("platform/presentation_wakeup.zig").take());
    try rig.close(accepted.handle);
}

test "local adapter creates isolated real terminals, applies resize and returns actual write receipts" {
    var sandbox = try Sandbox.init();
    defer sandbox.deinit();
    var rig = try Rig.init();
    defer rig.deinit();
    const a = try rig.sessions.create(.{ .local = .{ .initial_cwd = sandbox.path } }, target);
    const b = try rig.sessions.create(.{ .local = .{ .initial_cwd = sandbox.path } }, target);
    const first = try rig.ready(a);
    const second = try rig.ready(b);
    try std.testing.expect(!a.handle.eql(b.handle));
    try std.testing.expect((try processState(&rig, a.handle)).pid != (try processState(&rig, b.handle)).pid);
    const cwd = (try copyCwd(&rig, a.handle)).?;
    defer allocator.free(cwd);
    try std.testing.expectEqualStrings(sandbox.path, cwd);
    const input_a = "printf '%s_%s\\n' 'LOCAL' 'A'\n";
    const input_b = "printf '%s_%s\\n' 'LOCAL' 'B'\n";
    _ = try write(first, .{ .input_sequence = 1, .bytes = input_a });
    _ = try write(second, .{ .input_sequence = 1, .bytes = input_b });
    try std.testing.expectError(error.StaleInput, write(first, .{ .input_sequence = 1, .bytes = input_a }));
    var output_a: std.ArrayList(u8) = .empty;
    defer output_a.deinit(allocator);
    var output_b: std.ArrayList(u8) = .empty;
    defer output_b.deinit(allocator);
    try waitText(&rig, first, &output_a, "LOCAL_A");
    try waitText(&rig, second, &output_b, "LOCAL_B");
    try std.testing.expect(std.mem.indexOf(u8, output_a.items, "LOCAL_B") == null);
    try std.testing.expect(std.mem.indexOf(u8, output_b.items, "LOCAL_A") == null);
    const receipt = try waitWriteReceipt(first);
    try std.testing.expectEqual(@as(u64, 1), receipt.input_sequence);
    try std.testing.expectEqual(input_a.len, receipt.consumed_bytes);
    try std.testing.expectEqual(.completed, receipt.state);
    try resize(first, .{ .revision = 2, .cols = 93, .rows = 31 });
    try std.testing.expectError(error.StaleGeometry, resize(first, .{ .revision = 2, .cols = 70, .rows = 20 }));
    const until = native.zw_local_monotonic_ms() + 3000;
    while ((try status(first)).geometry.revision != 2) {
        try rig.tick();
        if (native.zw_local_monotonic_ms() >= until) return error.ResizeTimeout;
        pause();
    }
    var applied = try snapshot(first);
    defer applied.deinit(allocator);
    try std.testing.expect(applied.owner.eql(a.handle));
    try std.testing.expectEqual(@as(u64, 2), applied.geometry_revision);
    try std.testing.expectEqual(@as(u16, 93), applied.projection.cols);
    try std.testing.expectEqual(@as(u16, 31), applied.projection.rows);
    _ = try write(first, .{ .input_sequence = 2, .bytes = "stty size\n" });
    try waitText(&rig, first, &output_a, "31 93");
    const frame = (try (try first.textSlot()).take(0, rig.scratch)).?;
    try std.testing.expectEqual(@as(u16, 93), text_frame.decode(frame.text).?.cols);
    try std.testing.expectEqual(@as(u16, 31), text_frame.decode(frame.text).?.rows);
    _ = try rig.sessions.requestClose(b.handle, .{});
    try std.testing.expectError(error.ServiceUnavailable, write(second, .{ .input_sequence = 2, .bytes = "ignored\n" }));
    try rig.close(b.handle);
    try std.testing.expect((try status(first)).writable);
    try rig.close(a.handle);
    rig.consumers.clearRetainingCapacity();
    try rig.adapter.retire(a.handle);
    try rig.adapter.retire(b.handle);
    var old_buffer: [8]u8 = undefined;
    try std.testing.expectError(error.StaleSession, first.readOutput(&old_buffer));
}

test "local adapter retries a released startup failure and rejects old generation receipts" {
    var sandbox = try Sandbox.init();
    defer sandbox.deinit();
    const absent = try std.fs.path.join(allocator, &.{ sandbox.path, "initial directory" });
    defer allocator.free(absent);
    var rig = try Rig.init();
    defer rig.deinit();
    const original = try rig.sessions.create(.{ .local = .{ .initial_cwd = absent } }, target);
    const until = native.zw_local_monotonic_ms() + 5000;
    while (rig.sessions.queryState(original.handle).?.create_cleanup != .released) {
        try rig.tick();
        if (native.zw_local_monotonic_ms() >= until) return error.FailureTimeout;
        pause();
    }
    try std.testing.expectEqual(host.Lifecycle.failed, rig.sessions.queryState(original.handle).?.lifecycle);
    try sandbox.tmp.dir.createDir(std.testing.io, "initial directory", .default_dir);
    const retried = try rig.sessions.retry(original.handle);
    try std.testing.expectEqual(original.handle.session_id, retried.handle.session_id);
    try std.testing.expectEqual(original.handle.generation + 1, retried.handle.generation);
    const service = try rig.ready(retried);
    try std.testing.expect(!try rig.sessions.ready(original.handle, original.operation, plugins.requiredServices(.local)));
    try std.testing.expect(!try rig.sessions.createCleanupReceipt(original.handle, original.operation, .released));
    try std.testing.expectError(error.LifecycleDoesNotAllowRetry, rig.sessions.retry(retried.handle));
    _ = try write(service, .{ .input_sequence = 1, .bytes = "printf '%s_%s\\n' 'RETRY' 'OK'\n" });
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(allocator);
    try waitText(&rig, service, &output, "RETRY_OK");
    try rig.close(retried.handle);
}

test "local adapter exec is independent, uses the same journal and cancels on close" {
    var sandbox = try Sandbox.init();
    defer sandbox.deinit();
    var rig = try Rig.init();
    defer rig.deinit();
    const accepted = try rig.sessions.create(.{ .local = .{ .initial_cwd = sandbox.path } }, target);
    const service = try rig.ready(accepted);
    const binding = rig.sessions.queryService(accepted.handle, .exec).available;
    const operation = try rig.sessions.journal.begin(.{ .session = accepted.handle }, 1);
    const call = try startExec(&rig, binding, .{ .operation = operation, .call_id = 1, .command = "printf '%s_%s' 'EXEC' 'OUT'; printf '%s_%s' 'EXEC' 'ERR' >&2; exit 7", .cwd = sandbox.path });
    const until = native.zw_local_monotonic_ms() + 5000;
    while (true) {
        try rig.tick();
        var result = try execSnapshot(&rig, call);
        defer result.deinit(allocator);
        if (result.done) {
            try std.testing.expectEqualStrings("EXEC_OUT", result.stdout);
            try std.testing.expectEqualStrings("EXEC_ERR", result.stderr);
            try std.testing.expectEqual(@as(u8, 7), result.exit.?.exited);
            try std.testing.expectEqual(host.CloseReceipt.released, result.cleanup);
            break;
        }
        if (native.zw_local_monotonic_ms() >= until) return error.ExecTimeout;
        pause();
    }
    try rig.tick();
    try std.testing.expect(rig.sessions.journal.isTerminal(operation));
    try rig.adapter.retireExec(call);
    try std.testing.expectError(error.StaleExecCall, startExec(&rig, binding, .{ .operation = operation, .call_id = 1, .command = "must not run" }));
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(allocator);
    try collect(service, &output);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "EXEC_OUT") == null);
    const sleeping_key = try rig.sessions.journal.begin(.{ .session = accepted.handle }, 1);
    const sleeping = try startExec(&rig, binding, .{ .operation = sleeping_key, .call_id = 2, .command = "sleep 30", .cwd = sandbox.path });
    var impact = try closeRisk(&rig, accepted.handle);
    defer impact.deinit(allocator);
    try std.testing.expect(impact.owner.eql(accepted.handle));
    try std.testing.expectEqual(@as(usize, 1), impact.active_exec.len);
    try std.testing.expectEqualStrings("sleep 30", impact.active_exec[0].command);
    try std.testing.expectEqual(sleeping.call_id, impact.active_exec[0].handle.call_id);
    try std.testing.expect(impact.active_exec[0].state == .pending or impact.active_exec[0].pid.? > 0);
    try rig.tick();
    pause();
    try rig.close(accepted.handle);
    var result = try execSnapshot(&rig, sleeping);
    defer result.deinit(allocator);
    try std.testing.expect(result.done and result.cancelled);
    try std.testing.expectEqual(host.CloseReceipt.released, result.cleanup);
}

test "local adapter cancellation waits for cleanup and normal exit cannot retry" {
    var sandbox = try Sandbox.init();
    defer sandbox.deinit();
    var rig = try Rig.init();
    defer rig.deinit();
    const cancelled = try rig.sessions.create(.{ .local = .{ .initial_cwd = sandbox.path } }, target);
    try std.testing.expect(try rig.sessions.cancel(cancelled.operation));
    try std.testing.expectError(error.CleanupNotReleased, rig.sessions.retry(cancelled.handle));
    const until = native.zw_local_monotonic_ms() + 5000;
    while (rig.sessions.queryState(cancelled.handle).?.create_cleanup != .released) {
        try rig.tick();
        if (native.zw_local_monotonic_ms() >= until) return error.CancelTimeout;
        pause();
    }
    const accepted = try rig.sessions.create(.{ .local = .{ .initial_cwd = sandbox.path } }, target);
    const service = try rig.ready(accepted);
    _ = try write(service, .{ .input_sequence = 1, .bytes = "printf '%s_%s\\n' 'FINAL' 'TAIL'; exit 3\n" });
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(allocator);
    try waitText(&rig, service, &output, "FINAL_TAIL");
    const exited_until = native.zw_local_monotonic_ms() + 5000;
    while ((try processState(&rig, accepted.handle)).cleanup != .released) {
        try rig.tick();
        try collect(service, &output);
        if (native.zw_local_monotonic_ms() >= exited_until) return error.ExitTimeout;
        pause();
    }
    const process = try processState(&rig, accepted.handle);
    try std.testing.expectEqual(.exited, process.state);
    try std.testing.expectEqual(@as(u8, 3), process.exit.?.exited);
    try std.testing.expect(process.eof_seen);
    try std.testing.expectError(error.SessionStillPresented, rig.adapter.retire(accepted.handle));
    try std.testing.expect(!(try status(service)).writable);
    try std.testing.expectError(error.SessionNotWritable, write(service, .{ .input_sequence = 2, .bytes = "ignored\n" }));
    try std.testing.expectError(error.LifecycleDoesNotAllowRetry, rig.sessions.retry(accepted.handle));
    const opened = try rig.sessions.create(.{ .local = .{ .initial_cwd = sandbox.path } }, target);
    try std.testing.expect(opened.handle.session_id != accepted.handle.session_id);
    _ = try rig.ready(opened);
    try rig.close(accepted.handle);
    try rig.close(opened.handle);
}

test "local raw owner drain releases a cancelled attempt without a ready binding" {
    var sandbox = try Sandbox.init();
    defer sandbox.deinit();
    try sandbox.tmp.dir.writeFile(std.testing.io, .{ .sub_path = ".zshenv", .data = "setopt NO_RCS\nPROMPT=''\nRPROMPT=''\nprintf '%09000d\\n' 0\nprintf '%s\\n' RAW_OWNER_TAIL\n" });
    var rig = try Rig.initWithOptions(.{ .output_capacity = 4096 });
    defer rig.deinit();
    const attempt = try rig.sessions.create(.{ .local = .{ .initial_cwd = sandbox.path } }, target);
    try std.testing.expect(rig.sessions.queryService(attempt.handle, .terminal) != .available);
    var buffer: [1024]u8 = undefined;
    const output_until = native.zw_local_monotonic_ms() + 3000;
    var first_bytes: usize = 0;
    while (first_bytes == 0) {
        switch (try rig.adapter.readOutput(attempt.handle, &buffer)) {
            .bytes => |count| first_bytes = count,
            .would_block => {},
            .eof => return error.UnexpectedEof,
        }
        if (native.zw_local_monotonic_ms() >= output_until) return error.OutputTimeout;
        pause();
    }
    // No host drain/ready callback has run, despite real startup output.
    try std.testing.expect(rig.sessions.queryService(attempt.handle, .terminal) != .available);
    try std.testing.expect(try rig.sessions.cancel(attempt.operation));
    var saw_eof = false;
    var tail_bytes: usize = 0;
    const until = native.zw_local_monotonic_ms() + 6000;
    while (!saw_eof or rig.sessions.queryState(attempt.handle).?.create_cleanup != .released) {
        while (true) switch (try rig.adapter.readOutput(attempt.handle, &buffer)) {
            .bytes => |count| tail_bytes += count,
            .eof => {
                saw_eof = true;
                break;
            },
            .would_block => break,
        };
        try rig.tick();
        if (native.zw_local_monotonic_ms() >= until) return error.CancelTimeout;
        pause();
    }
    try std.testing.expect(tail_bytes > 0);
    try std.testing.expectError(error.StaleSession, rig.adapter.readOutput(try attempt.handle.nextGeneration(), &buffer));
    try std.testing.expect(rig.sessions.queryService(attempt.handle, .terminal) != .available);
}

test "local adapter resumes bounded output after backpressure and preserves the EOF tail frame" {
    var sandbox = try Sandbox.init();
    defer sandbox.deinit();
    var rig = try Rig.initWithOptions(.{ .output_capacity = 4096 });
    defer rig.deinit();
    const accepted = try rig.sessions.create(.{ .local = .{ .initial_cwd = sandbox.path } }, target);
    const service = try rig.ready(accepted);
    _ = try write(service, .{ .input_sequence = 1, .bytes = "repeat 9000 printf x; printf '%s_%s\\n' 'BUFFER' 'TAIL'; exit 0\n" });
    // No raw-output consumer yet: the worker must stop at its bounded queue,
    // not discard output or treat the full queue/EAGAIN as EOF.
    for (0..25) |_| pause();
    try std.testing.expect(!(try status(service)).eof_seen);
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(allocator);
    try waitText(&rig, service, &output, "BUFFER_TAIL");
    const until = native.zw_local_monotonic_ms() + 5000;
    while ((try processState(&rig, accepted.handle)).cleanup != .released) {
        try rig.tick();
        try collect(service, &output);
        if (native.zw_local_monotonic_ms() >= until) return error.EofTimeout;
        pause();
    }
    try std.testing.expect(std.mem.count(u8, output.items, "x") >= 9000);
    try rig.tick();
    const frame = (try (try service.textSlot()).take(0, rig.scratch)).?;
    try std.testing.expect(std.mem.indexOf(u8, text_frame.decode(frame.text).?.text, "BUFFER_TAIL") != null);
    try rig.close(accepted.handle);
}

test "local adapter serves owned snapshots validates paste and writes real parser replies" {
    var sandbox = try Sandbox.init();
    defer sandbox.deinit();
    var rig = try Rig.init();
    defer rig.deinit();
    const accepted = try rig.sessions.create(.{ .local = .{ .initial_cwd = sandbox.path } }, target);
    const service = try rig.ready(accepted);
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(allocator);
    _ = try write(service, .{ .input_sequence = 1, .bytes = "printf '\\033[?2004h\\033[?1000h\\033[?1006h\\033]7;file://localhost/fake/prompt\\007'; printf '%s_%s\\n' 'MODE' 'READY'\n" });
    try waitText(&rig, service, &output, "MODE_READY");
    _ = try waitWriteReceipt(service);
    // Raw PTY bytes and a write receipt can arrive before the cadence-limited
    // viewport. Wait for publication of the observed output, not just any frame.
    const observed_sequence = (try status(service)).output_sequence;
    const published_until = native.zw_local_monotonic_ms() + 3000;
    var initial = published: while (true) {
        var value = try snapshot(service);
        if (value.output_sequence >= observed_sequence) break :published value;
        value.deinit(allocator);
        if (native.zw_local_monotonic_ms() >= published_until) return error.PublicationTimeout;
        try rig.tick();
        pause();
    };
    defer initial.deinit(allocator);
    try std.testing.expect(initial.owner.eql(accepted.handle) and !initial.read_only);
    try std.testing.expect(initial.projection.modes.bracketed_paste);
    try std.testing.expectEqual(.normal, initial.projection.modes.mouse_tracking);
    try std.testing.expectEqualStrings("/fake/prompt", initial.projection.reported_cwd.?);
    const cwd_until = native.zw_local_monotonic_ms() + 3000;
    while (true) {
        var cwd = rig.adapter.cwdSnapshot(accepted.handle, allocator) catch |err| {
            if (err != error.WorkerBusy) return err;
            pause();
            continue;
        };
        defer cwd.deinit(allocator);
        if (cwd.source == .process) {
            try std.testing.expectEqualStrings(sandbox.path, cwd.value.?);
            break;
        }
        if (native.zw_local_monotonic_ms() >= cwd_until) return error.CwdTimeout;
        pause();
    }
    const idle_until = native.zw_local_monotonic_ms() + 3000;
    while (true) {
        var risk = try closeRisk(&rig, accepted.handle);
        defer risk.deinit(allocator);
        if (risk.foreground_state == .idle_shell) {
            try std.testing.expect(risk.owner.eql(accepted.handle) and !risk.unknown);
            try std.testing.expectEqual(@as(usize, 0), risk.active_exec.len);
            break;
        }
        if (native.zw_local_monotonic_ms() >= idle_until) return error.IdleForegroundTimeout;
        pause();
    }
    try std.testing.expectError(error.InvalidPaste, preparePaste(service, "a\n\x1b[201~evil"));
    try std.testing.expectError(error.InvalidPaste, preparePaste(service, "\xff"));
    var paste = try preparePaste(service, "printf '%s_%s\\n' 'PASTE' 'ON'");
    defer paste.deinit(allocator);
    const submitted = try commitPaste(service, paste, 2, false);
    try std.testing.expectEqual(paste.text.len + 12, submitted.queued_bytes);
    const receipt = try waitWriteReceipt(service);
    try std.testing.expectEqual(paste.text.len + 12, receipt.consumed_bytes);
    try std.testing.expectError(error.StaleInput, commitPaste(service, paste, 3, false));
    pause();
    try collect(service, &output);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "PASTE_ON") == null);
    const enter_revision = (try status(service)).mode_revision;
    const key_until = native.zw_local_monotonic_ms() + 3000;
    while (true) {
        _ = service.writeKey(.{ .input_sequence = 3, .mode_revision = enter_revision, .event = .{ .key = .enter } }) catch |err| {
            if (err != error.WorkerBusy or native.zw_local_monotonic_ms() >= key_until) return err;
            pause();
            continue;
        };
        break;
    }
    try waitText(&rig, service, &output, "PASTE_ON");
    _ = try waitWriteReceipt(service);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, output.items, "PASTE_ON"));
    var context = try contextSnapshot(&rig, service.binding);
    defer context.deinit();
    try std.testing.expect(context.owner.eql(accepted.handle));
    var block = try context.provider().read_lines(context.provider().ctx, 8, allocator);
    defer block.deinit(allocator);
    var found_output = false;
    for (block.lines) |line| if (std.mem.indexOf(u8, line, "PASTE_ON") != null) {
        found_output = true;
    };
    try std.testing.expect(found_output);
    try std.testing.expectEqualStrings(sandbox.path, block.cwd.?);
    try std.testing.expectEqualStrings("/bin/zsh", block.shell.?);
    var submitted_snapshot = try snapshot(service);
    defer submitted_snapshot.deinit(allocator);
    var found_submission = false;
    for (submitted_snapshot.projection.visible_rows) |row| if (row.submitted_wallclock_ms != null) {
        found_submission = true;
    };
    try std.testing.expect(found_submission);
    var pending = try preparePaste(service, "one\ntwo");
    defer pending.deinit(allocator);
    try std.testing.expect(pending.requires_confirmation);
    try std.testing.expectError(error.ConfirmationRequired, commitPaste(service, pending, 4, false));
    var old_mode = try preparePaste(service, "discard");
    defer old_mode.deinit(allocator);
    _ = try write(service, .{ .input_sequence = 4, .bytes = "stty -echo -icanon min 1 time 0; printf '\\033[?2004l'; printf '%s_%s\\n' 'PASTE' 'OFF_READY'; dd bs=1 count=3 2>/dev/null | od -An -tx1; stty sane\n" });
    try waitText(&rig, service, &output, "PASTE_OFF_READY");
    _ = try waitWriteReceipt(service);
    try std.testing.expectError(error.StaleMode, commitPaste(service, old_mode, 5, true));
    const foreground_until = native.zw_local_monotonic_ms() + 3000;
    while (true) {
        const process = try processState(&rig, accepted.handle);
        if (process.foreground) |foreground| if (foreground.process_group != process.pid.?) {
            try std.testing.expectEqual(process.pid.?, foreground.session_id);
            break;
        };
        if (native.zw_local_monotonic_ms() >= foreground_until) return error.ForegroundTimeout;
        pause();
    }
    var plain = try preparePaste(service, "abc");
    defer plain.deinit(allocator);
    const plain_submission = try commitPaste(service, plain, 5, false);
    try std.testing.expectEqual(@as(usize, 3), plain_submission.queued_bytes);
    const plain_receipt = try waitWriteReceipt(service);
    try std.testing.expectEqual(.completed, plain_receipt.state);
    try std.testing.expectEqual(@as(usize, 3), plain_receipt.consumed_bytes);
    try waitText(&rig, service, &output, "61  62  63");
    pause();
    _ = try write(service, .{ .input_sequence = 6, .bytes = "stty -echo -icanon min 1 time 0; printf '\\033[5n'; reply=$(dd bs=1 count=4 2>/dev/null); stty sane; printf '%s_%s ' 'PARSER' 'REPLY'; printf %s \"$reply\" | od -An -tx1\n" });
    try waitText(&rig, service, &output, "1b  5b  30  6e");
    try std.testing.expect(std.mem.indexOf(u8, output.items, "PARSER_REPLY") != null);
    try std.testing.expect(initial.projection.modes.bracketed_paste); // still owned old projection
    try rig.close(accepted.handle);
    var closed = try snapshot(service);
    defer closed.deinit(allocator);
    try std.testing.expect(closed.read_only and closed.eof_seen);
}

test "local recording captures real zsh output resize frozen policy and exit archive" {
    var sandbox = try Sandbox.init();
    defer sandbox.deinit();
    var rig = try Rig.initWithOptions(.{ .recording = .{ .io = std.testing.io, .directory = sandbox.path, .log = .{ .ring_mb = 1, .checkpoint_sec = 1 } } });
    defer rig.deinit();
    const accepted = try rig.sessions.create(.{ .local = .{ .initial_cwd = sandbox.path } }, target);
    const service = try rig.ready(accepted);
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(allocator);
    _ = try write(service, .{ .input_sequence = 1, .bytes = "printf '%s_%s\\n' 'RECORD' 'OUTPUT'\n" });
    try waitText(&rig, service, &output, "RECORD_OUTPUT");
    try service.resize(.{ .revision = 2, .cols = 100, .rows = 30 });
    const until_resize = native.zw_local_monotonic_ms() + 5000;
    while ((try status(service)).geometry.revision != 2) {
        if (native.zw_local_monotonic_ms() > until_resize) return error.ResizeTimeout;
        try rig.tick();
        rig.discard();
        pause();
    }
    try rig.adapter.configureRecording(.{ .io = std.testing.io, .directory = sandbox.path, .log = .{ .ring_mb = 2, .checkpoint_sec = 9, .retention_days = 2 } });
    const frozen = (try recordingSnapshot(rig.adapter, accepted.handle)).?;
    try std.testing.expectEqual(@as(usize, 1024 * 1024), frozen.max_bytes);
    try std.testing.expectEqual(@as(u16, 1), frozen.checkpoint_sec);
    const due = native.zw_local_monotonic_ms() + 1100;
    while (native.zw_local_monotonic_ms() < due) {
        try rig.tick();
        rig.discard();
        pause();
    }
    _ = try write(service, .{ .input_sequence = 2, .bytes = "printf '%s_%s\\n' 'CHECKPOINT' 'OUTPUT'\n" });
    try waitText(&rig, service, &output, "CHECKPOINT_OUTPUT");
    const due_checkpoint = native.zw_local_monotonic_ms() + 5000;
    while ((try recordingSnapshot(rig.adapter, accepted.handle)).?.checkpoint_count == 0) {
        if (native.zw_local_monotonic_ms() > due_checkpoint) return error.CheckpointTimeout;
        try rig.tick();
        rig.discard();
        pause();
    }
    try service.exportRecording(.cast, std.testing.io, sandbox.tmp.dir, "live.cast");
    const cast = try sandbox.tmp.dir.readFileAlloc(std.testing.io, "live.cast", allocator, .limited(2 * 1024 * 1024));
    defer allocator.free(cast);
    try std.testing.expect(std.mem.indexOf(u8, cast, "RECORD_OUTPUT") != null);
    try std.testing.expect(std.mem.indexOf(u8, cast, "\"r\",\"100x30\"") != null);
    _ = try write(service, .{ .input_sequence = 3, .bytes = "exit 7\n" });
    const until_closed = native.zw_local_monotonic_ms() + 5000;
    while (!(try recordingSnapshot(rig.adapter, accepted.handle)).?.closed) {
        if (native.zw_local_monotonic_ms() > until_closed) return error.RecordingCloseTimeout;
        try rig.tick();
        rig.discard();
        pause();
    }
    try rig.close(accepted.handle);
    const recorded = (try recordingSnapshot(rig.adapter, accepted.handle)).?;
    try std.testing.expect(recorded.archived and recorded.failure == null and recorded.dropped_bytes == 0);
    var archive: archive_mod.Archive = .{ .allocator = allocator, .io = std.testing.io, .dir = sandbox.tmp.dir };
    var entries = try archive.load(allocator);
    defer archive.freeEntries(&entries);
    try std.testing.expectEqual(@as(usize, 1), entries.items.len);
    const entry = entries.items[0];
    try std.testing.expectEqual(@backingInt(accepted.handle.session_id), entry.id);
    try std.testing.expect(entry.started_ms > 1_500_000_000_000 and entry.ended_ms >= entry.started_ms);
    try std.testing.expectEqual(@as(?i32, 7), entry.exit_code);
    const c = @import("generated_ghostty_vt");
    const stem = std.fs.path.stem(entry.cast_path);
    const checkpoint_path = try std.fmt.allocPrint(allocator, "logs/{s}.checkpoint", .{stem});
    defer allocator.free(checkpoint_path);
    const restored = try @import("local/recording.zig").Recording.restore(allocator, std.testing.io, sandbox.tmp.dir, checkpoint_path, 4 * 1024 * 1024);
    defer c.ghostty_terminal_free(restored);
    var restored_cols: u16 = 0;
    var restored_rows: u16 = 0;
    try std.testing.expectEqual(c.GHOSTTY_SUCCESS, c.ghostty_terminal_get(restored, c.GHOSTTY_TERMINAL_DATA_COLS, &restored_cols));
    try std.testing.expectEqual(c.GHOSTTY_SUCCESS, c.ghostty_terminal_get(restored, c.GHOSTTY_TERMINAL_DATA_ROWS, &restored_rows));
    try std.testing.expectEqual(@as(u16, 100), restored_cols);
    try std.testing.expectEqual(@as(u16, 30), restored_rows);
    var lease = try archive_mod.acquireLease(allocator, std.testing.io, sandbox.tmp.dir, entry.cast_path);
    defer lease.deinit();
    try std.testing.expectEqual(@as(usize, 0), try archive.prune(1, entry.ended_ms + 2 * std.time.ms_per_day));
    lease.deinit();
    try std.testing.expectEqual(@as(usize, 1), try archive.prune(1, entry.ended_ms + 2 * std.time.ms_per_day));
}

test "local recording IO failure reports separately and live zsh keeps working" {
    var sandbox = try Sandbox.init();
    defer sandbox.deinit();
    try sandbox.tmp.dir.writeFile(std.testing.io, .{ .sub_path = "blocked", .data = "file" });
    const blocked = try std.fs.path.join(allocator, &.{ sandbox.path, "blocked" });
    defer allocator.free(blocked);
    var rig = try Rig.initWithOptions(.{ .recording = .{ .io = std.testing.io, .directory = blocked, .log = .{ .ring_mb = 1, .checkpoint_sec = 1 } } });
    defer rig.deinit();
    const accepted = try rig.sessions.create(.{ .local = .{ .initial_cwd = sandbox.path } }, target);
    const service = try rig.ready(accepted);
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(allocator);
    _ = try write(service, .{ .input_sequence = 1, .bytes = "printf '%s_%s\\n' 'LIVE' 'AFTER_FAILURE'\n" });
    try waitText(&rig, service, &output, "LIVE_AFTER_FAILURE");
    const state = try status(service);
    try std.testing.expect(state.writable and state.terminal_error == null and state.recording_error != null);
    try std.testing.expectError(error.RecordingUnavailable, rig.adapter.recordingSnapshot(accepted.handle));
    try rig.close(accepted.handle);
}

test "local recording saved retention reaches active owner and retries a busy drain without changing frozen limits" {
    const config = @import("config/config.zig");
    const Runtime = @import("config/runtime_config.zig").RuntimeConfig;
    const Settings = @import("config/settings_controller.zig").Controller;
    var sandbox = try Sandbox.init();
    defer sandbox.deinit();
    var cfg: config.Config = .{};
    cfg.log = .{ .ring_mb = 1, .checkpoint_sec = 1, .retention_days = 14 };
    var storage: [32768]u8 = undefined;
    try sandbox.tmp.dir.writeFile(std.testing.io, .{ .sub_path = "settings.toml", .data = try cfg.format(&storage) });
    var saved = try Runtime.loadOrDefault(std.testing.io, sandbox.tmp.dir, allocator, "settings.toml");
    defer saved.deinit();
    var settings = try Settings.init(allocator, saved.value);
    defer settings.deinit();
    var rig = try Rig.initWithOptions(.{ .recording = .{ .io = std.testing.io, .directory = sandbox.path, .log = saved.value.log } });
    defer rig.deinit();
    const accepted = try rig.sessions.create(.{ .local = .{ .initial_cwd = sandbox.path } }, target);
    _ = try rig.ready(accepted);
    rig.adapter.applyRecordingRetention(saved.value.config_revision, saved.value.log.retention_days);
    const now = @import("platform/realtime.zig").milliseconds(undefined);
    try sandbox.tmp.dir.createDirPath(std.testing.io, "logs/history");
    try sandbox.tmp.dir.writeFile(std.testing.io, .{ .sub_path = "logs/history/older-retention.cast", .data = "old recording" });
    var archive: archive_mod.Archive = .{ .allocator = allocator, .io = std.testing.io, .dir = sandbox.tmp.dir };
    try archive.append(.{ .id = 9999, .started_ms = now - 5 * std.time.ms_per_day, .ended_ms = now - 4 * std.time.ms_per_day, .duration_ms = 0, .host = "fixture", .user = "fixture", .cast_path = "logs/history/older-retention.cast" });
    try settings.editKey("log", "retention_days", .{ .unsigned = 2 });
    try settings.editKey("log", "ring_mb", .{ .unsigned = 2 });
    try settings.editKey("log", "checkpoint_sec", .{ .unsigned = 9 });
    const original_revision = saved.value.config_revision;
    try settings.save(std.testing.io, sandbox.tmp.dir, &saved);
    try std.testing.expect(saved.value.config_revision != original_revision);
    const entry = rig.adapter.entries.items[0];
    {
        // Hold the exact worker mutex: neither publication nor drain may wait.
        while (!entry.mutex.state.tryLock()) std.atomic.spinLoopHint();
        defer entry.mutex.state.unlock();
        try std.testing.expectEqual(@as(u16, 14), entry.recording.?.retention_days.load(.acquire));
        rig.adapter.applyRecordingRetention(saved.value.config_revision, saved.value.log.retention_days);
        try std.testing.expect(try rig.adapter.drain(&rig.sessions));
        try std.testing.expectEqual(@as(u16, 14), entry.recording.?.retention_days.load(.acquire));
        try std.testing.expectEqual(@as(u16, 2), rig.adapter.recording_retention_target.?);
    }
    const deadline = native.zw_local_monotonic_ms() + 5000;
    while (true) {
        // Same saved revision does not republish; pending target survives it.
        rig.adapter.applyRecordingRetention(saved.value.config_revision, saved.value.log.retention_days);
        try rig.tick();
        while (!entry.mutex.state.tryLock()) std.atomic.spinLoopHint();
        const applied = entry.recording.?.retention_days.load(.acquire) == 2;
        entry.mutex.state.unlock();
        if (applied) break;
        if (native.zw_local_monotonic_ms() >= deadline) return error.RetentionPublicationTimeout;
        pause();
    }
    const frozen = (try recordingSnapshot(rig.adapter, accepted.handle)).?;
    try std.testing.expectEqual(@as(usize, 1024 * 1024), frozen.max_bytes);
    try std.testing.expectEqual(@as(u16, 1), frozen.checkpoint_sec);
    // Save/publication updates policy only; no immediate deletion.
    var old = try sandbox.tmp.dir.openFile(std.testing.io, "logs/history/older-retention.cast", .{});
    old.close(std.testing.io);
    try rig.close(accepted.handle);
    try std.testing.expectError(error.FileNotFound, sandbox.tmp.dir.openFile(std.testing.io, "logs/history/older-retention.cast", .{}));
}

test "local async retained search captures and cancels with real owner cleanup" {
    var sandbox = try Sandbox.init();
    defer sandbox.deinit();
    var rig = try Rig.init();
    defer rig.deinit();
    const accepted = try rig.sessions.create(.{ .local = .{} }, target);
    const service = try rig.ready(accepted);
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(allocator);
    _ = try write(service, .{ .input_sequence = 1, .bytes = "for i in {1..2000}; do print SEARCH_ROW_$i; done; print ASYNC_''SEARCH_READY\n" });
    try waitText(&rig, service, &output, "ASYNC_SEARCH_READY");
    const task = start: while (true) {
        const value = service.beginSearch() catch |err| {
            if (err != error.WorkerBusy) return err;
            try rig.tick();
            pause();
            continue;
        };
        break :start value;
    };
    const until = native.zw_local_monotonic_ms() + 5000;
    while (!task.done.load(.acquire)) {
        try rig.tick();
        rig.discard();
        pause();
        if (native.zw_local_monotonic_ms() >= until) return error.SearchTimeout;
    }
    try std.testing.expect(task.failure == null);
    var result = task.take().?;
    task.release();
    defer result.document.deinit(@import("vt/search_task.zig").allocator);
    try std.testing.expect(result.owner.eql(accepted.handle));
    try std.testing.expect(std.mem.indexOf(u8, result.document.text, "SEARCH_ROW_2000") != null);
    const cancelled = start: while (true) {
        const value = service.beginSearch() catch |err| {
            if (err != error.WorkerBusy) return err;
            try rig.tick();
            pause();
            continue;
        };
        break :start value;
    };
    cancelled.cancelled.store(true, .release);
    cancelled.release();
    try rig.close(accepted.handle);
    rig.consumers.clearRetainingCapacity();
    try rig.adapter.retire(accepted.handle);
}

test "built-in terminal types use actual local PTY TERM and legacy plus numeric keypad input" {
    var sandbox = try Sandbox.init();
    defer sandbox.deinit();
    const Key = @import("vt/input_event.zig").Key;
    const keys = [_]Key{ .f5, .f6, .f7, .f8, .f9, .f10, .numpad_0, .numpad_1, .numpad_2, .numpad_3, .numpad_4, .numpad_5, .numpad_6, .numpad_7, .numpad_8, .numpad_9, .numpad_decimal, .numpad_enter };
    const keypad = "\x1bOp\x1bOq\x1bOr\x1bOs\x1bOt\x1bOu\x1bOv\x1bOw\x1bOx\x1bOy\x1bOn\x1bOM";
    for (@import("vt/terminal_type.zig").builtin) |entry| for ([_]bool{ false, true }) |application| {
        var rig = try Rig.initWithOptions(.{ .term = entry.name });
        defer rig.deinit();
        const accepted = try rig.sessions.create(.{ .local = .{ .initial_cwd = sandbox.path } }, target);
        const service = try rig.ready(accepted);
        const function_bytes = if (entry.kind == .vt100) "\x1bOt\x1bOu\x1bOv\x1bOl\x1bOw\x1bOx" else "\x1b[15~\x1b[17~\x1b[18~\x1b[19~\x1b[20~\x1b[21~";
        const expected = try std.mem.concat(allocator, u8, &.{ function_bytes, if (application) keypad else "0123456789.\r" });
        defer allocator.free(expected);
        const command = try std.fmt.allocPrint(allocator, "python3 -c 'import os,tty,sys,select,time,termios; f=0; old=termios.tcgetattr(f); tty.setraw(f); os.write(1,b\"{s}\"); print(\"PROFILE_\"+os.environ[\"TERM\"]+\"_READY\",flush=True); data=b\"\"; deadline=time.monotonic()+10\nwhile len(data)<{d} and time.monotonic()<deadline:\n if select.select([f],[],[],0.1)[0]: data+=os.read(f,4096)\ntermios.tcsetattr(f,termios.TCSANOW,old); print(\"INPUT_\"+data.hex(),flush=True)'\n", .{ if (application) "\\x1b=\\x1b[?1035l" else "\\x1b>", expected.len });
        defer allocator.free(command);
        _ = try write(service, .{ .input_sequence = 1, .bytes = command });
        var output: std.ArrayList(u8) = .empty;
        defer output.deinit(allocator);
        const ready = try std.fmt.allocPrint(allocator, "PROFILE_{s}_READY", .{entry.name});
        defer allocator.free(ready);
        try waitText(&rig, service, &output, ready);
        for (keys, 0..) |key, i| {
            const until = native.zw_local_monotonic_ms() + 5000;
            while (true) {
                _ = service.writeKey(.{ .input_sequence = i + 2, .mode_revision = (try status(service)).mode_revision, .event = .{ .key = key } }) catch |err| {
                    if (err != error.WorkerBusy or native.zw_local_monotonic_ms() >= until) return err;
                    pause();
                    continue;
                };
                break;
            }
        }
        const hex = try allocator.alloc(u8, expected.len * 2);
        defer allocator.free(hex);
        for (expected, 0..) |byte, i| _ = try std.fmt.bufPrint(hex[i * 2 ..][0..2], "{x:0>2}", .{byte});
        const received = try std.fmt.allocPrint(allocator, "INPUT_{s}", .{hex});
        defer allocator.free(received);
        try waitText(&rig, service, &output, received);
        try rig.close(accepted.handle);
    };
}

test "local display progresses without a raw output consumer" {
    var sandbox = try Sandbox.init();
    defer sandbox.deinit();
    var rig = try Rig.initWithOptions(.{ .output_capacity = 4096, .retain_raw_output = false });
    defer rig.deinit();
    const accepted = try rig.sessions.create(.{ .local = .{ .initial_cwd = sandbox.path } }, target);
    const service = try rig.ready(accepted);
    (try service.textSlot()).enableStructured();
    // PTY ready precedes ZSH's first prompt/mode negotiation. A rejected
    // stale-mode request has admitted no bytes; retry the same sequence.
    const input_until = native.zw_local_monotonic_ms() + 5000;
    while (true) {
        _ = write(service, .{ .input_sequence = 1, .bytes = "repeat 9000 printf x; printf '\\n%s_%s\\n' 'DISPLAY' 'TAIL'; exit 0\n" }) catch |err| {
            if (err != error.StaleMode or native.zw_local_monotonic_ms() >= input_until) return err;
            pause();
            continue;
        };
        break;
    }
    const until = native.zw_local_monotonic_ms() + 8000;
    while (true) {
        try rig.tick();
        if ((try status(service)).eof_seen) break;
        if (native.zw_local_monotonic_ms() >= until) return error.EofTimeout;
        pause();
    }
    var found = false;
    while (native.zw_local_monotonic_ms() < until) {
        try rig.tick();
        var value = service.snapshot(allocator) catch {
            pause();
            continue;
        };
        defer value.deinit(allocator);
        var text: std.ArrayList(u8) = .empty;
        defer text.deinit(allocator);
        for (value.projection.cells) |cell| try text.appendSlice(allocator, value.projection.grapheme(cell));
        if (std.mem.indexOf(u8, text.items, "DISPLAY_TAIL") != null) {
            found = true;
            break;
        }
        pause();
    }
    try std.testing.expect(found);
    var raw: [64]u8 = undefined;
    try std.testing.expectEqual(terminal.Read.eof, try service.readOutput(&raw));
    try rig.close(accepted.handle);
}

test "Local recording identity returns real pre-execution identity and null for unrecorded process" {
    var sandbox = try Sandbox.init();
    defer sandbox.deinit();
    for ([_]bool{ false, true }) |recorded| {
        var rig = try Rig.initWithOptions(.{ .recording = if (recorded) .{ .io = std.testing.io, .directory = sandbox.path, .log = .{ .ring_mb = 1 } } else null });
        defer rig.deinit();
        const accepted = try rig.sessions.create(.{ .local = .{ .initial_cwd = sandbox.path } }, target);
        const service = try rig.ready(accepted);
        const until = native.zw_local_monotonic_ms() + 5000;
        var metadata: terminal.RecordingIdentity = undefined;
        while (true) {
            metadata = service.recordingIdentity() catch |err| {
                if (err != error.WorkerBusy) return err;
                if (native.zw_local_monotonic_ms() >= until) return error.WorkerTimeout;
                pause();
                continue;
            };
            break;
        }
        try std.testing.expect(metadata.owner.eql(accepted.handle));
        try std.testing.expectEqual(recorded, metadata.available);
        if (recorded) {
            try std.testing.expect(metadata.recording_id != null and metadata.recording_generation == 1);
            _ = try @import("host/identity.zig").RecordingId.parse(&metadata.recording_id.?);
            try std.testing.expect(metadata.failure == null);
        } else {
            try std.testing.expect(metadata.recording_id == null and metadata.recording_generation == 0);
            try std.testing.expectEqualStrings("RecordingDisabled", metadata.failure.?);
        }
        var stale = service;
        stale.binding.resource_owner.session.generation += 1;
        try std.testing.expectError(error.StaleSession, stale.recordingIdentity());
        try rig.close(accepted.handle);
    }
}
