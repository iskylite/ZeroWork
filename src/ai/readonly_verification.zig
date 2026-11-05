//! Observation-only identities and bounded evidence. Never accepts a command.
const std = @import("std");
const identity = @import("../host/identity.zig");
const session = @import("../host/session_host.zig");
const operation = @import("../host/operation.zig");
pub const Anchor = struct {
    owner: identity.SessionHandle,
    service: session.ServiceHandle,
    create_key: ?operation.OperationKey = null,
    operation_key: ?operation.OperationKey = null,
    execution_id: ?identity.ExecutionId = null,
    context: ?@import("host_tools.zig").Context = null,
    turn_id: u64,
    call_hash: [32]u8,
    arguments_hash: [32]u8,

    pub fn validate(self: Anchor) !void {
        if (@backingInt(self.owner.session_id) == 0 or self.owner.generation == 0 or self.turn_id == 0 or self.service.binding_id == 0 or self.service.binding_generation == 0) return error.VerificationIdentityMismatch;
        if (self.service.resource_owner != .session or !self.service.resource_owner.session.eql(self.owner)) return error.VerificationIdentityMismatch;
        if (self.service.origin_session) |origin| if (!origin.eql(self.owner)) return error.VerificationIdentityMismatch;
        if (self.create_key) |key| if (key.owner != .session or !key.owner.session.eql(self.owner) or key.operation_id == 0) return error.VerificationIdentityMismatch;
        if (self.service.kind == .exec) {
            const key = self.operation_key orelse return error.VerificationIdentityMismatch;
            if (key.owner != .session or !key.owner.session.eql(self.owner) or key.operation_id == 0 or self.execution_id != null) return error.VerificationIdentityMismatch;
        } else if (self.service.kind == .terminal) {
            const id = self.execution_id orelse return error.VerificationIdentityMismatch;
            if (!id.valid() or self.operation_key != null) return error.VerificationIdentityMismatch;
            try (self.context orelse return error.VerificationIdentityMismatch).validate();
        } else return error.VerificationIdentityMismatch;
    }
    pub fn matches(self: Anchor, turn: u64, call: []const u8, arguments_hash: [32]u8) bool {
        self.validate() catch return false;
        return self.turn_id == turn and std.mem.eql(u8, &self.call_hash, &digest(call)) and std.mem.eql(u8, &self.arguments_hash, &arguments_hash);
    }
};
pub fn digest(bytes: []const u8) [32]u8 {
    var result: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &result, .{});
    return result;
}
pub fn validateBinding(anchor: Anchor, owner: identity.SessionHandle, service: session.ServiceHandle, create_key: operation.OperationKey) !void {
    try anchor.validate();
    if (!anchor.owner.eql(owner) or !anchor.service.eql(service)) return error.StaleBinding;
    if (anchor.create_key) |original| if (!original.eql(create_key)) return error.StaleSession;
    const source = service.origin_session orelse switch (service.resource_owner) {
        .session => |handle| handle,
        else => return error.StaleBinding,
    };
    if (!source.eql(anchor.owner)) return error.StaleBinding;
}
pub const Observation = struct {
    anchor: Anchor,
    observed_at_ms: i64 = 0,
    source: enum { original_worker, original_terminal } = .original_worker,
    failure: ?anyerror = null,
    exit_code: ?i32 = null,
    running: ?bool = null,
    foreground_finished: ?bool = null,
    local_released: ?bool = null,
    remote_effect_unknown: ?bool = null,
    stdout: [1024]u8 = @splat(0),
    stdout_len: usize = 0,
    stderr: [1024]u8 = @splat(0),
    stderr_len: usize = 0,
    truncated: bool = false,

    pub fn copyOutput(self: *Observation, out: []const u8, err: []const u8) void {
        self.stdout_len = @min(out.len, self.stdout.len);
        self.stderr_len = @min(err.len, self.stderr.len);
        @memcpy(self.stdout[0..self.stdout_len], out[0..self.stdout_len]);
        @memcpy(self.stderr[0..self.stderr_len], err[0..self.stderr_len]);
        self.truncated = self.truncated or out.len > self.stdout_len or err.len > self.stderr_len;
    }
    pub fn describe(self: Observation, buffer: []u8) []const u8 {
        if (self.failure) |err| return std.fmt.bufPrint(buffer, "只读核查未取得新证据：{s}。原结果仍待核实。", .{failureReason(err)}) catch "核查不可用，原结果仍待核实。";
        var exit: [32]u8 = undefined;
        const exit_text = if (self.exit_code) |code| std.fmt.bufPrint(&exit, "退出码 {d}", .{code}) catch "已收到退出码" else "退出码未确认";
        return std.fmt.bufPrint(buffer, "{s}；{s}；{s}。业务后果仍待核实，原未知状态保留。", .{ exit_text, if (self.running == true) "原执行仍在运行" else if (self.foreground_finished == true) "原前台执行已结束" else "执行结束状态未确认", if (self.local_released == true) "本地资源已释放" else "本地资源释放未确认" }) catch "已追加原操作的观察证据，原未知状态保留。";
    }
};
pub fn failureReason(err: anyerror) []const u8 {
    return switch (err) {
        error.WorkerBusy, error.OperationBusy => "原执行正在处理，请稍后核查",
        error.StaleSession, error.StaleBinding, error.StaleReference, error.StaleGeneration, error.SessionClosed => "原连接或服务已失效，不会重连或切换目标",
        error.TargetNotAuthorized, error.ScopeChanged, error.ServiceDenied, error.PermissionDenied, error.MissingAssistantOwner, error.TargetOutsideScope => "原目标的读取权限已失效",
        error.VerificationIdentityMismatch => "执行回执与原调用或原目标不匹配",
        error.ExecutionNotFound, error.VerificationSourceUnavailable => "原执行实例已不可读取，仅保留历史证据",
        else => "原目标暂不支持此核查或证据不可用",
    };
}
pub const History = struct {
    pub const max_observations = 4;
    items: std.ArrayList(Observation) = .empty,
    pub fn append(self: *History, allocator: std.mem.Allocator, value: Observation) !void {
        try self.items.ensureTotalCapacityPrecise(allocator, max_observations);
        if (self.items.items.len == max_observations) _ = self.items.orderedRemove(0);
        self.items.appendAssumeCapacity(value);
    }
    pub fn clone(self: History, allocator: std.mem.Allocator) !History {
        var copy: History = .{};
        if (self.items.items.len > 0) {
            try copy.items.ensureTotalCapacityPrecise(allocator, max_observations);
            try copy.items.appendSlice(allocator, self.items.items);
        }
        return copy;
    }
};
pub const Backend = struct {
    context: *anyopaque,
    read: *const fn (*anyopaque, Anchor) anyerror!Observation,
};
pub fn observe(anchor: Anchor, now: i64, backend: Backend) Observation {
    anchor.validate() catch |err| return .{ .anchor = anchor, .observed_at_ms = now, .failure = err };
    var result = backend.read(backend.context, anchor) catch |err| return .{ .anchor = anchor, .observed_at_ms = now, .failure = err };
    if (!std.meta.eql(result.anchor, anchor) or result.stdout_len > result.stdout.len or result.stderr_len > result.stderr.len) return .{ .anchor = anchor, .observed_at_ms = now, .failure = error.VerificationIdentityMismatch };
    result.observed_at_ms = now;
    return result;
}

test "readonly verification rejects another generation and keeps bounded independent evidence" {
    const a = std.testing.allocator;
    const owner: identity.SessionHandle = .{ .session_id = @fromBackingInt(7), .generation = 2 };
    const original: Anchor = .{ .owner = owner, .operation_key = .{ .owner = .{ .session = owner }, .operation_id = 12 }, .service = .{ .resource_owner = .{ .session = owner }, .origin_session = owner, .kind = .exec, .binding_id = 8, .binding_generation = 3 }, .turn_id = 4, .call_hash = digest("original-call"), .arguments_hash = digest("original-args") };
    const Fake = struct {
        reads: usize = 0,
        wrong: bool = false,
        fn read(raw: *anyopaque, anchor: Anchor) !Observation {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.reads += 1;
            var value: Observation = .{ .anchor = anchor, .exit_code = 0, .local_released = true };
            if (self.wrong) value.anchor.owner.generation += 1;
            value.copyOutput("original stdout", "original stderr");
            return value;
        }
    };
    var peer: Fake = .{};
    var history: History = .{};
    defer history.items.deinit(a);
    for (0..6) |i| try history.append(a, observe(original, @intCast(i), .{ .context = &peer, .read = Fake.read }));
    try std.testing.expectEqual(@as(usize, 4), history.items.items.len);
    var clone = try history.clone(a);
    defer clone.items.deinit(a);
    history.items.items[0].stdout[0] = 'X';
    try std.testing.expectEqualStrings("original stdout", clone.items.items[0].stdout[0..clone.items.items[0].stdout_len]);
    peer.wrong = true;
    const wrong = observe(original, 99, .{ .context = &peer, .read = Fake.read });
    try std.testing.expectEqual(error.VerificationIdentityMismatch, wrong.failure.?);
    try std.testing.expect(wrong.exit_code == null and wrong.stdout_len == 0);
    try std.testing.expect(original.matches(4, "original-call", digest("original-args")));
    try std.testing.expect(!original.matches(4, "other-call", digest("original-args")));
    try std.testing.expect(!original.matches(5, "original-call", digest("original-args")));
    try std.testing.expect(!original.matches(4, "original-call", digest("changed-args")));
}

test "readonly verification terminal never falls back to a mutating snapshot or advances execution" {
    const terminal = @import("../host/terminal_service.zig");
    const execution = terminal.execution;
    const Fake = struct {
        reads: usize = 0,
        effects: usize = 0,
        owner: identity.SessionHandle,
        id: identity.ExecutionId,
        wrong: bool = false,
        fn observeOnly(raw: *anyopaque, _: session.ServiceHandle, _: identity.ExecutionId) !execution.Snapshot {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.reads += 1;
            var owner = self.owner;
            if (self.wrong) owner.generation += 1;
            return .{ .owner = owner, .execution_id = self.id, .state = .running, .local_released = false, .remote_effect_unknown = true };
        }
        fn snapshot(raw: *anyopaque, _: session.ServiceHandle) !execution.Snapshot {
            @as(*@This(), @ptrCast(@alignCast(raw))).effects += 1;
            return error.ForbiddenDuringVerification;
        }
        fn request(raw: *anyopaque, _: session.ServiceHandle, _: execution.Request) !void {
            @as(*@This(), @ptrCast(@alignCast(raw))).effects += 1;
        }
        fn renew(raw: *anyopaque, _: session.ServiceHandle, _: execution.Grant) !void {
            @as(*@This(), @ptrCast(@alignCast(raw))).effects += 1;
        }
        fn revoke(raw: *anyopaque, _: session.ServiceHandle, _: execution.Grant, _: bool) !void {
            @as(*@This(), @ptrCast(@alignCast(raw))).effects += 1;
        }
    };
    const owner: identity.SessionHandle = .{ .session_id = @fromBackingInt(9), .generation = 3 };
    const id = identity.ExecutionId.generate();
    var peer: Fake = .{ .owner = owner, .id = id };
    // Only these slots may be touched; other capabilities are deliberately unavailable.
    var table: terminal.Service.VTable = undefined;
    table.execution_observe = Fake.observeOnly;
    table.execution_snapshot = Fake.snapshot;
    table.execution_request = Fake.request;
    table.execution_renew = Fake.renew;
    table.execution_revoke = Fake.revoke;
    const service: terminal.Service = .{ .context = &peer, .vtable = &table, .binding = .{ .resource_owner = .{ .session = owner }, .origin_session = owner, .kind = .terminal, .binding_id = 3, .binding_generation = 2 } };
    const result = try service.observeExecution(id);
    try std.testing.expect(result.remote_effect_unknown and !result.local_released);
    var conflicting = service;
    conflicting.binding.origin_session.?.generation += 1;
    try std.testing.expectError(error.VerificationIdentityMismatch, conflicting.observeExecution(id));
    try std.testing.expectEqual(@as(usize, 1), peer.reads);
    peer.wrong = true;
    try std.testing.expectError(error.VerificationIdentityMismatch, service.observeExecution(id));
    table.execution_observe = null;
    try std.testing.expectError(error.VerificationSourceUnavailable, service.observeExecution(id));
    try std.testing.expectEqual(@as(usize, 2), peer.reads);
    try std.testing.expectEqual(@as(usize, 0), peer.effects);
}

test "readonly verification binding rejects rebuilt sessions services and create operations" {
    const owner: identity.SessionHandle = .{ .session_id = @fromBackingInt(7), .generation = 2 };
    const key: operation.OperationKey = .{ .owner = .{ .session = owner }, .operation_id = 11, .attempt_id = 3 };
    const service: session.ServiceHandle = .{ .resource_owner = .{ .session = owner }, .origin_session = owner, .kind = .exec, .binding_id = 8, .binding_generation = 3 };
    const anchor: Anchor = .{ .owner = owner, .operation_key = key, .service = service, .create_key = key, .turn_id = 4, .call_hash = digest("call"), .arguments_hash = digest("args") };
    try validateBinding(anchor, owner, service, key);
    var rebuilt = owner;
    rebuilt.generation += 1;
    try std.testing.expectError(error.StaleBinding, validateBinding(anchor, rebuilt, service, key));
    var binding = service;
    binding.binding_generation += 1;
    try std.testing.expectError(error.StaleBinding, validateBinding(anchor, owner, binding, key));
    var create = key;
    create.attempt_id = 4;
    try std.testing.expectError(error.StaleSession, validateBinding(anchor, owner, service, create));
}

test "readonly verification rejects malformed identities before a reader and discards invalid output lengths" {
    const owner: identity.SessionHandle = .{ .session_id = @fromBackingInt(7), .generation = 2 };
    const key: operation.OperationKey = .{ .owner = .{ .session = owner }, .operation_id = 11 };
    const original: Anchor = .{ .owner = owner, .service = .{ .resource_owner = .{ .session = owner }, .origin_session = owner, .kind = .exec, .binding_id = 8, .binding_generation = 3 }, .operation_key = key, .create_key = key, .turn_id = 4, .call_hash = digest("call"), .arguments_hash = digest("args") };
    const Fake = struct {
        reads: usize = 0,
        fn read(raw: *anyopaque, anchor: Anchor) !Observation {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.reads += 1;
            return .{ .anchor = anchor, .stdout_len = 1025, .exit_code = 0, .local_released = true };
        }
    };
    var peer: Fake = .{};
    for (0..5) |i| {
        var invalid = original;
        switch (i) {
            0 => invalid.owner.generation = 0,
            1 => invalid.service.origin_session.?.generation += 1,
            2 => invalid.service.resource_owner.session.generation += 1,
            3 => invalid.operation_key.?.owner.session.generation += 1,
            4 => invalid.operation_key = null,
            else => unreachable,
        }
        const rejected = observe(invalid, 42, .{ .context = &peer, .read = Fake.read });
        try std.testing.expectEqual(error.VerificationIdentityMismatch, rejected.failure.?);
    }
    try std.testing.expectEqual(@as(usize, 0), peer.reads);
    const corrupt = observe(original, 43, .{ .context = &peer, .read = Fake.read });
    try std.testing.expectEqual(error.VerificationIdentityMismatch, corrupt.failure.?);
    try std.testing.expect(corrupt.stdout_len == 0 and corrupt.exit_code == null and corrupt.local_released == null);
    try std.testing.expectEqual(@as(usize, 1), peer.reads);
}
