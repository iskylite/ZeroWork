//! Worker-owned authenticated ZLE bridge. Snapshots are shell observations;
//! terminal writes never update them speculatively.
const std = @import("std");
const identity = @import("../host/identity.zig");
pub const edit = @import("../host/trusted_edit.zig");
pub const Native = opaque {};
extern fn zw_local_edit_poll_fd(*Native) c_int;
extern fn zw_local_edit_create(u64, u64, [*]const u8, usize) ?*Native;
extern fn zw_local_edit_destroy(*Native) void;
extern fn zw_local_edit_directory(*Native) [*:0]const u8;
extern fn zw_local_edit_nonce(*Native) [*:0]const u8;
extern fn zw_local_edit_read(*Native, c_int, [*]u8, usize, *usize) c_int;
extern fn zw_local_edit_write(*Native, [*]const u8, usize, *usize) c_int;
const script = @embedFile("shell/integration.zsh") ++ "\n" ++ @embedFile("shell/execution.zsh");
pub const Bridge = struct {
    allocator: std.mem.Allocator,
    owner: identity.SessionHandle,
    native: *Native,
    snapshot: ?edit.Snapshot = null,
    outcome: ?edit.Outcome = null,
    pending: ?struct { request: edit.Request, deadline: i64, replacement_hash: u64, replacement_cursor: u64 } = null,
    hello: bool = false,
    last_received: u64 = 0,
    sequence: u64 = 0,
    last_operation: u64 = 0,
    connected_at: i64 = 0,
    disabled: bool = false,
    input_dirty: bool = false,
    input_epoch: u64 = 0,
    observation: ?struct { id: u64, epoch: u64 } = null,
    next_observation: u64 = 0,
    rx: std.ArrayList(u8) = .empty,
    tx: std.ArrayList(u8) = .empty,
    tx_offset: usize = 0,
    pub fn init(allocator: std.mem.Allocator, owner: identity.SessionHandle) !Bridge {
        const native = zw_local_edit_create(@backingInt(owner.session_id), owner.generation, script.ptr, script.len) orelse return error.IntegrationUnavailable;
        return .{ .allocator = allocator, .owner = owner, .native = native };
    }
    pub fn deinit(self: *Bridge) void {
        self.revoke(.integration_lost);
        self.rx.deinit(self.allocator);
        self.tx.deinit(self.allocator);
        zw_local_edit_destroy(self.native);
    }
    pub fn pollFd(self: *const Bridge) c_int {
        return if (self.disabled) -1 else zw_local_edit_poll_fd(self.native);
    }
    pub fn bootstrap(self: *Bridge) [*:0]const u8 {
        return zw_local_edit_directory(self.native);
    }
    pub fn revoke(self: *Bridge, reason: @FieldType(edit.Outcome, "reason")) void {
        if (self.snapshot) |*snapshot| snapshot.deinit(self.allocator);
        self.snapshot = null;
        if (self.pending) |pending| self.outcome = .{ .operation = pending.request.operation, .applied = false, .reason = reason };
        self.pending = null;
        // Revoking an edit (including Ctrl-C) invalidates observations, not
        // the already authenticated transport. Only a connection change may
        // require another hello; otherwise a fresh shell snapshot must remain
        // receivable and the old handshake deadline must not fire again.
        self.input_dirty = true;
        self.observation = null;
    }
    pub fn markInput(self: *Bridge) void {
        self.input_dirty = true;
        self.input_epoch +|= 1;
    }
    /// Called only after every queued PTY input byte has been written. A
    /// private observation barrier prevents an older snapshot from restoring
    /// trust while input is still in the shell's terminal queue.
    pub fn synchronizeInput(self: *Bridge) void {
        // A local cancellation discards the old snapshot. Its authenticated
        // connection still needs an observation barrier to learn the actual
        // current prompt, even when ZLE has no changed buffer to publish.
        if (!self.hello or self.disabled or self.pending != null) return;
        if (self.observation) |value| if (value.epoch == self.input_epoch) return;
        self.next_observation = std.math.add(u64, self.next_observation, 1) catch {
            self.fail();
            return;
        };
        var barrier: [32]u8 = undefined;
        self.send(&.{ "observe", decimal(&barrier, self.next_observation) catch unreachable }) catch {
            self.fail();
            return;
        };
        self.observation = .{ .id = self.next_observation, .epoch = self.input_epoch };
    }
    pub fn request(self: *Bridge, value: edit.Request, now: i64) !void {
        if (self.disabled or !self.hello or self.input_dirty) return error.TrustedEditUnavailable;
        if (self.pending != null or self.outcome != null) return error.TrustedEditPending;
        const current = self.snapshot orelse return error.TrustedEditUnavailable;
        if (!current.editable() or value.token != current.token or value.revision != current.revision) return error.StaleEdit;
        if (value.operation <= self.last_operation or value.operation == 0) return error.StaleOperation;
        if (value.replacement.len > edit.max_buffer or !std.unicode.utf8ValidateSlice(value.replacement) or std.mem.indexOfScalar(u8, value.replacement, 0) != null) return error.InvalidReplacement;
        if (value.kind == .begin and current.buffer.len != 0) return error.StaleEdit;
        if (value.kind == .end and (value.lease == 0 or value.lease != current.lease)) return error.StaleEdit;
        var op: [32]u8 = undefined;
        var token: [32]u8 = undefined;
        var revision: [32]u8 = undefined;
        var cursor: [32]u8 = undefined;
        var lease: [32]u8 = undefined;
        try self.send(&.{ @tagName(value.kind), try decimal(&op, value.operation), try decimal(&token, value.token), try decimal(&revision, value.revision), current.buffer, try decimal(&cursor, current.cursor), if (value.kind == .end) try decimal(&lease, value.lease) else value.replacement });
        // request strings were copied by encode; retain only scalar metadata.
        var pending = value;
        pending.replacement = "";
        self.pending = .{ .request = pending, .deadline = now + 500, .replacement_hash = std.hash.Wyhash.hash(0, value.replacement), .replacement_cursor = try std.unicode.utf8CountCodepoints(value.replacement) };
        self.last_operation = value.operation;
    }
    fn send(self: *Bridge, fields: []const []const u8) !void {
        if (self.tx.items.len - self.tx_offset > 256 * 1024) return error.ProtocolQueueFull;
        var session: [32]u8 = undefined;
        var generation: [32]u8 = undefined;
        var sequence: [32]u8 = undefined;
        var all: [24][]const u8 = undefined;
        self.sequence += 1;
        all[0] = "1";
        all[1] = try decimal(&session, @backingInt(self.owner.session_id));
        all[2] = try decimal(&generation, self.owner.generation);
        all[3] = std.mem.span(zw_local_edit_nonce(self.native));
        all[4] = try decimal(&sequence, self.sequence);
        @memcpy(all[5..][0..fields.len], fields);
        const frame = try edit.encode(self.allocator, all[0 .. fields.len + 5]);
        defer self.allocator.free(frame);
        try self.tx.appendSlice(self.allocator, frame);
    }
    pub fn poll(self: *Bridge, shell_pid: i32, now: i64) void {
        if (self.disabled) return;
        // The first precmd runs only after the user's startup files finish.
        // Keep listening for the owning shell for its session lifetime; until
        // its authenticated hello/snapshot arrives no edit is trusted. The
        // handshake deadline below starts only after a peer is accepted.
        if (self.pending) |pending| if (now >= pending.deadline) {
            self.revoke(.timeout);
            self.hello = true;
            self.markInput();
            self.synchronizeInput();
        };
        var bytes: [8192]u8 = undefined;
        for (0..32) |_| {
            var count: usize = 0;
            switch (zw_local_edit_read(self.native, shell_pid, &bytes, bytes.len, &count)) {
                0 => break,
                1 => self.rx.appendSlice(self.allocator, bytes[0..count]) catch {
                    self.fail();
                    return;
                },
                2 => {
                    self.revoke(.integration_lost);
                    self.hello = false;
                    self.rx.clearRetainingCapacity();
                    // Credits and observations target this connection only.
                    // Its normal preexec close must not turn a queued write
                    // into a permanent integration failure on the next poll.
                    self.tx.clearRetainingCapacity();
                    self.tx_offset = 0;
                    self.connected_at = 0;
                    break;
                },
                3 => {
                    self.revoke(.integration_lost);
                    self.hello = false;
                    self.rx.clearRetainingCapacity();
                    self.tx.clearRetainingCapacity();
                    self.tx_offset = 0;
                    self.last_received = 0;
                    self.sequence = 0;
                    self.connected_at = now;
                },
                else => {
                    self.fail();
                    return;
                },
            }
            if (self.rx.items.len > edit.max_frame + 8) {
                self.fail();
                return;
            }
            self.consume() catch {
                self.fail();
                return;
            };
        }
        if (!self.hello and self.connected_at != 0 and now - self.connected_at > 2000) {
            self.fail();
            return;
        }
        if (self.tx_offset < self.tx.items.len) {
            var count: usize = 0;
            if (zw_local_edit_write(self.native, self.tx.items[self.tx_offset..].ptr, self.tx.items.len - self.tx_offset, &count) < 0) {
                self.fail();
                return;
            }
            self.tx_offset += count;
            if (self.tx_offset == self.tx.items.len) {
                self.tx.clearRetainingCapacity();
                self.tx_offset = 0;
            }
        }
    }
    fn fail(self: *Bridge) void {
        self.revoke(.integration_lost);
        self.disabled = true;
    }
    fn consume(self: *Bridge) !void {
        while (self.rx.items.len >= 8) {
            const length = try std.fmt.parseInt(usize, self.rx.items[0..8], 16);
            if (length > edit.max_frame) return error.FrameTooLarge;
            if (self.rx.items.len < length + 8) return;
            var scratch: [24][]const u8 = undefined;
            const f = try edit.decode(self.rx.items[8..][0..length], &scratch);
            try self.receive(f);
            const consumed = length + 8;
            std.mem.copyForwards(u8, self.rx.items[0 .. self.rx.items.len - consumed], self.rx.items[consumed..]);
            self.rx.items.len -= consumed;
        }
    }
    fn observeBarrier(self: *Bridge, barrier: u64) void {
        if (self.observation) |value| {
            if (value.epoch == self.input_epoch and barrier == value.id) self.input_dirty = false;
        }
    }
    fn receive(self: *Bridge, f: []const []const u8) !void {
        if (f.len < 6 or !std.mem.eql(u8, f[0], "1") or try number(f[1]) != @backingInt(self.owner.session_id) or try number(f[2]) != self.owner.generation or !std.mem.eql(u8, f[3], std.mem.span(zw_local_edit_nonce(self.native)))) return error.WrongOwner;
        const sequence = try number(f[4]);
        if (sequence <= self.last_received) return error.StaleMessage;
        self.last_received = sequence;
        if (std.mem.eql(u8, f[5], "hello")) {
            if (f.len != 8 or !std.mem.eql(u8, f[6], "5.9") or !std.mem.eql(u8, f[7], "nonblocking_cloexec")) return error.Unsupported;
            self.hello = true;
        } else if (!self.hello) return error.MissingHello else if (std.mem.eql(u8, f[5], "snapshot")) {
            if (f.len != 17 or f[8].len > edit.max_buffer or !std.unicode.utf8ValidateSlice(f[8])) return error.InvalidSnapshot;
            const view: edit.Snapshot = .{ .owner = self.owner, .token = try number(f[6]), .revision = try number(f[7]), .buffer = @constCast(f[8]), .cursor = try number(f[9]), .mark = try number(f[10]), .region = try number(f[11]), .keymap = @constCast(f[12]), .context = @constCast(f[13]), .prebuffer = @constCast(f[14]), .lease = try number(f[15]) };
            const copy = try view.clone(self.allocator);
            if (self.snapshot) |*old| old.deinit(self.allocator);
            self.snapshot = copy;
            self.observeBarrier(try number(f[16]));
        } else if (std.mem.eql(u8, f[5], "revoked")) {
            self.revoke(.integration_lost);
            self.hello = true;
        } else if (std.mem.eql(u8, f[5], "applied") or std.mem.eql(u8, f[5], "rejected")) {
            const operation = if (f.len > 6) try number(f[6]) else return error.InvalidAck;
            const pending = self.pending orelse return;
            if (operation != pending.request.operation) return;
            const applied = std.mem.eql(u8, f[5], "applied");
            if (applied and (f.len != 12 or try number(f[7]) != pending.request.revision)) return error.InvalidAck;
            if (applied and pending.request.kind == .replace and (std.hash.Wyhash.hash(0, f[9]) != pending.replacement_hash or try number(f[10]) != pending.replacement_cursor)) return error.InvalidAck;
            self.outcome = .{ .operation = operation, .applied = applied, .revision = if (applied) try number(f[8]) else 0, .lease = if (applied) try number(f[11]) else 0, .reason = if (applied) .none else .rejected };
            self.pending = null;
        } else return error.InvalidMessage;
        try self.send(&.{"credit"});
    }
};
fn decimal(buffer: []u8, value: u64) ![]const u8 {
    return std.fmt.bufPrint(buffer, "{d}", .{value});
}
fn number(value: []const u8) !u64 {
    return std.fmt.parseInt(u64, value, 10);
}

test "observation accepts only the current connection barrier and input epoch" {
    var bridge: Bridge = .{ .allocator = std.testing.allocator, .owner = .{ .session_id = @fromBackingInt(1) }, .native = undefined, .input_dirty = true, .input_epoch = 2, .observation = .{ .id = 9, .epoch = 2 } };
    bridge.observeBarrier(8);
    try std.testing.expect(bridge.input_dirty);
    bridge.markInput();
    bridge.observeBarrier(9);
    try std.testing.expect(bridge.input_dirty);
    bridge.observation = .{ .id = 10, .epoch = 3 };
    bridge.observeBarrier(9);
    try std.testing.expect(bridge.input_dirty);
    bridge.observeBarrier(10);
    try std.testing.expect(!bridge.input_dirty);
    bridge.revoke(.integration_lost);
    bridge.observeBarrier(10);
    try std.testing.expect(bridge.input_dirty and bridge.observation == null);
}
