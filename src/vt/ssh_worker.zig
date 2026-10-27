const std = @import("std");
const Session = @import("../proto/ssh/session.zig").Session;
const Library = @import("../proto/ssh/session.zig").Library;
const Options = @import("../proto/ssh/session.zig").Options;
const JumpRoute = @import("../proto/ssh/jump_transport.zig").Route;
const VtAdapter = @import("ghostty_adapter.zig").Adapter;
const TextSlot = @import("text_slot.zig").TextSlot;
const InputQueue = @import("input_queue.zig").InputQueue;
const WorkerIo = @import("worker_io.zig").WorkerIo;
const WorkerLoop = @import("worker_loop.zig").Loop;
const Reconnect = @import("reconnect.zig").Machine;
const replay_mod = @import("reconnect_replay.zig");
const Replay = replay_mod.Replay;
const Timeline = @import("timeline.zig").Timeline;
const realtime = @import("../platform/realtime.zig");
const CheckpointController = @import("checkpoint_controller.zig").Controller;
const SshExecBridge = @import("../proto/ssh/exec_bridge.zig").SshExecBridge;
const SharedTransfer = @import("../proto/ssh/shared_transfer_service.zig").Service;
const ForwardService = @import("../proto/ssh/forward_service.zig").Service;

pub const RuntimeOptions = struct {
    scrollback: ?u32 = null,
    timeline_max_events: usize = 4096,
    timeline_max_bytes: usize = 64 * 1024 * 1024,
    reconnect_max: u8 = 5,
    auto_reconnect: bool = true,
    buffer_input: bool = true,
    reconnect_backoff: [5]u8 = .{ 1, 2, 4, 8, 16 },
    connect_timeout_ms: u32 = 15_000,
    keepalive_sec: u16 = 30,
    compression: bool = false,
    /// Plain shell commands to inject once the interactive shell is opened.
    /// Each non-empty entry is sent in order with one LF terminator.  This is
    /// deliberately a one-way command list; expect/send pairs are not parsed
    /// or inferred here.
    startup_commands: []const []const u8 = &.{},
    initial_input: []const u8 = "",
    /// Production runtimes wait for the host's actual pane attachment receipt.
    wait_for_attachment: bool = false,
    /// Owned by SessionRuntime and valid through every worker reconnect.
    jump_options: []const Options = &.{},
};

pub const current_directory_command = " printf '\\033]7;\\007\\033]7;file://localhost%s\\007' \"$(printf '%s' \"$PWD\" | sed 's/%/%25/g;s/ /%20/g')\"\n";

const startup_input_limit: usize = 64 * 1024;

/// Encode the declarative startup command list for the PTY input queue.
/// Commands remain shell text (quoting, pipes, etc. are intentional); the
/// only framing added by ZeroWork is one newline per non-empty command.
pub fn encodeStartupCommands(allocator: std.mem.Allocator, commands: []const []const u8) ![]u8 {
    var total: usize = 0;
    for (commands) |command| {
        if (command.len == 0) continue;
        const with_newline = std.math.add(usize, command.len, 1) catch return error.StartupCommandsTooLarge;
        total = std.math.add(usize, total, with_newline) catch return error.StartupCommandsTooLarge;
        if (total > startup_input_limit) return error.StartupCommandsTooLarge;
    }
    if (total == 0) return allocator.dupe(u8, "");
    const bytes = try allocator.alloc(u8, total);
    errdefer allocator.free(bytes);
    var offset: usize = 0;
    for (commands) |command| {
        if (command.len == 0) continue;
        @memcpy(bytes[offset .. offset + command.len], command);
        offset += command.len;
        bytes[offset] = '\n';
        offset += 1;
    }
    return bytes;
}

fn encodeStartupInput(allocator: std.mem.Allocator, commands: []const []const u8, initial_input: []const u8) ![]u8 {
    const commands_input = try encodeStartupCommands(allocator, commands);
    defer allocator.free(commands_input);
    const total = std.math.add(usize, commands_input.len, initial_input.len) catch return error.StartupCommandsTooLarge;
    if (total > startup_input_limit) return error.StartupCommandsTooLarge;
    const bytes = try allocator.alloc(u8, total);
    @memcpy(bytes[0..commands_input.len], commands_input);
    @memcpy(bytes[commands_input.len..], initial_input);
    return bytes;
}

/// Owns the concrete single-hop SSH → VT → UI worker resources.
pub const SshWorker = struct {
    allocator: std.mem.Allocator,
    cwd_capture: @import("cwd_capture.zig").Capture = .{},
    wakeup: @import("../platform/wakeup.zig").Wakeup,
    library: *const Library,
    options: Options,
    session: Session,
    detected_os: std.atomic.Value(@import("../proto/ssh/remote_os.zig").Kind),
    os_probe_finished: std.atomic.Value(bool),
    os_probe: ?@import("../ai/execbridge.zig").ExecHandle = null,
    exec_bridge: SshExecBridge,
    shared_transfer: ?*SharedTransfer = null,
    // Facades stay at stable addresses across the actual Session/Route moves.
    // Native calls run only in this Worker or the selected upstream Relay.
    forward_services: [9]?*ForwardService = @splat(null),
    forward_count: usize = 0,
    jump_route: ?*JumpRoute = null,
    jump_options: []const Options = &.{},
    vt: VtAdapter,
    text: TextSlot,
    input: InputQueue,
    read_buffer: []u8,
    write_buffer: []u8,
    io: WorkerIo,
    loop: WorkerLoop,
    loop_active: bool = true,
    reconnect: Reconnect,
    replay: Replay,
    timeline: Timeline,
    reconnect_backoff: [5]u8,
    auto_reconnect: bool,
    buffer_input: bool,
    startup_input: []u8,
    startup_pending: std.atomic.Value(bool) = .init(false),
    presentation_attached: std.atomic.Value(bool) = .init(true),
    startup_end_index: ?usize = null,
    shell_opened_ns: i128 = 0,
    /// UI→worker PTY resize request. UI thread stores (dims, seq); the worker
    /// applies the latest request on its next step. Low 16 bits = cols,
    /// high 16 = rows.
    pending_scrollback_limit: std.atomic.Value(u64) = .init(0),
    resize_dims: std.atomic.Value(u32) = .init(0),
    resize_seq: std.atomic.Value(u32) = .init(0),
    applied_resize_seq: u32 = 0,
    search_row: std.atomic.Value(usize) = .init(0),
    search_seq: std.atomic.Value(u32) = .init(0),
    applied_search_seq: u32 = 0,
    next_keepalive_ns: i128 = 0,
    /// IO-owner only. An SSH CHANNEL_EOF is independent of transport loss.
    shell_eof_ns: ?i128 = null,
    shell_exit_code: ?i32 = null,

    pub fn init(allocator: std.mem.Allocator, library: *const Library, options: Options, runtime: RuntimeOptions) !*SshWorker {
        const worker = try allocator.create(SshWorker);
        errdefer allocator.destroy(worker);
        var session_options = options;
        session_options.connect_timeout_ms = runtime.connect_timeout_ms;
        session_options.keepalive_sec = runtime.keepalive_sec;
        session_options.compression = runtime.compression;
        var route: ?*JumpRoute = null;
        var session = if (runtime.jump_options.len == 0) try Session.connect(library, session_options) else blk: {
            route = try JumpRoute.connect(allocator, library, runtime.jump_options);
            break :blk route.?.takeTarget();
        };
        errdefer if (route) |value| value.deinit();
        errdefer closeSessionForRollback(&session);
        var vt = try VtAdapter.init(allocator, options.rows, options.cols);
        errdefer vt.destroy();
        vt.configureTerminalType(options.term);
        try vt.setScrollbackLimit(runtime.scrollback orelse 25000);
        // The UI consumes the text slot only; the dirty-page slot is an
        // optional FeedBridge feature and stays unwired here because nobody
        // consumes it. Wiring it without a consumer used to trip ConsumerBehind
        // into the reconnect path ("typing dies after a few echoes").
        var text = try TextSlot.init(allocator, TextSlot.default_capacity);
        errdefer text.deinit(allocator);
        var wakeup = try @import("../platform/wakeup.zig").Wakeup.init();
        errdefer wakeup.deinit();
        var input = try InputQueue.init(allocator, 64 * 1024);
        errdefer input.deinit(allocator);
        const read_buffer = try allocator.alloc(u8, 32 * 1024);
        errdefer allocator.free(read_buffer);
        const write_buffer = try allocator.alloc(u8, 32 * 1024);
        errdefer allocator.free(write_buffer);
        var timeline = try Timeline.init(allocator, runtime.timeline_max_events, runtime.timeline_max_bytes);
        errdefer timeline.deinit();
        const startup_input = try encodeStartupInput(allocator, runtime.startup_commands, runtime.initial_input);
        errdefer allocator.free(startup_input);
        worker.* = undefined;
        worker.allocator = allocator;
        worker.library = library;
        worker.options = session_options;
        worker.next_keepalive_ns = realtime.monotonicNs() + @as(i128, runtime.keepalive_sec) * std.time.ns_per_s;
        worker.shell_eof_ns = null;
        worker.shell_exit_code = null;
        worker.session = session;
        worker.exec_bridge = SshExecBridge.init(&worker.session, allocator);
        worker.detected_os = .init(.unknown);
        worker.os_probe = null;
        worker.os_probe_finished = .init(false);
        worker.shared_transfer = try SharedTransfer.init(allocator, &worker.session);
        errdefer worker.shared_transfer.?.deinitLocal() catch {};
        worker.forward_services = @splat(null);
        worker.forward_count = if (runtime.jump_options.len == 0) 1 else runtime.jump_options.len;
        errdefer for (worker.forward_services[0..worker.forward_count]) |service| if (service) |value| value.deinitLocal() catch {};
        for (worker.forward_services[0..worker.forward_count]) |*service| service.* = try ForwardService.init(allocator, session_options.operation_key);
        worker.jump_route = route;
        worker.jump_options = runtime.jump_options;
        // Reader/writer contexts must point at the stored Session, not the
        // init-local copy (their ctx is &session.channel, stack-dangling otherwise).
        const reader = try worker.session.reader();
        const writer = try worker.session.writer();
        worker.vt = vt;
        worker.vt.configureCwdTracking();
        worker.text = text;
        worker.input = input;
        worker.wakeup = wakeup;
        worker.input.wakeup = &worker.wakeup;
        worker.read_buffer = read_buffer;
        worker.write_buffer = write_buffer;
        worker.timeline = timeline;
        worker.startup_input = startup_input;
        worker.startup_pending = .init(runtime.wait_for_attachment or startup_input.len != 0);
        worker.presentation_attached = .init(!runtime.wait_for_attachment);
        worker.pending_scrollback_limit = .init(0);
        worker.resize_dims = .init(0);
        worker.resize_seq = .init(0);
        worker.applied_resize_seq = 0;
        worker.search_row = .init(0);
        worker.search_seq = .init(0);
        worker.applied_search_seq = 0;
        worker.startup_end_index = null;
        worker.shell_opened_ns = realtime.monotonicNs();
        worker.reconnect_backoff = runtime.reconnect_backoff;
        worker.auto_reconnect = runtime.auto_reconnect;
        worker.buffer_input = runtime.buffer_input;
        worker.cwd_capture = .{};
        worker.io = .{
            .output_filter = .{ .context = worker, .feed = captureDirectoryOutput, .finish = finishDirectoryOutput },
            .feed = .{ .engine = @import("engine.zig").VtEngine.from(VtAdapter, &worker.vt), .text_slot = &worker.text },
            .input = &worker.input,
            .reader = reader,
            .writer = writer,
            .read_buffer = worker.read_buffer,
            .write_buffer = worker.write_buffer,
            .timeline = &worker.timeline,
            .timestamp_ctx = worker,
            .timestamp_fn = realtime.milliseconds,
        };
        worker.loop = try WorkerLoop.init(try worker.session.socketFd(), worker.io.handler());
        errdefer worker.loop.deinit();
        try worker.loop.setWakeup(&worker.wakeup);
        worker.loop_active = true;
        worker.reconnect = try Reconnect.init(@max(runtime.reconnect_max, 1), &worker.reconnect_backoff);
        worker.replay = try Replay.init(allocator, 8192);
        worker.replay.configure(session_options.operation_key, runtime.buffer_input, !runtime.wait_for_attachment and startup_input.len == 0);
        errdefer worker.replay.deinit();
        try worker.loop.setInterest(.{ .read = true });
        // No relay can borrow facades until every fallible Worker allocation
        // succeeded. Failed initialization therefore cannot strand a facade.
        if (worker.jump_route) |value| value.bindForwards(worker.forward_services[0..worker.forward_count]);
        // Opening the shell channel is not the same as prompt readiness.
        // step waits for a 500ms quiet interval before injecting setup.
        // A separate bounded exec request shares the existing IO owner.
        worker.os_probe = worker.exec_bridge.diagnostic(@import("../proto/ssh/remote_os.zig").command, .{ .timeout_ms = 3000, .capture_cap = 8192 }) catch null;
        if (worker.os_probe == null) worker.os_probe_finished.store(true, .release);
        return worker;
    }

    pub fn deinit(self: *SshWorker) void {
        for (self.forward_services[0..self.forward_count]) |service| if (service) |value| value.requestClose();
        if (self.releaseConnection() != .released) {
            // An owner-driven Listener may still borrow this exact Session
            // and EAGAIN buffers. Pin the complete graph for cleanup retry.
            if (self.forward_count != 0) return;
            const ledger = self.options.resource_ledger orelse return;
            // Initializer rollback may need to free VT/queues while native
            // cleanup is still pending. Move only those native owners into the
            // original job's bounded ledger; never destroy their handles here.
            if (self.session.handle != null or self.session.socket_fd >= 0) {
                if (!ledger.retainFailure(&self.session)) return;
            }
            if (self.jump_route) |route| {
                if (!ledger.retainRoute(route)) return;
                self.jump_route = null;
            }
        }
        // releaseConnection either freed the parent native Session or moved
        // its complete native graph to the original attempt ledger above.
        if (self.shared_transfer) |shared| {
            shared.deinitLocal() catch return;
            self.shared_transfer = null;
        }
        for (self.forward_services[0..self.forward_count]) |service| if (service) |value| {
            value.adoptIoAfterOwnerStopped();
            value.stepPaused() catch return;
            value.deinitLocal() catch return;
        };
        self.forward_count = 0;
        self.exec_bridge.deinitLocal();
        self.allocator.free(self.read_buffer);
        self.allocator.free(self.write_buffer);
        self.allocator.free(self.startup_input);
        self.timeline.deinit();
        self.replay.deinit();
        self.input.deinit(self.allocator);
        self.wakeup.deinit();
        self.text.deinit(self.allocator);
        self.vt.destroy();
        const allocator = self.allocator;
        self.* = undefined;
        allocator.destroy(self);
    }

    fn pollOsProbe(self: *SshWorker) void {
        const handle = self.os_probe orelse return;
        if (SshExecBridge.pollHandle(handle)) |result| {
            self.os_probe_finished.store(true, .release);
            if (result.status == .completed) {
                const kind = @import("../proto/ssh/remote_os.zig").parse(result.stdout);
                if (kind != .unknown) self.detected_os.store(kind, .release);
            }
            if ((self.exec_bridge.closeCall(handle) catch .awaiting) == .released) self.os_probe = null;
        }
    }

    pub fn requestScrollbackLimit(self: *SshWorker, limit: u32) void {
        self.pending_scrollback_limit.store(@as(u64, limit) + 1, .release);
        self.wakeup.notify();
    }
    pub fn applyPendingScrollbackLimit(self: *SshWorker) !void {
        const pending = self.pending_scrollback_limit.swap(0, .acq_rel);
        if (pending == 0) return;
        try self.vt.setScrollbackLimit(@intCast(pending - 1));
        self.io.feed.publishCurrentText(realtime.milliseconds(undefined));
    }

    pub fn step(self: *SshWorker, timeout_ms: u32) !void {
        try self.applyPendingScrollbackLimit();
        for (self.forward_services[0..self.forward_count]) |service| if (service) |value| if (value.parentCloseRequested()) return error.ForwardParentClosing;
        if (!self.loop_active) return error.WorkerStopped;
        if (self.io.closed) return self.finishShellStep();
        const shared_pending = if (self.shared_transfer) |shared| shared.hasPending() else false;
        const forward_pending = if (self.targetForward()) |service| service.hasListener() else false;
        self.loop.step(if (shared_pending) @min(timeout_ms, 1) else if (forward_pending) @min(timeout_ms, 5) else if (self.exec_bridge.hasPending()) @min(timeout_ms, 10) else timeout_ms) catch |err| {
            // A readable event can consume protocol EOF before a writable
            // event from the same batch reports that the shell is closed.
            if (self.io.closed) return self.finishShellStep();
            self.reconnect.suspect(null);
            return err;
        };
        // UI-side backpressure retry: a text frame publication deferred while
        // the UI was a generation behind is retried here. This must never be
        // classified as a connection failure — only socket/VT errors are.
        if (self.io.feed.republish_pending) self.io.feed.publishCurrentText(realtime.milliseconds(undefined));
        // SSH flow-control deadlock breaker: probe the channel EVERY step.
        // libssh2's channel_read entry force-sends the receive-window adjust
        // the remote needs to keep sending, and the remote stops (and no
        // kqueue READ event ever fires) once its window runs dry — the last
        // successful read does NOT mean the window is healthy. A conditional
        // probe missed exactly that case: last read of the burst returned
        // data, flag stayed clear, output froze until a user keypress
        // happened to send a packet and wake the remote. One non-blocking
        // read per 50ms step costs ~1µs idle.
        try self.io.pollChannelRead();
        try self.io.pumpWrites();
        if (self.io.closed) return self.finishShellStep();
        try self.session.stepRtt(realtime.monotonicNs());
        try self.exec_bridge.step();
        self.pollOsProbe();
        if (self.shared_transfer) |shared| try shared.step();
        if (self.targetForward()) |service| try service.step(&self.session);
        try self.enqueueStartupIfReady(realtime.monotonicNs(), @max(self.shell_opened_ns, self.io.last_output_ns));
        if (self.options.keepalive_sec != 0) {
            const now = realtime.monotonicNs();
            if (now >= self.next_keepalive_ns) {
                // EAGAIN is expected while the worker socket is busy; the
                // next step retries without classifying it as a disconnect.
                const keepalive_rc = @import("generated_ssh_session").zw_libssh2_session_send_keepalive(self.session.handle.?);
                // LIBSSH2_ERROR_EAGAIN means the non-blocking socket cannot
                // accept the packet yet. Retry shortly; it is not a lost
                // connection and must not enter reconnect handling.
                self.next_keepalive_ns = now + if (keepalive_rc == -37)
                    @as(i128, 50) * std.time.ns_per_ms
                else
                    @as(i128, self.options.keepalive_sec) * std.time.ns_per_s;
            }
        }
        self.io.diagBurstIfQuiet(realtime.milliseconds(undefined));
        // Apply the latest UI-requested PTY/grid resize (if any). Session
        // resize first: on transient libssh2 EAGAIN it fails and we simply
        // retry next step (applied_resize_seq not advanced). Only after the
        // remote accepted do we resize the local grid and republish a frame,
        // keeping remote wrap and local layout consistent.
        self.applyPendingResize() catch |err| {
            std.log.warn("[worker] pty resize deferred: {s}", .{@errorName(err)});
        };
        const search_seq = self.search_seq.load(.acquire);
        if (search_seq != self.applied_search_seq) {
            try self.vt.scrollToRow(self.search_row.load(.acquire));
            self.io.feed.publishCurrentText(realtime.milliseconds(undefined));
            self.applied_search_seq = search_seq;
        }
        // Writable interest is demand-driven. Recompute it after every poll so
        // partial writes and replayed input cannot leave a stale kqueue flag.
        // The libssh2 channel window is refunded from INSIDE channel_read:
        // when that WINDOW_ADJUST send hits EAGAIN (send buffer full), read
        // returns "no data" and the loop waits on READ only — but the remote
        // has stopped sending (window exhausted) and never wakes us. Watching
        // WRITE until the pending adjust drains breaks that deadlock ("output
        // freezes until a keypress").
        if (self.presentation_attached.load(.acquire) and !self.startup_pending.load(.acquire)) {
            _ = self.replay.attached(&self.input, self.options.operation_key, replay_mod.InputMode.from(self.vt.snapshot().modes)) catch false;
        }
        _ = self.replay.snapshot(&self.input);
        const needs_write = self.input.pending() != 0 or self.io.repliesPending();
        const next_interest = @import("worker_interest.zig").Interest{ .read = true, .write = needs_write };
        if (!std.meta.eql(self.loop.interest, next_interest)) {
            std.log.debug("[worker] interest change write={} pending={d}", .{ next_interest.write, self.input.pending() });
            try self.loop.setInterest(next_interest);
        }
    }

    /// Preserve the final text frame, then allow a late exit-status packet
    /// during the ordinary nonblocking channel-close exchange. EOF itself is
    /// enough to end the shell; absent status stays unknown, never exit 0.
    fn finishShellStep(self: *SshWorker) !void {
        if (self.shell_eof_ns == null) {
            self.shell_eof_ns = realtime.monotonicNs();
            self.replay.ended(&self.input);
            self.startup_pending.store(false, .release);
            self.startup_end_index = null;
            self.presentation_attached.store(false, .release);
            self.reconnect.close();
        }
        if (self.io.feed.republish_pending) {
            self.io.feed.publishCurrentText(realtime.milliseconds(undefined));
            if (self.io.feed.republish_pending) return;
        }
        if (self.session.channel) |channel| {
            const native = @import("generated_ssh_channel");
            const close_result = native.zw_libssh2_channel_wait_closed_step(channel.handle);
            var status: c_int = 0;
            if (native.zw_libssh2_channel_exit_status_received(channel.handle, &status) == 1) self.shell_exit_code = status;
            if (close_result == 1 and realtime.monotonicNs() - self.shell_eof_ns.? < std.time.ns_per_s) return;
        }
        return error.ShellEnded;
    }

    /// UI-thread entry: requests a PTY/grid resize. The worker applies the
    /// latest request on its next step; stale requests are superseded.
    pub fn requestResize(self: *SshWorker, cols: u16, rows: u16) void {
        if (cols == 0 or rows == 0) return;
        const dims: u32 = @as(u32, cols) | (@as(u32, rows) << 16);
        self.resize_dims.store(dims, .release);
        _ = self.resize_seq.fetchAdd(1, .release);
    }

    /// ServiceHost supplies the current real exec binding; this returns only
    /// the mailbox facade. Native execution stays in this worker's step loop.
    pub fn execService(self: *SshWorker, binding: @import("../host/session_host.zig").ServiceHandle) !@import("../ai/execbridge.zig").ExecBridge {
        try self.exec_bridge.bindService(binding);
        return self.exec_bridge.asBridge();
    }

    /// A transfer service over this exact original SSH Session. Submission
    /// performs no native IO; the existing worker step owns every SFTP call.
    pub fn transferService(self: *SshWorker, binding: @import("../host/session_host.zig").ServiceHandle) !*SharedTransfer {
        const shared = self.shared_transfer orelse return error.TransferServiceUnavailable;
        try shared.bindService(binding);
        return shared;
    }

    pub fn readonlyProvider(self: *SshWorker) !@import("../proto/ssh/shared_readonly_mailbox.zig").Provider {
        const shared = self.shared_transfer orelse return error.TransferServiceUnavailable;
        return shared.readonlyProvider();
    }

    /// UI receives only this memory-command/value-snapshot facade. The hop's
    /// Session, socket and Listener remain confined to its native IO owner.
    pub fn forwardService(self: *SshWorker, binding: @import("../host/session_host.zig").ServiceHandle, exit_index: ?usize) !*ForwardService {
        if (binding.kind != .forward or binding.resource_owner != .session or binding.origin_session == null or !binding.resource_owner.session.eql(binding.origin_session.?) or binding.binding_generation != binding.origin_session.?.generation or binding.binding_id == 0) return error.InvalidForwardAuthority;
        const index = exit_index orelse if (self.forward_count == 0) return error.ForwardServiceUnavailable else self.forward_count - 1;
        if (index >= self.forward_count) return error.InvalidForwardExit;
        const service = self.forward_services[index] orelse return error.ForwardServiceUnavailable;
        const original = service.snapshot().origin orelse return error.ForwardServiceUnavailable;
        if (original.owner != .session or !original.owner.session.eql(binding.origin_session.?)) return error.StaleForwardOrigin;
        return service;
    }

    fn targetForward(self: *SshWorker) ?*ForwardService {
        return if (self.forward_count == 0) null else self.forward_services[self.forward_count - 1];
    }
    /// Only after releaseConnection acknowledged every target/upstream native
    /// owner. The waiting worker then responds locally from retained ports.
    pub fn stepPausedForwards(self: *SshWorker) !void {
        for (self.forward_services[0..self.forward_count]) |service| if (service) |value| try value.stepPaused();
    }

    /// Worker-thread: applies the pending resize (remote PTY first, then the
    /// local grid, then a fresh frame) or fails transiently for a retry.
    fn applyPendingResize(self: *SshWorker) !void {
        const seq = self.resize_seq.load(.acquire);
        if (seq == self.applied_resize_seq) return;
        const dims = self.resize_dims.load(.acquire);
        const cols: u16 = @truncate(dims);
        const rows: u16 = @truncate(dims >> 16);
        try self.session.resize(cols, rows);
        try @import("engine.zig").VtEngine.from(VtAdapter, &self.vt).resize(cols, rows);
        self.io.feed.publishTextFrame(realtime.milliseconds(undefined));
        self.applied_resize_seq = seq;
        std.log.info("[worker] pty resize applied {d}x{d}", .{ cols, rows });
    }

    /// A controller-issued successor replaces only protocol resources. VT,
    /// output, recording and this IO owner stay with the original pane.
    pub fn rebuildForOperation(self: *SshWorker, previous: @import("../host/operation.zig").OperationKey, next: @import("../host/operation.zig").OperationKey) !void {
        switch (self.releaseConnection()) {
            .released => {},
            .awaiting => return error.CleanupNotReleased,
            .unknown => return error.CleanupUnknown,
        }
        if (self.options.operation_key == null or !self.options.operation_key.?.eql(previous)) return error.StaleOperation;
        if (self.options.resource_ledger) |ledger| try ledger.beginAttempt(previous, next) else return error.MissingResourceLedger;
        self.options.operation_key = next;
        self.options.attempt_id = next.attempt_id orelse return error.InvalidOperation;
        try self.replay.authorize(previous, next);
        const dims = self.resize_dims.load(.acquire);
        if (dims != 0) {
            self.options.cols = @truncate(dims);
            self.options.rows = @truncate(dims >> 16);
        }
        // Each attempt re-reads the real trust store. A previous attempt-only
        // acceptance never becomes persistent trust on a replacement socket.
        if (self.options.host_key_store) |store| try store.refresh();
        try self.rebuildReleasedTransport();
    }

    /// Compatibility entry cannot allocate an attempt or bypass the host gate.
    pub fn rebuildConnection(self: *SshWorker) !void {
        switch (self.releaseConnection()) {
            .released => return error.ReconnectAuthorizationRequired,
            .awaiting => return error.CleanupNotReleased,
            .unknown => return error.CleanupUnknown,
        }
    }

    fn rebuildReleasedTransport(self: *SshWorker) !void {
        for (self.forward_services[0..self.forward_count]) |service| if (service) |value| try value.prepareReplacement();
        var route_options: [9]Options = undefined;
        if (self.jump_options.len > route_options.len) return error.InvalidJumpRoute;
        for (self.jump_options, 0..) |options, index| {
            route_options[index] = options;
            route_options[index].operation_key = self.options.operation_key;
            route_options[index].attempt_id = self.options.attempt_id;
            if (index + 1 == self.jump_options.len) {
                route_options[index].cols = self.options.cols;
                route_options[index].rows = self.options.rows;
            }
        }
        var replacement_route: ?*JumpRoute = null;
        var replacement = if (self.jump_options.len == 0) try Session.connect(self.library, self.options) else blk: {
            replacement_route = try JumpRoute.connect(self.allocator, self.library, route_options[0..self.jump_options.len]);
            break :blk replacement_route.?.takeTarget();
        };
        errdefer if (replacement_route) |route| route.deinit();
        errdefer closeSessionForRollback(&replacement);
        var replacement_loop = try WorkerLoop.init(try replacement.socketFd(), self.io.handler());
        errdefer replacement_loop.deinit();
        try replacement_loop.setWakeup(&self.wakeup);
        try replacement_loop.setInterest(.{ .read = true });

        // Old calls remain terminal and are never replayed onto a replacement
        // transport. A fresh real host binding is required for new submissions.
        if (self.shared_transfer) |shared| try shared.prepareReplacement();
        try self.exec_bridge.transportReplaced(replacement);
        if (self.os_probe) |old| _ = self.exec_bridge.closeCall(old) catch .unknown;
        self.os_probe = self.exec_bridge.diagnostic(@import("../proto/ssh/remote_os.zig").command, .{ .timeout_ms = 3000, .capture_cap = 8192 }) catch null;
        self.os_probe_finished.store(self.os_probe == null, .release);
        if (self.shared_transfer) |shared| shared.transportReplaced();
        self.jump_route = replacement_route;
        self.loop = replacement_loop;
        self.loop_active = true;
        self.io.resetTransport(try self.session.reader(), try self.session.writer());
        self.shell_eof_ns = null;
        self.shell_exit_code = null;
        self.shell_opened_ns = realtime.monotonicNs();
        self.io.last_output_ns = 0;
        self.applied_resize_seq = 0;
        if (self.jump_route) |value| value.bindForwards(self.forward_services[0..self.forward_count]);
        if (self.targetForward()) |service| try service.step(&self.session);
        // Startup and the original initial input belong only to first attach.
        // Rebuilding a transport must never re-arm potentially side-effecting
        // commands, including startup that had not yet drained at disconnect.
        try self.resumeInputAfterReconnect();
        self.reconnect.connected();
        try self.loop.setInterest(.{ .read = true });
    }

    /// Sole IO owner: unregister readiness, close target, then release each
    /// relay/tunnel/upstream hop. A nonterminal receipt preserves every owner.
    pub fn releaseConnection(self: *SshWorker) @import("../proto/ssh/session.zig").ReleaseReceipt {
        if (self.targetForward()) |service| {
            service.adoptIoAfterOwnerStopped();
            service.transportLost() catch return .unknown;
        }
        self.exec_bridge.close();
        if (self.shared_transfer) |shared| {
            shared.transportLost();
            shared.adoptIoAfterOwnerStopped();
            shared.step() catch return .unknown;
        }
        // The only alternate caller is cleanup after WorkerThread.join. The
        // same mailbox/native graph is handed to that stopped owner's task.
        self.exec_bridge.adoptIoAfterOwnerStopped() catch return .awaiting;
        self.exec_bridge.step() catch return .unknown;
        if (self.loop_active) {
            self.loop.deinit();
            self.loop_active = false;
        }
        const target = self.session.closeReceipt();
        if (target != .released) return target;
        if (self.targetForward()) |service| service.sessionReleased() catch return .unknown;
        self.exec_bridge.sessionReleased() catch return .awaiting;
        if (self.shared_transfer) |shared| {
            shared.sessionReleased() catch return .awaiting;
            // Paused checkpoints keep their service alive until the host
            // explicitly exports them or cancels their original jobs.
            if (!shared.canReleaseParent()) return .awaiting;
        }
        if (self.options.resource_ledger) |ledger| {
            const pending = ledger.drainRetained();
            if (pending != .released and ledger.snapshot().retained_count != 0) return pending;
        }
        if (self.jump_route) |route| {
            const receipt = route.closeReceipt();
            if (receipt != .released) return receipt;
            route.deinit();
            self.jump_route = null;
        }
        if (self.options.resource_ledger) |ledger| {
            const resources = ledger.snapshot();
            if (!resources.released()) return if (resources.hasUnknown()) .unknown else .awaiting;
        }
        return .released;
    }

    fn closeSessionForRollback(session: *Session) void {
        if (session.closeReceipt() != .released) {
            if (session.resource_ledger) |ledger| _ = ledger.retainFailure(session);
        }
    }

    pub fn onReconnected(self: *SshWorker) !void {
        try self.rebuildConnection();
    }

    pub fn reconnectState(self: *const SshWorker) @import("reconnect.zig").State {
        return self.reconnect.currentState();
    }

    /// Free input-queue capacity in bytes. Atomic SPSC reads, safe to call
    /// from the UI thread (used by the large-paste pump).
    pub fn inputFreeCapacity(self: *const SshWorker) usize {
        return self.input.freeCapacity();
    }

    /// Binds a runtime-owned checkpoint controller before the worker thread starts.
    pub fn bindCheckpoint(self: *SshWorker, checkpoint: *CheckpointController) void {
        self.io.checkpoint = checkpoint;
    }

    /// Safe UI-thread export: timeline locking and atomic requested dimensions
    /// avoid reading the worker-owned VT grid while it is being resized.
    pub fn exportTimeline(self: *SshWorker, io: std.Io, dir: std.Io.Dir, path: []const u8) !void {
        const dimensions = self.resize_dims.load(.acquire);
        const cols: u16 = if (dimensions == 0) self.options.cols else @truncate(dimensions);
        const rows: u16 = if (dimensions == 0) self.options.rows else @truncate(dimensions >> 16);
        if (std.mem.endsWith(u8, path, ".cast"))
            try self.timeline.saveCast(io, dir, path, cols, rows)
        else
            try self.timeline.save(io, dir, path);
    }

    pub fn timelinePtr(self: *SshWorker) *Timeline {
        return &self.timeline;
    }

    pub fn textSlot(self: *SshWorker) *@import("text_slot.zig").TextSlot {
        return &self.text;
    }

    /// Copy selection from the worker-owned VT snapshot without exposing the adapter.
    pub fn searchText(self: *SshWorker, allocator: std.mem.Allocator) ![]u8 {
        return self.vt.searchText(allocator);
    }

    /// Copy the shell-reported cwd (OSC 7/9/1337) for UI/AI consumers.
    fn finishDirectoryOutput(raw: *anyopaque, io: *WorkerIo) !void {
        const self: *SshWorker = @ptrCast(@alignCast(raw));
        try self.cwd_capture.finish(io);
    }
    fn captureDirectoryOutput(raw: *anyopaque, io: *WorkerIo, bytes: []const u8) !void {
        const self: *SshWorker = @ptrCast(@alignCast(raw));
        try self.cwd_capture.feed(io, bytes, realtime.monotonicNs());
    }
    pub fn requestCurrentDirectory(self: *SshWorker) !void {
        self.vt.clearCwd();
        self.cwd_capture.arm();
        // Execute in the interactive shell: a separate exec channel starts in
        // the login directory and cannot observe a preceding `cd`.
        self.pushInput(current_directory_command) catch |err| {
            self.cwd_capture.requested.store(false, .release);
            return err;
        };
    }

    pub fn copyCwd(self: *SshWorker, allocator: std.mem.Allocator) !?[]u8 {
        return self.vt.copyCwd(allocator);
    }

    pub fn searchViewportOffset(self: *SshWorker) u64 {
        return self.vt.viewportOffset();
    }

    pub fn locateSearchRow(self: *SshWorker, row: usize) void {
        self.search_row.store(row, .release);
        _ = self.search_seq.fetchAdd(1, .release);
    }

    pub fn copySelection(self: *SshWorker, selection: @import("engine.zig").Selection, allocator: std.mem.Allocator) ![]u8 {
        return @import("engine.zig").VtEngine.from(VtAdapter, &self.vt).selectionText(selection, .plain, allocator);
    }

    /// Freeze the original legacy SSH VT range without retargeting a newer
    /// owner or output revision. The adapter serializes every read; revisions
    /// on both sides reject any mutation between the snapshot and byte copy.
    pub fn captureAiSelection(self: *SshWorker, allocator: std.mem.Allocator, owner: @import("../host/identity.zig").SessionHandle, selected: @import("engine.zig").Selection, version: u64) !@import("../host/ai_terminal_selection.zig").Captured {
        const before = try self.replay.notificationKey();
        if (before.owner != .session or !before.owner.session.eql(owner)) return error.StaleOwner;
        const snapshot = self.vt.snapshot();
        if (snapshot.version != version) return error.StaleSelection;
        if (selected.start_row > selected.end_row or selected.end_row >= snapshot.rows or selected.start_col >= snapshot.cols or selected.end_col >= snapshot.cols or (selected.start_row == selected.end_row and selected.start_col > selected.end_col)) return error.StaleSelection;
        const start = try self.vt.createAnchor(.{ .row = @intCast(selected.start_row), .col = selected.start_col });
        defer self.vt.releaseAnchor(start) catch {};
        const end = try self.vt.createAnchor(.{ .row = @intCast(selected.end_row), .col = selected.end_col + 1 });
        defer self.vt.releaseAnchor(end) catch {};
        const bytes = try self.copySelection(selected, allocator);
        errdefer allocator.free(bytes);
        if (bytes.len == 0) return error.NoSelection;
        if (bytes.len > @import("../host/ai_terminal_selection.zig").max_service_bytes) return error.SelectionTooLarge;
        if (self.vt.snapshot().version != version) return error.StaleSelection;
        const after = try self.replay.notificationKey();
        if (!before.eql(after)) return error.StaleOwner;
        return .{ .allocator = allocator, .owner = owner, .selection = .{ .start = .{ .owner = owner, .id = start }, .end = .{ .owner = owner, .id = end } }, .bytes = bytes, .source_version = version, .selected_rows = @intCast(selected.end_row - selected.start_row + 1) };
    }

    /// Compatibility/application bytes are deliberately never reconnect input.
    pub fn pushInput(self: *SshWorker, bytes: []const u8) !void {
        try self.pushInputFrom(bytes, .application);
    }

    pub fn pushInputFrom(self: *SshWorker, bytes: []const u8, source: replay_mod.Source) !void {
        const mode = if (source == .ordinary) replay_mod.InputMode.from(self.vt.snapshot().modes) else replay_mod.InputMode{};
        try self.replay.submit(&self.input, bytes, source, mode);
    }

    pub fn allowsBufferedOrdinaryInput(self: *SshWorker) bool {
        return (!self.presentation_attached.load(.acquire) or self.reconnect.currentState() != .connected) and self.replay.allowsOrdinary();
    }
    pub fn setInputBufferEnabled(self: *SshWorker, enabled: bool) void {
        self.replay.setEnabled(enabled);
    }
    pub fn discardBufferedInput(self: *SshWorker) void {
        self.replay.discardBuffered();
    }
    pub fn invalidateInput(self: *SshWorker) void {
        self.replay.invalidate();
    }
    pub fn inputSnapshot(self: *SshWorker) replay_mod.Replay.Snapshot {
        return self.replay.snapshot(&self.input);
    }
    /// The replay gate owns reconnect/close identity. Check it on both sides
    /// of the independently locked VT snapshot so a generation change cannot
    /// attribute old notification facts to the caller's captured owner.
    pub fn notificationSnapshot(self: *SshWorker, expected: @import("../host/identity.zig").SessionHandle) !@import("../host/terminal_service.zig").NotificationSnapshot {
        const before = try self.replay.notificationKey();
        if (before.owner != .session or !before.owner.session.eql(expected)) return error.StaleOwner;
        const snapshot = self.vt.snapshot();
        const after = try self.replay.notificationKey();
        if (!before.eql(after)) return error.StaleOwner;
        return .{ .owner = expected, .output_sequence = snapshot.output_sequence, .bell_count = snapshot.bell_count };
    }

    pub const NotificationPublication = struct { text_generation: u64, output_sequence: u64, at_tail: bool };
    /// Proves a successful projection for the exact current operation/VT
    /// version. The view must additionally prove it consumed this generation.
    pub fn notificationPublication(self: *SshWorker, expected: @import("../host/identity.zig").SessionHandle) !?NotificationPublication {
        const before = try self.replay.notificationKey();
        if (before.owner != .session or !before.owner.session.eql(expected)) return error.StaleOwner;
        const published = self.io.feed.notificationPublication() orelse return null;
        const scalar = self.vt.snapshot();
        const tail = self.vt.viewportAtTail() orelse return null;
        const after = self.vt.snapshot();
        if (!before.eql(try self.replay.notificationKey())) return error.StaleOwner;
        if (scalar.version != after.version or published.vt_version != scalar.version or published.output_sequence != scalar.output_sequence) return null;
        return .{ .text_generation = published.text_generation, .output_sequence = published.output_sequence, .at_tail = tail };
    }

    /// Sole IO owner after a fault, before releasing or awaiting a new grant.
    pub fn disconnectInput(self: *SshWorker) void {
        self.replay.disconnected(&self.input);
        if (self.options.cancel_token) |token| if (token.load(.acquire)) self.replay.discardBuffered();
        self.startup_pending.store(false, .release);
        self.startup_end_index = null;
    }

    pub fn markAttached(self: *SshWorker) void {
        self.presentation_attached.store(true, .release);
    }

    fn enqueueStartupIfReady(self: *SshWorker, now_ns: i128, last_output_ns: i128) !void {
        if (!self.presentation_attached.load(.acquire) or !self.startup_pending.load(.acquire) or !startupReadyAt(now_ns, last_output_ns)) return;
        try self.replay.startup(&self.input, self.startup_input);
        self.startup_end_index = self.input.write_index.load(.acquire);
        self.startup_pending.store(false, .release);
        _ = self.replay.attached(&self.input, self.options.operation_key, replay_mod.InputMode.from(self.vt.snapshot().modes)) catch |err| switch (err) {
            error.Full => false, // Retry handoff after startup drains; no transport failure.
            else => return err,
        };
    }

    fn resumeInputAfterReconnect(self: *SshWorker) !void {
        // disconnectInput already removed every old byte, including a partial
        // startup/application event. Only ordinary event records may be handed
        // off after the controller accepts the new attachment and VT modes.
        self.startup_end_index = null;
        self.startup_pending.store(false, .release);
    }

    pub fn interest(self: *const SshWorker) @import("worker_interest.zig").Interest {
        return self.loop.interest;
    }
};

fn startupReadyAt(now_ns: i128, last_output_ns: i128) bool {
    return now_ns >= last_output_ns and now_ns - last_output_ns >= 500 * std.time.ns_per_ms;
}

test "startup injection waits for a full quiet interval and resets on output" {
    const ms = std.time.ns_per_ms;
    try std.testing.expect(!startupReadyAt(499 * ms, 0));
    try std.testing.expect(startupReadyAt(500 * ms, 0));
    try std.testing.expect(!startupReadyAt(800 * ms, 400 * ms));
    try std.testing.expect(startupReadyAt(900 * ms, 400 * ms));
    try std.testing.expect(!startupReadyAt(0, 1));
}

test "startup command encoder preserves order and skips empty rows" {
    const commands = [_][]const u8{ "cd /opt/deploy", "", "printf 'ready'" };
    const encoded = try encodeStartupCommands(std.testing.allocator, &commands);
    defer std.testing.allocator.free(encoded);
    try std.testing.expectEqualStrings("cd /opt/deploy\nprintf 'ready'\n", encoded);
}

test "startup command encoder bounds input before allocation" {
    const huge = try std.testing.allocator.alloc(u8, startup_input_limit);
    defer std.testing.allocator.free(huge);
    const commands = [_][]const u8{huge};
    try std.testing.expectError(error.StartupCommandsTooLarge, encodeStartupCommands(std.testing.allocator, &commands));
}

fn inputTestWorker(worker: *SshWorker) !void {
    worker.cwd_capture = .{};
    worker.input = try InputQueue.init(std.testing.allocator, 256);
    worker.replay = try Replay.init(std.testing.allocator, 256);
    worker.options = .{ .host = "fixture", .user = "fixture", .auth = .agent, .operation_key = .{ .owner = .{ .session = .{ .session_id = @fromBackingInt(8) } }, .operation_id = 1, .attempt_id = 1 } };
    worker.replay.configure(worker.options.operation_key, true, false);
    worker.vt = try VtAdapter.init(std.testing.allocator, 3, 80);
    worker.startup_pending = .init(true);
    worker.presentation_attached = .init(false);
    worker.startup_end_index = null;
}
fn deinitInputTestWorker(worker: *SshWorker) void {
    worker.input.deinit(std.testing.allocator);
    worker.replay.deinit();
    worker.vt.destroy();
}

test "notification SSH read receipt requires successful current publication and actual viewport tail" {
    const a = std.testing.allocator;
    var worker: SshWorker = undefined;
    try inputTestWorker(&worker);
    defer deinitInputTestWorker(&worker);
    worker.text = try TextSlot.init(a, 4096);
    defer worker.text.deinit(a);
    worker.io.feed = .{ .engine = @import("engine.zig").VtEngine.from(VtAdapter, &worker.vt), .text_slot = &worker.text };
    const owner = worker.options.operation_key.?.owner.session;
    try std.testing.expect(try worker.notificationPublication(owner) == null);
    _ = try worker.io.feed.feedAndPublish("one", 100);
    const first = (try worker.notificationPublication(owner)).?;
    try std.testing.expect(first.at_tail);
    _ = try worker.io.feed.feedAndPublish("two", 101);
    try std.testing.expect(try worker.notificationPublication(owner) == null);
    worker.io.feed.publishCurrentText(110);
    try std.testing.expectEqual(@as(u64, 2), (try worker.notificationPublication(owner)).?.output_sequence);
    _ = try worker.io.feed.feedAndPublish("\r\n1\r\n2\r\n3\r\n4\r\n5\r\n6", 120);
    try worker.vt.scrollToRow(0);
    try std.testing.expect(try worker.notificationPublication(owner) == null);
    var scratch: [4096]u8 = undefined;
    _ = (try worker.text.take(0, &scratch)).?;
    worker.io.feed.publishCurrentText(130);
    try std.testing.expect(!(try worker.notificationPublication(owner)).?.at_tail);
    try worker.vt.scroll(.bottom);
    worker.io.feed.publishCurrentText(140);
    try std.testing.expect((try worker.notificationPublication(owner)).?.at_tail);
    var wrong = owner;
    wrong.generation += 1;
    try std.testing.expectError(error.StaleOwner, worker.notificationPublication(wrong));
    worker.replay.invalidate();
    try std.testing.expectError(error.TerminalClosed, worker.notificationPublication(owner));
}

test "notification SSH snapshot retains actual parser facts for only the live operation owner" {
    var worker: SshWorker = undefined;
    try inputTestWorker(&worker);
    defer deinitInputTestWorker(&worker);
    const original = worker.options.operation_key.?;
    const owner = original.owner.session;
    const baseline = try worker.notificationSnapshot(owner);
    try std.testing.expect(baseline.owner.eql(owner));
    try std.testing.expectEqual(@as(u64, 0), baseline.output_sequence);
    try std.testing.expectEqual(@as(u64, 0), baseline.bell_count);
    _ = try worker.vt.feed("\x1b]0;title\x07");
    _ = try worker.vt.feed("\x07\x07output");
    const first = try worker.notificationSnapshot(owner);
    try std.testing.expectEqual(@as(u64, 2), first.output_sequence);
    try std.testing.expectEqual(@as(u64, 2), first.bell_count);
    try std.testing.expectEqualDeep(first, try worker.notificationSnapshot(owner));
    worker.replay.ended(&worker.input);
    try std.testing.expectEqualDeep(first, try worker.notificationSnapshot(owner));
    var next = original;
    next.owner.session = try owner.nextGeneration();
    next.operation_id += 1;
    next.attempt_id = 2;
    try worker.replay.authorize(original, next);
    try std.testing.expectError(error.StaleOwner, worker.notificationSnapshot(owner));
    const successor = try worker.notificationSnapshot(next.owner.session);
    try std.testing.expect(successor.owner.eql(next.owner.session));
    try std.testing.expectEqual(first.output_sequence, successor.output_sequence);
    try std.testing.expectEqual(first.bell_count, successor.bell_count);
    _ = try worker.vt.feed("new\x07");
    const latest = try worker.notificationSnapshot(next.owner.session);
    try std.testing.expectEqual(@as(u64, 3), latest.output_sequence);
    try std.testing.expectEqual(@as(u64, 3), latest.bell_count);
    worker.invalidateInput();
    try std.testing.expectError(error.TerminalClosed, worker.notificationSnapshot(next.owner.session));
}

test "startup and initial input wait for attached and are consumed once" {
    var worker: SshWorker = undefined;
    try inputTestWorker(&worker);
    defer deinitInputTestWorker(&worker);
    worker.startup_input = try encodeStartupInput(std.testing.allocator, &.{"printf ready"}, "cd /tmp\n");
    defer std.testing.allocator.free(worker.startup_input);
    try worker.pushInputFrom("pwd\n", .ordinary);
    try std.testing.expectError(error.DisconnectedApplicationInput, worker.pushInput("APP\n"));
    try worker.enqueueStartupIfReady(2 * std.time.ns_per_s, 0);
    try std.testing.expectEqual(@as(usize, 0), worker.input.pending());
    worker.markAttached();
    try worker.enqueueStartupIfReady(2 * std.time.ns_per_s, 0);
    var buffer: [128]u8 = undefined;
    try std.testing.expectEqualStrings("printf ready\ncd /tmp\npwd\n", worker.input.drain(&buffer));
    worker.markAttached();
    try worker.enqueueStartupIfReady(3 * std.time.ns_per_s, 0);
    try std.testing.expectEqual(@as(usize, 0), worker.input.pending());
}

test "reconnect discards one-time startup and waits for new attachment" {
    var worker: SshWorker = undefined;
    try inputTestWorker(&worker);
    defer deinitInputTestWorker(&worker);
    worker.startup_input = @constCast("never-replay\n");
    worker.disconnectInput();
    var next = worker.options.operation_key.?;
    next.owner.session.generation += 1;
    next.operation_id += 1;
    next.attempt_id = 2;
    try worker.replay.authorize(worker.options.operation_key.?, next);
    worker.options.operation_key = next;
    try worker.resumeInputAfterReconnect();
    try worker.pushInputFrom("explicit input\n", .ordinary);
    try std.testing.expectEqual(@as(usize, 0), worker.input.pending());
    worker.markAttached();
    _ = try worker.replay.attached(&worker.input, next, replay_mod.InputMode.from(worker.vt.snapshot().modes));
    try worker.enqueueStartupIfReady(2 * std.time.ns_per_s, 0);
    var buffer: [128]u8 = undefined;
    try std.testing.expectEqualStrings("explicit input\n", worker.input.drain(&buffer));
}

test "reconnect drops partial startup and only retains untouched ordinary events" {
    var worker: SshWorker = undefined;
    try inputTestWorker(&worker);
    defer deinitInputTestWorker(&worker);
    worker.startup_input = @constCast("old startup\n");
    worker.markAttached();
    try worker.enqueueStartupIfReady(2 * std.time.ns_per_s, 0);
    try worker.input.consume(4);
    try worker.pushInputFrom("explicit queued input\n", .ordinary);
    try worker.pushInputFrom("old approved paste\n", .paste);
    worker.disconnectInput();
    var next = worker.options.operation_key.?;
    next.owner.session.generation += 1;
    next.operation_id += 1;
    next.attempt_id = 2;
    try worker.replay.authorize(worker.options.operation_key.?, next);
    worker.options.operation_key = next;
    try worker.resumeInputAfterReconnect();
    worker.markAttached();
    _ = try worker.replay.attached(&worker.input, next, replay_mod.InputMode.from(worker.vt.snapshot().modes));
    var buffer: [128]u8 = undefined;
    try std.testing.expectEqualStrings("explicit queued input\n", worker.input.drain(&buffer));
    try worker.enqueueStartupIfReady(3 * std.time.ns_per_s, 0);
    try std.testing.expectEqual(@as(usize, 0), worker.input.pending());
    try std.testing.expectEqual(@as(usize, 4), worker.inputSnapshot().uncertain);
}

test "full startup queue defers ordinary handoff without failing the transport" {
    var worker: SshWorker = undefined;
    try inputTestWorker(&worker);
    defer deinitInputTestWorker(&worker);
    var startup: [256]u8 = @splat('s');
    worker.startup_input = &startup;
    try worker.pushInputFrom("中", .ordinary);
    worker.markAttached();
    try worker.enqueueStartupIfReady(2 * std.time.ns_per_s, 0);
    try std.testing.expectEqual(startup.len, worker.input.pending());
    try worker.input.consume(startup.len);
    try std.testing.expect(try worker.replay.attached(&worker.input, worker.options.operation_key, replay_mod.InputMode.from(worker.vt.snapshot().modes)));
    var bytes: [8]u8 = undefined;
    try std.testing.expectEqualStrings("中", worker.input.drain(&bytes));
}

test "AI legacy SSH selection capture freezes actual VT bytes original owner version and releases anchors" {
    const a = std.testing.allocator;
    var worker: SshWorker = undefined;
    try inputTestWorker(&worker);
    defer deinitInputTestWorker(&worker);
    _ = try worker.vt.feed("ZW_SSH_CAPTURE_ORIGINAL\r\nsecond");
    const owner = worker.options.operation_key.?.owner.session;
    const version = worker.vt.snapshot().version;
    const range: @import("engine.zig").Selection = .{ .start_row = 0, .start_col = 0, .end_row = 0, .end_col = 22 };
    var captured = try worker.captureAiSelection(a, owner, range, version);
    defer captured.deinit();
    try std.testing.expectEqualStrings("ZW_SSH_CAPTURE_ORIGINAL", captured.bytes);
    try std.testing.expect(captured.owner.eql(owner));
    try std.testing.expectEqual(version, captured.source_version);
    try std.testing.expect(captured.selection.start.owner.eql(owner));
    try std.testing.expect(captured.selection.end.owner.eql(owner));
    try std.testing.expect(captured.selection.start.id != 0 and captured.selection.end.id != 0);
    try std.testing.expectEqual(@as(usize, 0), worker.vt.view_store.refs.items.len);
    var reference = try @import("../ai/terminal_text_attachments.zig").createSelection(a, .{ .owner = captured.owner, .source_name = "original SSH", .source_version = captured.source_version, .selected_rows = captured.selected_rows, .selection = captured.selection, .legacy_range = range }, captured.bytes, 1234);
    defer reference.release();
    var sent = reference.retain();
    defer sent.release();
    try std.testing.expect(sent.content().?.source.terminal.owner.eql(owner));
    try std.testing.expectEqual(version, sent.content().?.source.terminal.origin.selection.source_version);
    try std.testing.expectEqualDeep(range, sent.content().?.source.terminal.origin.selection.legacy_range.?);
    _ = try worker.vt.feed(" changed");
    try std.testing.expectEqualStrings("ZW_SSH_CAPTURE_ORIGINAL", sent.content().?.bytes);
    try std.testing.expectEqualStrings("ZW_SSH_CAPTURE_ORIGINAL", captured.bytes);
    try std.testing.expectError(error.StaleSelection, worker.captureAiSelection(a, owner, range, version));
    try std.testing.expectError(error.StaleOwner, worker.captureAiSelection(a, try owner.nextGeneration(), range, worker.vt.snapshot().version));
    try std.testing.expectEqual(@as(usize, 0), worker.vt.view_store.refs.items.len);
}

test "current directory request clears stale paths and consumes a fresh shell report" {
    var worker: SshWorker = undefined;
    try inputTestWorker(&worker);
    defer deinitInputTestWorker(&worker);
    worker.vt.configureCwdTracking();
    worker.replay.configure(worker.options.operation_key, true, true);
    _ = try worker.vt.feed("\x1b]7;file://localhost/old\x07");
    try worker.requestCurrentDirectory();
    try std.testing.expect((try worker.copyCwd(std.testing.allocator)) == null);
    var buffer: [256]u8 = undefined;
    try std.testing.expectEqualStrings(current_directory_command, worker.input.drain(&buffer));
    _ = try worker.vt.feed("\x1b]7;\x07\x1b]7;file://localhost/srv/a%20b%25c\x07");
    const path = (try worker.copyCwd(std.testing.allocator)).?;
    defer std.testing.allocator.free(path);
    try std.testing.expectEqualStrings("/srv/a b%c", path);
}

test "live scrollback requests apply to existing SSH engine and zero removes the limit" {
    const a = std.testing.allocator;
    var worker: SshWorker = undefined;
    worker.vt = try VtAdapter.init(a, 4, 80);
    defer worker.vt.destroy();
    worker.pending_scrollback_limit = .init(0);
    worker.wakeup = try @import("../platform/wakeup.zig").Wakeup.init();
    defer worker.wakeup.deinit();
    var text = try TextSlot.init(a, TextSlot.default_capacity);
    defer text.deinit(a);
    worker.io.feed = .{ .engine = @import("engine.zig").VtEngine.from(VtAdapter, &worker.vt), .text_slot = &text };
    try worker.vt.setScrollbackLimit(0);
    for (0..3000) |i| {
        var buffer: [32]u8 = undefined;
        _ = try worker.vt.feed(try std.fmt.bufPrint(&buffer, "live-row-{d}\r\n", .{i}));
    }
    worker.requestScrollbackLimit(128);
    try worker.applyPendingScrollbackLimit();
    var limited = try worker.vt.copyProjection(a);
    defer limited.deinit(a);
    try std.testing.expect(limited.scrollback.total_rows < 3000);
    worker.requestScrollbackLimit(0);
    try worker.applyPendingScrollbackLimit();
    for (0..3000) |i| {
        var buffer: [32]u8 = undefined;
        _ = try worker.vt.feed(try std.fmt.bufPrint(&buffer, "after-row-{d}\r\n", .{i}));
    }
    var unlimited = try worker.vt.copyProjection(a);
    defer unlimited.deinit(a);
    try std.testing.expect(unlimited.scrollback.total_rows >= 3000);
}
