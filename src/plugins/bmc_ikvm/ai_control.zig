//! Typed AI observation/input seam for the existing KVM runtime. Images come
//! only from immutable remote CPU FrameLeases; this service has no second
//! connection, credentials, local-window capture or provider upload capability.
const std = @import("std");
const typed = @import("../../host/plugin_services.zig");
const identity = @import("../../host/identity.zig");
const frames = @import("framebuffer.zig");
const remote = @import("remote_input.zig");
pub const automation = @import("automation_input.zig");
pub const image = @import("observation_image.zig");
const images = @import("../../ai/image_attachments.zig");

pub const key: typed.ServiceKey = .{ .name = "bmc_ikvm.ai_control", .major = 1 };
pub const Region = image.Region;
pub const Point = image.Point;
pub const Transform = image.Transform;
pub const max_observation_age_ms: u32 = 15_000;
pub const ScreenshotRequest = struct {
    region: ?Region = null,
    max_width: u32 = image.max_width,
    max_height: u32 = image.max_height,
    /// A caller can request a shorter validity period, never extend the bound.
    max_age_ms: u32 = max_observation_age_ms,
};
pub const Observation = struct {
    id: u64,
    owner: identity.SessionHandle,
    binding_generation: u64,
    frame_generation: u64,
    sequence: u64,
    captured_monotonic_ms: u64,
    frame_received_monotonic_ns: u64,
    valid_until_monotonic_ms: u64,
    transport_generation: u64,
    control_generation: u64,
    input_epoch: u64,
    original_width: u32,
    original_height: u32,
    output_width: u32,
    output_height: u32,
    transform: Transform,
    image_ref: images.ContentRef = .{},

    /// Only the returned value owns pixels. The service keeps bounded metadata,
    /// so completed/expired observations do not retain image history silently.
    pub fn deinit(self: *Observation) void {
        self.image_ref.release();
    }
};
pub const PointerAction = union(enum) {
    move: Point,
    click: struct { point: Point, button: automation.Button = .left, count: u8 = 1 },
    drag: struct { points: [32]Point = @splat(.{ .x = 0, .y = 0 }), count: u8, button: automation.Button = .left },
    wheel: struct { point: Point, steps_x: i8 = 0, steps_y: i8 = 0 },
};
pub const KeyboardAction = union(enum) { key: u32, chord: automation.Chord, text: automation.Text };
pub const PointerRequest = struct { observation_id: u64, operation_id: u64, proof: automation.Proof, action: PointerAction };
pub const KeyboardRequest = struct { observation_id: u64, operation_id: u64, proof: automation.Proof, action: KeyboardAction };
pub const Receipt = automation.Receipt;
pub const Interface = struct {
    screenshot: *const fn (*anyopaque, typed.Binding, std.mem.Allocator, ScreenshotRequest) anyerror!Observation,
    pointer: *const fn (*anyopaque, typed.Binding, PointerRequest) anyerror!Receipt,
    keyboard: *const fn (*anyopaque, typed.Binding, KeyboardRequest) anyerror!Receipt,
    operation_status: *const fn (*anyopaque, typed.Binding, u64) anyerror!Receipt,
    /// Host stop/takeover is always callable; it is not another model tool.
    stop: *const fn (*anyopaque, typed.Binding) anyerror!void,
};
pub const definition = typed.Definition.of(Interface, key);
pub const Clock = struct {
    context: ?*anyopaque = null,
    milliseconds: *const fn (?*anyopaque) u64 = monotonicMs,
};
pub const Refresh = struct { context: *anyopaque, request: *const fn (*anyopaque) anyerror!void };
pub const Stop = struct { context: *anyopaque, revoke_lease: *const fn (*anyopaque) void };

/// Main-thread owned, like Runtime and tool dispatch. Framebuffer/remote_input
/// independently lock their shared worker state. Encoding is synchronous and
/// deliberately capped at 1920×1200 until a host worker result lease is added.
pub const Service = struct {
    pub const observation_capacity = 32;
    const InputState = struct { transport_generation: u64, control_generation: u64, connected: bool, controlled: bool };
    owner: identity.SessionHandle,
    framebuffer: *frames.Service,
    input: *remote.Service,
    clock: Clock = .{},
    refresh: ?Refresh = null,
    on_stop: ?Stop = null,
    last_input_state: ?InputState = null,
    observations: [observation_capacity]?Observation = @splat(null),
    next_observation: u64 = 1,
    next_slot: usize = 0,
    last_operation_id: u64 = 0,
    last_action_observation_id: u64 = 0,
    refresh_fence_operation_id: u64 = 0,
    refresh_fence_sequence: u64 = 0,
    closed: bool = false,

    pub fn init(owner: identity.SessionHandle, framebuffer: *frames.Service, input: *remote.Service) Service {
        return .{ .owner = owner, .framebuffer = framebuffer, .input = input };
    }
    pub fn binding(self: *Service) typed.Binding {
        return typed.Binding.init(Interface, key, self, &vtable, self.owner, 1);
    }
    pub fn screenshot(self: *Service, binding_value: typed.Binding, a: std.mem.Allocator, request: ScreenshotRequest) !Observation {
        try self.validate(binding_value);
        _ = try self.poll();
        const last_receipt = if (self.last_operation_id != 0) try self.input.automationStatus(self.input.binding(), self.last_operation_id) else null;
        if (last_receipt) |receipt| if (receipt.status == .accepted) return error.OperationPending;
        if (request.max_age_ms == 0 or request.max_age_ms > max_observation_age_ms) return error.InvalidObservationAge;
        if (self.next_observation == std.math.maxInt(u64)) return error.ObservationIdentityExhausted;
        var input = try self.input.snapshot(self.input.binding());
        if (self.syncInput(input)) input = try self.input.snapshot(self.input.binding());
        if (input.geometry_pending) return error.FrameGeometryPending;
        var lease = switch (self.framebuffer.acquireLatest(self.framebuffer.binding(), 0)) {
            .frame => |value| value,
            .stale_binding => return error.StaleBinding,
            .unchanged => return error.FrameUnavailable,
            .unavailable => |reason| return switch (reason) {
                .awaiting_frame => error.FrameUnavailable,
                .closed => error.OwnerClosed,
                .lease_limit => error.FrameLeaseLimit,
            },
        };
        defer lease.release();
        const snapshot = lease.snapshot;
        if (!snapshot.session_handle.eql(self.owner)) return error.StaleFrame;
        if (input.geometry_generation != 0 and snapshot.frame_generation != input.geometry_generation) return error.FrameGeometryPending;
        const mapping = try image.transform(snapshot.width, snapshot.height, request.region, request.max_width, request.max_height);
        if (last_receipt) |receipt| {
            if (needsPostActionFrame(receipt)) {
                if (self.refresh_fence_operation_id != receipt.operation_id) return error.PostActionFramePending;
                if (snapshot.sequence <= self.refresh_fence_sequence or (receipt.sent_monotonic_ns != 0 and snapshot.received_monotonic_ns < receipt.sent_monotonic_ns)) return error.PostActionFramePending;
            }
        }
        const now = self.clock.milliseconds(self.clock.context);
        const reference = try image.capture(a, snapshot, mapping, now);
        var result: Observation = .{
            .id = self.next_observation,
            .owner = self.owner,
            .binding_generation = binding_value.generation,
            .frame_generation = snapshot.frame_generation,
            .sequence = snapshot.sequence,
            .captured_monotonic_ms = now,
            .frame_received_monotonic_ns = snapshot.received_monotonic_ns,
            .valid_until_monotonic_ms = std.math.add(u64, now, request.max_age_ms) catch {
                var discarded = reference;
                discarded.release();
                return error.InvalidCaptureTime;
            },
            .transport_generation = input.transport_generation,
            .control_generation = input.control_generation,
            .input_epoch = input.input_epoch,
            .original_width = snapshot.width,
            .original_height = snapshot.height,
            .output_width = mapping.output_width,
            .output_height = mapping.output_height,
            .transform = mapping,
            .image_ref = reference,
        };
        // Encoding cannot make old pixels describe a transport, control or
        // announced geometry that changed while the image was being copied.
        const current = self.input.snapshot(self.input.binding()) catch |err| {
            result.deinit();
            return err;
        };
        if (current.geometry_pending or input.geometry_generation != current.geometry_generation) {
            result.deinit();
            return error.FrameGeometryPending;
        }
        if (input.transport_generation != current.transport_generation or input.control_generation != current.control_generation or input.input_epoch != current.input_epoch) {
            result.deinit();
            return error.ObservationInvalidated;
        }
        var metadata = result;
        metadata.image_ref = .{};
        self.observations[self.next_slot] = metadata;
        self.next_slot = (self.next_slot + 1) % observation_capacity;
        self.next_observation += 1;
        return result;
    }
    pub fn pointer(self: *Service, binding_value: typed.Binding, request: PointerRequest) !Receipt {
        const authority = try self.validateObservation(binding_value, request.observation_id, request.proof);
        try self.requireFreshObservation(request.observation_id, request.operation_id);
        const observation = self.find(request.observation_id).?;
        const action = try mapPointer(observation.transform, request.action);
        const receipt = try self.input.submitAutomation(self.input.binding(), authority, .{ .operation_id = request.operation_id, .action = action });
        self.recordAction(request.observation_id, request.operation_id);
        return receipt;
    }
    pub fn keyboard(self: *Service, binding_value: typed.Binding, request: KeyboardRequest) !Receipt {
        const authority = try self.validateObservation(binding_value, request.observation_id, request.proof);
        try self.requireFreshObservation(request.observation_id, request.operation_id);
        const action: automation.Action = switch (request.action) {
            .key => |value| .{ .key = value },
            .chord => |value| .{ .chord = value },
            .text => |value| .{ .text = value },
        };
        const receipt = try self.input.submitAutomation(self.input.binding(), authority, .{ .operation_id = request.operation_id, .action = action });
        self.recordAction(request.observation_id, request.operation_id);
        return receipt;
    }
    pub fn operationStatus(self: *Service, binding_value: typed.Binding, operation_id: u64) !Receipt {
        try self.validate(binding_value);
        _ = try self.poll();
        return self.input.automationStatus(self.input.binding(), operation_id);
    }
    /// Runtime polls this on its owner thread. Calls also synchronize before
    /// capturing/dispatching, closing the gap between two main-loop polls.
    pub fn poll(self: *Service) !bool {
        if (self.closed) return false;
        var changed = self.syncInput(try self.input.snapshot(self.input.binding()));
        if (self.last_operation_id != 0 and self.refresh_fence_operation_id != self.last_operation_id) {
            const receipt = try self.input.automationStatus(self.input.binding(), self.last_operation_id);
            if (needsPostActionFrame(receipt)) changed = (try self.armPostActionRefresh(receipt.operation_id)) or changed;
        }
        return changed;
    }
    fn needsPostActionFrame(receipt: Receipt) bool {
        return receipt.status == .sent or (receipt.status == .outcome_unknown and (receipt.sent_events != 0 or receipt.possibly_written));
    }
    fn armPostActionRefresh(self: *Service, operation_id: u64) !bool {
        // Runtime polling starts the refresh as soon as the worker reports a
        // terminal write. Waiting for the next approved screenshot to do this
        // would make that screenshot fail even if a newer frame already exists.
        // This queues work only; IO and decoding remain on the existing worker.
        var lease = switch (self.framebuffer.acquireLatest(self.framebuffer.binding(), 0)) {
            .frame => |value| value,
            else => return false,
        };
        const sequence = lease.snapshot.sequence;
        lease.release();
        if (self.refresh) |refresh| refresh.request(refresh.context) catch |err| switch (err) {
            // A control command or reconnect can temporarily own the worker
            // slot. Keep the fence unarmed so the next poll retries safely.
            error.ControlQueueFull, error.VideoUnavailable => return false,
            else => return err,
        };
        self.refresh_fence_operation_id = operation_id;
        self.refresh_fence_sequence = sequence;
        return true;
    }
    fn syncInput(self: *Service, input: remote.Snapshot) bool {
        const current: InputState = .{ .transport_generation = input.transport_generation, .control_generation = input.control_generation, .connected = input.connected, .controlled = input.controlled };
        const previous = self.last_input_state;
        self.last_input_state = current;
        if (previous) |prior| if (!std.meta.eql(prior, current)) {
            // A fresh image alone cannot resume a Task's previous host grant
            // after reconnect or a new BMC control grant. Resume needs a new
            // real ContentContext lease as well as a fresh observation.
            if (self.on_stop) |callback| callback.revoke_lease(callback.context);
            return true;
        };
        return false;
    }
    pub fn stop(self: *Service, binding_value: typed.Binding) !void {
        try self.validate(binding_value);
        if (self.on_stop) |callback| callback.revoke_lease(callback.context);
        self.invalidate();
        self.input.revokeAutomation(.takeover);
    }
    pub fn close(self: *Service) void {
        if (self.closed) return;
        if (self.on_stop) |callback| callback.revoke_lease(callback.context);
        self.invalidate();
        self.closed = true;
        self.input.revokeAutomation(.closed);
    }
    fn invalidate(self: *Service) void {
        self.observations = @splat(null);
    }
    fn find(self: *Service, id: u64) ?Observation {
        for (self.observations) |slot| if (slot) |observation| if (observation.id == id) return observation;
        return null;
    }
    fn requireFreshObservation(self: *Service, observation_id: u64, operation_id: u64) !void {
        if (operation_id != self.last_operation_id and observation_id <= self.last_action_observation_id) return error.FreshObservationRequired;
    }
    fn recordAction(self: *Service, observation_id: u64, operation_id: u64) void {
        if (operation_id <= self.last_operation_id) return;
        self.last_operation_id = operation_id;
        self.last_action_observation_id = observation_id;
    }
    fn validateObservation(self: *Service, binding_value: typed.Binding, id: u64, proof: automation.Proof) !automation.Authority {
        try self.validate(binding_value);
        _ = try self.poll();
        const observation = self.find(id) orelse return error.ObservationNotFound;
        const now = self.clock.milliseconds(self.clock.context);
        if (now < observation.captured_monotonic_ms or now >= observation.valid_until_monotonic_ms) return error.ObservationExpired;
        const input = try self.input.snapshot(self.input.binding());
        if (!input.connected or !input.controlled) return error.RemoteInputUnavailable;
        if (input.geometry_pending) return error.FrameGeometryPending;
        if (input.geometry_generation != 0 and observation.frame_generation != input.geometry_generation) return error.ObservationInvalidated;
        if (observation.binding_generation != binding_value.generation or observation.transport_generation != input.transport_generation or observation.control_generation != input.control_generation or observation.input_epoch != input.input_epoch) return error.ObservationInvalidated;
        var lease = switch (self.framebuffer.acquireLatest(self.framebuffer.binding(), 0)) {
            .frame => |value| value,
            else => return error.FrameUnavailable,
        };
        defer lease.release();
        const frame = lease.snapshot;
        // Frame sequence deliberately does not participate: the remote screen
        // may update while a bounded action on this observation is prepared.
        if (!frame.session_handle.eql(observation.owner) or frame.frame_generation != observation.frame_generation or frame.width != observation.original_width or frame.height != observation.original_height) return error.ObservationInvalidated;
        return .{ .owner = self.owner, .binding_generation = binding_value.generation, .transport_generation = input.transport_generation, .control_generation = input.control_generation, .input_epoch = input.input_epoch, .geometry_generation = input.geometry_generation, .expires_at_ms = observation.valid_until_monotonic_ms, .proof = proof };
    }
    fn validate(self: *Service, binding_value: typed.Binding) !void {
        _ = try binding_value.borrow(Interface, key, self.owner);
        if (binding_value.context != @as(*anyopaque, @ptrCast(self)) or binding_value.vtable != @as(*const anyopaque, &vtable)) return error.StaleBinding;
        if (self.closed) return error.OwnerClosed;
    }
    const vtable: Interface = .{ .screenshot = screenshotFrom, .pointer = pointerFrom, .keyboard = keyboardFrom, .operation_status = statusFrom, .stop = stopFrom };
    fn from(raw: *anyopaque) *Service {
        return @ptrCast(@alignCast(raw));
    }
    fn screenshotFrom(raw: *anyopaque, binding_value: typed.Binding, a: std.mem.Allocator, request: ScreenshotRequest) !Observation {
        return from(raw).screenshot(binding_value, a, request);
    }
    fn pointerFrom(raw: *anyopaque, binding_value: typed.Binding, request: PointerRequest) !Receipt {
        return from(raw).pointer(binding_value, request);
    }
    fn keyboardFrom(raw: *anyopaque, binding_value: typed.Binding, request: KeyboardRequest) !Receipt {
        return from(raw).keyboard(binding_value, request);
    }
    fn statusFrom(raw: *anyopaque, binding_value: typed.Binding, operation_id: u64) !Receipt {
        return from(raw).operationStatus(binding_value, operation_id);
    }
    fn stopFrom(raw: *anyopaque, binding_value: typed.Binding) !void {
        return from(raw).stop(binding_value);
    }
};

pub fn mapPointer(mapping: Transform, action: PointerAction) !automation.Action {
    return switch (action) {
        .move => |point| .{ .pointer_move = try remotePoint(mapping, point) },
        .click => |value| .{ .click = .{ .point = try remotePoint(mapping, value.point), .button = value.button, .count = value.count } },
        .wheel => |value| .{ .wheel = .{ .point = try remotePoint(mapping, value.point), .steps_x = value.steps_x, .steps_y = value.steps_y } },
        .drag => |value| blk: {
            if (value.count < 2 or value.count > value.points.len) return error.InvalidDrag;
            var drag: automation.Drag = .{ .count = value.count, .button = value.button };
            for (value.points[0..value.count], drag.points[0..value.count]) |point, *destination| destination.* = try remotePoint(mapping, point);
            break :blk .{ .drag = drag };
        },
    };
}
fn remotePoint(mapping: Transform, point: Point) !automation.Point {
    const result = try mapping.remote(point);
    return .{ .x = result.x, .y = result.y };
}
fn monotonicMs(_: ?*anyopaque) u64 {
    var ts: std.c.timespec = undefined;
    if (std.c.clock_gettime(.MONOTONIC, &ts) != 0) return 0;
    return @as(u64, @intCast(ts.sec)) * 1000 + @as(u64, @intCast(ts.nsec)) / 1_000_000;
}
