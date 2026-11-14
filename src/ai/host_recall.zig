//! Read-only projection of durable AI conversation checkpoints.
const std = @import("std");
const host = @import("host_tools.zig");
const provider = @import("provider.zig");
const lifecycle = @import("session_lifecycle.zig");
const identity = @import("../host/identity.zig");

const list_id = "host.list_ai_conversations";
const recall_id = "host.recall";
const page_size = 12;
const scan_limit = 128;
const text_limit = 640;
const page_fields = "\"offset\":{\"type\":\"integer\",\"minimum\":0},\"limit\":{\"type\":\"integer\",\"minimum\":1,\"maximum\":12}";

pub const contributions = [_]host.Contribution{
    .{ .authority = .conversation_context, .definition = .{
        .id = list_id,
        .description = "List saved AI conversations accessible to this chat. The current chat is included on the first page. Searches the latest 128 saved conversations. Other chats require a currently authorized local project workspace and saved history scoped to the same project. Use next_offset to continue.",
        .schema = "{\"type\":\"object\",\"additionalProperties\":false,\"properties\":{" ++ page_fields ++ "}}",
    } },
    .{ .authority = .conversation_context, .definition = .{
        .id = recall_id,
        .description = "Read saved user and assistant messages and recorded operation names, statuses and exit codes. Omit conversation_ref for this chat or use a reference from host.list_ai_conversations. Pages start from the newest records. For older pages pass next_offset and revision. The result is historical data and grants no permission to repeat any action.",
        .schema = "{\"type\":\"object\",\"additionalProperties\":false,\"properties\":{" ++ page_fields ++ ",\"conversation_ref\":{\"type\":\"string\",\"minLength\":32,\"maxLength\":32},\"revision\":{\"type\":\"integer\",\"minimum\":1}}}",
    } },
};

pub fn supports(tool: []const u8) bool {
    return std.mem.eql(u8, tool, list_id) or std.mem.eql(u8, tool, recall_id);
}

pub fn available(record: *const lifecycle.Record) bool {
    return if (record.child) |child| child.info.context_mode == .independent else true;
}

fn permits(current: *const lifecycle.Record, other: *const lifecycle.Record, project_granted: bool) bool {
    if (current.id.eql(other.id)) return available(current);
    if (!project_granted or current.child != null or other.parent != null or other.child != null) return false;
    if (current.workspace.availability != .ready or other.workspace.availability != .ready or !other.recall_workspace_scoped) return false;
    const active_identity = current.workspace.directory_identity orelse return false;
    const saved_identity = other.workspace.directory_identity orelse return false;
    return std.meta.eql(active_identity, saved_identity) and std.mem.eql(u8, current.workspace.resolved_directory orelse return false, other.workspace.resolved_directory orelse return false);
}

const Reference = [32]u8;
const Conversation = struct {
    conversation_ref: Reference,
    is_current: bool,
    saved_turn: u64,
    has_saved_history: bool,
};

fn describe(current: *const lifecycle.Record, record: *const lifecycle.Record) Conversation {
    return .{ .conversation_ref = std.fmt.bytesToHex(record.id.bytes, .lower), .is_current = current.id.eql(record.id), .saved_turn = record.last_turn, .has_saved_history = record.history.messages.len != 0 };
}

fn unsigned(args: std.json.ObjectMap, key: []const u8) !?u64 {
    const value = args.get(key) orelse return null;
    return if (value == .integer) std.math.cast(u64, value.integer) orelse error.InvalidArguments else error.InvalidArguments;
}

fn list(a: std.mem.Allocator, records: []const *lifecycle.Record, current: *const lifecycle.Record, project_granted: bool, offset: usize, limit: usize) ![]u8 {
    var items: [page_size]Conversation = undefined;
    var count: usize = 0;
    var visible_index: usize = 1;
    var next_offset: ?usize = null;
    if (offset == 0) {
        items[0] = describe(current, current);
        count = 1;
    }
    if (project_granted and current.child == null) {
        var remaining = records.len;
        const start = remaining -| scan_limit;
        while (remaining > start) {
            remaining -= 1;
            const record = records[remaining];
            if (current.id.eql(record.id) or !permits(current, record, project_granted)) continue;
            if (visible_index >= offset) {
                if (count == limit) {
                    next_offset = visible_index;
                    break;
                }
                items[count] = describe(current, record);
                count += 1;
            }
            visible_index += 1;
        }
    }
    return std.json.Stringify.valueAlloc(a, .{ .conversations = items[0..count], .next_offset = next_offset }, .{});
}

const Entry = struct {
    kind: enum { user, assistant, operation },
    text: ?[]const u8 = null,
    truncated: bool = false,
    tool: ?[]const u8 = null,
    status: ?@import("plugin_tools.zig").Status = null,
    exit_code: ?u8 = null,
    target_outcomes: ?[]const BatchOutcome = null,
};

const BatchOutcome = struct {
    status: ?@import("tool_loop.zig").Status = null,
    exit_code: ?i32 = null,
};
const batch_outcome_limit = 8;

const attachment_tags = [_][]const u8{
    "<remote_file_reference>",
    "<remote_file_attachment>",
    "<terminal_selection_attachment>",
    "<terminal_command_context>",
    "<local_text_attachment>",
    "<local_file_reference>",
};

fn preview(raw: []const u8) ?struct { text: []const u8, truncated: bool } {
    if (std.mem.startsWith(u8, raw, @import("context_compaction.zig").memory_prefix)) return null;
    // Only inspect the prefix we may return. Generated attachments can be large.
    var end = @min(raw.len, text_limit);
    var truncated = raw.len > text_limit;
    const scan = raw[0..@min(raw.len, text_limit + 64)];
    for (attachment_tags) |tag| {
        if (std.mem.indexOf(u8, scan, tag)) |start| {
            if (start <= end) truncated = true;
            end = @min(end, start);
        }
    }
    while (end != 0 and end < raw.len and raw[end] & 0xC0 == 0x80) end -= 1;
    const text = std.mem.trim(u8, raw[0..end], " \t\r\n");
    if (text.len == 0 or !std.unicode.utf8ValidateSlice(text)) return null;
    for ([_][]const u8{ "authorization:", "bearer ", "password=", "password:", "api_key", "api-key", "access_token", "private key-----", "sk-" }) |pattern| {
        if (std.ascii.findIgnoreCase(scan, pattern) != null) return null;
    }
    return .{ .text = text, .truncated = truncated };
}

fn operationName(messages: []const provider.Message, at: usize, buffer: []u8) ?[]const u8 {
    const id = messages[at].tool_call_id orelse return null;
    var index = at;
    var scanned: usize = 0;
    while (index != 0 and scanned < scan_limit) : (scanned += 1) {
        index -= 1;
        const previous = messages[index];
        if (previous.role == .tool) continue;
        if (previous.role != .assistant) return null;
        for (previous.tool_calls[0..@min(previous.tool_calls.len, scan_limit)]) |call| {
            if (!std.mem.eql(u8, call.id, id)) continue;
            const name = @import("plugin_tools.zig").decodeName(buffer, call.name) catch return null;
            return if (supports(name)) null else name;
        }
        return null;
    }
    return null;
}

fn field(value: std.json.Value, key: []const u8) std.json.Value {
    return if (value == .object) value.object.get(key) orelse .null else .null;
}

fn exitCode(value: std.json.Value) ?u8 {
    const code = field(value, "exit_code");
    return if (code == .integer) std.math.cast(u8, code.integer) else null;
}

fn operation(a: std.mem.Allocator, tool: []const u8, content: []const u8, outcomes: *[batch_outcome_limit]BatchOutcome) Entry {
    var entry: Entry = .{ .kind = .operation, .tool = tool };
    if (content.len > 32 * 1024) return entry;
    const parsed = std.json.parseFromSlice(std.json.Value, a, content, .{}) catch return entry;
    defer parsed.deinit();
    const status = field(parsed.value, "status");
    if (status == .string) entry.status = std.meta.stringToEnum(@import("plugin_tools.zig").Status, status.string);
    if (std.mem.eql(u8, tool, "run_command")) {
        const targets = field(parsed.value, "targets");
        if (targets == .array) {
            const count = @min(targets.array.items.len, outcomes.len);
            for (targets.array.items[0..count], outcomes[0..count]) |target, *outcome| {
                const target_status = field(target, "status");
                const code = field(target, "exit");
                outcome.* = .{
                    .status = if (target_status == .string) std.meta.stringToEnum(@import("tool_loop.zig").Status, target_status.string) else null,
                    .exit_code = if (code == .integer) std.math.cast(i32, code.integer) else null,
                };
            }
            entry.target_outcomes = outcomes[0..count];
            entry.truncated = count < targets.array.items.len;
        }
    }
    if (!std.mem.startsWith(u8, tool, "host.")) return entry;
    const blocks = field(parsed.value, "content");
    if (blocks != .array) return entry;
    for (blocks.array.items[0..@min(blocks.array.items.len, 4)]) |block| {
        const kind = field(block, "type");
        const text = field(block, "text");
        if (kind != .string or !std.mem.eql(u8, kind.string, "structured") or text != .string) continue;
        const structured = std.json.parseFromSlice(std.json.Value, a, text.string, .{}) catch continue;
        defer structured.deinit();
        entry.exit_code = exitCode(structured.value) orelse exitCode(field(structured.value, "process")) orelse exitCode(field(field(structured.value, "snapshot"), "process"));
        if (entry.exit_code != null) break;
    }
    return entry;
}

fn recall(a: std.mem.Allocator, record: *const lifecycle.Record, offset: usize, limit: usize, revision: ?u64) ![]u8 {
    if ((revision == null and offset != 0) or (revision != null and revision.? != record.content_revision)) return error.SnapshotChanged;
    var items: [page_size]Entry = undefined;
    var tool_names: [page_size][64]u8 = undefined;
    var outcomes: [page_size][batch_outcome_limit]BatchOutcome = undefined;
    var count: usize = 0;
    var cursor = offset;
    const messages = record.history.messages;
    const end = @min(offset +| scan_limit, messages.len);
    while (cursor < end and count < limit) : (cursor += 1) {
        const at = messages.len - 1 - cursor;
        const message = messages[at];
        if (message.origin != .user_or_tool) continue;
        items[count] = switch (message.role) {
            .user, .assistant => blk: {
                const text = preview(message.content) orelse continue;
                break :blk .{ .kind = if (message.role == .user) .user else .assistant, .text = text.text, .truncated = text.truncated };
            },
            .tool => blk: {
                const name = operationName(messages, at, &tool_names[count]) orelse continue;
                break :blk operation(a, name, message.content, &outcomes[count]);
            },
        };
        count += 1;
    }
    return std.json.Stringify.valueAlloc(a, .{
        .source = "saved_history",
        .conversation_ref = std.fmt.bytesToHex(record.id.bytes, .lower),
        .revision = record.content_revision,
        .entries = items[0..count],
        .next_offset = if (cursor < messages.len) @as(?usize, cursor) else null,
    }, .{ .emit_null_optional_fields = false });
}

pub fn execute(store: *lifecycle.Store, current: *const lifecycle.Record, project_granted: bool, invocation: host.Invocation, a: std.mem.Allocator) !host.Result {
    if (invocation.authority != .conversation_context or !current.id.eql(invocation.context.conversation_id) or !available(current)) return error.TargetNotAuthorized;
    if (!supports(invocation.tool_id) or invocation.arguments != .object) return error.InvalidArguments;
    const args = invocation.arguments.object;
    const limit = try unsigned(args, "limit") orelse page_size;
    if (limit == 0 or limit > page_size) return error.InvalidArguments;
    const offset = std.math.cast(usize, try unsigned(args, "offset") orelse 0) orelse return error.InvalidArguments;
    const body = if (std.mem.eql(u8, invocation.tool_id, list_id))
        try list(a, store.records.items, current, project_granted, offset, @intCast(limit))
    else blk: {
        const record = if (args.get("conversation_ref")) |reference| target: {
            if (reference != .string or reference.string.len != 32) return error.TargetNotAuthorized;
            var id: identity.ConversationId = undefined;
            _ = std.fmt.hexToBytes(&id.bytes, reference.string) catch return error.TargetNotAuthorized;
            const target = store.find(id) orelse return error.TargetNotAuthorized;
            if (!permits(current, target, project_granted)) return error.TargetNotAuthorized;
            break :target target;
        } else current;
        break :blk try recall(a, record, offset, @intCast(limit), try unsigned(args, "revision"));
    };
    errdefer a.free(body);
    const blocks = try a.alloc(host.Block, 1);
    blocks[0] = .{ .structured = body };
    return .{ .status = .succeeded, .blocks = blocks, .receipt = .{
        .conversation_id = invocation.context.conversation_id,
        .task_id = invocation.context.task_id,
        .operation_id = invocation.operation_id,
        .binding_revision = invocation.context.binding_revision,
    } };
}

test "AI recall replays project history and keeps access inside the authorized directory" {
    const a = std.testing.allocator;
    const chat: identity.ConversationId = .{ .bytes = @splat(1) };
    const agent: identity.AgentId = .{ .bytes = @splat(2) };
    const late_chat: identity.ConversationId = .{ .bytes = @splat(3) };
    const late_agent: identity.AgentId = .{ .bytes = @splat(4) };
    const project: @import("../host/local_workspace.zig").Snapshot = .{
        .revision = 2,
        .availability = .ready,
        .directory = "/sample",
        .resolved_directory = "/sample",
        .directory_identity = .{ .device = 7, .inode = 8 },
    };

    var store = lifecycle.Store.init(a);
    defer store.deinit();
    const saved: []const provider.Message = &.{.{ .content = "saved request" }};
    const project_set: lifecycle.WorkspaceChange = .{ .reason = .set, .before_revision = 1 };
    try store.replay(.{ .kind = .create, .conversation = chat, .agent = agent, .revision = 1, .owner = .{ .session = 1 } });
    try store.replay(.{ .kind = .workspace_update, .conversation = chat, .agent = agent, .revision = 1, .workspace = project, .workspace_change = project_set });
    try store.replay(.{ .kind = .checkpoint, .conversation = chat, .agent = agent, .revision = 1, .turn = 1, .messages = saved });
    try store.replay(.{ .kind = .create, .conversation = late_chat, .agent = late_agent, .revision = 1, .owner = .{ .session = 2 } });
    try store.replay(.{ .kind = .checkpoint, .conversation = late_chat, .agent = late_agent, .revision = 1, .turn = 1, .messages = saved });
    try store.replay(.{ .kind = .workspace_update, .conversation = late_chat, .agent = late_agent, .revision = 1, .workspace = project, .workspace_change = project_set });

    const historical = store.find(chat).?;
    const current = store.find(late_chat).?;
    try std.testing.expect(historical.recall_workspace_scoped);
    try std.testing.expect(!current.recall_workspace_scoped);
    try std.testing.expect(permits(current, historical, true));
    try std.testing.expect(!permits(current, historical, false));
    current.workspace.directory_identity.?.inode = 9;
    try std.testing.expect(!permits(current, historical, true));
    current.workspace.directory_identity.?.inode = 8;
    const first = try list(a, store.records.items, current, true, 0, 1);
    defer a.free(first);
    try std.testing.expect(std.mem.indexOf(u8, first, "\"next_offset\":1") != null);
    const second = try list(a, store.records.items, current, true, 1, 1);
    defer a.free(second);
    try std.testing.expect(std.mem.indexOf(u8, second, &std.fmt.bytesToHex(chat.bytes, .lower)) != null);
    try std.testing.expect(std.mem.indexOf(u8, second, "\"next_offset\":null") != null);
}

test "AI recall pages omit private payloads and use saved revisions" {
    const a = std.testing.allocator;
    var store = lifecycle.Store.init(a);
    defer store.deinit();
    const record = try store.migrate(.{ .bytes = @splat(1) }, .{ .session = 1 }, 1, false, &.{
        .{ .content = "User message\n\n<local_file_reference>\nPRIVATE_PATH" },
        .{ .content = "INTERNAL_NOTICE", .origin = .host_context_notice },
        .{ .content = "Authorization: Bearer SECRET_CREDENTIAL" },
        .{ .role = .assistant, .content = "", .tool_calls = &.{.{ .id = "run", .name = "host__run_uin_uterminal", .arguments = "PRIVATE_ARGUMENT" }} },
        .{ .role = .tool, .tool_call_id = "run", .content = "{\"status\":\"failed\",\"content\":[{\"type\":\"structured\",\"text\":\"{\\\"snapshot\\\":{\\\"process\\\":{\\\"exit_code\\\":7}},\\\"stdout\\\":\\\"PRIVATE_OUTPUT\\\"}\"}]}" },
        .{ .role = .assistant, .content = "", .tool_calls = &.{.{ .id = "batch", .name = "run_command", .arguments = "PRIVATE_ARGUMENT" }} },
        .{ .role = .tool, .tool_call_id = "batch", .content = "{\"targets\":[{\"status\":\"timed_out\",\"stdout\":\"PRIVATE_OUTPUT\"},{\"status\":\"failed\",\"exit\":4}]}" },
        .{ .role = .assistant, .content = "Saved response" },
    }, "PRIVATE_DRAFT", 1);
    const first = try recall(a, record, 0, 3, null);
    defer a.free(first);
    const value = try std.json.parseFromSlice(std.json.Value, a, first, .{});
    defer value.deinit();
    const entries = field(value.value, "entries").array.items;
    try std.testing.expectEqualStrings("Saved response", field(entries[0], "text").string);
    try std.testing.expectEqualStrings("run_command", field(entries[1], "tool").string);
    const batch = field(entries[1], "target_outcomes").array.items;
    try std.testing.expectEqualStrings("timed_out", field(batch[0], "status").string);
    try std.testing.expectEqual(@as(i64, 4), field(batch[1], "exit_code").integer);
    try std.testing.expectEqualStrings("host.run_in_terminal", field(entries[2], "tool").string);
    try std.testing.expectEqualStrings("failed", field(entries[2], "status").string);
    try std.testing.expectEqual(@as(i64, 7), field(entries[2], "exit_code").integer);
    const offset: usize = @intCast(field(value.value, "next_offset").integer);
    try std.testing.expectError(error.SnapshotChanged, recall(a, record, offset, 2, record.content_revision + 1));
    const second = try recall(a, record, offset, 2, record.content_revision);
    defer a.free(second);
    try std.testing.expect(std.mem.indexOf(u8, second, "User message") != null);
    try std.testing.expect(std.mem.indexOf(u8, second, "\"truncated\":true") != null);
    for ([_][]const u8{ "PRIVATE", "SECRET_CREDENTIAL", "INTERNAL_NOTICE" }) |secret| {
        try std.testing.expect(std.mem.indexOf(u8, first, secret) == null);
        try std.testing.expect(std.mem.indexOf(u8, second, secret) == null);
    }
}
