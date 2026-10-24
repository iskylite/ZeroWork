const std = @import("std");
const terminal = @import("ai/terminal_text_attachments.zig");
const attachments = @import("ai/local_text_attachments.zig");
const request = @import("ai/local_text_request.zig");
const identity = @import("host/identity.zig");
const a = std.testing.allocator;
const owner: identity.SessionHandle = .{ .session_id = @fromBackingInt(101), .generation = 7 };
const selected: terminal.Selection = .{ .owner = owner, .source_name = "Original node", .source_version = 123, .selected_rows = 2, .selection = .{ .start = .{ .owner = owner, .id = 9 }, .end = .{ .owner = owner, .id = 10 }, .rectangle = false } };

test "AI terminal text freezes original selection bytes owner generation time rows and provenance" {
    var text = "14:20:05 真正日志时间\n14:20:06 失败输出".*;
    var name = "Original node".*;
    var metadata = selected;
    metadata.source_name = &name;
    metadata.selected_rows = 4; // Actual wrapped/rectangular VT span, not text lines.
    metadata.selection.rectangle = true;
    var value = try terminal.createSelection(a, metadata, &text, 1700000000123);
    defer value.release();
    @memset(&text, 'x');
    @memset(&name, 'x');
    metadata.owner.generation += 1;
    metadata.selection.start.id += 1;
    const content = value.content().?;
    try std.testing.expectEqualStrings("终端选区.txt", content.path);
    try std.testing.expectEqualStrings("14:20:05 真正日志时间\n14:20:06 失败输出", content.bytes);
    try std.testing.expectEqual(@as(i64, 1700000000123), content.captured_at_ms);
    try std.testing.expect(content.source == .terminal);
    try std.testing.expect(content.source.terminal.owner.eql(owner));
    try std.testing.expectEqualStrings("Original node", content.source.terminal.source_name);
    try std.testing.expectEqual(@as(u32, 4), content.source.terminal.line_count);
    try std.testing.expectEqual(@as(u64, 123), content.source.terminal.origin.selection.source_version);
    try std.testing.expectEqual(@as(u64, 9), content.source.terminal.origin.selection.selection.start.id);
    try std.testing.expect(content.source.terminal.origin.selection.selection.rectangle);
    var hash: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(content.bytes, &hash, .{});
    try std.testing.expectEqual(hash, content.sha256);
}

test "AI terminal text uses actual 1MiB VT service bound independently of local file 64KiB" {
    const bytes = try a.alloc(u8, terminal.max_capture_bytes + 1);
    defer a.free(bytes);
    @memset(bytes, 'a');
    try std.testing.expectError(error.LocalTextTooLarge, attachments.ContentRef.create(a, "/local.txt", bytes[0 .. 96 * 1024], 1));
    for ([_]usize{ 64 * 1024 + 1, 96 * 1024, terminal.max_capture_bytes }) |length| {
        var value = try terminal.createSelection(a, selected, bytes[0..length], 1);
        defer value.release();
        try std.testing.expectEqual(length, value.content().?.bytes.len);
        try std.testing.expectEqualSlices(u8, bytes[0..length], value.content().?.bytes);
    }
    try std.testing.expectError(error.TerminalTextTooLarge, terminal.createSelection(a, selected, bytes, 1));
}

test "AI terminal text rejects foreign anchors invalid encoding empty or unversioned source without IO" {
    var foreign = selected;
    foreign.selection.end.owner.generation += 1;
    try std.testing.expectError(error.StaleOwner, terminal.createSelection(a, foreign, "valid", 1));
    foreign = selected;
    foreign.source_version = 0;
    try std.testing.expectError(error.InvalidTerminalSource, terminal.createSelection(a, foreign, "valid", 1));
    foreign = selected;
    foreign.owner.generation = 0;
    try std.testing.expectError(error.InvalidAttachmentOwner, terminal.createSelection(a, foreign, "valid", 1));
    try std.testing.expectError(error.EmptyTerminalSelection, terminal.createSelection(a, selected, "", 1));
    try std.testing.expectError(error.InvalidTerminalText, terminal.createSelection(a, selected, "text\x00hidden", 1));
    try std.testing.expectError(error.InvalidTerminalText, terminal.createSelection(a, selected, "\xc3\x28", 1));
}

test "AI terminal text command context remains distinct from selection and freezes original failed command" {
    var command = "false 工作目录".*;
    var output = "14:20:05 original failure\nsecond line\n".*;
    const hint: @import("ai/command_error_hint.zig").Hint = .{ .owner = owner, .command_id = 17, .end_sequence = 19, .command = &command, .output = &output, .exit_code = 2 };
    var value = try terminal.createCommand(a, hint, "Original node", 1234);
    defer value.release();
    @memset(&command, 'x');
    @memset(&output, 'x');
    const content = value.content().?;
    try std.testing.expectEqualStrings("命令上下文.txt", content.path);
    try std.testing.expectEqualStrings("false 工作目录", content.source.terminal.origin.command.command);
    try std.testing.expectEqualStrings("14:20:05 original failure\nsecond line\n", content.bytes);
    try std.testing.expectEqual(@as(u32, 2), content.source.terminal.line_count);
    try std.testing.expectEqual(@as(u64, 17), content.source.terminal.origin.command.command_id);
    try std.testing.expectEqual(@as(i32, 2), content.source.terminal.origin.command.exit_code);
    try std.testing.expectEqual(@as(u32, 0), terminal.lineCount(""));
    try std.testing.expectEqual(@as(u32, 1), terminal.lineCount("\n"));
    try std.testing.expectEqual(@as(u32, 2), terminal.lineCount("one\nlast"));
}

test "AI terminal text preview confirmation and sent references survive draft removal and changed source" {
    var draft = try attachments.Draft.init(a, .{ .session = 101 });
    defer draft.deinit();
    const ticket = try draft.beginTerminal(owner);
    var incoming = try terminal.createSelection(a, selected, "immutable selection", 44);
    try draft.stage(ticket, &incoming);
    try std.testing.expect(incoming.content() == null);
    try std.testing.expectEqual(@as(usize, 0), draft.items.items.len);
    try std.testing.expectError(error.AttachmentsProcessing, draft.freeze());
    _ = try draft.attach(ticket);
    var sent = try draft.freeze();
    defer sent.deinit();
    var retained = try sent.retain();
    defer retained.deinit();
    try std.testing.expect(draft.remove(ticket.id));
    try std.testing.expectEqualStrings("immutable selection", sent.items[0].reference.content().?.bytes);
    try std.testing.expect(retained.items[0].reference.content().?.source.terminal.owner.eql(owner));
    try std.testing.expectEqual(@as(u64, 9), retained.items[0].reference.content().?.source.terminal.origin.selection.selection.start.id);
}

test "AI terminal text original generation ticket rejects replacement and cancelled or old epoch completions" {
    var draft = try attachments.Draft.init(a, .{ .session = 101 });
    defer draft.deinit();
    try std.testing.expectError(error.StaleAttachment, draft.beginTerminal(.{ .session_id = @fromBackingInt(102), .generation = 7 }));
    const ticket = try draft.beginTerminal(owner);
    var replacement = selected;
    replacement.owner = try owner.nextGeneration();
    replacement.selection.start.owner = replacement.owner;
    replacement.selection.end.owner = replacement.owner;
    var wrong = try terminal.createSelection(a, replacement, "wrong generation", 1);
    try std.testing.expectError(error.StaleAttachment, draft.stage(ticket, &wrong));
    try std.testing.expect(wrong.content() == null);
    try std.testing.expect(draft.contains(ticket));
    var local = try attachments.ContentRef.create(a, "/must-not-be-used", "local", 1);
    try std.testing.expectError(error.StaleAttachment, draft.complete(ticket, &local));
    try std.testing.expect(draft.cancel(ticket));
    var late = try terminal.createSelection(a, selected, "late original", 1);
    try std.testing.expectError(error.StaleAttachment, draft.complete(ticket, &late));
    const old = try draft.beginTerminal(owner);
    try draft.clear();
    var cleared = try terminal.createSelection(a, selected, "old epoch", 1);
    try std.testing.expectError(error.StaleAttachment, draft.stage(old, &cleared));
    const ordinary = try draft.begin();
    var unbound = try terminal.createSelection(a, selected, "no original generation ticket", 1);
    try std.testing.expectError(error.InvalidTerminalAttachmentTicket, draft.stage(ordinary, &unbound));
    try std.testing.expect(unbound.content() == null);
}

test "AI terminal text group draft retains explicit source session without pretending it is group output" {
    var draft = try attachments.Draft.init(a, .{ .group = 5 });
    defer draft.deinit();
    const ticket = try draft.beginTerminal(owner);
    var value = try terminal.createSelection(a, selected, "one original member", 1);
    try draft.stage(ticket, &value);
    _ = try draft.attach(ticket);
    var sent = try draft.freeze();
    defer sent.deinit();
    try std.testing.expect(sent.owner.eql(.{ .group = 5 }));
    try std.testing.expect(sent.items[0].reference.content().?.source.terminal.owner.eql(owner));
}

test "AI terminal text request composes full bytes metadata and budget without local path identity" {
    var draft = try attachments.Draft.init(a, .{ .session = 101 });
    defer draft.deinit();
    const ticket = try draft.beginTerminal(owner);
    const bytes = try a.alloc(u8, 96 * 1024);
    defer a.free(bytes);
    @memset(bytes, 'a');
    var value = try terminal.createSelection(a, selected, bytes, 12345);
    _ = try draft.complete(ticket, &value);
    var bundle = try draft.freeze();
    defer bundle.deinit();
    const wire = try request.compose(a, "保留原问题", &bundle, 2 * 1024 * 1024);
    defer a.free(wire);
    try std.testing.expect(std.mem.indexOf(u8, wire, "<terminal_selection_attachment>") != null);
    try std.testing.expect(std.mem.indexOf(u8, wire, "local_text_attachment") == null);
    try std.testing.expect(std.mem.indexOf(u8, wire, "source_session=101\nsource_generation=7") != null);
    try std.testing.expect(std.mem.indexOf(u8, wire, "captured_at_ms=12345\nselected_rows=2\nsource_version=123") != null);
    try std.testing.expect(std.mem.indexOf(u8, wire, bytes) != null);
    const exact = try request.compose(a, "保留原问题", &bundle, wire.len);
    defer a.free(exact);
    try std.testing.expectEqualSlices(u8, wire, exact);
    try std.testing.expectError(error.RequestTooLarge, request.compose(a, "保留原问题", &bundle, wire.len - 1));
    const messages = [_]@import("ai/provider.zig").Message{.{ .role = .user, .content = wire }};
    const chat: @import("ai/provider.zig").ChatRequest = .{ .model = "fixture", .system = "", .messages = &messages, .max_output = 1024 };
    try std.testing.expect(try request.inputTokens(chat) >= bytes.len / 4);
    try std.testing.expectError(error.ContextBudgetExceeded, request.checkContext(chat, 4096));
    try request.checkContext(chat, 131072);
    try std.testing.expectEqual(@as(usize, 1), draft.items.items.len);
    try std.testing.expectEqualStrings(bytes, draft.items.items[0].reference.content().?.bytes);
}

fn allocationCase(allocator: std.mem.Allocator) !void {
    const hint: @import("ai/command_error_hint.zig").Hint = .{ .owner = owner, .command_id = 1, .end_sequence = 2, .command = "false", .output = "original failure", .exit_code = 1 };
    var value = try terminal.createCommand(allocator, hint, "Original node", 1);
    defer value.release();
    var draft = try attachments.Draft.init(allocator, .{ .session = 101 });
    defer draft.deinit();
    const ticket = try draft.beginTerminal(owner);
    var staged = value.retain();
    try draft.stage(ticket, &staged);
    _ = try draft.attach(ticket);
    var bundle = try draft.freeze();
    defer bundle.deinit();
    const wire = try request.compose(allocator, "question", &bundle, 4096);
    defer allocator.free(wire);
    try std.testing.expect(std.mem.indexOf(u8, wire, "<terminal_command_context>") != null);
    try std.testing.expect(std.mem.indexOf(u8, wire, "command_id=1\ncommand_end=2\nexit_code=1\ncommand=false") != null);
}
test "AI terminal text allocation failures release provenance and reference snapshots" {
    try std.testing.checkAllAllocationFailures(a, allocationCase, .{});
}

comptime {
    _ = @import("ai_local_text_attachment_tests.zig");
}
