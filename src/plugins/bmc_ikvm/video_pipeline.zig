//! Worker-owned WebSocket/RFB composition. Keep this object at a stable address.
//! Parser event slices are consumed synchronously; only complete RGBA is copied
//! into the shared framebuffer. Exactly one worker calls every method here.
const std = @import("std");
pub const ws = @import("protocol/websocket.zig");
pub const rfb = @import("protocol/rfb_parser.zig");
const frames = @import("framebuffer.zig");
const input = @import("remote_input.zig");
const budgets = @import("../../host/frame_budget.zig");
const identity = @import("../../host/identity.zig");

pub const Wire = struct {
    context: *anyopaque,
    write: *const fn (*anyopaque, []const u8) anyerror!usize,
    abort: *const fn (*anyopaque) void,
};
pub const Pipeline = struct {
    const Output = struct { bytes: []u8, offset: usize = 0 };
    const Charge = struct { reservation: budgets.Reservation, remaining: usize };
    const InputOutput = struct {
        output: Output,
        raw: [8]u8,
        length: usize,
        authority: input.WriteAuthority,
    };
    allocator: std.mem.Allocator,
    owner: identity.SessionHandle,
    generation: u64,
    framebuffer: *frames.Service,
    remote_input: *input.Service,
    budget: *budgets.Budget,
    decoder: rfb.Decoder,
    websocket: ws.Parser = .{},
    output: [64]?Output = @splat(null),
    head: usize = 0,
    count: usize = 0,
    output_bytes: usize = 0,
    input_output: ?InputOutput = null,
    charges: [8]?Charge = @splat(null),
    staging: ?budgets.Reservation = null,
    decode_scratch: ?budgets.Reservation = null,
    wire: ?Wire = null,
    received_ns: u64 = 0,
    decoder_generation: u64 = 0,
    published_frames: u64 = 0,
    skipped_frames: u64 = 0,
    control_request: ?[4]u8 = null,
    control_request_deadline_ns: ?u64 = null,
    closed: bool = false,
    ready: bool = false,
    read_only_requested: bool = false,
    needs_generation_barrier: bool = false,
    pub const max_output_bytes = 64 * 1024;

    pub fn init(a: std.mem.Allocator, owner: identity.SessionHandle, generation: u64, framebuffer: *frames.Service, remote_input: *input.Service, budget: *budgets.Budget) !Pipeline {
        if (generation == 0 or !owner.eql(framebuffer.owner) or !owner.eql(remote_input.owner)) return error.InvalidVideoOwner;
        return .{ .allocator = a, .owner = owner, .generation = generation, .framebuffer = framebuffer, .remote_input = remote_input, .budget = budget, .needs_generation_barrier = framebuffer.frame_generation != 0, .decoder = try rfb.Decoder.init(a, .{ .max_buffered_bytes = 8 * 1024 * 1024, .max_decode_bytes = budgets.kvm_frame_bytes }) };
    }
    /// Must be called after init at the final address. Auth is evidence supplied
    /// by the worker after trusted TLS, separate WEB/KVM login and WS upgrade.
    pub fn start(self: *Pipeline, authenticated: rfb.Authenticated) !void {
        if (self.closed or self.ready) return error.InvalidVideoState;
        self.staging = try self.budget.reserve(self.owner, self.decoder.limits.max_buffered_bytes + max_output_bytes + 16 * 1024, .transport);
        errdefer {
            self.staging.?.release();
            self.staging = null;
        }
        // Enough for a maximum-size JPEG RGBA temporary, or RGB/gradient rows
        // plus the four bounded zlib stream windows. It is reserved up front so
        // a legitimate large Tight rectangle cannot bypass global accounting.
        self.decode_scratch = try self.budget.reserve(self.owner, self.decoder.limits.max_decode_bytes + 512 * 1024, .decode);
        errdefer {
            self.decode_scratch.?.release();
            self.decode_scratch = null;
        }
        self.decoder.limits.memory_budget = .{ .context = self, .reserve = reserve, .release = release };
        try self.decoder.websocketReady(authenticated);
        try self.remote_input.setConnected(true, self.generation);
        try self.remote_input.beginGeometryChange(self.generation);
        self.ready = true;
        _ = try self.drain();
    }
    pub fn deinit(self: *Pipeline) void {
        self.stop();
        self.decoder.deinit();
        for (&self.charges) |*charge| if (charge.*) |*value| {
            value.reservation.release();
            charge.* = null;
        };
        if (self.staging) |*value| value.release();
        if (self.decode_scratch) |*value| value.release();
        self.* = undefined;
    }
    pub fn stop(self: *Pipeline) void {
        if (self.closed) return;
        self.closed = true;
        self.control_request = null;
        self.control_request_deadline_ns = null;
        self.decoder.expireControlRequest();
        _ = self.remote_input.releaseAll(self.remote_input.binding(), .disconnected);
        self.remote_input.setConnected(false, self.generation) catch {};
        if (self.input_output) |value| self.allocator.free(value.output.bytes);
        self.input_output = null;
        for (&self.output) |*slot| if (slot.*) |value| {
            self.allocator.free(value.bytes);
            slot.* = null;
        };
        self.count = 0;
        self.output_bytes = 0;
    }
    pub fn feed(self: *Pipeline, bytes: []const u8, received_ns: u64) !usize {
        if (!self.ready or self.closed) return error.VideoUnavailable;
        self.received_ns = received_ns;
        return self.websocket.feed(bytes, self) catch |err| {
            self.abort();
            return err;
        };
    }
    pub fn onEvent(self: *Pipeline, event: ws.Event) !void {
        switch (event) {
            .binary => |bytes| {
                var offset: usize = 0;
                while (offset < bytes.len) {
                    const accepted = try self.decoder.feed(bytes[offset..]);
                    const events = try self.drain();
                    offset += accepted;
                    if (accepted == 0 and events == 0) return error.DecoderStalled;
                }
                // Bounded decoder yields need another empty feed, even when
                // all transport bytes were accepted on the preceding call.
                while (true) {
                    const before = self.decoder.bufferedBytes();
                    _ = try self.decoder.feed(&.{});
                    const events = try self.drain();
                    if (events == 0 and before == self.decoder.bufferedBytes()) break;
                }
            },
            .ping => |bytes| try self.enqueue(.pong, bytes),
            .pong => {},
            .close => self.abort(),
        }
    }
    fn drain(self: *Pipeline) !usize {
        var count: usize = 0;
        while (self.decoder.nextEvent()) |value| {
            var event = value;
            defer event.deinit(self.allocator);
            count += 1;
            switch (event) {
                .outbound => |bytes| try self.enqueue(.binary, bytes),
                .control => |control| {
                    // Revoke the input epoch before exposing the OEM state.
                    if (control.state != .major) _ = self.remote_input.releaseAll(self.remote_input.binding(), .control_revoked);
                    const current = try self.remote_input.snapshot(self.remote_input.binding());
                    try self.remote_input.setControl(control.state == .major and !self.read_only_requested, try identity.advance(current.control_generation));
                },
                .control_request => |request| {
                    self.control_request = request;
                    self.control_request_deadline_ns = self.received_ns +| 30 * std.time.ns_per_s;
                },
                .resize => |size| {
                    // Invalidate observed coordinates as soon as the decoder
                    // learns of a resize, before a new complete frame exists.
                    try self.remote_input.beginGeometryChange(self.generation);
                    self.decoder_generation = size.generation;
                    self.needs_generation_barrier = self.framebuffer.frame_generation != 0;
                    // Geometry is published atomically with the first complete
                    // frame, never as an incomplete framebuffer snapshot.
                },
                .frame_complete => |frame| {
                    if (frame.generation != self.decoder_generation) return error.StaleFrame;
                    if (self.needs_generation_barrier and frame.width == self.framebuffer.width and frame.height == self.framebuffer.height) {
                        _ = self.framebuffer.advanceGeneration() catch |err| switch (err) {
                            error.FrameBorrowed => {
                                self.skipped_frames += 1;
                                continue;
                            },
                            else => return err,
                        };
                    }
                    _ = self.framebuffer.publishComplete(frame.width, frame.height, frame.pixels, self.received_ns) catch |err| switch (err) {
                        error.FrameBorrowed => {
                            self.skipped_frames += 1;
                            continue;
                        },
                        else => return err,
                    };
                    self.needs_generation_barrier = false;
                    try self.remote_input.completeGeometryChange(self.generation, self.framebuffer.frame_generation);
                    self.published_frames += 1;
                },
                else => {},
            }
        }
        return count;
    }
    pub fn requestControl(self: *Pipeline) !void {
        try self.decoder.requestControl();
        _ = try self.drain();
    }
    pub fn replyControl(self: *Pipeline, context: [4]u8, reply: rfb.ControlReply) !void {
        try self.decoder.replyControl(context, reply);
        self.control_request = null;
        self.control_request_deadline_ns = null;
        _ = try self.drain();
    }
    /// Expiry only retires the local prompt. The server owns the final grant
    /// or rejection; no automatic OEM reply or control-state change is sent.
    pub fn expireControlRequest(self: *Pipeline, now_ns: u64) void {
        const deadline = self.control_request_deadline_ns orelse return;
        if (now_ns < deadline) return;
        self.decoder.expireControlRequest();
        self.control_request = null;
        self.control_request_deadline_ns = null;
    }
    pub fn requestFullRefresh(self: *Pipeline) !void {
        try self.decoder.requestFullRefresh();
    }
    fn enqueue(self: *Pipeline, opcode: ws.Opcode, payload: []const u8) !void {
        if (self.count == self.output.len or payload.len + 14 > max_output_bytes - self.output_bytes) return error.VideoOutputBackpressure;
        const bytes = try ws.clientFrame(self.allocator, opcode, true, payload);
        self.output[(self.head + self.count) % self.output.len] = .{ .bytes = bytes };
        self.count += 1;
        self.output_bytes += bytes.len;
    }
    /// TLS writes remain in WS-frame order. Input is acknowledged to its sender
    /// only after its complete masked WS frame is written. A pending input WS
    /// prefix is additionally guarded here because the inner RFB sender has not
    /// yet acknowledged that prefix and cannot detect its revocation itself.
    pub fn pump(self: *Pipeline, wire: Wire) !void {
        if (self.closed) return error.VideoUnavailable;
        self.wire = wire;
        defer self.wire = null;
        if (self.input_output) |value| {
            const state = try self.remote_input.snapshot(self.remote_input.binding());
            if (!self.inputAuthorityValid(value.authority, state)) {
                self.allocator.free(value.output.bytes);
                self.input_output = null;
                if (value.output.offset != 0) {
                    self.abort();
                    return error.InputWriteInterrupted;
                }
            }
        }
        if (self.input_output == null) {
            var turns: usize = 0;
            while (self.count != 0 and turns < 64) : (turns += 1) {
                const output = &self.output[self.head].?;
                const n = wire.write(wire.context, output.bytes[output.offset..]) catch |err| {
                    if (err == error.WouldBlock) return;
                    self.abort();
                    return err;
                };
                if (n > output.bytes.len - output.offset) {
                    self.abort();
                    return error.InvalidVideoWrite;
                }
                output.offset += n;
                if (output.offset != output.bytes.len) return;
                self.output_bytes -= output.bytes.len;
                self.allocator.free(output.bytes);
                self.output[self.head] = null;
                self.head = (self.head + 1) % self.output.len;
                self.count -= 1;
            }
        }
        if (self.count == 0 or self.input_output != null) _ = try self.remote_input.pump(.{ .context = self, .generation = self.generation, .write = inputWrite, .abort = inputAbort, .write_with_authority = inputWriteAuthorized });
    }
    fn inputWrite(raw_context: *anyopaque, raw_bytes: []const u8) !usize {
        // Retain the original callback for ordinary-input Wire compatibility.
        // Production uses inputWriteAuthorized with the sender's exact lane.
        const self: *Pipeline = @ptrCast(@alignCast(raw_context));
        const state = try self.remote_input.snapshot(self.remote_input.binding());
        return inputWriteAuthorized(raw_context, raw_bytes, .{ .input_epoch = state.input_epoch, .control_generation = state.control_generation, .transport_generation = self.generation });
    }
    fn inputWriteAuthorized(raw_context: *anyopaque, raw_bytes: []const u8, authority: input.WriteAuthority) !usize {
        const self: *Pipeline = @ptrCast(@alignCast(raw_context));
        if (raw_bytes.len > 8 or raw_bytes.len == 0) return error.InvalidInputPacket;
        const state = try self.remote_input.snapshot(self.remote_input.binding());
        if (!self.inputAuthorityValid(authority, state)) {
            self.abort();
            return error.InputWriteInterrupted;
        }
        if (self.input_output == null) {
            var value: InputOutput = .{ .output = .{ .bytes = try ws.clientFrame(self.allocator, .binary, true, raw_bytes) }, .raw = @splat(0), .length = raw_bytes.len, .authority = authority };
            @memcpy(value.raw[0..raw_bytes.len], raw_bytes);
            self.input_output = value;
        }
        const value = &self.input_output.?;
        if (!std.mem.eql(u8, value.raw[0..value.length], raw_bytes) or !std.meta.eql(value.authority, authority)) {
            self.abort();
            return error.InputWriteInterrupted;
        }
        const wire = self.wire orelse return error.VideoUnavailable;
        const n = try wire.write(wire.context, value.output.bytes[value.output.offset..]);
        if (n > value.output.bytes.len - value.output.offset) return error.InvalidVideoWrite;
        value.output.offset += n;
        if (n != 0 and value.output.offset != value.output.bytes.len) self.remote_input.notePartialWrite(authority);
        if (value.output.offset != value.output.bytes.len) return 0;
        const accepted = value.length;
        self.allocator.free(value.output.bytes);
        self.input_output = null;
        return accepted;
    }
    fn inputAuthorityValid(self: *const Pipeline, authority: input.WriteAuthority, state: input.Snapshot) bool {
        if (!state.connected or authority.transport_generation != self.generation or authority.transport_generation != state.transport_generation) return false;
        if (authority.release) return true;
        if (!state.controlled or authority.control_generation != state.control_generation) return false;
        if (authority.automation != null) return self.remote_input.writeAuthorityValid(authority);
        if (authority.explicit) return authority.input_epoch == state.explicit_input_epoch;
        return state.focused and !state.capture_paused and !state.geometry_pending and authority.input_epoch == state.input_epoch;
    }
    fn inputAbort(raw_context: *anyopaque) void {
        const self: *Pipeline = @ptrCast(@alignCast(raw_context));
        self.abort();
    }
    fn abort(self: *Pipeline) void {
        if (self.wire) |wire| wire.abort(wire.context);
        self.stop();
    }
    fn reserve(raw_context: *anyopaque, bytes: usize) !void {
        const self: *Pipeline = @ptrCast(@alignCast(raw_context));
        for (&self.charges) |*slot| if (slot.* == null) {
            slot.* = .{ .reservation = try self.budget.reserve(self.owner, bytes, .decode), .remaining = bytes };
            return;
        };
        return error.FrameReservationFull;
    }
    fn release(raw_context: *anyopaque, bytes: usize) void {
        const self: *Pipeline = @ptrCast(@alignCast(raw_context));
        // Coverage is freed before its framebuffer. Keep its original charge
        // conservatively until the remaining frame is freed. Whole releases
        // select the oldest exact reservation; partial releases use newest.
        var chosen: ?usize = null;
        for (self.charges, 0..) |slot, i| if (slot) |value| if (value.remaining == bytes) {
            if (chosen == null or value.reservation.id < self.charges[chosen.?].?.reservation.id) chosen = i;
        };
        if (chosen == null) for (self.charges, 0..) |slot, i| if (slot) |value| if (value.remaining > bytes) {
            if (chosen == null or value.reservation.id > self.charges[chosen.?].?.reservation.id) chosen = i;
        };
        if (chosen) |i| {
            self.charges[i].?.remaining -= bytes;
            if (self.charges[i].?.remaining == 0) {
                self.charges[i].?.reservation.release();
                self.charges[i] = null;
            }
        } else unreachable;
    }
};
