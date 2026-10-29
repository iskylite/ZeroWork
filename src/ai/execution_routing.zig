//! Trusted, Task-local route choices. Model arguments never create these grants.
//! A choice can name one command and one existing identity, or one explicitly
//! approved create operation and its proved resulting identity. It is consumed
//! at the command boundary and cannot authorize unknown successor commands.
const std = @import("std");
const host = @import("host_tools.zig");
const identity = @import("../host/identity.zig");
const config = @import("../config/config.zig");
pub const Route = enum { batch, current_terminal, new_terminal };
pub const Source = union(enum) {
    session: identity.SessionHandle,
    saved: identity.AssetOwner,
    pub fn eql(self: Source, other: Source) bool {
        return std.meta.activeTag(self) == std.meta.activeTag(other) and switch (self) {
            .session => |value| value.eql(other.session),
            .saved => |value| std.meta.eql(value, other.saved),
        };
    }
};
pub const Choice = struct {
    route: Route,
    create_new: bool = false,
    source: Source,
    retention: config.SessionRetention = .auto_idle,
};
pub const Create = struct {
    operation_id: identity.HostOperationId,
    request_hash: [32]u8,
    source: Source,
    retention: config.SessionRetention,
    policy: enum { reuse_only, new_only, prefer_reuse },
};
const Grant = struct {
    context: host.Context,
    choice: Choice,
    command_hash: ?[32]u8 = null,
    command_approved: bool = false,
    create: ?Create = null,
    created: ?identity.SessionHandle = null,
};
pub const Resolution = struct { route: Route, approved: bool = false, trusted: bool = false, choice: ?Choice = null, needs_creation: bool = false };
pub const State = struct {
    mutex: std.atomic.Mutex = .unlocked,
    context: ?host.Context = null,
    grant: ?Grant = null,
    fn lock(self: *State) void {
        while (!self.mutex.tryLock()) std.atomic.spinLoopHint();
    }
    pub fn configure(self: *State, context: host.Context) !void {
        try context.validate();
        self.lock();
        defer self.mutex.unlock();
        if (self.context == null or !self.context.?.eql(context)) self.grant = null;
        self.context = context;
    }
    pub fn revoke(self: *State) void {
        self.lock();
        defer self.mutex.unlock();
        self.grant = null;
    }
    /// A lifecycle create may require the selected interactive integration.
    /// Discovery and a model's proposed route cannot install this decision.
    pub fn requiresPtyCreate(self: *State, context: host.Context, source: Source) bool {
        self.lock();
        defer self.mutex.unlock();
        const grant = self.grant orelse return false;
        return grant.context.eql(context) and grant.choice.source.eql(source) and grant.choice.route == .new_terminal and grant.created == null;
    }
    pub fn clear(self: *State) void {
        self.lock();
        defer self.mutex.unlock();
        self.grant = null;
        self.context = null;
    }
    /// Called only with the actual submitted user request, never transcript,
    /// tool arguments, webpage text or an assistant's restatement. Conservative
    /// grammar: multiple/negated/quoted routing instructions remain ambiguous.
    /// No command permission is minted here; an exact command is still approved
    /// under the ordinary permission policy.
    pub fn captureIntent(self: *State, context: host.Context, submitted: []const u8, selected: ?identity.SessionHandle, retention: config.SessionRetention) !void {
        self.lock();
        defer self.mutex.unlock();
        if (self.context == null or !self.context.?.eql(context)) return error.ScopeChanged;
        self.grant = null;
        if (submitted.len > 65534 or std.mem.indexOfAny(u8, submitted, "\n\r\"") != null or containsAny(submitted, &.{ "“", "”" }) or containsAny(submitted, &.{ "不要", "别在", "不是", "不要新", "don't", "do not", " if ", "如果", "或者", "也可以", "还是", "或在", " or " })) return;
        var instruction = std.mem.trim(u8, submitted, " \t");
        if (std.mem.startsWith(u8, instruction, "请")) instruction = instruction["请".len..];
        if (std.mem.indexOfScalar(u8, instruction, '`')) |index| instruction = instruction[0..index];
        const current = startsAny(instruction, &.{ "这次在当前终端执行", "在当前终端运行", "run in the current terminal", "execute in the current terminal" });
        const fresh = startsAny(instruction, &.{ "新开终端运行", "新开一个终端运行", "新开一个会话再", "新工作终端运行", "run in a new terminal" });
        const batch = startsAny(instruction, &.{ "这次批处理执行", "这次批量执行", "run as batch" });
        if (@as(u8, @intFromBool(current)) + @as(u8, @intFromBool(fresh)) + @as(u8, @intFromBool(batch)) != 1) return;
        const handle = selected orelse return; // groups never infer active/pin
        if (context.binding == .session and context.binding.session != @backingInt(handle.session_id)) return error.TargetOutsideScope;
        const route: Route = if (current) .current_terminal else if (fresh and !containsAny(instruction, &.{ "批量", "批处理", "batch" })) .new_terminal else .batch;
        self.grant = .{ .context = context, .choice = .{ .route = route, .create_new = fresh, .source = .{ .session = handle }, .retention = if (containsAny(submitted, &.{ "后保留", "并保留", "and keep" })) .keep else retention } };
    }
    pub fn select(self: *State, context: host.Context, choice: Choice, command: []const u8, approved: bool) !void {
        if (command.len == 0 or command.len > 65534) return error.InvalidArguments;
        self.lock();
        defer self.mutex.unlock();
        if (self.context == null or !self.context.?.eql(context)) return error.ScopeChanged;
        var next: Grant = .{ .context = context, .choice = choice, .command_hash = digest(command), .command_approved = approved };
        if (self.grant) |prior| if (prior.context.eql(context) and std.meta.eql(prior.choice, choice) and (prior.command_hash == null or std.mem.eql(u8, &prior.command_hash.?, &next.command_hash.?))) {
            next.create = prior.create;
            next.created = prior.created;
        };
        self.grant = next;
    }
    pub fn resolve(self: *State, context: host.Context, target: identity.SessionHandle, command: []const u8, fallback: Route) Resolution {
        self.lock();
        defer self.mutex.unlock();
        const grant = self.grant orelse return .{ .route = fallback };
        if (!grant.context.eql(context)) return .{ .route = fallback };
        const expected = grant.created orelse switch (grant.choice.source) {
            .session => |value| value,
            .saved => return .{ .route = fallback },
        };
        if (!expected.eql(target)) {
            self.grant = null;
            return .{ .route = fallback };
        }
        if (grant.command_hash) |hash| {
            if (!std.mem.eql(u8, &hash, &digest(command))) {
                self.grant = null;
                return .{ .route = fallback };
            }
        }
        return .{ .route = grant.choice.route, .approved = grant.command_approved and grant.command_hash != null and (!(grant.choice.route == .new_terminal or grant.choice.create_new) or grant.created != null), .trusted = true, .choice = grant.choice, .needs_creation = (grant.choice.route == .new_terminal or grant.choice.create_new) and grant.created == null };
    }
    pub fn allowsModeException(self: *State, context: host.Context, target: identity.SessionHandle, hash: [32]u8) bool {
        self.lock();
        defer self.mutex.unlock();
        const grant = self.grant orelse return false;
        if (!grant.context.eql(context) or grant.command_hash == null or !std.mem.eql(u8, &grant.command_hash.?, &hash)) return false;
        const expected = grant.created orelse switch (grant.choice.source) {
            .session => |value| value,
            .saved => return false,
        };
        return expected.eql(target) and grant.choice.route != .batch and (!(grant.choice.route == .new_terminal or grant.choice.create_new) or grant.created != null);
    }
    /// Bind a finite successor to the exact host-validated open call displayed
    /// by its own approval card. It does not approve creation on its own.
    pub fn bindCreate(self: *State, context: host.Context, create: Create) !void {
        self.lock();
        defer self.mutex.unlock();
        const grant = if (self.grant) |*value| value else return error.RouteGrantNotFound;
        if (!grant.context.eql(context) or !(grant.choice.route == .new_terminal or grant.choice.create_new) or !grant.choice.source.eql(create.source) or grant.choice.retention != create.retention or !create.operation_id.valid() or grant.created != null) {
            self.grant = null;
            return error.RouteGrantChanged;
        }
        if (grant.create) |prior| {
            if (!std.meta.eql(prior, create)) {
                self.grant = null;
                return error.RouteGrantChanged;
            }
        }
        grant.create = create;
    }
    /// Only a committed lifecycle receipt, checked against Task ownership and
    /// actual source/operation by the host, may supply this identity.
    pub fn created(self: *State, context: host.Context, create: Create, target: identity.SessionHandle) !void {
        self.lock();
        defer self.mutex.unlock();
        const grant = if (self.grant) |*value| value else return error.RouteGrantNotFound;
        if (!grant.context.eql(context) or grant.create == null or !std.meta.eql(grant.create.?, create) or @backingInt(target.session_id) == 0 or target.generation == 0) return error.RouteGrantChanged;
        if (grant.created) |prior| if (!prior.eql(target)) return error.RouteGrantChanged;
        grant.created = target;
    }
    /// The only allowed context transition is the committed same-Task single
    /// session -> group handoff with the exact original source. Arbitrary
    /// configure/context/permission changes revoke the choice.
    pub fn handoff(self: *State, prior: host.Context, next: host.Context, initial: identity.SessionHandle) !void {
        self.lock();
        defer self.mutex.unlock();
        const grant = if (self.grant) |*value| value else return error.RouteGrantNotFound;
        if (!grant.context.eql(prior) or prior.binding != .session or next.binding != .group or prior.binding.session != @backingInt(initial.session_id) or !prior.conversation_id.eql(next.conversation_id) or !prior.task_id.eql(next.task_id) or prior.grant_revision != next.grant_revision or next.binding_revision != prior.binding_revision +| 1 or !(grant.choice.route == .new_terminal or grant.choice.create_new) or !grant.choice.source.eql(.{ .session = initial })) return error.RouteGrantChanged;
        self.context = next;
        grant.context = next;
    }
    pub fn consume(self: *State, context: host.Context, target: identity.SessionHandle, command: []const u8) void {
        self.lock();
        defer self.mutex.unlock();
        const grant = self.grant orelse return;
        if (!grant.context.eql(context)) return;
        const expected = grant.created orelse switch (grant.choice.source) {
            .session => |value| value,
            .saved => return,
        };
        if (expected.eql(target) and (grant.command_hash == null or std.mem.eql(u8, &grant.command_hash.?, &digest(command)))) self.grant = null;
    }
};
pub fn fixedRoute(mode: config.ExecutionMode, proposed: Route) Route {
    return switch (mode) {
        .auto, .ask => proposed,
        .isolated_exec => .batch,
        .attached_pty => .current_terminal,
        .new_pty => .new_terminal,
    };
}
pub fn digest(text: []const u8) [32]u8 {
    var hash: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(text, &hash, .{});
    return hash;
}
fn containsAny(text: []const u8, needles: []const []const u8) bool {
    for (needles) |needle| if (std.mem.indexOf(u8, text, needle) != null) return true;
    return false;
}
test {
    _ = @import("execution_routing_tests.zig");
}

fn startsAny(text: []const u8, needles: []const []const u8) bool {
    for (needles) |needle| if (std.mem.startsWith(u8, text, needle)) return true;
    return false;
}
