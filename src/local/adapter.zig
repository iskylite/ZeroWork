//! Non-UI Local plugin. A stable entry's worker owns its PTY and exec children.
//! drain() is controller-thread only and publishes through the existing host.
const std = @import("std");
const host = @import("../host/session_host.zig");
const operations = @import("../host/operation.zig");
const identity = @import("../host/identity.zig");
const plugins = @import("../host/plugin_registry.zig");
const terminal = @import("../host/terminal_service.zig");
const pty = @import("pty.zig");
const exec = @import("exec.zig");
const native = @import("native.zig");
const Queue = @import("../vt/input_queue.zig").InputQueue;
const TextSlot = @import("../vt/text_slot.zig").TextSlot;
const Vt = @import("../vt/ghostty_adapter.zig").Adapter;
const VtEngine = @import("../vt/engine.zig").VtEngine;
const Controller = @import("../vt/terminal_controller.zig").Controller;
const trusted_mod = @import("trusted_edit.zig");
const recording_mod = @import("recording.zig");
pub const ContextSnapshot = @import("context_snapshot.zig").Snapshot;
const Mutex = struct {
    state: std.atomic.Mutex = .unlocked,
    fn lock(self: *Mutex) void {
        while (!self.state.tryLock()) std.atomic.spinLoopHint();
    }
    fn tryLock(self: *Mutex) bool {
        return self.state.tryLock();
    }
    fn unlock(self: *Mutex) void {
        self.state.unlock();
    }
};

pub const Options = struct { term: []const u8 = "xterm-256color", cols: u16 = 80, rows: u16 = 24, output_capacity: usize = 1024 * 1024, recording: ?recording_mod.Options = null };
pub const ProcessSnapshot = @import("../host/process_service.zig").ProcessSnapshot;
pub const CwdSnapshot = @import("../host/process_service.zig").CwdSnapshot;
pub const ExecRisk = @import("../host/process_service.zig").ExecRisk;
pub const CloseRiskSnapshot = @import("../host/process_service.zig").CloseRiskSnapshot;
pub const ExecHandle = @import("../host/process_service.zig").ExecHandle;
pub const ExecRequest = @import("../host/process_service.zig").ExecRequest;
pub const ExecSnapshot = @import("../host/process_service.zig").ExecSnapshot;
const PendingWrite = struct { sequence: u64, mode: u64, bytes: []u8, consumed: usize = 0, failure: ?terminal.WriteFailure = null, submission: bool = false };
const ExecJob = struct {
    handle: ExecHandle,
    command_text: []u8,
    cwd: ?[]u8,
    limits: exec.Limits,
    command: ?exec.Command = null, // worker only
    pid: ?i32 = null,
    started: bool = false,
    cancel_requested: std.atomic.Value(bool) = .init(false),
    cancelled: bool = false,
    done: bool = false,
    published: bool = false,
    failure: ?operations.Failure = null,
    stdout: std.ArrayList(u8) = .empty,
    stderr: std.ArrayList(u8) = .empty,
    exit: ?native.Exit = null,
    timed_out: bool = false,
    truncated: bool = false,
    cleanup: host.CloseReceipt = .awaiting,
};
const Entry = struct {
    engine_spec_bound: bool = true,
    allocator: std.mem.Allocator,
    handle: identity.SessionHandle,
    key: operations.OperationKey,
    options: Options,
    cwd: ?[]u8,
    term: []u8,
    mutex: Mutex = .{},
    thread: ?std.Thread = null, // controller thread only
    wakeup: @import("../platform/wakeup.zig").Wakeup,
    worker_done: bool = false,
    close_requested: std.atomic.Value(bool) = .init(false),
    ready: bool = false,
    ready_published: bool = false,
    failure: ?operations.Failure = null,
    failure_published: bool = false,
    cleanup: host.CloseReceipt = .awaiting,
    cleanup_published: bool = false,
    close_key: ?operations.OperationKey = null,
    close_published: bool = false,
    binding: ?host.ServiceHandle = null,
    process_state: @FieldType(ProcessSnapshot, "state") = .starting,
    pid: ?i32 = null,
    exit: ?native.Exit = null,
    eof: bool = false,
    foreground: ?native.Foreground = null,
    foreground_valid: bool = false,
    metadata_observed_ms: u64 = 0,
    reported_cwd: [4096]u8 = undefined,
    reported_cwd_len: ?usize = null,
    cwd_source: @FieldType(CwdSnapshot, "source") = .unknown,
    output: Queue,
    output_sequence: u64 = 0,
    writes: std.ArrayList(PendingWrite) = .empty,
    receipts: std.ArrayList(terminal.WriteReceipt) = .empty,
    pending_bytes: usize = 0,
    last_input_sequence: u64 = 0,
    geometry: terminal.Geometry,
    transport_geometry_revision: u64 = 1,
    requested_geometry: ?terminal.Geometry = null,
    last_geometry_revision: u64 = 1,
    resize_error: ?[]const u8 = null,
    terminal_error: ?[]const u8 = null,
    snapshot_error: ?[]const u8 = null,
    projection: ?terminal.Projection = null,
    projection_output_sequence: u64 = 0,
    projection_geometry_revision: u64 = 1,
    requested_theme: ?terminal.Theme = null,
    last_theme: ?terminal.Theme = null,
    applied_theme_revision: u64 = 0,
    projection_theme_revision: u64 = 0,
    theme_error: ?[]const u8 = null,
    mode_revision: u64 = 1,
    modes: terminal.Modes = .{},
    reply_buffer: [64 * 1024]u8 = undefined,
    reply_len: usize = 0,
    reply_offset: usize = 0,
    jobs: std.ArrayList(*ExecJob) = .empty,
    last_exec_call_id: u64 = 0,
    text: TextSlot,
    vt: ?Vt = null,
    controller: ?Controller = null,
    process: ?pty.Session = null,
    recording: ?*recording_mod.Recording = null,
    recording_retention_days: std.atomic.Value(u16) = .init(14),
    recording_error: ?[]const u8 = null,
    trusted: ?trusted_mod.Bridge = null,
    trusted_error: ?[]const u8 = null,

    fn init(allocator: std.mem.Allocator, request: host.CreateRequest, options: Options) !*Entry {
        const self = try allocator.create(Entry);
        errdefer allocator.destroy(self);
        const cwd = if (request.spec.local.initial_cwd) |value| try allocator.dupe(u8, value) else null;
        errdefer if (cwd) |value| allocator.free(value);
        const term = try allocator.dupe(u8, options.term);
        errdefer allocator.free(term);
        var frozen_options = options;
        if (frozen_options.recording) |*recording| if (recording.directory) |directory| {
            recording.directory = try allocator.dupe(u8, directory);
        };
        errdefer if (frozen_options.recording) |recording| if (recording.directory) |directory| allocator.free(directory);
        var wakeup = try @import("../platform/wakeup.zig").Wakeup.init();
        errdefer wakeup.deinit();
        var output = try Queue.init(allocator, options.output_capacity);
        errdefer output.deinit(allocator);
        var text = try TextSlot.init(allocator, TextSlot.default_capacity);
        errdefer text.deinit(allocator);
        self.* = .{ .wakeup = wakeup, .allocator = allocator, .handle = request.handle, .key = request.key, .options = frozen_options, .recording_retention_days = .init(if (options.recording) |recording| recording.log.retention_days else 14), .cwd = cwd, .term = term, .output = output, .text = text, .geometry = .{ .revision = 1, .cols = options.cols, .rows = options.rows } };
        errdefer self.writes.deinit(allocator);
        try self.writes.ensureTotalCapacity(allocator, 64);
        try self.receipts.ensureTotalCapacity(allocator, 64);
        return self;
    }
    fn destroy(self: *Entry) void {
        for (self.writes.items) |write| self.allocator.free(write.bytes);
        self.writes.deinit(self.allocator);
        self.receipts.deinit(self.allocator);
        for (self.jobs.items) |job| {
            self.allocator.free(job.command_text);
            if (job.cwd) |cwd| self.allocator.free(cwd);
            job.stdout.deinit(self.allocator);
            job.stderr.deinit(self.allocator);
            self.allocator.destroy(job);
        }
        self.jobs.deinit(self.allocator);
        if (self.trusted) |*trusted| trusted.deinit();
        if (self.recording) |recording| recording.deinit();
        if (self.options.recording) |recording| if (recording.directory) |directory| self.allocator.free(directory);
        if (self.vt) |*vt| vt.destroy();
        if (self.projection) |*value| value.deinit(self.allocator);
        self.text.deinit(self.allocator);
        self.output.deinit(self.allocator);
        self.wakeup.deinit();
        if (self.cwd) |cwd| self.allocator.free(cwd);
        self.allocator.free(self.term);
        self.allocator.destroy(self);
    }
    fn receipt(self: *const Entry) host.CloseReceipt {
        return if (!self.worker_done or self.thread != null) .awaiting else self.cleanup;
    }
    fn completeWrite(self: *Entry, state: @FieldType(terminal.WriteReceipt, "state")) void {
        const write = self.writes.orderedRemove(0);
        self.pending_bytes -= write.bytes.len - write.consumed;
        self.receipts.appendAssumeCapacity(.{ .input_sequence = write.sequence, .mode_revision = write.mode, .consumed_bytes = write.consumed, .state = state, .failure = write.failure });
        self.allocator.free(write.bytes);
        @import("../platform/presentation_wakeup.zig").notify();
    }
    fn finish(self: *Entry, cleanup: host.CloseReceipt) void {
        if (self.trusted) |*bridge| bridge.deinit();
        self.trusted = null;
        self.cleanup = cleanup;
        if (cleanup == .unknown) self.process_state = .cleanup_unknown else if (self.close_requested.load(.acquire)) self.process_state = .closed;
        self.worker_done = true;
        @import("../platform/presentation_wakeup.zig").notify();
    }
};

/// Keep this allocation stable until shutdownStep() reports released. No scope,
/// widget or second operation journal is retained here.
pub const LocalAdapter = struct {
    allocator: std.mem.Allocator,
    options: Options,
    entries: std.ArrayList(*Entry) = .empty,
    session_host: ?*host.SessionHost = null,
    recording_config_revision: ?u64 = null,
    recording_retention_target: ?u16 = null,

    pub fn init(allocator: std.mem.Allocator, options: Options) !*LocalAdapter {
        if (options.cols == 0 or options.rows == 0 or options.output_capacity < 4096 or options.term.len == 0 or options.term.len > 128) return error.InvalidOptions;
        try native.validateString(options.term);
        const term = try allocator.dupe(u8, options.term);
        errdefer allocator.free(term);
        const self = try allocator.create(LocalAdapter);
        errdefer allocator.destroy(self);
        self.* = .{ .allocator = allocator, .options = options };
        self.options.term = term;
        self.options.recording = null;
        if (options.recording) |recording| try self.configureRecording(recording);
        return self;
    }
    /// Controller-thread configuration. Each new original generation captures
    /// ring/interval/storage; running recordings only receive retention policy.
    pub fn configureRecording(self: *LocalAdapter, options: recording_mod.Options) !void {
        if (options.log.ring_mb == 0 or options.log.checkpoint_sec == 0) return error.InvalidRecordingOptions;
        var owned = options;
        if (options.directory) |directory| owned.directory = try self.allocator.dupe(u8, directory);
        if (self.options.recording) |old| if (old.directory) |directory| self.allocator.free(directory);
        self.options.recording = owned;
        self.setRecordingRetention(options.log.retention_days);
    }
    /// Publish saved policy only. Drain retries busy/initializing recordings;
    /// ring, interval and storage stay frozen in the original Entry options.
    pub fn applyRecordingRetention(self: *LocalAdapter, revision: u64, retention_days: u16) void {
        if (self.recording_config_revision == revision) return;
        self.recording_config_revision = revision;
        self.setRecordingRetention(retention_days);
    }
    pub fn setRecordingRetention(self: *LocalAdapter, retention_days: u16) void {
        self.recording_retention_target = retention_days;
        for (self.entries.items) |entry| {
            entry.recording_retention_days.store(retention_days, .release);
            if (!entry.mutex.tryLock()) continue;
            if (entry.recording) |recording| recording.retention_days.store(retention_days, .release);
            entry.mutex.unlock();
        }
    }
    pub fn recordingSnapshot(self: *LocalAdapter, owner: identity.SessionHandle) !?recording_mod.Snapshot {
        const entry = self.find(owner) orelse return error.StaleSession;
        if (!entry.mutex.tryLock()) return error.WorkerBusy;
        defer entry.mutex.unlock();
        if (entry.recording) |recording| return recording.snapshot();
        if (entry.recording_error != null) return error.RecordingUnavailable;
        return null;
    }
    pub fn adapter(self: *LocalAdapter) host.Adapter {
        return .{ .registration = .{ .plugin_id = .local, .workspace_kind = .terminal, .services = plugins.requiredServices(.local) }, .context = self, .vtable = &.{ .create = create, .cancel = cancel, .close = close, .release_stale = releaseStale } };
    }
    pub fn deinit(self: *LocalAdapter) !void {
        for (self.entries.items) |entry| {
            if (!entry.mutex.tryLock()) return error.CleanupIncomplete;
            const released = entry.receipt() == .released;
            entry.mutex.unlock();
            if (!released) return error.CleanupIncomplete;
        }
        for (self.entries.items) |entry| entry.destroy();
        self.entries.deinit(self.allocator);
        if (self.options.recording) |recording| if (recording.directory) |directory| self.allocator.free(directory);
        self.allocator.free(self.options.term);
        self.allocator.destroy(self);
    }
    /// The presentation owner first detaches all readers. Active/read-only
    /// panes cannot be retired merely because their child has exited.
    pub fn retire(self: *LocalAdapter, handle: identity.SessionHandle) !void {
        const entry = self.find(handle) orelse return error.StaleSession;
        if (self.session_host) |session_host| if (session_host.queryState(handle)) |state| if (state.lifecycle != .closed) return error.SessionStillPresented;
        if (!entry.mutex.tryLock()) return error.WorkerBusy;
        const released = entry.receipt() == .released;
        entry.mutex.unlock();
        if (!released) return error.CleanupIncomplete;
        for (self.entries.items, 0..) |candidate, index| if (candidate == entry) {
            _ = self.entries.orderedRemove(index);
            break;
        };
        entry.destroy();
    }
    pub fn shutdownStep(self: *LocalAdapter) host.CloseReceipt {
        var result: host.CloseReceipt = .released;
        for (self.entries.items) |entry| {
            entry.close_requested.store(true, .release);
            entry.wakeup.notify();
            if (!entry.mutex.tryLock()) {
                if (result != .unknown) result = .awaiting;
                continue;
            }
            const done = entry.worker_done;
            entry.mutex.unlock();
            if (done) if (entry.thread) |thread| {
                thread.join();
                entry.thread = null;
            };
            const receipt = if (done) entry.receipt() else .awaiting;
            if (receipt == .unknown) result = .unknown else if (receipt == .awaiting and result != .unknown) result = .awaiting;
        }
        return result;
    }
    fn find(self: *LocalAdapter, handle: identity.SessionHandle) ?*Entry {
        for (self.entries.items) |entry| if (entry.handle.eql(handle)) return entry;
        return null;
    }
    fn create(raw: *anyopaque, request: host.CreateRequest) !void {
        const self: *LocalAdapter = @ptrCast(@alignCast(raw));
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        var adapted = request;
        if (request.spec == .plugin) {
            const value = try @import("../plugins/local/config.zig").decode(arena.allocator(), request.spec.plugin.payload);
            adapted.spec = .{ .local = .{ .initial_cwd = value.initial_cwd } };
        } else if (request.spec != .local) return error.WrongPlugin;
        if (self.find(request.handle) != null) return error.DuplicateSession;
        try self.entries.ensureUnusedCapacity(self.allocator, 1);
        const entry = try Entry.init(self.allocator, adapted, self.options);
        entry.engine_spec_bound = request.spec != .plugin;
        errdefer entry.destroy();
        entry.thread = try std.Thread.spawn(.{}, run, .{entry});
        self.entries.appendAssumeCapacity(entry);
    }
    fn cancel(raw: *anyopaque, key: operations.OperationKey) host.CloseReceipt {
        const self: *LocalAdapter = @ptrCast(@alignCast(raw));
        if (key.owner != .session) return .unknown;
        const entry = self.find(key.owner.session) orelse return .unknown;
        if (!entry.key.eql(key)) return .unknown;
        entry.close_requested.store(true, .release);
        entry.wakeup.notify();
        if (!entry.mutex.tryLock()) return .awaiting;
        defer entry.mutex.unlock();
        return entry.receipt();
    }
    fn close(raw: *anyopaque, handle: identity.SessionHandle, key: operations.OperationKey) !host.CloseReceipt {
        const self: *LocalAdapter = @ptrCast(@alignCast(raw));
        const entry = self.find(handle) orelse return .unknown;
        if (entry.close_key) |original| if (!original.eql(key)) return error.StaleClose;
        defer entry.wakeup.notify();
        entry.close_key = key;
        entry.close_requested.store(true, .release);
        if (!entry.mutex.tryLock()) return .awaiting;
        defer entry.mutex.unlock();
        return entry.receipt();
    }
    fn releaseStale(raw: *anyopaque, handle: identity.SessionHandle, key: operations.OperationKey) void {
        const self: *LocalAdapter = @ptrCast(@alignCast(raw));
        const entry = self.find(handle) orelse return;
        if (entry.key.eql(key)) {
            entry.close_requested.store(true, .release);
            entry.wakeup.notify();
        }
    }
    /// Events stay pending on allocation failure; the same host key is retried.
    pub fn drain(self: *LocalAdapter, session_host: *host.SessionHost) !bool {
        self.session_host = session_host;
        var pending = false;
        for (self.entries.items) |entry| {
            if (!entry.engine_spec_bound) {
                // The controller-thread drain runs after the factory returns,
                // before publishing ready or exposing any process service.
                if (session_host.queryState(entry.handle)) |state| if (state.lifecycle == .creating and state.create_operation.eql(entry.key)) {
                    try session_host.bindEngineSpec(entry.handle, entry.key, .{ .local = .{ .initial_cwd = entry.cwd } });
                };
                entry.engine_spec_bound = true;
            }
            if (!entry.mutex.tryLock()) {
                pending = true;
                continue;
            }
            if (self.recording_retention_target) |days| {
                entry.recording_retention_days.store(days, .release);
                if (entry.recording) |recording| recording.retention_days.store(days, .release);
            }
            const done = entry.worker_done;
            const ready = entry.ready;
            const failure = entry.failure;
            entry.mutex.unlock();
            if (done) if (entry.thread) |thread| {
                thread.join();
                entry.thread = null;
            };
            if (done) if (entry.controller) |*controller| {
                // Once joined, projection ownership transfers to this thread
                // so a backpressured EOF frame can still reach its consumer.
                applyTheme(entry);
                refreshProjection(entry);
                controller.retryPublication(nowMs());
                if (controller.publicationPending() or entry.requested_theme != null) pending = true;
            };
            if (failure) |value| if (!entry.failure_published) {
                _ = try session_host.failed(entry.handle, entry.key, value);
                entry.failure_published = true;
            };
            if (ready and !entry.ready_published) {
                _ = try session_host.ready(entry.handle, entry.key, plugins.requiredServices(.local));
                if (session_host.queryService(entry.handle, .terminal) == .available) entry.binding = session_host.queryService(entry.handle, .terminal).available;
                entry.ready_published = true;
            }
            if (!entry.mutex.tryLock()) {
                pending = true;
                continue;
            }
            const cleanup = entry.receipt();
            const close_key = entry.close_key;
            entry.mutex.unlock();
            if (cleanup != .awaiting and !entry.cleanup_published) {
                _ = try session_host.createCleanupReceipt(entry.handle, entry.key, cleanup);
                entry.cleanup_published = true;
            }
            if (cleanup != .awaiting and close_key != null and !entry.close_published) {
                _ = try session_host.closeReceipt(entry.handle, close_key.?, .close_protocol, cleanup);
                entry.close_published = true;
            }
            for (entry.jobs.items) |job| {
                if (!entry.mutex.tryLock()) {
                    pending = true;
                    break;
                }
                const job_done = job.done;
                const job_failure = job.failure;
                const cancelled = job.cancelled;
                const job_cleanup = job.cleanup;
                entry.mutex.unlock();
                if (!job_done or job.published) continue;
                if (job_failure) |value| {
                    if (value.cleanup == .released) _ = try session_host.journal.failReleased(job.handle.operation, value) else _ = try session_host.journal.publish(job.handle.operation, .failed, "", value);
                } else if (cancelled) {
                    _ = try session_host.journal.publish(job.handle.operation, .cancelled, "local exec cancelled", null);
                    _ = try session_host.journal.publish(job.handle.operation, if (job_cleanup == .released) .cleanup_released else .cleanup_unknown, "", null);
                } else if (job_cleanup == .released) _ = try session_host.journal.completeReleased(job.handle.operation, "local exec completed") else _ = try session_host.journal.publish(job.handle.operation, .cleanup_unknown, "local exec ownership unknown", null);
                job.published = true;
            }
            if (!done and (!ready or entry.close_requested.load(.acquire))) pending = true;
        }
        return pending;
    }
    fn resolve(self: *LocalAdapter, binding: host.ServiceHandle, kind: plugins.ServiceKind, writable: bool) !*Entry {
        if (binding.kind != kind or binding.resource_owner != .session) return error.WrongService;
        const session_host = self.session_host orelse return error.HostNotBound;
        const entry = self.find(binding.resource_owner.session) orelse return error.StaleSession;
        if (writable and !session_host.bindingIsLive(binding)) return error.ServiceUnavailable;
        if (kind == .terminal and (entry.binding == null or !entry.binding.?.eql(binding))) return error.StaleBinding;
        return entry;
    }
    pub fn terminalService(self: *LocalAdapter, binding: host.ServiceHandle) !terminal.Service {
        _ = try self.resolve(binding, .terminal, true);
        return .{ .binding = binding, .context = self, .vtable = &service_vtable };
    }
    pub fn processSnapshot(self: *LocalAdapter, handle: identity.SessionHandle) !ProcessSnapshot {
        const entry = self.find(handle) orelse return error.StaleSession;
        if (!entry.mutex.tryLock()) return error.WorkerBusy;
        defer entry.mutex.unlock();
        return .{ .owner = handle, .state = entry.process_state, .pid = entry.pid, .exit = entry.exit, .eof_seen = entry.eof, .cleanup = entry.receipt(), .foreground = entry.foreground };
    }
    pub fn copyCwd(self: *LocalAdapter, handle: identity.SessionHandle, allocator: std.mem.Allocator) !?[]u8 {
        const entry = self.find(handle) orelse return error.StaleSession;
        if (!entry.mutex.tryLock()) return error.WorkerBusy;
        defer entry.mutex.unlock();
        return if (entry.reported_cwd_len) |len| try allocator.dupe(u8, entry.reported_cwd[0..len]) else null;
    }
    pub fn cwdSnapshot(self: *LocalAdapter, handle: identity.SessionHandle, allocator: std.mem.Allocator) !CwdSnapshot {
        const entry = self.find(handle) orelse return error.StaleSession;
        if (!entry.mutex.tryLock()) return error.WorkerBusy;
        defer entry.mutex.unlock();
        return .{ .owner = handle, .value = if (entry.reported_cwd_len) |len| try allocator.dupe(u8, entry.reported_cwd[0..len]) else null, .source = entry.cwd_source };
    }
    pub fn contextSnapshot(self: *LocalAdapter, binding: host.ServiceHandle, limits: terminal.LineLimits, allocator: std.mem.Allocator) !ContextSnapshot {
        const entry = try self.resolve(binding, .terminal, false);
        if (!entry.mutex.tryLock()) return error.WorkerBusy;
        defer entry.mutex.unlock();
        var lines = try entry.controller.?.readLines(entry.handle, limits, allocator);
        errdefer lines.deinit(allocator);
        const cwd = if (entry.reported_cwd_len) |len| try allocator.dupe(u8, entry.reported_cwd[0..len]) else null;
        errdefer if (cwd) |value| allocator.free(value);
        const user = try std.fmt.allocPrint(allocator, "uid:{d}", .{std.c.getuid()});
        return .{ .allocator = allocator, .owner = entry.handle, .source_revision = entry.vt.?.snapshot().version, .lines = lines, .cwd_owned = cwd, .uid_label = user };
    }
    /// Bounded, read-only impact capture. Pending exec jobs count even before
    /// fork, and an unverified foreground/ownership is explicitly unknown.
    pub fn closeRiskSnapshot(self: *LocalAdapter, handle: identity.SessionHandle, allocator: std.mem.Allocator) !CloseRiskSnapshot {
        const entry = self.find(handle) orelse return error.StaleSession;
        if (!entry.mutex.tryLock()) return error.WorkerBusy;
        defer entry.mutex.unlock();
        var jobs: std.ArrayList(ExecRisk) = .empty;
        errdefer {
            for (jobs.items) |job| allocator.free(job.command);
            jobs.deinit(allocator);
        }
        var unknown = entry.cleanup == .unknown;
        for (entry.jobs.items) |job| {
            if (job.done and job.cleanup == .released) continue;
            var command_len = @min(job.command_text.len, 4096);
            while (command_len > 0 and !std.unicode.utf8ValidateSlice(job.command_text[0..command_len])) command_len -= 1;
            const text = try allocator.dupe(u8, job.command_text[0..command_len]);
            errdefer allocator.free(text);
            try jobs.append(allocator, .{ .handle = job.handle, .command = text, .command_truncated = command_len < job.command_text.len, .pid = job.pid, .state = if (job.done and job.cleanup != .released) .cleanup_unknown else if (job.started) .running else .pending });
            if (job.done and job.cleanup != .released) unknown = true;
        }
        const not_running = entry.process_state == .exited or entry.process_state == .closed or entry.process_state == .failed;
        const fresh = entry.foreground_valid and native.zw_local_monotonic_ms() -| entry.metadata_observed_ms <= 300;
        const foreground_state: @FieldType(CloseRiskSnapshot, "foreground_state") = if (not_running) .not_running else if (!fresh or entry.pid == null or entry.foreground == null) .unknown else if (entry.foreground.?.pid == entry.pid.? and entry.foreground.?.process_group == entry.pid.?) .idle_shell else .task;
        if (foreground_state == .unknown) unknown = true;
        return .{ .owner = handle, .process_state = entry.process_state, .shell_pid = entry.pid, .foreground = if (fresh) entry.foreground else null, .foreground_state = foreground_state, .observed_monotonic_ms = entry.metadata_observed_ms, .active_exec = try jobs.toOwnedSlice(allocator), .unknown = unknown };
    }
    pub fn startExec(self: *LocalAdapter, binding: host.ServiceHandle, request: ExecRequest) !ExecHandle {
        const entry = try self.resolve(binding, .exec, true);
        try native.validateOwner(entry.handle, request.operation);
        if (request.call_id == 0 or request.command.len == 0 or request.command.len > 1024 * 1024 or request.limits.capture_bytes == 0 or request.limits.capture_bytes > 16 * 1024 * 1024) return error.InvalidExec;
        try native.validateString(request.command);
        if (request.cwd) |cwd| {
            if (cwd.len == 0 or cwd[0] != '/') return error.InvalidDirectory;
            try native.validateString(cwd);
        }
        if (!entry.mutex.tryLock()) return error.WorkerBusy;
        defer entry.mutex.unlock();
        if (entry.close_requested.load(.acquire) or entry.process_state != .running) return error.SessionNotWritable;
        for (entry.jobs.items) |job| if (job.handle.call_id == request.call_id) {
            if (!job.handle.operation.eql(request.operation) or !std.mem.eql(u8, job.command_text, request.command) or !sameCwd(job.cwd, request.cwd) or !std.meta.eql(job.limits, request.limits)) return error.DuplicateCall;
            return job.handle;
        };
        if (request.call_id <= entry.last_exec_call_id) return error.StaleExecCall;
        if (self.session_host.?.journal.isTerminal(request.operation)) return error.OperationEnded;
        if (entry.jobs.items.len >= 16) return error.ExecCapacity;
        const job = try self.allocator.create(ExecJob);
        errdefer self.allocator.destroy(job);
        const command_text = try self.allocator.dupe(u8, request.command);
        errdefer self.allocator.free(command_text);
        const cwd = if (request.cwd) |value| try self.allocator.dupe(u8, value) else null;
        errdefer if (cwd) |value| self.allocator.free(value);
        job.* = .{ .handle = .{ .owner = entry.handle, .operation = request.operation, .call_id = request.call_id }, .command_text = command_text, .cwd = cwd, .limits = request.limits };
        errdefer job.stdout.deinit(self.allocator);
        errdefer job.stderr.deinit(self.allocator);
        try job.stdout.ensureTotalCapacity(self.allocator, request.limits.capture_bytes);
        try job.stderr.ensureTotalCapacity(self.allocator, request.limits.capture_bytes);
        try entry.jobs.append(self.allocator, job);
        entry.last_exec_call_id = request.call_id;
        entry.wakeup.notify();
        return job.handle;
    }
    fn findExec(self: *LocalAdapter, handle: ExecHandle) !struct { entry: *Entry, job: *ExecJob } {
        const entry = self.find(handle.owner) orelse return error.StaleSession;
        for (entry.jobs.items) |job| if (job.handle.call_id == handle.call_id and job.handle.operation.eql(handle.operation)) return .{ .entry = entry, .job = job };
        return error.StaleExec;
    }
    pub fn cancelExec(self: *LocalAdapter, handle: ExecHandle) !void {
        const found = try self.findExec(handle);
        found.job.cancel_requested.store(true, .release);
        found.entry.wakeup.notify();
    }
    /// Call IDs remain consumed after their bounded output buffers retire.
    pub fn retireExec(self: *LocalAdapter, handle: ExecHandle) !void {
        const found = try self.findExec(handle);
        if (!found.entry.mutex.tryLock()) return error.WorkerBusy;
        defer found.entry.mutex.unlock();
        const job = found.job;
        if (!job.done or job.cleanup != .released or !job.published) return error.CleanupIncomplete;
        for (found.entry.jobs.items, 0..) |candidate, index| if (candidate == job) {
            _ = found.entry.jobs.orderedRemove(index);
            break;
        };
        self.allocator.free(job.command_text);
        if (job.cwd) |cwd| self.allocator.free(cwd);
        job.stdout.deinit(self.allocator);
        job.stderr.deinit(self.allocator);
        self.allocator.destroy(job);
    }
    pub fn execSnapshot(self: *LocalAdapter, handle: ExecHandle, allocator: std.mem.Allocator) !ExecSnapshot {
        const found = try self.findExec(handle);
        if (!found.entry.mutex.tryLock()) return error.WorkerBusy;
        defer found.entry.mutex.unlock();
        const job = found.job;
        const stdout = try allocator.dupe(u8, job.stdout.items);
        errdefer allocator.free(stdout);
        return .{ .handle = handle, .stdout = stdout, .stderr = try allocator.dupe(u8, job.stderr.items), .exit = job.exit, .cancelled = job.cancelled, .timed_out = job.timed_out, .truncated = job.truncated, .cleanup = job.cleanup, .done = job.done };
    }

    const service_vtable: terminal.Service.VTable = .{ .write = serviceWrite, .resize = serviceResize, .read = serviceRead, .receipt = serviceReceipt, .status = serviceStatus, .text_slot = serviceText, .snapshot = serviceSnapshot, .prepare_paste = preparePaste, .commit_paste = commitPaste, .key = serviceKey, .mouse = serviceMouse, .create_anchor = serviceCreateAnchor, .resolve_anchor = serviceResolveAnchor, .release_anchor = serviceReleaseAnchor, .selection_text = serviceSelectionText, .scroll = serviceScroll, .read_lines = serviceReadLines, .theme = serviceSetTheme, .search_snapshot = serviceSearchSnapshot, .export_recording = serviceExportRecording, .trusted_snapshot = serviceTrustedSnapshot, .trusted_request = serviceTrustedRequest, .trusted_outcome = serviceTrustedOutcome, .trusted_cancel = serviceTrustedCancel };
    fn serviceTrustedSnapshot(raw: *anyopaque, binding: host.ServiceHandle, allocator: std.mem.Allocator) !?terminal.trusted_edit.Snapshot {
        const self: *LocalAdapter = @ptrCast(@alignCast(raw));
        const entry = try self.resolve(binding, .terminal, true);
        if (!entry.mutex.tryLock()) return error.WorkerBusy;
        defer entry.mutex.unlock();
        const bridge = if (entry.trusted) |*value| value else return null;
        if (!bridge.hello or bridge.disabled or bridge.pending != null or bridge.input_dirty or entry.writes.items.len != 0 or entry.close_requested.load(.acquire)) return null;
        return if (bridge.snapshot) |value| try value.clone(allocator) else null;
    }
    fn serviceTrustedRequest(raw: *anyopaque, binding: host.ServiceHandle, request: terminal.trusted_edit.Request) !void {
        const self: *LocalAdapter = @ptrCast(@alignCast(raw));
        const entry = try self.resolve(binding, .terminal, true);
        if (!entry.mutex.tryLock()) return error.WorkerBusy;
        defer entry.mutex.unlock();
        if (entry.close_requested.load(.acquire) or entry.process_state != .running or entry.eof) return error.SessionNotWritable;
        if (entry.writes.items.len != 0 or entry.reply_offset != entry.reply_len) return error.WorkerBusy;
        const bridge = if (entry.trusted) |*value| value else return error.TrustedEditUnavailable;
        if (bridge.input_dirty) return error.StaleEdit;
        try bridge.request(request, nowMs());
        entry.wakeup.notify();
    }
    fn serviceTrustedOutcome(raw: *anyopaque, binding: host.ServiceHandle) !?terminal.trusted_edit.Outcome {
        const self: *LocalAdapter = @ptrCast(@alignCast(raw));
        const entry = try self.resolve(binding, .terminal, true);
        if (!entry.mutex.tryLock()) return error.WorkerBusy;
        defer entry.mutex.unlock();
        const bridge = if (entry.trusted) |*value| value else return null;
        const value = bridge.outcome;
        bridge.outcome = null;
        return value;
    }
    fn serviceTrustedCancel(raw: *anyopaque, binding: host.ServiceHandle) !void {
        const self: *LocalAdapter = @ptrCast(@alignCast(raw));
        const entry = try self.resolve(binding, .terminal, true);
        if (!entry.mutex.tryLock()) return error.WorkerBusy;
        defer entry.mutex.unlock();
        if (entry.trusted) |*bridge| bridge.revoke(.integration_lost);
    }
    fn serviceExportRecording(raw: *anyopaque, binding: host.ServiceHandle, kind: terminal.RecordingKind, io: std.Io, dir: std.Io.Dir, path: []const u8) !void {
        const self: *LocalAdapter = @ptrCast(@alignCast(raw));
        const entry = try self.resolve(binding, .terminal, false);
        if (!entry.mutex.tryLock()) return error.WorkerBusy;
        const recording = entry.recording orelse {
            entry.mutex.unlock();
            return error.RecordingUnavailable;
        };
        entry.mutex.unlock();
        try recording.exportTo(entry.handle, @fromBackingInt(@intCast(@backingInt(kind))), io, dir, path);
    }
    fn serviceSetTheme(raw: *anyopaque, binding: host.ServiceHandle, theme: terminal.Theme) !void {
        const self: *LocalAdapter = @ptrCast(@alignCast(raw));
        const entry = try self.resolve(binding, .terminal, false);
        if (theme.revision == 0) return error.InvalidTheme;
        if (!entry.mutex.tryLock()) return error.WorkerBusy;
        defer entry.mutex.unlock();
        if (entry.last_theme) |previous| {
            if (theme.revision < previous.revision) return error.StaleTheme;
            if (theme.revision == previous.revision) {
                if (!std.meta.eql(theme, previous)) return error.ConflictingTheme;
                return;
            }
        }
        entry.last_theme = theme;
        entry.requested_theme = theme;
        entry.wakeup.notify();
        entry.theme_error = null;
    }
    fn serviceWrite(raw: *anyopaque, binding: host.ServiceHandle, request: terminal.WriteRequest) !terminal.Submission {
        const self: *LocalAdapter = @ptrCast(@alignCast(raw));
        const entry = try self.resolve(binding, .terminal, true);
        if (!entry.mutex.tryLock()) return error.WorkerBusy;
        defer entry.mutex.unlock();
        if (entry.close_requested.load(.acquire) or entry.process_state != .running or entry.eof) return error.SessionNotWritable;
        if (entry.terminal_error != null) return error.TerminalUnavailable;
        if (entry.trusted) |*bridge| {
            if (bridge.pending != null or bridge.outcome != null) return error.TrustedEditPending;
        }
        if (request.mode_revision != entry.mode_revision) return error.StaleMode;
        if (request.input_sequence <= entry.last_input_sequence) return error.StaleInput;
        if (entry.pending_bytes >= 64 * 1024 or request.bytes.len > 64 * 1024 - entry.pending_bytes or entry.writes.items.len + entry.receipts.items.len >= 64) return error.InputFull;
        const bytes = try self.allocator.dupe(u8, request.bytes);
        entry.writes.appendAssumeCapacity(.{ .sequence = request.input_sequence, .mode = request.mode_revision, .bytes = bytes, .submission = request.submission });
        entry.pending_bytes += bytes.len;
        entry.wakeup.notify();
        if (bytes.len != 0) if (entry.trusted) |*bridge| bridge.markInput();
        entry.last_input_sequence = request.input_sequence;
        return .{ .input_sequence = request.input_sequence, .queued_bytes = bytes.len };
    }
    fn serviceResize(raw: *anyopaque, binding: host.ServiceHandle, geometry: terminal.Geometry) !void {
        const self: *LocalAdapter = @ptrCast(@alignCast(raw));
        const entry = try self.resolve(binding, .terminal, true);
        if (!entry.mutex.tryLock()) return error.WorkerBusy;
        defer entry.mutex.unlock();
        if (entry.close_requested.load(.acquire) or entry.process_state != .running) return error.SessionNotWritable;
        if (geometry.revision <= entry.last_geometry_revision) return error.StaleGeometry;
        entry.resize_error = null;
        entry.requested_geometry = geometry;
        entry.wakeup.notify();
        entry.last_geometry_revision = geometry.revision;
    }
    fn serviceRead(raw: *anyopaque, binding: host.ServiceHandle, buffer: []u8) !terminal.Read {
        const self: *LocalAdapter = @ptrCast(@alignCast(raw));
        const entry = try self.resolve(binding, .terminal, false);
        return readEntryOutput(entry, buffer);
    }
    /// Controller-thread raw-output drain, including attempts cancelled before
    /// they acquire a service binding. Does not read the worker-owned PTY.
    pub fn readOutput(self: *LocalAdapter, owner: identity.SessionHandle, buffer: []u8) !terminal.Read {
        const entry = self.find(owner) orelse return error.StaleSession;
        return readEntryOutput(entry, buffer);
    }
    fn readEntryOutput(entry: *Entry, buffer: []u8) !terminal.Read {
        if (buffer.len == 0) return error.InvalidBuffer;
        if (!entry.mutex.tryLock()) return .would_block;
        defer entry.mutex.unlock();
        const bytes = entry.output.peek(buffer);
        if (bytes.len > 0) {
            const was_full = entry.output.freeCapacity() == 0;
            try entry.output.consume(bytes.len);
            if (was_full) entry.wakeup.notify();
            return .{ .bytes = bytes.len };
        }
        return if (entry.eof) .eof else .would_block;
    }
    fn serviceReceipt(raw: *anyopaque, binding: host.ServiceHandle) !?terminal.WriteReceipt {
        const self: *LocalAdapter = @ptrCast(@alignCast(raw));
        const entry = try self.resolve(binding, .terminal, false);
        if (!entry.mutex.tryLock()) return null;
        defer entry.mutex.unlock();
        return if (entry.receipts.items.len > 0) entry.receipts.orderedRemove(0) else null;
    }
    fn serviceStatus(raw: *anyopaque, binding: host.ServiceHandle) !terminal.Status {
        const self: *LocalAdapter = @ptrCast(@alignCast(raw));
        const entry = try self.resolve(binding, .terminal, false);
        const session_host = self.session_host.?;
        if (!entry.mutex.tryLock()) return error.WorkerBusy;
        defer entry.mutex.unlock();
        return .{ .owner = entry.handle, .writable = session_host.bindingIsLive(binding) and !entry.close_requested.load(.acquire) and entry.process_state == .running and !entry.eof and entry.terminal_error == null, .eof_seen = entry.eof, .geometry = entry.geometry, .output_sequence = entry.output_sequence, .bell_count = if (entry.controller) |*controller| controller.status().bell_count else 0, .pending_input_bytes = entry.pending_bytes, .resize_error = entry.resize_error, .terminal_error = entry.terminal_error, .snapshot_error = entry.snapshot_error, .recording_error = if (entry.recording) |recording| recording.snapshot().failure else entry.recording_error, .theme_error = entry.theme_error, .applied_theme_revision = entry.applied_theme_revision, .mode_revision = entry.mode_revision, .modes = entry.modes };
    }
    fn serviceText(raw: *anyopaque, binding: host.ServiceHandle) !*TextSlot {
        const self: *LocalAdapter = @ptrCast(@alignCast(raw));
        return &(try self.resolve(binding, .terminal, false)).text;
    }
    fn serviceSnapshot(raw: *anyopaque, binding: host.ServiceHandle, allocator: std.mem.Allocator) !terminal.TerminalSnapshot {
        const self: *LocalAdapter = @ptrCast(@alignCast(raw));
        const entry = try self.resolve(binding, .terminal, false);
        if (!entry.mutex.tryLock()) return error.WorkerBusy;
        defer entry.mutex.unlock();
        const value = entry.projection orelse return error.SnapshotUnavailable;
        return .{ .owner = entry.handle, .output_sequence = entry.projection_output_sequence, .geometry_revision = entry.projection_geometry_revision, .input_revision = entry.last_input_sequence, .read_only = !self.session_host.?.bindingIsLive(binding) or entry.close_requested.load(.acquire) or entry.process_state != .running or entry.eof or entry.terminal_error != null, .eof_seen = entry.eof, .projection = try value.clone(allocator), .applied_theme_revision = entry.projection_theme_revision };
    }
    fn preparePaste(raw: *anyopaque, binding: host.ServiceHandle, allocator: std.mem.Allocator, text: []const u8) !terminal.Paste {
        const self: *LocalAdapter = @ptrCast(@alignCast(raw));
        const entry = try self.resolve(binding, .terminal, true);
        const decision = (terminal.PastePolicy{}).inspect(text);
        if (decision == .reject) return error.InvalidPaste;
        if (text.len == 0) return error.InvalidPaste;
        if (!entry.mutex.tryLock()) return error.WorkerBusy;
        defer entry.mutex.unlock();
        if (entry.close_requested.load(.acquire) or entry.process_state != .running or entry.eof) return error.SessionNotWritable;
        return .{ .binding = binding, .input_revision = entry.last_input_sequence, .mode_revision = entry.mode_revision, .text = try allocator.dupe(u8, text), .requires_confirmation = decision == .confirm };
    }
    fn commitPaste(raw: *anyopaque, binding: host.ServiceHandle, paste: terminal.Paste, sequence: u64, confirmed: bool) !terminal.Submission {
        const self: *LocalAdapter = @ptrCast(@alignCast(raw));
        const entry = try self.resolve(binding, .terminal, true);
        if (!paste.binding.eql(binding)) return error.StaleBinding;
        const decision = (terminal.PastePolicy{}).inspect(paste.text);
        if (decision == .reject or paste.text.len == 0 or sequence == 0) return error.InvalidPaste;
        if (decision == .confirm and !confirmed) return error.ConfirmationRequired;
        if (!entry.mutex.tryLock()) return error.WorkerBusy;
        defer entry.mutex.unlock();
        if (entry.close_requested.load(.acquire) or entry.process_state != .running or entry.eof) return error.SessionNotWritable;
        if (entry.terminal_error != null) return error.TerminalUnavailable;
        if (paste.mode_revision != entry.mode_revision) return error.StaleMode;
        if (paste.input_revision != entry.last_input_sequence or sequence <= entry.last_input_sequence) return error.StaleInput;
        const wrapped = entry.modes.bracketed_paste;
        const count = paste.text.len + @as(usize, if (wrapped) 12 else 0);
        if (count > 1024 * 1024 + 12 - entry.pending_bytes or entry.writes.items.len + entry.receipts.items.len >= 64) return error.InputFull;
        const bytes = try self.allocator.alloc(u8, count);
        if (wrapped) {
            @memcpy(bytes[0..6], "\x1b[200~");
            @memcpy(bytes[6..][0..paste.text.len], paste.text);
            @memcpy(bytes[6 + paste.text.len ..], "\x1b[201~");
        } else @memcpy(bytes, paste.text);
        entry.writes.appendAssumeCapacity(.{ .sequence = sequence, .mode = paste.mode_revision, .bytes = bytes });
        entry.pending_bytes += count;
        entry.wakeup.notify();
        entry.last_input_sequence = sequence;
        return .{ .input_sequence = sequence, .queued_bytes = count };
    }
    fn serviceKey(raw: *anyopaque, binding: host.ServiceHandle, request: terminal.KeyRequest) !terminal.Submission {
        const self: *LocalAdapter = @ptrCast(@alignCast(raw));
        const entry = try self.resolve(binding, .terminal, true);
        if (!entry.mutex.tryLock()) return error.WorkerBusy;
        defer entry.mutex.unlock();
        try inputGate(entry, request.input_sequence, request.mode_revision);
        if (request.event.composing) return error.CompositionInProgress;
        if (entry.modes.keyboard_disabled) return error.KeyboardDisabled;
        const bytes = try entry.controller.?.encodeKey(entry.handle, request.mode_revision, request.event, self.allocator);
        errdefer self.allocator.free(bytes);
        return queueEncoded(entry, request.input_sequence, request.mode_revision, bytes, request.event.key == .enter and request.event.action != .release);
    }
    fn serviceMouse(raw: *anyopaque, binding: host.ServiceHandle, request: terminal.MouseRequest) !terminal.Submission {
        const self: *LocalAdapter = @ptrCast(@alignCast(raw));
        const entry = try self.resolve(binding, .terminal, true);
        if (!entry.mutex.tryLock()) return error.WorkerBusy;
        defer entry.mutex.unlock();
        try inputGate(entry, request.input_sequence, request.mode_revision);
        if (request.event.button == .right or request.event.button == .middle or request.event.modifiers.alt) return error.ReservedApplicationGesture;
        const bytes = try entry.controller.?.encodeMouse(entry.handle, request.mode_revision, request.geometry_revision, request.event, self.allocator);
        errdefer self.allocator.free(bytes);
        return queueEncoded(entry, request.input_sequence, request.mode_revision, bytes, false);
    }
    fn inputGate(entry: *Entry, sequence: u64, mode_revision: u64) !void {
        if (sequence == 0 or mode_revision == 0) return error.InvalidInput;
        if (entry.close_requested.load(.acquire) or entry.process_state != .running or entry.eof) return error.SessionNotWritable;
        if (entry.terminal_error != null) return error.TerminalUnavailable;
        if (mode_revision != entry.mode_revision) return error.StaleMode;
        if (sequence <= entry.last_input_sequence) return error.StaleInput;
    }
    fn queueEncoded(entry: *Entry, sequence: u64, mode_revision: u64, bytes: []u8, submission: bool) !terminal.Submission {
        if (entry.trusted) |*bridge| {
            if (bridge.pending != null or bridge.outcome != null) return error.TrustedEditPending;
        }
        if (entry.pending_bytes >= 64 * 1024 or bytes.len > 64 * 1024 - entry.pending_bytes or entry.writes.items.len + entry.receipts.items.len >= 64) return error.InputFull;
        if (bytes.len == 0) {
            entry.receipts.appendAssumeCapacity(.{ .input_sequence = sequence, .mode_revision = mode_revision, .consumed_bytes = 0, .state = .completed });
            entry.allocator.free(bytes);
        } else {
            entry.writes.appendAssumeCapacity(.{ .sequence = sequence, .mode = mode_revision, .bytes = bytes, .submission = submission });
            entry.pending_bytes += bytes.len;
            entry.wakeup.notify();
            if (entry.trusted) |*bridge| bridge.markInput();
        }
        entry.last_input_sequence = sequence;
        return .{ .input_sequence = sequence, .queued_bytes = bytes.len };
    }
    fn serviceCreateAnchor(raw: *anyopaque, binding: host.ServiceHandle, point: terminal.Point) !terminal.Anchor {
        const self: *LocalAdapter = @ptrCast(@alignCast(raw));
        const entry = try self.resolve(binding, .terminal, false);
        if (!entry.mutex.tryLock()) return error.WorkerBusy;
        defer entry.mutex.unlock();
        return entry.controller.?.createAnchor(entry.handle, point);
    }
    fn serviceResolveAnchor(raw: *anyopaque, binding: host.ServiceHandle, anchor: terminal.Anchor) !?terminal.AnchorPosition {
        const self: *LocalAdapter = @ptrCast(@alignCast(raw));
        const entry = try self.resolve(binding, .terminal, false);
        if (!entry.mutex.tryLock()) return error.WorkerBusy;
        defer entry.mutex.unlock();
        return entry.controller.?.resolveAnchor(anchor);
    }
    fn serviceReleaseAnchor(raw: *anyopaque, binding: host.ServiceHandle, anchor: terminal.Anchor) !void {
        const self: *LocalAdapter = @ptrCast(@alignCast(raw));
        const entry = try self.resolve(binding, .terminal, false);
        if (!entry.mutex.tryLock()) return error.WorkerBusy;
        defer entry.mutex.unlock();
        return entry.controller.?.releaseAnchor(anchor);
    }
    fn serviceSelectionText(raw: *anyopaque, binding: host.ServiceHandle, selected: terminal.Selection, allocator: std.mem.Allocator, max_bytes: usize) ![]u8 {
        const self: *LocalAdapter = @ptrCast(@alignCast(raw));
        const entry = try self.resolve(binding, .terminal, false);
        if (!entry.mutex.tryLock()) return error.WorkerBusy;
        defer entry.mutex.unlock();
        return entry.controller.?.selectionText(selected, allocator, max_bytes);
    }
    fn serviceScroll(raw: *anyopaque, binding: host.ServiceHandle, request: terminal.Scroll) !void {
        const self: *LocalAdapter = @ptrCast(@alignCast(raw));
        const entry = try self.resolve(binding, .terminal, false);
        if (!entry.mutex.tryLock()) return error.WorkerBusy;
        defer entry.mutex.unlock();
        try entry.controller.?.scroll(entry.handle, request, nowMs());
        refreshProjection(entry);
    }
    fn serviceReadLines(raw: *anyopaque, binding: host.ServiceHandle, limits: terminal.LineLimits, allocator: std.mem.Allocator) !terminal.Lines {
        const self: *LocalAdapter = @ptrCast(@alignCast(raw));
        const entry = try self.resolve(binding, .terminal, false);
        if (!entry.mutex.tryLock()) return error.WorkerBusy;
        defer entry.mutex.unlock();
        return entry.controller.?.readLines(entry.handle, limits, allocator);
    }
    fn serviceSearchSnapshot(raw: *anyopaque, binding: host.ServiceHandle, allocator: std.mem.Allocator) !terminal.SearchSnapshot {
        const self: *LocalAdapter = @ptrCast(@alignCast(raw));
        const entry = try self.resolve(binding, .terminal, false);
        if (!entry.mutex.tryLock()) return error.WorkerBusy;
        defer entry.mutex.unlock();
        return .{ .owner = entry.handle, .document = try entry.controller.?.searchSnapshot(entry.handle, allocator) };
    }
};

fn pause() void {
    const delay: std.c.timespec = .{ .sec = 0, .nsec = 10 * std.time.ns_per_ms };
    _ = std.c.nanosleep(&delay, null);
}
fn nowMs() i64 {
    return @intCast(native.zw_local_monotonic_ms());
}
fn sameCwd(a: ?[]const u8, b: ?[]const u8) bool {
    if (a) |left| return if (b) |right| std.mem.eql(u8, left, right) else false;
    return b == null;
}
fn asReceipt(cleanup: native.Cleanup) host.CloseReceipt {
    return switch (cleanup) {
        .awaiting => .awaiting,
        .released => .released,
        .unknown => .unknown,
    };
}
fn startFailure(entry: *Entry, failure: operations.Failure) void {
    entry.mutex.lock();
    defer entry.mutex.unlock();
    entry.failure = failure;
    entry.process_state = .failed;
    entry.eof = true;
    entry.finish(if (failure.cleanup == .released) .released else .unknown);
}
fn run(entry: *Entry) void {
    entry.mutex.lock();
    const cancelled = entry.close_requested.load(.acquire);
    entry.mutex.unlock();
    if (cancelled) {
        entry.mutex.lock();
        entry.eof = true;
        entry.finish(.released);
        entry.mutex.unlock();
        return;
    }
    entry.vt = Vt.init(entry.allocator, entry.options.rows, entry.options.cols) catch {
        startFailure(entry, .{ .domain = .plugin, .code = "LocalTerminalInitFailed", .stage = "terminal", .cleanup = .released, .safe_message = "无法初始化本地终端" });
        return;
    };
    entry.controller = Controller.init(.{ .owner = entry.handle, .engine = VtEngine.from(Vt, &entry.vt.?), .text_slot = &entry.text }) catch {
        startFailure(entry, .{ .domain = .plugin, .code = "LocalTerminalInitFailed", .stage = "terminal", .cleanup = .released, .safe_message = "无法初始化本地终端" });
        return;
    };
    entry.trusted = trusted_mod.Bridge.init(entry.allocator, entry.handle) catch |err| blk: {
        entry.trusted_error = @errorName(err);
        break :blk null;
    };
    var failure: native.Failure = .{};
    entry.process = pty.Session.start(entry.allocator, entry.handle, entry.key, .{ .initial_cwd = entry.cwd, .term = entry.term, .cols = entry.options.cols, .rows = entry.options.rows, .bootstrap = if (entry.trusted) |*bridge| bridge.bootstrap() else null }, &failure) catch {
        startFailure(entry, failure.hostFailure());
        return;
    };
    entry.mutex.lock();
    if (entry.options.recording) |options| {
        entry.recording = recording_mod.Recording.init(entry.allocator, entry.handle, options, entry.geometry.cols, entry.geometry.rows, nowMs()) catch |err| blk: {
            entry.recording_error = @errorName(err);
            break :blk null;
        };
    }
    entry.pid = entry.process.?.pid() catch null;
    if (entry.process.?.initialCwd() catch null) |cwd| if (cwd.len <= entry.reported_cwd.len) {
        @memcpy(entry.reported_cwd[0..cwd.len], cwd);
        entry.reported_cwd_len = cwd.len;
        entry.cwd_source = .initial_directory;
    };
    refreshProjection(entry);
    entry.process_state = if (entry.close_requested.load(.acquire)) .closing else .running;
    entry.ready = !entry.close_requested.load(.acquire);
    entry.mutex.unlock();
    var metadata_at: u64 = 0;
    const transport: terminal.Transport = .{ .context = entry, .vtable = &.{ .read = readPty, .write = writePty, .resize = resizePty } };
    while (true) {
        entry.mutex.lock();
        const status_before = .{ entry.process_state, entry.exit, entry.eof, entry.resize_error, entry.terminal_error, entry.snapshot_error, entry.theme_error, entry.applied_theme_revision };
        applyTheme(entry);
        if (entry.close_requested.load(.acquire) and entry.process_state == .running) entry.process_state = .closing;
        const closing = entry.close_requested.load(.acquire) or entry.exit != null;
        if (entry.trusted) |*bridge| {
            const before = bridge.last_received;
            const was_pending = bridge.pending != null;
            const was_hello = bridge.hello;
            const was_disabled = bridge.disabled;
            if (closing) bridge.revoke(.integration_lost) else if (entry.pid) |pid| bridge.poll(pid, nowMs());
            if (before != bridge.last_received or was_pending != (bridge.pending != null) or was_hello != bridge.hello or was_disabled != bridge.disabled) @import("../platform/presentation_wakeup.zig").notify();
        }
        if (closing) while (entry.writes.items.len > 0) entry.completeWrite(.cancelled);
        if (entry.process) |*process| {
            if (!closing) {
                if (entry.requested_geometry) |geometry| {
                    applyGeometry(entry, transport, geometry);
                }
                const input_modes = entry.vt.?.snapshot();
                entry.mode_revision = input_modes.mode_revision;
                entry.modes = input_modes.modes;
                // Serialize complete byte frames across both producers. A
                // reply may precede a not-yet-started input, never bisect an
                // input whose partial prefix already reached the PTY.
                const input_started = entry.writes.items.len > 0 and entry.writes.items[0].consumed > 0;
                if (!input_started) flushReply(entry, transport);
                if (entry.writes.items.len > 0 and entry.reply_offset == entry.reply_len) {
                    const write = &entry.writes.items[0];
                    if (write.consumed == 0 and write.mode != entry.mode_revision) {
                        write.failure = .stale_mode;
                        entry.completeWrite(.failed);
                        entry.mutex.unlock();
                        pause();
                        continue;
                    }
                    const result = transport.write(write.bytes[write.consumed..]) catch {
                        write.failure = .transport_failed;
                        entry.completeWrite(.failed);
                        // A transport write failure is not a startup failure.
                        entry.mutex.unlock();
                        pause();
                        continue;
                    };
                    if (result == .bytes) {
                        write.consumed += result.bytes;
                        entry.pending_bytes -= result.bytes;
                        if (result.bytes > 0) {
                            entry.foreground_valid = false;
                            // Keep metadata on its 250ms deadline, not per keystroke.
                        }
                        if (write.consumed == write.bytes.len) {
                            if (write.submission) entry.controller.?.recordSubmission(entry.handle) catch {};
                            entry.completeWrite(.completed);
                        }
                    }
                }
            }
            // Hello may arrive after Enter's old socket has closed. Re-arm
            // the current input epoch on the new editable prompt, without
            // requiring another PTY key to trigger synchronization.
            if (!closing and entry.writes.items.len == 0 and entry.reply_offset == entry.reply_len) {
                if (entry.trusted) |*bridge| bridge.synchronizeInput();
            }
            var buffer: [4096]u8 = undefined;
            for (0..16) |_| {
                const free = entry.output.freeCapacity();
                if (free == 0 or entry.eof) break;
                const read = transport.read(buffer[0..@min(buffer.len, free)]) catch |err| {
                    entry.terminal_error = @errorName(err);
                    break;
                };
                switch (read) {
                    .bytes => |count| {
                        entry.output.push(buffer[0..count]) catch unreachable;
                        entry.output_sequence += 1;
                        if (entry.recording) |recording| recording.appendOutput(entry.handle, buffer[0..count], nowMs());
                        if (entry.terminal_error == null) entry.controller.?.feedOutput(entry.handle, entry.output_sequence, buffer[0..count], nowMs()) catch |err| {
                            entry.terminal_error = @errorName(err);
                        };
                    },
                    .would_block => break,
                    .eof => {
                        entry.eof = true;
                        entry.controller.?.eof(entry.handle) catch {};
                        break;
                    },
                }
            }
            entry.exit = process.pollExit() catch entry.exit;
            if (entry.exit != null and !entry.close_requested.load(.acquire)) entry.process_state = .exited;
            if (native.zw_local_monotonic_ms() >= metadata_at) {
                const foreground = process.foreground();
                var metadata_changed = !std.meta.eql(entry.foreground, foreground) or entry.foreground_valid != (foreground != null);
                entry.foreground = foreground;
                entry.foreground_valid = entry.foreground != null;
                entry.metadata_observed_ms = native.zw_local_monotonic_ms();
                const cwd = process.currentCwd(entry.allocator) catch null;
                if (cwd) |value| {
                    defer entry.allocator.free(value);
                    if (value.len <= entry.reported_cwd.len) {
                        metadata_changed = metadata_changed or entry.cwd_source != .process or entry.reported_cwd_len != value.len or !std.mem.eql(u8, entry.reported_cwd[0..value.len], value);
                        @memcpy(entry.reported_cwd[0..value.len], value);
                        entry.reported_cwd_len = value.len;
                        entry.cwd_source = .process;
                    }
                } else {
                    metadata_changed = metadata_changed or entry.reported_cwd_len != null or entry.cwd_source != .unknown;
                    entry.reported_cwd_len = null;
                    entry.cwd_source = .unknown;
                }
                // A silent cd/foreground change does not publish a text frame.
                // Sampling timestamps alone must not keep an idle UI awake.
                if (metadata_changed) @import("../platform/presentation_wakeup.zig").notify();
                metadata_at = native.zw_local_monotonic_ms() + 250;
            }
        }
        refreshProjection(entry);
        var jobs_done = true;
        var jobs_unknown = false;
        for (entry.jobs.items) |job| {
            if (!job.done) {
                const job_before = .{ job.started, job.pid, job.done, job.stdout.items.len, job.stderr.items.len, job.cancelled, job.timed_out, job.truncated, job.cleanup };
                pollExec(entry, job, closing or entry.exit != null);
                if (!std.meta.eql(job_before, .{ job.started, job.pid, job.done, job.stdout.items.len, job.stderr.items.len, job.cancelled, job.timed_out, job.truncated, job.cleanup })) @import("../platform/presentation_wakeup.zig").notify();
            }
            if (!job.done) jobs_done = false;
            if (job.done and job.cleanup != .released) jobs_unknown = true;
        }
        if (entry.close_requested.load(.acquire) or (entry.exit != null and entry.eof)) {
            var cleanup: host.CloseReceipt = .released;
            if (entry.process) |*process| {
                cleanup = asReceipt(process.closeStep(entry.handle) catch .unknown);
                if (cleanup == .released) {
                    process.deinit() catch {
                        cleanup = .unknown;
                    };
                    if (cleanup == .released) entry.process = null;
                }
            }
            if (cleanup != .awaiting and jobs_done) {
                entry.controller.?.retryPublication(nowMs());
                if (entry.recording) |recording| {
                    // A saved policy published while this mutex was busy must
                    // also reach close-time pruning before the next UI drain.
                    recording.retention_days.store(entry.recording_retention_days.load(.acquire), .release);
                    recording.close(entry.handle, @import("../platform/realtime.zig").milliseconds(entry), if (entry.exit) |value| switch (value) {
                        .exited => |code| code,
                        .signal => null,
                    } else null);
                }
                entry.finish(if (jobs_unknown) .unknown else cleanup);
                entry.mutex.unlock();
                return;
            }
        }
        entry.controller.?.retryPublication(nowMs());
        // EOF and failure/status changes can occur without changing VT cells
        // or producing a new TextSlot generation.
        if (!std.meta.eql(status_before, .{ entry.process_state, entry.exit, entry.eof, entry.resize_error, entry.terminal_error, entry.snapshot_error, entry.theme_error, entry.applied_theme_revision })) @import("../platform/presentation_wakeup.zig").notify();
        // Wait outside the guard. PTY readability and queued input wake immediately;
        // the bounded deadline services trusted-shell IPC, child exit and exec jobs.
        const fd = if (!entry.eof and entry.output.freeCapacity() > 0) if (entry.process) |p| if (p.process) |native_process| native.zw_local_poll_fd(native_process) else -1 else -1 else -1;
        const edit_fd = if (!closing) if (entry.trusted) |*bridge| bridge.pollFd() else -1 else -1;
        const edit_writable = if (entry.trusted) |*bridge| bridge.tx_offset < bridge.tx.items.len else false;
        const writable = entry.writes.items.len > 0 or entry.reply_offset < entry.reply_len;
        const timeout: c_int = if (closing or !jobs_done or entry.controller.?.feed.republish_pending) 8 else 50;
        entry.mutex.unlock();
        entry.wakeup.waitExtra(fd, writable, edit_fd, edit_writable, timeout);
    }
}

fn applyGeometry(entry: *Entry, transport: terminal.Transport, geometry: terminal.Geometry) void {
    if (entry.transport_geometry_revision != geometry.revision) {
        transport.resize(geometry.revision, geometry.cols, geometry.rows) catch |err| {
            entry.resize_error = @errorName(err);
            return;
        };
        entry.transport_geometry_revision = geometry.revision;
    }
    entry.controller.?.resizeApplied(entry.handle, geometry, nowMs()) catch |err| {
        // Keep the last coherent frame/revision. Retry only the VT half; the
        // PTY has already accepted this revision and rejects stale resends.
        entry.resize_error = @errorName(err);
        return;
    };
    entry.geometry = geometry;
    if (entry.recording) |recording| recording.resizeApplied(entry.handle, geometry.cols, geometry.rows, nowMs());
    entry.resize_error = null;
    entry.requested_geometry = null;
}
fn refreshProjection(entry: *Entry) void {
    const scalar = entry.vt.?.snapshot();
    entry.mode_revision = scalar.mode_revision;
    entry.modes = scalar.modes;
    if (entry.projection) |value| if (value.version == scalar.version and entry.projection_geometry_revision == entry.geometry.revision and entry.projection_theme_revision == entry.applied_theme_revision) return;
    const value = entry.controller.?.copyProjection(entry.handle, entry.allocator) catch |err| {
        entry.snapshot_error = @errorName(err);
        return;
    };
    if (entry.projection) |*old| old.deinit(entry.allocator);
    entry.projection = value;
    entry.projection_output_sequence = entry.controller.?.status().output_sequence;
    entry.projection_geometry_revision = entry.geometry.revision;
    entry.projection_theme_revision = entry.applied_theme_revision;
    entry.snapshot_error = null;
    @import("../platform/presentation_wakeup.zig").notify();
}
fn applyTheme(entry: *Entry) void {
    const theme = entry.requested_theme orelse return;
    if (entry.controller == null) return;
    entry.controller.?.setTheme(entry.handle, theme, nowMs()) catch |err| {
        entry.theme_error = @errorName(err);
        return;
    };
    if (entry.recording) |recording| recording.themeApplied(entry.handle, theme, nowMs());
    entry.applied_theme_revision = theme.revision;
    entry.theme_error = null;
    entry.requested_theme = null;
}
fn flushReply(entry: *Entry, transport: terminal.Transport) void {
    if (entry.reply_offset == entry.reply_len) {
        entry.reply_len = entry.controller.?.readReply(entry.handle, &entry.reply_buffer) catch |err| {
            entry.terminal_error = @errorName(err);
            return;
        };
        entry.reply_offset = 0;
    }
    if (entry.reply_len == 0) return;
    const result = transport.write(entry.reply_buffer[entry.reply_offset..entry.reply_len]) catch |err| {
        entry.terminal_error = @errorName(err);
        return;
    };
    if (result == .bytes) entry.reply_offset += result.bytes;
}

fn readPty(raw: *anyopaque, buffer: []u8) !terminal.Read {
    const entry: *Entry = @ptrCast(@alignCast(raw));
    return switch (try entry.process.?.readOutput(entry.handle, buffer)) {
        .bytes => |count| .{ .bytes = count },
        .would_block => .would_block,
        .eof => .eof,
    };
}
fn writePty(raw: *anyopaque, bytes: []const u8) !terminal.Write {
    const entry: *Entry = @ptrCast(@alignCast(raw));
    return switch (try entry.process.?.write(entry.handle, bytes)) {
        .bytes => |count| .{ .bytes = count },
        .would_block => .would_block,
    };
}
fn resizePty(raw: *anyopaque, revision: u64, cols: u16, rows: u16) !void {
    const entry: *Entry = @ptrCast(@alignCast(raw));
    return entry.process.?.resize(entry.handle, revision, cols, rows);
}

fn pollExec(entry: *Entry, job: *ExecJob, closing: bool) void {
    if (closing) job.cancel_requested.store(true, .release);
    if (!job.started) {
        if (job.cancel_requested.load(.acquire)) {
            job.cancelled = true;
            job.done = true;
            job.cleanup = .released;
            return;
        }
        var failure: native.Failure = .{};
        job.command = exec.Command.start(entry.allocator, entry.handle, job.handle.operation, job.handle.call_id, job.command_text, job.cwd, job.limits, &failure) catch {
            job.failure = failure.hostFailure();
            job.cleanup = if (job.failure.?.cleanup == .released) .released else .unknown;
            job.done = true;
            return;
        };
        job.started = true;
        job.pid = job.command.?.pid() catch null;
    }
    const command = &job.command.?;
    if (job.cancel_requested.load(.acquire)) command.cancel(entry.handle) catch {};
    const result = command.poll() catch {
        job.cancel_requested.store(true, .release);
        command.cancel(entry.handle) catch {};
        return;
    };
    job.stdout.clearRetainingCapacity();
    job.stdout.appendSliceAssumeCapacity(result.stdout);
    job.stderr.clearRetainingCapacity();
    job.stderr.appendSliceAssumeCapacity(result.stderr);
    job.exit = result.exit;
    job.timed_out = result.timed_out;
    job.truncated = result.truncated;
    job.cancelled = result.cancelled;
    if (result.cancelled) job.cancel_requested.store(true, .release);
    job.cleanup = asReceipt(result.cleanup);
    if (result.cleanup != .awaiting) {
        if (result.cleanup == .released) command.deinit() catch {
            job.cleanup = .unknown;
        };
        if (job.cleanup == .released) job.command = null;
        job.done = true;
    }
}
