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

const Results = @import("tool_results.zig").Store;

pub fn save(a: std.mem.Allocator, io: std.Io, data_root: []const u8, id: ConversationId, history: []const Message, current: ?Message, cards: []const Card, results: ?*const Results) ![]u8 {
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
            has_response = try writeMessage(out, message, results);
        } else if (!has_response) {
            try writeAssistant(out, message.text);
        }
    }
    if (current) |*message| {
        if (!try writeMessage(out, message, results)) for (cards) |card| switch (card) {
            .text => |body| try writeAssistant(out, body),
            .code => |code| try writeCode(out, code.body),
            else => {},
        };
    }
    try out.flush();
    try atomic.replace(io);
    return url;
}

fn writeMessage(out: *std.Io.Writer, message: *const Message, results: ?*const Results) !bool {
    try writeSection(out, "你", message.text);
    const turn: *const Turn = if (message.turn) |*value| value else return false;
    const response = turn.displayResponse();
    if (turn.timeline.items.len != 0) {
        const response_start = turn.finalResponseStart();
        for (turn.timeline.items, 0..) |item, i| switch (item) {
            .message => |segment| if (i < response_start) try writeAssistant(out, segment.text.items),
            .thinking => |segment| try writeSection(out, "思考", segment.text.items),
            .input => |segment| try writeSection(out, "你", segment.text.items),
            .tool => |index| try writeStep(out, turn.steps.items[index], turn.id, results),
            .notice => |index| try writeSection(out, "提示", turn.host_notices.items[index].text),
        };
    } else {
        try writeSection(out, "思考", turn.thinking.items);
        for (turn.steps.items) |step| try writeStep(out, step, turn.id, results);
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

fn writeStep(out: *std.Io.Writer, step: Step, turn_id: u64, results: ?*const Results) !void {
    const facts = @import("execution_result_projection.zig");
    if (step.activity_started_ms == null and (step.phase == .rejected or step.phase == .failed) and facts.supports(step.name)) {
        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer arena.deinit();
        if (try facts.fromStep(arena.allocator(), step)) |execution| return writeExecution(out, step.name, execution);
    }
    if (results) |store| if (store.findCall(turn_id, step.call_id)) |record| {
        if (store.executionProjection(record)) |execution| {
            return writeExecution(out, step.name, execution);
        }
        if (std.mem.eql(u8, record.name, "run_command") and record.targets.len != 0) {
            try out.print("## 工具 · {s}\n\n", .{step.name});
            try writeIndented(out, record.command);
            for (record.targets) |target| {
                const result = target.result;
                try out.print("- 会话 #{d} · {s}\n", .{ result.session_id, facts.batchStatus(result) });
                if (result.exit) |code| try out.print("- 退出码 {d}\n", .{code});
                if (result.signal) |signal| try out.print("- 结束信号 {d}\n", .{signal});
                if (result.error_code) |code| try out.print("- 错误码：{s}\n", .{code});
                if (facts.batchOutputLabel(result)) |label| try out.print("- {s}\n", .{label});
                if (result.truncated or result.retained_truncated) try out.writeAll("- 输出有缺失或截断。\n");
                try out.writeByte('\n');
                if (result.stdout.len != 0) {
                    try out.writeAll("标准输出\n\n");
                    try writeIndented(out, result.stdout);
                }
                if (result.stderr.len != 0) {
                    try out.writeAll("标准错误\n\n");
                    try writeIndented(out, result.stderr);
                }
            }
            return;
        }
    };
    if (facts.supports(step.name)) {
        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer arena.deinit();
        if (try facts.fromStep(arena.allocator(), step)) |execution| return writeExecution(out, step.name, execution);
        const status = switch (step.phase) {
            .assembling, .approval => "等待派发",
            .running => "工具调用中 · 命令状态待核实",
            .skipped => "已跳过",
            else => "未保留执行回执",
        };
        try out.print("## 工具 · {s} · {s}\n\n", .{ step.name, status });
        if (step.command.len != 0) try writeIndented(out, step.command);
        if (step.detail.len != 0) try writeIndented(out, step.detail);
        return;
    }
    try out.print("## 工具 · {s} ({s})\n\n", .{ step.name, @tagName(step.phase) });
    if (step.command.len != 0) try out.print("{s}\n\n", .{step.command});
    if (step.detail.len != 0) try out.print("{s}\n\n", .{step.detail});
}

fn writeExecution(out: *std.Io.Writer, name: []const u8, execution: @import("execution_result_projection.zig").Projection) !void {
    try out.print("## 工具 · {s} · {s}\n\n", .{ name, execution.statusLabel() });
    if (execution.command) |command| try writeIndented(out, command);
    var buffer: [64]u8 = undefined;
    if (!execution.input_result) if (try execution.processLabel(&buffer)) |label| try out.print("- {s}\n", .{label});
    if (execution.failure) |code| {
        try out.print("- 错误码：{s}\n", .{code});
        if (std.mem.eql(u8, code, "RecordingExecutionCapacity") or std.mem.eql(u8, code, "SessionReconnected") or std.mem.eql(u8, code, "SessionClosed") or std.mem.eql(u8, code, "ToolApprovalRejected")) {
            try out.print("- {s}\n", .{@import("step_failure.zig").explanation(code)});
        }
    }
    if (execution.outputLabel()) |label| try out.print("- {s}\n", .{label});
    if (execution.output_gap or execution.output_truncated) try out.writeAll("- 输出有缺失或截断。\n");
    if (execution.output_error) |code| try out.print("- 输出读取错误：{s}\n", .{code});
    if (execution.recording_failed) try out.writeAll("- 录制保存失败。\n");
    if (execution.execution_id) |id| try out.print("- 执行引用：`x1:{s}`\n", .{std.fmt.bytesToHex(id.bytes, .lower)});
    if (execution.recording_id) |id| try out.print("- 录制：`{s}`\n", .{std.fmt.bytesToHex(id.bytes, .lower)});
    try out.writeByte('\n');
    if (execution.terminal_output.len != 0) try writeIndented(out, execution.terminal_output);
}

fn writeIndented(out: *std.Io.Writer, text: []const u8) !void {
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| try out.print("    {s}\n", .{line});
    try out.writeByte('\n');
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
    const url = try save(a, io, root, id, history, .{ .user = true, .text = @constCast("Code question") }, &.{.{ .code = .{ .lang = "text", .body = "# Code\nsecond line" } }}, null);
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

test "execution export uses terminal receipts rather than approval and tool callback status" {
    const a = std.testing.allocator;
    const identity = @import("../host/identity.zig");
    const terminal = @import("../host/terminal_execution.zig");
    const host = @import("host_tools.zig");
    const context: host.Context = .{ .conversation_id = .generate(), .task_id = .generate(), .binding = .{ .session = 1 }, .binding_revision = 1, .grant_revision = 1 };
    const owner: identity.SessionHandle = .{ .session_id = @fromBackingInt(1), .generation = 1 };
    const id = identity.ExecutionId.generate();
    const reference = try std.fmt.allocPrint(a, "x1:{s}", .{std.fmt.bytesToHex(id.bytes, .lower)});
    defer a.free(reference);
    var run = @import("tool_loop.zig").Loop.init(a, .{ .owner = context.binding, .members = .{} }, 3, .{});
    defer run.deinit();
    const key = run.arena.allocator();
    const Initial = struct { execution_ref: []const u8, snapshot: terminal.Snapshot, source_revision: u64, output: []const u8 = "", output_available: bool = true };
    const running: terminal.Snapshot = .{ .owner = owner, .execution_id = id, .state = .running, .submit_sent = true };
    var finished = running;
    finished.state = .interval_recorded;
    finished.process = .{ .foreground_finished = true, .exit_code = 0 };
    finished.output_scope = .session_interval;
    finished.recording_id = "0123456789abcdef0123456789abcdef".*;
    finished.recording_settled = true;
    finished.interval_saved = true;
    const blocks = [_][]u8{
        try std.json.Stringify.valueAlloc(key, Initial{ .execution_ref = reference, .snapshot = running, .source_revision = 1 }, .{}),
        try std.json.Stringify.valueAlloc(key, Initial{ .execution_ref = reference, .snapshot = finished, .source_revision = 2 }, .{}),
        try key.dupe(u8, "{\"state\":\"cancelled_unsent\",\"error_code\":\"RecordingExecutionCapacity\"}"),
    };
    for (blocks, [_][]const u8{ "run", "wait", "probe" }, 0..) |body, call, index| {
        const content = try a.alloc(host.Block, 1);
        content[0] = .{ .structured = try a.dupe(u8, body) };
        try run.records.append(key, .{ .key = .{ .owner = context.binding, .turn_id = 3, .call_id = call }, .name = if (index == 1) "host.wait_execution" else "host.run_in_terminal", .arguments = "{\"command\":\"true\"}", .arguments_hash = @splat(1), .dispatched = index != 2, .host_result = .{ .status = if (index == 2) .rejected else .succeeded, .blocks = content, .receipt = .{ .conversation_id = context.conversation_id, .task_id = context.task_id, .operation_id = index + 1, .binding_revision = 1 } } });
    }

    var store = Results.init(a);
    defer store.deinit();
    _ = try store.capture(&run, &.{});
    var turn: Turn = .{ .id = 3 };
    defer turn.deinit(a);
    for ([_][]const u8{ "run", "probe" }) |call| {
        try turn.applyEvent(a, .{ .call_id = call, .name = "host.run_in_terminal", .command = "true", .detail = "已批准，准备提交", .phase = .succeeded, .at_ms = 1 });
    }
    try turn.applyEvent(a, .{
        .call_id = "approval-denied",
        .name = "host.run_in_terminal",
        .command = "{\"command\":\"false\"}",
        .phase = .approval,
        .at_ms = 1,
    });
    try turn.applyEvent(a, .{
        .call_id = "approval-denied",
        .detail = "{\"status\":\"rejected\",\"error_code\":\"ToolApprovalRejected\",\"side_effect_started\":false}",
        .phase = .failed,
        .at_ms = 2,
    });
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    var path: [std.fs.max_path_bytes]u8 = undefined;
    const root = path[0..try tmp.dir.realPath(io, &path)];
    const link = try save(a, io, root, context.conversation_id, &.{}, .{ .user = true, .text = @constCast("检查终端结果"), .turn = turn }, &.{}, &store);
    defer a.free(link);
    const dir = try tmp.dir.openDir(io, directory, .{});
    defer dir.close(io);
    var name: [35]u8 = undefined;
    const exported = try dir.readFileAlloc(io, filename(context.conversation_id, &name), a, .unlimited);
    defer a.free(exported);
    try std.testing.expect(std.mem.indexOf(u8, exported, "命令已结束") != null);
    try std.testing.expect(std.mem.indexOf(u8, exported, "退出码 0") != null);
    try std.testing.expect(std.mem.indexOf(u8, exported, "本次采集区间没有输出。") != null);
    try std.testing.expect(std.mem.indexOf(u8, exported, "RecordingExecutionCapacity") != null);
    try std.testing.expect(std.mem.indexOf(u8, exported, "命令未派发，没有执行输出。") != null);
    try std.testing.expect(std.mem.indexOf(u8, exported, "未执行 · 已拒绝\n\n    false") != null);
    try std.testing.expect(std.mem.indexOf(u8, exported, "用户拒绝了本次工具操作。") != null);
    try std.testing.expect(std.mem.indexOf(u8, exported, "已批准，准备提交") == null);
}
