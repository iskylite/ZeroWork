//! Immutable bounded batch output, retained independently of provider pages.
const std = @import("std");
const identity = @import("../host/identity.zig");
const host = @import("host_tools.zig");
pub const capture_limit = 4 * 1024 * 1024;
const store_limit = 32 * 1024 * 1024;
pub const Context = struct { store: *Store, conversation_id: identity.ConversationId, owner: identity.SessionHandle };
pub const contribution: host.Contribution = .{ .authority = .conversation_context, .definition = .{
    .id = "host.read_command_output",
    .description = "Read a page of an existing run_command result, never executes or replays the command. Use output_ref and next_output_cursor returned by that result. Cursor is a byte offset over stdout then stderr. Pages default to 8192 bytes, maximum 8192. Returns next_output_cursor until all retained bytes are read, with the original exit/status and retained_truncated flag. Retention is bounded at 4 MiB per result and 32 MiB/32 results per assistant; expired references fail explicitly. Current conversation, session generation and execution-read capability are revalidated.",
    .schema = "{\"type\":\"object\",\"additionalProperties\":false,\"properties\":{\"output_ref\":{\"type\":\"string\",\"minLength\":32,\"maxLength\":32},\"output_cursor\":{\"type\":\"integer\",\"minimum\":0},\"max_bytes\":{\"type\":\"integer\",\"minimum\":4,\"maximum\":8192}},\"required\":[\"output_ref\"]}",
} };
pub fn supports(name: []const u8) bool {
    return std.mem.eql(u8, name, contribution.definition.id);
}
pub const Request = struct { output_ref: []const u8, output_cursor: usize = 0, max_bytes: usize = 8192 };
pub fn parse(a: std.mem.Allocator, value: std.json.Value) !std.json.Parsed(Request) {
    const request = try std.json.parseFromValue(Request, a, value, .{});
    errdefer request.deinit();
    if (request.value.output_ref.len != 32 or request.value.max_bytes < 4 or request.value.max_bytes > 8192) return error.InvalidArguments;
    return request;
}
pub const Page = struct { stdout: []const u8, stderr: []const u8, next: ?usize };
pub fn page(stdout: []const u8, stderr: []const u8, offset: usize, maximum: usize) !Page {
    if (offset > stdout.len + stderr.len or maximum < 4) return error.InvalidCursor;
    var remaining: usize = @min(maximum, 8192);
    var out: []const u8 = "";
    var err: []const u8 = "";
    if (offset < stdout.len) {
        out = prefix(stdout[offset..], remaining);
        remaining -= out.len;
        if (offset + out.len == stdout.len and remaining >= 4) err = prefix(stderr, remaining);
    } else err = prefix(stderr[offset - stdout.len ..], remaining);
    const next = offset + out.len + err.len;
    if (next == offset and next < stdout.len + stderr.len) return error.ResultLimit;
    return .{ .stdout = out, .stderr = err, .next = if (next < stdout.len + stderr.len) next else null };
}
pub fn capturedText(bytes: []const u8, truncated: bool) []const u8 {
    if (!truncated or std.unicode.utf8ValidateSlice(bytes)) return bytes;
    var removed: usize = 1;
    while (removed <= 3 and removed < bytes.len) : (removed += 1) {
        if (std.unicode.utf8ValidateSlice(bytes[0 .. bytes.len - removed])) return bytes[0 .. bytes.len - removed];
    }
    return bytes;
}
fn prefix(bytes: []const u8, maximum: usize) []const u8 {
    var keep = @min(bytes.len, maximum);
    // Inputs are text. Never split a character between result pages.
    while (keep > 0 and !std.unicode.utf8ValidateSlice(bytes[0..keep])) keep -= 1;
    return bytes[0..keep];
}
const Entry = struct {
    id: [32]u8,
    conversation_id: identity.ConversationId,
    owner: identity.SessionHandle,
    stdout: []u8,
    stderr: []u8,
    status: []const u8,
    exit: ?i32,
    signal: ?u8,
    retained_truncated: bool,
    local_released: bool,
    remote_effect_unknown: bool,
};
pub const Store = struct {
    allocator: std.mem.Allocator,
    entries: std.ArrayList(Entry) = .empty,
    bytes: usize = 0,
    mutex: std.atomic.Mutex = .unlocked,
    pub fn init(a: std.mem.Allocator) Store {
        return .{ .allocator = a };
    }
    fn lock(self: *Store) void {
        while (!self.mutex.tryLock()) std.atomic.spinLoopHint();
    }
    fn release(self: *Store, entry: Entry) void {
        self.bytes -= entry.stdout.len + entry.stderr.len;
        self.allocator.free(entry.stdout);
        self.allocator.free(entry.stderr);
    }
    pub fn deinit(self: *Store) void {
        for (self.entries.items) |entry| self.release(entry);
        self.entries.deinit(self.allocator);
    }
    pub fn put(self: *Store, context: Context, result: anytype) ![32]u8 {
        if (@backingInt(context.owner.session_id) != result.session_id) return error.StaleReference;
        const size = result.stdout.len + result.stderr.len;
        if (size > capture_limit) return error.ResultLimit;
        self.lock();
        defer self.mutex.unlock();
        while (self.entries.items.len >= 32 or self.bytes + size > store_limit) self.release(self.entries.orderedRemove(0));
        const out = try self.allocator.dupe(u8, result.stdout);
        errdefer self.allocator.free(out);
        const err = try self.allocator.dupe(u8, result.stderr);
        errdefer self.allocator.free(err);
        const id = std.fmt.bytesToHex(identity.ExecutionId.generate().bytes, .lower);
        try self.entries.append(self.allocator, .{ .id = id, .conversation_id = context.conversation_id, .owner = context.owner, .stdout = out, .stderr = err, .status = @tagName(result.status), .exit = result.exit, .signal = result.signal, .retained_truncated = result.truncated, .local_released = result.local_released, .remote_effect_unknown = result.remote_effect_unknown });
        self.bytes += size;
        return id;
    }
    fn find(self: *Store, conversation: identity.ConversationId, reference: []const u8) ?*const Entry {
        for (self.entries.items) |*entry| if (entry.conversation_id.eql(conversation) and std.mem.eql(u8, &entry.id, reference)) return entry;
        return null;
    }
    pub fn source(self: *Store, conversation: identity.ConversationId, reference: []const u8) !identity.SessionHandle {
        self.lock();
        defer self.mutex.unlock();
        return (self.find(conversation, reference) orelse return error.OutputExpired).owner;
    }
    pub fn read(self: *Store, conversation: identity.ConversationId, request: Request, a: std.mem.Allocator) ![]u8 {
        self.lock();
        defer self.mutex.unlock();
        const entry = self.find(conversation, request.output_ref) orelse return error.OutputExpired;
        const chunk = try page(entry.stdout, entry.stderr, request.output_cursor, request.max_bytes);
        return std.json.Stringify.valueAlloc(a, .{ .output_ref = request.output_ref, .source = entry.owner, .output_cursor = request.output_cursor, .next_output_cursor = chunk.next, .stdout = chunk.stdout, .stderr = chunk.stderr, .status = "succeeded", .execution_status = entry.status, .local_released = entry.local_released, .remote_effect_unknown = entry.remote_effect_unknown, .exit = entry.exit, .signal = entry.signal, .retained_bytes = entry.stdout.len + entry.stderr.len, .retained_truncated = entry.retained_truncated, .truncated = chunk.next != null or entry.retained_truncated }, .{});
    }
};

test "pagination batch output crosses UTF8 stdout stderr boundaries and never crosses conversations" {
    const a = std.testing.allocator;
    var store = Store.init(a);
    defer store.deinit();
    const context: Context = .{ .store = &store, .conversation_id = .{ .bytes = @splat(1) }, .owner = .{ .session_id = @fromBackingInt(17), .generation = 3 } };
    const result: @import("tool_loop.zig").TargetResult = .{ .session_id = 17, .status = .failed, .stdout = "你好stdout", .stderr = "错误stderr", .exit = 7, .truncated = true };
    const reference = try store.put(context, result);
    try std.testing.expectError(error.OutputExpired, store.source(.{ .bytes = @splat(2) }, &reference));
    try std.testing.expect((try store.source(context.conversation_id, &reference)).eql(context.owner));
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(a);
    var err: std.ArrayList(u8) = .empty;
    defer err.deinit(a);
    var offset: usize = 0;
    while (true) {
        const body = try store.read(context.conversation_id, .{ .output_ref = &reference, .output_cursor = offset, .max_bytes = 4 }, a);
        defer a.free(body);
        const parsed = try std.json.parseFromSlice(std.json.Value, a, body, .{});
        defer parsed.deinit();
        const object = parsed.value.object;
        try out.appendSlice(a, object.get("stdout").?.string);
        try err.appendSlice(a, object.get("stderr").?.string);
        try std.testing.expectEqualStrings("failed", object.get("execution_status").?.string);
        try std.testing.expectEqual(@as(i64, 7), object.get("exit").?.integer);
        try std.testing.expect(object.get("retained_truncated").?.bool);
        const next = object.get("next_output_cursor").?;
        if (next == .null) break;
        try std.testing.expect(next.integer > offset);
        offset = @intCast(next.integer);
    }
    try std.testing.expectEqualStrings(result.stdout, out.items);
    try std.testing.expectEqualStrings(result.stderr, err.items);
    try std.testing.expectError(error.InvalidCursor, store.read(context.conversation_id, .{ .output_ref = &reference, .output_cursor = 999 }, a));
    for (0..32) |_| _ = try store.put(context, result);
    try std.testing.expectError(error.OutputExpired, store.source(context.conversation_id, &reference));
}
