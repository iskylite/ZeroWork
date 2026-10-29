const std = @import("std");
const ssh = @import("session.zig");
const Session = ssh.Session;
const Channel = @import("channel.zig").Channel;
const bridge = @import("../../ai/execbridge.zig");
const ServiceHandle = @import("../../host/session_host.zig").ServiceHandle;
const operation = @import("../../host/operation.zig");
const c = @import("generated_ssh_channel");
const sc = @import("generated_ssh_session");

/// One mailbox attached to the existing Session IO owner, never another SSH
/// thread. Public submission/poll/cancel perform no native calls. step() owns
/// every exec channel call and resumes one Session channel-open at a time.
pub const SshExecBridge = struct {
    pub const max_calls = 8;
    pub const max_capture = 16 * 1024 * 1024;
    session: *Session,
    allocator: std.mem.Allocator,
    commands: [max_calls]?*Command = @splat(null),
    mutex: std.atomic.Value(bool) = .init(false),
    close_requested: std.atomic.Value(bool) = .init(false),
    io_owner: ?std.Thread.Id = null,
    binding: ?ServiceHandle = null,
    next_call_id: u64 = 1,
    exhausted: bool = false,

    pub fn init(session: *Session, allocator: std.mem.Allocator) SshExecBridge {
        return .{ .session = session, .allocator = allocator };
    }
    fn tryLock(self: *SshExecBridge) bool {
        return !self.mutex.swap(true, .acquire);
    }
    fn unlock(self: *SshExecBridge) void {
        self.mutex.store(false, .release);
    }

    /// Bind only a real host-provided exec binding. Runtime callers validate
    /// its liveness with SessionHost before exposing this service to consumers.
    pub fn bindService(self: *SshExecBridge, binding: ServiceHandle) !void {
        if (!self.tryLock()) return error.WorkerBusy;
        defer self.unlock();
        if (self.close_requested.load(.acquire)) return error.BridgeClosed;
        if (binding.kind != .exec or binding.binding_id == 0 or binding.binding_generation == 0) return error.InvalidBinding;
        if (binding.resource_owner != .session) return error.InvalidBinding;
        const key = self.session.resource_key orelse return error.MissingOperation;
        if (key.owner != .session or !key.owner.session.eql(binding.resource_owner.session)) return error.StaleSession;
        if (self.binding) |current| if (!current.eql(binding)) return error.StaleBinding;
        self.binding = binding;
    }

    /// Provider-only read-only metadata request. Its reserved call ID never
    /// consumes caller IDs (AI sessions commonly start their own IDs at one).
    pub fn diagnostic(self: *SshExecBridge, command: []const u8, opts: bridge.ExecOpts) !bridge.ExecHandle {
        var internal = opts;
        internal.call_id = std.math.maxInt(u64);
        return self.submit(command, internal, true);
    }
    pub fn exec(self: *SshExecBridge, command: []const u8, opts: bridge.ExecOpts) !bridge.ExecHandle {
        if (opts.call_id == std.math.maxInt(u64)) return error.InvalidCallId;
        return self.submit(command, opts, false);
    }
    fn submit(self: *SshExecBridge, command: []const u8, opts: bridge.ExecOpts, diagnostic_call: bool) !bridge.ExecHandle {
        if (command.len == 0) return error.EmptyCommand;
        if (command.len > std.math.maxInt(u16) - 1 or std.mem.indexOfScalar(u8, command, 0) != null) return error.InvalidCommand;
        if (opts.capture_cap == 0 or opts.capture_cap > max_capture) return error.InvalidCaptureLimit;
        if (!self.tryLock()) return error.WorkerBusy;
        defer self.unlock();
        if (self.close_requested.load(.acquire)) return error.BridgeClosed;
        if (self.session.state != .active) return error.SessionNotActive;
        const key = opts.key orelse self.session.resource_key;
        const binding = opts.service_binding orelse self.binding;
        if (self.binding) |current| {
            if (binding == null or !current.eql(binding.?)) return error.StaleBinding;
            if (opts.key == null) return error.MissingOperation;
        } else if (opts.service_binding != null) return error.UnboundService;
        if (key) |value| {
            if (value.operation_id == 0) return error.InvalidOperation;
            if (self.session.resource_key) |origin| if (!value.owner.eql(origin.owner)) return error.StaleSession;
        }
        if (binding) |value| if (key == null or key.?.owner != .session or !key.?.owner.session.eql(value.resource_owner.session)) return error.StaleSession;
        const call_id = if (opts.call_id != 0) opts.call_id else self.next_call_id;
        for (self.commands) |pending| if (pending) |item| {
            if (item.call_id == call_id) {
                if (item.key != null and key != null and !item.key.?.owner.eql(key.?.owner)) continue;
                if (!std.meta.eql(item.key, key) or !std.mem.eql(u8, item.command, command) or !optionalTextEql(item.cwd, opts.cwd) or item.cap != opts.capture_cap or item.timeout_ms != opts.timeout_ms) return error.ConflictingCallId;
                return .{ .ptr = item };
            }
        };
        if (!diagnostic_call and (self.exhausted or call_id < self.next_call_id)) return error.StaleCallId;
        var empty: ?usize = null;
        for (self.commands, 0..) |slot, index| if (slot == null) {
            empty = index;
            break;
        };
        const index = empty orelse return error.ExecQueueFull;
        const item = try self.allocator.create(Command);
        errdefer self.allocator.destroy(item);
        item.* = try Command.init(self, call_id, key, binding, command, opts);
        self.commands[index] = item;
        if (!diagnostic_call) {
            if (call_id == std.math.maxInt(u64) - 1) self.exhausted = true else self.next_call_id = call_id + 1;
        }
        return .{ .ptr = item };
    }

    pub fn abortHandle(handle: bridge.ExecHandle) void {
        const item: *Command = @ptrCast(@alignCast(handle.ptr));
        item.cancel_requested.store(true, .release);
    }
    pub fn pollHandle(handle: bridge.ExecHandle) ?bridge.ExecResult {
        const item: *Command = @ptrCast(@alignCast(handle.ptr));
        const self = item.owner;
        if (!self.tryLock()) return null;
        defer self.unlock();
        return if (item.terminal()) item.resultValue() else null;
    }
    pub fn snapshot(self: *SshExecBridge, handle: bridge.ExecHandle, allocator: std.mem.Allocator) !bridge.OwnedResult {
        if (!self.tryLock()) return error.WorkerBusy;
        defer self.unlock();
        const item = try self.find(handle);
        var arena = std.heap.ArenaAllocator.init(allocator);
        errdefer arena.deinit();
        const owned = arena.allocator();
        var result = item.resultValue();
        result.stdout = try owned.dupe(u8, result.stdout);
        result.stderr = try owned.dupe(u8, result.stderr);
        result.command = try owned.dupe(u8, result.command);
        result.cwd = if (result.cwd) |cwd| try owned.dupe(u8, cwd) else null;
        return .{ .arena = arena, .value = result };
    }
    fn find(self: *SshExecBridge, handle: bridge.ExecHandle) !*Command {
        for (self.commands) |slot| if (slot) |item| if (@intFromPtr(item) == @intFromPtr(handle.ptr)) return item;
        return error.StaleCall;
    }
    pub fn asBridge(self: *SshExecBridge) bridge.ExecBridge {
        return .{ .ctx = self, .exec_fn = bridgeExec, .abort_fn = abortHandle, .poll_fn = pollHandle, .close_fn = bridgeClose, .snapshot_fn = bridgeSnapshot, .close_call_fn = bridgeCloseCall };
    }
    fn bridgeExec(ctx: *anyopaque, command: []const u8, opts: bridge.ExecOpts) !bridge.ExecHandle {
        return @as(*SshExecBridge, @ptrCast(@alignCast(ctx))).exec(command, opts);
    }
    fn bridgeClose(ctx: *anyopaque) void {
        @as(*SshExecBridge, @ptrCast(@alignCast(ctx))).close();
    }
    fn bridgeSnapshot(handle: bridge.ExecHandle, allocator: std.mem.Allocator) !bridge.OwnedResult {
        const item: *Command = @ptrCast(@alignCast(handle.ptr));
        return item.owner.snapshot(handle, allocator);
    }
    fn bridgeCloseCall(handle: bridge.ExecHandle) !operation.Cleanup {
        const item: *Command = @ptrCast(@alignCast(handle.ptr));
        return switch (try item.owner.closeCall(handle)) {
            .released => .released,
            .awaiting => .releasing,
            .unknown => .unknown,
        };
    }

    /// Request only. The IO owner continues step(), including after a caller
    /// stops polling. A missing peer close acknowledgement is not released.
    pub fn close(self: *SshExecBridge) void {
        self.close_requested.store(true, .release);
    }
    pub fn closeReceipt(self: *SshExecBridge) ssh.ReleaseReceipt {
        self.close();
        if (!self.tryLock()) return .awaiting;
        defer self.unlock();
        var receipt: ssh.ReleaseReceipt = .released;
        for (self.commands) |slot| if (slot) |item| {
            if (item.cleanup == .unknown) receipt = .unknown else if (item.cleanup != .released and receipt != .unknown) receipt = .awaiting;
        };
        return receipt;
    }
    /// Returns released only when the handle can be retired. Old call IDs stay
    /// consumed after retirement; they never issue another remote command.
    pub fn closeCall(self: *SshExecBridge, handle: bridge.ExecHandle) !ssh.ReleaseReceipt {
        if (!self.tryLock()) return error.WorkerBusy;
        defer self.unlock();
        const item = try self.find(handle);
        item.cancel_requested.store(true, .release);
        if (item.cleanup != .released) return if (item.cleanup == .unknown) .unknown else .awaiting;
        for (&self.commands) |*slot| if (slot.* == item) {
            slot.* = null;
            break;
        };
        item.deinit();
        self.allocator.destroy(item);
        return .released;
    }
    pub fn hasPending(self: *SshExecBridge) bool {
        if (!self.tryLock()) return true;
        defer self.unlock();
        for (self.commands) |slot| if (slot) |item| if (item.state != .finished) return true;
        return false;
    }

    /// Every native call is made here, on the existing Session IO thread.
    /// A bounded amount of work per call preserves PTY/cancel responsiveness.
    pub fn step(self: *SshExecBridge) !void {
        if (!self.tryLock()) return;
        defer self.unlock();
        const current = std.Thread.getCurrentId();
        if (self.io_owner) |owner| {
            if (owner != current) return error.WrongIoOwner;
        } else self.io_owner = current;
        var opening: ?*Command = null;
        for (self.commands) |slot| if (slot) |item| if (item.state == .opening) {
            opening = item;
            break;
        };
        for (self.commands) |slot| if (slot) |item| {
            if (self.close_requested.load(.acquire)) item.cancel_requested.store(true, .release);
            item.checkStop();
            if (item.state == .queued) {
                if (opening != null) continue;
                if (!self.session.claimChannelOpen(.{ .kind = .exec, .id = item.call_id })) continue;
                item.state = .opening;
                item.status = .opening;
                item.diagnostics.phase = .opening;
                opening = item;
            }
            item.step();
            item.logReceipt();
            if (opening == item and item.state != .opening) opening = null;
        };
    }
    /// Only after the previous IO owner was joined/stopped. Cleanup/reconnect
    /// transfers the same Session, never runs two owners concurrently.
    pub fn adoptIoAfterOwnerStopped(self: *SshExecBridge) !void {
        if (!self.tryLock()) return error.WorkerBusy;
        defer self.unlock();
        self.io_owner = std.Thread.getCurrentId();
    }
    /// The existing parent Session is the final native owner of every child,
    /// including a channel-open still waiting for confirmation. Call only after
    /// Session.closeReceipt()==released, before destroying local call records.
    pub fn sessionReleased(self: *SshExecBridge) !void {
        if (self.session.handle != null or self.session.state != .closed) return error.CleanupNotReleased;
        if (!self.tryLock()) return error.WorkerBusy;
        defer self.unlock();
        for (self.commands) |slot| if (slot) |item| {
            if (!item.terminal()) item.stop(.cancelled, "SessionClosed");
            if (item.state != .finished) item.finished_ms = nowMs();
            item.channel = null;
            item.cleanup = .released;
            item.state = .finished;
            item.diagnostics.phase = .finished;
            item.diagnostics.release = .released;
            item.logReceipt();
        };
    }
    pub fn transportReplaced(self: *SshExecBridge, replacement: Session) !void {
        if (!self.tryLock()) return error.WorkerBusy;
        defer self.unlock();
        for (self.commands) |slot| if (slot) |item| if (item.cleanup != .released) return error.CleanupNotReleased;
        if (self.session.resource_key) |old_key| if (replacement.resource_key) |new_key| {
            if (!old_key.owner.eql(new_key.owner)) {
                self.next_call_id = 1;
                self.exhausted = false;
            }
        };
        self.session.* = replacement;
        self.binding = null;
        self.close_requested.store(false, .release);
    }
    /// Payloads contain no native borrowed pointers. A caller destroying the
    /// worker after moving an uncertain parent Session to its original ledger
    /// may drop this presentation mailbox without inventing child receipts.
    pub fn deinitLocal(self: *SshExecBridge) void {
        for (&self.commands) |*slot| if (slot.*) |item| {
            item.deinit();
            self.allocator.destroy(item);
            slot.* = null;
        };
    }

    pub const Command = struct {
        owner: *SshExecBridge,
        call_id: u64,
        key: ?operation.OperationKey,
        binding: ?ServiceHandle,
        command: [:0]u8,
        wire_command: [:0]u8,
        cwd: ?[]u8,
        channel: ?Channel = null,
        cap: u32,
        timeout_ms: u32,
        started_ms: i64,
        finished_ms: ?i64 = null,
        closing_ms: ?i64 = null,
        stdout: std.ArrayList(u8) = .empty,
        stderr: std.ArrayList(u8) = .empty,
        stdout_bytes: u64 = 0,
        stderr_bytes: u64 = 0,
        cancel_requested: std.atomic.Value(bool) = .init(false),
        state: enum { queued, opening, requesting, running, closing, finished } = .queued,
        status: bridge.Status = .queued,
        cleanup: operation.Cleanup = .not_started,
        effect: operation.Effect = .none,
        failure: ?[]const u8 = null,
        exit_code: ?i32 = null,
        request_started: bool = false,
        truncated: bool = false,
        diagnostics: bridge.Diagnostics = .{ .request_started = false },
        logged_unknown: bool = false,
        logged_finished: bool = false,

        fn init(owner: *SshExecBridge, call_id: u64, key: ?operation.OperationKey, binding: ?ServiceHandle, text: []const u8, opts: bridge.ExecOpts) !Command {
            const allocator = owner.allocator;
            const command = try allocator.dupeSentinel(u8, text, 0);
            errdefer allocator.free(command);
            const cwd = if (opts.cwd) |value| blk: {
                if (value.len == 0 or value[0] != '/' or value.len > 16 * 1024 or std.mem.indexOfScalar(u8, value, 0) != null or !std.unicode.utf8ValidateSlice(value)) return error.InvalidCwd;
                break :blk try allocator.dupe(u8, value);
            } else null;
            errdefer if (cwd) |value| allocator.free(value);
            const wire = if (cwd) |value| try commandAtCwd(allocator, value, text) else command;
            errdefer if (wire.ptr != command.ptr) allocator.free(wire);
            var stdout: std.ArrayList(u8) = .empty;
            errdefer stdout.deinit(allocator);
            var stderr: std.ArrayList(u8) = .empty;
            errdefer stderr.deinit(allocator);
            // All bounded capture storage exists before an exec packet can be
            // sent; OOM cannot lose bookkeeping for an already running command.
            try stdout.ensureTotalCapacity(allocator, opts.capture_cap);
            try stderr.ensureTotalCapacity(allocator, opts.capture_cap);
            return .{ .owner = owner, .call_id = call_id, .key = key, .binding = binding, .command = command, .wire_command = wire, .cwd = cwd, .cap = opts.capture_cap, .timeout_ms = opts.timeout_ms, .started_ms = nowMs(), .stdout = stdout, .stderr = stderr };
        }
        fn terminal(self: *const Command) bool {
            return switch (self.status) {
                .queued, .opening, .running => false,
                else => true,
            };
        }
        fn stop(self: *Command, status: bridge.Status, failure: ?[]const u8) void {
            if (self.diagnostics.stopped_phase == null) self.diagnostics.stopped_phase = self.diagnostics.phase;
            self.status = status;
            self.failure = failure;
            self.effect = if (self.request_started) .unknown else .none;
            if (self.state == .queued) {
                self.state = .finished;
                self.cleanup = .released;
                self.finished_ms = nowMs();
                self.diagnostics.phase = .finished;
                self.diagnostics.release = .released;
            } else {
                self.cleanup = .releasing;
                if (self.closing_ms == null) self.closing_ms = nowMs();
                // A Session-level open must first settle before another call
                // can open. Never send exec after cancellation during open.
                if (self.state != .opening) {
                    self.state = .closing;
                    self.diagnostics.phase = .closing;
                }
            }
        }
        fn checkStop(self: *Command) void {
            if (self.terminal()) return;
            if (self.cancel_requested.load(.acquire)) self.stop(.cancelled, null) else if (self.timeout_ms != 0 and elapsed(self.started_ms) >= self.timeout_ms) self.stop(.timed_out, "Timeout");
        }
        fn step(self: *Command) void {
            const session = self.owner.session;
            if (self.state == .finished) return;
            if (session.state != .active or session.handle == null) {
                if (!self.terminal()) self.stop(.failed, "SessionUnavailable");
                self.cleanup = .unknown;
                return;
            }
            sc.zw_libssh2_session_nonblocking(session.handle.?);
            if (self.state == .opening) {
                var raw: ?*sc.LIBSSH2_CHANNEL = null;
                const result = sc.zw_libssh2_exec_channel_open_step(session.handle.?, &raw);
                if (result == 1) {
                    self.cleanupDelay();
                    return;
                }
                if (result < 0) {
                    self.diagnostics.channel_open_error = result;
                    session.finishChannelOpen(.{ .kind = .exec, .id = self.call_id });
                    if (!self.terminal()) self.stop(if (result == -21 or result == -22) .channel_rejected else .failed, if (result == -21 or result == -22) "ChannelRejected" else "ChannelOpenFailed");
                    self.state = .finished;
                    self.cleanup = .released; // Native open error frees its unpublished channel.
                    self.finished_ms = nowMs();
                    self.diagnostics.phase = .finished;
                    self.diagnostics.release = .released;
                    return;
                }
                self.channel = .{ .handle = @ptrCast(raw.?) };
                session.finishChannelOpen(.{ .kind = .exec, .id = self.call_id });
                self.cleanup = .not_started;
                self.state = if (self.terminal()) .closing else .requesting;
                self.diagnostics.phase = if (self.terminal()) .closing else .requesting;
            }
            if (self.state == .requesting) {
                self.request_started = true;
                self.diagnostics.request_started = true;
                self.effect = .unknown;
                const result = sc.zw_libssh2_exec_request_step(@ptrCast(self.channel.?.handle), self.wire_command.ptr);
                if (result == 1) return;
                if (result < 0) {
                    self.diagnostics.request_error = result;
                    self.stop(if (result == -22) .channel_rejected else .failed, if (result == -22) "ExecRejected" else "ExecRequestFailed");
                    if (result == -22) self.effect = .none;
                } else {
                    self.state = .running;
                    self.status = .running;
                    self.diagnostics.phase = .running;
                    self.diagnostics.request_accepted = true;
                    self.effect = .partial; // The remote explicitly accepted execution.
                }
            }
            if (self.state == .running or self.state == .closing) {
                self.drain() catch {
                    if (!self.terminal()) self.stop(.failed, "ChannelReadFailed");
                };
                self.captureExit();
                if (self.state == .running and c.zw_libssh2_channel_eof(self.channel.?.handle) != 0) {
                    self.state = .closing;
                    self.diagnostics.eof_received = true;
                    self.diagnostics.phase = .peer_close;
                }
                if (self.state == .closing) self.finishClose();
            }
        }
        fn captureExit(self: *Command) void {
            var status: c_int = 0;
            if (c.zw_libssh2_channel_exit_status_received(self.channel.?.handle, &status) == 1) self.exit_code = status;
        }
        fn drain(self: *Command) !void {
            var buffer: [4096]u8 = undefined;
            for (0..2) |stream| {
                for (0..8) |_| {
                    const count = if (stream == 0) c.zw_libssh2_channel_read(self.channel.?.handle, &buffer, buffer.len) else c.zw_libssh2_channel_read_stderr(self.channel.?.handle, &buffer, buffer.len);
                    if (count < 0) {
                        self.diagnostics.read_error = @intCast(count);
                        return error.ChannelReadFailed;
                    }
                    if (count == 0) break;
                    const size: usize = @intCast(count);
                    if (stream == 0) self.stdout_bytes +|= size else self.stderr_bytes +|= size;
                    const keep = @min(size, self.cap - self.stdout.items.len - self.stderr.items.len);
                    const destination = if (stream == 0) &self.stdout else &self.stderr;
                    destination.appendSliceAssumeCapacity(buffer[0..keep]);
                    if (keep < size) self.truncated = true;
                }
            }
        }
        fn cleanupDelay(self: *Command) void {
            if (self.closing_ms) |started| {
                if (elapsed(started) >= 1000) self.cleanup = .unknown;
            }
        }
        fn finishClose(self: *Command) void {
            const raw = self.channel.?.handle;
            if (!self.terminal() and self.diagnostics.eof_received) {
                // EOF ends output, not the SSH request stream. The server may
                // still send exit-status before CLOSE; closing here can make
                // the peer discard that final result. Timeout/cancel bypass
                // this wait and retain their original cleanup ownership.
                self.diagnostics.phase = .peer_close;
                const wait_result = c.zw_libssh2_channel_wait_closed_step(raw);
                self.captureExit();
                if (wait_result == 1) return;
                if (wait_result < 0) {
                    self.diagnostics.wait_close_error = wait_result;
                    self.stop(.failed, "ChannelWaitCloseFailed");
                }
            }
            self.diagnostics.phase = .closing;
            self.cleanup = .releasing;
            if (self.closing_ms == null) self.closing_ms = nowMs();
            const close_result = c.zw_libssh2_channel_close_step(raw);
            self.captureExit();
            if (close_result == 1) {
                self.cleanupDelay();
                return;
            }
            if (close_result < 0) {
                self.diagnostics.close_error = close_result;
                if (!self.terminal()) self.stop(.failed, "ChannelCloseFailed");
            }
            self.diagnostics.phase = .releasing;
            const release = self.owner.session.closeChannelReceipt(&self.channel.?);
            self.diagnostics.release = switch (release) {
                .awaiting => .releasing,
                .unknown => .unknown,
                .released => .released,
            };
            switch (release) {
                .awaiting => {
                    self.cleanupDelay();
                    return;
                },
                .unknown => {
                    self.cleanup = .unknown;
                    return;
                },
                .released => {
                    self.channel = null;
                    self.cleanup = .released;
                    self.state = .finished;
                    self.diagnostics.phase = .finished;
                    self.finished_ms = nowMs();
                    if (!self.terminal()) {
                        self.status = .completed;
                        if (self.exit_code == null) {
                            self.effect = .unknown;
                            self.failure = "ExitStatusUnavailable";
                        }
                    }
                },
            }
        }
        fn resultValue(self: *const Command) bridge.ExecResult {
            return .{ .stdout = self.stdout.items, .stderr = self.stderr.items, .exit_code = self.exit_code, .elapsed_ms = @intCast(@max(@as(i64, 0), (self.finished_ms orelse nowMs()) - self.started_ms)), .key = self.key, .call_id = self.call_id, .service_binding = self.binding, .command = self.command, .cwd = self.cwd, .timeout_ms = self.timeout_ms, .capture_cap = self.cap, .status = self.status, .truncated = self.truncated, .stdout_bytes = self.stdout_bytes, .stderr_bytes = self.stderr_bytes, .effect = self.effect, .cleanup = self.cleanup, .failure = self.failure, .diagnostics = self.diagnostics };
        }
        fn logReceipt(self: *Command) void {
            const unknown = self.cleanup == .unknown and !self.logged_unknown;
            const finished = self.state == .finished and !self.logged_finished;
            if (!unknown and !finished) return;
            self.logged_unknown = self.logged_unknown or unknown;
            self.logged_finished = self.logged_finished or finished;
            const value = self.resultValue();
            const owner = if (self.key) |key| if (key.owner == .session) key.owner.session else null else null;
            // At most one unknown and one final receipt per call. All fields
            // are fixed enums/numbers; payloads and endpoint text stay out.
            @import("../../platform/applog.zig").info(.ssh, "exec receipt call={d} operation={any} attempt={any} session={any} generation={any} binding={any} binding_generation={any} phase={s} stopped={any} request_started={any} accepted={any} eof={any} status={s} exit={any} effect={s} cleanup={s} elapsed_ms={d} stdout_bytes={d} stderr_bytes={d} captured={d} truncated={any} open_error={any} request_error={any} read_error={any} close_error={any} wait_close_error={any} release={s}", .{ self.call_id, if (self.key) |key| key.operation_id else null, if (self.key) |key| key.attempt_id else null, if (owner) |id| @backingInt(id.session_id) else null, if (owner) |id| id.generation else null, if (self.binding) |binding| binding.binding_id else null, if (self.binding) |binding| binding.binding_generation else null, @tagName(self.diagnostics.phase), self.diagnostics.stopped_phase, self.diagnostics.request_started, self.diagnostics.request_accepted, self.diagnostics.eof_received, @tagName(self.status), self.exit_code, @tagName(self.effect), @tagName(self.cleanup), value.elapsed_ms, self.stdout_bytes, self.stderr_bytes, self.stdout.items.len + self.stderr.items.len, self.truncated, self.diagnostics.channel_open_error, self.diagnostics.request_error, self.diagnostics.read_error, self.diagnostics.close_error, self.diagnostics.wait_close_error, @tagName(self.diagnostics.release) });
        }
        fn deinit(self: *Command) void {
            const allocator = self.owner.allocator;
            if (self.wire_command.ptr != self.command.ptr) allocator.free(self.wire_command);
            allocator.free(self.command);
            if (self.cwd) |cwd| allocator.free(cwd);
            self.stdout.deinit(allocator);
            self.stderr.deinit(allocator);
        }
    };
};

fn commandAtCwd(allocator: std.mem.Allocator, cwd: []const u8, command: []const u8) ![:0]u8 {
    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(allocator);
    try text.appendSlice(allocator, "cd '");
    for (cwd) |byte| {
        if (byte == '\'') try text.appendSlice(allocator, "'\\''") else try text.append(allocator, byte);
    }
    try text.appendSlice(allocator, "' && ");
    try text.appendSlice(allocator, command);
    return allocator.dupeSentinel(u8, text.items, 0);
}
fn optionalTextEql(a: ?[]const u8, b: ?[]const u8) bool {
    if (a == null or b == null) return a == null and b == null;
    return std.mem.eql(u8, a.?, b.?);
}
fn nowMs() i64 {
    var ts: std.c.timespec = undefined;
    _ = std.c.clock_gettime(.MONOTONIC, &ts);
    return @as(i64, @intCast(ts.sec)) * 1000 + @divTrunc(@as(i64, @intCast(ts.nsec)), 1_000_000);
}
fn elapsed(started: i64) i64 {
    return nowMs() - started;
}

test "ssh exec bridge rejects empty command and freezes bounded capture before native IO" {
    var session: Session = .{ .state = .active };
    var sb = SshExecBridge.init(&session, std.testing.allocator);
    defer sb.deinitLocal();
    try std.testing.expectError(error.EmptyCommand, sb.exec("", .{}));
    try std.testing.expectError(error.InvalidCaptureLimit, sb.exec("printf ok", .{ .capture_cap = 0 }));
    const h = try sb.exec("printf ok", .{ .call_id = 1 });
    try std.testing.expect(SshExecBridge.pollHandle(h) == null);
    try std.testing.expectEqual(h.ptr, (try sb.exec("printf ok", .{ .call_id = 1 })).ptr);
    try std.testing.expectError(error.ConflictingCallId, sb.exec("printf other", .{ .call_id = 1 }));
    SshExecBridge.abortHandle(h);
    try sb.step();
    const result = SshExecBridge.pollHandle(h).?;
    try std.testing.expectEqual(bridge.Status.cancelled, result.status);
    try std.testing.expect(result.exit_code == null);
    try std.testing.expectEqual(operation.Effect.none, result.effect);
    try std.testing.expectEqual(operation.Cleanup.released, result.cleanup);
    try std.testing.expectEqual(bridge.Phase.finished, result.diagnostics.phase);
    try std.testing.expectEqual(@as(?bridge.Phase, .queued), result.diagnostics.stopped_phase);
    try std.testing.expectEqual(@as(?bool, false), result.diagnostics.request_started);
    try std.testing.expect(!result.diagnostics.request_accepted);
    try std.testing.expectEqual(ssh.ReleaseReceipt.released, try sb.closeCall(h));
    try std.testing.expectError(error.StaleCallId, sb.exec("printf ok", .{ .call_id = 1 }));
}

test "exec options preserve timeout capture and safe explicit cwd" {
    const opts: bridge.ExecOpts = .{};
    try std.testing.expectEqual(@as(u32, 30_000), opts.timeout_ms);
    try std.testing.expectEqual(@as(u32, 64 * 1024), opts.capture_cap);
    const text = try commandAtCwd(std.testing.allocator, "/tmp/a'b\n$(touch nope)", "printf ok");
    defer std.testing.allocator.free(text);
    try std.testing.expectEqualStrings("cd '/tmp/a'\\''b\n$(touch nope)' && printf ok", text);
}

test "OS diagnostic does not consume caller exec call IDs" {
    var session: Session = .{ .state = .active };
    var mailbox = SshExecBridge.init(&session, std.testing.allocator);
    defer mailbox.deinitLocal();
    _ = try mailbox.diagnostic(@import("remote_os.zig").command, .{ .capture_cap = 8192, .timeout_ms = 3000 });
    try std.testing.expectEqual(@as(u64, 1), mailbox.next_call_id);
    _ = try mailbox.exec("printf first-user-command", .{ .call_id = 1 });
    try std.testing.expectEqual(@as(u64, 2), mailbox.next_call_id);
}
