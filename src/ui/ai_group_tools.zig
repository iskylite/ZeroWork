//! A group call owns a frozen roster and one original protocol bridge per
//! member. The controller preflights every selected target before the worker
//! can invoke any child. Focus and pin never participate in authorization.
const std = @import("std");
const App = @import("application_host.zig").ApplicationHost;
const identity = @import("../host/identity.zig");
const scope_mod = @import("../ai/tool_scope.zig");
const loop = @import("../ai/tool_loop.zig");
const provider = @import("../ai/provider.zig");
const Local = @import("ai_local_tools.zig");
const adapter = @import("../ai/legacy_adapter.zig");
const Roster = @import("group_model.zig").Roster;
const trace = @import("../ai/tool_trace.zig");

const Child = struct {
    id: u64,
    owner: identity.SessionHandle,
    failure: ?anyerror = null,
    bridge: adapter.Adapter,
    fn interface(self: *Child) loop.Host {
        return self.bridge.vtable.interface(self.bridge.context);
    }
    fn preflight(self: *Child, app: *App, invocation: loop.Invocation) !void {
        if (self.failure) |err| return err;
        try self.bridge.vtable.preflight(self.bridge.context, app, invocation);
    }
};
const Exchange = struct {
    invocation: loop.Invocation,
    sequence: u64,
    started_ns: i128 = 0,
    phase: std.atomic.Value(enum(u8) { waiting, dispatch, rejected, cancelled }) = .init(.waiting),
    cancel: provider.CancelToken = .{},
    upstream_cancel: ?*provider.CancelToken = null,
    decision: enum { pending, approved, rejected } = .pending,
    preflight_error: ?anyerror = null,
    target_errors: [scope_mod.max_targets]?anyerror = @splat(null),
    target_text: ?[]u8 = null,
};
pub const Bridge = struct {
    allocator: std.mem.Allocator,
    children: std.ArrayList(*Child) = .empty,
    scope: ?scope_mod.Scope = null,
    roster: ?*Roster = null,
    revision: u64 = 0,
    mutex: std.atomic.Mutex = .unlocked,
    exchange: ?*Exchange = null,
    sequence: u64 = 0,
    files: ?*@import("file_application_host.zig").Host = null,
    shutting_down: bool = false,

    pub fn init(allocator: std.mem.Allocator) Bridge {
        return .{ .allocator = allocator };
    }
    fn lock(self: *Bridge) void {
        while (!self.mutex.tryLock()) std.atomic.spinLoopHint();
    }
    pub fn prepare(self: *Bridge, app: *App, roster: *Roster, scope: scope_mod.Scope) !void {
        if (self.scope != null or self.exchange != null) return error.ToolCleanupPending;
        if (scope.owner != .group) return error.InvalidGroupOwner;
        const group = roster.findById(std.math.cast(u32, scope.owner.group) orelse return error.UnknownGroup) orelse return error.UnknownGroup;
        if (scope.members.len == 0) return error.EmptyGroup;
        self.roster = roster;
        self.revision = group.membership_revision;
        self.scope = scope;
        self.shutting_down = false;
        errdefer self.clear() catch {};
        for (scope.members.slice()) |id| {
            var owner: ?identity.SessionHandle = null;

            for (app.workspace.tabs.items) |tab| if (tab.content_owner == .session and @backingInt(tab.content_owner.session.session_id) == id) {
                if (!group.contains(tab.id)) return error.TargetOutsideAssistant;
                owner = tab.content_owner.session;
                break;
            };
            const handle = owner orelse return error.StaleSession;
            const manifest = app.sessions.manifestFor(handle) orelse return error.AdapterNotConnected;
            const factory = manifest.ai_adapter_factory orelse return error.ToolHostUnavailable;
            const child = try self.allocator.create(Child);
            errdefer self.allocator.destroy(child);
            child.* = .{ .id = id, .owner = handle, .bridge = try factory(self.allocator) };
            try self.children.append(self.allocator, child);
            child.bridge.vtable.delegate(child.bridge.context, scope.owner);
            child.bridge.vtable.files(child.bridge.context, if (self.files) |files| files else null);
            child.bridge.vtable.prepare(child.bridge.context, app, handle) catch |err| {
                child.failure = err;
            };
        }
    }
    pub fn toolIds(self: *Bridge, tool: scope_mod.Tool) scope_mod.Targets {
        var ids: scope_mod.Targets = .{};
        for (self.children.items) |child| {
            const available = child.bridge.vtable.tool_ids(child.bridge.context, tool);
            if (available.len == 0) continue;
            ids.ids[ids.len] = child.id;
            ids.len += 1;
        }
        return ids;
    }
    fn find(self: *Bridge, id: u64) ?*Child {
        for (self.children.items) |child| if (child.id == id) return child;
        return null;
    }
    fn singleton(invocation: loop.Invocation, id: u64) loop.Invocation {
        var child = invocation;
        child.call.targets = .{};
        child.call.targets.ids[0] = id;
        child.call.targets.len = 1;
        // The parent already made the only approval decision for this exact
        // call. Keep its owner/hash/turn/call identity in every child trace.
        child.verdict = .allow_auto;
        return child;
    }
    fn validateRoster(self: *Bridge, app: *App, selected: []const u64) !void {
        const captured = self.scope orelse return error.GroupUnavailable;
        const roster = self.roster orelse return error.GroupUnavailable;
        const group = roster.findById(@intCast(captured.owner.group)) orelse return error.GroupRemoved;
        if (group.membership_revision != self.revision) return error.GroupMembershipChanged;
        for (selected) |id| {
            const child = self.find(id) orelse return error.TargetOutsideAssistant;
            const pane = app.legacyForHandle(child.owner) orelse return error.StaleSession;
            var found = false;
            for (group.members.items) |member| if (member.pane_id == pane and member.active) {
                found = true;
                break;
            };
            if (!found) return error.GroupMembershipChanged;
        }
    }
    pub fn interface(self: *Bridge) loop.Host {
        return .{ .context = self, .execute = execute };
    }
    fn execute(raw: *anyopaque, invocation: loop.Invocation, allocator: std.mem.Allocator, token: ?*provider.CancelToken) !loop.Outcome {
        const self: *Bridge = @ptrCast(@alignCast(raw));
        var current: Exchange = .{ .invocation = invocation, .sequence = 0, .upstream_cancel = token };
        self.lock();
        if (self.exchange != null or self.shutting_down or self.scope == null or !self.scope.?.owner.eql(invocation.key.owner)) {
            self.mutex.unlock();
            return error.ToolHostUnavailable;
        }
        self.sequence = std.math.add(u64, self.sequence, 1) catch {
            self.mutex.unlock();
            return error.IdentityExhausted;
        };
        current.sequence = self.sequence;
        current.started_ns = @import("../platform/realtime.zig").monotonicNs();
        self.exchange = &current;
        trace.emit(.{ .event = "group_host_received", .sequence = current.sequence, .turn_id = invocation.key.turn_id, .call_id = invocation.key.call_id, .owner = invocation.key.owner, .verdict = invocation.verdict, .command = invocation.call.command, .targets = invocation.call.targets.slice(), .revision = self.revision });
        self.mutex.unlock();
        defer {
            self.lock();
            self.exchange = null;
            self.mutex.unlock();
            if (current.target_text) |text| self.allocator.free(text);
        }
        while (current.phase.load(.acquire) == .waiting) {
            if (token) |cancel| if (cancel.isCancelled()) current.cancel.cancel();
            pause();
        }
        var owned: [scope_mod.max_targets]?loop.Outcome = @splat(null);
        defer for (&owned) |*outcome| if (outcome.*) |*value| value.deinit(allocator);
        var values: [scope_mod.max_targets]loop.TargetResult = undefined;
        for (invocation.call.targets.slice(), 0..) |id, index| {
            if (token) |cancel| if (cancel.isCancelled()) current.cancel.cancel();
            const child = self.find(id);
            values[index] = .{ .session_id = id, .status = .rejected, .transport = .unknown };
            if (current.phase.load(.acquire) != .dispatch) {
                values[index].status = if (current.phase.load(.acquire) == .cancelled) .cancelled else .rejected;
                values[index].error_code = if (current.target_errors[index]) |err| @errorName(err) else if (current.preflight_error) |err| @errorName(err) else "GroupPreflightAborted";
                continue;
            }
            if (current.cancel.isCancelled()) {
                values[index].status = .cancelled;
                values[index].error_code = "CancelledBeforeDispatch";
                continue;
            }
            const target = child orelse {
                values[index].error_code = "TargetOutsideAssistant";
                continue;
            };
            const host = target.interface();
            owned[index] = host.execute(host.context, singleton(invocation, id), allocator, &current.cancel) catch |err| {
                values[index].status = .unknown;
                values[index].local_released = false;
                values[index].error_code = @errorName(err);
                current.cancel.cancel();
                continue;
            };
            if (owned[index].?.targets.len == 1) values[index] = owned[index].?.targets[0] else {
                values[index].status = .unknown;
                values[index].error_code = "InvalidToolOutcome";
                current.cancel.cancel();
            }
        }
        return loop.Outcome.copy(allocator, values[0..invocation.call.targets.len]);
    }
    pub fn pendingApproval(self: *Bridge) ?Local.Approval {
        self.lock();
        defer self.mutex.unlock();
        const current = self.exchange orelse return null;
        if (current.phase.load(.acquire) != .waiting or current.cancel.isCancelled() or current.invocation.verdict != .need_confirm or current.decision != .pending) return null;
        const text = current.target_text orelse return null;
        const child = self.find(current.invocation.call.targets.ids[0]) orelse return null;
        return .{ .group = true, .target = text, .owner = child.owner, .cwd = null, .sequence = current.sequence, .arguments_hash = current.invocation.arguments_hash, .command = current.invocation.call.command, .call_id = current.invocation.key.call_id };
    }
    pub fn decide(self: *Bridge, sequence: u64, hash: [32]u8, approved: bool) !void {
        self.lock();
        defer self.mutex.unlock();
        const current = self.exchange orelse return error.StaleApproval;
        if (current.sequence != sequence or current.phase.load(.acquire) != .waiting or current.cancel.isCancelled() or current.decision != .pending or !std.mem.eql(u8, &hash, &current.invocation.arguments_hash)) return error.StaleApproval;
        current.decision = if (approved) .approved else .rejected;
        trace.emit(.{ .event = "group_approval_decision", .sequence = sequence, .call_id = current.invocation.key.call_id, .approved = approved, .targets = current.invocation.call.targets.slice() });
    }
    pub fn pump(self: *Bridge, app: *App) void {
        self.lock();
        if (self.exchange) |current| {
            // The worker may be blocked inside the original child's execute.
            // Relay the stable request token from this controller tick too.
            if (current.upstream_cancel) |token| if (token.isCancelled()) current.cancel.cancel();
            if (current.phase.load(.acquire) == .waiting) {
                if (current.cancel.isCancelled()) {
                    current.phase.store(.cancelled, .release);
                } else {
                    self.validateRoster(app, current.invocation.call.targets.slice()) catch |err| {
                        current.preflight_error = err;
                        current.phase.store(.rejected, .release);
                    };
                    if (current.phase.load(.acquire) == .waiting) {
                        for (current.invocation.call.targets.slice(), 0..) |id, i| {
                            const child = self.find(id) orelse {
                                current.target_errors[i] = error.TargetOutsideAssistant;
                                continue;
                            };
                            current.target_errors[i] = null;
                            child.preflight(app, singleton(current.invocation, id)) catch |err| {
                                current.target_errors[i] = err;
                            };
                        }
                        var failed = false;
                        var waiting = false;
                        for (current.target_errors) |maybe_error| if (maybe_error) |err| {
                            if (err == error.WorkerBusy) waiting = true else failed = true;
                        };
                        if (waiting and @import("../platform/realtime.zig").monotonicNs() - current.started_ns >= @as(i128, current.invocation.timeout_ms) * std.time.ns_per_ms) {
                            current.preflight_error = error.ToolDeadlineExceeded;
                            failed = true;
                        }
                        if (failed) {
                            current.phase.store(.rejected, .release);
                        } else if (waiting) {
                            // Capability transport is still connecting. No target
                            // starts until every captured source is ready.
                        } else if (current.invocation.verdict == .deny_exec_copy_only) {
                            current.preflight_error = error.ToolExecutionDenied;
                            current.phase.store(.rejected, .release);
                        } else if (current.decision == .rejected) {
                            current.preflight_error = error.ToolApprovalRejected;
                            current.phase.store(.rejected, .release);
                        } else if (current.invocation.verdict != .need_confirm or current.decision == .approved) {
                            trace.emit(.{ .event = "group_preflight_passed", .owner = current.invocation.key.owner, .call_id = current.invocation.key.call_id, .targets = current.invocation.call.targets.slice(), .revision = self.revision });
                            current.phase.store(.dispatch, .release);
                        } else if (current.target_text == null) {
                            current.target_text = self.describeTargets(current.invocation.call.targets.slice()) catch null;
                        }
                    }
                }
            } else if (current.phase.load(.acquire) == .dispatch) {
                self.validateRoster(app, current.invocation.call.targets.slice()) catch {
                    current.cancel.cancel();
                    // Stop child exchanges before pumping them in this same
                    // controller tick; no not-yet-started member may slip
                    // through while the worker observes the cancel token.
                    for (self.children.items) |child| {
                        _ = child.bridge.vtable.stop(child.bridge.context, child.owner);
                    }
                };
            }
        }
        self.mutex.unlock();
        for (self.children.items) |child| child.bridge.vtable.pump(child.bridge.context, app);
    }
    fn describeTargets(self: *Bridge, ids: []const u64) ![]u8 {
        var text: std.ArrayList(u8) = .empty;
        errdefer text.deinit(self.allocator);
        const header = try std.fmt.allocPrint(self.allocator, "组 #{d} · {d} 个目标 · 成员快照 r{d}\n", .{ self.scope.?.owner.group, ids.len, self.revision });
        defer self.allocator.free(header);
        try text.appendSlice(self.allocator, header);
        for (ids) |id| {
            const child = self.find(id) orelse return error.TargetOutsideAssistant;
            const target = child.bridge.vtable.label(child.bridge.context);
            const cwd: ?[]const u8 = null;
            const row = try std.fmt.allocPrint(self.allocator, "#{d} · generation {d} · {s} · 目录 {s}\n", .{ id, child.owner.generation, target, cwd orelse "未知" });
            defer self.allocator.free(row);
            try text.appendSlice(self.allocator, row);
        }
        return text.toOwnedSlice(self.allocator);
    }
    pub fn stopOwner(self: *Bridge, owner: identity.SessionHandle) @import("../host/session_host.zig").CloseReceipt {
        self.lock();
        if (self.exchange) |current| for (self.children.items) |child| if (child.owner.eql(owner)) {
            current.cancel.cancel();
            break;
        };
        self.mutex.unlock();
        var receipt: @import("../host/session_host.zig").CloseReceipt = .released;
        for (self.children.items) |child| {
            const r = child.bridge.vtable.stop(child.bridge.context, owner);
            if (r == .unknown or (r == .awaiting and receipt == .released)) receipt = r;
        }
        return receipt;
    }
    pub fn writeRisk(self: *Bridge, owner: identity.SessionHandle) bool {
        self.lock();
        var pending = false;
        if (self.exchange) |current| {
            const phase = current.phase.load(.acquire);
            if (current.invocation.call.tool == .run_command and current.decision != .rejected and (phase == .waiting or phase == .dispatch)) {
                for (self.children.items) |child| if (child.owner.eql(owner)) {
                    for (current.invocation.call.targets.slice()) |id| if (id == child.id) {
                        pending = true;
                        break;
                    };
                };
            }
        }
        self.mutex.unlock();
        if (pending) return true;
        for (self.children.items) |child| if (child.owner.eql(owner)) {
            if (child.bridge.vtable.risk(child.bridge.context, owner)) return true;
        };
        return false;
    }
    pub fn closeImpact(self: *Bridge, owner: identity.SessionHandle) @import("group_close_controller.zig").Impact {
        self.lock();
        var impact: @import("group_close_controller.zig").Impact = .{};
        var found = false;
        for (self.children.items) |child| if (child.owner.eql(owner)) {
            found = true;
            break;
        };
        if (!found) {
            self.mutex.unlock();
            return impact;
        }
        var hash = std.hash.Wyhash.init(0x414947524f5550);
        var pending = false;
        var approvals: usize = 0;
        var targets: usize = 0;
        if (self.exchange) |current| {
            pending = true;
            std.hash.autoHash(&hash, current.sequence);
            std.hash.autoHash(&hash, current.invocation.key.turn_id);
            std.hash.autoHash(&hash, current.invocation.key.owner);
            hash.update(current.invocation.key.call_id);
            hash.update(&current.invocation.arguments_hash);
            std.hash.autoHash(&hash, current.decision);
            std.hash.autoHash(&hash, current.phase.load(.acquire));
            targets = current.invocation.call.targets.len;
            approvals = @intFromBool(current.invocation.verdict == .need_confirm and current.decision == .pending and current.phase.load(.acquire) == .waiting);
            for (current.invocation.call.targets.slice()) |id| std.hash.autoHash(&hash, id);
        }
        self.mutex.unlock();
        for (self.children.items) |child| if (child.owner.eql(owner)) {
            const child_impact = child.bridge.vtable.impact(child.bridge.context, owner);
            if (child_impact.ai != 0) {
                pending = true;
                std.hash.autoHash(&hash, child_impact.ai);
            }
            impact.unknown = child_impact.unknown;
        };
        if (!pending) return impact;
        impact.ai = hash.final();
        if (impact.ai == 0) impact.ai = 1;
        var text: [512]u8 = undefined;
        const detail = std.fmt.bufPrint(&text, "组 #{d} · 会话 #{d} · {d} 个目标 · 待批准 {d}", .{ self.scope.?.owner.group, @backingInt(owner.session_id), targets, approvals }) catch "组 AI 原始成员调用正在收尾";
        impact.setDetail(detail);
        return impact;
    }
    pub fn stopGroup(self: *Bridge, group_id: u64) @import("../host/session_host.zig").CloseReceipt {
        self.lock();
        const captured = self.scope orelse {
            self.mutex.unlock();
            return .released;
        };
        if (captured.owner != .group or captured.owner.group != group_id) {
            self.mutex.unlock();
            return .released;
        }
        var receipt: @import("../host/session_host.zig").CloseReceipt = .released;
        if (self.exchange) |current| {
            current.cancel.cancel();
            if (current.phase.load(.acquire) == .waiting) current.phase.store(.cancelled, .release);
            receipt = .awaiting;
        }
        self.mutex.unlock();
        for (self.children.items) |child| {
            const r = child.bridge.vtable.stop(child.bridge.context, child.owner);
            if (r == .unknown or (r == .awaiting and receipt == .released)) receipt = r;
        }
        return receipt;
    }
    pub fn shutdown(self: *Bridge, app: ?*App) void {
        self.lock();
        self.shutting_down = true;
        if (self.exchange) |current| {
            current.cancel.cancel();
            if (current.phase.load(.acquire) == .waiting) current.phase.store(.cancelled, .release);
        }
        self.mutex.unlock();
        for (self.children.items) |child| child.bridge.vtable.shutdown(child.bridge.context, if (app) |host| host else null);
    }
    pub fn clear(self: *Bridge) !void {
        if (self.exchange != null) return error.ToolCleanupPending;
        for (self.children.items) |child| try child.bridge.vtable.clear(child.bridge.context);
        for (self.children.items) |child| {
            child.bridge.vtable.destroy(child.bridge.context, self.allocator);
            self.allocator.destroy(child);
        }
        self.children.clearRetainingCapacity();
        self.scope = null;
        self.roster = null;
    }
    pub fn deinit(self: *Bridge) void {
        self.clear() catch unreachable;
        self.children.deinit(self.allocator);
        self.* = undefined;
    }
};
fn pause() void {
    var duration: std.c.timespec = .{ .sec = 0, .nsec = 5 * std.time.ns_per_ms };
    _ = std.c.nanosleep(&duration, null);
}
