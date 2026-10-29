//! Main-thread secure collector coordinator. Only metadata/status is public;
//! secret bytes and one-use refs never cross the model/worker JSON boundary.
const std = @import("std");
const secret = @import("../ai/host_secret_store.zig");
const identity = @import("../host/identity.zig");
pub const Binding = secret.Binding;
pub const State = enum { awaiting_host_secret, secret_submitted, cancelled };
pub const Theme = extern struct { background: u32, foreground: u32, secondary: u32, well: u32, accent: u32 };
/// This API is an internal native boundary, never a provider tool adapter.
pub const Collector = struct {
    context: ?*anyopaque = null,
    open: *const fn (?*anyopaque, [:0]const u8, Theme) anyerror!*anyopaque,
    poll: *const fn (?*anyopaque, *anyopaque, []u8) anyerror!?usize,
    close: *const fn (?*anyopaque, *anyopaque) void,
};
pub const Authority = struct {
    context: *anyopaque,
    /// Check current CID/Task/binding/config/grants, handle generation,
    /// execution/fence/epoch/wait/input seq and attested host_secret consumer.
    validate: *const fn (*anyopaque, Binding) anyerror!void,
    submit: *const fn (*anyopaque, Binding, []const u8) anyerror!void,
    cancel: *const fn (*anyopaque, Binding) void,
};
const Pending = struct { binding: Binding, created_ms: u64, native: *anyopaque, submitted: bool = false };
pub const Controller = struct {
    store: secret.Store = .{},
    collector: Collector = nativeCollector(),
    authority: Authority,
    pending: ?Pending = null,
    state: State = .cancelled,

    /// Success means a native secure collector was actually queued. Return
    /// awaiting_host_secret only after this succeeds. One collector per owner.
    pub fn begin(self: *Controller, binding: Binding, now_ms: u64, theme: Theme) !void {
        if (self.pending != null) return error.HostSecretBusy;
        try binding.validate();
        try self.authority.validate(self.authority.context, binding);
        var metadata: [256]u8 = undefined;
        const text = try std.fmt.bufPrint(metadata[0 .. metadata.len - 1], "终端 {d}/{d} · 受控 zerowork_secret_consume\n授权 {d} · 等待 {d}", .{ @backingInt(binding.handle.session_id), binding.handle.generation, binding.grant.fence, binding.wait_sequence });
        metadata[text.len] = 0;
        const handle = try self.collector.open(self.collector.context, metadata[0..text.len :0], theme);
        self.pending = .{ .binding = binding, .created_ms = now_ms, .native = handle };
        self.state = .awaiting_host_secret;
    }
    pub fn poll(self: *Controller, now_ms: u64) void {
        self.store.expire(now_ms);
        const pending = self.pending orelse return;
        if (now_ms < pending.created_ms or now_ms - pending.created_ms >= secret.lifetime_ms) {
            self.cancel();
            return;
        }
        self.authority.validate(self.authority.context, pending.binding) catch {
            self.cancel();
            return;
        };
        if (pending.submitted) return; // Wait for the private consumer's receipt.
        var bytes: [secret.max_bytes]u8 = @splat(0);
        defer std.crypto.secureZero(u8, &bytes);
        const length = (self.collector.poll(self.collector.context, pending.native, &bytes) catch {
            self.cancel();
            return;
        }) orelse return;
        if (length == 0 or length > bytes.len) {
            self.cancel();
            return;
        }
        const ref = self.store.deposit(pending.binding, bytes[0..length], now_ms) catch {
            self.cancel();
            return;
        };
        self.store.consume(ref, pending.binding, now_ms, .{ .context = self, .submit = transfer }) catch {
            self.cancel();
            return;
        };
        self.collector.close(self.collector.context, pending.native);
        self.pending.?.submitted = true;
        // Native pointer is no longer accessed once submitted.
    }
    fn transfer(raw: *anyopaque, binding: Binding, bytes: []const u8) !void {
        const self: *Controller = @ptrCast(@alignCast(raw));
        try self.authority.validate(self.authority.context, binding);
        try self.authority.submit(self.authority.context, binding, bytes);
    }
    /// Only a validated private secret_consumed receipt may publish success.
    pub fn consumed(self: *Controller, binding: Binding) !void {
        const pending = self.pending orelse return error.HostSecretNotFound;
        if (!pending.submitted or !pending.binding.eql(binding)) return error.SecretScopeChanged;
        self.pending = null;
        self.state = .secret_submitted;
    }
    pub fn cancel(self: *Controller) void {
        if (self.pending) |pending| {
            if (!pending.submitted) self.collector.close(self.collector.context, pending.native);
            self.authority.cancel(self.authority.context, pending.binding);
        }
        self.pending = null;
        self.store.cancelAll();
        self.state = .cancelled;
    }
    pub fn cancelTask(self: *Controller, cid: identity.ConversationId, task: identity.TaskId) void {
        if (self.pending) |pending| if (pending.binding.context.conversation_id.eql(cid) and pending.binding.context.task_id.eql(task)) self.cancel();
        self.store.cancelTask(cid, task);
    }
    pub fn cancelSession(self: *Controller, handle: identity.SessionHandle) void {
        if (self.pending) |pending| if (pending.binding.handle.eql(handle)) self.cancel();
        self.store.cancelSession(handle);
    }
    pub fn deinit(self: *Controller) void {
        self.cancel();
        self.store.deinit();
    }
};
extern fn zw_host_secret_open([*:0]const u8, *const Theme) ?*anyopaque;
extern fn zw_host_secret_poll(*anyopaque, [*]u8, usize, *usize) c_int;
extern fn zw_host_secret_close(*anyopaque) void;
fn nativeOpen(_: ?*anyopaque, metadata: [:0]const u8, theme: Theme) !*anyopaque {
    if (@import("builtin").is_test) return error.HostSecretUnavailable;
    return zw_host_secret_open(metadata.ptr, &theme) orelse error.HostSecretUnavailable;
}
fn nativePoll(_: ?*anyopaque, handle: *anyopaque, out: []u8) !?usize {
    if (@import("builtin").is_test) return error.HostSecretUnavailable;
    var length: usize = 0;
    return switch (zw_host_secret_poll(handle, out.ptr, out.len, &length)) {
        0 => null,
        1 => length,
        else => error.HostSecretCancelled,
    };
}
fn nativeClose(_: ?*anyopaque, handle: *anyopaque) void {
    if (@import("builtin").is_test) return;
    zw_host_secret_close(handle);
}
pub fn nativeCollector() Collector {
    return .{ .open = nativeOpen, .poll = nativePoll, .close = nativeClose };
}

const Fixture = struct {
    submitted: usize = 0,
    cancelled: usize = 0,
    closed: usize = 0,
    valid: bool = true,
    ready: bool = false,
    fn binding() Binding {
        return .{ .context = .{ .conversation_id = .{ .bytes = @splat(1) }, .task_id = .{ .bytes = @splat(2) }, .binding = .{ .session = 1 }, .binding_revision = 1, .grant_revision = 1 }, .handle = .{ .session_id = @fromBackingInt(1) }, .grant = .{ .execution_id = .{ .bytes = @splat(3) }, .task_id = .{ .bytes = @splat(2) }, .fence = 1, .input_epoch = 1, .ownership_revision = 1 }, .wait_sequence = 1, .input_sequence = 1 };
    }
    fn validate(raw: *anyopaque, _: Binding) !void {
        const self: *Fixture = @ptrCast(@alignCast(raw));
        if (!self.valid) return error.ScopeChanged;
    }
    fn submit(raw: *anyopaque, _: Binding, bytes: []const u8) !void {
        const self: *Fixture = @ptrCast(@alignCast(raw));
        try std.testing.expectEqualStrings("fake-only", bytes);
        self.submitted += 1;
    }
    fn cancel(raw: *anyopaque, _: Binding) void {
        const self: *Fixture = @ptrCast(@alignCast(raw));
        self.cancelled += 1;
    }
    fn open(raw: ?*anyopaque, _: [:0]const u8, _: Theme) !*anyopaque {
        return raw.?;
    }
    fn poll(raw: ?*anyopaque, _: *anyopaque, bytes: []u8) !?usize {
        const self: *Fixture = @ptrCast(@alignCast(raw.?));
        if (!self.ready) return null;
        @memcpy(bytes[0..9], "fake-only");
        return 9;
    }
    fn close(raw: ?*anyopaque, _: *anyopaque) void {
        const self: *Fixture = @ptrCast(@alignCast(raw.?));
        self.closed += 1;
    }
    fn controller(self: *Fixture) Controller {
        return .{ .authority = .{ .context = self, .validate = validate, .submit = submit, .cancel = cancel }, .collector = .{ .context = self, .open = open, .poll = poll, .close = close } };
    }
};
const test_theme: Theme = .{ .background = 0x202124ff, .foreground = 0xf0f0f0ff, .secondary = 0xb0b0b0ff, .well = 0x303134ff, .accent = 0x365f9bff };
test "host secret controller async metadata and exact consumed receipt" {
    var fixture: Fixture = .{};
    var controller = fixture.controller();
    defer controller.deinit();
    try controller.begin(Fixture.binding(), 0, test_theme);
    try std.testing.expectEqual(State.awaiting_host_secret, controller.state);
    controller.poll(1);
    try std.testing.expectEqual(@as(usize, 0), fixture.submitted);
    fixture.ready = true;
    controller.poll(2);
    try std.testing.expectEqual(@as(usize, 1), fixture.submitted);
    try std.testing.expectEqual(State.awaiting_host_secret, controller.state);
    var stale = Fixture.binding();
    stale.wait_sequence += 1;
    try std.testing.expectError(error.SecretScopeChanged, controller.consumed(stale));
    try controller.consumed(Fixture.binding());
    try std.testing.expectEqual(State.secret_submitted, controller.state);
    try std.testing.expectEqual(@as(usize, 1), fixture.closed);
}
test "host secret controller revocation timeout cancellation zero submit" {
    var fixture: Fixture = .{ .ready = true };
    var controller = fixture.controller();
    defer controller.deinit();
    try controller.begin(Fixture.binding(), 0, test_theme);
    fixture.valid = false;
    controller.poll(1);
    try std.testing.expectEqual(State.cancelled, controller.state);
    try std.testing.expectEqual(@as(usize, 0), fixture.submitted);
    fixture.valid = true;
    try controller.begin(Fixture.binding(), 10, test_theme);
    controller.poll(60_010);
    try std.testing.expectEqual(@as(usize, 0), fixture.submitted);
    try std.testing.expectEqual(@as(usize, 2), fixture.closed);
    try std.testing.expectEqual(@as(usize, 2), fixture.cancelled);
}

test "host secret controller queued cancellation does not reuse native handle" {
    var fixture: Fixture = .{ .ready = true };
    var controller = fixture.controller();
    defer controller.deinit();
    try controller.begin(Fixture.binding(), 0, test_theme);
    controller.poll(1);
    try std.testing.expectEqual(@as(usize, 1), fixture.submitted);
    try std.testing.expectEqual(@as(usize, 1), fixture.closed);
    controller.poll(60_000);
    try std.testing.expectEqual(State.cancelled, controller.state);
    try std.testing.expectEqual(@as(usize, 1), fixture.closed);
    try std.testing.expectEqual(@as(usize, 1), fixture.cancelled);
    try std.testing.expectError(error.HostSecretNotFound, controller.consumed(Fixture.binding()));
}
