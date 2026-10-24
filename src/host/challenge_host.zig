//! Main-thread challenge matching. Display state contains public prompts only;
//! secret answers are transferred once to the caller and explicitly zeroed.
const std = @import("std");
const identity = @import("identity.zig");
const OperationKey = @import("operation.zig").OperationKey;
pub const Owner = union(enum) {
    session: identity.SessionHandle,
    operation: OperationKey,
    pub fn from(value: anytype) Owner {
        return switch (@TypeOf(value)) {
            Owner => value,
            identity.SessionHandle => .{ .session = value },
            OperationKey => .{ .operation = value },
            else => @compileError("challenge owner must be a session or original operation"),
        };
    }
    pub fn eql(self: Owner, other: anytype) bool {
        return std.meta.eql(self, Owner.from(other));
    }
    pub fn belongsTo(self: Owner, value: Owner) bool {
        if (self.eql(value)) return true;
        if (value == .session and self == .operation and self.operation.owner == .session) return self.operation.owner.session.eql(value.session);
        return false;
    }
    pub fn valid(self: Owner, generation: u64) bool {
        return switch (self) {
            .session => |value| @backingInt(value.session_id) != 0 and value.generation == generation,
            .operation => |value| value.operation_id != 0 and (value.attempt_id orelse 1) == generation,
        };
    }
    pub fn active(self: Owner, current: ?identity.SessionHandle) bool {
        const session = switch (self) {
            .session => |value| value,
            .operation => |value| switch (value.owner) {
                .session => |owner| owner,
                else => return true,
            },
        };
        return if (current) |value| session.eql(value) else false;
    }
};
pub const Kind = enum { secret_input, trust_material, choice };
pub const Option = struct { value: []const u8, label: []const u8 };
pub const Field = struct { label: []const u8, secret: bool = true, max_bytes: usize = 8192, confirmation: ?[]const u8 = null };
pub const Payload = struct { title: []const u8, detail: []const u8 = "", source_name: []const u8 = "", material: []const u8 = "", choices: []const Option = &.{}, fields: []const Field = &.{}, submit_label: []const u8 = "确认" };
pub const State = enum { pending, answered, withdrawn, timed_out, cancelled };
pub const View = struct { owner: Owner, request_id: u64, generation: u64, kind: Kind, payload: Payload, deadline: u64, state: State = .pending, background: bool = false };
pub const Reply = union(enum) { secret_input: []const u8, trust_material: bool, choice: []const u8, fields: []const []const u8 };
pub const Answer = struct {
    allocator: std.mem.Allocator,
    owner: Owner,
    request_id: u64,
    generation: u64,
    value: Reply,
    pub fn deinit(self: *Answer) void {
        switch (self.value) {
            .secret_input => |secret| {
                std.crypto.secureZero(u8, @constCast(secret));
                self.allocator.free(secret);
            },
            .choice => |choice| self.allocator.free(choice),
            .fields => |fields| {
                for (fields) |bytes| {
                    std.crypto.secureZero(u8, @constCast(bytes));
                    self.allocator.free(bytes);
                }
                self.allocator.free(fields);
            },
            .trust_material => {},
        }
        self.* = undefined;
    }
};
const Record = struct { arena: std.heap.ArenaAllocator, view: View };
pub const Completion = struct { owner: Owner, request_id: u64, generation: u64, state: State };
pub const Host = struct {
    pub const capacity = 32;
    allocator: std.mem.Allocator,
    records: std.ArrayList(Record) = .empty,
    answers: std.ArrayList(Answer) = .empty,
    pub fn init(allocator: std.mem.Allocator) Host {
        return .{ .allocator = allocator };
    }
    pub fn deinit(self: *Host) void {
        for (self.records.items) |*record| record.arena.deinit();
        self.records.deinit(self.allocator);
        for (self.answers.items) |*value| value.deinit();
        self.answers.deinit(self.allocator);
    }
    pub fn offer(self: *Host, owner_value: anytype, request_id: u64, generation: u64, kind: Kind, payload: Payload, deadline: u64) !void {
        const owner = Owner.from(owner_value);
        if (!owner.valid(generation) or request_id == 0 or generation == 0 or deadline == 0 or payload.title.len == 0) return error.InvalidChallenge;
        if (payload.title.len > 256 or payload.detail.len > 8192 or payload.material.len > 16384 or payload.choices.len > 32 or payload.fields.len > 16 or payload.source_name.len > 4096 or payload.submit_label.len > 128) return error.ChallengeTooLarge;
        if (kind == .secret_input and payload.choices.len != 0) return error.UnexpectedChoices;
        if (kind == .choice and payload.choices.len == 0) return error.MissingChoices;
        if (self.find(owner, request_id, generation) != null) return error.DuplicateChallenge;
        if (self.records.items.len == capacity) return error.ChallengeQueueFull;
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        errdefer arena.deinit();
        const alloc = arena.allocator();
        var copy = payload;
        copy.title = try alloc.dupe(u8, payload.title);
        copy.detail = try alloc.dupe(u8, payload.detail);
        copy.source_name = try alloc.dupe(u8, payload.source_name);
        copy.material = try alloc.dupe(u8, payload.material);
        const choices = try alloc.alloc(Option, payload.choices.len);
        for (payload.choices, 0..) |option, i| {
            if (option.value.len == 0 or option.value.len > 256 or option.label.len > 256) return error.InvalidChoice;
            for (payload.choices[0..i]) |prior| if (std.mem.eql(u8, prior.value, option.value)) return error.DuplicateChoice;
            choices[i] = .{ .value = try alloc.dupe(u8, option.value), .label = try alloc.dupe(u8, option.label) };
        }
        copy.choices = choices;
        copy.submit_label = try alloc.dupe(u8, payload.submit_label);
        const fields = try alloc.alloc(Field, payload.fields.len);
        for (payload.fields, fields) |field, *destination| {
            if (field.label.len == 0 or field.label.len > 4096 or field.max_bytes == 0 or field.max_bytes > 8192) return error.InvalidChallengeField;
            destination.* = .{ .label = try alloc.dupe(u8, field.label), .secret = field.secret, .max_bytes = field.max_bytes, .confirmation = if (field.confirmation) |value| try alloc.dupe(u8, value) else null };
        }
        copy.fields = fields;
        try self.records.append(self.allocator, .{ .arena = arena, .view = .{ .owner = owner, .request_id = request_id, .generation = generation, .kind = kind, .payload = copy, .deadline = deadline } });
    }
    /// Borrowed public-only display data; invalidated by the next host mutation.
    pub fn snapshot(self: *const Host, index: usize, active_owner: ?identity.SessionHandle) ?View {
        if (index >= self.records.items.len) return null;
        var view = self.records.items[index].view;
        view.background = !view.owner.active(active_owner);
        return view;
    }
    pub fn answer(self: *Host, owner_value: anytype, request_id: u64, generation: u64, reply: Reply, now_ms: u64) !Answer {
        const owner = Owner.from(owner_value);
        const record = self.find(owner, request_id, generation) orelse return error.ChallengeMismatch;
        if (record.view.state != .pending) return error.ChallengeNotPending;
        if (now_ms >= record.view.deadline) {
            record.view.state = .timed_out;
            return error.ChallengeExpired;
        }
        const expected: std.meta.Tag(Reply) = if (record.view.payload.fields.len != 0) .fields else if (record.view.payload.choices.len != 0) .choice else switch (record.view.kind) {
            .secret_input => .secret_input,
            .trust_material => .trust_material,
            .choice => .choice,
        };
        if (std.meta.activeTag(reply) != expected) return error.ChallengeKindMismatch;
        var value = reply;
        switch (reply) {
            .secret_input => |secret| {
                if (secret.len > 8192) return error.SecretTooLarge;
                value = .{ .secret_input = try self.allocator.dupe(u8, secret) };
            },
            .choice => |choice| {
                var found = false;
                for (record.view.payload.choices) |option| if (std.mem.eql(u8, option.value, choice)) {
                    found = true;
                    break;
                };
                if (!found) return error.UnknownChoice;
                value = .{ .choice = try self.allocator.dupe(u8, choice) };
            },
            .fields => |fields| {
                if (fields.len != record.view.payload.fields.len) return error.InvalidChallengeResponse;
                for (fields, record.view.payload.fields) |bytes, field| {
                    if (bytes.len == 0 or bytes.len > field.max_bytes or std.mem.indexOfScalar(u8, bytes, 0) != null) return error.InvalidChallengeResponse;
                    if (field.confirmation) |confirmation| if (!std.mem.eql(u8, bytes, confirmation)) return error.InvalidChallengeConfirmation;
                }
                const copies = try self.allocator.alloc([]const u8, fields.len);
                errdefer self.allocator.free(copies);
                var copied: usize = 0;
                errdefer for (copies[0..copied]) |bytes| {
                    std.crypto.secureZero(u8, @constCast(bytes));
                    self.allocator.free(bytes);
                };
                for (fields, copies) |bytes, *copy| {
                    copy.* = try self.allocator.dupe(u8, bytes);
                    copied += 1;
                }
                value = .{ .fields = copies };
            },
            .trust_material => {},
        }
        record.view.state = .answered;
        return .{ .allocator = self.allocator, .owner = owner, .request_id = request_id, .generation = generation, .value = value };
    }
    /// UI transfers an owned reply into the host mailbox. Controller polling
    /// receives it only by the original owner/request/generation tuple.
    pub fn submitAnswer(self: *Host, owner_value: anytype, request_id: u64, generation: u64, reply: Reply, now_ms: u64) !void {
        const owner = Owner.from(owner_value);
        if (self.answers.items.len >= capacity) return error.ChallengeAnswerQueueFull;
        try self.answers.ensureUnusedCapacity(self.allocator, 1);
        const value = try self.answer(owner, request_id, generation, reply, now_ms);
        self.answers.appendAssumeCapacity(value);
    }
    pub fn stateFor(self: *const Host, owner_value: anytype, request_id: u64, generation: u64) ?State {
        const owner = Owner.from(owner_value);
        for (self.records.items) |record| if (record.view.owner.eql(owner) and record.view.request_id == request_id and record.view.generation == generation) return record.view.state;
        return null;
    }
    pub fn takeAnswer(self: *Host, owner_value: anytype, request_id: u64, generation: u64) ?Answer {
        const owner = Owner.from(owner_value);
        for (self.answers.items, 0..) |value, i| if (value.owner.eql(owner) and value.request_id == request_id and value.generation == generation) {
            const answer_value = self.answers.orderedRemove(i);
            // Consuming the reply acknowledges the answered prompt. The
            // answer owns independent bytes; public prompt storage can retire.
            for (self.records.items, 0..) |record, index| if (record.view.owner.eql(owner) and record.view.request_id == request_id and record.view.generation == generation) {
                var removed = self.records.orderedRemove(index);
                removed.arena.deinit();
                break;
            };
            return answer_value;
        };
        return null;
    }
    pub fn withdraw(self: *Host, owner_value: anytype, request_id: u64, generation: u64) !bool {
        const owner = Owner.from(owner_value);
        const record = self.find(owner, request_id, generation) orelse return error.ChallengeMismatch;
        if (record.view.state != .pending) return false;
        record.view.state = .withdrawn;
        return true;
    }
    pub fn ownerClosed(self: *Host, owner_value: anytype) void {
        const owner = Owner.from(owner_value);
        var index: usize = 0;
        while (index < self.answers.items.len) {
            if (self.answers.items[index].owner.belongsTo(owner)) {
                var value = self.answers.orderedRemove(index);
                value.deinit();
            } else index += 1;
        }
        for (self.records.items) |*record| if (record.view.owner.belongsTo(owner) and record.view.state == .pending) {
            record.view.state = .cancelled;
        };
    }
    /// After controller cancellation/close has consumed its terminal state,
    /// release public prompt storage without retaining authentication history.
    pub fn retireOwner(self: *Host, owner_value: anytype) void {
        const owner = Owner.from(owner_value);
        self.ownerClosed(owner);
        var i: usize = 0;
        while (i < self.records.items.len) {
            if (self.records.items[i].view.owner.belongsTo(owner)) {
                var removed = self.records.orderedRemove(i);
                removed.arena.deinit();
            } else i += 1;
        }
    }
    pub fn tick(self: *Host, now_ms: u64) void {
        for (self.records.items) |*record| if (record.view.state == .pending and now_ms >= record.view.deadline) {
            record.view.state = .timed_out;
        };
    }
    pub fn takeCompletion(self: *Host) ?Completion {
        for (self.records.items, 0..) |record, i| if (record.view.state != .pending) {
            var removed = self.records.orderedRemove(i);
            defer removed.arena.deinit();
            return .{ .owner = removed.view.owner, .request_id = removed.view.request_id, .generation = removed.view.generation, .state = removed.view.state };
        };
        return null;
    }
    pub fn retire(self: *Host, owner_value: anytype, request_id: u64, generation: u64) void {
        const owner = Owner.from(owner_value);
        if (self.takeAnswer(owner, request_id, generation)) |incoming| {
            var value = incoming;
            value.deinit();
        }
        for (self.records.items, 0..) |record, i| if (record.view.owner.eql(owner) and record.view.request_id == request_id and record.view.generation == generation) {
            var removed = self.records.orderedRemove(i);
            removed.arena.deinit();
            return;
        };
    }
    fn find(self: *Host, owner_value: anytype, request_id: u64, generation: u64) ?*Record {
        const owner = Owner.from(owner_value);
        for (self.records.items) |*record| if (record.view.owner.eql(owner) and record.view.request_id == request_id and record.view.generation == generation) return record;
        return null;
    }
};
pub const ChallengeHost = Host;
test "challenge answer matches request and secrets never enter snapshot" {
    var host = Host.init(std.testing.allocator);
    defer host.deinit();
    const owner: identity.SessionHandle = .{ .session_id = @fromBackingInt(7) };
    try host.offer(owner, 1, 1, .secret_input, .{ .title = "Password", .source_name = "fixture" }, 100);
    try std.testing.expectError(error.ChallengeMismatch, host.answer(owner, 2, 1, .{ .secret_input = "secret" }, 1));
    try std.testing.expectError(error.ChallengeKindMismatch, host.answer(owner, 1, 1, .{ .choice = "secret" }, 1));
    var answer = try host.answer(owner, 1, 1, .{ .secret_input = "secret" }, 1);
    defer answer.deinit();
    const view = host.snapshot(0, null).?;
    try std.testing.expect(view.background);
    try std.testing.expectEqualStrings("", view.payload.detail);
    try std.testing.expectEqual(State.answered, host.takeCompletion().?.state);
    try std.testing.expectEqualStrings("secret", answer.value.secret_input);
}
test "challenge timeout withdrawal and close are distinct idempotent terminals" {
    var host = Host.init(std.testing.allocator);
    defer host.deinit();
    const owner: identity.SessionHandle = .{ .session_id = @fromBackingInt(7) };
    try host.offer(owner, 1, 1, .trust_material, .{ .title = "Trust?", .material = "sha256:test" }, 5);
    host.tick(5);
    try std.testing.expectError(error.ChallengeNotPending, host.answer(owner, 1, 1, .{ .trust_material = true }, 5));
    try std.testing.expectEqual(State.timed_out, host.takeCompletion().?.state);
    try host.offer(owner, 2, 1, .choice, .{ .title = "Choice", .choices = &.{.{ .value = "one", .label = "One" }} }, 10);
    try std.testing.expect(try host.withdraw(owner, 2, 1));
    try std.testing.expect(!try host.withdraw(owner, 2, 1));
    try std.testing.expectEqual(State.withdrawn, host.takeCompletion().?.state);
}

test "challenge mailbox matches owner request generation and clears unconsumed secret on close" {
    var host = Host.init(std.testing.allocator);
    defer host.deinit();
    const owner: identity.SessionHandle = .{ .session_id = @fromBackingInt(5) };
    try host.offer(owner, 7, 1, .secret_input, .{ .title = "Secret" }, 100);
    try host.submitAnswer(owner, 7, 1, .{ .secret_input = "one-time" }, 1);
    try std.testing.expect(host.takeAnswer(try owner.nextGeneration(), 7, 1) == null);
    var value = host.takeAnswer(owner, 7, 1).?;
    defer value.deinit();
    try std.testing.expectEqualStrings("one-time", value.value.secret_input);
    _ = host.takeCompletion();
    try host.offer(owner, 8, 1, .secret_input, .{ .title = "Secret" }, 100);
    try host.submitAnswer(owner, 8, 1, .{ .secret_input = "unconsumed" }, 1);
    host.ownerClosed(owner);
    try std.testing.expect(host.takeAnswer(owner, 8, 1) == null);
}

test "original probe operation and session challenge identities cannot alias and form answers are owned" {
    var host = Host.init(std.testing.allocator);
    defer host.deinit();
    const session: identity.SessionHandle = .{ .session_id = @fromBackingInt(7), .generation = 3 };
    const operation: OperationKey = .{ .owner = .app, .operation_id = 7, .attempt_id = 3 };
    try host.offer(operation, 1, 3, .secret_input, .{ .title = "Additional authentication", .fields = &.{ .{ .label = "Account", .secret = false, .max_bytes = 256 }, .{ .label = "Recovery response", .max_bytes = 256 } } }, 100);
    try host.offer(session, 1, 3, .secret_input, .{ .title = "Session secret" }, 100);
    try std.testing.expect(!host.snapshot(0, null).?.payload.fields[0].secret);
    try std.testing.expect(host.snapshot(0, null).?.payload.fields[1].secret);
    var account = [_]u8{ 'o', 'p', 's' };
    var secret = [_]u8{ 'o', 'n', 'e' };
    try host.submitAnswer(operation, 1, 3, .{ .fields = &.{ &account, &secret } }, 1);
    @memset(&account, 'x');
    @memset(&secret, 'x');
    try std.testing.expect(host.takeAnswer(session, 1, 3) == null);
    var answer_value = host.takeAnswer(operation, 1, 3).?;
    defer answer_value.deinit();
    try std.testing.expectEqualStrings("ops", answer_value.value.fields[0]);
    try std.testing.expectEqualStrings("one", answer_value.value.fields[1]);
    try std.testing.expectEqual(State.pending, host.stateFor(session, 1, 3).?);
}

test "trust replacement requires exact confirmation and closing session retires its operation answers" {
    var host = Host.init(std.testing.allocator);
    defer host.deinit();
    const session: identity.SessionHandle = .{ .session_id = @fromBackingInt(7), .generation = 3 };
    const operation: OperationKey = .{ .owner = .{ .session = session }, .operation_id = 19, .attempt_id = 2 };
    try host.offer(operation, 1, 2, .trust_material, .{ .title = "Key changed", .material = "Old SHA256:old / New SHA256:new", .fields = &.{.{ .label = "Type yes", .secret = false, .max_bytes = 3, .confirmation = "yes" }} }, 100);
    try std.testing.expectError(error.InvalidChallengeConfirmation, host.submitAnswer(operation, 1, 2, .{ .fields = &.{"YES"} }, 1));
    try std.testing.expectEqual(State.pending, host.stateFor(operation, 1, 2).?);
    try host.submitAnswer(operation, 1, 2, .{ .fields = &.{"yes"} }, 1);
    host.ownerClosed(session);
    try std.testing.expect(host.takeAnswer(operation, 1, 2) == null);
    host.retireOwner(session);
    try std.testing.expectEqual(@as(usize, 0), host.records.items.len);
    try std.testing.expectEqual(@as(usize, 0), host.answers.items.len);
}
