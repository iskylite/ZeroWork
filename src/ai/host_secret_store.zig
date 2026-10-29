//! Host-only, one-use secrets. Never serialize Ref, Binding or Store to tools,
//! assistant history, journals or diagnostics. Callers supply a monotonic clock.
const std = @import("std");
const host = @import("host_tools.zig");
const identity = @import("../host/identity.zig");
const execution = @import("../host/terminal_execution.zig");
pub const lifetime_ms: u64 = 60_000;
pub const max_bytes = 1024;
pub const Binding = struct {
    context: host.Context,
    handle: identity.SessionHandle,
    grant: execution.Grant,
    wait_sequence: u64,
    input_sequence: u64,
    pub fn validate(self: Binding) !void {
        try self.context.validate();
        if (@backingInt(self.handle.session_id) == 0 or self.handle.generation == 0 or !self.grant.execution_id.valid() or !self.grant.task_id.eql(self.context.task_id) or self.grant.fence == 0 or self.grant.input_epoch == 0 or self.grant.ownership_revision == 0 or self.wait_sequence == 0 or self.input_sequence == 0) return error.InvalidSecretBinding;
    }
    pub fn eql(self: Binding, other: Binding) bool {
        return self.context.eql(other.context) and self.handle.eql(other.handle) and std.meta.eql(self.grant, other.grant) and self.wait_sequence == other.wait_sequence and self.input_sequence == other.input_sequence;
    }
};
/// Opaque host memory capability. There is intentionally no text/JSON form.
pub const Ref = struct { token: [32]u8 };
pub const Sink = struct {
    context: *anyopaque,
    /// Must revalidate live authority and synchronously transfer bytes to the
    /// dedicated, attested consumer; it must not retain this borrowed slice.
    submit: *const fn (*anyopaque, Binding, []const u8) anyerror!void,
};
const Entry = struct {
    reference: Ref,
    binding: Binding,
    created_ms: u64,
    bytes: [max_bytes]u8 = @splat(0),
    len: usize,
};
pub const Store = struct {
    entries: [4]?Entry = @splat(null),
    /// Takes ownership of input immediately, including on validation failure.
    pub fn deposit(self: *Store, binding: Binding, input: []u8, now_ms: u64) !Ref {
        defer std.crypto.secureZero(u8, input);
        try binding.validate();
        try validateValue(input);
        self.expire(now_ms);
        for (&self.entries) |*slot| if (slot.* == null) {
            var ref: Ref = undefined;
            while (true) {
                std.c.arc4random_buf(&ref.token, ref.token.len);
                if (!std.mem.allEqual(u8, &ref.token, 0)) break;
            }
            slot.* = .{ .reference = ref, .binding = binding, .created_ms = now_ms, .len = input.len };
            @memcpy(slot.*.?.bytes[0..input.len], input);
            return ref;
        };
        return error.HostSecretBusy;
    }
    /// Every matching-ref attempt consumes it, including stale authority,
    /// expiry and sink failures. No retry after an uncertain private write.
    pub fn consume(self: *Store, ref: Ref, binding: Binding, now_ms: u64, sink: Sink) !void {
        if (std.mem.allEqual(u8, &ref.token, 0)) return error.HostSecretNotFound;
        for (&self.entries) |*slot| if (slot.*) |*entry| {
            if (!std.crypto.timing_safe.eql([32]u8, ref.token, entry.reference.token)) continue;
            defer clear(slot);
            if (!entry.binding.eql(binding)) return error.SecretScopeChanged;
            if (expired(entry.created_ms, now_ms)) return error.HostSecretExpired;
            // Erase capability before entering external code (reentrancy fails).
            std.crypto.secureZero(u8, &entry.reference.token);
            try sink.submit(sink.context, entry.binding, entry.bytes[0..entry.len]);
            return;
        };
        return error.HostSecretNotFound;
    }
    pub fn expire(self: *Store, now_ms: u64) void {
        for (&self.entries) |*slot| if (slot.*) |*entry| if (expired(entry.created_ms, now_ms)) clear(slot);
    }
    pub fn cancelTask(self: *Store, cid: identity.ConversationId, task: identity.TaskId) void {
        for (&self.entries) |*slot| if (slot.*) |*entry| if (entry.binding.context.conversation_id.eql(cid) and entry.binding.context.task_id.eql(task)) clear(slot);
    }
    pub fn cancelSession(self: *Store, handle: identity.SessionHandle) void {
        for (&self.entries) |*slot| if (slot.*) |*entry| if (entry.binding.handle.eql(handle)) clear(slot);
    }
    pub fn cancelAll(self: *Store) void {
        for (&self.entries) |*slot| clear(slot);
    }
    pub fn deinit(self: *Store) void {
        self.cancelAll();
    }
};
fn expired(created: u64, now: u64) bool {
    return now < created or now - created >= lifetime_ms;
}
fn clear(slot: *?Entry) void {
    if (slot.*) |*entry| std.crypto.secureZero(u8, std.mem.asBytes(entry));
    slot.* = null;
}
pub fn validateValue(value: []const u8) !void {
    if (value.len == 0 or value.len > max_bytes or !std.unicode.utf8ValidateSlice(value)) return error.InvalidHostSecret;
    var view = std.unicode.Utf8View.init(value) catch return error.InvalidHostSecret;
    var it = view.iterator();
    while (it.nextCodepoint()) |cp| if (cp < 0x20 or (cp >= 0x7f and cp <= 0x9f)) return error.InvalidHostSecret;
}
fn fixture() Binding {
    return .{ .context = .{ .conversation_id = .{ .bytes = @splat(1) }, .task_id = .{ .bytes = @splat(2) }, .binding = .{ .session = 1 }, .binding_revision = 1, .grant_revision = 1 }, .handle = .{ .session_id = @fromBackingInt(1), .generation = 1 }, .grant = .{ .execution_id = .{ .bytes = @splat(3) }, .task_id = .{ .bytes = @splat(2) }, .fence = 1, .input_epoch = 1, .ownership_revision = 1 }, .wait_sequence = 1, .input_sequence = 1 };
}
const Spy = struct {
    calls: usize = 0,
    fail: bool = false,
    fn submit(raw: *anyopaque, _: Binding, bytes: []const u8) !void {
        const self: *Spy = @ptrCast(@alignCast(raw));
        self.calls += 1;
        try std.testing.expectEqualStrings("fixture-only-secret", bytes);
        if (self.fail) return error.TestConsumerFailed;
    }
    fn sink(self: *Spy) Sink {
        return .{ .context = self, .submit = submit };
    }
};
test "host secret ownership, one use and sink failure all erase" {
    var store: Store = .{};
    defer store.deinit();
    var spy: Spy = .{};
    var value = "fixture-only-secret".*;
    const ref = try store.deposit(fixture(), &value, 100);
    try std.testing.expect(std.mem.allEqual(u8, &value, 0));
    try store.consume(ref, fixture(), 101, spy.sink());
    try std.testing.expectError(error.HostSecretNotFound, store.consume(ref, fixture(), 102, spy.sink()));
    try std.testing.expectEqual(@as(usize, 1), spy.calls);
    value = "fixture-only-secret".*;
    const second = try store.deposit(fixture(), &value, 100);
    spy.fail = true;
    try std.testing.expectError(error.TestConsumerFailed, store.consume(second, fixture(), 101, spy.sink()));
    try std.testing.expectError(error.HostSecretNotFound, store.consume(second, fixture(), 102, spy.sink()));
    try std.testing.expect(store.entries[0] == null);
}
test "host secret binds every authority and input identity" {
    var store: Store = .{};
    defer store.deinit();
    var spy: Spy = .{};
    for (0..13) |field| {
        var value = "fixture-only-secret".*;
        const ref = try store.deposit(fixture(), &value, 0);
        var stale = fixture();
        switch (field) {
            0 => stale.context.conversation_id.bytes[0] += 1,
            1 => stale.context.task_id.bytes[0] += 1,
            2 => stale.context.binding = .{ .group = 1 },
            3 => stale.context.binding_revision += 1,
            4 => stale.context.grant_revision += 1,
            5 => stale.handle.session_id = @fromBackingInt(2),
            6 => stale.handle.generation += 1,
            7 => stale.grant.execution_id.bytes[0] += 1,
            8 => stale.grant.fence += 1,
            9 => stale.grant.input_epoch += 1,
            10 => stale.grant.ownership_revision += 1,
            11 => stale.wait_sequence += 1,
            12 => stale.input_sequence += 1,
            else => unreachable,
        }
        try std.testing.expectError(error.SecretScopeChanged, store.consume(ref, stale, 1, spy.sink()));
        try std.testing.expectError(error.HostSecretNotFound, store.consume(ref, fixture(), 1, spy.sink()));
    }
    try std.testing.expectEqual(@as(usize, 0), spy.calls);
}
test "host secret expiry rollback cancellation and invalid values zero input" {
    var store: Store = .{};
    defer store.deinit();
    var spy: Spy = .{};
    var value = "fixture-only-secret".*;
    const ref = try store.deposit(fixture(), &value, 100);
    try std.testing.expectError(error.HostSecretExpired, store.consume(ref, fixture(), 60_100, spy.sink()));
    value = "fixture-only-secret".*;
    const rollback = try store.deposit(fixture(), &value, 100);
    try std.testing.expectError(error.HostSecretExpired, store.consume(rollback, fixture(), 99, spy.sink()));
    value = "fixture-only-secret".*;
    const cancelled = try store.deposit(fixture(), &value, 100);
    store.cancelTask(fixture().context.conversation_id, fixture().context.task_id);
    try std.testing.expectError(error.HostSecretNotFound, store.consume(cancelled, fixture(), 101, spy.sink()));
    var invalid = "test\nfixture".*;
    try std.testing.expectError(error.InvalidHostSecret, store.deposit(fixture(), &invalid, 100));
    try std.testing.expect(std.mem.allEqual(u8, &invalid, 0));
}

test "host secret store bounded capacity expiry session and shutdown erase" {
    var store: Store = .{};
    defer store.deinit();
    var refs: [4]Ref = undefined;
    for (&refs) |*ref| {
        var value = "fixture-only-secret".*;
        ref.* = try store.deposit(fixture(), &value, 100);
    }
    var overflow = "fixture-only-secret".*;
    try std.testing.expectError(error.HostSecretBusy, store.deposit(fixture(), &overflow, 100));
    try std.testing.expect(std.mem.allEqual(u8, &overflow, 0));
    store.cancelSession(fixture().handle);
    for (store.entries) |entry| try std.testing.expect(entry == null);
    var value = "fixture-only-secret".*;
    _ = try store.deposit(fixture(), &value, 100);
    store.expire(60_100);
    try std.testing.expect(store.entries[0] == null);
    value = "fixture-only-secret".*;
    _ = try store.deposit(fixture(), &value, 100);
    store.cancelAll();
    try std.testing.expect(store.entries[0] == null);
}
