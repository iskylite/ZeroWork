//! Controller-thread Local tools. The Manager worker only exchanges immutable
//! requests/results; it never touches the ApplicationHost or a terminal node.
const std = @import("std");
const Application = @import("application_host.zig").ApplicationHost;
const local = @import("../host/process_service.zig");
const identity = @import("../host/identity.zig");
const sessions = @import("../host/session_host.zig");
const provider = @import("../ai/provider.zig");
const loop = @import("../ai/tool_loop.zig");
const trace = @import("../ai/tool_trace.zig");
const clock = @import("../platform/realtime.zig");

const Capture = struct {
    owner: identity.SessionHandle,
    exec_binding: sessions.ServiceHandle,
    terminal_binding: sessions.ServiceHandle,
    cwd: ?[]u8,
};
const ApprovalState = enum { pending, approved, rejected };
const Exchange = struct {
    invocation: loop.Invocation,
    allocator: std.mem.Allocator,
    sequence: u64,
    started_ms: u64,
    ready: std.atomic.Value(bool) = .init(false),
    cancel: std.atomic.Value(bool) = .init(false),
    approval: ApprovalState = .pending,
    outcome: ?loop.Outcome = null,
    failure: ?anyerror = null,
};
pub const Approval = @import("../ai/legacy_adapter.zig").Approval;

pub const Bridge = struct {
    allocator: std.mem.Allocator,
    capture: ?Capture = null,
    delegated_owner: ?@import("../ai/tool_scope.zig").Owner = null,
    mutex: std.atomic.Mutex = .unlocked,
    exchange: ?*Exchange = null,
    sequence: u64 = 0,
    shutting_down: bool = false,
    active: ?struct { handle: local.ExecHandle, started_ms: u64 } = null,

    pub fn assembleContext(allocator: std.mem.Allocator, raw: *anyopaque, owner: identity.SessionHandle, context_window: u32, redact: bool) !@import("../ai/assembler.zig").Assembled {
        const app: *Application = @ptrCast(@alignCast(raw));
        const id = app.legacyForHandle(owner) orelse return error.StaleSession;
        const tab = app.workspace.sessionTab(id) orelse return error.StaleSession;
        var terminal = tab.terminal orelse return error.ServiceUnavailable;
        const surface = terminal.terminal_surface orelse return error.ServiceUnavailable;
        if (!surface.owner.eql(owner)) return error.StaleSession;
        var lines = try surface.service.readLines(.{ .max_lines = 1024, .max_bytes = 16384 }, allocator);
        defer lines.deinit(allocator);
        var text: std.ArrayList(u8) = .empty;
        defer text.deinit(allocator);
        for (lines.lines) |line| {
            try text.appendSlice(allocator, line);
            try text.append(allocator, '\n');
        }
        var directory = try app.localCwd(id, allocator);
        defer if (directory) |*value| value.deinit(allocator);
        const cwd = if (directory) |value| value.value else null;
        const selection = terminal.copySelectionText(allocator) catch null;
        defer if (selection) |value| allocator.free(value);
        return @import("../ai/session_snapshot_context.zig").assembleText(allocator, text.items, .{ .host = "本机 · zsh" }, cwd, selection, redact, context_window);
    }
    pub fn init(allocator: std.mem.Allocator) Bridge {
        return .{ .allocator = allocator };
    }
    fn lock(self: *Bridge) void {
        while (!self.mutex.tryLock()) std.atomic.spinLoopHint();
    }
    /// Main-thread only, after the previous Manager worker has joined.
    pub fn prepare(self: *Bridge, app: *Application, owner: identity.SessionHandle) !void {
        self.lock();
        defer self.mutex.unlock();
        if (self.exchange != null or self.active != null) return error.ToolCleanupPending;
        const id = app.legacyForHandle(owner) orelse return error.StaleSession;
        const tab = app.workspace.sessionTab(id) orelse return error.StaleSession;
        if (!tab.local or !tab.content_owner.eql(.{ .session = owner }) or tab.closing or tab.failed or tab.archived) return error.ServiceUnavailable;
        const exec_binding = switch (app.sessions.queryService(owner, .exec)) {
            .available => |binding| binding,
            else => return error.ServiceUnavailable,
        };
        const terminal_binding = switch (app.sessions.queryService(owner, .terminal)) {
            .available => |binding| binding,
            else => return error.ServiceUnavailable,
        };
        if (!app.sessions.bindingIsLive(exec_binding) or !app.sessions.bindingIsLive(terminal_binding)) return error.StaleBinding;
        var directory = try app.localCwd(id, self.allocator);
        defer if (directory) |*value| value.deinit(self.allocator);
        const cwd = if (directory) |value| if (value.value) |path| try self.allocator.dupe(u8, path) else null else null;
        if (self.capture) |old| if (old.cwd) |path| self.allocator.free(path);
        self.capture = .{ .owner = owner, .exec_binding = exec_binding, .terminal_binding = terminal_binding, .cwd = cwd };
        self.shutting_down = false;
    }
    pub fn clear(self: *Bridge) !void {
        self.lock();
        defer self.mutex.unlock();
        if (self.exchange != null or self.active != null) return error.ToolCleanupPending;
        if (self.capture) |old| if (old.cwd) |path| self.allocator.free(path);
        self.capture = null;
    }
    pub fn interface(self: *Bridge) loop.Host {
        return .{ .context = self, .execute = execute };
    }
    fn execute(raw: *anyopaque, invocation: loop.Invocation, allocator: std.mem.Allocator, token: ?*provider.CancelToken) !loop.Outcome {
        const self: *Bridge = @ptrCast(@alignCast(raw));
        var exchange: Exchange = .{ .invocation = invocation, .allocator = allocator, .sequence = 0, .started_ms = now() };
        self.lock();
        if (self.shutting_down or self.exchange != null or self.active != null or self.capture == null) {
            self.mutex.unlock();
            return error.ToolHostUnavailable;
        }
        self.sequence = std.math.add(u64, self.sequence, 1) catch {
            self.mutex.unlock();
            return error.IdentityExhausted;
        };
        exchange.sequence = self.sequence;
        trace.emit(.{ .event = "host_received", .sequence = exchange.sequence, .turn_id = invocation.key.turn_id, .call_id = invocation.key.call_id, .owner = invocation.key.owner, .verdict = invocation.verdict, .command = invocation.call.command });
        self.exchange = &exchange;
        self.mutex.unlock();
        // Cancellation asks the controller to cancel the original child. Do
        // not release this stack exchange before its actual cleanup receipt.
        while (!exchange.ready.load(.acquire)) {
            if (token) |cancel| if (cancel.isCancelled()) exchange.cancel.store(true, .release);
            var duration: std.c.timespec = .{ .sec = 0, .nsec = 5 * std.time.ns_per_ms };
            _ = std.c.nanosleep(&duration, null);
        }
        self.lock();
        if (self.exchange == &exchange) self.exchange = null;
        self.mutex.unlock();
        if (exchange.failure) |err| return err;
        return exchange.outcome orelse error.ToolHostUnavailable;
    }
    /// Main-thread only. Approval refers to this exact immutable call/hash.
    pub fn pendingApproval(self: *Bridge) ?Approval {
        self.lock();
        defer self.mutex.unlock();
        const exchange = self.exchange orelse return null;
        if (exchange.ready.load(.acquire) or exchange.cancel.load(.acquire) or exchange.invocation.verdict != .need_confirm or exchange.approval != .pending) return null;
        const capture = self.capture orelse return null;
        return .{ .target = "本机 · zsh", .owner = capture.owner, .cwd = capture.cwd, .sequence = exchange.sequence, .arguments_hash = exchange.invocation.arguments_hash, .command = exchange.invocation.call.command, .call_id = exchange.invocation.key.call_id };
    }
    pub fn decide(self: *Bridge, sequence: u64, hash: [32]u8, approved: bool) !void {
        self.lock();
        defer self.mutex.unlock();
        const exchange = self.exchange orelse return error.StaleApproval;
        if (exchange.sequence != sequence or !std.mem.eql(u8, &hash, &exchange.invocation.arguments_hash) or exchange.ready.load(.acquire) or exchange.cancel.load(.acquire) or exchange.approval != .pending) return error.StaleApproval;
        trace.emit(.{ .event = "approval_decision", .sequence = sequence, .call_id = exchange.invocation.key.call_id, .approved = approved });
        exchange.approval = if (approved) .approved else .rejected;
    }
    fn validate(self: *Bridge, app: *Application, invocation: loop.Invocation) !Capture {
        const capture = self.capture orelse return error.ServiceUnavailable;
        const id = app.legacyForHandle(capture.owner) orelse return error.StaleSession;
        const tab = app.workspace.sessionTab(id) orelse return error.StaleSession;
        if (!tab.local or !tab.content_owner.eql(.{ .session = capture.owner }) or tab.closing or tab.failed or tab.archived) return error.StaleSession;
        if (self.delegated_owner) |owner| {
            if (!owner.eql(invocation.key.owner)) return error.TargetOutsideAssistant;
        } else if (invocation.key.owner != .session or invocation.key.owner.session != @backingInt(capture.owner.session_id)) return error.TargetOutsideAssistant;
        if (invocation.call.targets.len != 1 or invocation.call.targets.ids[0] != @backingInt(capture.owner.session_id)) return error.TargetOutsideAssistant;
        _ = try invocation.scope.validate(invocation.call.targets.slice());
        if (!app.sessions.bindingIsLive(capture.exec_binding) or !app.sessions.bindingIsLive(capture.terminal_binding)) return error.StaleBinding;
        return capture;
    }
    pub fn preflight(self: *Bridge, app: *Application, invocation: loop.Invocation) !void {
        _ = try self.validate(app, invocation);
        if (invocation.call.tool == .list_remote_files or invocation.call.tool == .read_remote_file) return error.UnsupportedTool;
        if (invocation.call.tool == .run_command and self.capture.?.cwd == null) return error.UnknownDirectory;
    }
    fn finish(exchange: *Exchange, result: loop.TargetResult) void {
        trace.emit(.{ .event = "host_result", .sequence = exchange.sequence, .turn_id = exchange.invocation.key.turn_id, .call_id = exchange.invocation.key.call_id, .result = result });
        exchange.outcome = loop.Outcome.copy(exchange.allocator, &.{result}) catch |err| {
            exchange.failure = err;
            exchange.ready.store(true, .release);
            return;
        };
        exchange.ready.store(true, .release);
    }
    fn failure(exchange: *Exchange, status: loop.Status, err: anyerror) void {
        finish(exchange, .{ .session_id = exchange.invocation.call.targets.ids[0], .status = status, .transport = .local, .error_code = @errorName(err) });
    }
    /// UI/controller thread pump. All host and adapter calls stay here.
    pub fn pump(self: *Bridge, app: *Application) void {
        self.lock();
        defer self.mutex.unlock();
        const exchange = self.exchange;
        if (exchange) |current| if (current.ready.load(.acquire)) return;
        if (self.active) |active| {
            if (exchange) |current| if (current.cancel.load(.acquire)) app.local_adapter.cancelExec(active.handle) catch {};
            if (exchange) |current| _ = self.validate(app, current.invocation) catch {
                app.local_adapter.cancelExec(active.handle) catch {};
            };
            var snapshot = app.local_adapter.execSnapshot(active.handle, self.allocator) catch |err| {
                if (err == error.WorkerBusy) return;
                if (exchange) |current| finish(current, .{ .session_id = @backingInt(active.handle.owner.session_id), .status = .unknown, .transport = .local, .local_released = false, .error_code = @errorName(err) });
                return;
            };
            defer snapshot.deinit(self.allocator);
            if (!snapshot.done) return;
            if (snapshot.cleanup != .released) {
                if (exchange) |current| finish(current, .{ .session_id = @backingInt(active.handle.owner.session_id), .status = .unknown, .transport = .local, .stdout = snapshot.stdout, .stderr = snapshot.stderr, .local_released = false, .error_code = "LocalCleanupUnknown" });
                return;
            }
            app.local_adapter.retireExec(active.handle) catch |err| {
                if (err == error.WorkerBusy or err == error.CleanupIncomplete) return;
                if (exchange) |current| finish(current, .{ .session_id = @backingInt(active.handle.owner.session_id), .status = .unknown, .transport = .local, .local_released = false, .error_code = @errorName(err) });
                return;
            };
            self.active = null;
            if (exchange) |current| {
                const text_output = std.unicode.utf8ValidateSlice(snapshot.stdout) and std.unicode.utf8ValidateSlice(snapshot.stderr);
                finish(current, .{ .session_id = @backingInt(active.handle.owner.session_id), .transport = .local, .status = if (snapshot.timed_out) .timed_out else if (snapshot.cancelled) .cancelled else if (!text_output) .failed else if (snapshot.exit) |exit| if (exit == .exited and exit.exited == 0) .succeeded else .failed else .failed, .stdout = if (text_output) snapshot.stdout else "", .stderr = if (text_output) snapshot.stderr else "", .exit = if (snapshot.exit) |exit| if (exit == .exited) exit.exited else null else null, .signal = if (snapshot.exit) |exit| if (exit == .signal) exit.signal else null else null, .cwd = self.capture.?.cwd, .elapsed_ms = elapsed(active.started_ms), .truncated = snapshot.truncated, .error_code = if (text_output) null else "NonTextToolOutput" });
            }
            return;
        }
        const current = exchange orelse return;
        if (current.cancel.load(.acquire)) return failure(current, .cancelled, error.Cancelled);
        const capture = self.validate(app, current.invocation) catch |err| return failure(current, .rejected, err);
        if (current.invocation.verdict == .deny_exec_copy_only) return failure(current, .rejected, error.ToolExecutionDenied);
        if (current.invocation.verdict == .need_confirm) switch (current.approval) {
            .pending => return,
            .rejected => return failure(current, .rejected, error.ToolApprovalRejected),
            .approved => {},
        };
        switch (current.invocation.call.tool) {
            .read_terminal => {
                const service = app.local_adapter.terminalService(capture.terminal_binding) catch |err| return failure(current, .rejected, err);
                var lines = service.readLines(.{ .max_lines = 1024, .max_bytes = @min(current.invocation.call.max_bytes, current.invocation.capture_bytes) }, self.allocator) catch |err| {
                    if (err == error.WorkerBusy) return;
                    return failure(current, .failed, err);
                };
                defer lines.deinit(self.allocator);
                var bytes: std.ArrayList(u8) = .empty;
                defer bytes.deinit(self.allocator);
                const cap = @min(current.invocation.call.max_bytes, current.invocation.capture_bytes);
                for (lines.lines) |line| {
                    var keep = @min(line.len, cap - bytes.items.len);
                    while (keep > 0 and !std.unicode.utf8ValidateSlice(line[0..keep])) keep -= 1;
                    bytes.appendSlice(self.allocator, line[0..keep]) catch |err| return failure(current, .failed, err);
                    if (bytes.items.len < cap) bytes.append(self.allocator, '\n') catch |err| return failure(current, .failed, err);
                    if (bytes.items.len == cap) break;
                }
                finish(current, .{ .session_id = @backingInt(capture.owner.session_id), .status = .succeeded, .transport = .local, .stdout = bytes.items, .cwd = capture.cwd, .truncated = bytes.items.len == cap });
            },
            .run_command => {
                if (capture.cwd == null) return failure(current, .rejected, error.UnknownDirectory);
                const key = app.sessions.journal.begin(.{ .session = capture.owner }, null) catch |err| return failure(current, .failed, err);
                const handle = app.local_adapter.startExec(capture.exec_binding, .{ .operation = key, .call_id = key.operation_id, .command = current.invocation.call.command, .cwd = capture.cwd, .limits = .{ .timeout_ms = current.invocation.timeout_ms, .capture_bytes = @min(current.invocation.call.max_bytes, current.invocation.capture_bytes) } }) catch |err| {
                    _ = app.sessions.journal.failReleased(key, .{ .domain = .host, .code = @errorName(err), .cleanup = .released, .safe_message = "Local tool did not start" }) catch {};
                    if (err == error.WorkerBusy) return;
                    return failure(current, .failed, err);
                };
                trace.emit(.{ .event = "exec_started", .sequence = current.sequence, .turn_id = current.invocation.key.turn_id, .call_id = current.invocation.key.call_id, .operation = key, .cwd = capture.cwd });
                self.active = .{ .handle = handle, .started_ms = now() };
            },
            else => failure(current, .rejected, error.UnsupportedTool),
        }
    }
    /// The original session cannot release its adapter while this call waits.
    /// Only command execution contributes a write risk. Read tools still
    /// participate in closeImpact's identity/cleanup fingerprint.
    pub fn writeRisk(self: *Bridge, owner: identity.SessionHandle) bool {
        self.lock();
        defer self.mutex.unlock();
        const capture = self.capture orelse return false;
        if (!capture.owner.eql(owner)) return false;
        if (self.active != null) return true;
        const current = self.exchange orelse return false;
        return !current.ready.load(.acquire) and current.invocation.call.tool == .run_command and current.approval != .rejected;
    }
    pub fn closeImpact(self: *Bridge, owner: identity.SessionHandle) @import("group_close_controller.zig").Impact {
        self.lock();
        defer self.mutex.unlock();
        var impact: @import("group_close_controller.zig").Impact = .{};
        const capture = self.capture orelse return impact;
        if (!capture.owner.eql(owner)) return impact;
        const pending = if (self.exchange) |current| !current.ready.load(.acquire) else false;
        if (!pending and self.active == null) return impact;
        var hash = std.hash.Wyhash.init(0x41494c4f43414c);
        std.hash.autoHash(&hash, owner);
        if (self.exchange) |current| {
            std.hash.autoHash(&hash, current.sequence);
            std.hash.autoHash(&hash, current.invocation.key.turn_id);
            hash.update(current.invocation.key.call_id);
            hash.update(&current.invocation.arguments_hash);
            std.hash.autoHash(&hash, current.approval);
            std.hash.autoHash(&hash, current.invocation.verdict);
        }
        if (self.active) |active| {
            std.hash.autoHash(&hash, active.handle.owner);
            std.hash.autoHash(&hash, active.handle.operation.operation_id);
            std.hash.autoHash(&hash, active.handle.call_id);
        }
        impact.ai = hash.final();
        if (impact.ai == 0) impact.ai = 1;
        var text: [512]u8 = undefined;
        const detail = std.fmt.bufPrint(&text, "本地会话 #{d} · 待批准 {d} · 执行中 {d}", .{ @backingInt(owner.session_id), @as(u8, if (self.exchange) |current| @intFromBool(pending and current.invocation.verdict == .need_confirm and current.approval == .pending) else 0), @as(u8, @intFromBool(self.active != null)) }) catch "AI Local 调用正在收尾";
        impact.setDetail(detail);
        return impact;
    }
    pub fn stopOwner(self: *Bridge, owner: identity.SessionHandle) @import("application_host.zig").CloseReceipt {
        self.lock();
        defer self.mutex.unlock();
        const capture = self.capture orelse return .released;
        if (!capture.owner.eql(owner)) return .released;
        if (self.exchange) |exchange| {
            exchange.cancel.store(true, .release);
            if (!exchange.ready.load(.acquire)) return .awaiting;
        }
        return if (self.active != null) .awaiting else .released;
    }
    /// Exceptional teardown wakes a waiting worker before the ApplicationHost
    /// is destroyed. Any still-live child remains owned by its Local adapter.
    pub fn shutdown(self: *Bridge, app: ?*Application) void {
        self.lock();
        defer self.mutex.unlock();
        self.shutting_down = true;
        if (self.active) |active| if (app) |host| host.local_adapter.cancelExec(active.handle) catch {};
        if (self.exchange) |exchange| if (!exchange.ready.load(.acquire)) finish(exchange, .{ .session_id = exchange.invocation.call.targets.ids[0], .status = if (self.active == null) .cancelled else .unknown, .transport = .local, .local_released = self.active == null, .error_code = "ToolHostShuttingDown" });
    }
    pub fn deinit(self: *Bridge) void {
        // The Manager worker must have joined before destroying this bridge.
        std.debug.assert(self.exchange == null);
        if (self.capture) |capture| if (capture.cwd) |path| self.allocator.free(path);
        self.* = undefined;
    }
};
fn now() u64 {
    return @intCast(@max(0, @divTrunc(clock.monotonicNs(), std.time.ns_per_ms)));
}
fn elapsed(started: u64) u64 {
    return now() -| started;
}

/// Registered only by the Local provider contribution.
pub fn createAdapter(allocator: std.mem.Allocator) !@import("../ai/legacy_adapter.zig").Adapter {
    return @import("../ai/legacy_adapter.zig").Adapter.create(Bridge, Application, allocator);
}
