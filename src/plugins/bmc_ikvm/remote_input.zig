//! Bounded human/automation mailboxes and RFB sender. Callers submit/revoke under a
//! short lock. Exactly one worker pumps; wire callbacks always run unlocked.
//! A partial message is never replayed. Revoking an incomplete normal packet
//! aborts that transport, since inserting a release would corrupt RFB framing.
const std = @import("std");
const identity = @import("../../host/identity.zig");
const typed = @import("../../host/plugin_services.zig");
pub const automation = @import("automation_input.zig");

pub const key: typed.ServiceKey = .{ .name = "bmc_ikvm.remote_input" };
pub const service_key = key;
pub const Key = struct { keysym: u32, down: bool };
pub const Pointer = struct { x: u16, y: u16, buttons: u8 };
pub const Wheel = struct { x: u16, y: u16, steps_x: i8 = 0, steps_y: i8 = 0 };
pub const Chord = struct {
    keys: [8]u32 = @splat(0),
    count: u8,
    pub fn init(keys: []const u32) !Chord {
        if (keys.len == 0 or keys.len > 8) return error.InvalidChord;
        var chord: Chord = .{ .count = @intCast(keys.len) };
        @memcpy(chord.keys[0..keys.len], keys);
        for (keys, 0..) |value, index| {
            if (value == 0) return error.InvalidChord;
            for (keys[0..index]) |prior| if (prior == value) return error.InvalidChord;
        }
        return chord;
    }
};
pub const Event = union(enum) { key: Key, pointer: Pointer, wheel: Wheel, chord: Chord };
pub const Command = struct {
    session_handle: identity.SessionHandle,
    binding_generation: u64,
    input_sequence: u64,
    input_epoch: u64,
    control_generation: u64,
    geometry_generation: u64 = 0,
    event: Event,
};
/// An intentional menu action, never a captured key/pointer event. Its epoch
/// comes from Snapshot.explicit_input_epoch so ordinary focus barriers cannot
/// cancel a menu click that was already accepted. Control/transport barriers do.
pub const ExplicitChordCommand = struct {
    session_handle: identity.SessionHandle,
    binding_generation: u64,
    input_sequence: u64,
    input_epoch: u64,
    control_generation: u64,
    transport_generation: u64,
    chord: Chord,
};
pub const ReleaseCause = enum { released, lost_focus, control_revoked, disconnected, takeover, closed, queue_full, send_failed, geometry_changed };
pub const SubmitResult = union(enum) { accepted: u64, read_only, not_focused, queue_full, stale_binding, stale_epoch, invalid_command };
pub const ReleaseResult = enum { accepted, locally_cleared_remote_unconfirmed, stale_binding };
pub const Snapshot = struct {
    input_epoch: u64,
    explicit_input_epoch: u64 = 1,
    last_input_sequence: u64 = 0,
    last_sent_input_sequence: u64 = 0,
    last_sent_transport_generation: u64 = 0,
    control_generation: u64,
    transport_generation: u64,
    connected: bool,
    controlled: bool,
    focused: bool,
    capture_paused: bool,
    queued: usize,
    remote_unconfirmed: bool,
    automation_queued: usize = 0,
    /// Last successfully published framebuffer generation. Zero preserves
    /// compatibility for standalone input services without a video pipeline.
    geometry_generation: u64 = 0,
    geometry_pending: bool = false,
};
pub const Interface = struct {
    snapshot: *const fn (*anyopaque, typed.Binding) anyerror!Snapshot,
    submit: *const fn (*anyopaque, typed.Binding, Command) SubmitResult,
    release_all: *const fn (*anyopaque, typed.Binding, ReleaseCause) ReleaseResult,
    submit_chord: ?*const fn (*anyopaque, typed.Binding, ExplicitChordCommand) SubmitResult = null,
};
pub const definition = typed.Definition.of(Interface, key);
/// generation identifies this particular transport, independently of owner.
/// write is nonblocking (0/error.WouldBlock means retry the unsent suffix).
/// abort must close/invalidate the old stream; a fresh stream gets a new
/// generation via setConnected, and never receives old down/up messages.
pub const WriteAuthority = struct {
    input_epoch: u64,
    control_generation: u64,
    transport_generation: u64,
    explicit: bool = false,
    release: bool = false,
    automation: ?automation.Authority = null,
    operation_id: u64 = 0,
};
pub const Wire = struct {
    context: *anyopaque,
    generation: u64,
    write: *const fn (*anyopaque, []const u8) anyerror!usize,
    abort: *const fn (*anyopaque) void,
    /// A framing adapter must retain this authority while its outer packet is
    /// partially written. Existing unframed writers keep the original callback.
    write_with_authority: ?*const fn (*anyopaque, []const u8, WriteAuthority) anyerror!usize = null,
};

pub const Service = struct {
    pub const capacity = 256;
    pub const explicit_capacity = 16;
    pub const automation_capacity = 1;
    pub const automation_history_capacity = 64;
    const wheel_mask: u8 = 0x78;
    const Effect = union(enum) { key: Key, pointer: Pointer };
    const Tx = struct {
        bytes: [8]u8 = @splat(0),
        length: u8,
        offset: u8 = 0,
        epoch: u64,
        control_generation: u64,
        transport_generation: u64,
        release: bool,
        explicit: bool = false,
        automation: ?automation.Authority = null,
        operation_id: u64 = 0,
        input_sequence: u64 = 0,
        completes_command: bool = false,
        effect: Effect,
    };
    const Active = struct { command: Command, explicit: bool = false, transport_generation: u64 = 0, step: u8 = 0, introduced: [8]u32 = @splat(0), introduced_count: u8 = 0 };
    const AutomationEntry = struct { authority: automation.Authority, operation_id: u64, batch: automation.Batch, step: u16 = 0 };
    const AutomationRecord = struct { receipt: automation.Receipt, fingerprint: [32]u8, lease: @import("../../host/content_context.zig").Lease };
    owner: identity.SessionHandle,
    input_epoch: u64 = 1,
    explicit_input_epoch: u64 = 1,
    control_generation: u64 = 1,
    transport_generation: u64 = 1,
    connected: bool = false,
    transport_used: bool = false,
    controlled: bool = false,
    focused: bool = false,
    capture_paused: bool = false,
    geometry_generation: u64 = 0,
    geometry_pending: bool = false,
    closed: bool = false,
    remote_unconfirmed: bool = false,
    entries: [capacity]Command = undefined,
    head: usize = 0,
    count: usize = 0,
    explicit_entries: [explicit_capacity]ExplicitChordCommand = undefined,
    explicit_head: usize = 0,
    explicit_count: usize = 0,
    automation_entries: [automation_capacity]AutomationEntry = undefined,
    automation_head: usize = 0,
    automation_count: usize = 0,
    automation_active: ?AutomationEntry = null,
    automation_authority: ?automation.Authority = null,
    automation_history: [automation_history_capacity]AutomationRecord = undefined,
    automation_history_count: usize = 0,
    automation_history_next: usize = 0,
    last_automation_operation: u64 = 0,
    automation_uncertain_lease: ?@import("../../host/content_context.zig").Lease = null,
    automation_uncertain_operation: u64 = 0,
    automation_budget_lease: ?@import("../../host/content_context.zig").Lease = null,
    automation_budget_started_ms: u64 = 0,
    automation_budget_steps: u8 = 0,
    last_sequence: u64 = 0,
    last_sent_sequence: u64 = 0,
    last_sent_transport_generation: u64 = 0,
    queued_buttons: u8 = 0,
    release_pending: bool = false,
    release_cause: ReleaseCause = .released,
    pressed_keys: [256]u32 = @splat(0),
    pressed_count: usize = 0,
    pressed_buttons: u8 = 0,
    pointer_x: u16 = 0,
    pointer_y: u16 = 0,
    active: ?Active = null,
    tx: ?Tx = null,
    mutex: std.atomic.Value(bool) = .init(false),
    pumping: std.atomic.Value(bool) = .init(false),

    pub fn init(owner: identity.SessionHandle) Service {
        return .{ .owner = owner };
    }
    pub fn binding(self: *Service) typed.Binding {
        return typed.Binding.init(Interface, key, self, &vtable, self.owner, 1);
    }
    pub fn snapshot(self: *Service, binding_value: typed.Binding) !Snapshot {
        self.lock();
        defer self.unlock();
        if (!self.matches(binding_value)) return error.StaleBinding;
        return .{ .input_epoch = self.input_epoch, .explicit_input_epoch = self.explicit_input_epoch, .last_input_sequence = self.last_sequence, .last_sent_input_sequence = self.last_sent_sequence, .last_sent_transport_generation = self.last_sent_transport_generation, .control_generation = self.control_generation, .transport_generation = self.transport_generation, .connected = self.connected, .controlled = self.controlled, .focused = self.focused, .capture_paused = self.capture_paused, .queued = self.count + self.explicit_count + self.automation_count, .remote_unconfirmed = self.remote_unconfirmed, .automation_queued = self.automation_count + @as(usize, @intFromBool(self.automation_active != null)), .geometry_generation = self.geometry_generation, .geometry_pending = self.geometry_pending };
    }
    pub fn command(self: *Service, sequence: u64, event: Event) Command {
        self.lock();
        defer self.unlock();
        return .{ .session_handle = self.owner, .binding_generation = self.owner.generation, .input_sequence = sequence, .input_epoch = self.input_epoch, .control_generation = self.control_generation, .geometry_generation = self.geometry_generation, .event = event };
    }
    pub fn explicitChordCommand(self: *Service, sequence: u64, chord: Chord) ExplicitChordCommand {
        self.lock();
        defer self.unlock();
        return .{ .session_handle = self.owner, .binding_generation = self.owner.generation, .input_sequence = sequence, .input_epoch = self.explicit_input_epoch, .control_generation = self.control_generation, .transport_generation = self.transport_generation, .chord = chord };
    }
    /// Caller must finish/abort and stop the old transport worker before rebind.
    /// New transport generations start with no remote pressed-state assumption.
    pub fn setConnected(self: *Service, connected: bool, generation: u64) !void {
        self.lock();
        defer self.unlock();
        if (generation == 0 or generation < self.transport_generation) return error.StaleTransport;
        if (self.closed and connected) return error.InputClosed;
        if (generation == self.transport_generation and connected == self.connected) return;
        if (connected and !self.connected and generation == self.transport_generation and self.transport_used) return error.StaleTransport;
        self.barrier(.disconnected);
        if (generation != self.transport_generation) {
            self.active = null;
            self.tx = null;
            self.pressed_count = 0;
            self.pressed_buttons = 0;
            self.release_pending = false;
            self.remote_unconfirmed = false;
            self.transport_used = false;
        }
        self.transport_generation = generation;
        self.connected = connected;
        // A new channel requires a new server control grant and new local
        // content focus. Old permission/focus cannot authorize a reconnect.
        self.controlled = false;
        self.focused = false;
        if (connected) self.transport_used = true;
        if (!connected) {
            self.remote_unconfirmed = self.remote_unconfirmed or self.pressed_count != 0 or self.pressed_buttons != 0 or self.tx != null;
            self.pressed_count = 0;
            self.pressed_buttons = 0;
            self.active = null;
            self.tx = null;
            self.release_pending = false;
        }
        self.capture_paused = true;
    }
    pub fn setControl(self: *Service, controlled: bool, generation: u64) !void {
        self.lock();
        defer self.unlock();
        if (generation == 0 or generation < self.control_generation) return error.StaleControl;
        if (self.closed) return error.InputClosed;
        if (controlled != self.controlled or generation != self.control_generation) self.barrier(.control_revoked);
        self.control_generation = generation;
        self.controlled = controlled;
        if (controlled and self.connected and !self.geometry_pending) self.capture_paused = false;
    }
    /// Decoder geometry is not yet a displayed coordinate system. Revoke the
    /// old epoch immediately and reject attempts to recapture its old image.
    pub fn beginGeometryChange(self: *Service, transport_generation: u64) !void {
        self.lock();
        defer self.unlock();
        if (transport_generation != self.transport_generation) return error.StaleTransport;
        if (self.closed or !self.connected) return error.InputUnavailable;
        self.barrier(.geometry_changed);
        self.geometry_pending = true;
        self.focused = false;
        self.capture_paused = true;
    }
    /// Called only after publishComplete succeeded. Capture remains released;
    /// callers must first present this generation and explicitly capture again.
    pub fn completeGeometryChange(self: *Service, transport_generation: u64, frame_generation: u64) !void {
        self.lock();
        defer self.unlock();
        if (transport_generation != self.transport_generation) return error.StaleTransport;
        if (self.closed or !self.connected) return error.InputUnavailable;
        if (frame_generation == 0 or frame_generation < self.geometry_generation) return error.StaleFrameGeometry;
        self.geometry_generation = frame_generation;
        self.geometry_pending = false;
    }
    pub fn setFocus(self: *Service, focused: bool) void {
        self.lock();
        defer self.unlock();
        if (focused and self.automation_authority != null) self.barrier(.takeover);
        if (self.focused and !focused) self.barrier(.lost_focus);
        self.focused = focused and !self.closed and !self.geometry_pending;
        if (self.focused and self.controlled and self.connected) self.capture_paused = false;
    }
    pub fn resumeCapture(self: *Service) !void {
        self.lock();
        defer self.unlock();
        if (self.closed or !self.connected or !self.controlled or !self.focused or self.remote_unconfirmed or self.geometry_pending) return error.InputUnavailable;
        self.capture_paused = false;
    }
    pub fn submit(self: *Service, binding_value: typed.Binding, value: Command) SubmitResult {
        self.lock();
        defer self.unlock();
        if (!self.matches(binding_value) or !value.session_handle.eql(self.owner) or value.binding_generation != self.owner.generation) return .stale_binding;
        if (self.closed or !self.connected or !self.controlled) return .read_only;
        if (!self.focused or self.geometry_pending) return .not_focused;
        if (value.input_epoch != self.input_epoch or value.control_generation != self.control_generation or (self.geometry_generation != 0 and value.geometry_generation != self.geometry_generation)) return .stale_epoch;
        if (!validEvent(value.event) or value.input_sequence == 0 or value.input_sequence <= self.last_sequence) return .invalid_command;
        if (self.capture_paused) return .queue_full;
        // Physical input is a takeover even when a host failed to notify its
        // ContentContext first. Never interleave it with automation downs.
        if (self.automation_authority != null) {
            self.barrier(.takeover);
            return .stale_epoch;
        }
        // Only a move preserving the complete button mask can replace another
        // move. Transitions, wheel steps and key/chord events retain ordering.
        if (value.event == .pointer and value.event.pointer.buttons == self.queued_buttons and self.count != 0) {
            const tail = (self.head + self.count - 1) % capacity;
            const prior = self.entries[tail];
            if (prior.event == .pointer and prior.event.pointer.buttons == self.queued_buttons and prior.input_epoch == value.input_epoch) {
                // A button transition itself may not be replaced: check its
                // predecessor mask (or the worker's already-sent mask).
                const preceding_mask = if (self.count > 1) self.maskBeforeTail() else self.pressed_buttons & ~wheel_mask;
                if (preceding_mask == self.queued_buttons) {
                    self.entries[tail] = value;
                    self.last_sequence = value.input_sequence;
                    return .{ .accepted = value.input_sequence };
                }
            }
        }
        if (self.count == capacity) {
            self.barrier(.queue_full);
            self.capture_paused = true;
            return .queue_full;
        }
        self.entries[(self.head + self.count) % capacity] = value;
        self.count += 1;
        self.last_sequence = value.input_sequence;
        if (value.event == .pointer) self.queued_buttons = value.event.pointer.buttons;
        return .{ .accepted = value.input_sequence };
    }
    /// Focus and capture belong only to ordinary input. The independently
    /// bounded menu queue rejects a full submission without discarding prior
    /// actions, consuming its sequence, or changing capture/focus state.
    pub fn submitChord(self: *Service, binding_value: typed.Binding, value: ExplicitChordCommand) SubmitResult {
        self.lock();
        defer self.unlock();
        if (!self.matches(binding_value) or !value.session_handle.eql(self.owner) or value.binding_generation != self.owner.generation) return .stale_binding;
        if (self.closed or !self.connected or !self.controlled) return .read_only;
        if (value.input_epoch != self.explicit_input_epoch or value.control_generation != self.control_generation or value.transport_generation != self.transport_generation) return .stale_epoch;
        if (!validEvent(.{ .chord = value.chord }) or value.input_sequence == 0 or value.input_sequence <= self.last_sequence) return .invalid_command;
        var accepted = value;
        if (self.automation_authority != null) {
            self.barrier(.takeover);
            accepted.input_epoch = self.explicit_input_epoch;
        }
        if (self.explicit_count == explicit_capacity) return .queue_full;
        self.explicit_entries[(self.explicit_head + self.explicit_count) % explicit_capacity] = accepted;
        self.explicit_count += 1;
        self.last_sequence = value.input_sequence;
        return .{ .accepted = value.input_sequence };
    }
    /// Automation is a separate lane, authorized by a live host lease rather
    /// than by manufacturing human content focus. Every operation owns its
    /// complete bounded sequence before it becomes visible to the worker.
    pub fn submitAutomation(self: *Service, binding_value: typed.Binding, authority: automation.Authority, request: automation.Request) !automation.Receipt {
        const batch = try automation.compile(request.action);
        const fingerprint = batch.fingerprint();
        self.lock();
        defer self.unlock();
        if (!self.matches(binding_value) or !authority.owner.eql(self.owner) or authority.binding_generation != self.owner.generation) return error.StaleBinding;
        if (request.operation_id == 0) return error.InvalidOperationId;
        if (self.automationRecord(request.operation_id)) |record| {
            if (!std.mem.eql(u8, &fingerprint, &record.fingerprint)) return error.OperationConflict;
            return record.receipt;
        }
        // The host assigns monotonically increasing operation IDs. Once an ID
        // leaves bounded history it remains consumed and can never replay.
        if (request.operation_id <= self.last_automation_operation) return error.OperationExpired;
        if (self.geometry_pending) return error.FrameGeometryPending;
        for (self.automation_history[0..self.automation_history_count]) |record| if (record.receipt.status == .accepted) return error.AutomationOperationInFlight;
        if (self.automation_uncertain_lease) |lease| if (std.meta.eql(lease, authority.proof.lease)) return error.InputOutcomeUnknown;
        if (self.focused or self.count != 0 or self.explicit_count != 0 or self.active != null) return error.HumanInputActive;
        if (self.automation_authority == null and !self.release_pending and (self.pressed_count != 0 or self.pressed_buttons != 0)) return error.HumanInputActive;
        if (!self.automationAuthorityValid(authority)) return error.StaleAutomationAuthority;
        if (self.remote_unconfirmed) return error.RemoteInputUnconfirmed;
        if (self.automation_authority) |prior| if (!std.meta.eql(prior.proof.lease, authority.proof.lease)) return error.AutomationLeaseActive;
        if (self.automation_count == automation_capacity) return error.QueueFull;
        const now = monotonicMs();
        if (now == 0) return error.InputClockUnavailable;
        if (self.automation_budget_lease == null or !std.meta.eql(self.automation_budget_lease.?, authority.proof.lease)) {
            self.automation_budget_lease = authority.proof.lease;
            self.automation_budget_started_ms = now;
            self.automation_budget_steps = 0;
        }
        if (self.automation_budget_steps >= 32 or now < self.automation_budget_started_ms or now - self.automation_budget_started_ms >= 600_000) return error.AutomationBudgetExceeded;
        const receipt: automation.Receipt = .{ .owner = self.owner, .operation_id = request.operation_id, .total_events = batch.count };
        self.automation_history[self.automation_history_next] = .{ .receipt = receipt, .fingerprint = fingerprint, .lease = authority.proof.lease };
        self.automation_history_next = (self.automation_history_next + 1) % automation_history_capacity;
        self.automation_history_count = @min(self.automation_history_count + 1, automation_history_capacity);
        self.automation_entries[(self.automation_head + self.automation_count) % automation_capacity] = .{ .authority = authority, .operation_id = request.operation_id, .batch = batch };
        self.automation_count += 1;
        self.automation_authority = authority;
        self.automation_budget_steps += 1;
        self.last_automation_operation = request.operation_id;
        return receipt;
    }
    pub fn automationStatus(self: *Service, binding_value: typed.Binding, operation_id: u64) !automation.Receipt {
        self.lock();
        defer self.unlock();
        if (!self.matches(binding_value)) return error.StaleBinding;
        const record = self.automationRecord(operation_id) orelse return error.UnknownOperation;
        if (record.receipt.status == .accepted) if (self.automation_authority) |authority| if (!self.automationAuthorityValid(authority)) self.barrier(.takeover);
        return record.receipt;
    }
    pub fn revokeAutomation(self: *Service, cause: ReleaseCause) void {
        self.lock();
        defer self.unlock();
        self.barrier(cause);
    }
    /// The framing adapter calls this after a nonempty WS prefix. Its inner
    /// RFB write still reports zero until the outer frame is complete.
    pub fn notePartialWrite(self: *Service, authority: WriteAuthority) void {
        self.lock();
        defer self.unlock();
        self.noteAutomationPossible(authority.operation_id);
    }
    pub fn writeAuthorityValid(self: *Service, authority: WriteAuthority) bool {
        self.lock();
        defer self.unlock();
        if (!self.connected or authority.transport_generation != self.transport_generation) return false;
        if (authority.release) return true;
        if (authority.automation) |value| return self.automationAuthorityValid(value) and authority.operation_id != 0;
        if (authority.explicit) return !self.closed and self.controlled and authority.input_epoch == self.explicit_input_epoch and authority.control_generation == self.control_generation;
        return !self.closed and self.controlled and self.focused and !self.capture_paused and !self.geometry_pending and authority.input_epoch == self.input_epoch and authority.control_generation == self.control_generation;
    }
    pub fn releaseAll(self: *Service, binding_value: typed.Binding, cause: ReleaseCause) ReleaseResult {
        self.lock();
        defer self.unlock();
        if (!self.matches(binding_value)) return .stale_binding;
        self.barrier(cause);
        if (!self.connected) {
            self.remote_unconfirmed = self.remote_unconfirmed or self.pressed_count != 0 or self.pressed_buttons != 0 or self.tx != null;
            self.pressed_count = 0;
            self.pressed_buttons = 0;
            self.release_pending = false;
            return .locally_cleared_remote_unconfirmed;
        }
        return .accepted;
    }
    pub fn close(self: *Service) void {
        self.lock();
        defer self.unlock();
        if (self.closed) return;
        self.barrier(.closed);
        self.closed = true;
        self.controlled = false;
        self.focused = false;
        self.capture_paused = true;
    }
    /// At most 64 complete messages / 128 nonblocking write calls per turn.
    /// A return value counts RFB messages, not logical commands. The worker may
    /// call again when writable; a partial prefix remains owned by this sender.
    pub fn pump(self: *Service, wire: Wire) !usize {
        if (self.pumping.swap(true, .acquire)) return error.MultipleInputSenders;
        defer self.pumping.store(false, .release);
        var completed: usize = 0;
        var writes: usize = 0;
        while (completed < 64 and writes < 128) {
            self.lock();
            if (wire.generation != self.transport_generation) {
                self.unlock();
                return error.StaleTransport;
            }
            if (!self.connected) {
                self.unlock();
                return completed;
            }
            if (self.tx) |tx| {
                if (!self.txValid(tx)) {
                    if (tx.operation_id != 0) self.barrier(.takeover);
                    self.tx = null;
                    self.active = null;
                    const partial = tx.offset != 0;
                    if (partial) self.failLocked();
                    self.unlock();
                    if (partial) {
                        wire.abort(wire.context);
                        return error.InputWriteInterrupted;
                    }
                    continue;
                }
            }
            if (self.tx == null) {
                self.prepareNext() catch |err| {
                    self.barrier(.send_failed);
                    self.capture_paused = true;
                    self.unlock();
                    return err;
                };
            }
            const tx = self.tx orelse {
                self.unlock();
                return completed;
            };
            // This is the final authority check immediately before every write,
            // including each suffix of a short write. Callbacks are unlocked.
            if (!self.txValid(tx)) {
                self.unlock();
                continue;
            }
            self.unlock();
            writes += 1;
            const write_result = if (wire.write_with_authority) |write| write(wire.context, tx.bytes[tx.offset..tx.length], .{ .input_epoch = tx.epoch, .control_generation = tx.control_generation, .transport_generation = tx.transport_generation, .explicit = tx.explicit, .release = tx.release, .automation = tx.automation, .operation_id = tx.operation_id }) else wire.write(wire.context, tx.bytes[tx.offset..tx.length]);
            const written = write_result catch |err| {
                if (err == error.WouldBlock) return completed;
                self.lock();
                self.noteAutomationPossible(tx.operation_id);
                self.failLocked();
                self.unlock();
                wire.abort(wire.context);
                return err;
            };
            if (written == 0) return completed;
            if (written > tx.length - tx.offset) {
                self.lock();
                self.noteAutomationPossible(tx.operation_id);
                self.failLocked();
                self.unlock();
                wire.abort(wire.context);
                return error.InvalidInputWrite;
            }
            self.lock();
            self.noteAutomationPossible(tx.operation_id);
            if (written == tx.length - tx.offset) {
                self.noteAutomationSent(tx.operation_id);
                if (tx.completes_command and tx.input_sequence != 0) {
                    self.last_sent_sequence = @max(self.last_sent_sequence, tx.input_sequence);
                    self.last_sent_transport_generation = tx.transport_generation;
                }
            }
            // A rebind may have occurred in the callback. The new transport
            // must not inherit completion or pressed state from the old one.
            if (tx.transport_generation != self.transport_generation or self.tx == null) {
                self.unlock();
                return error.StaleTransport;
            }
            self.tx.?.offset += @intCast(written);
            if (self.tx.?.offset == self.tx.?.length) {
                self.commit(tx.effect);
                if (tx.operation_id != 0) if (self.automation_active) |*active| {
                    if (active.operation_id == tx.operation_id) active.step += 1;
                };
                if (!tx.release) if (self.active) |*active| {
                    active.step += 1;
                };
                self.tx = null;
                completed += 1;
            }
            self.unlock();
        }
        return completed;
    }
    fn prepareNext(self: *Service) !void {
        while (self.tx == null) {
            // Once an explicit chord has started, a focus-only barrier lets its
            // paired ups finish before clearing prior ordinary pressed state.
            // Hard barriers discard active first, so releases retain priority.
            const explicit_in_progress = if (self.active) |active| active.explicit and active.step != 0 else false;
            if (self.release_pending and !explicit_in_progress) {
                if (self.pressed_count != 0) {
                    self.tx = self.keyTx(.{ .keysym = self.pressed_keys[self.pressed_count - 1], .down = false }, true);
                    return;
                }
                if (self.pressed_buttons != 0) {
                    self.tx = self.pointerTx(.{ .x = self.pointer_x, .y = self.pointer_y, .buttons = 0 }, true);
                    return;
                }
                self.release_pending = false;
                self.remote_unconfirmed = false;
            }
            if (self.automation_active != null or self.automation_count != 0) {
                if (self.automation_active == null) {
                    self.automation_active = self.automation_entries[self.automation_head];
                    self.automation_head = (self.automation_head + 1) % automation_capacity;
                    self.automation_count -= 1;
                }
                const active = self.automation_active.?;
                if (active.step == active.batch.count) {
                    self.automation_active = null;
                    continue;
                }
                if (!self.automationAuthorityValid(active.authority)) {
                    self.barrier(.takeover);
                    continue;
                }
                switch (active.batch.events[active.step]) {
                    .key => |value| self.tx = self.keyTx(.{ .keysym = value.keysym, .down = value.down }, false),
                    .pointer => |value| self.tx = self.pointerTx(.{ .x = value.x, .y = value.y, .buttons = value.buttons }, false),
                }
                self.tx.?.automation = active.authority;
                self.tx.?.operation_id = active.operation_id;
                return;
            }
            if (self.active == null) {
                if (self.count == 0 and self.explicit_count == 0) return;
                // Shared monotonic sequences preserve order between both
                // queues while focus barriers may discard only ordinary work.
                const take_explicit = self.explicit_count != 0 and (self.count == 0 or self.explicit_entries[self.explicit_head].input_sequence < self.entries[self.head].input_sequence);
                if (take_explicit) {
                    const value = self.explicit_entries[self.explicit_head];
                    self.explicit_head = (self.explicit_head + 1) % explicit_capacity;
                    self.explicit_count -= 1;
                    self.active = .{ .command = .{ .session_handle = value.session_handle, .binding_generation = value.binding_generation, .input_sequence = value.input_sequence, .input_epoch = value.input_epoch, .control_generation = value.control_generation, .event = .{ .chord = value.chord } }, .explicit = true, .transport_generation = value.transport_generation };
                } else {
                    const command_value = self.entries[self.head];
                    self.head = (self.head + 1) % capacity;
                    self.count -= 1;
                    self.active = .{ .command = command_value };
                }
                if (!self.activeValid(self.active.?)) {
                    self.active = null;
                    continue;
                }
                const command_value = self.active.?.command;
                if (command_value.event == .chord) {
                    const chord = command_value.event.chord;
                    for (chord.keys[0..chord.count]) |keysym| {
                        if (self.pressedIndex(keysym) != null) continue;
                        const active = &self.active.?;
                        active.introduced[active.introduced_count] = keysym;
                        active.introduced_count += 1;
                    }
                }
            }
            const active = self.active.?;
            if (!self.activeValid(active)) {
                self.active = null;
                continue;
            }
            switch (active.command.event) {
                .key => |value| {
                    if (active.step != 0) {
                        self.active = null;
                        continue;
                    }
                    if (value.down and self.pressedIndex(value.keysym) == null and self.pressed_count == self.pressed_keys.len) return error.TooManyPressedKeys;
                    self.tx = self.keyTx(value, false);
                    self.tx.?.completes_command = true;
                },
                .pointer => |value| {
                    if (active.step != 0) {
                        self.active = null;
                        continue;
                    }
                    self.tx = self.pointerTx(value, false);
                    self.tx.?.completes_command = true;
                },
                .wheel => |value| {
                    const horizontal: u8 = @abs(value.steps_x);
                    const vertical: u8 = @abs(value.steps_y);
                    if (active.step >= (horizontal + vertical) * 2) {
                        self.active = null;
                        continue;
                    }
                    const pulse = active.step / 2;
                    const bit: u8 = if (pulse < vertical) (if (value.steps_y > 0) 8 else 16) else (if (value.steps_x > 0) 64 else 32);
                    const mask = (self.pressed_buttons & ~wheel_mask) | (if (active.step % 2 == 0) bit else @as(u8, 0));
                    self.tx = self.pointerTx(.{ .x = value.x, .y = value.y, .buttons = mask }, false);
                    self.tx.?.completes_command = active.step + 1 == (horizontal + vertical) * 2;
                },
                .chord => {
                    if (active.step >= active.introduced_count * 2) {
                        self.active = null;
                        continue;
                    }
                    const down = active.step < active.introduced_count;
                    const index = if (down) active.step else active.introduced_count * 2 - active.step - 1;
                    const keysym = active.introduced[index];
                    if (down and self.pressed_count == self.pressed_keys.len) return error.TooManyPressedKeys;
                    self.tx = self.keyTx(.{ .keysym = keysym, .down = down }, false);
                    self.tx.?.completes_command = active.step + 1 == active.introduced_count * 2;
                },
            }
        }
    }
    fn keyTx(self: *Service, value: Key, release: bool) Tx {
        const explicit = !release and if (self.active) |active| active.explicit else false;
        var tx: Tx = .{ .length = 8, .epoch = if (explicit) self.explicit_input_epoch else self.input_epoch, .control_generation = self.control_generation, .transport_generation = self.transport_generation, .release = release, .explicit = explicit, .effect = .{ .key = value } };
        if (!release) if (self.active) |active| {
            tx.input_sequence = active.command.input_sequence;
        };
        tx.bytes[0] = 4;
        tx.bytes[1] = @intFromBool(value.down);
        std.mem.writeInt(u32, tx.bytes[4..8], value.keysym, .big);
        return tx;
    }
    fn pointerTx(self: *Service, value: Pointer, release: bool) Tx {
        var tx: Tx = .{ .length = 6, .epoch = self.input_epoch, .control_generation = self.control_generation, .transport_generation = self.transport_generation, .release = release, .effect = .{ .pointer = value } };
        if (!release) if (self.active) |active| {
            tx.input_sequence = active.command.input_sequence;
        };
        tx.bytes[0] = 5;
        tx.bytes[1] = value.buttons;
        std.mem.writeInt(u16, tx.bytes[2..4], value.x, .big);
        std.mem.writeInt(u16, tx.bytes[4..6], value.y, .big);
        return tx;
    }
    fn commit(self: *Service, effect: Effect) void {
        switch (effect) {
            .key => |value| {
                const index = self.pressedIndex(value.keysym);
                if (value.down) {
                    if (index == null) {
                        std.debug.assert(self.pressed_count < self.pressed_keys.len);
                        self.pressed_keys[self.pressed_count] = value.keysym;
                        self.pressed_count += 1;
                    }
                } else if (index) |position| {
                    std.mem.copyForwards(u32, self.pressed_keys[position .. self.pressed_count - 1], self.pressed_keys[position + 1 .. self.pressed_count]);
                    self.pressed_count -= 1;
                }
            },
            .pointer => |value| {
                self.pointer_x = value.x;
                self.pointer_y = value.y;
                self.pressed_buttons = value.buttons;
            },
        }
    }
    fn barrier(self: *Service, cause: ReleaseCause) void {
        self.cancelAutomationLocked();
        // Exhaustion permanently denies further input; the epoch never wraps.
        if (self.input_epoch == std.math.maxInt(u64)) {
            self.closed = true;
            self.controlled = false;
        } else self.input_epoch += 1;
        self.head = 0;
        self.count = 0;
        self.queued_buttons = 0;
        const revoke_explicit = self.closed or switch (cause) {
            .released, .lost_focus, .queue_full, .geometry_changed => false,
            else => true,
        };
        if (revoke_explicit) {
            if (self.explicit_input_epoch == std.math.maxInt(u64)) {
                self.closed = true;
                self.controlled = false;
            } else self.explicit_input_epoch += 1;
            self.explicit_head = 0;
            self.explicit_count = 0;
        }
        if (revoke_explicit or (if (self.active) |active| !active.explicit else false)) self.active = null;
        self.release_pending = true;
        self.release_cause = cause;
    }
    fn failLocked(self: *Service) void {
        self.barrier(.send_failed);
        self.connected = false;
        self.capture_paused = true;
        self.remote_unconfirmed = true;
        self.pressed_count = 0;
        self.pressed_buttons = 0;
        self.tx = null;
        self.release_pending = false;
    }
    fn commandValid(self: *Service, value: Command) bool {
        return !self.closed and self.connected and self.controlled and self.focused and !self.capture_paused and !self.geometry_pending and value.session_handle.eql(self.owner) and value.binding_generation == self.owner.generation and value.input_epoch == self.input_epoch and value.control_generation == self.control_generation and (self.geometry_generation == 0 or value.geometry_generation == self.geometry_generation);
    }
    fn activeValid(self: *Service, value: Active) bool {
        if (!value.explicit) return self.commandValid(value.command);
        return !self.closed and self.connected and self.controlled and value.transport_generation == self.transport_generation and value.command.session_handle.eql(self.owner) and value.command.binding_generation == self.owner.generation and value.command.input_epoch == self.explicit_input_epoch and value.command.control_generation == self.control_generation;
    }
    fn txValid(self: *Service, value: Tx) bool {
        if (!self.connected or value.transport_generation != self.transport_generation) return false;
        if (value.release) return true;
        if (value.automation) |authority| return self.automationAuthorityValid(authority) and value.operation_id != 0;
        if (value.explicit) return !self.closed and self.controlled and value.epoch == self.explicit_input_epoch and value.control_generation == self.control_generation;
        return !self.closed and self.controlled and self.focused and !self.capture_paused and !self.geometry_pending and value.epoch == self.input_epoch and value.control_generation == self.control_generation;
    }
    fn automationAuthorityValid(self: *Service, authority: automation.Authority) bool {
        const checked_ms = monotonicMs();
        if (checked_ms == 0 or checked_ms >= authority.expires_at_ms) return false;
        if (self.automation_budget_lease) |lease| if (std.meta.eql(lease, authority.proof.lease)) {
            if (checked_ms < self.automation_budget_started_ms or checked_ms - self.automation_budget_started_ms >= 600_000) return false;
        };
        return !self.closed and self.connected and self.controlled and !self.focused and !self.geometry_pending and (self.geometry_generation == 0 or authority.geometry_generation == self.geometry_generation) and authority.owner.eql(self.owner) and authority.binding_generation == self.owner.generation and authority.transport_generation == self.transport_generation and authority.control_generation == self.control_generation and authority.input_epoch == self.input_epoch and authority.proof.lease.kind == .automation and authority.proof.lease.owner.eql(self.owner) and authority.proof.lease.id != 0 and authority.proof.lease.context_instance != 0 and authority.proof.validate(authority.proof.context, authority.proof.lease);
    }
    fn automationRecord(self: *Service, operation_id: u64) ?*AutomationRecord {
        for (self.automation_history[0..self.automation_history_count]) |*record| if (record.receipt.operation_id == operation_id) return record;
        return null;
    }
    fn cancelAutomationLocked(self: *Service) void {
        for (self.automation_history[0..self.automation_history_count]) |*record| {
            const receipt = &record.receipt;
            if (receipt.status == .accepted) {
                receipt.status = if (receipt.possibly_written or receipt.sent_events != 0) .outcome_unknown else .cancelled_unsent;
                if (receipt.status == .outcome_unknown) {
                    self.automation_uncertain_lease = record.lease;
                    self.automation_uncertain_operation = receipt.operation_id;
                }
            }
        }
        self.automation_head = 0;
        self.automation_count = 0;
        self.automation_active = null;
        self.automation_authority = null;
    }
    fn noteAutomationPossible(self: *Service, operation_id: u64) void {
        if (operation_id == 0) return;
        if (self.automationRecord(operation_id)) |record| {
            record.receipt.possibly_written = true;
            if (record.receipt.status == .cancelled_unsent) {
                record.receipt.status = .outcome_unknown;
                self.automation_uncertain_lease = record.lease;
                self.automation_uncertain_operation = operation_id;
            }
        }
    }
    fn noteAutomationSent(self: *Service, operation_id: u64) void {
        if (operation_id == 0) return;
        if (self.automationRecord(operation_id)) |record| {
            record.receipt.sent_events = @min(record.receipt.sent_events + 1, record.receipt.total_events);
            if (record.receipt.sent_events == record.receipt.total_events) {
                record.receipt.status = .sent;
                record.receipt.sent_monotonic_ns = monotonicNs();
                record.receipt.sent_monotonic_ms = record.receipt.sent_monotonic_ns / std.time.ns_per_ms;
                if (self.automation_uncertain_operation == operation_id) {
                    self.automation_uncertain_lease = null;
                    self.automation_uncertain_operation = 0;
                }
            }
        }
    }
    fn pressedIndex(self: *Service, keysym: u32) ?usize {
        for (self.pressed_keys[0..self.pressed_count], 0..) |value, index| if (value == keysym) return index;
        return null;
    }
    fn maskBeforeTail(self: *Service) u8 {
        var mask = self.pressed_buttons & ~wheel_mask;
        for (0..self.count - 1) |offset| {
            const event = self.entries[(self.head + offset) % capacity].event;
            if (event == .pointer) mask = event.pointer.buttons;
        }
        return mask;
    }
    fn matches(self: *Service, binding_value: typed.Binding) bool {
        _ = binding_value.borrow(Interface, key, self.owner) catch return false;
        return binding_value.context == @as(*anyopaque, @ptrCast(self)) and binding_value.vtable == @as(*const anyopaque, &vtable);
    }
    const vtable: Interface = .{ .snapshot = snapshotFromBinding, .submit = submitFromBinding, .release_all = releaseFromBinding, .submit_chord = submitChordFromBinding };
    fn snapshotFromBinding(context: *anyopaque, binding_value: typed.Binding) !Snapshot {
        const self: *Service = @ptrCast(@alignCast(context));
        return self.snapshot(binding_value);
    }
    fn submitFromBinding(context: *anyopaque, binding_value: typed.Binding, value: Command) SubmitResult {
        const self: *Service = @ptrCast(@alignCast(context));
        return self.submit(binding_value, value);
    }
    fn submitChordFromBinding(context: *anyopaque, binding_value: typed.Binding, value: ExplicitChordCommand) SubmitResult {
        const self: *Service = @ptrCast(@alignCast(context));
        return self.submitChord(binding_value, value);
    }
    fn releaseFromBinding(context: *anyopaque, binding_value: typed.Binding, cause: ReleaseCause) ReleaseResult {
        const self: *Service = @ptrCast(@alignCast(context));
        return self.releaseAll(binding_value, cause);
    }
    fn lock(self: *Service) void {
        while (self.mutex.swap(true, .acquire)) std.atomic.spinLoopHint();
    }
    fn unlock(self: *Service) void {
        self.mutex.store(false, .release);
    }
};
pub const RemoteInputService = Service;

fn monotonicMs() u64 {
    return monotonicNs() / std.time.ns_per_ms;
}
fn monotonicNs() u64 {
    var ts: std.c.timespec = undefined;
    if (std.c.clock_gettime(.MONOTONIC, &ts) != 0 or ts.sec < 0) return 0;
    return @as(u64, @intCast(ts.sec)) * std.time.ns_per_s + @as(u64, @intCast(ts.nsec));
}

fn validEvent(event: Event) bool {
    return switch (event) {
        .key => |value| value.keysym != 0,
        .pointer => |value| value.buttons & Service.wheel_mask == 0,
        .wheel => |value| value.steps_x >= -16 and value.steps_x <= 16 and value.steps_y >= -16 and value.steps_y <= 16 and (value.steps_x != 0 or value.steps_y != 0),
        .chord => |value| blk: {
            if (value.count == 0 or value.count > value.keys.len) break :blk false;
            for (value.keys[0..value.count], 0..) |keysym, index| {
                if (keysym == 0) break :blk false;
                for (value.keys[0..index]) |prior| if (prior == keysym) break :blk false;
            }
            break :blk true;
        },
    };
}
