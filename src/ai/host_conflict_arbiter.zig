//! Host-initiated terminal input conflict arbitration. Value-only mailbox in
//! the same shape as user_interaction.Broker: the worker publishes one kind
//! snapshot, the UI answers through the composer card, and Stop/scope changes
//! invalidate the pending request without manufacturing a decision. This is
//! deliberately outside approvals.Broker — no invocation identity backs this
//! question and no permission mode may auto-resolve it.
const std = @import("std");
const host = @import("host_tools.zig");
const provider = @import("provider.zig");
pub const Kind = enum {
    /// IME composition staged on the terminal surface.
    ime,
    /// Pending paste awaiting confirmation on the terminal surface.
    paste,
    pub fn title(self: Kind) []const u8 {
        return switch (self) {
            .ime => "终端输入被组字暂存占用",
            .paste => "终端有未确认的粘贴内容",
        };
    }
    pub fn detail(self: Kind) []const u8 {
        return switch (self) {
            .ime => "终端上有正在编辑的输入法组字内容，AI 命令无法与它一起提交。清除后将重新提交命令。",
            .paste => "终端上有等待确认的粘贴内容，AI 命令需要等它处理完才能提交。可以清除粘贴内容并继续执行。",
        };
    }
    pub fn accept_label(self: Kind) []const u8 {
        return switch (self) {
            .ime => "清除组字并继续",
            .paste => "清除粘贴并继续",
        };
    }
};
pub const Ticket = struct {
    context: host.Context,
    sequence: u64,
    kind: Kind,
    pub fn eql(a: Ticket, b: Ticket) bool {
        return a.context.eql(b.context) and a.sequence == b.sequence and a.kind == b.kind;
    }
};
pub const Snapshot = struct {
    ticket: Ticket,
    kind: Kind,
};
pub const Decision = enum { clear_and_proceed, cancel };
pub const Broker = struct {
    mutex: std.atomic.Mutex = .unlocked,
    live_context: ?host.Context = null,
    next_sequence: u64 = 1,
    entry: ?struct { snapshot: Snapshot, decision: ?Decision = null } = null,
    fn lock(self: *Broker) void {
        while (!self.mutex.tryLock()) std.atomic.spinLoopHint();
    }
    pub fn configure(self: *Broker, context: host.Context) void {
        self.lock();
        defer self.mutex.unlock();
        self.live_context = context;
        self.entry = null;
    }
    pub fn stop(self: *Broker) void {
        self.lock();
        defer self.mutex.unlock();
        self.live_context = null;
        self.entry = null;
    }
    /// New guidance invalidates this request, without stopping the task or
    /// manufacturing a decision. Waiting workers observe CancelledBeforeDispatch.
    pub fn supersede(self: *Broker) void {
        self.lock();
        defer self.mutex.unlock();
        self.entry = null;
    }
    /// Publishes one conflict question bound to the live conversation. The
    /// card is unconditional: no policy engine participates in this broker.
    pub fn begin(self: *Broker, context: host.Context, kind: Kind) !Ticket {
        try context.validate();
        self.lock();
        defer self.mutex.unlock();
        if (self.live_context == null or !self.live_context.?.eql(context)) return error.ScopeChanged;
        if (self.entry != null) return error.ConflictQuestionBusy;
        const ticket: Ticket = .{ .context = context, .sequence = self.next_sequence, .kind = kind };
        self.next_sequence = std.math.add(u64, self.next_sequence, 1) catch return error.ConflictQuestionLimit;
        self.entry = .{ .snapshot = .{ .ticket = ticket, .kind = kind } };
        return ticket;
    }
    pub fn snapshot(self: *Broker) ?Snapshot {
        self.lock();
        defer self.mutex.unlock();
        const entry = self.entry orelse return null;
        return if (entry.decision == null) entry.snapshot else null;
    }
    pub fn decide(self: *Broker, ticket: Ticket, decision: Decision) !void {
        self.lock();
        defer self.mutex.unlock();
        const entry = if (self.entry) |*value| value else return error.StaleConflictQuestion;
        if (!entry.snapshot.ticket.eql(ticket) or entry.decision != null) return error.StaleConflictQuestion;
        entry.decision = decision;
    }
    pub fn finish(self: *Broker, ticket: Ticket) void {
        self.lock();
        defer self.mutex.unlock();
        if (self.entry) |entry| if (entry.snapshot.ticket.eql(ticket)) {
            self.entry = null;
        };
    }
    pub fn poll(self: *Broker, ticket: Ticket) !?Decision {
        self.lock();
        defer self.mutex.unlock();
        const entry = self.entry orelse return error.CancelledBeforeDispatch;
        if (!entry.snapshot.ticket.eql(ticket)) return error.StaleConflictQuestion;
        return entry.decision;
    }
    pub fn wait(self: *Broker, ticket: Ticket, cancel: ?*provider.CancelToken) !Decision {
        const waiting = provider.CancelToken.beginUserWait(cancel);
        defer waiting.end();
        defer self.finish(ticket);
        while (true) {
            if (cancel) |token| if (token.isCancelled()) return error.CancelledBeforeDispatch;
            if (try self.poll(ticket)) |value| {
                if (cancel) |token| if (token.isCancelled()) return error.CancelledBeforeDispatch;
                return value;
            }
            @import("retry.zig").wait(10, cancel) catch return error.CancelledBeforeDispatch;
        }
    }
};

test "arbitration broker lifecycle matches decision flow" {
    const identity = @import("../host/identity.zig");
    const context: host.Context = .{ .conversation_id = try identity.ConversationId.parse("000000000000000000000000000000aa"), .task_id = try identity.TaskId.parse("000000000000000000000000000000bb"), .binding = .{ .session = 77 }, .binding_revision = 1, .grant_revision = 1 };
    var broker: Broker = .{};
    broker.configure(context);
    const ticket = try broker.begin(context, .paste);
    const pending = broker.snapshot().?;
    try std.testing.expect(pending.ticket.eql(ticket));
    try std.testing.expectEqual(Kind.paste, pending.kind);
    try std.testing.expect((try broker.poll(ticket)) == null);
    try broker.decide(ticket, .clear_and_proceed);
    try std.testing.expectEqual(Decision.clear_and_proceed, try broker.poll(ticket));
    try std.testing.expectEqual(Decision.clear_and_proceed, try broker.wait(ticket, null));
    try std.testing.expect(broker.snapshot() == null);
    // Stale decisions and double decisions fail closed.
    try std.testing.expectError(error.StaleConflictQuestion, broker.decide(ticket, .cancel));
    const second = try broker.begin(context, .ime);
    try std.testing.expectError(error.StaleConflictQuestion, broker.decide(ticket, .cancel));
    broker.finish(second);
    // Supersede releases a waiting worker with CancelledBeforeDispatch.
    const third = try broker.begin(context, .ime);
    broker.supersede();
    try std.testing.expectError(error.CancelledBeforeDispatch, broker.poll(third));
    // Stop invalidates the live context; begin fails closed afterwards.
    broker.stop();
    try std.testing.expectError(error.ScopeChanged, broker.begin(context, .ime));
}

test "kind copy stays nonempty for every variant" {
    inline for (.{ Kind.ime, Kind.paste }) |kind| {
        try std.testing.expect(kind.title().len > 0);
        try std.testing.expect(kind.detail().len > 0);
        try std.testing.expect(kind.accept_label().len > 0);
    }
}
