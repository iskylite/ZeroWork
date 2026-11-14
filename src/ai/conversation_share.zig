//! A local, readable snapshot of one displayed conversation.
const std = @import("std");
const Message = @import("assistant_store.zig").Message;
const Turn = @import("conversation_turn.zig").Turn;
const Step = @import("step_events.zig").Step;
const Card = @import("card.zig").Card;
const ConversationId = @import("../host/identity.zig").ConversationId;
const directory = "ai-shares";

fn filename(id: ConversationId, buffer: *[35]u8) []const u8 {
    const hex = std.fmt.bytesToHex(id.bytes, .lower);
    return std.fmt.bufPrint(buffer, "{s}.md", .{hex}) catch unreachable;
}

pub fn remove(io: std.Io, root: std.Io.Dir, id: ConversationId) !void {
    if (!id.valid()) return error.ConversationUnavailable;
    const dir = root.openDir(io, directory, .{ .follow_symlinks = false }) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    defer dir.close(io);
    var buffer: [35]u8 = undefined;
    dir.deleteFile(io, filename(id, &buffer)) catch |err| if (err != error.FileNotFound) return err;
}

pub fn save(a: std.mem.Allocator, io: std.Io, data_root: []const u8, id: ConversationId, history: []const Message, current: ?Message, cards: []const Card) ![]u8 {
    if (history.len == 0 and current == null) return error.EmptyConversation;
    if (data_root.len == 0 or !id.valid()) return error.ConversationUnavailable;
    const dir = try std.Io.Dir.cwd().openDir(io, data_root, .{});
    defer dir.close(io);
    var root: [std.fs.max_path_bytes]u8 = undefined;
    const root_len = try dir.realPath(io, &root);
    var name_buffer: [35]u8 = undefined;
    const name = filename(id, &name_buffer);
    const hex = std.fmt.bytesToHex(id.bytes, .lower);
    const absolute = try std.fs.path.join(a, &.{ root[0..root_len], directory, name });
    defer a.free(absolute);
    const uri: std.Uri = .{ .scheme = "file", .host = .empty, .path = .{ .raw = absolute } };
    const url = try std.fmt.allocPrint(a, "{f}", .{uri});
    errdefer a.free(url);

    dir.createDir(io, directory, @fromBackingInt(0o700)) catch |err| if (err != error.PathAlreadyExists) return err;
    const shares = try dir.openDir(io, directory, .{ .follow_symlinks = false });
    defer shares.close(io);
    var atomic = try shares.createFileAtomic(io, name, .{ .permissions = @fromBackingInt(0o600), .replace = true });
    defer atomic.deinit(io);
    var buffer: [4096]u8 = undefined;
    var writer = atomic.file.writer(io, &buffer);
    const out = &writer.interface;
    try out.print("# AI 会话 {s}\n\n", .{hex});
    var has_response = false;
    for (history) |*message| {
        if (message.user) {
            has_response = try writeMessage(out, message);
        } else if (!has_response) {
            try writeAssistant(out, message.text);
        }
    }
    if (current) |*message| {
        if (!try writeMessage(out, message)) for (cards) |card| switch (card) {
            .text => |body| try writeAssistant(out, body),
            .code => |code| try writeCode(out, code.body),
            else => {},
        };
    }
    try out.flush();
    try atomic.replace(io);
    return url;
}

fn writeMessage(out: *std.Io.Writer, message: *const Message) !bool {
    try writeSection(out, "你", message.text);
    const turn: *const Turn = if (message.turn) |*value| value else return false;
    const response = turn.displayResponse();
    if (turn.timeline.items.len != 0) {
        const response_start = turn.finalResponseStart();
        for (turn.timeline.items, 0..) |item, i| switch (item) {
            .message => |segment| if (i < response_start) try writeAssistant(out, segment.text.items),
            .thinking => |segment| try writeSection(out, "思考", segment.text.items),
            .input => |segment| try writeSection(out, "你", segment.text.items),
            .tool => |index| try writeStep(out, turn.steps.items[index]),
            .notice => |index| try writeSection(out, "提示", turn.host_notices.items[index].text),
        };
    } else {
        try writeSection(out, "思考", turn.thinking.items);
        for (turn.steps.items) |step| try writeStep(out, step);
        for (turn.host_notices.items) |notice| try writeSection(out, "提示", notice.text);
        const prose = turn.prose.items;
        const end = if (std.mem.endsWith(u8, prose, response)) prose.len - response.len else prose.len;
        try writeAssistant(out, prose[0..end]);
    }
    try writeAssistant(out, response);
    return response.len != 0 or turn.prose.items.len != 0;
}

fn writeAssistant(out: *std.Io.Writer, body: []const u8) !void {
    try writeSection(out, "AI 助手", @import("history_environment.zig").assistantText(body));
}

fn writeCode(out: *std.Io.Writer, body: []const u8) !void {
    if (body.len == 0) return;
    try out.writeAll("## AI 助手\n\n");
    var lines = std.mem.splitScalar(u8, body, '\n');
    while (lines.next()) |line| try out.print("    {s}\n", .{line});
    try out.writeByte('\n');
}

fn writeSection(out: *std.Io.Writer, label: []const u8, body: []const u8) !void {
    if (body.len != 0) try out.print("## {s}\n\n{s}\n\n", .{ label, body });
}

fn writeStep(out: *std.Io.Writer, step: Step) !void {
    try out.print("## 工具 · {s} ({s})\n\n", .{ step.name, @tagName(step.phase) });
    if (step.command.len != 0) try out.print("{s}\n\n", .{step.command});
    if (step.detail.len != 0) try out.print("{s}\n\n", .{step.detail});
}

test "AiHost integration share keeps legacy answers and turn prose without repeating retained cards" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path: [std.fs.max_path_bytes]u8 = undefined;
    const root = path[0..try tmp.dir.realPath(io, &path)];
    const id = ConversationId.generate();
    const marker = @import("history_environment.zig").marker;
    var turn: Turn = .{ .answer = try a.dupe(u8, marker ++ "\nFinal answer") };
    defer turn.deinit(a);
    try turn.prose.appendSlice(a, "Earlier explanation\n" ++ marker ++ "\nFinal answer");
    const history: []const Message = &.{
        .{ .user = true, .text = @constCast("Legacy question") },
        .{ .user = false, .text = @constCast(marker ++ "\nLegacy answer") },
        .{ .user = true, .text = @constCast("Full question"), .turn = turn },
        .{ .user = false, .text = @constCast("Final answer") },
    };
    const url = try save(a, io, root, id, history, .{ .user = true, .text = @constCast("Code question") }, &.{.{ .code = .{ .lang = "text", .body = "# Code\nsecond line" } }});
    defer a.free(url);
    const dir = try tmp.dir.openDir(io, directory, .{});
    defer dir.close(io);
    var name_buffer: [35]u8 = undefined;
    const body = try dir.readFileAlloc(io, filename(id, &name_buffer), a, .unlimited);
    defer a.free(body);
    try std.testing.expect(std.mem.indexOf(u8, body, "Legacy answer") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "Earlier explanation") != null);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, body, "Final answer"));
    try std.testing.expect(std.mem.indexOf(u8, body, marker) == null);
    try std.testing.expect(std.mem.indexOf(u8, body, "    # Code\n    second line") != null);
}
