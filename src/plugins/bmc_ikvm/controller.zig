//! Non-UI controller. Creation freezes configuration/route on their owner;
//! detached protocol worker owns Driver IO, Pipeline and cleanup. poll/cancel
//! never join, resolve credentials or execute native IO. The production plugin
//! supplies the evidence-gated native backend and operation-scoped approvals.
const std = @import("std");
const builtin = @import("builtin");
pub const model = @import("model.zig");
pub const route = @import("route.zig");
pub const video = @import("video_pipeline.zig");
pub const management = @import("management_adapter.zig");
const profile = @import("protocol/profile.zig");
const frames = @import("framebuffer.zig");
const input = @import("remote_input.zig");
const budgets = @import("../../host/frame_budget.zig");
const resolver = @import("../../host/connection_config_resolver.zig");
const typed = @import("../../host/plugin_services.zig");
const actions = @import("../../host/resource_actions.zig");
const ledger = @import("management_journal.zig");
const svc = @import("services.zig");
pub const progress = @import("connection_progress.zig");

pub const RouteState = enum { frozen, connecting, connected, failed, closed };
pub const VideoState = enum { idle, authenticating, negotiating, awaiting_frame, streaming, failed, closed };
pub const ManagementState = enum { idle, authenticating, available, unavailable, closed };
pub const Cleanup = enum { not_started, awaiting, unknown, released };
/// Worker counters only. Frame publication is a client decode/copy receipt;
/// these values do not claim renderer FPS or BMC-to-display input latency.
pub const Performance = struct {
    read_calls: u64 = 0,
    read_bytes: u64 = 0,
    read_would_block: u64 = 0,
    written_bytes: u64 = 0,
    idle_waits: u64 = 0,
    idle_wait_ms: u64 = 0,
    active_yields: u64 = 0,
    feed_ns: u64 = 0,
    max_feed_ns: u64 = 0,
    last_read_ns: u64 = 0,
    last_published_ns: u64 = 0,
};
pub const Snapshot = struct {
    owner: svc.identity.SessionHandle,
    operation: svc.OperationKey,
    transport_generation: u64 = 1,
    route: RouteState = .frozen,
    video: VideoState = .idle,
    management: ManagementState = .idle,
    cleanup: Cleanup = .not_started,
    input: input.Snapshot,
    published_frames: u64 = 0,
    rfb_ready: bool = false,
    control: video.rfb.ControlState = .read_only,
    control_request: ?[4]u8 = null,
    failure: ?anyerror = null,
    worker_exited: bool = false,
    progress: progress.Snapshot = .{},
    performance: Performance = .{},
};
/// begin performs route/TLS/auth/validated WS upgrade on the worker. It must
/// honor cancel while connecting. Credentials belong to this backend and may
/// only be sent after its host trust facade authorizes the original authority.
/// Drivers are explicit IO adapters, never automatic fallback authentication.
/// read/write are nonblocking; cleanup is idempotent and returns a real receipt.
/// The controller/driver/context/journal/budget remain alive until released.
pub const Driver = struct {
    context: *anyopaque,
    begin: *const fn (*anyopaque, *const model.Payload, *const route.Plan, svc.OperationKey, *const std.atomic.Value(bool)) anyerror!video.rfb.Authenticated,
    read: *const fn (*anyopaque, []u8) anyerror!usize,
    write: *const fn (*anyopaque, []const u8) anyerror!usize,
    abort: *const fn (*anyopaque) void,
    cleanup: *const fn (*anyopaque) Cleanup,
    wait: *const fn (*anyopaque, u32) void,
    now_ns: *const fn (*anyopaque) u64,
    /// Optional HTTP adapter is polled even while an issued work item waits.
    /// It copies Outbound before returning and never retries writes itself.
    management_io: ?*const fn (*anyopaque, ?management.power.Outbound) anyerror!?management.power.Completion = null,
    /// Worker-only projection of actual management reads. WEB login
    /// alone does not prove the backend published usable service snapshots.
    management_available: ?*const fn (*anyopaque) bool = null,
};

pub const Controller = struct {
    const ControlCommand = union(enum) { request, reply: struct { context: [4]u8, value: video.rfb.ControlReply }, refresh };
    const QueuedControl = struct { generation: u64, value: ControlCommand };
    allocator: std.mem.Allocator,
    config: svc.Owned(model.Payload),
    plan: route.Plan,
    owner: svc.identity.SessionHandle,
    operation: svc.OperationKey,
    framebuffer: frames.Service,
    remote_input: input.Service,
    manager: management.Adapter,
    pipeline: ?video.Pipeline = null,
    cancel_requested: std.atomic.Value(bool) = .init(false),
    worker_exited: std.atomic.Value(bool) = .init(false),
    started: bool = false,
    driver: ?Driver = null,
    creator_thread: std.Thread.Id,
    mutex: std.atomic.Value(bool) = .init(false),
    state: Snapshot,
    connection_progress: progress.Tracker = .{},
    control_command: ?QueuedControl = null,

    pub fn create(a: std.mem.Allocator, owner: svc.identity.SessionHandle, operation: svc.OperationKey, payload: model.Payload, configs: ?resolver.Resolver, budget: *budgets.Budget, journal: *ledger.Journal, facade: ?actions.Facade) !*Controller {
        return createWithPolicy(a, owner, operation, payload, configs, budget, journal, facade, .user_approved);
    }
    /// Legacy protocol fixtures supply their own preauthorized capabilities.
    /// Production runtimes always use createWithPolicy and exact user approval.
    pub fn createForTest(a: std.mem.Allocator, owner: svc.identity.SessionHandle, operation: svc.OperationKey, payload: model.Payload, configs: ?resolver.Resolver, budget: *budgets.Budget, journal: *ledger.Journal, facade: ?actions.Facade) !*Controller {
        if (!builtin.is_test) return error.TestDriverForbidden;
        if (payload.display.read_only_requested) return error.ReadOnlyRequested;
        const self = try createWithPolicy(a, owner, operation, payload, configs, budget, journal, facade, .user_approved);
        self.manager.fixture_preauthorized = true;
        self.manager.engine.fixture_preauthorized = true;
        return self;
    }
    pub fn createWithPolicy(a: std.mem.Allocator, owner: svc.identity.SessionHandle, operation: svc.OperationKey, payload: model.Payload, configs: ?resolver.Resolver, budget: *budgets.Budget, journal: *ledger.Journal, facade: ?actions.Facade, policy: svc.ManagementPolicy) !*Controller {
        try model.validate(payload);
        if (operation.owner != .session or !operation.owner.session.eql(owner) or operation.operation_id == 0) return error.InvalidOperationOwner;
        var config = try svc.Owned(model.Payload).init(a, payload);
        errdefer config.deinit();
        var ids: [8]svc.identity.ConnectionId = undefined;
        const hops = switch (payload.access) {
            .direct => &.{},
            .ssh_route => |r| r.hops,
        };
        for (hops, 0..) |hop, i| ids[i] = @fromBackingInt(hop.asset_id);
        var plan = try route.Plan.init(a, owner, configs, ids[0..hops.len], .{ .host = payload.endpoint.host, .port = payload.endpoint.https_port });
        errdefer plan.deinit();
        const self = try a.create(Controller);
        errdefer a.destroy(self);
        var remote_input = input.Service.init(owner);
        self.* = .{ .allocator = a, .config = config, .plan = plan, .owner = owner, .operation = operation, .framebuffer = frames.Service.init(a, owner, budget), .remote_input = remote_input, .manager = undefined, .creator_thread = std.Thread.getCurrentId(), .state = .{ .owner = owner, .operation = operation, .input = try remote_input.snapshot(remote_input.binding()) } };
        self.connection_progress = progress.Tracker.init(@intCast(hops.len));
        try self.manager.initWithPolicy(a, owner, self.config.value.endpoint, journal, facade, if (payload.display.read_only_requested) .read_only else policy);
        return self;
    }
    pub fn start(self: *Controller, identity: profile.Identity, driver: Driver) !void {
        const selected = profile.select(identity) catch |err| {
            self.failed(err);
            return err;
        };
        try selected.validateForProduction();
        try self.spawn(driver);
    }
    /// Start a prepared production backend whose begin performs trust and
    /// profile selection on the worker before requesting any credential.
    /// Configuration/UI callers do not manufacture a fixed device identity.
    pub fn startPrepared(self: *Controller, driver: Driver) !void {
        try self.spawn(driver);
    }
    /// Synthetic IO must be explicit and is unavailable in non-test binaries.
    /// This still invokes the real WS/RFB/frame/input/management implementation.
    pub fn startSynthetic(self: *Controller, selected: profile.Profile, driver: Driver) !void {
        if (!builtin.is_test or !selected.synthetic) return error.SyntheticProfileForbidden;
        try self.spawn(driver);
    }
    fn spawn(self: *Controller, driver: Driver) !void {
        if (self.started or self.cancel_requested.load(.acquire)) return error.ControllerAlreadyStarted;
        self.driver = driver;
        self.started = true;
        const thread = std.Thread.spawn(.{}, run, .{self}) catch |err| {
            self.started = false;
            self.driver = null;
            return err;
        };
        thread.detach();
    }
    pub fn poll(self: *Controller) Snapshot {
        self.lock();
        var state = self.state;
        self.unlock();
        state.input = self.remote_input.snapshot(self.remote_input.binding()) catch state.input;
        if (self.cancel_requested.load(.acquire)) {
            state.rfb_ready = false;
            state.control = .read_only;
            state.control_request = null;
        }
        state.worker_exited = self.worker_exited.load(.acquire);
        state.progress = self.connection_progress.snapshot();
        return state;
    }
    pub fn cancel(self: *Controller) void {
        self.cancel_requested.store(true, .release);
        self.manager.revoke();
        // Revoke submission immediately, even while begin/read/cleanup is
        // blocked. close retains actual held state and priority releases; an
        // unavailable wire must still leave remote_unconfirmed set on stop.
        self.remote_input.close();
        if (self.started) {
            self.connection_progress.setStage(.cleanup);
            self.lock();
            if (self.state.cleanup == .not_started) self.state.cleanup = .awaiting;
            self.unlock();
        }
        if (!self.started) {
            self.lock();
            self.state.cleanup = .released;
            self.state.route = .closed;
            self.state.video = .closed;
            self.state.management = .closed;
            self.unlock();
            self.worker_exited.store(true, .release);
            self.connection_progress.finish(true);
        }
    }
    /// Memory-only destruction after worker cleanup, with frame lease evidence.
    /// An outstanding renderer borrow returns an error without destroying self.
    pub fn deinit(self: *Controller) !void {
        if (self.started and !self.worker_exited.load(.acquire)) return error.ControllerWorkerActive;
        if (self.started and self.poll().cleanup != .released) return error.CleanupIncomplete;
        try self.framebuffer.deinit();
        self.remote_input.close();
        self.manager.deinit();
        self.plan.deinit();
        self.config.deinit();
        const a = self.allocator;
        a.destroy(self);
    }
    pub fn framebufferBinding(self: *Controller) typed.Binding {
        return self.framebuffer.binding();
    }
    pub fn inputBinding(self: *Controller) typed.Binding {
        return self.remote_input.binding();
    }
    pub fn powerBinding(self: *Controller) typed.Binding {
        return self.manager.powerBinding();
    }
    pub fn bootBinding(self: *Controller) typed.Binding {
        return self.manager.bootBinding();
    }
    pub fn requestControl(self: *Controller) !void {
        if (self.config.value.display.read_only_requested) return error.ReadOnlyRequested;
        try self.enqueueControl(.request);
    }
    pub fn replyControl(self: *Controller, context: [4]u8, reply: video.rfb.ControlReply) !void {
        if (self.config.value.display.read_only_requested and reply == .full_control) return error.ReadOnlyRequested;
        try self.enqueueControl(.{ .reply = .{ .context = context, .value = reply } });
    }
    pub fn requestFullRefresh(self: *Controller) !void {
        try self.enqueueControl(.refresh);
    }
    fn enqueueControl(self: *Controller, command: ControlCommand) !void {
        self.lock();
        defer self.unlock();
        if (self.cancel_requested.load(.acquire) or self.state.route != .connected or !self.state.rfb_ready) return error.VideoUnavailable;
        if (self.control_command != null) return error.ControlQueueFull;
        self.control_command = .{ .generation = self.state.transport_generation, .value = command };
    }
    fn run(self: *Controller) void {
        // The main thread neither joins this detached worker nor owns its IO.
        std.debug.assert(std.Thread.getCurrentId() != self.creator_thread);
        const driver = self.driver.?;
        self.work(driver) catch |err| {
            // Closing input can race a decoded grant or a pending send. Those
            // old operations cannot turn an intentional close into a failure.
            self.failed(if (self.cancel_requested.load(.acquire)) error.Cancelled else err);
        };
        if (self.pipeline) |*pipeline| {
            pipeline.deinit();
            self.pipeline = null;
        }
        self.remote_input.close();
        self.manager.close();
        self.connection_progress.setStage(.cleanup);
        driver.abort(driver.context);
        self.lock();
        self.state.cleanup = .awaiting;
        self.unlock();
        while (true) {
            const receipt = driver.cleanup(driver.context);
            self.lock();
            self.state.cleanup = if (receipt == .released) .awaiting else receipt;
            self.unlock();
            if (receipt == .released) break;
            driver.wait(driver.context, 10);
        }
        while (true) {
            self.framebuffer.close() catch |err| {
                if (err == error.FrameBorrowed) {
                    driver.wait(driver.context, 10);
                    continue;
                }
                self.failed(err);
            };
            break;
        }
        self.lock();
        self.state.cleanup = .released;
        self.state.route = .closed;
        self.state.rfb_ready = false;
        self.state.control = .read_only;
        self.state.control_request = null;
        if (self.state.video != .failed) self.state.video = .closed;
        self.state.management = .closed;
        self.unlock();
        self.connection_progress.finish(self.cancel_requested.load(.acquire));
        self.worker_exited.store(true, .release);
    }
    fn work(self: *Controller, driver: Driver) !void {
        if (self.cancel_requested.load(.acquire)) return;
        self.lock();
        self.state.route = .connecting;
        self.state.video = .authenticating;
        self.state.management = .authenticating;
        self.unlock();
        self.connection_progress.setStage(.route);
        const authenticated = try driver.begin(driver.context, &self.config.value, &self.plan, self.operation, &self.cancel_requested);
        // A successful but stale begin still owns resources; run always cleans
        // those up without publishing availability or feeding a late frame.
        if (self.cancel_requested.load(.acquire)) return;
        self.connection_progress.setStage(.rfb_negotiation);
        self.pipeline = try video.Pipeline.init(self.allocator, self.owner, 1, &self.framebuffer, &self.remote_input, self.framebuffer.budget);
        self.pipeline.?.read_only_requested = self.config.value.display.read_only_requested;
        try self.pipeline.?.start(authenticated);
        self.lock();
        self.state.route = .connected;
        self.state.video = .negotiating;
        self.state.management = if (authenticated.web_authenticated and (if (driver.management_available) |available| available(driver.context) else true)) .available else .unavailable;
        self.unlock();
        var bytes: [16 * 1024]u8 = undefined;
        var performance: Performance = .{};
        var active_turns: usize = 0;
        const wire: video.Wire = .{ .context = driver.context, .write = driver.write, .abort = driver.abort };
        while (!self.cancel_requested.load(.acquire)) {
            const written_before = self.pipeline.?.written_bytes;
            // Input need not wait behind the next video record or management
            // read. Each feed remains bounded to one 16KiB transport chunk.
            try self.pipeline.?.pump(wire);
            const now = driver.now_ns(driver.context);
            performance.read_calls += 1;
            const read_count: ?usize = driver.read(driver.context, &bytes) catch |err| switch (err) {
                error.WouldBlock => blk: {
                    performance.read_would_block += 1;
                    break :blk null;
                },
                else => return err,
            };
            if (read_count) |n| {
                if (n == 0) return error.VideoClosed;
                if (n > bytes.len) return error.InvalidVideoRead;
                performance.read_bytes += n;
                performance.last_read_ns = now;
                const published_before = self.pipeline.?.published_frames;
                const feed_start = driver.now_ns(driver.context);
                _ = try self.pipeline.?.feed(bytes[0..n], now);
                const feed_end = driver.now_ns(driver.context);
                const feed_ns = feed_end -| feed_start;
                performance.feed_ns += feed_ns;
                performance.max_feed_ns = @max(performance.max_feed_ns, feed_ns);
                if (self.pipeline.?.published_frames != published_before) performance.last_published_ns = feed_end;
            }
            self.pipeline.?.expireControlRequest(now);
            self.lock();
            const control = self.control_command;
            self.control_command = null;
            self.unlock();
            // The UI snapshot can become stale after enqueue. Only the worker
            // checks the live decoder and transport before consuming commands.
            if (control) |queued| if (queued.generation == self.pipeline.?.generation and decoderReady(self.pipeline.?.decoder.phase)) switch (queued.value) {
                .request => try self.pipeline.?.requestControl(),
                .reply => |reply| self.pipeline.?.replyControl(reply.context, reply.value) catch |err| switch (err) {
                    error.NoControlRequest, error.StaleControlRequest => {},
                    else => return err,
                },
                .refresh => try self.pipeline.?.requestFullRefresh(),
            };
            try self.pipeline.?.pump(wire);
            if (driver.management_io) |io| {
                // Adapter retains the HTTP slot after logical cancellation:
                // null keeps draining it, and only its exact late completion is
                // retired without changing unknown. Other errors still fail.
                const outbound = try self.manager.next(now / std.time.ns_per_ms);
                if (try io(driver.context, outbound)) |completion| try self.manager.complete(completion, now / std.time.ns_per_ms);
            } else try self.manager.tick(now / std.time.ns_per_ms);
            performance.written_bytes = self.pipeline.?.written_bytes;
            const progressed = read_count != null or performance.written_bytes != written_before;
            const yield_active = progressed and active_turns + 1 == 16;
            if (progressed) {
                active_turns = if (yield_active) 0 else active_turns + 1;
                if (yield_active) performance.active_yields += 1;
            } else {
                active_turns = 0;
                performance.idle_waits += 1;
                performance.idle_wait_ms += 2;
            }
            self.lock();
            if (driver.management_available) |available| self.state.management = if (available(driver.context)) .available else .unavailable;
            self.state.published_frames = self.pipeline.?.published_frames;
            self.state.control_request = self.pipeline.?.control_request;
            self.state.control = self.pipeline.?.decoder.control_state;
            self.state.rfb_ready = decoderReady(self.pipeline.?.decoder.phase);
            self.state.performance = performance;
            self.state.video = if (self.state.published_frames != 0) .streaming else if (self.state.rfb_ready) .awaiting_frame else .negotiating;
            const connection_stage: progress.Stage = switch (self.state.video) {
                .streaming => .streaming,
                .awaiting_frame => .awaiting_first_frame,
                else => .rfb_negotiation,
            };
            self.unlock();
            self.connection_progress.setStage(connection_stage);
            // Drain ready TLS records without a sleep per record. Yield after
            // 256KiB of productive turns; only a fully idle turn backs off.
            if (yield_active) std.Thread.yield() catch {};
            if (!progressed) driver.wait(driver.context, 2);
        }
    }
    fn failed(self: *Controller, err: anyerror) void {
        self.connection_progress.fail(err);
        self.lock();
        self.state.rfb_ready = false;
        self.state.control = .read_only;
        self.state.control_request = null;
        if (err == error.Cancelled) {
            if (self.state.failure == null) {
                self.state.video = .closed;
                if (self.state.route != .connected) self.state.route = .closed;
            }
        } else {
            self.state.failure = err;
            self.state.video = .failed;
            if (self.state.route != .connected) self.state.route = .failed;
        }
        self.unlock();
    }
    fn decoderReady(phase: video.rfb.Phase) bool {
        return switch (phase) {
            .normal, .rectangle_header, .raw_pixels, .tight_pixels, .copy_rect, .cursor => true,
            else => false,
        };
    }
    fn lock(self: *Controller) void {
        while (self.mutex.swap(true, .acquire)) std.atomic.spinLoopHint();
    }
    fn unlock(self: *Controller) void {
        self.mutex.store(false, .release);
    }
};
