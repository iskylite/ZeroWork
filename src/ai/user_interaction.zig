//! Human questions use a value-only mailbox. Postponing is exclusively a UI
//! state: it never resolves the worker or sends an empty tool response.
const std = @import("std");
const host = @import("host_tools.zig");
const provider = @import("provider.zig");
pub const max_options = 6;
pub const contribution: host.Contribution = .{ .authority = .conversation_context, .definition = .{
    .id = "host.request_user_input",
    .description = "Ask the user a question in the assistant composer and wait for their explicit answer. Use for missing information or a choice; never use to approve tool execution or request secrets. Options have stable unique IDs. The user can postpone without answering. Returns selected option ID and answer text. Cancellation produces no answer.",
    .schema =
    \\{"type":"object","additionalProperties":false,"properties":{"question":{"type":"string","minLength":1,"maxLength":1024},"options":{"type":"array","maxItems":6,"items":{"type":"object","additionalProperties":false,"properties":{"id":{"type":"string","minLength":1,"maxLength":64},"label":{"type":"string","minLength":1,"maxLength":256},"description":{"type":"string","maxLength":512}},"required":["id","label"]}},"allow_custom":{"type":"boolean"}},"required":["question"]}
    ,
} };
pub fn supports(name: []const u8) bool {
    return std.mem.eql(u8, name, contribution.definition.id);
}
pub fn Text(comptime capacity: usize) type {
    return struct {
        bytes: [capacity]u8 = @splat(0),
        len: usize = 0,
        pub fn init(value: []const u8) !@This() {
            if (value.len > capacity or !std.unicode.utf8ValidateSlice(value)) return error.InvalidUserQuestion;
            var buffer: @This() = .{ .len = value.len };
            @memcpy(buffer.bytes[0..value.len], value);
            return buffer;
        }
        pub fn text(self: *const @This()) []const u8 {
            return self.bytes[0..self.len];
        }
    };
}
pub const Option = struct { id: Text(64), label: Text(256), description: Text(512) = .{} };
pub const Ticket = struct {
    context: host.Context,
    sequence: u64,
    operation_id: u64,
    turn_id: u64,
    arguments_hash: [32]u8,
    pub fn eql(a: Ticket, b: Ticket) bool {
        return a.context.eql(b.context) and a.sequence == b.sequence and a.operation_id == b.operation_id and a.turn_id == b.turn_id and std.mem.eql(u8, &a.arguments_hash, &b.arguments_hash);
    }
};
pub const Snapshot = struct {
    ticket: Ticket,
    call: Text(provider.max_tool_call_id_bytes),
    question: Text(1024),
    options: [max_options]Option = undefined,
    option_count: usize = 0,
    allow_custom: bool = true,
};
pub const Answer = struct { option_id: ?Text(64) = null, text: Text(4096) };
pub const Broker = struct {
    mutex: std.atomic.Mutex = .unlocked,
    live_context: ?host.Context = null,
    next_sequence: u64 = 1,
    entry: ?struct { snapshot: Snapshot, answer: ?Answer = null } = null,
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
    /// New guidance invalidates this question, without stopping the task or
    /// manufacturing an answer. Waiting workers observe CancelledBeforeDispatch.
    pub fn supersede(self: *Broker) void {
        self.lock(); defer self.mutex.unlock(); self.entry = null;
    }
    pub fn begin(self: *Broker, invocation: host.Invocation, allocator: std.mem.Allocator) !Ticket {
        if (invocation.dispatch_fence) |fence| try fence.check();
        try invocation.context.validate();
        if (!supports(invocation.tool_id) or invocation.authority != .conversation_context or invocation.operation_id == 0 or invocation.turn_id == 0 or invocation.call_id.len == 0) return error.InvalidUserQuestion;
        const canonical = try @import("canonical_arguments.zig").digest(allocator, invocation.arguments);
        var wire: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(invocation.arguments_json, &wire, .{});
        if (!std.mem.eql(u8, &canonical, &invocation.canonical_arguments_hash) or !std.mem.eql(u8, &wire, &invocation.arguments_hash)) return error.InvalidUserQuestion;
        const Request = struct { question: []const u8, options: []const struct { id: []const u8, label: []const u8, description: []const u8 = "" } = &.{}, allow_custom: bool = true };
        const parsed = try std.json.parseFromValue(Request, allocator, invocation.arguments, .{});
        defer parsed.deinit();
        const request = parsed.value;
        if (std.mem.trim(u8, request.question, " \t\r\n").len == 0 or request.options.len > max_options or (request.options.len == 0 and !request.allow_custom)) return error.InvalidUserQuestion;
        var snapshot_value: Snapshot = .{ .ticket = undefined, .call = try Text(provider.max_tool_call_id_bytes).init(invocation.call_id), .question = try Text(1024).init(request.question), .allow_custom = request.allow_custom, .option_count = request.options.len };
        for (request.options, 0..) |option, index| {
            if (std.mem.trim(u8, option.id, " \t\r\n").len == 0 or std.mem.trim(u8, option.label, " \t\r\n").len == 0) return error.InvalidUserQuestion;
            for (request.options[0..index]) |previous| if (std.mem.eql(u8, previous.id, option.id)) return error.InvalidUserQuestion;
            snapshot_value.options[index] = .{ .id = try Text(64).init(option.id), .label = try Text(256).init(option.label), .description = try Text(512).init(option.description) };
        }
        self.lock();
        defer self.mutex.unlock();
        if (self.live_context == null or !self.live_context.?.eql(invocation.context)) return error.ScopeChanged;
        if (self.entry != null) return error.UserQuestionBusy;
        snapshot_value.ticket = .{ .context = invocation.context, .sequence = self.next_sequence, .operation_id = invocation.operation_id, .turn_id = invocation.turn_id, .arguments_hash = invocation.arguments_hash };
        self.next_sequence = std.math.add(u64, self.next_sequence, 1) catch return error.UserQuestionLimit;
        self.entry = .{ .snapshot = snapshot_value };
        return snapshot_value.ticket;
    }
    pub fn snapshot(self: *Broker) ?Snapshot {
        self.lock();
        defer self.mutex.unlock();
        const entry = self.entry orelse return null;
        return if (entry.answer == null) entry.snapshot else null;
    }
    pub fn answer(self: *Broker, ticket: Ticket, option_id: ?[]const u8, custom: []const u8) !void {
        self.lock();
        defer self.mutex.unlock();
        const entry = if (self.entry) |*value| value else return error.StaleUserQuestion;
        if (!entry.snapshot.ticket.eql(ticket) or entry.answer != null) return error.StaleUserQuestion;
        if (option_id) |id| {
            for (entry.snapshot.options[0..entry.snapshot.option_count]) |option| if (std.mem.eql(u8, option.id.text(), id)) {
                entry.answer = .{ .option_id = option.id, .text = try Text(4096).init(option.label.text()) };
                return;
            };
            return error.InvalidUserAnswer;
        }
        if (!entry.snapshot.allow_custom or std.mem.trim(u8, custom, " \t\r\n").len == 0) return error.InvalidUserAnswer;
        entry.answer = .{ .text = try Text(4096).init(std.mem.trim(u8, custom, " \t\r\n")) };
    }
    pub fn finish(self: *Broker, ticket: Ticket) void {
        self.lock();
        defer self.mutex.unlock();
        if (self.entry) |entry| if (entry.snapshot.ticket.eql(ticket)) {
            self.entry = null;
        };
    }
    pub fn poll(self: *Broker, ticket: Ticket) !?Answer {
        self.lock();
        defer self.mutex.unlock();
        const entry = self.entry orelse return error.CancelledBeforeDispatch;
        if (!entry.snapshot.ticket.eql(ticket)) return error.StaleUserQuestion;
        return entry.answer;
    }
    pub fn wait(self: *Broker, ticket: Ticket, cancel: ?*provider.CancelToken) !Answer {
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
pub fn result(invocation: host.Invocation, value: Answer, allocator: std.mem.Allocator) !host.Result {
    const body = try std.json.Stringify.valueAlloc(allocator, .{ .option_id = if (value.option_id) |id| id.text() else @as(?[]const u8, null), .answer = value.text.text() }, .{});
    errdefer allocator.free(body);
    const blocks = try allocator.alloc(host.Block, 1);
    blocks[0] = .{ .structured = body };
    return .{ .status = .succeeded, .blocks = blocks, .receipt = .{ .conversation_id = invocation.context.conversation_id, .task_id = invocation.context.task_id, .operation_id = invocation.operation_id, .binding_revision = invocation.context.binding_revision } };
}
