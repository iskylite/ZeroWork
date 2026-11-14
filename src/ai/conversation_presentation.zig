//! Durable display history, separate from compactable provider context.
//! Rehydration owns every value and never recreates execution authority.
const std = @import("std");
const messages = @import("assistant_store.zig");
const turns = @import("conversation_turn.zig");
const journal = @import("session_journal.zig");
const wire = @import("wire_history.zig");
const text = @import("local_text_attachments.zig");
const images = @import("image_attachments.zig");
const provider = @import("provider.zig");
const Segment = struct { text: []const u8, started_ms: u64, ended_ms: ?u64, expanded: bool, submission: ?@import("../host/identity.zig").SubmissionId = null };
const Timeline = union(enum) { message: Segment, thinking: Segment, input: Segment, tool: usize, notice: usize };
const Group = struct { first: usize, expanded: bool };
const Turn = struct {
    id: u64,
    task_id: ?@import("../host/identity.zig").TaskId,
    sent_at_ms: u64,
    ended_at_ms: ?u64,
    started_mono_ms: u64,
    elapsed_ms: u64,
    input_tokens: ?u64,
    output_tokens: ?u64,
    request_count: ?u64 = null,
    thinking_started_ms: ?u64,
    thinking_ended_ms: ?u64,
    thinking_expanded: bool,
    file_source: ?@import("terminal_file_source.zig").Source,
    before: []const journal.Message = &.{},
    after: []const journal.Message = &.{},
    before_refs: ?[]const usize = null,
    after_refs: ?[]const usize = null,
    answer: []const u8,
    prose: []const u8,
    thinking: []const u8,
    steps: []const @import("step_events.zig").Step,
    notices: []const turns.HostNotice,
    timeline: []const Timeline,
    groups: []const Group,
};
const scalar_fields = .{ "id", "task_id", "sent_at_ms", "ended_at_ms", "started_mono_ms", "elapsed_ms", "input_tokens", "output_tokens", "request_count", "thinking_started_ms", "thinking_ended_ms", "thinking_expanded" };
const TextItem = struct { id: u64, content: text.Content };
const TextBundle = struct { owner: text.Owner, conversation_id: ?messages.ConversationId, draft_epoch: u64, items: []const TextItem };
const ImageBundle = struct { owner: text.Owner, conversation_id: ?messages.ConversationId, draft_epoch: u64, ids: []const u64, messages: []const journal.Message };
const Message = struct { user: bool, text: []const u8, wire_text: ?[]const u8, turn: ?Turn, attachments: ?TextBundle, images: ?ImageBundle };
const Snapshot = struct {
    schema: u8 = 1,
    messages: []const Message,
    context: []const journal.Message = &.{},
};

// Before/after checkpoints often share most of their provider messages.
// Preserve each ordered checkpoint while encoding each distinct message once.
const ContextTable = struct {
    allocator: std.mem.Allocator,
    entries: std.ArrayList(journal.Message) = .empty,
    indices: std.HashMapUnmanaged(provider.Message, usize, MessageKey, 80) = .empty,

    const MessageKey = struct {
        pub fn hash(_: MessageKey, message: provider.Message) u64 {
            return std.hash.Wyhash.hash(@backingInt(message.role), message.content);
        }

        pub fn eql(_: MessageKey, left: provider.Message, right: provider.Message) bool {
            if (left.role != right.role or left.origin != right.origin or
                !std.meta.eql(left.skill, right.skill) or
                !std.meta.eql(left.image_owner, right.image_owner) or left.image_transform != right.image_transform or
                !std.mem.eql(u8, left.content, right.content) or
                (left.tool_call_id == null) != (right.tool_call_id == null) or
                !std.mem.eql(u8, left.tool_call_id orelse "", right.tool_call_id orelse "") or
                left.tool_calls.len != right.tool_calls.len or
                left.file_reference_spans.len != right.file_reference_spans.len or
                left.images.len != right.images.len or left.offloaded_images.len != right.offloaded_images.len) return false;
            for (left.tool_calls, right.tool_calls) |a, b| {
                if (!std.mem.eql(u8, a.id, b.id) or !std.mem.eql(u8, a.name, b.name) or !std.mem.eql(u8, a.arguments, b.arguments)) return false;
            }
            for (left.file_reference_spans, right.file_reference_spans) |a, b| {
                if (!std.meta.eql(a, b)) return false;
            }
            for (left.images, right.images) |a, b| {
                if (!sameImage(a, b)) return false;
            }
            for (left.offloaded_images, right.offloaded_images) |a, b| {
                if (!std.meta.eql(a.owner, b.owner) or !sameImage(a.reference, b.reference)) return false;
            }
            return true;
        }

        fn sameImage(left: images.ContentRef, right: images.ContentRef) bool {
            if (left.snapshot == right.snapshot) return true;
            const a = left.content() orelse return false;
            const b = right.content() orelse return false;
            return a.captured_at_ms == b.captured_at_ms and std.mem.eql(u8, a.path, b.path) and std.mem.eql(u8, a.bytes, b.bytes);
        }
    };

    fn checkpoint(self: *ContextTable, history: []const provider.Message) ![]const usize {
        const refs = try self.allocator.alloc(usize, history.len);
        for (history, refs) |message, *ref| {
            const entry = try self.indices.getOrPut(self.allocator, message);
            if (!entry.found_existing) {
                entry.value_ptr.* = self.entries.items.len;
                const encoded = try journal.Journal.encode(self.allocator, &.{message});
                try self.entries.append(self.allocator, encoded[0]);
            }
            ref.* = entry.value_ptr.*;
        }
        return refs;
    }
};

pub const Version = struct {
    content: u64 = 0,
    context: u64 = 0,
    usage: ?@import("context_usage.zig").Baseline = null,
};

/// Own the mutable display data before handing it to a serializer. Large
/// immutable provider transcripts and attachment bytes are retained by reference.
pub const Capture = struct {
    history: std.ArrayList(messages.Message) = .empty,
    current: ?messages.Message = null,
    cards: @import("card_stream.zig").Stream,

    pub fn init(a: std.mem.Allocator, history: []const messages.Message, current: ?messages.Message, cards: []const @import("card.zig").Card) !Capture {
        var result: Capture = .{ .cards = .init(a) };
        errdefer result.deinit(a);
        try result.history.ensureTotalCapacity(a, history.len);
        for (history) |message| result.history.appendAssumeCapacity(try message.clone(a));
        if (current) |message| {
            result.current = try message.clone(a);
            for (cards) |card| switch (card) {
                .text, .code => _ = try result.cards.append(card),
                else => {},
            };
        }
        return result;
    }

    pub fn deinit(self: *Capture, a: std.mem.Allocator) void {
        self.cards.deinit();
        if (self.current) |*message| message.deinit(a);
        for (self.history.items) |*message| message.deinit(a);
        self.history.deinit(a);
    }

    pub fn encode(self: *const Capture, a: std.mem.Allocator) ![]u8 {
        return capture(a, self.history.items, self.current, self.cards.cards.items);
    }
};

fn encodeTurn(a: std.mem.Allocator, source: *const turns.Turn, context: *ContextTable) !Turn {
    var result: Turn = undefined;
    inline for (scalar_fields) |field| @field(result, field) = @field(source, field);
    result.file_source = source.file_source;
    result.before = &.{};
    result.after = &.{};
    result.before_refs = try context.checkpoint(source.before.messages);
    result.after_refs = try context.checkpoint(source.after.messages);
    result.answer = source.answer;
    result.prose = source.prose.items;
    result.thinking = source.thinking.items;
    result.steps = source.steps.items;
    result.notices = source.host_notices.items;
    const timeline = try a.alloc(Timeline, source.timeline.items.len);
    for (source.timeline.items, timeline) |item, *dest| dest.* = switch (item) {
        .tool => |index| .{ .tool = index },
        .notice => |index| .{ .notice = index },
        .thinking, .message, .input => |segment| blk: {
            const value: Segment = .{ .text = segment.text.items, .started_ms = segment.started_ms, .ended_ms = segment.ended_ms, .expanded = segment.expanded, .submission = segment.submission };
            break :blk if (item == .message) .{ .message = value } else if (item == .input) .{ .input = value } else .{ .thinking = value };
        },
    };
    result.timeline = timeline;
    const groups = try a.alloc(Group, source.step_groups.items.len);
    for (source.step_groups.items, groups) |group, *dest| dest.* = .{ .first = group.first, .expanded = group.expanded };
    result.groups = groups;
    return result;
}
fn encodeMessage(a: std.mem.Allocator, source: messages.Message, context: *ContextTable) !Message {
    var result: Message = .{ .user = source.user, .text = source.text, .wire_text = source.wire_text, .turn = if (source.turn) |*turn| try encodeTurn(a, turn, context) else null, .attachments = null, .images = null };
    if (source.attachments) |bundle| {
        const items = try a.alloc(TextItem, bundle.items.len);
        for (bundle.items, items) |item, *dest| dest.* = .{ .id = item.id, .content = item.reference.content() orelse return error.EmptyAttachmentResult };
        result.attachments = .{ .owner = bundle.owner, .conversation_id = bundle.conversation_id, .draft_epoch = bundle.draft_epoch, .items = items };
    }
    if (source.images) |bundle| {
        const refs = try a.alloc(images.ContentRef, bundle.items.len);
        const ids = try a.alloc(u64, bundle.items.len);
        for (bundle.items, refs, ids) |item, *ref, *id| {
            ref.* = item.reference;
            id.* = item.id;
        }
        result.images = .{ .owner = bundle.owner, .conversation_id = bundle.conversation_id, .draft_epoch = bundle.draft_epoch, .ids = ids, .messages = try journal.Journal.encode(a, &.{.{ .content = "", .images = refs }}) };
    }
    return result;
}
/// Include the currently displayed final turn without moving it out of its view.
pub fn capture(allocator: std.mem.Allocator, history: []const messages.Message, current: ?messages.Message, cards: []const @import("card.zig").Card) ![]u8 {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var context: ContextTable = .{ .allocator = a };
    var result: std.ArrayList(Message) = .empty;
    for (history) |message| try result.append(a, try encodeMessage(a, message, &context));
    if (current) |message| {
        try result.append(a, try encodeMessage(a, message, &context));
        // Older/non-timeline turns still keep their complete rendered response.
        for (cards) |card| switch (card) {
            .text => |body| try result.append(a, try encodeMessage(a, .{ .user = false, .text = @constCast(body) }, &context)),
            .code => |code| try result.append(a, try encodeMessage(a, .{ .user = false, .text = @constCast(code.body) }, &context)),
            else => {},
        };
    }
    // Placing the context before the turn rows keeps a streaming tail update
    // contiguous in the journal patch even when its current row grows.
    return std.json.Stringify.valueAlloc(allocator, .{ .schema = @as(u8, 2), .context = context.entries.items, .messages = result.items }, .{});
}
fn decodeHistory(allocator: std.mem.Allocator, source: []const journal.Message, refs: *std.ArrayList(images.ContentRef)) !wire.History {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const decoded = try journal.Journal.decode(allocator, arena.allocator(), source, refs);
    return wire.History.copy(allocator, decoded, "");
}
fn decodeCheckpoint(a: std.mem.Allocator, inline_messages: []const journal.Message, indices: ?[]const usize, context: ?[]const provider.Message, refs: *std.ArrayList(images.ContentRef)) !wire.History {
    const table = context orelse {
        if (indices != null) return error.InvalidPresentation;
        return decodeHistory(a, inline_messages, refs);
    };
    if (inline_messages.len != 0) return error.InvalidPresentation;
    const order = indices orelse return error.InvalidPresentation;
    const ordered = try a.alloc(provider.Message, order.len);
    defer a.free(ordered);
    for (order, ordered) |index, *message| {
        if (index >= table.len) return error.InvalidPresentation;
        message.* = table[index];
    }
    return wire.History.copy(a, ordered, "");
}

fn decodeTurn(a: std.mem.Allocator, source: Turn, context: ?[]const provider.Message, refs: *std.ArrayList(images.ContentRef)) !turns.Turn {
    var result: turns.Turn = .{};
    errdefer result.deinit(a);
    inline for (scalar_fields) |field| @field(result, field) = @field(source, field);
    result.restored_interrupted = source.ended_at_ms == null;
    result.file_source = if (source.file_source) |value| try value.clone(a) else null;
    result.before = try decodeCheckpoint(a, source.before, source.before_refs, context, refs);
    result.after = try decodeCheckpoint(a, source.after, source.after_refs, context, refs);
    result.answer = try a.dupe(u8, source.answer);
    try result.prose.appendSlice(a, source.prose);
    try result.thinking.appendSlice(a, source.thinking);
    for (source.steps) |step| {
        var copy = try step.clone(a);
        errdefer copy.deinit(a);
        try result.steps.append(a, copy);
    }
    for (source.notices) |notice| {
        var copy = notice;
        copy.text = try a.dupe(u8, notice.text);
        errdefer a.free(copy.text);
        try result.host_notices.append(a, copy);
    }
    for (source.timeline) |item| {
        switch (item) {
            .tool => |i| if (i >= result.steps.items.len) return error.InvalidPresentation,
            .notice => |i| if (i >= result.host_notices.items.len) return error.InvalidPresentation,
            else => {},
        }
        try result.timeline.ensureUnusedCapacity(a, 1);
        result.timeline.appendAssumeCapacity(switch (item) {
            .tool => |index| .{ .tool = index },
            .notice => |index| .{ .notice = index },
            .message, .thinking, .input => |stored| blk: {
                const segment = try a.create(turns.Segment);
                segment.* = .{ .allocator = a, .started_ms = stored.started_ms, .ended_ms = stored.ended_ms, .expanded = stored.expanded, .submission = stored.submission };
                errdefer segment.release();
                try segment.text.appendSlice(a, stored.text);
                break :blk if (item == .message) .{ .message = segment } else if (item == .input) .{ .input = segment } else .{ .thinking = segment };
            },
        });
    }
    for (source.groups) |group| {
        try result.step_groups.ensureUnusedCapacity(a, 1);
        result.step_groups.appendAssumeCapacity(try @import("step_groups.zig").State.create(a, group.first, group.expanded));
    }
    return result;
}
fn decodeMessage(a: std.mem.Allocator, source: Message, context: ?[]const provider.Message, refs: *std.ArrayList(images.ContentRef)) !messages.Message {
    var result: messages.Message = .{ .user = source.user, .text = try a.dupe(u8, source.text) };
    errdefer result.deinit(a);
    result.wire_text = if (source.wire_text) |value| try a.dupe(u8, value) else null;
    result.turn = if (source.turn) |turn| try decodeTurn(a, turn, context, refs) else null;
    if (source.attachments) |bundle| {
        result.attachments = .{ .allocator = a, .owner = bundle.owner, .conversation_id = bundle.conversation_id, .draft_epoch = bundle.draft_epoch, .items = try a.alloc(text.Item, bundle.items.len) };
        const items = result.attachments.?.items;
        // Initialize all slots so partial decoding also releases safely.
        for (items) |*item| item.* = .{ .id = 0, .reference = .{} };
        result.attachments.?.items = items;
        for (bundle.items, items) |item, *dest| dest.* = .{ .id = item.id, .reference = try text.ContentRef.restore(a, item.content) };
    }
    if (source.images) |bundle| {
        var decoded = try decodeHistory(a, bundle.messages, refs);
        defer decoded.deinit();
        if (decoded.messages.len != 1 or decoded.messages[0].images.len != bundle.ids.len) return error.InvalidPresentation;
        const items = try a.alloc(images.SentItem, bundle.ids.len);
        for (bundle.ids, decoded.messages[0].images, items) |id, ref, *dest| dest.* = .{ .id = id, .reference = ref.retain() };
        result.images = .{ .allocator = a, .owner = bundle.owner, .conversation_id = bundle.conversation_id, .draft_epoch = bundle.draft_epoch, .items = items };
    }
    return result;
}
pub fn restore(a: std.mem.Allocator, bytes: []const u8, through: u64) !std.ArrayList(messages.Message) {
    const parsed = try std.json.parseFromSlice(Snapshot, a, bytes, .{});
    defer parsed.deinit();
    // Turn boundaries and attachment cards share immutable pixels on replay.
    var refs: std.ArrayList(images.ContentRef) = .empty;
    defer {
        for (refs.items) |*ref| ref.release();
        refs.deinit(a);
    }
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const context: ?[]const provider.Message = switch (parsed.value.schema) {
        1 => if (parsed.value.context.len == 0) null else return error.InvalidPresentation,
        2 => try journal.Journal.decode(a, arena.allocator(), parsed.value.context, &refs),
        else => return error.InvalidPresentation,
    };
    var result: std.ArrayList(messages.Message) = .empty;
    errdefer {
        for (result.items) |*message| message.deinit(a);
        result.deinit(a);
    }
    for (parsed.value.messages) |message| {
        if (message.turn) |turn| if (through != 0 and turn.id > through) break;
        try result.ensureUnusedCapacity(a, 1);
        result.appendAssumeCapacity(try decodeMessage(a, message, context, &refs));
    }
    return result;
}

/// Older journals retained model messages before display snapshots existed.
/// Recover their visible prose without inventing timestamps, steps or tool runs.
pub fn restoreHistory(a: std.mem.Allocator, bytes: ?[]const u8, through: u64, history: []const @import("provider.zig").Message) !std.ArrayList(messages.Message) {
    var result = if (bytes) |snapshot| try restore(a, snapshot, through) else std.ArrayList(messages.Message).empty;
    errdefer {
        for (result.items) |*message| message.deinit(a);
        result.deinit(a);
    }
    if (result.items.len != 0) return result;
    for (history) |message| {
        if (message.origin == .host_context_notice or message.role == .tool or message.content.len == 0) continue;
        try result.ensureUnusedCapacity(a, 1);
        result.appendAssumeCapacity(.{ .user = message.role == .user, .text = try a.dupe(u8, message.content) });
    }
    return result;
}

test "conversation presentation deduplicates repeated provider history without merging edited checkpoints" {
    const a = std.testing.allocator;
    const large = try a.alloc(u8, 256 * 1024);
    defer a.free(large);
    @memset(large, 'x');
    var first: turns.Turn = .{ .id = 1 };
    defer first.deinit(a);
    var second: turns.Turn = .{ .id = 2 };
    defer second.deinit(a);
    first.before = try wire.History.copy(a, &.{.{ .content = large }}, "");
    first.after = try wire.History.copy(a, first.before.messages, "第一轮");
    second.before = try wire.History.copy(a, first.after.messages, "");
    second.after = try wire.History.copy(a, &.{ .{ .content = large }, .{ .role = .assistant, .content = "编辑后" } }, "");
    const snapshot = try capture(a, &.{.{ .user = true, .text = @constCast("first"), .turn = first }}, .{ .user = true, .text = @constCast("second"), .turn = second }, &.{});
    defer a.free(snapshot);
    try std.testing.expect(snapshot.len < large.len + 4096);
    var restored = try restore(a, snapshot, 0);
    defer {
        for (restored.items) |*message| message.deinit(a);
        restored.deinit(a);
    }
    try std.testing.expectEqualStrings(large, restored.items[0].turn.?.before.messages[0].content);
    try std.testing.expectEqualStrings("第一轮", restored.items[1].turn.?.before.messages[1].content);
    try std.testing.expectEqualStrings("编辑后", restored.items[1].turn.?.after.messages[1].content);

    // Schema 1 stored each checkpoint inline and is still readable.
    const legacy = try std.json.parseFromSlice(Snapshot, a, snapshot, .{});
    defer legacy.deinit();
    var old = legacy.value.messages[0];
    old.turn.?.before_refs = null;
    old.turn.?.after_refs = null;
    old.turn.?.before = &.{.{ .role = .user, .content = large }};
    old.turn.?.after = &.{.{ .role = .assistant, .content = "旧回答" }};
    const legacy_bytes = try std.json.Stringify.valueAlloc(a, Snapshot{ .messages = &.{old} }, .{});
    defer a.free(legacy_bytes);
    var legacy_restored = try restore(a, legacy_bytes, 0);
    defer {
        for (legacy_restored.items) |*message| message.deinit(a);
        legacy_restored.deinit(a);
    }
    try std.testing.expectEqualStrings("旧回答", legacy_restored.items[0].turn.?.after.messages[0].content);
}

test "conversation presentation legacy history restores missing and empty snapshots without replay" {
    const a = std.testing.allocator;
    const history = [_]@import("provider.zig").Message{
        .{ .content = "旧问题 🧑‍💻" },
        .{ .role = .assistant, .content = "", .tool_calls = &.{.{ .id = "old-read", .name = "host.read_terminal", .arguments = "{}" }} },
        .{ .role = .tool, .content = "historical output is not assistant prose", .tool_call_id = "old-read" },
        .{ .role = .assistant, .content = "旧答案 ✅" },
    };
    for ([_]?[]const u8{ null, "{\"schema\":1,\"messages\":[]}" }) |snapshot| {
        var restored = try restoreHistory(a, snapshot, 1, &history);
        defer {
            for (restored.items) |*message| message.deinit(a);
            restored.deinit(a);
        }
        try std.testing.expectEqual(@as(usize, 2), restored.items.len);
        try std.testing.expect(restored.items[0].user and !restored.items[1].user);
        try std.testing.expectEqualStrings("旧问题 🧑‍💻", restored.items[0].text);
        try std.testing.expectEqualStrings("旧答案 ✅", restored.items[1].text);
        try std.testing.expect(restored.items[0].turn == null);
    }
}

test "conversation presentation interrupted replay freezes time and separates partial response without completing the turn" {
    const a = std.testing.allocator;
    var turn: turns.Turn = .{ .id = 4, .sent_at_ms = 1000, .started_mono_ms = 100, .elapsed_ms = 20 };
    defer turn.deinit(a);
    try turn.applyEvent(a, .{ .kind = .thinking, .detail = "检查过程", .phase = .assembling, .at_ms = 110 });
    try turn.applyEvent(a, .{ .kind = .step, .call_id = "read", .name = "host.read_terminal", .phase = .succeeded, .at_ms = 120 });
    try turn.applyEvent(a, .{ .kind = .text, .detail = "已收到的答复，尚未完成", .phase = .assembling, .at_ms = 140 });
    const bytes = try capture(a, &.{}, .{ .user = true, .text = @constCast("问题"), .turn = turn }, &.{});
    defer a.free(bytes);
    var restored = try restore(a, bytes, 4);
    defer {
        for (restored.items) |*message| message.deinit(a);
        restored.deinit(a);
    }
    const recovered = &restored.items[0].turn.?;
    try std.testing.expect(recovered.restored_interrupted and recovered.displayFinished());
    try std.testing.expect(recovered.ended_at_ms == null and recovered.answer.len == 0);
    try std.testing.expectEqualStrings("已收到的答复，尚未完成", recovered.displayResponse());
    try std.testing.expectEqual(@as(usize, 2), recovered.finalResponseStart());
    try std.testing.expectEqual(@as(u64, 140), recovered.displayClock(100000000));
    try std.testing.expect(!recovered.process_expanded);
    var copy = try recovered.clone(a);
    defer copy.deinit(a);
    try std.testing.expect(copy.restored_interrupted);
    // An earlier message followed by a tool is process text, not a final reply.
    try recovered.applyEvent(a, .{ .kind = .step, .call_id = "late", .name = "host.read_terminal", .phase = .running, .at_ms = 160 });
    try std.testing.expectEqualStrings("", recovered.displayResponse());
    try std.testing.expect(recovered.answer.len == 0 and recovered.ended_at_ms == null);
    try std.testing.expect(!@import("step_groups.zig").summarize(recovered, 3, 4, 100000000).live);
}

test "conversation presentation roundtrip keeps questions steps reasoning attachments and exact turn summary" {
    const a = std.testing.allocator;
    var turn: turns.Turn = .{ .id = 7, .sent_at_ms = 1793870400000, .ended_at_ms = 1793870404000, .elapsed_ms = 4000, .input_tokens = 1200, .output_tokens = 80, .request_count = 2 };
    defer turn.deinit(a);
    turn.before = try wire.History.copy(a, &.{}, "");
    turn.after = try wire.History.copy(a, &.{ .{ .content = "检查终端 🧑‍💻" }, .{ .role = .assistant, .content = "检查完毕 ✅" } }, "");
    turn.answer = try a.dupe(u8, "检查完毕 ✅");
    try turn.applyEvent(a, .{ .kind = .thinking, .detail = "先看现状", .phase = .assembling, .at_ms = 10 });
    try turn.applyEvent(a, .{ .kind = .step, .call_id = "read-1", .name = "host.read_terminal", .command = "read", .phase = .running, .at_ms = 20 });
    try turn.applyEvent(a, .{ .kind = .step, .call_id = "read-1", .name = "host.read_terminal", .detail = "真实终端输出", .phase = .succeeded, .at_ms = 30 });
    try turn.applyEvent(a, .{ .kind = .text, .detail = "检查完毕 ✅", .phase = .assembling, .at_ms = 40 });
    turn.finishSegment(50);
    var draft = try text.Draft.init(a, .{ .session = 1 });
    defer draft.deinit();
    const ticket = try draft.begin();
    var ref = try text.ContentRef.create(a, "说明.txt", "原始附件 🧑‍💻", 100);
    _ = try draft.complete(ticket, &ref);
    var bundle = try draft.freeze();
    defer bundle.deinit();
    const bytes = try capture(a, &.{}, .{ .user = true, .text = @constCast("检查终端 🧑‍💻"), .turn = turn, .attachments = bundle }, &.{.{ .text = "检查完毕 ✅" }});
    defer a.free(bytes);
    var restored = try restore(a, bytes, 7);
    defer {
        for (restored.items) |*message| message.deinit(a);
        restored.deinit(a);
    }
    turn.deinit(a);
    bundle.deinit();
    try std.testing.expectEqual(@as(usize, 2), restored.items.len);
    const question = restored.items[0];
    try std.testing.expect(question.user and question.turn != null);
    try std.testing.expectEqualStrings("检查终端 🧑‍💻", question.text);
    try std.testing.expectEqualStrings("原始附件 🧑‍💻", question.attachments.?.items[0].reference.content().?.bytes);
    const restored_turn = question.turn.?;
    try std.testing.expectEqual(@as(u64, 4000), restored_turn.elapsed_ms);
    try std.testing.expectEqual(@as(?u64, 1200), restored_turn.input_tokens);
    try std.testing.expectEqual(@as(?u64, 80), restored_turn.output_tokens);
    try std.testing.expectEqual(@as(?u64, 2), restored_turn.request_count);
    try std.testing.expectEqualStrings("先看现状", restored_turn.thinking.items);
    try std.testing.expectEqualStrings("真实终端输出", restored_turn.steps.items[0].detail);
    try std.testing.expectEqual(@as(usize, 3), restored_turn.timeline.items.len);
    try std.testing.expectEqualStrings("检查完毕 ✅", restored_turn.answer);
    // The rehydrated prefix remains valid input for the next Chinese/emoji turn.
    const request = try @import("provider_http.zig").requestBody(a, .openai_compat, .{ .model = "fixture", .system = "rules", .messages = restored_turn.after.messages }, 200000);
    defer a.free(request);
    try std.testing.expect(std.unicode.utf8ValidateSlice(request));
}

test "conversation presentation pinned prefix excludes later complete turns" {
    const a = std.testing.allocator;
    var first: turns.Turn = .{ .id = 1, .sent_at_ms = 100, .ended_at_ms = 200, .elapsed_ms = 100, .answer = try a.dupe(u8, "第一个答案") };
    defer first.deinit(a);
    var second: turns.Turn = .{ .id = 2, .sent_at_ms = 300, .ended_at_ms = 400, .elapsed_ms = 100, .answer = try a.dupe(u8, "第二个答案") };
    defer second.deinit(a);
    const history = [_]messages.Message{
        .{ .user = true, .text = @constCast("第一个问题"), .turn = first },
        .{ .user = false, .text = @constCast("第一个答案") },
        .{ .user = true, .text = @constCast("第二个问题"), .turn = second },
        .{ .user = false, .text = @constCast("第二个答案") },
    };
    const bytes = try capture(a, &history, null, &.{});
    defer a.free(bytes);
    var prefix = try restore(a, bytes, 1);
    defer {
        for (prefix.items) |*message| message.deinit(a);
        prefix.deinit(a);
    }
    try std.testing.expectEqual(@as(usize, 2), prefix.items.len);
    try std.testing.expectEqualStrings("第一个问题", prefix.items[0].text);
    try std.testing.expectEqualStrings("第一个答案", prefix.items[0].turn.?.answer);
    try std.testing.expectEqual(@as(u64, 100), prefix.items[0].turn.?.elapsed_ms);
}

test "conversation presentation retained image pixels survive original bundle release" {
    const a = std.testing.allocator;
    const png = "\x89PNG\r\n\x1a\n\x00\x00\x00\x0dIHDR" ++ "\x00\x00\x00\x01\x00\x00\x00\x01\x08\x06\x00\x00\x00\x1f\x15\xc4\x89" ++ "\x00\x00\x00\x0dIDAT\x78\x9c\x63\xf8\xcf\xc0\xf0\x1f\x00\x05\x00\x01\xff\x89\x99\x3d\x1d" ++ "\x00\x00\x00\x00IEND\xae\x42\x60\x82";
    var ref = try images.ContentRef.create(a, "original.png", png, 100, .{});
    defer ref.release();
    var items = [_]images.SentItem{.{ .id = 4, .reference = ref }};
    const bundle: images.Bundle = .{ .allocator = a, .owner = .{ .session = 1 }, .draft_epoch = 1, .items = &items };
    var turn: turns.Turn = .{ .id = 1 };
    defer turn.deinit(a);
    turn.before = try wire.History.copy(a, &.{.{ .content = "pixels", .images = &.{ref} }}, "");
    turn.after = try wire.History.copy(a, turn.before.messages, "");
    const bytes = try capture(a, &.{}, .{ .user = true, .text = @constCast("看图片"), .images = bundle, .turn = turn }, &.{});
    defer a.free(bytes);
    ref.release();
    turn.deinit(a);
    var restored = try restore(a, bytes, 0);
    defer {
        for (restored.items) |*message| message.deinit(a);
        restored.deinit(a);
    }
    const restored_ref = restored.items[0].images.?.items[0].reference;
    try std.testing.expect(restored_ref.snapshot == restored.items[0].turn.?.before.messages[0].images[0].snapshot);
    try std.testing.expect(restored_ref.snapshot == restored.items[0].turn.?.after.messages[0].images[0].snapshot);
    const content = restored_ref.content().?;
    try std.testing.expectEqualStrings("original.png", content.path);
    try std.testing.expectEqualSlices(u8, png, content.bytes);
    try std.testing.expectEqual(@as(u32, 1), content.width);
}
