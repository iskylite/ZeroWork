//! In-memory, metadata-only approval. UI publishes an exact decision; only the
//! provider worker waits. This broker never stops commands or changes execution
//! grants and must not be waited on while holding a Bridge/UI lock.
const std = @import("std");
const host = @import("host_tools.zig");
const provider = @import("provider.zig");
const inventory = @import("inventory_grants.zig");
pub const Decision = enum { deny, allow_once, allow_conversation };

pub fn Fixed(comptime capacity: usize) type {
    return struct {
        bytes: [capacity]u8 = @splat(0),
        len: usize = 0,
        pub fn init(value: []const u8) !@This() {
            if (value.len > capacity or !std.unicode.utf8ValidateSlice(value)) return error.InvalidInventoryApproval;
            var result: @This() = .{ .len = value.len };
            @memcpy(result.bytes[0..value.len], value);
            return result;
        }
        pub fn text(self: *const @This()) []const u8 {
            return self.bytes[0..self.len];
        }
    };
}
pub const Ticket = struct {
    context: host.Context,
    selection: inventory.Selection,
    sequence: u64,
    policy_revision: u64,
    operation_id: u64,
    turn_id: u64,
    canonical_arguments_hash: [32]u8,
    tool: Fixed(provider.max_tool_name_bytes),
    call: Fixed(provider.max_tool_call_id_bytes),

    pub fn eql(self: Ticket, other: Ticket) bool {
        return self.context.eql(other.context) and self.selection.eql(other.selection) and self.sequence == other.sequence and self.policy_revision == other.policy_revision and self.operation_id == other.operation_id and self.turn_id == other.turn_id and std.mem.eql(u8, &self.canonical_arguments_hash, &other.canonical_arguments_hash) and std.mem.eql(u8, self.tool.text(), other.tool.text()) and std.mem.eql(u8, self.call.text(), other.call.text());
    }
    fn matches(self: Ticket, value: host.Invocation) bool {
        return self.context.eql(value.context) and self.operation_id == value.operation_id and self.turn_id == value.turn_id and std.mem.eql(u8, &self.canonical_arguments_hash, &value.canonical_arguments_hash) and std.mem.eql(u8, self.tool.text(), value.tool_id) and std.mem.eql(u8, self.call.text(), value.call_id);
    }
};
/// All text and identity fields are value-owned, so cancellation cannot leave
/// the main thread holding a pointer into provider/worker storage.
pub const Snapshot = struct { ticket: Ticket, target: Fixed(512), detail: Fixed(1024) };
const Entry = struct { snapshot: Snapshot, decision: ?Decision = null, once_claimed: bool = false };
const Authority = struct { context: host.Context, policy_revision: u64, sequence: u64 };

pub const Broker = struct {
    mutex: std.atomic.Mutex = .unlocked,
    live_context: ?host.Context = null,
    policy_revision: u64 = 0,
    sequence: u64 = 0,
    stopped: bool = false,
    entry: ?Entry = null,
    continuous: [64]?Authority = @splat(null),
    // Decisions are bounded per Task. Once full, fail closed instead of asking
    // again or silently evicting a denied semantic request.
    seen: [128][32]u8 = undefined,
    seen_contexts: [128]host.Context = undefined,
    seen_invocations: [128]inventory.InvocationIdentity = undefined,
    seen_sequences: [128]u64 = undefined,
    seen_consumed: [128]bool = undefined,
    seen_len: usize = 0,

    fn lock(self: *Broker) void {
        while (!self.mutex.tryLock()) std.atomic.spinLoopHint();
    }
    pub fn configure(self: *Broker, context: host.Context, policy_revision: u64) !void {
        try context.validate();
        if (policy_revision == 0) return error.InvalidInventoryApproval;
        self.lock();
        defer self.mutex.unlock();
        if (self.live_context) |previous| {
            if (!previous.eql(context) or self.policy_revision != policy_revision) self.entry = null;
        }
        var index: usize = 0;
        while (index < self.seen_len) {
            const saved = self.seen_contexts[index];
            if (saved.conversation_id.eql(context.conversation_id) and (!saved.eql(context) or (self.live_context != null and self.live_context.?.conversation_id.eql(context.conversation_id) and self.policy_revision != policy_revision))) {
                self.removeSeen(index);
            } else index += 1;
        }
        for (&self.continuous) |*slot| if (slot.*) |grant| {
            if (grant.context.conversation_id.eql(context.conversation_id) and (!sameAuthority(grant.context, context) or grant.policy_revision != policy_revision)) slot.* = null;
        };
        self.live_context = context;
        self.policy_revision = policy_revision;
        self.stopped = false;
    }
    /// Captured on the main thread after confirming this particular workspace
    /// query actually reaches outside its binding. No model-facing grant flag.
    pub fn begin(self: *Broker, invocation: host.Invocation, selection: inventory.Selection, policy_revision: u64, allocator: std.mem.Allocator) !Ticket {
        try validateRequest(invocation, allocator);
        if (std.mem.allEqual(u8, &selection.membership_digest, 0)) return error.InvalidInventoryApproval;
        const key = try semanticKey(invocation, allocator);
        self.lock();
        defer self.mutex.unlock();
        if (self.stopped) return error.CancelledBeforeDispatch;
        if (self.live_context == null or !self.live_context.?.eql(invocation.context) or self.policy_revision != policy_revision) return error.ScopeChanged;
        if (self.entry != null) return error.InventoryApprovalBusy;
        const continuous = self.currentAuthority(invocation.context, policy_revision) != null;
        if (!continuous) {
            const exact = inventory.InvocationIdentity.capture(invocation);
            for (self.seen[0..self.seen_len], 0..) |previous, index| {
                if (self.seen_consumed[index]) {
                    if (self.seen_invocations[index].eql(exact)) return error.InventoryAlreadyConsumed;
                } else if (std.mem.eql(u8, &key, &previous)) return error.InventoryApprovalDenied;
            }
            if (self.seen_len == self.seen.len) return error.InventoryRequestLimit;
        }
        self.sequence = std.math.add(u64, self.sequence, 1) catch return error.InventorySequenceExhausted;
        const ticket: Ticket = .{ .context = invocation.context, .selection = selection, .sequence = self.sequence, .policy_revision = policy_revision, .operation_id = invocation.operation_id, .turn_id = invocation.turn_id, .canonical_arguments_hash = invocation.canonical_arguments_hash, .tool = try Fixed(provider.max_tool_name_bytes).init(invocation.tool_id), .call = try Fixed(provider.max_tool_call_id_bytes).init(invocation.call_id) };
        self.entry = .{ .snapshot = .{ .ticket = ticket, .target = try Fixed(512).init("工作区中打开的会话与会话组"), .detail = try Fixed(1024).init("AI需要查看已打开会话和会话组的名称、连接状态与分组。不会读取终端内容或执行命令。") }, .decision = if (continuous) .allow_conversation else null };
        if (!continuous) {
            self.seen[self.seen_len] = key;
            self.seen_contexts[self.seen_len] = invocation.context;
            self.seen_invocations[self.seen_len] = inventory.InvocationIdentity.capture(invocation);
            self.seen_sequences[self.seen_len] = ticket.sequence;
            self.seen_consumed[self.seen_len] = false;
            self.seen_len += 1;
        }
        return ticket;
    }
    pub fn snapshot(self: *Broker) ?Snapshot {
        self.lock();
        defer self.mutex.unlock();
        const entry = self.entry orelse return null;
        return if (!self.stopped and entry.decision == null) entry.snapshot else null;
    }
    /// Called only by a real UI event; exact snapshot equality prevents stale
    /// presses from approving a later request.
    pub fn decide(self: *Broker, ticket: Ticket, decision: Decision) !void {
        self.lock();
        defer self.mutex.unlock();
        const entry = if (self.entry) |*value| value else return error.StaleInventoryDecision;
        if (self.stopped or entry.decision != null or !entry.snapshot.ticket.eql(ticket)) return error.StaleInventoryDecision;
        if (decision == .allow_conversation) {
            var target: ?*?Authority = null;
            for (&self.continuous) |*slot| {
                if (slot.* == null or slot.*.?.context.conversation_id.eql(ticket.context.conversation_id)) {
                    target = slot;
                    if (slot.* != null) break;
                }
            }
            const slot = target orelse return error.InventoryRequestLimit;
            slot.* = .{ .context = ticket.context, .policy_revision = ticket.policy_revision, .sequence = ticket.sequence };
        }
        entry.decision = decision;
    }
    pub fn poll(self: *Broker, ticket: Ticket) !bool {
        self.lock();
        defer self.mutex.unlock();
        if (self.stopped) return error.CancelledBeforeDispatch;
        const entry = self.entry orelse return error.StaleInventoryDecision;
        if (!entry.snapshot.ticket.eql(ticket)) return error.StaleInventoryDecision;
        return if (entry.decision) |decision| switch (decision) {
            .deny => error.InventoryApprovalDenied,
            .allow_once, .allow_conversation => true,
        } else false;
    }
    pub fn wait(self: *Broker, ticket: Ticket, cancel: ?*provider.CancelToken) !void {
        errdefer self.finish(ticket);
        while (true) {
            if (cancel) |token| if (token.isCancelled()) return error.CancelledBeforeDispatch;
            if (try self.poll(ticket)) return;
            @import("retry.zig").wait(10, cancel) catch return error.CancelledBeforeDispatch;
        }
    }
    /// Fresh main-thread context and selection are required immediately before
    /// projection. Continuous authority applies to newly opened sessions too;
    /// each returned grant still freezes the exact current snapshot.
    pub fn grantForInvocation(self: *Broker, invocation: host.Invocation, selection: inventory.Selection, policy_revision: u64) ?inventory.Grant {
        const actual = @import("canonical_arguments.zig").digest(std.heap.page_allocator, invocation.arguments) catch return null;
        if (!std.mem.eql(u8, &actual, &invocation.canonical_arguments_hash)) return null;
        self.lock();
        defer self.mutex.unlock();
        if (self.stopped or self.live_context == null or !self.live_context.?.eql(invocation.context) or self.policy_revision != policy_revision or invocation.authority != .conversation_context) return null;
        if (self.currentAuthority(invocation.context, policy_revision)) |authority| return makeGrant(invocation, selection, authority.sequence, .conversation);
        const entry = if (self.entry) |*value| value else return null;
        const ticket = entry.snapshot.ticket;
        if (entry.decision != .allow_once or entry.once_claimed or !ticket.matches(invocation) or !ticket.selection.eql(selection)) return null;
        entry.once_claimed = true;
        return makeGrant(invocation, selection, ticket.sequence, .invocation);
    }
    /// Exactly-once consumption belongs after query execution, including a
    /// failed/stale read; a permit is never saved for a later invocation.
    pub fn finish(self: *Broker, ticket: Ticket) void {
        self.lock();
        defer self.mutex.unlock();
        if (self.entry) |entry| if (entry.snapshot.ticket.eql(ticket)) {
            if (entry.decision == .allow_once or entry.decision == .allow_conversation) {
                for (self.seen_sequences[0..self.seen_len], 0..) |sequence, index| {
                    if (sequence == ticket.sequence) self.seen_consumed[index] = true;
                }
            }
            self.entry = null;
        };
    }
    /// Composer permission menu lookup: no TaskId is created for this read.
    pub fn conversationAllowed(self: *Broker, conversation_id: @import("../host/identity.zig").ConversationId, binding: @import("tool_scope.zig").Owner, binding_revision: u64, policy_revision: u64) bool {
        self.lock();
        defer self.mutex.unlock();
        for (&self.continuous) |*slot| if (slot.*) |grant| {
            if (!grant.context.conversation_id.eql(conversation_id)) continue;
            if (grant.context.binding.eql(binding) and grant.context.binding_revision == binding_revision and grant.policy_revision == policy_revision) return true;
            // Observing a changed binding/configuration invalidates authority;
            // restoring an old option later cannot resurrect a prior grant.
            slot.* = null;
        };
        return false;
    }
    pub fn revokeConversation(self: *Broker, conversation_id: @import("../host/identity.zig").ConversationId) void {
        self.lock();
        defer self.mutex.unlock();
        for (&self.continuous) |*slot| if (slot.*) |grant| {
            if (grant.context.conversation_id.eql(conversation_id)) slot.* = null;
        };
        if (self.entry) |entry| if (entry.snapshot.ticket.context.conversation_id.eql(conversation_id)) {
            self.entry = null;
        };
    }
    pub fn continuousAllowed(self: *Broker) bool {
        self.lock();
        defer self.mutex.unlock();
        const context = self.live_context orelse return false;
        return self.currentAuthority(context, self.policy_revision) != null;
    }
    /// Stop cancels pending discovery only. Already-running commands belong to
    /// other controllers; conversation authority survives a new Task.
    pub fn stop(self: *Broker) void {
        self.lock();
        defer self.mutex.unlock();
        self.stopped = true;
        self.entry = null;
    }
    /// Revocation does not stop or invalidate the provider's active round.
    pub fn revoke(self: *Broker) void {
        self.lock();
        defer self.mutex.unlock();
        if (self.live_context) |context| for (&self.continuous) |*slot| if (slot.*) |grant| {
            if (grant.context.conversation_id.eql(context.conversation_id)) slot.* = null;
        };
        self.entry = null;
    }
    pub fn clearConversation(self: *Broker, conversation_id: @import("../host/identity.zig").ConversationId) void {
        self.lock();
        defer self.mutex.unlock();
        for (&self.continuous) |*slot| if (slot.*) |grant| {
            if (grant.context.conversation_id.eql(conversation_id)) slot.* = null;
        };
        if (self.entry) |entry| if (entry.snapshot.ticket.context.conversation_id.eql(conversation_id)) {
            self.entry = null;
        };
        var index: usize = 0;
        while (index < self.seen_len) {
            if (self.seen_contexts[index].conversation_id.eql(conversation_id)) self.removeSeen(index) else index += 1;
        }
        if (self.live_context) |context| if (context.conversation_id.eql(conversation_id)) {
            self.live_context = null;
            self.stopped = true;
        };
    }
    fn removeSeen(self: *Broker, index: usize) void {
        self.seen_len -= 1;
        self.seen[index] = self.seen[self.seen_len];
        self.seen_contexts[index] = self.seen_contexts[self.seen_len];
        self.seen_invocations[index] = self.seen_invocations[self.seen_len];
        self.seen_sequences[index] = self.seen_sequences[self.seen_len];
        self.seen_consumed[index] = self.seen_consumed[self.seen_len];
    }
    fn currentAuthority(self: *const Broker, context: host.Context, policy_revision: u64) ?Authority {
        for (self.continuous) |slot| if (slot) |grant| {
            if (sameAuthority(grant.context, context) and grant.policy_revision == policy_revision) return grant;
        };
        return null;
    }
    /// Close/replacement of the conversation clears all in-memory authority.
    pub fn clear(self: *Broker) void {
        self.lock();
        defer self.mutex.unlock();
        self.live_context = null;
        self.entry = null;
        self.continuous = @splat(null);
        self.policy_revision = 0;
        self.seen_len = 0;
        self.stopped = true;
    }
};
fn sameAuthority(a: host.Context, b: host.Context) bool {
    return a.conversation_id.eql(b.conversation_id) and a.binding.eql(b.binding) and a.binding_revision == b.binding_revision and a.grant_revision == b.grant_revision;
}
fn makeGrant(invocation: host.Invocation, selection: inventory.Selection, sequence: u64, duration: inventory.Duration) inventory.Grant {
    return .{ .context = invocation.context, .selection = selection, .sequence = sequence, .issued_at = 0, .expires_at = std.math.maxInt(i64), .duration = duration, .invocation = if (duration == .invocation) inventory.InvocationIdentity.capture(invocation) else null };
}
fn validateRequest(value: host.Invocation, allocator: std.mem.Allocator) !void {
    try value.context.validate();
    if (value.authority != .conversation_context or value.operation_id == 0 or value.turn_id == 0 or value.call_id.len == 0 or value.arguments != .object) return error.InvalidInventoryApproval;
    if (!std.mem.eql(u8, value.tool_id, "host.list_sessions") and !std.mem.eql(u8, value.tool_id, "host.list_groups")) return error.InvalidInventoryApproval;
    const requested_scope = value.arguments.object.get("scope") orelse return error.InvalidInventoryApproval;
    if (requested_scope != .string or !std.mem.eql(u8, requested_scope.string, "workspace")) return error.InvalidInventoryApproval;
    const canonical = try @import("canonical_arguments.zig").digest(allocator, value.arguments);
    var raw_hash: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(value.arguments_json, &raw_hash, .{});
    if (!std.mem.eql(u8, &canonical, &value.canonical_arguments_hash) or !std.mem.eql(u8, &raw_hash, &value.arguments_hash)) return error.InvalidInventoryApproval;
}
fn semanticKey(value: host.Invocation, allocator: std.mem.Allocator) ![32]u8 {
    const wire = try std.json.Stringify.valueAlloc(allocator, .{ value.context, value.tool_id, value.canonical_arguments_hash }, .{});
    defer allocator.free(wire);
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(wire, &digest, .{});
    return digest;
}
test {
    _ = @import("inventory_approval_tests.zig");
}
