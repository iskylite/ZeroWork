//! Independent host approvals. No SessionHandle, UI pointer, borrowed invocation
//! string or Bridge lock crosses this worker/main-thread mailbox.
const std = @import("std");
const host = @import("host_tools.zig");
const provider = @import("provider.zig");
const fetch = @import("fetch_url.zig");
pub const lifetime_ms: i64 = 120_000;
pub const routing = @import("execution_routing.zig");
pub const RouteSelection = struct {
    proposed: routing.Route,
    choice: routing.Choice,
    target: @import("../host/identity.zig").SessionHandle,
    selectable: bool = false,
    reason: []const u8 = "按本次任务选择运行方式；只覆盖此命令。",
};
pub const SubjectKind = enum { network_url, lifecycle, terminal_command };
/// Display data comes from a trusted preflight, never an authorization decision.
/// The owner still checks lifecycle grants, execution modes and live targets.
pub const Subject = struct {
    kind: SubjectKind,
    target: []const u8,
    detail: []const u8,
    impact: []const u8 = "",
    route: ?RouteSelection = null,
};
fn Fixed(comptime capacity: usize) type {
    return struct {
        bytes: [capacity]u8 = @splat(0),
        len: usize = 0,
        fn init(value: []const u8) !@This() {
            if (value.len > capacity or !std.unicode.utf8ValidateSlice(value)) return error.InvalidHostApproval;
            var self: @This() = .{ .len = value.len };
            @memcpy(self.bytes[0..value.len], value);
            return self;
        }
        pub fn text(self: *const @This()) []const u8 {
            return self.bytes[0..self.len];
        }
    };
}
/// A value snapshot owns all its text. Safe to copy while the worker cancels.
pub const Snapshot = struct {
    kind: SubjectKind,
    route: ?struct { proposed: routing.Route, choice: routing.Choice, target: @import("../host/identity.zig").SessionHandle, selectable: bool, reason: Fixed(1024) } = null,
    target: Fixed(8192),
    detail: Fixed(65534),
    impact: Fixed(2048),
    context: host.Context,
    authority: provider.ToolAuthority,
    sequence: u64,
    operation_id: u64,
    turn_id: u64,
    arguments_hash: [32]u8,
    canonical_arguments_hash: [32]u8,
    tool: Fixed(provider.max_tool_name_bytes),
    call: Fixed(provider.max_tool_call_id_bytes),
    requested_url: Fixed(8192),
    canonical_url: Fixed(8192),
    network_policy_revision: u64,
    created_at_ms: i64,
    expires_at_ms: i64,
    expired: bool = false,
};
pub const Permit = struct { sequence: u64, arguments_hash: [32]u8 };
const State = enum { pending, approved, rejected };
const Entry = struct { snapshot: Snapshot, state: State = .pending };
pub const Broker = struct {
    mutex: std.atomic.Mutex = .unlocked,
    execution_route: routing.State = .{},
    live_context: ?host.Context = null,
    network_policy_revision: u64 = 0,
    sequence: u64 = 0,
    stopped: bool = false,
    entry: ?Entry = null,
    /// Tests may inject a monotonic clock; production uses the native clock.
    clock_context: ?*anyopaque = null,
    clock: *const fn (?*anyopaque) i64 = monotonicMs,

    fn lock(self: *Broker) void {
        while (!self.mutex.tryLock()) std.atomic.spinLoopHint();
    }
    fn now(self: *Broker) i64 {
        return self.clock(self.clock_context);
    }
    pub fn configure(self: *Broker, context: host.Context, network_policy_revision: u64) !void {
        try context.validate();
        try self.execution_route.configure(context);
        if (network_policy_revision == 0) return error.InvalidHostAuthority;
        self.lock();
        defer self.mutex.unlock();
        if (self.live_context == null or !self.live_context.?.eql(context) or self.network_policy_revision != network_policy_revision) self.entry = null;
        self.live_context = context;
        self.network_policy_revision = network_policy_revision;
        self.stopped = false;
    }
    /// Main thread and Stop/close may call this without joining the worker.
    /// Invalidate granted permits too, so cancellation cannot leave a live grant.
    pub fn stop(self: *Broker) void {
        self.lock();
        defer self.mutex.unlock();
        self.stopped = true;
        self.entry = null;
        self.execution_route.clear();
    }
    /// Publish one precise URL approval. Exposed for cooperative schedulers;
    /// ordinary worker users should call request() below.
    pub fn begin(self: *Broker, invocation: host.Invocation, exact_url: []const u8, network_revision: u64, allocator: std.mem.Allocator) !Permit {
        return self.beginSubject(invocation, .{ .kind = .network_url, .target = exact_url, .detail = exact_url }, network_revision, allocator);
    }
    pub fn beginSubject(self: *Broker, invocation: host.Invocation, subject: Subject, policy_revision: u64, allocator: std.mem.Allocator) !Permit {
        if (subject.target.len == 0 or subject.detail.len == 0 or invocation.tool_id.len == 0 or invocation.call_id.len == 0) return error.InvalidHostApproval;
        switch (subject.kind) {
            .network_url => if (invocation.authority != .local_network_read or !fetch.supports(invocation.tool_id)) return error.InvalidHostApproval,
            .lifecycle => if (invocation.authority != .lifecycle) return error.InvalidHostApproval,
            .terminal_command => if (invocation.authority != .execution_control) return error.InvalidHostApproval,
        }
        if (subject.route != null and subject.kind != .terminal_command) return error.InvalidHostApproval;
        const args = invocation.arguments;
        if (args != .object) return error.InvalidHostApproval;
        if (subject.kind == .network_url) {
            if (args.object.count() != 1) return error.InvalidHostApproval;
            const argument = args.object.get("url") orelse return error.InvalidHostApproval;
            if (argument != .string or !std.mem.eql(u8, argument.string, subject.target) or !std.mem.eql(u8, subject.target, subject.detail)) return error.InvalidHostApproval;
        }
        // Verify the parser-produced hashes rather than accepting a caller's
        // assertion that changed arguments belong to an already displayed card.
        const canonical_hash = try @import("canonical_arguments.zig").digest(allocator, args);
        var raw_hash: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(invocation.arguments_json, &raw_hash, .{});
        if (!std.mem.eql(u8, &canonical_hash, &invocation.canonical_arguments_hash) or !std.mem.eql(u8, &raw_hash, &invocation.arguments_hash)) return error.InvalidHostApproval;
        const canonical = if (subject.kind == .network_url) try fetch.normalizeUrl(allocator, subject.target) else try allocator.dupe(u8, "");
        defer allocator.free(canonical);
        var frozen: Snapshot = .{
            .kind = subject.kind,
            .route = if (subject.route) |route| .{ .proposed = route.proposed, .choice = route.choice, .target = route.target, .selectable = route.selectable, .reason = try Fixed(1024).init(route.reason) } else null,
            .target = try Fixed(8192).init(subject.target),
            .detail = try Fixed(65534).init(subject.detail),
            .impact = try Fixed(2048).init(subject.impact),
            .context = invocation.context,
            .authority = invocation.authority,
            .sequence = 0,
            .operation_id = invocation.operation_id,
            .turn_id = invocation.turn_id,
            .arguments_hash = raw_hash,
            .canonical_arguments_hash = canonical_hash,
            .tool = try Fixed(provider.max_tool_name_bytes).init(invocation.tool_id),
            .call = try Fixed(provider.max_tool_call_id_bytes).init(invocation.call_id),
            .requested_url = try Fixed(8192).init(if (subject.kind == .network_url) subject.target else ""),
            .canonical_url = try Fixed(8192).init(canonical),
            .network_policy_revision = policy_revision,
            .created_at_ms = 0,
            .expires_at_ms = 0,
        };
        self.lock();
        defer self.mutex.unlock();
        if (self.stopped) return error.CancelledBeforeDispatch;
        if (self.live_context == null or !self.live_context.?.eql(invocation.context) or self.network_policy_revision != policy_revision) return error.ScopeChanged;
        if (self.entry != null) return error.HostApprovalBusy;
        self.sequence = std.math.add(u64, self.sequence, 1) catch return error.ApprovalSequenceExhausted;
        frozen.sequence = self.sequence;
        frozen.created_at_ms = self.now();
        frozen.expires_at_ms = std.math.add(i64, frozen.created_at_ms, lifetime_ms) catch return error.ApprovalSequenceExhausted;
        self.entry = .{ .snapshot = frozen };
        return .{ .sequence = frozen.sequence, .arguments_hash = raw_hash };
    }
    /// Waits outside all mailbox/UI/Bridge locks. On cancel/reject/expiry, the
    /// pending entry is removed before this function returns.
    pub fn request(self: *Broker, invocation: host.Invocation, exact_url: []const u8, network_revision: u64, allocator: std.mem.Allocator, cancel: ?*provider.CancelToken) !Permit {
        return self.requestSubject(invocation, .{ .kind = .network_url, .target = exact_url, .detail = exact_url }, network_revision, allocator, cancel);
    }
    pub fn requestSubject(self: *Broker, invocation: host.Invocation, subject: Subject, policy_revision: u64, allocator: std.mem.Allocator, cancel: ?*provider.CancelToken) !Permit {
        if (cancel) |token| if (token.isCancelled()) return error.CancelledBeforeDispatch;
        const permit = try self.beginSubject(invocation, subject, policy_revision, allocator);
        errdefer self.finish(permit);
        while (true) {
            if (cancel) |token| if (token.isCancelled()) return error.CancelledBeforeDispatch;
            // Expiry keeps this exact call suspended; only the user can renew
            // or reject it. Never turn a missing decision into a model retry.
            const approved = self.poll(permit) catch |err| switch (err) {
                error.ToolApprovalExpired => false,
                else => return err,
            };
            if (approved) return permit;
            @import("retry.zig").wait(10, cancel) catch return error.CancelledBeforeDispatch;
        }
    }
    /// Returns true after approval, false while pending, or a terminal rejection.
    pub fn poll(self: *Broker, permit: Permit) !bool {
        self.lock();
        defer self.mutex.unlock();
        if (self.stopped) return error.CancelledBeforeDispatch;
        const entry = self.entry orelse return error.ScopeChanged;
        if (!matches(entry.snapshot, permit)) return error.StaleApproval;
        if (entry.state == .rejected) return error.ToolApprovalRejected;
        if (self.now() >= entry.snapshot.expires_at_ms) {
            // A decision delivered just before expiry may be observed later.
            // Keep it visible and require renewal instead of hiding a waiter.
            if (entry.state == .approved) self.entry.?.state = .pending;
            return error.ToolApprovalExpired;
        }
        return switch (entry.state) {
            .pending => false,
            .approved => true,
            .rejected => error.ToolApprovalRejected,
        };
    }
    /// Main-thread value snapshot; no references to worker-owned memory escape.
    pub fn snapshot(self: *Broker) ?Snapshot {
        self.lock();
        defer self.mutex.unlock();
        const entry = self.entry orelse return null;
        if (self.stopped or entry.state != .pending) return null;
        var result = entry.snapshot;
        result.expired = self.now() >= result.expires_at_ms;
        return result;
    }
    pub fn decide(self: *Broker, sequence: u64, hash: [32]u8, approved: bool) !void {
        self.lock();
        defer self.mutex.unlock();
        const entry = if (self.entry) |*item| item else return error.StaleApproval;
        if (self.stopped or entry.state != .pending or entry.snapshot.sequence != sequence or !std.mem.eql(u8, &entry.snapshot.arguments_hash, &hash) or (approved and self.now() >= entry.snapshot.expires_at_ms)) return error.StaleApproval;
        if (approved) {
            if (entry.snapshot.route) |route| try self.execution_route.select(entry.snapshot.context, route.choice, entry.snapshot.detail.text(), true);
        }
        if (!approved and entry.snapshot.route != null) self.execution_route.revoke();
        entry.state = if (approved) .approved else .rejected;
    }
    /// Explicit renewal never grants approval. The same frozen request must
    /// still be approved separately and revalidated at dispatch.
    pub fn renew(self: *Broker, sequence: u64, hash: [32]u8) !void {
        self.lock();
        defer self.mutex.unlock();
        const entry = if (self.entry) |*value| value else return error.StaleApproval;
        if (self.stopped or entry.state != .pending or entry.snapshot.sequence != sequence or !std.mem.eql(u8, &entry.snapshot.arguments_hash, &hash) or self.now() < entry.snapshot.expires_at_ms) return error.StaleApproval;
        entry.snapshot.created_at_ms = self.now();
        entry.snapshot.expires_at_ms = std.math.add(i64, self.now(), lifetime_ms) catch return error.ApprovalSequenceExhausted;
    }
    /// Selection changes the pending card only. One subsequent approve action
    /// binds it to this command; cancel never mints a selection grant.
    pub fn chooseRoute(self: *Broker, sequence: u64, hash: [32]u8, route: routing.Route) !void {
        self.lock();
        defer self.mutex.unlock();
        const entry = if (self.entry) |*value| value else return error.StaleApproval;
        if (self.stopped or entry.state != .pending or entry.snapshot.sequence != sequence or !std.mem.eql(u8, &entry.snapshot.arguments_hash, &hash) or self.now() >= entry.snapshot.expires_at_ms) return error.StaleApproval;
        const selection = if (entry.snapshot.route) |*value| value else return error.RouteSelectionUnavailable;
        if (!selection.selectable) return error.RouteSelectionUnavailable;
        selection.choice.route = route;
    }
    pub fn selectedRoute(self: *Broker, permit: Permit) !routing.Choice {
        self.lock();
        defer self.mutex.unlock();
        const entry = self.entry orelse return error.StaleApproval;
        if (self.stopped or !matches(entry.snapshot, permit) or entry.state != .approved or self.now() >= entry.snapshot.expires_at_ms) return error.StaleApproval;
        return if (entry.snapshot.route) |route| route.choice else error.RouteSelectionUnavailable;
    }
    /// A later real tool call can reuse a prior exact route+command approval.
    /// All ordinary backend preflights and forbidden rules still run first.
    pub fn beginGrantedSubject(self: *Broker, invocation: host.Invocation, subject: Subject, policy_revision: u64, allocator: std.mem.Allocator) !?Permit {
        const route = subject.route orelse return null;
        const target = route.target;
        const resolution = self.execution_route.resolve(invocation.context, target, subject.detail, route.proposed);
        if (!resolution.trusted or !resolution.approved or resolution.route != route.proposed or resolution.choice == null or !std.meta.eql(resolution.choice.?, route.choice)) return null;
        const permit = try self.beginSubject(invocation, subject, policy_revision, allocator);
        self.lock();
        defer self.mutex.unlock();
        if (self.entry) |*entry| if (matches(entry.snapshot, permit)) {
            entry.state = .approved;
            return permit;
        };
        return error.ScopeChanged;
    }
    pub fn finish(self: *Broker, permit: Permit) void {
        self.lock();
        defer self.mutex.unlock();
        if (self.entry) |entry| if (matches(entry.snapshot, permit)) {
            self.entry = null;
        };
    }
    /// Read-only dispatch gate. No UI, waits, allocation or grant creation.
    /// A redirect to another URL requires a fresh precise approval.
    pub fn authorize(self: *Broker, permit: Permit, invocation: host.Invocation, url: []const u8, network_revision: u64) fetch.Decision {
        return self.authorizeInner(permit, invocation, .network_url, url, null, null, network_revision);
    }
    pub fn authorizeSubject(self: *Broker, permit: Permit, invocation: host.Invocation, subject: Subject, policy_revision: u64) fetch.Decision {
        return self.authorizeInner(permit, invocation, subject.kind, subject.target, subject.detail, subject.impact, policy_revision);
    }
    /// Preserve the exact approval deadline across an asynchronous deployment.
    pub fn authorizedSubjectExpiry(self: *Broker, permit: Permit, invocation: host.Invocation, subject: Subject, policy_revision: u64) ?i64 {
        self.lock();
        defer self.mutex.unlock();
        if (self.authorizeInnerLocked(permit, invocation, subject.kind, subject.target, subject.detail, subject.impact, policy_revision) != .allow) return null;
        return self.entry.?.snapshot.expires_at_ms;
    }
    fn authorizeInner(self: *Broker, permit: Permit, invocation: host.Invocation, kind: SubjectKind, target: []const u8, detail: ?[]const u8, impact: ?[]const u8, network_revision: u64) fetch.Decision {
        self.lock();
        defer self.mutex.unlock();
        return self.authorizeInnerLocked(permit, invocation, kind, target, detail, impact, network_revision);
    }
    fn authorizeInnerLocked(self: *Broker, permit: Permit, invocation: host.Invocation, kind: SubjectKind, target: []const u8, detail: ?[]const u8, impact: ?[]const u8, network_revision: u64) fetch.Decision {
        if (self.stopped or self.live_context == null or !self.live_context.?.eql(invocation.context) or self.network_policy_revision != network_revision) return .scope_changed;
        const entry = self.entry orelse return .approval_required;
        const saved = entry.snapshot;
        if (saved.kind != kind) return .scope_changed;
        if (saved.route) |route| if (route.choice.route != route.proposed) return .scope_changed;
        if (!matches(saved, permit) or !saved.context.eql(invocation.context) or saved.authority != invocation.authority or saved.operation_id != invocation.operation_id or saved.turn_id != invocation.turn_id or saved.network_policy_revision != network_revision or !std.mem.eql(u8, saved.tool.text(), invocation.tool_id) or !std.mem.eql(u8, saved.call.text(), invocation.call_id) or !std.mem.eql(u8, &saved.arguments_hash, &invocation.arguments_hash) or !std.mem.eql(u8, &saved.canonical_arguments_hash, &invocation.canonical_arguments_hash)) return .scope_changed;
        if (self.now() >= saved.expires_at_ms) return .approval_required;
        var raw_hash: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(invocation.arguments_json, &raw_hash, .{});
        if (!std.mem.eql(u8, &saved.arguments_hash, &raw_hash)) return .scope_changed;
        if (kind == .network_url and detail == null) {
            if (!std.mem.eql(u8, saved.canonical_url.text(), target)) return .approval_required;
        } else if (!std.mem.eql(u8, saved.target.text(), target)) return .approval_required;
        if (detail) |text| if (!std.mem.eql(u8, saved.detail.text(), text)) return .scope_changed;
        if (impact) |text| if (!std.mem.eql(u8, saved.impact.text(), text)) return .scope_changed;
        return switch (entry.state) {
            .approved => .allow,
            .pending => .approval_required,
            .rejected => .denied,
        };
    }
};
fn matches(snapshot: Snapshot, permit: Permit) bool {
    return snapshot.sequence == permit.sequence and std.mem.eql(u8, &snapshot.arguments_hash, &permit.arguments_hash);
}
fn monotonicMs(_: ?*anyopaque) i64 {
    return @intCast(@divTrunc(@import("../platform/realtime.zig").monotonicNs(), std.time.ns_per_ms));
}
test {
    _ = routing;
    _ = @import("host_approval_tests.zig");
}
