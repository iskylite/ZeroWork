//! One main-thread ingress for UI events, shortcuts and parsed app commands.
//! Issue IDs at this synchronous ingress and preserve the same ID across all
//! routes for one input event. A later ID consumes the earlier range; delayed
//! older inputs are rejected, never replayed after result/payload retirement.
const std = @import("std");
const identity = @import("identity.zig");
const actions = @import("actions.zig");
const OperationKey = @import("operation.zig").OperationKey;
const Snapshot = @import("../ui/session_lifecycle.zig").Snapshot;

pub const SelectionSnapshot = struct {
    owner: identity.CommandOwner,
    revision: u64,
    text: []const u8 = "",
    tabs: []const identity.TabId = &.{},
};
pub const Payload = union(enum) { none, text: []const u8, tab: identity.TabId, number: u64, toggle: bool };
pub const UiCommand = struct {
    command_id: u64,
    kind: actions.ActionId,
    owner: identity.CommandOwner,
    view_revision: u64,
    selection_snapshot: ?SelectionSnapshot = null,
    payload: Payload = .none,
};

/// Resolve this from the captured owner, never from a later active tab. Domain
/// controllers still validate their own handle/service revisions on submission.
pub const LiveContext = struct {
    owner: identity.CommandOwner,
    view_revision: u64,
    selection_revision: ?u64 = null,
    action_context: actions.Context,
};
pub const RejectCode = enum { invalid_command_id, already_consumed, command_id_reused, invalid_owner, stale_owner, stale_view, stale_selection, selection_required, unavailable, handler_failed };
pub const Rejection = struct { code: RejectCode, reason: []const u8, action_cause: ?actions.Cause = null };
pub const Decision = union(enum) { rejected: Rejection, accepted: OperationKey };

/// The handler returns its domain controller's operation key. It must copy or
/// transfer request data before returning accepted; this dispatcher retains at
/// most one command snapshot and creates no parallel operation journal.
pub const Handler = struct {
    context: *anyopaque,
    submit: *const fn (*anyopaque, UiCommand) anyerror!OperationKey,
};
const Recent = struct { command: Snapshot(UiCommand), decision: Decision };

pub const Dispatcher = struct {
    allocator: std.mem.Allocator,
    next_command_id: u64 = 1,
    exhausted: bool = false,
    consumed_through: u64 = 0,
    retired_through: u64 = 0,
    recent: ?Recent = null,
    dispatching: bool = false,

    pub fn deinit(self: *Dispatcher) void {
        if (self.recent) |*recent| recent.command.deinit();
        self.recent = null;
    }

    pub fn issue(self: *Dispatcher) !u64 {
        if (self.dispatching) return error.ReentrantDispatch;
        if (self.exhausted) return error.CommandIdExhausted;
        const id = self.next_command_id;
        if (id == std.math.maxInt(u64)) self.exhausted = true else self.next_command_id += 1;
        return id;
    }

    pub fn submit(self: *Dispatcher, command: UiCommand, live: LiveContext, handler: ?Handler) !Decision {
        if (self.dispatching) return error.ReentrantDispatch;
        if (command.command_id == 0 or (!self.exhausted and command.command_id >= self.next_command_id)) return reject(.invalid_command_id, "输入命令身份无效或尚未分配");
        if (command.command_id <= self.retired_through) return reject(.already_consumed, "此输入命令已处理并释放");
        if (self.recent) |recent| if (recent.command.value.command_id == command.command_id) {
            return if (sameCommand(recent.command.value, command)) recent.decision else reject(.command_id_reused, "同一输入命令身份不能用于不同动作或参数");
        };
        if (command.command_id <= self.consumed_through) return reject(.already_consumed, "此输入命令已处理或已过期");

        // Every fallible allocation is complete before a handler can start work.
        // On OOM the caller keeps ownership and may submit the same ID again.
        const owned = try Snapshot(UiCommand).init(self.allocator, command);
        self.dispatching = true;
        defer self.dispatching = false;
        const decision: Decision = if (preflight(owned.value, live, handler != null)) |failure|
            .{ .rejected = failure }
        else blk: {
            const accepted = handler.?.submit(handler.?.context, owned.value) catch |err| break :blk reject(.handler_failed, @errorName(err));
            break :blk .{ .accepted = accepted };
        };
        if (self.recent) |*recent| recent.command.deinit();
        self.recent = .{ .command = owned, .decision = decision };
        self.consumed_through = command.command_id;
        return decision;
    }

    /// Explicitly release retained input data after its source lifecycle ends.
    /// Watermarks remain for the dispatcher's entire lifetime, so an old event
    /// can never execute again after retirement or after a newer event arrives.
    pub fn retire(self: *Dispatcher, through: u64) !void {
        if (self.dispatching) return error.ReentrantDispatch;
        if (through > self.consumed_through) return error.CommandNotConsumed;
        self.retired_through = @max(self.retired_through, through);
        if (self.recent) |*recent| if (recent.command.value.command_id <= through) {
            recent.command.deinit();
            self.recent = null;
        };
    }
};

fn reject(code: RejectCode, reason: []const u8) Decision {
    return .{ .rejected = .{ .code = code, .reason = reason } };
}

fn preflight(command: UiCommand, live: LiveContext, has_handler: bool) ?Rejection {
    if (!validOwner(command.owner)) return .{ .code = .invalid_owner, .reason = "命令所属对象身份无效" };
    if (!command.owner.eql(live.owner)) return .{ .code = .stale_owner, .reason = "命令所属对象已变化" };
    if (command.view_revision == 0 or command.view_revision != live.view_revision) return .{ .code = .stale_view, .reason = "命令所属视图已变化" };
    if (command.selection_snapshot) |selection| {
        if (!selection.owner.eql(command.owner) or selection.revision == 0 or live.selection_revision != selection.revision) return .{ .code = .stale_selection, .reason = "命令捕获的选区已变化" };
    } else if (actions.descriptor(command.kind).rule.needs_selection) return .{ .code = .selection_required, .reason = "此动作需要捕获原选区" };
    var context = live.action_context;
    context.handler_ready = context.handler_ready and has_handler;
    if (actions.evaluate(command.kind, context)) |unavailable| return .{ .code = .unavailable, .reason = unavailable.reason, .action_cause = unavailable.cause };
    return null;
}

fn validOwner(owner: identity.CommandOwner) bool {
    return switch (owner) {
        .app => true,
        .asset => |asset| @backingInt(asset.id) != 0 and asset.revision != 0,
        .session => |session| @backingInt(session.session_id) != 0 and session.generation != 0,
        .group => |group| @backingInt(group.id) != 0 and group.revision != 0,
        .history => |history| @backingInt(history) != 0,
        .transfer_owner => |transfer| @backingInt(transfer.id) != 0 and @backingInt(transfer.original_handle.session_id) != 0 and transfer.original_handle.generation != 0,
    };
}

fn sameCommand(a: UiCommand, b: UiCommand) bool {
    if (a.command_id != b.command_id or a.kind != b.kind or !a.owner.eql(b.owner) or a.view_revision != b.view_revision) return false;
    if ((a.selection_snapshot == null) != (b.selection_snapshot == null)) return false;
    if (a.selection_snapshot) |left| {
        const right = b.selection_snapshot.?;
        if (!left.owner.eql(right.owner) or left.revision != right.revision or !std.mem.eql(u8, left.text, right.text) or !std.mem.eql(identity.TabId, left.tabs, right.tabs)) return false;
    }
    if (std.meta.activeTag(a.payload) != std.meta.activeTag(b.payload)) return false;
    return switch (a.payload) {
        .none => true,
        .text => |value| std.mem.eql(u8, value, b.payload.text),
        .tab => |value| value == b.payload.tab,
        .number => |value| value == b.payload.number,
        .toggle => |value| value == b.payload.toggle,
    };
}

const Probe = struct {
    calls: usize = 0,
    fn submit(raw: *anyopaque, _: UiCommand) !OperationKey {
        const self: *Probe = @ptrCast(@alignCast(raw));
        self.calls += 1;
        return .{ .owner = .app, .operation_id = 71 };
    }
    fn handler(self: *Probe) Handler {
        return .{ .context = self, .submit = submit };
    }
};
fn appContext() LiveContext {
    return .{ .owner = .app, .view_revision = 1, .action_context = .{ .permission_granted = true, .handler_ready = true } };
}

test "one input returns the real domain operation once and rejects changed reuse" {
    var dispatcher: Dispatcher = .{ .allocator = std.testing.allocator };
    defer dispatcher.deinit();
    var probe: Probe = .{};
    var text = [_]u8{ 'a', 'b' };
    const command: UiCommand = .{ .command_id = try dispatcher.issue(), .kind = .toggle_sidebar, .owner = .app, .view_revision = 1, .payload = .{ .text = &text } };
    const first = try dispatcher.submit(command, appContext(), probe.handler());
    const duplicate = try dispatcher.submit(command, appContext(), probe.handler());
    try std.testing.expectEqual(@as(u64, 71), first.accepted.operation_id);
    try std.testing.expect(first.accepted.eql(duplicate.accepted));
    try std.testing.expectEqual(@as(usize, 1), probe.calls);
    text[0] = 'X';
    try std.testing.expectEqual(RejectCode.command_id_reused, (try dispatcher.submit(command, appContext(), probe.handler())).rejected.code);
    try std.testing.expectEqualStrings("ab", dispatcher.recent.?.command.value.payload.text);
    try std.testing.expectEqual(@as(usize, 1), probe.calls);
}

test "captured owner view and selection reject stale input before invoking a handler" {
    var dispatcher: Dispatcher = .{ .allocator = std.testing.allocator };
    defer dispatcher.deinit();
    var probe: Probe = .{};
    var command: UiCommand = .{ .command_id = try dispatcher.issue(), .kind = .toggle_sidebar, .owner = .app, .view_revision = 1 };
    var live = appContext();
    live.owner = .{ .history = @fromBackingInt(9) };
    try std.testing.expectEqual(RejectCode.stale_owner, (try dispatcher.submit(command, live, probe.handler())).rejected.code);
    command.command_id = try dispatcher.issue();
    live = appContext();
    live.view_revision = 2;
    try std.testing.expectEqual(RejectCode.stale_view, (try dispatcher.submit(command, live, probe.handler())).rejected.code);
    command.command_id = try dispatcher.issue();
    command.kind = .copy;
    command.selection_snapshot = .{ .owner = .app, .revision = 1, .text = "selected" };
    live = appContext();
    live.selection_revision = 2;
    try std.testing.expectEqual(RejectCode.stale_selection, (try dispatcher.submit(command, live, probe.handler())).rejected.code);
    try std.testing.expectEqual(@as(usize, 0), probe.calls);
}

test "action availability and actual handler are required at the shared ingress" {
    var dispatcher: Dispatcher = .{ .allocator = std.testing.allocator };
    defer dispatcher.deinit();
    var probe: Probe = .{};
    var command: UiCommand = .{ .command_id = try dispatcher.issue(), .kind = .toggle_sidebar, .owner = .app, .view_revision = 1 };
    try std.testing.expectEqual(actions.Cause.handler_not_ready, (try dispatcher.submit(command, appContext(), null)).rejected.action_cause.?);
    command.command_id = try dispatcher.issue();
    var live = appContext();
    live.action_context.permission_granted = false;
    try std.testing.expectEqual(actions.Cause.permission_denied, (try dispatcher.submit(command, live, probe.handler())).rejected.action_cause.?);
    try std.testing.expectEqual(@as(usize, 0), probe.calls);
}

test "retired and superseded IDs cannot execute again after payloads are freed" {
    var dispatcher: Dispatcher = .{ .allocator = std.testing.allocator };
    defer dispatcher.deinit();
    var probe: Probe = .{};
    var command: UiCommand = .{ .command_id = try dispatcher.issue(), .kind = .toggle_sidebar, .owner = .app, .view_revision = 1 };
    _ = try dispatcher.submit(command, appContext(), probe.handler());
    const old = command;
    command.command_id = try dispatcher.issue();
    _ = try dispatcher.submit(command, appContext(), probe.handler());
    try std.testing.expectEqual(RejectCode.already_consumed, (try dispatcher.submit(old, appContext(), probe.handler())).rejected.code);
    try dispatcher.retire(command.command_id);
    try std.testing.expect(dispatcher.recent == null);
    try std.testing.expectEqual(RejectCode.already_consumed, (try dispatcher.submit(command, appContext(), probe.handler())).rejected.code);
    try std.testing.expectEqual(@as(usize, 2), probe.calls);
    try std.testing.expectError(error.CommandNotConsumed, dispatcher.retire(command.command_id + 1));
    command.command_id = try dispatcher.issue();
    _ = try dispatcher.submit(command, appContext(), probe.handler());
    try std.testing.expectEqual(@as(usize, 3), probe.calls);
}

fn allocationProbe(allocator: std.mem.Allocator) !void {
    var dispatcher: Dispatcher = .{ .allocator = allocator };
    defer dispatcher.deinit();
    var probe: Probe = .{};
    const command: UiCommand = .{ .command_id = try dispatcher.issue(), .kind = .toggle_sidebar, .owner = .app, .view_revision = 1, .payload = .{ .text = "immutable request" } };
    _ = dispatcher.submit(command, appContext(), probe.handler()) catch |err| {
        try std.testing.expectEqual(@as(usize, 0), probe.calls);
        try std.testing.expectEqual(@as(u64, 0), dispatcher.consumed_through);
        return err;
    };
    try std.testing.expectEqual(@as(usize, 1), probe.calls);
}

test "snapshot allocation failures never dispatch or consume the input" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, allocationProbe, .{});
}
