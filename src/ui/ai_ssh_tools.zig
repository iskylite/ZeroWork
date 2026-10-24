//! Controller-thread SSH tools. Native channel IO stays on the attached
//! connection's existing worker; the AI worker exchanges immutable values only.
const std = @import("std");
const Application = @import("application_host.zig").ApplicationHost;
const identity = @import("../host/identity.zig");
const sessions = @import("../host/session_host.zig");
const operation = @import("../host/operation.zig");
const exec = @import("../ai/execbridge.zig");
const provider = @import("../ai/provider.zig");
const loop = @import("../ai/tool_loop.zig");
const trace = @import("../ai/tool_trace.zig");
const Worker = @import("../host/runtime_service.zig").Runtime;
const file_app = @import("file_application_host.zig");
const file_capture = @import("../host/ai_remote_file_snapshot.zig");
const file_result = @import("ai_file_tool_result.zig");
const viewport = @import("../vt/viewport.zig");

pub const Approval = @import("ai_local_tools.zig").Approval;
const Capture = struct {
    owner: identity.SessionHandle,
    create_key: operation.OperationKey,
    exec_binding: sessions.ServiceHandle,
    terminal_binding: sessions.ServiceHandle,
    cwd: ?[]u8,
    target: []u8,
    file_bindings: ?@import("../host/file_binding_host.zig").Bindings = null,
    file_dedicated: bool = false,
};
const ApprovalState = enum { pending, approved, rejected };
const Exchange = struct {
    invocation: loop.Invocation,
    allocator: std.mem.Allocator,
    sequence: u64,
    ready: std.atomic.Value(bool) = .init(false),
    cancel: std.atomic.Value(bool) = .init(false),
    approval: ApprovalState = .pending,
    operation_key: ?operation.OperationKey = null,
    operation_journal: ?*operation.Journal = null,
    outcome: ?loop.Outcome = null,
    failure: ?anyerror = null,
};
const Active = struct {
    facade: exec.ExecBridge,
    handle: exec.ExecHandle,
    key: operation.OperationKey,
    journal: *operation.Journal,
    cleanup_unknown: bool = false,
    stale: bool = false,
};

pub const Bridge = struct {
    allocator: std.mem.Allocator,
    capture: ?Capture = null,
    delegated_owner: ?@import("../ai/tool_scope.zig").Owner = null,
    mutex: std.atomic.Mutex = .unlocked,
    exchange: ?*Exchange = null,
    active: ?Active = null,
    sequence: u64 = 0,
    shutting_down: bool = false,
    files: ?*file_app.Host = null,
    file_reader: ?*file_capture.Reader = null,
    file_started_ns: i128 = 0,
    file_timed_out: bool = false,

    pub fn assembleContext(allocator: std.mem.Allocator, raw: *anyopaque, owner: identity.SessionHandle, context_window: u32, redact: bool) !@import("../ai/assembler.zig").Assembled {
        const app: *Application = @ptrCast(@alignCast(raw));
        const id = app.legacyForHandle(owner) orelse return error.StaleSession;
        const tab = app.workspace.sessionTab(id) orelse return error.StaleSession;
        const runtime = tab.runtime orelse return error.ServiceUnavailable;
        const config = tab.host_snapshot orelse return error.ServiceUnavailable;
        const text = try runtime.workerPtr().searchText(allocator);
        defer allocator.free(text);
        const cwd = try runtime.workerPtr().copyCwd(allocator);
        defer if (cwd) |value| allocator.free(value);
        var terminal_view = tab.terminal;
        const selection = if (terminal_view) |*view| view.copySelectionText(allocator) catch null else null;
        defer if (selection) |value| allocator.free(value);
        return @import("../ai/session_snapshot_context.zig").assembleText(allocator, text, .{ .host = config.value.host, .user = config.value.user, .hops = @intCast(@max(config.value.route.len, config.value.jump_chain.len)) }, cwd, selection, redact, context_window);
    }
    pub fn init(allocator: std.mem.Allocator) Bridge {
        return .{ .allocator = allocator };
    }
    fn lock(self: *Bridge) void {
        while (!self.mutex.tryLock()) std.atomic.spinLoopHint();
    }
    fn freeCapture(self: *Bridge) void {
        if (self.capture) |capture| {
            if (capture.cwd) |cwd| self.allocator.free(cwd);
            self.allocator.free(capture.target);
        }
        self.capture = null;
    }
    /// Controller only, after the preceding AI worker has joined. A capture
    /// names the original session generation, services and create operation.
    pub fn prepare(self: *Bridge, app: *Application, owner: identity.SessionHandle) !void {
        self.lock();
        defer self.mutex.unlock();
        if (self.exchange != null or self.active != null or self.file_reader != null) return error.ToolCleanupPending;
        const state = app.sessions.queryState(owner) orelse return error.StaleSession;
        const id = app.legacyForHandle(owner) orelse return error.StaleSession;
        const tab = app.workspace.sessionTab(id) orelse return error.StaleSession;
        if (tab.local or !tab.content_owner.eql(.{ .session = owner }) or tab.closing or tab.failed or tab.archived) return error.ServiceUnavailable;
        const exec_binding = try liveBinding(app, owner, .exec);
        const terminal_binding = try liveBinding(app, owner, .terminal);
        _ = try app.sshExecService(owner);
        const runtime = tab.runtime orelse return error.ServiceUnavailable;
        const remote = tab.host_snapshot orelse return error.ServiceUnavailable;
        const target = try std.fmt.allocPrint(self.allocator, "SSH · {s}@{s}:{d}", .{ remote.value.user, remote.value.host, remote.value.port });
        errdefer self.allocator.free(target);
        const cwd = try runtime.workerPtr().copyCwd(self.allocator);
        self.freeCapture();
        self.capture = .{ .owner = owner, .create_key = state.create_operation, .exec_binding = exec_binding, .terminal_binding = terminal_binding, .cwd = cwd, .target = target, .file_dedicated = app.workspace.app_config.transfer.dedicated_connection };
        self.shutting_down = false;
    }
    pub fn filesAvailable(self: *Bridge) bool {
        return self.files != null and self.files.?.file_host != null;
    }
    fn pollFile(self: *Bridge, app: ?*Application) void {
        const reader = self.file_reader orelse return;
        const current = self.exchange;
        var live: ?file_capture.Context = null;
        if (current) |exchange| {
            if (app) |host| {
                if (self.validate(host, exchange.invocation)) |_| {
                    live = reader.original;
                } else |_| {}
            }
            if (exchange.cancel.load(.acquire)) reader.cancel();
            if (@import("../platform/realtime.zig").monotonicNs() - self.file_started_ns >= @as(i128, exchange.invocation.timeout_ms) * std.time.ns_per_ms) {
                self.file_timed_out = true;
                reader.cancel();
            }
        }
        _ = reader.poll(live);
        const owner_id = @backingInt(reader.original.source.session.session_id);
        if (reader.cleanupReceipt() == .unknown) {
            if (current) |exchange| finish(exchange, .{ .session_id = owner_id, .status = .unknown, .transport = .sftp, .local_released = false, .error_code = "SftpCleanupUnknown" });
            return;
        }
        // Keep the exact reader until the service confirms native cleanup,
        // including after an unknown outcome has returned to the AI worker.
        if (!reader.terminal or !reader.retired) return;
        var result = reader.take() orelse return;
        defer result.release();
        defer {
            reader.deinit() catch unreachable;
            self.file_reader = null;
            self.file_started_ns = 0;
        }
        const exchange = current orelse return;
        if (exchange.ready.load(.acquire)) return;
        const value = result.value().?;
        if (value.body == .failure) {
            const metadata = std.json.Stringify.valueAlloc(exchange.allocator, value.metadata, .{}) catch |err| return failure(exchange, .failed, err);
            defer exchange.allocator.free(metadata);
            finish(exchange, .{ .session_id = owner_id, .status = if (self.file_timed_out) .timed_out else if (value.body.failure == .cancelled) .cancelled else if (value.body.failure == .source_changed) .rejected else .failed, .transport = .sftp, .stdout = if (metadata.len <= @min(exchange.invocation.capture_bytes, 65536)) metadata else "", .error_code = if (self.file_timed_out) "ToolDeadlineExceeded" else file_result.failureCode(value.body.failure) });
        } else {
            const projection = file_result.project(exchange.allocator, value, @min(exchange.invocation.capture_bytes, 65536)) catch |err| return failure(exchange, .failed, err);
            defer projection.deinit(exchange.allocator);
            finish(exchange, .{ .session_id = owner_id, .status = .succeeded, .transport = .sftp, .stdout = projection.stdout, .stderr = projection.stderr, .truncated = projection.truncated });
        }
    }
    pub fn clear(self: *Bridge) !void {
        self.lock();
        defer self.mutex.unlock();
        if (self.exchange != null or self.active != null or self.file_reader != null) return error.ToolCleanupPending;
        self.freeCapture();
    }
    pub fn interface(self: *Bridge) loop.Host {
        return .{ .context = self, .execute = execute };
    }
    fn execute(raw: *anyopaque, invocation: loop.Invocation, allocator: std.mem.Allocator, token: ?*provider.CancelToken) !loop.Outcome {
        const self: *Bridge = @ptrCast(@alignCast(raw));
        var exchange: Exchange = .{ .invocation = invocation, .allocator = allocator, .sequence = 0 };
        self.lock();
        if (self.shutting_down or self.exchange != null or self.active != null or self.file_reader != null or self.capture == null) {
            self.mutex.unlock();
            return error.ToolHostUnavailable;
        }
        self.sequence = std.math.add(u64, self.sequence, 1) catch {
            self.mutex.unlock();
            return error.IdentityExhausted;
        };
        self.file_started_ns = @import("../platform/realtime.zig").monotonicNs();
        self.file_timed_out = false;
        exchange.sequence = self.sequence;
        self.exchange = &exchange;
        trace.emit(.{ .event = "host_received", .sequence = exchange.sequence, .turn_id = invocation.key.turn_id, .call_id = invocation.key.call_id, .owner = invocation.key.owner, .verdict = invocation.verdict, .command = invocation.call.command });
        self.mutex.unlock();
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
    pub fn pendingApproval(self: *Bridge) ?Approval {
        self.lock();
        defer self.mutex.unlock();
        const current = self.exchange orelse return null;
        if (current.ready.load(.acquire) or current.cancel.load(.acquire) or current.invocation.verdict != .need_confirm or current.approval != .pending) return null;
        const capture = self.capture orelse return null;
        return .{ .target = capture.target, .owner = capture.owner, .cwd = capture.cwd, .sequence = current.sequence, .arguments_hash = current.invocation.arguments_hash, .command = current.invocation.call.command, .call_id = current.invocation.key.call_id };
    }
    pub fn decide(self: *Bridge, sequence: u64, hash: [32]u8, approved: bool) !void {
        self.lock();
        defer self.mutex.unlock();
        const current = self.exchange orelse return error.StaleApproval;
        if (current.sequence != sequence or !std.mem.eql(u8, &hash, &current.invocation.arguments_hash) or current.ready.load(.acquire) or current.cancel.load(.acquire) or current.approval != .pending) return error.StaleApproval;
        trace.emit(.{ .event = "approval_decision", .sequence = sequence, .call_id = current.invocation.key.call_id, .approved = approved });
        current.approval = if (approved) .approved else .rejected;
    }
    fn validate(self: *Bridge, app: *Application, invocation: loop.Invocation) !*Worker {
        const capture = self.capture orelse return error.ServiceUnavailable;
        try validateTarget(capture, invocation, self.delegated_owner);
        if (!app.sessions.bindingIsLive(capture.exec_binding) or !app.sessions.bindingIsLive(capture.terminal_binding)) return error.StaleBinding;
        const state = app.sessions.queryState(capture.owner) orelse return error.StaleSession;
        if (!state.create_operation.eql(capture.create_key)) return error.StaleSession;
        const id = app.legacyForHandle(capture.owner) orelse return error.StaleSession;
        const tab = app.workspace.sessionTab(id) orelse return error.StaleSession;
        if (tab.local or !tab.content_owner.eql(.{ .session = capture.owner }) or tab.closing or tab.failed or tab.archived) return error.StaleSession;
        const runtime = tab.runtime orelse return error.ServiceUnavailable;
        if (runtime.torn_down) return error.ServiceUnavailable;
        const reconnect = runtime.reconnectSnapshot() orelse return error.ServiceUnavailable;
        if (reconnect.key == null or !reconnect.key.?.eql(capture.create_key) or (reconnect.phase != .active and reconnect.phase != .ready)) return error.StaleSession;
        return runtime.workerPtr();
    }
    pub fn preflight(self: *Bridge, app: *Application, invocation: loop.Invocation) !void {
        const worker = try self.validate(app, invocation);
        if (invocation.call.tool != .list_remote_files and invocation.call.tool != .read_remote_file) return;
        const files = self.files orelse return error.FileSourceUnavailable;
        const host = files.file_host orelse return error.FileSourceUnavailable;
        if (self.capture.?.file_bindings == null) {
            const owner = self.capture.?.owner;
            self.capture.?.file_bindings = if (self.capture.?.file_dedicated) try files.ensureReadonlySource(owner) else try files.ensureSharedReadonlySource(owner, try worker.readonlyProvider());
        }
        const state = host.state(self.capture.?.file_bindings.?.directory) orelse return error.StaleBinding;
        if (state.phase == .connecting) return error.WorkerBusy;
        if (state.phase != .ready) return error.RemoteFilesUnavailable;
    }
    fn finish(current: *Exchange, result: loop.TargetResult) void {
        if (current.ready.load(.acquire)) return;
        if (result.local_released) if (current.operation_key) |key| if (current.operation_journal) |journal| {
            if (result.status == .succeeded) {
                _ = journal.completeReleased(key, "SSH tool finished") catch {};
            } else {
                _ = journal.failReleased(key, .{ .domain = .host, .code = result.error_code orelse @tagName(result.status), .cleanup = .released, .safe_message = "SSH tool finished" }) catch {};
            }
        };
        trace.emit(.{ .event = "host_result", .sequence = current.sequence, .turn_id = current.invocation.key.turn_id, .call_id = current.invocation.key.call_id, .result = result });
        current.outcome = loop.Outcome.copy(current.allocator, &.{result}) catch |err| {
            current.failure = err;
            current.ready.store(true, .release);
            return;
        };
        current.ready.store(true, .release);
    }
    fn failure(current: *Exchange, status: loop.Status, err: anyerror) void {
        finish(current, .{ .session_id = current.invocation.call.targets.ids[0], .status = status, .transport = if (current.invocation.call.tool == .list_remote_files or current.invocation.call.tool == .read_remote_file) .sftp else .ssh, .error_code = @errorName(err) });
    }
    fn uncertain(self: *Bridge, err: anyerror) void {
        if (self.active) |*active| active.cleanup_unknown = true;
        if (self.exchange) |current| finish(current, .{ .session_id = @backingInt(self.capture.?.owner.session_id), .status = .unknown, .transport = .ssh, .local_released = false, .remote_effect_unknown = self.active != null, .error_code = @errorName(err) });
    }
    /// Read only copied snapshots; neither cancellation nor retirement calls
    /// libssh2. The original worker retains native ownership throughout.
    fn pollActive(self: *Bridge) void {
        const active = self.active orelse return;
        var snapshot = active.facade.snapshot(active.handle, self.allocator) catch |err| {
            if (err == error.WorkerBusy) return;
            self.uncertain(err);
            return;
        };
        defer snapshot.deinit();
        const value = snapshot.value;
        const capture = self.capture.?;
        if (value.key == null or !value.key.?.eql(active.key) or value.call_id != active.key.operation_id or value.service_binding == null or !value.service_binding.?.eql(capture.exec_binding)) {
            active.facade.cancel(active.handle);
            self.uncertain(error.ExecIdentityMismatch);
            return;
        }
        if (value.cleanup == .unknown) {
            self.uncertain(error.SshCleanupUnknown);
            return;
        }
        if (!terminal(value.status) or value.cleanup != .released) return;
        const receipt = active.facade.closeCall(active.handle) catch |err| {
            if (err == error.WorkerBusy) return;
            self.uncertain(err);
            return;
        };
        if (receipt != .released) {
            if (receipt == .unknown) self.uncertain(error.SshCleanupUnknown);
            return;
        }
        self.active = null;
        // The native child has been retired, so allocation failure here cannot
        // turn a retained resource into a released one.
        _ = active.journal.completeReleased(active.key, "SSH tool finished") catch {};
        if (self.exchange) |current| {
            const text_output = std.unicode.utf8ValidateSlice(value.stdout) and std.unicode.utf8ValidateSlice(value.stderr);
            const status: loop.Status = if (active.stale) .rejected else if (value.status == .cancelled) .cancelled else if (value.status == .timed_out) .timed_out else if (!text_output) .failed else if (value.status == .completed and value.exit_code != null and value.exit_code.? == 0) .succeeded else .failed;
            finish(current, .{ .session_id = @backingInt(capture.owner.session_id), .status = status, .transport = .ssh, .stdout = if (text_output and !active.stale) value.stdout else "", .stderr = if (text_output and !active.stale) value.stderr else "", .exit = value.exit_code, .cwd = capture.cwd, .elapsed_ms = value.elapsed_ms, .truncated = value.truncated, .remote_effect_unknown = active.stale or value.status == .cancelled or value.status == .timed_out, .error_code = if (active.stale) "StaleBinding" else if (!text_output) "NonTextToolOutput" else value.failure });
        }
    }
    /// Controller only. The close hook must hold the original runtime until
    /// stopOwner reports released; a lost binding never redirects an exec.
    pub fn pump(self: *Bridge, app: *Application) void {
        self.lock();
        defer self.mutex.unlock();
        if (self.file_reader != null) {
            self.pollFile(app);
            return;
        }
        if (self.active) |*active| {
            if (self.exchange) |current| {
                if (current.cancel.load(.acquire)) active.facade.cancel(active.handle);
                _ = self.validate(app, current.invocation) catch {
                    active.stale = true;
                    active.facade.cancel(active.handle);
                };
            }
            self.pollActive();
            return;
        }
        const current = self.exchange orelse return;
        if (current.ready.load(.acquire)) return;
        if (current.cancel.load(.acquire)) return failure(current, .cancelled, error.Cancelled);
        const worker = self.validate(app, current.invocation) catch |err| return failure(current, .rejected, err);
        const capture = self.capture.?;
        if (current.invocation.verdict == .deny_exec_copy_only) return failure(current, .rejected, error.ToolExecutionDenied);
        if (current.invocation.verdict == .need_confirm) switch (current.approval) {
            .pending => return,
            .rejected => return failure(current, .rejected, error.ToolApprovalRejected),
            .approved => {},
        };
        switch (current.invocation.call.tool) {
            .read_terminal => {
                const cap = @min(current.invocation.call.max_bytes, current.invocation.capture_bytes);
                var lines = worker.readLines(.{ .max_lines = 1024, .max_bytes = cap }, self.allocator) catch |err| return failure(current, .failed, err);
                defer lines.deinit(self.allocator);
                const output = flattenLines(lines, cap, self.allocator) catch |err| return failure(current, .failed, err);
                defer self.allocator.free(output);
                trace.emit(.{ .event = "terminal_read", .sequence = current.sequence, .turn_id = current.invocation.key.turn_id, .call_id = current.invocation.key.call_id, .owner = capture.owner, .create_key = capture.create_key, .service_binding = capture.terminal_binding, .transport = "ssh", .max_bytes = cap, .actual_bytes = output.len, .truncated = lines.truncated or output.len == cap });
                finish(current, .{ .session_id = @backingInt(capture.owner.session_id), .status = .succeeded, .transport = .ssh, .stdout = output, .cwd = capture.cwd, .truncated = lines.truncated or output.len == cap });
            },
            .run_command => {
                const facade = app.sshExecService(capture.owner) catch |err| {
                    if (err == error.WorkerBusy) return;
                    return failure(current, .rejected, err);
                };
                if (current.operation_key == null) {
                    current.operation_key = app.sessions.journal.begin(.{ .session = capture.owner }, capture.create_key.attempt_id) catch |err| return failure(current, .failed, err);
                    current.operation_journal = &app.sessions.journal;
                }
                const key = current.operation_key.?;
                const handle = facade.exec(current.invocation.call.command, .{ .key = key, .call_id = key.operation_id, .service_binding = capture.exec_binding, .cwd = capture.cwd, .timeout_ms = current.invocation.timeout_ms, .capture_cap = @min(current.invocation.call.max_bytes, current.invocation.capture_bytes) }) catch |err| {
                    if (err == error.WorkerBusy) return;
                    _ = app.sessions.journal.failReleased(key, .{ .domain = .host, .code = @errorName(err), .cleanup = .released, .safe_message = "SSH tool did not start" }) catch {};
                    return failure(current, .failed, err);
                };
                self.active = .{ .facade = facade, .handle = handle, .key = key, .journal = &app.sessions.journal };
                trace.emit(.{ .event = "exec_started", .sequence = current.sequence, .turn_id = current.invocation.key.turn_id, .call_id = current.invocation.key.call_id, .operation = key, .create_key = capture.create_key, .service_binding = capture.exec_binding, .transport = "ssh", .target = capture.target, .cwd = capture.cwd });
            },
            .list_remote_files, .read_remote_file => {
                const files = self.files orelse return failure(current, .rejected, error.FileSourceUnavailable);
                const host = files.file_host orelse return failure(current, .rejected, error.FileSourceUnavailable);
                if (self.capture.?.file_bindings == null) {
                    const bindings = if (capture.file_dedicated)
                        files.ensureReadonlySource(capture.owner)
                    else blk: {
                        const readonly_provider = worker.readonlyProvider() catch |err| return failure(current, .rejected, err);
                        break :blk files.ensureSharedReadonlySource(capture.owner, readonly_provider);
                    };
                    self.capture.?.file_bindings = bindings catch |err| return failure(current, .rejected, err);
                }
                const bindings = self.capture.?.file_bindings.?;
                const state = host.state(bindings.directory) orelse return failure(current, .rejected, error.StaleBinding);
                if (state.phase == .connecting) {
                    if (@import("../platform/realtime.zig").monotonicNs() - self.file_started_ns >= @as(i128, current.invocation.timeout_ms) * std.time.ns_per_ms) return failure(current, .timed_out, error.ToolDeadlineExceeded);
                    return;
                }
                if (state.phase != .ready) return failure(current, .failed, error.RemoteFilesUnavailable);
                const context: file_capture.Context = .{ .scope = current.invocation.scope, .source = .{ .session = capture.owner, .revision = current.sequence, .bindings = bindings } };
                self.file_reader = file_capture.Reader.start(self.allocator, host, context, current.invocation.call.path, if (current.invocation.call.tool == .list_remote_files) .{ .list = .{} } else .{ .read = .{ .max_bytes = current.invocation.call.max_bytes } }) catch |err| return failure(current, .failed, err);

                self.file_timed_out = false;
            },
        }
    }
    /// Gates runtime destruction, including after the AI worker has returned
    /// an uncertain result. It never closes the whole SSH service.
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
        if (!pending and self.active == null and self.file_reader == null) return impact;
        var hash = std.hash.Wyhash.init(0x4149535348);
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
            std.hash.autoHash(&hash, active.key.operation_id);
            std.hash.autoHash(&hash, active.cleanup_unknown);
            if (active.cleanup_unknown) impact.unknown = 1;
        }
        if (self.file_reader) |reader| {
            std.hash.autoHash(&hash, reader.original.source.revision);
            if (reader.cleanupReceipt() == .unknown) impact.unknown = 1;
        }
        impact.ai = hash.final();
        if (impact.ai == 0) impact.ai = 1;
        var text: [512]u8 = undefined;
        const detail = std.fmt.bufPrint(&text, "AI #{d} · {s} · 待批 {d} · 执行 {d} · 文件读取 {d}", .{ @backingInt(owner.session_id), capture.target, @as(u8, if (self.exchange) |current| @intFromBool(pending and current.invocation.verdict == .need_confirm and current.approval == .pending) else 0), @as(u8, @intFromBool(self.active != null)), @as(u8, @intFromBool(self.file_reader != null)) }) catch "AI SSH 调用正在收尾";
        impact.setDetail(detail);
        return impact;
    }
    pub fn stopOwner(self: *Bridge, owner: identity.SessionHandle) sessions.CloseReceipt {
        self.lock();
        defer self.mutex.unlock();
        const capture = self.capture orelse return .released;
        if (!capture.owner.eql(owner)) return .released;
        if (self.exchange) |current| current.cancel.store(true, .release);
        if (self.file_reader) |reader| {
            reader.cancel();
            self.pollFile(null);
            if (self.file_reader) |remaining| return if (remaining.cleanupReceipt() == .unknown) .unknown else .awaiting;
        }
        if (self.active) |active| {
            active.facade.cancel(active.handle);
            self.pollActive();
            if (self.active) |remaining| return if (remaining.cleanup_unknown) .unknown else .awaiting;
        }
        if (self.exchange) |current| if (!current.ready.load(.acquire)) failure(current, .cancelled, error.Cancelled);
        return .released;
    }
    /// Exceptional app teardown transfers any still-live child back to its
    /// existing worker. AppHost must outlive this call, and close that worker
    /// only after the waiting AI worker has joined. No released receipt is made.
    pub fn shutdown(self: *Bridge, _: ?*Application) void {
        self.lock();
        defer self.mutex.unlock();
        self.shutting_down = true;
        const child_retained = self.active != null or self.file_reader != null;
        if (self.file_reader) |reader| {
            reader.detachForHostShutdown();
            self.file_reader = null;
        }
        if (self.active) |active| active.facade.cancel(active.handle);
        if (self.exchange) |current| if (!current.ready.load(.acquire)) finish(current, .{ .session_id = current.invocation.call.targets.ids[0], .status = if (child_retained) .unknown else .cancelled, .transport = if (current.invocation.call.tool == .list_remote_files or current.invocation.call.tool == .read_remote_file) .sftp else .ssh, .local_released = !child_retained, .remote_effect_unknown = self.active != null, .error_code = "ToolHostShuttingDown" });
        self.active = null;
    }
    pub fn deinit(self: *Bridge) void {
        std.debug.assert(self.exchange == null and self.active == null and self.file_reader == null);
        self.freeCapture();
        self.* = undefined;
    }
};

fn liveBinding(app: *Application, owner: identity.SessionHandle, kind: sessions.ServiceKind) !sessions.ServiceHandle {
    const binding = switch (app.sessions.queryService(owner, kind)) {
        .available => |value| value,
        else => return error.ServiceUnavailable,
    };
    if (!app.sessions.bindingIsLive(binding)) return error.StaleBinding;
    return binding;
}
fn validateTarget(capture: Capture, invocation: loop.Invocation, delegated_owner: ?@import("../ai/tool_scope.zig").Owner) !void {
    const id = @backingInt(capture.owner.session_id);
    if (delegated_owner) |owner| {
        if (!owner.eql(invocation.key.owner)) return error.TargetOutsideAssistant;
    } else if (invocation.key.owner != .session or invocation.key.owner.session != id) return error.TargetOutsideAssistant;
    if (invocation.call.targets.len != 1 or invocation.call.targets.ids[0] != id) return error.TargetOutsideAssistant;
    _ = try invocation.scope.validate(invocation.call.targets.slice());
}
fn terminal(status: exec.Status) bool {
    return status != .queued and status != .opening and status != .running;
}
fn flattenLines(lines: viewport.Lines, cap: usize, allocator: std.mem.Allocator) ![]u8 {
    var bytes: std.ArrayList(u8) = .empty;
    defer bytes.deinit(allocator);
    for (lines.lines) |line| {
        var keep = @min(line.len, cap - bytes.items.len);
        while (keep > 0 and !std.unicode.utf8ValidateSlice(line[0..keep])) keep -= 1;
        try bytes.appendSlice(allocator, line[0..keep]);
        if (bytes.items.len < cap) try bytes.append(allocator, '\n');
        if (bytes.items.len == cap) break;
    }
    return bytes.toOwnedSlice(allocator);
}

const TestPeer = struct {
    key: operation.OperationKey,
    binding: sessions.ServiceHandle,
    cleanup: operation.Cleanup = .releasing,
    status: exec.Status = .cancelled,
    snapshot_busy: bool = false,
    close_busy: bool = false,
    cancel_count: usize = 0,
    close_count: usize = 0,
    retired: bool = false,
    fn facade(self: *TestPeer) exec.ExecBridge {
        return .{ .ctx = self, .exec_fn = unexpectedExec, .abort_fn = cancel, .poll_fn = poll, .close_fn = unexpectedClose, .snapshot_fn = snapshot, .close_call_fn = closeCall };
    }
    fn unexpectedExec(_: *anyopaque, _: []const u8, _: exec.ExecOpts) !exec.ExecHandle {
        return error.UnexpectedRedispatch;
    }
    fn unexpectedClose(_: *anyopaque) void {
        @panic("AI must never close the shared SSH service");
    }
    fn from(handle: exec.ExecHandle) *TestPeer {
        return @ptrCast(@alignCast(handle.ptr));
    }
    fn cancel(handle: exec.ExecHandle) void {
        from(handle).cancel_count += 1;
    }
    fn poll(_: exec.ExecHandle) ?exec.ExecResult {
        return null;
    }
    fn snapshot(handle: exec.ExecHandle, allocator: std.mem.Allocator) !exec.OwnedResult {
        const self = from(handle);
        std.debug.assert(!self.retired);
        if (self.snapshot_busy) return error.WorkerBusy;
        var arena = std.heap.ArenaAllocator.init(allocator);
        errdefer arena.deinit();
        const stdout = try arena.allocator().dupe(u8, "SSH_REAL_RECEIPT_FIXTURE");
        return .{ .arena = arena, .value = .{ .stdout = stdout, .stderr = "", .exit_code = if (self.status == .completed) 0 else null, .elapsed_ms = 5, .key = self.key, .call_id = self.key.operation_id, .service_binding = self.binding, .status = self.status, .cleanup = self.cleanup } };
    }
    fn closeCall(handle: exec.ExecHandle) !operation.Cleanup {
        const self = from(handle);
        self.close_count += 1;
        std.debug.assert(!self.retired);
        if (self.close_busy) return error.WorkerBusy;
        if (self.cleanup == .released) self.retired = true;
        return self.cleanup;
    }
};
fn testCapture(allocator: std.mem.Allocator, owner: identity.SessionHandle, key: operation.OperationKey) !Capture {
    const binding: sessions.ServiceHandle = .{ .resource_owner = .{ .session = owner }, .origin_session = owner, .kind = .exec, .binding_id = 7, .binding_generation = owner.generation };
    var terminal_binding = binding;
    terminal_binding.kind = .terminal;
    terminal_binding.binding_id = 8;
    return .{ .owner = owner, .create_key = key, .exec_binding = binding, .terminal_binding = terminal_binding, .cwd = null, .target = try allocator.dupe(u8, "SSH · captured@original.example:22") };
}
fn testInvocation(id: u64) loop.Invocation {
    return .{ .key = .{ .owner = .{ .session = id }, .turn_id = 3, .call_id = "ssh-original-call" }, .scope = .{ .owner = .{ .session = id }, .members = .{ .ids = .{id} ++ @as([15]u64, @splat(0)), .len = 1 } }, .round_index = 0, .call_index = 0, .arguments = "df -h", .arguments_hash = @splat(1), .call = .{ .tool = .run_command, .command = "df -h", .targets = .{ .ids = .{id} ++ @as([15]u64, @splat(0)), .len = 1 } }, .verdict = .need_confirm, .policy_revision = 1 };
}

test "SSH AI tools cancellation waits for the original child receipt through busy snapshots and retirement" {
    const a = std.testing.allocator;
    const owner: identity.SessionHandle = .{ .session_id = @fromBackingInt(41), .generation = 2 };
    var journal = operation.Journal.init(a);
    defer journal.deinit();
    const key = try journal.begin(.{ .session = owner }, 1);
    var bridge = Bridge.init(a);
    defer bridge.deinit();
    bridge.capture = try testCapture(a, owner, key);
    var peer: TestPeer = .{ .key = key, .binding = bridge.capture.?.exec_binding, .snapshot_busy = true };
    bridge.active = .{ .facade = peer.facade(), .handle = .{ .ptr = &peer }, .key = key, .journal = &journal };
    var current: Exchange = .{ .invocation = testInvocation(41), .allocator = a, .sequence = 4 };
    bridge.exchange = &current;
    defer {
        bridge.exchange = null;
        if (current.outcome) |*result| result.deinit(a);
    }
    const other = identity.SessionHandle{ .session_id = owner.session_id, .generation = 3 };
    try std.testing.expectEqual(sessions.CloseReceipt.released, bridge.stopOwner(other));
    try std.testing.expectEqual(@as(usize, 0), peer.cancel_count);
    try std.testing.expectEqual(sessions.CloseReceipt.awaiting, bridge.stopOwner(owner));
    try std.testing.expect(!current.ready.load(.acquire));
    peer.snapshot_busy = false;
    try std.testing.expectEqual(sessions.CloseReceipt.awaiting, bridge.stopOwner(owner));
    try std.testing.expect(!current.ready.load(.acquire));
    peer.cleanup = .released;
    peer.close_busy = true;
    try std.testing.expectEqual(sessions.CloseReceipt.awaiting, bridge.stopOwner(owner));
    try std.testing.expect(bridge.active != null and !peer.retired);
    try std.testing.expect(!current.ready.load(.acquire));
    peer.close_busy = false;
    try std.testing.expectEqual(sessions.CloseReceipt.released, bridge.stopOwner(owner));
    try std.testing.expect(peer.retired and bridge.active == null);
    try std.testing.expectEqual(@as(usize, 2), peer.close_count);
    try std.testing.expectEqual(loop.Status.cancelled, current.outcome.?.targets[0].status);
    try std.testing.expect(current.outcome.?.targets[0].remote_effect_unknown);
    try std.testing.expect(current.outcome.?.targets[0].local_released);
    try std.testing.expectEqual(loop.Transport.ssh, current.outcome.?.targets[0].transport);
    try std.testing.expect(journal.isTerminal(key));
}

test "SSH AI tools retain unknown cleanup and refuse to call it released" {
    const a = std.testing.allocator;
    const owner: identity.SessionHandle = .{ .session_id = @fromBackingInt(41), .generation = 2 };
    var journal = operation.Journal.init(a);
    defer journal.deinit();
    const key = try journal.begin(.{ .session = owner }, null);
    var bridge = Bridge.init(a);
    defer bridge.deinit();
    bridge.capture = try testCapture(a, owner, key);
    var peer: TestPeer = .{ .key = key, .binding = bridge.capture.?.exec_binding, .cleanup = .unknown };
    bridge.active = .{ .facade = peer.facade(), .handle = .{ .ptr = &peer }, .key = key, .journal = &journal };
    var current: Exchange = .{ .invocation = testInvocation(41), .allocator = a, .sequence = 5 };
    bridge.exchange = &current;
    defer {
        bridge.exchange = null;
        if (current.outcome) |*result| result.deinit(a);
    }
    try std.testing.expectEqual(sessions.CloseReceipt.unknown, bridge.stopOwner(owner));
    try std.testing.expectEqual(loop.Status.unknown, current.outcome.?.targets[0].status);
    try std.testing.expect(!current.outcome.?.targets[0].local_released);
    try std.testing.expect(bridge.active != null and !peer.retired);
    try std.testing.expectError(error.ToolCleanupPending, bridge.clear());
    try std.testing.expect(!journal.isTerminal(key));
    // A later real parent receipt can converge the same original child.
    peer.cleanup = .released;
    try std.testing.expectEqual(sessions.CloseReceipt.released, bridge.stopOwner(owner));
    try std.testing.expect(bridge.active == null and peer.retired);
    try std.testing.expect(!current.outcome.?.targets[0].local_released);
}

test "SSH AI tools approval stays on the captured endpoint and exact sequence hash" {
    const a = std.testing.allocator;
    const owner: identity.SessionHandle = .{ .session_id = @fromBackingInt(41), .generation = 2 };
    const key: operation.OperationKey = .{ .owner = .{ .session = owner }, .operation_id = 1 };
    var bridge = Bridge.init(a);
    defer bridge.deinit();
    bridge.capture = try testCapture(a, owner, key);
    var current: Exchange = .{ .invocation = testInvocation(41), .allocator = a, .sequence = 17 };
    bridge.exchange = &current;
    defer {
        bridge.exchange = null;
        if (current.outcome) |*result| result.deinit(a);
    }
    const approval = bridge.pendingApproval().?;
    try std.testing.expectEqualStrings("SSH · captured@original.example:22", approval.target);
    try std.testing.expect(approval.owner.eql(owner) and approval.cwd == null);
    var changed_hash = approval.arguments_hash;
    changed_hash[0] ^= 1;
    try std.testing.expectError(error.StaleApproval, bridge.decide(16, approval.arguments_hash, true));
    try std.testing.expectError(error.StaleApproval, bridge.decide(17, changed_hash, true));
    try bridge.decide(17, approval.arguments_hash, false);
    try std.testing.expect(bridge.pendingApproval() == null and bridge.active == null);
    try std.testing.expectEqual(sessions.CloseReceipt.released, bridge.stopOwner(owner));
    try std.testing.expectEqual(loop.Status.cancelled, current.outcome.?.targets[0].status);
    try std.testing.expect(!current.outcome.?.targets[0].remote_effect_unknown);
    var other = testInvocation(42);
    try std.testing.expectError(error.TargetOutsideAssistant, validateTarget(bridge.capture.?, other, null));
    other = testInvocation(41);
    other.call.targets.ids[0] = 42;
    try std.testing.expectError(error.TargetOutsideAssistant, validateTarget(bridge.capture.?, other, null));
}

test "SSH AI tools terminal copy is bounded and keeps complete UTF8" {
    const a = std.testing.allocator;
    var adapter = try @import("../vt/ghostty_adapter.zig").Adapter.init(a, 4, 40);
    defer adapter.destroy();
    _ = try adapter.feed("old\r\n新终端输出\r\nlatest");
    var lines = try adapter.readLines(.{ .max_lines = 2, .max_bytes = 20 }, a);
    defer lines.deinit(a);
    const output = try flattenLines(lines, 17, a);
    defer a.free(output);
    try std.testing.expect(output.len <= 17);
    try std.testing.expect(std.unicode.utf8ValidateSlice(output));
    try std.testing.expect(std.mem.indexOf(u8, output, "old") == null);
    try std.testing.expect(std.mem.indexOf(u8, output, "新") != null or std.mem.indexOf(u8, output, "latest") != null);
}

test "SSH pending approval cancellation has no remote effect unknown without dispatch" {
    const a = std.testing.allocator;
    const owner: identity.SessionHandle = .{ .session_id = @fromBackingInt(41), .generation = 2 };
    var journal = operation.Journal.init(a);
    defer journal.deinit();
    const key = try journal.begin(.{ .session = owner }, 1);
    var bridge = Bridge.init(a);
    defer bridge.deinit();
    bridge.capture = try testCapture(a, owner, key);
    var current: Exchange = .{ .invocation = testInvocation(41), .allocator = a, .sequence = 4 };
    bridge.exchange = &current;
    defer {
        bridge.exchange = null;
        if (current.outcome) |*outcome| outcome.deinit(a);
    }
    try std.testing.expectEqual(sessions.CloseReceipt.released, bridge.stopOwner(owner));
    try std.testing.expect(current.ready.load(.acquire));
    try std.testing.expectEqual(loop.Status.cancelled, current.outcome.?.targets[0].status);
    try std.testing.expect(!current.outcome.?.targets[0].remote_effect_unknown);
    try std.testing.expect(bridge.active == null);
}

test "SSH AI tools write risk excludes pending reads but retains unknown command cleanup" {
    const a = std.testing.allocator;
    const owner: identity.SessionHandle = .{ .session_id = @fromBackingInt(41), .generation = 2 };
    const other: identity.SessionHandle = .{ .session_id = @fromBackingInt(41), .generation = 3 };
    var journal = operation.Journal.init(a);
    defer journal.deinit();
    const key = try journal.begin(.{ .session = owner }, 1);
    var bridge = Bridge.init(a);
    defer bridge.deinit();
    bridge.capture = try testCapture(a, owner, key);
    var current: Exchange = .{ .invocation = testInvocation(41), .allocator = a, .sequence = 4 };
    bridge.exchange = &current;
    defer bridge.exchange = null;
    try std.testing.expect(bridge.writeRisk(owner));
    try std.testing.expect(!bridge.writeRisk(other));
    for ([_]@import("../ai/tool_scope.zig").Tool{ .read_terminal, .list_remote_files, .read_remote_file }) |tool| {
        current.invocation.call.tool = tool;
        try std.testing.expect(!bridge.writeRisk(owner));
        try std.testing.expect(bridge.closeImpact(owner).ai != 0);
    }
    current.invocation.call.tool = .run_command;
    current.ready.store(true, .release);
    try std.testing.expect(!bridge.writeRisk(owner));
    var peer: TestPeer = .{ .key = key, .binding = bridge.capture.?.exec_binding, .cleanup = .unknown };
    bridge.active = .{ .facade = peer.facade(), .handle = .{ .ptr = &peer }, .key = key, .journal = &journal, .cleanup_unknown = true };
    defer bridge.active = null;
    try std.testing.expect(bridge.writeRisk(owner));
}

/// Registered only by providers using this SSH compatibility engine.
pub fn createAdapter(allocator: std.mem.Allocator) !@import("../ai/legacy_adapter.zig").Adapter {
    return @import("../ai/legacy_adapter.zig").Adapter.create(Bridge, Application, allocator);
}
